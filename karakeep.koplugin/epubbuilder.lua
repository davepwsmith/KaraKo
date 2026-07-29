--[[--
Builds an EPUB from a Karakeep bookmark.

Karakeep has no EPUB export endpoint (unlike Wallabag), so the plugin assembles
one on device. The approach follows newsdownloader.koplugin: hand the crawled
HTML to crengine's getBalancedHTML() to make it well-formed, then write the
container with ffi/archiver's zip writer.

@module koplugin.karakeep.epubbuilder
]]

local logger = require("logger")
local socket = require("socket")
local socketutil = require("socketutil")
local http = require("socket.http")
local ltn12 = require("ltn12")

local ArticleUtil = require("articleutil")

local EpubBuilder = {}

local CSS = [[
body { margin: 0; padding: 0; font-family: serif; text-align: justify; }
h1 { font-size: 1.4em; text-align: left; margin: 0 0 0.2em 0; }
h2, h3, h4, h5, h6 { text-align: left; margin: 1em 0 0.3em 0; }
p { margin: 0 0 0.6em 0; text-indent: 0; }
img { max-width: 100%; height: auto; text-align: center; }
figure { margin: 0.8em 0; text-align: center; }
figcaption { font-size: 0.8em; font-style: italic; text-align: center; }
blockquote { margin: 0.6em 1.2em; font-style: italic; }
pre { font-family: monospace; font-size: 0.85em; white-space: pre-wrap; margin: 0.6em 0; }
code { font-family: monospace; font-size: 0.9em; }
hr { border: 0; border-top: 1px solid #999; margin: 1em 0; }
table { border-collapse: collapse; }
td, th { border: 1px solid #999; padding: 0.2em 0.4em; }
.kk-meta { font-size: 0.8em; margin: 0 0 1em 0; }
.kk-note { font-size: 0.9em; font-style: italic; margin: 0 0 1em 0; }
]]

-- Fetch a remote image. Kept separate from the Karakeep client because these
-- are third-party URLs that must not carry the API token.
local function fetchUrl(url, block_timeout, total_timeout)
    local sink = {}
    socketutil:set_timeout(block_timeout or 10, total_timeout or 30)

    local code, resp_headers = socket.skip(1, http.request{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(sink),
        headers = { ["User-Agent"] = "KOReader Karakeep plugin" },
    })

    socketutil:reset_timeout()

    if resp_headers == nil or code ~= 200 then
        return nil
    end

    return table.concat(sink)
end

--- Convert markdown to the small subset of HTML we need.
--
-- Only used when Karakeep has no crawled HTML for a bookmark, so this is a
-- fallback rather than a general-purpose converter: headings, lists, block
-- quotes, fenced code, images, links, bold and italic.
--
-- @tparam string md
-- @treturn string
function EpubBuilder.markdownToHtml(md)
    if type(md) ~= "string" then return "" end

    local out = {}
    local in_code, in_list = false, false

    local function closeList()
        if in_list then
            table.insert(out, "</ul>")
            in_list = false
        end
    end

    local function inline(text)
        text = ArticleUtil.escapeXml(text)
        -- Images before links: the syntaxes differ only by a leading "!".
        text = text:gsub("!%[([^%]]*)%]%((%S-)%)", function(alt, src)
            return string.format('<img src="%s" alt="%s"/>', src, alt)
        end)
        text = text:gsub("%[([^%]]*)%]%((%S-)%)", function(label, href)
            return string.format('<a href="%s">%s</a>', href, label)
        end)
        text = text:gsub("`([^`]+)`", "<code>%1</code>")
        text = text:gsub("%*%*([^%*]+)%*%*", "<strong>%1</strong>")
        text = text:gsub("%_%_([^%_]+)%_%_", "<strong>%1</strong>")
        text = text:gsub("%*([^%*]+)%*", "<em>%1</em>")
        return text
    end

    for line in (md .. "\n"):gmatch("(.-)\n") do
        if line:match("^%s*```") then
            closeList()
            table.insert(out, in_code and "</pre>" or "<pre>")
            in_code = not in_code
        elseif in_code then
            table.insert(out, ArticleUtil.escapeXml(line))
        else
            local hashes, heading = line:match("^(#+)%s+(.*)$")
            local bullet = line:match("^%s*[%*%-%+]%s+(.*)$")
            local quote = line:match("^%s*>%s?(.*)$")

            if heading then
                closeList()
                local level = math.min(#hashes, 6)
                table.insert(out, string.format("<h%d>%s</h%d>", level, inline(heading), level))
            elseif bullet then
                if not in_list then
                    table.insert(out, "<ul>")
                    in_list = true
                end
                table.insert(out, "<li>" .. inline(bullet) .. "</li>")
            elseif quote then
                closeList()
                table.insert(out, "<blockquote>" .. inline(quote) .. "</blockquote>")
            elseif line:match("^%s*%-%-%-+%s*$") then
                closeList()
                table.insert(out, "<hr/>")
            elseif line:match("^%s*$") then
                closeList()
            else
                closeList()
                table.insert(out, "<p>" .. inline(line) .. "</p>")
            end
        end
    end

    closeList()
    if in_code then table.insert(out, "</pre>") end

    return table.concat(out, "\n")
end

--- Assemble the article body, before image rewriting.
-- @tparam table bookmark A Karakeep bookmark.
-- @tparam string|nil body_html Article HTML, or nil to use a placeholder.
-- @treturn string
function EpubBuilder.buildDocument(bookmark, body_html)
    local content = bookmark.content or {}
    local title = bookmark.title or content.title or content.url or "Untitled"

    local meta = {}
    if content.author and content.author ~= "" then
        table.insert(meta, ArticleUtil.escapeXml(content.author))
    end
    if content.publisher and content.publisher ~= "" then
        table.insert(meta, ArticleUtil.escapeXml(content.publisher))
    end
    if content.datePublished and content.datePublished ~= "" then
        table.insert(meta, ArticleUtil.escapeXml(content.datePublished:sub(1, 10)))
    end

    local parts = {
        "<h1>" .. ArticleUtil.escapeXml(title) .. "</h1>",
    }

    if #meta > 0 then
        table.insert(parts, '<p class="kk-meta">' .. table.concat(meta, " &#183; ") .. "</p>")
    end

    if content.url and content.url ~= "" then
        table.insert(parts, string.format('<p class="kk-meta"><a href="%s">%s</a></p>',
            ArticleUtil.escapeXml(content.url), ArticleUtil.escapeXml(content.url)))
    end

    -- The user's own note from Karakeep travels with the article.
    if bookmark.note and bookmark.note ~= "" then
        table.insert(parts, '<p class="kk-note">' .. ArticleUtil.escapeXml(bookmark.note) .. "</p>")
    end

    table.insert(parts, "<hr/>")
    table.insert(parts, body_html or "<p><em>No readable content was available for this bookmark.</em></p>")

    return table.concat(parts, "\n")
end

local function opf(bookmark, title, images)
    local content = bookmark.content or {}
    local parts = {
        [[<?xml version="1.0" encoding="UTF-8"?>]],
        [[<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="2.0">]],
        [[<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">]],
        "<dc:title>" .. ArticleUtil.escapeXml(title) .. "</dc:title>",
        "<dc:identifier id=\"bookid\">urn:karakeep:" .. ArticleUtil.escapeXml(bookmark.id) .. "</dc:identifier>",
        "<dc:language>en</dc:language>",
    }

    if content.author and content.author ~= "" then
        table.insert(parts, "<dc:creator>" .. ArticleUtil.escapeXml(content.author) .. "</dc:creator>")
    end
    if content.publisher and content.publisher ~= "" then
        table.insert(parts, "<dc:publisher>" .. ArticleUtil.escapeXml(content.publisher) .. "</dc:publisher>")
    end
    if content.url and content.url ~= "" then
        table.insert(parts, "<dc:source>" .. ArticleUtil.escapeXml(content.url) .. "</dc:source>")
    end
    if content.datePublished and content.datePublished ~= "" then
        table.insert(parts, "<dc:date>" .. ArticleUtil.escapeXml(content.datePublished) .. "</dc:date>")
    end
    for _, tag in ipairs(bookmark.tags or {}) do
        if tag.name then
            table.insert(parts, "<dc:subject>" .. ArticleUtil.escapeXml(tag.name) .. "</dc:subject>")
        end
    end

    table.insert(parts, "</metadata>")
    table.insert(parts, "<manifest>")
    table.insert(parts, [[<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>]])
    table.insert(parts, [[<item id="content" href="content.xhtml" media-type="application/xhtml+xml"/>]])
    table.insert(parts, [[<item id="css" href="stylesheet.css" media-type="text/css"/>]])

    for index, image in ipairs(images) do
        table.insert(parts, string.format('<item id="img%d" href="%s" media-type="%s"/>',
            index, ArticleUtil.escapeXml(image.path), image.media_type))
    end

    table.insert(parts, "</manifest>")
    table.insert(parts, [[<spine toc="ncx"><itemref idref="content"/></spine>]])
    table.insert(parts, "</package>")

    return table.concat(parts, "\n")
end

local function ncx(bookmark, title)
    return table.concat({
        [[<?xml version="1.0" encoding="UTF-8"?>]],
        [[<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">]],
        [[<head><meta name="dtb:uid" content="urn:karakeep:]] .. ArticleUtil.escapeXml(bookmark.id) .. [["/></head>]],
        "<docTitle><text>" .. ArticleUtil.escapeXml(title) .. "</text></docTitle>",
        [[<navMap><navPoint id="navpoint-1" playOrder="1">]],
        "<navLabel><text>" .. ArticleUtil.escapeXml(title) .. "</text></navLabel>",
        [[<content src="content.xhtml"/>]],
        [[</navPoint></navMap></ncx>]],
    }, "\n")
end

--- Build an EPUB for a bookmark and write it to disk.
--
-- @tparam table bookmark Karakeep bookmark, with content included.
-- @tparam string filepath Destination path.
-- @tparam table opts
--   body_html      article HTML (defaults to bookmark.content.htmlContent)
--   include_images download and embed images
--   max_images     cap on embedded images
--   progress       optional function(message) for UI feedback
-- @treturn bool ok
-- @treturn string|nil Error description when ok is false.
function EpubBuilder.build(bookmark, filepath, opts)
    opts = opts or {}

    local content = bookmark.content or {}
    local title = bookmark.title or content.title or content.url or "Untitled"
    local body_html = opts.body_html or content.htmlContent

    if not body_html or body_html == "" then
        return false, "no_content"
    end

    body_html = ArticleUtil.sanitizeHtml(body_html)

    local candidates = {}
    if opts.include_images then
        body_html, candidates = ArticleUtil.collectImages(body_html, opts.max_images or 30)
    else
        body_html = body_html:gsub("<%s*[iI][mM][gG][^>]*>", "")
    end

    -- Fetch images before opening the archive: an entry can only be written
    -- once, so we must know which images survive before we emit the XHTML that
    -- references them. Bytes are held one at a time and spilled to disk.
    local images, image_data = {}, {}
    for index, candidate in ipairs(candidates) do
        if opts.progress then
            opts.progress(string.format("Fetching image %d of %d…", index, #candidates))
        end

        local data = fetchUrl(candidate.src, opts.image_block_timeout, opts.image_total_timeout)
        -- Trust the magic bytes, not the URL: extensions are frequently a lie,
        -- and crengine will not render an image whose type is misdeclared.
        local media_type = data and ArticleUtil.sniffImageType(data)

        if data and media_type and media_type ~= "image/webp" then
            table.insert(images, { path = candidate.path, media_type = media_type })
            image_data[candidate.path] = data
        else
            logger.dbg("Karakeep: dropping image", candidate.src, media_type or "unfetchable")
        end
    end

    -- Drop <img> elements whose source we could not embed, so the EPUB never
    -- shows a broken-image box.
    if #images < #candidates then
        local kept = {}
        for _, image in ipairs(images) do kept[image.path] = true end

        body_html = body_html:gsub('<img src="([^"]*)"[^>]*/?>', function(path)
            if kept[path] then return nil end
            return ""
        end)
    end

    local document = EpubBuilder.buildDocument(bookmark, body_html)

    -- crengine turns arbitrary crawler HTML into balanced XHTML. Without this,
    -- a single unclosed <p> from the source site breaks the whole EPUB.
    local balanced_ok, balanced = pcall(function()
        local cre = require("libs/libkoreader-cre")
        return cre.getBalancedHTML(document, 0x0)
    end)
    if balanced_ok and balanced and balanced ~= "" then
        document = balanced
    else
        logger.warn("Karakeep: getBalancedHTML failed, writing unbalanced HTML for", bookmark.id)
    end

    local xhtml = table.concat({
        [[<?xml version="1.0" encoding="UTF-8"?>]],
        [[<html xmlns="http://www.w3.org/1999/xhtml">]],
        "<head>",
        "<title>" .. ArticleUtil.escapeXml(title) .. "</title>",
        [[<link rel="stylesheet" type="text/css" href="stylesheet.css"/>]],
        "</head>",
        "<body>",
        document,
        "</body></html>",
    }, "\n")

    local Archiver = require("ffi/archiver")
    local writer = Archiver.Writer:new{}
    local tmp_path = filepath .. ".tmp"

    if not writer:open(tmp_path, "epub") then
        return false, "zip_open_failed"
    end

    local mtime = os.time()

    -- "mimetype" must be first and stored uncompressed.
    writer:setZipCompression("store")
    writer:addFileFromMemory("mimetype", "application/epub+zip", mtime)
    writer:setZipCompression("deflate")

    writer:addFileFromMemory("META-INF/container.xml", table.concat({
        [[<?xml version="1.0" encoding="UTF-8"?>]],
        [[<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">]],
        [[<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>]],
        [[</container>]],
    }, "\n"), mtime)

    writer:addFileFromMemory("OEBPS/stylesheet.css", CSS, mtime)
    writer:addFileFromMemory("OEBPS/content.xhtml", xhtml, mtime)
    writer:addFileFromMemory("OEBPS/content.opf", opf(bookmark, title, images), mtime)
    writer:addFileFromMemory("OEBPS/toc.ncx", ncx(bookmark, title), mtime)

    -- Already-compressed formats gain nothing from deflate, and the Kobo's CPU
    -- is slow enough that it is worth skipping.
    writer:setZipCompression("store")
    for _, image in ipairs(images) do
        writer:addFileFromMemory("OEBPS/" .. image.path, image_data[image.path], mtime)
        image_data[image.path] = nil -- release as we go
    end

    writer:close()
    collectgarbage()

    os.remove(filepath)
    local renamed, rename_err = os.rename(tmp_path, filepath)
    if not renamed then
        os.remove(tmp_path)
        return false, rename_err or "rename_failed"
    end

    return true
end

return EpubBuilder
