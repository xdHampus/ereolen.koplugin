--[[--
Search tab: query the eReolen catalogue and open a result.

Previously this built a blank ereol.Token() against a hardcoded Library.ODENSE,
so it searched unauthenticated as the wrong library, and its own download
dialog pointed at a sample PDF on africau.edu. Both are gone: the search runs
through the signed-in session, and results hand off to the item view, which owns
borrowing and downloading.
]]

local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local EReolenView = require("ereolenview")
local NetworkMgr = require("ui/network/manager")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local EReolenItem = require("ereolenitem")
local EReolenShared = require("ereolenshared")
local EReolenWrapper = require("ereolenwrapper")

-- How many collections to ask for at a time. A collection groups a title's
-- ebook and audiobook editions, and it is collections the paging addresses, not
-- records.
--
-- Note what the two QuerySettings fields actually mean, verified against the
-- live API 2026-07-25: startIndex is an offset, but **endIndex is a count, not
-- an end offset**, and it is capped at 200 -- 250 comes back as an HTTP error.
-- The old code set endIndex = offset + PAGE_SIZE, so every page was larger than
-- the one before it (page 2 fetched 40 collections, page 3 sixty...) and past
-- offset 200 the request simply failed.
--
-- 100 is a compromise: about 180 records and ~3s on a Kobo, and enough that
-- most searches need no second request at all.
local PAGE_COLLECTIONS = 100

local EReolenSearch = EReolenView:extend{
    width = Screen:getWidth(),
    height = Screen:getHeight() * 0.9,
    no_title = false,
    parent = nil,
}

function EReolenSearch:init()
    self.title = _("Search")
    self.title_bar_left_icon = nil
    self.item_table = self:genStartStateItemTable()
    self:setupViewToggle()
    EReolenView.init(self) -- call parent's init()
end

--- Same contract as EReolenAccount:showPage, so EReolenItem can render into us.
--- Back to the search root without re-running Menu.init on a live widget.
function EReolenSearch:showStart()
    self:switchItemTable(_("Search"), self:genStartStateItemTable())
end

function EReolenSearch:showPage(title, item_table, on_back)
    self:showRecords(title, item_table, on_back or function() self:showStart() end)
end

function EReolenSearch:genStartStateItemTable()
    local item_table = {}
    table.insert(item_table, {
        text = _("New search"),
        deletable = false, editable = false,
        callback = function() self:displayNewSearch() end,
    })
    if self.last_query then
        table.insert(item_table, {
            text = T(_("Again: %1"), self.last_label or self.last_query),
            deletable = false, editable = false,
            callback = function() self:runSearch(self.last_query, 0, self.last_label) end,
        })
    end
    table.insert(item_table, {
        text = _("Browse categories"),
        deletable = false, editable = false,
        callback = function() self:showCategories() end,
    })
    return item_table
end

--- Search typeahead. getSuggestions needs no session, so this works signed out.
function EReolenSearch:showSuggestions(prefix)
    if prefix == nil or prefix == "" then
        UIManager:show(InfoMessage:new{ text = _("Type something to get suggestions for.") })
        return
    end
    NetworkMgr:runWhenOnline(function()
        local suggestions, err = EReolenWrapper:call(function(token)
            return ereol.Item.getSuggestions(prefix, token)
        end)
        if not suggestions then
            UIManager:show(InfoMessage:new{ text = err })
            return
        end

        local item_table = {}
        if #suggestions == 0 then
            table.insert(item_table, {
                text = _("No suggestions"),
                deletable = false, editable = false,
            })
        end
        local seen = {}
        for _, suggestion in ipairs(suggestions) do
            local text = suggestion.suggestion
            if text ~= "" and not seen[text] then
                seen[text] = true
                table.insert(item_table, {
                    text = text,
                    deletable = false, editable = false,
                    callback = function() self:runSearch(text, 0) end,
                })
            end
        end
        self:showPage(T(_("Suggestions for “%1”"), prefix), item_table)
    end)
end

--- The app's curated categories, from Firebase rather than the RPC API.
function EReolenSearch:showCategories()
    NetworkMgr:runWhenOnline(function()
        local data, err = EReolenShared:refresh()
        if not data then
            UIManager:show(InfoMessage:new{
                text = T(_("Could not load the categories:\n%1"), err),
            })
            return
        end

        local item_table = {}
        for _, category in ipairs(data.categories) do
            local label = category.title
            if category.count then label = T("%1 (%2)", label, category.count) end
            table.insert(item_table, {
                text = label,
                deletable = false, editable = false,
                callback = function() self:showCategory(category) end,
            })
        end
        self:showPage(_("Categories"), item_table)
    end)
end

--- One category: its own query plus whichever shelves are CQL-backed.
function EReolenSearch:showCategory(category)
    local back = function() self:showCategories() end
    local item_table = {}

    if category.query then
        table.insert(item_table, {
            text = T(_("Everything in %1"), category.title),
            deletable = false, editable = false,
            callback = function() self:runSearch(category.query, 0, category.title) end,
        })
    end

    for _, shelf in ipairs(category.shelves or {}) do
        local title = shelf.title or _("Untitled shelf")
        table.insert(item_table, {
            text = title,
            deletable = false, editable = false,
            callback = function() self:runSearch(shelf.query, 0, title) end,
        })
    end

    if #item_table == 0 then
        table.insert(item_table, {
            text = _("Nothing browsable in this category yet"),
            deletable = false, editable = false,
        })
    end
    self:showPage(category.title, item_table, back)
end

function EReolenSearch:displayNewSearch(default_text)
    self.search_input = InputDialog:new{
        title = _("Search eReolen"),
        input = default_text,
        show_parent = self,
        input_hint = _("Search query"),
        description = _("Input search query. Use AND or OR to improve results."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        self.search_input:onClose()
                        UIManager:close(self.search_input)
                    end,
                },
                {
                    text = _("Suggest"),
                    callback = function()
                        local prefix = self.search_input:getInputText()
                        self.search_input:onClose()
                        UIManager:close(self.search_input)
                        self:showSuggestions(prefix)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = self.search_input:getInputText()
                        self.search_input:onClose()
                        UIManager:close(self.search_input)
                        self:runSearch(query, 0)
                    end,
                },
            }
        },
        close_callback = function() self.search_input = nil end,
    }
    UIManager:show(self.search_input)
    self.search_input:onShowKeyboard()
end

--- One Record per collection.
-- PageResult.data groups a title's editions together, so flattening it put the
-- same book on screen two or three times over -- "Vejen til Wigan Pier" as
-- ebook and as audiobook, side by side. Take the first of each and let the item
-- view's "Other formats of this title" row reach the rest. An ebook is the
-- better default on an e-reader, so prefer one when the collection has both.
local function flattenResults(page)
    local records = {}
    for _, collection in ipairs(page.data or {}) do
        local pick = collection[1]
        for _, record in ipairs(collection) do
            if record.recordType == "ebook" then pick = record break end
        end
        if pick then table.insert(records, pick) end
    end
    return records
end

local function describe(record)
    local label = record.title
    if record.creators and record.creators[1] then
        label = T("%1 — %2", label, record.creators[1])
    end
    if record.recordType then
        label = T("%1 (%2)", label, record.recordType)
    end
    return label
end

--- `offset` is a collection offset. `append` keeps what is already on screen
-- and adds to it, which is what the "Show more" row at the end does.
function EReolenSearch:runSearch(query, offset, label, append)
    if query == nil or query == "" then return end
    self.last_query = query
    self.last_label = label

    NetworkMgr:runWhenOnline(function()
        local settings = ereol.QuerySettings()
        settings.startIndex = offset
        settings.endIndex = PAGE_COLLECTIONS -- a count, not an end offset

        local page, err = EReolenWrapper:call(function(token)
            return ereol.Item.search(query, token, settings)
        end)
        if not page then
            UIManager:show(InfoMessage:new{ text = err })
            return
        end

        self:showResults(query, offset, page, label, append)
    end)
end

function EReolenSearch:showResults(query, offset, page, label, append)
    local records = flattenResults(page)
    local item_table = {}
    -- Rows are rebuilt from scratch each time; only the accumulated record rows
    -- carry over, so the header and footer are never duplicated.
    local kept = (append and self.result_rows) or {}
    local shown_before = #kept

    -- Starting another search is the SEARCH tab's job, not a tile's: see
    -- ereolencatalog.lua, which opens the query dialog when the tab is tapped
    -- while search results are already showing.

    if #records == 0 then
        table.insert(item_table, {
            text = _("No results"),
            deletable = false, editable = false,
        })
        -- A typed query that found nothing is exactly when suggestions help.
        if not label then
            table.insert(item_table, {
                text = T(_("Suggestions for “%1”"), query),
                deletable = false, editable = false,
                callback = function() self:showSuggestions(query) end,
            })
        end
    end

    for i = 1, #kept do table.insert(item_table, kept[i]) end
    local record_rows = kept
    for _, record in ipairs(records) do
        local row = EReolenView.recordRow(record, function()
            EReolenItem.show(self, record, function()
                self:showResults(query, offset, page, label)
            end)
        end)
        table.insert(item_table, row)
        table.insert(record_rows, row)
    end

    -- Remember only the record rows, so a later "Show more" extends the list
    -- instead of re-adding the header and footer.
    self.result_rows = record_rows

    local total = page.count or 0
    local shown = #records + shown_before

    if page.more then
        -- Advance by the collections actually returned: near the end of a
        -- result set the server hands back fewer than were asked for.
        local next_offset = offset + #page.data
        table.insert(item_table, {
            text = T(_("Show more (%1 of %2 shown)"), shown, total),
            deletable = false, editable = false,
            callback = function() self:runSearch(query, next_offset, label, true) end,
        })
    end

    -- PageResult.count counts records while the indices address collections, so
    -- a page range would be a guess. The count is honest, and KOReader's own
    -- menu footer supplies "page x of y" for the rows now that the whole
    -- result set lives in one item table.
    local name = label or query
    local title = name
    if shown > 0 then
        -- `total` counts records and `shown` counts titles, so the two are not
        -- comparable; say which one this is and whether there are more.
        title = page.more
            and T(_("%1 — %2 titles, more available"), name, shown)
            or T(_("%1 — %2 titles"), name, shown)
    end

    -- A negative itemnumber tells switchItemTable to stay on the current page,
    -- which is what makes "Show more" feel like growing the list.
    self:showRecords(title, item_table, function() self:showStart() end)
    if append then self.page = math.min(self.page, self.page_num) end
end

return EReolenSearch
