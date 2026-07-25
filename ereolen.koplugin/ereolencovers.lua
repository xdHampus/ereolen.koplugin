--[[--
Cover art.

Records from search and getProduct come back with `cover` and `thumbnail` unset,
so cover URLs have to come from the separate getCovers RPC. That call takes an
array, so a whole result page is resolved in one request and cached here; the
item view then has the URL already.

getCovers works without a session, so covers still render when signed out.
]]

local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")

local EReolenWrapper = require("ereolenwrapper")

local EReolenCovers = {
    -- identifier -> url, or false when the server has no cover for it. Only
    -- URLs are cached; decoded bitmaps are far too big to hold onto on an
    -- e-reader.
    urls = {},
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

--- Cover URL for one identifier, or nil when there is none.
function EReolenCovers:urlFor(identifier)
    if self.urls[identifier] == nil then
        self:prefetch({identifier})
    end
    local url = self.urls[identifier]
    if url == false then return nil end
    return url
end

--- GET `url` and decode it. Returns a BlitBuffer, or nil plus a message.
function EReolenCovers:fetch(url)
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
    if data == "" then return nil, "empty response" end

    local bb = RenderImage:renderImageData(data, #data, false)
    if not bb then
        return nil, "could not decode " .. tostring(headers and headers["content-type"])
    end

    -- Cap at the screen so a 1500px cover does not sit in memory full size.
    -- Do not hand the target box straight to renderImageData: scaleBlitBuffer
    -- stretches to exactly the width and height given, so passing the screen
    -- size distorts every cover and upscales the small ones -- PubHub's are
    -- around 500x800, well under a Libra's 1264x1680.
    local scale = math.min(Screen:getWidth() / bb:getWidth(),
                           Screen:getHeight() / bb:getHeight())
    if scale >= 1 then return bb end
    return RenderImage:scaleBlitBuffer(bb,
        math.floor(bb:getWidth() * scale), math.floor(bb:getHeight() * scale))
end

return EReolenCovers
