--[[--
Session and account handling for the eReolen API.

`require("libereolenwrapper")` registers everything under the global `ereol`
table as a side effect. KOReader's plugin loader has already put the plugin's
own `lib/` on `package.cpath` by the time this file runs -- see
frontend/pluginloader.lua, which does this for every enabled plugin.

Credentials live in G_reader_settings. The session token does not: it is a
userdata handle, so it is kept in memory and re-created on demand.
]]

local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

require("libereolenwrapper")

local SETTINGS_KEY = "ereolen_account"

-- eReolen result codes, from bundle module 1314 plus observed values.
local CODE_WRONG_CREDENTIALS = 11101
local CODE_NO_AUTHENTICATED_USER = 12003
local CODE_VERSION_REJECTED = 10403
local CODE_UNAVAILABLE_FOR_ACCOUNT = 11675
-- Observed 2026-07-25 from createLoan on a title already on loan. Notably not
-- 10407, which is how the server rejects a malformed identifier -- so this also
-- confirmed that createLoan accepts search-form identifiers.
local CODE_ALREADY_LOANED = 13131

local EReolenWrapper = {
    token = nil,
    app_version_synced = false,
}

--- Human-readable text for a failed Response.
function EReolenWrapper:errorMessage(vc)
    if not vc then
        return _("No response from eReolen.")
    end
    local code = vc.code or 0
    if code == CODE_WRONG_CREDENTIALS then
        return _("Wrong card number or PIN.")
    elseif code == CODE_NO_AUTHENTICATED_USER then
        return _("Your eReolen session expired. Please sign in again.")
    elseif code == CODE_VERSION_REJECTED then
        return T(_("eReolen rejected this app version (%1). It needs updating."),
            ereol.ApiEnv.getAppVersion())
    elseif code == CODE_UNAVAILABLE_FOR_ACCOUNT then
        return _("This is not available for your library account.")
    elseif code == CODE_ALREADY_LOANED then
        return _("You have already borrowed this title.")
    end
    local message = vc.message
    if message == nil or message == "" then
        message = _("Unknown error")
    end
    if code ~= 0 then
        return T(_("%1 (code %2)"), message, code)
    end
    return message
end

--- Ask the server which app version it requires, once per run.
-- A stale version makes every authenticated call fail with 10403.
function EReolenWrapper:syncAppVersion()
    if self.app_version_synced then return end
    self.app_version_synced = true
    if ereol.ApiEnv.syncAppVersion() then
        logger.dbg("eReolen: app version synced to", ereol.ApiEnv.getAppVersion())
    else
        logger.warn("eReolen: could not read requiredVersion, keeping",
            ereol.ApiEnv.getAppVersion())
    end
end

function EReolenWrapper:getAccount()
    return G_reader_settings:readSetting(SETTINGS_KEY)
end

function EReolenWrapper:hasAccount()
    local account = self:getAccount()
    return account ~= nil and account.username ~= nil and account.username ~= ""
end

function EReolenWrapper:saveAccount(account)
    G_reader_settings:saveSetting(SETTINGS_KEY, account)
    self.token = nil
end

function EReolenWrapper:clearAccount()
    G_reader_settings:delSetting(SETTINGS_KEY)
    self.token = nil
end

--- Library enum value for the stored account, or nil if the code is unknown.
function EReolenWrapper:getLibrary()
    local account = self:getAccount()
    if not account or not account.library then return nil end
    return ereol.ApiEnv.getLibraryFromCode(account.library)
end

--- Authenticate and cache the token. Returns the token, or nil plus a message.
function EReolenWrapper:login(username, password, library_code)
    self:syncAppVersion()

    local library = ereol.ApiEnv.getLibraryFromCode(library_code)
    if library == nil then
        return nil, T(_("Unknown library code: %1"), library_code)
    end

    local vc = ereol.Auth.authenticate(username, password, library)
    if not vc.success then
        return nil, self:errorMessage(vc)
    end

    self.token = vc.data
    return self.token
end

--- Log in with the stored credentials if there is no live token yet.
function EReolenWrapper:ensureSession()
    if self.token then return self.token end

    local account = self:getAccount()
    if not account or not account.username then
        return nil, _("No eReolen account configured yet.")
    end

    return self:login(account.username, account.password, account.library)
end

--- Run an API call with a valid session, recovering from 12003.
-- `fn` receives the token and returns a Response table.
-- Returns the response data, or nil plus a message.
--
-- eReolen hands out 12003 intermittently on sessions that are still good
-- (observed 2026-07-25: getLoans succeeded, the identical call a moment later
-- returned 12003, and the next one succeeded again -- most likely a
-- load-balanced session store). So retry the same session once before spending
-- a fresh authenticate, then re-authenticate and try once more.
function EReolenWrapper:call(fn)
    local token, err = self:ensureSession()
    if not token then return nil, err end

    local vc = fn(token)

    if vc and not vc.success and vc.code == CODE_NO_AUTHENTICATED_USER then
        logger.dbg("eReolen: 12003, retrying with the same session")
        vc = fn(token)
    end

    if vc and not vc.success and vc.code == CODE_NO_AUTHENTICATED_USER then
        logger.dbg("eReolen: still 12003, re-authenticating")
        self.token = nil
        token, err = self:ensureSession()
        if not token then return nil, err end
        vc = fn(token)
    end

    if not vc or not vc.success then
        return nil, self:errorMessage(vc)
    end
    return vc.data
end

function EReolenWrapper:logout()
    if self.token then
        ereol.Auth.deauthenticate(self.token)
    end
    self.token = nil
end

--- Email and phone, which addReservation requires. Stored beside the card.
function EReolenWrapper:getContact()
    local account = self:getAccount() or {}
    return account.email, account.phone
end

function EReolenWrapper:saveContact(email, phone)
    local account = self:getAccount() or {}
    account.email = email
    account.phone = phone
    -- Keep the live token: this is not a credential change.
    local token = self.token
    self:saveAccount(account)
    self.token = token
end

--- The three account-wide lists, memoised.
-- An item view wants to know whether a title is on loan, on the want-to-read
-- list and reserved. Fetching all three every time an item opens is three round
-- trips per tap, so they are cached until something mutates them.
function EReolenWrapper:profileLists(force)
    if self.profile_cache and not force then return self.profile_cache end

    local lists = {}
    lists.loans = self:call(function(token) return ereol.Profile.getLoans(token) end) or {}
    lists.checklist = self:call(function(token) return ereol.Profile.getCheckList(token) end) or {}
    lists.reservations = self:call(function(token) return ereol.Profile.getReservations(token) end) or {}

    self.profile_cache = lists
    return lists
end

function EReolenWrapper:invalidateProfile()
    self.profile_cache = nil
end

--- Find an entry for `isbn` in one of those lists.
-- Matches on ISBN because a search result's identifier carries an extra source
-- field that the account lists' identifiers do not -- see ereolenitem.lua.
function EReolenWrapper.findByIsbn(list, isbn, identifier)
    if not list then return nil end
    for i = 1, #list do
        local li = list[i].loanIdentifier
        if (isbn and isbn ~= "" and li.isbn == isbn) or li.identifier == identifier then
            return list[i]
        end
    end
    return nil
end

--- Resolve identifiers to Records in one getRecordsByIdentifiers call.
-- Returns a map of identifier -> Record. Empty when the lookup fails: titles
-- are a nicety and the caller can still fall back to the ISBN.
function EReolenWrapper:getRecordsByIdentifier(identifiers)
    if #identifiers == 0 then return {} end
    local records, err = self:call(function(token)
        return ereol.Item.getRecords(identifiers, token)
    end)
    if not records then
        logger.dbg("eReolen: could not resolve titles:", err)
        return {}
    end
    return records
end

return EReolenWrapper
