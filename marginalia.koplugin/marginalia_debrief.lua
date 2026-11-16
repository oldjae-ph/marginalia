-- marginalia_debrief.lua
-- The chapter debrief: pure logic. Builds the request, checks and tidies the answer,
-- lays it out for the screen. No UI, no network.
--
-- The answer is held to the spec's grounding rule IN CODE: every "reading between the
-- lines" claim must carry a quotation, and a quotation that cannot be found in the
-- chapter text is thrown away together with its claim.

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local Template = require(plugin_path .. "marginalia_prompt_debrief")
local Records = require(plugin_path .. "marginalia_records")

local Debrief = {}

-- What each kind of book is debriefed for (the genre ids are the guide's). `between`:
-- "reading between the lines" is on by default, which the spec limits to literary
-- fiction and classics.
Debrief.PROFILES = {
    literary = { focus = "themes, symbolism, motives and the author's technique", between = true },
    mystery_thriller = { focus = "clues, suspects, what has been established and what has not; never the solution", between = false },
    fantasy_scifi = { focus = "the rules of the world, factions, invented terms and how the setting works", between = false },
    general = { focus = "characters, relationships and what is at stake; light on symbolism", between = false },
}
local PROFILE_OF = {
    literary = "literary", mystery_thriller = "mystery_thriller", fantasy_scifi = "fantasy_scifi",
    historical = "general", romance = "general", horror = "general", nonfiction = "general", general = "general",
}

function Debrief.profileFor(genre)
    return Debrief.PROFILES[PROFILE_OF[genre] or "general"]
end

Debrief.MAX_CHAPTER_CHARS = 30000

local function clip(text, n)
    text = tostring(text or "")
    if #text <= n then return text end
    local cut = text:sub(1, n):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "")
    return cut .. "..."
end

-- ctx: { title, author, chapter_title, genre, depth ("full"|"quick"), between (bool|nil
-- = the genre's default), records (entries from Records.upTo), chapter_text }
function Debrief.buildPrompt(ctx)
    ctx = ctx or {}
    local profile = Debrief.profileFor(ctx.genre)
    local between = ctx.between
    if between == nil then between = profile.between end
    local quick = ctx.depth == "quick"
    between = between and not quick

    local sections
    if quick then
        sections = Template.sections_quick
    else
        sections = string.format(Template.sections_full, between and Template.between_the_lines or "")
    end
    local records_text = Records.asText(ctx.records or {})
    if records_text == "" then records_text = Template.no_records end

    return string.format(Template.template,
        tostring(ctx.title or "Unknown"), tostring(ctx.author or "Unknown"), tostring(ctx.chapter_title or "this chapter"),
        profile.focus,
        between and Template.between_rules or "",
        records_text,
        clip(ctx.chapter_text or "", Debrief.MAX_CHAPTER_CHARS),
        sections)
end

-- ---------------------------------------------------------------------------
-- Quotations: found in the chapter, or the claim goes
-- ---------------------------------------------------------------------------

-- Plain comparison form: lower case, one kind of quote mark and dash, single spaces.
local function normalise(text)
    text = tostring(text or ""):lower()
    text = text:gsub("\226\128[\152\153]", "'"):gsub("\226\128[\156\157]", '"')   -- curly quotes
    text = text:gsub("\226\128[\147\148]", "-"):gsub("\226\128\166", "...")       -- dashes, ellipsis
    text = text:gsub("\194\160", " "):gsub("%s+", " ")
    return (text:gsub("^ ", ""):gsub(" $", ""))
end
Debrief._normalise = normalise

local MIN_QUOTE = 12 -- shorter than this proves nothing

function Debrief.quoteIsInText(quote, chapter_text)
    local q = normalise(quote):gsub("^[\"'%.%s]+", ""):gsub("[\"'%.%s]+$", "")
    if #q < MIN_QUOTE then return false end
    return normalise(chapter_text):find(q, 1, true) ~= nil
end

-- ---------------------------------------------------------------------------
-- The answer
-- ---------------------------------------------------------------------------

local function text(v, max)
    if type(v) ~= "string" then return nil end
    v = v:gsub("%s+", " "):match("^%s*(.-)%s*$")
    if v == "" or v == "---" then return nil end
    return clip(v, max or 800)
end

local function textList(src, max_items, max_len)
    local out = {}
    if type(src) ~= "table" then return out end
    for _, v in ipairs(src) do
        local t = text(v, max_len or 300)
        if t then out[#out + 1] = t end
        if #out >= max_items then break end
    end
    return out
end

-- opts: { chapter_text, chapter_title, depth }. Returns a debrief, or nil if the answer
-- has no "in brief". The record is always built (from the answer, or from the brief).
function Debrief.parse(result, opts)
    opts = opts or {}
    if type(result) ~= "table" then return nil end
    local in_brief = text(result.in_brief, 900)
    if not in_brief then return nil end
    local quick = opts.depth == "quick"
    local d = {
        v = 1,
        depth = quick and "quick" or "full",
        in_brief = in_brief,
        why_it_matters = text(result.why_it_matters, 900),
        what_happened = quick and {} or textList(result.what_happened, 8, 260),
        who_changed = quick and {} or textList(result.who_changed, 6, 260),
        questions = quick and {} or textList(result.questions, 3, 260),
        between_the_lines = {},
        dropped_claims = 0,
    }
    if not quick and type(result.if_hard) == "table" then
        local passage, reread = text(result.if_hard.passage, 700), text(result.if_hard.reread, 500)
        if passage or reread then d.if_hard = { passage = passage, reread = reread } end
    end
    if not quick and type(result.between_the_lines) == "table" then
        for _, item in ipairs(result.between_the_lines) do
            local claim = type(item) == "table" and text(item.claim, 400) or nil
            local quote = type(item) == "table" and text(item.quote, 300) or nil
            local tag = type(item) == "table" and item.tag == "in the text" and "in the text" or "interpretation"
            if claim and quote and Debrief.quoteIsInText(quote, opts.chapter_text) then
                d.between_the_lines[#d.between_the_lines + 1] = { claim = claim, tag = tag, quote = quote }
            else
                d.dropped_claims = d.dropped_claims + 1
            end
            if #d.between_the_lines >= 4 then break end
        end
    end
    d.record = Records.make(result.record, opts.chapter_title, in_brief)
    return d
end

function Debrief.isUsable(saved)
    return type(saved) == "table" and type(saved.in_brief) == "string" and saved.in_brief ~= ""
end

-- ---------------------------------------------------------------------------
-- Laying it out
-- ---------------------------------------------------------------------------

local function bullets(list)
    local out = {}
    for _, v in ipairs(list) do out[#out + 1] = "- " .. v end
    return table.concat(out, "\n")
end

-- Plain text for the screen: "In brief" first, so the first screen is the summary.
function Debrief.format(d, chapter_title, partial)
    if not Debrief.isUsable(d) then return "" end
    local out = {}
    local function section(title, body)
        if body and body ~= "" then out[#out + 1] = title .. "\n" .. body end
    end
    if partial then
        out[#out + 1] = "(This chapter is not finished yet: this covers what you have read so far.)"
    end
    section("In brief", d.in_brief)
    section("What happened", bullets(d.what_happened or {}))
    section("Who changed", bullets(d.who_changed or {}))
    section("Why it matters", d.why_it_matters)
    if d.between_the_lines and #d.between_the_lines > 0 then
        local lines = {}
        for _, item in ipairs(d.between_the_lines) do
            lines[#lines + 1] = string.format("- [%s] %s\n    \"%s\"", item.tag, item.claim, item.quote)
        end
        section("Reading between the lines", table.concat(lines, "\n"))
    end
    if d.if_hard then
        local parts = {}
        if d.if_hard.passage then parts[#parts + 1] = "In plain English: " .. d.if_hard.passage end
        if d.if_hard.reread then parts[#parts + 1] = "Worth rereading: " .. d.if_hard.reread end
        section("If this one was hard", table.concat(parts, "\n"))
    end
    section("Questions to sit with", bullets(d.questions or {}))
    if d.dropped_claims and d.dropped_claims > 0 then
        out[#out + 1] = string.format("(%d point%s left out: no matching quotation could be found in the chapter.)",
            d.dropped_claims, d.dropped_claims == 1 and "" or "s")
    end
    return table.concat(out, "\n\n")
end

return Debrief
