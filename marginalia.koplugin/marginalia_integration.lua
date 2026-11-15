-- marginalia_integration.lua
-- Mixin: connects marginalia_session.lua to the live reader. main.lua applies it
-- with safeRequireMixin() and calls three one-line hooks, so the upstream diff
-- stays tiny. The boundary is stored in the book's own sidecar settings under the
-- key "marginalia_boundary" (separate from xray's cache file and settings keys).

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local Context = require(plugin_path .. "marginalia_context")

local M = {}

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
    if stamp then data.marginalia_boundary = stamp end
end

-- May this saved data be used? Fails closed: no session, an unanswered first-open
-- question, or no table of contents all mean "no". Data from past the boundary is
-- set aside (renamed, never deleted) and treated as if there were no cache.
function M:marginaliaCheckCache(cm, data, book_path)
    local session = self.marginalia
    if not session or not session:isSettled() then return false end
    local limit, limit_page = session:getLimit(), session:getLimitPage()
    if not limit_page then return false end -- cannot judge: hide it, leave the file alone
    if not Context.isTainted(data, limit, limit_page) then return true end
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

-- The first-open question was answered: saved data can now be judged.
function M:marginaliaOnSettled()
    self:marginaliaReloadData()
end

-- The READER moved the boundary back: whatever was made under the old, further
-- boundary is now past it. Stop anything in flight, drop unsaved writes (they
-- would be stamped with the new boundary), and reload through the guard.
function M:marginaliaOnLowered()
    if self.cancelActiveAIRequest then
        pcall(self.cancelActiveAIRequest, self, "Boundary moved back")
    end
    local cm = self.cache_manager
    if cm and cm.cancelAsyncSaves then pcall(cm.cancelAsyncSaves, cm) end
    self:marginaliaReloadData()
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
        })
        self.marginalia = session
        session:start(self:getCurrentPage())
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

-- Upstream's "Spoiler Settings" only chooses between spoiler-free and "Full Book
-- Mode". Marginalia has no full-book mode (it is locked off), so the entry would
-- only mislead. Removed here, after upstream builds the menu, so upstream's own
-- code stays untouched. Matched by title, in English and in the plugin's language.
function M:marginaliaHideFullBookSetting(items)
    local ok, err = pcall(function()
        local titles = { ["Spoiler Settings"] = true }
        local localized = self.loc and self.loc.t and self.loc:t("spoiler_preference_title")
        if type(localized) == "string" and localized ~= "" then titles[localized] = true end
        removeEntries(items, titles)
    end)
    if not ok then self:log("Marginalia: could not hide the full-book setting: " .. tostring(err)) end
end

-- Add "Spoiler boundary" to the top of the X-Ray menu. Called from getSubMenuItems().
function M:marginaliaAddMenuItems(items)
    self:marginaliaHideFullBookSetting(items)
    local ok, err = pcall(function()
        local MenuBuilder = require(plugin_path .. "marginalia_menu")
        local Prompt = require(plugin_path .. "marginalia_prompt")
        table.insert(items, 1, MenuBuilder.topItem({
            get_session = function() return self.marginalia end,
            current_page = function() return self:getCurrentPage() end,
            ui = Prompt,
        }))
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
