local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local coder_names = require "titan-compiler.coder.names"
local compiler_io = require "titan-compiler.io"
local coverage = require "titan-compiler.coverage"
local coverage_lines = require "titan-compiler.coverage_lines"
local driver = require "titan-compiler.driver"
local h = require "spec.support.helpers"
local incremental = require "titan-compiler.incremental"
local jobs = require "titan-compiler.jobs"
local installed_prefix = require "spec.support.installed_prefix"
local lfs = require "lfs"
local module_symbols = require "spec.support.module_symbols"
local asan_mapper = require "spec.support.asan_generated_c_context"
local objectmetadata = require "titan-compiler.objectmetadata"
local parser = require "titan-compiler.parser"
local platform = require "titan-compiler.platform"
local staticmetadata = require "titan-compiler.staticmetadata"
local temporary = require "spec.support.temporary"
local util = require "titan-compiler.util"

local PREFIX = installed_prefix.active()
local LUA = PREFIX .. (platform.windows and "/bin/lua.exe" or "/bin/lua")
local io_strategy = compiler_io.new_sync()
local ROOT = assert(lfs.currentdir())

local function cli_frontend(filename, bootstrap)
    local file = assert(io.open(filename, "wb"))
    assert(file:write(string.format([[
package.path = %q .. "/?.lua;" .. package.path
require("titan-compiler.coder").DEFAULT_SPLIT_THRESHOLD = 1
%s
dofile(%q .. "/titanc")
]], ROOT, bootstrap or "", ROOT)))
    assert(file:close())
    return filename
end

local function write_file(path, contents)
    if platform.windows then path = path:gsub("\\", "/") end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and lfs.attributes(parent, "mode") ~= "directory" then
        local accum = path:sub(1, 1) == "/" and "" or "."
        for part in parent:gmatch("[^/]+") do
            accum = (accum == "" or accum == ".") and (accum == "" and ("/" .. part) or part)
                or (accum .. "/" .. part)
            if lfs.attributes(accum, "mode") ~= "directory" then
                lfs.mkdir(accum)
            end
        end
    end
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    assert(file:close())
    return contents
end

local function definition_parts(generated, symbol)
    local owners = {}
    for _, part in ipairs(generated.parts) do
        for line in coder_names._linkage_symbol_name(part.code):gmatch("[^\n]+") do
            if line:match("^%s*TITAN_MODULE_PRIVATE ")
                or line:match("^%s*TITAN_SOURCE_LOCAL ")
                or (line:find(symbol .. "(", 1, true) and line:match("{%s*$")) then
                if (line:find(symbol .. "(", 1, true)
                    or line:find(symbol .. "[]", 1, true))
                    and (line:find("{", 1, true) or line:find("=", 1, true)) then
                    owners[#owners + 1] = part.index
                end
            end
        end
    end
    return owners
end

local function file_exists(path)
    return lfs.symlinkattributes(path, "mode") == "file"
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "link" or mode == "file" then
        os.remove(path)
    elseif mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                remove_tree(path .. "/" .. entry)
            end
        end
        lfs.rmdir(path)
    end
end

local function run_cmd(argv, cwd)
    local previous = cwd and assert(lfs.currentdir()) or nil
    if cwd then assert(lfs.chdir(cwd)) end
    local ok, result = pcall(function()
        return io_strategy:run(argv, {
            stderr_to_stdout = true,
            -- Windows runtime outputs belong to its installed private SDK,
            -- not the checkout's Unix Makefile/runtime archive.
            env = platform.windows and { TITAN_ROOT = PREFIX } or nil,
        })
    end)
    if previous then assert(lfs.chdir(previous)) end
    assert.is_true(ok, tostring(result))
    local output = result.output or result.diagnostic or ""
    if platform.windows then output = output:gsub("\r\n", "\n") end
    return result.ok, output, result.why, result.status
end

local MULTI_CONSTRUCT_SOURCE = [[
record Point
    x: integer
    y: integer
end

function Point:sum(): integer
    return self.x + self.y
end

union Outcome
    ok(integer)
    err(string)
end

interface Measurable
    function measure(): integer
end

function Point:measure(): integer
    return self.x * 10 + self.y
end

base_offset: integer = 5

local function make_adder(delta: integer): function(integer): integer
    local captured = delta
    return function(input: integer): integer
        captured = captured + 1
        return input + captured
    end
end

function compute_alpha(a: integer, b: integer): integer
    local p = Point.new(a, b)
    local m: Measurable = p
    local adder = make_adder(base_offset)
    local adjusted: function(value): value = adder
    local res: integer = adjusted(m:measure()) as integer
    return res + p:sum()
end

function compute_beta(items: {integer}): integer
    local copy: {integer} = { 10, 20, 30 }
    local total = 0
    for i = 1, #items do
        total = total + items[i]
    end
    for i = 1, #copy do
        total = total + copy[i]
    end
    return total
end

function compute_gamma(flag: boolean): integer
    local choice = flag and Outcome.ok(42) or Outcome.err("nope")
    case choice
        when ok(v) then
            return v
        when err(msg) then
            return #msg
    end
end

do
    base_offset = 10
end
]]

describe("split generated C translation units (S1)", function()
    local workspace
    local saved_src, saved_out, saved_cc
    local saved_clang_format, cleanup_context

    before_each(function()
        saved_src = driver.TITAN_SOURCE_PATH
        saved_out = driver.OUTPUT_ROOT
        saved_cc = driver.CC
        saved_clang_format = driver.CLANG_FORMAT
        workspace = temporary.name("-split-units")
        os.remove(workspace)
        assert(lfs.mkdir(workspace))
        workspace = assert(io_strategy:realpath(workspace))
        if platform.windows then workspace = workspace:gsub("\\", "/") end
    end)

    after_each(function()
        driver.TITAN_SOURCE_PATH = saved_src
        driver.OUTPUT_ROOT = saved_out
        driver.CC = saved_cc
        driver.CLANG_FORMAT = saved_clang_format
        if cleanup_context then
            local context = cleanup_context
            cleanup_context = nil
            assert(driver.close_resolver_context(context))
        end
        h.with_resolver_context(nil, function(context)
            return driver.configure_foreign_c(context)
        end)
        if workspace then
            remove_tree(workspace)
            workspace = nil
        end
    end)

    local function check_module(modname, source, filename)
        h.reset(true)
        filename = filename or (modname:gsub("[.]", "/") .. ".titan")
        local ast, parse_err = parser.parse(filename, source)
        assert.truthy(ast, parse_err)
        local _, errors = checker.check(modname, ast, source, filename)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        return ast
    end

    it("produces identical single-TU text when splitting is disabled or below threshold", function()
        local ast_off = check_module("split_ident", MULTI_CONSTRUCT_SOURCE)
        local gen_off = coder.generate(
            "split_ident", ast_off, {}, driver.TITAN_ABI_VERSION, true, {
                c_parts = 1,
                split_threshold = 0,
            })
        assert.is_nil(gen_off.private_header)
        assert.equal(1, #gen_off.parts)
        assert.equal(0, gen_off.parts[1].index)
        assert.is_true(gen_off.parts[1].code_bytes > 0)

        local ast_below = check_module("split_ident", MULTI_CONSTRUCT_SOURCE)
        local gen_below = coder.generate(
            "split_ident", ast_below, {}, driver.TITAN_ABI_VERSION, true, {
                c_parts = 4,
                split_threshold = gen_off.parts[1].code_bytes + 1024,
            })
        assert.is_nil(gen_below.private_header)
        assert.equal(1, #gen_below.parts)
        assert.equal(0, gen_below.parts[1].index)
        assert.equal(gen_off.parts[1].code_bytes, gen_below.parts[1].code_bytes)
        assert.equal(gen_off.parts[1].code, gen_below.parts[1].code)
        assert.same(gen_off.private_symbols, gen_below.private_symbols)
    end)

    it("partitions above-threshold modules into dense parts with a private header and part-0 pinning", function()
        local ast = check_module("split_part", MULTI_CONSTRUCT_SOURCE)
        local gen = coder.generate(
            "split_part", ast, {}, driver.TITAN_ABI_VERSION, true, {
                c_parts = 4,
                split_threshold = 1,
                private_header_output = "split_part.priv.h",
            })
        assert.is_string(gen.private_header)
        assert.truthy(gen.private_header:sub(1, #coder.PRIVATE_HEADER_MARKER)
            == coder.PRIVATE_HEADER_MARKER)
        assert.equal(4, #gen.parts)
        local sum_bytes = 0
        for idx, part in ipairs(gen.parts) do
            assert.equal(idx - 1, part.index)
            assert.is_true(part.code_bytes > 0)
            sum_bytes = sum_bytes + part.code_bytes
            assert.truthy(part.code:find('#include "split_part.priv.h"', 1, true))
        end

        -- Part 0 owns protocol, metadata, init, preload, and resolver.
        local part0 = gen.parts[1].code
        assert.truthy(part0:find("TITAN_META_SECTION", 1, true))
        assert.truthy(part0:find("Udata *split_part_init(lua_State *L)", 1, true))
        assert.truthy(part0:find("int luaopen_split_part(lua_State *L)", 1, true))
        local pinned = {}
        for _, entry in ipairs(gen.private_symbols) do
            if entry.owner == "module preload helper"
                or entry.owner == "module native symbol resolver"
                or entry.owner == "function type tag 0" then
                assert.same({ 0 }, definition_parts(gen, entry.symbol), entry.owner)
                pinned[entry.owner] = true
            end
        end
        assert.same({
            ["module preload helper"] = true,
            ["module native symbol resolver"] = true,
            ["function type tag 0"] = true,
        }, pinned)
        assert.truthy(part0:find("split_part_module_identity(void)", 1, true))

        for i = 2, #gen.parts do
            local side = gen.parts[i].code
            assert.is_nil(side:find("TITAN_META_SECTION", 1, true))
            assert.is_nil(side:find("Udata *split_part_init(lua_State *L)", 1, true))
            assert.is_nil(side:find("int luaopen_split_part(lua_State *L)", 1, true))
            assert.is_nil(side:find("split_part_module_identity(void)", 1, true))
        end
    end)

    it("keeps one callback address across parts and pointer-keyed registration", function()
        local header = workspace .. "/identity.h"
        write_file(header, [[
typedef int (*identity_callback)(int);
static inline void identity_register(identity_callback *slot, identity_callback cb) {
    *slot = cb;
}
static inline int identity_unregister(identity_callback *slot, identity_callback cb) {
    if (*slot != cb) return 0;
    *slot = 0;
    return 1;
}
]])
        local source = string.format([[
foreign import %q
local foreign function callback(input: int): int return input + 1 end
function pointer_one(): foreign function(int): int return callback end
function pointer_two(): foreign function(int): int return callback end
function register_one(slot: foreign *identity_callback)
    ffi.identity_register(slot, callback)
end
function unregister_two(slot: foreign *identity_callback): boolean
    return ffi.identity_unregister(slot, callback) ~= 0
end
function exercise(): boolean
    local slot = foreign identity_callback.new_array(1)
    register_one(slot)
    return pointer_one() == pointer_two() and unregister_two(slot)
end
]], header)
        for _, count in ipairs({ 1, 8 }) do
            local stem = workspace .. "/identity" .. count
            local ast = check_module("identity", source, stem .. ".titan")
            local generated = coder.generate("identity", ast, {},
                driver.TITAN_ABI_VERSION, true, { c_parts = count, split_threshold = 1 })
            if count == 1 then
                local below = coder.generate("identity", ast, {},
                    driver.TITAN_ABI_VERSION, true, {
                        c_parts = 8, split_threshold = generated.parts[1].code_bytes + 1,
                    })
                assert.equal(generated.parts[1].code, below.parts[1].code)
            end
            if count > 1 then
                local one = definition_parts(generated,
                    coder_names._linkage_symbol_name(coder_names._foreign_func_name("identity", "pointer_one")))
                local two = definition_parts(generated,
                    coder_names._linkage_symbol_name(coder_names._foreign_func_name("identity", "pointer_two")))
                assert.equal(1, #one)
                assert.equal(1, #two)
                assert.is_true(one[1] ~= two[1], "pointer producers must occupy different parts")
            end
            local ok, err, _, _, objects = driver.compile("identity", ast,
                stem .. ".titan", {}, false, { c_parts = count, split_threshold = 1 })
            assert.truthy(ok, err)
            local dso = stem .. (platform.windows and ".dll" or ".so")
            assert(driver.compile_library_output(dso, objects, nil, false,
                nil, {}, nil, dso, platform.windows and { "identity" } or nil))
            local script = workspace .. "/check_identity.lua"
            write_file(script, string.format([[
local open = assert(package.loadlib(%q, "luaopen_identity"))
local module = open()
assert(module.pointer_one() == module.pointer_two())
assert(module.exercise())
]], dso))
            local ran, output = run_cmd({ LUA, "-E", script })
            assert.truthy(ran, output)
        end
    end)

    it("preflights every actual side output and cross-request aliases before mutation", function()
        if platform.windows then pending("POSIX symlink/hardlink creation fixture"); return end
        local stem = workspace .. "/aliases"
        local path = stem .. ".titan"
        write_file(path, MULTI_CONSTRUCT_SOURCE)
        local function compile()
            local ast = check_module("aliases", MULTI_CONSTRUCT_SOURCE, path)
            return driver.compile("aliases", ast, path, {}, false,
                { c_parts = 4, split_threshold = 1 })
        end
        assert(compile())
        local old_c, old_o = read_file(stem .. ".c"), read_file(stem .. ".o")
        for _, suffix in ipairs({ ".part1.c", ".part1.o", ".priv.h" }) do
            local saved = read_file(stem .. suffix)
            assert(os.remove(stem .. suffix))
            assert(lfs.link(path, stem .. suffix, true))
            local ok, err = compile()
            assert.is_nil(ok)
            assert.is_string(err)
            assert.equal(MULTI_CONSTRUCT_SOURCE, read_file(path))
            assert.equal(old_c, read_file(stem .. ".c"))
            assert.equal(old_o, read_file(stem .. ".o"))
            assert(os.remove(stem .. suffix))
            write_file(stem .. suffix, saved)
        end
        local staged_input = workspace .. "/stage-input.h"
        write_file(staged_input, "staging input sentinel")
        local stage_ast = check_module("aliases", MULTI_CONSTRUCT_SOURCE, path)
        local reserve = driver.sibling_temporary_path
        driver.sibling_temporary_path = function(destination, ...)
            if destination:find(".ffi.h.format", 1, true) then
                return staged_input:gsub("[.]h$", "")
            end
            return reserve(destination, ...)
        end
        local called, staged_ok, staged_error = pcall(driver.compile, "aliases",
            stage_ast, path, {}, false, {
                c_parts = 4, split_threshold = 1, native_inputs = { staged_input },
            })
        driver.sibling_temporary_path = reserve
        assert.truthy(called, staged_ok)
        assert.is_nil(staged_ok)
        assert.matches("aliases input", staged_error, 1, true)
        assert.equal("staging input sentinel", read_file(staged_input))
        assert.equal(old_c, read_file(stem .. ".c"))
        assert.equal(old_o, read_file(stem .. ".o"))
        local input = workspace .. "/native-input.o"
        write_file(input, "input sentinel")
        assert(os.remove(stem .. ".part1.o"))
        assert(lfs.link(input, stem .. ".part1.o"))
        local ast = check_module("aliases", MULTI_CONSTRUCT_SOURCE, path)
        local results = driver.compile_modules({ {
            modname = "aliases", mod = { ast = ast, filename = path },
            options = { c_parts = 4, split_threshold = 1, native_inputs = { input } },
        } }, 1, false)
        assert.is_nil(results[1].ok)
        assert.matches("aliases input", results[1].err, 1, true)
        assert.equal("input sentinel", read_file(input))
        assert.equal(old_o, read_file(stem .. ".o"))
        assert(os.remove(stem .. ".part1.o"))
        local saved_part = read_file(stem .. ".part2.o")
        assert(os.remove(stem .. ".part2.o"))
        assert(lfs.mkdir(stem .. ".part2.o"))
        local rejected, kind_error = compile()
        assert.is_nil(rejected)
        assert.matches("regular nonlink file", kind_error, 1, true)
        assert.equal(old_o, read_file(stem .. ".o"))
        assert(lfs.rmdir(stem .. ".part2.o"))
        write_file(stem .. ".part2.o", saved_part)
        local left = check_module("left", MULTI_CONSTRUCT_SOURCE, path)
        local right_path = stem .. ".part1.titan"
        local right = check_module("right", MULTI_CONSTRUCT_SOURCE, right_path)
        results = driver.compile_modules({
            { modname = "left", mod = { ast = left, filename = path },
              options = { c_parts = 4, split_threshold = 1 } },
            { modname = "right", mod = { ast = right, filename = right_path },
              options = { c_parts = 1 } },
        }, 2, false)
        assert.is_nil(results[1].ok)
        assert.matches("aliases output", results[1].err, 1, true)
        assert.equal(old_o, read_file(stem .. ".o"))
    end)

    it("preserves authored headers that alias final program or provider outputs", function()
        local frontend = cli_frontend(workspace .. "/reject_frontend.lua", [[
require("titan-compiler.driver").compile_modules = function()
    error("generated compilation must not start after a preflight collision")
end
require("titan-compiler.process").start_worker = function()
    error("build workers must not start after a preflight collision")
end
]])
        for index, kind in ipairs({ "executable", "provider" }) do
            local src, out = workspace .. "/final-src" .. index, workspace .. "/final-out" .. index
            local is_program = kind == "executable"
            local name = is_program and "app" or "library"
            local provider = assert(driver.provider_output_path(name, out))
            local header
            if kind == "executable" then
                header = platform.windows
                    and assert(driver.windows_program_paths("app", nil, nil, out)).executable
                    or out .. "/app"
            else header = provider end
            local contents = "#define R2_HEADER_VALUE 7\n"
            write_file(header, contents)
            local declaration = is_program
                and "function main(args: {string}): integer return ffi.R2_HEADER_VALUE - 7 end\n"
                or "function result(): integer return ffi.R2_HEADER_VALUE end\n"
            write_file(src .. "/" .. name .. ".titan",
                string.format("foreign import %q\n", header) .. declaration)
            write_file(out .. "/" .. name .. ".c", "previous generated C")
            write_file(out .. "/" .. name .. ".o", "previous object")
            local ok, output = run_cmd({ LUA, "-E", frontend, "--tree", src,
                "-o", out, "--c-parts", "4", name })
            assert.is_false(ok, output)
            assert.truthy(output:find("aliases input", 1, true), output)
            assert.equal(contents, read_file(header))
            assert.equal("previous generated C", read_file(out .. "/" .. name .. ".c"))
            assert.equal("previous object", read_file(out .. "/" .. name .. ".o"))
            assert.is_false(file_exists(out .. "/" .. name .. ".ffi.h"))
        end
    end)

    it("protects a cached module's authored header from a fresh module's split output", function()
        local src, out = workspace .. "/cached-src", workspace .. "/cached-out"
        local header = out .. "/b.part1.c"
        local contents = "#define R2_CACHED_VALUE 7\n"
        write_file(header, contents)
        write_file(src .. "/a.titan", string.format([[
foreign import %q
function read_value(): integer return ffi.R2_CACHED_VALUE end
]], header))
        local hit_log = workspace .. "/cached-observed"
        -- The frontend is a certified compiler input: keep both its path and
        -- bytes identical between the producer build and collision attempt.
        local frontend = cli_frontend(workspace .. "/cache_frontend.lua", string.format([[
local driver = require("titan-compiler.driver")
local preflight = assert(driver.preflight_build_outputs)
driver.preflight_build_outputs = function(context, plan, ...)
    if plan.modules.b then
        local cached = assert(plan.modules.a, "module a must be part of the source link set")
        assert(cached.certified and cached.certified.status == "hit",
            "module a must be certified before collision preflight")
        local file = assert(io.open(%q, "wb"))
        assert(file:write("cached"))
        assert(file:close())
        driver.compile_modules = function() error("generated compilation must not start") end
        require("titan-compiler.process").start_worker = function()
            error("build workers must not start after a preflight collision")
        end
    end
    return preflight(context, plan, ...)
end
]], hit_log))
        local ok, output = run_cmd({ LUA, "-E", frontend, "--tree", src,
            "-o", out, "--c-parts", "4", "-c", "a" })
        assert.truthy(ok, output)
        local inventory = assert(objectmetadata.read(read_file(out .. "/a.o"), out .. "/a.o"))
        local snapshots = { [header] = contents }
        for _, part in ipairs(inventory.object_metadata.parts) do
            for _, suffix in ipairs({ part.c_suffix, part.object_suffix }) do
                local path = out .. "/a" .. suffix
                snapshots[path] = read_file(path)
            end
        end
        for _, suffix in ipairs({ ".ffi.h" }) do
            snapshots[out .. "/a" .. suffix] = read_file(out .. "/a" .. suffix)
        end
        write_file(src .. "/b.titan", 'local a = import "a"\n'
            .. MULTI_CONSTRUCT_SOURCE:gsub("do\n%s+base_offset = 10\nend", [[
function main(args: {string}): integer return a.read_value() - 7 end
do base_offset = 10 end
]]))
        for _, suffix in ipairs({ ".c", ".o" }) do
            local path = out .. "/b" .. suffix
            snapshots[path] = "previous b" .. suffix
            write_file(path, snapshots[path])
        end
        ok, output = run_cmd({ LUA, "-E", frontend, "--tree", src, "-o", out,
            "--c-parts", "4", "--incremental", "b" })
        assert.is_false(ok, output)
        assert.truthy(output:find("aliases input", 1, true), output)
        assert.equal("cached", read_file(hit_log))
        for path, previous in pairs(snapshots) do assert.equal(previous, read_file(path), path) end
        assert.is_false(file_exists(out .. "/b.ffi.h"))
    end)

    -- Pre-marker compilers emitted the same units without the generated-C
    -- marker line. Split units included their private header by the absolute
    -- path they were generated at, so a moved output tree retains the old one.
    local function legacy_program(name)
        local src = workspace .. "/" .. name .. "-src"
        local frontend = cli_frontend(workspace .. "/" .. name .. "-frontend.lua")
        write_file(src .. "/legacy.titan", MULTI_CONSTRUCT_SOURCE)
        local function cli(out, parts)
            return run_cmd({ LUA, "-E", frontend, "--tree", src, "-o", out,
                "--c-parts", tostring(parts), "-c", "legacy" })
        end
        return src, cli
    end

    local function assert_legacy_upgrade(newline)
        local src, cli = legacy_program("legacy")
        local marker = driver.GENERATED_C_MARKER
        local function unit_names(out)
            local names = {}
            for entry in lfs.dir(out) do
                if entry == "legacy.c" or entry:match("^legacy%.part%d+%.c$") then
                    names[#names + 1] = entry
                end
            end
            table.sort(names)
            return names
        end
        local function build_legacy(out, parts, anchor_lines)
            local ok, output = cli(out, parts)
            assert.truthy(ok, output)
            local names = unit_names(out)
            assert.equal(parts, #names)
            for _, name in ipairs(names) do
                local filename = out .. "/" .. name
                local contents = read_file(filename)
                -- Exercise native text-mode generated output on either host
                -- while writing the emulated legacy bytes in binary mode.
                contents = contents:gsub("\r\n", "\n")
                if newline == "\r\n" then contents = contents:gsub("\n", newline) end
                assert.equal(marker, contents:sub(1, #marker), filename)
                -- Pre-marker compilers also had no generated-C filename macro.
                contents = contents:gsub("^[^\n]*\n", "", 1)
                    :gsub('^#define[ \t]+TITAN_GENERATED_C_FILE[ \t]+"[^"\r\n]*"\r?\n', "", 1)
                if anchor_lines then
                    contents = assert(coverage_lines.convert(contents, filename))
                end
                write_file(filename, contents)
            end
            return names
        end
        local function private_include(filename)
            local contents = read_file(filename)
            if contents:sub(1, #marker) == marker then
                contents = contents:gsub("^[^\n]*\n", "", 1)
            end
            contents = contents:gsub(
                '^#define[ \t]+TITAN_GENERATED_C_FILE[ \t]+"[^"\r\n]*"\r?\n', "", 1)
            return assert(contents:match('^#include "([^"\r\n]*)"'))
        end
        local revision = 0
        local function rebuild(out, parts, names)
            revision = revision + 1
            write_file(src .. "/legacy.titan", (MULTI_CONSTRUCT_SOURCE:gsub("\ndo\n",
                "\nfunction legacy_revision(): integer return " .. revision .. " end\n\ndo\n", 1)))
            local ok, output = cli(out, parts)
            assert.truthy(ok, output)
            for _, name in ipairs(names) do
                assert.equal(marker, read_file(out .. "/" .. name):sub(1, #marker), name)
            end
        end

        local same = workspace .. "/legacy-same"
        local names = build_legacy(same, 4)
        for _, name in ipairs(names) do
            local header = private_include(same .. "/" .. name)
            assert.equal("/legacy-same/legacy.priv.h", header:sub(-#"/legacy-same/legacy.priv.h"))
        end
        rebuild(same, 4, names)

        local old, moved = workspace .. "/legacy-old", workspace .. "/legacy-moved"
        names = build_legacy(old, 4)
        assert(os.rename(old, moved))
        for _, name in ipairs(names) do
            local header = private_include(moved .. "/" .. name)
            assert.equal("/legacy-old/legacy.priv.h", header:sub(-#"/legacy-old/legacy.priv.h"))
        end
        rebuild(moved, 4, names)
        for _, name in ipairs(names) do
            local header = private_include(moved .. "/" .. name)
            assert.equal("/legacy-moved/legacy.priv.h", header:sub(-#"/legacy-moved/legacy.priv.h"))
        end

        local anchored = workspace .. "/legacy-anchored"
        names = build_legacy(anchored, 1, true)
        assert.truthy(read_file(anchored .. "/legacy.c"):find(
            '#line %d+ "[^\n]*"\nstatic TITAN_UNUSED inline int '))
        rebuild(anchored, 1, names)
    end

    for _, newline in ipairs({ "LF", "CRLF" }) do
        it("upgrades same-path, moved and coverage-anchored pre-marker generated C with " .. newline, function()
            assert_legacy_upgrade(newline == "LF" and "\n" or "\r\n")
        end)
    end

    it("refuses authored and unproven split-shaped C at reserved C outputs", function()
        local _, cli = legacy_program("refuse")
        local out = workspace .. "/refuse-out"
        local push = "\n\n#if defined(__ELF__)\n#pragma GCC visibility push(protected)\n#endif\n" ..
            "int legacy_authored;\n"
        for _, case in ipairs({
            { "legacy.c", "int legacy_authored(void) { return 1; }\n" },
            -- A split-shaped unit from another directory is owned only beside a
            -- marker-owned private header whose leaf it names by absolute path.
            { "legacy.part1.c", '#include "' .. workspace .. '/elsewhere/legacy.priv.h"' .. push },
            { "legacy.part1.c", '#include "' .. workspace .. '/elsewhere/other.priv.h"' .. push, true },
            { "legacy.part1.c", '#include "legacy.priv.h"' .. push, true },
        }) do
            remove_tree(out)
            local filename = out .. "/" .. case[1]
            write_file(filename, case[2])
            if case[3] then
                write_file(out .. "/legacy.priv.h", driver.PRIVATE_HEADER_MARKER .. "\n")
            end
            local ok, output = cli(out, 4)
            assert.falsy(ok, output)
            assert.truthy(output:find("(not compiler-generated C;", 1, true), output)
            assert.equal(case[2], read_file(filename))
            assert.is_false(file_exists(out .. "/legacy.o"))
            assert.is_false(file_exists(out .. "/legacy.ffi.h"))
        end
    end)

    it("renders, writes and formats each CLI header once and releases materialized C", function()
        local log_path, format_log = workspace .. "/header_calls", workspace .. "/header_formats"
        local formatter = workspace .. "/header_formatter.lua"
        write_file(formatter, string.format([[
local file = assert(io.open(%q, "ab"))
assert(file:write(arg[#arg], "\n"))
assert(file:close())
]], format_log))
        local formatter_command = assert(cdriver.shell_quote(LUA)) .. " " .. assert(cdriver.shell_quote(formatter))
        local worker = workspace .. "/header_worker.lua"
        write_file(worker, string.format([[
local function main()
local driver = require("titan-compiler.driver")
local coder = require("titan-compiler.coder")
local function record(name)
    local file = assert(io.open(%q, "ab"))
    assert(file:write(name, "\n"))
    assert(file:close())
end
for _, name in ipairs({ "generate_ffi_header", "generate_foreign_header" }) do
    local generate = coder[name]
    coder[name] = function(...)
        -- The checker owns a separate relative-include probe header. Count it
        -- separately from the final output-tree header whose plan is shared.
        record(name == "generate_foreign_header" and select(4, ...) ~= nil
            and "checking_foreign_header" or name)
        return generate(...)
    end
end
local write_headers = driver.write_foreign_header_plans
driver.write_foreign_header_plans = function(...)
    record("write_headers")
    return write_headers(...)
end
local generated = setmetatable({}, { __mode = "v" })
local generate, serial = coder.generate, 0
coder.generate = function(...)
    local result = generate(...)
    serial = serial + 1
    generated[serial] = result
    return result
end
local compile = driver.compile_modules
driver.compile_modules = function(...)
    local results = compile(...)
    collectgarbage("collect")
    assert(next(generated) == nil, "materialized plans retain generated C")
    return results
end
driver.CLANG_FORMAT = %q
require("titan-compiler.build_worker").main()
end
return { main = main }
]], log_path, formatter_command))
        local frontend = cli_frontend(workspace .. "/header_frontend.lua", string.format([[
package.path = %q .. "/?.lua;" .. package.path
require("titan-compiler.build").WORKER_ENTRY = "header_worker"
require("titan-compiler.driver").CLANG_FORMAT = %q
]], workspace, formatter_command))
        local src, out = workspace .. "/once-src", workspace .. "/once-out"
        write_file(src .. "/once.titan", [[
foreign function plus_one(input: int): int return input + 1 end
function call(input: integer): integer return plus_one(input) end
]])
        local ok, output = run_cmd({ LUA, "-E", frontend, "--tree", src,
            "-o", out, "--c-parts", "4", "--pretty-print", "-c", "once" })
        assert.truthy(ok, output)
        local counts = {}
        for name in read_file(log_path):gmatch("[^\n]+") do counts[name] = (counts[name] or 0) + 1 end
        assert.same({
            generate_ffi_header = 1, generate_foreign_header = 1,
            checking_foreign_header = 1, write_headers = 1,
        }, counts)
        local ffi_count, foreign_count = 0, 0
        for path in read_file(format_log):gmatch("[^\n]+") do
            if path:find(".ffi.h.format.", 1, true) then ffi_count = ffi_count + 1 end
            if path:find(".titan.h.format.", 1, true) then foreign_count = foreign_count + 1 end
        end
        assert.equal(1, ffi_count)
        assert.equal(1, foreign_count)
    end)

    it("aggregates plain nm definitions and undefined weak references across parts", function()
        local path = workspace .. "/symbols.titan"
        write_file(path, MULTI_CONSTRUCT_SOURCE)
        local ast = check_module("symbols", MULTI_CONSTRUCT_SOURCE, path)
        local ok, err, primary = driver.compile("symbols", ast, path, {}, false,
            { c_parts = 2, split_threshold = 1 })
        assert.truthy(ok, err)
        local symbols = module_symbols.collect(primary, function(argv)
            assert.equal("fixture-nm", argv[1])
            assert.equal(2, #argv)
            local side = argv[2]:find(".part1.o", 1, true) ~= nil
            if side then
                return true, [[00000000 T _internal
00000000 W _weak_function
00000000 V _weak_object
00000000 u _unique_object
00000000 w _weak_defined_function
00000000 v _weak_defined_object
00000000 ? _unknown_addressed
         ? _unknown_bare
         U _entry
         U _external_macho
         w _weak_external_function
         v _weak_external_object
]]
            end
            return true, [[00000000 T _entry
         U _internal
         U _external_elf
         U _weak_function
         U _weak_object
         U _unique_object
symbols.o:
nm: no symbols
]]
        end, { "fixture-nm" })
        assert.equal(2, #symbols.objects)
        assert.same({
            _entry = true, _internal = true, _weak_function = true,
            _weak_object = true, _unique_object = true,
            _weak_defined_function = true, _weak_defined_object = true,
        }, symbols.defined)
        assert.same({
            _external_macho = true, _external_elf = true,
            _weak_external_function = true, _weak_external_object = true,
        }, symbols.undefined)
    end)

    it("rejects private inventory collisions without writing or launching a compiler", function()
        if platform.windows then pending("POSIX compiler launch sentinel"); return end
        local requests = {}
        for _, name in ipairs({ "left", "right" }) do
            local path = workspace .. "/" .. name .. ".titan"
            write_file(path, MULTI_CONSTRUCT_SOURCE)
            requests[#requests + 1] = {
                modname = name,
                mod = { filename = path, ast = check_module(name, MULTI_CONSTRUCT_SOURCE, path) },
                options = { c_parts = 4, split_threshold = 1 },
            }
            write_file(workspace .. "/" .. name .. ".c", "old C")
            write_file(workspace .. "/" .. name .. ".o", "old object")
        end
        local generate, compiler = coder.generate, driver.CC
        local launched, wrapper = workspace .. "/launched", workspace .. "/compiler.sh"
        write_file(wrapper, "#!/bin/sh\n: > " .. launched .. "\nexit 1\n")
        assert(run_cmd({ "chmod", "+x", wrapper }))
        driver.CC = wrapper
        coder.generate = function(...)
            local generated = generate(...)
            generated.private_symbols[#generated.private_symbols + 1] = {
                symbol = "injected_shared_identity", owner = "injected owner",
            }
            return generated
        end
        local called, results = pcall(driver.compile_modules, requests, 2, false)
        coder.generate, driver.CC = generate, compiler
        assert.truthy(called, results)
        assert.is_nil(results[1].ok)
        assert.matches("cannot link C symbol", results[1].err, 1, true)
        assert.is_false(file_exists(launched))
        for _, name in ipairs({ "left", "right" }) do
            assert.equal("old C", read_file(workspace .. "/" .. name .. ".c"))
            assert.equal("old object", read_file(workspace .. "/" .. name .. ".o"))
            assert.is_false(file_exists(workspace .. "/" .. name .. ".ffi.h"))
        end
    end)

    local function prepare_split_program()
        local src = workspace .. "/program-src"
        local frontend = cli_frontend(workspace .. "/frontend.lua")
        write_file(src .. "/pkg/library.titan", MULTI_CONSTRUCT_SOURCE)
        write_file(src .. "/app.titan", [[
local lib = import "pkg.library"
function main(args: {string}): integer
    if lib.compute_alpha(2, 3) == 39 and lib.compute_beta({1, 2}) == 63
        and lib.compute_gamma(true) == 42 then return 0 end
    return 1
end
]])
        local function cli(out, extra, root, path)
            local argv = { "env", "TITAN_PATH_0_6=" .. (path or PREFIX .. "/lib/titan/0.6") .. ";;",
                LUA, "-E", frontend, "--tree", src, "-o", out, "--c-parts", "4" }
            if extra then argv[#argv + 1] = extra end
            argv[#argv + 1] = root
            local ok, output = run_cmd(argv)
            assert.truthy(ok, output)
        end
        return src, cli
    end

    it("links and runs source-split programs", function()
        local _, cli = prepare_split_program()
        local source_out = workspace .. "/source-out"
        cli(source_out, nil, "app")
        local record = assert(objectmetadata.read(read_file(source_out .. "/pkg/library.o"),
            source_out .. "/pkg/library.o"))
        assert.equal(4, #record.object_metadata.parts)
        local ok, output = run_cmd({ source_out .. (platform.windows and "/bin/app.exe" or "/app") })
        assert.truthy(ok, output)
    end)

    it("extracts split archive members with --static", function()
        if platform.windows then
            pending("Windows supports DLL providers, not --static archive extraction")
            return
        end
        local src, cli = prepare_split_program()
        local provider_out, static_out = workspace .. "/provider-out", workspace .. "/static-out"
        cli(provider_out, nil, "pkg.library")
        local archive = provider_out .. "/pkg/library.a"
        local listed, members = run_cmd({ "ar", "t", archive })
        assert.truthy(listed, members)
        assert.truthy(members:find("library.part1.o", 1, true), members)
        assert(os.rename(src .. "/pkg/library.titan", src .. "/pkg/library.saved"))
        cli(static_out, "--static", "app", provider_out)
        assert(os.rename(provider_out .. "/pkg/library.so", provider_out .. "/pkg/library.hidden"))
        local ok, output = run_cmd({ static_out .. "/app" })
        assert.truthy(ok, output)
    end)

    it("applies CLI/environment/default precedence and preflights compile-only, library and program outputs", function()
        local frontend = cli_frontend(workspace .. "/frontend.lua")
        write_file(workspace .. "/cli.titan", MULTI_CONSTRUCT_SOURCE)
        local function cli(out, environment, options)
            local argv = { "env" }
            if environment then argv[#argv + 1] = "TITAN_C_PARTS=" .. environment
            else argv[#argv + 1], argv[#argv + 2] = "-u", "TITAN_C_PARTS" end
            for _, item in ipairs({ LUA, "-E", frontend, "--tree", workspace, "-o", out }) do
                argv[#argv + 1] = item
            end
            for _, item in ipairs(options) do argv[#argv + 1] = item end
            argv[#argv + 1] = "cli"
            return run_cmd(argv)
        end
        for index, case in ipairs({
            { "8", { "-c", "--c-parts", "2" }, 2 },
            { "2", { "-c" }, 2 },
            { false, { "-c" }, driver.default_c_parts() },
            { "invalid", { "-c", "--c-parts", "1" }, 1 },
        }) do
            local out = workspace .. "/precedence" .. index
            local ok, output = cli(out, case[1], case[2])
            assert.truthy(ok, output)
            local entry = assert(objectmetadata.read(read_file(out .. "/cli.o"), out .. "/cli.o"))
            assert.equal(case[3], entry.object_metadata.c_parts)
        end
        local sentinel_out = workspace .. "/sentinel"
        local sentinel_c, sentinel_o = sentinel_out .. "/cli.part99.c", sentinel_out .. "/cli.part99.o"
        write_file(sentinel_c, "int split_external_sentinel(void) { return 99; }\n")
        local command = assert(cdriver.split_shell_words(driver.CC))
        for _, arg in ipairs({ "-fPIC", "-c", sentinel_c, "-o", sentinel_o }) do
            command[#command + 1] = arg
        end
        local built, diagnostic = run_cmd(command)
        assert.truthy(built, diagnostic)
        local sentinel_bytes = read_file(sentinel_o)
        local linked, link_output = cli(sentinel_out, "4",
            { "--c-parts", "1", "-X", sentinel_o, "--" })
        assert.truthy(linked, link_output)
        assert.equal(sentinel_bytes, read_file(sentinel_o))
        assert.equal("int split_external_sentinel(void) { return 99; }\n", read_file(sentinel_c))
        write_file(workspace .. "/cli.titan", MULTI_CONSTRUCT_SOURCE .. [[
function main(args: {string}): integer return 0 end
]])
        local out = workspace .. "/reject-program"
        write_file(out .. "/cli.priv.h", "user header")
        local ok = cli(out, "4", { "--c-parts", "4" })
        assert.is_false(ok)
        assert.equal("user header", read_file(out .. "/cli.priv.h"))
        assert.is_false(file_exists(out .. "/cli.c"))
        if not platform.windows then
            local target = workspace .. "/cli.titan"
            os.remove(out .. "/cli.priv.h")
            assert(lfs.link(target, out .. "/cli.part1.c", true))
            ok = cli(out, "4", { "-c", "--c-parts", "4" })
            assert.is_false(ok)
            assert.truthy(read_file(target):find("function main", 1, true))
            assert.is_false(file_exists(out .. "/cli.c"))
        end
    end)

    it("compiles, links, and runs split modules with identical behavior and public symbols to unsplit", function()
        local header_path = workspace .. "/raw_math.h"
        write_file(header_path, [[
#ifndef RAW_MATH_H
#define RAW_MATH_H
static inline int c_scale(int x, int factor) {
    return x * factor;
}
#endif
]])
        local dep_src = string.format([[
foreign import %q

record SharedBox
    value: integer
end

local function private_Step(x: integer): integer
    return x + 3
end

function make_box(v: integer): SharedBox
    return SharedBox.new(private_Step(v))
end

foreign function raw_triple(x: int): int
    return ffi.c_scale(x, 3)
end
local foreign function imported_callback(x: int): int
    return x + 9
end
]], header_path)

        local main_src = [[
local dep = import "pkg.dep.titan"
local transfer = import "transfer"
local protobuf = import "protobuf"
local reflect = import "reflect"

record Payload
    count: integer
    label: string
end

function Payload:format(): string
    return self.label .. ":" .. self.count
end

union Status
    ready(Payload)
    empty()
end

interface Formatter
    function format(): string
end

local function make_counter(seed: integer): function(integer): integer
    local acc = seed
    return function(step: integer): integer
        acc = acc + step
        return acc
    end
end

function exercise_all(base: integer): (integer, string, boolean)
    local box = dep.make_box(base)
    local tripled = dep.raw_triple(box.value as foreign int) as integer
    local c = make_counter(tripled)
    local widened: function(value): value = c
    local after_calls: integer = (widened(4) as integer) + (widened(6) as integer)
    local p = Payload.new(after_calls, "sum")
    local fmt: Formatter = p
    local st = Status.ready(p)
    local arr: {integer} = { base, tripled, after_calls }
    local matched = false
    case st
        when ready(inner) then
            matched = (inner.count == arr[3])
        when empty() then
            matched = false
    end
    return after_calls, fmt:format(), matched
end

function imported_pointer_one(): foreign function(int): int return dep.imported_callback end
function imported_pointer_two(): foreign function(int): int return dep.imported_callback end
function imported_callback_identity(): boolean
    return imported_pointer_one() == imported_pointer_two()
end

function exercise_metadata(): boolean
    local counter = make_counter(10)
    local packet = transfer.encode_message(counter)
    defer transfer.discard_message(packet)
    local restored: function(integer): integer = transfer.decode_message(packet)
    if counter(2) ~= 12 or restored(3) ~= 13 then return false end
    local original = Payload.new(restored(4), "codec")
    local encoded = protobuf.serialize(original)
    local decoded: Payload = protobuf.deserialize_nominal(encoded, "pkg.main.Payload", false)
    if decoded.count ~= 17 or decoded.label ~= "codec" then return false end
    case reflect.inspect(decoded)
        when is_record(view) then
            if view.n_fields ~= 2 or view:get(1) ~= 17 then return false end
            view:set(2, "reflected")
        else
            return false
    end
    return decoded:format() == "reflected:17"
end
]]

        local function build_variant(subdir, c_parts, threshold)
            h.reset(true)
            local dir = workspace .. "/" .. subdir
            local src_dir = dir .. "/src"
            local out_dir = dir .. "/out"
            write_file(src_dir .. "/pkg/dep.titan", dep_src)
            write_file(src_dir .. "/pkg/main.titan", main_src)

            local context = driver.new_resolver_context({
                output_root = out_dir,
            })
            assert(driver.configure_foreign_c(context))
            local prev_src = driver.TITAN_SOURCE_PATH
            local prev_out = driver.OUTPUT_ROOT
            driver.TITAN_SOURCE_PATH = src_dir
            driver.OUTPUT_ROOT = assert(driver.prepare_output_root(out_dir))
            local loader = driver.defaultloader({}, {
                source_roots = { ["pkg.dep"] = true, ["pkg.main"] = true },
                context = context,
                output_root = driver.OUTPUT_ROOT,
                c_parts = c_parts,
                split_threshold = threshold,
            })
            for _, name in ipairs({ "pkg.dep", "pkg.main" }) do
                local modtype, errors = checker.checkimport(name, loader)
                assert.truthy(modtype, errors)
                assert.equal(0, #errors, table.concat(errors, "\n"))
            end
            local finalized, errors = driver.finalize_resolver_context(context)
            assert.truthy(finalized, errors and table.concat(errors, "\n"))
            local linked_names = {}
            for name in pairs(context.source_names) do
                linked_names[#linked_names + 1] = name
            end
            table.sort(linked_names)
            assert.same({ "pkg.dep", "pkg.main" }, linked_names)
            local plans = assert(driver.plan_foreign_headers(linked_names, driver.imported))
            assert(driver.write_foreign_header_plans(plans, false, false))

            local requests = {}
            for _, name in ipairs(linked_names) do
                requests[#requests + 1] = {
                    modname = name,
                    mod = driver.imported[name],
                    static_deps = context.native_static_names,
                    options = {
                        nominal_layouts = context.nominal_layouts,
                        c_parts = c_parts,
                        split_threshold = threshold,
                    },
                }
            end
            local results = driver.compile_modules(requests, 2, false)
            for idx, res in ipairs(results) do
                assert.is_true(res.ok, res.err)
                assert.is_table(res.objects, "missing objects list for request " .. idx)
            end

            local gen_objs = {}
            local ofiles = {}
            for _, name in ipairs(linked_names) do
                local mod = driver.imported[name]
                gen_objs[#gen_objs + 1] = {
                    modname = name,
                    filename = mod.compiled,
                    objects = mod.compiled_objects,
                }
                for _, obj in ipairs(mod.compiled_objects) do
                    ofiles[#ofiles + 1] = obj
                end
            end
            local target = assert(driver.derive_target_fingerprint(
                gen_objs[1].filename, gen_objs[1].modname))
            assert(driver.validate_generated_objects(gen_objs, target))

            local provider_out = assert(
                driver.provider_output_path("pkg", driver.OUTPUT_ROOT))
            local dso_path = provider_out
            assert(driver.compile_library_output(
                dso_path, ofiles, nil, false, nil, {}, nil, dso_path,
                platform.windows and linked_names or nil))
            local archive_path
            if not platform.windows then
                archive_path = dso_path:gsub("[.]so$", ".a")
                local archive_res, archive_err = driver.build_static_archive(
                    archive_path, ofiles,
                    nil, target, false)
                assert.truthy(archive_res, archive_err)
                local val_so = dir .. "/archive-val.so"
                assert(driver.compile_archive_validation_image(
                    val_so, archive_path, nil, false, nil, nil))
                assert(driver.validate_library_image(val_so, linked_names))
                assert(driver.validate_archive_library_equality(
                    archive_res.archive, val_so, linked_names, "split archive validation"))
                os.remove(val_so)
            end

            driver.TITAN_SOURCE_PATH = prev_src
            driver.OUTPUT_ROOT = prev_out
            assert(driver.close_resolver_context(context))
            return {
                out_dir = out_dir,
                dso = dso_path,
                archive = archive_path,
                dep_objects = driver.module_compiled_objects(driver.imported["pkg.dep"]),
                main_objects = driver.module_compiled_objects(driver.imported["pkg.main"]),
                module_names = linked_names,
                private_symbols = driver.imported["pkg.main"].private_symbols,
            }
        end

        local unsplit = build_variant("unsplit", 1, coder.DEFAULT_SPLIT_THRESHOLD)
        local split = build_variant("split", 4, 1)

        assert.equal(1, #unsplit.main_objects)
        assert.equal(4, #split.main_objects)
        assert.is_true(file_exists(split.out_dir .. "/pkg/main.priv.h"))
        local record = assert(objectmetadata.read(read_file(split.out_dir .. "/pkg/main.o"),
            split.out_dir .. "/pkg/main.o"))
        assert.equal(4, #record.object_metadata.parts)

        -- Execute both providers in fresh Lua processes, exercising cross-part
        -- calls, closures, transfer, protobuf codecs, reflection, and foreign bindings.
        for _, variant in ipairs({ unsplit, split }) do
            local script = workspace .. "/verify_run.lua"
            -- `pkg.main`/`pkg.dep` share one prefix provider, so the child
            -- installs the Titan searcher through the support module and
            -- names the provider root; no Lua shims are generated.
            write_file(script, [[
require "titan"
local main = require("pkg.main")
local dep = require("pkg.dep")
local total, formatted, matched = main.exercise_all(7)
assert(total == 74, "unexpected total: " .. tostring(total))
assert(formatted == "sum:74", "unexpected formatted: " .. tostring(formatted))
assert(matched == true, "unexpected matched")
assert(main.exercise_metadata(), "cross-part transfer/codecs/reflection failed")
assert(main.imported_callback_identity(), "source-imported callback address diverged")
local box = dep.make_box(10)
assert(box.value == 13)
print("VARIANT_OK")
]])
            local ok, out = run_cmd({ "env",
                "TITAN_PATH_0_6=" .. variant.out_dir .. ";;",
                LUA, "-E", script })
            assert.is_true(ok, out)
            assert.truthy(out:find("VARIANT_OK", 1, true), out)
        end

        if platform.windows then
            local interfaces = {}
            for _, name in ipairs(split.module_names) do
                interfaces[name] = driver.imported[name].type
            end
            local _, expected = driver.windows_provider_exports(
                split.module_names, interfaces, "pkg.dll")
            table.sort(expected)
            for _, variant in ipairs({ unsplit, split }) do
                local ok, output = run_cmd({ "llvm-readobj", "--coff-exports", variant.dso })
                assert.truthy(ok, output)
                local names = {}
                for line in output:gmatch("[^\r\n]+") do
                    local name = line:match("^%s*Name:%s+(%S+)%s*$")
                    if name then names[#names + 1] = name end
                end
                table.sort(names)
                assert.same(expected, names, output)
            end
        end
        if not platform.windows and not driver.IS_DARWIN then
            -- The final images preserve public exports and hide every inventoried private.
            local ok1, nm_unsplit = run_cmd({ "nm", "-D", "--defined-only", unsplit.dso })
            local ok2, nm_split = run_cmd({ "nm", "-D", "--defined-only", split.dso })
            assert.is_true(ok1, nm_unsplit)
            assert.is_true(ok2, nm_split)
            local function exported_names(nm_out)
                local names = {}
                for line in nm_out:gmatch("[^\n]+") do
                    local sym = line:match("%s+[A-Za-z]%s+(%S+)%s*$")
                    if sym then names[#names + 1] = sym end
                end
                table.sort(names)
                return names
            end
            local pub_unsplit = exported_names(nm_unsplit)
            local pub_split = exported_names(nm_split)
            assert.same(pub_unsplit, pub_split)
            local exported = {}
            for _, symbol in ipairs(pub_split) do exported[symbol] = true end
            for _, entry in ipairs(split.private_symbols) do
                assert.is_nil(exported[entry.symbol], entry.owner .. ": " .. entry.symbol)
            end

            -- Check ld -r combined object undefined/defined equivalence against unsplit.
            local combined_o = workspace .. "/combined_main.o"
            local ld_argv = { "ld", "-r", "-o", combined_o }
            for _, obj in ipairs(split.main_objects) do
                ld_argv[#ld_argv + 1] = obj
            end
            local ld_ok, ld_out = run_cmd(ld_argv)
            assert.is_true(ld_ok, ld_out)
            local _, undef_unsplit = run_cmd({ "nm", "-u", unsplit.main_objects[1] })
            local _, undef_combined = run_cmd({ "nm", "-u", combined_o })
            local function undef_set(text)
                local s = {}
                for line in text:gmatch("[^\n]+") do
                    local sym = line:match("U%s+(%S+)%s*$")
                    if sym then s[sym] = true end
                end
                return s
            end
            assert.same(undef_set(undef_unsplit), undef_set(undef_combined))
        end
    end)

    it("invalidates the old primary during compilation and replays diagnostics in part order", function()
        if platform.windows then pending("POSIX native diagnostic wrapper"); return end
        local stem = workspace .. "/diagnostics"
        local source_path = stem .. ".titan"
        write_file(source_path, MULTI_CONSTRUCT_SOURCE)
        local ast = check_module("diagnostics", MULTI_CONSTRUCT_SOURCE, source_path)
        assert(driver.compile("diagnostics", ast, source_path, {}, false,
            { c_parts = 4, split_threshold = 1 }))
        local wrapper = workspace .. "/diagnostics_cc.sh"
        write_file(wrapper, string.format([[
#!/bin/sh
compile=no
preprocess=no
source=
previous=
for arg in "$@"; do
  test "$previous" != -c || source=$arg
  case "$arg" in -c) compile=yes ;; -E) preprocess=yes ;; esac
  previous=$arg
done
test "$compile" = yes && test "$preprocess" = no || exit 94
case "$source" in
  %q.c) part=0 ;;
  %q.part1.c) part=1 ;;
  %q.part2.c) part=2 ;;
  %q.part3.c) part=3 ;;
  *) exit 94 ;;
esac
test ! -e %q.o || exit 95
test "$part" != 0 || sleep 0.1
echo "split-diagnostic-$part" >&2
exit 1
]], stem, stem, stem, stem, stem))
        assert(run_cmd({ "chmod", "+x", wrapper }))
        -- Capture the real process boundary instead of replacing Busted's
        -- sandboxed io table, which need not be the driver's io table.
        local probe = workspace .. "/diagnostics.lua"
        write_file(probe, string.format([[
package.path = %q .. "/?.lua;" .. package.path
require "spec.support.helpers"
local checker = require "titan-compiler.checker"
local driver = require "titan-compiler.driver"
local parser = require "titan-compiler.parser"
local source, filename = %q, %q
local ast = assert(parser.parse(filename, source))
local _, errors = checker.check("diagnostics", ast, source, filename)
assert(#errors == 0, table.concat(errors, "\n"))
driver.CC = %q
local results = driver.compile_modules({ {
    modname = "diagnostics", mod = { ast = ast, filename = filename },
    options = { c_parts = 4, split_threshold = 1 },
} }, 4, false)
assert(results[1].ok == nil, "injected C compilation unexpectedly succeeded")
]], ROOT, MULTI_CONSTRUCT_SOURCE, source_path, wrapper))
        local ok, output = run_cmd({
            "env", "TITAN_ROOT=" .. PREFIX, LUA, probe,
        })
        assert.is_true(ok, output)
        local position = 0
        for part = 0, 3 do
            position = assert(output:find("split-diagnostic-" .. part, position + 1, true), output)
        end
        assert.is_false(file_exists(stem .. ".o"))
    end)

    it("enforces complete part-set incremental reuse, repairs missing/truncated/stale parts, cleans holes, and leaves no commit marker on failure", function()
        local src_dir = workspace .. "/inc_src"
        local out_dir = workspace .. "/inc_out"
        local titan_file = src_dir .. "/mod.titan"
        write_file(titan_file, MULTI_CONSTRUCT_SOURCE)

        local function run_compile(c_parts, threshold, incremental, inject_fail_part, inject_fail_rename)
            h.reset(true)
            local context = driver.new_resolver_context({
                source_first = true,
                output_root = out_dir,
            })
            assert(driver.configure_foreign_c(context))
            local prev_src = driver.TITAN_SOURCE_PATH
            local prev_out = driver.OUTPUT_ROOT
            local prev_cc = driver.CC
            driver.TITAN_SOURCE_PATH = src_dir
            driver.OUTPUT_ROOT = assert(driver.prepare_output_root(out_dir))

            local loader = driver.defaultloader({}, {
                source_roots = { mod = true },
                incremental = incremental,
                context = context,
                output_root = driver.OUTPUT_ROOT,
                c_parts = c_parts,
                split_threshold = threshold,
            })
            local ok, errs = checker.checkimport("mod", loader)
            assert.truthy(ok, errs)
            assert.equal(0, #errs, table.concat(errs, "\n"))
            local mod = driver.imported["mod"]
            local was_hit = mod.compiled ~= nil

            if inject_fail_part then
                local wrapper = workspace .. "/fail_part_cc.lua"
                write_file(wrapper, string.format([==[
local cdriver = require("c-parser.cdriver")
local command = assert(cdriver.split_shell_words(%q))
local source
for index, argument in ipairs(arg) do
    if argument == "-c" then source = arg[index + 1] end
    if argument == "-E" then source = nil; break end
end
if source and source:match("%%.part%d%%.c$") then
    io.stderr:write("injected part %d failure\n")
    local marker = assert(io.open(%q, "wb"))
    assert(marker:write(source))
    assert(marker:close())
    os.exit(1)
end
for _, argument in ipairs(arg) do command[#command + 1] = argument end
local result = require("titan-compiler.io").new_sync():run(command,
    { stderr_to_stdout = true })
io.stderr:write(result.output or result.diagnostic or "")
os.exit(result.ok and 0 or 1)
]==], prev_cc, inject_fail_part, inject_fail_part, workspace .. "/failed_part"))
                driver.CC = assert(cdriver.shell_quote(LUA)) .. " " ..
                    assert(cdriver.shell_quote(wrapper))
            end

            local original_rename = os.rename
            if inject_fail_rename then
                local suffix = inject_fail_rename == true and ".part2.o" or inject_fail_rename
                os.rename = function(from, to)
                    if to:gsub("\\", "/") == out_dir .. "/mod" .. suffix then
                        return nil, "injected publication failure for " .. suffix
                    end
                    return original_rename(from, to)
                end
            end

            local results = driver.compile_modules({
                {
                    modname = "mod",
                    mod = mod,
                    static_deps = { mod = true },
                    options = {
                        context = context,
                        c_parts = c_parts,
                        split_threshold = threshold,
                        native_inputs = { out_dir .. "/mod.part99.o" },
                    },
                },
            }, 2, false)

            os.rename = original_rename
            driver.CC = prev_cc
            driver.TITAN_SOURCE_PATH = prev_src
            driver.OUTPUT_ROOT = prev_out
            assert(driver.close_resolver_context(context))
            return was_hit, results[1]
        end

        -- 1. Cold build with 4 parts
        local hit, res = run_compile(4, 1, true)
        assert.is_false(hit)
        assert.is_true(res.ok, res.err)
        assert.equal(4, #res.objects)
        for k = 0, 3 do
            assert.is_true(file_exists(driver.part_object_filename(out_dir .. "/mod", k)))
        end
        assert.is_true(file_exists(out_dir .. "/mod.priv.h"))

        -- 2. Warm incremental build with same policy is a hit
        hit, res = run_compile(4, 1, true)
        assert.is_true(hit)
        assert.is_true(res.ok)
        assert.equal(4, #res.objects)

        -- 3. Deleting a sidecar part (.part2.o) forces a full module miss and rebuilds it
        assert(os.remove(out_dir .. "/mod.part2.o"))
        hit, res = run_compile(4, 1, true)
        assert.is_false(hit)
        assert.is_true(res.ok)
        assert.is_true(file_exists(out_dir .. "/mod.part2.o"))

        -- 4. Truncating a sidecar part (.part1.o) forces a miss and rebuilds it
        write_file(out_dir .. "/mod.part1.o", "truncated")
        hit, res = run_compile(4, 1, true)
        assert.is_false(hit)
        assert.is_true(res.ok)

        -- 5. A part's older mtime does not invalidate unchanged content.
        local src_mtime = assert(lfs.attributes(titan_file, "modification"))
        assert(lfs.touch(out_dir .. "/mod.part3.o", src_mtime - 10, src_mtime - 10))
        local saved_part = read_file(out_dir .. "/mod.part3.o")
        hit, res = run_compile(4, 1, true)
        assert.is_true(hit)
        assert.is_true(res.ok)
        assert.equal(saved_part, read_file(out_dir .. "/mod.part3.o"))
        assert.equal(src_mtime - 10, lfs.attributes(out_dir .. "/mod.part3.o", "modification"))

        -- A valid object from another target is also a whole-module miss.
        local part_bytes = read_file(out_dir .. "/mod.part1.o")
        if part_bytes:sub(1, 4) == "\127ELF" then
            write_file(out_dir .. "/mod.part1.o",
                part_bytes:sub(1, 18) .. string.char(183, 0) .. part_bytes:sub(21))
            hit, res = run_compile(4, 1, true)
            assert.is_false(hit)
            assert.is_true(res.ok, res.err)
        end
        for _, suffix in ipairs({ ".priv.h" }) do
            assert(os.remove(out_dir .. "/mod" .. suffix))
            hit, res = run_compile(4, 1, false)
            assert.is_true(res.ok, res.err)
            assert.is_true(file_exists(out_dir .. "/mod" .. suffix))
        end
        write_file(out_dir .. "/mod.part99.c", "authored C sentinel")
        write_file(out_dir .. "/mod.part99.o", "extra object sentinel")
        -- 6. Create a hole by deleting .part2.o/.part2.c, then reduce c_parts to 2:
        --    stale .part3.o and .part3.c must still be cleaned!
        assert(os.remove(out_dir .. "/mod.part2.o"))
        assert(os.remove(out_dir .. "/mod.part2.c"))
        hit, res = run_compile(2, 1, true)
        assert.is_false(hit)
        assert.is_true(res.ok)
        assert.equal(2, #res.objects)
        assert.is_false(file_exists(out_dir .. "/mod.part2.o"))
        assert.is_false(file_exists(out_dir .. "/mod.part3.o"))
        assert.is_false(file_exists(out_dir .. "/mod.part3.c"))

        -- 7. Reduce c_parts to 1: .priv.h and .part1.o/.c must be cleaned!
        hit, res = run_compile(1, 1, true)
        assert.is_false(hit)
        assert.is_true(res.ok)
        assert.equal(1, #res.objects)
        assert.is_false(file_exists(out_dir .. "/mod.priv.h"))
        assert.is_false(file_exists(out_dir .. "/mod.part1.o"))
        assert.is_false(file_exists(out_dir .. "/mod.part1.c"))
        assert.equal("authored C sentinel", read_file(out_dir .. "/mod.part99.c"))
        assert.equal("extra object sentinel", read_file(out_dir .. "/mod.part99.o"))

        -- 8. Failed part compile leaves no primary mod.o.
        hit, res = run_compile(4, 1, false, 2, false)
        assert.falsy(res.ok)
        assert.matches("%.part2%.c$", read_file(workspace .. "/failed_part"))
        assert.is_false(file_exists(out_dir .. "/mod.o"))

        -- A failure at any publication boundary rolls back every object.
        for _, suffix in ipairs({ ".part2.o", ".o" }) do
            hit, res = run_compile(4, 1, false)
            assert.is_true(res.ok, res.err)
            hit, res = run_compile(4, 1, false, nil, suffix)
            assert.falsy(res.ok)
            assert.matches("injected publication failure", res.err, 1, true)
            for part = 0, 3 do
                assert.is_false(file_exists(driver.part_object_filename(out_dir .. "/mod", part)))
            end
        end
    end)

    local function certified_split_module()
        local source_root = workspace .. "/semantic_src"
        local output_root = workspace .. "/semantic_out"
        local filename = source_root .. "/mod.titan"
        write_file(filename, MULTI_CONSTRUCT_SOURCE)
        h.reset(true)
        driver.TITAN_SOURCE_PATH = source_root
        driver.OUTPUT_ROOT = assert(driver.prepare_output_root(output_root))
        local context = driver.new_resolver_context({
            source_first = true, output_root = output_root, jobs = 2,
        })
        cleanup_context = context
        assert(driver.configure_foreign_c(context))
        local options = { context = context, c_parts = 4, split_threshold = 1 }
        local loader = driver.defaultloader({}, {
            source_roots = { mod = true }, incremental = false,
            context = context, output_root = driver.OUTPUT_ROOT,
            c_parts = 4, split_threshold = 1,
        })
        local ok, errors = checker.checkimport("mod", loader)
        assert.truthy(ok, errors)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        local mod = driver.imported.mod
        filename = mod.native_output or filename
        assert(driver.compile("mod", mod.ast, filename, { mod = true },
            false, options, mod))
        assert.is_true(file_exists(output_root .. "/mod.o"))
        return context, mod, options, filename, output_root
    end

    for _, boundary in ipairs({ "direct", "serial batch", "parallel batch" }) do
        it("returns a real preprocessing failure without a commit marker through " .. boundary, function()
            local context, mod, options, filename, output_root = certified_split_module()
            local strategy, temporaries = context.io, {}
            local tmpname, run_batch = strategy.tmpname, strategy.run_batch
            function strategy:tmpname()
                local path, err = tmpname(self)
                if path then temporaries[#temporaries + 1] = path end
                return path, err
            end
            local batches = 0
            function strategy:run_batch(commands, batch_options)
                assert.equal(4, #commands)
                assert.equal(2, batch_options.jobs)
                batches = batches + 1
                -- The real C preprocessor, not a returned fake result, rejects
                -- the private source and supplies its diagnostic.
                assert(self:write_file(commands[1][#commands[1] - 2],
                    "#error generated_C_preprocessing_rejected\n"))
                return run_batch(self, commands, batch_options)
            end
            local result
            if boundary == "direct" then
                local ok, err = driver.compile("mod", mod.ast, filename,
                    { mod = true }, false, options, mod)
                result = { ok = ok, err = err }
            else
                result = driver.compile_modules({ {
                    modname = "mod", mod = mod, static_deps = { mod = true },
                    options = options,
                } }, boundary == "serial batch" and 1 or 2, false)[1]
            end
            assert.falsy(result.ok)
            assert.matches("generated_C_preprocessing_rejected", result.err, 1, true)
            assert.equal(1, batches)
            assert.is_true(#temporaries >= 8)
            for _, path in ipairs(temporaries) do assert.is_false(file_exists(path), path) end
            for part = 0, 3 do
                assert.is_false(file_exists(driver.part_object_filename(output_root .. "/mod", part)))
            end
            for name in lfs.dir(output_root) do
                assert.is_nil(name:find(".tmp.", 1, true), name)
            end
            assert.is_nil(read_file(output_root .. "/mod.c"):find("titan_object_source_mod", 1, true))
            assert.is_nil(mod.compiled)
        end)
    end

    it("retires the primary and preprocessing scratch before propagating a strategy cancellation", function()
        local context, mod, options, _, output_root = certified_split_module()
        local token, temporaries = {}, {}
        local tmpname = context.io.tmpname
        function context.io:tmpname()
            local path, err = tmpname(self)
            if path then temporaries[#temporaries + 1] = path end
            return path, err
        end
        function context.io:run_batch() error(token, 0) end
        local called, err = pcall(driver.compile_modules, { {
            modname = "mod", mod = mod, static_deps = { mod = true },
            options = options,
        } }, 2, false)
        assert.is_false(called)
        assert.equal(token, err)
        assert.is_true(#temporaries >= 8)
        for _, path in ipairs(temporaries) do assert.is_false(file_exists(path), path) end
        for part = 0, 3 do
            assert.is_false(file_exists(driver.part_object_filename(output_root .. "/mod", part)))
        end
        for name in lfs.dir(output_root) do
            assert.is_nil(name:find(".tmp.", 1, true), name)
        end
        assert.is_nil(mod.compiled)
    end)

    for _, outcome in ipairs({ "failure", "cancellation" }) do
        it("keeps relocated preprocessing " .. outcome .. " distinct from a certified hit", function()
            local context, _, _, _, output_root = certified_split_module()
            local policy = context.codegen_policy
            assert(driver.close_resolver_context(context))
            cleanup_context = nil
            local moved = workspace .. "/semantic_moved"
            assert(os.rename(output_root, moved))
            driver.OUTPUT_ROOT = assert(driver.prepare_output_root(moved))
            context = driver.new_resolver_context({
                source_first = true, output_root = moved, jobs = 2,
            })
            context.codegen_policy = policy
            cleanup_context = context
            assert(driver.configure_foreign_c(context))
            local strategy, temporaries = context.io, {}
            local tmpname = strategy.tmpname
            function strategy:tmpname()
                local path, err = tmpname(self)
                if path then temporaries[#temporaries + 1] = path end
                return path, err
            end
            function strategy:run_batch(commands)
                assert.equal(4, #commands)
                if outcome == "cancellation" then return {}, 2 end
                return { { ok = false, diagnostic = "relocated preprocessing rejected" } }
            end
            local source = {
                kind = "flat", main = driver.TITAN_SOURCE_PATH .. "/mod.titan",
                files = { driver.TITAN_SOURCE_PATH .. "/mod.titan" },
                native_output = moved .. "/mod.titan",
            }
            assert(driver.incremental_configuration(context))
            local called, verdict = pcall(incremental.certify_local, context, "mod", source)
            if outcome == "failure" then
                assert.is_true(called)
                assert.equal("miss", verdict.status)
                assert.equal("relocation", verdict.reason)
                assert.matches("relocated preprocessing rejected", verdict.detail, 1, true)
            else
                assert.is_false(called)
                assert.equal(2, verdict)
                assert.equal(2, context.generated_c_cancelled_signal)
                local propagate = jobs.propagate
                finally(function() jobs.propagate = propagate end)
                local delivered
                jobs.propagate = function(signal) delivered = signal end
                assert(driver.close_resolver_context(context))
                assert.equal(2, delivered)
                cleanup_context = nil
            end
            assert.is_true(#temporaries >= 8)
            for _, path in ipairs(temporaries) do assert.is_false(file_exists(path), path) end
        end)
    end

    it("refuses user-owned .priv.h paths before mutating outputs", function()
        local stem = workspace .. "/protected_mod"
        local source_path = stem .. ".titan"
        write_file(source_path, MULTI_CONSTRUCT_SOURCE)
        local ast = check_module("protected_mod", MULTI_CONSTRUCT_SOURCE, source_path)

        write_file(stem .. ".priv.h", "/* user authored header */\n")
        local ok, err = driver.compile("protected_mod", ast, source_path, {}, false, {
            c_parts = 4,
            split_threshold = 1,
        })
        assert.is_nil(ok)
        assert.matches("refusing to overwrite user-owned generated-header path", err, 1, true)
        assert.equal("/* user authored header */\n", read_file(stem .. ".priv.h"))
        assert.is_false(file_exists(stem .. ".o"))
        ast = check_module("protected_mod", MULTI_CONSTRUCT_SOURCE, source_path)
        ok, err = driver.compile("protected_mod", ast, source_path, {}, false, {
            c_parts = 4, split_threshold = math.maxinteger,
        })
        assert.truthy(ok, err)
        assert.equal("/* user authored header */\n", read_file(stem .. ".priv.h"))
        os.remove(stem .. ".o")
        os.remove(stem .. ".priv.h")

    end)

    it("maps ASan generated-C offsets to hidden functions in nonzero parts using snapshotted private headers", function()
        if platform.windows or driver.IS_DARWIN then
            pending("ELF BuildId and section-relative DWARF shadow verification apply to Linux ELF providers")
            return
        end
        local gen_dir = workspace .. "/asan_gen"
        local src_file = gen_dir .. "/asan_mod.titan"
        write_file(src_file, MULTI_CONSTRUCT_SOURCE)
        local ast = check_module("asan_mod", MULTI_CONSTRUCT_SOURCE, src_file)

        local prev_cflags = driver.EXTRA_CFLAGS
        local prev_ldflags = driver.EXTRA_LDFLAGS
        driver.EXTRA_CFLAGS = { "-O0", "-fno-lto" }
        driver.EXTRA_LDFLAGS = { "-O0", "-fno-lto", "-Wl,--build-id=sha1" }

        local ok, err, primary_o, _, objects = driver.compile(
            "asan_mod", ast, src_file, {}, false, {
                c_parts = 4,
                split_threshold = 1,
            })
        assert.truthy(ok, err)
        assert.equal(4, #objects)
        local provider = workspace .. "/asan_mod.so"
        assert(driver.compile_library_output(provider, objects, nil, false))

        driver.EXTRA_CFLAGS = prev_cflags
        driver.EXTRA_LDFLAGS = prev_ldflags

        -- Find a hidden function (e.g. a lambda or Lua entry) defined in a nonzero part (.part1.o .. .part3.o).
        local target_sym_name
        for part_idx = 2, #objects do
            local nm_ok, nm_out = run_cmd({ "nm", "-anS", "--defined-only", objects[part_idx] })
            assert.is_true(nm_ok, nm_out)
            for _, sym in ipairs(asan_mapper.parse_nm(nm_out)) do
                if sym.name:find("\226\132\153", 1, true) then
                    target_sym_name = sym.name
                    break
                end
            end
            if target_sym_name then break end
        end
        assert.is_string(target_sym_name, "expected a ℙ hidden function in a nonzero part")

        local dso_nm_ok, dso_nm_out = run_cmd({ "nm", "-anS", "--defined-only", provider })
        assert.is_true(dso_nm_ok, dso_nm_out)
        local dso_sym
        for _, sym in ipairs(asan_mapper.parse_nm(dso_nm_out)) do
            if sym.name == target_sym_name then
                dso_sym = sym
                break
            end
        end
        assert.is_table(dso_sym, "missing hidden symbol in linked provider")

        local _, readelf_out = run_cmd({ "readelf", "-n", provider })
        local build_id = assert(readelf_out:match("Build ID:%s*([%da-fA-F]+)"))

        local snapshot_dir = workspace .. "/asan_snapshot"
        local unit_count, snap_err = asan_mapper.snapshot(snapshot_dir, provider, gen_dir)
        assert.equal(4, unit_count, snap_err)
        assert.is_true(file_exists(snapshot_dir .. "/headers/asan_mod.priv.h"))
        assert.is_true(file_exists(snapshot_dir .. "/headers/asan_mod.ffi.h"))

        -- Remove the original generated directory to prove shadow compilation uses snapshotted headers/parts.
        remove_tree(gen_dir)

        local log_file = workspace .. "/asan.log"
        write_file(log_file, table.concat({
            "==999==ERROR: AddressSanitizer: synthetic crash",
            string.format("#0 0x7fff00001111 in %s %s:12 (%s+0x%x) (BuildId: %s)",
                target_sym_name, src_file, provider, dso_sym.address, build_id),
            "SUMMARY: AddressSanitizer: synthetic crash",
            "",
        }, "\n"))

        local report, report_err = asan_mapper.report_logs(log_file, snapshot_dir, {
            work_dir = workspace .. "/asan_shadow",
        })
        assert.is_string(report, report_err)
        assert.truthy(report:find("symbol: " .. target_sym_name .. "+0x0", 1, true), report)
        assert.matches("generated C context:.-/asan_mod%.part%d+%.c:%d+", report)
    end)

    it("preserves cross-part native and lambda error tracebacks with exact .titan locations", function()
        local trace_src = [[
local function make_throwing_lambda(tag: string): function(integer): integer
    return function(x: integer): integer
        if x < 0 then
            raise "boom:" .. tag
        end
        return x + 1
    end
end

local function middle_step(fn: function(integer): integer, v: integer): integer
    return fn(v) + 10
end

function entry_point(v: integer): integer
    local fn = make_throwing_lambda("part")
    return middle_step(fn, v)
end
]]
        local dir = workspace .. "/trace_test"
        local src_file = dir .. "/trace_mod.titan"
        write_file(src_file, trace_src)
        local ast = check_module("trace_mod", trace_src, src_file)
        local ok, err, _, _, objects = driver.compile(
            "trace_mod", ast, src_file, {}, false, {
                c_parts = 3,
                split_threshold = 1,
            })
        assert.truthy(ok, err)
        assert.equal(3, #objects)
        local dso = dir .. "/trace_mod" .. (platform.windows and ".dll" or ".so")
        assert(driver.compile_library_output(
            dso, objects, nil, false, nil, {}, nil, dso,
            platform.windows and { "trace_mod" } or nil))

        local script = dir .. "/run_trace.lua"
        write_file(script, string.format([[
package.cpath = %q .. "/?" .. %q .. ";" .. package.cpath
local titan = require("titan")
local mod = require("trace_mod")
local ok, err = pcall(mod.entry_point, -5)
assert(not ok)
assert(tostring(err):find("boom:part", 1, true), tostring(err))
local bt = titan.backtrace()
assert(bt:find("anonymous function at .*trace_mod%%.titan:2"), "missing lambda def line:\n" .. bt)
assert(bt:find("in trace_mod.middle_step", 1, true), "missing middle_step frame:\n" .. bt)
assert(bt:find("in trace_mod.entry_point", 1, true), "missing entry_point frame:\n" .. bt)
assert(not bt:find("titanentry", 1, true), "leaked titanentry:\n" .. bt)
assert(not bt:find("\226\132\153", 1, true), "leaked ℙ separator:\n" .. bt)
print("TRACE_OK")
]], dir, platform.windows and ".dll" or ".so"))
        local run_ok, run_out = run_cmd({ LUA, "-E", script })
        assert.is_true(run_ok, run_out)
        assert.truthy(run_out:find("TRACE_OK", 1, true), run_out)
    end)

    it("converts coverage lines per part, records all part C files, and removes stale part counters", function()
        local cov_dir = workspace .. "/cov_test"
        local src_file = cov_dir .. "/cov_mod.titan"
        write_file(src_file, MULTI_CONSTRUCT_SOURCE)
        local ast = check_module("cov_mod", MULTI_CONSTRUCT_SOURCE, src_file)
        local entry = { source_files = { src_file } }

        local ok, err, primary_o, _, objects = driver.compile(
            "cov_mod", ast, src_file, {}, false, {
                c_parts = 4,
                split_threshold = 1,
                coverage = true,
                coverage_backend = platform.windows and "llvm-gcov" or "gcc-gcov",
            }, entry)
        assert.truthy(ok, err)
        assert.equal(4, #objects)
        assert.is_table(entry.coverage)
        assert.equal(4, #entry.coverage.files)
        local all_lines = {}
        for _, c_file in ipairs(entry.coverage.files) do
            assert.is_true(file_exists(c_file), c_file)
            local file_anchors = entry.coverage.anchors[c_file]
            assert.is_table(file_anchors)
            for _, lines in pairs(file_anchors) do
                for _, ln in ipairs(lines) do all_lines[ln] = true end
            end
        end
        assert.is_true(next(all_lines) ~= nil, "expected source line anchors across split parts")

        -- Simulate stale .gcda/.gcno files for part 2 & 3, then recompile with c_parts = 2
        write_file(cov_dir .. "/cov_mod.part2.gcda", "stale")
        write_file(cov_dir .. "/cov_mod.part3.gcda", "stale")
        write_file(cov_dir .. "/cov_mod.part3.gcno", "stale")
        local ast2 = check_module("cov_mod", MULTI_CONSTRUCT_SOURCE, src_file)
        local entry2 = { source_files = { src_file } }
        local ok2, err2 = driver.compile(
            "cov_mod", ast2, src_file, {}, false, {
                c_parts = 2,
                split_threshold = 1,
                coverage = true,
                coverage_backend = platform.windows and "llvm-gcov" or "gcc-gcov",
            }, entry2)
        assert.truthy(ok2, err2)
        assert.equal(2, #entry2.coverage.files)
        assert.is_false(file_exists(cov_dir .. "/cov_mod.part2.gcda"))
        assert.is_false(file_exists(cov_dir .. "/cov_mod.part3.gcda"))
        assert.is_false(file_exists(cov_dir .. "/cov_mod.part3.gcno"))
    end)

    it("excludes inventoried private symbols from Windows .def exports and rejects link-set collisions", function()
        local ast = check_module("win_mod", [[
foreign function public_raw(x: int): int
    return x + 1
end
local foreign function private_raw(x: int): int
    return x + 2
end
function call_both(n: integer): integer
    local fn = function(v: integer): integer return v + n end
    return (public_raw(fn(1) as foreign int) as integer) + (private_raw(2) as integer)
end
]])
        local def_text, export_names = driver.windows_provider_exports(
            { "win_mod" }, { win_mod = ast._type }, "win_mod.dll")
        assert.truthy(def_text:find("win_mod_\226\132\179_public_raw_titan", 1, true))
        assert.is_nil(def_text:find("private_raw", 1, true))
        local generated = coder.generate("win_mod", ast, {}, driver.TITAN_ABI_VERSION,
            true, { c_parts = 4, split_threshold = 1 })
        local exported = {}
        for _, symbol in ipairs(export_names) do exported[symbol] = true end
        for _, entry in ipairs(generated.private_symbols) do
            assert.is_nil(exported[entry.symbol], entry.owner .. ": " .. entry.symbol)
        end

        -- Verify record_module_symbols detects collisions in the private inventory
        local owners = {}
        local errs = {}
        driver.record_module_symbols(owners, "left.mod", {
            { symbol = "shared_private_sym", owner = "anonymous function 0" },
        }, errs)
        driver.record_module_symbols(owners, "right.mod", {
            { symbol = "shared_private_sym", owner = "array writer 0" },
        }, errs)
        assert.equal(1, #errs)
        assert.matches("cannot link C symbol 'shared_private_sym'", errs[1], 1, true)
    end)

    it("validates --c-parts and TITAN_C_PARTS precedence and rejects non-positive values", function()
        local n, err = driver.parse_c_parts("8")
        assert.equal(8, n)
        assert.is_nil(err)

        for _, bad in ipairs({ "0", "-1", "abc", "", "1.5", 0, -4 }) do
            local val, parse_err = driver.parse_c_parts(bad)
            assert.is_nil(val)
            assert.equal("--c-parts and TITAN_C_PARTS require a positive integer", parse_err)
        end
    end)

    it("preserves Titan source traceback lines across split parts and pretty-prints all part files", function()
        local src_dir = workspace .. "/tb_src"
        local out_dir = workspace .. "/tb_out"
        local tb_source = MULTI_CONSTRUCT_SOURCE:gsub("do\n%s+base_offset = 10\nend", [[
function boom_leaf(x: integer): integer
    if x < 0 then
        raise "negative_boom"
    end
    return x + 1
end
function boom_caller(x: integer): string
    do
        local _ = boom_leaf(x) + 10
        return "ok"
    catch
        return (error as string) .. "\n" .. traceback
    end
end
do
    base_offset = 10
end]])
        write_file(src_dir .. "/tbmod.titan", tb_source)

        local indent_log = workspace .. "/indent.log"
        local indent_stub = workspace .. "/stub_clang_format.lua"
        write_file(indent_stub, string.format([==[
local file = assert(io.open(%q, "ab"))
assert(file:write(arg[#arg], "\n"))
assert(file:close())
]==], indent_log))

        h.reset(true)
        local context = driver.new_resolver_context({
            source_first = true,
            output_root = out_dir,
            pretty_print = true,
        })
        cleanup_context = context
        assert(driver.configure_foreign_c(context))
        driver.CLANG_FORMAT = assert(cdriver.shell_quote(LUA)) .. " " ..
            assert(cdriver.shell_quote(indent_stub))
        driver.TITAN_SOURCE_PATH = src_dir
        driver.OUTPUT_ROOT = assert(driver.prepare_output_root(out_dir))

        local compile_opts = {
            source_roots = { tbmod = true },
            context = context,
            output_root = driver.OUTPUT_ROOT,
            c_parts = 4,
            split_threshold = 1,
            pretty_print = true,
        }
        local loader = driver.defaultloader({}, compile_opts)
        local modtype, errors = checker.checkimport("tbmod", loader)
        assert.truthy(modtype, errors)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        local finalized, finalize_errors = driver.finalize_resolver_context(context)
        assert.truthy(finalized, finalize_errors and table.concat(finalize_errors, "\n"))
        assert(driver.prepare_foreign_headers({ "tbmod" }, driver.imported, false, true))
        local mod = driver.imported["tbmod"]
        local results = driver.compile_modules({
            {
                modname = "tbmod",
                mod = mod,
                static_deps = context.native_static_names,
                options = {
                    nominal_layouts = context.nominal_layouts,
                    c_parts = 4,
                    split_threshold = 1,
                    pretty_print = true,
                },
            },
        }, 2, false)
        driver.CLANG_FORMAT = saved_clang_format
        assert.is_true(results[1].ok, results[1].err)
        assert.equal(4, #results[1].objects)
        local formatted = read_file(indent_log)
        assert.truthy(formatted:find("tbmod.priv.h", 1, true), formatted)
        assert.truthy(formatted:find("tbmod.c", 1, true), formatted)
        assert.truthy(formatted:find("tbmod.part1.c", 1, true), formatted)
        assert.truthy(formatted:find("tbmod.part2.c", 1, true), formatted)
        assert.truthy(formatted:find("tbmod.part3.c", 1, true), formatted)

        local dso = out_dir .. "/tbmod" .. (platform.windows and ".dll" or ".so")
        assert(driver.compile_library_output(
            dso, results[1].objects, nil, false, nil, {}, nil, dso,
            platform.windows and { "tbmod" } or nil))
        local verify = workspace .. "/verify_tb.lua"
        write_file(verify, string.format([[
package.path = %q .. "/?.lua;" .. package.path
package.cpath = %q .. "/?" .. %q .. ";" .. package.cpath
local tbmod = require("tbmod")
local trace = tbmod.boom_caller(-5)
assert(trace:find("negative_boom", 1, true), trace)
assert(trace:find("tbmod.titan:", 1, true), trace)
assert(trace:find("boom_leaf", 1, true), trace)
assert(trace:find("boom_caller", 1, true), trace)
print("TB_OK")
]], out_dir, out_dir, platform.windows and ".dll" or ".so"))
        local run_ok, run_out = run_cmd({ LUA, "-E", verify })
        assert.is_true(run_ok, run_out)
        assert.truthy(run_out:find("TB_OK", 1, true), run_out)
    end)
end)
