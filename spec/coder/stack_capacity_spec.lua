local cpreamble = require "titan-compiler.cpreamble"
local h = require "spec.support.helpers"
local lfs = require "lfs"

local function clean()
    for _, suffix in ipairs({
        ".c", ".o", ".so", ".a", ".lua", "__entrypoint.c",
        "__entrypoint.o",
    }) do
        if not h.verbose or not suffix:match("%.c$") then
            os.remove("test" .. suffix)
        end
    end
    os.execute("rm -rf test.dSYM test.so.dSYM")
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    assert.truthy(file:close())
    return contents
end

local function unchecked_raw_calls(path)
    local contents = read_file(path)
    local failures = {}
    local search = 1
    while true do
        local at = contents:find(
            "lua_checkstack%s*%(%s*L%s*,", search)
        if not at then break end
        local prefix = contents:sub(math.max(1, at - 32), at - 1)
        if not prefix:match("!%s*$") then
            local line = 1
            for _ in contents:sub(1, at):gmatch("\n") do
                line = line + 1
            end
            failures[#failures + 1] = path .. ":" .. tostring(line)
        end
        search = at + 1
    end
    return failures
end

describe("generated Lua-stack capacity", function()
    after_each(clean)

    it("centralizes ordinary reservations in a raising helper", function()
        local prefix = cpreamble.fixed_prefix
        assert.truthy(prefix:find(
            "static TITAN_UNUSED inline void titan_ensure_stack",
            1, true))
        assert.truthy(prefix:find(
            "if (TITAN_UNLIKELY(!lua_checkstack(L, slots)))",
            1, true))
        assert.truthy(prefix:find(
            'luaL_error(L, "stack overflow in Titan generated code")',
            1, true))
    end)

    it("has no generated raw reservation that ignores failure", function()
        local failures = {}
        for name in lfs.dir("titan-compiler") do
            if name:match("%.lua$") then
                local path = "titan-compiler/" .. name
                for _, failure in ipairs(unchecked_raw_calls(path)) do
                    failures[#failures + 1] = failure
                end
            end
        end
        assert.same({}, failures)
    end)

    it("uses the helper across representative generated paths", function()
        local csrc = h.compile_and_read_c([[
            stored: {integer} = { 1 }

            record Box
                n: integer
            end

            function Box:get(): integer
                return self.n
            end

            function flexible(): (...: integer)
                return 1, 2
            end

            function exercise(
                    f: () -> integer,
                    x: integer,
                    ...: integer): integer
                local values: {integer} = { x }
                local captured = x
                local lambda: () -> integer = function(): integer
                    return captured
                end
                local box = Box.new(x)
                local bound: () -> integer = box:get
                do
                    if x < 0 then
                        raise "negative"
                    end
                catch
                    return 0
                end
                return f() + lambda() + bound() + values[1]
            end
        ]])

        assert.truthy(csrc:find(
            "static TITAN_UNUSED inline void titan_ensure_stack",
            1, true))
        assert.truthy(csrc:find(
            "titan_ensure_stack(L, 10);", 1, true))
        local _, closure_reservations = csrc:gsub(
            "titan_ensure_stack%(L, 6%);", "")
        assert.is_true(closure_reservations >= 2,
            "lambda and bound-method construction must both reserve six slots")
        assert.truthy(csrc:find(
            "titan_ensure_stack(L, 1);", 1, true))
        assert.truthy(csrc:find(
            "titan_ensure_stack(L, (int)_missing);", 1, true))
        assert.truthy(csrc:find(
            "titan_ensure_stack(L, 0 + _flexcap);", 1, true))
        assert.truthy(csrc:find(
            "titan_ensure_stack(L, 3);", 1, true))

        local _, calls = csrc:gsub("titan_ensure_stack%(L,", "")
        assert.is_true(calls >= 12,
            "representative module omitted stack-reserving paths")
    end)
end)
