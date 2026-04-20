local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local _ = require("gettext")

local CATEGORIES = {
    { tag = "math.OA", name = "Operator Algebras" },
    { tag = "math.FA", name = "Functional Analysis" },
    { tag = "math.SP", name = "Spectral Theory" },
    { tag = "math.PR", name = "Probability" },
    { tag = "math.ST", name = "Statistics Theory" },
}

local ARXIV_DOWNLOAD_DIR = "/mnt/us/documents/arxiv/"
local ARXIV_API_URL = "http://export.arxiv.org/api/query"
local MAX_RESULTS = 10

local ArxivBrowser = WidgetContainer:extend{
    name = "arxiv_browser",
    is_doc_only = false,
}

function ArxivBrowser:init()
    self.ui.menu:registerToMainMenu(self)
end

function ArxivBrowser:addToMainMenu(menu_items)
    menu_items.arxiv_browser = {
        text = _("arXiv Browser"),
        sorting_hint = "tools",
        callback = function()
            NetworkMgr:runWhenOnline(function()
                self:showCategoryMenu()
            end)
        end,
    }
end

function ArxivBrowser:showCategoryMenu()
    local items = {}
    for _, cat in ipairs(CATEGORIES) do
        local tag = cat.tag
        local name = cat.name
        table.insert(items, {
            text = name,
            mandatory = tag,
            callback = function()
                UIManager:close(self.category_menu)
                self:fetchAndShowPapers(tag)
            end,
        })
    end
    self.category_menu = Menu:new{
        title = _("arXiv Categories"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
    }
    UIManager:show(self.category_menu)
end

function ArxivBrowser:fetchAndShowPapers(category, start)
    start = start or 0
    local loading = InfoMessage:new{ text = _("Fetching papers…") }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local url = ARXIV_API_URL
        .. "?search_query=cat:" .. category
        .. "&sortBy=submittedDate&sortOrder=descending"
        .. "&max_results=" .. MAX_RESULTS
        .. "&start=" .. start

    local response = {}
    local ok, err = pcall(function()
        local _, code = http.request{
            url = url,
            sink = ltn12.sink.table(response),
        }
        if code ~= 200 then
            error("HTTP " .. tostring(code))
        end
    end)

    UIManager:close(loading)

    if not ok then
        UIManager:show(InfoMessage:new{
            text = _("Failed to fetch papers: ") .. tostring(err),
        })
        return
    end

    local xml_str = table.concat(response)
    local papers = self:parseAtomFeed(xml_str)

    if not papers or #papers == 0 then
        UIManager:show(InfoMessage:new{ text = _("No papers found.") })
        return
    end

    self:showPaperList(papers, category, start)
end

function ArxivBrowser:parseAtomFeed(xml_str)
    local xml_module = require("lib.xml")
    local handler_module = require("lib.handler")

    local h = handler_module.simpleTreeHandler()
    h.options.noreduce = { entry = true, author = true, link = true }
    local parser = xml_module.xmlParser(h)
    local ok, err = pcall(function() parser:parse(xml_str) end)

    if not ok then
        logger.warn("ArxivBrowser: XML parse error:", err)
        return {}
    end

    local feed = h.root and h.root.feed
    if not feed then return {} end

    local entries = feed.entry
    if not entries then return {} end

    local papers = {}
    for _, entry in ipairs(entries) do
        local id = entry.id or ""
        if type(id) == "table" then id = id[1] or "" end
        local arxiv_id = id:match("abs/(.-)%s*$") or id
        arxiv_id = arxiv_id:match("^(.-)v%d+$") or arxiv_id

        local title = entry.title or "Untitled"
        if type(title) == "table" then title = title[1] or "Untitled" end
        title = title:gsub("%s+", " "):match("^%s*(.-)%s*$")

        local authors = {}
        if entry.author then
            for _, a in ipairs(entry.author) do
                if type(a) == "table" then
                    local name = a.name
                    if type(name) == "table" then name = name[1] end
                    if name then table.insert(authors, name) end
                end
            end
        end

        local published = entry.published or ""
        if type(published) == "table" then published = published[1] or "" end
        local date = published:match("^(%d%d%d%d%-%d%d%-%d%d)") or ""

        table.insert(papers, {
            id = arxiv_id,
            title = title,
            authors = authors,
            date = date,
        })
    end

    return papers
end

function ArxivBrowser:showPaperList(papers, category, start)
    local items = {}
    for _, paper in ipairs(papers) do
        local p = paper
        table.insert(items, {
            text = p.title,
            mandatory = p.date,
            callback = function()
                UIManager:close(self.paper_menu)
                self:downloadAndOpenPaper(p)
            end,
        })
    end

    table.insert(items, {
        text = _("See next 10"),
        callback = function()
            UIManager:close(self.paper_menu)
            self:fetchAndShowPapers(category, start + MAX_RESULTS)
        end,
    })

    self.paper_menu = Menu:new{
        title = _("Recent: ") .. category,
        item_table = items,
        is_borderless = true,
        is_popout = false,
    }
    UIManager:show(self.paper_menu)
end

local function https_get(url, sink, redirect_count)
    redirect_count = redirect_count or 0
    if redirect_count > 5 then error("Too many redirects") end

    local https = require("ssl.https")
    local response_body = {}
    local actual_sink = sink or ltn12.sink.table(response_body)
    local _, code, headers = https.request{
        url = url,
        sink = actual_sink,
    }
    if (code == 301 or code == 302 or code == 303 or code == 307 or code == 308)
        and headers and headers.location then
        return https_get(headers.location, sink, redirect_count + 1)
    end
    return code
end

function ArxivBrowser:downloadAndOpenPaper(paper)
    if not lfs.attributes(ARXIV_DOWNLOAD_DIR, "mode") then
        lfs.mkdir(ARXIV_DOWNLOAD_DIR)
    end

    local safe_id = paper.id:gsub("/", "_")
    local filepath = ARXIV_DOWNLOAD_DIR .. safe_id .. ".pdf"

    if lfs.attributes(filepath, "mode") then
        self:openDocument(filepath)
        return
    end

    local loading = InfoMessage:new{
        text = _("Downloading…\n") .. paper.title,
    }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local pdf_url = "https://arxiv.org/pdf/" .. paper.id

    local ok, err = pcall(function()
        local file = io.open(filepath, "wb")
        if not file then error("Cannot create file: " .. filepath) end
        local code = https_get(pdf_url, ltn12.sink.file(file))
        if code ~= 200 then
            os.remove(filepath)
            error("HTTP " .. tostring(code))
        end
    end)

    UIManager:close(loading)

    if not ok then
        UIManager:show(InfoMessage:new{
            text = _("Download failed: ") .. tostring(err),
        })
        return
    end

    self:openDocument(filepath)
end

function ArxivBrowser:openDocument(filepath)
    local ReaderUI = require("apps/reader/readerui")
    UIManager:scheduleIn(0.1, function()
        ReaderUI:showReader(filepath)
    end)
end

return ArxivBrowser
