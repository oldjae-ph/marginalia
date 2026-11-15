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

function M:marginaliaOnReaderReady()
    if self.marginalia then return end
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

return M
