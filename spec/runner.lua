--[[--
A very small spec runner.

KOReader's own tests use busted, but busted is not much use here: the modules
under test must be exercised with a plain Lua 5.1 interpreter (the dialect
LuaJIT implements), and only articleutil.lua is free enough of KOReader
dependencies to run outside the device. Keeping the runner to a few lines means
`make test` works anywhere Lua is installed.
]]

local Runner = {
    passed = 0,
    failed = 0,
    failures = {},
    current = nil,
}

function Runner.describe(name, fn)
    Runner.current = name
    fn()
end

function Runner.it(name, fn)
    local label = (Runner.current or "?") .. " :: " .. name
    local ok, err = xpcall(fn, function(e)
        return tostring(e) .. "\n" .. debug.traceback("", 2)
    end)

    if ok then
        Runner.passed = Runner.passed + 1
        io.write(".")
    else
        Runner.failed = Runner.failed + 1
        table.insert(Runner.failures, { label = label, err = err })
        io.write("F")
    end
    io.flush()
end

local function render(value)
    if type(value) == "string" then return string.format("%q", value) end
    return tostring(value)
end

function Runner.assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%sexpected %s, got %s",
            message and (message .. ": ") or "", render(expected), render(actual)), 2)
    end
end

function Runner.assertTrue(value, message)
    if not value then
        error((message or "expected a truthy value") .. ", got " .. render(value), 2)
    end
end

function Runner.assertNil(value, message)
    if value ~= nil then
        error((message or "expected nil") .. ", got " .. render(value), 2)
    end
end

function Runner.assertMatch(haystack, needle, message)
    if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
        error(string.format("%sexpected %s to contain %s",
            message and (message .. ": ") or "", render(haystack), render(needle)), 2)
    end
end

function Runner.assertNoMatch(haystack, needle, message)
    if type(haystack) == "string" and haystack:find(needle, 1, true) then
        error(string.format("%sexpected %s not to contain %s",
            message and (message .. ": ") or "", render(haystack), render(needle)), 2)
    end
end

function Runner.report()
    io.write("\n\n")
    for _, failure in ipairs(Runner.failures) do
        io.write("FAILED: " .. failure.label .. "\n  " .. failure.err .. "\n\n")
    end
    io.write(string.format("%d passed, %d failed\n", Runner.passed, Runner.failed))
    return Runner.failed == 0
end

return Runner
