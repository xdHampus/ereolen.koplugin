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

-- cache catalog parsed from feed xml
local CatalogCache = Cache:new{
    slots = 20,
}

local EReolenBrowser = Menu:extend{
    catalog_type = "application/atom%+xml",
    search_type = "application/opensearchdescription%+xml",
    search_template_type = "application/atom%+xml",
    acquisition_rel = "^http://opds%-spec%.org/acquisition",
    image_rel = "http://opds-spec.org/image",
    thumbnail_rel = "http://opds-spec.org/image/thumbnail",
    stream_rel = "http://vaemendis.net/opds-pse/stream",

    width = Screen:getWidth(),
    height = Screen:getHeight() * 0.9,
    no_title = false,
    parent = nil,
}

function EReolenBrowser:init()
    self.catalog_title = nil
    self.title_bar_left_icon = "plus"
    self.onLeftButtonTap = function()
        self:addNewCatalog()
    end
    Menu.init(self) -- call parent's init()
end


-- This function shows a dialog with input fields
-- for entering information for an OPDS catalog.
function EReolenBrowser:addNewCatalog()
    self.add_server_dialog = MultiInputDialog:new{
        title = _("Add User"),
        fields = {
            {
                text = "",
                hint = _("Library"),
            },
            {
                text = "",
                hint = _("Username"),
            },
            {
                text = "",
                hint = _("Password"),
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        self.add_server_dialog:onClose()
                        UIManager:close(self.add_server_dialog)
                    end
                },
                {
                    text = _("Add"),
                    callback = function()
                        self.add_server_dialog:onClose()
                        UIManager:close(self.add_server_dialog)
                    end
                },
            },
        },
    }
    UIManager:show(self.add_server_dialog)
    self.add_server_dialog:onShowKeyboard()
end

return EReolenBrowser
