-- Specs for marginalia_menu.lua: the "Spoiler boundary" menu. Real session and
-- boundary, fake dialogs. Nothing may change until the reader confirms.
package.path = "marginalia.koplugin/?.lua;" .. package.path

local Session = require("marginalia_session")
local MenuBuilder = require("marginalia_menu")

local TOC = {
    { page = 1, title = "The Idiot" },
    { page = 2, title = "Contents" },
    { page = 3, title = "PART I" },
    { page = 4, title = "I." },
    { page = 14, title = "II." },
    { page = 30, title = "III." },
}

-- A started session plus recorded dialogs. opts.page = the page the reader is on.
local function newEnv(opts)
    opts = opts or {}
    local env = { page = opts.page or 1, confirms = {}, infos = {}, picks = {}, lowered = 0, applied = 0 }
    env.session = Session:new({
        get_toc = function()
            if opts.no_toc then return nil end
            return TOC, 60
        end,
        store = { load = function() return nil end, save = function() end },
        prompter = { askFinished = function() end, askInitial = function() end },
        book_title = "The Idiot",
        is_nonnarrative = function(t) return t:lower() == "contents" end,
        on_lowered = function() env.lowered = env.lowered + 1 end,
    })
    local real_apply = env.session.apply
    env.session.apply = function(self, plan) env.applied = env.applied + 1; return real_apply(self, plan) end
    env.session:start(1)
    env.ui = {
        confirm = function(text, ok_text, on_ok) env.confirms[#env.confirms + 1] = { text = text, ok_text = ok_text, on_ok = on_ok } end,
        info = function(text) env.infos[#env.infos + 1] = text end,
        pickChapter = function(title, choices, on_pick) env.picks[#env.picks + 1] = { title = title, choices = choices, on_pick = on_pick } end,
    }
    env.deps = {
        get_session = function() return env.session end,
        current_page = function() return env.page end,
        ui = env.ui,
    }
    return env
end

local function item(env, label_start)
    for _, it in ipairs(MenuBuilder.subItems(env.deps)) do
        local label = it.text or (it.text_func and it.text_func())
        if label and label:sub(1, #label_start) == label_start then return it end
    end
    error("no menu item starting with: " .. label_start)
end

local function readTo(env, page) for p = 1, page do env.session:onPageUpdate(p) end end
local function last(list) return list[#list] end

describe("Menu: status", function()
    it("describes the boundary in words", function()
        assert.are.equal("not set yet", MenuBuilder.statusText(nil))
        assert.are.equal("not set yet", MenuBuilder.statusText({ settled = false }))
        assert.are.equal("start of the book", MenuBuilder.statusText({ settled = true }))
        assert.are.equal('"II.", 44% through', MenuBuilder.statusText({ settled = true, title = "II.", percent = 44 }))
    end)

    it("the top entry shows the boundary on its label and is kept current", function()
        local env = newEnv()
        local top = MenuBuilder.topItem(env.deps)
        assert.are.equal("Spoiler boundary: start of the book", top.text_func())
        readTo(env, 8)
        assert.are.equal('Spoiler boundary: "I.", 50% through', top.text_func())
    end)

    it("the top entry builds its submenu fresh each time", function()
        local env = newEnv()
        local top = MenuBuilder.topItem(env.deps)
        assert.are_not.equal(top.sub_item_table_func(), top.sub_item_table_func())
    end)

    it("offers a disabled placeholder when there is no session", function()
        local deps = { get_session = function() return nil end, current_page = function() return 1 end, ui = {} }
        local items = MenuBuilder.subItems(deps)
        assert.are.equal(1, #items)
        assert.is_false(items[1].enabled_func())
        assert.are.equal("Spoiler boundary: not set yet", MenuBuilder.topItem(deps).text_func())
    end)

    it("has the expected entries", function()
        local env = newEnv()
        local items = MenuBuilder.subItems(env.deps)
        assert.are.equal(4, #items)
        assert.are.equal("Now: start of the book", items[1].text_func())
        assert.are.equal("I have read up to here (end of this page)", items[2].text)
        assert.are.equal("I have finished a chapter...", items[3].text)
        assert.are.equal("Back to the start of the book", items[4].text)
    end)

    it("tapping the status explains the boundary and changes nothing", function()
        local env = newEnv()
        local before = env.session:getLimit()
        item(env, "Now:").callback()
        assert.are.equal(1, #env.infos)
        assert.is_true(env.infos[1]:find("Only you can move it", 1, true) ~= nil)
        assert.are.same(before, env.session:getLimit())
    end)
end)

describe("Menu: I have read up to here", function()
    it("asks first and changes nothing until the reader says yes", function()
        local env = newEnv({ page = 20 })
        item(env, "I have read up to here").callback()
        assert.are.equal(1, #env.confirms)
        assert.is_true(last(env.confirms).text:find("Set the boundary at the end of this page", 1, true) ~= nil)
        assert.are.equal("Yes, up to here", last(env.confirms).ok_text)
        assert.are.same({ chapter = 1, frac = 0 }, env.session:getLimit())
        assert.are.equal(0, env.applied)
    end)

    it("moves the boundary to the end of this page on yes, and says so", function()
        local env = newEnv({ page = 20 })
        item(env, "I have read up to here").callback()
        last(env.confirms).on_ok()
        assert.are.equal(5, env.session:getLimit().chapter)
        assert.are.equal("Boundary set at the end of this page.", last(env.infos))
        assert.are.equal(0, env.lowered)
    end)

    it("when going BACK, says what happens to X-Ray data", function()
        local env = newEnv({ page = 35 })
        item(env, "I have read up to here").callback()
        last(env.confirms).on_ok() -- boundary now at page 35
        env.page = 20
        item(env, "I have read up to here").callback()
        local ask = last(env.confirms)
        assert.is_true(ask.text:find("Move the boundary back", 1, true) ~= nil)
        assert.is_true(ask.text:find("set aside (kept, not deleted)", 1, true) ~= nil)
        assert.are.equal("Yes, move back", ask.ok_text)
        ask.on_ok()
        assert.are.equal(1, env.lowered)
    end)

    it("does nothing but explain when the boundary is already there", function()
        local env = newEnv({ page = 20 })
        item(env, "I have read up to here").callback()
        last(env.confirms).on_ok()
        local asked = #env.confirms
        item(env, "I have read up to here").callback()
        assert.are.equal(asked, #env.confirms)
        assert.are.equal("The boundary is already at the end of this page.", last(env.infos))
    end)

    it("says so when it cannot place the page", function()
        local env = newEnv({ page = 20 })
        env.page = 999
        item(env, "I have read up to here").callback()
        assert.are.equal(0, #env.confirms)
        assert.are.equal("Could not work out where that is in the book.", last(env.infos))
    end)

    it("cancelling (never answering) changes nothing", function()
        local env = newEnv({ page = 20 })
        local before = env.session:getLimit()
        item(env, "I have read up to here").callback()
        assert.are.same(before, env.session:getLimit())
        assert.are.equal(0, env.applied)
    end)
end)

describe("Menu: I have finished a chapter", function()
    it("lists the real chapters and changes nothing yet", function()
        local env = newEnv()
        item(env, "I have finished a chapter").callback()
        assert.are.equal(1, #env.picks)
        local titles = {}
        for _, c in ipairs(env.picks[1].choices) do titles[#titles + 1] = c.title end
        assert.are.same({ "I.", "II.", "III." }, titles)
        assert.are.same({ chapter = 1, frac = 0 }, env.session:getLimit())
    end)

    it("asks about the chosen chapter by name, then moves to its end", function()
        local env = newEnv()
        item(env, "I have finished a chapter").callback()
        env.picks[1].on_pick(env.picks[1].choices[2]) -- "II."
        local ask = last(env.confirms)
        assert.is_true(ask.text:find('Set the boundary at the end of "II."', 1, true) ~= nil)
        assert.are.equal("Yes, I've finished it", ask.ok_text)
        assert.are.equal(0, env.applied)
        ask.on_ok()
        assert.are.same({ chapter = 5, frac = 1 }, env.session:getLimit())
        assert.are.equal('Boundary set at the end of "II.".', last(env.infos))
    end)

    it("choosing an earlier chapter than the boundary warns and, on yes, moves back", function()
        local env = newEnv()
        env.session:apply(env.session:planAtChapterEnd(6))
        item(env, "I have finished a chapter").callback()
        env.picks[1].on_pick(env.picks[1].choices[1]) -- "I."
        local ask = last(env.confirms)
        assert.is_true(ask.text:find("Move the boundary back", 1, true) ~= nil)
        ask.on_ok()
        assert.are.equal(4, env.session:getLimit().chapter)
        assert.are.equal(1, env.lowered)
    end)

    it("says so when the book has no chapters to choose from", function()
        local env = newEnv({ no_toc = true })
        item(env, "I have finished a chapter").callback()
        assert.are.equal(0, #env.picks)
        assert.are.equal("No chapters were found in this book's table of contents.", last(env.infos))
    end)
end)

describe("Menu: back to the start of the book", function()
    it("explains it is already there when it is", function()
        local env = newEnv()
        item(env, "Back to the start").callback()
        assert.are.equal(0, #env.confirms)
        assert.are.equal("The boundary is already at the start of the book.", last(env.infos))
    end)

    it("warns that data is set aside, and only acts on yes", function()
        local env = newEnv()
        env.session:apply(env.session:planAtChapterEnd(6))
        item(env, "Back to the start").callback()
        local ask = last(env.confirms)
        assert.is_true(ask.text:find("Move the boundary back to the start of the book", 1, true) ~= nil)
        assert.is_true(ask.text:find("set aside (kept, not deleted)", 1, true) ~= nil)
        assert.are.equal("Yes, start over", ask.ok_text)
        assert.are.equal(6, env.session:getLimit().chapter)
        ask.on_ok()
        assert.are.same({ chapter = 1, frac = 0 }, env.session:getLimit())
        assert.are.equal(1, env.lowered)
    end)
end)

describe("Menu: only the reader moves the boundary", function()
    it("opening, browsing and cancelling every entry never applies a change", function()
        local env = newEnv({ page = 20 })
        MenuBuilder.topItem(env.deps).text_func()
        for _, it in ipairs(MenuBuilder.subItems(env.deps)) do
            if it.callback then it.callback() end
        end
        if env.picks[1] then env.picks[1].on_pick(env.picks[1].choices[1]) end
        -- every confirmation is left unanswered
        assert.are.equal(0, env.applied)
        assert.are.same({ chapter = 1, frac = 0 }, env.session:getLimit())
    end)

    it("reports a failed change instead of pretending it worked", function()
        local env = newEnv({ page = 20 })
        item(env, "I have read up to here").callback()
        env.session.apply = function() return false end
        last(env.confirms).on_ok()
        assert.are.equal("Could not change the boundary.", last(env.infos))
    end)
end)
