--[[--
Item detail view: what a single title is, whether it can be borrowed, and the
Borrow button.

Rendered into a host Menu rather than as its own widget, so it works the same
from search results and from the Account tab. The host must provide
showPage(title, item_table, on_back) -- see EReolenAccount:showPage.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local ImageViewer = require("ui/widget/imageviewer")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local EReolenCovers = require("ereolencovers")
local EReolenDownload = require("ereolendownload")
local EReolenWrapper = require("ereolenwrapper")

local EReolenItem = {}

-- ereolen.getLoanStatuses values seen in the wild. Only "loanable" is borrowable;
-- the app's own Borrow button is hidden otherwise.
local STATUS_LOANABLE = "loanable"

local function joinList(list, sep)
    if not list or #list == 0 then return nil end
    return table.concat(list, sep or ", ")
end

--- creators often holds the same person twice, once per name order
-- ("George Orwell" and "Orwell, George"). Keep the first spelling of each.
local function dedupeNames(list)
    if not list then return nil end
    local seen, out = {}, {}
    for _, name in ipairs(list) do
        -- Drop parenthesised qualifiers first, or "Palle Schmidt (f. 1972)" and
        -- "Schmidt, Palle" tokenise differently and both survive.
        local bare = name:gsub("%b()", " ")
        local words = {}
        for word in bare:lower():gmatch("%a+") do table.insert(words, word) end
        table.sort(words)
        local key = table.concat(words, " ")
        if key ~= "" and not seen[key] then
            seen[key] = true
            table.insert(out, name)
        end
    end
    return out
end

local function formatDate(timestamp)
    if not timestamp or timestamp <= 0 then return _("unknown") end
    return os.date("%Y-%m-%d", timestamp)
end

--- Plain-text blurb for a record, preferring the longer of the two fields.
local function blurbOf(record)
    local abstract = record.abstract
    local description = record.description
    local text = abstract
    if description and description ~= "" and (not text or #description > #text) then
        text = description
    end
    if not text or text == "" then return nil end
    -- The API returns light HTML in description.
    return (text:gsub("<br%s*/?>", "\n"):gsub("<[^>]->", ""))
end

--- What this title's state is for this account.
-- Returns status (from getLoanStatuses) plus the matching loan, checklist entry
-- and reservation if any.
--
-- Matches on ISBN, not identifier: a search result's identifier carries an extra
-- source field that the account lists' identifiers do not. e.g.
-- {"i":"978…","s":"870970-basis:48341624","c":"ereolen"} from search versus
-- {"i":"978…","c":"ereolen"} from getLoans. The ISBN is stable.
local function itemState(record)
    local identifier = record.loanIdentifier.identifier
    local isbn = record.loanIdentifier.isbn

    local status
    local statuses = EReolenWrapper:call(function(token)
        return ereol.Item.getLoanStatuses({identifier}, token)
    end)
    if statuses then status = statuses[identifier] end

    local lists = EReolenWrapper:profileLists()
    return status,
        EReolenWrapper.findByIsbn(lists.loans, isbn, identifier),
        EReolenWrapper.findByIsbn(lists.checklist, isbn, identifier),
        EReolenWrapper.findByIsbn(lists.reservations, isbn, identifier)
end

--- How many of the library's concurrent-loan slots are in use.
-- Returns used, max. max is nil when the profile cannot be read.
local function quota()
    local loans = EReolenWrapper:profileLists().loans
    local used = loans and #loans or nil

    local library = EReolenWrapper:getLibrary()
    if not library then return used, nil end
    local vc = ereol.Profile.getLibraryProfile(library)
    if not vc.success then return used, nil end
    return used, vc.data.maxConcurrentLoansPerBorrower
end

function EReolenItem.borrow(host, record, refresh)
    local identifier = record.loanIdentifier.identifier
    local label = record.title

    local used, max = quota()
    local quota_line = ""
    if used and max then
        if used >= max then
            UIManager:show(InfoMessage:new{
                text = T(_("You have used all %1 of your loans. Loans cannot be returned early — they expire on their own."), max),
            })
            return
        end
        quota_line = T(_("\n\nThis uses loan %1 of %2."), used + 1, max)
    end

    -- Spelling out the irreversibility matters: eReolen has no return method at
    -- all -- not a missing feature, the app tells users loans expire after 30
    -- days -- so a mis-tap costs a slot for the whole period.
    UIManager:show(ConfirmBox:new{
        text = T(_("Borrow “%1”?\n\nIt cannot be returned early; it expires on its own.%2"), label, quota_line),
        ok_text = _("Borrow"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            NetworkMgr:runWhenOnline(function()
                local loan, err = EReolenWrapper:call(function(token)
                    return ereol.Item.createLoan(identifier, token)
                end)
                if not loan then
                    UIManager:show(InfoMessage:new{
                        text = T(_("Could not borrow “%1”:\n%2"), label, err),
                    })
                    return
                end
                EReolenWrapper:invalidateProfile()
                UIManager:show(InfoMessage:new{
                    text = T(_("Borrowed “%1”."), label),
                    timeout = 2,
                })
                if refresh then refresh() end
            end)
        end,
    })
end

--- Place a hold. addReservation takes an email and phone, and the app likewise
-- refuses to offer reserving until the user has both on file.
function EReolenItem.reserve(record, on_done)
    local identifier = record.loanIdentifier.identifier
    local email, phone = EReolenWrapper:getContact()

    local function send(mail, tel)
        NetworkMgr:runWhenOnline(function()
            local ok, err = EReolenWrapper:call(function(token)
                return ereol.Profile.addReservation(identifier, mail, tel, token)
            end)
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = T(_("Could not reserve “%1”:\n%2"), record.title, err),
                })
                return
            end
            EReolenWrapper:saveContact(mail, tel)
            EReolenWrapper:invalidateProfile()
            UIManager:show(InfoMessage:new{
                text = T(_("Reserved “%1”."), record.title),
                timeout = 2,
            })
            if on_done then on_done() end
        end)
    end

    local dialog
    dialog = MultiInputDialog:new{
        title = T(_("Reserve “%1”"), record.title),
        fields = {
            { text = email or "", hint = _("Email") },
            { text = phone or "", hint = _("Phone") },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        dialog:onClose()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Reserve"),
                    callback = function()
                        local fields = dialog:getFields()
                        dialog:onClose()
                        UIManager:close(dialog)
                        if fields[1] == "" or fields[2] == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("eReolen needs both an email address and a phone number to reserve a title."),
                            })
                            return
                        end
                        send(fields[1], fields[2])
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- PageResult.data is a list of collections, each a list of Record.
local function flattenPage(page)
    local records = {}
    for _, collection in ipairs(page.data or {}) do
        for _, record in ipairs(collection) do
            table.insert(records, record)
        end
    end
    return records
end

local function describe(record)
    local label = record.title
    local creator = record.creators and record.creators[1]
    if creator then label = T("%1 — %2", label, creator) end
    if record.recordType then label = T("%1 (%2)", label, record.recordType) end
    return label
end

--- A page of records, each row opening its own item view.
function EReolenItem.showRecordList(host, title, records, on_back)
    local item_table = {}
    if #records == 0 then
        table.insert(item_table, {
            text = _("Nothing here"),
            deletable = false, editable = false,
        })
    end
    for _, record in ipairs(records) do
        table.insert(item_table, {
            text = describe(record),
            deletable = false, editable = false,
            callback = function()
                EReolenItem.show(host, record, function()
                    EReolenItem.showRecordList(host, title, records, on_back)
                end)
            end,
        })
    end
    host:showPage(title, item_table, on_back)
end

--- A row that fetches a related-titles list only when tapped, so opening an item
-- view stays one round trip rather than six.
local function relatedRow(host, row, label, page_title, fetch, on_back)
    row(label, function()
        NetworkMgr:runWhenOnline(function()
            local records, err = fetch()
            if not records then
                UIManager:show(InfoMessage:new{ text = err })
                return
            end
            EReolenItem.showRecordList(host, page_title, records, on_back)
        end)
    end)
end

local function showCover(record, url)
    NetworkMgr:runWhenOnline(function()
        local bb, err = EReolenCovers:fetch(url)
        if not bb then
            UIManager:show(InfoMessage:new{
                text = T(_("Could not load the cover:\n%1"), err),
            })
            return
        end
        UIManager:show(ImageViewer:new{
            image = bb,
            image_disposable = true,  -- the viewer frees the BlitBuffer
            fullscreen = true,
            with_title_bar = true,
            title_text = record.title,
        })
    end)
end

--- Renders `record` into `host`. `on_back` returns to whatever came before.
function EReolenItem.show(host, record, on_back)
    local identifier = record.loanIdentifier.identifier
    local status, existing, checklisted, reserved = itemState(record)

    local item_table = {}
    local function row(text, callback)
        table.insert(item_table, {
            text = text,
            deletable = false, editable = false,
            callback = callback,
        })
    end

    local creators = joinList(dedupeNames(record.creators))
    if creators then row(T(_("By %1"), creators)) end

    local facts = {}
    if record.recordType then table.insert(facts, record.recordType) end
    if record.year then table.insert(facts, record.year) end
    if record.language then table.insert(facts, record.language) end
    if record.publisher and record.publisher ~= "" then table.insert(facts, record.publisher) end
    if #facts > 0 then row(table.concat(facts, " · ")) end

    local series = joinList(dedupeNames(record.series))
    if series then row(T(_("Series: %1"), series)) end

    -- Resolved up front so the row is only offered when a cover actually exists.
    local cover_url = EReolenCovers:urlFor(identifier)
    if cover_url then
        row(_("Cover"), function() showCover(record, cover_url) end)
    end

    local blurb = blurbOf(record)
    if blurb then
        local preview = blurb:gsub("%s+", " ")
        if #preview > 90 then preview = preview:sub(1, 90) .. "…" end
        row(preview, function()
            UIManager:show(TextViewer:new{
                title = record.title,
                text = blurb,
            })
        end)
    end

    local back_here = function() EReolenItem.show(host, record, on_back) end
    local settings = ereol.QuerySettings()
    settings.startIndex = 0
    settings.endIndex = 20

    -- Same title in another format: this is the ebook <-> audiobook switch.
    relatedRow(host, row, _("Other formats of this title"), record.title, function()
        local others, err = EReolenWrapper:call(function(token)
            return ereol.Item.getOthersOfSameTitle(identifier, token)
        end)
        if not others then return nil, err end
        -- Drop the edition we are already looking at.
        local out = {}
        for _, r in ipairs(others) do
            if r.loanIdentifier.identifier ~= identifier then table.insert(out, r) end
        end
        return out
    end, back_here)

    local creator = record.creators and record.creators[1]
    if creator then
        relatedRow(host, row, T(_("More by %1"), creator), creator, function()
            local page, err = EReolenWrapper:call(function(token)
                return ereol.Item.getMoreOfSameCreator(identifier, token, settings)
            end)
            if not page then return nil, err end
            return flattenPage(page)
        end, back_here)
    end

    if record.series and #record.series > 0 then
        relatedRow(host, row, T(_("More in %1"), record.series[1]), record.series[1], function()
            local page, err = EReolenWrapper:call(function(token)
                return ereol.Item.getMoreInSameSeries(identifier, token, settings)
            end)
            if not page then return nil, err end
            return flattenPage(page)
        end, back_here)
    end

    relatedRow(host, row, _("More in this genre"), _("Same genre"), function()
        local page, err = EReolenWrapper:call(function(token)
            return ereol.Item.getMoreOfSameGenre(identifier, token, settings)
        end)
        if not page then return nil, err end
        return flattenPage(page)
    end, back_here)

    relatedRow(host, row, _("Similar titles"), _("Similar titles"), function()
        return EReolenWrapper:call(function(token)
            -- Note: this method rejects an 8th param, so the wrapper strips
            -- facets from the settings it is given.
            return ereol.Item.getSomethingSimilar(identifier, token, settings)
        end)
    end, back_here)

    row(_("Reviews"), function()
        NetworkMgr:runWhenOnline(function()
            local reviews, err = EReolenWrapper:call(function(token)
                return ereol.Item.getReviews(identifier, token)
            end)
            if not reviews then
                UIManager:show(InfoMessage:new{ text = err })
                return
            end
            if #reviews == 0 then
                UIManager:show(InfoMessage:new{ text = _("No reviews for this title.") })
                return
            end
            local parts = {}
            for _, review in ipairs(reviews) do
                table.insert(parts, review.source .. "\n" .. review.subTitle
                    .. (review.url ~= "" and ("\n" .. review.url) or ""))
            end
            UIManager:show(TextViewer:new{
                title = T(_("Reviews: %1"), record.title),
                text = table.concat(parts, "\n\n"),
            })
        end)
    end)

    local refresh = back_here

    -- Want-to-read list.
    if checklisted then
        row(_("Remove from want-to-read"), function()
            NetworkMgr:runWhenOnline(function()
                local ok, err = EReolenWrapper:call(function(token)
                    return ereol.Profile.removeFromCheckList({checklisted.loanIdentifier.identifier}, token)
                end)
                if not ok then
                    UIManager:show(InfoMessage:new{ text = err })
                    return
                end
                EReolenWrapper:invalidateProfile()
                UIManager:show(InfoMessage:new{ text = _("Removed from your want-to-read list."), timeout = 2 })
                back_here()
            end)
        end)
    else
        row(_("Add to want-to-read"), function()
            NetworkMgr:runWhenOnline(function()
                local ok, err = EReolenWrapper:call(function(token)
                    return ereol.Profile.addToCheckList(identifier, token)
                end)
                if not ok then
                    UIManager:show(InfoMessage:new{ text = err })
                    return
                end
                EReolenWrapper:invalidateProfile()
                UIManager:show(InfoMessage:new{ text = _("Added to your want-to-read list."), timeout = 2 })
                back_here()
            end)
        end)
    end

    -- Reservations: only meaningful when the title cannot be borrowed now.
    if reserved then
        row(T(_("Reserved (%1) — tap to cancel"), reserved.status), function()
            UIManager:show(ConfirmBox:new{
                text = T(_("Cancel your reservation of “%1”?"), record.title),
                ok_text = _("Cancel reservation"),
                ok_callback = function()
                    NetworkMgr:runWhenOnline(function()
                        local ok, err = EReolenWrapper:call(function(token)
                            return ereol.Profile.removeReservations({reserved.loanIdentifier.identifier}, token)
                        end)
                        if not ok then
                            UIManager:show(InfoMessage:new{ text = err })
                            return
                        end
                        EReolenWrapper:invalidateProfile()
                        back_here()
                    end)
                end,
            })
        end)
    elseif not existing and status and status ~= STATUS_LOANABLE then
        row(_("Reserve"), function() EReolenItem.reserve(record, back_here) end)
    end

    if existing then
        row(T(_("Borrowed — expires %1"), formatDate(existing.expireDate)))
        row(_("Download"), function()
            EReolenDownload.loan(existing, record.title)
        end)
    elseif status == STATUS_LOANABLE then
        row(_("Borrow"), function()
            EReolenItem.borrow(host, record, refresh)
        end)
    elseif status then
        row(T(_("Not available to borrow (%1)"), status))
    else
        row(_("Availability unknown"))
    end

    host:showPage(record.title, item_table, on_back)
end

return EReolenItem
