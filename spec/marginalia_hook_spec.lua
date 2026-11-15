-- Specs for the small hooks in main.lua and marginalia_integration.lua.
-- Checks that the confirmed boundary has replaced xray's automatic chapter fetch.
require("spec.spec_helper")

local UIManager = require("ui/uimanager")
local XRayPlugin = dofile("marginalia.koplugin/main.lua")

describe("Marginalia hooks in main.lua", function()
    local plugin, scheduled, orig_schedule, orig_unschedule, orig_nexttick, orig_confirmbox

    local function newPlugin(extra)
        local p = {
            destroyed = false,
            auto_fetch_enabled = true,
            bg_fetch_pending = false,
            bg_fetch_active = false,
            _reader_ready = true,
            chapters_fetched = {},
            timeline = {},
            book_data = {},
            log = function() end,
            clearPendingBackgroundFetch = function() end,
            clearChapterFetchTimer = function() end,
            _getFlatToc = function()
                -- page 50 starts an un-fetched chapter: xray's old code would schedule a fetch here
                return { { title = "Chapter 1", page = 1 }, { title = "Chapter 2", page = 50 } }
            end,
            ui = { getCurrentPage = function() return 50 end, document = {} },
        }
        for k, v in pairs(extra or {}) do p[k] = v end
        return setmetatable(p, { __index = XRayPlugin })
    end

    before_each(function()
        scheduled = {}
        orig_schedule, orig_unschedule, orig_nexttick = UIManager.scheduleIn, UIManager.unschedule, UIManager.nextTick
        orig_confirmbox = package.loaded["ui/widget/confirmbox"]
        UIManager.scheduleIn = function(_, delay, cb) scheduled[#scheduled + 1] = { delay = delay, cb = cb } end
        UIManager.unschedule = function() end
        plugin = newPlugin()
    end)

    after_each(function()
        UIManager.scheduleIn, UIManager.unschedule, UIManager.nextTick = orig_schedule, orig_unschedule, orig_nexttick
        package.loaded["ui/widget/confirmbox"] = orig_confirmbox
    end)

    it("loads the Marginalia mixin", function()
        assert.are.equal("function", type(XRayPlugin.marginaliaOnReaderReady))
        assert.are.equal("function", type(XRayPlugin.marginaliaOnPageUpdate))
        assert.are.equal("function", type(XRayPlugin.marginaliaFlush))
    end)

    it("gives page turns to Marginalia", function()
        local pages = {}
        plugin.marginalia = { onPageUpdate = function(_, page) pages[#pages + 1] = page end }
        plugin:onPageUpdate(50)
        plugin:onPageUpdate(51)
        assert.are.same({ 50, 51 }, pages)
    end)

    it("no longer starts xray's automatic fetch when a new chapter begins", function()
        plugin.marginalia = { onPageUpdate = function() end }
        plugin:onPageUpdate(50)
        assert.are.equal(0, #scheduled)
        assert.is_false(plugin.bg_fetch_pending)
    end)

    it("does not fall back to automatic fetching when tracking could not start", function()
        plugin.marginalia = nil -- e.g. the session failed to start
        plugin:onPageUpdate(50)
        assert.are.equal(0, #scheduled)
        assert.is_false(plugin.bg_fetch_pending)
    end)

    it("never lets a tracking error reach the reader", function()
        plugin.marginalia = { onPageUpdate = function() error("boom") end }
        plugin:onPageUpdate(50) -- must not raise
        assert.are.equal(0, #scheduled)
    end)

    it("saves the boundary when the device suspends", function()
        local flushed = 0
        plugin.marginalia = { flush = function() flushed = flushed + 1 end }
        plugin:onSuspend()
        assert.are.equal(1, flushed)
    end)

    it("still shows the return banner logic before handing over (hook comes after it)", function()
        local shown
        plugin.pending_return_banner = { return_page = 7, entity = {}, mentions = {} }
        plugin.showReturnBanner = function(_, return_page) shown = return_page end
        plugin.marginalia = { onPageUpdate = function() end }
        plugin:onPageUpdate(50)
        assert.is_nil(plugin.pending_return_banner)
        assert.are.equal(1, #scheduled) -- banner is scheduled, auto-fetch is not
        scheduled[1].cb()
        assert.are.equal(7, shown)
    end)
end)

describe("Marginalia integration (marginalia_integration.lua)", function()
    local orig_nexttick, orig_confirmbox, saved, flushes, dialog

    local function newPlugin(toc, page)
        saved, flushes, dialog = {}, 0, nil
        local doc_settings = {
            readSetting = function(_, key) return saved[key] end,
            saveSetting = function(_, key, value) saved[key] = value end,
            flush = function() flushes = flushes + 1 end,
        }
        return setmetatable({
            destroyed = false,
            log = function() end,
            getCurrentPage = function() return page end,
            ui = {
                doc_settings = doc_settings,
                document = {
                    getPageCount = function() return 60 end,
                    getToc = function() return toc end,
                    getProps = function() return { title = "A Test Book" } end,
                },
            },
        }, { __index = XRayPlugin })
    end

    local orig_uimanager, orig_prompt, orig_show

    before_each(function()
        orig_nexttick, orig_confirmbox = UIManager.nextTick, package.loaded["ui/widget/confirmbox"]
        orig_uimanager, orig_prompt = package.loaded["ui/uimanager"], package.loaded["marginalia_prompt"]
        orig_show = UIManager.show
        UIManager.nextTick = function(_, fn) fn() end
        UIManager.show = function() end
        package.loaded["ui/widget/confirmbox"] = {
            new = function(_, opts) dialog = opts; return opts end,
        }
        -- Other specs may have loaded marginalia_prompt (or swapped the UIManager mock)
        -- earlier in the same run; load a fresh copy bound to the fakes above.
        package.loaded["ui/uimanager"] = UIManager
        package.loaded["marginalia_prompt"] = nil
    end)

    after_each(function()
        local ok, analyzer = pcall(require, "xray_chapteranalyzer")
        if ok then analyzer.limit_provider = nil end -- never leak a gate into other specs
        local ok_cm, cache_class = pcall(require, "xray_cachemanager")
        if ok_cm then cache_class.boundary_guard = nil end
        UIManager.nextTick, UIManager.show = orig_nexttick, orig_show
        package.loaded["ui/widget/confirmbox"] = orig_confirmbox
        package.loaded["ui/uimanager"], package.loaded["marginalia_prompt"] = orig_uimanager, orig_prompt
    end)

    it("starts quietly at the front of a book and saves a fresh boundary", function()
        local plugin = newPlugin({ { title = "Chapter 1", page = 1 }, { title = "Chapter 2", page = 30 } }, 1)
        plugin:marginaliaOnReaderReady()
        assert.is_not_nil(plugin.marginalia)
        assert.is_nil(dialog)
        assert.are.equal(1, saved.marginalia_boundary.confirmed_chapter)
        assert.is_true(flushes >= 1)
    end)

    it("uses its own settings key, not xray's", function()
        local plugin = newPlugin({ { title = "Chapter 1", page = 1 } }, 1)
        plugin:marginaliaOnReaderReady()
        for key in pairs(saved) do assert.are.equal("marginalia_boundary", key) end
    end)

    it("cleans the TOC: sorted by page, entries without a page dropped", function()
        local toc = { { title = "C", page = 30 }, { title = "No page here" }, { title = "A", page = 1 }, { title = "B", page = 14 } }
        local plugin = newPlugin(toc, 20) -- mid-book: should ask where the reader is
        plugin:marginaliaOnReaderReady()
        assert.is_not_nil(dialog)
        assert.is_true(dialog.icon ~= false) -- icon=false crashes KOReader's ConfirmBox
        dialog.ok_callback() -- "Yes, up to here"
        -- page 20 is in B, the 2nd entry once sorted and cleaned
        assert.are.equal(2, plugin.marginalia:getLimit().chapter)
    end)

    it("treats dismissing the first-open question as 'start of the book'", function()
        local plugin = newPlugin({ { title = "A", page = 1 }, { title = "B", page = 14 } }, 20)
        plugin:marginaliaOnReaderReady()
        dialog.cancel_callback()
        assert.are.same({ chapter = 1, frac = 0 }, plugin.marginalia:getLimit())
    end)

    it("restores the saved boundary the next time the book is opened", function()
        local toc = { { title = "A", page = 1 }, { title = "B", page = 14 }, { title = "C", page = 30 } }
        local plugin = newPlugin(toc, 20)
        plugin:marginaliaOnReaderReady()
        dialog.ok_callback()
        local before = plugin.marginalia:getLimit()
        local keep = saved.marginalia_boundary

        local plugin2 = newPlugin(toc, 25)
        saved.marginalia_boundary = keep
        dialog = nil
        plugin2:marginaliaOnReaderReady()
        assert.is_nil(dialog)
        assert.are.same(before, plugin2.marginalia:getLimit())
    end)

    it("asks 'Have you finished ...?' at a chapter change and moves only on yes", function()
        local plugin = newPlugin({ { title = "One", page = 1 }, { title = "Two", page = 11 } }, 1)
        plugin:marginaliaOnReaderReady()
        for p = 1, 10 do plugin:marginaliaOnPageUpdate(p) end
        assert.is_nil(dialog)
        plugin:marginaliaOnPageUpdate(11)
        assert.is_not_nil(dialog)
        assert.is_true(dialog.icon ~= false) -- icon=false crashes KOReader's ConfirmBox
        assert.is_true(dialog.text:find('"One"', 1, true) ~= nil)
        assert.are.equal(1, plugin.marginalia:getLimit().chapter)
        dialog.ok_callback()
        assert.are.equal(2, plugin.marginalia:getLimit().chapter)
    end)

    it("does nothing harmful when the book has no table of contents", function()
        local plugin = newPlugin({}, 20)
        plugin:marginaliaOnReaderReady()
        plugin:marginaliaOnPageUpdate(21)
        assert.is_nil(dialog)
    end)

    it("installs the spoiler gate before anything can fail, and then allows nothing", function()
        local plugin = newPlugin({ { title = "A", page = 1 } }, 1)
        plugin.ui.document.getPageCount = function() error("document closed") end -- session cannot start
        plugin:marginaliaOnReaderReady()
        local analyzer = require("xray_chapteranalyzer")
        assert.are.equal("function", type(analyzer.limit_provider))
        assert.are.equal(0, analyzer:getLimitPage())
        assert.are.equal(0, plugin:marginaliaLimitPage())
    end)

    it("the gate follows the reader's boundary and ignores jumps", function()
        local plugin = newPlugin({ { title = "A", page = 1 }, { title = "B", page = 14 } }, 1)
        plugin:marginaliaOnReaderReady()
        local analyzer = require("xray_chapteranalyzer")
        for p = 1, 5 do plugin:marginaliaOnPageUpdate(p) end
        assert.are.equal(5, analyzer:getLimitPage())
        plugin:marginaliaOnPageUpdate(40) -- TOC jump
        plugin:marginaliaOnPageUpdate(41)
        assert.are.equal(5, analyzer:getLimitPage())
    end)

    it("takes the gate down on close, but never another book's gate", function()
        local analyzer = require("xray_chapteranalyzer")
        local first = newPlugin({ { title = "A", page = 1 } }, 1)
        first:marginaliaOnReaderReady()
        local second = newPlugin({ { title = "A", page = 1 } }, 1)
        second:marginaliaOnReaderReady()
        first:marginaliaOnDestroy() -- the first book closing must not remove the second's gate
        assert.are.equal("function", type(analyzer.limit_provider))
        second:marginaliaOnDestroy()
        assert.is_nil(analyzer.limit_provider)
    end)

    it("keeps working if starting fails", function()
        local plugin = newPlugin({ { title = "A", page = 1 } }, 1)
        plugin.ui.document.getPageCount = function() error("document closed") end
        plugin:marginaliaOnReaderReady()
        plugin:marginaliaOnPageUpdate(2) -- no session, must not raise
        plugin:marginaliaFlush()
        assert.is_true(true)
    end)
end)

describe("Marginalia menu hook in main.lua", function()
    local function menuPlugin(with_marginalia)
        local p = setmetatable({
            destroyed = false,
            log = function() end,
            getCurrentPage = function() return 1 end,
            loc = { t = function() return nil end },
            ai_helper = { settings = {}, hasApiKey = function() return true end },
            characters = {}, timeline = {}, locations = {}, terms = {}, historical_figures = {},
            book_data = {}, ui = { document = {}, getCurrentPage = function() return 1 end },
        }, { __index = XRayPlugin })
        if with_marginalia then
            p.marginalia = {
                describe = function() return { settled = true, title = "II.", percent = 44 } end,
            }
        end
        return p
    end

    it("puts 'Spoiler boundary' first in the X-Ray menu", function()
        local plugin = menuPlugin(true)
        local items = plugin:getSubMenuItems()
        assert.are.equal('Spoiler boundary: "II.", 44% through', items[1].text_func())
        assert.are.equal("function", type(items[1].sub_item_table_func))
        assert.are.equal(items, plugin.current_xray_menu_table)
    end)

    it("keeps upstream's entries after it", function()
        local items = menuPlugin(true):getSubMenuItems()
        assert.is_true(#items > 5)
        assert.is_not_nil(items[2].text)
    end)

    it("still shows the entry (not set yet) when tracking is not running", function()
        local items = menuPlugin(false):getSubMenuItems()
        assert.are.equal("Spoiler boundary: not set yet", items[1].text_func())
    end)

    it("never breaks upstream's menu if building the entry fails", function()
        local plugin = menuPlugin(true)
        local saved = package.loaded["marginalia_menu"]
        package.loaded["marginalia_menu"] = { topItem = function() error("boom") end }
        local ok, items = pcall(function() return plugin:getSubMenuItems() end)
        package.loaded["marginalia_menu"] = saved
        assert.is_true(ok)
        assert.is_true(#items > 5) -- upstream's entries are all still there
        assert.is_nil(items[1].text_func and items[1].text_func():find("Spoiler boundary", 1, true))
    end)
end)
