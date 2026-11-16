-- marginalia_spoilercheck.lua
-- Second-pass spoiler check. After the AI has written X-Ray text, a small fast
-- model reads just that text and the reader's position and flags anything that
-- hints at, or depends on, what comes later. Flagged text is replaced, never shown.
--
-- Pure logic here (no network, no UI): collect the text to check, build the
-- request, read the verdict, apply it. marginalia_integration.lua drives it.
--
-- Fails CLOSED: a verdict that cannot be read, or a missing Claude key, means the
-- text is not shown. Unknown is not safe.

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local Template = require(plugin_path .. "marginalia_prompt_spoiler_check")

local SpoilerCheck = {}

SpoilerCheck.MODEL = "claude-haiku-5-5"
SpoilerCheck.BATCH = 40          -- statements per request
SpoilerCheck.MAX_CHARS = 700     -- longest statement sent (the full text is kept)
SpoilerCheck.WITHHELD = "(hidden by the spoiler check)"

-- Fields that hold text written by the AI about the story.
local FIELDS = {
    description = true, intro_description = true, biography = true, definition = true,
    importance_in_book = true, context_in_book = true, change = true,
    role = true, intro_role = true, status = true,
    event = true, timeline_event = true,
}
-- Fields that are events: when withheld they say so, others are blanked.
local EVENT_FIELDS = { event = true, timeline_event = true }
SpoilerCheck.FIELDS = FIELDS

local MAX_DEPTH = 6

local function worthChecking(text)
    if type(text) ~= "string" then return false end
    local trimmed = text:match("^%s*(.-)%s*$")
    return #trimmed >= 3 and trimmed ~= "---"
end

-- Every checkable statement inside an AI result, in a stable order:
-- { id, text, label, holder, key }. Order is by walking sorted keys so the same
-- result always gives the same numbering.
function SpoilerCheck.collect(data)
    local items = {}
    local function walk(node, path, depth)
        if type(node) ~= "table" or depth > MAX_DEPTH then return end
        local keys = {}
        for k in pairs(node) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            if type(a) == type(b) then return a < b end
            return type(a) == "number"
        end)
        local name = type(node.name) == "string" and node.name or nil
        for _, k in ipairs(keys) do
            local v = node[k]
            if type(k) == "string" and FIELDS[k] and worthChecking(v) then
                local label = path
                if name then label = label .. ' "' .. name:sub(1, 60) .. '"' end
                items[#items + 1] = { text = v, label = label .. " " .. k, holder = node, key = k }
            elseif type(v) == "table" then
                walk(v, type(k) == "string" and k or path, depth + 1)
            end
        end
    end
    walk(data, "item", 0)
    for i, item in ipairs(items) do item.id = i end
    return items
end

-- Split items into groups for separate requests. Each group is numbered from 1.
function SpoilerCheck.chunk(items, size)
    size = size or SpoilerCheck.BATCH
    local groups = {}
    for i = 1, #items, size do
        local group = {}
        for j = i, math.min(i + size - 1, #items) do
            local item = items[j]
            group[#group + 1] = { id = #group + 1, text = item.text, label = item.label,
                                  holder = item.holder, key = item.key }
        end
        groups[#groups + 1] = group
    end
    return groups
end

local function clip(text, n)
    if #text <= n then return text end
    return text:sub(1, n) .. "..."
end

-- ctx: { title, author, position }
function SpoilerCheck.buildPrompt(items, ctx)
    ctx = ctx or {}
    local lines = {}
    for _, item in ipairs(items) do
        lines[#lines + 1] = string.format("%d. [%s] %s", item.id, item.label,
            clip((item.text:gsub("%s+", " ")), SpoilerCheck.MAX_CHARS))
    end
    return string.format(Template.template,
        tostring(ctx.title or "Unknown"), tostring(ctx.author or "Unknown"),
        tostring(ctx.position or "unknown"), table.concat(lines, "\n"))
end

-- The HTTP request for the checker, in the shape AIHelper:makeRequestAsync takes.
-- Needs the Claude key: without it there is no way to check, so: nil + a reason.
function SpoilerCheck.buildRequest(helper, prompt)
    local config = helper and helper.providers and helper.providers.claude
    if type(config) ~= "table" or type(config.api_key) ~= "string" or config.api_key == "" then
        return nil, "error_spoiler_check", "The spoiler check needs a Claude API key (new X-Ray text is held back until it can run)."
    end
    local ok_json, json = pcall(require, "json")
    if not ok_json or type(json) ~= "table" then
        return nil, "error_spoiler_check", "No JSON library for the spoiler check."
    end
    local model = (helper.settings and helper.settings.marginalia_spoiler_check_model) or SpoilerCheck.MODEL
    local payload = {
        model = model,
        max_tokens = 1024,
        system = Template.system,
        messages = { { role = "user", content = prompt } },
    }
    -- Claude 5.x models think before they answer, and thinking counts against
    -- max_tokens: with a small limit the model can run out before writing a single
    -- word ("No text in AI response", seen live). Give those models room, and ask
    -- for the least thinking, since the answer is only a list of numbers.
    local adaptive = type(helper.isClaudeAdaptiveModel) == "function" and helper.isClaudeAdaptiveModel(model)
    if adaptive then
        payload.max_tokens = 16000
        payload.thinking = { type = "adaptive" }
        payload.output_config = { effort = "low" }
    end
    local body = json.encode(payload)
    return {
        {
            url = config.endpoint or "https://api.anthropic.com/v1/messages",
            headers = {
                ["Content-Type"] = "application/json",
                ["anthropic-version"] = "2023-06-01",
                ["x-api-key"] = config.api_key,
            },
            body = body,
            provider = "claude",
            model = model,
        },
    }
end

-- The checker's answer as a set of flagged numbers, or nil if it cannot be trusted.
-- Valid: a table with a "flagged" list of whole numbers from 1 to count.
function SpoilerCheck.parseVerdict(verdict, count)
    if type(verdict) ~= "table" or type(verdict.flagged) ~= "table" then return nil end
    local set = {}
    for k, v in pairs(verdict.flagged) do
        if type(k) ~= "number" then return nil end
        if type(v) ~= "number" or v ~= math.floor(v) or v < 1 or v > count then return nil end
        set[v] = true
    end
    return set
end

-- Replace every flagged statement. The text is gone from the data for good.
function SpoilerCheck.apply(items, flagged)
    local replaced = 0
    for _, item in ipairs(items) do
        if flagged[item.id] and item.holder then
            if EVENT_FIELDS[item.key] then
                item.holder[item.key] = SpoilerCheck.WITHHELD
            elseif item.key == "status" then
                item.holder[item.key] = nil
            else
                item.holder[item.key] = "---"
            end
            replaced = replaced + 1
        end
    end
    return replaced
end

return SpoilerCheck
