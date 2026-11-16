-- marginalia_debriefflow.lua
-- The chapter debrief, end to end. Methods that marginalia_integration.lua adds to the
-- plugin: pick the chapter text (only as far as the spoiler gate allows), gather the
-- records of earlier chapters, ask the AI in the background, check the answer a second
-- time, save the debrief and the chapter record, show it. Screens are in
-- marginalia_debriefui.lua (replaceable: the specs use a fake one).
--
-- Spoiler rules specific to the debrief:
--   * a chapter AFTER the boundary is refused, and its text could not be fetched anyway
--     (the gate); a chapter that is still being read is debriefed as far as read, and
--     its record is NOT saved (a half-chapter record would mislead later requests)
--   * earlier chapters enter the request only as records, and only records of chapters
--     up to the CURRENT boundary
--   * the answer is checked a second time; flagged or unchecked is a warning with
--     [Write again] / [Show anyway], never a silent swap
--   * the record is saved only when the debrief is shown, so memory never holds an
--     answer the reader was warned about and turned away

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local Debrief = require(plugin_path .. "marginalia_debrief")
local Records = require(plugin_path .. "marginalia_records")
local Guide = require(plugin_path .. "marginalia_guide")

local DebriefFlow = {}

local DEBRIEFS, RECORDS = "marginalia_debriefs", "marginalia_records"

local function store(self, key)
    local ds = self.ui and self.ui.doc_settings
    if not ds then return nil end
    local v = ds:readSetting(key)
    return type(v) == "table" and v or nil
end

local function save(self, key, value)
    local ds = self.ui and self.ui.doc_settings
    if not ds then return end
    ds:saveSetting(key, value)
    ds:flush()
end

function DebriefFlow:marginaliaDebriefUI()
    if not self._marginalia_debrief_ui then
        self._marginalia_debrief_ui = require(plugin_path .. "marginalia_debriefui")
    end
    return self._marginalia_debrief_ui
end

-- "full" (all sections) or "quick" (in brief + why it matters). Per reader, in settings.
function DebriefFlow:marginaliaDebriefDepth()
    local s = self.ai_helper and self.ai_helper.settings
    return (s and s.marginalia_debrief_depth == "quick") and "quick" or "full"
end

function DebriefFlow:marginaliaDebriefToggleDepth()
    local now = self:marginaliaDebriefDepth()
    local nxt = now == "quick" and "full" or "quick"
    if self.ai_helper and self.ai_helper.saveSettings then self.ai_helper:saveSettings({ marginalia_debrief_depth = nxt }) end
    if self.ai_helper and self.ai_helper.settings then self.ai_helper.settings.marginalia_debrief_depth = nxt end
    return nxt
end

local function chapterInfo(self, index)
    local session = self.marginalia
    if not (session and session:isSettled() and session.deps and session.deps.get_toc) then return nil end
    local toc, total = session.deps.get_toc()
    local entry = toc and toc[index]
    if not entry then return nil end
    local stop = toc[index + 1] and toc[index + 1].page or ((total or entry.page) + 1)
    local title = tostring(entry.title or ""):match("^%s*(.-)%s*$")
    if title == "" then title = "Chapter " .. index end
    return { title = title, start = entry.page, stop = stop }
end

-- Is this chapter wholly inside the boundary (finished), partly (being read), or
-- beyond it?  "done" | "partial" | "beyond"
local function chapterState(self, index)
    local limit = self.marginalia:getLimit()
    if index > limit.chapter then return "beyond" end
    if index == limit.chapter and limit.frac < 0.999 then return "partial" end
    return "done"
end

-- ---------------------------------------------------------------------------
-- Starting one
-- ---------------------------------------------------------------------------

function DebriefFlow:marginaliaDebriefStart(index)
    if self._marginalia_debrief_busy then return end
    local ui, helper = self:marginaliaDebriefUI(), self.ai_helper
    local session = self.marginalia
    if not (helper and session and session:isSettled()) then
        return ui.info("Your spoiler boundary is not set yet, so there is nothing to debrief.")
    end
    local info = chapterInfo(self, index)
    if not info then return ui.info("That chapter could not be found in the table of contents.") end
    local state = chapterState(self, index)
    if state == "beyond" then
        return ui.info("That chapter is beyond your spoiler boundary. Finish it first.")
    end

    -- the chapter text: only what the gate lets through (all of it, for a finished chapter)
    local analyzer = self.chapter_analyzer or require(plugin_path .. "xray_chapteranalyzer")
    local ok, chapter_text = pcall(function()
        return analyzer:getTextFromPageRange(self.ui, info.start, info.stop, Debrief.MAX_CHAPTER_CHARS)
    end)
    if not ok or type(chapter_text) ~= "string" or not chapter_text:match("%S") then
        return ui.info("There is no text of this chapter to debrief yet.")
    end

    self._marginalia_debrief_busy = true
    local book = {}
    pcall(function() book = self.ui.document:getProps() or {} end)
    local depth = self:marginaliaDebriefDepth()
    local genre = self:marginaliaGuideGenre()
    local records = Records.upTo(store(self, RECORDS), session:getLimit().chapter, index)
    local prompt = Debrief.buildPrompt({
        title = book.title, author = book.authors or book.author, chapter_title = info.title,
        genre = genre, depth = depth, records = records, chapter_text = chapter_text,
    })
    local Prompts = require(plugin_path .. "marginalia_prompts")
    prompt = Prompts.forPrompt(prompt)

    local requests, code, msg = helper:buildComprehensiveRequest(nil, nil, nil, prompt)
    local function release() self._marginalia_debrief_busy = nil end
    if not requests then
        release()
        return ui.info("The debrief could not be started: " .. tostring(msg or code or "no AI is set up."))
    end
    local file = self:marginaliaTempFile("debrief")
    local pid, err_code, err_msg = helper:makeRequestAsync(requests, file)
    if not pid then
        release()
        return ui.info("The debrief could not be started: " .. tostring(err_msg or err_code or "unknown error"))
    end
    local working = ui.working("Writing the debrief of " .. info.title .. "...")
    self:marginaliaWaitFor(file, pid, function(data, c, m)
        if data == nil or data == false then
            ui.closeWorking(working); release()
            return ui.info("The debrief failed: " .. tostring(m or c or "unknown error"))
        end
        local debrief = Debrief.parse(data, { chapter_text = chapter_text, chapter_title = info.title, depth = depth })
        if not debrief then
            ui.closeWorking(working); release()
            return ui.info("The debrief could not be read. Please try again.")
        end
        debrief.genre = genre
        debrief.partial = state == "partial" or nil
        local position = self:marginaliaSpoilerPosition()
        if not position then
            ui.closeWorking(working); release()
            return ui.info("Your spoiler boundary is not set, so the debrief cannot be checked.")
        end
        -- the check reads every statement, the record included
        self:marginaliaGuideCheck(debrief, function(outcome, detail)
            ui.closeWorking(working)
            self:marginaliaDebriefAfterCheck(index, info, debrief, outcome, detail)
        end, position)
    end)
end

-- ---------------------------------------------------------------------------
-- After the check
-- ---------------------------------------------------------------------------

function DebriefFlow:marginaliaDebriefKeep(index, info, debrief)
    local debriefs = store(self, DEBRIEFS) or {}
    debrief.created_at = os.time()
    local record = debrief.record
    debrief.record = nil -- the record lives in its own place, not in the display copy
    debriefs[index] = debrief
    save(self, DEBRIEFS, debriefs)
    -- A half-read chapter leaves no record: later requests would take it for the whole.
    if record and not debrief.partial then
        save(self, RECORDS, Records.put(store(self, RECORDS), index, record))
    end
    self._marginalia_debrief_busy = nil
    self:marginaliaDebriefShow(index)
end

function DebriefFlow:marginaliaDebriefAfterCheck(index, info, debrief, outcome, detail)
    if outcome == "clean" then return self:marginaliaDebriefKeep(index, info, debrief) end
    self:marginaliaDebriefUI().warn(outcome, detail, {
        regenerate = function() self._marginalia_debrief_busy = nil; self:marginaliaDebriefStart(index) end,
        show_anyway = function() self:marginaliaDebriefKeep(index, info, debrief) end,
        cancel = function() self._marginalia_debrief_busy = nil end,
    })
end

-- ---------------------------------------------------------------------------
-- Showing and picking
-- ---------------------------------------------------------------------------

function DebriefFlow:marginaliaDebriefShow(index)
    local saved = (store(self, DEBRIEFS) or {})[index]
    local info = chapterInfo(self, index)
    if not (info and Debrief.isUsable(saved)) then return self:marginaliaDebriefStart(index) end
    -- a saved debrief of a chapter past the boundary (the boundary was moved back) stays hidden
    if chapterState(self, index) == "beyond" then
        return self:marginaliaDebriefUI().info("That chapter is beyond your spoiler boundary.")
    end
    self:marginaliaDebriefUI().show(info.title, Debrief.format(saved, info.title, saved.partial), {
        write_again = function() self:marginaliaDebriefStart(index) end,
    })
end

-- "Debrief chapter": chapters up to the boundary, saved ones marked.
function DebriefFlow:marginaliaDebriefPick()
    local session, ui = self.marginalia, self:marginaliaDebriefUI()
    if not (session and session:isSettled()) then return ui.info("Your spoiler boundary is not set yet.") end
    local limit = session:getLimit()
    local debriefs = store(self, DEBRIEFS) or {}
    local choices = {}
    for _, choice in ipairs(session:chapterChoices()) do
        if choice.index <= limit.chapter then
            local copy = { index = choice.index, title = choice.title, is_current = choice.is_current }
            if Debrief.isUsable(debriefs[choice.index]) then copy.title = copy.title .. "   (debriefed)" end
            choices[#choices + 1] = copy
        end
    end
    if #choices == 0 then return ui.info("You have not read any chapter yet.") end
    ui.pickChapter("Debrief which chapter?", choices, function(choice) self:marginaliaDebriefShow(choice.index) end)
end

-- Entries for the X-Ray menu.
function DebriefFlow:marginaliaDebriefMenuItems()
    return {
        {
            text = "Debrief chapter",
            text_func = function()
                local n = Records.count(store(self, DEBRIEFS))
                return n > 0 and string.format("Debrief chapter (%d saved)", n) or "Debrief chapter"
            end,
            keep_menu_open = true,
            callback = function() self:marginaliaDebriefPick() end,
        },
        {
            text = "Debrief depth",
            text_func = function()
                return "Debrief depth: " .. (self:marginaliaDebriefDepth() == "quick" and "Quick" or "Full")
            end,
            keep_menu_open = true,
            callback = function(menu)
                self:marginaliaDebriefToggleDepth()
                if menu and menu.updateItems then menu:updateItems() end
            end,
        },
    }
end

-- The finished chapter's debrief, from the chapter-end question.
function DebriefFlow:marginaliaDebriefAfterFinish(index)
    if type(index) ~= "number" then return end
    require("ui/uimanager"):scheduleIn(1, function()
        if self.destroyed or not self.ui or not self.ui.document then return end
        local ok, err = pcall(self.marginaliaDebriefStart, self, index)
        if not ok then self:log("Marginalia: could not start the debrief: " .. tostring(err)) end
    end)
end

return DebriefFlow
