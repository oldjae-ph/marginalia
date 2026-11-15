-- The fetch code must treat "the reader's page" as the confirmed boundary, not the
-- page the reader happens to be on after a jump. Covers the bookkeeping that the
-- live emulator test exposed: last_fetch_page was saved as 159 when the data only
-- reached page 49, which would have made later updates skip pages 49 to 159.
require("spec.spec_helper")
package.path = "marginalia.koplugin/?.lua;" .. package.path

local fetch = require("xray_fetch")
local data = require("xray_data")
local integration = require("marginalia_integration")
local UIManager = require("ui/uimanager")

describe("fetching never uses a page past the boundary", function()
    local plugin, orig_schedule, orig_network

    local function setLimit(page)
        plugin._marginalia_gate = function() return page end
    end

    before_each(function()
        orig_schedule = UIManager.scheduleIn
        orig_network = package.loaded["ui/network/manager"]
        package.loaded["ui/network/manager"] = { runWhenOnline = function(_, cb) cb() end }

        plugin = createMockPlugin()
        for _, mod in ipairs({ data, fetch, integration }) do
            for k, v in pairs(mod) do plugin[k] = v end
        end
        plugin.ui.getCurrentPage = function() return 159 end -- the reader jumped far ahead
        plugin.ui.document.getPageCount = function() return 1315 end
        plugin.ai_helper = { settings = { spoiler_setting = "spoiler_free" } }
        setLimit(49) -- ...but has only confirmed up to page 49
    end)

    after_each(function()
        UIManager.scheduleIn = orig_schedule
        package.loaded["ui/network/manager"] = orig_network
    end)

    describe("marginaliaClampPage", function()
        it("holds a page back to the limit and leaves earlier pages alone", function()
            assert.are.equal(49, plugin:marginaliaClampPage(159))
            assert.are.equal(30, plugin:marginaliaClampPage(30))
            assert.are.equal(49, plugin:marginaliaClampPage(49))
        end)

        it("never returns below 1, even when nothing is allowed", function()
            setLimit(0)
            assert.are.equal(1, plugin:marginaliaClampPage(159))
        end)

        it("returns the page unchanged when no gate is installed", function()
            plugin._marginalia_gate = nil
            assert.are.equal(159, plugin:marginaliaClampPage(159))
        end)

        it("passes through a missing page", function()
            assert.is_nil(plugin:marginaliaClampPage(nil))
        end)
    end)

    describe("entry points", function()
        local called
        before_each(function()
            called = nil
            plugin.continueWithFetch = function(_, reading_percent, is_update, last_fetch_page)
                called = { reading_percent = reading_percent, is_update = is_update, last_fetch_page = last_fetch_page }
            end
        end)

        it("fetchFromAI reports the boundary's share of the book, not the page jumped to", function()
            plugin:fetchFromAI()
            assert.are.equal(math.floor(49 / 1315 * 100), called.reading_percent) -- 3, not 12
        end)

        it("updateFromAI does too, and still passes the last fetched page through", function()
            plugin.book_data = { last_fetch_page = 30 }
            plugin:updateFromAI()
            assert.are.equal(3, called.reading_percent)
            assert.are.equal(30, called.last_fetch_page)
        end)

        it("is unchanged for a reader who is behind the boundary", function()
            plugin.ui.getCurrentPage = function() return 25 end
            plugin:fetchFromAI()
            assert.are.equal(math.floor(25 / 1315 * 100), called.reading_percent)
        end)
    end)

    describe("continueWithFetch", function()
        it("analyses text up to the boundary, not up to the page jumped to", function()
            local callbacks, seen = {}, {}
            UIManager.scheduleIn = function(_, _, cb) callbacks[#callbacks + 1] = cb end
            plugin.chapter_analyzer = {
                getEndPageForCurrentPage = function(_, _, page) return page end,
                getTextForAnalysis = function(_, _, _, _, end_page, first_missing)
                    seen.end_page, seen.first_missing = end_page, first_missing
                    return string.rep("x", 100)
                end,
                getDetailedChapterSamples = function(_, _, _, _, _, _, _, current_page)
                    seen.samples_page = current_page
                    return nil, nil
                end,
                getAnnotationsForAnalysis = function(_, _, max_page) seen.annot_page = max_page; return "" end,
            }
            plugin.book_data = {}
            pcall(function()
                plugin:continueWithFetch(3, false, nil, true)
                local guard = 0
                while #callbacks > 0 and guard < 20 do
                    guard = guard + 1
                    table.remove(callbacks, 1)()
                end
            end)
            assert.are.equal(49, seen.end_page)
        end)
    end)
end)
