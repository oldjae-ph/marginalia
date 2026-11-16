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

    describe("the reading guide offer", function()
        local offers
        local function withGuideScreen(plugin)
            offers = 0
            plugin._marginalia_guide_ui = { offer = function() offers = offers + 1 end }
            return plugin
        end

        it("is made when a book opens at its start", function()
            local plugin = withGuideScreen(newPlugin({ { title = "Chapter 1", page = 1 }, { title = "Chapter 2", page = 30 } }, 1))
            plugin:marginaliaOnReaderReady()
            assert.are.equal(1, offers)
        end)

        it("waits for the first-open question, and is made once it is answered", function()
            local plugin = withGuideScreen(newPlugin({ { title = "A", page = 1 }, { title = "B", page = 14 } }, 20))
            plugin:marginaliaOnReaderReady()
            assert.is_not_nil(dialog)          -- "Have you read up to here?"
            assert.are.equal(0, offers)        -- not on top of it
            dialog.ok_callback()
            assert.are.equal(1, offers)
        end)

        it("is not made for a book that already has a guide", function()
            local plugin = withGuideScreen(newPlugin({ { title = "Chapter 1", page = 1 } }, 1))
            saved.marginalia_guide = { v = 1, state = "never" }
            plugin:marginaliaOnReaderReady()
            assert.are.equal(0, offers)
        end)
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

    describe("the chapter-end question with a debrief on offer", function()
        local bdialog, debriefs, orig_buttondialog
        local function chapterEnd()
            local plugin = newPlugin({ { title = "One", page = 1 }, { title = "Two", page = 11 } }, 1)
            debriefs = {}
            plugin.marginaliaDebriefStart = function(_, index) debriefs[#debriefs + 1] = index end
            plugin._marginalia_guide_ui = { offer = function() end } -- keep the guide's own dialog out of it
            plugin:marginaliaOnReaderReady()
            for p = 1, 10 do plugin:marginaliaOnPageUpdate(p) end
            plugin:marginaliaOnPageUpdate(11)
            return plugin
        end
        local function press(label)
            for _, row in ipairs(bdialog.buttons) do
                for _, b in ipairs(row) do if b.text == label then return b.callback() end end
            end
            error("no button: " .. label)
        end

        before_each(function()
            bdialog = nil
            orig_buttondialog = package.loaded["ui/widget/buttondialog"]
            package.loaded["ui/widget/buttondialog"] = { new = function(_, opts) bdialog = opts return opts end }
        end)
        after_each(function() package.loaded["ui/widget/buttondialog"] = orig_buttondialog end)

        it("offers three answers, and the question names the chapter", function()
            chapterEnd()
            assert.is_nil(dialog) -- not the plain yes/no box
            assert.is_not_nil(bdialog)
            assert.is_true(bdialog.title:find('"One"', 1, true) ~= nil)
            local labels = {}
            for _, row in ipairs(bdialog.buttons) do for _, b in ipairs(row) do labels[#labels + 1] = b.text end end
            assert.are.same({ "Mark done + debrief", "Mark done", "Not yet" }, labels)
        end)

        it("'Mark done + debrief' moves the boundary, then debriefs the chapter just FINISHED", function()
            local plugin = chapterEnd()
            assert.are.equal(1, plugin.marginalia:getLimit().chapter)
            press("Mark done + debrief")
            assert.are.equal(2, plugin.marginalia:getLimit().chapter)
            assert.are.same({ 1 }, debriefs) -- chapter One, not the chapter just started
        end)

        it("'Mark done + debrief' starts no debrief if the boundary did not actually move", function()
            local plugin = chapterEnd()
            -- the reader moved the boundary some other way while the question was open
            plugin.marginalia.boundary.pending_chapter = nil
            press("Mark done + debrief")
            assert.are.equal(1, plugin.marginalia:getLimit().chapter)
            assert.are.same({}, debriefs)
        end)

        it("'Mark done' moves the boundary and starts no debrief", function()
            local plugin = chapterEnd()
            press("Mark done")
            assert.are.equal(2, plugin.marginalia:getLimit().chapter)
            assert.are.same({}, debriefs)
        end)

        it("'Not yet' and dismissing it move nothing", function()
            local plugin = chapterEnd()
            press("Not yet")
            assert.are.equal(1, plugin.marginalia:getLimit().chapter)
            local again = chapterEnd()
            bdialog.tap_close_callback()
            assert.are.equal(1, again.marginalia:getLimit().chapter)
            assert.are.same({}, debriefs)
        end)

        it("is the plain two-answer question when debriefs are not available", function()
            local plugin = newPlugin({ { title = "One", page = 1 }, { title = "Two", page = 11 } }, 1)
            plugin._marginalia_guide_ui = { offer = function() end }
            plugin:marginaliaOnReaderReady()
            plugin.marginalia.deps.on_debrief = nil
            for p = 1, 11 do plugin:marginaliaOnPageUpdate(p) end
            assert.is_not_nil(dialog)
            assert.is_nil(bdialog)
        end)
    end)

    it("asks 'Have you finished ...?' at a chapter change and moves only on yes", function()
        local plugin = newPlugin({ { title = "One", page = 1 }, { title = "Two", page = 11 } }, 1)
        plugin:marginaliaOnReaderReady()
        plugin.marginalia.deps.on_debrief = nil -- the two-answer form (the three-answer form is tested above)
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

    describe("prefetching upcoming chapters", function()
        local orig_network, queued

        local function prefetchPlugin()
            local plugin = newPlugin({ { title = "Chapter 1", page = 1 }, { title = "Chapter 2", page = 50 },
                { title = "Chapter 3", page = 100 } }, 1)
            queued = 0
            plugin.ai_helper = { settings = { prefetch_horizon_chapters = 2 }, hasApiKey = function() return true end }
            plugin.getCurrentDocPage = function() return 1 end
            plugin._getFlatToc = function()
                return { { title = "Chapter 1", page = 1 }, { title = "Chapter 2", page = 50 }, { title = "Chapter 3", page = 100 } }
            end
            plugin.queueSequentialChapterScan = function() queued = queued + 1 end
            return plugin
        end

        before_each(function()
            orig_network = package.loaded["ui/network/manager"]
            package.loaded["ui/network/manager"] = {
                isConnected = function() return true end,
                hasDefaultRoute = function() return true end,
                isOnline = function() return true end,
            }
        end)
        after_each(function() package.loaded["ui/network/manager"] = orig_network end)

        it("upstream queues upcoming chapters when a horizon is set (control)", function()
            local plugin = prefetchPlugin()
            plugin:checkPrefetchHorizon()
            assert.are.equal(1, queued)
        end)

        it("is switched off once Marginalia is running", function()
            local plugin = prefetchPlugin()
            plugin:marginaliaOnReaderReady()
            plugin:checkPrefetchHorizon()
            assert.are.equal(0, queued)
        end)

        it("stays off when the settings picker or a network reconnect asks for it", function()
            local plugin = prefetchPlugin()
            plugin:marginaliaOnReaderReady()
            for _ = 1, 3 do
                if plugin.checkPrefetchHorizon then plugin:checkPrefetchHorizon() end
            end
            assert.are.equal(0, queued)
        end)

        it("only changes the plugin it is running for, not upstream's definition", function()
            local plugin = prefetchPlugin()
            plugin:marginaliaOnReaderReady()
            assert.are_not.equal(XRayPlugin.checkPrefetchHorizon, plugin.checkPrefetchHorizon)
            local other = prefetchPlugin() -- a plugin that never started Marginalia
            other:checkPrefetchHorizon()
            assert.are.equal(1, queued)
        end)
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

    it("puts 'Reading guide' second, and keeps upstream's entries after it", function()
        local items = menuPlugin(true):getSubMenuItems()
        assert.is_true(#items > 5)
        assert.are.equal("Reading guide", items[2].text)
        assert.are.equal("function", type(items[2].callback))
        assert.is_not_nil(items[3].text)
    end)

    it("still shows the entry (not set yet) when tracking is not running", function()
        local items = menuPlugin(false):getSubMenuItems()
        assert.are.equal("Spoiler boundary: not set yet", items[1].text_func())
    end)

    -- every entry text anywhere in the (static) menu tree
    local function allTexts(items, out)
        out = out or {}
        for _, item in ipairs(items) do
            if type(item) == "table" then
                if item.text then out[#out + 1] = item.text end
                if type(item.sub_item_table) == "table" then allTexts(item.sub_item_table, out) end
            end
        end
        return out
    end
    local function has(list, text)
        for _, t in ipairs(list) do if t == text then return true end end
        return false
    end

    it("upstream does offer the full-book picker (control: without our hook it is there)", function()
        local plugin = menuPlugin(true)
        plugin.marginaliaAddMenuItems = false -- hook disabled
        assert.is_true(has(allTexts(plugin:getSubMenuItems()), "Spoiler Settings"))
    end)

    it("hides the full-book 'Spoiler Settings' entry", function()
        local texts = allTexts(menuPlugin(true):getSubMenuItems())
        assert.is_false(has(texts, "Spoiler Settings"))
    end)

    it("upstream does offer Prefetch Horizon (control: without our hook it is there)", function()
        local plugin = menuPlugin(true)
        plugin.marginaliaAddMenuItems = false
        assert.is_true(has(allTexts(plugin:getSubMenuItems()), "Prefetch Horizon (Offline Readers)"))
    end)

    it("hides the 'Prefetch Horizon' entry", function()
        local texts = allTexts(menuPlugin(true):getSubMenuItems())
        assert.is_false(has(texts, "Prefetch Horizon (Offline Readers)"))
    end)

    it("upstream does offer the updater entries (control: without our hook they are there)", function()
        local plugin = menuPlugin(true)
        plugin.marginaliaAddMenuItems = false
        local texts = allTexts(plugin:getSubMenuItems())
        assert.is_true(has(texts, "Check for Updates"))
        assert.is_true(has(texts, "Beta Channel Settings"))
    end)

    it("hides 'Check for Updates' and 'Beta Channel Settings'", function()
        local texts = allTexts(menuPlugin(true):getSubMenuItems())
        assert.is_false(has(texts, "Check for Updates"))
        assert.is_false(has(texts, "Beta Channel Settings"))
    end)

    it("hides Prefetch Horizon in the plugin's own language too", function()
        local plugin = menuPlugin(true)
        plugin.loc = { t = function(_, key) if key == "menu_prefetch_horizon" then return "Vorabruf-Horizont" end end }
        plugin.marginaliaAddMenuItems = false
        assert.is_true(has(allTexts(plugin:getSubMenuItems()), "Vorabruf-Horizont")) -- control
        plugin.marginaliaAddMenuItems = XRayPlugin.marginaliaAddMenuItems
        assert.is_false(has(allTexts(plugin:getSubMenuItems()), "Vorabruf-Horizont"))
    end)

    it("hides it in the plugin's own language too", function()
        local plugin = menuPlugin(true)
        plugin.loc = { t = function(_, key) if key == "spoiler_preference_title" then return "Spoiler-Einstellungen" end end }
        plugin.marginaliaAddMenuItems = false
        local before = allTexts(plugin:getSubMenuItems())
        assert.is_true(has(before, "Spoiler-Einstellungen")) -- control
        plugin.marginaliaAddMenuItems = XRayPlugin.marginaliaAddMenuItems
        local after = allTexts(plugin:getSubMenuItems())
        assert.is_false(has(after, "Spoiler-Einstellungen"))
    end)

    it("leaves its neighbours alone", function()
        local texts = allTexts(menuPlugin(true):getSubMenuItems())
        assert.is_true(has(texts, "Series Context"))
        assert.is_true(has(texts, "Maintenance"))
        assert.is_true(has(texts, "Content & Fetch Settings"))
        assert.is_true(has(texts, "Settings"))
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
