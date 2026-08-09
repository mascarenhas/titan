local assert = require "luassert"
local cdriver = require "c-parser.cdriver"

local test

describe("titan.test outside a native test runner", function()
    setup(function()
        package.loaded["titan.test"] = nil
        test = require "titan.test"
    end)

    it("publishes only the documented public surface", function()
        assert.equal("userdata", type(test))
        assert.equal("function", type(test.testing))
        assert.equal("function", type(test.verbose))
        assert.equal("function", type(test.location))
        assert.equal("function", type(test.skip))
        assert.equal("function", type(test.assert))
        assert.equal("table", type(test.Context))

        local private_names = {
            "Cleanup", "RegisteredTest", "runner_begin", "runner_end",
            "runner_new_context", "runner_take_subtests",
            "runner_take_cleanup", "runner_skip_reason",
            "runner_error_text", "runner_matches", "runner_trace_location",
        }
        for _, name in ipairs(private_names) do
            local ok, message = pcall(function() return test[name] end)
            assert.falsy(ok, name)
            assert.truthy(tostring(message):find(
                "member '" .. name .. "' does not exist", 1, true),
                tostring(message))
        end
    end)

    it("reports inactive state", function()
        assert.is_false(test.testing())
        assert.is_false(test.verbose())
    end)

    it("raises readable ordinary errors outside the runner", function()
        local ok, message = pcall(test.assert, false)
        assert.falsy(ok)
        assert.truthy(tostring(message):find("assertion failed", 1, true),
            tostring(message))

        ok, message = pcall(test.assert, false, "custom assertion")
        assert.falsy(ok)
        assert.truthy(tostring(message):find("custom assertion", 1, true),
            tostring(message))

        ok, message = pcall(test.skip, "not today")
        assert.falsy(ok)
        assert.truthy(tostring(message):find(
            "test skipped: not today", 1, true), tostring(message))
    end)

    it("defers helper capture when a raw Lua binding is not callable",
       function()
        local script = os.tmpname()
        local file = assert(io.open(script, "w"))
        file:write([[
local original = string.gmatch
string.gmatch = false
local test = require "titan.test"
string.gmatch = original
local ok, source, name, line = pcall(test.location)
assert(ok, source)
assert(source == "<none>" and name == "<none>" and line == 0)
io.write("ok\n")
]])
        file:close()
        local command = "lua -E " .. assert(cdriver.shell_quote(script)) ..
            " 2>&1"
        local pipe = assert(io.popen(command, "r"))
        local output = pipe:read("*a")
        local ok, reason, status = pipe:close()
        os.remove(script)
        assert.is_true(ok, string.format(
            "poisoned helper child failed (%s %s):\n%s",
            tostring(reason), tostring(status), output))
        assert.equal("ok\n", output)
    end)

    it("uses the documented no-native-frame location sentinel", function()
        local file, function_name, line = test.location()
        assert.equal("<none>", file)
        assert.equal("<none>", function_name)
        assert.equal(0, line)
    end)
end)
