-- marginalia_integration.lua
-- Mixin: connects marginalia_session.lua to the live reader. main.lua applies it
-- with safeRequireMixin() and calls three one-line hooks, so the upstream diff
-- stays tiny. The boundary is stored in the book's own sidecar settings under the
-- key "marginalia_boundary" (separate from xray's cache file and settings keys).

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""

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
end

return M
