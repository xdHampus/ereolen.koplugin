--[[--
Account tab: active loans, reservations, want-to-read list, loan history and
the library's loan quota, all from the eReolen Profile API.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local EReolenWrapper = require("ereolenwrapper")

local EReolenAccount = Menu:extend{
    width = Screen:getWidth(),
    height = Screen:getHeight() * 0.9,
    no_title = false,
    parent = nil,
}

local function formatDate(timestamp)
    if not timestamp or timestamp <= 0 then return _("unknown") end
    return os.date("%Y-%m-%d", timestamp)
end

--- Title for a loan/reservation/checklist entry, falling back to the ISBN.
local function describe(record, loan_identifier)
    if record and record.title and record.title ~= "" then
        local creators = record.creators
        if creators and creators[1] then
            return T("%1 — %2", record.title, creators[1])
        end
        return record.title
    end
    return T(_("ISBN %1"), loan_identifier.isbn)
end

--- Collect identifiers from a list of entries that all carry a loanIdentifier.
local function identifiersOf(entries)
    local identifiers = {}
    for i = 1, #entries do
        table.insert(identifiers, entries[i].loanIdentifier.identifier)
    end
    return identifiers
end

function EReolenAccount:init()
    self.title = _("Account")
    self.title_bar_left_icon = nil
    self.item_table = self:genStartStateItemTable()
    Menu.init(self) -- call parent's init()
end

function EReolenAccount:genStartStateItemTable()
    local item_table = {}

    if not EReolenWrapper:hasAccount() then
        table.insert(item_table, {
            text = _("Not signed in — add your library card on the front page"),
            deletable = false, editable = false,
        })
        return item_table
    end

    table.insert(item_table, {
        text = _("Loans"), deletable = false, editable = false,
        callback = function() self:showLoans() end,
    })
    table.insert(item_table, {
        text = _("Reservations"), deletable = false, editable = false,
        callback = function() self:showReservations() end,
    })
    table.insert(item_table, {
        text = _("Checklist"), deletable = false, editable = false,
        callback = function() self:showChecklist() end,
    })
    table.insert(item_table, {
        text = _("Loan history"), deletable = false, editable = false,
        callback = function() self:showLoanHistory() end,
    })
    table.insert(item_table, {
        text = _("Library profile"), deletable = false, editable = false,
        callback = function() self:showLibraryProfile() end,
    })
    return item_table
end

--- Replace the menu contents with `item_table` under `title`, plus a Back row.
function EReolenAccount:showPage(title, item_table)
    table.insert(item_table, {
        text = _("Back"),
        deletable = false, editable = false,
        callback = function() self:init() end,
    })
    self.title = title
    self.item_table = item_table
    Menu.init(self)
end

--- Fetch through EReolenWrapper:call and show the error page on failure.
-- Returns the data, or nil when the page has already been rendered.
function EReolenAccount:fetch(title, fn)
    local data, err = EReolenWrapper:call(fn)
    if not data then
        UIManager:show(InfoMessage:new{ text = err })
        self:showPage(title, {})
        return nil
    end
    return data
end

function EReolenAccount:showLoans()
    local title = _("Loans")
    local loans = self:fetch(title, function(token)
        return ereol.Profile.getLoans(token)
    end)
    if not loans then return end

    local item_table = {}
    if #loans == 0 then
        table.insert(item_table, {
            text = _("No active loans"),
            deletable = false, editable = false,
        })
    else
        local records = EReolenWrapper:getRecordsByIdentifier(identifiersOf(loans))
        for i = 1, #loans do
            local loan = loans[i]
            local label = describe(records[loan.loanIdentifier.identifier], loan.loanIdentifier)
            table.insert(item_table, {
                text = T(_("%1 (expires %2)"), label, formatDate(loan.expireDate)),
                deletable = false, editable = false,
                callback = function() self:downloadLoan(loan, label) end,
            })
        end
    end
    self:showPage(title, item_table)
end

function EReolenAccount:getDownloadDir()
    return G_reader_settings:readSetting("download_dir")
        or G_reader_settings:readSetting("lastdir")
        or Device.home_dir
        or "."
end

--- Downloads a loan's fulfilment ticket and hands it to whatever can open it.
-- For an ebook that ticket is an Adobe ACSM: eReolen does not serve the book
-- itself, so something has to redeem the ACSM against acs.pubhub.dk. KOReader
-- has no built-in ADEPT support, so this needs a plugin that registers an
-- "acsm" document provider (acsm.koplugin does).
function EReolenAccount:downloadLoan(loan, label)
    local dir = self:getDownloadDir()
    -- Strip the " — author" suffix describe() adds; keep the filename short.
    local base = util.getSafeFilename(label:gsub(" — .*$", ""), dir)

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

        if not path:lower():match("%.acsm$") then
            -- Audiobooks and anything the server hands over directly.
            self:offerToOpen(path)
            return
        end

        if not DocumentRegistry:hasProvider(path) then
            UIManager:show(InfoMessage:new{
                text = T(_("Saved the loan ticket to:\n%1\n\nIt is an Adobe ACSM, which KOReader cannot open on its own. Install a plugin that handles ACSM files (for example acsm.koplugin) and open the file again."), path),
            })
            return
        end
        self:offerToOpen(path)
    end)
end

function EReolenAccount:offerToOpen(path)
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

function EReolenAccount:showReservations()
    local title = _("Reservations")
    local reservations = self:fetch(title, function(token)
        return ereol.Profile.getReservations(token)
    end)
    if not reservations then return end

    local item_table = {}
    if #reservations == 0 then
        table.insert(item_table, {
            text = _("No reservations"),
            deletable = false, editable = false,
        })
    else
        local records = EReolenWrapper:getRecordsByIdentifier(identifiersOf(reservations))
        for i = 1, #reservations do
            local reservation = reservations[i]
            table.insert(item_table, {
                text = T(_("%1 (%2)"),
                    describe(records[reservation.loanIdentifier.identifier], reservation.loanIdentifier),
                    reservation.status),
                deletable = false, editable = false,
            })
        end
    end
    self:showPage(title, item_table)
end

function EReolenAccount:showChecklist()
    local title = _("Checklist")
    local checklist = self:fetch(title, function(token)
        return ereol.Profile.getCheckList(token)
    end)
    if not checklist then return end

    local item_table = {}
    if #checklist == 0 then
        table.insert(item_table, {
            text = _("Nothing on your want-to-read list"),
            deletable = false, editable = false,
        })
    else
        local records = EReolenWrapper:getRecordsByIdentifier(identifiersOf(checklist))
        for i = 1, #checklist do
            local entry = checklist[i]
            table.insert(item_table, {
                text = describe(records[entry.loanIdentifier.identifier], entry.loanIdentifier),
                deletable = false, editable = false,
            })
        end
    end
    self:showPage(title, item_table)
end

function EReolenAccount:showLoanHistory()
    local title = _("Loan history")
    local history = self:fetch(title, function(token)
        return ereol.Profile.getLoanHistory(token)
    end)
    if not history then return end

    local item_table = {}
    if #history == 0 then
        table.insert(item_table, {
            text = _("No loan history"),
            deletable = false, editable = false,
        })
    else
        -- getLoanHistory already carries title and creator, so no extra lookup.
        for i = 1, #history do
            local entry = history[i]
            local label = entry.title
            if entry.creator and entry.creator ~= "" then
                label = T("%1 — %2", entry.title, entry.creator)
            end
            table.insert(item_table, {
                text = T(_("%1 (borrowed %2)"), label, formatDate(entry.loanDate)),
                deletable = false, editable = false,
            })
        end
    end
    self:showPage(title, item_table)
end

function EReolenAccount:showLibraryProfile()
    local title = _("Library profile")
    local library = EReolenWrapper:getLibrary()
    if not library then
        UIManager:show(InfoMessage:new{
            text = _("No library configured for this account."),
        })
        self:showPage(title, {})
        return
    end

    -- getLibraryProfile takes a library value, not a token.
    local vc = ereol.Profile.getLibraryProfile(library)
    if not vc.success then
        UIManager:show(InfoMessage:new{ text = EReolenWrapper:errorMessage(vc) })
        self:showPage(title, {})
        return
    end

    local profile = vc.data
    local item_table = {
        {
            text = T(_("Concurrent loans: %1"), profile.maxConcurrentLoansPerBorrower),
            deletable = false, editable = false,
        },
        {
            text = T(_("Concurrent audiobook loans: %1"), profile.maxConcurrentAudioLoansPerBorrower),
            deletable = false, editable = false,
        },
        {
            text = T(_("Concurrent reservations: %1"), profile.maxConcurrentReservationsPerBorrower),
            deletable = false, editable = false,
        },
        {
            text = T(_("Concurrent audiobook reservations: %1"), profile.maxConcurrentAudioReservationsPerBorrower),
            deletable = false, editable = false,
        },
    }
    self:showPage(title, item_table)
end

return EReolenAccount
