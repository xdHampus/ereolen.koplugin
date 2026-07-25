--[[--
Account tab: active loans, reservations, want-to-read list, loan history and
the library's loan quota, all from the eReolen Profile API.
]]

local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local EReolenDownload = require("ereolendownload")
local EReolenItem = require("ereolenitem")
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
--- Back to the account root without re-running Menu.init on a live widget.
function EReolenAccount:showStart()
    self:switchItemTable(_("Account"), self:genStartStateItemTable())
end

function EReolenAccount:showPage(title, item_table, on_back)
    table.insert(item_table, {
        text = _("Back"),
        deletable = false, editable = false,
        callback = on_back or function() self:showStart() end,
    })
    self:switchItemTable(title, item_table)
end

--- Open an account-list entry in the item view.
-- The batch getRecords lookup can miss, so fall back to getProduct for the one
-- record rather than leaving the row dead.
function EReolenAccount:openEntry(entry, record, label, on_back, fallback)
    local single = record
    if not single then
        single = EReolenWrapper:call(function(token)
            return ereol.Item.getProduct(entry.loanIdentifier.identifier, token)
        end)
    end
    if single then
        EReolenItem.show(self, single, on_back)
    elseif fallback then
        fallback()
    else
        UIManager:show(InfoMessage:new{
            text = T(_("No details available for ISBN %1."), entry.loanIdentifier.isbn),
        })
    end
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
            local record = records[loan.loanIdentifier.identifier]
            local label = describe(record, loan.loanIdentifier)
            table.insert(item_table, {
                text = T(_("%1 (expires %2)"), label, formatDate(loan.expireDate)),
                deletable = false, editable = false,
                callback = function()
                    self:openEntry(loan, record, label,
                        function() self:showLoans() end,
                        -- Still no metadata; the download is the point anyway.
                        function() EReolenDownload.loan(loan, label) end)
                end,
            })
        end
    end
    self:showPage(title, item_table)
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
            local record = records[reservation.loanIdentifier.identifier]
            table.insert(item_table, {
                text = T(_("%1 (%2)"),
                    describe(record, reservation.loanIdentifier), reservation.status),
                deletable = false, editable = false,
                callback = function()
                    self:openEntry(reservation, record, nil, function() self:showReservations() end)
                end,
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
            local record = records[entry.loanIdentifier.identifier]
            table.insert(item_table, {
                text = describe(record, entry.loanIdentifier),
                deletable = false, editable = false,
                callback = function()
                    self:openEntry(entry, record, nil, function() self:showChecklist() end)
                end,
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
