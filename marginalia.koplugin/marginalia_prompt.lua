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
function Prompt.askFinished(finished_title, on_yes, on_not_yet)
    local yes, no = once(on_yes), once(on_not_yet)
    local text
    if finished_title and finished_title ~= "" then
        text = string.format('You have started a new chapter.\n\nHave you finished "%s"?', finished_title)
    else
        text = "You have started a new chapter.\n\nHave you finished the previous chapter?"
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

return Prompt
