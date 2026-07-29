--[[--
KaraKo plugin for KOReader.

Synchronises unread articles from a Karakeep server onto the device as EPUBs,
and pushes read status and highlights back when you are done with them.

The overall shape follows wallabag.koplugin, which solves the same problem for
a different read-it-later service. The notable differences are that Karakeep has
no EPUB export endpoint (so epubbuilder.lua assembles one on device) and that it
does have a highlights API (so highlights.lua can push annotations back).

@module koplugin.karako.main
]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local FileManager = require("apps/filemanager/filemanager")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = ffiUtil.template

local ArticleUtil = require("articleutil")
local Config = require("config")
local EpubBuilder = require("epubbuilder")
local Highlights = require("highlights")
local KarakeepApi = require("api")

-- Named "karako", not "karakeep": AlgusDark's karakeep.koplugin sends bookmarks
-- and clippings to Karakeep, which is the opposite direction to this plugin, and
-- the two are useful together. Sharing a plugin name, menu key or settings file
-- would stop them coexisting.
local KaraKo = WidgetContainer:extend{
    name = "karako",
    is_doc_only = false,
}

function KaraKo:onDispatcherRegisterActions()
    Dispatcher:registerAction("karako_sync", {
        category = "none",
        event = "SynchronizeKarako",
        title = _("Synchronise KaraKo"),
        general = true,
    })
    Dispatcher:registerAction("karako_go_to_directory", {
        category = "none",
        event = "GoToKarakoDirectory",
        title = _("Go to KaraKo folder"),
        general = true,
    })
end

function KaraKo:init()
    self:logBuild()
    self.settings = self:openSettings()
    self:loadSettings()
    self:applyConfigFile()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

--- Log which copy of the plugin is actually running.
--
-- A stack trace gives line numbers, which are useless for telling a fixed copy
-- from a stale one still sitting in the plugins directory. The path and the
-- modification time of main.lua settle it immediately.
function KaraKo:logBuild()
    local path = self.path or "?"
    local main_lua = ffiUtil.joinPath(path, "main.lua")
    local modified = lfs.attributes(main_lua, "modification")

    logger.info(string.format("KaraKo: version %s, main.lua modified %s, loaded from %s",
        self.version or "?",
        modified and os.date("%Y-%m-%d %H:%M:%S", modified) or "?",
        path))
end

--- Where a config file may live, in the order they are tried.
--
-- The data directory first, because it survives replacing the plugin folder;
-- next to the plugin second, because that is the folder you just copied over
-- and the obvious place to look.
-- @treturn table Array of paths.
function KaraKo:configPaths()
    local data_dir = DataStorage:getDataDir()
    return {
        data_dir .. "/karako.conf",
        data_dir .. "/settings/karako.conf",
        ffiUtil.joinPath(self.path or ".", "karako.conf"),
    }
end

--- Find a config file, if there is one.
-- @treturn string|nil Path.
function KaraKo:findConfigFile()
    for _, path in ipairs(self:configPaths()) do
        if lfs.attributes(path, "mode") == "file" then
            return path
        end
    end
end

--- Apply a config file over the stored settings.
--
-- Settings the file names win, every start, which is what makes the file
-- declarative. Settings it leaves out stay under the menu's control.
--
-- @treturn string|nil Path applied.
-- @treturn table Problems found in the file.
function KaraKo:applyConfigFile()
    local path = self:findConfigFile()
    if not path then return nil, {} end

    local values, problems = Config.read(path)
    if not values then return nil, problems end

    local applied = 0
    for key, value in pairs(values) do
        self[key] = value
        applied = applied + 1
    end

    if applied > 0 then
        -- Persist, so the settings survive the file being removed later.
        self:onFlushSettings()
    end

    logger.info("KaraKo: applied", applied, "settings from", path)
    for _, problem in ipairs(problems) do
        logger.warn("KaraKo: " .. path .. ": " .. problem)
    end

    self.config_path = path
    return path, problems
end

--- Open our settings, migrating from the name an earlier build used.
--
-- This plugin used to write settings/karakeep.lua, which is also the file
-- AlgusDark's karakeep.koplugin uses. Migration is therefore guarded on a key
-- only we write, so that an install of that plugin is never mistaken for our
-- own old settings and read in.
-- @treturn table LuaSettings
function KaraKo:openSettings()
    local settings_dir = DataStorage:getSettingsDir()
    local settings = LuaSettings:open(settings_dir .. "/karako.lua")

    if settings:readSetting("server_url") ~= nil then
        return settings -- already ours, nothing to do
    end

    local legacy = LuaSettings:open(settings_dir .. "/karakeep.lua")
    if legacy:readSetting("articles_per_sync") == nil then
        return settings -- not ours: either absent, or another plugin's
    end

    logger.info("KaraKo: migrating settings from karakeep.lua to karako.lua")
    for key, value in pairs(legacy.data or {}) do
        settings:saveSetting(key, value)
    end
    settings:flush()

    return settings
end

function KaraKo:loadSettings()
    self.server_url = self.settings:readSetting("server_url", "")
    self.api_token = self.settings:readSetting("api_token", "")
    self.directory = self.settings:readSetting("directory")

    self.articles_per_sync = self.settings:readSetting("articles_per_sync", 30)
    self.sync_scope = self.settings:readSetting("sync_scope", "all")
    self.scope_id = self.settings:readSetting("scope_id")
    self.scope_name = self.settings:readSetting("scope_name")

    self.download_images = self.settings:readSetting("download_images", true)
    self.max_images = self.settings:readSetting("max_images", 20)

    self.archive_finished = self.settings:readSetting("archive_finished", true)
    self.archive_read = self.settings:readSetting("archive_read", true)
    self.archive_abandoned = self.settings:readSetting("archive_abandoned", false)
    self.archive_tag = self.settings:readSetting("archive_tag", "")
    self.delete_local_after_archive = self.settings:readSetting("delete_local_after_archive", true)

    self.sync_highlights = self.settings:readSetting("sync_highlights", true)
end

function KaraKo:onFlushSettings()
    if self.settings then
        self.settings:saveSetting("server_url", self.server_url)
        self.settings:saveSetting("api_token", self.api_token)
        self.settings:saveSetting("directory", self.directory)
        self.settings:saveSetting("articles_per_sync", self.articles_per_sync)
        self.settings:saveSetting("sync_scope", self.sync_scope)
        self.settings:saveSetting("scope_id", self.scope_id)
        self.settings:saveSetting("scope_name", self.scope_name)
        self.settings:saveSetting("download_images", self.download_images)
        self.settings:saveSetting("max_images", self.max_images)
        self.settings:saveSetting("archive_finished", self.archive_finished)
        self.settings:saveSetting("archive_read", self.archive_read)
        self.settings:saveSetting("archive_abandoned", self.archive_abandoned)
        self.settings:saveSetting("archive_tag", self.archive_tag)
        self.settings:saveSetting("delete_local_after_archive", self.delete_local_after_archive)
        self.settings:saveSetting("sync_highlights", self.sync_highlights)
        self.settings:flush()
    end
end

function KaraKo:getApi()
    return KarakeepApi:new{
        server_url = self.server_url,
        api_token = self.api_token,
    }
end

function KaraKo:isReady()
    return self.server_url ~= "" and self.api_token ~= "" and self.directory ~= nil
end

--------------------------------------------------------------------------------
-- Menu
--------------------------------------------------------------------------------

function KaraKo:addToMainMenu(menu_items)
    menu_items.karako = {
        text = _("KaraKo"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Synchronise now"),
                callback = function() self:onSynchronizeKarako() end,
            },
            {
                text = _("Send read status and highlights"),
                keep_menu_open = true,
                callback = function()
                    if not self:isReady() then
                        UIManager:show(InfoMessage:new{
                            text = _("Set the server address, API key and download folder first."),
                        })
                        return
                    end
                    NetworkMgr:runWhenOnline(function()
                        local Trapper = require("ui/trapper")
                        Trapper:wrap(function()
                            self:uploadStatuses(self:getLocalArticles(), false)
                        end)
                    end)
                end,
            },
            {
                text = _("Go to KaraKo folder"),
                callback = function() self:onGoToKarakoDirectory() end,
            },
            {
                text = _("Server"),
                keep_menu_open = true,
                callback = function(touchmenu_instance) self:editServerSettings(touchmenu_instance) end,
            },
            {
                text_func = function()
                    if self.config_path then return _("Settings file: in use") end
                    return _("Settings file: none")
                end,
                help_text = _("Set up KaraKo from a text file instead of typing an API key on the device."),
                separator = true,
                keep_menu_open = true,
                sub_item_table_func = function() return self:configFileMenu() end,
            },
            {
                text_func = function()
                    return T(_("What to sync: %1"), self:describeScope())
                end,
                keep_menu_open = true,
                sub_item_table_func = function() return self:scopeMenu() end,
            },
            {
                text_func = function()
                    return T(_("Articles per sync: %1"), self.articles_per_sync)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance) self:setArticlesPerSync(touchmenu_instance) end,
            },
            {
                text = _("Download folder"),
                keep_menu_open = true,
                callback = function(touchmenu_instance) self:setDownloadDirectory(touchmenu_instance) end,
            },
            {
                text = _("Embed images"),
                checked_func = function() return self.download_images end,
                callback = function() self.download_images = not self.download_images end,
                separator = true,
            },
            {
                text = _("When an article is finished"),
                sub_item_table = {
                    {
                        text = _("Archive it in Karakeep"),
                        help_text = _("Applies when you mark an article as finished."),
                        checked_func = function() return self.archive_finished end,
                        callback = function() self.archive_finished = not self.archive_finished end,
                    },
                    {
                        text = _("Archive when 100% read"),
                        checked_func = function() return self.archive_read end,
                        callback = function() self.archive_read = not self.archive_read end,
                    },
                    {
                        text = _("Archive when marked as abandoned"),
                        checked_func = function() return self.archive_abandoned end,
                        callback = function() self.archive_abandoned = not self.archive_abandoned end,
                        separator = true,
                    },
                    {
                        text_func = function()
                            if self.archive_tag == "" then
                                return _("Also add a tag: off")
                            end
                            return T(_("Also add a tag: %1"), self.archive_tag)
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance) self:setArchiveTag(touchmenu_instance) end,
                    },
                    {
                        text = _("Delete the local copy once archived"),
                        help_text = _("Turn this off to keep finished articles on the device."),
                        checked_func = function() return self.delete_local_after_archive end,
                        callback = function()
                            self.delete_local_after_archive = not self.delete_local_after_archive
                        end,
                    },
                },
            },
            {
                text = _("Send highlights to Karakeep"),
                help_text = _([[
Highlights are matched to the article by their text, because KOReader and Karakeep describe positions in incompatible ways. A passage that appears more than once matches its first occurrence, and one that cannot be found is still sent, but without a position.]]),
                checked_func = function() return self.sync_highlights end,
                callback = function() self.sync_highlights = not self.sync_highlights end,
            },
        },
    }
end

function KaraKo:describeScope()
    if self.sync_scope == "list" then
        return T(_("list '%1'"), self.scope_name or self.scope_id or "?")
    elseif self.sync_scope == "tag" then
        return T(_("tag '%1'"), self.scope_name or self.scope_id or "?")
    end
    return _("all unread")
end

function KaraKo:scopeMenu()
    return {
        {
            text = _("All unarchived bookmarks"),
            checked_func = function() return self.sync_scope == "all" end,
            callback = function()
                self.sync_scope = "all"
                self.scope_id = nil
                self.scope_name = nil
            end,
        },
        {
            text = _("A single list…"),
            keep_menu_open = true,
            checked_func = function() return self.sync_scope == "list" end,
            callback = function(touchmenu_instance) self:chooseScope("list", touchmenu_instance) end,
        },
        {
            text = _("A single tag…"),
            keep_menu_open = true,
            checked_func = function() return self.sync_scope == "tag" end,
            callback = function(touchmenu_instance) self:chooseScope("tag", touchmenu_instance) end,
        },
    }
end

--- Fetch the available lists or tags from the server and let the user pick one.
function KaraKo:chooseScope(kind, touchmenu_instance)
    if self.server_url == "" or self.api_token == "" then
        UIManager:show(InfoMessage:new{ text = _("Configure the server first.") })
        return
    end

    NetworkMgr:runWhenOnline(function()
        local api = self:getApi()
        local ok, items
        if kind == "list" then
            ok, items = api:getLists()
        else
            ok, items = api:getTags()
        end

        if not ok then
            UIManager:show(InfoMessage:new{ text = _("Could not fetch the list from Karakeep.") })
            return
        end

        if #items == 0 then
            UIManager:show(InfoMessage:new{
                text = kind == "list" and _("This Karakeep account has no lists.")
                    or _("This Karakeep account has no tags."),
            })
            return
        end

        local Menu = require("ui/widget/menu")
        local Screen = require("device").screen
        local entries = {}
        local chooser

        for _, item in ipairs(items) do
            table.insert(entries, {
                text = item.name or item.id,
                callback = function()
                    self.sync_scope = kind
                    self.scope_id = item.id
                    self.scope_name = item.name
                    UIManager:close(chooser)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end

        table.sort(entries, function(a, b) return a.text < b.text end)

        chooser = Menu:new{
            title = kind == "list" and _("Choose a list") or _("Choose a tag"),
            item_table = entries,
            width = Screen:getWidth(),
            height = Screen:getHeight(),
            close_callback = function() UIManager:close(chooser) end,
        }
        UIManager:show(chooser)
    end)
end

--- Menu for the optional config file.
function KaraKo:configFileMenu()
    return {
        {
            text = _("Where KaraKo looks"),
            keep_menu_open = true,
            callback = function()
                local lines = { _("Checked in order, first one found wins:"), "" }
                for _, path in ipairs(self:configPaths()) do
                    local marker = (path == self.config_path) and "\u{2713} " or "\u{00B7} "
                    table.insert(lines, marker .. path)
                end
                UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
            end,
        },
        {
            text = _("Create an example file"),
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:writeConfigTemplate(touchmenu_instance) end,
        },
        {
            text = _("Reload it now"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local path, problems = self:applyConfigFile()

                local text
                if not path then
                    text = _("No settings file found.")
                else
                    text = T(_("Loaded settings from:\n%1"), path)
                    if #problems > 0 then
                        text = text .. "\n\n" .. table.concat(problems, "\n")
                    end
                end

                UIManager:show(InfoMessage:new{ text = text })
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
    }
end

--- Write a commented example config file for the user to fill in.
function KaraKo:writeConfigTemplate(touchmenu_instance)
    local path = DataStorage:getDataDir() .. "/karako.conf"

    if lfs.attributes(path, "mode") == "file" then
        UIManager:show(InfoMessage:new{
            text = T(_("A settings file already exists at:\n%1\n\nIt was left untouched."), path),
        })
        return
    end

    local handle = io.open(path, "w")
    if not handle then
        UIManager:show(InfoMessage:new{ text = T(_("Could not write to:\n%1"), path) })
        return
    end

    handle:write(Config.template())
    handle:close()

    UIManager:show(InfoMessage:new{
        text = T(_("Wrote an example settings file to:\n%1\n\nEdit it on a computer, then use 'Reload it now'."), path),
    })
    if touchmenu_instance then touchmenu_instance:updateItems() end
end

function KaraKo:editServerSettings(touchmenu_instance)
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Karakeep server"),
        fields = {
            {
                text = self.server_url,
                input_type = "string",
                hint = _("Server address, e.g. https://karakeep.example.com"),
            },
            {
                text = self.api_token,
                input_type = "string",
                text_type = "password",
                hint = _("API key (KaraKo: Settings > API Keys)"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save and test"),
                    callback = function()
                        local fields = dialog:getFields()
                        self.server_url = ArticleUtil.normaliseServerUrl(fields[1])
                        self.api_token = util.trim(fields[2])
                        self:onFlushSettings()
                        UIManager:close(dialog)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                        self:testConnection()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KaraKo:testConnection()
    if self.server_url == "" or self.api_token == "" then
        UIManager:show(InfoMessage:new{ text = _("Both the server address and an API key are required.") })
        return
    end

    NetworkMgr:runWhenOnline(function()
        local ok, reason, user = self:getApi():verifyCredentials()

        if ok then
            UIManager:show(InfoMessage:new{
                text = T(_("Connected to Karakeep as %1."), (user and (user.name or user.email)) or "?"),
                timeout = 3,
            })
        elseif reason == "unauthorized" then
            UIManager:show(InfoMessage:new{ text = _("Karakeep rejected the API key.") })
        elseif reason == "not_karakeep" then
            UIManager:show(InfoMessage:new{
                text = _("No Karakeep API at that address. Enter the server's base address, without /api/v1."),
            })
        elseif reason == "unreachable" then
            UIManager:show(InfoMessage:new{ text = _("Could not reach the server.") })
        else
            UIManager:show(InfoMessage:new{ text = _("Could not connect to Karakeep.") })
        end
    end)
end

function KaraKo:setArticlesPerSync(touchmenu_instance)
    UIManager:show(SpinWidget:new{
        title_text = _("Articles per sync"),
        info_text = _("The most recent unread articles are fetched, up to this many. Local copies are only tidied up when a sync sees everything, so a limit smaller than your unread count leaves them alone."),
        value = self.articles_per_sync,
        value_min = 1,
        value_max = 200,
        value_step = 1,
        value_hold_step = 10,
        callback = function(spin)
            self.articles_per_sync = spin.value
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })
end

function KaraKo:setArchiveTag(touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Tag to add when archiving"),
        description = _("Leave empty to add no tag."),
        input = self.archive_tag,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        self.archive_tag = util.trim(dialog:getInputText())
                        UIManager:close(dialog)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KaraKo:setDownloadDirectory(touchmenu_instance)
    require("ui/downloadmgr"):new{
        onConfirm = function(path)
            self.directory = path
            self:onFlushSettings()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    }:chooseDir()
end

--------------------------------------------------------------------------------
-- Local article bookkeeping
--------------------------------------------------------------------------------

--- Map bookmark ID to local path for every downloaded article.
-- @tparam[opt] string dir
-- @tparam[opt] table map
-- @treturn table
function KaraKo:getLocalArticles(dir, map)
    dir = dir or self.directory
    map = map or {}

    if not dir or lfs.attributes(dir, "mode") ~= "directory" then
        return map
    end

    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local entry_path = ffiUtil.joinPath(dir, entry)
            local mode = lfs.attributes(entry_path, "mode")

            if mode == "file" then
                local id = ArticleUtil.getBookmarkId(entry)
                if id then map[id] = entry_path end
            elseif mode == "directory" and not entry:match("%.sdr$") then
                self:getLocalArticles(entry_path, map)
            end
        end
    end

    return map
end

--- Decide whether a local article counts as done with.
-- @tparam string path
-- @treturn bool
function KaraKo:isFinished(path)
    if not DocSettings:hasSidecarFile(path) then
        return false -- never opened
    end

    local doc_settings = DocSettings:open(path)
    local summary = doc_settings:readSetting("summary")
    local status = summary and summary.status

    if status == "complete" then
        return self.archive_finished
    elseif status == "abandoned" then
        return self.archive_abandoned
    elseif doc_settings:readSetting("percent_finished") == 1 then
        return self.archive_read
    end

    return false
end

function KaraKo:deleteLocalArticle(path)
    if lfs.attributes(path, "mode") == "file" then
        -- deleteFile() takes care of the sidecar and the history entry too.
        FileManager:deleteFile(path, true)
    end
end

function KaraKo:refreshFileManager()
    if FileManager.instance then
        FileManager.instance:onRefresh()
    end
end

--------------------------------------------------------------------------------
-- Sync
--------------------------------------------------------------------------------

function KaraKo:onSynchronizeKarako()
    if not self:isReady() then
        UIManager:show(InfoMessage:new{
            text = _("Set the server address, API key and download folder first."),
        })
        return
    end

    NetworkMgr:runWhenOnline(function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function() self:synchronize() end)
    end)
    return true
end

function KaraKo:synchronize()
    local Trapper = require("ui/trapper")
    local api = self:getApi()

    local local_articles = self:getLocalArticles()

    -- Upload first: an article archived now drops out of the list we are about
    -- to fetch, so we never re-download something we have just finished.
    local archived, upload_failed = self:uploadStatuses(local_articles, true)

    Trapper:info(_("Fetching your Karakeep articles…"))

    logger.info(string.format("KaraKo: syncing scope=%s%s limit=%d from %s",
        self.sync_scope,
        self.scope_id and (":" .. self.scope_id) or "",
        self.articles_per_sync,
        self.server_url))

    local remote, err, complete = self:fetchBookmarks(api)
    if not remote then
        logger.err("KaraKo: fetch failed:", tostring(err))
        Trapper:reset()
        UIManager:show(InfoMessage:new{
            text = err == "network_error" and _("Could not reach the Karakeep server.")
                or _("Could not fetch articles from Karakeep."),
        })
        return
    end

    -- Record what the server holds before downloading anything, so that
    -- cancelling half way through does not make the rest look deleted.
    local remote_ids = {}
    for _, bookmark in ipairs(remote) do
        remote_ids[bookmark.id] = true
    end

    local downloaded, failed, skipped = 0, 0, 0
    local cancelled = false

    for index, bookmark in ipairs(remote) do
        if local_articles[bookmark.id] then
            skipped = skipped + 1
        else
            local content = bookmark.content or {}
            local title = ArticleUtil.displayText(
                bookmark.title or content.title or content.url, _("Untitled"))

            logger.dbg("KaraKo: downloading", bookmark.id, title)

            local go_on = Trapper:info(T(_("Downloading %1 of %2:\n\n%3"), index, #remote, title))
            if not go_on then
                cancelled = true
                break
            end

            if self:downloadArticle(api, bookmark) then
                downloaded = downloaded + 1
            else
                failed = failed + 1
            end
        end
    end

    -- Deleting local files is only safe when we have seen the whole scope. A
    -- capped or cancelled sync cannot tell "archived elsewhere" apart from
    -- "did not fit in this run".
    local removed = 0
    if complete and not cancelled then
        removed = self:processRemoteDeletes(local_articles, remote_ids)
    end

    logger.info(string.format(
        "KaraKo: sync done - %d fetched, %d downloaded, %d skipped, %d failed, %d removed (complete=%s cancelled=%s)",
        #remote, downloaded, skipped, failed, removed, tostring(complete), tostring(cancelled)))

    Trapper:reset()
    self:refreshFileManager()

    local lines = {
        T(N_("Downloaded %1 article.", "Downloaded %1 articles.", downloaded), downloaded),
    }
    if skipped > 0 then
        table.insert(lines, T(N_("%1 already on the device.", "%1 already on the device.", skipped), skipped))
    end
    if archived > 0 then
        table.insert(lines, T(N_("Archived %1 article in Karakeep.", "Archived %1 articles in Karakeep.", archived), archived))
    end
    if removed > 0 then
        table.insert(lines, T(N_("Removed %1 local article.", "Removed %1 local articles.", removed), removed))
    end
    if failed > 0 then
        table.insert(lines, T(N_("%1 article could not be downloaded.", "%1 articles could not be downloaded.", failed), failed))
    end
    if upload_failed > 0 then
        table.insert(lines, T(N_("%1 finished article could not be archived, and will be retried next sync.",
            "%1 finished articles could not be archived, and will be retried next sync.", upload_failed), upload_failed))
    end

    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

--- Fetch bookmarks for the configured scope, following pagination.
-- @treturn table|nil Array of bookmarks.
-- @treturn string|nil Error code.
-- @treturn bool Whether the whole scope was seen, rather than cut off by the
--   per-sync cap. Callers must not delete local files unless this is true.
function KaraKo:fetchBookmarks(api)
    local bookmarks = {}
    local cursor = nil

    repeat
        local ok, result = api:getBookmarkPage{
            scope = self.sync_scope,
            scope_id = self.scope_id,
            limit = math.min(self.articles_per_sync, 100),
            cursor = cursor,
        }

        if not ok then
            return nil, result, false
        end

        for _, bookmark in ipairs(result.bookmarks or {}) do
            -- The list and tag endpoints cannot filter server-side, so archived
            -- bookmarks are dropped here.
            if not bookmark.archived and self:isReadable(bookmark) then
                table.insert(bookmarks, bookmark)
                if #bookmarks >= self.articles_per_sync then
                    return bookmarks, nil, false
                end
            end
        end

        cursor = result.nextCursor
    until not cursor

    return bookmarks, nil, true
end

--- Is there anything worth putting on the device?
-- Asset bookmarks (uploaded PDFs and images) and empty notes are skipped.
function KaraKo:isReadable(bookmark)
    local content = bookmark.content
    if not content then return false end
    return content.type == "link" or content.type == "text"
end

function KaraKo:downloadArticle(api, bookmark)
    local Trapper = require("ui/trapper")
    local content = bookmark.content or {}
    local title = bookmark.title or content.title or content.url

    local body_html = content.htmlContent

    -- text bookmarks carry their body directly; links may not have been crawled
    -- yet, in which case the readable-content endpoint is the fallback.
    if content.type == "text" then
        body_html = EpubBuilder.markdownToHtml(content.text or "")
    elseif not body_html or body_html == "" then
        local ok, markdown = api:getReadableContent(bookmark.id, "markdown")
        if ok and markdown and markdown ~= "" then
            body_html = EpubBuilder.markdownToHtml(markdown)
        end
    end

    if not body_html or body_html == "" then
        logger.info("KaraKo: no readable content for", bookmark.id, content.url)
        return false
    end

    local filename = ArticleUtil.buildFilename(bookmark.id, title)
    local filepath = ffiUtil.joinPath(self.directory, filename)

    local ok, err = EpubBuilder.build(bookmark, filepath, {
        body_html = body_html,
        include_images = self.download_images,
        max_images = self.max_images,
        progress = function(message)
            Trapper:info(message, true, true)
        end,
    })

    if not ok then
        logger.warn("KaraKo: could not build EPUB for", bookmark.id, err)
        return false
    end

    return true
end

--- Archive finished articles in Karakeep and push their highlights.
--
-- There is no upload queue, and deliberately so: "finished" and "highlighted"
-- already live durably in KOReader's .sdr sidecar, which this reconciles
-- against the server on every run. An upload that fails because the network
-- dropped is simply retried next time, with no separate queue state that could
-- drift from what is actually on disk. The one thing that needs saying out loud
-- is when uploads did fail, so the counts below are reported rather than only
-- logged.
--
-- @tparam table local_articles
-- @tparam[opt=true] bool quiet
-- @treturn number Articles archived.
-- @treturn number Articles that should have been archived but could not be.
function KaraKo:uploadStatuses(local_articles, quiet)
    if quiet == nil then quiet = true end

    local api = self:getApi()
    if not api:isConfigured() then return 0, 0 end

    -- Trapper:info() is a no-op outside a wrapped coroutine, so this is safe
    -- whether we were called from a sync or straight from the menu.
    local Trapper = require("ui/trapper")
    local archived, highlights_sent, unresolved_total, failed = 0, 0, 0, 0
    local examined, total = 0, 0
    for _ in pairs(local_articles) do total = total + 1 end

    for id, path in pairs(local_articles) do
        examined = examined + 1
        Trapper:info(T(_("Sending read status and highlights (%1 of %2)…"), examined, total), true, true)

        local finished = self:isFinished(path)

        -- Highlights are pushed for anything that has been opened, not just
        -- finished articles, so notes are not lost if you never mark it read.
        if self.sync_highlights and DocSettings:hasSidecarFile(path) then
            local created, unresolved = Highlights.push(api, id, path)
            highlights_sent = highlights_sent + created
            unresolved_total = unresolved_total + unresolved
        end

        if finished then
            local ok = api:updateBookmark(id, { archived = true })

            if ok then
                archived = archived + 1

                if self.archive_tag ~= "" then
                    api:attachTags(id, { self.archive_tag })
                end

                if self.delete_local_after_archive then
                    self:deleteLocalArticle(path)
                    local_articles[id] = nil
                end
            else
                -- Left on the device with its sidecar intact, so the next run
                -- picks it up again.
                failed = failed + 1
                logger.warn("KaraKo: could not archive", id, "- will retry next sync")
            end
        end
    end

    if not quiet then
        Trapper:reset() -- clear the progress widget before the summary
        local lines = {
            T(N_("Archived %1 article.", "Archived %1 articles.", archived), archived),
        }
        if highlights_sent > 0 then
            table.insert(lines, T(N_("Sent %1 highlight.", "Sent %1 highlights.", highlights_sent), highlights_sent))
        end
        if unresolved_total > 0 then
            table.insert(lines, T(N_("%1 highlight could not be positioned in the article.",
                "%1 highlights could not be positioned in the article.", unresolved_total), unresolved_total))
        end
        if failed > 0 then
            table.insert(lines, T(N_("%1 article could not be sent, and will be retried next sync.",
                "%1 articles could not be sent, and will be retried next sync.", failed), failed))
        end
        UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
        self:refreshFileManager()
    end

    return archived, failed
end

--- Remove local articles that are no longer in the remote result.
--
-- Only runs when the sync was not capped, because a capped sync cannot tell
-- "archived elsewhere" apart from "did not fit in this page".
-- @treturn number
function KaraKo:processRemoteDeletes(local_articles, remote_ids)
    local count = 0
    for id, path in pairs(local_articles) do
        if not remote_ids[id] and not self:isFinished(path) then
            -- Untouched locally and gone remotely: archived or deleted in
            -- Karakeep from another device.
            if not DocSettings:hasSidecarFile(path) then
                self:deleteLocalArticle(path)
                count = count + 1
            end
        end
    end
    return count
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function KaraKo:onGoToKarakoDirectory()
    if not self.directory then
        UIManager:show(InfoMessage:new{ text = _("No download folder is configured yet.") })
        return true
    end

    if self.ui.document then
        self.ui:onClose()
    end

    if FileManager.instance then
        FileManager.instance:reinit(self.directory)
    else
        FileManager:showFiles(self.directory)
    end

    return true
end

return KaraKo
