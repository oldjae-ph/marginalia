-- Specs for marginalia_context.lua: may saved X-Ray data be shown or sent?
package.path = "marginalia.koplugin/?.lua;" .. package.path

local Context = require("marginalia_context")

local function dataWith(extra)
    local d = { characters = { { name = "Alice" } }, last_fetch_page = 40 }
    for k, v in pairs(extra or {}) do d[k] = v end
    return d
end

describe("Context.compare", function()
    it("orders positions by chapter, then by fraction", function()
        assert.are.equal(-1, Context.compare({ chapter = 2, frac = 0.9 }, { chapter = 3, frac = 0 }))
        assert.are.equal(1, Context.compare({ chapter = 3, frac = 0.1 }, { chapter = 3, frac = 0 }))
        assert.are.equal(0, Context.compare({ chapter = 3, frac = 0.5 }, { chapter = 3, frac = 0.5 }))
    end)

    it("answers nil for unusable positions", function()
        assert.is_nil(Context.compare(nil, { chapter = 1, frac = 0 }))
        assert.is_nil(Context.compare({ chapter = 0, frac = 0 }, { chapter = 1, frac = 0 }))
        assert.is_nil(Context.compare({ chapter = 1, frac = 0 / 0 }, { chapter = 1, frac = 0 }))
        assert.is_nil(Context.compare("x", { chapter = 1, frac = 0 }))
    end)
end)

describe("Context.makeStamp", function()
    it("copies the boundary", function()
        local limit = { chapter = 4, frac = 0.25 }
        local stamp = Context.makeStamp(limit)
        assert.are.equal(4, stamp.chapter)
        assert.are.equal(0.25, stamp.frac)
        limit.chapter = 9 -- later changes to the boundary must not alter the stamp
        assert.are.equal(4, stamp.chapter)
    end)

    it("makes no stamp from a bad boundary", function()
        assert.is_nil(Context.makeStamp(nil))
        assert.is_nil(Context.makeStamp({ chapter = -1, frac = 0 }))
    end)
end)

describe("Context.hasContent", function()
    it("is false for empty or non-story data", function()
        assert.is_false(Context.hasContent(nil))
        assert.is_false(Context.hasContent({}))
        assert.is_false(Context.hasContent({ characters = {}, timeline = {}, author_info = { name = "x" } }))
    end)

    it("is true as soon as any story list has an entry", function()
        for _, key in ipairs({ "characters", "locations", "timeline", "historical_figures", "terms" }) do
            assert.is_true(Context.hasContent({ [key] = { { name = "x" } } }))
        end
    end)
end)

describe("Context.isTainted: stamped data", function()
    local limit = { chapter = 5, frac = 0.4 }

    it("is usable when made at or before the boundary", function()
        for _, stamp in ipairs({ { chapter = 5, frac = 0.4 }, { chapter = 5, frac = 0.1 }, { chapter = 2, frac = 1 } }) do
            local s = Context.makeStamp(stamp)
            assert.is_false(Context.isTainted(dataWith({ marginalia_boundary = s }), limit, 100))
        end
    end)

    it("is tainted when made under a later boundary (after a roll back)", function()
        for _, stamp in ipairs({ { chapter = 5, frac = 0.5 }, { chapter = 6, frac = 0 }, { chapter = 40, frac = 1 } }) do
            local s = Context.makeStamp(stamp)
            assert.is_true(Context.isTainted(dataWith({ marginalia_boundary = s }), limit, 100))
        end
    end)

    it("ignores last_fetch_page when a good stamp is present", function()
        local s = Context.makeStamp({ chapter = 5, frac = 0.1 })
        assert.is_false(Context.isTainted(dataWith({ marginalia_boundary = s, last_fetch_page = 9999 }), limit, 100))
    end)

    it("treats a damaged stamp as unknown, not as safe", function()
        for _, bad in ipairs({ "x", {}, { v = 99, chapter = 1, frac = 0 }, { v = 1, chapter = "1", frac = 0 }, { v = 1, chapter = 1 } }) do
            local d = dataWith({ marginalia_boundary = bad, last_fetch_page = 9999 })
            assert.is_true(Context.isTainted(d, limit, 100)) -- falls back to the page rule, which fails here
        end
    end)

    it("is tainted when the current boundary cannot be read", function()
        local s = Context.makeStamp({ chapter = 1, frac = 0 })
        assert.is_true(Context.isTainted(dataWith({ marginalia_boundary = s }), nil, 100))
    end)
end)

describe("Context.isTainted: data from before Marginalia (no stamp)", function()
    local limit = { chapter = 5, frac = 0.4 }

    it("is usable when it was fetched no further than the boundary", function()
        assert.is_false(Context.isTainted(dataWith({ last_fetch_page = 40 }), limit, 40))
        assert.is_false(Context.isTainted(dataWith({ last_fetch_page = 10 }), limit, 40))
    end)

    it("is tainted when it was fetched past the boundary", function()
        assert.is_true(Context.isTainted(dataWith({ last_fetch_page = 41 }), limit, 40))
        assert.is_true(Context.isTainted(dataWith({ last_fetch_page = 1315 }), limit, 40)) -- e.g. a whole-book fetch
    end)

    it("is tainted when nothing says how far it reaches", function()
        assert.is_true(Context.isTainted(dataWith({ last_fetch_page = false }), limit, 40))
        local d = dataWith(); d.last_fetch_page = nil
        assert.is_true(Context.isTainted(d, limit, 40))
    end)

    it("is tainted when the limit page cannot be worked out", function()
        assert.is_true(Context.isTainted(dataWith({ last_fetch_page = 10 }), limit, nil))
    end)

    it("an empty cache can never be tainted", function()
        assert.is_false(Context.isTainted({ last_fetch_page = 9999 }, limit, 0))
        assert.is_false(Context.isTainted({}, nil, nil))
        assert.is_false(Context.isTainted(nil, limit, 40))
    end)
end)
