-- marginalia_boundary.lua
-- Spoiler boundary manager. Pure logic: no UI, no KOReader modules, no I/O.
--
-- The boundary is the furthest point the READER has confirmed they have read.
-- Nothing past it may enter a request, be shown, or be stored as memory.
--
-- Positions are { chapter = <TOC index, integer>, frac = <0..1> } where frac is
-- how far through the chapter the END of the visible text is. Fractions (not page
-- numbers) so a font-size change cannot move the boundary.
--
-- Rules (these are the product; do not weaken):
--   * Only sequential reading moves the auto position, and only inside the
--     confirmed chapter. A position is "sequential" when it sits at most one
--     page-turn (`step`) beyond the current auto position. Jumps (TOC, endnotes,
--     flipping ahead) are therefore ignored without needing to detect them.
--   * Crossing into the next chapter never moves the confirmed boundary. It
--     only sets `pending_chapter` so the UI can ask "Finished chapter X?".
--   * Only the reader moves the confirmed boundary: confirm(), setByReader(),
--     rollBack(). update() never changes confirmed_chapter, with one exception:
--     chapters the caller marks skippable (front matter, part headings) carry no
--     story text and are passed through.
--   * Corrupt saved state falls back to the most restrictive boundary.

local Boundary = {}
Boundary.__index = Boundary

local EPS = 1e-9
local END_TOL = 1e-6
local STATE_VERSION = 1

local function isNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function isChapter(v)
    return isNumber(v) and v >= 1 and v == math.floor(v)
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Largest forward move (as a fraction of the chapter) that still counts as one
-- page turn. Callers pass ~1/pages_in_chapter. Bad input falls back to a small
-- value: a too-small step only makes the boundary more conservative.
local function cleanStep(step)
    if not isNumber(step) or step <= 0 then return 0.02 end
    return clamp(step, 0.001, 1)
end

function Boundary:new(opts)
    opts = opts or {}
    local first = isChapter(opts.first_chapter) and opts.first_chapter or 1
    return setmetatable({
        first_chapter = first,
        confirmed_chapter = first,
        auto_frac = 0,
        auto_step = 0.02,
        pending_chapter = nil,
        pending_frac = 0,
        pending_step = 0.02,
        is_skippable = type(opts.is_skippable) == "function" and opts.is_skippable or nil,
    }, self)
end

-- True when the auto position is within one page-turn of the end of the
-- confirmed chapter, i.e. the reader has read (almost) all of it in order.
function Boundary:_atChapterEnd()
    return (1 - self.auto_frac) <= self.auto_step + EPS
end

-- Feed the reader's current position. Returns a table:
--   moved          = true when the auto position advanced
--   pending        = chapter number to ask "Finished chapter <previous>?" about
--   auto_confirmed = true when a skippable chapter was passed through
-- It never raises and never moves confirmed_chapter past a non-skippable chapter.
function Boundary:update(pos, step)
    local result = {}
    if type(pos) ~= "table" or not isChapter(pos.chapter) or not isNumber(pos.frac) then
        result.ignored = true
        return result
    end
    local c = pos.chapter
    local frac = clamp(pos.frac, 0, 1)
    step = cleanStep(step)

    if c == self.confirmed_chapter then
        local d = frac - self.auto_frac
        if d > EPS and d <= step + EPS then
            self.auto_frac = frac
            self.auto_step = step
            result.moved = true
        end
        return result
    end

    if c < self.confirmed_chapter then
        return result -- re-reading earlier material: no effect
    end

    -- c is ahead of the confirmed chapter. Slide over skippable chapters only
    -- when the reader really is at the end of the confirmed chapter.
    local target = self.confirmed_chapter + 1
    if c > target and self.is_skippable and self:_atChapterEnd() then
        local all_skippable = true
        for k = target, c - 1 do
            if not self.is_skippable(k) then all_skippable = false; break end
        end
        if all_skippable then
            self.confirmed_chapter = c - 1
            self.auto_frac = 1
            self.pending_chapter = nil
            self.pending_frac = 0
            target = c
        end
    end

    if c ~= target then
        return result -- a jump: ignored
    end

    if self.pending_chapter == c then
        local d = frac - self.pending_frac
        if d > EPS and d <= step + EPS then
            self.pending_frac = frac
            self.pending_step = step
            result.moved = true
        end
        result.pending = c
    elseif self:_atChapterEnd() and frac <= step + EPS then
        self.auto_frac = 1
        self.pending_chapter = c
        self.pending_frac = frac
        self.pending_step = step
        result.pending = c
    else
        return result -- a jump into the next chapter: ignored
    end

    -- Nothing to ask when no story text has been passed: entering a skippable
    -- chapter, or the first story chapter after front matter only.
    if self.is_skippable and (self.is_skippable(c) or not self:_storyStarted()) then
        self:confirm(c)
        result.pending = nil
        result.auto_confirmed = true
    end
    return result
end

-- Has the reader confirmed any chapter that carries story text?
function Boundary:_storyStarted()
    if not self.is_skippable then return true end
    for k = self.first_chapter, self.confirmed_chapter do
        if not self.is_skippable(k) then return true end
    end
    return false
end

-- The reader said "yes, I finished the previous chapter".
function Boundary:confirm(chapter)
    local c = self.pending_chapter
    if not c then return false end
    if chapter ~= nil and chapter ~= c then return false end
    self.confirmed_chapter = c
    self.auto_frac = self.pending_frac
    self.auto_step = self.pending_step
    self.pending_chapter = nil
    self.pending_frac = 0
    return true
end

-- The reader explicitly sets the boundary (any direction), e.g. "I have read up
-- to here" when resuming a book. Never call this from automatic code paths.
function Boundary:setByReader(chapter, frac)
    if not isChapter(chapter) or not isNumber(frac) then return false end
    self.confirmed_chapter = chapter
    self.auto_frac = clamp(frac, 0, 1)
    self.auto_step = 0.02
    self.pending_chapter = nil
    self.pending_frac = 0
    return true
end

-- The reader moves the boundary back (re-reading, or confirmed too early).
-- Refuses to move forward: use setByReader for that.
function Boundary:rollBack(chapter, frac)
    if not isChapter(chapter) or not isNumber(frac) then return false end
    frac = clamp(frac, 0, 1)
    if chapter > self.confirmed_chapter then return false end
    if chapter == self.confirmed_chapter and frac > self.auto_frac + EPS then return false end
    return self:setByReader(chapter, frac)
end

-- The limit nothing may cross.
function Boundary:getLimit()
    return { chapter = self.confirmed_chapter, frac = self.auto_frac }
end

function Boundary:getConfirmedChapter()
    return self.confirmed_chapter
end

function Boundary:getPendingChapter()
    return self.pending_chapter
end

-- Is this position at or before the boundary?
function Boundary:isAllowed(pos)
    if type(pos) ~= "table" or not isChapter(pos.chapter) or not isNumber(pos.frac) then
        return false
    end
    if pos.chapter < self.confirmed_chapter then return true end
    if pos.chapter > self.confirmed_chapter then return false end
    return pos.frac <= self.auto_frac + EPS
end

function Boundary:toTable()
    return {
        version = STATE_VERSION,
        first_chapter = self.first_chapter,
        confirmed_chapter = self.confirmed_chapter,
        auto_frac = self.auto_frac,
        auto_step = self.auto_step,
        pending_chapter = self.pending_chapter,
        pending_frac = self.pending_frac,
        pending_step = self.pending_step,
    }
end

-- Rebuild from saved state. Anything unreadable gives the most restrictive
-- boundary (start of the book) and returns ok = false. Never raises.
function Boundary.fromTable(t, opts)
    local fresh = Boundary:new(opts)
    if type(t) ~= "table" or t.version ~= STATE_VERSION
        or not isChapter(t.confirmed_chapter) or not isNumber(t.auto_frac)
        or t.auto_frac < 0 or t.auto_frac > 1 then
        return fresh, false
    end
    fresh.confirmed_chapter = t.confirmed_chapter
    fresh.auto_frac = t.auto_frac
    fresh.auto_step = isNumber(t.auto_step) and cleanStep(t.auto_step) or 0.02
    -- A pending chapter is only believable if it is exactly the next one.
    if isChapter(t.pending_chapter) and t.pending_chapter == t.confirmed_chapter + 1
        and isNumber(t.pending_frac) and t.pending_frac >= 0 and t.pending_frac <= 1 then
        fresh.pending_chapter = t.pending_chapter
        fresh.pending_frac = t.pending_frac
        fresh.pending_step = isNumber(t.pending_step) and cleanStep(t.pending_step) or 0.02
    end
    return fresh, true
end

return Boundary
