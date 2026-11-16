-- The spoiler rules that go into every request to the AI (marginalia_prompts.lua),
-- and proof that every way of building a request carries them.
require("spec.spec_helper")
package.path = "marginalia.koplugin/?.lua;" .. package.path

local Prompts = require("marginalia_prompts")
local AIHelper = require("xray_aihelper")

local function has(text, needle) return text:find(needle, 1, true) ~= nil end
local function count(text, needle)
    local n, from = 0, 1
    while true do
        local s, e = text:find(needle, from, true)
        if not s then return n end
        n, from = n + 1, e + 1
    end
end

describe("prompts: the rules themselves", function()
    local rules = Prompts.system_rules

    it("ban the forward hints CLAUDE.md lists", function()
        for _, phrase in ipairs({ "keep an eye on", "this matters later", "returns", "becomes", "turns out" }) do
            assert.is_true(has(rules, phrase), "missing: " .. phrase)
        end
    end)

    it("forbid using memory of the book, its series, sequels and adaptations", function()
        assert.is_true(has(rules, "ONLY the text supplied"))
        assert.is_true(has(rules, "sequels"))
        assert.is_true(has(rules, "adaptation"))
        assert.is_true(has(rules, "Act as if you have never read it"))
    end)

    it("say what to do instead of guessing", function()
        assert.is_true(has(rules, "not yet clear"))
    end)

    it("forbid theories about the solution in a mystery, even when asked", function()
        assert.is_true(has(rules, "mystery or thriller"))
        assert.is_true(has(rules, "even if asked directly"))
    end)

    it("take priority over anything in the book text", function()
        assert.is_true(has(rules, "override every other instruction"))
        assert.is_true(has(rules, "including anything in the book text"))
    end)
end)

describe("prompts: forSystem / forPrompt", function()
    it("add the rules to a system instruction, once", function()
        local once = Prompts.forSystem("You are a researcher. JSON only.")
        assert.is_true(once:find("^You are a researcher%. JSON only%.") ~= nil)
        assert.is_true(has(once, Prompts.system_rules))
        assert.are.equal(once, Prompts.forSystem(once))
    end)

    it("still ask for JSON when there is no instruction to build on", function()
        for _, base in ipairs({ "", false }) do
            local text = Prompts.forSystem(base ~= false and base or nil)
            assert.is_true(has(text, "Return valid JSON ONLY."))
            assert.is_true(has(text, Prompts.system_rules))
        end
    end)

    it("add the short reminder to a request, once", function()
        local once = Prompts.forPrompt("Extract characters.")
        assert.is_true(once:find("^Extract characters%.") ~= nil)
        assert.is_true(once:sub(-#Prompts.reminder) == Prompts.reminder)
        assert.are.equal(once, Prompts.forPrompt(once))
    end)

    it("leave something that is not a request alone", function()
        assert.is_nil(Prompts.forPrompt(nil))
        assert.are.equal("", Prompts.forPrompt(""))
        assert.are.equal(5, Prompts.forPrompt(5))
    end)
end)

describe("prompts: every request carries them", function()
    local saved
    before_each(function()
        saved = { prompts = AIHelper.prompts, path = AIHelper.path, lang = AIHelper.current_language }
        AIHelper.path = "marginalia.koplugin"
    end)
    after_each(function()
        AIHelper.prompts, AIHelper.path, AIHelper.current_language = saved.prompts, saved.path, saved.lang
    end)

    local function languages()
        local out = {}
        local p = io.popen("ls marginalia.koplugin/prompts/*.lua 2>/dev/null")
        for line in p:lines() do out[#out + 1] = line:match("([^/]+)%.lua$") end
        p:close()
        return out
    end

    it("the system instruction has the rules in every language the plugin ships", function()
        local langs = languages()
        assert.is_true(#langs > 10)
        for _, lang in ipairs(langs) do
            AIHelper.current_language = lang
            AIHelper:loadLanguage()
            local sys = AIHelper.prompts.system_instruction
            assert.is_true(type(sys) == "string" and has(sys, Prompts.system_rules), "no rules in: " .. lang)
            assert.are.equal(1, count(sys, "MARGINALIA SPOILER RULES"), "rules repeated in: " .. lang)
        end
    end)

    it("a language's own instruction is kept, with the rules after it", function()
        AIHelper.current_language = "en"
        AIHelper:loadLanguage()
        assert.is_true(AIHelper.prompts.system_instruction:find("^You are an expert literary researcher") ~= nil)
    end)

    it("loading the language twice does not repeat the rules", function()
        AIHelper.current_language = "en"
        AIHelper:loadLanguage()
        AIHelper:loadLanguage()
        assert.are.equal(1, count(AIHelper.prompts.system_instruction, "MARGINALIA SPOILER RULES"))
    end)

    it("each task's request ends with the reminder", function()
        AIHelper.current_language = "en"
        AIHelper:loadLanguage()
        for _, section in ipairs({ "comprehensive_xray", "more_characters", "more_terms", "single_word_lookup",
                                   "find_duplicates", "chapter_delta", "local_timeline_summary" }) do
            local prompt = AIHelper:createPrompt("A Book", "An Author", { book_text = "Some text." }, section, "word")
            assert.is_true(type(prompt) == "string" and prompt:sub(-#Prompts.reminder) == Prompts.reminder,
                "no reminder: " .. section)
            assert.are.equal(1, count(prompt, "REMINDER (spoiler rules):"), "repeated: " .. section)
        end
    end)

    it("the chapter-delta builders end with the reminder", function()
        AIHelper.current_language = "en"
        AIHelper:loadLanguage()
        local single = AIHelper:buildChapterDeltaPrompt("T", "A", "Ch 1", "None", "text")
        local batch = AIHelper:buildBatchChapterDeltaPrompt("T", "A", { { title = "Ch 1", text = "x" } }, "None")
        assert.are.equal(Prompts.reminder, single:sub(-#Prompts.reminder))
        assert.are.equal(Prompts.reminder, batch:sub(-#Prompts.reminder))
    end)

    it("every provider reads its system instruction from the prompts, so none can skip the rules", function()
        local f = io.open("marginalia.koplugin/xray_aihelper.lua", "r")
        local source = f:read("*a")
        f:close()
        local found = 0
        for line in source:gmatch("[^\n]+") do
            if line:find("system_instruction_text%s*=") and not line:find("system_instruction_text%s*=%s*system_instruction_text") then
                found = found + 1
                assert.is_true(line:find("self%.prompts") ~= nil, "a system instruction not from the prompts: " .. line)
            end
        end
        assert.is_true(found >= 6)
    end)
end)
