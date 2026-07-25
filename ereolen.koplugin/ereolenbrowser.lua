--[[--
The front page.

Laid out like the app's: the editors' shelves, each a title over a strip of
cover art. Every one of those comes out of the cached Firebase blob, which
carries the records *and* a cover URL for each, so the whole page draws without
a single RPC call -- see ereolenshared.lua.

Signing in and out lives here too, and is the only thing shown until there is a
card to use.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local EReolenView = require("ereolenview")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local EReolenCovers = require("ereolencovers")
local EReolenItem = require("ereolenitem")
local EReolenShared = require("ereolenshared")
local EReolenWrapper = require("ereolenwrapper")

local EReolenBrowser = EReolenView:extend{
    width = Screen:getWidth(),
    height = Screen:getHeight() * 0.9,
    no_title = false,
    parent = nil,
}

function EReolenBrowser:init()
    self.title = _("eReolen")
    if EReolenWrapper:hasAccount() then
        self.title_bar_left_icon = "star.empty"
        self.onLeftButtonTap = function() self:showRecommendations() end
    else
        self.title_bar_left_icon = "plus"
        self.onLeftButtonTap = function() self:addNewCatalog() end
    end
    self.item_table = self:genItemTable()
    EReolenView.init(self) -- call parent's init()
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

--- Open a front-page item. Its record has to be fetched: the blob carries
--- enough to draw a tile, not enough for the detail view.
function EReolenBrowser:openShelfItem(item)
    NetworkMgr:runWhenOnline(function()
        local record, err = EReolenWrapper:call(function(token)
            return ereol.Item.getProduct(item.identifier, token)
        end)
        if not record then
            UIManager:show(InfoMessage:new{ text = err })
            return
        end
        EReolenItem.show(self, record, function() self:showStart() end)
    end)
end

function EReolenBrowser:genItemTable()
    local item_table = {}
    local account = EReolenWrapper:getAccount()

    if not (account and account.username) then
        table.insert(item_table, {
            text = _("Not signed in — tap to add your library card"),
            deletable = false, editable = false,
            callback = function() self:addNewCatalog() end,
        })
        return item_table
    end

    -- The shelves, straight from the cache. Nothing here waits on the network.
    local shelves = EReolenShared:shelves()
    EReolenCovers:seed(EReolenShared:coverUrls())
    for _, shelf in ipairs(shelves) do
        table.insert(item_table, {
            shelf = shelf,
            text = shelf.title,
            deletable = false, editable = false,
            on_item = function(item) self:openShelfItem(item) end,
            callback = function() self:showShelf(shelf) end,
        })
    end

    return item_table
end

--- A whole shelf as a grid. Its items are already here, so this is instant.
function EReolenBrowser:showShelf(shelf)
    local item_table = {}
    for _, item in ipairs(shelf.items) do
        table.insert(item_table, {
            -- No Record yet, but a cover URL and a title are enough to draw a
            -- tile; the detail view fetches the rest when one is opened.
            cover_url = item.cover,
            text = item.title,
            caption = item.creator and (item.title .. "\n" .. item.creator) or item.title,
            subtitle = item.creator,
            detail = item.year and item.publisher
                and (item.year .. " · " .. item.publisher) or item.publisher,
            deletable = false, editable = false,
            callback = function() self:openShelfItem(item) end,
        })
    end
    self:showPage(shelf.title, item_table, function() self:showStart() end)
end

--- Same contract as the other tabs, so EReolenItem can render into us.
function EReolenBrowser:showPage(title, item_table, on_back)
    self:showRecords(title, item_table, on_back or function() self:showStart() end)
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

--- Refresh the shelves from Firebase, then redraw.
function EReolenBrowser:refreshShelves()
    NetworkMgr:runWhenOnline(function()
        local _data, err = EReolenShared:refresh()
        if err then
            UIManager:show(InfoMessage:new{ text = err })
        end
        self:showStart()
    end)
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
