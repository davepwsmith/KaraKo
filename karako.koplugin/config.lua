--[[--
Optional plain-text configuration file.

Typing a Karakeep API key on an e-reader keyboard is miserable, so settings can
instead be dropped in a file and picked up at startup. Keys present in the file
win over anything set through the menu, which makes the file declarative: you
can keep it with your dotfiles and know what the device is running.

    # ~/.config/koreader/karako.conf
    server_url = https://karakeep.example.com
    api_token  = ak1_abc123...
    directory  = /mnt/onboard/karakeep
    articles_per_sync = 50
    download_images   = false

No KOReader dependencies, so the parser is exercised by the specs.

@module koplugin.karako.config
]]

local Config = {}

--- Settings the file may set, and the type each is coerced to.
-- Anything not listed here is reported as unknown rather than silently ignored,
-- because a typo in a config file is otherwise invisible.
Config.SCHEMA = {
    server_url = "string",
    api_token = "string",
    directory = "string",
    archive_tag = "string",
    sync_scope = "string",
    scope_id = "string",
    scope_name = "string",

    articles_per_sync = "number",
    max_images = "number",
    max_archive_mb = "number",
    auto_sync_interval = "number",

    download_images = "boolean",
    prefer_archive = "boolean",
    archive_finished = "boolean",
    archive_read = "boolean",
    archive_abandoned = "boolean",
    delete_local_after_archive = "boolean",
    sync_highlights = "boolean",
    auto_sync = "boolean",
}

local TRUE_WORDS = { ["true"] = true, yes = true, on = true, ["1"] = true }
local FALSE_WORDS = { ["false"] = true, no = true, off = true, ["0"] = true }

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Parse the contents of a config file.
--
-- Accepts `key = value` and `key: value`, one per line. Blank lines and lines
-- starting with # or ; are comments. Values are taken literally to end of line,
-- so a URL or a token needs no quoting, though surrounding quotes are stripped
-- if present.
--
-- @tparam string|nil text
-- @treturn table Recognised settings, coerced to their schema type.
-- @treturn table Array of human-readable problems; empty when all is well.
function Config.parse(text)
    local values, problems = {}, {}

    if type(text) ~= "string" then
        return values, problems
    end

    local line_number = 0
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        line_number = line_number + 1
        local trimmed = trim(line)

        if trimmed ~= "" and not trimmed:match("^[#;]") then
            local key, value = trimmed:match("^([%w_]+)%s*[=:]%s*(.*)$")

            if not key then
                table.insert(problems, string.format("line %d: expected 'key = value'", line_number))
            else
                value = trim(value)
                -- Allow quoting for values with meaningful leading/trailing space.
                local unquoted = value:match('^"(.*)"$') or value:match("^'(.*)'$")
                if unquoted then value = unquoted end

                local expected = Config.SCHEMA[key]
                if not expected then
                    table.insert(problems, string.format("line %d: unknown setting '%s'", line_number, key))
                elseif expected == "string" then
                    values[key] = value
                elseif expected == "number" then
                    local number = tonumber(value)
                    if number then
                        values[key] = number
                    else
                        table.insert(problems,
                            string.format("line %d: '%s' needs a number, got '%s'", line_number, key, value))
                    end
                elseif expected == "boolean" then
                    local lowered = value:lower()
                    if TRUE_WORDS[lowered] then
                        values[key] = true
                    elseif FALSE_WORDS[lowered] then
                        values[key] = false
                    else
                        table.insert(problems,
                            string.format("line %d: '%s' needs true or false, got '%s'", line_number, key, value))
                    end
                end
            end
        end
    end

    return values, problems
end

--- Read and parse a config file.
-- @tparam string path
-- @treturn table|nil Settings, or nil when the file does not exist.
-- @treturn table Problems.
function Config.read(path)
    local handle = io.open(path, "r")
    if not handle then return nil, {} end

    local text = handle:read("*a")
    handle:close()

    return Config.parse(text)
end

--- The example file written by the menu, for a user to fill in.
-- @treturn string
function Config.template()
    return table.concat({
        "# KaraKo settings. Lines starting with # are ignored.",
        "#",
        "# Anything set here is applied every time KOReader starts and overrides",
        "# the same setting in the menu, so delete a line to control it from the",
        "# menu instead.",
        "#",
        "# This file contains your API key in plain text. Keep it readable only",
        "# by you, and give the device its own key so it can be revoked alone.",
        "",
        "server_url = https://karakeep.example.com",
        "api_token  = paste-your-key-here",
        "",
        "# Where downloaded articles are kept.",
        "# directory = /mnt/onboard/karakeep",
        "",
        "# articles_per_sync = 30",
        "# download_images   = true",
        "# sync_highlights   = true",
        "# archive_tag       = read-on-kobo",
        "",
    }, "\n")
end

return Config
