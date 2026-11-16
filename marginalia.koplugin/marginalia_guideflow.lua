-- marginalia_guideflow.lua
-- The reading guide, end to end. A set of methods that marginalia_integration.lua
-- adds to the plugin: offer the guide, ask the AI for it in the background, check the
-- answer a second time, save it with the book, show it. The screens themselves are in
-- marginalia_guideui.lua (replaceable: the specs use a fake one).
--
-- Spoiler rules specific to the guide (it leans on what the AI KNOWS about the book):
--   * no book text goes into the request except what the spoiler gate lets through,
--     so at the very start of a book the guide is built from the description alone
--   * the answer is checked by the second-pass checker before it is saved or shown;
--     a flagged or unchecked guide is NOT swapped silently: the reader is warned and
--     chooses [Regenerate] or [Show anyway]

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local Guide = require(plugin_path .. "marginalia_guide")
local SpoilerCheck = require(plugin_path .. "marginalia_spoilercheck")

local GuideFlow = {}

local SETTING = "marginalia_guide"
local POLL_SECONDS = 2
local TIMEOUT_SECONDS = 300

local function uiManager()
    return require("ui/uimanager")
end

-- ---------------------------------------------------------------------------
-- Saved guide
-- ---------------------------------------------------------------------------

function GuideFlow:marginaliaGuideLoad()
    local ds = self.ui and self.ui.doc_settings
    if not ds then return nil end
    local saved = ds:readSetting(SETTING)
    return type(saved) == "table" and saved or nil
end

function GuideFlow:marginaliaGuideSave(saved)
    local ds = self.ui and self.ui.doc_settings
    if not ds then return end
    ds:saveSetting(SETTING, saved)
    ds:flush()
end

-- The genre chosen for this book (detected, or set by the reader), or nil.
function GuideFlow:marginaliaGuideGenre()
    local saved = self:marginaliaGuideLoad()
    return Guide.isUsable(saved) and saved.genre or nil
end

function GuideFlow:marginaliaGuideUI()
    if not self._marginalia_guide_ui then
        self._marginalia_guide_ui = require(plugin_path .. "marginalia_guideui")
    end
    return self._marginalia_guide_ui
end

local function bookInfo(self)
    local props = {}
    local doc = self.ui and self.ui.document
    if doc and doc.getProps then pcall(function() props = doc:getProps() or {} end) end
    return {
        title = props.title, author = props.authors or props.author, description = props.description,
    }
end

-- ---------------------------------------------------------------------------
-- Offering
-- ---------------------------------------------------------------------------

-- Offer the guide if this book has none yet. Called once the boundary is settled, so it
-- never lands on top of the first-open boundary question.
function GuideFlow:marginaliaGuideMaybeOffer()
    if self._marginalia_guide_busy or self._marginalia_guide_offered then return end
    local session = self.marginalia
    if not (session and session:isSettled()) then return end
    if not Guide.shouldOffer(self:marginaliaGuideLoad()) then return end
    self._marginalia_guide_offered = true
    local info = bookInfo(self)
    local ui = self:marginaliaGuideUI()
    ui.offer(info.title, {
        create = function() self:marginaliaGuideStart() end,
        later = function()
            -- keeps the offer for the next time; never overwrites a finished guide
            if not Guide.isUsable(self:marginaliaGuideLoad()) then self:marginaliaGuideSave(Guide.markState("later")) end
        end,
        never = function() self:marginaliaGuideSave(Guide.markState("never")) end,
    })
end

-- ---------------------------------------------------------------------------
-- Asking for it
-- ---------------------------------------------------------------------------

-- The first chapter's text, only as far as the spoiler gate allows. At the start of a
-- book the gate allows nothing, so this is nil and the guide uses the description.
function GuideFlow:marginaliaGuideOpeningText()
    local ok, text = pcall(function()
        local session, doc = self.marginalia, self.ui and self.ui.document
        if not (session and doc and session.deps and session.deps.get_toc) then return nil end
        local toc, total = session.deps.get_toc()
        if not (toc and total) then return nil end
        local first = (session.boundary and session.boundary.first_chapter) or 1
        local entry = toc[first]
        if not entry then return nil end
        local stop = toc[first + 1] and toc[first + 1].page or (total + 1)
        local analyzer = self.chapter_analyzer
        if not analyzer then
            local Analyzer = require(plugin_path .. "xray_chapteranalyzer")
            analyzer = Analyzer
        end
        return analyzer:getTextFromPageRange(self.ui, entry.page, stop, 6000)
    end)
    if ok and type(text) == "string" and text:match("%S") then return text end
    return nil
end

local function finish(self)
    self._marginalia_guide_busy = nil
end

-- Wait for an async request: calls on_result(data, code, msg) once, data being a table
-- (ok), false (failed) or nil only on timeout/close. Polls ai_helper:checkAsyncResult.
local function waitFor(self, file, pid, on_result)
    local helper = self.ai_helper
    local started = os.time()
    local function poll()
        if self.destroyed or not self.ui or not self.ui.document then return on_result(nil, "closed", "The book was closed.") end
        local data, code, msg = helper:checkAsyncResult(file, pid)
        if data == nil then
            if os.time() - started > TIMEOUT_SECONDS then return on_result(nil, "timeout", "The request took too long.") end
            uiManager():scheduleIn(POLL_SECONDS, poll)
            return
        end
        return on_result(data, code, msg)
    end
    uiManager():scheduleIn(POLL_SECONDS, poll)
end

local function tempFile(helper, tag)
    return (helper.path or ".") .. "/tmp_" .. tag .. "_" .. tostring(os.time()) .. ".json"
end

-- Shared with the chapter debrief (marginalia_debriefflow.lua), which asks the AI and
-- checks the answer in the same way.
function GuideFlow:marginaliaWaitFor(file, pid, on_result) return waitFor(self, file, pid, on_result) end
function GuideFlow:marginaliaTempFile(tag) return tempFile(self.ai_helper, tag) end

function GuideFlow:marginaliaGuideStart()
    if self._marginalia_guide_busy then return end
    local helper, ui = self.ai_helper, self:marginaliaGuideUI()
    if not helper then return end
    self._marginalia_guide_busy = true
    local info = bookInfo(self)
    local prompt = Guide.buildPrompt({
        title = info.title, author = info.author, description = info.description,
        opening_text = self:marginaliaGuideOpeningText(),
    })
    -- The usual spoiler rules say "use only the supplied text", which would stop the
    -- guide using what it knows about the author and the period. For this one request
    -- they are swapped for the guide's own rules (plot forbidden, background allowed),
    -- and put straight back.
    local Prompts = require(plugin_path .. "marginalia_prompts")
    local requests, code, msg
    local prompts = helper.prompts
    if type(prompts) ~= "table" and helper.loadLanguage then helper:loadLanguage(); prompts = helper.prompts end
    local usual = type(prompts) == "table" and prompts.system_instruction or nil
    if type(prompts) == "table" then prompts.system_instruction = Prompts.forGuideSystem(usual) end
    local ok, a, b, c = pcall(helper.buildComprehensiveRequest, helper, nil, nil, nil, prompt)
    if type(prompts) == "table" then prompts.system_instruction = usual end
    if ok then requests, code, msg = a, b, c else code, msg = "error_build", tostring(a) end
    if not requests then
        finish(self)
        return ui.info("The reading guide could not be started: " .. tostring(msg or code or "no AI is set up."))
    end
    local file = tempFile(helper, "guide")
    local pid, err_code, err_msg = helper:makeRequestAsync(requests, file)
    if not pid then
        finish(self)
        return ui.info("The reading guide could not be started: " .. tostring(err_msg or err_code or "unknown error"))
    end
    local working = ui.working("Writing your reading guide...")
    waitFor(self, file, pid, function(data, c, m)
        if data == nil or data == false then
            ui.closeWorking(working); finish(self)
            return ui.info("The reading guide failed: " .. tostring(m or c or "unknown error"))
        end
        local guide = Guide.parse(data)
        if not guide then
            ui.closeWorking(working); finish(self)
            return ui.info("The reading guide could not be read. Please try again.")
        end
        self:marginaliaGuideCheck(guide, function(outcome, detail)
            ui.closeWorking(working)
            self:marginaliaGuideAfterCheck(guide, outcome, detail)
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- The second-pass check
-- ---------------------------------------------------------------------------

local GUIDE_POSITION = "the very beginning of the book. The reader has read nothing yet, except possibly the first chapter. "
    .. "A statement is fine if it is about the author, the period, the style or general background, or about people met in the first chapter."

-- done("clean") | done("flagged", count) | done("unchecked", reason)
-- `position` says how far the reader has got (default: the very start, for the guide).
function GuideFlow:marginaliaGuideCheck(guide, done, position)
    local helper = self.ai_helper
    local items = SpoilerCheck.collectAll(guide)
    if #items == 0 then return done("clean") end
    local batches = SpoilerCheck.chunk(items)
    local info = bookInfo(self)
    local flagged_total, index = 0, 1

    local function nextBatch()
        if index > #batches then
            return done(flagged_total > 0 and "flagged" or "clean", flagged_total)
        end
        local batch = batches[index]
        local prompt = SpoilerCheck.buildPrompt(batch, {
            title = info.title, author = info.author, position = position or GUIDE_POSITION,
        })
        local requests, code, msg = SpoilerCheck.buildRequest(helper, prompt)
        if not requests then return done("unchecked", msg or code) end
        local file = tempFile(helper, "guidecheck")
        local pid, err_code, err_msg = helper:makeRequestAsync(requests, file)
        if not pid then return done("unchecked", err_msg or err_code or "could not start the check") end
        waitFor(self, file, pid, function(verdict, c, m)
            if verdict == nil or verdict == false then return done("unchecked", m or c) end
            local set = SpoilerCheck.parseVerdict(verdict, #batch)
            if not set then return done("unchecked", "The check gave an answer that could not be read.") end
            for _ in pairs(set) do flagged_total = flagged_total + 1 end
            index = index + 1
            nextBatch()
        end)
    end
    nextBatch()
end

-- Clean: save and show. Anything else: warn, and let the reader choose.
function GuideFlow:marginaliaGuideAfterCheck(guide, outcome, detail)
    local ui = self:marginaliaGuideUI()
    local function keep()
        guide.created_at = os.time()
        self:marginaliaGuideSave(guide)
        finish(self)
        self:marginaliaGuideShow()
    end
    if outcome == "clean" then return keep() end
    ui.warn(outcome, detail, {
        regenerate = function() finish(self); self:marginaliaGuideStart() end,
        show_anyway = keep,
        cancel = function() finish(self) end,
    })
end

-- ---------------------------------------------------------------------------
-- Showing it
-- ---------------------------------------------------------------------------

function GuideFlow:marginaliaGuideShow()
    local saved = self:marginaliaGuideLoad()
    local ui = self:marginaliaGuideUI()
    if not Guide.isUsable(saved) then
        -- nothing saved yet (or the reader once said "not for this book"): they asked
        -- for it from the menu, so make one
        return self:marginaliaGuideStart()
    end
    ui.show(Guide.format(saved), Guide.genreLabel(saved.genre), {
        regenerate = function() self:marginaliaGuideStart() end,
        change_genre = function()
            ui.pickGenre(Guide.GENRES, saved.genre, function(id)
                saved.genre = id
                saved.genre_confidence = "high" -- the reader has decided
                self:marginaliaGuideSave(saved)
                self:marginaliaGuideShow()
            end)
        end,
    })
end

-- The "Reading guide" entry for the Marginalia menu.
function GuideFlow:marginaliaGuideMenuItem()
    return {
        text_func = function()
            return Guide.isUsable(self:marginaliaGuideLoad()) and "Reading guide" or "Reading guide (not made yet)"
        end,
        keep_menu_open = true,
        callback = function() self:marginaliaGuideShow() end,
    }
end

return GuideFlow
