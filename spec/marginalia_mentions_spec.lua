-- Specs for "Mentions": snippets of book text saved inside X-Ray entities.
-- They must never reach past the confirmed boundary, even when the reader has
-- skimmed ahead of it, and saved ones from earlier must be trimmed on load.
require("spec.spec_helper")
package.path = "marginalia.koplugin/?.lua;" .. package.path

local Context = require("marginalia_context")
local analyzer = require("xray_chapteranalyzer")

local function mention(p) return { page = p, snippet = "secret " .. p, chapter = "c" } end

describe("mentions: Context.pruneMentions", function()
    local function data()
        return {
            characters = { { name = "A", mentions = { mention(2), mention(5), mention(9) }, last_mention_page = 9 } },
            locations = { { name = "L", mentions = { mention(3), { snippet = "no page" } }, last_mention_page = 3 } },
            terms = { { name = "T" } },
        }
    end

    it("removes mentions past the limit and keeps the rest", function()
        local d = data()
        assert.are.equal(2, Context.pruneMentions(d, 5)) -- page 9 and the page-less one
        local pages = {}
        for _, m in ipairs(d.characters[1].mentions) do pages[#pages + 1] = m.page end
        assert.are.same({ 2, 5 }, pages)
        assert.are.equal(1, #d.locations[1].mentions)
    end)

    it("pulls last_mention_page back so the gap is scanned later", function()
        local d = data()
        Context.pruneMentions(d, 5)
        assert.are.equal(5, d.characters[1].last_mention_page)
        assert.are.equal(3, d.locations[1].last_mention_page) -- already inside: untouched
    end)

    it("a limit of 0 removes every mention", function()
        local d = data()
        assert.are.equal(5, Context.pruneMentions(d, 0))
        assert.are.equal(0, #d.characters[1].mentions)
    end)

    it("does nothing without a usable limit, and never errors on odd data", function()
        local d = data()
        assert.are.equal(0, Context.pruneMentions(d, nil))
        assert.are.equal(3, #d.characters[1].mentions)
        assert.are.equal(0, Context.pruneMentions(nil, 5))
        assert.are.equal(0, Context.pruneMentions({ characters = { "x", { mentions = "bad" } } }, 5))
    end)
end)

describe("mentions: the scan stops at the boundary", function()
    local TOC = { { title = "One", page = 1 }, { title = "Two", page = 4 }, { title = "Three", page = 7 } }
    local ui = { document = { getPageCount = function() return 10 end } }
    local UIManager = require("ui/uimanager")
    local logger = require("logger")
    logger.error = function(...) io.stderr:write("SCANERR ", table.concat({ ... }, " "), "\n") end
    local orig, orig_schedule, queue

    before_each(function()
        -- the scan is a coroutine driven by timers: queue them, then run them in order
        queue = {}
        orig_schedule = UIManager.scheduleIn
        UIManager.scheduleIn = function(a, b, c)
            local fn = type(a) == "function" and a or type(b) == "function" and b or c
            queue[#queue + 1] = fn
        end
        orig = analyzer.findMentionsInChapter
        -- one mention on the first page of a chapter, one on the second, one on its last
        analyzer.findMentionsInChapter = function(_, _, _, entry, nxt)
            local last = (nxt and nxt.page or 11) - 1
            return { mention(entry.page), mention(entry.page + 1), mention(last) }
        end
    end)
    after_each(function()
        analyzer.findMentionsInChapter = orig
        analyzer.limit_provider = nil
        UIManager.scheduleIn = orig_schedule
    end)

    local function scan(max_page)
        local got
        analyzer:scanMentionsAsync(ui, { name = "A" }, TOC, nil, max_page, nil, function(m) got = m end)
        local guard = 0
        while #queue > 0 and guard < 1000 do
            guard = guard + 1
            table.remove(queue, 1)()
        end
        local top = 0
        for _, m in ipairs(got or {}) do top = math.max(top, m.page) end
        return got, top
    end

    it("without a gate, scans as far as the caller asked (upstream behaviour)", function()
        local _, top = scan(nil)
        assert.are.equal(10, top)
    end)

    it("with a gate, a caller asking for the whole book still stops at the limit", function()
        analyzer.limit_provider = function() return 5 end
        local got, top = scan(nil)
        assert.is_true(top <= 5)
        assert.is_true(#got > 0)
    end)

    it("with a gate, a caller asking for pages past the limit is held back", function()
        analyzer.limit_provider = function() return 5 end
        local _, top = scan(9) -- the reader has skimmed ahead to page 9
        assert.is_true(top <= 5)
    end)

    it("a caller asking for less than the limit keeps their smaller limit", function()
        analyzer.limit_provider = function() return 8 end
        local _, top = scan(3)
        assert.is_true(top <= 3)
    end)

    it("with a gate, chapters that start past the limit are not even searched", function()
        analyzer.limit_provider = function() return 5 end
        local searched = {}
        local inner = analyzer.findMentionsInChapter
        analyzer.findMentionsInChapter = function(self, u, e, entry, nxt)
            searched[#searched + 1] = entry.page
            return inner(self, u, e, entry, nxt)
        end
        scan(nil)
        for _, start in ipairs(searched) do assert.is_true(start <= 5) end
        assert.are.equal(2, #searched) -- chapters starting at pages 1 and 4
    end)

    it("a limit of 0 finds nothing", function()
        analyzer.limit_provider = function() return 0 end
        local got = scan(nil)
        assert.are.equal(0, #got)
    end)

    it("a broken gate fails closed", function()
        analyzer.limit_provider = function() error("boom") end
        local got = scan(nil)
        assert.are.equal(0, #got)
    end)

    it("a mention with no page cannot be placed, so it is dropped under a gate", function()
        analyzer.limit_provider = function() return 5 end
        analyzer.findMentionsInChapter = function() return { { snippet = "x" }, mention(2) } end
        local got = scan(nil)
        assert.is_true(#got > 0)
        for _, m in ipairs(got) do assert.is_not_nil(m.page) end
    end)
end)
