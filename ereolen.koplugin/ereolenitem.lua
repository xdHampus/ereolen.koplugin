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

local Screen = require("device").screen
local Size = require("ui/size")
local EReolenItemPage = require("ereolenitempage")
local EReolenCovers = require("ereolencovers")
local EReolenView = require("ereolenview")
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
function EReolenItem.showRecordList(host, title, records, on_back, empty_text)
    local item_table = {}
    if #records == 0 then
        table.insert(item_table, {
            text = empty_text or _("Nothing here"),
            deletable = false, editable = false,
        })
    end
    for _, record in ipairs(records) do
        table.insert(item_table, EReolenView.recordRow(record, function()
            EReolenItem.show(host, record, function()
                EReolenItem.showRecordList(host, title, records, on_back)
            end)
        end))
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
                -- Still open the page: an error the user has to dismiss before
                -- landing back where they started reads as the tap having done
                -- nothing at all.
                EReolenItem.showRecordList(host, page_title, {}, on_back, err)
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

    -- Actions are buttons; sections are the quieter list underneath.
    local actions, sections = {}, {}
    local function action(text, callback) table.insert(actions, { text = text, callback = callback }) end
    local function section(text, callback) table.insert(sections, { text = text, callback = callback }) end

    local reopen = function() EReolenItem.show(host, record, on_back) end

    ------------------------------------------------------------------- header
    local facts = {}
    if record.recordType then table.insert(facts, record.recordType) end
    if record.year then table.insert(facts, record.year) end
    if record.language and record.language ~= "" then table.insert(facts, record.language) end
    if record.publisher and record.publisher ~= "" then table.insert(facts, record.publisher) end

    local status_text
    if existing then
        status_text = T(_("Borrowed — expires %1"), formatDate(existing.expireDate))
    elseif reserved then
        status_text = T(_("Reserved (%1)"), reserved.status)
    elseif status == STATUS_LOANABLE then
        status_text = _("Available to borrow")
    elseif status then
        status_text = T(_("Not available (%1)"), status)
    end

    ------------------------------------------------------------------ actions
    if existing then
        action(_("Download"), function() EReolenDownload.loan(existing, record.title) end)
    elseif status == STATUS_LOANABLE then
        action(_("Borrow"), function() EReolenItem.borrow(host, record, reopen) end)
    end

    if checklisted then
        action(_("Remove from want-to-read"), function()
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
                reopen()
            end)
        end)
    else
        action(_("Want to read"), function()
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
                reopen()
            end)
        end)
    end

    if reserved then
        action(_("Cancel reservation"), function()
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
                        reopen()
                    end)
                end,
            })
        end)
    elseif not existing and status and status ~= STATUS_LOANABLE then
        action(_("Reserve"), function() EReolenItem.reserve(record, reopen) end)
    end

    ----------------------------------------------------------------- sections
    local cover_url = EReolenCovers:urlFor(identifier)
    if cover_url then
        section(_("View cover full size"), function() showCover(record, cover_url) end)
    end

    local settings = ereol.QuerySettings()
    -- endIndex is a count, not an end offset: 20 related titles is plenty for
    -- a section someone taps out of curiosity.
    settings.startIndex = 0
    settings.endIndex = 20

    local function relatedSection(label, page_title, fetch)
        section(label, function()
            NetworkMgr:runWhenOnline(function()
                local records, err = fetch()
                if not records then
                    EReolenItem.showRecordList(host, page_title, {}, on_back, err)
                    return
                end
                EReolenItem.showRecordList(host, page_title, records, on_back)
            end)
        end)
    end

    relatedSection(_("Other formats of this title"), _("Other formats"), function()
        local others, err = EReolenWrapper:callAllowEmpty(function(token)
            return ereol.Item.getOthersOfSameTitle(identifier, token)
        end)
        if not others then return nil, err end
        return others
    end)

    local creator = record.creators and record.creators[1]
    if creator then
        relatedSection(T(_("More by %1"), creator), creator, function()
            local page, err = EReolenWrapper:callAllowEmpty(function(token)
                return ereol.Item.getMoreOfSameCreator(identifier, token, settings)
            end)
            if not page then return nil, err end
            return flattenPage(page)
        end)
    end

    if record.series and #record.series > 0 then
        relatedSection(T(_("More in %1"), record.series[1]), record.series[1], function()
            local page, err = EReolenWrapper:callAllowEmpty(function(token)
                return ereol.Item.getMoreInSameSeries(identifier, token, settings)
            end)
            if not page then return nil, err end
            return flattenPage(page)
        end)
    end

    relatedSection(_("More in this genre"), _("Same genre"), function()
        local page, err = EReolenWrapper:callAllowEmpty(function(token)
            return ereol.Item.getMoreOfSameGenre(identifier, token, settings)
        end)
        if not page then return nil, err end
        return flattenPage(page)
    end)

    relatedSection(_("Similar titles"), _("Similar titles"), function()
        return EReolenWrapper:callAllowEmpty(function(token)
            -- This method rejects an 8th param, so the wrapper strips facets.
            return ereol.Item.getSomethingSimilar(identifier, token, settings)
        end)
    end)

    section(_("About the author"), function()
        NetworkMgr:runWhenOnline(function()
            local about, err = EReolenWrapper:callAllowEmpty(function(token)
                return ereol.Item.getAboutCreators(identifier, token)
            end)
            if not about then
                UIManager:show(InfoMessage:new{ text = err })
                return
            end
            if #about == 0 then
                UIManager:show(InfoMessage:new{ text = _("Nothing about this author.") })
                return
            end
            local parts = {}
            for _, entry in ipairs(about) do
                local block = entry.creator
                if entry.source ~= "" then block = block .. " (" .. entry.source .. ")" end
                block = block .. "\n" .. entry.subTitle
                if entry.url ~= "" then block = block .. "\n" .. entry.url end
                table.insert(parts, block)
            end
            UIManager:show(TextViewer:new{
                title = _("About the author"),
                text = table.concat(parts, "\n\n"),
            })
        end)
    end)

    section(_("Reviews"), function()
        NetworkMgr:runWhenOnline(function()
            local reviews, err = EReolenWrapper:callAllowEmpty(function(token)
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

    -------------------------------------------------------------------- show
    -- The cover is nearly always already on disk from the grid we came from, so
    -- this rarely touches the network.
    local cover_bb
    if cover_url then
        local page_cover_w = math.floor(
            (Screen:getWidth() - 2 * Size.padding.large - 18) * 0.30)
        cover_bb = EReolenCovers:thumbnail(cover_url, page_cover_w,
            math.floor(page_cover_w * 1.45))
    end

    UIManager:show(EReolenItemPage:new{
        record = record,
        cover_bb = cover_bb,
        headline = joinList(dedupeNames(record.creators)),
        facts = #facts > 0 and table.concat(facts, " · ") or nil,
        series = joinList(dedupeNames(record.series)) and
            T(_("Series: %1"), joinList(dedupeNames(record.series))) or nil,
        status_text = status_text,
        summary = blurbOf(record),
        actions = actions,
        sections = sections,
        on_close = on_back,
    })
end

return EReolenItem
