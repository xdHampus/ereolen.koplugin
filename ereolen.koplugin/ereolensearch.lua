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
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local EReolenItem = require("ereolenitem")
local EReolenShared = require("ereolenshared")
local EReolenWrapper = require("ereolenwrapper")

local PAGE_SIZE = 20

local EReolenSearch = Menu:extend{
    width = Screen:getWidth(),
    height = Screen:getHeight() * 0.9,
    no_title = false,
    parent = nil,
}

function EReolenSearch:init()
    self.title = _("Search")
    self.title_bar_left_icon = nil
    self.item_table = self:genStartStateItemTable()
    Menu.init(self) -- call parent's init()
end

--- Same contract as EReolenAccount:showPage, so EReolenItem can render into us.
function EReolenSearch:showPage(title, item_table, on_back)
    table.insert(item_table, {
        text = _("Back"),
        deletable = false, editable = false,
        callback = on_back or function() self:init() end,
    })
    self.title = title
    self.item_table = item_table
    Menu.init(self)
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

--- PageResult.data is a list of collections, each a list of Record.
local function flattenResults(page)
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
    if record.creators and record.creators[1] then
        label = T("%1 — %2", label, record.creators[1])
    end
    if record.recordType then
        label = T("%1 (%2)", label, record.recordType)
    end
    return label
end

function EReolenSearch:runSearch(query, offset, label)
    if query == nil or query == "" then return end
    self.last_query = query
    self.last_label = label

    NetworkMgr:runWhenOnline(function()
        local settings = ereol.QuerySettings()
        settings.startIndex = offset
        settings.endIndex = offset + PAGE_SIZE

        local page, err = EReolenWrapper:call(function(token)
            return ereol.Item.search(query, token, settings)
        end)
        if not page then
            UIManager:show(InfoMessage:new{ text = err })
            return
        end

        self:showResults(query, offset, page, label)
    end)
end

function EReolenSearch:showResults(query, offset, page, label)
    local records = flattenResults(page)
    local item_table = {}

    -- A browsed shelf has a name; only a typed query is worth offering to edit.
    if label then
        table.insert(item_table, {
            text = _("New search"),
            deletable = false, editable = false,
            callback = function() self:displayNewSearch() end,
        })
    else
        table.insert(item_table, {
            text = T(_("Edit search: %1"), query),
            deletable = false, editable = false,
            callback = function() self:displayNewSearch(query) end,
        })
    end

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

    for _, record in ipairs(records) do
        table.insert(item_table, {
            text = describe(record),
            deletable = false, editable = false,
            callback = function()
                EReolenItem.show(self, record, function()
                    self:showResults(query, offset, page, label)
                end)
            end,
        })
    end

    if offset > 0 then
        table.insert(item_table, {
            text = _("< Previous page"),
            deletable = false, editable = false,
            callback = function() self:runSearch(query, math.max(0, offset - PAGE_SIZE), label) end,
        })
    end
    if page.more then
        table.insert(item_table, {
            text = _("Next page >"),
            deletable = false, editable = false,
            callback = function() self:runSearch(query, offset + PAGE_SIZE, label) end,
        })
    end

    -- PageResult.count counts records, but startIndex/endIndex page over
    -- *collections*, each of which groups a title's ebook and audiobook
    -- editions. So there is no honest record range to show -- only a page
    -- number and the total.
    local shown = label or query
    local title = shown
    if page.count and page.count > 0 then
        local page_no = math.floor(offset / PAGE_SIZE) + 1
        title = T(_("%1 — page %2 (%3 results)"), shown, page_no, page.count)
    end

    self.title = title
    self.item_table = item_table
    table.insert(self.item_table, {
        text = _("Back"),
        deletable = false, editable = false,
        callback = function() self:init() end,
    })
    Menu.init(self)
end

return EReolenSearch
