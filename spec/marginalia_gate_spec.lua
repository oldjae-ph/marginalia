-- Specs for the spoiler gate: marginalia_limit.lua and the guards added to
-- xray_chapteranalyzer.lua. A fake 10-page book carries a unique marker on every
-- page (SECRET1 ... SECRET10); with a limit of L, no marker above L may ever come out.
require("spec.spec_helper")
package.path = "marginalia.koplugin/?.lua;" .. package.path

local Limit = require("marginalia_limit")
local Position = require("marginalia_position")
local analyzer = require("xray_chapteranalyzer")

local PAGES = 10
-- chapters: 1 = pages 1-3, 2 = pages 4-6, 3 = pages 7-10
local TOC_ENTRIES = { { title = "One", page = 1 }, { title = "Two", page = 4 }, { title = "Three", page = 7 } }

local function pageText(p)
    -- long enough that chapter samples (which skip short text) include it
    return string.format("[page %d] SECRET%d %s ", p, p, string.rep("lorem ipsum dolor sit amet ", 4))
end

local function makeUi(opts)
    opts = opts or {}
    local live_page = opts.live_page or 1
    local toc = {}
    for _, e in ipairs(opts.toc or TOC_ENTRIES) do
        toc[#toc + 1] = { title = e.title, page = e.page, xpointer = e.page and ("xp:" .. e.page) or nil }
    end
    local doc = {
        getPageCount = function() return PAGES end,
        getToc = function() return toc end,
        getXPointer = function() return "xp:" .. live_page end,
        gotoXPointer = function() end,
        gotoPage = function() end,
        getPageXPointer = function(_, p) return "xp:" .. math.max(1, math.min(p, PAGES + 1)) end,
        getEndXPointer = function() return "xp:" .. (PAGES + 1) end,
        getPageFromXPointer = function(_, xp) return tonumber(tostring(xp):match("^xp:(%d+)")) end,
        -- end XPointer is the START of its page, so the range stops before that page
        getTextFromXPointers = function(_, a, b)
            local pa = tonumber(a:match("^xp:(%d+)"))
            local pb = tonumber(b:match("^xp:(%d+)"))
            local out = {}
            for p = pa, math.min(pb - 1, PAGES) do out[#out + 1] = pageText(p) end
            return table.concat(out)
        end,
    }
    return {
        rolling = {},
        document = doc,
        getCurrentPage = function() return live_page end,
        annotation = { annotations = opts.annotations },
    }
end

local function maxMarker(text)
    local top = 0
    for n in tostring(text or ""):gmatch("SECRET(%d+)") do top = math.max(top, tonumber(n)) end
    return top
end

describe("gate: Limit.lastAllowedPage", function()
    local toc = { { page = 1 }, { page = 11 }, { page = 31 } }

    it("is the exact inverse of Position.fromPage for every page", function()
        for page = 1, 50 do
            local pos = Position.fromPage(toc, page, 50)
            assert.are.equal(page, Limit.lastAllowedPage(toc, pos, 50))
        end
    end)

    it("allows nothing at the very start of a chapter", function()
        assert.are.equal(10, Limit.lastAllowedPage(toc, { chapter = 2, frac = 0 }, 50))
        assert.are.equal(0, Limit.lastAllowedPage(toc, { chapter = 1, frac = 0 }, 50))
    end)

    it("rounds down, so repagination can only hide text", function()
        -- 7/16 of chapter II (pages 11-30, size 20) = 8.75 pages in -> page 18, not 19
        assert.are.equal(18, Limit.lastAllowedPage(toc, { chapter = 2, frac = 0.4375 }, 50))
    end)

    it("never goes past the end of the chapter or the book", function()
        assert.are.equal(30, Limit.lastAllowedPage(toc, { chapter = 2, frac = 1 }, 50))
        assert.are.equal(50, Limit.lastAllowedPage(toc, { chapter = 3, frac = 1 }, 50))
    end)

    it("answers nil (meaning: nothing allowed) when it cannot tell", function()
        assert.is_nil(Limit.lastAllowedPage(nil, { chapter = 1, frac = 0 }, 50))
        assert.is_nil(Limit.lastAllowedPage(toc, nil, 50))
        assert.is_nil(Limit.lastAllowedPage(toc, { chapter = 9, frac = 0 }, 50))
        assert.is_nil(Limit.lastAllowedPage(toc, { chapter = 0, frac = 0 }, 50))
        assert.is_nil(Limit.lastAllowedPage(toc, { chapter = 1, frac = 0 / 0 }, 50))
        assert.is_nil(Limit.lastAllowedPage(toc, { chapter = 1, frac = 0.5 }, 0))
        assert.is_nil(Limit.lastAllowedPage({ {} }, { chapter = 1, frac = 0.5 }, 50))
    end)
end)

describe("gate: text extraction never passes the limit", function()
    local function withLimit(value)
        analyzer.limit_provider = type(value) == "function" and value or function() return value end
    end

    after_each(function() analyzer.limit_provider = nil end)

    it("leaves upstream behaviour alone when no limit is set (control)", function()
        local ui = makeUi()
        assert.are.equal(10, maxMarker(analyzer:getTextFromPageRange(ui, 1, 11, 100000)))
    end)

    it("getTextFromPageRange stops at the limit", function()
        withLimit(5)
        local text = analyzer:getTextFromPageRange(makeUi(), 1, 11, 100000)
        assert.are.equal(5, maxMarker(text))
    end)

    it("getTextFromPageRange returns nothing when the range starts past the limit", function()
        withLimit(5)
        assert.is_nil(analyzer:getTextFromPageRange(makeUi(), 6, 9, 100000))
        withLimit(0)
        assert.is_nil(analyzer:getTextFromPageRange(makeUi(), 1, 9, 100000))
    end)

    it("fails closed when the limit provider errors or answers nonsense", function()
        for _, bad in ipairs({ function() error("boom") end, function() return "x" end, function() return nil end }) do
            withLimit(bad)
            assert.is_nil(analyzer:getTextFromPageRange(makeUi(), 1, 9, 100000))
            assert.are.equal("", analyzer:getSingleChapterText(makeUi(), { page = 1, xpointer = "xp:1" }, { page = 4, xpointer = "xp:4" }, nil, 50000))
        end
    end)

    it("getTextForAnalysis clamps an explicit end page", function()
        withLimit(5)
        local text = analyzer:getTextForAnalysis(makeUi(), 100000, nil, 11)
        assert.are.equal(5, maxMarker(text))
    end)

    it("getTextForAnalysis treats 'no page' as the reader's real page, then clamps", function()
        withLimit(5)
        assert.are.equal(5, maxMarker(analyzer:getTextForAnalysis(makeUi({ live_page = 9 }), 100000, nil, nil)))
        -- a reader behind the limit is still held to where they are
        assert.is_true(maxMarker(analyzer:getTextForAnalysis(makeUi({ live_page = 3 }), 100000, nil, nil)) <= 4)
    end)

    it("getTextForAnalysis distrusts an XPointer past the limit", function()
        withLimit(5)
        local text = analyzer:getTextForAnalysis(makeUi(), 100000, nil, nil, nil, "xp:8")
        assert.are.equal(5, maxMarker(text))
    end)

    it("getTextForAnalysis distrusts an XPointer it cannot place", function()
        withLimit(5)
        local text = analyzer:getTextForAnalysis(makeUi(), 100000, nil, nil, nil, "garbage")
        assert.are.equal(5, maxMarker(text))
    end)

    it("getTextForAnalysis still honours an XPointer inside the limit", function()
        withLimit(5)
        local text = analyzer:getTextForAnalysis(makeUi(), 100000, nil, nil, nil, "xp:3")
        assert.is_true(maxMarker(text) <= 2)
    end)

    it("getSingleChapterText returns nothing for a chapter past the limit or of unknown position", function()
        withLimit(5)
        local ui = makeUi()
        assert.are.equal("", analyzer:getSingleChapterText(ui, { page = 7, xpointer = "xp:7" }, nil, nil, 50000))
        assert.are.equal("", analyzer:getSingleChapterText(ui, { title = "no page", xpointer = "xp:7" }, nil, nil, 50000))
    end)

    it("getSingleChapterText cuts a chapter that straddles the limit", function()
        withLimit(5)
        local text = analyzer:getSingleChapterText(makeUi(), { page = 4, xpointer = "xp:4" }, { page = 7, xpointer = "xp:7" }, nil, 50000)
        assert.are.equal(5, maxMarker(text))
        assert.is_true(text:find("SECRET4", 1, true) ~= nil)
    end)

    it("getSingleChapterText still returns a finished chapter in full", function()
        withLimit(5)
        local text = analyzer:getSingleChapterText(makeUi(), { page = 1, xpointer = "xp:1" }, { page = 4, xpointer = "xp:4" }, nil, 50000)
        assert.are.equal(3, maxMarker(text))
        assert.is_true(text:find("SECRET1", 1, true) ~= nil)
    end)

    it("getSingleChapterText ignores a caller's page that is past the limit", function()
        withLimit(5)
        local text = analyzer:getSingleChapterText(makeUi(), { page = 4, xpointer = "xp:4" }, { page = 7, xpointer = "xp:7" }, 9, 50000)
        assert.are.equal(5, maxMarker(text))
    end)

    it("getSingleChapterText returns nothing for a chapter ahead of the caller's page", function()
        withLimit(9)
        local text = analyzer:getSingleChapterText(makeUi(), { page = 4, xpointer = "xp:4" }, { page = 7, xpointer = "xp:7" }, 2, 50000)
        assert.are.equal("", text)
    end)

    it("getSingleChapterText cuts a segment with its own end page at the limit", function()
        local segment = { page = 4, end_page = 8, xpointer = "xp:4" }
        local unlimited = analyzer:getSingleChapterText(makeUi(), segment, nil, nil, 50000)
        assert.is_true(maxMarker(unlimited) >= 7) -- the control really does run on to the segment's end
        withLimit(5)
        assert.are.equal(5, maxMarker(analyzer:getSingleChapterText(makeUi(), segment, nil, nil, 50000)))
        withLimit(10) -- a generous limit changes nothing
        assert.are.equal(unlimited, analyzer:getSingleChapterText(makeUi(), segment, nil, nil, 50000))
    end)

    it("chapter samples never include text past the limit, even when asked for the whole book", function()
        withLimit(5)
        local samples = analyzer:getDetailedChapterSamples(makeUi(), 200, 150000, true, nil, nil, nil, nil)
        assert.is_not_nil(samples)
        assert.is_true(maxMarker(samples) <= 5)
        assert.is_nil(samples:find("CHAPTER [Three]", 1, true))
    end)

    it("whole-book samples DO include later chapters with no limit (control)", function()
        local samples = analyzer:getDetailedChapterSamples(makeUi(), 200, 150000, true, nil, nil, nil, nil)
        assert.is_true(maxMarker(samples) > 5)
    end)

    it("chapter samples skip a TOC entry whose position is unknown", function()
        withLimit(8)
        local toc = { { title = "One", page = 1 }, { title = "Mystery chapter" }, { title = "Three", page = 7 } }
        local samples = analyzer:getDetailedChapterSamples(makeUi({ toc = toc }), 200, 150000, false, nil, nil, 8, nil)
        assert.is_nil(samples and samples:find("Mystery chapter", 1, true))
    end)

    it("annotations past the limit, or with no page, are left out", function()
        withLimit(5)
        local ui = makeUi({ annotations = {
            { page = 2, text = "early highlight" },
            { page = 8, text = "late highlight" },
            { text = "highlight of unknown page" },
        } })
        local out = analyzer:getAnnotationsForAnalysis(ui, 9)
        assert.is_true(out:find("early highlight", 1, true) ~= nil)
        assert.is_nil(out:find("late highlight", 1, true))
        assert.is_nil(out:find("unknown page", 1, true))
    end)

    it("annotations: upstream behaviour is unchanged with no limit (control)", function()
        local ui = makeUi({ annotations = { { page = 2, text = "early" }, { text = "unknown" } } })
        local out = analyzer:getAnnotationsForAnalysis(ui, 9)
        assert.is_true(out:find("unknown", 1, true) ~= nil)
    end)

    it("holds for every limit and every way of asking (sweep)", function()
        for limit = 0, PAGES do
            withLimit(limit)
            local ui = makeUi({ live_page = 10 })
            for end_page = 1, PAGES + 2 do
                assert.is_true(maxMarker(analyzer:getTextFromPageRange(ui, 1, end_page, 100000)) <= limit)
                assert.is_true(maxMarker(analyzer:getTextForAnalysis(ui, 100000, nil, end_page)) <= limit)
            end
            assert.is_true(maxMarker(analyzer:getTextForAnalysis(ui, 100000, nil, nil)) <= limit)
            for _, ch in ipairs({
                { { page = 1, xpointer = "xp:1" }, { page = 4, xpointer = "xp:4" } },
                { { page = 4, xpointer = "xp:4" }, { page = 7, xpointer = "xp:7" } },
                { { page = 7, xpointer = "xp:7" }, nil },
            }) do
                for _, cur in ipairs({ -1, 1, 5, 10 }) do
                    local text = analyzer:getSingleChapterText(ui, ch[1], ch[2], cur > 0 and cur or nil, 50000)
                    local top = maxMarker(text)
                    if top > limit then
                        error(string.format("leak: limit=%d chapter starting page %d, caller page %s -> text reached page %d",
                            limit, ch[1].page, tostring(cur > 0 and cur or nil), top))
                    end
                end
            end
            assert.is_true(maxMarker(analyzer:getDetailedChapterSamples(ui, 200, 150000, true)) <= limit)
            assert.is_true(maxMarker(analyzer:getDetailedChapterSamples(ui, 200, 150000, false, nil, nil, 10)) <= limit)
        end
    end)
end)
