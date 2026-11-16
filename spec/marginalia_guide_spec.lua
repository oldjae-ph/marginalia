-- The reading guide: when it is offered, what is asked for, how the answer is read and
-- checked, and what the reader sees. The screens are faked; the AI is faked.
require("spec.spec_helper")
package.path = "marginalia.koplugin/?.lua;" .. package.path

local Guide = require("marginalia_guide")
local Prompts = require("marginalia_prompts")
local SpoilerCheck = require("marginalia_spoilercheck")
local XRayPlugin = dofile("marginalia.koplugin/main.lua")

local function has(text, needle) return type(text) == "string" and text:find(needle, 1, true) ~= nil end

local function goodResult(extra)
    local r = {
        genre = "literary", genre_confidence = "high", knowledge = "good",
        author_and_period = "Written in the 1860s in Russia.",
        style_and_structure = "A long realist novel.",
        opening_characters = { { name = "Prince Myshkin", note = "A young man on a train." } },
        themes = { "What does goodness cost?", "Can innocence survive society?" },
        hard_parts = { "Russian names have several forms." },
    }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end

describe("guide: when to offer", function()
    it("offers it when nothing is saved, and when the reader said 'Later'", function()
        assert.is_true(Guide.shouldOffer(nil))
        assert.is_true(Guide.shouldOffer(Guide.markState("later")))
    end)
    it("does not offer it once it exists or the reader said 'Not for this book'", function()
        assert.is_false(Guide.shouldOffer(Guide.markState("created")))
        assert.is_false(Guide.shouldOffer(Guide.markState("never")))
    end)
    it("treats damaged saved data as nothing saved", function()
        assert.is_true(Guide.shouldOffer("junk"))
        assert.is_true(Guide.shouldOffer({ state = "???" }))
    end)
end)

describe("guide: the request", function()
    it("asks about this book, and says there is no text when none is allowed", function()
        local p = Guide.buildPrompt({ title = "The Idiot", author = "Dostoevsky", description = "<p>A prince &amp; a scandal.</p>" })
        assert.is_true(has(p, "The Idiot") and has(p, "Dostoevsky"))
        assert.is_true(has(p, "A prince & a scandal."))
        assert.is_false(has(p, "<p>"))
        assert.is_true(has(p, "No part of the book's text is provided"))
        assert.is_false(has(p, "OPENING TEXT (the first chapter"))
    end)

    it("includes the opening text only when it is given", function()
        local p = Guide.buildPrompt({ title = "T", author = "A", opening_text = "It was November." })
        assert.is_true(has(p, "OPENING TEXT (the first chapter") and has(p, "It was November."))
        assert.is_false(has(p, "No part of the book's text"))
    end)

    it("states the spoiler rules, the genre list and the answer format", function()
        local p = Guide.buildPrompt({})
        for _, needle in ipairs({ "ABSOLUTE RULES", "mystery_thriller", "QUESTIONS", "opening_characters", "knowledge", "limited" }) do
            assert.is_true(has(p, needle), needle)
        end
    end)

    it("copes with percent signs and very long text", function()
        local p = Guide.buildPrompt({ title = "100% %s %d", description = string.rep("x", 9000), opening_text = string.rep("y", 20000) })
        assert.is_true(has(p, "100% %s %d"))
        assert.is_true(#p < 12000)
    end)

    it("asks for names spelled as this edition spells them", function()
        local p = Guide.buildPrompt({ title = "T", opening_text = "Muishkin spoke." })
        assert.is_true(has(p, "Spell every name EXACTLY as it is spelled in the OPENING TEXT"))
        assert.is_true(has(p, "different"))
    end)

    it("shows 'none provided' for a missing description", function()
        assert.is_true(has(Guide.buildPrompt({ title = "T" }), "(none provided)"))
    end)
end)

describe("guide: the answer", function()
    it("is tidied into a guide", function()
        local g = Guide.parse(goodResult())
        assert.are.equal("created", g.state)
        assert.are.equal("literary", g.genre)
        assert.are.equal(1, #g.opening_characters)
        assert.are.equal(2, #g.themes)
    end)

    it("falls back safely: unknown genre, confidence and knowledge", function()
        local g = Guide.parse(goodResult({ genre = "space opera", genre_confidence = "huge", knowledge = "maybe" }))
        assert.are.equal("general", g.genre)
        assert.are.equal("low", g.genre_confidence)
        assert.are.equal("good", g.knowledge)
        assert.are.equal("limited", Guide.parse(goodResult({ knowledge = "limited" })).knowledge)
    end)

    it("limits and cleans the lists", function()
        local many = {}
        for i = 1, 20 do many[i] = "Question " .. i .. "?" end
        local chars = {}
        for i = 1, 20 do chars[i] = { name = "C" .. i, note = "n" } end
        local g = Guide.parse(goodResult({ themes = many, opening_characters = chars, hard_parts = { "", "---", "Real." } }))
        assert.are.equal(5, #g.themes)
        assert.are.equal(6, #g.opening_characters)
        assert.are.same({ "Real." }, g.hard_parts)
    end)

    it("drops characters without a name, and keeps a character without a note", function()
        local g = Guide.parse(goodResult({ opening_characters = { { note = "x" }, { name = "Ann" }, "junk" } }))
        assert.are.equal(1, #g.opening_characters)
        assert.are.equal("Ann", g.opening_characters[1].name)
        assert.is_nil(g.opening_characters[1].note)
    end)

    it("is refused when there is nothing useful in it", function()
        assert.is_nil(Guide.parse(nil))
        assert.is_nil(Guide.parse("text"))
        assert.is_nil(Guide.parse({}))
        assert.is_nil(Guide.parse({ genre = "literary", author_and_period = "---", themes = {} }))
    end)

    it("is usable only if saved as created with content", function()
        assert.is_true(Guide.isUsable(Guide.parse(goodResult())))
        assert.is_false(Guide.isUsable(Guide.markState("later")))
        assert.is_false(Guide.isUsable({ state = "created" }))
        assert.is_false(Guide.isUsable(nil))
    end)
end)

describe("guide: on the screen", function()
    it("lays out the sections in the spec's order", function()
        local text = Guide.format(Guide.parse(goodResult()))
        local order = { "Genre", "The author and the period", "Style and structure", "Who you meet at the start",
                        "Questions to keep in mind", "What may make it hard" }
        local last = 0
        for _, heading in ipairs(order) do
            local at = text:find(heading, 1, true)
            assert.is_true(at ~= nil and at > last, heading)
            last = at
        end
        assert.is_true(has(text, "- Prince Myshkin: A young man on a train."))
    end)

    it("says when the genre is only a guess, and when the book is not well known", function()
        local text = Guide.format(Guide.parse(goodResult({ genre_confidence = "low", knowledge = "limited" })))
        assert.is_true(has(text, "you can change it"))
        assert.is_true(has(text, "Background is limited"))
        local sure = Guide.format(Guide.parse(goodResult()))
        assert.is_false(has(sure, "you can change it") or has(sure, "Background is limited"))
    end)

    it("shows nothing for a guide that is not usable", function()
        assert.are.equal("", Guide.format(Guide.markState("later")))
        assert.are.equal("", Guide.format(nil))
    end)

    it("names a genre, with a fallback", function()
        assert.are.equal("Mystery / thriller", Guide.genreLabel("mystery_thriller"))
        assert.are.equal("General fiction", Guide.genreLabel("nonsense"))
    end)
end)

describe("guide: its own system rules", function()
    it("allow background and forbid plot, unlike the usual rules", function()
        assert.is_true(has(Prompts.guide_rules, "general knowledge of the author"))
        assert.is_true(has(Prompts.guide_rules, "NOTHING about what happens"))
        assert.is_false(has(Prompts.guide_rules, "ONLY the text supplied"))
    end)

    it("replace the usual rules rather than add to them", function()
        local usual = Prompts.forSystem("You are a researcher. JSON only.")
        local guide = Prompts.forGuideSystem(usual)
        assert.is_true(guide:find("^You are a researcher%. JSON only%.") ~= nil)
        assert.is_true(has(guide, "MARGINALIA GUIDE RULES"))
        assert.is_false(has(guide, "MARGINALIA SPOILER RULES"))
        assert.is_false(has(guide, "Act as if you have never read it"))
    end)

    it("work from nothing, and are not repeated", function()
        assert.is_true(has(Prompts.forGuideSystem(nil), "Return valid JSON ONLY."))
        local once = Prompts.forGuideSystem("Base.")
        assert.are.equal(once, Prompts.forGuideSystem(once))
        local count, from = 0, 1
        while true do
            local s, e = once:find("MARGINALIA GUIDE RULES", from, true)
            if not s then break end
            count, from = count + 1, e + 1
        end
        assert.are.equal(1, count)
    end)
end)

describe("guide: checking every piece of text", function()
    it("finds text whatever the field is called, except settings", function()
        local items = SpoilerCheck.collectAll(Guide.parse(goodResult()))
        local texts = {}
        for _, item in ipairs(items) do texts[item.text] = true end
        assert.is_true(texts["Written in the 1860s in Russia."] and texts["What does goodness cost?"] and texts["Prince Myshkin"])
        assert.is_true(texts["A young man on a train."])
        assert.is_nil(texts["literary"])   -- the genre id is a setting
        assert.is_nil(texts["created"])
        for i, item in ipairs(items) do assert.are.equal(i, item.id) end
    end)
end)

-- ---------------------------------------------------------------------------
-- The flow, with a fake screen, a fake AI and a fake saved-settings store
-- ---------------------------------------------------------------------------

describe("guide: the flow", function()
    local plugin, helper, fake_ui, store, guide_replies, check_replies, infos, built, claude_key

    local function newFakeUI()
        local calls = { offers = {}, warns = {}, shown = {}, genre_picks = {}, working = 0, closed = 0 }
        local ui = { calls = calls }
        function ui.offer(title, handlers) calls.offers[#calls.offers + 1] = { title = title, handlers = handlers } end
        function ui.working() calls.working = calls.working + 1 return { w = calls.working } end
        function ui.closeWorking() calls.closed = calls.closed + 1 end
        function ui.info(text) infos[#infos + 1] = text end
        function ui.warn(kind, detail, handlers) calls.warns[#calls.warns + 1] = { kind = kind, detail = detail, handlers = handlers } end
        function ui.show(text, label, handlers) calls.shown[#calls.shown + 1] = { text = text, label = label, handlers = handlers } end
        function ui.pickGenre(genres, current, on_pick) calls.genre_picks[#calls.genre_picks + 1] = { current = current, on_pick = on_pick } end
        return ui
    end

    local function setup(opts)
        opts = opts or {}
        infos, built, store = {}, {}, {}
        guide_replies, check_replies = {}, {}
        claude_key = opts.key == nil and "sk" or opts.key
        fake_ui = newFakeUI()
        helper = {
            path = "/tmp",
            prompts = { system_instruction = Prompts.forSystem("Base instruction.") },
            providers = { claude = { api_key = claude_key } },
            settings = {},
            buildComprehensiveRequest = function(h, _, _, _, prompt)
                built[#built + 1] = { prompt = prompt, system = h.prompts.system_instruction }
                if opts.cannot_build then return nil, "error_x", "no AI is set up" end
                return { { url = "u", headers = {}, body = "b", provider = "claude", model = "m" } }
            end,
            makeRequestAsync = function(_, requests, file)
                if opts.cannot_start then return nil, "error_busy", "busy" end
                return 7
            end,
            checkAsyncResult = function(_, file)
                local queue = file:find("guidecheck", 1, true) and check_replies or guide_replies
                local reply = table.remove(queue, 1)
                if reply == nil then return false, "error_test", "no reply queued" end
                return table.unpack(reply, 1, 3)
            end,
        }
        plugin = setmetatable({
            log = function() end, destroyed = false,
            ai_helper = helper,
            _marginalia_guide_ui = fake_ui,
            marginalia = {
                isSettled = function() return opts.unsettled ~= true end,
                deps = { get_toc = function() return { { page = 1, title = "I" }, { page = 5, title = "II" } }, 10 end },
                boundary = { first_chapter = 1 },
            },
            ui = {
                document = { file = "/b.epub", getProps = function() return { title = "The Idiot", authors = "Dostoevsky", description = "A prince." } end },
                doc_settings = {
                    -- like the real store, hand out a copy: a change only counts once it is saved
                    readSetting = function(_, k)
                        local v = store[k]
                        if type(v) ~= "table" then return v end
                        local copy = {}
                        for key, value in pairs(v) do copy[key] = value end
                        return copy
                    end,
                    saveSetting = function(_, k, v) store[k] = v end,
                    flush = function() end,
                },
            },
        }, { __index = XRayPlugin })
        if opts.opening then plugin.chapter_analyzer = { getTextFromPageRange = function() return opts.opening end } end
        plugin.chapter_analyzer = plugin.chapter_analyzer or { getTextFromPageRange = function() return nil end }
    end

    local function useCapturingJson()
        package.loaded["json"] = { encode = function() return "BODY" end, decode = function() return {} end }
    end
    local orig_json
    before_each(function() orig_json = package.loaded["json"]; useCapturingJson() end)
    after_each(function() package.loaded["json"] = orig_json end)

    describe("offering it", function()
        it("offers it on a new book, once", function()
            setup()
            plugin:marginaliaGuideMaybeOffer()
            plugin:marginaliaGuideMaybeOffer()
            assert.are.equal(1, #fake_ui.calls.offers)
            assert.are.equal("The Idiot", fake_ui.calls.offers[1].title)
        end)

        it("waits until the boundary question has been answered", function()
            setup({ unsettled = true })
            plugin:marginaliaGuideMaybeOffer()
            assert.are.equal(0, #fake_ui.calls.offers)
        end)

        it("does not offer it again once it exists, or after 'Not for this book'", function()
            setup(); store.marginalia_guide = Guide.parse(goodResult())
            plugin:marginaliaGuideMaybeOffer()
            assert.are.equal(0, #fake_ui.calls.offers)
            setup(); store.marginalia_guide = Guide.markState("never")
            plugin:marginaliaGuideMaybeOffer()
            assert.are.equal(0, #fake_ui.calls.offers)
        end)

        it("offers it again after 'Later'", function()
            setup(); store.marginalia_guide = Guide.markState("later")
            plugin:marginaliaGuideMaybeOffer()
            assert.are.equal(1, #fake_ui.calls.offers)
        end)

        it("'Later' and 'Not for this book' are remembered, and never erase a finished guide", function()
            setup()
            plugin:marginaliaGuideMaybeOffer()
            fake_ui.calls.offers[1].handlers.later()
            assert.are.equal("later", store.marginalia_guide.state)
            fake_ui.calls.offers[1].handlers.never()
            assert.are.equal("never", store.marginalia_guide.state)
            store.marginalia_guide = Guide.parse(goodResult())
            fake_ui.calls.offers[1].handlers.later()
            assert.are.equal("created", store.marginalia_guide.state)
        end)

        it("is scheduled when the book opens, once settled", function()
            setup()
            plugin:marginaliaGuideScheduleOffer()
            assert.are.equal(1, #fake_ui.calls.offers)
        end)
    end)

    describe("making it", function()
        it("sends the description and no book text at the start of a book", function()
            setup()
            guide_replies = { { goodResult() } }; check_replies = { { { flagged = {} } } }
            plugin:marginaliaGuideStart()
            assert.is_true(has(built[1].prompt, "A prince."))
            assert.is_true(has(built[1].prompt, "No part of the book's text is provided"))
        end)

        it("sends the opening only as far as the spoiler gate allowed it", function()
            setup({ opening = "GATED OPENING" })
            guide_replies = { { goodResult() } }; check_replies = { { { flagged = {} } } }
            plugin:marginaliaGuideStart()
            assert.is_true(has(built[1].prompt, "GATED OPENING"))
        end)

        it("uses the guide's own rules for this request, then puts the usual ones back", function()
            setup()
            local usual = helper.prompts.system_instruction
            guide_replies = { { goodResult() } }; check_replies = { { { flagged = {} } } }
            plugin:marginaliaGuideStart()
            assert.is_true(has(built[1].system, "MARGINALIA GUIDE RULES"))
            assert.is_false(has(built[1].system, "MARGINALIA SPOILER RULES"))
            assert.are.equal(usual, helper.prompts.system_instruction)
        end)

        it("saves and shows a guide that passes the check", function()
            setup()
            guide_replies = { { goodResult() } }; check_replies = { { { flagged = {} } } }
            plugin:marginaliaGuideStart()
            assert.are.equal("created", store.marginalia_guide.state)
            assert.are.equal(1, #fake_ui.calls.shown)
            assert.is_true(has(fake_ui.calls.shown[1].text, "Questions to keep in mind"))
            assert.are.equal("Literary fiction / classic", fake_ui.calls.shown[1].label)
            assert.are.equal(0, #fake_ui.calls.warns)
            assert.are.equal(fake_ui.calls.working, fake_ui.calls.closed)
        end)

        it("does the second-pass check with the guide's own position", function()
            setup()
            local seen
            local orig = SpoilerCheck.buildPrompt
            SpoilerCheck.buildPrompt = function(items, ctx) seen = ctx return orig(items, ctx) end
            guide_replies = { { goodResult() } }; check_replies = { { { flagged = {} } } }
            plugin:marginaliaGuideStart()
            SpoilerCheck.buildPrompt = orig
            assert.is_true(has(seen.position, "very beginning of the book"))
            assert.are.equal("The Idiot", seen.title)
        end)

        it("one request at a time", function()
            setup()
            plugin._marginalia_guide_busy = true
            plugin:marginaliaGuideStart()
            assert.are.equal(0, #built)
        end)
    end)

    describe("when the check does not pass: a warning, never a silent swap", function()
        it("flagged: nothing is saved or shown until the reader chooses", function()
            setup()
            guide_replies = { { goodResult() } }; check_replies = { { { flagged = { 2 } } } }
            plugin:marginaliaGuideStart()
            assert.are.equal(1, #fake_ui.calls.warns)
            assert.are.equal("flagged", fake_ui.calls.warns[1].kind)
            assert.is_nil(store.marginalia_guide)
            assert.are.equal(0, #fake_ui.calls.shown)
        end)

        it("'Show anyway' saves the guide exactly as written, and shows it", function()
            setup()
            guide_replies = { { goodResult() } }; check_replies = { { { flagged = { 2 } } } }
            plugin:marginaliaGuideStart()
            fake_ui.calls.warns[1].handlers.show_anyway()
            assert.are.equal("created", store.marginalia_guide.state)
            assert.are.equal(2, #store.marginalia_guide.themes)
            assert.are.equal(1, #fake_ui.calls.shown)
        end)

        it("'Write a new guide' asks again", function()
            setup()
            guide_replies = { { goodResult() } }; check_replies = { { { flagged = { 1 } } } }
            plugin:marginaliaGuideStart()
            guide_replies = { { goodResult() } }; check_replies = { { { flagged = {} } } }
            fake_ui.calls.warns[1].handlers.regenerate()
            assert.are.equal(2, #built)
            assert.are.equal(1, #fake_ui.calls.shown)
        end)

        it("'Cancel' saves nothing and frees the next request", function()
            setup()
            guide_replies = { { goodResult() } }; check_replies = { { { flagged = { 1 } } } }
            plugin:marginaliaGuideStart()
            fake_ui.calls.warns[1].handlers.cancel()
            assert.is_nil(store.marginalia_guide)
            assert.is_nil(plugin._marginalia_guide_busy)
        end)

        it("unchecked (no Claude key): warns, with the reason", function()
            setup({ key = "" })
            guide_replies = { { goodResult() } }
            plugin:marginaliaGuideStart()
            assert.are.equal("unchecked", fake_ui.calls.warns[1].kind)
            assert.is_true(has(fake_ui.calls.warns[1].detail, "Claude API key"))
            assert.is_nil(store.marginalia_guide)
        end)

        it("unchecked (the checker's answer is unreadable): warns", function()
            setup()
            guide_replies = { { goodResult() } }; check_replies = { { { flagged = { 99 } } } }
            plugin:marginaliaGuideStart()
            assert.are.equal("unchecked", fake_ui.calls.warns[1].kind)
        end)

        it("unchecked (the checker fails): warns", function()
            setup()
            guide_replies = { { goodResult() } }; check_replies = { { false, "error_api", "HTTP 529" } }
            plugin:marginaliaGuideStart()
            assert.are.equal("unchecked", fake_ui.calls.warns[1].kind)
            assert.is_true(has(fake_ui.calls.warns[1].detail, "529"))
        end)
    end)

    describe("when it cannot be made", function()
        it("says so if no AI is set up", function()
            setup({ cannot_build = true })
            plugin:marginaliaGuideStart()
            assert.is_true(has(infos[1], "no AI is set up"))
            assert.is_nil(plugin._marginalia_guide_busy)
        end)

        it("says so if the request cannot start", function()
            setup({ cannot_start = true })
            plugin:marginaliaGuideStart()
            assert.is_true(has(infos[1], "busy"))
            assert.is_nil(plugin._marginalia_guide_busy)
        end)

        it("says so if the AI fails, and shows no guide", function()
            setup()
            guide_replies = { { false, "error_api", "HTTP 500" } }
            plugin:marginaliaGuideStart()
            assert.is_true(has(infos[1], "HTTP 500"))
            assert.is_nil(store.marginalia_guide)
            assert.are.equal(fake_ui.calls.working, fake_ui.calls.closed)
        end)

        it("says so if the answer is not a guide", function()
            setup()
            guide_replies = { { { nonsense = true } } }
            plugin:marginaliaGuideStart()
            assert.is_true(has(infos[1], "could not be read"))
            assert.is_nil(store.marginalia_guide)
        end)
    end)

    describe("reading it again", function()
        it("shows the saved guide", function()
            setup(); store.marginalia_guide = Guide.parse(goodResult())
            plugin:marginaliaGuideShow()
            assert.are.equal(1, #fake_ui.calls.shown)
            assert.are.equal(0, #built)
        end)

        it("makes one when there is none (asked for from the menu)", function()
            setup()
            guide_replies = { { goodResult() } }; check_replies = { { { flagged = {} } } }
            plugin:marginaliaGuideShow()
            assert.are.equal(1, #built)
        end)

        it("lets the reader correct the genre, and remembers it", function()
            setup(); store.marginalia_guide = Guide.parse(goodResult())
            plugin:marginaliaGuideShow()
            fake_ui.calls.shown[1].handlers.change_genre()
            fake_ui.calls.genre_picks[1].on_pick("mystery_thriller")
            assert.are.equal("mystery_thriller", store.marginalia_guide.genre)
            assert.are.equal("mystery_thriller", plugin:marginaliaGuideGenre())
            assert.are.equal("Mystery / thriller", fake_ui.calls.shown[2].label)
        end)

        it("has a menu entry that says whether the guide exists", function()
            setup()
            local item = plugin:marginaliaGuideMenuItem()
            assert.are.equal("Reading guide (not made yet)", item.text_func())
            store.marginalia_guide = Guide.parse(goodResult())
            assert.are.equal("Reading guide", item.text_func())
        end)

        it("gives no genre until there is a guide", function()
            setup()
            assert.is_nil(plugin:marginaliaGuideGenre())
        end)
    end)
end)
