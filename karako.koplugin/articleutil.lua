--[[--
Pure helpers for the Karakeep plugin.

This module deliberately has no KOReader dependencies so that it can be
exercised by the specs in `spec/` with a plain Lua 5.1 interpreter.

@module koplugin.karako.articleutil
]]

local ArticleUtil = {}

-- Downloaded articles carry the Karakeep bookmark ID in their filename, so that
-- it survives a round trip through the filesystem with nothing to keep in sync.
--
-- The marker goes at the *end*, as "<title> [kk-id_<bookmarkId>].epub". It used
-- to lead, the way wallabag.koplugin's "[w-id_123] " does, but a file browser
-- shows the start of a name and truncates the end, so a leading marker put an
-- opaque ID where the title should be and pushed every title out of sight. It
-- also made the folder sort by ID rather than by title.
--
-- Names written by earlier versions still lead with it. Since the marker is
-- looked for anywhere in the name, both forms read back the same and no
-- existing download is orphaned or fetched again.
ArticleUtil.ID_OPEN = "[kk-id_"
ArticleUtil.ID_CLOSE = "]"

--- Extract the Karakeep bookmark ID from a filename or path.
--
-- Reads both the current trailing marker and the leading one earlier versions
-- wrote. safeTitle() turns any bracket in a title into a round one, so a
-- "[kk-id_" in a name is always ours.
--
-- @tparam string path Filename or full path of a downloaded article.
-- @treturn string|nil The bookmark ID, or nil if this is not one of our files.
function ArticleUtil.getBookmarkId(path)
    if type(path) ~= "string" then return nil end

    local name = path:match("([^/]+)$") or path

    -- Plain finds throughout: the marker contains "[" and "]", which would
    -- otherwise need escaping as a pattern.
    local open_at = name:find(ArticleUtil.ID_OPEN, 1, true)
    if not open_at then return nil end

    local from = open_at + #ArticleUtil.ID_OPEN
    local close_at = name:find(ArticleUtil.ID_CLOSE, from, true)
    if not close_at then return nil end

    local id = name:sub(from, close_at - 1)
    if id == "" then return nil end

    -- Karakeep IDs are opaque, but they are always URL-safe, so anything with a
    -- path separator or a bracket in it is a false positive.
    if id:find("[/%[%]]") then return nil end

    return id
end

--- Whether a name uses the leading marker earlier versions wrote.
-- @tparam string path
-- @treturn bool
function ArticleUtil.hasLegacyName(path)
    if type(path) ~= "string" then return false end
    local name = path:match("([^/]+)$") or path
    return name:sub(1, #ArticleUtil.ID_OPEN) == ArticleUtil.ID_OPEN
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

--- Build the local filename for a bookmark: "<title> [kk-id_<id>].epub".
-- @tparam string id Karakeep bookmark ID.
-- @tparam string|nil title
-- @tparam[opt=".epub"] string ext
-- @treturn string
function ArticleUtil.buildFilename(id, title, ext)
    ext = ext or ".epub"
    local marker = " " .. ArticleUtil.ID_OPEN .. id .. ArticleUtil.ID_CLOSE

    -- Leave room for the marker and the extension within a 255 byte name.
    local budget = 255 - #marker - #ext

    return ArticleUtil.safeTitle(title, math.min(180, budget)) .. marker .. ext
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

-- Case-insensitive pattern for a tag or attribute name, e.g. "script" ->
-- "[sS][cC][rR][iI][pP][tT]". Non-letters are escaped first, so the hyphen in
-- an attribute like "data-src" stays a literal instead of becoming the lazy
-- repeat quantifier it would otherwise be.
local function anyCase(word)
    return (word:gsub("%W", "%%%0"):gsub("%a", function(c)
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

    -- <noscript> is where a lazy-loading site keeps the plain <img> that works
    -- without JavaScript, so throwing the element away throws away the picture.
    -- Its contents are unwrapped when there is an image among them, and dropped
    -- otherwise -- what is left in that case is a "please enable JavaScript"
    -- notice that helps nobody on an e-reader.
    local noscript = anyCase("noscript")
    html = html:gsub("<%s*" .. noscript .. "[^>]*>(.-)<%s*/%s*" .. noscript .. "%s*>",
        function(inner)
            if inner:find("<%s*[iI][mM][gG]") then return inner end
            return ""
        end)
    html = html:gsub("<%s*/?%s*" .. noscript .. "[^>]*>", "") -- orphans

    for _, tag in ipairs({ "script", "style", "iframe", "object", "embed",
                           "form", "input", "button", "svg", "canvas" }) do
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

--- The article text as Karakeep's own reader measures it.
--
-- Karakeep indexes highlights by offsets into its DOM text: the text nodes
-- concatenated, with nothing inserted where the tags were. htmlToText() puts a
-- space in place of every tag so that words do not run together for matching,
-- which is right for matching and wrong for offsets -- it inflates every
-- position by the number of tags before it, so a highlight sent to Karakeep
-- lands progressively further past where the reader marked it. Offsets must
-- therefore be resolved here, not there.
--
-- Whitespace is deliberately left as-is, because Karakeep counts it.
--
-- @tparam string|nil html
-- @treturn string
function ArticleUtil.htmlToRenderedText(html)
    if type(html) ~= "string" then return "" end

    local s = ArticleUtil.sanitizeHtml(html)
    s = s:gsub("<[^>]*>", "")
    return ArticleUtil.decodeEntities(s)
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

--- Count the UTF-16 code units a UTF-8 string occupies.
--
-- Karakeep is a JavaScript application, so the offsets its highlights API takes
-- index a JavaScript string: UTF-16 code units, not bytes. A single "é" is two
-- bytes but one code unit, an emoji four bytes but two, so byte offsets drift
-- as soon as an article contains anything outside ASCII -- which is to say
-- almost always, since a curly quote or an em-dash is enough.
--
-- @tparam string s
-- @treturn number
function ArticleUtil.utf16Length(s)
    if type(s) ~= "string" then return 0 end

    local units, i, len = 0, 1, #s

    while i <= len do
        local b = s:byte(i)
        if b < 0x80 then
            units, i = units + 1, i + 1
        elseif b < 0xC0 then
            -- A stray continuation byte: not valid UTF-8. Counting it as one
            -- keeps the result monotonic rather than silently losing ground.
            units, i = units + 1, i + 1
        elseif b < 0xE0 then
            units, i = units + 1, i + 2
        elseif b < 0xF0 then
            units, i = units + 1, i + 3
        else
            units, i = units + 2, i + 4 -- above the BMP: a surrogate pair
        end
    end

    return units
end

--- Move an index forward to the start of a UTF-8 character.
local function alignToCharStart(s, i)
    while i <= #s do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then break end -- not a continuation byte
        i = i + 1
    end
    return i
end

--- Locate a highlighted passage within an article's plain text.
--
-- KOReader records highlights as crengine XPointers, which mean nothing to
-- Karakeep, so the only thing the two sides share is the highlighted text
-- itself. This is therefore best-effort: a passage that appears more than once
-- resolves to its first occurrence, and one that cannot be found at all returns
-- nil so the caller can decide what to do.
--
-- Matching ignores whitespace entirely. The two sides disagree about it by
-- construction: KOReader hands us a passage with a space where a paragraph
-- ended, Karakeep's DOM text has nothing there at all. Comparing the two with
-- every space removed sidesteps that, and the map built alongside turns a
-- position in the squeezed copy back into one in the real text, so the offsets
-- still count the whitespace Karakeep counts.
--
-- @tparam string s
-- @treturn string The text with every ASCII space character removed.
-- @treturn table Byte position in that copy -> byte position in `s`.
local function squeeze(s)
    local out, map = {}, {}
    for i = 1, #s do
        local b = s:byte(i)
        -- ASCII whitespace only. UTF-8 continuation bytes are all >= 0x80, so
        -- a multi-byte character can never be mistaken for a space and torn.
        if b ~= 32 and not (b >= 9 and b <= 13) then
            out[#out + 1] = string.char(b)
            map[#out] = i
        end
    end
    return table.concat(out), map
end

-- @tparam string text Article text, as returned by htmlToRenderedText() -- the
--   stream Karakeep measures offsets in, NOT htmlToText()'s.
-- @tparam string needle The highlighted passage.
-- @treturn number|nil Zero-based start offset, in UTF-16 code units -- what
--   Karakeep indexes by. See utf16Length().
-- @treturn number|nil End offset, exclusive.
function ArticleUtil.findTextOffsets(text, needle)
    if type(text) ~= "string" or type(needle) ~= "string" then return nil end
    if needle == "" then return nil end

    local hay, map = squeeze(text)
    local pin = squeeze(needle)
    if pin == "" then return nil end

    local match_pos, match_len

    local start_pos = hay:find(pin, 1, true)
    if start_pos then
        match_pos, match_len = start_pos, #pin
    -- Length is judged on the passage as given, not the squeezed copy: the
    -- threshold is about having a distinctive middle to probe with, and
    -- removing the spaces would quietly raise the bar.
    elseif #needle > 40 then
        -- KOReader may have captured a partial word at either end, or the
        -- crawler and the renderer may disagree about punctuation. Retry on a
        -- distinctive middle slice before giving up. The slice is snapped to
        -- character boundaries: cutting mid-sequence would still match
        -- byte-wise, but the offsets it produced would point into the middle
        -- of a character.
        local from = alignToCharStart(pin, 11)
        local probe = ArticleUtil.trimPartialUtf8(pin:sub(from, #pin - 10))
        if probe ~= "" then
            local probe_pos = hay:find(probe, 1, true)
            if probe_pos then
                match_pos, match_len = probe_pos, #probe
            end
        end
    end

    if not match_pos then return nil end

    -- Back to the real text, where the whitespace Karakeep counts still exists.
    local first_byte = map[match_pos]
    local last_byte = map[match_pos + match_len - 1]

    local start_offset = ArticleUtil.utf16Length(text:sub(1, first_byte - 1))
    local length = ArticleUtil.utf16Length(text:sub(first_byte, last_byte))

    return start_offset, start_offset + length
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
-- Attributes a lazy-loading site puts the real image in, best first. The plain
-- `src` on such a page is a placeholder -- a 1x1 GIF, a blur, or a data: URI --
-- so it is consulted last.
local LAZY_ATTRS = {
    "data-src", "data-original", "data-lazy-src", "data-actualsrc",
    "data-hi-res-src", "data-full-src", "data-image-src",
}

--- Read one attribute out of a tag's attribute text.
-- @tparam string attrs
-- @tparam string name
-- @treturn string|nil
local function attribute(attrs, name)
    local pattern = (name:gsub("%W", "%%%0"):gsub("%a", function(c)
        return "[" .. c:lower() .. c:upper() .. "]"
    end))
    local value = attrs:match(pattern .. "%s*=%s*\"([^\"]*)\"")
        or attrs:match(pattern .. "%s*=%s*'([^']*)'")
    if not value then return nil end

    value = ArticleUtil.decodeEntities(value)
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then return nil end
    return value
end

-- Roughly the widest a 300 dpi e-reader can use. Anything larger is downscaled
-- for display anyway, so fetching it only costs time, memory and storage.
local USEFUL_IMAGE_WIDTH = 1600

--- Choose one URL from a srcset.
--
-- A srcset is "url 480w, url 1200w" or "url 1x, url 2x". The widest candidate
-- that is still sensible for an e-reader screen wins; failing that, the
-- narrowest available, since something is better than nothing.
--
-- @tparam string|nil srcset
-- @treturn string|nil
function ArticleUtil.pickFromSrcset(srcset)
    if type(srcset) ~= "string" or srcset == "" then return nil end

    local best, best_width
    local smallest, smallest_width

    for candidate in (srcset .. ","):gmatch("%s*(.-)%s*,") do
        if candidate ~= "" then
            local url = candidate:match("^(%S+)")
            local descriptor = candidate:match("%s(%d+)[wW]$")
                or candidate:match("%s(%d+)%.?%d*[xX]$")

            if url then
                -- A bare URL with no descriptor is treated as full width, since
                -- it is the only candidate the author offered.
                local width = tonumber(descriptor) or USEFUL_IMAGE_WIDTH
                -- "2x" style descriptors are multipliers, not widths.
                if candidate:match("[xX]$") then width = width * 800 end

                if width <= USEFUL_IMAGE_WIDTH and (not best_width or width > best_width) then
                    best, best_width = url, width
                end
                if not smallest_width or width < smallest_width then
                    smallest, smallest_width = url, width
                end
            end
        end
    end

    return best or smallest
end

--- Work out which URL an <img> really points at.
--
-- Karakeep's extraction keeps the page's original markup, so an article from a
-- lazy-loading site arrives with the real image in a data- attribute or a
-- srcset and a placeholder in `src`. Reading `src` alone is why such articles
-- came through with no pictures.
--
-- @tparam string attrs The attribute text of an <img> tag.
-- @treturn string|nil
function ArticleUtil.imageSourceFrom(attrs)
    if type(attrs) ~= "string" then return nil end

    for _, name in ipairs(LAZY_ATTRS) do
        local value = attribute(attrs, name)
        if value then return value end
    end

    local from_srcset = ArticleUtil.pickFromSrcset(
        attribute(attrs, "data-srcset") or attribute(attrs, "srcset"))
    if from_srcset then return from_srcset end

    local src = attribute(attrs, "src")
    if not src then return nil end

    -- A placeholder is worse than nothing: it would occupy the slot and stop
    -- anything better being used.
    if src:match("^%s*[dD][aA][tT][aA]:") then return nil end
    if src:lower():match("placeholder") or src:lower():match("blank%.") then return nil end

    return src
end

function ArticleUtil.collectImages(html, max_images)
    if type(html) ~= "string" then return "", {} end
    max_images = max_images or 30

    local images = {}
    local by_src = {}

    local rewritten = html:gsub("<%s*[iI][mM][gG]([^>]*)>", function(attrs)
        local src = ArticleUtil.imageSourceFrom(attrs)

        if not src or src == "" then return "" end

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

--- Where an article's text might come from, best first.
--
-- `htmlContent` is the normal source and covers articles of any length. Karakeep
-- inlines it in its database only below a size threshold (5 KB by default), but
-- a request with includeContent=true hydrates the field from the asset before
-- answering, so that split is invisible here. `contentAssetId` is a safety net
-- for the case where Karakeep's own read of that asset fails: it swallows the
-- error and returns null rather than failing the request.
--
-- The archives are a different kind of thing. `precrawledArchive` is what a
-- SingleFile upload produced and `fullPageArchive` is Karakeep's own snapshot;
-- both are whole pages, including navigation, sidebars, cookie banners and
-- inlined assets. Karakeep runs a precrawled archive through the same
-- readability extraction it uses for a live crawl, so its text has already
-- reached `htmlContent`/`contentAssetId` by the time we see the bookmark. They
-- are therefore a fallback for when extraction produced nothing, not a
-- preference -- unless the caller asks otherwise.
--
-- @tparam table bookmark
-- @tparam[opt=false] bool prefer_archive Put the archives first.
-- @treturn table Array of { kind, asset_id, full_page, label }.
function ArticleUtil.contentSources(bookmark, prefer_archive)
    local content = (type(bookmark) == "table" and bookmark.content) or {}
    if content.type ~= "link" then return {} end

    local readable, archives = {}, {}

    if type(content.htmlContent) == "string" and content.htmlContent ~= "" then
        table.insert(readable, { kind = "inline", label = "inline readable HTML" })
    end
    if type(content.contentAssetId) == "string" and content.contentAssetId ~= "" then
        table.insert(readable, {
            kind = "asset",
            asset_id = content.contentAssetId,
            label = "readable HTML asset",
        })
    end

    -- The user's own capture first: it is the one that can hold content behind
    -- a paywall they are entitled to read.
    if type(content.precrawledArchiveAssetId) == "string" and content.precrawledArchiveAssetId ~= "" then
        table.insert(archives, {
            kind = "asset",
            asset_id = content.precrawledArchiveAssetId,
            full_page = true,
            label = "precrawled archive",
        })
    end
    if type(content.fullPageArchiveAssetId) == "string" and content.fullPageArchiveAssetId ~= "" then
        table.insert(archives, {
            kind = "asset",
            asset_id = content.fullPageArchiveAssetId,
            full_page = true,
            label = "full page archive",
        })
    end

    local sources = {}
    local first = prefer_archive and archives or readable
    local second = prefer_archive and readable or archives

    for _, source in ipairs(first) do table.insert(sources, source) end
    for _, source in ipairs(second) do table.insert(sources, source) end

    -- Always last: it is served as markdown, so formatting and images are lost
    -- in the conversion back to HTML.
    table.insert(sources, { kind = "endpoint", label = "readable content endpoint" })

    return sources
end

--- Coerce a value to something safe to put in a UI string.
--
-- stripJsonNulls() should mean nothing odd ever reaches formatting, but a
-- surprise from the API should degrade to a readable label rather than throw
-- from inside string.gsub and abandon the whole sync.
--
-- @tparam any value
-- @tparam[opt="?"] string fallback Used when the value is not usable text.
-- @treturn string
function ArticleUtil.displayText(value, fallback)
    fallback = fallback or "?"

    if type(value) == "string" and value ~= "" then return value end
    if type(value) == "number" then return tostring(value) end

    return fallback
end

--- Replace JSON nulls with nil throughout a decoded response.
--
-- KOReader's JSON decoder represents null as a *function*, because a nil would
-- simply vanish from the table and the key would be indistinguishable from one
-- that was never sent. A function is truthy, so without this every
-- `bookmark.title or fallback` silently keeps the sentinel instead of falling
-- through, and it goes on to reach string formatting or a URL. Karakeep marks a
-- lot of fields nullable -- title, note, author, htmlContent, datePublished and
-- nextCursor among them -- so this is applied once to every decoded response.
--
-- A decoded JSON value can never legitimately be a function, so testing the type
-- is enough to identify the sentinel.
--
-- @tparam any value Decoded JSON.
-- @tparam[opt=0] number depth Recursion guard.
-- @treturn any The same value with nulls removed.
function ArticleUtil.stripJsonNulls(value, depth)
    if type(value) ~= "table" then
        if type(value) == "function" then return nil end
        return value
    end

    depth = (depth or 0) + 1
    if depth > 32 then return value end

    if value[1] ~= nil then
        -- Array-like: rebuild it, so that removing a null cannot leave a hole
        -- that would silently truncate a later ipairs().
        local out = {}
        for _, item in ipairs(value) do
            if type(item) ~= "function" then
                table.insert(out, ArticleUtil.stripJsonNulls(item, depth))
            end
        end
        return out
    end

    for key, item in pairs(value) do
        if type(item) == "function" then
            value[key] = nil
        elseif type(item) == "table" then
            value[key] = ArticleUtil.stripJsonNulls(item, depth)
        end
    end

    return value
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

--- Build a query string from a table, skipping anything that is not a scalar.
--
-- Keys are sorted so the output is stable and testable. Only strings, numbers
-- and booleans can be encoded; anything else is dropped rather than run through
-- tostring(), which would put a literal "table: 0x55f3…" on the wire and fail in
-- a thoroughly baffling way. Callers that care -- pagination, in particular --
-- must notice the value went missing; see KaraKo:fetchBookmarks().
--
-- @tparam table params
-- @treturn string Empty string, or "?a=1&b=2".
function ArticleUtil.buildQuery(params)
    if type(params) ~= "table" then return "" end

    local keys = {}
    for key, value in pairs(params) do
        local kind = type(value)
        if kind == "string" or kind == "number" or kind == "boolean" then
            table.insert(keys, key)
        end
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
