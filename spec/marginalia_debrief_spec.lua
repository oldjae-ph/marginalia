-- The chapter debrief: the saved chapter records, the request, the answer (and the
-- grounding rule: a claim whose quotation is not in the chapter is thrown away), and
-- the whole flow with a fake screen and a fake AI.
require("spec.spec_helper")
package.path = "marginalia.koplugin/?.lua;" .. package.path

local Records = require("marginalia_records")
local Debrief = require("marginalia_debrief")
local Prompts = require("marginalia_prompts")
local SpoilerCheck = require("marginalia_spoilercheck")
local XRayPlugin = dofile("marginalia.koplugin/main.lua")

local function has(text, needle) return type(text) == "string" and text:find(needle, 1, true) ~= nil end

local CHAPTER = 'The prince said, "I have not prepared my judgment." Rogozhin laughed\nloudly and  stared at him.'

local function goodAnswer(extra)
    local r = {
        in_brief = "The prince meets Rogozhin on the train.",
        what_happened = { "They talk in the carriage.", "Rogozhin asks questions." },
        who_changed = { "Myshkin is no longer alone." },
        why_it_matters = "It sets up a link between two men.",
        between_the_lines = {
            { claim = "The prince is candid.", tag = "in the text", quote = "I have not prepared my judgment" },
        },
        if_hard = { passage = "He says he is unprepared.", reread = "The first exchange." },
        questions = { "What did they want from each other?" },
        record = { summary = "Myshkin meets Rogozhin on a train.", events = { "A talk in a carriage." },
                   character_changes = { "Myshkin gains a companion." }, threads = { "What does Rogozhin want?" } },
    }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end

describe("records: the chapter memory", function()
    it("tidies a record, within about 150 words", function()
        local many = {}
        for i = 1, 12 do many[i] = "Event " .. i end
        local r = Records.make({ summary = string.rep("word ", 200), events = many, character_changes = many, threads = many }, "Ch. 3")
        assert.are.equal("Ch. 3", r.title)
        assert.is_true(#r.summary <= 453)
        assert.are.equal(5, #r.events); assert.are.equal(4, #r.character_changes); assert.are.equal(3, #r.threads)
    end)

    it("falls back to the brief, and gives nothing when there is nothing", function()
        assert.are.equal("Brief.", Records.make({}, "T", "Brief.").summary)
        assert.is_nil(Records.make({}, "T", nil))
        assert.is_nil(Records.make({ summary = "  " }, "T", ""))
        assert.is_nil(Records.make(nil, "T"))
    end)

    local function sample()
        local rs = {}
        for i = 1, 6 do rs[i] = Records.make({ summary = "Summary " .. i, events = { "e" .. i } }, "Chapter " .. i) end
        rs["bad"] = "junk"
        rs[7] = { summary = "" }
        return rs
    end

    it("hands back only chapters up to the boundary, in order", function()
        local out = Records.upTo(sample(), 4)
        assert.are.equal(4, #out)
        for i, e in ipairs(out) do assert.are.equal(i, e.index) end
    end)

    it("can stop before the chapter being debriefed", function()
        local out = Records.upTo(sample(), 6, 3)
        assert.are.equal(2, #out)
        assert.are.equal(2, out[2].index)
    end)

    it("ignores junk and an unusable limit", function()
        assert.are.equal(0, #Records.upTo(nil, 3))
        assert.are.equal(0, #Records.upTo(sample(), nil))
        assert.are.equal(0, #Records.upTo({ [1] = { summary = 5 } }, 3))
    end)

    it("turns records into request text, newest first when there is no room", function()
        local text = Records.asText(Records.upTo(sample(), 6))
        assert.is_true(has(text, "Chapter 1: Summary 1") and has(text, "Events: e6"))
        local short = Records.asText(Records.upTo(sample(), 6), 120)
        assert.is_true(has(short, "Summary 6"))
        assert.is_false(has(short, "Summary 1"))
        assert.are.equal("", Records.asText({}))
    end)

    it("stores one record per chapter, replacing an older one, and counts debriefs", function()
        local rs = Records.put(nil, 2, Records.make({ summary = "A" }, "T"))
        rs = Records.put(rs, 2, Records.make({ summary = "B" }, "T"))
        assert.are.equal("B", rs[2].summary)
        assert.are.same(rs, Records.put(rs, 3, { summary = "" })) -- unusable: not stored
        assert.are.equal(2, Records.count({ [1] = { in_brief = "x" }, [2] = { in_brief = "y" }, [3] = {} }))
        assert.are.equal(0, Records.count(nil))
    end)
end)

describe("debrief: the request", function()
    local function prompt(ctx)
        local c = { title = "The Idiot", author = "D", chapter_title = "Ch. 3", chapter_text = CHAPTER, genre = "literary" }
        for k, v in pairs(ctx or {}) do c[k] = v end
        return Debrief.buildPrompt(c)
    end

    it("carries the chapter text and the book", function()
        local p = prompt()
        assert.is_true(has(p, "I have not prepared my judgment") and has(p, "The Idiot") and has(p, "Ch. 3"))
    end)

    it("says there are no earlier records for the first debrief, and sends them otherwise", function()
        assert.is_true(has(prompt(), "(none: this is the first chapter being debriefed)"))
        local recs = Records.upTo({ [1] = Records.make({ summary = "Earlier thing." }, "Ch. 1") }, 5)
        assert.is_true(has(prompt({ records = recs }), "Earlier thing."))
    end)

    it("bans forward hints and memory of the book, and any guess at a solution", function()
        local p = prompt()
        for _, needle in ipairs({ "Do not use anything you remember", "keep an eye on", "turns out", "never guess the solution" }) do
            assert.is_true(has(p, needle), needle)
        end
    end)

    it("changes its focus with the kind of book", function()
        assert.is_true(has(prompt({ genre = "mystery_thriller" }), "clues, suspects"))
        assert.is_true(has(prompt({ genre = "fantasy_scifi" }), "rules of the world"))
        assert.is_true(has(prompt({ genre = "romance" }), "relationships and what is at stake"))
        assert.is_true(has(prompt({ genre = false }), "relationships and what is at stake")) -- no guide: general
        assert.is_true(has(prompt({ genre = "literary" }), "symbolism"))
    end)

    it("asks for 'reading between the lines' only for literary fiction by default, and with quotations", function()
        assert.is_true(has(prompt({ genre = "literary" }), "between_the_lines"))
        assert.is_true(has(prompt({ genre = "literary" }), "copied EXACTLY"))
        assert.is_false(has(prompt({ genre = "mystery_thriller" }), "between_the_lines"))
        assert.is_true(has(prompt({ genre = "mystery_thriller", between = true }), "between_the_lines"))
        assert.is_false(has(prompt({ genre = "literary", between = false }), "between_the_lines"))
    end)

    it("quick: only the brief and why it matters, and never the extras", function()
        local p = prompt({ depth = "quick" })
        assert.is_true(has(p, "why_it_matters"))
        assert.is_false(has(p, "what_happened") or has(p, "between_the_lines") or has(p, "if_hard"))
        assert.is_true(has(p, '"record"')) -- a record is always kept
    end)

    it("cuts a very long chapter and survives text that looks like format codes", function()
        local p = prompt({ chapter_text = string.rep("100% %s %d ", 9000) })
        assert.is_true(#p < 35000 + 6000)
        assert.is_true(has(p, "100% %s %d"))
    end)
end)

describe("debrief: finding a quotation in the chapter", function()
    it("matches whatever the case, spacing, quote marks or dashes", function()
        assert.is_true(Debrief.quoteIsInText("rogozhin laughed loudly and stared", CHAPTER))
        assert.is_true(Debrief.quoteIsInText('"I have not prepared my judgment."', CHAPTER))
        assert.is_true(Debrief.quoteIsInText("\226\128\156I have not prepared my judgment\226\128\157", CHAPTER))
        assert.is_true(Debrief.quoteIsInText("it is \226\128\147 well, he said", "It is - well, he said."))
    end)

    it("refuses a quotation that is not there, is too short, or has no text to look in", function()
        assert.is_false(Debrief.quoteIsInText("He wept bitterly for hours", CHAPTER))
        assert.is_false(Debrief.quoteIsInText("the prince", CHAPTER)) -- real, but too short to prove anything
        assert.is_false(Debrief.quoteIsInText("I have not prepared my judgment", nil))
        assert.is_false(Debrief.quoteIsInText(nil, CHAPTER))
    end)
end)

describe("debrief: the answer", function()
    local function parse(result, opts)
        local o = { chapter_text = CHAPTER, chapter_title = "Ch. 3", depth = "full" }
        for k, v in pairs(opts or {}) do o[k] = v end
        return Debrief.parse(result, o)
    end

    it("is tidied, with its record", function()
        local d = parse(goodAnswer())
        assert.are.equal("The prince meets Rogozhin on the train.", d.in_brief)
        assert.are.equal(2, #d.what_happened)
        assert.are.equal("Myshkin meets Rogozhin on a train.", d.record.summary)
        assert.are.equal("Ch. 3", d.record.title)
    end)

    it("keeps a claim whose quotation is in the chapter, and drops one whose is not", function()
        local d = parse(goodAnswer({ between_the_lines = {
            { claim = "Real.", tag = "in the text", quote = "I have not prepared my judgment" },
            { claim = "Invented.", tag = "interpretation", quote = "He swore revenge upon them all" },
            { claim = "No quote at all.", tag = "interpretation" },
            { quote = "I have not prepared my judgment" },
        } }))
        assert.are.equal(1, #d.between_the_lines)
        assert.are.equal("Real.", d.between_the_lines[1].claim)
        assert.are.equal(3, d.dropped_claims)
    end)

    it("tags a claim 'interpretation' unless it says 'in the text'", function()
        local d = parse(goodAnswer({ between_the_lines = {
            { claim = "A.", tag = "in the text", quote = "I have not prepared my judgment" },
            { claim = "B.", tag = "obvious", quote = "I have not prepared my judgment" },
        } }))
        assert.are.equal("in the text", d.between_the_lines[1].tag)
        assert.are.equal("interpretation", d.between_the_lines[2].tag)
    end)

    it("quick: keeps only the brief, why it matters and the record", function()
        local d = parse(goodAnswer(), { depth = "quick" })
        assert.are.equal("quick", d.depth)
        assert.are.equal(0, #d.what_happened + #d.who_changed + #d.questions + #d.between_the_lines)
        assert.is_nil(d.if_hard)
        assert.is_not_nil(d.why_it_matters)
    end)

    it("builds a record from the brief when the AI gave none", function()
        local d = parse(goodAnswer({ record = false }))
        assert.are.equal("The prince meets Rogozhin on the train.", d.record.summary)
    end)

    it("is refused without an 'in brief', or when it is not a table", function()
        assert.is_nil(parse(goodAnswer({ in_brief = "" })))
        assert.is_nil(parse(nil))
        assert.is_nil(parse("text"))
    end)

    it("limits the lists", function()
        local many = {}
        for i = 1, 30 do many[i] = "Item " .. i end
        local d = parse(goodAnswer({ what_happened = many, who_changed = many, questions = many }))
        assert.are.equal(8, #d.what_happened); assert.are.equal(6, #d.who_changed); assert.are.equal(3, #d.questions)
    end)
end)

describe("debrief: on the screen", function()
    local function made(extra)
        return Debrief.parse(goodAnswer(extra), { chapter_text = CHAPTER, chapter_title = "Ch. 3", depth = "full" })
    end

    it("starts with 'In brief' and follows the spec's order", function()
        local text = Debrief.format(made(), "Ch. 3")
        local order = { "In brief", "What happened", "Who changed", "Why it matters", "Reading between the lines",
                        "If this one was hard", "Questions to sit with" }
        local last = 0
        for _, heading in ipairs(order) do
            local at = text:find(heading, 1, true)
            assert.is_true(at ~= nil and at > last, heading)
            last = at
        end
        assert.are.equal(1, text:find("In brief", 1, true))
    end)

    it("shows each claim tagged, with its quotation", function()
        local text = Debrief.format(made(), "Ch. 3")
        assert.is_true(has(text, '[in the text] The prince is candid.'))
        assert.is_true(has(text, '"I have not prepared my judgment"'))
    end)

    it("says when the chapter is not finished, and when points were left out", function()
        local partial = Debrief.format(made(), "Ch. 3", true)
        assert.is_true(has(partial, "not finished yet"))
        local d = made({ between_the_lines = { { claim = "x", tag = "interpretation", quote = "never said anything like this" } } })
        assert.is_true(has(Debrief.format(d, "Ch. 3"), "1 point left out"))
    end)

    it("shows nothing for a debrief that is not usable", function()
        assert.are.equal("", Debrief.format(nil))
        assert.are.equal("", Debrief.format({}))
    end)
end)

-- ---------------------------------------------------------------------------
-- The flow
-- ---------------------------------------------------------------------------

describe("debrief: the flow", function()
    local plugin, helper, ui, store, replies, checks, infos, built, guide_store

    local PAGES = { { page = 1, title = "One" }, { page = 5, title = "Two" }, { page = 9, title = "Three" }, { page = 13, title = "Four" } }

    local function newUI()
        local u = { calls = { shown = {}, warns = {}, picks = {}, working = 0, closed = 0 } }
        function u.working() u.calls.working = u.calls.working + 1 return {} end
        function u.closeWorking() u.calls.closed = u.calls.closed + 1 end
        function u.info(t) infos[#infos + 1] = t end
        function u.warn(kind, detail, h) u.calls.warns[#u.calls.warns + 1] = { kind = kind, detail = detail, handlers = h } end
        function u.show(title, text, h) u.calls.shown[#u.calls.shown + 1] = { title = title, text = text, handlers = h } end
        function u.pickChapter(title, choices, on_pick) u.calls.picks[#u.calls.picks + 1] = { title = title, choices = choices, on_pick = on_pick } end
        return u
    end

    local function setup(opts)
        opts = opts or {}
        infos, built, store, replies, checks = {}, {}, {}, {}, {}
        ui = newUI()
        local limit = opts.limit or { chapter = 3, frac = 1 }
        helper = {
            path = "/tmp", settings = opts.settings or {},
            prompts = { system_instruction = Prompts.forSystem("Base.") },
            providers = { claude = { api_key = opts.key == nil and "sk" or opts.key } },
            saveSettings = function(h, t) for k, v in pairs(t) do h.settings[k] = v end end,
            buildComprehensiveRequest = function(_, _, _, _, p)
                built[#built + 1] = p
                return { { url = "u", headers = {}, body = "b", provider = "claude", model = "m" } }
            end,
            makeRequestAsync = function() return 7 end,
            checkAsyncResult = function(_, file)
                local queue = file:find("guidecheck", 1, true) and checks or replies
                local reply = table.remove(queue, 1)
                if reply == nil then return false, "error_test", "nothing queued" end
                return table.unpack(reply, 1, 3)
            end,
        }
        plugin = setmetatable({
            log = function() end, destroyed = false, ai_helper = helper, _marginalia_debrief_ui = ui,
            marginalia = {
                isSettled = function() return opts.unsettled ~= true end,
                getLimit = function() return limit end,
                getLimitPage = function() return 20 end,
                describe = function() return { settled = true, title = "Three", percent = 100 } end,
                deps = { get_toc = function() return PAGES, 16 end },
                chapterChoices = function()
                    local out = {}
                    for i, e in ipairs(PAGES) do out[#out + 1] = { index = i, title = e.title, is_current = i == limit.chapter } end
                    return out
                end,
            },
            chapter_analyzer = { getTextFromPageRange = function(_, _, from, to)
                if opts.no_text then return nil end
                return "TEXT OF PAGES " .. from .. "-" .. to .. ". " .. CHAPTER
            end },
            ui = {
                document = { file = "/b.epub", getPageCount = function() return 16 end,
                             getProps = function() return { title = "The Idiot", authors = "D" } end },
                doc_settings = {
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
        if opts.genre then store.marginalia_guide = { state = "created", genre = opts.genre, author_and_period = "x", themes = { "q?" } } end
    end

    local orig_json
    before_each(function() orig_json = package.loaded["json"]; package.loaded["json"] = { encode = function() return "BODY" end, decode = function() return {} end } end)
    after_each(function() package.loaded["json"] = orig_json end)

    local function queue(answer, verdict)
        replies = { { answer } }
        checks = { { verdict or { flagged = {} } } }
    end

    describe("starting one", function()
        it("refuses a chapter beyond the boundary, without asking the AI", function()
            setup({ limit = { chapter = 2, frac = 1 } })
            plugin:marginaliaDebriefStart(3)
            assert.is_true(has(infos[1], "beyond your spoiler boundary"))
            assert.are.equal(0, #built)
        end)

        it("says so when the gate lets no text through", function()
            setup({ no_text = true })
            plugin:marginaliaDebriefStart(2)
            assert.is_true(has(infos[1], "no text of this chapter"))
            assert.are.equal(0, #built)
        end)

        it("waits for the boundary to be set", function()
            setup({ unsettled = true })
            plugin:marginaliaDebriefStart(2)
            assert.is_true(has(infos[1], "boundary is not set"))
            assert.are.equal(0, #built)
        end)

        it("one at a time", function()
            setup()
            plugin._marginalia_debrief_busy = true
            plugin:marginaliaDebriefStart(2)
            assert.are.equal(0, #built)
        end)

        it("asks about the right pages of the book", function()
            setup()
            queue(goodAnswer())
            plugin:marginaliaDebriefStart(2)
            assert.is_true(has(built[1], "TEXT OF PAGES 5-9"))
            assert.is_true(has(built[1], "Chapter: Two"))
        end)
    end)

    describe("what earlier chapters it is told", function()
        it("only records of chapters before this one and no further than the boundary", function()
            setup({ limit = { chapter = 3, frac = 1 } })
            store.marginalia_records = {
                [1] = Records.make({ summary = "ONE-SUMMARY" }, "One"),
                [2] = Records.make({ summary = "TWO-SUMMARY" }, "Two"),
                [3] = Records.make({ summary = "THREE-SUMMARY" }, "Three"),
                [4] = Records.make({ summary = "FOUR-SUMMARY-SPOILER" }, "Four"), -- beyond the boundary
            }
            queue(goodAnswer())
            plugin:marginaliaDebriefStart(3)
            assert.is_true(has(built[1], "ONE-SUMMARY") and has(built[1], "TWO-SUMMARY"))
            assert.is_false(has(built[1], "THREE-SUMMARY"))        -- the chapter itself is sent as text
            assert.is_false(has(built[1], "FOUR-SUMMARY-SPOILER")) -- beyond the boundary: never
        end)

        it("a boundary moved back hides the records written further on", function()
            setup({ limit = { chapter = 2, frac = 1 } })
            store.marginalia_records = {
                [1] = Records.make({ summary = "ONE-SUMMARY" }, "One"),
                [3] = Records.make({ summary = "THREE-SUMMARY" }, "Three"),
            }
            queue(goodAnswer())
            plugin:marginaliaDebriefStart(2)
            assert.is_true(has(built[1], "ONE-SUMMARY"))
            assert.is_false(has(built[1], "THREE-SUMMARY"))
        end)

        it("uses the genre chosen in the reading guide", function()
            setup({ genre = "mystery_thriller" })
            queue(goodAnswer())
            plugin:marginaliaDebriefStart(2)
            assert.is_true(has(built[1], "clues, suspects"))
        end)

        it("quick depth asks for the short form", function()
            setup({ settings = { marginalia_debrief_depth = "quick" } })
            queue(goodAnswer())
            plugin:marginaliaDebriefStart(2)
            assert.is_false(has(built[1], "what_happened"))
        end)
    end)

    describe("keeping it", function()
        it("saves the debrief and the chapter record, and shows it", function()
            setup()
            queue(goodAnswer())
            plugin:marginaliaDebriefStart(2)
            assert.are.equal("The prince meets Rogozhin on the train.", store.marginalia_debriefs[2].in_brief)
            assert.is_nil(store.marginalia_debriefs[2].record)  -- the record has its own place
            assert.are.equal("Myshkin meets Rogozhin on a train.", store.marginalia_records[2].summary)
            assert.are.equal(1, #ui.calls.shown)
            assert.is_true(has(ui.calls.shown[1].text, "In brief"))
            assert.are.equal("Two", ui.calls.shown[1].title)
            assert.are.equal(ui.calls.working, ui.calls.closed)
            assert.is_nil(plugin._marginalia_debrief_busy)
        end)

        it("a chapter still being read is debriefed as far as read, with NO record", function()
            setup({ limit = { chapter = 2, frac = 0.5 } })
            queue(goodAnswer())
            plugin:marginaliaDebriefStart(2)
            assert.is_true(store.marginalia_debriefs[2].partial)
            assert.is_nil(store.marginalia_records)
            assert.is_true(has(ui.calls.shown[1].text, "not finished yet"))
        end)

        it("drops a claim whose quotation is not in the chapter, before anything is saved", function()
            setup()
            queue(goodAnswer({ between_the_lines = { { claim = "Invented.", tag = "interpretation", quote = "He swore revenge on them all" } } }))
            plugin:marginaliaDebriefStart(2)
            assert.are.equal(0, #store.marginalia_debriefs[2].between_the_lines)
            assert.is_true(has(ui.calls.shown[1].text, "1 point left out"))
        end)

        it("shows a saved debrief again without asking", function()
            setup()
            queue(goodAnswer())
            plugin:marginaliaDebriefStart(2)
            plugin:marginaliaDebriefShow(2)
            assert.are.equal(1, #built)
            assert.are.equal(2, #ui.calls.shown)
        end)

        it("'Write again' asks again", function()
            setup()
            queue(goodAnswer())
            plugin:marginaliaDebriefStart(2)
            queue(goodAnswer({ in_brief = "A second telling." }))
            ui.calls.shown[1].handlers.write_again()
            assert.are.equal(2, #built)
            assert.are.equal("A second telling.", store.marginalia_debriefs[2].in_brief)
        end)

        it("keeps a saved debrief of a chapter past the boundary hidden (the boundary was moved back)", function()
            setup({ limit = { chapter = 1, frac = 1 } })
            store.marginalia_debriefs = { [3] = { in_brief = "Later events." } }
            plugin:marginaliaDebriefShow(3)
            assert.are.equal(0, #ui.calls.shown)
            assert.is_true(has(infos[1], "beyond your spoiler boundary"))
        end)
    end)

    describe("when the check does not pass: a warning, never a silent swap", function()
        it("flagged: nothing saved until the reader chooses; 'Show anyway' saves it as written", function()
            setup()
            queue(goodAnswer(), { flagged = { 1 } })
            plugin:marginaliaDebriefStart(2)
            assert.are.equal("flagged", ui.calls.warns[1].kind)
            assert.is_nil(store.marginalia_debriefs)
            assert.is_nil(store.marginalia_records)
            ui.calls.warns[1].handlers.show_anyway()
            assert.are.equal("The prince meets Rogozhin on the train.", store.marginalia_debriefs[2].in_brief)
            assert.is_not_nil(store.marginalia_records[2])
        end)

        it("'Write a new debrief' asks again; 'Cancel' keeps nothing and frees the next request", function()
            setup()
            queue(goodAnswer(), { flagged = { 1 } })
            plugin:marginaliaDebriefStart(2)
            queue(goodAnswer())
            ui.calls.warns[1].handlers.regenerate()
            assert.are.equal(2, #built)
            setup()
            queue(goodAnswer(), { flagged = { 1 } })
            plugin:marginaliaDebriefStart(2)
            ui.calls.warns[1].handlers.cancel()
            assert.is_nil(store.marginalia_debriefs)
            assert.is_nil(plugin._marginalia_debrief_busy)
        end)

        it("unchecked (no Claude key): warns", function()
            setup({ key = "" })
            replies = { { goodAnswer() } }
            plugin:marginaliaDebriefStart(2)
            assert.are.equal("unchecked", ui.calls.warns[1].kind)
            assert.is_nil(store.marginalia_debriefs)
        end)

        it("the check reads the whole debrief, the record included, but not the quotations", function()
            setup()
            local seen
            local orig = SpoilerCheck.buildPrompt
            SpoilerCheck.buildPrompt = function(items, ctx) seen = { items = items, ctx = ctx } return orig(items, ctx) end
            queue(goodAnswer())
            plugin:marginaliaDebriefStart(2)
            SpoilerCheck.buildPrompt = orig
            local texts = {}
            for _, item in ipairs(seen.items) do texts[item.text] = true end
            assert.is_true(texts["Myshkin meets Rogozhin on a train."])   -- the record's summary
            assert.is_true(texts["The prince meets Rogozhin on the train."])
            assert.is_nil(texts["I have not prepared my judgment"])      -- a quotation: already in the chapter
            assert.is_nil(texts["in the text"])                            -- a label
            assert.is_true(has(seen.ctx.position, "Three"))                -- how far the reader has got
        end)
    end)

    describe("when it cannot be made", function()
        it("says so if the AI fails or the answer is not a debrief, and saves nothing", function()
            setup()
            replies = { { false, "error_api", "HTTP 500" } }
            plugin:marginaliaDebriefStart(2)
            assert.is_true(has(infos[1], "HTTP 500"))
            setup()
            replies = { { { nonsense = true } } }
            plugin:marginaliaDebriefStart(2)
            assert.is_true(has(infos[1], "could not be read"))
            assert.is_nil(store.marginalia_debriefs)
            assert.is_nil(plugin._marginalia_debrief_busy)
        end)
    end)

    describe("the menu", function()
        it("lists chapters up to the boundary, and marks the debriefed ones", function()
            setup({ limit = { chapter = 2, frac = 1 } })
            store.marginalia_debriefs = { [1] = { in_brief = "x" } }
            plugin:marginaliaDebriefPick()
            local choices = ui.calls.picks[1].choices
            assert.are.equal(2, #choices)
            assert.is_true(has(choices[1].title, "(debriefed)"))
            assert.is_false(has(choices[2].title, "(debriefed)"))
        end)

        it("opening a chapter from the list shows or makes its debrief", function()
            setup()
            queue(goodAnswer())
            plugin:marginaliaDebriefPick()
            ui.calls.picks[1].on_pick({ index = 2 })
            assert.are.equal(1, #ui.calls.shown)
        end)

        it("says so when nothing has been read", function()
            setup({ limit = { chapter = 1, frac = 0 } })
            plugin.marginalia.chapterChoices = function() return {} end
            plugin:marginaliaDebriefPick()
            assert.is_true(has(infos[1], "not read any chapter"))
        end)

        it("has an entry that counts saved debriefs, and one that toggles the depth", function()
            setup()
            local items = plugin:marginaliaDebriefMenuItems()
            assert.are.equal("Debrief chapter", items[1].text_func())
            store.marginalia_debriefs = { [1] = { in_brief = "x" } }
            assert.are.equal("Debrief chapter (1 saved)", items[1].text_func())
            assert.are.equal("Debrief depth: Full", items[2].text_func())
            items[2].callback()
            assert.are.equal("Debrief depth: Quick", items[2].text_func())
            assert.are.equal("quick", helper.settings.marginalia_debrief_depth)
            items[2].callback()
            assert.are.equal("Debrief depth: Full", items[2].text_func())
        end)

        it("starts a debrief for the chapter just finished", function()
            setup()
            local started
            plugin.marginaliaDebriefStart = function(_, index) started = index end
            plugin:marginaliaDebriefAfterFinish(2)
            assert.are.equal(2, started)
            started = nil
            plugin:marginaliaDebriefAfterFinish("junk")
            assert.is_nil(started)
        end)
    end)
end)
