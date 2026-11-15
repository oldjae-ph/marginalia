-- marginalia_menu.lua
-- The "Spoiler boundary" entry in the X-Ray menu: show where the boundary is and
-- let the READER move it. Pure logic; the dialogs are injected (see
-- marginalia_prompt.lua for the real ones), so every flow can be unit-tested.
--
-- Rules: nothing changes until the reader confirms; going BACK says plainly what
-- happens to saved X-Ray data (set aside, not deleted); the menu never moves the
-- boundary any other way. Text is English-only for now.
--
-- deps = {
--   get_session  = function() return session|nil end,
--   current_page = function() return page end,
--   ui = {
--     confirm     = function(text, ok_text, on_ok) end,     -- Cancel does nothing
--     info        = function(text) end,
--     pickChapter = function(title, choices, on_pick) end,  -- choices from Session:chapterChoices()
--   },
-- }

local Menu = {}

local EXPLANATION = "Marginalia only uses the story up to this point: nothing later is read, "
    .. "sent or shown.\n\nOnly you can move it. It moves forward when you answer \"Yes, finished\" "
    .. "at the end of a chapter, or when you set it here."

-- "start of the book" / '"II.", 44% through'
function Menu.statusText(d)
    if not d or not d.settled then return "not set yet" end
    if not d.title then return "start of the book" end
    return string.format('"%s", %d%% through', d.title, d.percent)
end

local function unavailable()
    return {
        { text = "Not available for this book", enabled_func = function() return false end },
    }
end

-- Explain, confirm, then apply. `where` reads as "the end of this page".
local function propose(deps, plan, where, raise_text, raise_ok, lower_ok)
    local ui = deps.ui
    local session = deps.get_session()
    if not plan then
        ui.info("Could not work out where that is in the book.")
        return
    end
    if plan.same then
        ui.info("The boundary is already at " .. where .. ".")
        return
    end
    local text, ok_text
    if plan.lowers then
        text = "Move the boundary back to " .. where .. "?\n\n"
            .. "X-Ray data made further on will be set aside (kept, not deleted), "
            .. "and X-Ray will start again from here."
        ok_text = lower_ok or "Yes, move back"
    else
        text = "Set the boundary at " .. where .. "?\n\n" .. raise_text
        ok_text = raise_ok
    end
    ui.confirm(text, ok_text, function()
        if session:apply(plan) then
            ui.info("Boundary set at " .. where .. ".")
        else
            ui.info("Could not change the boundary.")
        end
    end)
end

local function chooseChapter(deps)
    local session = deps.get_session()
    local choices = session:chapterChoices()
    if #choices == 0 then
        deps.ui.info("No chapters were found in this book's table of contents.")
        return
    end
    deps.ui.pickChapter("I have finished up to...", choices, function(choice)
        local plan = session:planAtChapterEnd(choice.index)
        propose(deps, plan, 'the end of "' .. choice.title .. '"',
            "Marginalia will use the story up to the end of that chapter.", "Yes, I've finished it")
    end)
end

-- The entries inside the submenu. Built fresh each time the menu opens.
function Menu.subItems(deps)
    local session = deps.get_session()
    if not session then return unavailable() end
    return {
        {
            text_func = function() return "Now: " .. Menu.statusText(session:describe()) end,
            keep_menu_open = true,
            callback = function() deps.ui.info(EXPLANATION) end,
            separator = true,
        },
        {
            text = "I have read up to here (end of this page)",
            callback = function()
                propose(deps, session:planAtPage(deps.current_page()), "the end of this page",
                    "Marginalia will use the story up to here.", "Yes, up to here")
            end,
        },
        {
            text = "I have finished a chapter...",
            callback = function() chooseChapter(deps) end,
        },
        {
            text = "Back to the start of the book",
            callback = function()
                propose(deps, session:planAtStart(), "the start of the book", "", "Yes, start over", "Yes, start over")
            end,
        },
    }
end

-- The top-level entry. Its label shows the boundary, so it is visible at a glance.
function Menu.topItem(deps)
    local function label()
        local session = deps.get_session()
        return "Spoiler boundary: " .. Menu.statusText(session and session:describe())
    end
    return {
        text = "Spoiler boundary",
        text_func = label,
        separator = true,
        sub_item_table_func = function() return Menu.subItems(deps) end,
    }
end

return Menu
