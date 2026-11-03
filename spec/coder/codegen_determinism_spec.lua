-- Generated C must be a function of its inputs alone. Lua randomizes its
-- string hash seed per process, so any emitter that walks a string-keyed
-- registry directly makes two identical builds emit different bytes. Generate
-- the same module in separate processes (hence different seeds) and require
-- the complete C/private-header/foreign-header bytes to agree.
--
-- The fixture exercises every registry whose order reaches generated C:
-- per-record and per-interface method maps, nominal metatable recovery,
-- static-dependency extern declarations, bound method/function entries, and
-- owned C metatables.
local assert = require "luassert"
local compiler_io = require "titan-compiler.io"
local installed_prefix = require "spec.support.installed_prefix"
local platform = require "titan-compiler.platform"

local PREFIX = installed_prefix.active()
local LUA = PREFIX .. (platform.windows and "/bin/lua.exe" or "/bin/lua")

local DEPENDENCY = [[
record Loaded
    count: integer
end
function Loaded:tally(): integer return self.count end
function Loaded.make(n: integer): Loaded return Loaded.new(n) end
function accept(n: integer): integer return n + 1 end
function apply(f: function (integer): integer, n: integer): integer return f(n) end
]]
local MAIN = [[
local dependency = import "dependency"
local foreign function relay(n: int): int return n end
record Alpha
    value: integer
end
function Alpha:first(): integer return self.value end
function Alpha:second(): integer return self.value + 1 end
function Alpha.make(n: integer): Alpha return Alpha.new(n) end
interface Reader
    function read(): integer
    function peek(): integer
end
function Alpha:read(): integer return self.value end
function Alpha:peek(): integer return self.value + 1 end
function forward(alpha: Alpha, n: integer): integer
    local bound = alpha:first
    local accepted = dependency.accept
    return dependency.apply(accepted, bound()) + accepted(n) + dependency.accept(n)
end
function owned_values(n: integer): value
    local integer_cell = foreign int.new()
    local double_cell = foreign double.new()
    local short_cell = foreign short.new()
    local integer_dynamic: value = integer_cell
    local double_dynamic: value = double_cell
    local short_dynamic: value = short_cell
    return integer_dynamic
end
function use(reader: Reader, f: function (integer): integer): integer
    return reader:read() + reader:peek() + f(2) + relay(1)
end
do use(Alpha.make(1), dependency.accept); forward(Alpha.make(1), 3); owned_values(1) end
]]

local CHILD = [[
package.path = "./?.lua;./?/init.lua;" .. package.path
local h = require "spec.support.helpers"
local coder = require "titan-compiler.coder"
local driver = require "titan-compiler.driver"

local function generate()
    local ok, err, imported = h.run_checker_modules({
        dependency = $DEPENDENCY,
        determinism = $MAIN,
    }, "determinism")
    if not ok then error(err) end
    local ast = assert(imported.determinism.ast)
    ast._ffi_header_output = "/generated/determinism.ffi.h"
    ast._foreign_header_output = "/generated/determinism.titan.h"
    -- Four parts keep a private header in the compared bytes, and the local
    -- foreign body keeps a published foreign header there too.
    local generated = coder.generate("determinism", ast, { dependency = true },
        driver.TITAN_ABI_VERSION, true, {
            c_parts = 4,
            split_threshold = 1,
            source_output_stem = "/generated/determinism",
        })
    assert(generated.private_header and generated.private_header ~= "")
    assert(generated.foreign_header and generated.foreign_header ~= "")
    local texts = { generated.private_header or "", generated.foreign_header or "" }
    for _, part in ipairs(generated.parts) do texts[#texts + 1] = part.code end
    return table.concat(texts, "\n")
end

local text = generate()
assert(text == generate(), "repeated in-process generation disagreed")
local file = assert(io.open(arg[1], "wb"))
assert(file:write(text))
assert(file:close())
]]

local function escaped(source)
    return string.format("%q", source)
end

local function child_script()
    return (CHILD:gsub("%$DEPENDENCY", function() return escaped(DEPENDENCY) end)
        :gsub("%$MAIN", function() return escaped(MAIN) end))
end

local function run(argv)
    local result = compiler_io.new_sync():run(argv)
    if not result.ok then
        return nil, result.output or result.diagnostic or result.why
    end
    return result.output or ""
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
end

local function remove_tree(path)
    local lfs = require "lfs"
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                remove_tree(path .. "/" .. entry)
            end
        end
        assert(lfs.rmdir(path))
    elseif mode then
        assert(os.remove(path))
    end
end

describe("generated C determinism", function()
    it("emits identical bytes from separate processes", function()
        local root = assert(compiler_io.new_sync():tmpname())
        os.remove(root)
        assert(require("lfs").mkdir(root))
        local tested, test_error = xpcall(function()
            local script = root .. "/generate.lua"
            write_file(script, child_script())
            local outputs = {}
            for index = 1, 3 do
                local path = root .. "/out" .. index .. ".c"
                local output, err = run({ LUA, script, path })
                assert.truthy(output, err)
                outputs[index] = read_file(path)
            end
            -- Non-vacuous: every ordered registry is present in this fixture.
            local text = outputs[1]
            for _, needle in ipairs({
                "extern lua_Integer dependency_",
                "#ifndef TITAN_GENERATED_PRIVATE_",
                [[static inline int determinism_\u2119_foreign_inline_relay]],
                "Titan record determinism.Alpha metatable",
                "Titan interface determinism.Reader metatable",
                'lua_pushliteral(L, "first");',
                'lua_pushliteral(L, "second");',
                "Titan owned C",
                "titan_pushmodule(L, _mod);",
            }) do
                assert.truthy(text:find(needle, 1, true), needle)
            end
            for index = 2, #outputs do
                assert.equal(outputs[1], outputs[index],
                    "process " .. index .. " emitted different generated C")
            end
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(test_error, 0) end
    end)
end)
