-- Second-pass spoiler check: a small model reads the AI's new X-Ray text before the
-- reader does. Nothing is shown until it has passed; if the check cannot run, the
-- text is held back (fails closed).
require("spec.spec_helper")
package.path = "marginalia.koplugin/?.lua;" .. package.path

local SpoilerCheck = require("marginalia_spoilercheck")
local XRayPlugin = dofile("marginalia.koplugin/main.lua")

-- The test environment's JSON library is a stub, so use one that keeps the table it
-- is asked to encode: the specs then look at the request's contents directly.
local captured, orig_json
local function useCapturingJson()
    orig_json = package.loaded["json"]
    captured = nil
    package.loaded["json"] = { encode = function(t) captured = t return "BODY" end, decode = function() return {} end }
end
local function restoreJson() package.loaded["json"] = orig_json end

local function ids(items)
    local out = {}
    for _, item in ipairs(items) do out[#out + 1] = item.id end
    return out
end

local function sample()
    return {
        characters = {
            { name = "Alice", role = "Protagonist", status = "alive", description = "A young clerk.", evidence = "quote" },
            { name = "Bob", role = "Antagonist", description = "---" },
        },
        locations = { { name = "Keep", description = "A grim castle." } },
        timeline = { { chapter = "I", event = "Alice arrives." } },
    }
end

describe("spoilercheck: collecting the text to check", function()
    it("finds the story text, in a steady order, numbered from 1", function()
        local items = SpoilerCheck.collect(sample())
        assert.are.same({ 1, 2, 3, 4, 5, 6 }, ids(items))
        local again = SpoilerCheck.collect(sample())
        for i, item in ipairs(items) do assert.are.equal(item.text, again[i].text) end
    end)

    it("includes roles and statuses, not names, quotes or empty placeholders", function()
        local texts = {}
        for _, item in ipairs(SpoilerCheck.collect(sample())) do texts[item.text] = true end
        assert.is_true(texts["Protagonist"] and texts["alive"] and texts["Antagonist"])
        assert.is_true(texts["A young clerk."] and texts["A grim castle."] and texts["Alice arrives."])
        assert.is_nil(texts["quote"])   -- evidence is from the supplied text
        assert.is_nil(texts["---"])     -- nothing there
        assert.is_nil(texts["Alice"])   -- a name is not a statement
    end)

    it("reaches into chapter batches and single-word lookups", function()
        local data = { chapters = { { timeline_event = "Something happens.",
                                      new_characters = { { name = "Cara", intro_description = "Meets Alice.", description = "A spy." } } } },
                       item = { name = "Dan", biography = "A general." } }
        assert.are.equal(4, #SpoilerCheck.collect(data))
    end)

    it("finds nothing to check in results without story text", function()
        assert.are.equal(0, #SpoilerCheck.collect({ book_type = "fiction", duplicate_pairs = {} }))
        assert.are.equal(0, #SpoilerCheck.collect({ author = "A", author_bio = "Born in 1900." }))
        assert.are.equal(0, #SpoilerCheck.collect({}))
    end)

    it("gives each statement a label with the entity's name", function()
        local items = SpoilerCheck.collect(sample())
        local found = false
        for _, item in ipairs(items) do if item.label:find('characters "Alice" role', 1, true) then found = true end end
        assert.is_true(found)
    end)
end)

describe("spoilercheck: batches", function()
    it("splits into groups, each numbered from 1, still pointing at the real fields", function()
        local data = { characters = {} }
        for i = 1, 85 do data.characters[i] = { name = "C" .. i, description = "text " .. i } end
        local groups = SpoilerCheck.chunk(SpoilerCheck.collect(data), 40)
        assert.are.equal(3, #groups)
        assert.are.equal(40, #groups[1]); assert.are.equal(5, #groups[3])
        assert.are.equal(1, groups[2][1].id)
        SpoilerCheck.apply(groups[2], { [1] = true })
        assert.are.equal("---", data.characters[41].description)
        assert.are.equal("text 40", data.characters[40].description)
    end)
end)

describe("spoilercheck: the request", function()
    local function helper(key)
        return { providers = { claude = { api_key = key } }, settings = {} }
    end
    before_each(useCapturingJson)
    after_each(restoreJson)

    it("asks the small model, with the numbered statements and the reader's position", function()
        local items = SpoilerCheck.collect(sample())
        local prompt = SpoilerCheck.buildPrompt(items, { title = "The Book", author = "An Author", position = "chapter II, 40%" })
        assert.is_true(prompt:find("The Book", 1, true) ~= nil)
        assert.is_true(prompt:find("chapter II, 40%", 1, true) ~= nil)
        assert.is_true(prompt:find("1. [", 1, true) ~= nil)
        assert.is_true(prompt:find("A grim castle.", 1, true) ~= nil)
        assert.is_true(prompt:find('{"flagged"', 1, true) ~= nil)
    end)

    it("cuts very long statements and survives text that looks like format codes", function()
        local data = { characters = { { name = "A", description = string.rep("x", 5000) .. " %s %d" } } }
        local prompt = SpoilerCheck.buildPrompt(SpoilerCheck.collect(data), { position = "p" })
        assert.is_true(#prompt < 4000)
        assert.is_true(prompt:find("...", 1, true) ~= nil)
    end)

    it("builds a Claude request with the key, the model and the checker's instructions", function()
        local requests = SpoilerCheck.buildRequest(helper("sk-test"), "PROMPT")
        assert.are.equal(1, #requests)
        local req = requests[1]
        assert.are.equal("claude", req.provider)
        assert.are.equal("claude-haiku-5-5", req.model)
        assert.are.equal("sk-test", req.headers["x-api-key"])
        assert.are.equal("claude-haiku-5-5", captured.model)
        assert.are.equal("PROMPT", captured.messages[1].content)
        assert.is_true(captured.system:find("spoiler checker", 1, true) ~= nil)
    end)

    it("gives a thinking model room to think, and asks for little thinking", function()
        local h = helper("k")
        h.isClaudeAdaptiveModel = function(model) return model:find("%-5%-") ~= nil end
        SpoilerCheck.buildRequest(h, "p")
        assert.is_true(captured.max_tokens >= 16000)  -- was 1024: the model ran out before answering
        assert.are.equal("adaptive", captured.thinking.type)
        assert.are.equal("low", captured.output_config.effort)
    end)

    it("leaves a model without thinking alone", function()
        local h = helper("k")
        h.settings.marginalia_spoiler_check_model = "claude-haiku-4-5"
        h.isClaudeAdaptiveModel = function(model) return model:find("%-5%-") ~= nil end
        SpoilerCheck.buildRequest(h, "p")
        assert.are.equal(1024, captured.max_tokens)
        assert.is_nil(captured.thinking)
    end)

    it("can be pointed at another model, and another endpoint", function()
        local h = helper("k"); h.settings.marginalia_spoiler_check_model = "m-x"; h.providers.claude.endpoint = "https://proxy/v1/messages"
        local req = SpoilerCheck.buildRequest(h, "p")[1]
        assert.are.equal("m-x", req.model)
        assert.are.equal("https://proxy/v1/messages", req.url)
    end)

    it("without a Claude key there is no request, and it says why", function()
        for _, h in ipairs({ helper(""), helper(nil), { providers = {} }, {} }) do
            local requests, code, msg = SpoilerCheck.buildRequest(h, "p")
            assert.is_nil(requests)
            assert.are.equal("error_spoiler_check", code)
            assert.is_true(msg:find("Claude API key", 1, true) ~= nil)
        end
    end)
end)

describe("spoilercheck: reading the verdict", function()
    it("accepts a list of valid numbers, or an empty list", function()
        assert.are.same({ [2] = true, [5] = true }, SpoilerCheck.parseVerdict({ flagged = { 2, 5 } }, 6))
        assert.are.same({}, SpoilerCheck.parseVerdict({ flagged = {} }, 6))
    end)

    it("refuses anything it cannot trust (so the text stays hidden)", function()
        for _, bad in ipairs({
            { flagged = { 0 } }, { flagged = { 7 } }, { flagged = { 1.5 } }, { flagged = { "2" } },
            { flagged = { a = 1 } }, { flagged = "none" }, {}, { other = {} },
        }) do
            assert.is_nil(SpoilerCheck.parseVerdict(bad, 6))
        end
        assert.is_nil(SpoilerCheck.parseVerdict(nil, 6))
        assert.is_nil(SpoilerCheck.parseVerdict("flagged", 6))
    end)
end)

describe("spoilercheck: replacing flagged text", function()
    it("blanks descriptions, marks events, clears a status, leaves the rest", function()
        local data = sample()
        local items = SpoilerCheck.collect(data)
        local flagged = {}
        for _, item in ipairs(items) do
            if item.key == "description" and item.text == "A young clerk." then flagged[item.id] = true end
            if item.key == "event" then flagged[item.id] = true end
            if item.key == "status" then flagged[item.id] = true end
        end
        assert.are.equal(3, SpoilerCheck.apply(items, flagged))
        assert.are.equal("---", data.characters[1].description)
        assert.are.equal(SpoilerCheck.WITHHELD, data.timeline[1].event)
        assert.is_nil(data.characters[1].status)
        assert.are.equal("Protagonist", data.characters[1].role)
        assert.are.equal("A grim castle.", data.locations[1].description)
    end)
end)

describe("spoilercheck: driving it from the polling step", function()
    before_each(useCapturingJson)
    after_each(restoreJson)
    local plugin, helper, results, started, files_started

    local function session(settled)
        return {
            isSettled = function() return settled ~= false end,
            describe = function() return { settled = true, title = "II", percent = 40 } end,
            getLimitPage = function() return 30 end,
        }
    end

    local function setup(opts)
        opts = opts or {}
        results, started, files_started = {}, {}, {}
        helper = {
            providers = { claude = { api_key = opts.key == nil and "sk" or opts.key } },
            settings = {},
            -- stands in for the real polling function: a file's result is given once, then it is gone
            checkAsyncResult = function(_, file)
                local r = results[file]
                if r == nil then return nil end
                results[file] = nil
                return table.unpack(r, 1, 3)
            end,
            makeRequestAsync = function(_, requests, file)
                if opts.cannot_start then return nil, "error_busy", "busy" end
                started[#started + 1] = { requests = requests, file = file }
                return 100 + #started
            end,
        }
        plugin = setmetatable({
            log = function() end,
            ai_helper = helper,
            marginalia = opts.session or session(true),
            ui = { document = { getProps = function() return { title = "The Book", authors = "An Author" } end,
                                getPageCount = function() return 100 end } },
        }, { __index = XRayPlugin })
        if not opts.skip_install then plugin:marginaliaInstallSpoilerCheck() end
        return plugin
    end

    local function arrive(file, data) results[file] = { data } end

    it("control: without the check, the text is handed straight to the caller", function()
        setup({ skip_install = true })
        local data = sample()
        arrive("f1", data)
        assert.are.equal(data, helper:checkAsyncResult("f1", 1))
    end)

    it("holds the text back and starts the check when it arrives", function()
        setup()
        local data = sample()
        arrive("f1", data)
        assert.is_nil(helper:checkAsyncResult("f1", 1))     -- not handed over
        assert.are.equal(1, #started)
        assert.are.equal("f1.check", started[1].file)
        assert.is_true(captured.messages[1].content:find("A young clerk.", 1, true) ~= nil)
        assert.is_true(captured.messages[1].content:find('chapter "II"', 1, true) ~= nil)
        assert.is_nil(helper:checkAsyncResult("f1", 1))     -- still waiting for the verdict
        assert.are.equal(1, #started)
    end)

    it("hands the text over once the check passes", function()
        setup()
        local data = sample()
        arrive("f1", data)
        helper:checkAsyncResult("f1", 1)
        results["f1.check"] = { { flagged = {} } }
        local out = helper:checkAsyncResult("f1", 1)
        assert.are.equal(data, out)
        assert.are.equal("A young clerk.", out.characters[1].description)
    end)

    it("removes what the check flagged before handing the text over", function()
        setup()
        local data = sample()
        arrive("f1", data)
        helper:checkAsyncResult("f1", 1)
        local items = SpoilerCheck.collect(data)
        local target
        for _, item in ipairs(items) do if item.text == "A young clerk." then target = item.id end end
        results["f1.check"] = { { flagged = { target } } }
        local out = helper:checkAsyncResult("f1", 1)
        assert.are.equal("---", out.characters[1].description)
        assert.are.equal("A grim castle.", out.locations[1].description)
    end)

    it("checks long results in several requests, one after another", function()
        setup()
        local data = { characters = {} }
        for i = 1, 85 do data.characters[i] = { name = "C" .. i, description = "text " .. i } end
        arrive("f1", data)
        assert.is_nil(helper:checkAsyncResult("f1", 1))
        assert.are.equal(1, #started)
        results["f1.check"] = { { flagged = {} } }
        assert.is_nil(helper:checkAsyncResult("f1", 1))     -- batch 2 started, not done
        assert.are.equal(2, #started)
        results["f1.check"] = { { flagged = { 1 } } }       -- flags the first statement of batch 2
        assert.is_nil(helper:checkAsyncResult("f1", 1))
        assert.are.equal(3, #started)
        results["f1.check"] = { { flagged = {} } }
        local out = helper:checkAsyncResult("f1", 1)
        assert.are.equal(data, out)
        assert.are.equal("---", out.characters[41].description)
        assert.are.equal("text 40", out.characters[40].description)
    end)

    describe("fails closed", function()
        local function neverShown(first, second, third)
            -- whatever happens, the caller must not receive the AI's text
            for _, v in ipairs({ first, second, third }) do assert.is_false(type(v) == "table" and v.characters ~= nil) end
        end

        it("when there is no Claude key", function()
            setup({ key = "" })
            arrive("f1", sample())
            local a, code, msg = helper:checkAsyncResult("f1", 1)
            assert.is_false(a)
            assert.are.equal("error_spoiler_check", code)
            assert.is_true(msg:find("Claude API key", 1, true) ~= nil)
            assert.are.equal(0, #started)
        end)

        it("when the boundary is not set yet", function()
            setup({ session = session(false) })
            arrive("f1", sample())
            local a, code = helper:checkAsyncResult("f1", 1)
            assert.is_false(a); assert.are.equal("error_spoiler_check", code)
        end)

        it("when there is no tracking at all", function()
            setup()
            plugin.marginalia = nil
            arrive("f1", sample())
            assert.is_false((helper:checkAsyncResult("f1", 1)))
        end)

        it("when the check request cannot be started", function()
            setup({ cannot_start = true })
            arrive("f1", sample())
            local a, code = helper:checkAsyncResult("f1", 1)
            assert.is_false(a); assert.are.equal("error_spoiler_check", code)
        end)

        it("when the checker returns an error", function()
            setup()
            arrive("f1", sample())
            helper:checkAsyncResult("f1", 1)
            results["f1.check"] = { false, "error_api", "HTTP 529" }
            local a, code, msg = helper:checkAsyncResult("f1", 1)
            assert.is_false(a); assert.are.equal("error_spoiler_check", code)
            assert.is_true(msg:find("529", 1, true) ~= nil)
        end)

        it("when the checker's answer cannot be read", function()
            setup()
            local data = sample()
            arrive("f1", data)
            helper:checkAsyncResult("f1", 1)
            results["f1.check"] = { { flagged = { 99 } } }
            local a, code = helper:checkAsyncResult("f1", 1)
            assert.is_false(a); assert.are.equal("error_spoiler_check", code)
            neverShown(a)
        end)

        it("and a later poll for the same file does not hand the text over", function()
            setup()
            arrive("f1", sample())
            helper:checkAsyncResult("f1", 1)
            results["f1.check"] = { { nonsense = true } }
            helper:checkAsyncResult("f1", 1)             -- fails
            local again = helper:checkAsyncResult("f1", 1)
            assert.is_nil(again)                          -- nothing, certainly not the data
        end)
    end)

    it("passes through what has nothing to check, and what has failed", function()
        setup()
        local plain = { book_type = "fiction", duplicate_pairs = {} }
        arrive("f1", plain)
        assert.are.equal(plain, helper:checkAsyncResult("f1", 1))
        assert.are.equal(0, #started)
        results["f2"] = { false, "error_api", "no" }
        local a, code, msg = helper:checkAsyncResult("f2", 1)
        assert.is_false(a); assert.are.equal("error_api", code); assert.are.equal("no", msg)
        assert.is_nil(helper:checkAsyncResult("f3", 1))   -- still pending
    end)

    it("is put in place when the reader opens a book", function()
        setup({ skip_install = true })
        local before = helper.checkAsyncResult
        plugin.marginalia = nil
        plugin.getCurrentPage = function() return 1 end
        plugin:marginaliaOnReaderReady()
        assert.are_not.equal(before, helper.checkAsyncResult)
    end)

    it("is installed once, even if Marginalia starts twice", function()
        setup()
        local wrapped = helper.checkAsyncResult
        plugin:marginaliaInstallSpoilerCheck()
        assert.are.equal(wrapped, helper.checkAsyncResult)
    end)

    it("moving the boundary back drops text that was waiting for its check", function()
        setup()
        plugin.cancelActiveAIRequest = function() end
        arrive("f1", sample())
        helper:checkAsyncResult("f1", 1)
        assert.is_not_nil(next(plugin._marginalia_check_state))
        plugin:marginaliaOnLowered()
        assert.is_nil(next(plugin._marginalia_check_state))
    end)
end)
