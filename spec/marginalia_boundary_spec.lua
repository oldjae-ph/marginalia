-- Specs for marginalia_boundary.lua and marginalia_position.lua.
-- Uses only assertions that work in both busted and tools/spec_runner.lua.
package.path = "marginalia.koplugin/?.lua;" .. package.path

local Boundary = require("marginalia_boundary")
local Position = require("marginalia_position")

local STEP = 0.1 -- one page turn = 10% of the chapter in these tests

-- Read a chapter sequentially from `from` to `to` in page-turn steps.
local function read(b, chapter, from, to)
    local f = from
    while f < to - 1e-9 do
        f = math.min(f + STEP, to)
        b:update({ chapter = chapter, frac = f }, STEP)
    end
end

local function near(a, b) return math.abs(a - b) < 1e-6 end

describe("Boundary: sequential reading", function()
    it("starts at the beginning of the first chapter", function()
        local b = Boundary:new()
        assert.are.same({ chapter = 1, frac = 0 }, b:getLimit())
        assert.is_true(b:isAllowed({ chapter = 1, frac = 0 }))
        assert.is_false(b:isAllowed({ chapter = 1, frac = 0.1 }))
    end)

    it("advances one page turn at a time inside the confirmed chapter", function()
        local b = Boundary:new()
        read(b, 1, 0, 0.3)
        assert.is_true(near(0.3, b:getLimit().frac))
        assert.is_true(b:isAllowed({ chapter = 1, frac = 0.3 }))
        assert.is_false(b:isAllowed({ chapter = 1, frac = 0.4 }))
    end)

    it("ignores a forward jump inside the chapter", function()
        local b = Boundary:new()
        read(b, 1, 0, 0.1)
        local r = b:update({ chapter = 1, frac = 0.8 }, STEP)
        assert.is_nil(r.moved)
        assert.is_true(near(0.1, b:getLimit().frac))
    end)

    it("does not let reading after a jump drag the boundary along", function()
        local b = Boundary:new()
        read(b, 1, 0, 0.1)
        b:update({ chapter = 1, frac = 0.8 }, STEP) -- jump
        b:update({ chapter = 1, frac = 0.9 }, STEP) -- then reads on from there
        b:update({ chapter = 1, frac = 1.0 }, STEP)
        assert.is_true(near(0.1, b:getLimit().frac))
    end)

    it("ignores backward moves and never lowers the boundary", function()
        local b = Boundary:new()
        read(b, 1, 0, 0.5)
        b:update({ chapter = 1, frac = 0.2 }, STEP)
        assert.is_true(near(0.5, b:getLimit().frac))
    end)
end)

describe("Boundary: crossing chapters needs the reader", function()
    it("sets pending but does not move the confirmed boundary", function()
        local b = Boundary:new()
        read(b, 1, 0, 1.0)
        local r = b:update({ chapter = 2, frac = 0.05 }, STEP)
        assert.are.equal(2, r.pending)
        assert.are.equal(1, b:getConfirmedChapter())
        assert.are.equal(2, b:getPendingChapter())
        assert.is_false(b:isAllowed({ chapter = 2, frac = 0.05 }))
    end)

    it("treats a page shared by two chapters as the next chapter's first page", function()
        local b = Boundary:new()
        read(b, 1, 0, 0.9) -- last page of chapter 1 is not fully read yet
        local r = b:update({ chapter = 2, frac = 0.04 }, STEP)
        assert.are.equal(2, r.pending)
        assert.is_true(near(1, b:getLimit().frac))
        assert.are.equal(1, b:getConfirmedChapter())
    end)

    it("ignores a jump to the next chapter from the middle of this one", function()
        local b = Boundary:new()
        read(b, 1, 0, 0.3)
        local r = b:update({ chapter = 2, frac = 0.05 }, STEP)
        assert.is_nil(r.pending)
        assert.is_nil(b:getPendingChapter())
    end)

    it("ignores jumps several chapters ahead, even after many of them", function()
        local b = Boundary:new()
        read(b, 1, 0, 0.3)
        for ch = 3, 30 do
            b:update({ chapter = ch, frac = 0 }, STEP)
            b:update({ chapter = ch, frac = 0.1 }, STEP)
        end
        assert.are.equal(1, b:getConfirmedChapter())
        assert.is_nil(b:getPendingChapter())
        assert.is_true(near(0.3, b:getLimit().frac))
    end)

    it("moves only when the reader confirms", function()
        local b = Boundary:new()
        read(b, 1, 0, 1.0)
        b:update({ chapter = 2, frac = 0.05 }, STEP)
        assert.is_true(b:confirm(2))
        assert.are.equal(2, b:getConfirmedChapter())
        assert.is_true(near(0.05, b:getLimit().frac))
        assert.is_nil(b:getPendingChapter())
    end)

    it("keeps reading in the pending chapter out of bounds until confirmed", function()
        local b = Boundary:new()
        read(b, 1, 0, 1.0)
        b:update({ chapter = 2, frac = 0.05 }, STEP)
        b:update({ chapter = 2, frac = 0.15 }, STEP)
        b:update({ chapter = 2, frac = 0.25 }, STEP)
        assert.is_false(b:isAllowed({ chapter = 2, frac = 0.05 }))
        b:confirm()
        -- what was read in order while pending becomes allowed, nothing more
        assert.is_true(near(0.25, b:getLimit().frac))
        assert.is_false(b:isAllowed({ chapter = 2, frac = 0.5 }))
    end)

    it("does not track jumps inside the pending chapter", function()
        local b = Boundary:new()
        read(b, 1, 0, 1.0)
        b:update({ chapter = 2, frac = 0.05 }, STEP)
        b:update({ chapter = 2, frac = 0.7 }, STEP)
        b:confirm()
        assert.is_true(near(0.05, b:getLimit().frac))
    end)

    it("refuses to confirm with nothing pending or the wrong chapter", function()
        local b = Boundary:new()
        assert.is_false(b:confirm())
        read(b, 1, 0, 1.0)
        b:update({ chapter = 2, frac = 0.05 }, STEP)
        assert.is_false(b:confirm(3))
        assert.are.equal(1, b:getConfirmedChapter())
    end)

    it("re-offers the prompt when the reader comes back to the next chapter", function()
        local b = Boundary:new()
        read(b, 1, 0, 1.0)
        b:update({ chapter = 2, frac = 0.05 }, STEP)
        b:update({ chapter = 1, frac = 0.5 }, STEP) -- went back to re-read
        local r = b:update({ chapter = 2, frac = 0.05 }, STEP)
        assert.are.equal(2, r.pending)
        assert.are.equal(1, b:getConfirmedChapter())
    end)
end)

describe("Boundary: only the reader moves the boundary", function()
    it("never changes the confirmed chapter on update() (random walk)", function()
        math.randomseed(12345)
        local b = Boundary:new()
        read(b, 1, 0, 0.4)
        for _ = 1, 2000 do
            local before = b:getLimit()
            b:update({ chapter = math.random(1, 40), frac = math.random() }, STEP)
            assert.are.equal(1, b:getConfirmedChapter())
            -- the auto position can only grow by at most one page turn per update
            assert.is_true(b:getLimit().frac - before.frac <= STEP + 1e-6)
        end
    end)

    it("rolls back when the reader asks", function()
        local b = Boundary:new()
        b:setByReader(3, 0.5)
        assert.is_true(b:rollBack(2, 0.2))
        assert.are.same({ chapter = 2, frac = 0.2 }, b:getLimit())
        assert.is_false(b:isAllowed({ chapter = 3, frac = 0 }))
    end)

    it("refuses to 'roll back' forward", function()
        local b = Boundary:new()
        b:setByReader(2, 0.5)
        assert.is_false(b:rollBack(3, 0))
        assert.is_false(b:rollBack(2, 0.9))
        assert.are.same({ chapter = 2, frac = 0.5 }, b:getLimit())
    end)

    it("lets the reader set the boundary explicitly and clears pending", function()
        local b = Boundary:new()
        read(b, 1, 0, 1.0)
        b:update({ chapter = 2, frac = 0.05 }, STEP)
        assert.is_true(b:setByReader(5, 0.3))
        assert.are.same({ chapter = 5, frac = 0.3 }, b:getLimit())
        assert.is_nil(b:getPendingChapter())
    end)

    it("rejects nonsense from the reader-facing calls", function()
        local b = Boundary:new()
        assert.is_false(b:setByReader(0, 0.5))
        assert.is_false(b:setByReader(1.5, 0.5))
        assert.is_false(b:setByReader("2", 0.5))
        assert.is_false(b:setByReader(2, 0 / 0))
        assert.is_false(b:rollBack(nil, nil))
        assert.are.same({ chapter = 1, frac = 0 }, b:getLimit())
    end)
end)

describe("Boundary: front matter that carries no story", function()
    local function skippable(ch) return ch <= 2 end

    it("passes through skippable chapters without asking", function()
        local b = Boundary:new({ is_skippable = skippable })
        read(b, 1, 0, 1.0)
        local r = b:update({ chapter = 2, frac = 0.05 }, STEP)
        assert.is_true(r.auto_confirmed)
        assert.is_nil(r.pending)
        assert.are.equal(2, b:getConfirmedChapter())
    end)

    it("still asks before the first real chapter", function()
        local b = Boundary:new({ is_skippable = skippable })
        read(b, 1, 0, 1.0)
        b:update({ chapter = 2, frac = 0.05 }, STEP)
        read(b, 2, 0.05, 1.0)
        local r = b:update({ chapter = 3, frac = 0.05 }, STEP)
        assert.are.equal(3, r.pending)
        assert.are.equal(2, b:getConfirmedChapter())
    end)

    it("slides over an empty skippable chapter that shares a page", function()
        local b = Boundary:new({ is_skippable = skippable })
        read(b, 1, 0, 1.0)
        -- chapter 2 has no pages of its own, the page already belongs to chapter 3
        local r = b:update({ chapter = 3, frac = 0.05 }, STEP)
        assert.are.equal(3, r.pending)
        assert.are.equal(2, b:getConfirmedChapter())
    end)

    it("does not slide over skippable chapters on a jump", function()
        local b = Boundary:new({ is_skippable = skippable })
        read(b, 1, 0, 0.3)
        local r = b:update({ chapter = 3, frac = 0.05 }, STEP)
        assert.is_nil(r.pending)
        assert.are.equal(1, b:getConfirmedChapter())
    end)

    it("never slides over a chapter that is not skippable", function()
        local b = Boundary:new({ is_skippable = function(ch) return ch == 1 end })
        read(b, 1, 0, 1.0)
        local r = b:update({ chapter = 4, frac = 0.05 }, STEP)
        assert.is_nil(r.pending)
        assert.are.equal(1, b:getConfirmedChapter())
    end)
end)

describe("Boundary: bad input and saved state", function()
    it("ignores malformed positions", function()
        local b = Boundary:new()
        read(b, 1, 0, 0.3)
        for _, bad in ipairs({ "x", 5, { chapter = "1", frac = 0.5 }, { chapter = 1 },
            { chapter = 0, frac = 0.5 }, { chapter = 1.5, frac = 0.5 },
            { chapter = 1, frac = 0 / 0 }, { chapter = 1, frac = math.huge } }) do
            local r = b:update(bad, STEP)
            assert.is_true(r.ignored)
        end
        assert.is_true(near(0.3, b:getLimit().frac))
        assert.is_false(b:isAllowed(nil))
        assert.is_false(b:isAllowed({ chapter = 1 }))
    end)

    it("survives a save and load round trip", function()
        local b = Boundary:new()
        read(b, 1, 0, 1.0)
        b:update({ chapter = 2, frac = 0.05 }, STEP)
        local b2, ok = Boundary.fromTable(b:toTable())
        assert.is_true(ok)
        assert.are.same(b:getLimit(), b2:getLimit())
        assert.are.equal(2, b2:getPendingChapter())
    end)

    it("falls back to the start of the book on corrupt state", function()
        local good = Boundary:new()
        good:setByReader(7, 0.5)
        local saved = good:toTable()
        local cases = {
            "garbage", 42, {}, { version = 99 },
            { version = 1, confirmed_chapter = -3, auto_frac = 0.5 },
            { version = 1, confirmed_chapter = 7, auto_frac = 5 },
            { version = 1, confirmed_chapter = 7, auto_frac = 0 / 0 },
            { version = 1, confirmed_chapter = "7", auto_frac = 0.5 },
        }
        for _, c in ipairs(cases) do
            local b, ok = Boundary.fromTable(c)
            assert.is_false(ok)
            assert.are.same({ chapter = 1, frac = 0 }, b:getLimit())
        end
        -- and the good one is untouched by all that
        assert.are.equal(7, saved.confirmed_chapter)
    end)

    it("drops a pending chapter that is not the next one", function()
        local t = Boundary:new():toTable()
        t.confirmed_chapter = 3
        t.pending_chapter = 9
        t.pending_frac = 0.1
        local b, ok = Boundary.fromTable(t)
        assert.is_true(ok)
        assert.is_nil(b:getPendingChapter())
        assert.are.equal(3, b:getConfirmedChapter())
    end)
end)

describe("Position.fromPage", function()
    -- chapters start on pages 1, 11 and 31 of a 50 page book
    local toc = { { page = 1 }, { page = 11 }, { page = 31 } }

    it("maps a page to chapter and end-of-page fraction", function()
        local pos, step = Position.fromPage(toc, 5, 50)
        assert.are.equal(1, pos.chapter)
        assert.is_true(near(0.5, pos.frac)) -- end of page 5 = start of page 6 = 5/10
        assert.is_true(near(0.1, step))
    end)

    it("reaches 1.0 on the last page before the next chapter", function()
        local pos = Position.fromPage(toc, 10, 50)
        assert.are.equal(1, pos.chapter)
        assert.is_true(near(1, pos.frac))
    end)

    it("counts the page that starts a chapter as that chapter", function()
        local pos = Position.fromPage(toc, 11, 50)
        assert.are.equal(2, pos.chapter)
        assert.is_true(near(0.05, pos.frac))
    end)

    it("handles the last chapter using the total page count", function()
        local pos, step = Position.fromPage(toc, 50, 50)
        assert.are.equal(3, pos.chapter)
        assert.is_true(near(1, pos.frac))
        assert.is_true(near(1 / 20, step))
    end)

    it("returns nil for no TOC, bad pages or pages before the first entry", function()
        assert.is_nil(Position.fromPage(nil, 5, 50))
        assert.is_nil(Position.fromPage({}, 5, 50))
        assert.is_nil(Position.fromPage(toc, 0, 50))
        assert.is_nil(Position.fromPage(toc, 60, 50))
        assert.is_nil(Position.fromPage({ { page = 5 } }, 2, 50))
    end)

    it("copes with two TOC entries on the same page", function()
        local pos = Position.fromPage({ { page = 1 }, { page = 4 }, { page = 4 }, { page = 9 } }, 4, 20)
        assert.are.equal(3, pos.chapter)
    end)

    it("feeds the boundary correctly page by page, with no prompt mid-chapter", function()
        local b = Boundary:new()
        local prompted
        for page = 1, 10 do
            local pos, step = Position.fromPage(toc, page, 50)
            local r = b:update(pos, step)
            prompted = prompted or r.pending
        end
        assert.is_nil(prompted)
        assert.is_true(b:isAllowed({ chapter = 1, frac = 1 }))
        -- turning to page 11 asks about chapter 2 and stays out of bounds
        local pos, step = Position.fromPage(toc, 11, 50)
        local r = b:update(pos, step)
        assert.are.equal(2, r.pending)
        assert.is_false(b:isAllowed(pos))
    end)

    it("ignores a TOC jump to page 40 when fed page by page", function()
        local b = Boundary:new()
        for page = 1, 3 do b:update(Position.fromPage(toc, page, 50)) end
        local pos, step = Position.fromPage(toc, 40, 50)
        local r = b:update(pos, step)
        assert.is_nil(r.pending)
        assert.are.equal(1, b:getConfirmedChapter())
        assert.is_false(b:isAllowed(pos))
    end)
end)
