local parser = require  "titan-compiler.parser"
local util = require "titan-compiler.util"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local pretty = require "titan-compiler.pretty"
local types = require "titan-compiler.types"
local location = require "titan-compiler.location"
local cdriver = require "c-parser.cdriver"

local lfs = require "lfs"

local driver = {}

driver.imported = {}

driver.TITAN_VER = "0.15"
driver.TITAN_VER_SUFFIX = "_0_15"
driver.LUA_VERSION = "5.5"

local LUA_CPATH_SUFFIX = "/lib/lua/" .. driver.LUA_VERSION .. "/?.so"

-- Return the installation prefix encoded by the first canonical Lua C-module
-- template. Deliberately do not accept a merely similar template: this is the
-- one layout established by Titan's prefix-owned Lua installation.
function driver.root_from_package_cpath(cpath)
    if type(cpath) ~= "string" then return nil end
    for template in (cpath .. ";"):gmatch("(.-);") do
        if #template >= #LUA_CPATH_SUFFIX and
           template:sub(-#LUA_CPATH_SUFFIX) == LUA_CPATH_SUFFIX then
            local root = template:sub(1, #template - #LUA_CPATH_SUFFIX)
            return root ~= "" and root or "/"
        end
    end
    return nil
end

local function normalize_root(root)
    if type(root) ~= "string" or root == "" then return nil end
    if root:sub(1, 1) ~= "/" then
        root = lfs.currentdir() .. "/" .. root
    end
    root = root:gsub("/+$", "")
    return root ~= "" and root or "/"
end

function driver.resolve_installation_root(cpath, override)
    if override == "" then override = nil end
    return normalize_root(override or driver.root_from_package_cpath(cpath))
end

local function root_join(root, suffix)
    if root == "/" then return "/" .. suffix end
    return root .. "/" .. suffix
end

function driver.installed_paths(root)
    root = normalize_root(root)
    if not root then return nil end
    local titan_lib = root_join(root, "lib/titan/" .. driver.TITAN_VER)
    return {
        root = root,
        lua_source = root_join(root, "src/lua-5.5.0"),
        include = root_join(root, "include"),
        lib = root_join(root, "lib"),
        libtitan = root_join(root, "lib/libtitan.a"),
        libbacktrace = root_join(root, "lib/libbacktrace.a"),
        liblua = root_join(root, "lib/liblua.a"),
        titan_bin = titan_lib,
        lua_cpath = titan_lib .. "/?.so",
    }
end

function driver.source_checkout_from_driver_source(source, current_dir)
    if type(source) ~= "string" then return false end
    if source:sub(1, 1) ~= "@" then return false end
    source = source:sub(2)
    if source:sub(1, 1) ~= "/" then
        source = (current_dir or lfs.currentdir()) .. "/" .. source
    end
    local root = source:match("^(.*)/titan%-compiler/driver[.]lua$")
    return root ~= nil and
        lfs.attributes(root .. "/titan-runtime/titan.c", "mode") == "file" and
        lfs.attributes(root .. "/Makefile", "mode") == "file"
end

local function is_source_checkout()
    if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then
        return false
    end
    return driver.source_checkout_from_driver_source(
        debug.getinfo(1, "S").source)
end

local internal_root = os.getenv("TITAN_ROCKS_ROOT")
if internal_root == "" then internal_root = nil end
driver.TITAN_ROOT = driver.resolve_installation_root(
    package.cpath, internal_root)
driver.SOURCE_CHECKOUT = not internal_root and is_source_checkout()
driver.INSTALLED = not driver.SOURCE_CHECKOUT
driver.INSTALL_PATHS = driver.installed_paths(driver.TITAN_ROOT)
driver.INSTALLATION_ERROR = driver.INSTALLED and not driver.INSTALL_PATHS and
    ("cannot locate the Titan installation: package.cpath has no entry ending "
        .. "in '" .. LUA_CPATH_SUFFIX .. "'") or nil

local default_titan_bin_path
if driver.INSTALL_PATHS then
    default_titan_bin_path = ".;" .. driver.INSTALL_PATHS.titan_bin
else
    default_titan_bin_path = ".;/usr/local/lib/titan/" .. driver.TITAN_VER
end

driver.TITAN_BIN_PATH = os.getenv("TITAN_PATH" .. driver.TITAN_VER_SUFFIX)
    or os.getenv("TITAN_PATH")
    or default_titan_bin_path
driver.TITAN_SOURCE_PATH = "."
driver.LUA_SOURCE_PATH = driver.INSTALLED and driver.INSTALL_PATHS and
    driver.INSTALL_PATHS.lua_source or "lua-5.5.0/src"
driver.TITAN_RUNTIME_PATH = "titan-runtime/"
driver.LIBBACKTRACE_PATH = "libbacktrace"
driver.INCLUDE_PATH = driver.INSTALLED and driver.INSTALL_PATHS and
    driver.INSTALL_PATHS.include or nil
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
driver.TOOLCHAIN_ERROR = driver.INSTALLATION_ERROR or cppflags_error or
    cflags_error or ldflags_error

function driver.configure_foreign_c()
    local include_dirs
    if driver.INSTALLED then
        include_dirs = { driver.INCLUDE_PATH, driver.LUA_SOURCE_PATH }
    else
        include_dirs = {
            driver.TITAN_RUNTIME_PATH,
            driver.LUA_SOURCE_PATH,
        }
    end
    checker.configure_foreign_c({
        compiler = driver.CC,
        language_mode = "c99",
        cppflags = driver.EXTRA_CPPFLAGS or {},
        compiler_include_dirs = include_dirs,
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
        if lfs.attributes(filename, "mode") then return filename end
    end
    return nil
end

local function regular_file(filename)
    return lfs.attributes(filename, "mode") == "file"
end

local function source_resolution_in_root(root, modname)
    local module_path = modname:gsub("[.]", "/")
    local basename = modname:match("([^.]+)$")
    if not basename then return nil end
    local folder = root .. "/" .. module_path
    local folder_main = folder .. "/" .. basename .. ".titan"

    if regular_file(folder_main) then
        local opened, iterator, state = pcall(lfs.dir, folder)
        if not opened or type(iterator) ~= "function" then
            local detail = opened and state or iterator
            return nil, "cannot enumerate folder module '" .. modname ..
                "' at '" .. folder_main .. "': " .. tostring(detail)
        end

        local contributors = {}
        local enumerated, enumeration_error = pcall(function()
            for name in iterator, state do
                if name ~= basename .. ".titan" and
                   name:sub(-6) == ".titan" and
                   regular_file(folder .. "/" .. name) then
                    table.insert(contributors, name)
                end
            end
        end)
        if not enumerated then
            return nil, "cannot enumerate folder module '" .. modname ..
                "' at '" .. folder_main .. "': " ..
                tostring(enumeration_error)
        end
        table.sort(contributors, util.bytewise_less)

        local files = { folder_main }
        for _, name in ipairs(contributors) do
            table.insert(files, folder .. "/" .. name)
        end
        return {
            kind = "folder",
            main = folder_main,
            files = files,
            program_output = module_path .. "__main",
        }
    end

    local flat = root .. "/" .. module_path .. ".titan"
    if not regular_file(flat) then return nil end

    local owner = modname:match("^(.*)[.][^.]+$")
    if owner then
        local owner_path = owner:gsub("[.]", "/")
        local owner_basename = owner:match("([^.]+)$")
        if not owner_basename then return nil end
        local owner_main = root .. "/" .. owner_path .. "/" ..
            owner_basename .. ".titan"
        if regular_file(owner_main) then
            return {
                kind = "blocked",
                owner = owner,
                main = owner_main,
                contributor = flat,
            }
        end
    end

    return {
        kind = "flat",
        main = flat,
        files = { flat },
        program_output = module_path,
    }
end

local function resolve_source(paths, modname)
    for root in paths:gmatch("[^;]+") do
        local source, err = source_resolution_in_root(root, modname)
        if source or err then return source, err end
    end
    return nil
end

local function blocked_source_error(modname, source)
    return "source module '" .. modname .. "' cannot be loaded directly: " ..
        "constituent '" .. source.contributor .. "' belongs to folder module '" ..
        source.owner .. "' whose main source is '" .. source.main .. "'"
end

local function load_compiled_interface(modname, binf)
    local prefix = modname:gsub("[%-.]", "_")
    local loadlib = require("titan")._loadlib
    local abif, err = loadlib(binf, prefix .. "_abi")
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
    local typesf, terr = loadlib(binf, prefix .. "_types")
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
    local source_roots = options.source_roots or {}
    local dependency_stack = {}

    local function remember_dependency_closure(modname, seen)
        seen = seen or {}
        if seen[modname] then return end
        seen[modname] = true
        local mod = driver.imported[modname]
        if not mod or mod == CIRCULAR_MARK then return end
        if mod.ast then
            static_deps[modname] = true
            for depname in pairs(mod.deps or {}) do
                static_deps[depname] = true
                remember_dependency_closure(depname, seen)
            end
        end
    end

    local function remember_direct_dependency(modname)
        local direct = dependency_stack[#dependency_stack]
        if not direct then return end
        local mod = driver.imported[modname]
        if mod and mod ~= CIRCULAR_MARK and mod.ast then
            direct[modname] = true
        end
    end

    local function parse_source(modname, source, loader)
        local ast = {}
        local main_input
        local main_initializer

        for index, filename in ipairs(source.files) do
            local input, err = util.get_file_contents(filename)
            if not input then return false, err end
            local nodes, perr = parser.parse(filename, input)
            if not nodes then
                return false, parser.error_to_string(perr, filename)
            end

            if index == 1 then
                main_input = input
                if nodes[#nodes] and
                   nodes[#nodes]._module_initializer then
                    main_initializer = table.remove(nodes)
                end
            else
                for _, node in ipairs(nodes) do
                    if node._module_initializer then
                        return false, location.format_error(node.loc,
                            "module initializer is only allowed in the " ..
                            "folder main source '%s'", source.main)
                    end
                end
            end

            for _, node in ipairs(nodes) do table.insert(ast, node) end
        end
        if main_initializer then table.insert(ast, main_initializer) end

        driver.imported[modname] = CIRCULAR_MARK
        local direct_deps = {}
        table.insert(dependency_stack, direct_deps)
        local modt, errors = checker.check(
            modname, ast, main_input, source.main, loader)
        table.remove(dependency_stack)
        driver.imported[modname] = {
            ast = ast,
            type = modt,
            filename = source.main,
            program_output = source.program_output,
            deps = direct_deps,
        }
        static_deps[modname] = true
        return true, modt, errors
    end

    local function loader(modname)
        if driver.imported[modname] == CIRCULAR_MARK then
            return false, "circular reference to module"
        end
        if source_roots[modname] and driver.imported[modname] and
           not driver.imported[modname].ast then
            -- An explicit root is a source build request even if this
            -- long-lived compiler process saw its binary as an earlier
            -- dependency. Dependencies remain unconditionally binary-first.
            driver.imported[modname] = nil
        end
        if driver.imported[modname] then
            local mod = driver.imported[modname]
            remember_dependency_closure(modname)
            remember_direct_dependency(modname)
            return true, mod.type, {}
        end

        local source, source_err
        if source_roots[modname] then
            source, source_err = resolve_source(
                driver.TITAN_SOURCE_PATH, modname)
            if source_err then return false, source_err end
            if not source then
                return false, "source module '" .. modname .. "' not found"
            end
            if source.kind == "blocked" then
                return false, blocked_source_error(modname, source)
            end
            local ok, modt, errors = parse_source(modname, source, loader)
            if ok then remember_direct_dependency(modname) end
            return ok, modt, errors
        end

        local binf = findmodule(driver.TITAN_BIN_PATH, modname, ".so")
        if binf then
            local modt_or_err, err = load_compiled_interface(modname, binf)
            if not modt_or_err then return false, err end
            driver.imported[modname] = {
                type = modt_or_err,
                compiled = true,
                filename = binf,
            }
            remember_direct_dependency(modname)
            return true, modt_or_err, {}
        end
        source, source_err = resolve_source(driver.TITAN_SOURCE_PATH, modname)
        if source_err then return false, source_err end
        if not source then return false, "module '" .. modname .. "' not found" end
        if source.kind == "blocked" then
            return false, blocked_source_error(modname, source)
        end
        local ok, modt, errors = parse_source(modname, source, loader)
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
        for depname in pairs(mod.deps or {}) do
            closure[depname] = true
            visit(depname)
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

function driver.compile_module(modname, mod, static_deps, verbose)
    if mod.compiled then return true, nil, nil end
    local ok, err, libname = driver.compile(
        modname, mod.ast, mod.filename, static_deps, verbose)
    if not ok then return nil, err end
    mod.compiled = libname
    return true, nil, libname
end

local RUNTIME_ARCHIVE_INPUTS = {
    "titan.c",
    "titan.h",
    "titan_longjmp.h",
    "titan_coro.c",
    "minicoro.h",
    "titan/coro.h",
    "titan/ffi.h",
    "titan_uv.c",
    "titan/uv.h",
}
local RUNTIME_ARCHIVE_MEMBERS = {
    "titan.o",
    "titan_coro.o",
    "titan_uv.o",
}

local function is_archive_symbol_index(member)
    -- BSD/Darwin `ar t` exposes ranlib's generated symbol-table pseudo-member;
    -- GNU `ar t` hides its equivalent. Neither is a runtime object.
    return member == "__.SYMDEF" or
        member == "__.SYMDEF SORTED" or
        member == "__.SYMDEF_64" or
        member == "__.SYMDEF_64 SORTED"
end

function driver.runtime_archive_members_are_exact(output)
    if type(output) ~= "string" then return false end
    local members = {}
    for member in output:gmatch("[^\r\n]+") do
        if not is_archive_symbol_index(member) then
            table.insert(members, member)
        end
    end
    if #members ~= #RUNTIME_ARCHIVE_MEMBERS then return false end
    for index, expected in ipairs(RUNTIME_ARCHIVE_MEMBERS) do
        if members[index] ~= expected then return false end
    end
    return true
end

local function runtime_archive_has_expected_members(runtime_lib)
    local ar, err = parsed_words(os.getenv("AR") or "ar", "AR")
    if not ar then return false, err end
    if #ar == 0 then return false, "AR command is empty" end
    append_argv(ar, { "t", runtime_lib })
    local cmd
    cmd, err = command_argv(ar)
    if not cmd then return false, err end
    local pipe, popen_err = io.popen(cmd .. " 2>&1", "r")
    if not pipe then return false, popen_err end
    local output = pipe:read("*a")
    local ok = pipe:close()
    return ok == true and driver.runtime_archive_members_are_exact(output),
        output
end

local function runtime_archive_is_current(runtime_lib)
    local archive_mtime = lfs.attributes(runtime_lib, "modification")
    if not archive_mtime then return false end
    for _, relative in ipairs(RUNTIME_ARCHIVE_INPUTS) do
        local input_mtime = lfs.attributes(
            driver.TITAN_RUNTIME_PATH .. relative, "modification")
        if input_mtime and input_mtime > archive_mtime then return false end
    end
    return true
end

local runtime_checked = false

local function check_runtime(verbose)
    if driver.INSTALLED then return true end
    if runtime_checked then return true end
    local runtime_lib = driver.TITAN_RUNTIME_PATH .. "libtitan.a"
    if os.getenv("TITAN_RUNTIME_PREBUILT") ~= "1" then
        local make, err = parsed_words(os.getenv("MAKE") or "make", "MAKE")
        if not make then return nil, err end
        if #make == 0 then return nil, "MAKE command is empty" end
        append_argv(make, {
            "--no-print-directory",
            "TITAN_RUNTIME_LUA_SOURCE_PATH=" .. driver.LUA_SOURCE_PATH,
            runtime_lib,
        })
        local ok, term, code = run_argv(make, verbose)
        if not ok then
            return nil, string.format("failed to build Titan runtime (%s%s)",
                tostring(term), code and (", " .. tostring(code)) or "")
        end
    end
    if not runtime_archive_is_current(runtime_lib) then
        return nil, "Titan runtime build did not produce a current '" ..
            runtime_lib .. "'"
    end
    local exact, archive_err =
        runtime_archive_has_expected_members(runtime_lib)
    if not exact then
        return nil, "Titan runtime archive has invalid members: " ..
            tostring(archive_err)
    end
    runtime_checked = true
    return true
end

local function append_compile_includes(args)
    if driver.INSTALLED then
        append_argv(args, {
            "-I", driver.INCLUDE_PATH,
            "-I", driver.LUA_SOURCE_PATH,
        })
    else
        append_argv(args, {
            "-I", driver.TITAN_RUNTIME_PATH,
            "-I", driver.LUA_SOURCE_PATH,
            "-I", driver.LIBBACKTRACE_PATH,
        })
    end
end

function driver.installed_link_inputs(paths, is_darwin)
    local inputs = {
        paths.libtitan,
        paths.libbacktrace,
    }
    table.insert(inputs, paths.liblua)
    if not is_darwin then
        table.insert(inputs, "-ldl")
    end
    table.insert(inputs, "-lm")
    return inputs
end

function driver.source_link_inputs(lua_source_path)
    lua_source_path = lua_source_path or driver.LUA_SOURCE_PATH
    return {
        driver.TITAN_RUNTIME_PATH .. "libtitan.a",
        driver.LIBBACKTRACE_PATH .. "/.libs/libbacktrace.a",
        lua_source_path .. "/liblua.a",
        "-ldl",
        "-lm",
    }
end

local function append_runtime_libraries(args)
    if driver.INSTALLED then
        local paths = driver.INSTALL_PATHS
        append_argv(args, driver.installed_link_inputs(
            paths, driver.IS_DARWIN))
    else
        append_argv(args, driver.source_link_inputs(driver.LUA_SOURCE_PATH))
    end
end

function driver.compile(modname, ast, sourcef, static_deps, verbose)
    local runtime_ok, runtime_err = check_runtime(verbose)
    if not runtime_ok then return nil, runtime_err end
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
    local args, flags_err = compiler_argv(true)
    if not args then return nil, flags_err end
    append_argv(args, { static_flag(), filename })
    append_compile_includes(args)
    append_argv(args, { "-o", libname })
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

    /* Publish the original process arguments before loading the main module.
    ** A transitive titan.uv import may pass them through uv_setup_args and
    ** replace the argv pointer in the private registry slot. Keeping that call
    ** in titan.uv leaves its canonical shared object as the sole libuv
    ** provider. */
    lua_pushinteger(L, argc);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_MAIN_ARGC_KEY);
    lua_pushlightuserdata(L, argv);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_MAIN_ARGV_KEY);

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

    /* uv_setup_args may return replacement storage. Use the pointer published
    ** by titan.uv when constructing the Titan argument table. */
    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_MAIN_ARGV_KEY);
    argv = lua_touserdata(L, -1);
    lua_pop(L, 1);

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
    titan_init_paths(L);
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

local function ensure_directory(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then return true end
    if mode then return nil, "output path '" .. path .. "' is not a directory" end

    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path then
        local ok, err = ensure_directory(parent)
        if not ok then return nil, err end
    end

    local ok, err = lfs.mkdir(path)
    if ok or lfs.attributes(path, "mode") == "directory" then return true end
    return nil, err
end

local function ensure_output_parent(filename)
    local parent = filename:match("^(.*)/[^/]+$")
    if not parent or parent == "" then return true end
    return ensure_directory(parent)
end

function driver.compile_library(modname, libnames, link, verbose, extra_objects)
    local runtime_ok, runtime_err = check_runtime(verbose)
    if not runtime_ok then return nil, runtime_err end
    local soname = modname:gsub("[.]", "/") .. ".so"
    local output_ok, output_err = ensure_output_parent(soname)
    if not output_ok then return nil, output_err end
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

    append_runtime_libraries(args)

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

function driver.compile_program(modname, libnames, link, verbose, extra_objects,
                                program_output)
    local runtime_ok, runtime_err = check_runtime(verbose)
    if not runtime_ok then return nil, runtime_err end
    local execname = program_output or modname:gsub("[.]", "/")
    local output_ok, output_err = ensure_output_parent(execname)
    if not output_ok then return nil, output_err end
    local entrypoint_name = modname:gsub("[.]", "/") .. "__entrypoint.c"
    output_ok, output_err = ensure_output_parent(entrypoint_name)
    if not output_ok then return nil, output_err end
    os.remove(execname)

    local entrypoint_c, err = write_entrypoint(modname)
    if err then return nil, err end
    local entrypoint_o = entrypoint_c:gsub("[.]c$", ".o")
    os.remove(entrypoint_o)

    local compile_args
    compile_args, err = compiler_argv(true)
    if not compile_args then return nil, err end
    append_argv(compile_args, { "-c", entrypoint_c })
    append_compile_includes(compile_args)
    append_argv(compile_args, { "-o", entrypoint_o })
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

    append_runtime_libraries(args)
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
