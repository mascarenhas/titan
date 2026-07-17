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

driver.TITAN_VER = "0.16"
driver.TITAN_VER_SUFFIX = "_0_16"
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
driver.DEFAULT_TITAN_BIN_PATH = default_titan_bin_path

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
    if not driver.IS_DARWIN then return true end
    return run_argv({ "dsymutil", output }, verbose)
end

-- Expand an explicit Titan binary path with the same `;;` default insertion
-- used by the native runtime's pushpath(). Empty path entries are separators,
-- not directories; callers split the expanded result with path_entries().
function driver.expand_titan_bin_path(path, default_path)
    default_path = default_path or driver.DEFAULT_TITAN_BIN_PATH
    if path == nil then return default_path end
    return (path:gsub(";;", function()
        return ";" .. default_path .. ";"
    end))
end

function driver.titan_bin_path_entries(path, default_path)
    local entries = {}
    local expanded = driver.expand_titan_bin_path(path, default_path)
    for entry in expanded:gmatch("[^;]+") do
        table.insert(entries, entry)
    end
    return entries
end

local function module_components(modname)
    if type(modname) ~= "string" or modname == "" then return {} end
    local components = {}
    for component in modname:gmatch("[^.]+") do
        table.insert(components, component)
    end
    if #components == 0 or table.concat(components, ".") ~= modname then
        return {}
    end
    return components
end

function driver.deduplicate_module_names(names)
    local unique = {}
    local seen = {}
    for _, name in ipairs(names or {}) do
        if not seen[name] then
            seen[name] = true
            table.insert(unique, name)
        end
    end
    return unique
end

-- Derive the physical provider for a no-main invocation from the longest
-- common sequence of complete dotted components. The returned root list is
-- deduplicated while retaining the CLI's first-occurrence order.
function driver.common_module_provider(names)
    local unique = driver.deduplicate_module_names(names)
    if #unique == 0 then return nil, unique end
    local prefix = module_components(unique[1])
    if #prefix == 0 then return nil, unique, unique[1], unique[1] end

    local prefix_length = #prefix
    for index = 2, #unique do
        local components = module_components(unique[index])
        local limit = math.min(prefix_length, #components)
        local shared = 0
        while shared < limit and
              prefix[shared + 1] == components[shared + 1] do
            shared = shared + 1
        end
        prefix_length = shared
        if prefix_length == 0 then
            return nil, unique, unique[1], unique[index]
        end
    end

    local provider = table.concat(prefix, ".", 1, prefix_length)
    return provider, unique
end

function driver.mangle_module_name(modname)
    return modname:gsub("[%-.]", "_")
end

-- Return shallowest-to-exact physical container candidates for one logical
-- module. Component boundaries are significant: a.b and a.bc share only a.
function driver.module_binary_candidates(modname)
    local components = module_components(modname)
    if #components == 0 then return {} end

    local candidates = {}
    local path = ""
    for index, component in ipairs(components) do
        path = index == 1 and component or (path .. "/" .. component)
        table.insert(candidates, path .. ".so")
    end
    return candidates
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

local function one_metadata_result(fn, label)
    local results = table.pack(pcall(fn))
    if not results[1] then return nil, tostring(results[2]) end
    if results.n ~= 2 or type(results[2]) ~= "string" then
        return nil, label .. " must return exactly one string"
    end
    return results[2]
end

local function validate_module_interface(modtype, modname)
    if type(modtype) ~= "table" or modtype._tag ~= "Type.Module" then
        return nil, "metadata did not deserialize to a Type.Module"
    end
    if modtype.name ~= modname then
        return nil, "returned type metadata for '" .. tostring(modtype.name) ..
            "' while loading module '" .. modname .. "'"
    end

    local expected_prefix = driver.mangle_module_name(modname) .. "_"
    local expected_file = modname:gsub("[.]", "/") .. ".so"
    if modtype.prefix ~= expected_prefix or modtype.file ~= expected_file or
       type(modtype.members) ~= "table" or
       type(modtype.type_members) ~= "table" then
        return nil, "metadata did not construct a canonical Type.Module"
    end

    local numeric_count, maximum_index = 0, 0
    for key in pairs(modtype.members) do
        if type(key) == "number" then
            if key < 1 or key % 1 ~= 0 then
                return nil, "module member list has an invalid index"
            end
            numeric_count = numeric_count + 1
            maximum_index = math.max(maximum_index, key)
        elseif type(key) ~= "string" then
            return nil, "module member table has an invalid key"
        end
    end
    if numeric_count ~= maximum_index then
        return nil, "module member list is not dense"
    end

    local names = {}
    for index = 1, maximum_index do
        local member = modtype.members[index]
        if type(member) ~= "table" or
           (member._tag ~= "Type.ModuleMember" and
            member._tag ~= "Type.ModuleVariable") or
           member.modname ~= modname or type(member.name) ~= "string" or
           member.name == "" or type(member.type) ~= "table" or
           type(member.type._tag) ~= "string" then
            return nil, "module member " .. index .. " has an invalid schema"
        end
        if names[member.name] then
            return nil, "module interface contains duplicate member '" ..
                member.name .. "'"
        end
        names[member.name] = member
        if modtype.members[member.name] ~= member then
            return nil, "module member map does not match member '" ..
                member.name .. "'"
        end
    end
    for key, member in pairs(modtype.members) do
        if type(key) == "string" and names[key] ~= member then
            return nil, "module member map contains an invalid entry '" ..
                key .. "'"
        end
    end
    for name, member in pairs(modtype.type_members) do
        if type(name) ~= "string" or name == "" or type(member) ~= "table" or
           type(member._tag) ~= "string" then
            return nil, "module type-member table has an invalid schema"
        end
    end

    -- This is also the canonical recursive schema walk for all serializable
    -- member types. It catches unknown tags and missing nested fields now,
    -- while this candidate's metadata claim is still the diagnostic subject.
    local serialized_ok, serialized_or_err = pcall(types.serialize, modtype)
    if not serialized_ok then
        return nil, "module interface is not serializable: " ..
            tostring(serialized_or_err)
    end
    return true
end

-- Probe one existing container for a logical module. A missing dlsym entry is
-- a membership absence; an open failure is terminal. Callers decide whether a
-- clean nonclaim is skippable (ancestor) or an error (exact candidate).
local function probe_compiled_interface(modname, binf)
    local prefix = driver.mangle_module_name(modname)
    local loadlib = require("titan")._loadlib
    local abiname = prefix .. "_abi"
    local typesname = prefix .. "_types"
    local abif, abierr, abistage = loadlib(binf, abiname)
    if not abif and abistage ~= nil and abistage ~= "init" then
        return "error", "cannot inspect compiled module '" .. modname ..
            "' in '" .. binf .. "': " .. tostring(abierr)
    end
    local typesf, typeserr, typesstage = loadlib(binf, typesname)
    if not typesf and typesstage ~= nil and typesstage ~= "init" then
        return "error", "cannot inspect compiled module '" .. modname ..
            "' in '" .. binf .. "': " .. tostring(typeserr)
    end

    if not abif and not typesf then
        return "nonclaim", {
            abi = abierr,
            types = typeserr,
        }
    elseif not abif or not typesf then
        local missing = not abif and abiname or typesname
        return "error", "compiled container '" .. binf .. "' claims module '" ..
            modname .. "' but is missing metadata symbol '" .. missing .. "'"
    end

    local abi_or_err, abi_call_err = one_metadata_result(
        abif, "compiled module ABI marker '" .. abiname .. "'")
    if not abi_or_err then return "error", abi_call_err end
    if abi_or_err ~= driver.TITAN_VER then
        return "error", "compiled module '" .. modname
            .. "' ABI mismatch: expected " .. driver.TITAN_VER
            .. " but found " .. tostring(abi_or_err)
    end

    local types_or_err, types_call_err = one_metadata_result(
        typesf, "compiled module type metadata '" .. typesname .. "'")
    if not types_or_err then return "error", types_call_err end
    local modtf, lerr = load("return " .. types_or_err, modname, "t", types)
    if not modtf then return "error", lerr end
    local mok, modt_or_err = pcall(modtf)
    if not mok then return "error", modt_or_err end
    local valid, validation_err =
        validate_module_interface(modt_or_err, modname)
    if not valid then
        return "error", "compiled container '" .. binf ..
            "' has invalid metadata for module '" .. modname .. "': " ..
            validation_err
    end
    return "valid", modt_or_err
end

local function join_path(root, relative)
    if root:sub(-1) == "/" then return root .. relative end
    return root .. "/" .. relative
end

-- Locate a compiled logical module inside shallow-to-exact containers. Search
-- is root-major so an earlier local exact module wins over a later installed
-- shallow bundle. Once a relative candidate exists in one root it shadows the
-- same relative pathname in all later roots, even when it is a clean nonclaim.
function driver.find_compiled_interface(paths, modname)
    local candidates = driver.module_binary_candidates(modname)
    if #candidates == 0 then return nil end
    local occupied = {}

    for _, root in ipairs(driver.titan_bin_path_entries(paths)) do
        local absolute_root = assert(normalize_root(root))
        for index, relative in ipairs(candidates) do
            if not occupied[relative] then
                local filename = join_path(absolute_root, relative)
                -- lstat semantics are intentional: a broken symlink or other
                -- occupied pathname is a broken selected candidate, not an
                -- invitation to fall through to a later Titan path root.
                if lfs.symlinkattributes(filename, "mode") then
                    occupied[relative] = true
                    local status, value =
                        probe_compiled_interface(modname, filename)
                    if status == "valid" then
                        value.file = relative
                        return value, filename, relative
                    elseif status == "error" then
                        return nil, value
                    elseif index == #candidates then
                        return nil, "compiled module '" .. modname ..
                            "' has no compatible Titan ABI marker (expected " ..
                            driver.TITAN_VER .. "): " ..
                            tostring(value and value.abi)
                    end
                end
            end
        end
    end
    return nil
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

        local modt_or_err, binf_or_err =
            driver.find_compiled_interface(driver.TITAN_BIN_PATH, modname)
        if modt_or_err then
            driver.imported[modname] = {
                type = modt_or_err,
                compiled = true,
                filename = binf_or_err,
            }
            remember_direct_dependency(modname)
            return true, modt_or_err, {}
        elseif binf_or_err then
            return false, binf_or_err
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

function driver.sibling_temporary_path(filename)
    local unique = os.tmpname()
    os.remove(unique)
    unique = unique:match("([^/]+)$") or unique:gsub("[^%w]", "_")
    return filename .. ".tmp." .. unique
end

-- Keep the linked image's basename identical to its eventual public basename.
-- This matters on macOS: dsymutil names the inner DWARF payload after the input
-- file, and libbacktrace later looks it up using the loaded DSO basename. The
-- random component therefore belongs in a sibling directory, not in the DSO.
function driver.staged_library_output(publicname)
    local parent_ok, parent_err = ensure_output_parent(publicname)
    if not parent_ok then return nil, parent_err end
    local basename = publicname:match("([^/]+)$")
    if not basename then return nil, "invalid library output path" end
    local directory = driver.sibling_temporary_path(publicname .. ".stage")
    local made, make_err = lfs.mkdir(directory)
    if not made then return nil, make_err end
    return directory .. "/" .. basename, directory
end

local function remove_path(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                local ok, err = remove_path(path .. "/" .. name)
                if not ok then return nil, err end
            end
        end
        return lfs.rmdir(path)
    elseif mode then
        return os.remove(path)
    end
    return true
end
driver.remove_path = remove_path

function driver.compile_library_output(soname, libnames, link, verbose,
                                       extra_objects)
    local runtime_ok, runtime_err = check_runtime(verbose)
    if not runtime_ok then return nil, runtime_err end
    local output_ok, output_err = ensure_output_parent(soname)
    if not output_ok then return nil, output_err end
    os.remove(soname)
    remove_path(soname .. ".dSYM")

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
    if ok then
        local dsym_ok, dsym_term, dsym_code = run_dsymutil(soname, verbose)
        if not dsym_ok then
            os.remove(soname)
            remove_path(soname .. ".dSYM")
            return nil, dsym_term, dsym_code
        end
    end
    return ok, term, code
end

function driver.compile_library(modname, libnames, link, verbose, extra_objects)
    local soname = modname:gsub("[.]", "/") .. ".so"
    return driver.compile_library_output(
        soname, libnames, link, verbose, extra_objects)
end

-- Publish a successfully validated sibling temporary DSO. On Darwin the
-- matching dSYM is staged first and restored if the final atomic DSO rename
-- fails; the public DSO pathname is the commit point.
function driver.publish_library(tempname, publicname)
    local dsym_backup
    local temp_dsym = tempname .. ".dSYM"
    local public_dsym = publicname .. ".dSYM"

    if driver.IS_DARWIN then
        if lfs.attributes(temp_dsym, "mode") ~= "directory" then
            return nil, "linked library '" .. tempname ..
                "' has no companion dSYM"
        end
        if lfs.attributes(public_dsym, "mode") then
            dsym_backup = driver.sibling_temporary_path(public_dsym .. ".old")
            local backed_up, backup_err = os.rename(public_dsym, dsym_backup)
            if not backed_up then return nil, backup_err end
        end
        local moved, move_err = os.rename(temp_dsym, public_dsym)
        if not moved then
            if dsym_backup then os.rename(dsym_backup, public_dsym) end
            return nil, move_err
        end
    end

    local published, publish_err = os.rename(tempname, publicname)
    if not published then
        if driver.IS_DARWIN then
            os.rename(public_dsym, temp_dsym)
            if dsym_backup then os.rename(dsym_backup, public_dsym) end
        end
        return nil, publish_err
    end

    if dsym_backup then remove_path(dsym_backup) end
    if not driver.IS_DARWIN then remove_path(public_dsym) end
    return true
end

local function absolute_filename(filename)
    if filename:sub(1, 1) == "/" then return filename end
    return lfs.currentdir() .. "/" .. filename
end

-- Verify every logical protocol exported by a newly linked container before
-- its public pathname is changed. Metadata functions are executed and decoded;
-- init/Lua entry points are resolved but deliberately not called.
function driver.validate_library_image(filename, module_names)
    filename = absolute_filename(filename)
    local loadlib = require("titan")._loadlib
    for _, modname in ipairs(module_names) do
        local status, value = probe_compiled_interface(modname, filename)
        if status ~= "valid" then
            if status == "nonclaim" then
                return nil, "linked container '" .. filename ..
                    "' does not contain metadata for module '" .. modname .. "'"
            end
            return nil, value
        end

        local prefix = driver.mangle_module_name(modname)
        for _, symbol in ipairs({
            prefix .. "_init",
            "luaopen_" .. prefix,
        }) do
            local fn, err = loadlib(filename, symbol)
            if not fn then
                return nil, "linked container '" .. filename ..
                    "' is missing entry '" .. symbol .. "': " .. tostring(err)
            end
        end
    end
    return true
end

local support_validation_script = [[
local image, result = ...

local function finish(ok, message)
    local out = assert(io.open(result, "wb"))
    out:write(message)
    out:close()
    os.exit(ok and 0 or 1)
end

local open, load_error = package.loadlib(image, "luaopen_titan")
if not open then
    finish(false, "cannot load luaopen_titan: " .. tostring(load_error))
end

local values = table.pack(pcall(open))
if not values[1] then
    finish(false, "luaopen_titan failed: " .. tostring(values[2]))
end
if values.n ~= 2 or type(values[2]) ~= "table" then
    finish(false, "luaopen_titan must return exactly one support table")
end
if type(values[2]._loadlib) ~= "function" or
   type(values[2]._loadlibglobal) ~= "function" then
    finish(false, "luaopen_titan support table must expose _loadlib and _loadlibglobal")
end
finish(true, "ok")
]]

local function current_lua_executable()
    if driver.INSTALL_PATHS then
        return root_join(driver.INSTALL_PATHS.root, "bin/lua")
    end
    local source_lua = driver.LUA_SOURCE_PATH .. "/lua"
    if lfs.attributes(source_lua, "mode") == "file" then return source_lua end
    if type(arg) == "table" and type(arg[-1]) == "string" and
       lfs.attributes(arg[-1], "mode") == "file" then
        return arg[-1]
    end
    return "lua"
end

-- Provider `titan` owns Lua's bare native support API. Validate its entry in a
-- fresh process so package.loaded or a compiler-side support table cannot make
-- an unrelated/stub luaopen_titan appear valid.
function driver.validate_titan_support(filename, verbose)
    local script = os.tmpname()
    local result = os.tmpname()
    local ok, err = util.set_file_contents(script, support_validation_script)
    if not ok then
        os.remove(script)
        os.remove(result)
        return nil, err
    end

    local ran, term, code = run_argv({
        current_lua_executable(), "-E", script,
        absolute_filename(filename), result,
    }, verbose)
    local message = util.get_file_contents(result)
    os.remove(script)
    os.remove(result)
    if not ran then
        return nil, "linked provider 'titan' has an invalid native support " ..
            "entry: " .. tostring(message or term) ..
            (code and (" (exit " .. tostring(code) .. ")") or "")
    end
    if message ~= "ok" then
        return nil, "linked provider 'titan' support validation returned " ..
            tostring(message)
    end
    return true
end

driver.GENERATED_SHIM_BANNER = "-- Generated by titanc; do not edit.\n"

local function safe_module_output_path(modname, extension)
    local components = module_components(modname)
    if #components == 0 then return nil end
    for _, component in ipairs(components) do
        if component == "." or component == ".." or
           component:find("[/\\%z]") then
            return nil
        end
    end
    return table.concat(components, "/") .. extension
end

local function validate_output_ancestors(filename)
    local current = ""
    for component in filename:gmatch("([^/]+)/") do
        current = current == "" and component or (current .. "/" .. component)
        local attr = lfs.symlinkattributes(current)
        if attr and attr.mode ~= "directory" then
            return nil, "output parent '" .. current .. "' is not a directory"
        end
    end
    return true
end

local shim_template = [[local path, search_error = package.searchpath($PROVIDER, package.cpath)
if not path then error(search_error, 0) end

local titan = require "titan"
local open, open_error = titan._loadlibglobal(path, $ENTRY)
if not open then error(open_error, 0) end

return open()
]]

-- Validate the complete shim set before code generation. Only files carrying
-- Titan's exact generated banner are owned and replaceable.
function driver.plan_module_shims(provider, module_names)
    local provider_path = safe_module_output_path(provider, ".so")
    if not provider_path then
        return nil, "invalid library provider name '" .. tostring(provider) .. "'"
    end

    local plans = {}
    local seen = {}
    for _, modname in ipairs(module_names) do
        local filename = safe_module_output_path(modname, ".lua")
        if not filename then
            return nil, "module '" .. tostring(modname) ..
                "' has no safe generated Lua shim path"
        end
        if seen[filename] then
            return nil, "multiple modules would generate Lua shim '" ..
                filename .. "'"
        end
        seen[filename] = true

        local parents_ok, parents_err = validate_output_ancestors(filename)
        if not parents_ok then return nil, parents_err end
        local attr = lfs.symlinkattributes(filename)
        if attr then
            if attr.mode ~= "file" then
                return nil, "refusing to replace non-file Lua shim path '" ..
                    filename .. "'"
            end
            local input, read_err = util.get_file_contents(filename)
            if not input then return nil, read_err end
            if input:sub(1, #driver.GENERATED_SHIM_BANNER) ~=
               driver.GENERATED_SHIM_BANNER then
                return nil, "refusing to overwrite unrecognized Lua file '" ..
                    filename .. "'"
            end
        end

        local entry = "luaopen_" .. driver.mangle_module_name(modname)
        table.insert(plans, {
            modname = modname,
            filename = filename,
            contents = driver.GENERATED_SHIM_BANNER .. util.render(
                shim_template, {
                    PROVIDER = string.format("%q", provider),
                    ENTRY = string.format("%q", entry),
                }),
        })
    end
    return plans, provider_path
end

function driver.write_module_shims(plans)
    for _, plan in ipairs(plans) do
        local output_ok, output_err = ensure_output_parent(plan.filename)
        if not output_ok then return nil, output_err end
        local tempname = driver.sibling_temporary_path(plan.filename)
        local wrote, write_err = util.set_file_contents(tempname, plan.contents)
        if not wrote then
            os.remove(tempname)
            return nil, write_err
        end
        local moved, move_err = os.rename(tempname, plan.filename)
        if not moved then
            os.remove(tempname)
            return nil, move_err
        end
    end
    return true
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
