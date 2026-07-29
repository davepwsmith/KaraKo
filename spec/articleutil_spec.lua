local Runner = require("spec.runner")
local ArticleUtil = require("articleutil")

local describe, it = Runner.describe, Runner.it
local assertEqual, assertTrue, assertNil = Runner.assertEqual, Runner.assertTrue, Runner.assertNil
local assertMatch, assertNoMatch = Runner.assertMatch, Runner.assertNoMatch

describe("getBookmarkId", function()
    it("reads the ID back out of a filename", function()
        assertEqual(ArticleUtil.getBookmarkId("[kk-id_abc123] Some Article.epub"), "abc123")
    end)

    it("works on a full path", function()
        assertEqual(ArticleUtil.getBookmarkId("/mnt/onboard/karakeep/[kk-id_xy9] T.epub"), "xy9")
    end)

    it("survives a title containing the postfix", function()
        assertEqual(ArticleUtil.getBookmarkId("[kk-id_abc] Lists] and things.epub"), "abc")
    end)

    it("ignores files that are not ours", function()
        assertNil(ArticleUtil.getBookmarkId("Some Other Book.epub"))
        assertNil(ArticleUtil.getBookmarkId("[w-id_12] A wallabag article.epub"))
        assertNil(ArticleUtil.getBookmarkId("[kk-id_] Empty.epub"))
        assertNil(ArticleUtil.getBookmarkId("[kk-id_abc"))
        assertNil(ArticleUtil.getBookmarkId(nil))
    end)
end)

describe("safeTitle", function()
    it("replaces characters FAT32 cannot store", function()
        assertEqual(ArticleUtil.safeTitle('a/b\\c:d*e?f"g<h>i|j'), "a_b_c_d_e_f_g_h_i_j")
    end)

    it("neutralises brackets so the ID prefix stays unambiguous", function()
        assertEqual(ArticleUtil.safeTitle("[draft] Notes"), "(draft) Notes")
    end)

    it("collapses whitespace and trims", function()
        assertEqual(ArticleUtil.safeTitle("  a   b  "), "a b")
    end)

    it("never returns an empty name", function()
        assertEqual(ArticleUtil.safeTitle(""), "Untitled")
        assertEqual(ArticleUtil.safeTitle(nil), "Untitled")
        assertEqual(ArticleUtil.safeTitle("..."), "Untitled")
    end)

    it("does not end in a dot or a space", function()
        assertEqual(ArticleUtil.safeTitle("Ends with a dot."), "Ends with a dot")
    end)

    it("truncates to the byte budget", function()
        assertTrue(#ArticleUtil.safeTitle(string.rep("x", 500), 40) <= 40)
    end)
end)

describe("trimPartialUtf8", function()
    it("leaves complete strings alone", function()
        assertEqual(ArticleUtil.trimPartialUtf8("caf\195\169"), "caf\195\169")
        assertEqual(ArticleUtil.trimPartialUtf8("plain"), "plain")
    end)

    it("drops a dangling multi-byte sequence", function()
        -- "café" cut one byte short of the é
        assertEqual(ArticleUtil.trimPartialUtf8("caf\195"), "caf")
        -- a 3-byte character missing its last byte
        assertEqual(ArticleUtil.trimPartialUtf8("a\226\128"), "a")
    end)
end)

describe("buildFilename", function()
    it("round-trips through getBookmarkId", function()
        local name = ArticleUtil.buildFilename("k7dz", "Why Kobo?")
        assertEqual(name, "[kk-id_k7dz] Why Kobo_.epub")
        assertEqual(ArticleUtil.getBookmarkId(name), "k7dz")
    end)

    it("round-trips even with a hostile title", function()
        local name = ArticleUtil.buildFilename("abc", "[weird] title/with: junk")
        assertEqual(ArticleUtil.getBookmarkId(name), "abc")
    end)

    it("stays within a 255 byte filename", function()
        local name = ArticleUtil.buildFilename("abc", string.rep("long ", 200))
        assertTrue(#name <= 255, "filename was " .. #name .. " bytes")
    end)
end)

describe("utf8Char", function()
    it("encodes each sequence length", function()
        assertEqual(ArticleUtil.utf8Char(65), "A")
        assertEqual(ArticleUtil.utf8Char(0xE9), "\195\169")      -- é
        assertEqual(ArticleUtil.utf8Char(0x2014), "\226\128\148") -- em dash
        assertEqual(ArticleUtil.utf8Char(0x1F600), "\240\159\152\128")
    end)
end)

describe("decodeEntities", function()
    it("decodes named entities", function()
        assertEqual(ArticleUtil.decodeEntities("a &amp; b"), "a & b")
        assertEqual(ArticleUtil.decodeEntities("&lt;tag&gt;"), "<tag>")
    end)

    it("decodes numeric entities in both bases", function()
        assertEqual(ArticleUtil.decodeEntities("caf&#233;"), "caf\195\169")
        assertEqual(ArticleUtil.decodeEntities("caf&#xE9;"), "caf\195\169")
    end)

    it("leaves unknown entities alone", function()
        assertEqual(ArticleUtil.decodeEntities("&notareal;"), "&notareal;")
    end)
end)

describe("escapeXml", function()
    it("escapes the five XML specials", function()
        assertEqual(ArticleUtil.escapeXml([[<a href="x">'&']]),
            "&lt;a href=&quot;x&quot;&gt;&apos;&amp;&apos;")
    end)

    it("escapes ampersands only once", function()
        assertEqual(ArticleUtil.escapeXml("&lt;"), "&amp;lt;")
    end)
end)

describe("sanitizeHtml", function()
    it("removes scripts and their contents", function()
        local out = ArticleUtil.sanitizeHtml('<p>a</p><script>alert("x")</script><p>b</p>')
        assertNoMatch(out, "alert")
        assertNoMatch(out, "script")
        assertMatch(out, "<p>a</p>")
        assertMatch(out, "<p>b</p>")
    end)

    it("removes styles, iframes and comments", function()
        assertNoMatch(ArticleUtil.sanitizeHtml("<style>p{color:red}</style>x"), "color")
        assertNoMatch(ArticleUtil.sanitizeHtml('<iframe src="ad"></iframe>x'), "iframe")
        assertNoMatch(ArticleUtil.sanitizeHtml("<!-- tracking -->x"), "tracking")
    end)

    it("strips inline event handlers", function()
        local out = ArticleUtil.sanitizeHtml('<p onclick="evil()">a</p>')
        assertNoMatch(out, "onclick")
        assertMatch(out, ">a</p>")
    end)

    it("defuses javascript: links", function()
        assertNoMatch(ArticleUtil.sanitizeHtml('<a href="javascript:evil()">x</a>'), "javascript:")
    end)

    it("keeps ordinary markup intact", function()
        local html = "<h2>Title</h2><p>Body with <em>emphasis</em>.</p>"
        assertEqual(ArticleUtil.sanitizeHtml(html), html)
    end)
end)

describe("htmlToText", function()
    it("flattens tags to whitespace-normalised text", function()
        assertEqual(ArticleUtil.htmlToText("<p>Hello</p>\n<p>world</p>"), "Hello world")
    end)

    it("decodes entities as it goes", function()
        assertEqual(ArticleUtil.htmlToText("<p>a &amp; b</p>"), "a & b")
    end)

    it("does not run adjacent words together", function()
        assertEqual(ArticleUtil.htmlToText("<b>one</b><i>two</i>"), "one two")
    end)
end)

describe("findTextOffsets", function()
    local text = "The quick brown fox jumps over the lazy dog near the river bank today"

    it("finds an exact passage", function()
        local first, last = ArticleUtil.findTextOffsets(text, "brown fox")
        assertEqual(first, 10)
        assertEqual(last, 19)
        assertEqual(text:sub(first + 1, last), "brown fox")
    end)

    it("normalises whitespace before matching", function()
        local first = ArticleUtil.findTextOffsets(text, "  brown\n  fox ")
        assertEqual(first, 10)
    end)

    it("falls back to a middle slice when the edges do not match", function()
        local needle = "XX quick brown fox jumps over the lazy dog YY"
        local first, last = ArticleUtil.findTextOffsets(text, needle)
        assertTrue(first, "expected the probe fallback to find something")
        assertTrue(last > first)
    end)

    it("returns nil when the passage is absent", function()
        assertNil(ArticleUtil.findTextOffsets(text, "not in the article at all"))
        assertNil(ArticleUtil.findTextOffsets(text, ""))
    end)

    it("treats the needle literally, not as a pattern", function()
        local haystack = "cost is 10% (approx) per unit"
        local first = ArticleUtil.findTextOffsets(haystack, "10% (approx)")
        assertEqual(first, 8)
    end)
end)

describe("collectImages", function()
    it("rewrites sources and collects them in order", function()
        local html = '<p><img src="https://e.com/a.png"/>x<img src="https://e.com/b.jpg"/></p>'
        local out, images = ArticleUtil.collectImages(html)

        assertEqual(#images, 2)
        assertEqual(images[1].src, "https://e.com/a.png")
        assertEqual(images[1].path, "images/img1.png")
        assertEqual(images[2].path, "images/img2.jpg")
        assertMatch(out, 'src="images/img1.png"')
        assertNoMatch(out, "e.com")
    end)

    it("reuses one entry for a repeated source", function()
        local html = '<img src="https://e.com/a.png"><img src="https://e.com/a.png">'
        local out, images = ArticleUtil.collectImages(html)
        assertEqual(#images, 1)
        local count = select(2, out:gsub('src="images/img1%.png"', ""))
        assertEqual(count, 2)
    end)

    it("drops data URIs, relative paths and sourceless tags", function()
        local out, images = ArticleUtil.collectImages(
            '<img src="data:image/png;base64,AAAA"><img src="/rel.png"><img alt="x">')
        assertEqual(#images, 0)
        assertNoMatch(out, "<img")
    end)

    it("honours the cap and drops the overflow", function()
        local html = ""
        for i = 1, 10 do html = html .. string.format('<img src="https://e.com/%d.png">', i) end

        local out, images = ArticleUtil.collectImages(html, 3)
        assertEqual(#images, 3)
        assertEqual(select(2, out:gsub("<img", "")), 3)
    end)
end)

describe("imageExtension and mediaType", function()
    it("maps known extensions, ignoring query strings", function()
        assertEqual(ArticleUtil.imageExtension("https://e.com/a.PNG?w=100"), ".png")
        assertEqual(ArticleUtil.imageExtension("https://e.com/a.jpeg"), ".jpg")
    end)

    it("defaults to jpg for extensionless URLs", function()
        assertEqual(ArticleUtil.imageExtension("https://e.com/image"), ".jpg")
    end)

    it("maps paths to media types", function()
        assertEqual(ArticleUtil.mediaType("images/img1.png"), "image/png")
        assertEqual(ArticleUtil.mediaType("images/img1.gif"), "image/gif")
        assertEqual(ArticleUtil.mediaType("images/img1.unknown"), "image/jpeg")
    end)
end)

describe("sniffImageType", function()
    it("recognises formats by magic bytes", function()
        assertEqual(ArticleUtil.sniffImageType("\255\216\255" .. string.rep("\0", 20)), "image/jpeg")
        assertEqual(ArticleUtil.sniffImageType("\137PNG\r\n\26\n" .. string.rep("\0", 20)), "image/png")
        assertEqual(ArticleUtil.sniffImageType("GIF89a" .. string.rep("\0", 20)), "image/gif")
        assertEqual(ArticleUtil.sniffImageType("RIFF\0\0\0\0WEBP" .. string.rep("\0", 20)), "image/webp")
    end)

    it("returns nil for HTML served in place of an image", function()
        assertNil(ArticleUtil.sniffImageType("<!DOCTYPE html><html>404 not found</html>"))
        assertNil(ArticleUtil.sniffImageType("short"))
    end)
end)

describe("contentSources", function()
    local function link(fields)
        local content = { type = "link", url = "https://e.com/a" }
        for k, v in pairs(fields) do content[k] = v end
        return { id = "b1", content = content }
    end

    local function labels(sources)
        local out = {}
        for _, source in ipairs(sources) do table.insert(out, source.label) end
        return table.concat(out, " > ")
    end

    it("prefers inline readable HTML", function()
        local sources = ArticleUtil.contentSources(link{ htmlContent = "<p>x</p>" })
        assertEqual(sources[1].kind, "inline")
    end)

    it("uses the content asset, which is the common case over ~5 KB", function()
        -- Karakeep nulls htmlContent and stores the same HTML as an asset once
        -- it passes the inline threshold.
        local sources = ArticleUtil.contentSources(link{ contentAssetId = "a1" })
        assertEqual(sources[1].kind, "asset")
        assertEqual(sources[1].asset_id, "a1")
        assertTrue(not sources[1].full_page)
    end)

    it("puts extracted content ahead of archives by default", function()
        local sources = ArticleUtil.contentSources(link{
            contentAssetId = "a1",
            precrawledArchiveAssetId = "p1",
            fullPageArchiveAssetId = "f1",
        })
        assertEqual(labels(sources),
            "readable HTML asset > precrawled archive > full page archive > readable content endpoint")
    end)

    it("prefers the user's own capture over Karakeep's snapshot", function()
        local sources = ArticleUtil.contentSources(link{
            precrawledArchiveAssetId = "p1",
            fullPageArchiveAssetId = "f1",
        })
        assertEqual(sources[1].label, "precrawled archive")
        assertEqual(sources[2].label, "full page archive")
    end)

    it("flips the order when asked to prefer archives", function()
        local sources = ArticleUtil.contentSources(link{
            htmlContent = "<p>x</p>",
            precrawledArchiveAssetId = "p1",
        }, true)
        assertEqual(labels(sources),
            "precrawled archive > inline readable HTML > readable content endpoint")
    end)

    it("marks archives as whole pages", function()
        local sources = ArticleUtil.contentSources(link{ precrawledArchiveAssetId = "p1" })
        assertTrue(sources[1].full_page)
    end)

    it("always ends with the endpoint, so there is a last resort", function()
        local bare = ArticleUtil.contentSources(link{})
        assertEqual(#bare, 1)
        assertEqual(bare[1].kind, "endpoint")
    end)

    it("ignores empty strings, which are not usable content", function()
        local sources = ArticleUtil.contentSources(link{ htmlContent = "", contentAssetId = "" })
        assertEqual(#sources, 1)
        assertEqual(sources[1].kind, "endpoint")
    end)

    it("returns nothing for bookmarks that are not links", function()
        assertEqual(#ArticleUtil.contentSources{ content = { type = "text", text = "x" } }, 0)
        assertEqual(#ArticleUtil.contentSources{ content = { type = "asset" } }, 0)
        assertEqual(#ArticleUtil.contentSources{}, 0)
        assertEqual(#ArticleUtil.contentSources(nil), 0)
    end)
end)

describe("displayText", function()
    it("passes ordinary strings through", function()
        assertEqual(ArticleUtil.displayText("A Title"), "A Title")
    end)

    it("falls back for anything unusable", function()
        local function jsonNull() end
        assertEqual(ArticleUtil.displayText(jsonNull, "Untitled"), "Untitled")
        assertEqual(ArticleUtil.displayText(nil, "Untitled"), "Untitled")
        assertEqual(ArticleUtil.displayText("", "Untitled"), "Untitled")
        assertEqual(ArticleUtil.displayText({}, "Untitled"), "Untitled")
    end)

    it("renders numbers", function()
        assertEqual(ArticleUtil.displayText(42), "42")
    end)

    it("never returns a value string.format would reject", function()
        local function jsonNull() end
        for _, v in ipairs({ "ok", 1 }) do
            assertTrue(pcall(string.format, "%s", ArticleUtil.displayText(v)))
        end
        assertTrue(pcall(string.format, "%s", ArticleUtil.displayText(jsonNull)))
    end)
end)

describe("stripJsonNulls", function()
    -- KOReader decodes JSON null to a function, which is truthy. Stand-in here.
    local function jsonNull() end -- the value itself is the sentinel; never called

    it("removes a null field so `or` falls through", function()
        local bookmark = ArticleUtil.stripJsonNulls{ title = jsonNull, id = "a" }
        assertNil(bookmark.title)
        assertEqual(bookmark.title or "Untitled", "Untitled")
    end)

    it("reproduces the crash it exists to prevent", function()
        -- Before the fix, a null title survived the `or` chain and reached
        -- string formatting, which errors with "invalid replacement value".
        local raw = { title = jsonNull }
        assertTrue(raw.title, "a JSON null must be truthy for this test to mean anything")
        local ok = pcall(string.format, "%s", raw.title)
        assertTrue(not ok or type(raw.title) == "function")

        local cleaned = ArticleUtil.stripJsonNulls{ title = jsonNull }
        assertEqual(string.format("%s", cleaned.title or "Untitled"), "Untitled")
    end)

    it("recurses into nested objects", function()
        local bookmark = ArticleUtil.stripJsonNulls{
            id = "a",
            content = { type = "link", url = "https://e.com", author = jsonNull },
        }
        assertNil(bookmark.content.author)
        assertEqual(bookmark.content.url, "https://e.com")
    end)

    it("clears a null nextCursor so pagination terminates", function()
        -- Left in place, the sentinel is truthy, so the paging loop would keep
        -- going and send "function: 0x..." as the cursor.
        local page = ArticleUtil.stripJsonNulls{ bookmarks = {}, nextCursor = jsonNull }
        assertNil(page.nextCursor)
    end)

    it("recurses into arrays of objects", function()
        local page = ArticleUtil.stripJsonNulls{
            bookmarks = {
                { id = "a", title = jsonNull },
                { id = "b", title = "kept" },
            },
        }
        assertEqual(#page.bookmarks, 2)
        assertNil(page.bookmarks[1].title)
        assertEqual(page.bookmarks[2].title, "kept")
    end)

    it("drops nulls inside an array without truncating it", function()
        local out = ArticleUtil.stripJsonNulls{ list = { "a", jsonNull, "b" } }
        assertEqual(#out.list, 2)
        assertEqual(out.list[1], "a")
        assertEqual(out.list[2], "b")
    end)

    it("leaves ordinary values alone", function()
        local out = ArticleUtil.stripJsonNulls{
            s = "x", n = 1, t = true, f = false, empty = {},
        }
        assertEqual(out.s, "x")
        assertEqual(out.n, 1)
        assertEqual(out.t, true)
        assertEqual(out.f, false, "false must survive; it is not a null")
        assertEqual(type(out.empty), "table")
    end)

    it("tolerates scalars and deep nesting", function()
        assertEqual(ArticleUtil.stripJsonNulls("plain"), "plain")
        assertNil(ArticleUtil.stripJsonNulls(jsonNull))

        local deep, cursor = {}, nil
        cursor = deep
        for _ = 1, 40 do cursor.next = {}; cursor = cursor.next end
        assertTrue(ArticleUtil.stripJsonNulls(deep), "must not overflow the stack")
    end)
end)

describe("buildQuery", function()
    it("returns an empty string for no parameters", function()
        assertEqual(ArticleUtil.buildQuery({}), "")
        assertEqual(ArticleUtil.buildQuery(nil), "")
    end)

    it("sorts keys and renders booleans", function()
        assertEqual(ArticleUtil.buildQuery{ limit = 10, archived = false, includeContent = true },
            "?archived=false&includeContent=true&limit=10")
    end)

    it("percent-encodes values", function()
        assertEqual(ArticleUtil.buildQuery{ q = "a b&c" }, "?q=a%20b%26c")
    end)

    it("skips nil values", function()
        assertEqual(ArticleUtil.buildQuery{ cursor = nil, limit = 5 }, "?limit=5")
    end)
end)

describe("normaliseServerUrl", function()
    it("strips trailing slashes", function()
        assertEqual(ArticleUtil.normaliseServerUrl("https://k.example.com/"), "https://k.example.com")
    end)

    it("strips a pasted /api/v1 suffix", function()
        assertEqual(ArticleUtil.normaliseServerUrl("https://k.example.com/api/v1"), "https://k.example.com")
        assertEqual(ArticleUtil.normaliseServerUrl("https://k.example.com/api/v1/"), "https://k.example.com")
    end)

    it("trims surrounding whitespace", function()
        assertEqual(ArticleUtil.normaliseServerUrl("  https://k.example.com  "), "https://k.example.com")
    end)

    it("leaves a port and a subpath alone", function()
        assertEqual(ArticleUtil.normaliseServerUrl("http://192.168.1.5:3000"), "http://192.168.1.5:3000")
        assertEqual(ArticleUtil.normaliseServerUrl("https://host/karakeep"), "https://host/karakeep")
    end)
end)

return Runner
