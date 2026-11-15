-- Specs for marginalia_session.lua (glue between page events and the boundary).
-- All KOReader pieces are faked. Works in busted and tools/spec_runner.lua.
package.path = "marginalia.koplugin/?.lua;" .. package.path

local Session = require("marginalia_session")

-- A small book shaped like The Idiot: title, contents, part heading, then chapters.
local TOC = {
    { page = 1, title = "The Idiot" },
    { page = 2, title = "Contents" },
    { page = 3, title = "PART I" },
    { page = 4, title = "I." },
    { page = 14, title = "II." },
    { page = 30, title = "III." },
}
local TOTAL = 60

local function newEnv(opts)
    opts = opts or {}
    local env = { saves = {}, asked_finished = {}, asked_initial = 0, toc = opts.toc or TOC, total = opts.total or TOTAL,
        lowered = 0, settled = 0 }
    env.store = {
        data = opts.saved,
        load = function() return env.store.data end,
        save = function(t, flush)
            if opts.save_error then error("disk full") end
            env.store.data = t
            env.saves[#env.saves + 1] = { flush = flush }
        end,
    }
    env.prompter = {
        askFinished = function(title, yes, no)
            env.asked_finished[#env.asked_finished + 1] = { title = title, yes = yes, no = no }
        end,
        askInitial = function(here, start)
            env.asked_initial = env.asked_initial + 1
            env.initial = { here = here, start = start }
        end,
    }
    env.session = Session:new({
        get_toc = function()
            if opts.no_toc then return nil end
            return env.toc, env.total
        end,
        store = env.store,
        prompter = env.prompter,
        book_title = "The Idiot",
        is_nonnarrative = function(t) return t:lower() == "contents" end,
        on_lowered = function() env.lowered = env.lowered + 1 end,
        on_settled = function() env.settled = env.settled + 1 end,
    })
    return env
end

local function readPages(env, from, to)
    for p = from, to do env.session:onPageUpdate(p) end
end

local function lastAsked(env) return env.asked_finished[#env.asked_finished] end

describe("Session.isSkippableTitle", function()
    local function skip(t) return Session.isSkippableTitle(t, "The Idiot", function(x) return x:lower() == "contents" end) end

    it("skips front matter, the book title and bare part headings", function()
        for _, t in ipairs({ "Contents", "The Idiot", "the idiot", "PART I", "Part Two", "Part 3",
            "Part Two: The Journey", "Book One", "BOOK II.", "Volume 2", "", "   " }) do
            assert.is_true(skip(t))
        end
    end)

    it("keeps real chapters, including ones that merely start with 'part'", function()
        for _, t in ipairs({ "I.", "III.", "Chapter 3", "Part of the Plan", "Partners in Crime",
            "A Part Apart", "Booked Solid", "The Hound" }) do
            assert.is_false(skip(t))
        end
    end)
end)

describe("Session: starting", function()
    it("does not ask when the book is opened at the front", function()
        local env = newEnv()
        env.session:start(1)
        assert.are.equal(0, env.asked_initial)
        assert.are.same({ chapter = 1, frac = 0 }, env.session:getLimit())
        assert.is_true(#env.saves >= 1) -- fresh state written so we never ask again
    end)

    it("does not ask on the first pages of the first story chapter", function()
        local env = newEnv()
        env.session:start(4)
        assert.are.equal(0, env.asked_initial)
    end)

    it("asks where the reader is when a book is opened mid-way", function()
        local env = newEnv()
        env.session:start(20)
        assert.are.equal(1, env.asked_initial)
        -- until answered, nothing past the start is allowed
        assert.are.same({ chapter = 1, frac = 0 }, env.session:getLimit())
    end)

    it("'I've read up to here' sets the boundary at the end of that page and saves it", function()
        local env = newEnv()
        env.session:start(20)
        env.initial.here()
        local limit = env.session:getLimit()
        assert.are.equal(5, limit.chapter) -- "II." is the 5th TOC entry
        assert.is_true(math.abs(limit.frac - (20 + 1 - 14) / 16) < 1e-6)
        assert.is_true(env.saves[#env.saves].flush)
    end)

    it("'Start of the book' keeps the boundary at the start and does not ask again", function()
        local env = newEnv()
        env.session:start(20)
        env.initial.start()
        assert.are.same({ chapter = 1, frac = 0 }, env.session:getLimit())
        local env2 = newEnv({ saved = env.store.data })
        env2.session:start(20)
        assert.are.equal(0, env2.asked_initial)
    end)

    it("restores a saved boundary without asking", function()
        local env = newEnv()
        env.session:start(20)
        env.initial.here()
        local env2 = newEnv({ saved = env.store.data })
        env2.session:start(25)
        assert.are.equal(0, env2.asked_initial)
        assert.are.same(env.session:getLimit(), env2.session:getLimit())
    end)

    it("treats unreadable saved state like a first open", function()
        local env = newEnv({ saved = { version = 99, junk = true } })
        env.session:start(20)
        assert.are.equal(1, env.asked_initial)
        assert.are.same({ chapter = 1, frac = 0 }, env.session:getLimit())
    end)

    it("does nothing, and does not crash, without a table of contents", function()
        local env = newEnv({ no_toc = true })
        env.session:start(20)
        env.session:onPageUpdate(21)
        assert.are.equal(0, env.asked_initial)
        assert.are.equal(0, #env.asked_finished)
    end)

    it("ignores page events before start()", function()
        local env = newEnv()
        env.session:onPageUpdate(10)
        assert.are.equal(0, #env.asked_finished)
        assert.is_nil(env.session:getLimit())
    end)
end)

describe("Session: reading and the chapter-end question", function()
    it("never asks about front matter, and asks about each real chapter change", function()
        local env = newEnv()
        env.session:start(1)
        readPages(env, 1, 13)
        assert.are.equal(0, #env.asked_finished) -- title, contents, part heading, chapter I: no question
        env.session:onPageUpdate(14) -- first page of II.
        assert.are.equal(1, #env.asked_finished)
        assert.are.equal("I.", lastAsked(env).title)
    end)

    it("moves the boundary only when the reader says yes", function()
        local env = newEnv()
        env.session:start(1)
        readPages(env, 1, 14)
        local before = env.session:getLimit()
        assert.are.equal(4, before.chapter) -- still chapter I. (index 4)
        lastAsked(env).yes()
        assert.are.equal(5, env.session:getLimit().chapter)
        assert.is_true(env.saves[#env.saves].flush)
    end)

    it("does not move the boundary when the reader says not yet, and does not nag", function()
        local env = newEnv()
        env.session:start(1)
        readPages(env, 1, 14)
        lastAsked(env).no()
        readPages(env, 15, 20)
        assert.are.equal(1, #env.asked_finished)
        assert.are.equal(4, env.session:getLimit().chapter)
    end)

    it("asks again when the reader goes back and crosses into the chapter again", function()
        local env = newEnv()
        env.session:start(1)
        readPages(env, 1, 14)
        lastAsked(env).no()
        env.session:onPageUpdate(13) -- back to the end of chapter I
        env.session:onPageUpdate(14)
        assert.are.equal(2, #env.asked_finished)
    end)

    it("does not open a second question while one is showing", function()
        local env = newEnv()
        env.session:start(1)
        readPages(env, 1, 14)
        readPages(env, 15, 18)
        assert.are.equal(1, #env.asked_finished)
    end)

    it("ignores jumps: no question, boundary unchanged", function()
        local env = newEnv()
        env.session:start(1)
        readPages(env, 1, 6)
        local before = env.session:getLimit()
        env.session:onPageUpdate(50) -- TOC / endnote / flip ahead
        env.session:onPageUpdate(51)
        env.session:onPageUpdate(52)
        assert.are.equal(0, #env.asked_finished)
        assert.are.same(before, env.session:getLimit())
    end)

    it("ignores a jump to the very next chapter from mid-chapter", function()
        local env = newEnv()
        env.session:start(1)
        readPages(env, 1, 7)
        env.session:onPageUpdate(14)
        assert.are.equal(0, #env.asked_finished)
        assert.are.equal(4, env.session:getLimit().chapter)
    end)

    it("a late 'yes' after the reader jumped around cannot move an unrelated boundary", function()
        local env = newEnv()
        env.session:start(1)
        readPages(env, 1, 14)
        local q = lastAsked(env)
        env.session:setBoundaryAtPage(6) -- reader resets the boundary before answering
        q.yes()
        assert.are.equal(4, env.session:getLimit().chapter)
    end)

    it("saves progress without forcing a disk write on every page turn", function()
        local env = newEnv()
        env.session:start(1)
        readPages(env, 1, 4) -- front matter and the first story page (these do force saves)
        local n = #env.saves
        readPages(env, 5, 8) -- ordinary page turns inside chapter I
        assert.is_true(#env.saves > n)
        for i = n + 1, #env.saves do assert.is_false(env.saves[i].flush) end
    end)

    it("survives a failing save", function()
        local env = newEnv({ save_error = true })
        env.session:start(1)
        readPages(env, 1, 14)
        assert.are.equal(1, #env.asked_finished)
    end)
end)

describe("Session: the limit page", function()
    it("is nil before the session has started", function()
        assert.is_nil(newEnv().session:getLimitPage())
    end)

    it("follows sequential reading page by page", function()
        local env = newEnv()
        env.session:start(1)
        readPages(env, 1, 8)
        assert.are.equal(8, env.session:getLimitPage())
    end)

    it("does not move on a jump", function()
        local env = newEnv()
        env.session:start(1)
        readPages(env, 1, 6)
        env.session:onPageUpdate(50)
        env.session:onPageUpdate(51)
        assert.are.equal(6, env.session:getLimitPage())
    end)

    it("stays at the end of the chapter until the reader confirms the next one", function()
        local env = newEnv()
        env.session:start(1)
        readPages(env, 1, 14) -- crosses into chapter II
        assert.are.equal(13, env.session:getLimitPage())
        lastAsked(env).yes()
        assert.are.equal(14, env.session:getLimitPage())
    end)

    it("is nil (nothing allowed) when there is no table of contents", function()
        local env = newEnv({ no_toc = true })
        env.session:start(1)
        assert.is_nil(env.session:getLimitPage())
    end)

    it("does not grow when the font size changes", function()
        local env = newEnv()
        env.session:start(1)
        readPages(env, 1, 8)
        env.toc = {
            { page = 1, title = "The Idiot" }, { page = 3, title = "Contents" },
            { page = 5, title = "PART I" }, { page = 7, title = "I." },
            { page = 27, title = "II." }, { page = 59, title = "III." },
        }
        env.total = 120
        -- twice as many pages for the same text: the boundary moves with the text,
        -- so the limit page about doubles but covers the same words
        local limit = env.session:getLimitPage()
        assert.is_true(limit >= 15 and limit <= 17)
    end)
end)

describe("Session: reader-initiated changes", function()
    it("sets the boundary where the reader says", function()
        local env = newEnv()
        env.session:start(1)
        assert.is_true(env.session:setBoundaryAtPage(20))
        assert.are.equal(5, env.session:getLimit().chapter)
    end)

    it("rolls back but refuses to roll forward", function()
        local env = newEnv()
        env.session:start(1)
        env.session:setBoundaryAtPage(35)
        assert.is_true(env.session:rollBackToPage(16))
        assert.are.equal(5, env.session:getLimit().chapter)
        assert.is_false(env.session:rollBackToPage(40))
        assert.are.equal(5, env.session:getLimit().chapter)
    end)

    it("cannot be moved forward by reading in a different font size", function()
        local env = newEnv()
        env.session:start(1)
        env.session:setBoundaryAtPage(20) -- chapter II, 7/16 through
        local before = env.session:getLimit()
        -- bigger font: everything takes twice as many pages
        env.toc = {
            { page = 1, title = "The Idiot" }, { page = 3, title = "Contents" },
            { page = 5, title = "PART I" }, { page = 7, title = "I." },
            { page = 27, title = "II." }, { page = 59, title = "III." },
        }
        env.total = 120
        env.session:onPageUpdate(60) -- somewhere in chapter III
        assert.are.same(before, env.session:getLimit())
    end)
end)

describe("Session: describing the boundary", function()
    it("is nil before the session has started", function()
        assert.is_nil(newEnv().session:describe())
    end)

    it("says 'start of the book' (no title) at the very start", function()
        local env = newEnv()
        env.session:start(1)
        local d = env.session:describe()
        assert.is_true(d.settled)
        assert.is_nil(d.title)
    end)

    it("names the chapter and how far through it, skipping front matter", function()
        local env = newEnv()
        env.session:start(1)
        readPages(env, 1, 8)
        local d = env.session:describe()
        assert.are.equal("I.", d.title)
        assert.are.equal(50, d.percent) -- end of page 8 = 5 of 10 pages into chapter I
    end)

    it("is not settled while the first-open question is showing", function()
        local env = newEnv()
        env.session:start(20)
        assert.is_false(env.session:describe().settled)
    end)
end)

describe("Session: planning and applying reader changes", function()
    it("plans a move to the end of a page and says whether it goes back", function()
        local env = newEnv()
        env.session:start(1)
        local forward = env.session:planAtPage(20)
        assert.are.equal(5, forward.chapter)
        assert.is_false(forward.lowers)
        assert.is_false(forward.same)
        env.session:apply(forward)
        assert.is_true(env.session:planAtPage(8).lowers)
        assert.is_true(env.session:planAtPage(20).same)
    end)

    it("plans nothing it cannot place", function()
        local env = newEnv()
        env.session:start(1)
        assert.is_nil(env.session:planAtPage(0))
        assert.is_nil(env.session:planAtPage(999))
        assert.is_nil(env.session:planAtChapterEnd(99))
        assert.is_nil(env.session:planAtChapterEnd("x"))
        assert.is_nil(newEnv().session:planAtPage(5)) -- not started
        assert.is_nil(newEnv({ no_toc = true }).session:planAtPage(5))
    end)

    it("plans 'I have finished chapter N' as the end of that chapter", function()
        local env = newEnv()
        env.session:start(1)
        local plan = env.session:planAtChapterEnd(5)
        assert.are.equal(5, plan.chapter)
        assert.are.equal(1, plan.frac)
        assert.are.equal("II.", plan.title)
    end)

    it("plans the start of the book", function()
        local env = newEnv()
        env.session:start(1)
        assert.is_true(env.session:planAtStart().same)
        env.session:apply(env.session:planAtChapterEnd(5))
        local plan = env.session:planAtStart()
        assert.is_true(plan.lowers)
        assert.are.equal(1, plan.chapter)
        assert.are.equal(0, plan.frac)
    end)

    it("changes nothing until a plan is applied", function()
        local env = newEnv()
        env.session:start(1)
        local before = env.session:getLimit()
        env.session:planAtPage(20); env.session:planAtChapterEnd(5); env.session:planAtStart()
        assert.are.same(before, env.session:getLimit())
    end)

    it("applying a forward plan moves the boundary, saves it, and does not announce 'lowered'", function()
        local env = newEnv()
        env.session:start(1)
        assert.is_true(env.session:apply(env.session:planAtChapterEnd(5)))
        assert.are.same({ chapter = 5, frac = 1 }, env.session:getLimit())
        assert.is_true(env.saves[#env.saves].flush)
        assert.are.equal(0, env.lowered)
    end)

    it("applying a plan that goes back announces 'lowered'", function()
        local env = newEnv()
        env.session:start(1)
        env.session:apply(env.session:planAtChapterEnd(6))
        assert.is_true(env.session:apply(env.session:planAtPage(8)))
        assert.are.equal(1, env.lowered)
    end)

    it("refuses garbage plans", function()
        local env = newEnv()
        env.session:start(1)
        assert.is_false(env.session:apply(nil))
        assert.is_false(env.session:apply("x"))
        assert.is_false(env.session:apply({ chapter = 0, frac = 0.5 }))
        assert.is_false(env.session:apply({ chapter = 2, frac = 0 / 0 }))
        assert.is_false(newEnv().session:apply({ chapter = 2, frac = 0.5 })) -- not started
        assert.are.same({ chapter = 1, frac = 0 }, env.session:getLimit())
    end)

    it("a choice from the menu settles an unanswered first-open question, and the late answer cannot undo it", function()
        local env = newEnv()
        env.session:start(20) -- question showing
        assert.is_false(env.session:isSettled())
        assert.is_true(env.session:apply(env.session:planAtChapterEnd(4)))
        assert.is_true(env.session:isSettled())
        assert.are.equal(1, env.settled)
        env.initial.here() -- the reader taps the old question afterwards
        assert.are.same({ chapter = 4, frac = 1 }, env.session:getLimit())
        env.initial.start()
        assert.are.same({ chapter = 4, frac = 1 }, env.session:getLimit())
    end)
end)

describe("Session: chapter choices", function()
    it("lists real chapters only and marks the current one", function()
        local env = newEnv()
        env.session:start(1)
        readPages(env, 1, 8)
        local list = env.session:chapterChoices()
        local titles = {}
        for _, c in ipairs(list) do titles[#titles + 1] = c.title end
        assert.are.same({ "I.", "II.", "III." }, titles)
        assert.is_true(list[1].is_current)
        assert.is_false(list[2].is_current)
        assert.are.equal(4, list[1].index) -- index in the table of contents
    end)

    it("is empty without a session or a table of contents", function()
        assert.are.same({}, newEnv().session:chapterChoices())
        local env = newEnv({ no_toc = true })
        env.session:start(1)
        assert.are.same({}, env.session:chapterChoices())
    end)

    it("gives untitled chapters a name", function()
        local env = newEnv({ toc = { { page = 1, title = "Intro chapter" }, { page = 10, title = "  " }, { page = 20, title = "Three" } }, total = 30 })
        env.session:start(1)
        local list = env.session:chapterChoices()
        assert.is_true(#list >= 2)
        for _, c in ipairs(list) do assert.is_true(c.title ~= "") end
    end)
end)
