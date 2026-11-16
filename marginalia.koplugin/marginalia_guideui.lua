-- marginalia_guideui.lua
-- The screens of the reading guide. UI only: marginalia_guideflow.lua decides what
-- happens. E-ink: plain black and white, large buttons, no animation.
-- Closing a dialog with the back key counts as the cautious answer: nothing is saved,
-- nothing is shown.

local UIManager = require("ui/uimanager")

local GuideUI = {}

local function once(fn)
    local done = false
    return function(...)
        if done then return end
        done = true
        return fn(...)
    end
end

-- "New book. Create a reading guide?"  [Create reading guide] [Later] [Not for this book]
function GuideUI.offer(title, handlers)
    local ButtonDialog = require("ui/widget/buttondialog")
    local create, later, never = once(handlers.create), once(handlers.later), once(handlers.never)
    local dialog
    local function pick(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end
    -- nextTick: let the page finish drawing before the dialog appears
    UIManager:nextTick(function()
        dialog = ButtonDialog:new{
            title = string.format("New book%s\n\nCreate a spoiler-free reading guide? It covers the author, the period, "
                .. "the characters you meet at the start and themes to watch for.",
                (title and title ~= "") and (": " .. title) or ""),
            buttons = {
                { { text = "Create reading guide", callback = pick(create) } },
                {
                    { text = "Later", callback = pick(later) },
                    { text = "Not for this book", callback = pick(never) },
                },
            },
        }
        UIManager:show(dialog)
    end)
end

-- A message with no timeout, shown while the AI is working. Close it with closeWorking.
function GuideUI.working(text)
    local InfoMessage = require("ui/widget/infomessage")
    local widget = InfoMessage:new{ text = text }
    UIManager:show(widget)
    UIManager:forceRePaint()
    return widget
end

function GuideUI.closeWorking(widget)
    if widget then UIManager:close(widget) end
end

function GuideUI.info(text)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text, timeout = 8 })
end

-- The second-pass check did not pass, or could not run. Never a silent swap: the reader
-- chooses. kind is "flagged" or "unchecked".
function GuideUI.warn(kind, detail, handlers)
    local ButtonDialog = require("ui/widget/buttondialog")
    local regenerate, show_anyway, cancel = once(handlers.regenerate), once(handlers.show_anyway), once(handlers.cancel)
    local text
    if kind == "flagged" then
        text = "The spoiler check thinks this guide may reveal something about the story.\n\n"
            .. "You can have a new one written, or read this one anyway."
    else
        text = "The spoiler check could not run, so this guide has not been checked for spoilers.\n\n"
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
            { { text = "Write a new guide", callback = pick(regenerate) } },
            {
                { text = "Show anyway", callback = pick(show_anyway) },
                { text = "Cancel", callback = pick(cancel) },
            },
        },
    }
    UIManager:show(dialog)
end

-- The guide itself, scrollable. handlers: regenerate, change_genre.
function GuideUI.show(text, genre_label, handlers)
    local TextViewer = require("ui/widget/textviewer")
    local viewer
    local function pick(fn)
        return function()
            UIManager:close(viewer)
            fn()
        end
    end
    viewer = TextViewer:new{
        title = "Reading guide",
        text = text,
        justified = false,
        buttons_table = {
            {
                { text = "Genre: " .. tostring(genre_label), callback = pick(handlers.change_genre) },
                { text = "Write again", callback = pick(handlers.regenerate) },
            },
        },
    }
    UIManager:show(viewer)
end

-- A list of genres; choosing one calls on_pick(id).
function GuideUI.pickGenre(genres, current, on_pick)
    local Menu = require("ui/widget/menu")
    local items = {}
    for _, genre in ipairs(genres) do
        items[#items + 1] = {
            text = genre.label .. (genre.id == current and "   (current)" or ""),
            callback = function()
                UIManager:close(GuideUI._genre_menu)
                on_pick(genre.id)
            end,
        }
    end
    GuideUI._genre_menu = Menu:new{
        title = "Genre of this book",
        item_table = items,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        close_callback = function() UIManager:close(GuideUI._genre_menu) end,
    }
    UIManager:show(GuideUI._genre_menu)
end

return GuideUI
