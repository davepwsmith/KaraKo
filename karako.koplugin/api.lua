--[[--
Minimal Karakeep REST client.

Covers only what the plugin needs: listing bookmarks for a sync scope, fetching
readable content and assets, and pushing read status, tags and highlights back.

See https://docs.karakeep.app/api/karakeep-api/ for the full API.

@module koplugin.karako.api
]]

local JSON = require("json")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local ArticleUtil = require("articleutil")

local KarakeepApi = {}
KarakeepApi.__index = KarakeepApi

-- Karakeep's own docs describe a 429 with a retry hint; a couple of quick
-- retries keeps a large first sync from falling over. The hint is honoured when
-- the server sends one -- see retryAfterSeconds() -- and 2^attempt is the
-- fallback.
local MAX_RETRIES = 2

--- Create a client.
-- @tparam table opts server_url, api_token, and optional timeouts.
-- @treturn table
function KarakeepApi:new(opts)
    local instance = {
        server_url = ArticleUtil.normaliseServerUrl(opts.server_url),
        api_token = opts.api_token,
        block_timeout = opts.block_timeout or 20,
        total_timeout = opts.total_timeout or 60,
        file_block_timeout = opts.file_block_timeout or 30,
        file_total_timeout = opts.file_total_timeout or 300,
    }
    return setmetatable(instance, self)
end

function KarakeepApi:isConfigured()
    return self.server_url ~= nil and self.server_url ~= ""
        and self.api_token ~= nil and self.api_token ~= ""
end

--- Perform a request against the Karakeep API.
--
-- @tparam string method GET, POST, PATCH, …
-- @tparam string path Path below /api/v1, e.g. "/bookmarks".
-- @tparam[opt] table opts
--   query    table appended as a query string
--   body     table encoded as JSON
--   filepath write the response body to this path instead of decoding it
--   quiet    do not log failures at error level
-- @treturn bool ok
-- @treturn table|string Decoded JSON, the filepath, or an error code.
-- @treturn number|nil HTTP status when the request completed but failed.
--
-- Retries are attempted for the failures where repeating the request can
-- plausibly help *and* is safe to do; see the comment in the loop below.
function KarakeepApi:call(method, path, opts)
    opts = opts or {}

    if not self:isConfigured() then
        return false, "not_configured"
    end

    local url = self.server_url .. "/api/v1" .. path .. ArticleUtil.buildQuery(opts.query)
    local body_json = opts.body and JSON.encode(opts.body) or nil

    local ok, result, code, retry_after
    for attempt = 0, MAX_RETRIES do
        ok, result, code, retry_after =
            self:_request(method, url, body_json, opts.filepath, opts.quiet)

        -- A 429 is refused before the server acts on it, so repeating it is
        -- safe whatever the method. A 5xx or a dropped connection is not: the
        -- request may well have been processed and only the answer lost, and
        -- Karakeep has no idempotency key, so repeating POST /highlights would
        -- quietly create a second copy of the highlight. Those are retried for
        -- reads only.
        local safe_to_repeat = method == "GET" or method == "HEAD"
        local retriable = code == 429
            or (safe_to_repeat and (result == "network_error" or (code and code >= 500)))

        if ok or not retriable or attempt == MAX_RETRIES then
            break
        end

        -- This sleep blocks the UI thread, which is why the fallback backoff is
        -- short and the server's own hint is clamped in retryAfterSeconds().
        local delay = retry_after or 2 ^ attempt
        logger.dbg("KaraKoApi: retrying", method, path, "in", delay, "s after", result, code)
        socket.sleep(delay)
    end

    return ok, result, code
end

--- Seconds to wait, from a 429's Retry-After header.
--
-- Clamped: the value is server-controlled and the wait blocks the UI, so a
-- header asking for an hour must not freeze the device for one.
-- @treturn number|nil
local function retryAfterSeconds(resp_headers)
    -- luasocket lower-cases header names.
    local seconds = tonumber(resp_headers and resp_headers["retry-after"])
    if not seconds or seconds < 0 then return nil end
    return math.min(seconds, 30)
end

function KarakeepApi:_request(method, url, body_json, filepath, quiet)
    local sink = {}
    local headers = {
        ["Authorization"] = "Bearer " .. self.api_token,
        ["Accept"] = "application/json, */*",
    }

    local request = {
        method = method,
        url = url,
        headers = headers,
    }

    if body_json then
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body_json)
        request.source = ltn12.source.string(body_json)
    end

    local sink_file
    if filepath then
        sink_file = io.open(filepath, "w")
        if not sink_file then
            logger.err("KaraKoApi: cannot open", filepath, "for writing")
            return false, "io_error"
        end
        request.sink = ltn12.sink.file(sink_file)
        socketutil:set_timeout(self.file_block_timeout, self.file_total_timeout)
    else
        request.sink = ltn12.sink.table(sink)
        socketutil:set_timeout(self.block_timeout, self.total_timeout)
    end

    logger.dbg("KaraKoApi:", method, url)

    local code, resp_headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if resp_headers == nil then
        -- ltn12.sink.file closes the handle itself, so only clean up the file.
        if filepath then os.remove(filepath) end
        logger.err("KaraKoApi: network error", status or code, url)
        return false, "network_error"
    end

    if code == 200 or code == 201 then
        if filepath then
            return true, filepath
        end

        local content = table.concat(sink)
        if content == "" then
            return true, {}
        end

        local decoded_ok, decoded = pcall(JSON.decode, content)
        if decoded_ok and decoded then
            -- Every response goes through this: KOReader decodes JSON null to a
            -- truthy sentinel, which would otherwise defeat every `or` fallback
            -- in the plugin. See ArticleUtil.stripJsonNulls.
            return true, ArticleUtil.stripJsonNulls(decoded)
        end

        logger.err("KaraKoApi: response was not valid JSON:", content:sub(1, 200))
        return false, "json_error", code
    end

    if filepath then os.remove(filepath) end

    if not quiet then
        logger.err("KaraKoApi: HTTP", code, status, url)
    end

    return false, "http_error", code, retryAfterSeconds(resp_headers)
end

-- Karakeep returns 401 for a bad token and 404 for a URL that is not the API at
-- all; distinguishing them makes the settings dialog far more useful.
--- Check that the server URL and token work.
-- @treturn bool ok
-- @treturn string|nil Machine-readable failure reason.
function KarakeepApi:verifyCredentials()
    local ok, result, code = self:call("GET", "/users/me", { quiet = true })
    if ok then
        return true, nil, result
    end
    if code == 401 or code == 403 then
        return false, "unauthorized"
    elseif code == 404 then
        return false, "not_karakeep"
    elseif result == "network_error" then
        return false, "unreachable"
    end
    return false, "unknown"
end

--- Fetch one page of bookmarks for the configured sync scope.
--
-- @tparam table opts
--   scope     "all", "list" or "tag"
--   scope_id  list or tag ID, when scope is not "all"
--   limit     page size
--   cursor    pagination cursor from a previous call
-- @treturn bool ok
-- @treturn table|string { bookmarks = {...}, nextCursor = ... } or an error code.
function KarakeepApi:getBookmarkPage(opts)
    local query = {
        limit = opts.limit,
        cursor = opts.cursor,
        includeContent = true,
        -- Newest first, matching Karakeep's own default. With a per-sync cap,
        -- ascending order would bury new articles under an old backlog.
        sortOrder = "desc",
    }

    local path
    if opts.scope == "list" then
        path = "/lists/" .. opts.scope_id .. "/bookmarks"
    elseif opts.scope == "tag" then
        path = "/tags/" .. opts.scope_id .. "/bookmarks"
    else
        path = "/bookmarks"
        -- Only the unfiltered endpoint can exclude archived bookmarks
        -- server-side; list and tag results are filtered by the caller.
        query.archived = false
    end

    return self:call("GET", path, { query = query })
end

--- Fetch a single bookmark.
function KarakeepApi:getBookmark(id)
    return self:call("GET", "/bookmarks/" .. id, {
        query = { includeContent = true },
    })
end

-- The content endpoint returns bounded chunks, capped at 50000 characters each.
-- Ten of those is far more than any article, and stops a pathological response
-- from looping forever.
local MAX_CONTENT_CHUNKS = 10

--- Fetch the full readable content of a bookmark that has no crawled HTML.
--
-- Follows the endpoint's continuation cursor so that long articles are not
-- silently truncated at the first chunk.
--
-- @tparam string id
-- @tparam[opt="markdown"] string format "markdown" or "text"
-- @treturn bool ok
-- @treturn string|nil The whole content, or an error code.
function KarakeepApi:getReadableContent(id, format)
    local chunks = {}
    local cursor = nil

    for _ = 1, MAX_CONTENT_CHUNKS do
        local ok, result = self:call("GET", "/bookmarks/" .. id .. "/content", {
            query = {
                format = cursor and nil or (format or "markdown"), -- the cursor carries the format
                maxChars = 50000,
                cursor = cursor,
            },
        })

        if not ok then
            -- Keep whatever we already have rather than losing the article.
            if #chunks > 0 then break end
            return false, result
        end

        table.insert(chunks, result.content or "")

        cursor = result.nextCursor
        if not cursor or not result.truncated then break end
    end

    return true, table.concat(chunks)
end

--- Download an asset to a local file.
--
-- Used for page archives, and to retry readable HTML that Karakeep stored out
-- of line and then failed to expand for us. A file rather than memory, so the
-- size can be checked before a possibly large archive is read in.
--
-- Article images are not fetched this way: epubbuilder.lua gets those from
-- their original URLs, which keeps the API token off third-party requests.
--
-- Requires the "Assets: Read" scope on the API key.
--
-- @tparam string asset_id
-- @tparam string filepath
-- @treturn bool ok
-- @treturn string|nil filepath, or an error code.
function KarakeepApi:downloadAsset(asset_id, filepath)
    return self:call("GET", "/assets/" .. asset_id, { filepath = filepath })
end

--- Update mutable bookmark fields, e.g. { archived = true }.
function KarakeepApi:updateBookmark(id, fields)
    return self:call("PATCH", "/bookmarks/" .. id, { body = fields })
end

--- Attach tags by name, creating them if they do not exist.
-- @tparam string id
-- @tparam table names Array of tag names.
function KarakeepApi:attachTags(id, names)
    local tags = {}
    for _, name in ipairs(names) do
        table.insert(tags, { tagName = name, attachedBy = "human" })
    end
    return self:call("POST", "/bookmarks/" .. id .. "/tags", { body = { tags = tags } })
end

--- Fetch the highlights Karakeep already holds for a bookmark, so we do not
--- create duplicates on every sync.
function KarakeepApi:getHighlights(id)
    return self:call("GET", "/bookmarks/" .. id .. "/highlights", { quiet = true })
end

--- Create a highlight.
-- @tparam table highlight bookmarkId, startOffset, endOffset, text, note, color.
function KarakeepApi:createHighlight(highlight)
    return self:call("POST", "/highlights", { body = highlight })
end

--- List all lists. Karakeep returns them in one response, unpaginated.
function KarakeepApi:getLists()
    local ok, result = self:call("GET", "/lists")
    if not ok then return false, result end
    return true, result.lists or {}
end

--- List tags, most-used first, capped at 200.
--
-- Not paginated: the only caller is the "choose a tag" picker, and a menu of
-- more than 200 entries would be unusable on a device anyway.
function KarakeepApi:getTags()
    local ok, result = self:call("GET", "/tags", { query = { limit = 200, sort = "usage" } })
    if not ok then return false, result end
    return true, result.tags or {}
end

return KarakeepApi
