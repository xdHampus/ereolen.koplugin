local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Screen = require("device").screen
local T = require("ffi/util").template
local Button = require("ui/widget/button")

local EReolenBrowser = require("ereolenbrowser")
local EReolenSearch =require("ereolensearch")
local EReolenAccount =require("ereolenaccount")

local EReolenCatalog = InputContainer:extend{
    title = _("EReolen Catalog"),
}

function EReolenCatalog:init()
    local ereolen_browser = EReolenBrowser:new{
        title = "Frontpage",
        show_parent = self,
        is_popout = false,
        is_borderless = true,
        has_close_button = false,
        close_callback = function() return self:onClose() end,
        file_downloaded_callback = function(downloaded_file)
            UIManager:show(ConfirmBox:new{
                text = T(_("File saved to:\n%1\nWould you like to read the downloaded book now?"),
                    BD.filepath(downloaded_file)),
                ok_text = _("Read now"),
                cancel_text = _("Read later"),
                ok_callback = function()
                    local Event = require("ui/event")
                    UIManager:broadcastEvent(Event:new("SetupShowReader"))

                    self:onClose()

                    local ReaderUI = require("apps/reader/readerui")
                    ReaderUI:showReader(downloaded_file)
                end
            })
        end
    }
    local ereolen_search = EReolenSearch:new{
        title = "Search",
        show_parent = self,
        is_popout = false,
        is_borderless = true,
        has_close_button = false,
    }
    local ereolen_account = EReolenAccount:new{
        title = "Account",
        show_parent = self,
        is_popout = false,
        is_borderless = true,
        has_close_button = false,
    }
    self.active_page = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        height = Screen:getHeight() * 0.9,
        width = Screen:getWidth(),
        background = Blitbuffer.COLOR_WHITE,
    }
    -- Five buttons of equal width, with room for each one's margins. Sizing the
    -- close button separately made it 12px wide on a 600px screen, and once the
    -- margins came off, TextWidget refused the non-positive text width.
    local tab_margin = 2
    local tab_button_width = math.floor(Screen:getWidth() / 5) - tab_margin * 2
    self.bottom_tab = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        height = Screen:getHeight() * 0.1,
        width = Screen:getWidth(),
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            Button:new{
                text = _("FRONT"),
                width = tab_button_width,
                margin = tab_margin,
                callback = function()
                    self.active_page[1] = ereolen_browser
                    UIManager:setDirty(self, function()
                        return "ui", self[1].dimen
                    end)
                end,
            },    
            Button:new{
                text = _("SEARCH"),
                width = tab_button_width,
                margin = tab_margin,
                callback = function()
                    self.active_page[1] = ereolen_search
                    UIManager:setDirty(self, function()
                        return "ui", self[1].dimen
                    end)
                end,
            },    
            Button:new{
                text = _("READ"),
                width = tab_button_width,
                margin = tab_margin,
            },    
            Button:new{
                text = _("ACCOUNT"),
                width = tab_button_width,
                margin = tab_margin,
                callback = function()
                    self.active_page[1] = ereolen_account
                    UIManager:setDirty(self, function()
                        return "ui", self[1].dimen
                    end)
                end,
            },   
            Button:new{
                text = _("CLOSE"),
                width = tab_button_width,
                margin = tab_margin,
                callback = function() return self:onClose() end,
            },    
        },
    }
    self.active_page[1] = ereolen_browser
    self[1] = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            self.active_page,
            self.bottom_tab,
        },
    }
    
end

function EReolenCatalog:onShow()
    UIManager:setDirty(self, function()
        return "ui", self[1].dimen
    end)
end

function EReolenCatalog:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self[1].dimen
    end)
end

function EReolenCatalog:showCatalog()
    logger.dbg("show eReolen catalog")
    UIManager:show(EReolenCatalog:new{
        dimen = Screen:getSize(),
        covers_fullscreen = true, -- hint for UIManager:_repaint()
    })
end

function EReolenCatalog:onClose()
    logger.dbg("close eReolen catalog")
    UIManager:close(self)
    return true
end

return EReolenCatalog
