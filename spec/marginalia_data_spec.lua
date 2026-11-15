-- Saved X-Ray data and the spoiler boundary: stamping, hiding data from past the
-- boundary, setting it aside (never deleting), and locking out "full book" mode.
-- Uses the real CacheManager on real files under /tmp.
require("spec.spec_helper")
package.path = "marginalia.koplugin/?.lua;" .. package.path

local CacheManager = require("xray_cachemanager")
local analyzer = require("xray_chapteranalyzer")
local UIManager = require("ui/uimanager")
local XRayPlugin = dofile("marginalia.koplugin/main.lua")

local BOOK = "/tmp/marginalia_data_book.epub"
local SIDECAR = BOOK .. ".sdr"
local CACHE = SIDECAR .. "/xray_cache.lua"

local function sh(cmd) return os.execute(cmd) end
local function listSidecar()
    local out = {}
    local p = io.popen("ls " .. SIDECAR .. " 2>/dev/null")
    if p then for line in p:lines() do out[#out + 1] = line end p:close() end
    return out
end
local function setAside()
    local found = {}
    for _, name in ipairs(listSidecar()) do
        if name:find("^xray_cache%.lua%.spoiler%-") then found[#found + 1] = name end
    end
    return found
end
local function story(extra)
    local d = { characters = { { name = "Alice" } }, last_fetch_page = 5, cache_version = "6.1" }
    for k, v in pairs(extra or {}) do d[k] = v end
    return d
end

describe("CacheManager: Marginalia hooks", function()
    local cm

    before_each(function()
        CacheManager.boundary_guard = nil -- start from "no guard", whatever ran before
        sh("rm -rf " .. SIDECAR); sh("mkdir -p " .. SIDECAR)
        cm = CacheManager:new()
    end)
    after_each(function() CacheManager.boundary_guard = nil end)

    it("changes nothing when no guard is installed (control)", function()
        assert.is_true(cm:saveCache(BOOK, story()))
        local loaded = cm:loadCache(BOOK)
        assert.are.equal("Alice", loaded.characters[1].name)
        assert.is_nil(loaded.marginalia_boundary)
    end)

    it("stamps the boundary on a synchronous save", function()
        CacheManager.boundary_guard = {
            stamp = function(data) data.marginalia_boundary = { v = 1, chapter = 3, frac = 0.5 } end,
            check = function() return true end,
        }
        assert.is_true(cm:saveCache(BOOK, story()))
        local loaded = cm:loadCache(BOOK)
        assert.are.equal(3, loaded.marginalia_boundary.chapter)
        assert.are.equal(0.5, loaded.marginalia_boundary.frac)
    end)

    it("stamps the boundary on an async save too", function()
        CacheManager.boundary_guard = {
            stamp = function(data) data.marginalia_boundary = { v = 1, chapter = 4, frac = 0.25 } end,
            check = function() return true end,
        }
        cm:asyncSaveCache(BOOK, story())
        if cm.flushAsyncSaves then cm:flushAsyncSaves() end
        local loaded = cm:loadCache(BOOK)
        assert.is_not_nil(loaded)
        assert.are.equal(4, loaded.marginalia_boundary.chapter)
    end)

    it("hands the guard the manager, the data and the book path", function()
        cm:saveCache(BOOK, story())
        local seen
        CacheManager.boundary_guard = {
            stamp = function() end,
            check = function(manager, data, path) seen = { manager = manager, data = data, path = path }; return true end,
        }
        cm:loadCache(BOOK)
        assert.are.equal(cm, seen.manager)
        assert.are.equal("Alice", seen.data.characters[1].name)
        assert.are.equal(BOOK, seen.path)
    end)

    it("treats data the guard rejects as no cache, and leaves the file alone", function()
        cm:saveCache(BOOK, story())
        CacheManager.boundary_guard = { stamp = function() end, check = function() return false end }
        assert.is_nil(cm:loadCache(BOOK))
        local f = io.open(CACHE, "r")
        assert.is_not_nil(f)
        f:close()
    end)

    it("quarantine renames the file, never deletes it", function()
        cm:saveCache(BOOK, story())
        local before = io.open(CACHE, "r"):read("*a")
        local target = cm:quarantine(BOOK)
        assert.is_not_nil(target)
        assert.is_nil(io.open(CACHE, "r"))
        local kept = io.open(target, "r")
        assert.is_not_nil(kept)
        assert.are.equal(before, kept:read("*a"))
        kept:close()
        assert.are.equal(1, #setAside())
        assert.is_nil(cm:loadCache(BOOK)) -- gone from the loader's point of view
    end)

    it("quarantine of a missing file is harmless", function()
        assert.is_nil(cm:quarantine(BOOK))
    end)

    it("a new save after quarantine does not touch the set-aside copy", function()
        cm:saveCache(BOOK, story({ characters = { { name = "Old spoiler" } } }))
        local target = cm:quarantine(BOOK)
        cm:saveCache(BOOK, story({ characters = { { name = "Fresh" } } }))
        assert.are.equal("Fresh", cm:loadCache(BOOK).characters[1].name)
        local kept = io.open(target, "r"):read("*a")
        assert.is_true(kept:find("Old spoiler", 1, true) ~= nil)
    end)
end)

describe("Marginalia integration: saved data and the boundary", function()
    local TOC = { { title = "A", page = 1 }, { title = "B", page = 14 }, { title = "C", page = 30 } }
    local orig_nexttick, orig_confirmbox, orig_uimanager, orig_prompt, orig_show
    local dialog, cancelled, async_cancelled

    -- A plugin with just enough of upstream's loading behaviour to see what happens
    -- to saved data. autoLoadCache is a minimal stand-in for upstream's.
    local function newPlugin(page, toc)
        dialog, cancelled, async_cancelled = nil, 0, 0
        local saved = {}
        local plugin = setmetatable({
            destroyed = false,
            log = function() end,
            getCurrentPage = function() return page end,
            cache_manager = CacheManager:new(),
            ui = {
                doc_settings = {
                    readSetting = function(_, k) return saved[k] end,
                    saveSetting = function(_, k, v) saved[k] = v end,
                    flush = function() end,
                },
                document = {
                    file = BOOK,
                    getPageCount = function() return 60 end,
                    getToc = function() return toc or TOC end,
                    getProps = function() return { title = "A Test Book" } end,
                },
            },
            cancelActiveAIRequest = function() cancelled = cancelled + 1 end,
            autoLoadCache = function(self)
                local data = self.cache_manager:loadCache(BOOK)
                if data then
                    self.book_data = data
                    self.characters = data.characters or {}
                    self.timeline = data.timeline or {}
                end
            end,
        }, { __index = XRayPlugin })
        plugin.cache_manager.cancelAsyncSaves = function() async_cancelled = async_cancelled + 1 end
        return plugin
    end

    local function readTo(plugin, page)
        for p = 1, page do plugin:marginaliaOnPageUpdate(p) end
    end

    before_each(function()
        CacheManager.boundary_guard = nil
        analyzer.limit_provider = nil
        sh("rm -rf " .. SIDECAR); sh("mkdir -p " .. SIDECAR)
        orig_nexttick, orig_confirmbox = UIManager.nextTick, package.loaded["ui/widget/confirmbox"]
        orig_uimanager, orig_prompt, orig_show = package.loaded["ui/uimanager"], package.loaded["marginalia_prompt"], UIManager.show
        UIManager.nextTick = function(_, fn) fn() end
        UIManager.show = function() end
        package.loaded["ui/widget/confirmbox"] = { new = function(_, opts) dialog = opts; return opts end }
        package.loaded["ui/uimanager"] = UIManager
        package.loaded["marginalia_prompt"] = nil
    end)

    after_each(function()
        CacheManager.boundary_guard = nil
        analyzer.limit_provider = nil
        UIManager.nextTick, UIManager.show = orig_nexttick, orig_show
        package.loaded["ui/widget/confirmbox"] = orig_confirmbox
        package.loaded["ui/uimanager"], package.loaded["marginalia_prompt"] = orig_uimanager, orig_prompt
    end)

    local function start(plugin)
        plugin:marginaliaOnReaderReady()
        plugin:autoLoadCache()
    end

    describe("loading", function()
        local function empty(t) return t == nil or next(t) == nil end

        -- The realistic flow: the book is opened mid-way, the reader answers the
        -- first-open question, and saved data is then judged against that boundary.
        local function openMidBookAnsweringYes()
            local plugin = newPlugin(20) -- page 20 is in chapter B
            start(plugin)
            assert.is_not_nil(dialog)
            dialog.ok_callback() -- "Yes, up to here"
            return plugin
        end

        it("loads data that was fetched no further than the boundary", function()
            CacheManager:new():saveCache(BOOK, story({ last_fetch_page = 5 })) -- unstamped, reaches page 5
            local plugin = openMidBookAnsweringYes()
            assert.are.equal("Alice", plugin.characters[1].name)
            assert.are.equal(0, #setAside())
        end)

        it("sets aside data that reaches past the boundary, and shows nothing", function()
            CacheManager:new():saveCache(BOOK, story({ last_fetch_page = 500 })) -- e.g. fetched in full-book mode
            local plugin = openMidBookAnsweringYes()
            assert.is_true(empty(plugin.characters))
            assert.are.equal(1, #setAside())
            assert.is_nil(io.open(CACHE, "r"))
        end)

        it("sets aside stamped data made under a later boundary", function()
            CacheManager:new():saveCache(BOOK, story({ marginalia_boundary = { v = 1, chapter = 3, frac = 0.5 } }))
            local plugin = openMidBookAnsweringYes()
            assert.is_true(empty(plugin.characters))
            assert.are.equal(1, #setAside())
        end)

        it("keeps stamped data made under an earlier boundary", function()
            CacheManager:new():saveCache(BOOK, story({ marginalia_boundary = { v = 1, chapter = 1, frac = 0.2 } }))
            local plugin = openMidBookAnsweringYes()
            assert.are.equal("Alice", plugin.characters[1].name)
            assert.are.equal(0, #setAside())
        end)

        it("at the very start of a book, older data that reaches further is set aside", function()
            CacheManager:new():saveCache(BOOK, story({ last_fetch_page = 5 }))
            local plugin = newPlugin(1)
            start(plugin)
            assert.is_true(empty(plugin.characters))
            assert.are.equal(1, #setAside())
        end)

        it("hides everything, without touching the file, when there is no table of contents", function()
            CacheManager:new():saveCache(BOOK, story())
            local plugin = newPlugin(1, {})
            start(plugin)
            assert.is_true(empty(plugin.characters))
            assert.are.equal(0, #setAside())
            assert.is_not_nil(io.open(CACHE, "r"))
        end)

        it("hides everything when tracking could not start", function()
            CacheManager:new():saveCache(BOOK, story())
            local plugin = newPlugin(1)
            plugin.ui.document.getPageCount = function() error("closed") end
            start(plugin)
            assert.is_true(empty(plugin.characters))
            assert.are.equal(0, #setAside())
        end)

        it("does not touch saved data while the first-open question is unanswered", function()
            CacheManager:new():saveCache(BOOK, story({ last_fetch_page = 16 })) -- reaches page 16
            local plugin = newPlugin(20) -- opened mid-book: the question appears
            start(plugin)
            assert.is_not_nil(dialog)
            assert.is_true(empty(plugin.characters)) -- hidden for now
            assert.are.equal(0, #setAside()) -- but NOT set aside: the boundary is not known yet
            assert.is_not_nil(io.open(CACHE, "r"))
        end)

        it("shows it once the reader says they have read that far", function()
            CacheManager:new():saveCache(BOOK, story({ last_fetch_page = 16 }))
            local plugin = newPlugin(20)
            start(plugin)
            dialog.ok_callback() -- "Yes, up to here" (page 20)
            assert.are.equal("Alice", plugin.characters[1].name)
            assert.are.equal(0, #setAside())
        end)

        it("sets it aside if the reader says they are at the start", function()
            CacheManager:new():saveCache(BOOK, story({ last_fetch_page = 16 }))
            local plugin = newPlugin(20)
            start(plugin)
            dialog.cancel_callback() -- "No, I'm at the start"
            assert.is_true(empty(plugin.characters))
            assert.are.equal(1, #setAside())
        end)
    end)

    describe("saving", function()
        it("stamps saves with the boundary at that moment", function()
            local plugin = newPlugin(1)
            start(plugin)
            readTo(plugin, 6)
            plugin.cache_manager:saveCache(BOOK, story())
            local loaded = plugin.cache_manager:loadCache(BOOK)
            assert.are.equal(1, loaded.marginalia_boundary.chapter)
            assert.is_true(math.abs(loaded.marginalia_boundary.frac - 6 / 13) < 1e-6)
        end)

        it("does not stamp while the boundary is unknown", function()
            local plugin = newPlugin(20)
            start(plugin) -- first-open question showing
            local data = story()
            CacheManager.boundary_guard.stamp(data)
            assert.is_nil(data.marginalia_boundary)
        end)
    end)

    describe("when the reader moves the boundary back", function()
        it("sets aside data made under the old, further boundary and clears memory", function()
            local plugin = newPlugin(1)
            start(plugin)
            plugin.marginalia:setBoundaryAtPage(20) -- reader moves forward: fine
            plugin.cache_manager:saveCache(BOOK, story()) -- stamped at page 20
            plugin:autoLoadCache()
            assert.are.equal("Alice", plugin.characters[1].name)

            assert.is_true(plugin.marginalia:rollBackToPage(8))
            assert.are.equal(1, cancelled) -- anything in flight was stopped
            assert.are.equal(1, async_cancelled) -- unsaved writes dropped
            assert.are.same({}, plugin.characters)
            assert.are.same({}, plugin.book_data)
            assert.are.equal(1, #setAside())
            assert.is_nil(io.open(CACHE, "r"))
        end)

        it("keeps data that was made at or before the new, earlier boundary", function()
            local plugin = newPlugin(1)
            start(plugin)
            plugin.marginalia:setBoundaryAtPage(6)
            plugin.cache_manager:saveCache(BOOK, story()) -- stamped at page 6
            plugin.marginalia:setBoundaryAtPage(20)
            assert.is_true(plugin.marginalia:rollBackToPage(10)) -- still later than the stamp
            assert.are.equal("Alice", plugin.characters[1].name)
            assert.are.equal(0, #setAside())
        end)

        it("does nothing disruptive when the reader moves the boundary forward", function()
            local plugin = newPlugin(1)
            start(plugin)
            plugin.marginalia:setBoundaryAtPage(6)
            plugin.marginalia:setBoundaryAtPage(20)
            assert.are.equal(0, cancelled)
            assert.are.equal(0, async_cancelled)
        end)
    end)

    describe("full-book mode", function()
        local function fakeHelper()
            local helper = { settings = { spoiler_setting = "full_book", other = 1 } }
            helper.saveSettings = function(h, new_settings)
                for k, v in pairs(new_settings or {}) do h.settings[k] = v end
                return true
            end
            helper.loadSettings = function(h) h.settings = { spoiler_setting = "full_book", other = 2 }; return h.settings end
            return helper
        end

        it("is forced to spoiler-free", function()
            local plugin = newPlugin(1)
            plugin.ai_helper = fakeHelper()
            plugin:marginaliaLockSpoilerMode()
            assert.are.equal("spoiler_free", plugin.ai_helper.settings.spoiler_setting)
            assert.are.equal(1, plugin.ai_helper.settings.other) -- nothing else is touched
        end)

        it("cannot be switched on from the settings menu", function()
            local plugin = newPlugin(1)
            plugin.ai_helper = fakeHelper()
            plugin:marginaliaLockSpoilerMode()
            plugin.ai_helper:saveSettings({ spoiler_setting = "full_book", other = 3 })
            assert.are.equal("spoiler_free", plugin.ai_helper.settings.spoiler_setting)
            assert.are.equal(3, plugin.ai_helper.settings.other)
        end)

        it("stays locked after settings are reloaded from disk", function()
            local plugin = newPlugin(1)
            plugin.ai_helper = fakeHelper()
            plugin:marginaliaLockSpoilerMode()
            plugin.ai_helper:loadSettings()
            assert.are.equal("spoiler_free", plugin.ai_helper.settings.spoiler_setting)
            assert.are.equal(2, plugin.ai_helper.settings.other)
        end)

        it("does not wrap the settings functions twice", function()
            local plugin = newPlugin(1)
            plugin.ai_helper = fakeHelper()
            plugin:marginaliaLockSpoilerMode()
            local first = plugin.ai_helper.saveSettings
            plugin:marginaliaLockSpoilerMode()
            assert.are.equal(first, plugin.ai_helper.saveSettings)
        end)

        it("is applied when the reader becomes ready", function()
            local plugin = newPlugin(1)
            plugin.ai_helper = fakeHelper()
            plugin:marginaliaOnReaderReady()
            assert.are.equal("spoiler_free", plugin.ai_helper.settings.spoiler_setting)
        end)
    end)

    describe("closing the book", function()
        it("takes the guard down, but not another book's", function()
            local first = newPlugin(1)
            first:marginaliaOnReaderReady()
            local second = newPlugin(1)
            second:marginaliaOnReaderReady()
            first:marginaliaOnDestroy()
            assert.is_not_nil(CacheManager.boundary_guard)
            second:marginaliaOnDestroy()
            assert.is_nil(CacheManager.boundary_guard)
        end)
    end)
end)
