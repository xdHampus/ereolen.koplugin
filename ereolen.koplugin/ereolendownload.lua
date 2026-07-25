--[[--
Downloading a loan, shared by the Account tab and the item view.

eReolen never serves the book itself. For an ebook the loan's downloadUrl is an
Adobe ACSM -- a fulfilment ticket that something else has to redeem against
acs.pubhub.dk. KOReader has no built-in ADEPT support, so this needs a plugin
that registers an "acsm" document provider; acsm.koplugin does, and it both
fulfils and decrypts. Audiobooks put a direct media URL in the same field.

Once the ticket is on disk we hand it straight to that provider rather than
dropping the user in the file manager to find the .acsm and tap it themselves.
`filemanagerutil.openFile` is the same dispatch the file manager uses, so any
plugin that claims .acsm works, not only acsm.koplugin.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local EReolenDownload = {}

function EReolenDownload.getDir()
    return G_reader_settings:readSetting("download_dir")
        or G_reader_settings:readSetting("lastdir")
        or Device.home_dir
        or "."
end

--- Hand `path` to whatever registered a provider for it.
-- The catalog window has to close first: for an ACSM the provider puts its own
-- progress dialogs up and then opens the book, and both would land underneath
-- our full-screen window.
local function openWithProvider(path)
    local FileManager = require("apps/filemanager/filemanager")
    local ReaderUI = require("apps/reader/readerui")
    local ui = FileManager.instance or ReaderUI.instance
    if not ui then
        UIManager:show(InfoMessage:new{ text = T(_("Saved to:\n%1"), path) })
        return
    end
    filemanagerutil.openFile(ui, path, function()
        local EReolenCatalog = require("ereolencatalog")
        if EReolenCatalog.instance then
            EReolenCatalog.instance:onClose()
        end
    end)
end

--- Fetches `loan`'s fulfilment ticket and opens it.
-- `label` is used for the filename; a " — author" suffix is stripped.
function EReolenDownload.loan(loan, label)
    local dir = EReolenDownload.getDir()
    local title = (label or "loan"):gsub(" — .*$", "")
    local base = util.getSafeFilename(title, dir)

    NetworkMgr:runWhenOnline(function()
        local vc = ereol.Item.download(dir, base, loan)
        if not vc.success then
            UIManager:show(InfoMessage:new{
                text = T(_("Download failed:\n%1"), vc.message),
            })
            return
        end

        local path = vc.data
        logger.dbg("eReolen: downloaded", path)

        local is_acsm = path:lower():match("%.acsm$") ~= nil
        if is_acsm and not DocumentRegistry:hasProvider(path) then
            UIManager:show(InfoMessage:new{
                text = T(_("Saved the loan ticket to:\n%1\n\nIt is an Adobe ACSM, which KOReader cannot open on its own. Install a plugin that handles ACSM files (for example acsm.koplugin) and open the file again."), path),
            })
            return
        end

        if is_acsm then
            -- The ACSM is a ticket, not the book. Redeeming it binds the loan
            -- to this device for good, so say what is about to happen rather
            -- than silently starting a multi-step Adobe exchange.
            UIManager:show(ConfirmBox:new{
                text = T(_("Ready to download “%1”.\n\nThis redeems the loan with Adobe and can take a minute."), title),
                ok_text = _("Download"),
                cancel_text = _("Later"),
                ok_callback = function() openWithProvider(path) end,
            })
            return
        end

        -- Audiobooks and anything else that arrived as the real file.
        UIManager:show(ConfirmBox:new{
            text = T(_("Saved to:\n%1\n\nOpen it now?"), path),
            ok_text = _("Open"),
            cancel_text = _("Later"),
            ok_callback = function() openWithProvider(path) end,
        })
    end)
end

return EReolenDownload
