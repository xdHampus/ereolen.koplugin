local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Screen = require("device").screen
local EReolenNavBar = require("ereolennavbar")

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
        -- No close_callback here. Menu:onMenuSelect calls it after *every* leaf
        -- row's callback, so wiring it to onClose meant tapping any front-page
        -- row tore the whole catalog down -- the list loaded and the window
        -- vanished with no error. The CLOSE tab below is the way out.
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
        height = Screen:getHeight() - math.floor(Screen:getHeight() * 0.085),
        width = Screen:getWidth(),
        background = Blitbuffer.COLOR_WHITE,
    }
    local function switchTo(id, widget, before)
        self.active_page[1] = widget
        if before then before() end
        self.nav_bar:setActive(id)
        UIManager:setDirty(self, function()
            return "ui", self[1].dimen
        end)
    end

    self.nav_bar = EReolenNavBar:new{
        show_parent = self,
        tabs = {
            {
                id = "front", label = _("Front"), icon = "home",
                callback = function() switchTo("front", ereolen_browser) end,
            },
            {
                id = "search", label = _("Search"), icon = "appbar.search",
                callback = function()
                    -- Tapping Search while already on it means "search for
                    -- something else", which is why results carry no edit row.
                    if self.active_page[1] == ereolen_search then
                        ereolen_search:displayNewSearch(ereolen_search.last_query)
                        return
                    end
                    switchTo("search", ereolen_search)
                end,
            },
            {
                id = "read", label = _("Read"), icon = "book.opened",
                callback = function()
                    -- "Read" is the loans list: those are the books you can open.
                    switchTo("read", ereolen_account, function()
                        ereolen_account:showLoans()
                    end)
                end,
            },
            {
                id = "account", label = _("Account"), icon = "appbar.settings",
                callback = function()
                    switchTo("account", ereolen_account, function()
                        ereolen_account:showStart()
                    end)
                end,
            },
            {
                id = "close", label = _("Close"), icon = "exit",
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
            self.nav_bar,
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
    local catalog = EReolenCatalog:new{
        dimen = Screen:getSize(),
        covers_fullscreen = true, -- hint for UIManager:_repaint()
    }
    -- ereolendownload needs to get this window out of the way before handing a
    -- file to the reader or to the ACSM provider.
    EReolenCatalog.instance = catalog
    UIManager:show(catalog)
end

function EReolenCatalog:onClose()
    logger.dbg("close eReolen catalog")
    if EReolenCatalog.instance == self then
        EReolenCatalog.instance = nil
    end
    UIManager:close(self)
    return true
end

return EReolenCatalog
