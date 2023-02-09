--[[
    This code is derived from the LAPHLibs which can be found here:

    https://github.com/Wiladams/LAPHLibs
    local lib = package.loadlib("./libnativefunc.so", "luaopen_libnativefunc")
lib();
--]]
local util = require("util")
local luxl = require("luxl")
local ffi = require("ffi")
local logger = require("logger")
--local lnf = require("libnativefunc")
local nl = require("libereolenwrapper")

local EReolenWrapper = {}

function EReolenWrapper:parse()
    logger.dbg("TESTING")
    logger.dbg("TESTING")
    logger.dbg("TESTING")
    logger.dbg("TESTING")
    logger.dbg("TESTING")
    logger.dbg("TESTING")
    logger.dbg("TESTING")
    logger.dbg("TESTING")
    logger.dbg("TESTING")
    logger.dbg("TESTING\n\n")
    local r = ereol.Review()
    r.source = "12"
    print(r:toJson())
    logger.dbg("\n\nTESTING")


end

return EReolenWrapper
