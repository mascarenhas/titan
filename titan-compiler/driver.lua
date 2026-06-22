local parser = require  "titan-compiler.parser"
local util = require "titan-compiler.util"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local pretty = require "titan-compiler.pretty"
local types = require "titan-compiler.types"

local lfs = require "lfs"

local driver = {}

driver.imported = {}

driver.TITAN_VER = "0.10"
driver.TITAN_VER_SUFFIX = "_0_10"
driver.TITAN_BIN_PATH = os.getenv("TITAN_PATH" .. driver.TITAN_VER_SUFFIX)
    or os.getenv("TITAN_PATH")
    or ".;/usr/local/lib/titan/" .. driver.TITAN_VER
driver.TITAN_SOURCE_PATH = "."
driver.LUA_SOURCE_PATH = "lua-5.5.0/src/"
driver.TITAN_RUNTIME_PATH = "titan-runtime/"
driver.LIBBACKTRACE_PATH = "libbacktrace"
-- -g emits DWARF (carries the #line file/line a traceback needs) and
-- -fno-optimize-sibling-calls keeps tail frames on the stack so libbacktrace
-- can unwind them.
driver.CFLAGS = "--std=c99 -O2 -Wall -fPIC -g -fno-optimize-sibling-calls"
driver.CC = "cc"

local CIRCULAR_MARK = {}

local function shell(cmd)
    local p = assert(io.popen(cmd))
    local out = p:read("*a")
    p:close()
    return out
end

driver.UNAME = shell("uname")
-- On Mach-O (macOS), libbacktrace needs a companion `.dSYM` bundle to symbolize
-- PCs to #line-attributed .titan file/line — the linker does NOT produce one, so
-- without `dsymutil` the native Titan frames are unsymbolized and dropped. Run
-- `dsymutil` after every final link on Darwin only; on Linux DWARF is embedded in
-- the binary and dsymutil may be absent, so it must be a no-op there.
driver.IS_DARWIN = string.match(driver.UNAME, "Darwin") ~= nil

local function run_dsymutil(output, verbose)
    if not driver.IS_DARWIN then return end
    local cmd = "dsymutil " .. output
    if verbose then
        print(cmd)
    end
    os.execute(cmd)
end

local function findmodule(paths, modname, extension)
    local modf = modname:gsub("[.]", "/") .. extension
    for path in paths:gmatch("[^;]+") do
        local filename = path .. "/" .. modf
        local mtime = lfs.attributes(filename, "modification")
        if mtime then return mtime, filename end
    end
    return nil
end

function driver.defaultloader(static_deps)
    static_deps = static_deps or {}
    local function loader(modname)
        if driver.imported[modname] == CIRCULAR_MARK then
            driver.imported[modname] = nil
            return false, "circular reference to module"
        end
        if driver.imported[modname] then
            local mod = driver.imported[modname]
            if mod.ast then static_deps[modname] = true end
            return true, mod.type, {}
        end
        local mtime_bin, binf = findmodule(driver.TITAN_BIN_PATH, modname, ".so")
        local mtime_src, srcf = findmodule(driver.TITAN_SOURCE_PATH, modname, ".titan")
        if mtime_bin and binf and ((not mtime_src) or mtime_bin >= mtime_src) then
            local prefix = modname:gsub("[%-.]", "_")
            local abif, err = package.loadlib(binf, prefix .. "_abi")
            if not abif then
                return false, "compiled module '" .. modname
                    .. "' has no compatible Titan ABI marker (expected "
                    .. driver.TITAN_VER .. "): " .. tostring(err)
            end
            local ok, abi_or_err = pcall(abif)
            if not ok then return false, abi_or_err end
            if abi_or_err ~= driver.TITAN_VER then
                return false, "compiled module '" .. modname
                    .. "' ABI mismatch: expected " .. driver.TITAN_VER
                    .. " but found " .. tostring(abi_or_err)
            end
            local typesf, err = package.loadlib(binf, prefix .. "_types")
            if not typesf then return false, err end
            local ok, types_or_err = pcall(typesf)
            if not ok then return false, types_or_err end
            local modtf, err = load("return " .. types_or_err, modname, "t", types)
            if not modtf then return false, err end
            local ok, modt_or_err = pcall(modtf)
            if not ok then return false, modt_or_err end
            driver.imported[modname] = { type = modt_or_err, compiled = true }
            return true, modt_or_err, {}
        end
        if not mtime_src then return false, "module '" .. modname .. "' not found" end
        local input, err = util.get_file_contents(srcf)
        if not input then return false, err end
        local ast, err = parser.parse(srcf, input)
        if not ast then return false, parser.error_to_string(err, srcf) end
        driver.imported[modname] = CIRCULAR_MARK
        local modt, errors = checker.check(modname, ast, input, srcf, loader)
        driver.imported[modname] = { ast = ast, type = modt, filename = srcf }
        static_deps[modname] = true
        return true, modt, errors
    end
    return loader
end

function driver.tableloader(modtable, imported, deps)
    deps = deps or {}
    local function loader(modname)
        if imported[modname] == CIRCULAR_MARK then
            imported[modname] = nil
            return false, "circular reference to module"
        end
        if imported[modname] then
            local mod = imported[modname]
            deps[modname] = true
            return true, mod.type, {}
        end
        local modf = "./" .. modname .. ".titan"
        local input = modtable[modname]
        local ast, err = parser.parse(modf, modtable[modname])
        if not ast then return false, parser.error_to_string(err, modf) end
        imported[modname] = CIRCULAR_MARK
        local modt, errors = checker.check(modname, ast, input, modf, loader)
        local mods = types.serialize(modt)
        local modtf, err = load("return " .. mods, modname, "t", types)
        if not modtf then return false, err end
        local ok, modt_or_err = pcall(modtf)
        if not ok then return false, modt_or_err end
        modt = modt_or_err
        imported[modname] = { ast = ast, type = modt, filename = modf }
        deps[modname] = true
        return true, modt, errors
    end
    return loader
end

local function shared_flag()
    local shared = "-shared"
    if string.match(driver.UNAME, "Darwin") then
        shared = shared .. " -undefined dynamic_lookup"
    end
    return shared
end

local function static_flag()
    return "-c"
end

function driver.compile_module(modname, mod, static_deps, verbose)
    if mod.compiled then return true, mod.compiled end
    local ok, err, libname = driver.compile(modname, mod.ast, mod.filename, static_deps, verbose)
    if not ok then return nil, err end
    mod.compiled = libname
    return true, nil, libname
end

local function check_runtime()
    local runtime_c = driver.TITAN_RUNTIME_PATH .. "titan.c"
    local runtime_o = driver.TITAN_RUNTIME_PATH .. "titan.o"
    local titanc_mtime = lfs.attributes(runtime_c, "modification")
    local titano_mtime = lfs.attributes(runtime_o, "modification")
    if (not titano_mtime) or (titano_mtime < titanc_mtime) then
        local args = {driver.CC, driver.CFLAGS, "-c", runtime_c,
            "-I", driver.TITAN_RUNTIME_PATH, "-I", driver.LUA_SOURCE_PATH,
            "-I", driver.LIBBACKTRACE_PATH,
            "-o", runtime_o }
        os.execute(table.concat(args, " "))
    end
end

function driver.compile(modname, ast, sourcef, static_deps, verbose)
    check_runtime()
    sourcef = sourcef or modname:gsub("[.]", "/") .. ".titan"
    static_deps = static_deps or {}
    local code = coder.generate(modname, ast, static_deps)
    code = pretty.reindent_c(code)
    local filename = sourcef:gsub("[.]titan$", "") .. ".c"
    local libname = sourcef:gsub("[.]titan$", "") .. ".o"
    os.remove(filename)
    os.remove(libname)
    local ok, err = util.set_file_contents(filename, code)
    if not ok then return nil, err end
    local libflag = static_flag()
    local args = {driver.CC, driver.CFLAGS, libflag, filename,
                  "-I", "titan-runtime",
                  "-I", driver.LUA_SOURCE_PATH,
                  "-I", driver.LIBBACKTRACE_PATH, "-o", libname}
    local cmd = table.concat(args, " ")
    if verbose then
        print(cmd)
    end
    local ok, err = os.execute(cmd)
    if ok then
        return ok, nil, libname
    else
        return nil, err
    end
end

local entrypoint_template = [[

#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
#include "titan.h"

/* portable alerts, from srlua */
#ifdef _WIN32
#include <windows.h>
#define alert(message)  MessageBox(NULL, message, progname, MB_ICONERROR | MB_OK)
#define getprogname()   char name[MAX_PATH]; argv[0]= GetModuleFileName(NULL,name,sizeof(name)) ? name : NULL;
#else
#define alert(message)  fprintf(stderr,"%s: %s\n", "$PROGNAME", message)
#define getprogname()
#endif

/* fatal error, from srlua */
static void fatal(const char* message) {
    alert(message);
    exit(EXIT_FAILURE);
}

/* Same message conversion policy as lua.c's msghandler: strings/numbers through
** lua_tostring, then __tostring if present and string-valued, otherwise a typed
** placeholder. */
static const char *errmsg_tostring(lua_State *L, int idx) {
    const char *msg;
    idx = lua_absindex(L, idx);
    msg = lua_tostring(L, idx);
    if (msg == NULL) {
        if (luaL_callmeta(L, idx, "__tostring") && lua_type(L, -1) == LUA_TSTRING) {
            msg = lua_tostring(L, -1);
        } else {
            msg = lua_pushfstring(L, "(error object is a %s value)",
                                  luaL_typename(L, idx));
        }
    }
    return msg;
}

static const char *strip_bootstrap_prefix(const char *message) {
    static const char prefix[] = "[string \"local arg = ...;...\"]:3: ";
    const size_t prefix_len = sizeof(prefix) - 1;
    while (strncmp(message, prefix, prefix_len) == 0) {
        message += prefix_len;
    }
    return message;
}

static int line_ends_with(const char *line, size_t len, const char *suffix) {
    const size_t suffix_len = strlen(suffix);
    if (suffix_len == 0 || len < suffix_len) return 0;
    return memcmp(line + len - suffix_len, suffix, suffix_len) == 0;
}

static void write_tabbed_trace(const char *trace) {
    const char *p = trace;
    const char *last_frame_marker = " in $MODNAME.main";
    if (p == NULL || *p == '\0') {
        fputc('\n', stderr);
        return;
    }
    while (*p != '\0') {
        const char *e = strchr(p, '\n');
        const size_t len = e ? (size_t)(e - p) : strlen(p);
        fputs("\n\t", stderr);
        fwrite(p, 1, len, stderr);
        if (line_ends_with(p, len, last_frame_marker)) {
            break;
        }
        if (e == NULL) break;
        p = e + 1;
    }
    fputc('\n', stderr);
}

static void report_titan_error(const char *message, const char *trace) {
    fprintf(stderr, "%s: %s\n", "$PROGNAME", strip_bootstrap_prefix(message));
    fputs("stack traceback:", stderr);
    write_tabbed_trace(trace);
    exit(EXIT_FAILURE);
}

/* main script launcher, based on srlua */
static int pmain(lua_State *L) {
    int argc = lua_tointeger(L, 1);
    char** argv = lua_touserdata(L, 2);
    int i;
    const char code[] = "local arg = ...;\nreturn\nrequire('$MODNAME').main(arg);";
    luaL_loadstring(L, code);
    if (lua_type(L, lua_gettop(L)) == LUA_TSTRING) {
        fatal(lua_tostring(L, -1));
    }
    lua_createtable(L, argc, 0);
    for (i = 0; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_call(L, 1, 1);
    return 1;
}

int $LUAOPEN_FN(lua_State* L);

/* main function, based on srlua */
int main(int argc, char** argv) {
    int ret;
    lua_State* L;
    getprogname();
    if (argv[0] == NULL) {
        fatal("cannot locate this executable");
    }
    L = luaL_newstate();
    if (L == NULL) {
        fatal("not enough memory for state");
    }
    luaL_openlibs(L);
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    lua_pushcfunction(L, $LUAOPEN_FN);
    lua_setfield(L, -2, "$MODNAME");
    lua_pushcfunction(L, errorhandler);
    lua_pushcfunction(L, pmain);
    lua_pushinteger(L, argc);
    lua_pushlightuserdata(L, argv);
    /* Protected mode with Titan's runtime errorhandler installed. On failure,
    ** errorhandler captures the raw unified Lua+Titan trace into
    ** registry[TITAN_BACKTRACE_KEY] and returns the original error object, so it
    ** is still available here after lua_pcall. main() then adds the standalone
    ** Lua-style presentation: "<progname>: <message>", "stack traceback:", and
    ** the raw trace with a tab prepended to each frame line. */
    if (lua_pcall(L, 2, 1, -4) != 0) {
        const char *report;
        if (lua_getfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY) == LUA_TSTRING) {
            const char *trace = lua_tostring(L, -1);
            report_titan_error(errmsg_tostring(L, -2), trace);
        } else {
            lua_pop(L, 1);                 /* nil/non-string slot */
            report = errmsg_tostring(L, -1);
        }
        fatal(report);
    }
    ret = lua_tointeger(L, -1);
    lua_close(L);
    return ret;
}

]]

local function write_entrypoint(modname)
    local entrypoint_c = modname:gsub("[.]", "/") .. "__entrypoint.c"
    local fd, err = io.open(entrypoint_c, "w")
    if not fd then return nil, err end
    local _, err = fd:write(util.render(entrypoint_template, {
        PROGNAME = modname:gsub(".*[.]", ""),
        LUAOPEN_FN = "luaopen_" .. modname:gsub("[.]", "_"),
        MODNAME = modname,
    }))
    if err then return nil, err end
    fd:close()
    return entrypoint_c
end

function driver.compile_library(modname, libnames, link, verbose)
    local soname = modname:gsub("[.]", "/") .. ".so"
    os.remove(soname)

    local args = {driver.CC, driver.CFLAGS, shared_flag(), "-o", soname}
    for _, libname in ipairs(libnames) do
        table.insert(args, libname)
    end

    table.insert(args, driver.TITAN_RUNTIME_PATH .. "titan.o")

    table.insert(args, driver.LIBBACKTRACE_PATH .. "/.libs/libbacktrace.a")
    table.insert(args, driver.LUA_SOURCE_PATH .. "/liblua.a")
    table.insert(args, "-ldl")
    table.insert(args, "-lm")

    if link then
        local libs = util.split_string(link, ",")
        for _, lib in ipairs(libs) do
            table.insert(args, "-l" .. lib)
        end
    end

    local cmd = table.concat(args, " ")
    if verbose then
        print(cmd)
    end
    local ok, term, code = os.execute(cmd)
    run_dsymutil(soname, verbose)
    return ok, term, code
end

function driver.compile_program(modname, libnames, link, verbose)
    local execname = modname:gsub("[.]", "/")
    os.remove(execname)

    local entrypoint_c, err = write_entrypoint(modname)
    if err then return nil, err end

    local args = {driver.CC, driver.CFLAGS, "-o", execname,
                "-I", driver.TITAN_RUNTIME_PATH, "-I", driver.LUA_SOURCE_PATH,
                entrypoint_c}
    for _, libname in ipairs(libnames) do
        table.insert(args, libname)
    end

    table.insert(args, driver.TITAN_RUNTIME_PATH .. "titan.o")

    table.insert(args, driver.LIBBACKTRACE_PATH .. "/.libs/libbacktrace.a")
    table.insert(args, driver.LUA_SOURCE_PATH .. "/liblua.a")
    table.insert(args, "-ldl")
    table.insert(args, "-lm")
    if link then
        local libs = util.split_string(link, ",")
        for _, lib in ipairs(libs) do
            table.insert(args, "-l" .. lib)
        end
    end
    local cmd = table.concat(args, " ")
    if verbose then
        print(cmd)
    end
    local ok, term, code = os.execute(cmd)
    run_dsymutil(execname, verbose)
    return ok, term, code
end

return driver
