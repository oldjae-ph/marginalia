-- marginalia_debriefui.lua
-- The screens of the chapter debrief. UI only: marginalia_debriefflow.lua decides what
-- happens. E-ink: plain black and white, large buttons, no animation. The busy message,
-- the info message and the chapter list are the same ones the reading guide uses.

local UIManager = require("ui/uimanager")

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""

local DebriefUI = {}

local function once(fn)
    local done = false
    return function(...)
        if done then return end
        done = true
        return fn(...)
    end
end

function DebriefUI.working(text)
    local InfoMessage = require("ui/widget/infomessage")
    local widget = InfoMessage:new{ text = text }
    UIManager:show(widget)
    UIManager:forceRePaint()
    return widget
end

function DebriefUI.closeWorking(widget)
    if widget then UIManager:close(widget) end
end

function DebriefUI.info(text)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text, timeout = 8 })
end

function DebriefUI.pickChapter(title, choices, on_pick)
    return require(plugin_path .. "marginalia_prompt").pickChapter(title, choices, on_pick)
end

-- The second-pass check did not pass, or could not run. The reader chooses; nothing is
-- swapped silently. kind is "flagged" or "unchecked".
function DebriefUI.warn(kind, detail, handlers)
    local ButtonDialog = require("ui/widget/buttondialog")
    local regenerate, show_anyway, cancel = once(handlers.regenerate), once(handlers.show_anyway), once(handlers.cancel)
    local text
    if kind == "flagged" then
        text = "The spoiler check thinks this debrief may reveal something beyond what you have read.\n\n"
            .. "You can have a new one written, or read this one anyway."
    else
        text = "The spoiler check could not run, so this debrief has not been checked for spoilers.\n\n"
            .. "You can try again, or read it unchecked."
        if type(detail) == "string" and detail ~= "" then text = text .. "\n\n(" .. detail:sub(1, 160) .. ")" end
    end
    local dialog
    local function pick(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end
    dialog = ButtonDialog:new{
        title = text,
        buttons = {
            { { text = "Write a new debrief", callback = pick(regenerate) } },
            {
                { text = "Show anyway", callback = pick(show_anyway) },
                { text = "Cancel", callback = pick(cancel) },
            },
        },
    }
    UIManager:show(dialog)
end

-- The debrief, scrollable: "In brief" is the first thing on the screen.
function DebriefUI.show(chapter_title, text, handlers)
    local TextViewer = require("ui/widget/textviewer")
    local viewer
    viewer = TextViewer:new{
        title = "Debrief: " .. tostring(chapter_title),
        text = text,
        justified = false,
        buttons_table = {
            {
                {
                    text = "Write again",
                    callback = function()
                        UIManager:close(viewer)
                        handlers.write_again()
                    end,
                },
            },
        },
    }
    UIManager:show(viewer)
end

return DebriefUI
