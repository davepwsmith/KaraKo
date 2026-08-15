local Runner = require("spec.runner")
local Config = require("config")

local describe, it = Runner.describe, Runner.it
local assertEqual, assertTrue, assertNil = Runner.assertEqual, Runner.assertTrue, Runner.assertNil
local assertMatch = Runner.assertMatch

describe("Config.parse", function()
    it("reads the basic key = value form", function()
        local values, problems = Config.parse([[
server_url = https://karakeep.example.com
api_token = ak1_secret
]])
        assertEqual(values.server_url, "https://karakeep.example.com")
        assertEqual(values.api_token, "ak1_secret")
        assertEqual(#problems, 0)
    end)

    it("accepts a colon instead of an equals sign", function()
        local values = Config.parse("server_url: https://e.com")
        assertEqual(values.server_url, "https://e.com")
    end)

    it("does not need URLs or tokens quoted", function()
        -- A URL contains ":" and "/", and a token can contain "="; the value is
        -- taken literally to end of line.
        local values = Config.parse("server_url = http://192.168.1.5:3000/karakeep\napi_token = a=b=c")
        assertEqual(values.server_url, "http://192.168.1.5:3000/karakeep")
        assertEqual(values.api_token, "a=b=c")
    end)

    it("strips surrounding quotes when present", function()
        assertEqual(Config.parse('archive_tag = "read on kobo"').archive_tag, "read on kobo")
        assertEqual(Config.parse("archive_tag = 'kobo'").archive_tag, "kobo")
    end)

    it("ignores comments, blank lines and stray whitespace", function()
        local values, problems = Config.parse([[
# a comment
; another

   server_url   =    https://e.com

]])
        assertEqual(values.server_url, "https://e.com")
        assertEqual(#problems, 0)
    end)

    it("coerces numbers", function()
        local values = Config.parse("articles_per_sync = 50")
        assertEqual(values.articles_per_sync, 50)
        assertEqual(type(values.articles_per_sync), "number")
    end)

    it("accepts the usual spellings of true and false", function()
        for _, word in ipairs({ "true", "yes", "on", "1", "TRUE", "Yes" }) do
            assertEqual(Config.parse("download_images = " .. word).download_images, true, word)
        end
        for _, word in ipairs({ "false", "no", "off", "0", "False" }) do
            assertEqual(Config.parse("download_images = " .. word).download_images, false, word)
        end
    end)

    it("keeps false distinct from absent", function()
        local values = Config.parse("sync_highlights = false")
        assertEqual(values.sync_highlights, false)
        assertNil(values.download_images)
    end)

    it("reads finish_action, so the file can pick what finishing does", function()
        local values, problems = Config.parse("finish_action = remove_from_scope")
        assertEqual(values.finish_action, "remove_from_scope")
        assertEqual(#problems, 0)
    end)

    it("reports an unknown setting rather than ignoring it", function()
        local values, problems = Config.parse("srever_url = https://e.com")
        assertNil(values.srever_url)
        assertEqual(#problems, 1)
        assertMatch(problems[1], "unknown setting")
        assertMatch(problems[1], "line 1")
    end)

    it("reports a value of the wrong type", function()
        local _, problems = Config.parse("articles_per_sync = lots")
        assertEqual(#problems, 1)
        assertMatch(problems[1], "needs a number")
    end)

    it("reports a malformed line", function()
        local _, problems = Config.parse("this is not a setting")
        assertEqual(#problems, 1)
        assertMatch(problems[1], "expected 'key = value'")
    end)

    it("keeps good lines when a bad one is present", function()
        local values, problems = Config.parse([[
server_url = https://e.com
nonsense
api_token = tok
]])
        assertEqual(values.server_url, "https://e.com")
        assertEqual(values.api_token, "tok")
        assertEqual(#problems, 1)
        assertMatch(problems[1], "line 2")
    end)

    it("handles CRLF line endings", function()
        local values, problems = Config.parse("server_url = https://e.com\r\napi_token = tok\r\n")
        assertEqual(values.server_url, "https://e.com")
        assertEqual(values.api_token, "tok")
        assertEqual(#problems, 0)
    end)

    it("tolerates empty and non-string input", function()
        assertEqual(#select(2, Config.parse("")), 0)
        assertEqual(#select(2, Config.parse(nil)), 0)
    end)
end)

describe("Config.read", function()
    it("returns nil for a file that is not there", function()
        local values = Config.read("/nonexistent/karako.conf")
        assertNil(values)
    end)

    it("round-trips a file it wrote", function()
        local path = os.tmpname()
        local handle = io.open(path, "w")
        handle:write("server_url = https://e.com\napi_token = tok\n")
        handle:close()

        local values, problems = Config.read(path)
        assertEqual(values.server_url, "https://e.com")
        assertEqual(#problems, 0)
        os.remove(path)
    end)
end)

describe("Config.template", function()
    it("parses cleanly, so the example is never itself broken", function()
        local values, problems = Config.parse(Config.template())
        assertEqual(#problems, 0, problems[1])
        assertTrue(values.server_url, "the template should set server_url")
        assertTrue(values.api_token, "the template should set api_token")
    end)

    it("warns that the key is stored in plain text", function()
        assertMatch(Config.template():lower(), "plain text")
    end)
end)

return Runner
