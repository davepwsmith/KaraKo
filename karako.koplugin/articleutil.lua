--[[--
Pure helpers for the Karakeep plugin.

This module deliberately has no KOReader dependencies so that it can be
exercised by the specs in `spec/` with a plain Lua 5.1 interpreter.

@module koplugin.karako.articleutil
]]

local ArticleUtil = {}

-- Downloaded articles are named "[kk-id_<bookmarkId>] <title>.epub" so that the
-- Karakeep bookmark ID survives a round trip through the filesystem. This mirrors
-- what wallabag.koplugin does with "[w-id_123] ".
ArticleUtil.ID_PREFIX = "[kk-id_"
ArticleUtil.ID_POSTFIX = "] "

--- Extract the Karakeep bookmark ID from a filename or path.
-- @tparam string path Filename or full path of a downloaded article.
-- @treturn string|nil The bookmark ID, or nil if this is not one of our files.
function ArticleUtil.getBookmarkId(path)
    if type(path) ~= "string" then return nil end

    local name = path:match("([^/]+)$") or path
    local prefix_len = #ArticleUtil.ID_PREFIX

    if name:sub(1, prefix_len) ~= ArticleUtil.ID_PREFIX then
        return nil
    end

    -- Plain find: the postfix contains "]", which is harmless in a pattern but
    -- we do not want to think about it.
    local endpos = name:find(ArticleUtil.ID_POSTFIX, prefix_len + 1, true)
    if not endpos then return nil end

    local id = name:sub(prefix_len + 1, endpos - 1)
    if id == "" then return nil end

    -- Karakeep IDs are opaque, but they are always URL-safe, so anything with a
    -- path separator or a bracket in it is a false positive.
    if id:find("[/%[%]]") then return nil end

    return id
end

--- Drop a trailing incomplete UTF-8 sequence left behind by a byte-wise truncation.
-- @tparam string s
-- @treturn string
function ArticleUtil.trimPartialUtf8(s)
    local i = #s
    -- A sequence is at most 4 bytes, so we never need to walk back further.
    local limit = math.max(1, #s - 3)

    while i >= limit do
        local b = s:byte(i)
        if b < 0x80 then
            return s -- plain ASCII, nothing dangling
        elseif b >= 0xC0 then
            local need
            if b >= 0xF0 then need = 4
            elseif b >= 0xE0 then need = 3
            else need = 2 end

            if #s - i + 1 >= need then
                return s -- the sequence starting here is complete
            end
            return s:sub(1, i - 1)
        end
        i = i - 1 -- continuation byte, keep walking back to the start byte
    end

    return s
end

--- Turn an article title into something safe to write to a Kobo's FAT32 partition.
-- @tparam string|nil title
-- @tparam[opt=180] number max_len Maximum length in bytes.
-- @treturn string Never empty.
function ArticleUtil.safeTitle(title, max_len)
    max_len = max_len or 180

    if type(title) ~= "string" or title == "" then
        return "Untitled"
    end

    title = title:gsub("[%z\1-\31\127]", " ")   -- control characters
    title = title:gsub('[/\\%?%*:|"<>]', "_")   -- illegal on FAT32/NTFS
    title = title:gsub("%[", "("):gsub("%]", ")") -- keep our ID prefix unambiguous
    title = title:gsub("%s+", " ")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")

    if #title > max_len then
        title = ArticleUtil.trimPartialUtf8(title:sub(1, max_len))
        title = title:gsub("%s+$", "")
    end

    -- FAT32 cannot represent a name ending in a dot or a space.
    title = title:gsub("[%.%s]+$", "")

    if title == "" then return "Untitled" end
    return title
end

--- Build the local filename for a bookmark.
-- @tparam string id Karakeep bookmark ID.
-- @tparam string|nil title
-- @tparam[opt=".epub"] string ext
-- @treturn string
function ArticleUtil.buildFilename(id, title, ext)
    ext = ext or ".epub"
    -- Leave room for the prefix, the ID and the extension within a 255 byte name.
    local budget = 255 - #ArticleUtil.ID_PREFIX - #id - #ArticleUtil.ID_POSTFIX - #ext
    return ArticleUtil.ID_PREFIX .. id .. ArticleUtil.ID_POSTFIX
        .. ArticleUtil.safeTitle(title, math.min(180, budget)) .. ext
end

--- Encode a Unicode code point as UTF-8. Lua 5.1 has no utf8 library.
-- @tparam number cp
-- @treturn string
function ArticleUtil.utf8Char(cp)
    if type(cp) ~= "number" or cp < 0 or cp > 0x10FFFF then return "" end

    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40),
                           0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
                           0x80 + (math.floor(cp / 0x40) % 0x40),
                           0x80 + (cp % 0x40))
    end

    return string.char(0xF0 + math.floor(cp / 0x40000),
                       0x80 + (math.floor(cp / 0x1000) % 0x40),
                       0x80 + (math.floor(cp / 0x40) % 0x40),
                       0x80 + (cp % 0x40))
end

local NAMED_ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
    nbsp = " ", ensp = " ", emsp = " ", thinsp = " ", shy = "",
    ndash = "\226\128\147", mdash = "\226\128\148",
    lsquo = "\226\128\152", rsquo = "\226\128\153",
    ldquo = "\226\128\156", rdquo = "\226\128\157",
    hellip = "\226\128\166", middot = "\194\183", bull = "\226\128\162",
    copy = "\194\169", reg = "\194\174", trade = "\226\132\162",
    laquo = "\194\171", raquo = "\194\187", deg = "\194\176",
}

--- Decode the HTML entities we are likely to meet in crawled article text.
-- Unknown named entities are left untouched.
-- @tparam string s
-- @treturn string
function ArticleUtil.decodeEntities(s)
    if type(s) ~= "string" then return "" end

    s = s:gsub("&#[xX](%x+);", function(hex)
        return ArticleUtil.utf8Char(tonumber(hex, 16))
    end)
    s = s:gsub("&#(%d+);", function(dec)
        return ArticleUtil.utf8Char(tonumber(dec))
    end)
    -- Returning nil from gsub leaves the match in place, which is what we want
    -- for entities we do not know about.
    s = s:gsub("&(%a+);", function(name)
        return NAMED_ENTITIES[name]
    end)

    return s
end

--- Escape a string for inclusion in XML/XHTML text or an attribute value.
-- @tparam string|nil s
-- @treturn string
function ArticleUtil.escapeXml(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    s = s:gsub('"', "&quot;")
    s = s:gsub("'", "&apos;")
    return s
end

-- Case-insensitive pattern for a tag name, e.g. "script" -> "[sS][cC][rR][iI][pP][tT]".
local function anyCase(word)
    return (word:gsub("%a", function(c)
        return "[" .. c:lower() .. c:upper() .. "]"
    end))
end

local function stripElement(html, tag)
    local name = anyCase(tag)
    -- Paired form, then any leftover self-closing or orphaned opening tag.
    html = html:gsub("<%s*" .. name .. "[^>]*>.-<%s*/%s*" .. name .. "%s*>", "")
    html = html:gsub("<%s*/?%s*" .. name .. "[^>]*>", "")
    return html
end

--- Remove elements and attributes that have no business in an offline EPUB.
-- crengine's getBalancedHTML() deals with well-formedness afterwards; this only
-- removes things that are actively unhelpful on an e-reader.
-- @tparam string|nil html
-- @treturn string
function ArticleUtil.sanitizeHtml(html)
    if type(html) ~= "string" then return "" end

    html = html:gsub("<!%-%-.-%-%->", "")
    html = html:gsub("<[%?!][^>]*>", "") -- doctypes and processing instructions

    for _, tag in ipairs({ "script", "style", "iframe", "object", "embed",
                           "noscript", "form", "input", "button", "svg", "canvas" }) do
        html = stripElement(html, tag)
    end

    -- Inline event handlers: onclick="…", onload='…'
    html = html:gsub("%s[oO][nN]%a+%s*=%s*\"[^\"]*\"", "")
    html = html:gsub("%s[oO][nN]%a+%s*=%s*'[^']*'", "")
    -- javascript: URLs
    html = html:gsub("([hH][rR][eE][fF]%s*=%s*)\"%s*[jJ][aA][vV][aA][sS][cC][rR][iI][pP][tT]:[^\"]*\"", "%1\"#\"")
    html = html:gsub("([hH][rR][eE][fF]%s*=%s*)'%s*[jJ][aA][vV][aA][sS][cC][rR][iI][pP][tT]:[^']*'", "%1'#'")

    return html
end

--- Flatten HTML to the plain text used for highlight offset matching.
-- @tparam string|nil html
-- @treturn string Whitespace-normalised, entity-decoded text.
function ArticleUtil.htmlToText(html)
    if type(html) ~= "string" then return "" end

    local s = ArticleUtil.sanitizeHtml(html)
    -- Block-level boundaries become spaces so words do not run together.
    s = s:gsub("<[^>]*>", " ")
    s = ArticleUtil.decodeEntities(s)
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")

    return s
end

--- Collapse runs of whitespace, so text captured on device can be compared with
-- text rendered on the server.
-- @tparam string|nil s
-- @treturn string
function ArticleUtil.normaliseWhitespace(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

--- Locate a highlighted passage within an article's plain text.
--
-- KOReader records highlights as crengine XPointers, which mean nothing to
-- Karakeep, so the only thing the two sides share is the highlighted text
-- itself. This is therefore best-effort: a passage that appears more than once
-- resolves to its first occurrence, and one that cannot be found at all returns
-- nil so the caller can decide what to do.
--
-- @tparam string text Article plain text, as returned by htmlToText().
-- @tparam string needle The highlighted passage.
-- @treturn number|nil Zero-based start offset, in bytes.
-- @treturn number|nil End offset, exclusive.
function ArticleUtil.findTextOffsets(text, needle)
    if type(text) ~= "string" or type(needle) ~= "string" then return nil end

    needle = ArticleUtil.normaliseWhitespace(needle)
    if needle == "" then return nil end

    local start_pos = text:find(needle, 1, true)

    if not start_pos then
        -- KOReader may have captured a partial word at either end, or the
        -- crawler and the renderer may disagree about punctuation. Retry on a
        -- distinctive middle slice before giving up.
        if #needle > 40 then
            local probe = needle:sub(11, #needle - 10)
            local probe_pos = text:find(probe, 1, true)
            if probe_pos then
                return probe_pos - 1, probe_pos - 1 + #probe
            end
        end
        return nil
    end

    return start_pos - 1, start_pos - 1 + #needle
end

--- Rewrite <img> sources to local EPUB paths, collecting what needs downloading.
--
-- Data URIs and images we cannot resolve are dropped rather than left pointing
-- at the network, so the EPUB never shows a broken-image box.
--
-- @tparam string|nil html
-- @tparam[opt=30] number max_images
-- @treturn string Rewritten HTML.
-- @treturn table Array of { src = <remote url>, path = "images/img1.jpg" }.
function ArticleUtil.collectImages(html, max_images)
    if type(html) ~= "string" then return "", {} end
    max_images = max_images or 30

    local images = {}
    local by_src = {}

    local rewritten = html:gsub("<%s*[iI][mM][gG]([^>]*)>", function(attrs)
        local src = attrs:match("[sS][rR][cC]%s*=%s*\"([^\"]*)\"")
            or attrs:match("[sS][rR][cC]%s*=%s*'([^']*)'")

        if not src or src == "" then return "" end

        src = ArticleUtil.decodeEntities(src)
        src = src:gsub("^%s+", ""):gsub("%s+$", "")

        -- Only absolute http(s) sources are usable: Karakeep gives us the
        -- article out of context, so a relative path has nothing to resolve
        -- against, and data: URIs are already inline.
        if not src:match("^[hH][tT][tT][pP][sS]?://") then return "" end

        local existing = by_src[src]
        if existing then
            return string.format('<img src="%s"/>', ArticleUtil.escapeXml(existing))
        end

        if #images >= max_images then return "" end

        local ext = ArticleUtil.imageExtension(src)
        local path = string.format("images/img%d%s", #images + 1, ext)

        table.insert(images, { src = src, path = path })
        by_src[src] = path

        -- No alt="": crengine's getBalancedHTML() rewrites an empty attribute
        -- to a bare one ("alt"), which is not well-formed XML.
        return string.format('<img src="%s"/>', ArticleUtil.escapeXml(path))
    end)

    return rewritten, images
end

local KNOWN_IMAGE_EXTS = {
    jpg = ".jpg", jpeg = ".jpg", png = ".png", gif = ".gif",
    webp = ".webp", svg = ".svg", bmp = ".bmp",
}

--- Guess a file extension for an image URL, defaulting to .jpg.
-- @tparam string src
-- @treturn string
function ArticleUtil.imageExtension(src)
    local path = src:match("^[^%?#]*") or src
    local ext = path:match("%.([%a%d]+)$")
    if ext then
        local known = KNOWN_IMAGE_EXTS[ext:lower()]
        if known then return known end
    end
    return ".jpg"
end

local MEDIA_TYPES = {
    [".jpg"] = "image/jpeg", [".png"] = "image/png", [".gif"] = "image/gif",
    [".webp"] = "image/webp", [".svg"] = "image/svg+xml", [".bmp"] = "image/bmp",
}

--- Map a local image path to its EPUB media type.
-- @tparam string path
-- @treturn string
function ArticleUtil.mediaType(path)
    local ext = path:match("(%.[%a%d]+)$")
    return (ext and MEDIA_TYPES[ext:lower()]) or "image/jpeg"
end

--- Sniff an image's media type from its magic bytes.
-- The extension in a URL is frequently a lie, and crengine will refuse an image
-- whose declared type does not match its content.
-- @tparam string data
-- @treturn string|nil Media type, or nil if unrecognised.
function ArticleUtil.sniffImageType(data)
    if type(data) ~= "string" or #data < 12 then return nil end

    if data:sub(1, 3) == "\255\216\255" then return "image/jpeg" end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "image/png" end
    if data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then return "image/gif" end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return "image/webp" end
    if data:sub(1, 2) == "BM" then return "image/bmp" end
    if data:match("^%s*<%?xml") or data:match("^%s*<svg") then return "image/svg+xml" end

    return nil
end

--- Percent-encode a string for use in a URL query value.
-- @tparam string s
-- @treturn string
function ArticleUtil.urlEncode(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("[^%w%-%_%.%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

--- Build a query string from a table, skipping nil values.
-- Keys are sorted so the output is stable and testable.
-- @tparam table params
-- @treturn string Empty string, or "?a=1&b=2".
function ArticleUtil.buildQuery(params)
    if type(params) ~= "table" then return "" end

    local keys = {}
    for key, value in pairs(params) do
        if value ~= nil then table.insert(keys, key) end
    end
    table.sort(keys)

    local parts = {}
    for _, key in ipairs(keys) do
        local value = params[key]
        if type(value) == "boolean" then value = value and "true" or "false" end
        table.insert(parts, ArticleUtil.urlEncode(key) .. "=" .. ArticleUtil.urlEncode(tostring(value)))
    end

    if #parts == 0 then return "" end
    return "?" .. table.concat(parts, "&")
end

--- Normalise a user-entered server URL: strip trailing slashes and a trailing
-- "/api/v1" that people paste in from the Karakeep docs.
-- @tparam string|nil url
-- @treturn string
function ArticleUtil.normaliseServerUrl(url)
    if type(url) ~= "string" then return "" end

    url = url:gsub("^%s+", ""):gsub("%s+$", "")
    url = url:gsub("/+$", "")
    url = url:gsub("/api/v1$", "")
    url = url:gsub("/+$", "")

    return url
end

return ArticleUtil
