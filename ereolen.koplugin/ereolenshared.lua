--[[--
The eReolen app's browse layer, which does NOT come from the RPC API.

Front page, categories and themes all come from one public JSON blob on Firebase
Storage. Each category carries a CQL query and a list of shelves, and each shelf
is either another CQL query or a reference to a pre-baked list. The CQL goes in
`search`'s ordinary query slot -- verified: the category "Sommerlæsning" query
returns exactly the 557 results the file claims -- so browsing needs no new RPC
method at all, just `ereol.Item.search`.

The blob is ~6.5 MB decoded and 70% of it is `categories_details`, which only the
`theme_list` shelves need. So the download is parsed straight from a file with
rapidjson, a compact subset is written to a small cache, and the big table is
dropped. That parse only happens when the remote generation changes.

NOTE: the one-time parse has only been exercised on desktop. If it proves too
heavy on an e-reader, the fix is to shrink what the server hands us rather than
to hold more of it in memory.
]]

local DataStorage = require("datastorage")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")

-- Public object: no auth token is needed, despite the app sending one.
local BASE = "https://firebasestorage.googleapis.com/v0/b/ereolen-app/o/production%2Fshared.json"
local CONTENT_URL = BASE .. "?alt=media"
local META_URL = BASE

local EReolenShared = {
    cache_path = DataStorage:getSettingsDir() .. "/ereolen_shared.json",
    data = nil,
}

local function get(url, sink)
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code = socket.skip(1, http.request{ url = url, method = "GET", sink = sink })
    socketutil:reset_timeout()
    return code
end

--- Remote `generation`, which changes whenever the content is republished.
-- Cheap: the metadata document is under a kilobyte.
local function remoteGeneration()
    local sink = {}
    local code = get(META_URL, ltn12.sink.table(sink))
    if code ~= 200 then return nil, "HTTP " .. tostring(code) end
    local meta = rapidjson.decode(table.concat(sink))
    if not meta then return nil, "unparseable metadata" end
    return meta.generation or meta.updated
end

--- Many shelves hold a bare list of record ids joined by OR:
---   870970-basis:52519365 OR 870970-basis:52334551 OR ...
-- The server rejects that with code 1133; each id has to be a `rec.id=` term.
-- Category queries are already well-formed CQL and contain "=", which is what
-- tells the two apart.
local function normaliseQuery(query)
    if not query or query == "" then return nil end
    if query:find("=", 1, true) then return query end

    local terms = {}
    for term in query:gmatch("[^%s]+") do
        if term:upper() ~= "OR" and term:find(":", 1, true) then
            table.insert(terms, "rec.id=" .. term)
        end
    end
    if #terms == 0 then return query end
    return table.concat(terms, " OR ")
end

--- Keep only what the browse UI uses: titles, counts and CQL queries.
-- Drops categories_details and front_page (70%+ of the payload) and the cover
-- URL lists, which are the bulk of what is left.
local function compact(raw)
    local out = { generation = nil, categories = {}, sortings = {}, facet_labels = {} }

    for _, category in ipairs(raw.categories or {}) do
        local shelves = {}
        for _, shelf in ipairs(category.shelves or {}) do
            -- theme_list and video_bundle shelves need categories_details, which
            -- is deliberately not cached. Only query shelves are usable so far.
            if shelf.type == "query" then
                local query = normaliseQuery(shelf.query)
                if query then
                    table.insert(shelves, {
                        title = shelf.title ~= "" and shelf.title or nil,
                        query = query,
                        sort = shelf.sort ~= "" and shelf.sort or nil,
                    })
                end
            end
        end
        table.insert(out.categories, {
            title = category.title,
            count = category.count,
            query = normaliseQuery(category.query),
            cover = (category.coverUrls or {})[1],
            shelves = shelves,
        })
    end

    local settings = raw.settings or {}
    for key, value in pairs(settings.sortings or {}) do out.sortings[key] = value end
    local da = (settings.translations or {}).da or {}
    for key, value in pairs(da) do
        if key:match("^key__filter_facet__") or key:match("_ascending$") or key:match("_descending$") then
            out.facet_labels[key] = value
        end
    end
    return out
end

function EReolenShared:loadCache()
    if self.data then return self.data end
    if not lfs.attributes(self.cache_path, "mode") then return nil end
    local ok, cached = pcall(rapidjson.load, self.cache_path)
    if not ok or not cached then return nil end
    self.data = cached
    return self.data
end

--- Download and rebuild the cache when the remote content has changed.
-- Returns the compact data, or nil plus a message.
function EReolenShared:refresh(force)
    local generation, err = remoteGeneration()
    if not generation and not force then
        -- Offline: a stale cache is much better than nothing.
        local cached = self:loadCache()
        if cached then return cached end
        return nil, err
    end

    local cached = self:loadCache()
    if cached and not force and generation and cached.generation == generation then
        return cached
    end

    local tmp = self.cache_path .. ".download"
    local file = io.open(tmp, "wb")
    if not file then return nil, "cannot write " .. tmp end
    -- Straight to disk, so the 6.5 MB never becomes a Lua string as well.
    local code = get(CONTENT_URL, ltn12.sink.file(file))
    if code ~= 200 then
        os.remove(tmp)
        return nil, "HTTP " .. tostring(code)
    end

    local ok, raw = pcall(rapidjson.load, tmp)
    if not ok or not raw then
        os.remove(tmp)
        return nil, "could not parse the shared content"
    end

    local data = compact(raw)
    data.generation = generation
    raw = nil  -- luacheck: ignore
    collectgarbage()

    os.remove(tmp)
    local dumped = pcall(rapidjson.dump, data, self.cache_path)
    if not dumped then logger.warn("eReolen: could not cache shared content") end

    self.data = data
    logger.dbg("eReolen: shared content refreshed,", #data.categories, "categories")
    return data
end

function EReolenShared:categories()
    local data = self:loadCache()
    if not data then return nil end
    return data.categories
end

--- Human-readable label for a facet or sort key, from the app's own Danish strings.
function EReolenShared:label(key)
    local data = self:loadCache()
    if not data then return nil end
    return data.facet_labels[key]
end

function EReolenShared:sortings()
    local data = self:loadCache()
    if not data then return nil end
    return data.sortings
end

return EReolenShared
