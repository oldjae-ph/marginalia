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
    local env = { saves = {}, asked_finished = {}, asked_initial = 0, toc = opts.toc or TOC, total = opts.total or TOTAL }
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
