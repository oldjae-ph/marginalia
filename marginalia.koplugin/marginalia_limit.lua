-- marginalia_limit.lua
-- Turns the spoiler boundary (chapter + fraction) into the last page of the book
-- the reader may see or send. Pure logic, no KOReader.
--
-- Inverse of marginalia_position.lua: that maps a page to the END of the page as a
-- fraction of its chapter; this maps the fraction back to a page. Rounding goes
-- DOWN, so any disagreement after repagination can only hide text, never reveal it.

local Limit = {}

local function isNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- toc: array of { page = <number> } sorted by page (as the integration builds it).
-- limit: { chapter, frac } from Boundary:getLimit().
-- Returns the last allowed page (0 = nothing yet), or nil when it cannot be worked
-- out (no TOC, bad boundary). Callers must treat nil as "nothing allowed".
function Limit.lastAllowedPage(toc, limit, total_pages)
    if type(toc) ~= "table" or type(limit) ~= "table" then return nil end
    total_pages = tonumber(total_pages)
    if not total_pages or total_pages < 1 then return nil end
    local c, frac = limit.chapter, limit.frac
    if not isNumber(c) or c < 1 or c ~= math.floor(c) or not isNumber(frac) then return nil end
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end

    local entry = toc[c]
    local start_p = entry and tonumber(entry.page)
    if not start_p then return nil end
    local next_entry = toc[c + 1]
    local end_p = (next_entry and tonumber(next_entry.page)) or (total_pages + 1)
    local size = end_p - start_p
    if size < 1 then size = 1 end

    -- end of page p = (p + 1 - start) / size  =>  p = frac * size + start - 1
    local last = math.floor(frac * size + start_p - 1 + 1e-6)
    local lo, hi = start_p - 1, end_p - 1
    if last < lo then last = lo end
    if last > hi then last = hi end
    if last > total_pages then last = total_pages end
    if last < 0 then last = 0 end
    return last
end

return Limit
