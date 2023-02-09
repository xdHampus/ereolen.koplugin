local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local EReolen = WidgetContainer:new{
    name = "ereolen",
    is_doc_only = false,
}


function EReolen:onDispatcherRegisterActions()
    Dispatcher:registerAction("ereolen_show_catalog",
        {category="none", event="ShowEReolenCatalog", title=_("eReolen catalog"), filemanager=true,}
    )
end

function EReolen:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function EReolen:showCatalog()
    local EReolenCatalog = require("ereolencatalog")
    local filemanagerRefresh = function() self.ui:onRefresh() end
    function EReolenCatalog:onClose()
        UIManager:close(self)
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            filemanagerRefresh()
        else
            FileManager:showFiles(G_reader_settings:readSetting("download_dir"))
        end
    end
    EReolenCatalog:showCatalog()
end

function EReolen:onShowOPDSCatalog()
    self:showCatalog()
    return true
end

function EReolen:addToMainMenu(menu_items)
    if not self.ui.view then
        menu_items.ereolen = {
            text = _("eReolen catalog"),
            sorting_hint = "search",
            callback = function() self:showCatalog() end
        }
    end
end

return EReolen
