--[[--
Headless check for EpubBuilder.build() against a real KOReader.

`make test` covers the pure Lua, but EPUB assembly needs crengine (for
getBalancedHTML) and libarchive (for the zip), neither of which can be faked
usefully. This script drives the real ones without starting the UI.

Run it from inside an extracted KOReader AppImage — see TESTING.md:

    cd squashfs-root/usr/lib/koreader
    ./luajit tools/epubcheck.lua

Exits non-zero if any check fails.
]]

require("setupkoenv")

-- Required before anything pulls in KOReader's device layer, which the image
-- fetching path does.
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")

package.path = "plugins/karakeep.koplugin/?.lua;" .. package.path

local cre = require("libs/libkoreader-cre")
os.execute("mkdir -p /tmp/kk-crcache")
pcall(cre.initCache, "/tmp/kk-crcache", 0, true, 40)

local EpubBuilder = require("epubbuilder")

local failures = 0

local function check(name, condition, detail)
    if condition then
        print("  ok   " .. name)
    else
        failures = failures + 1
        print("  FAIL " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
    end
end

local function readEntry(epub_path, entry)
    local pipe = io.popen(string.format("unzip -p %q %q 2>/dev/null", epub_path, entry))
    if not pipe then return nil end
    local content = pipe:read("*a")
    pipe:close()
    return content ~= "" and content or nil
end

--------------------------------------------------------------------------------
print("Ragged HTML is balanced into a valid EPUB")
--------------------------------------------------------------------------------

local ragged = {
    id = "epubcheck1",
    title = "A Test Article",
    note = "note from Karakeep",
    content = {
        type = "link",
        url = "https://example.com/a",
        author = "A. Writer",
        publisher = "Example Press",
        datePublished = "2026-01-15T09:00:00.000Z",
        htmlContent = [[<p>unclosed paragraph
<p>second &amp; third <em>emphasis <b>nested</b></p></div>
<h2>heading</h2><ul><li>one<li>two</ul>
<blockquote>Caf&#233; &mdash; na&iuml;ve</blockquote>
<script>alert("stripped")</script><p onclick="evil()">final.</p>]],
    },
    tags = { { id = "t1", name = "testing" } },
}

local plain_path = "/tmp/kk-epubcheck-plain.epub"
local built, build_err = EpubBuilder.build(ragged, plain_path, { include_images = false })
check("build succeeds", built, build_err)

local xhtml = readEntry(plain_path, "OEBPS/content.xhtml")
check("content.xhtml exists", xhtml ~= nil)

if xhtml then
    -- The point of the crengine pass: without it these stay broken.
    check("unclosed <p> is closed", xhtml:find("<p>unclosed paragraph </p>", 1, true) ~= nil)
    check("mis-nested <em> is closed", xhtml:find("<b>nested</b></em>", 1, true) ~= nil)
    check("stray </div> is dropped", xhtml:find("</div>", 1, true) == nil)
    check("<li> items are closed", xhtml:find("<li>one</li>", 1, true) ~= nil)

    -- Sanitising happens before crengine sees it.
    check("<script> is stripped", xhtml:find("alert(", 1, true) == nil)
    check("onclick is stripped", xhtml:find("onclick", 1, true) == nil)

    check("entities become UTF-8", xhtml:find("Caf\195\169", 1, true) ~= nil)
    check("XML declaration is present", xhtml:find("<?xml", 1, true) == 1)
    check("xhtml namespace survives", xhtml:find("xmlns=", 1, true) ~= nil)
    check("metadata is rendered", xhtml:find("A. Writer", 1, true) ~= nil)
    check("Karakeep note travels with it", xhtml:find("note from Karakeep", 1, true) ~= nil)
end

for _, entry in ipairs({ "mimetype", "META-INF/container.xml", "OEBPS/content.opf",
                         "OEBPS/toc.ncx", "OEBPS/stylesheet.css" }) do
    check("archive contains " .. entry, readEntry(plain_path, entry) ~= nil)
end

--------------------------------------------------------------------------------
print("Images are fetched, sniffed and embedded")
--------------------------------------------------------------------------------

-- Needs a local fixture server; skipped when it is not running.
local base = os.getenv("KK_IMG_SERVER")

if not base then
    print("  skip (set KK_IMG_SERVER, e.g. http://127.0.0.1:8799/, to run these)")
else
    local with_images = {
        id = "epubcheck2",
        title = "Image Test",
        content = {
            type = "link",
            url = "https://example.com/i",
            htmlContent = table.concat({
                '<p>a</p><img src="' .. base .. 'a.png">',
                -- Extension lies about the content; the bytes must win.
                '<p>b</p><img src="' .. base .. 'liar.jpg">',
                -- An HTML error page served where an image was expected.
                '<p>c</p><img src="' .. base .. 'broken.png">',
                '<p>d</p><img src="http://127.0.0.1:9/unreachable.png">',
                -- Same source twice: one file, two references.
                '<p>e</p><img src="' .. base .. 'a.png">',
            }),
        },
    }

    local image_path = "/tmp/kk-epubcheck-images.epub"
    local ok_images = EpubBuilder.build(with_images, image_path, { include_images = true })
    check("build with images succeeds", ok_images)

    local opf = readEntry(image_path, "OEBPS/content.opf") or ""
    local body = readEntry(image_path, "OEBPS/content.xhtml") or ""

    check("real image is embedded", readEntry(image_path, "OEBPS/images/img1.png") ~= nil)
    check("media type comes from the bytes, not the URL",
        opf:find('href="images/img2.jpg" media%-type="image/png"') ~= nil)
    check("non-image response is rejected", readEntry(image_path, "OEBPS/images/img3.png") == nil)
    check("unreachable image is rejected", readEntry(image_path, "OEBPS/images/img4.png") == nil)
    check("failed images leave no <img> behind",
        select(2, body:gsub("<img", "")) == 3)
    check("duplicate source is embedded once",
        readEntry(image_path, "OEBPS/images/img5.png") == nil)
    check("all paragraphs survive", select(2, body:gsub("<p>", "")) >= 5)
end

--------------------------------------------------------------------------------
print("")
if failures == 0 then
    print("epubcheck: all checks passed")
    os.exit(0)
end
print(string.format("epubcheck: %d check(s) failed", failures))
os.exit(1)
