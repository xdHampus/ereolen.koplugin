--[[--
The detail page for one title, as a page rather than a menu.

A book has a shape that a list of rows cannot express: cover, title, author,
what it is, whether you have it, what it is about, and only then the places you
can go next. So this is a full-screen widget -- cover and facts across the top,
the actions that matter as buttons under them, the whole summary in running
text, and the optional sections as a quiet list at the bottom.

It scrolls, because a summary can be long and an e-reader screen is not.

Shown over whatever list you came from, so closing it puts you back exactly
where you were with no reload.
]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Screen = Device.screen
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local EReolenItemPage = InputContainer:extend{
    -- Filled in by the caller.
    record = nil,
    cover_bb = nil,
    headline = nil,      -- author line
    facts = nil,         -- "E-bog · 2019 · Dansk · Gyldendal"
    series = nil,
    status_text = nil,   -- "Borrowed — expires 2026-08-24"
    summary = nil,
    actions = nil,       -- { {text=, callback=, disabled=}, ... }  shown as buttons
    sections = nil,      -- { {text=, callback=}, ... }             shown as rows
    on_close = nil,
}

function EReolenItemPage:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    if Device:isTouchDevice() then
        self.ges_events.Close = {
            GestureRange:new{ ges = "swipe", range = self.dimen },
        }
    end
    self.key_events.Close = { { Device.input.group.Back } }

    local pad = Size.padding.large
    -- The scrollable container reserves 3x its bar width on the right; content
    -- laid out to the full width gets clipped there (the summary lost its last
    -- word or two on every line).
    local scrollbar_w = 3 * ScrollableContainer.scroll_bar_width
    local inner_w = self.dimen.w - 2 * pad - scrollbar_w

    self.title_bar = TitleBar:new{
        width = self.dimen.w,
        fullscreen = true,
        align = "center",
        title = self.record.title,
        title_multilines = true,
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    local body = VerticalGroup:new{ align = "left" }

    ------------------------------------------------------------------ header
    -- Big enough to be the page's anchor, small enough that the facts beside it
    -- are not stranded in white space.
    local cover_w = math.floor(inner_w * 0.30)
    local cover_h = math.floor(cover_w * 1.45)
    local facts_w = inner_w - cover_w - pad

    local facts = VerticalGroup:new{ align = "left" }
    local function line(text, face, gap)
        if not text or text == "" then return end
        if gap then table.insert(facts, VerticalSpan:new{ width = gap }) end
        table.insert(facts, TextBoxWidget:new{
            text = text,
            face = face,
            width = facts_w,
        })
    end
    line(self.record.title, Font:getFace("tfont", 22))
    line(self.headline, Font:getFace("cfont", 18), Size.padding.small)
    line(self.facts, Font:getFace("cfont", 15), Size.padding.default)
    line(self.series, Font:getFace("cfont", 15), Size.padding.small)
    line(self.status_text, Font:getFace("tfont", 16), Size.padding.default)

    local cover
    if self.cover_bb then
        cover = CenterContainer:new{
            dimen = Geom:new{ w = cover_w, h = cover_h },
            ImageWidget:new{
                image = self.cover_bb,
                -- The cover cache owns this buffer.
                image_disposable = false,
            },
        }
    else
        cover = FrameContainer:new{
            width = cover_w, height = cover_h,
            margin = 0, padding = 0, bordersize = Size.border.thin,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = cover_w, h = cover_h },
                TextBoxWidget:new{
                    text = _("No cover"),
                    face = Font:getFace("cfont", 14),
                    width = cover_w - 2 * Size.padding.default,
                    alignment = "center",
                },
            },
        }
    end

    table.insert(body, HorizontalGroup:new{
        align = "top",
        cover,
        HorizontalSpan:new{ width = pad },
        facts,
    })

    ----------------------------------------------------------------- actions
    if self.actions and #self.actions > 0 then
        table.insert(body, VerticalSpan:new{ width = pad })
        -- One per row. Two side by side looked tidier until a label like
        -- "Remove from want-to-read" ran off the end of its half.
        local rows = {}
        for i = 1, #self.actions do
            local action = self.actions[i]
            table.insert(rows, { {
                text = action.text,
                enabled = action.callback ~= nil,
                callback = action.callback and function() action.callback() end or nil,
            } })
        end
        table.insert(body, ButtonTable:new{
            width = inner_w,
            buttons = rows,
            zero_sep = true,
            show_parent = self,
        })
    end

    ----------------------------------------------------------------- summary
    if self.summary and self.summary ~= "" then
        table.insert(body, VerticalSpan:new{ width = pad })
        table.insert(body, TextBoxWidget:new{
            text = self.summary,
            face = Font:getFace("cfont", 18),
            width = inner_w,
            justified = true,
        })
    end

    ---------------------------------------------------------------- sections
    if self.sections and #self.sections > 0 then
        table.insert(body, VerticalSpan:new{ width = pad })
        table.insert(body, LineWidget:new{
            background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{ w = inner_w, h = Size.line.thin },
        })
        local rows = {}
        for _, section in ipairs(self.sections) do
            table.insert(rows, { {
                text = section.text,
                align = "left",
                callback = function() section.callback() end,
            } })
        end
        table.insert(body, ButtonTable:new{
            width = inner_w,
            buttons = rows,
            zero_sep = true,
            show_parent = self,
        })
    end

    table.insert(body, VerticalSpan:new{ width = pad })

    local body_h = self.dimen.h - self.title_bar:getHeight()
    self.scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = self.dimen.w, h = body_h },
        show_parent = self,
        FrameContainer:new{
            width = self.dimen.w - scrollbar_w,
            margin = 0,
            padding = pad,
            padding_top = Size.padding.default,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            body,
        },
    }

    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        margin = 0,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            self.title_bar,
            self.scroll,
        },
    }
end

function EReolenItemPage:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function EReolenItemPage:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

function EReolenItemPage:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

--- A swipe in any direction closes, matching ImageViewer and TextViewer.
function EReolenItemPage:onSwipe(_, ges)
    if ges.direction == "south" or ges.direction == "east" then
        return self:onClose()
    end
    return false
end

EReolenItemPage.onCloseGesture = EReolenItemPage.onClose

return EReolenItemPage
