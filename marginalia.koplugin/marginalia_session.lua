-- marginalia_session.lua
-- Glue between the reader's page events and the spoiler boundary. Pure logic:
-- everything KOReader-specific (TOC, saved settings, dialogs) is injected, so this
-- is unit-tested without the UI. See marginalia_integration.lua for the real wiring.
--
-- deps = {
--   get_toc     = function() return flat_toc, total_pages end   -- toc: array of {page, title}
--   store       = { load = function() return table|nil end,
--                   save = function(table, flush) end }
--   prompter    = { askFinished = function(finished_title, on_yes, on_not_yet) end,
--                   askInitial  = function(on_here, on_start) end }
--   book_title  = string|nil,
--   is_nonnarrative = function(title) -> boolean   -- xray's front/back matter test
--   log         = function(msg)                    -- optional, never pass book text
-- }

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local Boundary = require(plugin_path .. "marginalia_boundary")
local Position = require(plugin_path .. "marginalia_position")
local Limit = require(plugin_path .. "marginalia_limit")

local Session = {}
Session.__index = Session

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- A TOC entry that carries no story text of its own: front/back matter, the book
-- title, or a bare part/book heading ("PART I", "Book Two:"). Conservative on
-- purpose: a real chapter titled "Part of the Plan" must not match.
function Session.isSkippableTitle(title, book_title, is_nonnarrative)
    if is_nonnarrative and is_nonnarrative(title) then return true end
    local t = trim(title):lower()
    if t == "" then return true end
    local bt = trim(book_title):lower()
    if bt ~= "" and t == bt then return true end
    for _, word in ipairs({ "part", "book", "volume" }) do
        if t:match("^" .. word .. "%s+[%w]+%.?$") or t:match("^" .. word .. "%s+[%w]+%s*[:%.%-]") then
            return true
        end
    end
    return false
end

function Session:new(deps)
    local o = setmetatable({ deps = deps, boundary = nil, prompt_open = false, declined = nil }, self)
    return o
end

function Session:_log(msg)
    if self.deps.log then self.deps.log("Marginalia: " .. msg) end
end

function Session:_isSkippableIndex(idx)
    local toc = self.toc
    local entry = toc and toc[idx]
    if not entry then return false end
    return Session.isSkippableTitle(entry.title, self.deps.book_title, self.deps.is_nonnarrative)
end

function Session:_persist(flush)
    if not self.boundary then return end
    local ok, err = pcall(self.deps.store.save, self.boundary:toTable(), flush)
    if not ok then self:_log("could not save boundary: " .. tostring(err)) end
end

function Session:_firstStoryIndex()
    for i = 1, #(self.toc or {}) do
        if not self:_isSkippableIndex(i) then return i end
    end
    return 1
end

-- Title of the chapter the reader is being asked about: the last real chapter at
-- or before the confirmed boundary (headings in between do not count).
function Session:_finishedTitle()
    local confirmed = self.boundary:getConfirmedChapter()
    for i = confirmed, 1, -1 do
        if not self:_isSkippableIndex(i) then
            local e = self.toc and self.toc[i]
            return e and trim(e.title) ~= "" and trim(e.title) or nil
        end
    end
    return nil
end

function Session:_newBoundary()
    return Boundary:new({
        is_skippable = function(idx) return self:_isSkippableIndex(idx) end,
    })
end

-- Load saved state. First open (or unreadable state) asks the reader where they
-- are, unless they are still at the very start of the story.
function Session:start(current_page)
    local toc, total = self.deps.get_toc()
    self.toc = toc
    local saved = self.deps.store.load()
    local b, ok = Boundary.fromTable(saved, {
        is_skippable = function(idx) return self:_isSkippableIndex(idx) end,
    })
    self.boundary = b
    if saved ~= nil and ok then
        self:_log("boundary restored at chapter " .. tostring(b:getConfirmedChapter()))
        return
    end
    if saved ~= nil then self:_log("saved boundary unreadable, starting from the beginning") end

    local pos, step = Position.fromPage(toc, current_page, total)
    if not pos then
        self:_log("no table of contents, boundary stays at the start")
        return
    end
    local first_story = self:_firstStoryIndex()
    local at_start = pos.chapter < first_story
        or (pos.chapter == first_story and pos.frac <= 3 * step + 1e-9)
    if at_start then
        self:_persist(true)
        return
    end
    self.prompt_open = true
    self.deps.prompter.askInitial(
        function() -- "I've read up to here"
            self.prompt_open = false
            self.boundary:setByReader(pos.chapter, pos.frac)
            self:_persist(true)
        end,
        function() -- "Start of the book"
            self.prompt_open = false
            self:_persist(true)
        end)
end

-- Called on every page turn. Returns nothing; never raises into the reader.
function Session:onPageUpdate(page)
    if not self.boundary then return end
    local toc, total = self.deps.get_toc()
    self.toc = toc
    local pos, step = Position.fromPage(toc, page, total)
    if not pos then return end

    local r = self.boundary:update(pos, step)
    if r.auto_confirmed then
        self:_persist(true)
    elseif r.moved or r.pending then
        self:_persist(false)
    end

    -- Coming back to the confirmed chapter or earlier re-arms the prompt.
    if pos.chapter <= self.boundary:getConfirmedChapter() then self.declined = nil end

    if r.pending and not self.prompt_open and self.declined ~= r.pending then
        self:_askFinished(r.pending)
    end
end

function Session:_askFinished(chapter)
    self.prompt_open = true
    self.deps.prompter.askFinished(self:_finishedTitle(),
        function() -- yes
            self.prompt_open = false
            if self.boundary:confirm(chapter) then
                self:_persist(true)
                self:_log("reader confirmed chapter " .. tostring(chapter))
            end
        end,
        function() -- not yet
            self.prompt_open = false
            self.declined = chapter
        end)
end

-- Reader-initiated changes. Never call these from automatic code paths.
function Session:setBoundaryAtPage(page)
    if not self.boundary then return false end
    local toc, total = self.deps.get_toc()
    self.toc = toc
    local pos = Position.fromPage(toc, page, total)
    if not pos or not self.boundary:setByReader(pos.chapter, pos.frac) then return false end
    self:_persist(true)
    return true
end

function Session:rollBackToPage(page)
    if not self.boundary then return false end
    local toc, total = self.deps.get_toc()
    self.toc = toc
    local pos = Position.fromPage(toc, page, total)
    if not pos or not self.boundary:rollBack(pos.chapter, pos.frac) then return false end
    self:_persist(true)
    return true
end

function Session:getLimit()
    return self.boundary and self.boundary:getLimit() or nil
end

-- Last page the reader may see or send, or nil when it cannot be worked out
-- (no session, no TOC). Callers treat nil as "nothing allowed".
function Session:getLimitPage()
    if not self.boundary then return nil end
    local toc, total = self.deps.get_toc()
    return Limit.lastAllowedPage(toc, self.boundary:getLimit(), total)
end

function Session:flush()
    self:_persist(true)
end

return Session
