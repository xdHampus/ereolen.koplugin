--[[--
Front page of the eReolen catalog: sign in, sign out, and show which library
card is in use.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local EReolenItem = require("ereolenitem")
local EReolenWrapper = require("ereolenwrapper")

local EReolenBrowser = Menu:extend{
    width = Screen:getWidth(),
    height = Screen:getHeight() * 0.9,
    no_title = false,
    parent = nil,
}

function EReolenBrowser:init()
    self.title = _("eReolen")
    self.title_bar_left_icon = "plus"
    self.onLeftButtonTap = function()
        self:addNewCatalog()
    end
    self.item_table = self:genItemTable()
    Menu.init(self) -- call parent's init()
end

--- Accepts either a library code ("odensebib") or a display name ("Odense").
local function resolveLibraryCode(input)
    if input == nil or input == "" then return nil end

    if ereol.ApiEnv.getLibraryFromCode(input) ~= nil then
        return input
    end

    local wanted = input:lower()
    for i = 0, ereol.ApiEnv.getLibraryCount() - 1 do
        if ereol.ApiEnv.getLibraryName(i):lower() == wanted then
            return ereol.ApiEnv.getLibraryCode(i)
        end
    end
    return nil
end

function EReolenBrowser:genItemTable()
    local item_table = {}
    local account = EReolenWrapper:getAccount()

    if account and account.username then
        local library = ereol.ApiEnv.getLibraryFromCode(account.library)
        local library_name = library and ereol.ApiEnv.getLibraryName(library) or account.library
        table.insert(item_table, {
            text = T(_("Signed in as %1 (%2)"), account.username, library_name),
            deletable = false, editable = false,
            callback = function() self:signOut() end,
        })
        table.insert(item_table, {
            text = _("Recommended for you"),
            deletable = false, editable = false,
            callback = function() self:showRecommendations() end,
        })
    else
        table.insert(item_table, {
            text = _("Not signed in — tap to add your library card"),
            deletable = false, editable = false,
            callback = function() self:addNewCatalog() end,
        })
    end

    return item_table
end

--- Same contract as the other tabs, so EReolenItem can render into us.
function EReolenBrowser:showPage(title, item_table, on_back)
    table.insert(item_table, {
        text = _("Back"),
        deletable = false, editable = false,
        callback = on_back or function() self:showStart() end,
    })
    self:switchItemTable(title, item_table)
end

function EReolenBrowser:showRecommendations()
    NetworkMgr:runWhenOnline(function()
        local records, err = EReolenWrapper:call(function(token)
            return ereol.Item.getPersonalRecommendations(token)
        end)
        if not records then
            UIManager:show(InfoMessage:new{ text = err })
            return
        end
        EReolenItem.showRecordList(self, _("Recommended for you"), records,
            function() self:showStart() end)
    end)
end

--- Back to the front page without re-running Menu.init on a live widget.
function EReolenBrowser:showStart()
    self:switchItemTable(_("eReolen"), self:genItemTable())
end

function EReolenBrowser:refresh()
    self:switchItemTable(self.title, self:genItemTable())
end

-- This function shows a dialog with input fields for the library card.
function EReolenBrowser:addNewCatalog()
    local account = EReolenWrapper:getAccount() or {}
    self.add_server_dialog = MultiInputDialog:new{
        title = _("eReolen library card"),
        fields = {
            {
                text = account.library or "",
                hint = _("Library (e.g. odensebib or Odense)"),
            },
            {
                text = account.username or "",
                hint = _("Card number"),
            },
            {
                text = "",
                hint = _("PIN"),
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
                    text = _("Sign in"),
                    callback = function()
                        local fields = self.add_server_dialog:getFields()
                        self.add_server_dialog:onClose()
                        UIManager:close(self.add_server_dialog)
                        self:signIn(fields[1], fields[2], fields[3])
                    end
                },
            },
        },
    }
    UIManager:show(self.add_server_dialog)
    self.add_server_dialog:onShowKeyboard()
end

function EReolenBrowser:signIn(library_input, username, password)
    local library_code = resolveLibraryCode(library_input)
    if not library_code then
        UIManager:show(InfoMessage:new{
            text = T(_("Unknown library: %1"), library_input or ""),
        })
        return
    end
    if username == nil or username == "" or password == nil or password == "" then
        UIManager:show(InfoMessage:new{
            text = _("Card number and PIN are both required."),
        })
        return
    end

    NetworkMgr:runWhenOnline(function()
        local token, err = EReolenWrapper:login(username, password, library_code)
        if not token then
            UIManager:show(InfoMessage:new{ text = err })
            return
        end

        EReolenWrapper:saveAccount{
            library = library_code,
            username = username,
            password = password,
        }
        -- saveAccount drops the cached token; keep the one we just got.
        EReolenWrapper.token = token

        UIManager:show(InfoMessage:new{
            text = _("Signed in to eReolen."),
            timeout = 2,
        })
        self:refresh()
    end)
end

function EReolenBrowser:signOut()
    UIManager:show(ConfirmBox:new{
        text = _("Sign out of eReolen and forget this card?"),
        ok_text = _("Sign out"),
        ok_callback = function()
            EReolenWrapper:logout()
            EReolenWrapper:clearAccount()
            self:refresh()
        end,
    })
end

return EReolenBrowser
