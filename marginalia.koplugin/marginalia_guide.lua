-- marginalia_guide.lua
-- The reading guide: pure logic. Building the request text, checking and tidying
-- what the AI sends back, and laying it out for the screen. No UI, no network.
--
-- Saved per book (in the book's own settings) as:
--   { v = 1, state = "created" | "later" | "never",
--     genre = "<id>", genre_confidence, knowledge = "good" | "limited",
--     author_and_period, style_and_structure,
--     opening_characters = { {name, note}, ... }, themes = {...}, hard_parts = {...},
--     created_at }

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local Template = require(plugin_path .. "marginalia_prompt_guide")

local Guide = {}

Guide.VERSION = 1

-- The genres a book can be set to. The id is what is saved; it will pick the debrief
-- profile. The label is what the reader sees.
Guide.GENRES = {
    { id = "literary", label = "Literary fiction / classic" },
    { id = "mystery_thriller", label = "Mystery / thriller" },
    { id = "fantasy_scifi", label = "Fantasy / science fiction" },
    { id = "romance", label = "Romance" },
    { id = "historical", label = "Historical fiction" },
    { id = "horror", label = "Horror" },
    { id = "nonfiction", label = "Non-fiction" },
    { id = "general", label = "General fiction" },
}

local GENRE_BY_ID = {}
for _, g in ipairs(Guide.GENRES) do GENRE_BY_ID[g.id] = g end

function Guide.genreLabel(id)
    local g = GENRE_BY_ID[id]
    return g and g.label or GENRE_BY_ID.general.label
end

-- ---------------------------------------------------------------------------
-- When to offer
-- ---------------------------------------------------------------------------

-- Offer the guide the first time a book is opened (nothing saved), and again on later
-- opens if the reader chose "Later". Never once it exists or they said "Not for this
-- book". Damaged saved data counts as nothing saved.
function Guide.shouldOffer(saved)
    if type(saved) ~= "table" then return true end
    return saved.state == "later" or (saved.state ~= "created" and saved.state ~= "never")
end

function Guide.markState(state)
    return { v = Guide.VERSION, state = state }
end

-- ---------------------------------------------------------------------------
-- The request
-- ---------------------------------------------------------------------------

local function stripMarkup(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("<[^>]*>", " "):gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&quot;", '"')
    text = text:gsub("&#?%w+;", " "):gsub("%s+", " ")
    return (text:match("^%s*(.-)%s*$"))
end

local function clip(text, n)
    if #text <= n then return text end
    -- do not cut inside a UTF-8 character
    local cut = text:sub(1, n)
    cut = cut:gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "")
    return cut .. "..."
end

Guide.MAX_DESCRIPTION = 1500
Guide.MAX_OPENING = 6000

-- ctx: { title, author, description, opening_text }
-- opening_text must already have passed the spoiler gate; nothing is added here.
function Guide.buildPrompt(ctx)
    ctx = ctx or {}
    local description = clip(stripMarkup(ctx.description), Guide.MAX_DESCRIPTION)
    if description == "" then description = "(none provided)" end
    local opening = ctx.opening_text
    local block
    if type(opening) == "string" and opening:match("%S") then
        block = string.format(Template.opening_block, clip(opening, Guide.MAX_OPENING))
    else
        block = Template.no_text_block
    end
    return string.format(Template.template,
        tostring(ctx.title or "Unknown"), tostring(ctx.author or "Unknown"), description, block)
end

-- ---------------------------------------------------------------------------
-- The answer
-- ---------------------------------------------------------------------------

local function text(v, max)
    if type(v) ~= "string" then return nil end
    v = v:gsub("%s+", " "):match("^%s*(.-)%s*$")
    if v == "" or v == "---" then return nil end
    return clip(v, max or 1200)
end

local function textList(list, max_items, max_len)
    local out = {}
    if type(list) ~= "table" then return out end
    for _, v in ipairs(list) do
        local t = text(v, max_len or 400)
        if t then out[#out + 1] = t end
        if #out >= max_items then break end
    end
    return out
end

-- Tidy an AI answer into a guide, or nil if it is not usable. A guide needs at least
-- the author/period text or the themes; everything else is optional.
function Guide.parse(result)
    if type(result) ~= "table" then return nil end
    local guide = {
        v = Guide.VERSION,
        state = "created",
        genre = GENRE_BY_ID[result.genre] and result.genre or "general",
        genre_confidence = ({ high = true, medium = true, low = true })[result.genre_confidence] and result.genre_confidence or "low",
        knowledge = result.knowledge == "limited" and "limited" or "good",
        author_and_period = text(result.author_and_period),
        style_and_structure = text(result.style_and_structure),
        themes = textList(result.themes, 5, 300),
        hard_parts = textList(result.hard_parts, 6, 400),
        opening_characters = {},
    }
    if type(result.opening_characters) == "table" then
        for _, c in ipairs(result.opening_characters) do
            local name = type(c) == "table" and text(c.name, 80) or nil
            if name then
                guide.opening_characters[#guide.opening_characters + 1] = { name = name, note = text(c.note, 300) }
            end
            if #guide.opening_characters >= 6 then break end
        end
    end
    if not guide.author_and_period and #guide.themes == 0 then return nil end
    return guide
end

-- Is this saved data a usable guide?
function Guide.isUsable(saved)
    return type(saved) == "table" and saved.state == "created"
        and (type(saved.author_and_period) == "string" or (type(saved.themes) == "table" and #saved.themes > 0))
end

-- ---------------------------------------------------------------------------
-- Laying it out
-- ---------------------------------------------------------------------------

-- Plain text for the screen, in the spec's order. E-ink: no markup, short lines.
function Guide.format(guide)
    if not Guide.isUsable(guide) then return "" end
    local out = {}
    local function section(title, body)
        if body and body ~= "" then out[#out + 1] = title .. "\n" .. body end
    end
    section("Genre", Guide.genreLabel(guide.genre) .. (guide.genre_confidence == "low" and "  (a guess: you can change it)" or ""))
    section("The author and the period", guide.author_and_period)
    section("Style and structure", guide.style_and_structure)
    if guide.opening_characters and #guide.opening_characters > 0 then
        local lines = {}
        for _, c in ipairs(guide.opening_characters) do
            lines[#lines + 1] = "- " .. c.name .. (c.note and (": " .. c.note) or "")
        end
        section("Who you meet at the start", table.concat(lines, "\n"))
    end
    if guide.themes and #guide.themes > 0 then
        local lines = {}
        for _, t in ipairs(guide.themes) do lines[#lines + 1] = "- " .. t end
        section("Questions to keep in mind", table.concat(lines, "\n"))
    end
    if guide.hard_parts and #guide.hard_parts > 0 then
        local lines = {}
        for _, t in ipairs(guide.hard_parts) do lines[#lines + 1] = "- " .. t end
        section("What may make it hard", table.concat(lines, "\n"))
    end
    if guide.knowledge == "limited" then
        out[#out + 1] = "Note: this book is not well known to the assistant, so this guide is built only from the description and the opening. Background is limited."
    end
    return table.concat(out, "\n\n")
end

return Guide
