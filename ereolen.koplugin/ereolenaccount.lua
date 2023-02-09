local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local Cache = require("cache")
local ConfirmBox = require("ui/widget/confirmbox")
local DocumentRegistry = require("document/documentregistry")
local Font = require("ui/font")
local ImageViewer = require("ui/widget/imageviewer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputDialog = require("ui/widget/inputdialog")
local Button = require("ui/widget/button")
local VerticalGroup = require("ui/widget/verticalgroup")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local Blitbuffer = require("ffi/blitbuffer")
local TextWidget = require("ui/widget/textwidget")
local HorizontalGroup = require("ui/widget/horizontalgroup")

--local ffi = require("ffi")
--local lnf = require("libereolenwrapper")
--ffi.cdef[[
--void Sleep(int ms);
--int poll(struct pollfd *fds, unsigned long nfds, int timeout);
--]]

--local ffi = require("ffi")
--require("ffi/zlib_h")
--
--local libz
--if ffi.os == "Windows" then
--    libz = ffi.load("libs/libz1.dll")
--elseif ffi.os == "OSX" then
--    libz = ffi.load("libs/libz.1.dylib")
--else
--    libz = ffi.load("libs/libz.so.1")
--end
--
--package.cpath = package.cpath..";plugins/ereolen.koplugin/lib/?.so"


--src/plugins/ereolen.koplugin/lib/libereolenwrapper.so



local EReolenAccount = Menu:extend{
    width = Screen:getWidth(),
    height = Screen:getHeight() * 0.9,
    no_title = false,
    parent = nil,
}



function EReolenAccount:init()
    self.title = "Account"
    self.title_bar_left_icon = nil
    self.item_table = self:genStartStateItemTable()
    Menu.init(self) -- call parent's init()
end

function EReolenAccount:genStartStateItemTable()

    local item_table = {}
    table.insert(item_table, {
        text = "Loans", deletable = false, editable = false,
        callback = function() self:showLoans() end,
    })
    table.insert(item_table, {
        text = "Reservations", deletable = false, editable = false,
        callback = function() self:showReservations() end,
    })
    table.insert(item_table, {
        text = "Checklist", deletable = false, editable = false,
        callback = function() self:showChecklist() end,
    })
    table.insert(item_table, {
        text = "Loan history", deletable = false, editable = false,
        callback = function() self:showLoanHistory() end,
    })
    table.insert(item_table, {
        text = "Settings", deletable = false, editable = false,
        callback = function() self:showSettings() end,
    })
    return item_table
end

function EReolenAccount:showLoans()
    local item_table = {}
    table.insert(item_table, {
        text = "R1",
        deletable = false, editable = false,
    })
    table.insert(item_table, {
        text = "R2",
        deletable = false, editable = false,
    })
    table.insert(item_table, {
        text = "R3",
        deletable = false, editable = false,
    })
    table.insert(item_table, {
        text = "Back",
        deletable = false, editable = false,
        callback = function()
            self:init()
        end,
    })
    self.title = "Loans"
    self.item_table = item_table
    Menu.init(self)
end

function EReolenAccount:showReservations()
    local item_table = {}
    table.insert(item_table, {
        text = "R1",
        deletable = false, editable = false,
    })
    table.insert(item_table, {
        text = "R2",
        deletable = false, editable = false,
    })
    table.insert(item_table, {
        text = "R3",
        deletable = false, editable = false,
    })
    table.insert(item_table, {
        text = "Back",
        deletable = false, editable = false,
        callback = function()
            self:init()
        end,
    })
    self.title = "Reservations"
    self.item_table = item_table
    Menu.init(self)
end

function EReolenAccount:showChecklist()
    local item_table = {}
    table.insert(item_table, {
        text = "R1",
        deletable = false, editable = false,
    })
    table.insert(item_table, {
        text = "R2",
        deletable = false, editable = false,
    })
    table.insert(item_table, {
        text = "R3",
        deletable = false, editable = false,
    })
    table.insert(item_table, {
        text = "Back",
        deletable = false, editable = false,
        callback = function()
            self:init()
        end,
    })
    self.title = "Checklist"
    self.item_table = item_table
    Menu.init(self)
end

function EReolenAccount:showLoanHistory()
    local item_table = {}
    table.insert(item_table, {
        text = "R1",
        deletable = false, editable = false,
    })
    table.insert(item_table, {
        text = "R2",
        deletable = false, editable = false,
    })
    table.insert(item_table, {
        text = "R3",
        deletable = false, editable = false,
    })
    table.insert(item_table, {
        text = "Back",
        deletable = false, editable = false,
        callback = function()
            self:init()
        end,
    })
    self.title = "Loan History"
    self.item_table = item_table
    Menu.init(self)
end

function EReolenAccount:showSettings()
    local item_table = {}
    table.insert(item_table, {
        text = "R1",
        deletable = false, editable = false,
    })
    table.insert(item_table, {
        text = "R2",
        deletable = false, editable = false,
    })
    table.insert(item_table, {
        text = "R3",
        deletable = false, editable = false,
    })
    table.insert(item_table, {
        text = "Back",
        deletable = false, editable = false,
        callback = function()
            self:init()
        end,
    })
    self.title = "Settings"
    self.item_table = item_table
    Menu.init(self)
end

return EReolenAccount
