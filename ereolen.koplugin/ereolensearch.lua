local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local Cache = require("cache")
local ConfirmBox = require("ui/widget/confirmbox")
local DocumentRegistry = require("document/documentregistry")
local Font = require("ui/font")
local ImageViewer = require("ui/widget/imageviewer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputDialog = require("ui/widget/inputdialog")
local Button = require("ui/widget/button")
local VerticalGroup = require("ui/widget/verticalgroup")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local Blitbuffer = require("ffi/blitbuffer")
local TextWidget = require("ui/widget/textwidget")
local HorizontalGroup = require("ui/widget/horizontalgroup")

--local ffi = require("ffi")
--local lnf = require("libereolenwrapper")
--ffi.cdef[[
--void Sleep(int ms);
--int poll(struct pollfd *fds, unsigned long nfds, int timeout);
--]]
local nl = require("libereolenwrapper")


local EReolenSearch = Menu:extend{
    search_template_type = "application/atom%+xml",
    acquisition_rel = "^http://opds%-spec%.org/acquisition",
    image_rel = "http://opds-spec.org/image",
    thumbnail_rel = "http://opds-spec.org/image/thumbnail",
    stream_rel = "http://vaemendis.net/opds-pse/stream",

    width = Screen:getWidth(),
    height = Screen:getHeight() * 0.9,
    no_title = false,
    parent = nil,
}



function EReolenSearch:init()
    self.catalog_title = nil
    self.title_bar_left_icon = nil
    self.item_table = self:genStartStateItemTable()
    Menu.init(self) -- call parent's init()
end

function EReolenSearch:displayNewSearch(default_text)
    self.search_input = InputDialog:new{
        title = _("Search"),
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
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        self:newSearch(self.search_input:getInputText())
                        self.search_input:onClose()
                        UIManager:close(self.search_input)
                    end,
                },
            }
        },
        close_callback = function() self.search_input = nil end,
    }
    UIManager:show(self.search_input)
    self.search_input:onShowKeyboard()
end

function EReolenSearch:genStartStateItemTable()
    local item_table = {}
    table.insert(item_table, {
        text = "New search",
        deletable = false, editable = false,
        callback = function() self:displayNewSearch() end,
    })
    table.insert(item_table, {
        text = "Categories",
        deletable = false, editable = false,
    })
    table.insert(item_table, {
        text = "Themes",
        deletable = false, editable = false,
    })
    return item_table
end

function EReolenSearch:newSearch(searchQuery)
    local item_table = {}
    table.insert(item_table, {
        text = "Edit search: "..searchQuery,
        deletable = false, editable = false,
        callback = function() self:displayNewSearch(searchQuery) end,
    })
    table.insert(item_table, {
        text = "Back",
        deletable = false, editable = false,
        --callback = function() self:init() end
    })
  
    local t = ereol.Token()
    t.library = ereol.Library.ODENSE
    --print(t.library)


    local vc = ereol.Item.search(searchQuery, t, ereol.QuerySettings())
    
    --print(vc.message)
    --print(vc.success)
    --print(vc.detailedMessage)
    if vc.success and (vc.data ~= nil) then
        --print(vc.data.count)
        --print(vc.data.more)
        for _,resultEntries in ipairs(vc.data.data) do
            for _,entry in ipairs(resultEntries) do
                --[[

                print("Title:   \t"..entry.title)
                print("Record type:\t"..entry.recordType)
                print("Abstract:\t"..entry.abstract)
                print("Description:\t"..entry.description)
                print("\n")
                ]]--                
                
                if entry.recordType == "ebook" then
                    table.insert(item_table, {
                        text = entry.title.." - "..entry.recordType,
                        deletable = false, editable = false,
                        callback = function() self:viewSearchEntry(entry) end,
                    })
                end
            end
        end
    end
  
    self:newSearchInit(item_table)
end

function EReolenSearch:newSearchInit(item_table)
    self.item_table = item_table
    self.close_callback = function()
        self.has_close_button = false
        --self.close_callback = nil
        self.onLeftButtonTap = nil
        --self:init()
    end
    self.title_bar_left_icon = "appbar.menu"
    self.has_close_button = true
    self.onLeftButtonTap = function()
        self:changeSearchFilters()
    end
    Menu.init(self)
end


-- Shows dialog to download / stream a book
function EReolenSearch:viewSearchEntry(item)
    local acquisitions = {}
    table.insert(acquisitions, {
        type  = "application/pdf",
        href  = "https://www.africau.edu/images/default/sample.pdf",
        title = "pdf",
        count = 1,
    })

    local filename = item.title
    if item.creators[0] then
        filename = item.creators[0] .. " - " .. filename
    end
    local filename_orig = filename

    local function createTitle(path, file) -- title for ButtonDialogTitle
        return T(_("Download folder:\n%1\n\nDownload filename:\n%2\n\nDownload file type:"),
            BD.dirpath(path), file)
    end

    local buttons = {} -- buttons for ButtonDialogTitle
    local stream_buttons -- page stream buttons
    local download_buttons = {} -- file type download buttons
    
    for i, acquisition in ipairs(acquisitions) do -- filter out unsupported file types
        local filetype = util.getFileNameSuffix(acquisition.href)
        logger.dbg("Filetype for download is", filetype)
        if not DocumentRegistry:hasProvider("dummy." .. filetype) then
            filetype = nil
        end
        if not filetype and DocumentRegistry:hasProvider(nil, acquisition.type) then
            filetype = DocumentRegistry:mimeToExt(acquisition.type)
        end
        if filetype then -- supported file type
            local text = url.unescape(acquisition.title or string.upper(filetype))
            table.insert(download_buttons, {
                text = text .. "\u{2B07}", -- append DOWNWARDS BLACK ARROW
                callback = function()
                    self:downloadFile(filename .. "." .. string.lower(filetype), acquisition.href)
                    UIManager:close(self.download_dialog)
                end,
            })
        end
    end
    

    local buttons_nb = #download_buttons
    if buttons_nb > 0 then
        if buttons_nb == 1 then -- one wide button
            table.insert(buttons, download_buttons)
        else
            if buttons_nb % 2 == 1 then -- we need even number of buttons
                table.insert(download_buttons, {text = ""})
            end
            for i = 1, buttons_nb, 2 do -- two buttons in a row
                table.insert(buttons, {download_buttons[i], download_buttons[i+1]})
            end
        end
        table.insert(buttons, {}) -- separator
    end
    if stream_buttons then
        table.insert(buttons, stream_buttons)
        table.insert(buttons, {}) -- separator
    end
    table.insert(buttons, { -- action buttons
        {
            text = _("Choose folder"),
            callback = function()
                require("ui/downloadmgr"):new{
                    onConfirm = function(path)
                        logger.dbg("Download folder set to", path)
                        G_reader_settings:saveSetting("download_dir", path)
                        self.download_dialog:setTitle(createTitle(path, filename))
                    end,
                }:chooseDir(self.getCurrentDownloadDir())
            end,
        },
        {
            text = _("Change filename"),
            callback = function()
                local dialog
                dialog = InputDialog:new{
                    title = _("Enter filename"),
                    input = filename,
                    input_hint = filename_orig,
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                id = "close",
                                callback = function()
                                    UIManager:close(dialog)
                                end,
                            },
                            {
                                text = _("Set filename"),
                                is_enter_default = true,
                                callback = function()
                                    filename = dialog:getInputValue()
                                    if filename == "" then
                                        filename = filename_orig
                                    end
                                    UIManager:close(dialog)
                                    self.download_dialog:setTitle(createTitle(self.getCurrentDownloadDir(), filename))
                                end,
                            },
                        }
                    },
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end,
        },
    })
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.download_dialog)
            end,
        },
        {
            text = _("Book information"),
            enabled = true,
            callback = function()
                local TextViewer = require("ui/widget/textviewer")
                UIManager:show(TextViewer:new{
                    title = item.title,
                    title_multilines = true,
                    text = self.entryItemToPlainText(item),
                    text_face = Font:getFace("x_smallinfofont", G_reader_settings:readSetting("items_font_size")),
                })
            end,
        },
    })

    self.download_dialog = ButtonDialogTitle:new{
        title = createTitle(self.getCurrentDownloadDir(), filename),
        buttons = buttons,
    }
    UIManager:show(self.download_dialog)
end


function EReolenSearch.entryItemToPlainText(item)
    return util.htmlToPlainTextIfHtml(
        "Title: "..item.title
        .."<br>Publisher:"..item.publisher
        .."<br>Language:"..item.language
        .."<br>Media Type:"..item.mediaType
        ..((item.year == nil) and "" or ("<br>Year:"..item.year))
        ..((item.seriesPart == nil) and "" or ("<br>Series:"..item.seriesPart))
        ..((item.edition == nil) and "" or ("<br>Edition:"..item.edition))
        .."<br><br>Description:<br>"..item.description
        ..((item.firstPublished == nil) and "" or ("<br>First Published:"..item.firstPublished))
        ..((item.abstract == nil) and "" or ("<br><br>Abstract:<br>"..item.abstract.."<br>"))
    )
end

-- Downloads a book (with "File already exists" dialog)
function EReolenSearch:downloadFile(filename, remote_url)
    local download_dir = self.getCurrentDownloadDir()

    filename = util.getSafeFilename(filename, download_dir)
    local local_path = (download_dir ~= "/" and download_dir or "") .. '/' .. filename
    local_path = util.fixUtf8(local_path, "_")

    local function download()
        UIManager:scheduleIn(1, function()
            logger.dbg("Downloading file", local_path, "from", remote_url)
            local parsed = url.parse(remote_url)

            local code, headers, status
            if parsed.scheme == "http" or parsed.scheme == "https" then
                socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
                code, headers, status = socket.skip(1, http.request {
                    url      = remote_url,
                    headers  = {
                        ["Accept-Encoding"] = "identity",
                    },
                    sink     = ltn12.sink.file(io.open(local_path, "w")),
                    user     = self.root_catalog_username,
                    password = self.root_catalog_password,
                })
                socketutil:reset_timeout()
            else
                UIManager:show(InfoMessage:new {
                    text = T(_("Invalid protocol:\n%1"), parsed.scheme),
                })
            end

            if code == 200 then
                logger.dbg("File downloaded to", local_path)
                self:fileDownloadedCallback(local_path)
            elseif code == 302 and remote_url:match("^https") and headers.location:match("^http[^s]") then
                util.removeFile(local_path)
                UIManager:show(InfoMessage:new{
                    text = T(_("Insecure HTTPS → HTTP downgrade attempted by redirect from:\n\n'%1'\n\nto\n\n'%2'.\n\nPlease inform the server administrator that many clients disallow this because it could be a downgrade attack."), BD.url(remote_url), BD.url(headers.location)),
                    icon = "notice-warning",
                })
            else
                util.removeFile(local_path)
                logger.dbg("OPDSBrowser:downloadFile: Request failed:", status or code)
                logger.dbg("OPDSBrowser:downloadFile: Response headers:", headers)
                UIManager:show(InfoMessage:new {
                    text = T(_("Could not save file to:\n%1\n%2"),
                        BD.filepath(local_path),
                        status or code or "network unreachable"),
                })
            end
        end)

        UIManager:show(InfoMessage:new{
            text = _("Downloading may take several minutes…"),
            timeout = 1,
        })
    end

    if lfs.attributes(local_path) then
        UIManager:show(ConfirmBox:new{
            text = T(_("The file %1 already exists. Do you want to overwrite it?"), BD.filepath(local_path)),
            ok_text = _("Overwrite"),
            ok_callback = function()
                download()
            end,
        })
    else
        download()
    end
end

-- Returns user selected or last opened folder
function EReolenSearch.getCurrentDownloadDir()
    return G_reader_settings:readSetting("download_dir") or G_reader_settings:readSetting("lastdir")
end

function EReolenSearch:fileDownloadedCallback(downloaded_file)
    UIManager:show(ConfirmBox:new{
        text = T(_("File saved to:\n%1\nWould you like to read the downloaded book now?"),
                    BD.filepath(downloaded_file)),
        ok_text = _("Read now"),
        cancel_text = _("Read later"),
        ok_callback = function()
            local Event = require("ui/event")
            UIManager:broadcastEvent(Event:new("SetupShowReader"))

            self:onClose()

            local ReaderUI = require("apps/reader/readerui")
            ReaderUI:showReader(downloaded_file)
        end
    })
end


function EReolenSearch:changeSearchFilters()
end


return EReolenSearch
