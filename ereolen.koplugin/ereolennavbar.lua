--[[--
The bottom navigation bar.

It used to be five hard-edged buttons of equal width with shouty uppercase
labels, which is not what the rest of KOReader looks like and read as five
identical boxes with no sense of where you were.

This is an icon over a label per tab, borderless, with a rule above the tab you
are on -- so the bar is quieter than the content above it, and it says which
section is showing.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Screen = Device.screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local NavTab = InputContainer:extend{}

function NavTab:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
    self:update()
end

function NavTab:update()
    local indicator_h = Size.line.thick
    local label = TextWidget:new{
        text = self.label,
        face = Font:getFace(self.active and "tfont" or "cfont", 14),
        max_width = self.width - 2 * Size.padding.small,
    }
    local icon = IconWidget:new{
        icon = self.icon,
        width = Size.item.height_default,
        height = Size.item.height_default,
        dim = not self.active,
    }
    local body = VerticalGroup:new{
        align = "center",
        -- A rule only over the current tab. Reserving the same height on the
        -- others keeps every label on the same baseline.
        self.active
            and LineWidget:new{
                background = Blitbuffer.COLOR_BLACK,
                dimen = Geom:new{ w = math.floor(self.width * 0.5), h = indicator_h },
            }
            or VerticalSpan:new{ width = indicator_h },
        VerticalSpan:new{ width = Size.padding.small },
        icon,
        VerticalSpan:new{ width = Size.padding.tiny or 1 },
        label,
    }

    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        margin = 0,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            body,
        },
    }
end

function NavTab:setActive(active)
    if self.active == active then return end
    self.active = active
    self:update()
end

function NavTab:onTap()
    if self.callback then self.callback() end
    return true
end

local EReolenNavBar = InputContainer:extend{
    -- { { id=, label=, icon=, callback= }, ... }
    tabs = nil,
    height = nil,
}

function EReolenNavBar:init()
    local width = Screen:getWidth()
    self.height = self.height or math.floor(Screen:getHeight() * 0.085)
    self.dimen = Geom:new{ x = 0, y = 0, w = width, h = self.height }

    local count = #self.tabs
    local tab_w = math.floor(width / count)
    local group = HorizontalGroup:new{ align = "top" }
    self.cells = {}
    for i, tab in ipairs(self.tabs) do
        -- The last cell takes any rounding remainder so the row fills the width.
        local w = (i == count) and (width - tab_w * (count - 1)) or tab_w
        local cell = NavTab:new{
            width = w,
            height = self.height - Size.line.thin,
            label = tab.label,
            icon = tab.icon,
            active = i == 1,
            callback = tab.callback,
            show_parent = self.show_parent or self,
        }
        self.cells[tab.id] = cell
        table.insert(group, cell)
    end

    self[1] = FrameContainer:new{
        width = width,
        height = self.height,
        margin = 0,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            LineWidget:new{
                background = Blitbuffer.COLOR_GRAY,
                dimen = Geom:new{ w = width, h = Size.line.thin },
            },
            group,
        },
    }
end

--- Mark one tab as the current one.
function EReolenNavBar:setActive(id)
    for tab_id, cell in pairs(self.cells) do
        cell:setActive(tab_id == id)
    end
end

return EReolenNavBar
