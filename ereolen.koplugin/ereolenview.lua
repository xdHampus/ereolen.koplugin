--[[--
The widget every list of books is drawn with: search results, a shelf, related
titles, loans, the want-to-read list.

Two presentations over the same rows, switchable from the title bar and
remembered in G_reader_settings:

  * "mosaic"  -- a grid of cover art, which is how the app presents everything.
  * "list"    -- one row per title with a thumbnail, plus author, type, year and
                 whether it is on loan. Denser, and readable without covers.

Covers arrive progressively. Building a page blocks on nothing: tiles paint
immediately with their title as a placeholder, then a chain of nextTick tasks
fetches one cover at a time and repaints just that tile. A page turn bumps a
generation counter and the in-flight chain gives up, so flipping through pages
never queues work for pages nobody is looking at any more.

The rows themselves are ordinary Menu entries. A row with `record` set draws as
a book; one without draws as an action tile ("Show more", "Back"), so callers
can mix navigation into a grid without a second widget.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local Screen = Device.screen
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")

local EReolenCovers = require("ereolencovers")

local VIEW_MODE_KEY = "ereolen_view_mode"

-- Covers are portrait, near enough to 1:1.45 across both PubHub and OverDrive.
local COVER_RATIO = 1.45

local EReolenView = Menu:extend{
    -- Set by callers that want the grid; account lists default to the list mode
    -- because "3 loans" does not need nine tiles.
    view_mode = nil,
    is_borderless = true,
    is_popout = false,
}

function EReolenView.getViewMode()
    return G_reader_settings:readSetting(VIEW_MODE_KEY) or "mosaic"
end

function EReolenView.setViewMode(mode)
    G_reader_settings:saveSetting(VIEW_MODE_KEY, mode)
end

--- Which presentation this item table should actually get.
-- A page of pure navigation -- the category list, the account root -- has no
-- covers to show, so a grid of bordered text boxes would be worse than a plain
-- list however the setting is set. Scanned once per item table, not per redraw.
function EReolenView:_effectiveMode()
    if self._scanned_table ~= self.item_table then
        self._scanned_table = self.item_table
        self._has_records = false
        self._has_shelves = false
        for _, entry in ipairs(self.item_table or {}) do
            if entry.record or entry.cover_url then self._has_records = true end
            if entry.shelf then self._has_shelves = true end
        end
    end
    if self._has_shelves then return "shelves" end
    if not self._has_records then return "list" end
    return self.view_mode or EReolenView.getViewMode()
end

--- Build a row for `record`. One place, so every list -- results, shelves,
--- loans, related titles -- describes a book the same way.
-- `status` is optional trailing text such as "on loan until 24-08".
function EReolenView.recordRow(record, callback, status)
    local creator = record.creators and record.creators[1] or nil
    local bits = {}
    if record.recordType and record.recordType ~= "" then
        table.insert(bits, record.recordType)
    end
    if record.year and record.year ~= "" then
        table.insert(bits, tostring(record.year))
    end
    if record.publisher and record.publisher ~= "" then
        table.insert(bits, record.publisher)
    end
    if status and status ~= "" then table.insert(bits, status) end

    return {
        record = record,
        text = record.title or "",
        subtitle = creator,
        detail = table.concat(bits, " · "),
        -- The grid has room for a title and, if it is short, the author.
        caption = (function()
            local lines = { record.title }
            if creator then table.insert(lines, creator) end
            if status and status ~= "" then table.insert(lines, status) end
            return table.concat(lines, "\n")
        end)(),
        callback = callback,
        deletable = false, editable = false,
    }
end

--------------------------------------------------------------------------- tiles

--- A cover, or a bordered box with the title in it when there is none yet.
-- The image is drawn at whatever size the cache produced; see coverBox below
-- for why that is a fixed height rather than a fixed box.
local function coverOrPlaceholder(bb, title, w, h)
    if bb then
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            ImageWidget:new{
                image = bb,
                -- The cache owns this buffer and reuses it on the next redraw.
                image_disposable = false,
            },
        }
    end
    return FrameContainer:new{
        width = w,
        height = h,
        margin = 0,
        padding = Size.padding.small,
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * Size.padding.small, h = h - 2 * Size.padding.small },
            TextBoxWidget:new{
                text = title or "",
                face = Font:getFace("cfont", 15),
                width = w - 4 * Size.padding.small,
                alignment = "center",
            },
        },
    }
end

local RecordTile = InputContainer:extend{}

function RecordTile:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
    self:update()
end

function RecordTile:update()
    local entry = self.entry
    local inner_w = self.width - 2 * Size.padding.small

    if not (entry.record or entry.cover_url) then
        -- An action tile: "Show more", "Back". Bordered so it reads as a
        -- control rather than a book with a missing cover.
        self[1] = FrameContainer:new{
            width = self.width,
            height = self.height,
            margin = 0,
            padding = Size.padding.small,
            bordersize = Size.border.thin,
            radius = Size.radius.window,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = self.height - 2 * Size.padding.small },
                TextBoxWidget:new{
                    text = entry.text or "",
                    face = Font:getFace("cfont", 17),
                    width = inner_w,
                    alignment = "center",
                },
            },
        }
        return
    end

    -- Two lines of title plus author at 15px, with a little air. At 22% the
    -- second line collided with the covers on the row below.
    local caption_h = math.floor(self.height * 0.30)
    local cover_h = self.height - caption_h - Size.padding.small
    local cover_w = math.min(inner_w, math.floor(cover_h / COVER_RATIO))

    local caption = TextBoxWidget:new{
        text = entry.caption or entry.text or "",
        face = Font:getFace("cfont", 15),
        width = inner_w,
        alignment = "center",
        height = caption_h,
        -- Clip to the slot: height_adjust let a three-line caption grow past it
        -- and overlap the covers on the next row.
        height_adjust = false,
        height_overflow_show_ellipsis = true,
    }

    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        margin = 0,
        padding = Size.padding.small,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = cover_h },
                coverOrPlaceholder(self.cover_bb, entry.text, cover_w, cover_h),
            },
            VerticalSpan:new{ width = Size.padding.small },
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = caption_h },
                caption,
            },
        },
    }
end

function RecordTile:setCover(bb)
    self.cover_bb = bb
    self:update()
end

function RecordTile:onTap()
    if self.menu and self.entry then
        self.menu:onMenuSelect(self.entry)
    end
    return true
end

local ListRow = InputContainer:extend{}

function ListRow:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
    self:update()
end

function ListRow:update()
    local entry = self.entry
    local pad = Size.padding.default
    local inner_h = self.height - 2 * pad

    if not (entry.record or entry.cover_url) then
        self[1] = FrameContainer:new{
            width = self.width,
            height = self.height,
            margin = 0,
            padding = pad,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            LeftContainer:new{
                dimen = Geom:new{ w = self.width - 2 * pad, h = inner_h },
                TextWidget:new{
                    text = entry.text or "",
                    face = Font:getFace("cfont", 19),
                    max_width = self.width - 2 * pad,
                },
            },
        }
        return
    end

    local thumb_h = inner_h
    local thumb_w = math.floor(thumb_h / COVER_RATIO)
    local text_w = self.width - 2 * pad - thumb_w - Size.padding.large

    local lines = VerticalGroup:new{ align = "left" }
    table.insert(lines, TextWidget:new{
        text = entry.text or "",
        face = Font:getFace("cfont", 19),
        max_width = text_w,
    })
    if entry.subtitle and entry.subtitle ~= "" then
        table.insert(lines, VerticalSpan:new{ width = Size.padding.small })
        table.insert(lines, TextWidget:new{
            text = entry.subtitle,
            face = Font:getFace("cfont", 16),
            max_width = text_w,
        })
    end
    if entry.detail and entry.detail ~= "" then
        table.insert(lines, VerticalSpan:new{ width = Size.padding.small })
        table.insert(lines, TextWidget:new{
            text = entry.detail,
            face = Font:getFace("cfont", 14),
            max_width = text_w,
        })
    end

    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        margin = 0,
        padding = pad,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = thumb_w, h = thumb_h },
                coverOrPlaceholder(self.cover_bb, nil, thumb_w, thumb_h),
            },
            HorizontalSpan:new{ width = Size.padding.large },
            CenterContainer:new{
                dimen = Geom:new{ w = text_w, h = inner_h },
                LeftContainer:new{
                    dimen = Geom:new{ w = text_w, h = inner_h },
                    lines,
                },
            },
        },
    }
end

ListRow.setCover = RecordTile.setCover
ListRow.onTap = RecordTile.onTap

--- A front-page shelf: its name, then a strip of covers from it.
-- Each cover is tappable on its own, and the name opens the whole shelf.
local ShelfStrip = InputContainer:extend{}

function ShelfStrip:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.covers = {}
    self:update()
end

function ShelfStrip:update()
    local pad = Size.padding.default
    local title_h = Size.item.height_default
    local strip_h = self.height - title_h - 2 * pad
    local cover_h = strip_h
    local cover_w = math.floor(cover_h / COVER_RATIO)
    local gap = Size.padding.large

    -- As many covers as fit, and never more than the shelf has.
    local fits = math.max(1, math.floor((self.width - 2 * pad + gap) / (cover_w + gap)))
    self.visible = math.min(fits, #self.entry.shelf.items)

    local strip = HorizontalGroup:new{ align = "top" }
    self.slots = {}
    for i = 1, self.visible do
        local item = self.entry.shelf.items[i]
        local slot = CenterContainer:new{
            dimen = Geom:new{ w = cover_w, h = cover_h },
            coverOrPlaceholder(self.covers[i], item.title, cover_w, cover_h),
        }
        self.slots[i] = slot
        table.insert(strip, slot)
        if i < self.visible then
            table.insert(strip, HorizontalSpan:new{ width = gap })
        end
    end

    self.cover_w, self.cover_h = cover_w, cover_h
    self.strip_x, self.strip_gap = pad, gap
    self.strip_y = title_h + pad

    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        margin = 0,
        padding = pad,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            LeftContainer:new{
                dimen = Geom:new{ w = self.width - 2 * pad, h = title_h },
                TextWidget:new{
                    text = self.entry.shelf.title,
                    face = Font:getFace("tfont", 20),
                    max_width = self.width - 2 * pad,
                },
            },
            strip,
        },
    }
    self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
end

function ShelfStrip:setCover(index, bb)
    self.covers[index] = bb
    self:update()
end

--- Which cover was tapped, if any. Anything else opens the shelf itself.
function ShelfStrip:onTap(_, ges)
    local x = ges.pos.x - self.dimen.x - self.strip_x
    local y = ges.pos.y - self.dimen.y - self.strip_y
    if y >= 0 and y <= self.cover_h and x >= 0 then
        local slot = math.floor(x / (self.cover_w + self.strip_gap)) + 1
        local within = x - (slot - 1) * (self.cover_w + self.strip_gap)
        if slot >= 1 and slot <= self.visible and within <= self.cover_w then
            if self.entry.on_item then
                self.entry.on_item(self.entry.shelf.items[slot])
                return true
            end
        end
    end
    if self.menu and self.entry then
        self.menu:onMenuSelect(self.entry)
    end
    return true
end

--------------------------------------------------------------------- geometry

function EReolenView:_recalculateDimen(no_recalculate_dimen)
    local mode = self:_effectiveMode()
    local landscape = Screen:getWidth() > Screen:getHeight()

    if self._has_shelves then
        self.nb_cols = 1
        self.nb_rows = landscape and 2 or 3
    elseif mode == "mosaic" then
        self.nb_cols = landscape and 4 or 3
        self.nb_rows = landscape and 2 or 3
    elseif self._has_records then
        self.nb_cols = 1
        self.nb_rows = landscape and 4 or 6
    else
        -- Plain navigation rows: fit more of them on screen.
        self.nb_cols = 1
        self.nb_rows = landscape and 8 or 12
    end
    self.perpage = self.nb_cols * self.nb_rows

    local top_height = 0
    if self.title_bar and not self.no_title then
        top_height = self.title_bar:getHeight()
    end
    local bottom_height = 0
    if self.page_return_arrow and self.page_info_text then
        bottom_height = math.max(self.page_return_arrow:getSize().h,
                                 self.page_info_text:getSize().h) + Size.padding.button
    end

    self.available_height = self.inner_dimen.h - top_height - bottom_height
    self.item_width = math.floor(self.inner_dimen.w / self.nb_cols)
    self.item_height = math.floor(self.available_height / self.nb_rows)
    self.item_dimen = Geom:new{
        x = 0, y = 0, w = self.item_width, h = self.item_height,
    }

    self.page_num = self:getPageNumber(#self.item_table)
    if self.page > self.page_num then self.page = self.page_num end
    if self.page < 1 then self.page = 1 end
end

------------------------------------------------------------------ cover loading

--- Walk the visible tiles fetching one cover per tick.
-- Sequential on purpose: two covers at once would not be faster on a single
-- Lua thread, and one at a time lets a page turn cancel the rest.
function EReolenView:_loadCovers(tiles, generation)
    local index = 0
    local function step()
        if generation ~= self.cover_generation then return end -- page moved on
        index = index + 1
        local tile = tiles[index]
        if not tile then return end

        local url = tile.cover_url
        if url then
            local bb = EReolenCovers:thumbnail(url, tile.cover_w, tile.cover_h)
            if generation ~= self.cover_generation then return end
            if bb then
                if tile.strip then
                    tile.strip:setCover(tile.index, bb)
                else
                    tile:setCover(bb)
                end
                UIManager:setDirty(self.show_parent or self, function()
                    return "ui", tile.dimen
                end)
            end
        end
        UIManager:nextTick(step)
    end
    UIManager:nextTick(step)
end

--- Resolve cover URLs for a page in one RPC, then let the tiles draw.
function EReolenView:_resolveCoverUrls(entries)
    local wanted = {}
    for _, entry in ipairs(entries) do
        local id = entry.record and entry.record.loanIdentifier
            and entry.record.loanIdentifier.identifier
        -- Skip anything that already brought its own URL along.
        if id and not entry.cover_url and EReolenCovers.urls[id] == nil then
            table.insert(wanted, id)
        end
    end
    if #wanted > 0 then
        EReolenCovers:prefetch(wanted)
    end
end

--------------------------------------------------------------------- rendering

function EReolenView:updateItems(select_number, no_recalculate_dimen)
    local old_dimen = self.dimen and self.dimen:copy()
    self.layout = {}
    self.item_group:clear()
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.content_group:resetLayout()
    self:_recalculateDimen(no_recalculate_dimen)

    -- Anything still loading covers is for a page we have left.
    self.cover_generation = (self.cover_generation or 0) + 1
    local generation = self.cover_generation

    local mode = self:_effectiveMode()
    local mosaic = mode == "mosaic"
    local first = (self.page - 1) * self.perpage + 1
    local last = math.min(first + self.perpage - 1, #self.item_table)

    local page_entries = {}
    for i = first, last do table.insert(page_entries, self.item_table[i]) end
    self:_resolveCoverUrls(page_entries)

    local tiles = {}
    local row_group
    for i, entry in ipairs(page_entries) do
        if mosaic and (i - 1) % self.nb_cols == 0 then
            row_group = HorizontalGroup:new{ align = "top" }
            table.insert(self.item_group, row_group)
        end

        local Tile = entry.shelf and ShelfStrip or (mosaic and RecordTile or ListRow)
        local tile = Tile:new{
            entry = entry,
            menu = self,
            width = self.item_width,
            height = self.item_height,
            show_parent = self.show_parent or self,
        }

        if entry.shelf then
            for i = 1, tile.visible or 0 do
                local item = entry.shelf.items[i]
                if item and item.cover then
                    table.insert(tiles, {
                        strip = tile, index = i, cover_url = item.cover,
                        cover_w = tile.cover_w, cover_h = tile.cover_h,
                        dimen = tile.dimen,
                    })
                end
            end
        end

        local id = entry.record and entry.record.loanIdentifier
            and entry.record.loanIdentifier.identifier
        if entry.cover_url then
            tile.cover_url = entry.cover_url
        elseif id then
            tile.cover_url = EReolenCovers:urlFor(id)
        end
        if tile.cover_url then
            if mosaic then
                tile.cover_h = self.item_height - math.floor(self.item_height * 0.30)
                tile.cover_w = math.floor(tile.cover_h / COVER_RATIO)
            else
                tile.cover_h = self.item_height - 2 * Size.padding.default
                tile.cover_w = math.floor(tile.cover_h / COVER_RATIO)
            end
            table.insert(tiles, tile)
        end

        if mosaic then
            table.insert(row_group, tile)
        else
            table.insert(self.item_group, tile)
        end
        table.insert(self.layout, { tile })
    end

    self:updatePageInfo(select_number)
    self:mergeTitleBarIntoLayout()

    UIManager:setDirty(self.show_parent, function()
        local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
        return "ui", refresh_dimen
    end)

    if #tiles > 0 then
        self:_loadCovers(tiles, generation)
    end
end

--- Show `item_table` as a sub-page, with the footer's return arrow to go back.
-- Menu draws that arrow when onReturn is set and enables it while paths is
-- non-empty, so both have to be maintained.
function EReolenView:showRecords(title, item_table, on_back)
    if on_back then
        self.paths = { title }
        self.onReturn = function()
            self.paths = {}
            self.onReturn = nil
            on_back()
        end
    else
        self.paths = {}
        self.onReturn = nil
    end
    self:switchItemTable(title, item_table)
end

--- Put a grid/list toggle in the title bar of any page that shows books.
-- Menu builds the title bar in init(), so callers set these before init runs.
function EReolenView:setupViewToggle()
    -- Left, not right: Menu hands close_callback to the title bar
    -- unconditionally, so the right slot is always the close button, and Menu
    -- never forwards a right_icon anyway. The page-view glyph reads as "how
    -- this page is laid out".
    self.title_bar_left_icon = "appbar.pageview"
    self.onLeftButtonTap = function()
        self:toggleViewMode()
    end
end

--- Swap presentation without refetching anything.
function EReolenView:toggleViewMode()
    local mode = (self.view_mode or EReolenView.getViewMode()) == "mosaic"
        and "list" or "mosaic"
    self.view_mode = mode
    EReolenView.setViewMode(mode)
    self.page = 1
    self:updateItems(1, false)
end

function EReolenView:onCloseWidget()
    self.cover_generation = (self.cover_generation or 0) + 1
    Menu.onCloseWidget(self)
end

return EReolenView
