--[[--
Downloading a loan, shared by the Account tab and the item view.

eReolen never serves the book itself. For an ebook the loan's downloadUrl is an
Adobe ACSM -- a fulfilment ticket that something else has to redeem against
acs.pubhub.dk. KOReader has no built-in ADEPT support, so this needs a plugin
that registers an "acsm" document provider; acsm.koplugin does, and it both
fulfils and decrypts. Audiobooks put a direct media URL in the same field.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
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

local function offerToOpen(path)
    UIManager:show(ConfirmBox:new{
        text = T(_("Saved to:\n%1\n\nOpen it now?"), path),
        ok_text = _("Open"),
        cancel_text = _("Later"),
        ok_callback = function()
            local ReaderUI = require("apps/reader/readerui")
            ReaderUI:showReader(path)
        end,
    })
end

--- Fetches `loan`'s fulfilment ticket and offers to open it.
-- `label` is used for the filename; a " — author" suffix is stripped.
function EReolenDownload.loan(loan, label)
    local dir = EReolenDownload.getDir()
    local base = util.getSafeFilename((label or "loan"):gsub(" — .*$", ""), dir)

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

        if path:lower():match("%.acsm$") and not DocumentRegistry:hasProvider(path) then
            UIManager:show(InfoMessage:new{
                text = T(_("Saved the loan ticket to:\n%1\n\nIt is an Adobe ACSM, which KOReader cannot open on its own. Install a plugin that handles ACSM files (for example acsm.koplugin) and open the file again."), path),
            })
            return
        end
        offerToOpen(path)
    end)
end

return EReolenDownload
