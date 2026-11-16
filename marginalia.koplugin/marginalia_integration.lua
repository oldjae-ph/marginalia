-- marginalia_integration.lua
-- Mixin: connects marginalia_session.lua to the live reader. main.lua applies it
-- with safeRequireMixin() and calls three one-line hooks, so the upstream diff
-- stays tiny. The boundary is stored in the book's own sidecar settings under the
-- key "marginalia_boundary" (separate from xray's cache file and settings keys).

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local Context = require(plugin_path .. "marginalia_context")
local SpoilerCheck = require(plugin_path .. "marginalia_spoilercheck")

local M = {}

-- The reading guide's methods (marginalia_guideflow.lua) live on the plugin too.
for name, fn in pairs(require(plugin_path .. "marginalia_guideflow")) do M[name] = fn end
-- ... and the chapter debrief's (marginalia_debriefflow.lua)
for name, fn in pairs(require(plugin_path .. "marginalia_debriefflow")) do M[name] = fn end

-- Flat TOC as {page, title} sorted by page, entries without a page dropped.
-- Rebuilt whenever the page count changes (font size or margin changes repaginate).
local function buildTocGetter(self)
    local cache = { total = nil, toc = nil }
    return function()
        local doc = self.ui and self.ui.document
        if not doc or not doc.getPageCount then return nil end
        local total = doc:getPageCount()
        if not total then return nil end
        if cache.toc and cache.total == total then return cache.toc, total end

        local utils = require(plugin_path .. "xray_utils")
        local ok, raw = pcall(doc.getToc, doc)
        local list = {}
        if ok and type(raw) == "table" then
            for i, node in ipairs(utils:flattenTOC(raw)) do
                local page = type(node) == "table" and tonumber(node.page)
                if page then list[#list + 1] = { page = page, title = node.title or "", _i = #list + 1 } end
            end
        end
        table.sort(list, function(a, b)
            if a.page ~= b.page then return a.page < b.page end
            return a._i < b._i
        end)
        cache.toc, cache.total = list, total
        return list, total
    end
end

-- Install the spoiler gate FIRST, before anything that can fail: if the session
-- cannot start, the provider still answers 0 ("nothing allowed"), never "no limit".
function M:marginaliaInstallGate()
    local ok, ChapterAnalyzer = pcall(require, plugin_path .. "xray_chapteranalyzer")
    if not ok then
        self:log("Marginalia: could not install the spoiler gate: " .. tostring(ChapterAnalyzer))
        return
    end
    self._marginalia_gate = function()
        local session = self.marginalia
        local page = session and session:getLimitPage()
        return page or 0
    end
    ChapterAnalyzer.limit_provider = self._marginalia_gate
    self._marginalia_analyzer = ChapterAnalyzer

    -- Saved X-Ray data: stamp on every save, check on every load (see xray_cachemanager.lua)
    local ok_cm, CacheManager = pcall(require, plugin_path .. "xray_cachemanager")
    if ok_cm then
        self._marginalia_cache_guard = {
            stamp = function(data) self:marginaliaStampCache(data) end,
            check = function(cm, data, book_path) return self:marginaliaCheckCache(cm, data, book_path) end,
        }
        CacheManager.boundary_guard = self._marginalia_cache_guard
        self._marginalia_cache_class = CacheManager
    else
        self:log("Marginalia: could not install the cache guard: " .. tostring(CacheManager))
    end
end

-- Write the boundary this data was made under into the cache.
function M:marginaliaStampCache(data)
    local session = self.marginalia
    if type(data) ~= "table" or not session or not session:isSettled() then return end
    local stamp = Context.makeStamp(session:getLimit())
    if stamp then
        data.marginalia_boundary = stamp
        -- Everything in memory has passed the series-context check (see below), so
        -- from now on this data need not be cleaned again when it is loaded.
        data.marginalia_series_checked = true
    end
end

-- May this saved data be used? Fails closed: no session, an unanswered first-open
-- question, or no table of contents all mean "no". Data from past the boundary is
-- set aside (renamed, never deleted) and treated as if there were no cache.
function M:marginaliaCheckCache(cm, data, book_path)
    -- Another book's saved data (series features read the earlier books): the
    -- boundary here is for the book being read, so it cannot judge that data, and
    -- must never set that other book's file aside. What series context may take
    -- from it is decided separately (marginaliaTrustsSeriesBook).
    local doc = self.ui and self.ui.document
    if book_path and doc and doc.file and book_path ~= doc.file then return true end

    local session = self.marginalia
    if not session or not session:isSettled() then return false end
    local limit, limit_page = session:getLimit(), session:getLimitPage()
    if not limit_page then return false end -- cannot judge: hide it, leave the file alone
    if not Context.isTainted(data, limit, limit_page) then
        -- usable, but trim saved mention snippets that reach past the boundary
        local removed = Context.pruneMentions(data, limit_page)
        if removed > 0 then self:log("Marginalia: dropped " .. removed .. " saved mention(s) past your boundary") end
        -- Series context saved before this check existed may hold AI summaries or
        -- unchecked data from earlier books: remove it once; it is rebuilt from
        -- trusted entries when series context is next loaded.
        if not data.marginalia_series_checked and Context.hasSeriesContext(data) then
            local stripped = Context.stripSeriesContext(data)
            self:log("Marginalia: removed " .. stripped .. " unchecked series-context item(s); they will be rebuilt")
        end
        return true
    end
    self:log("Marginalia: saved X-Ray data reaches past your boundary; setting it aside")
    if cm and cm.quarantine then cm:quarantine(book_path) end
    return false
end

-- Forget everything X-Ray holds in memory for this book.
function M:marginaliaClearData()
    self.book_data = {}
    self.characters, self.locations, self.timeline = {}, {}, {}
    self.historical_figures, self.terms, self.images = {}, {}, {}
    self.chapters_fetched = {}
    self.terms_fetched = false
    self.series_context_loaded = false
    self.xray_mode_enabled = false
end

-- Drop memory and load again through the guard (so tainted data is set aside).
function M:marginaliaReloadData()
    self:marginaliaClearData()
    if self.autoLoadCache then
        local ok, err = pcall(self.autoLoadCache, self)
        if not ok then self:log("Marginalia: reloading saved data failed: " .. tostring(err)) end
    end
end

-- Offer the reading guide a moment after the page is up, never on top of another
-- question (it waits for the boundary to be settled).
function M:marginaliaGuideScheduleOffer()
    require("ui/uimanager"):scheduleIn(3, function()
        if self.destroyed or not self.ui or not self.ui.document then return end
        local ok, err = pcall(self.marginaliaGuideMaybeOffer, self)
        if not ok then self:log("Marginalia: could not offer the reading guide: " .. tostring(err)) end
    end)
end

-- The first-open question was answered: saved data can now be judged.
function M:marginaliaOnSettled()
    self:marginaliaReloadData()
    self:marginaliaGuideScheduleOffer()
end

-- The READER moved the boundary back: whatever was made under the old, further
-- boundary is now past it. Stop anything in flight, drop unsaved writes (they
-- would be stamped with the new boundary), and reload through the guard.
function M:marginaliaOnLowered()
    self:marginaliaTrimSeriesEntry()
    -- text waiting for its spoiler check was written for the old, further boundary
    for key in pairs(self._marginalia_check_state or {}) do self._marginalia_check_state[key] = nil end
    if self.cancelActiveAIRequest then
        pcall(self.cancelActiveAIRequest, self, "Boundary moved back")
    end
    local cm = self.cache_manager
    if cm and cm.cancelAsyncSaves then pcall(cm.cancelAsyncSaves, cm) end
    self:marginaliaReloadData()
end

-- Series context: which earlier-book entries may be copied into this book, and which
-- AI jobs may run for them.
--   trusted   made from the reader's own X-Ray data and stamped with how far they got
--   not       AI summaries from the model's memory (could reveal the whole earlier
--             book), roster stubs, unstamped data
function M:marginaliaTrustsSeriesBook(entry)
    return Context.isTrustedSeriesBook(entry)
end

-- fetchSeriesContext lists books to fetch from the AI's memory and books whose events
-- it will send to the AI to summarize. Nothing is fetched from memory, and only
-- trusted entries are summarized. Returns the two filtered lists.
function M:marginaliaFilterSeriesTasks(missing_books, summary_jobs)
    local kept = {}
    for _, job in ipairs(summary_jobs or {}) do
        if self:marginaliaTrustsSeriesBook(job.book) then kept[#kept + 1] = job end
    end
    if missing_books and #missing_books > 0 then
        self:log("Marginalia: not fetching " .. #missing_books .. " earlier book summary(ies) from the AI's memory")
    end
    return {}, kept
end

-- This book's own copy in the series file was made under a boundary that has now been
-- moved back: drop it, so later books cannot be given what was un-read. (The saved
-- X-Ray data itself is set aside, not deleted; this is only the derived copy.)
function M:marginaliaTrimSeriesEntry()
    local ok, err = pcall(function()
        local manager = self.series_manager
        local session = self.marginalia
        local doc = self.ui and self.ui.document
        local slug = self.book_data and self.book_data.series_slug
        if not (manager and session and doc and doc.file and slug) then return end
        local cache = manager:loadSeriesCache(slug)
        if not (cache and cache.books and cache.book_paths) then return end
        local limit, changed = session:getLimit(), false
        for index, path in pairs(cache.book_paths) do
            local entry = cache.books[index]
            if path == doc.file and entry and Context.compare(entry.marginalia_boundary, limit) == 1 then
                cache.books[index] = nil
                changed = true
            end
        end
        if changed then manager:saveSeriesCache(slug, cache) end
    end)
    if not ok then self:log("Marginalia: could not trim the series entry: " .. tostring(err)) end
end

-- "Full book" mode would tell the AI that nothing is off limits. Marginalia has no
-- such mode: force spoiler-free whenever settings are loaded or saved.
function M:marginaliaLockSpoilerMode()
    local helper = self.ai_helper
    if type(helper) ~= "table" then return end
    local function force(h)
        if type(h.settings) == "table" then h.settings.spoiler_setting = "spoiler_free" end
    end
    if not helper._marginalia_locked then
        helper._marginalia_locked = true
        local orig_save, orig_load = helper.saveSettings, helper.loadSettings
        if type(orig_save) == "function" then
            helper.saveSettings = function(h, new_settings, keys_to_delete)
                if type(new_settings) == "table" and new_settings.spoiler_setting ~= nil then
                    new_settings.spoiler_setting = "spoiler_free"
                end
                local result = orig_save(h, new_settings, keys_to_delete)
                force(h)
                return result
            end
        end
        if type(orig_load) == "function" then
            helper.loadSettings = function(h, ...)
                local result = orig_load(h, ...)
                force(h)
                return result
            end
        end
    end
    force(helper)
end

-- Second-pass spoiler check (marginalia_spoilercheck.lua). Every fetch polls
-- ai_helper:checkAsyncResult() until its result is ready, so that is where the
-- check goes: when the AI's text arrives it is NOT returned; a small model reads it
-- first (the caller just sees "not ready yet" and keeps polling), anything flagged
-- is replaced, and only then does the caller get the data. If the check cannot run
-- the caller gets a failure and the text is never shown (fails closed).
local function failCheck(pending, result_file, reason)
    pending[result_file] = nil
    return false, "error_spoiler_check", reason
end

function M:marginaliaSpoilerPosition()
    local session = self.marginalia
    if not (session and session:isSettled()) then return nil end
    local d = session:describe()
    if not d then return nil end
    local parts = {}
    if d.title then
        parts[#parts + 1] = string.format('the point %d%% of the way through the chapter "%s"', d.percent or 0, d.title)
    else
        parts[#parts + 1] = "the very start of the book (nothing yet)"
    end
    local doc = self.ui and self.ui.document
    local page, total = session:getLimitPage(), doc and doc.getPageCount and doc:getPageCount()
    if page and total and total > 0 then
        parts[#parts + 1] = string.format("about %d%% of the whole book", math.floor(page / total * 100))
    end
    return table.concat(parts, ", ")
end

function M:marginaliaStartCheckBatch(helper, state, result_file)
    local pending = self._marginalia_check_state
    local position = self:marginaliaSpoilerPosition()
    if not position then return failCheck(pending, result_file, "Your spoiler boundary is not set, so the new text cannot be checked.") end
    local doc = self.ui and self.ui.document
    local props = {}
    if doc and doc.getProps then pcall(function() props = doc:getProps() or {} end) end
    local prompt = SpoilerCheck.buildPrompt(state.batches[state.cur], {
        title = props.title, author = props.authors or props.author, position = position,
    })
    local requests, code, msg = SpoilerCheck.buildRequest(helper, prompt)
    if not requests then return failCheck(pending, result_file, msg or code) end
    local check_file = result_file .. ".check"
    local pid, err_code, err_msg = helper:makeRequestAsync(requests, check_file)
    if not pid then return failCheck(pending, result_file, err_msg or err_code or "could not start the spoiler check") end
    state.check_file, state.check_pid = check_file, pid
    return nil -- not ready: the caller keeps polling
end

function M:marginaliaInstallSpoilerCheck()
    local helper = self.ai_helper
    if type(helper) ~= "table" or helper._marginalia_checked then return end
    local orig = helper.checkAsyncResult
    if type(orig) ~= "function" then return end
    helper._marginalia_checked = true
    local plugin = self
    local pending = {}
    self._marginalia_check_state = pending

    helper.checkAsyncResult = function(h, result_file, expected_pid, ...)
        local state = pending[result_file]
        if state then
            -- the text has arrived; waiting for the checker's verdict on it
            local verdict, code, msg = orig(h, state.check_file, state.check_pid)
            if verdict == nil then return nil end
            if verdict == false then return failCheck(pending, result_file, msg or code) end
            local batch = state.batches[state.cur]
            local flagged = SpoilerCheck.parseVerdict(verdict, #batch)
            if not flagged then return failCheck(pending, result_file, "The spoiler check gave an answer that could not be read.") end
            local replaced = SpoilerCheck.apply(batch, flagged)
            if replaced > 0 then plugin:log("Marginalia: spoiler check withheld " .. replaced .. " statement(s)") end
            state.cur = state.cur + 1
            if state.cur > #state.batches then
                pending[result_file] = nil
                return state.data
            end
            return plugin:marginaliaStartCheckBatch(h, state, result_file)
        end

        local data, code, msg = orig(h, result_file, expected_pid, ...)
        if type(data) ~= "table" then return data, code, msg end
        local items = SpoilerCheck.collect(data)
        if #items == 0 then return data end -- nothing story-related to check
        state = { data = data, batches = SpoilerCheck.chunk(items), cur = 1 }
        pending[result_file] = state
        return plugin:marginaliaStartCheckBatch(h, state, result_file)
    end
end

-- The last page the reader may see or send (0 = nothing).
function M:marginaliaLimitPage()
    return self._marginalia_gate and self._marginalia_gate() or nil
end

-- A page, held back to the boundary: where upstream code says "the reader is on
-- page N" it must not mean a page past what has been confirmed. Never below 1, so
-- upstream arithmetic stays safe even when the limit is 0 (the gate then yields
-- no text anyway). Without a gate (nothing installed) the page is unchanged.
function M:marginaliaClampPage(page)
    page = tonumber(page)
    local limit = self:marginaliaLimitPage()
    if not page or not limit then return page end
    return math.max(1, math.min(page, limit))
end

function M:marginaliaOnReaderReady()
    if self.marginalia then return end
    self:marginaliaInstallGate()
    self:marginaliaLockSpoilerMode()
    self:marginaliaInstallSpoilerCheck()
    self:marginaliaDisablePrefetch()
    self:marginaliaDisableUpdates()
    local ok, err = pcall(function()
        local Session = require(plugin_path .. "marginalia_session")
        local Prompt = require(plugin_path .. "marginalia_prompt")
        local ui = self.ui
        local book_title
        pcall(function() book_title = ui.document:getProps().title end)

        local session = Session:new({
            get_toc = buildTocGetter(self),
            store = {
                load = function()
                    return ui.doc_settings and ui.doc_settings:readSetting("marginalia_boundary") or nil
                end,
                save = function(t, flush)
                    if not ui.doc_settings then return end
                    ui.doc_settings:saveSetting("marginalia_boundary", t)
                    if flush then ui.doc_settings:flush() end
                end,
            },
            prompter = Prompt,
            book_title = book_title,
            is_nonnarrative = function(title) return self:isNonNarrativeChapter(title) end,
            log = function(msg) self:log(msg) end,
            on_settled = function() self:marginaliaOnSettled() end,
            on_lowered = function() self:marginaliaOnLowered() end,
            on_debrief = function(index) self:marginaliaDebriefAfterFinish(index) end,
        })
        self.marginalia = session
        session:start(self:getCurrentPage())
        -- already settled (book opened at its start, or answered before): offer now
        if session:isSettled() then self:marginaliaGuideScheduleOffer() end
    end)
    if not ok then
        self.marginalia = nil
        self:log("Marginalia: could not start boundary tracking: " .. tostring(err))
    end
end

-- Returns nothing. Errors are logged, never raised into the reader.
function M:marginaliaOnPageUpdate(pageno)
    if not self.marginalia then return end
    local ok, err = pcall(self.marginalia.onPageUpdate, self.marginalia, pageno)
    if not ok then self:log("Marginalia: page update failed: " .. tostring(err)) end
end

-- Remove every entry with one of these titles, at any depth of static submenus.
local function removeEntries(items, titles)
    for i = #items, 1, -1 do
        local item = items[i]
        if type(item) == "table" then
            if item.text and titles[item.text] then
                table.remove(items, i)
            elseif type(item.sub_item_table) == "table" then
                removeEntries(item.sub_item_table, titles)
            end
        end
    end
end

-- Settings that Marginalia switches off, so showing them would only mislead:
--   "Spoiler Settings"  chooses between spoiler-free and "Full Book Mode" (locked off)
--   "Prefetch Horizon"  fetches X-Ray data for chapters AHEAD of the reader (disabled)
--   "Beta Channel Settings", "Check for Updates"  the self-updater is off (xray_updater.lua)
-- Removed here, after upstream builds the menu, so upstream's own code stays
-- untouched. Matched by title, in English and in the plugin's language.
local HIDDEN_SETTINGS = {
    { key = "spoiler_preference_title", english = "Spoiler Settings" },
    { key = "menu_prefetch_horizon", english = "Prefetch Horizon (Offline Readers)" },
    { key = "menu_beta_channel", english = "Beta Channel Settings" },
    { key = "updater_check", english = "Check for Updates" },
}

function M:marginaliaHideMisleadingSettings(items)
    local ok, err = pcall(function()
        local titles = {}
        for _, setting in ipairs(HIDDEN_SETTINGS) do
            titles[setting.english] = true
            local localized = self.loc and self.loc.t and self.loc:t(setting.key)
            if type(localized) == "string" and localized ~= "" then titles[localized] = true end
        end
        removeEntries(items, titles)
    end)
    if not ok then self:log("Marginalia: could not hide settings: " .. tostring(err)) end
end

-- Prefetching "upcoming chapters" has no place in a spoiler-safe plugin. The text
-- gate already blanks those chapters (so nothing is sent), but the scan still marks
-- them as fetched, so X-Ray would skip them for good once the reader arrives. It
-- also runs on every network reconnect, a path the page-turn hook does not cover.
-- Shadow the method on this plugin object; upstream's definition is untouched.
function M:marginaliaDisablePrefetch()
    self.checkPrefetchHorizon = function() end
end

-- The self-updater downloads upstream's release and unzips it over this plugin, so it
-- is off (xray_updater.lua refuses to run). Stop the weekly background check from
-- even starting; its menu entries are hidden above and the About button is not drawn.
function M:marginaliaDisableUpdates()
    self.checkWeeklyUpdate = function() end
end

-- Add "Spoiler boundary" to the top of the X-Ray menu. Called from getSubMenuItems().
function M:marginaliaAddMenuItems(items)
    self:marginaliaHideMisleadingSettings(items)
    local ok, err = pcall(function()
        local MenuBuilder = require(plugin_path .. "marginalia_menu")
        local Prompt = require(plugin_path .. "marginalia_prompt")
        table.insert(items, 1, MenuBuilder.topItem({
            get_session = function() return self.marginalia end,
            current_page = function() return self:getCurrentPage() end,
            ui = Prompt,
        }))
        local guide_item = self:marginaliaGuideMenuItem()
        guide_item.text = "Reading guide"
        table.insert(items, 2, guide_item)
        for i, item in ipairs(self:marginaliaDebriefMenuItems()) do table.insert(items, 2 + i, item) end
    end)
    if not ok then self:log("Marginalia: could not add the boundary menu: " .. tostring(err)) end
end

function M:marginaliaFlush()
    if not self.marginalia then return end
    pcall(self.marginalia.flush, self.marginalia)
end

-- Reader closed: save, and take the gate down only if it is still ours (a newly
-- opened book installs its own).
function M:marginaliaOnDestroy()
    self:marginaliaFlush()
    local analyzer = self._marginalia_analyzer
    if analyzer and analyzer.limit_provider == self._marginalia_gate then
        analyzer.limit_provider = nil
    end
    local cm_class = self._marginalia_cache_class
    if cm_class and cm_class.boundary_guard == self._marginalia_cache_guard then
        cm_class.boundary_guard = nil
    end
end

return M
