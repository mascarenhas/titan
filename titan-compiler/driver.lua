local parser = require  "titan-compiler.parser"
local util = require "titan-compiler.util"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local pretty = require "titan-compiler.pretty"
local types = require "titan-compiler.types"
local cdriver = require "c-parser.cdriver"

local lfs = require "lfs"

local driver = {}

driver.imported = {}

driver.TITAN_VER = "0.11"
driver.TITAN_VER_SUFFIX = "_0_11"
local function package_cpath_dirs()
    local dirs = {}
    for template in package.cpath:gmatch("[^;]+") do
        local q = template:find("?", 1, true)
        if q then
            local dir = template:sub(1, q - 1):gsub("[/\\]*$", "")
            if dir ~= "" then
                table.insert(dirs, dir)
            end
        end
    end
    return table.concat(dirs, ";")
end

local DEFAULT_TITAN_BIN_PATH = ".;/usr/local/lib/titan/" .. driver.TITAN_VER
local cpath_dirs = package_cpath_dirs()
if cpath_dirs ~= "" then
    DEFAULT_TITAN_BIN_PATH = DEFAULT_TITAN_BIN_PATH .. ";" .. cpath_dirs
end

driver.TITAN_BIN_PATH = os.getenv("TITAN_PATH" .. driver.TITAN_VER_SUFFIX)
    or os.getenv("TITAN_PATH")
    or DEFAULT_TITAN_BIN_PATH
driver.TITAN_SOURCE_PATH = "."
driver.TITAN_STDLIB_SOURCE_PATH = os.getenv("TITAN_STDLIB_SOURCE_PATH")
    or "stdlib"
driver.TITAN_STDLIB_PATH = os.getenv("TITAN_STDLIB_PATH")
    or ("/usr/local/lib/titan/" .. driver.TITAN_VER)
driver.STANDARD_DEPENDENCY = "standard"
driver.STANDARD_MODULES = {
    coroutine = true,
    uv = true,
    timer = true,
    fs = true,
    net = true,
    os = true,
}
driver.LUA_SOURCE_PATH = "lua-5.5.0/src/"
driver.TITAN_RUNTIME_PATH = "titan-runtime/"
driver.LIBBACKTRACE_PATH = "libbacktrace"
-- -g emits DWARF (carries the #line file/line a traceback needs) and
-- -fno-optimize-sibling-calls keeps tail frames on the stack so libbacktrace
-- can unwind them.
driver.CFLAGS = "--std=c99 -O2 -Wall -fPIC -g -fno-optimize-sibling-calls"
driver.CC = os.getenv("CC") or "cc"

driver.split_shell_words = cdriver.split_shell_words
driver.shell_quote = cdriver.shell_quote

local function parse_extra_flags(name)
    local words, err = cdriver.split_shell_words(os.getenv(name) or "")
    if not words then
        return nil, "invalid " .. name .. ": " .. err
    end
    return words
end

local cppflags_error, cflags_error, ldflags_error
driver.EXTRA_CPPFLAGS, cppflags_error =
    parse_extra_flags("TITAN_EXTRA_CPPFLAGS")
driver.EXTRA_CFLAGS, cflags_error =
    parse_extra_flags("TITAN_EXTRA_CFLAGS")
driver.EXTRA_LDFLAGS, ldflags_error =
    parse_extra_flags("TITAN_EXTRA_LDFLAGS")
driver.TOOLCHAIN_ERROR = cppflags_error or cflags_error or ldflags_error

function driver.configure_foreign_c()
    checker.configure_foreign_c({
        compiler = driver.CC,
        language_mode = "c99",
        cppflags = driver.EXTRA_CPPFLAGS or {},
        compiler_include_dirs = {
            driver.TITAN_RUNTIME_PATH,
            driver.LUA_SOURCE_PATH,
        },
    }, driver.TOOLCHAIN_ERROR)
end

driver.configure_foreign_c()

local CIRCULAR_MARK = {}

local function shell(cmd)
    local p = assert(io.popen(cmd))
    local out = p:read("*a")
    p:close()
    return out
end

local function append_argv(dst, src)
    for _, arg in ipairs(src or {}) do
        table.insert(dst, arg)
    end
end

local function parsed_words(value, label)
    local words, err = cdriver.split_shell_words(value or "")
    if not words then
        return nil, "invalid " .. label .. ": " .. err
    end
    return words
end

local function command_argv(argv)
    local quoted = {}
    for i, arg in ipairs(argv) do
        local word, err = cdriver.shell_quote(arg)
        if not word then return nil, err end
        quoted[i] = word
    end
    return table.concat(quoted, " ")
end

local function run_argv(argv, verbose)
    local cmd, err = command_argv(argv)
    if not cmd then return nil, err end
    if verbose then print(cmd) end
    return os.execute(cmd)
end

local function compiler_argv(include_extra_compile_flags)
    if driver.TOOLCHAIN_ERROR then return nil, driver.TOOLCHAIN_ERROR end
    local cc, err = parsed_words(driver.CC, "CC")
    if not cc then return nil, err end
    if #cc == 0 then return nil, "CC command is empty" end
    local cflags
    cflags, err = parsed_words(driver.CFLAGS, "compiler defaults")
    if not cflags then return nil, err end
    local argv = {}
    append_argv(argv, cc)
    if include_extra_compile_flags then
        append_argv(argv, driver.EXTRA_CPPFLAGS)
    end
    append_argv(argv, cflags)
    if include_extra_compile_flags then
        append_argv(argv, driver.EXTRA_CFLAGS)
    end
    return argv
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
    run_argv({ "dsymutil", output }, verbose)
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

local function findmodules(paths, modname, extension)
    local found = {}
    local modf = modname:gsub("[.]", "/") .. extension
    for path in paths:gmatch("[^;]+") do
        local filename = path .. "/" .. modf
        local attr = lfs.attributes(filename)
        if attr then
            table.insert(found, { mtime = attr.modification, filename = filename })
        end
    end
    return found
end

local function same_file(a, b)
    if not a or not b then return false end
    local aa, ba = lfs.attributes(a), lfs.attributes(b)
    if aa and ba and aa.dev and aa.ino and ba.dev and ba.ino then
        return aa.dev == ba.dev and aa.ino == ba.ino
    end
    local function normalize(path)
        if path:sub(1, 1) ~= "/" then
            path = lfs.currentdir() .. "/" .. path
        end
        local parts = {}
        for part in path:gmatch("[^/]+") do
            if part == ".." then
                if #parts > 0 then table.remove(parts) end
            elseif part ~= "." and part ~= "" then
                table.insert(parts, part)
            end
        end
        return "/" .. table.concat(parts, "/")
    end
    return normalize(a) == normalize(b)
end

local function load_compiled_interface(modname, binf)
    local prefix = modname:gsub("[%-.]", "_")
    local abif, err = package.loadlib(binf, prefix .. "_abi")
    if not abif then
        return nil, "compiled module '" .. modname
            .. "' has no compatible Titan ABI marker (expected "
            .. driver.TITAN_VER .. "): " .. tostring(err)
    end
    local ok, abi_or_err = pcall(abif)
    if not ok then return nil, abi_or_err end
    if abi_or_err ~= driver.TITAN_VER then
        return nil, "compiled module '" .. modname
            .. "' ABI mismatch: expected " .. driver.TITAN_VER
            .. " but found " .. tostring(abi_or_err)
    end
    local typesf, terr = package.loadlib(binf, prefix .. "_types")
    if not typesf then return nil, terr end
    local tok, types_or_err = pcall(typesf)
    if not tok then return nil, types_or_err end
    local modtf, lerr = load("return " .. types_or_err, modname, "t", types)
    if not modtf then return nil, lerr end
    local mok, modt_or_err = pcall(modtf)
    if not mok then return nil, modt_or_err end
    return modt_or_err
end

function driver.defaultloader(static_deps, options)
    static_deps = static_deps or {}
    options = options or {}
    local dependency_stack = {}

    local function remember_dependency_closure(modname, seen)
        seen = seen or {}
        if seen[modname] then return end
        seen[modname] = true
        local mod = driver.imported[modname]
        if not mod or mod == CIRCULAR_MARK then return end
        if mod.ast then
            static_deps[modname] = true
            for depname, origin in pairs(mod.deps or {}) do
                static_deps[depname] = origin
                if origin == true then
                    remember_dependency_closure(depname, seen)
                end
            end
        elseif mod.origin == "standard" then
            static_deps[modname] = driver.STANDARD_DEPENDENCY
        end
    end

    local function remember_direct_dependency(modname)
        local direct = dependency_stack[#dependency_stack]
        if not direct then return end
        local mod = driver.imported[modname]
        if mod and mod ~= CIRCULAR_MARK then
            if mod.ast then
                direct[modname] = true
            elseif mod.origin == "standard" then
                direct[modname] = driver.STANDARD_DEPENDENCY
            end
        end
    end

    local function parse_source(modname, srcf, loader, origin)
        local input, err = util.get_file_contents(srcf)
        if not input then return false, err end
        local ast, perr = parser.parse(srcf, input)
        if not ast then return false, parser.error_to_string(perr, srcf) end
        driver.imported[modname] = CIRCULAR_MARK
        local direct_deps = {}
        table.insert(dependency_stack, direct_deps)
        local modt, errors = checker.check(modname, ast, input, srcf, loader)
        table.remove(dependency_stack)
        driver.imported[modname] = {
            ast = ast,
            type = modt,
            filename = srcf,
            origin = origin,
            deps = direct_deps,
        }
        static_deps[modname] = true
        return true, modt, errors
    end

    local function standard_conflict(modname, canonical_bin)
        local _, canonical_src = findmodule(
            options.stdlib_source_path or driver.TITAN_STDLIB_SOURCE_PATH,
            modname, ".titan")
        for _, match in ipairs(findmodules(
            driver.TITAN_SOURCE_PATH, modname, ".titan")) do
            if not same_file(match.filename, canonical_src) then
                return "reserved standard module '" .. modname
                    .. "' is shadowed by application source '"
                    .. match.filename .. "'"
            end
        end
        for _, match in ipairs(findmodules(
            driver.TITAN_BIN_PATH, modname, ".so")) do
            if not same_file(match.filename, canonical_bin) then
                return "reserved standard module '" .. modname
                    .. "' is shadowed by local binary '"
                    .. match.filename .. "'"
            end
        end
        return nil
    end

    local function loader(modname)
        if driver.imported[modname] == CIRCULAR_MARK then
            driver.imported[modname] = nil
            return false, "circular reference to module"
        end
        if driver.imported[modname] then
            local mod = driver.imported[modname]
            remember_dependency_closure(modname)
            remember_direct_dependency(modname)
            return true, mod.type, {}
        end

        if driver.STANDARD_MODULES[modname] then
            if options.stdlib_build_root == modname then
                local _, srcf = findmodule(
                    options.stdlib_source_path or driver.TITAN_STDLIB_SOURCE_PATH,
                    modname, ".titan")
                if not srcf then
                    return false, "standard module source '" .. modname
                        .. ".titan' not found under '"
                        .. (options.stdlib_source_path
                            or driver.TITAN_STDLIB_SOURCE_PATH) .. "'"
                end
                local ok, modt, errors = parse_source(
                    modname, srcf, loader, "standard")
                if ok then remember_direct_dependency(modname) end
                return ok, modt, errors
            end

            local _, binf = findmodule(
                options.stdlib_path or driver.TITAN_STDLIB_PATH,
                modname, ".so")
            local conflict = standard_conflict(modname, binf)
            if conflict then return false, conflict end
            if not binf then
                return false, "standard module '" .. modname
                    .. "' is not installed under TITAN_STDLIB_PATH ('"
                    .. (options.stdlib_path or driver.TITAN_STDLIB_PATH)
                    .. "'); run 'make stdlib' or configure TITAN_STDLIB_PATH"
            end
            local modt, err = load_compiled_interface(modname, binf)
            if not modt then return false, err end
            driver.imported[modname] = {
                type = modt,
                compiled = true,
                filename = binf,
                origin = "standard",
            }
            static_deps[modname] = driver.STANDARD_DEPENDENCY
            remember_direct_dependency(modname)
            return true, modt, {}
        end

        local mtime_bin, binf = findmodule(driver.TITAN_BIN_PATH, modname, ".so")
        local mtime_src, srcf = findmodule(driver.TITAN_SOURCE_PATH, modname, ".titan")
        if mtime_bin and binf and ((not mtime_src) or mtime_bin >= mtime_src) then
            local modt_or_err, err = load_compiled_interface(modname, binf)
            if not modt_or_err then return false, err end
            driver.imported[modname] = { type = modt_or_err, compiled = true }
            return true, modt_or_err, {}
        end
        if not mtime_src then return false, "module '" .. modname .. "' not found" end
        local ok, modt, errors = parse_source(
            modname, srcf, loader, "application")
        if ok then remember_direct_dependency(modname) end
        return ok, modt, errors
    end
    return loader
end

function driver.dependency_closure(modname)
    local closure = {}
    local seen = {}
    local function visit(name)
        if seen[name] then return end
        seen[name] = true
        local mod = driver.imported[name]
        if not mod or mod == CIRCULAR_MARK then return end
        for depname, origin in pairs(mod.deps or {}) do
            closure[depname] = origin
            if origin == true then visit(depname) end
        end
    end
    closure[modname] = true
    visit(modname)
    return closure
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
        if #errors ~= 0 then
            imported[modname] = { ast = ast, type = modt, filename = modf }
            deps[modname] = true
            return true, modt, errors
        end
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
    local shared = { "-shared" }
    if string.match(driver.UNAME, "Darwin") then
        table.insert(shared, "-undefined")
        table.insert(shared, "dynamic_lookup")
    end
    return shared
end

local function static_flag()
    return "-c"
end

function driver.compile_module(modname, mod, static_deps, verbose, options)
    if mod.compiled then return true, nil, nil end
    local ok, err, libname = driver.compile(
        modname, mod.ast, mod.filename, static_deps, verbose, options)
    if not ok then return nil, err end
    mod.compiled = libname
    return true, nil, libname
end

local function check_runtime(verbose)
    local runtime_c = driver.TITAN_RUNTIME_PATH .. "titan.c"
    local runtime_o = driver.TITAN_RUNTIME_PATH .. "titan.o"
    local titanc_mtime = lfs.attributes(runtime_c, "modification")
    local titano_mtime = lfs.attributes(runtime_o, "modification")
    if (not titano_mtime) or (titano_mtime < titanc_mtime) then
        local args, err = compiler_argv(true)
        if not args then return nil, err end
        append_argv(args, { "-c", runtime_c,
            "-I", driver.TITAN_RUNTIME_PATH, "-I", driver.LUA_SOURCE_PATH,
            "-I", driver.LIBBACKTRACE_PATH, "-o", runtime_o })
        local ok, term, code = run_argv(args, verbose)
        if not ok then
            return nil, string.format("failed to compile Titan runtime (%s%s)",
                tostring(term), code and (", " .. tostring(code)) or "")
        end
    end
    return true
end

function driver.compile(modname, ast, sourcef, static_deps, verbose, options)
    local runtime_ok, runtime_err = check_runtime(verbose)
    if not runtime_ok then return nil, runtime_err end
    sourcef = sourcef or modname:gsub("[.]", "/") .. ".titan"
    static_deps = static_deps or {}
    local code = coder.generate(modname, ast, static_deps, options)
    code = pretty.reindent_c(code)
    local filename = sourcef:gsub("[.]titan$", "") .. ".c"
    local libname = sourcef:gsub("[.]titan$", "") .. ".o"
    os.remove(filename)
    os.remove(libname)
    local ok, err = util.set_file_contents(filename, code)
    if not ok then return nil, err end
    local args, flags_err = compiler_argv(true)
    if not args then return nil, flags_err end
    append_argv(args, { static_flag(), filename,
        "-I", driver.TITAN_RUNTIME_PATH, "-I", driver.LUA_SOURCE_PATH,
        "-I", driver.LIBBACKTRACE_PATH, "-o", libname })
    local ok, err = run_argv(args, verbose)
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

    /* Requiring the main module first initializes every transitive import. An
    ** async standard module may install the private bootstrap hook while that
    ** happens, but it must not change which main callable this executable
    ** invokes. Retrieve main before consulting the hook, then invoke either
    ** path inside main()'s existing outer lua_pcall. */
    lua_settop(L, 0);
    lua_getglobal(L, "require");
    lua_pushliteral(L, "$MODNAME");
    lua_call(L, 1, 1);
    lua_getfield(L, -1, "main");
    lua_remove(L, -2);                 /* leave the main callable */

    lua_createtable(L, argc, 0);
    for (i = 0; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }

    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_MAIN_BOOTSTRAP_KEY);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);                 /* direct path: main, arguments */
        lua_call(L, 1, 1);
    } else {
        lua_insert(L, 1);              /* hook, main, arguments */
        lua_call(L, 2, 1);
    }
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

function driver.compile_library(modname, libnames, link, verbose, extra_objects)
    local soname = modname:gsub("[.]", "/") .. ".so"
    os.remove(soname)

    local args, err = compiler_argv(false)
    if not args then return nil, err end
    append_argv(args, shared_flag())
    append_argv(args, { "-o", soname })
    for _, libname in ipairs(libnames) do
        table.insert(args, libname)
    end
    for _, object in ipairs(extra_objects or {}) do
        table.insert(args, object)
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
    append_argv(args, driver.EXTRA_LDFLAGS)

    local ok, term, code = run_argv(args, verbose)
    if ok then run_dsymutil(soname, verbose) end
    return ok, term, code
end

function driver.compile_program(modname, libnames, link, verbose, extra_objects)
    local execname = modname:gsub("[.]", "/")
    os.remove(execname)

    local entrypoint_c, err = write_entrypoint(modname)
    if err then return nil, err end
    local entrypoint_o = entrypoint_c:gsub("[.]c$", ".o")
    os.remove(entrypoint_o)

    local compile_args
    compile_args, err = compiler_argv(true)
    if not compile_args then return nil, err end
    append_argv(compile_args, { "-c", entrypoint_c,
        "-I", driver.TITAN_RUNTIME_PATH, "-I", driver.LUA_SOURCE_PATH,
        "-o", entrypoint_o })
    local compiled, cterm, ccode = run_argv(compile_args, verbose)
    if not compiled then return nil, cterm, ccode end

    local args
    args, err = compiler_argv(false)
    if not args then return nil, err end
    append_argv(args, { "-o", execname, entrypoint_o })
    for _, libname in ipairs(libnames) do
        table.insert(args, libname)
    end
    for _, object in ipairs(extra_objects or {}) do
        table.insert(args, object)
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
    append_argv(args, driver.EXTRA_LDFLAGS)
    local ok, term, code = run_argv(args, verbose)
    if ok then run_dsymutil(execname, verbose) end
    return ok, term, code
end

return driver
