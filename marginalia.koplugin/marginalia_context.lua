-- marginalia_context.lua
-- Decides whether saved X-Ray data may be shown or sent, given the confirmed
-- spoiler boundary. Pure logic, no KOReader, no I/O.
--
-- Every cache save is stamped with the boundary it was made under (the gate in
-- xray_chapteranalyzer.lua guarantees the text behind it never passed that
-- boundary). Data whose stamp is AHEAD of the current boundary, for instance
-- after the reader rolled back, or data from before Marginalia that reached
-- further than the boundary, "was generated past the boundary" and must not be
-- shown or sent. Positions are { chapter, frac } as in marginalia_boundary.lua.

local Context = {}

local STAMP_VERSION = 1
local EPS = 1e-9

local function isNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function validPosition(p)
    return type(p) == "table" and isNumber(p.chapter) and p.chapter >= 1
        and p.chapter == math.floor(p.chapter) and isNumber(p.frac)
end

-- -1, 0 or 1; nil when either position is unusable.
function Context.compare(a, b)
    if not validPosition(a) or not validPosition(b) then return nil end
    if a.chapter ~= b.chapter then return a.chapter < b.chapter and -1 or 1 end
    if math.abs(a.frac - b.frac) <= EPS then return 0 end
    return a.frac < b.frac and -1 or 1
end

-- The stamp to write into a cache: a copy of the boundary, versioned.
function Context.makeStamp(limit)
    if not validPosition(limit) then return nil end
    return { v = STAMP_VERSION, chapter = limit.chapter, frac = limit.frac }
end

local function stampPosition(stamp)
    if type(stamp) ~= "table" or stamp.v ~= STAMP_VERSION then return nil end
    return validPosition(stamp) and stamp or nil
end

-- Could this data hold story content at all? Empty data cannot spoil anything.
function Context.hasContent(data)
    if type(data) ~= "table" then return false end
    for _, key in ipairs({ "characters", "locations", "timeline", "historical_figures", "terms" }) do
        local list = data[key]
        if type(list) == "table" and next(list) ~= nil then return true end
    end
    return false
end

-- Is this data from past the boundary?
--   data        the loaded cache table
--   limit       { chapter, frac } current boundary
--   limit_page  last allowed page (0 = nothing), or nil if it cannot be worked out
-- Returns true (tainted) / false (usable). When it cannot tell, and the data has
-- content, it answers true: unknown is not safe.
function Context.isTainted(data, limit, limit_page)
    if type(data) ~= "table" then return false end
    if not Context.hasContent(data) then return false end

    local stamp = stampPosition(data.marginalia_boundary)
    if stamp then
        local order = Context.compare(stamp, limit)
        if order == nil then return true end
        return order > 0
    end

    -- Made before Marginalia (no stamp): judge by how far it was fetched.
    -- Pages are only meaningful in the layout they were made in, so this is a
    -- best effort; the stamp makes it exact from the first save onwards.
    local fetched = tonumber(data.last_fetch_page)
    if not fetched or not isNumber(limit_page) then return true end
    return fetched > limit_page
end

return Context
