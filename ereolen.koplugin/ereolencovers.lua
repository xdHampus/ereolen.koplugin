--[[--
Cover art.

Records from search and getProduct come back with `cover` and `thumbnail` unset,
so cover URLs have to come from the separate getCovers RPC. That call takes an
array, so a whole result page is resolved in one request and cached here; views
then have the URL already. getCovers works without a session, so covers still
render when signed out.

Two caches sit under that:

  * the encoded bytes, on disk, keyed by URL. A cover is 20-60 KB and never
    changes, so re-fetching one over Wi-Fi to draw a grid the user has already
    seen is pure latency. The directory is capped and pruned oldest-first.
  * decoded thumbnails, in memory, keyed by URL and target size. Decoding is
    fast but not free, and a grid redraws on every page turn.

Anything drawn at grid size stays small: a 3-across mosaic on a Libra is about
380x530, which is 200 KB as an 8bpp BlitBuffer, so a page of nine is under
2 MB and the LRU keeps two pages' worth.
]]

local DataStorage = require("datastorage")
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")
local util = require("util")

local EReolenWrapper = require("ereolenwrapper")

local CACHE_DIR = DataStorage:getDataDir() .. "/cache/ereolen-covers"
local CACHE_MAX_FILES = 400
local THUMB_LRU_MAX = 24

local EReolenCovers = {
    -- identifier -> url, or false when the server has no cover for it.
    urls = {},
    -- "<url>@<w>x<h>" -> BlitBuffer, most recently used last in `thumb_order`.
    thumbs = {},
    thumb_order = {},
}

--- Resolve cover URLs for many identifiers in one call and cache them.
function EReolenCovers:prefetch(identifiers)
    local missing = {}
    for _, id in ipairs(identifiers) do
        if self.urls[id] == nil then table.insert(missing, id) end
    end
    if #missing == 0 then return end

    local covers = EReolenWrapper:call(function(token)
        return ereol.Item.getCoverUrls(missing, token)
    end)
    if not covers then
        logger.dbg("eReolen: cover lookup failed")
        return
    end

    for _, id in ipairs(missing) do
        -- Remember the misses too, so we do not ask again for every redraw.
        self.urls[id] = covers[id] or false
    end
end

--- Seed known URLs without an RPC call.
-- The front page blob already carries a cover URL for every record on it, so
-- the whole front page draws without touching getCovers at all.
function EReolenCovers:seed(map)
    if not map then return end
    for identifier, url in pairs(map) do
        if self.urls[identifier] == nil and type(url) == "string" and url ~= "" then
            self.urls[identifier] = url
        end
    end
end

--- Cover URL for one identifier, or nil when there is none.
function EReolenCovers:urlFor(identifier)
    if self.urls[identifier] == nil then
        self:prefetch({identifier})
    end
    local url = self.urls[identifier]
    if url == false then return nil end
    return url
end

--- True when the URL is already on disk, so drawing it costs no network.
function EReolenCovers:isCached(url)
    return url ~= nil and lfs.attributes(self:cachePath(url), "mode") == "file"
end

function EReolenCovers:cachePath(url)
    -- djb2 over the URL. Collisions would only mean a wrong cover, and the
    -- length guard makes them vanishingly unlikely in a 400-file directory.
    local hash = 5381
    for i = 1, #url do
        hash = (hash * 33 + url:byte(i)) % 0x7FFFFFFF
    end
    return string.format("%s/%08x-%d", CACHE_DIR, hash, #url)
end

local function ensureCacheDir()
    if lfs.attributes(CACHE_DIR, "mode") == "directory" then return true end
    return util.makePath(CACHE_DIR)
end

--- Keep the cover cache from growing without bound. Cheap: one readdir.
function EReolenCovers:pruneCache()
    if lfs.attributes(CACHE_DIR, "mode") ~= "directory" then return end
    local entries = {}
    for name in lfs.dir(CACHE_DIR) do
        if name ~= "." and name ~= ".." then
            local path = CACHE_DIR .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                table.insert(entries, { path = path, at = attr.modification or 0 })
            end
        end
    end
    if #entries <= CACHE_MAX_FILES then return end
    table.sort(entries, function(a, b) return a.at < b.at end)
    for i = 1, #entries - CACHE_MAX_FILES do
        os.remove(entries[i].path)
    end
    logger.dbg("eReolen: pruned", #entries - CACHE_MAX_FILES, "cached covers")
end

--- Encoded image bytes for `url`, from disk when possible.
function EReolenCovers:bytes(url)
    local path = self:cachePath(url)
    local file = io.open(path, "rb")
    if file then
        local data = file:read("*a")
        file:close()
        if data and #data > 0 then return data end
    end

    local sink = {}
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, headers = socket.skip(1, http.request{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()

    if code ~= 200 then
        return nil, "HTTP " .. tostring(code)
    end
    local data = table.concat(sink)
    if data == "" then
        return nil, "empty response"
    end

    if ensureCacheDir() then
        local out = io.open(path, "wb")
        if out then
            out:write(data)
            out:close()
        end
    end
    return data, nil, headers
end

--- Scale `bb` so it fits, without distorting it.
-- scaleBlitBuffer scales to exactly the width and height it is given, so the
-- ratio has to be worked out here.
--
-- `fit` picks which dimension rules. "box" keeps the whole image inside w x h,
-- which is right for a full-screen viewer. "height" makes every cover exactly
-- `h` tall and lets the width fall where it may -- covers are not all the same
-- shape, and matching on the smaller scale left rows of them visibly ragged
-- along the bottom. Width is still clamped, so an unusually wide cover cannot
-- push its neighbours out of the row.
local function fitTo(bb, w, h, fit)
    if not (w and h) then return bb end
    local scale
    if fit == "height" then
        scale = h / bb:getHeight()
        local max_w = w * 1.25
        if bb:getWidth() * scale > max_w then scale = max_w / bb:getWidth() end
    else
        scale = math.min(w / bb:getWidth(), h / bb:getHeight())
    end
    if scale >= 1 then return bb end
    return RenderImage:scaleBlitBuffer(bb,
        math.max(1, math.floor(bb:getWidth() * scale)),
        math.max(1, math.floor(bb:getHeight() * scale)))
end

--- GET `url` and decode it at full size, capped to the screen.
-- Returns a BlitBuffer, or nil plus a message.
function EReolenCovers:fetch(url)
    local data, err, headers = self:bytes(url)
    if not data then return nil, err end

    local bb = RenderImage:renderImageData(data, #data, false)
    if not bb then
        return nil, "could not decode " .. tostring(headers and headers["content-type"])
    end
    return fitTo(bb, Screen:getWidth(), Screen:getHeight(), "box")
end

local function lruTouch(self, key)
    for i = #self.thumb_order, 1, -1 do
        if self.thumb_order[i] == key then table.remove(self.thumb_order, i) end
    end
    table.insert(self.thumb_order, key)
    while #self.thumb_order > THUMB_LRU_MAX do
        local evicted = table.remove(self.thumb_order, 1)
        local bb = self.thumbs[evicted]
        self.thumbs[evicted] = nil
        if bb then bb:free() end
    end
end

--- A cover scaled to fit `w` x `h`, cached. Returns a BlitBuffer or nil.
-- The buffer belongs to this cache: draw it, do not free it, and do not hand it
-- to a widget that disposes of its image.
function EReolenCovers:thumbnail(url, w, h)
    if not url then return nil end
    local key = string.format("%s@%dx%d", url, w, h)
    local hit = self.thumbs[key]
    if hit then
        lruTouch(self, key)
        return hit
    end

    local data, err = self:bytes(url)
    if not data then
        logger.dbg("eReolen: cover fetch failed", url, err)
        return nil
    end
    -- Decode straight to roughly the target: MuPDF and turbojpeg both take the
    -- box, and a smaller decode is a faster decode. fitTo then corrects the
    -- aspect ratio, since the decoders stretch to the box they are given.
    local bb = RenderImage:renderImageData(data, #data, false)
    if not bb then return nil end
    bb = fitTo(bb, w, h, "height")

    self.thumbs[key] = bb
    lruTouch(self, key)
    return bb
end

--- Drop decoded thumbnails. Called when a view that used them goes away.
function EReolenCovers:releaseThumbnails()
    for _, bb in pairs(self.thumbs) do
        if bb then bb:free() end
    end
    self.thumbs = {}
    self.thumb_order = {}
end

return EReolenCovers
