-- Series context copies what EARLIER books said into the book being read. It must
-- only use entries made from the reader's own X-Ray data and stamped with how far
-- they read; AI summaries from the model's memory and unstamped data are out.
require("spec.spec_helper")
package.path = "marginalia.koplugin/?.lua;" .. package.path

local Context = require("marginalia_context")
local SeriesManager = require("xray_seriesmanager")
local XRayPlugin = dofile("marginalia.koplugin/main.lua")

local STAMP = { v = 1, chapter = 3, frac = 0.5 }

describe("series: Context.isTrustedSeriesBook", function()
    it("trusts the reader's own X-Ray data that carries a stamp", function()
        assert.is_true(Context.isTrustedSeriesBook({ source = "local_xray", marginalia_boundary = STAMP }))
        assert.is_true(Context.isTrustedSeriesBook({ marginalia_boundary = STAMP })) -- source not recorded
    end)
    it("does not trust the model's own summary, even if stamped", function()
        assert.is_false(Context.isTrustedSeriesBook({ source = "llm_summary", marginalia_boundary = STAMP }))
    end)
    it("does not trust roster stubs or unstamped (older) data", function()
        assert.is_false(Context.isTrustedSeriesBook({ source = "roster", marginalia_boundary = STAMP }))
        assert.is_false(Context.isTrustedSeriesBook({ source = "local_xray" }))
    end)
    it("does not trust a damaged stamp, or something that is not an entry", function()
        assert.is_false(Context.isTrustedSeriesBook({ marginalia_boundary = { v = 9, chapter = 3, frac = 0.5 } }))
        assert.is_false(Context.isTrustedSeriesBook({ marginalia_boundary = { v = 1, chapter = "3", frac = 0.5 } }))
        assert.is_false(Context.isTrustedSeriesBook({ marginalia_boundary = { v = 1, chapter = 0, frac = 0.5 } }))
        assert.is_false(Context.isTrustedSeriesBook(nil))
        assert.is_false(Context.isTrustedSeriesBook("x"))
    end)
end)

describe("series: Context.stripSeriesContext", function()
    local function data()
        return {
            series_context_loaded = true,
            characters = {
                { name = "Alice", description = "Own text.\n\n[From Book 1] Earlier spoiler.", from_series = true, is_series = true },
                { name = "Bob", description = "[From Book 1] Only from before", source = "series_prior", source_book = 1 },
                { name = "Cara", description = "Plain." },
            },
            locations = { { name = "Keep", source = "series_prior" } },
            terms = { { name = "T", definition = "[From Book 2] def" } },
            timeline = { { event = "old", source = "series_prior" }, { event = "now" } },
        }
    end

    it("removes copied items, tagged paragraphs and flags, and keeps the book's own content", function()
        local d = data()
        assert.is_true(Context.stripSeriesContext(d) > 0)
        assert.are.equal(2, #d.characters)
        assert.are.equal("Own text.", d.characters[1].description)
        assert.is_nil(d.characters[1].from_series)
        assert.is_nil(d.characters[1].is_series)
        assert.are.equal("Plain.", d.characters[2].description)
        assert.are.equal(0, #d.locations)
        assert.are.equal("", d.terms[1].definition)
        assert.are.equal(1, #d.timeline)
        assert.are.equal("now", d.timeline[1].event)
        assert.is_false(d.series_context_loaded)
    end)

    it("leaves data with no series context alone, and never errors on odd data", function()
        local d = { characters = { { name = "A", description = "x" } } }
        assert.are.equal(0, Context.stripSeriesContext(d))
        assert.are.equal("x", d.characters[1].description)
        assert.are.equal(0, Context.stripSeriesContext(nil))
        assert.are.equal(0, Context.stripSeriesContext({ characters = "bad", timeline = { "x" } }))
    end)

    it("hasSeriesContext sees each kind of leftover", function()
        assert.is_false(Context.hasSeriesContext({ characters = { { name = "A" } } }))
        assert.is_true(Context.hasSeriesContext({ series_context_loaded = true }))
        assert.is_true(Context.hasSeriesContext({ locations = { { source = "series_prior" } } }))
        assert.is_true(Context.hasSeriesContext({ characters = { { from_series = true } } }))
        assert.is_false(Context.hasSeriesContext(nil))
    end)
end)

describe("series: merging earlier books into this one", function()
    local function newPlugin()
        local plugin = setmetatable({
            log = function() end,
            characters = {}, locations = {}, terms = {}, timeline = {},
            ui = { document = {
                file = "/books/three.epub",
                getProps = function() return { title = "Book Three" } end,
                getToc = function() return {} end,
            } },
            assignTimelinePages = function() end,
            sortTimelineByTOC = function() end,
            sortDataByFrequency = function() end,
        }, { __index = XRayPlugin })
        return plugin
    end

    local function seriesCache()
        return {
            books = {
                [1] = { title = "One", source = "local_xray", marginalia_boundary = STAMP,
                        characters = { { name = "Alice", description = "Read it" } } },
                [2] = { title = "Two", source = "llm_summary",
                        characters = { { name = "Bob", description = "From the model's memory" } },
                        timeline = { { event = "Bob dies" } } },
            },
            book_paths = {},
        }
    end

    local function names(list)
        local out = {}
        for _, c in ipairs(list) do out[#out + 1] = c.name end
        table.sort(out)
        return table.concat(out, ",")
    end

    it("copies only trusted earlier books (control: without the rule it copies everything)", function()
        local control = newPlugin()
        control.marginaliaTrustsSeriesBook = false -- upstream behaviour
        control:mergeSeriesContext(seriesCache(), { index = 3, slug = "s" }, nil, true)
        assert.are.equal("Alice,Bob", names(control.characters))

        local plugin = newPlugin()
        plugin:mergeSeriesContext(seriesCache(), { index = 3, slug = "s" }, nil, true)
        assert.are.equal("Alice", names(plugin.characters))
        assert.are.equal(0, #plugin.timeline) -- the model's "Bob dies" never arrives
    end)

    it("an unstamped (older) entry is not copied either", function()
        local cache = seriesCache()
        cache.books[1].marginalia_boundary = nil
        local plugin = newPlugin()
        plugin:mergeSeriesContext(cache, { index = 3, slug = "s" }, nil, true)
        assert.are.equal("", names(plugin.characters))
    end)

    it("never copies a later book into an earlier one", function()
        local cache = seriesCache()
        cache.books[4] = { title = "Four", source = "local_xray", marginalia_boundary = STAMP,
                           characters = { { name = "Later" } } }
        local plugin = newPlugin()
        plugin:mergeSeriesContext(cache, { index = 3, slug = "s" }, nil, true)
        assert.is_nil(names(plugin.characters):find("Later", 1, true))
    end)
end)

describe("series: fetching context never asks the AI about earlier books from memory", function()
    -- other specs replace the network stub; use our own, and put theirs back
    local orig_network
    before_each(function()
        orig_network = package.loaded["ui/network/manager"]
        package.loaded["ui/network/manager"] = {
            isOnline = function() return true end,
            runWhenOnline = function(self, fn) (type(self) == "function" and self or fn)() end,
        }
    end)
    after_each(function() package.loaded["ui/network/manager"] = orig_network end)

    local function newPlugin()
        local state = { ai_calls = 0, merged = 0 }
        local plugin = setmetatable({
            log = function() end,
            destroyed = false,
            ui = { document = {
                file = "/books/three.epub",
                getProps = function() return { title = "Book Three", authors = "An Author" } end,
            } },
            ai_helper = {
                settings = { series_context_enabled = true },
                setTrapWidget = function() end,
                resetTrapWidget = function() end,
                createPrompt = function() return {} end,
                executeUnifiedRequest = function() state.ai_calls = state.ai_calls + 1 return nil, "err", "no" end,
            },
            series_manager = {
                getSeriesInfo = function() return { name = "S", index = 3, slug = "s" } end,
                getPriorBookList = function()
                    return { { index = 1, title = "One" }, { index = 2, title = "Two" } }
                end,
                loadSeriesCache = function()
                    return { books = {
                        [1] = { title = "One", source = "local_xray", marginalia_boundary = STAMP,
                                characters = { { name = "Alice" } } },
                    }, book_paths = {} }
                end,
                findLocalBookXRay = function() return nil end,
                saveSeriesCache = function() return true end,
            },
            mergeSeriesContext = function() state.merged = state.merged + 1 end,
        }, { __index = XRayPlugin })
        return plugin, state
    end

    it("control: without the rule, the missing book is fetched from the AI", function()
        local plugin, state = newPlugin()
        plugin.marginaliaFilterSeriesTasks = false -- upstream behaviour
        plugin:fetchSeriesContext(true)
        assert.is_true(state.ai_calls > 0)
    end)

    it("with the rule, no AI request is made and what is trusted is merged", function()
        local plugin, state = newPlugin()
        plugin:fetchSeriesContext(true)
        assert.are.equal(0, state.ai_calls)
        assert.are.equal(1, state.merged)
    end)
end)

describe("series: the series file keeps each book's stamp", function()
    local store
    local manager = SeriesManager:new()
    manager.loadSeriesCache = function() return store end
    manager.saveSeriesCache = function(_, _, d) store = d return true end
    local function data(extra)
        local d = { title = "One", characters = { { name = "Alice" } } }
        for k, v in pairs(extra or {}) do d[k] = v end
        return d
    end
    before_each(function() store = nil end)

    it("records the stamp the book's own data carries", function()
        manager:syncBookToSeriesCache("s", 1, data({ marginalia_boundary = STAMP }), "/books/one.epub", true)
        assert.are.same(STAMP, store.books[1].marginalia_boundary)
        assert.is_true(Context.isTrustedSeriesBook(store.books[1]))
    end)

    it("does not invent a stamp for data that has none", function()
        manager:syncBookToSeriesCache("s", 1, data(), "/books/one.epub", true)
        assert.is_nil(store.books[1].marginalia_boundary)
        assert.is_false(Context.isTrustedSeriesBook(store.books[1]))
    end)

    it("a roster stub does not wipe the stamp of data already recorded", function()
        manager:syncBookToSeriesCache("s", 1, data({ marginalia_boundary = STAMP }), "/books/one.epub", true)
        manager:syncBookToSeriesCache("s", 1, { title = "One", characters = {}, locations = {}, terms = {}, timeline = {} },
            "/books/one.epub", true)
        assert.are.same(STAMP, store.books[1].marginalia_boundary)
    end)
end)

describe("series: the plugin's hooks", function()
    local function newPlugin(opts)
        opts = opts or {}
        local quarantined = {}
        local plugin = setmetatable({
            log = function() end,
            ui = { document = { file = "/books/three.epub" } },
            marginalia = opts.session,
        }, { __index = XRayPlugin })
        plugin._quarantined = quarantined
        return plugin, { quarantine = function(_, path) quarantined[#quarantined + 1] = path end }
    end
    local function session(limit, page)
        return { isSettled = function() return true end, getLimit = function() return limit end,
                 getLimitPage = function() return page end }
    end

    it("filters the AI jobs: nothing from the model's memory, only trusted summaries", function()
        local plugin = newPlugin()
        local missing = { { index = 1, title = "One" } }
        local jobs = {
            { index = 1, book = { source = "local_xray", marginalia_boundary = STAMP } },
            { index = 2, book = { source = "local_xray" } }, -- unstamped
        }
        local m, j = plugin:marginaliaFilterSeriesTasks(missing, jobs)
        assert.are.equal(0, #m)
        assert.are.equal(1, #j)
        assert.are.equal(1, j[1].index)
    end)

    it("another book's saved data is never judged or set aside by this book's boundary", function()
        local s = session({ chapter = 1, frac = 0.1 }, 3)
        local plugin, cm = newPlugin({ session = s })
        local far = { characters = { { name = "X" } }, marginalia_boundary = { v = 1, chapter = 9, frac = 0.9 } }
        assert.is_true(plugin:marginaliaCheckCache(cm, far, "/books/one.epub"))
        assert.are.equal(0, #plugin._quarantined)
        -- control: the same data for THIS book is judged, and set aside
        assert.is_false(plugin:marginaliaCheckCache(cm, far, "/books/three.epub"))
        assert.are.equal(1, #plugin._quarantined)
    end)

    it("older series context in this book's data is removed once, on load", function()
        local plugin, cm = newPlugin({ session = session({ chapter = 5, frac = 0.5 }, 50) })
        local d = {
            characters = { { name = "A", description = "ok\n\n[From Book 1] x", from_series = true },
                           { name = "B", source = "series_prior" } },
            marginalia_boundary = { v = 1, chapter = 2, frac = 0.1 },
        }
        assert.is_true(plugin:marginaliaCheckCache(cm, d, "/books/three.epub"))
        assert.are.equal(1, #d.characters)
        assert.are.equal("ok", d.characters[1].description)
    end)

    it("data saved under the new rules is not cleaned again", function()
        local plugin, cm = newPlugin({ session = session({ chapter = 5, frac = 0.5 }, 50) })
        local d = {
            characters = { { name = "B", source = "series_prior", source_book = 1 } },
            marginalia_boundary = { v = 1, chapter = 2, frac = 0.1 },
            marginalia_series_checked = true,
        }
        assert.is_true(plugin:marginaliaCheckCache(cm, d, "/books/three.epub"))
        assert.are.equal(1, #d.characters)
    end)

    it("saving marks the data as checked", function()
        local plugin = newPlugin({ session = session({ chapter = 5, frac = 0.5 }, 50) })
        local d = { characters = { { name = "A" } } }
        plugin:marginaliaStampCache(d)
        assert.is_true(d.marginalia_series_checked)
        assert.is_not_nil(d.marginalia_boundary)
    end)

    describe("moving the boundary back", function()
        local store
        local function withSeries(limit)
            local plugin = newPlugin({ session = session(limit, 5) })
            plugin.book_data = { series_slug = "s" }
            plugin.series_manager = {
                loadSeriesCache = function() return store end,
                saveSeriesCache = function(_, _, d) store = d return true end,
            }
            return plugin
        end
        before_each(function()
            store = {
                books = {
                    [1] = { source = "local_xray", marginalia_boundary = { v = 1, chapter = 1, frac = 0.5 } },
                    [3] = { source = "local_xray", marginalia_boundary = { v = 1, chapter = 6, frac = 0.5 } },
                },
                book_paths = { [1] = "/books/one.epub", [3] = "/books/three.epub" },
            }
        end)

        it("drops this book's copy if it was made under a later boundary", function()
            withSeries({ chapter = 2, frac = 0.0 }):marginaliaTrimSeriesEntry()
            assert.is_nil(store.books[3])
            assert.is_not_nil(store.books[1]) -- another book is untouched
        end)

        it("keeps it if it was made at or before the new boundary", function()
            withSeries({ chapter = 6, frac = 0.5 }):marginaliaTrimSeriesEntry()
            assert.is_not_nil(store.books[3])
        end)
    end)
end)
