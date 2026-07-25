--[[--
Item detail view: what a single title is, whether it can be borrowed, and the
Borrow button.

Rendered into a host Menu rather than as its own widget, so it works the same
from search results and from the Account tab. The host must provide
showPage(title, item_table, on_back) -- see EReolenAccount:showPage.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

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

--- Look up this title's loan status and whether it is already borrowed.
-- Returns status (string or nil) and the LoanActive if one exists.
--
-- Matches on ISBN, not identifier: a search result's identifier carries an extra
-- source field that getLoans' does not, so the two never compare equal for the
-- same book. e.g. {"i":"978…","s":"870970-basis:48341624","c":"ereolen"} from
-- search vs {"i":"978…","c":"ereolen"} from getLoans. The ISBN is stable.
local function loanState(record)
    local identifier = record.loanIdentifier.identifier
    local isbn = record.loanIdentifier.isbn

    local status
    local statuses = EReolenWrapper:call(function(token)
        return ereol.Item.getLoanStatuses({identifier}, token)
    end)
    if statuses then status = statuses[identifier] end

    local existing
    local loans = EReolenWrapper:call(function(token)
        return ereol.Profile.getLoans(token)
    end)
    if loans then
        for i = 1, #loans do
            local li = loans[i].loanIdentifier
            if (isbn and isbn ~= "" and li.isbn == isbn) or li.identifier == identifier then
                existing = loans[i]
                break
            end
        end
    end
    return status, existing
end

--- How many of the library's concurrent-loan slots are in use.
-- Returns used, max. max is nil when the profile cannot be read.
local function quota()
    local loans = EReolenWrapper:call(function(token)
        return ereol.Profile.getLoans(token)
    end)
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
                UIManager:show(InfoMessage:new{
                    text = T(_("Borrowed “%1”."), label),
                    timeout = 2,
                })
                if refresh then refresh() end
            end)
        end,
    })
end

--- Renders `record` into `host`. `on_back` returns to whatever came before.
function EReolenItem.show(host, record, on_back)
    local identifier = record.loanIdentifier.identifier
    local status, existing = loanState(record)

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

    local refresh = function() EReolenItem.show(host, record, on_back) end

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
