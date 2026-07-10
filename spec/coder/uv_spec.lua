local lfs = require "lfs"
local checker = require "titan-compiler.checker"
local driver = require "titan-compiler.driver"
local parser = require "titan-compiler.parser"
local types = require "titan-compiler.types"

local function shell_quote(word)
    return "'" .. word:gsub("'", "'\\''") .. "'"
end

local function run_command(command)
    local pipe = assert(io.popen(command .. " 2>&1"))
    local output = pipe:read("*a")
    local ok, _, code = pipe:close()
    return ok == true or code == 0, output
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local function host_config()
    local ok, host = run_command("uname -s")
    assert.truthy(ok, host)
    host = assert(host:match("([^\r\n]+)"))
    local cppflags = "-Ilibuv-v1.52.1/include"
    local ldflags = "-lpthread"
    if host == "Linux" then
        cppflags = cppflags .. " -D_GNU_SOURCE"
        ldflags = ldflags .. " -ldl -lrt"
    end
    return host, cppflags, ldflags
end

local function build_uv()
    assert.truthy(lfs.attributes("libuv-build/libuv.a"),
        "bundled libuv is missing; run 'make libuv'")
    -- Other coder specs deliberately clean root-level shared objects.  Build
    -- the pinned dependency here so this suite does not depend on file order.
    local coroutine_ok, coroutine_output = run_command(
        "CCACHE_DISABLE=1 make coroutine.so")
    assert.truthy(coroutine_ok, coroutine_output)
    local _, cppflags, ldflags = host_config()
    local shim_command = table.concat({
        "CCACHE_DISABLE=1", os.getenv("CC") or "cc",
        "--std=c99 -O2 -Wall -fPIC -g -fno-optimize-sibling-calls",
        cppflags, "-fno-strict-aliasing",
        "-c titan-runtime/titan_uv.c",
        "-I titan-runtime -I lua-5.5.0/src -I libbacktrace",
        "-o titan-runtime/titan_uv.o",
    }, " ")
    local shim_ok, shim_output = run_command(shim_command)
    assert.truthy(shim_ok, shim_output)

    local cwd = lfs.currentdir()
    local command = table.concat({
        "CCACHE_DISABLE=1",
        "TITAN_STDLIB_PATH=" .. shell_quote(cwd),
        "TITAN_EXTRA_CPPFLAGS=" .. shell_quote(cppflags),
        "TITAN_EXTRA_CFLAGS=" .. shell_quote("-fno-strict-aliasing"),
        "TITAN_EXTRA_LDFLAGS=" .. shell_quote(ldflags),
        "./titanc --stdlib-build --tree stdlib --lua-name titan.uv uv",
        "-X titan-runtime/titan_uv.o libuv-build/libuv.a",
    }, " ")
    local compile_ok, compile_output = run_command(command)
    assert.truthy(compile_ok, compile_output)

    local link_ok, link_output = run_command(
        "mkdir -p titan && ln -sfn ../uv.so titan/uv.so")
    assert.truthy(link_ok, link_output)
end

local function run_lua(code)
    local script = os.tmpname() .. "-uv-spec.lua"
    local file = assert(io.open(script, "wb"))
    file:write(code)
    file:close()
    -- Use the raw bundled interpreter and put the just-built checkout alias
    -- first.  The project ./lua wrapper intentionally prefers the installed
    -- rock, which can be older during a focused source test.
    local command = "env TITAN_STDLIB_PATH=" ..
        shell_quote(lfs.currentdir()) ..
        " LUA_CPATH=" .. shell_quote("./?.so;;") ..
        " .lua/bin/lua " .. shell_quote(script)
    local ok, output = run_command(command)
    os.remove(script)
    return ok, output
end

local function dispatcher_section(generated, native_name, lua_entry_name)
    local first = assert(generated:find(
        "static void " .. native_name, 1, true))
    local last = assert(generated:find(
        "static int " .. lua_entry_name, first, true))
    return generated:sub(first, last - 1)
end

describe("uv GC owners and native callbacks", function()
    setup(build_uv)

    teardown(function()
        types.registry = {}
        driver.imported = {}
    end)

    it("generates exact owner ABI and function-level native catches", function()
        local generated = read_file("stdlib/uv.c")
        local public_uv = assert(generated:find("#include <uv.h>", 1, true))
        local lua_header = assert(generated:find("#include <lua.h>", 1, true))
        local ffi_header = assert(generated:find(
            "#include <titan/ffi.h>", 1, true))
        local shim_header = assert(generated:find(
            "#include <titan/uv.h>", 1, true))
        assert.is_true(public_uv < lua_header)
        assert.is_true(lua_header < ffi_header)
        assert.is_true(ffi_header < shim_header)

        assert.match("uv_timer_dispatch_titan%(lua_State %*L, Udata %*_mod, CClosure %*_fn, Udata%* _param_owner, lua_Integer _param_event_kind, lua_Integer _param_result, size_t _param_size%)",
            generated)
        assert.match("uv_fs_dispatch_titan%(lua_State %*L, Udata %*_mod, CClosure %*_fn, Udata%* _param_owner, lua_Integer _param_event_kind, lua_Integer _param_result, size_t _param_size%)",
            generated)

        local timer = dispatcher_section(generated,
            "uv_timer_dispatch_titan(",
            "uv_timer_dispatch_titanentry_lua(")
        local fs = dispatcher_section(generated,
            "uv_fs_dispatch_titan(",
            "uv_fs_dispatch_titanentry_lua(")
        assert.match("TITAN_SETJMP", timer, 1, true)
        assert.match("uv_stop", timer, 1, true)
        assert.match("TITAN_SETJMP", fs, 1, true)
        assert.match("uv_fs_req_cleanup", fs, 1, true)
        assert.match("uv_stop", fs, 1, true)

        assert.match("sizeof%(uv_loop_t%)", generated)
        assert.match("sizeof%(uv_timer_t%)", generated)
        assert.match("sizeof%(uv_fs_t%)", generated)
        assert.match("sizeof%(uv_buf_t%)", generated)
        assert.match("_Alignof%(uv_loop_t%)", generated)
        assert.match("_Alignof%(uv_timer_t%)", generated)
        assert.match("_Alignof%(uv_fs_t%)", generated)
        assert.match("lua_getupvalue%(L,.-1.-1", generated)

        local access = generated:match(
            "int uv__timer_is_closing_titan%b()%s*{(.-)static int uv__timer_is_closing_titanentry_lua")
        assert.truthy(access)
        assert.match("titan_uvshim_timer_is_closing", access, 1, true)
        assert.not_match("lua_newuserdatauv", access, 1, true)
        assert.not_match("lua_togco", access, 1, true)

        local shim = read_file("titan-runtime/titan_uv.c")
        assert.not_match("lua_pcall", shim, 1, true)
        assert.not_match("luaD_call", shim, 1, true)
        assert.match("dispatch%(L, M, NULL, owner", shim)
    end)

    it("exports only the qualified Lua entry and checks wrong owners", function()
        local host = host_config()
        local nm = host == "Darwin" and "nm -g uv.so" or "nm -D uv.so"
        local nm_ok, symbols = run_command(nm)
        assert.truthy(nm_ok, symbols)
        assert.match("luaopen_titan_uv", symbols, 1, true)
        assert.not_match("luaopen_uv", symbols, 1, true)

        local ok, output = run_lua([[
            local lua_coroutine = require "coroutine"
            local uv = require "titan.uv"
            assert(require "coroutine" == lua_coroutine)
            assert(uv.uv_timer_t.new == nil)
            local good, err = pcall(uv._timer_is_closed, {})
            assert(not good)
            assert(tostring(err):find("uv_timer_t", 1, true))
            good, err = pcall(uv._timer_is_closed, uv)
            assert(not good) -- wrong-record full userdata, not just a table
            assert(tostring(err):find("uv_timer_t", 1, true))
            assert(uv.version() == "1.52.1")
        ]])
        assert.truthy(ok, output)
    end)

    it("cleans normal timer, close, and filesystem callbacks after GC", function()
        local ok, output = run_lua([[
            local uv = require "titan.uv"
            local r = uv._phase1_probe(".", false, false, false, false)
            assert(r[1] == 5)  -- two timers + two closes + one fs callback
            assert(r[2] == 2 and r[3] == 2 and r[4] == 1)
            assert(r[5] == 0 and r[6] == 0)
            assert(r[7] == 1 and r[8] == 1 and r[19] == 1)
            assert(r[9] == 1)  -- callback dispatch restored the main stack top
            assert(r[10] == 0 and r[11] == 32)
            assert(r[12] == 1) -- all fixed slots, including module userdata
            assert(r[13] == 0)
            assert(r[20] == 1) -- repeated native-wrapper access did not box
        ]])
        assert.truthy(ok, output)
    end)

    it("contains an observed Task failure and runs a later live timer", function()
        local ok, output = run_lua([[
            local uv = require "titan.uv"
            local r = uv._phase1_probe(".", true, false, false, false)
            assert(r[1] == 5 and r[2] == 2)
            assert(r[5] == 1 and r[6] == 0)
            assert(r[14] == 1) -- independent timer ran after failure storage
            assert(r[17] == "phase-1 observed task failure")
            assert(r[18]:find("in uv.task_body", 1, true))
            assert(r[4] == 1 and r[7] == 1)
            assert(r[3] == 2 and r[8] == 1 and r[19] == 1)
            assert(r[9] == 1 and r[12] == 1)
        ]])
        assert.truthy(ok, output)
    end)

    it("turns Task-handler and first-dispatch failures into Runtime fatal state", function()
        local ok, output = run_lua([[
            local uv = require "titan.uv"

            local handler = uv._phase1_probe(".", true, true, false, false)
            assert(handler[6] == 1 and handler[5] == 0)
            assert(handler[15] == "phase-1 task error handler failure")
            assert(handler[16]:find("in uv.task_error_handler", 1, true))
            assert(handler[3] == 2 and handler[4] == 1)
            assert(handler[7] == 1 and handler[8] == 1 and handler[19] == 1)
            assert(handler[9] == 1 and handler[12] == 1)

            local injected = uv._phase1_probe(".", false, false, true, false)
            assert(injected[6] == 1)
            assert(injected[15] == "phase-1 injected dispatcher failure")
            assert(injected[16]:find("in uv.timer_dispatch", 1, true))
            assert(injected[2] == 0) -- failure was first dispatcher operation
            assert(injected[3] == 2 and injected[4] == 1)
            assert(injected[7] == 1 and injected[8] == 1 and injected[19] == 1)
            assert(injected[9] == 1 and injected[12] == 1)

            local fs_injected = uv._phase1_probe(
                ".", false, false, false, true)
            assert(fs_injected[6] == 1)
            assert(fs_injected[15] ==
                   "phase-1 injected filesystem dispatcher failure")
            assert(fs_injected[16]:find("in uv.fs_dispatch", 1, true))
            assert(fs_injected[4] == 0) -- failure was first FS body operation
            assert(fs_injected[7] == 1) -- catch still cleaned and unrooted FS
            assert(fs_injected[3] == 2 and fs_injected[19] == 1)
            assert(fs_injected[9] == 1 and fs_injected[12] == 1)
        ]])
        assert.truthy(ok, output)
    end)

    it("rehydrates the same opaque nominal type from binary-only uv.so", function()
        types.registry = {}
        driver.imported = {}
        local old_path = driver.TITAN_STDLIB_PATH
        driver.TITAN_STDLIB_PATH = lfs.currentdir()

        local source = [[
            local uv = import "uv"

            function identity(timer: uv.uv_timer_t): uv.uv_timer_t
                return timer
            end
        ]]
        local ast, parse_errors = parser.parse("uv_consumer.titan", source)
        assert.truthy(ast, parse_errors and
            parser.error_to_string(parse_errors, "uv_consumer.titan"))
        local deps = {}
        local modtype, errors = checker.check("uv_consumer", ast, source,
            "uv_consumer.titan", driver.defaultloader(deps))
        driver.TITAN_STDLIB_PATH = old_path

        assert.equals(0, #errors, table.concat(errors, "\n"))
        assert.equals("standard", deps.uv)
        assert.truthy(modtype.members.identity)
        local timer = assert(types.registry["uv.uv_timer_t"])
        assert.equals("Type.Record", timer._tag)
        assert.equals(0, #timer.fields)
        assert.equals(8, timer.nfields)
    end)
end)
