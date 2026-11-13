-- marginalia_position.lua
-- Converts a reader page into a boundary position. Pure logic: callers pass in
-- a flattened TOC (as xray's utils:flattenTOC returns) so this needs no KOReader.
--
-- Convention: the position is the END of the visible page, because that is how
-- much text the reader has actually seen. The end of page p is the start of p+1.
-- A page that starts a new TOC chapter belongs to that chapter, so a page shared
-- by the tail of chapter N and the head of N+1 counts as N+1 (conservative: the
-- tail of N on that page is simply not covered until N+1 is confirmed).

local Position = {}

-- toc: array of { page = <number> } sorted by page ascending (titles ignored).
-- Returns pos = { chapter, frac }, step (about one page as a fraction of the
-- chapter), or nil when there is no usable TOC or the page is before it.
function Position.fromPage(toc, page, total_pages)
    if type(toc) ~= "table" or #toc == 0 then return nil end
    page = tonumber(page)
    total_pages = tonumber(total_pages)
    if not page or not total_pages or page < 1 or total_pages < page then return nil end

    local chapter
    for i, entry in ipairs(toc) do
        local p = tonumber(entry.page)
        if p and p <= page then chapter = i else break end
    end
    if not chapter then return nil end

    local start_p = tonumber(toc[chapter].page)
    local next_entry = toc[chapter + 1]
    local end_p = (next_entry and tonumber(next_entry.page)) or (total_pages + 1)
    local size = end_p - start_p
    if size < 1 then size = 1 end -- two TOC entries on one page

    local frac = (page + 1 - start_p) / size
    if frac > 1 then frac = 1 end
    if frac < 0 then frac = 0 end
    return { chapter = chapter, frac = frac }, 1 / size
end

return Position
