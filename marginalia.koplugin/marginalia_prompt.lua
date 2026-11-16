-- marginalia_prompt.lua
-- The two questions Marginalia asks the reader. UI only; the decisions live in
-- marginalia_session.lua. E-ink friendly: plain ConfirmBox, black and white, no
-- animation, the large default buttons.
--
-- Dismissing a box (back key, tap outside) counts as the cautious answer
-- ("Not yet" / "start of the book"), never as a confirmation.
--
-- Never pass `icon = false` to ConfirmBox: KOReader (v2026.07.1) always builds an
-- IconWidget from it and crashes the whole app on a boolean. Leave the default.

local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")

local Prompt = {}

local function once(fn)
    local done = false
    return function(...)
        if done then return end
        done = true
        return fn(...)
    end
end

-- "You started a new chapter. Have you finished <previous>?"
-- With on_yes_debrief the question has three answers (as in the spec's screen):
-- [Mark done + debrief] [Mark done] [Not yet]. Dismissing it counts as "Not yet".
function Prompt.askFinished(finished_title, on_yes, on_not_yet, on_yes_debrief)
    local yes, no = once(on_yes), once(on_not_yet)
    local text
    if finished_title and finished_title ~= "" then
        text = string.format('You have started a new chapter.\n\nHave you finished "%s"?', finished_title)
    else
        text = "You have started a new chapter.\n\nHave you finished the previous chapter?"
    end
    if on_yes_debrief then
        local yes_debrief = once(on_yes_debrief)
        UIManager:nextTick(function()
            local ButtonDialog = require("ui/widget/buttondialog")
            local dialog
            local function pick(fn)
                return function()
                    UIManager:close(dialog)
                    fn()
                end
            end
            dialog = ButtonDialog:new{
                title = text .. "\n\nMarking it done moves your spoiler boundary forward. You can move it back any time.",
                tap_close_callback = no,
                buttons = {
                    { { text = "Mark done + debrief", callback = pick(yes_debrief) } },
                    {
                        { text = "Mark done", callback = pick(yes) },
                        { text = "Not yet", callback = pick(no) },
                    },
                },
            }
            UIManager:show(dialog)
        end)
        return
    end
    -- nextTick: let the page finish drawing before the dialog appears.
    UIManager:nextTick(function()
        UIManager:show(ConfirmBox:new{
            text = text,
            ok_text = "Yes, finished",
            cancel_text = "Not yet",
            ok_callback = yes,
            cancel_callback = no,
        })
    end)
end

-- First open of a book that is not at its start: where is the reader?
function Prompt.askInitial(on_here, on_start)
    local here, start = once(on_here), once(on_start)
    UIManager:nextTick(function()
        UIManager:show(ConfirmBox:new{
            text = "Marginalia only uses the story up to the point you have read.\n\n"
                .. "Have you already read up to this page?",
            ok_text = "Yes, up to here",
            cancel_text = "No, I'm at the start",
            ok_callback = here,
            cancel_callback = start,
        })
    end)
end

-- ---------------------------------------------------------------------------
-- Dialogs for the Spoiler boundary menu (see marginalia_menu.lua).
-- ---------------------------------------------------------------------------

-- A yes/cancel question. Cancel (or back, or tapping outside) does nothing.
function Prompt.confirm(text, ok_text, on_ok)
    local yes = once(on_ok)
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = ok_text,
        cancel_text = "Cancel",
        ok_callback = yes,
    })
end

function Prompt.info(text)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text, timeout = 6 })
end

-- A full-screen list of chapters; choosing one calls on_pick(choice).
function Prompt.pickChapter(title, choices, on_pick)
    local Menu = require("ui/widget/menu")
    local items = {}
    for _, choice in ipairs(choices) do
        items[#items + 1] = {
            text = choice.title .. (choice.is_current and "   (current)" or ""),
            callback = function() on_pick(choice) end,
        }
    end
    local menu
    menu = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

return Prompt
