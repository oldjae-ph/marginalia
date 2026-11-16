-- The self-updater is OFF. It would download upstream's release and unzip it over
-- this plugin's folder, so while it is off nothing in it may touch the network or
-- the disk, whichever way it is reached.
require("spec.spec_helper")
package.path = "marginalia.koplugin/?.lua;" .. package.path

local XRayPlugin = dofile("marginalia.koplugin/main.lua")
local updater = require("xray_updater")
local UIManager = require("ui/uimanager")

describe("updater: the module", function()
    local http_calls, network_calls, orig_http, orig_network, orig_enabled, orig_execute

    before_each(function()
        http_calls, network_calls = 0, 0
        orig_enabled = updater.enabled
        orig_http, orig_network = package.loaded["socket/http"], package.loaded["ui/network/manager"]
        package.loaded["socket/http"] = { request = function() http_calls = http_calls + 1 return nil end }
        package.loaded["ui/network/manager"] = {
            runWhenOnline = function(self, fn) network_calls = network_calls + 1 (type(self) == "function" and self or fn)() end,
            isOnline = function() return true end,
        }
        orig_execute = os.execute
        os.execute = function() error("the updater must not run commands") end
    end)
    after_each(function()
        updater.enabled = orig_enabled
        package.loaded["socket/http"], package.loaded["ui/network/manager"] = orig_http, orig_network
        os.execute = orig_execute
    end)

    it("is switched off", function()
        assert.is_false(updater.enabled)
    end)

    it("a manual check does nothing: no network, no waiting for the network", function()
        updater.checkForUpdates({ t = function() end }, false)
        updater.checkForUpdates({ t = function() end }, true)
        assert.are.equal(0, network_calls)
        assert.are.equal(0, http_calls)
    end)

    it("a silent check does nothing and never calls back", function()
        local called = false
        updater.checkSilentForUpdates({ t = function() end }, false, { on_done = function() called = true end })
        assert.is_false(called)
        assert.are.equal(0, http_calls)
    end)

    it("the check's inner step does nothing either: no network, nothing shown", function()
        local shown, orig_show = 0, UIManager.show
        UIManager.show = function() shown = shown + 1 end
        updater._doCheckForUpdates("0.0.1", false)
        UIManager.show = orig_show
        assert.are.equal(0, http_calls)
        assert.are.equal(0, shown)
    end)

    it("control: switched on, a manual check does go to the network", function()
        updater.enabled = true
        pcall(updater.checkForUpdates, { t = function() end }, false)
        assert.are.equal(1, network_calls)
    end)
end)

describe("updater: the plugin", function()
    local function newPlugin()
        return setmetatable({
            destroyed = false,
            log = function() end,
            getCurrentPage = function() return 1 end,
            loc = { t = function() return nil end },
            ai_helper = { settings = { last_update_check = 0 }, hasApiKey = function() return true end,
                          saveSettings = function() end },
            characters = {}, timeline = {}, locations = {}, terms = {}, historical_figures = {},
            book_data = {},
            ui = { document = { getPageCount = function() return 10 end, getToc = function() return {} end,
                                getProps = function() return {} end }, getCurrentPage = function() return 1 end },
        }, { __index = XRayPlugin })
    end

    describe("the weekly background check", function()
        local utils, orig_net, orig_check, checks
        before_each(function()
            utils = require("xray_utils")
            orig_net, orig_check = utils.isSilentNetworkAvailable, updater.checkSilentForUpdates
            utils.isSilentNetworkAvailable = function() return true end
            checks = 0
            updater.checkSilentForUpdates = function() checks = checks + 1 end
        end)
        after_each(function()
            utils.isSilentNetworkAvailable, updater.checkSilentForUpdates = orig_net, orig_check
        end)

        it("control: upstream starts one when a week has passed", function()
            newPlugin():checkWeeklyUpdate()
            assert.are.equal(1, checks)
        end)

        it("never starts once Marginalia is running", function()
            local plugin = newPlugin()
            plugin:marginaliaOnReaderReady()
            plugin:checkWeeklyUpdate()
            assert.are.equal(0, checks)
        end)

        it("only changes the plugin it is running for, not upstream's definition", function()
            local plugin = newPlugin()
            plugin:marginaliaOnReaderReady()
            assert.are_not.equal(XRayPlugin.checkWeeklyUpdate, plugin.checkWeeklyUpdate)
        end)
    end)

    describe("the About dialog", function()
        local shown, orig_dialog, orig_show
        before_each(function()
            shown = nil
            orig_dialog, orig_show = package.loaded["ui/widget/buttondialog"], UIManager.show
            package.loaded["ui/widget/buttondialog"] = { new = function(_, opts) shown = opts return opts end }
            UIManager.show = function() end
        end)
        after_each(function()
            package.loaded["ui/widget/buttondialog"], UIManager.show = orig_dialog, orig_show
        end)

        local function labels()
            local out = {}
            for _, b in ipairs(shown.buttons[1]) do out[#out + 1] = b.text end
            return out
        end
        local function about()
            -- the real _meta.lua needs KOReader's translation function: give it a plain one
            os.execute("mkdir -p /tmp/marginalia_about")
            local f = io.open("/tmp/marginalia_about/_meta.lua", "w")
            f:write('return { version = "1.0", fullname = "Test", description = "d" }')
            f:close()
            local plugin = newPlugin()
            plugin.path = "/tmp/marginalia_about"
            plugin:showAbout()
        end

        it("has no 'Check for Updates' button while the updater is off", function()
            about()
            assert.are.same({ "Close" }, labels())
        end)

        it("control: it would have one if the updater were on", function()
            local orig = updater.enabled
            updater.enabled = true
            about()
            updater.enabled = orig
            assert.are.same({ "Close", "Check for Updates" }, labels())
        end)
    end)
end)
