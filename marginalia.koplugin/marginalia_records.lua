-- marginalia_records.lua
-- Chapter records and saved debriefs, kept in the book's own settings.
--
-- A RECORD is the compact memory of one chapter (about 150 words): later requests send
-- records instead of earlier chapter text. Every record was written inside the
-- boundary of its time, so memory built from them cannot hold a spoiler. Even so,
-- records are never used past the CURRENT boundary: if the reader moves it back, the
-- records of chapters beyond it are simply not read (see upTo).
--
-- A DEBRIEF is what the reader saw on screen, kept so it is shown again without
-- another request ("regenerate only when asked").

local Records = {}

local MAX_SUMMARY = 450
local MAX_ITEM = 140
local MAX_EVENTS, MAX_CHANGES, MAX_THREADS = 5, 4, 3

local function clip(text, n)
    text = tostring(text or ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
    if #text <= n then return text end
    local cut = text:sub(1, n):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "")
    return cut .. "..."
end

local function list(src, max_items)
    local out = {}
    if type(src) ~= "table" then return out end
    for _, v in ipairs(src) do
        if type(v) == "string" and v:match("%S") then out[#out + 1] = clip(v, MAX_ITEM) end
        if #out >= max_items then break end
    end
    return out
end

-- Tidy a record from the AI's answer, or nil if there is nothing to keep.
-- `title` is the chapter's title in the book; `fallback_summary` is used if the AI gave
-- none (the debrief's "in brief").
function Records.make(raw, title, fallback_summary)
    raw = type(raw) == "table" and raw or {}
    local summary = type(raw.summary) == "string" and raw.summary:match("%S") and raw.summary or fallback_summary
    if type(summary) ~= "string" or not summary:match("%S") then return nil end
    return {
        v = 1,
        title = clip(title or "", 120),
        summary = clip(summary, MAX_SUMMARY),
        events = list(raw.events, MAX_EVENTS),
        character_changes = list(raw.character_changes, MAX_CHANGES),
        threads = list(raw.threads, MAX_THREADS),
    }
end

local function isRecord(r)
    return type(r) == "table" and type(r.summary) == "string" and r.summary ~= ""
end

-- All records of chapters up to and including `limit_chapter`, in chapter order, as
-- { {index = n, record = r}, ... }. `before` (optional) keeps only chapters before it:
-- a debrief of chapter 7 sends the records of chapters 1-6.
function Records.upTo(records, limit_chapter, before)
    local out = {}
    if type(records) ~= "table" or type(limit_chapter) ~= "number" then return out end
    for key, record in pairs(records) do
        local index = tonumber(key)
        if index and index <= limit_chapter and (not before or index < before) and isRecord(record) then
            out[#out + 1] = { index = index, record = record }
        end
    end
    table.sort(out, function(a, b) return a.index < b.index end)
    return out
end

-- The records as text for a request. Newest chapters win if there is not room.
function Records.asText(entries, max_chars)
    max_chars = max_chars or 6000
    local blocks = {}
    for _, e in ipairs(entries) do
        local r = e.record
        local lines = { string.format("Chapter %s: %s", r.title ~= "" and r.title or tostring(e.index), r.summary) }
        if #r.events > 0 then lines[#lines + 1] = "  Events: " .. table.concat(r.events, "; ") end
        if #r.character_changes > 0 then lines[#lines + 1] = "  Character changes: " .. table.concat(r.character_changes, "; ") end
        if #r.threads > 0 then lines[#lines + 1] = "  Open questions: " .. table.concat(r.threads, "; ") end
        blocks[#blocks + 1] = table.concat(lines, "\n")
    end
    local kept, used = {}, 0
    for i = #blocks, 1, -1 do
        used = used + #blocks[i] + 1
        if used > max_chars then break end
        table.insert(kept, 1, blocks[i])
    end
    return table.concat(kept, "\n")
end

-- Store one chapter's record (replacing any earlier one) in the saved table.
function Records.put(records, index, record)
    records = type(records) == "table" and records or {}
    if type(index) == "number" and isRecord(record) then records[index] = record end
    return records
end

-- How many debriefs are saved, for the menu.
function Records.count(debriefs)
    local n = 0
    if type(debriefs) == "table" then
        for _, d in pairs(debriefs) do if type(d) == "table" and d.in_brief then n = n + 1 end end
    end
    return n
end

return Records
