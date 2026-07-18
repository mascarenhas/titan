local parser = require  "titan-compiler.parser"
local util = require "titan-compiler.util"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local pretty = require "titan-compiler.pretty"
local types = require "titan-compiler.types"
local location = require "titan-compiler.location"
local staticmetadata = require "titan-compiler.staticmetadata"
local cdriver = require "c-parser.cdriver"

local lfs = require "lfs"

local driver = {}

driver.imported = {}

driver.TITAN_VER = "0.16"
driver.TITAN_VER_SUFFIX = "_0_16"
driver.LUA_VERSION = "5.5"

local LUA_CPATH_SUFFIX = "/lib/lua/" .. driver.LUA_VERSION .. "/?.so"

local function normalize_absolute_path(path)
    local components = {}
    for component in path:gmatch("[^/]+") do
        if component == ".." then
            if #components ~= 0 then table.remove(components) end
        elseif component ~= "." and component ~= "" then
            components[#components + 1] = component
        end
    end
    return "/" .. table.concat(components, "/")
end

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
    -- A literal `..` after a symlink must be resolved by the filesystem:
    -- lexical normalization would name a different directory. Ordinary roots
    -- keep their normalized pathname spelling (notably macOS /tmp rather than
    -- /private/tmp), preserving the existing loader-path contract.
    if ("/" .. root .. "/"):find("/../", 1, true) then
        local previous = lfs.currentdir()
        if lfs.chdir(root) then
            local resolved = lfs.currentdir()
            assert(lfs.chdir(previous))
            return resolved
        end
    end
    return normalize_absolute_path(root)
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
driver.AR = os.getenv("AR") or "ar"
driver.RANLIB = os.getenv("RANLIB") or "ranlib"

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

function driver.new_resolver_context(options)
    options = options or {}
    return {
        prefer_static = options.prefer_static == true,
        provider_cache = {},
        contextual_types = {},
        native_interface_types = {},
        native_constraints = {},
    }
end

local function add_native_constraint(
        context, owner, binding, provider, exposer)
    local constraints = context.native_constraints[owner]
    if not constraints then
        constraints = {}
        context.native_constraints[owner] = constraints
    end
    local key = table.concat({
        binding or "", provider or "", exposer or "",
    }, "\0")
    if constraints[key] then return end
    constraints[key] = {
        binding = binding,
        provider = provider,
        exposer = exposer,
    }
end

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
function driver.module_compiled_candidates(modname, suffix)
    assert(suffix == ".so" or suffix == ".a",
        "compiled module candidates require .so or .a")
    local components = module_components(modname)
    if #components == 0 then return {} end

    local candidates = {}
    local path = ""
    for index, component in ipairs(components) do
        path = index == 1 and component or (path .. "/" .. component)
        table.insert(candidates, path .. suffix)
    end
    return candidates
end

function driver.module_binary_candidates(modname)
    return driver.module_compiled_candidates(modname, ".so")
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

function driver.validate_module_interface(modtype, modname)
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

function driver.decode_module_interface(serialized, modname, origin)
    local modtf, load_err =
        load("return " .. serialized, "@" .. (origin or modname), "t", types)
    if not modtf then return nil, load_err end
    local decoded = table.pack(pcall(modtf))
    if not decoded[1] then return nil, tostring(decoded[2]) end
    if decoded.n ~= 2 then
        return nil, "serialized module interface must return exactly one value"
    end
    local valid, validation_err =
        driver.validate_module_interface(decoded[2], modname)
    if not valid then return nil, validation_err end
    return decoded[2]
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
    local modt_or_err, validation_err = driver.decode_module_interface(
        types_or_err, modname, binf .. ":" .. typesname)
    if not modt_or_err then
        return "error", "compiled container '" .. binf ..
            "' has invalid metadata for module '" .. modname .. "': " ..
            validation_err
    end
    return "valid", modt_or_err, {
        module = modname,
        abi = abi_or_err,
        types = types_or_err,
        type = modt_or_err,
        origin = binf,
    }
end
driver.probe_compiled_interface = probe_compiled_interface

local function join_path(root, relative)
    if root:sub(-1) == "/" then return root .. relative end
    return root .. "/" .. relative
end

-- Locate a compiled logical module inside shallow-to-exact containers. Search
-- is root-major so an earlier local exact module wins over a later installed
-- shallow bundle. Once a relative candidate exists in one root it shadows the
-- same relative pathname in all later roots, even when it is a clean nonclaim.
function driver.find_dynamic_interface(paths, modname)
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

-- Compatibility wrapper for callers which predate static providers.
function driver.find_compiled_interface(paths, modname)
    return driver.find_dynamic_interface(paths, modname)
end

local function inspect_static_provider(context, filename, relative)
    local cached = context.provider_cache[filename]
    if cached then
        if cached.error then return nil, cached.error end
        return cached
    end

    local provider, scan_err = staticmetadata.scan_archive(filename, {
        expected_abi = driver.TITAN_VER,
        validate_types = function(name, serialized, origin)
            return driver.decode_module_interface(
                serialized, name, origin)
        end,
    })
    if not provider then
        local err = "cannot inspect static provider '" .. filename ..
            "': " .. tostring(scan_err)
        context.provider_cache[filename] = { error = err }
        return nil, err
    end

    provider.archive = filename
    provider.relative_archive = relative
    for name, entry in pairs(provider.entries or {}) do
        local modtype = entry.decoded_types
        local type_err
        if not modtype then
            modtype, type_err = driver.decode_module_interface(
                entry.types, name, entry.origin or filename)
        end
        if not modtype then
            local err = "static provider '" .. filename ..
                "' has invalid types for module '" .. name .. "': " ..
                tostring(type_err)
            context.provider_cache[filename] = { error = err }
            return nil, err
        end
        entry.type = modtype
    end
    context.provider_cache[filename] = provider
    return provider
end

function driver.find_static_interface(paths, modname, context)
    context = context or driver.new_resolver_context()
    local candidates =
        driver.module_compiled_candidates(modname, ".a")
    if #candidates == 0 then return nil end
    local occupied = {}

    for _, root in ipairs(driver.titan_bin_path_entries(paths)) do
        local absolute_root = assert(normalize_root(root))
        for index, relative in ipairs(candidates) do
            if not occupied[relative] then
                local filename = join_path(absolute_root, relative)
                if lfs.symlinkattributes(filename, "mode") then
                    occupied[relative] = true
                    -- Preserve lstat occupancy (including usable symlinks),
                    -- but never open a FIFO/device/directory as an archive.
                    local followed_mode = lfs.attributes(filename, "mode")
                    if followed_mode ~= "file" then
                        return nil, "static provider candidate '" ..
                            filename .. "' for module '" .. modname ..
                            "' is not a readable regular file"
                    end
                    local provider, provider_err =
                        inspect_static_provider(context, filename, relative)
                    if not provider then return nil, provider_err end
                    local entry = provider.entries[modname]
                    if entry then
                        return entry.type, filename, relative, provider
                    elseif index == #candidates then
                        return nil, "exact static provider '" .. filename ..
                            "' contains no metadata for module '" .. modname ..
                            "'"
                    end
                end
            end
        end
    end
    return nil
end

function driver.find_dependency_interface(paths, modname, context)
    context = context or driver.new_resolver_context()
    local formats = context.prefer_static
        and { "static", "dynamic" } or { "dynamic", "static" }

    for _, format in ipairs(formats) do
        if format == "dynamic" then
            local modtype, filename, relative =
                driver.find_dynamic_interface(paths, modname)
            if modtype then
                return {
                    kind = "dynamic",
                    type = modtype,
                    filename = filename,
                    relative = relative,
                }
            elseif filename then
                return nil, filename
            end
        else
            local modtype, filename, relative, provider =
                driver.find_static_interface(paths, modname, context)
            if modtype then
                return {
                    kind = "static",
                    type = modtype,
                    filename = filename,
                    relative = relative,
                    static_archive = filename,
                    static_provider = provider,
                }
            elseif filename then
                return nil, filename
            end
        end
    end
    return nil
end

function driver.defaultloader(static_deps, options)
    static_deps = static_deps or {}
    options = options or {}
    local context = options.context or driver.new_resolver_context(options)
    local source_roots = options.source_roots or {}
    local dependency_stack = {}

    local function remember_dependency_closure(modname, seen)
        seen = seen or {}
        if seen[modname] then return end
        seen[modname] = true
        local mod = driver.imported[modname]
        if not mod or mod == CIRCULAR_MARK then return end
        if mod.ast or mod.kind == "static" then
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
        if mod and mod ~= CIRCULAR_MARK and
           (mod.ast or mod.kind == "static") then
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
            kind = "source",
            ast = ast,
            type = modt,
            filename = source.main,
            source_files = source.files,
            program_output = source.program_output,
            deps = direct_deps,
        }
        static_deps[modname] = true
        return true, modt, errors
    end

    local function recover_contextual_owner(modname, request)
        local exposer = request and request.exposer
        local exposing_name = type(exposer) == "table" and exposer.name or
            exposer
        local exposing = type(exposer) == "table" and exposer or
            (exposing_name and driver.imported[exposing_name])
        if not exposing or exposing == CIRCULAR_MARK or
           exposing.kind == "source" then
            return nil
        end
        if modname == exposing_name then
            return true, exposing.type, {}
        end

        local physical_identity = exposing.static_archive or
            exposing.filename or exposing_name
        local cache_key = physical_identity .. "\0" .. exposing_name ..
            "\0" .. modname
        local cached = context.contextual_types[cache_key]
        if cached then
            if cached.error then return false, cached.error end
            context.native_interface_types[modname] = cached.type
            return true, cached.type, {}
        end

        local function remember_type(modtype)
            context.contextual_types[cache_key] = { type = modtype }
            context.native_interface_types[modname] = modtype
            return true, modtype, {}
        end

        if exposing.kind == "static" then
            local entry = exposing.static_provider and
                exposing.static_provider.entries[modname]
            if entry then
                add_native_constraint(context, modname, "direct-carried",
                    exposing.static_archive, exposing_name)
                return remember_type(entry.type)
            end
        elseif exposing.kind == "dynamic" then
            local status, value =
                probe_compiled_interface(modname, exposing.filename)
            if status == "valid" then
                add_native_constraint(context, modname, "dynamic-global",
                    exposing.filename, exposing_name)
                return remember_type(value)
            elseif status == "error" then
                context.contextual_types[cache_key] = { error = value }
                return false, value
            end
        end

        local ordinary = driver.imported[modname]
        if ordinary and ordinary ~= CIRCULAR_MARK then
            -- The exposing compiled object did not carry/claim this owner, so
            -- its machine code already chose a producer-dynamic identity.
            -- Reuse the independently known type only to finish checking and
            -- record the edge; finalization will reject that independently
            -- selected source/archive/other-DSO implementation.
            add_native_constraint(context, modname, "dynamic-global",
                exposing.static_archive or exposing.filename, exposing_name)
            return remember_type(ordinary.type)
        end

        -- The exposing compiled object already chose how to bind this owner.
        -- Reading another interface is type recovery only: it must not create
        -- ordinary resolver state or add an archive link input.
        local resolved, compiled_err = driver.find_dependency_interface(
            driver.TITAN_BIN_PATH, modname, context)
        if not resolved then
            local err = compiled_err or
                ("module '" .. modname .. "' not found while recovering " ..
                    "the interface exposed by '" .. exposing_name .. "'")
            context.contextual_types[cache_key] = { error = err }
            return false, err
        end
        add_native_constraint(context, modname, "dynamic-global",
            exposing.static_archive or exposing.filename, exposing_name)
        return remember_type(resolved.type)
    end

    local function loader(modname, request)
        if request and request.kind == "nominal-owner" then
            local contextual_ok, contextual_type, contextual_errors =
                recover_contextual_owner(modname, request)
            if contextual_ok ~= nil then
                return contextual_ok, contextual_type, contextual_errors
            end
        end
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

        local resolved, compiled_err = driver.find_dependency_interface(
            driver.TITAN_BIN_PATH, modname, context)
        if resolved then
            resolved.compiled = true
            driver.imported[modname] = resolved
            if resolved.kind == "static" then
                static_deps[modname] = true
            end
            remember_direct_dependency(modname)
            return true, resolved.type, {}
        elseif compiled_err then
            return false, compiled_err
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
    context.loader = loader
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

function driver.finalize_resolver_context(context)
    context = context or driver.new_resolver_context()
    local source_names = {}
    local dynamic_names = {}
    local selected_static_modules = {}
    local providers_by_path = {}

    for name, mod in pairs(driver.imported) do
        if mod ~= CIRCULAR_MARK then
            if mod.kind == "static" then
                selected_static_modules[name] = mod
                providers_by_path[mod.static_archive] = mod.static_provider
            elseif mod.ast or mod.kind == "source" then
                source_names[name] = true
            elseif mod.kind == "dynamic" or mod.compiled then
                dynamic_names[name] = mod
            end
        end
    end

    local selected_static_providers = {}
    for _, provider in pairs(providers_by_path) do
        selected_static_providers[#selected_static_providers + 1] = provider
    end
    table.sort(selected_static_providers, function(left, right)
        return util.bytewise_less(left.archive, right.archive)
    end)

    -- Checker-time contextual reads are provisional: a later explicit source
    -- root can replace a compiled cache entry. Rebuild every native exposure
    -- edge from final provenance only.
    context.native_constraints = {}
    context.contextual_types = {}
    context.native_interface_types = {}

    if context.loader then
        local dynamic_order = {}
        for name in pairs(dynamic_names) do
            dynamic_order[#dynamic_order + 1] = name
        end
        table.sort(dynamic_order, util.bytewise_less)
        for _, name in ipairs(dynamic_order) do
            local mod = dynamic_names[name]
            checker.register_module_interface(
                name, mod.type, context.loader, {
                    name = name,
                    kind = "dynamic",
                    type = mod.type,
                    filename = mod.filename,
                })
        end
    end

    -- Every carried interface can impose native-owner constraints even when
    -- ordinary lookup selected the provider through a different key.
    if context.loader then
        for _, provider in ipairs(selected_static_providers) do
            local key_order = provider.key_order
            if not key_order then
                key_order = {}
                for name in pairs(provider.entries) do
                    key_order[#key_order + 1] = name
                end
                table.sort(key_order, util.bytewise_less)
            end
            for _, name in ipairs(key_order) do
                local entry = provider.entries[name]
                checker.register_module_interface(
                    name, entry.type, context.loader, {
                        name = name,
                        kind = "static",
                        type = entry.type,
                        filename = provider.archive,
                        static_archive = provider.archive,
                        static_provider = provider,
                    })
            end
        end
    end

    local native_static_names = {}
    for name in pairs(source_names) do native_static_names[name] = true end
    local native_bindings = {}
    for name in pairs(source_names) do native_bindings[name] = "direct" end
    for name in pairs(dynamic_names) do native_bindings[name] = "handle" end
    local physical_owner = {}
    local errors = {}

    for _, provider in ipairs(selected_static_providers) do
        for name in pairs(provider.entries) do
            native_static_names[name] = true
            native_bindings[name] = "direct"
            local previous = physical_owner[name]
            if previous and previous ~= provider.archive then
                errors[#errors + 1] = "static providers '" .. previous ..
                    "' and '" .. provider.archive ..
                    "' both contain logical module '" .. name .. "'"
            else
                physical_owner[name] = provider.archive
            end

            local ordinary = driver.imported[name]
            if ordinary and ordinary ~= CIRCULAR_MARK then
                local same_static = ordinary.kind == "static" and
                    ordinary.static_archive == provider.archive
                if not same_static then
                    errors[#errors + 1] = "static provider '" ..
                        provider.archive .. "' physically contains module '" ..
                        name .. "', which also resolved independently as " ..
                        tostring(ordinary.kind or
                            (ordinary.ast and "source" or "compiled"))
                end
            end
        end
    end

    local mangled_owners = {}
    local all_native_names = {}
    for name in pairs(source_names) do all_native_names[name] = true end
    for name in pairs(dynamic_names) do all_native_names[name] = true end
    for name in pairs(physical_owner) do all_native_names[name] = true end
    for name in pairs(context.native_constraints) do
        all_native_names[name] = true
    end
    for name in pairs(all_native_names) do
        local mangled = driver.mangle_module_name(name)
        local previous = mangled_owners[mangled]
        if previous and previous ~= name then
            errors[#errors + 1] = "cannot link logical modules '" ..
                previous .. "' and '" .. name ..
                "': both use C symbol prefix '" .. mangled .. "'"
        else
            mangled_owners[mangled] = name
        end
    end

    for owner, keyed in pairs(context.native_constraints) do
        -- Complete physical membership is native provenance even when the
        -- owner was not independently selected. If another selected
        -- provider's facade requires that owner through its producer-chosen
        -- DSO, carrying the owner directly would mix identities.
        local direct_provider = physical_owner[owner]
        local dynamic_provider
        for _, constraint in pairs(keyed) do
            if constraint.binding == "direct-carried" then
                if direct_provider and
                   direct_provider ~= constraint.provider then
                    errors[#errors + 1] = "logical owner '" .. owner ..
                        "' is carried directly by conflicting static providers '" ..
                        direct_provider .. "' and '" ..
                        tostring(constraint.provider) .. "'"
                end
                direct_provider = constraint.provider
            elseif constraint.binding == "dynamic-global" then
                if dynamic_provider and
                   dynamic_provider ~= constraint.provider then
                    errors[#errors + 1] = "logical owner '" .. owner ..
                        "' has producer-dynamic exposures from conflicting " ..
                        "providers '" .. dynamic_provider .. "' and '" ..
                        tostring(constraint.provider) .. "'"
                end
                dynamic_provider = constraint.provider
            end
        end
        if direct_provider and dynamic_provider then
            errors[#errors + 1] = "logical owner '" .. owner ..
                "' is required both directly by static provider '" ..
                direct_provider .. "' and dynamically through '" ..
                dynamic_provider .. "'"
        end
        local ordinary_owner = driver.imported[owner]
        if dynamic_provider and ordinary_owner and
           ordinary_owner ~= CIRCULAR_MARK then
            -- A multi-module DSO can expose and independently claim the same
            -- owner through one exact physical handle. That is the existing
            -- contextual DSO case, not an identity mixture. Producer-dynamic
            -- constraints baked into a selected archive still name the
            -- exposing `.a`, so no independently selected implementation can
            -- satisfy this exception.
            local same_dynamic_provider =
                ordinary_owner.kind == "dynamic" and
                ordinary_owner.filename == dynamic_provider
            if not same_dynamic_provider then
                errors[#errors + 1] = "logical owner '" .. owner ..
                    "' resolved independently as " ..
                    tostring(ordinary_owner.kind or "compiled") ..
                    " but selected provider '" .. dynamic_provider ..
                    "' requires its producer-chosen dynamic identity"
            end
        end
        if dynamic_provider and not direct_provider then
            native_bindings[owner] = "global"
        elseif direct_provider then
            native_bindings[owner] = "direct"
        end
    end

    context.source_names = source_names
    context.dynamic_names = dynamic_names
    context.selected_static_modules = selected_static_modules
    context.selected_static_providers = selected_static_providers
    context.native_static_names = native_static_names
    context.native_bindings = native_bindings
    context.physical_owner = physical_owner

    if #errors ~= 0 then return nil, errors end
    return context
end

-- The standalone protocol gate must preserve ordinary archive extraction.
-- Start with archive keys actually selected by ordinary resolution, then add
-- only physically carried owners whose direct symbols code generation
-- actually referenced. Constraints from unrelated physical entries still
-- participate in preflight, but must not force their objects out of an
-- archive merely because an unused exported signature mentions them.
function driver.required_static_protocol_names(context, used_native_names)
    local required = {}
    for name in pairs(context.selected_static_modules or {}) do
        required[name] = true
    end
    for name in pairs(used_native_names or {}) do
        if context.physical_owner and context.physical_owner[name] then
            required[name] = true
        end
    end

    local names = {}
    for name in pairs(required) do names[#names + 1] = name end
    table.sort(names, util.bytewise_less)
    return names
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
            imported[modname] = {
                kind = "source", ast = ast, type = modt, filename = modf,
            }
            deps[modname] = true
            return true, modt, errors
        end
        local mods = types.serialize(modt)
        local modtf, err = load("return " .. mods, modname, "t", types)
        if not modtf then return false, err end
        local ok, modt_or_err = pcall(modtf)
        if not ok then return false, modt_or_err end
        modt = modt_or_err
        imported[modname] = {
            kind = "source", ast = ast, type = modt, filename = modf,
        }
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
    local ok, err, libname, native_references = driver.compile(
        modname, mod.ast, mod.filename, static_deps, verbose)
    if not ok then return nil, err end
    mod.compiled = libname
    mod.native_references = native_references or {}
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

local function runtime_link_inputs()
    if driver.INSTALLED then
        return driver.installed_link_inputs(
            driver.INSTALL_PATHS, driver.IS_DARWIN)
    end
    return driver.source_link_inputs(driver.LUA_SOURCE_PATH)
end

-- Standalone links keep ordinary -X inputs outside ELF archive groups, but
-- libtitan may itself reference metadata-free payload carried by a selected
-- provider (the bundled libuv objects in titan.a are the canonical case).
-- Search providers once before -X so their unresolved references can select
-- ordinary -X members, then search libtitan and the providers together after
-- -X so either direction reaches a fixed point. Nothing is force-loaded.
function driver.standalone_native_link_inputs(
        static_archives, extra_objects, runtime, is_darwin)
    static_archives = static_archives or {}
    extra_objects = extra_objects or {}
    runtime = runtime or {}
    is_darwin = is_darwin == nil and driver.IS_DARWIN or is_darwin
    local args = {}
    if #static_archives ~= 0 and not is_darwin then
        assert(runtime[1], "standalone link has no Titan runtime archive")
        table.insert(args, "-Wl,--start-group")
        append_argv(args, static_archives)
        table.insert(args, "-Wl,--end-group")
        append_argv(args, extra_objects)
        table.insert(args, "-Wl,--start-group")
        table.insert(args, runtime[1])
        append_argv(args, static_archives)
        table.insert(args, "-Wl,--end-group")
        for index = 2, #runtime do
            table.insert(args, runtime[index])
        end
    else
        append_argv(args, static_archives)
        append_argv(args, extra_objects)
        append_argv(args, runtime)
    end
    return args
end

local function archive_input_path(archive)
    if type(archive) == "table" then
        return archive.path or archive.archive or archive.filename
    end
    return archive
end

function driver.force_load_arguments(archives, is_darwin)
    local args = {}
    is_darwin = is_darwin == nil and driver.IS_DARWIN or is_darwin
    if is_darwin then
        for _, archive in ipairs(archives) do
            archive = assert(archive_input_path(archive),
                "archive input has no pathname")
            local path = archive:sub(1, 1) == "/" and archive or
                (lfs.currentdir() .. "/" .. archive)
            append_argv(args, {
                "-Xlinker", "-force_load",
                "-Xlinker", path,
            })
        end
    else
        if #archives ~= 0 then
            table.insert(args, "-Wl,--whole-archive")
            for _, archive in ipairs(archives) do
                local path = assert(archive_input_path(archive),
                    "archive input has no pathname")
                table.insert(args, path)
            end
            table.insert(args, "-Wl,--no-whole-archive")
        end
    end
    return args
end

local function append_force_loaded_archives(args, archives)
    append_argv(args, driver.force_load_arguments(archives))
end

function driver.compile(modname, ast, sourcef, static_deps, verbose)
    local runtime_ok, runtime_err = check_runtime(verbose)
    if not runtime_ok then return nil, runtime_err end
    sourcef = sourcef or modname:gsub("[.]", "/") .. ".titan"
    static_deps = static_deps or {}
    local code, native_references =
        coder.generate(modname, ast, static_deps, driver.TITAN_VER)
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
        return ok, nil, libname, native_references
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

local function absolute_native_path(filename)
    if filename:sub(1, 1) == "/" then return filename end
    return lfs.currentdir() .. "/" .. filename
end

local function read_binary_file(filename)
    if lfs.attributes(filename, "mode") ~= "file" then
        return nil, "native input '" .. tostring(filename) ..
            "' is not a regular file"
    end
    local file, open_err = io.open(filename, "rb")
    if not file then return nil, open_err end
    local contents = file:read("*a")
    local close_ok, close_err = file:close()
    if not contents then return nil, "cannot read native input" end
    if close_ok == nil then return nil, close_err end
    return contents
end

local function write_binary_file(filename, contents)
    local file, open_err = io.open(filename, "wb")
    if not file then return nil, open_err end
    local ok, write_err = file:write(contents)
    if not ok then
        file:close()
        return nil, write_err
    end
    local close_ok, close_err = file:close()
    if close_ok == nil then return nil, close_err end
    return true
end

local function metadata_scan_options(target)
    return {
        target = target,
        expected_abi = driver.TITAN_VER,
        validate_types = function(name, serialized, origin)
            return driver.decode_module_interface(serialized, name, origin)
        end,
    }
end

local function scan_native_file(filename, target, validate_types)
    local bytes, read_err = read_binary_file(filename)
    if not bytes then
        return nil, "cannot read native input '" .. tostring(filename) ..
            "': " .. tostring(read_err)
    end
    local options = {
        target = target,
        expected_abi = driver.TITAN_VER,
    }
    if validate_types then
        options.validate_types = function(name, serialized, origin)
            return driver.decode_module_interface(serialized, name, origin)
        end
    end
    local parsed, scan_err =
        staticmetadata.scan_bytes(bytes, filename, options)
    if not parsed then return nil, scan_err end
    return parsed
end

-- The first real generated module object is the authoritative target. It must
-- remain a single-architecture relocatable object and carry its own validated
-- one-key Titan metadata section.
function driver.derive_target_fingerprint(filename, expected_module)
    local parsed, scan_err = scan_native_file(filename, nil, true)
    if not parsed then return nil, scan_err end
    if parsed.kind ~= "object" then
        return nil, "generated module object '" .. tostring(filename) ..
            "' is not a single-architecture relocatable object"
    end
    if not parsed.metadata then
        return nil, "generated module object '" .. tostring(filename) ..
            "' has no Titan metadata section"
    end
    if expected_module and parsed.metadata.module ~= expected_module then
        return nil, "generated module object '" .. tostring(filename) ..
            "' contains metadata for '" .. parsed.metadata.module ..
            "' instead of '" .. expected_module .. "'"
    end
    return parsed.fingerprint, parsed
end

function driver.validate_generated_objects(objects, target)
    for _, input in ipairs(objects or {}) do
        local filename = type(input) == "table" and input.filename or input
        local expected_module =
            type(input) == "table" and input.modname or nil
        local fingerprint, parsed_or_err =
            driver.derive_target_fingerprint(filename, expected_module)
        if not fingerprint then return nil, parsed_or_err end
        local matches, mismatch =
            staticmetadata.fingerprint_matches(fingerprint, target)
        if not matches then
            return nil, "generated module object '" .. tostring(filename) ..
                "' target mismatch: " .. tostring(mismatch)
        end
    end
    return true
end

-- Static providers are resolved before generated objects exist, so a universal
-- archive cannot choose its active slice during lookup. Finalize that choice
-- from the first generated module object's authoritative target, and reject a
-- regular archive whose members do not all match it.
function driver.prepare_static_providers_for_target(providers, target)
    for _, provider in ipairs(providers or {}) do
        local active = provider
        if provider.kind == "fat_archive" then
            local selected, selection_err =
                staticmetadata.select_fat_slice(provider, target)
            if not selected then
                return nil, "static provider '" ..
                    tostring(provider.archive or provider.filename) ..
                    "' has no compatible target slice: " ..
                    tostring(selection_err)
            end
            provider.selected_slice = selected
            active = selected.archive
        elseif provider.kind ~= "archive" then
            return nil, "static provider '" ..
                tostring(provider.archive or provider.filename) ..
                "' is not a supported archive container"
        end
        for _, member in ipairs(active.members or {}) do
            local matches, mismatch = staticmetadata.fingerprint_matches(
                member.fingerprint, target)
            if not matches then
                return nil, tostring(member.origin) ..
                    " target mismatch: " .. tostring(mismatch)
            end
        end
    end
    return true
end

local function selected_native_view(parsed)
    if parsed.kind == "fat_object" then
        return parsed.selected_slice and parsed.selected_slice.object
    elseif parsed.kind == "fat_archive" then
        return parsed.selected_slice and parsed.selected_slice.archive
    end
    return parsed
end

local function has_metadata_entries(parsed)
    if parsed.metadata then return true end
    return parsed.entries and next(parsed.entries) ~= nil
end

-- Classify generic no-main `-X` payload without changing CLI order. The
-- returned descriptors keep the complete parse and active fat slice so DSO
-- linking and archive flattening can share one validated decision.
function driver.classify_native_payloads(paths, target)
    if type(target) ~= "table" then
        return nil, "native payload classification requires a target fingerprint"
    end
    local plan = {
        target = target,
        inputs = {},
        objects = {},
        archives = {},
    }
    for ordinal, filename in ipairs(paths or {}) do
        local parsed, scan_err = scan_native_file(filename, target, false)
        if not parsed then
            return nil, "invalid no-main -X input '" .. tostring(filename) ..
                "': " .. tostring(scan_err)
        end
        local selected = selected_native_view(parsed)
        if not selected then
            return nil, "no active target slice in no-main -X input '" ..
                tostring(filename) .. "'"
        end
        if has_metadata_entries(parsed) then
            return nil, "generic no-main -X input '" .. tostring(filename) ..
                "' contains Titan module metadata; import it as a logical " ..
                "module instead"
        end
        local descriptor = {
            ordinal = ordinal,
            path = filename,
            -- Native inputs that begin with '-' are still pathnames. Feed an
            -- absolute spelling to CC so neither objects nor Linux archive
            -- force-load arguments can be reinterpreted as options.
            link_path = absolute_native_path(filename),
            kind = parsed.kind,
            container = parsed,
            selected_slice = parsed.selected_slice,
        }
        if selected.kind == "object" then
            descriptor.object = selected
            plan.objects[#plan.objects + 1] = descriptor
        elseif selected.kind == "archive" then
            descriptor.archive = selected
            descriptor.members = selected.members
            plan.archives[#plan.archives + 1] = descriptor
        else
            return nil, "unsupported no-main -X native input '" ..
                tostring(filename) .. "'"
        end
        plan.inputs[#plan.inputs + 1] = descriptor
    end
    return plan
end

function driver.compare_archive_entries(actual, expected, subject)
    subject = subject or "static archive"
    actual = actual or {}
    expected = expected or {}
    local actual_names = {}
    local expected_names = {}
    for name in pairs(actual) do actual_names[#actual_names + 1] = name end
    for name in pairs(expected) do expected_names[#expected_names + 1] = name end
    table.sort(actual_names, util.bytewise_less)
    table.sort(expected_names, util.bytewise_less)
    if #actual_names ~= #expected_names then
        return nil, subject .. " logical key count differs: expected " ..
            tostring(#expected_names) .. " but found " ..
            tostring(#actual_names)
    end
    for index, name in ipairs(expected_names) do
        if actual_names[index] ~= name then
            return nil, subject .. " logical key set differs: expected '" ..
                name .. "' at index " .. tostring(index) .. " but found '" ..
                tostring(actual_names[index]) .. "'"
        end
        local found = actual[name]
        local wanted = expected[name]
        if found.abi ~= wanted.abi then
            return nil, subject .. " ABI for module '" .. name ..
                "' differs: expected " .. tostring(wanted.abi) ..
                " but found " .. tostring(found.abi)
        end
        if found.types ~= wanted.types then
            return nil, subject .. " type metadata for module '" .. name ..
                "' differs"
        end
        if found.payload and wanted.payload and
           found.payload ~= wanted.payload then
            return nil, subject .. " canonical payload for module '" ..
                name .. "' differs"
        end
    end
    return true
end

local function merge_manifest_entry(entries, entry)
    if not entry then return true end
    local previous = entries[entry.module]
    if previous then
        return nil, "flattened native inputs contain logical module '" ..
            entry.module .. "' more than once (" ..
            tostring(previous.origin) .. " and " ..
            tostring(entry.origin) .. ")"
    end
    entries[entry.module] = entry
    return true
end

local function safe_staged_leaf(name, fallback)
    name = type(name) == "string" and
        (name:match("([^/\\]+)$") or name) or ""
    if name == "" or name == "." or name == ".." or name:find("%z") then
        return fallback
    end
    return name
end

local function parsed_object_input(input, target)
    if type(input) == "string" then
        local parsed, err = scan_native_file(input, target, true)
        if not parsed then return nil, err end
        local selected = selected_native_view(parsed)
        if not selected or selected.kind ~= "object" then
            return nil, "native object input '" .. input ..
                "' is not a relocatable object"
        end
        return {
            path = input,
            origin = input,
            parsed = parsed,
            object = selected,
        }
    elseif type(input) == "table" then
        if input.object then
            local matches, mismatch = staticmetadata.fingerprint_matches(
                input.object.fingerprint, target)
            if not matches then
                return nil, "native object input '" ..
                    tostring(input.path or input.object.origin) ..
                    "' target mismatch: " .. mismatch
            end
            return {
                path = input.path,
                origin = input.path or input.object.origin,
                parsed = input.container or input.object,
                object = input.object,
            }
        elseif input.kind == "object" or input.kind == "fat_object" then
            local selected = selected_native_view(input)
            if not selected then
                return nil, "fat object input has no selected target slice"
            end
            local matches, mismatch = staticmetadata.fingerprint_matches(
                selected.fingerprint, target)
            if not matches then return nil, mismatch end
            return {
                path = input.filename,
                origin = input.origin,
                parsed = input,
                object = selected,
            }
        end
    end
    return nil, "invalid native object input descriptor"
end

local function parsed_archive_input(input, target)
    if type(input) == "string" then
        local parsed, err = staticmetadata.scan_archive(
            input, metadata_scan_options(target))
        if not parsed then return nil, err end
        local selected = selected_native_view(parsed)
        if not selected or selected.kind ~= "archive" then
            return nil, "static archive input '" .. input ..
                "' has no selected regular archive"
        end
        return {
            path = input,
            origin = input,
            parsed = parsed,
            archive = selected,
        }
    elseif type(input) == "table" then
        if input.archive and type(input.archive) == "table" then
            return {
                path = input.path,
                origin = input.path or input.archive.origin,
                parsed = input.container or input.archive,
                archive = input.archive,
            }
        elseif input.kind == "archive" or input.kind == "fat_archive" then
            local selected = selected_native_view(input)
            if not selected then
                return nil, "fat archive input has no selected target slice"
            end
            return {
                path = input.archive or input.filename,
                origin = input.origin,
                parsed = input,
                archive = selected,
            }
        elseif input.members and input.entries then
            -- Resolver provider records are parsed archive results with an
            -- `archive` pathname added after scanning.
            return {
                path = input.archive or input.filename,
                origin = input.origin,
                parsed = input,
                archive = input,
            }
        end
    end
    return nil, "invalid static archive input descriptor"
end

local function tool_argv(configured, label)
    local argv, err = parsed_words(configured, label)
    if not argv then return nil, err end
    if #argv == 0 then return nil, label .. " command is empty" end
    return argv
end

local function copy_argv(argv)
    local copy = {}
    append_argv(copy, argv)
    return copy
end

local function run_archive_tool(base, arguments, verbose)
    local argv = copy_argv(base)
    append_argv(argv, arguments)
    return run_argv(argv, verbose)
end

local function archive_tool_capabilities(ar, ranlib, probe, object, verbose)
    os.remove(probe)
    local ar_args = { "qD", probe }
    if object then ar_args[#ar_args + 1] = object end
    local ar_d = run_archive_tool(ar, ar_args, verbose)
    if not ar_d then
        os.remove(probe)
        ar_args[1] = "q"
        local ar_ok, ar_term, ar_code =
            run_archive_tool(ar, ar_args, verbose)
        if not ar_ok then
            os.remove(probe)
            return nil, "configured AR supports neither qD nor q (" ..
                tostring(ar_term) .. ", exit " .. tostring(ar_code) .. ")"
        end
    end

    local ranlib_d = run_archive_tool(ranlib, { "-D", probe }, verbose)
    if not ranlib_d then
        local ranlib_ok, ranlib_term, ranlib_code =
            run_archive_tool(ranlib, { probe }, verbose)
        if not ranlib_ok then
            os.remove(probe)
            return nil, "configured RANLIB supports neither -D nor ordinary " ..
                "mode (" .. tostring(ranlib_term) .. ", exit " ..
                tostring(ranlib_code) .. ")"
        end
    end
    os.remove(probe)
    return {
        deterministic = ar_d and ranlib_d and true or false,
        ar_mode = ar_d and ranlib_d and "qD" or "q",
        ranlib_d = ar_d and ranlib_d and true or false,
    }
end

local ARCHIVE_ARGV_LIMIT = 128 * 1024

local function archive_batches(paths, fixed_size)
    local batches = {}
    local batch = {}
    local size = fixed_size
    for _, path in ipairs(paths) do
        local contribution = #path + 1
        if #batch ~= 0 and size + contribution > ARCHIVE_ARGV_LIMIT then
            batches[#batches + 1] = batch
            batch = {}
            size = fixed_size
        end
        batch[#batch + 1] = path
        size = size + contribution
    end
    if #batch ~= 0 or #batches == 0 then batches[#batches + 1] = batch end
    return batches
end

-- Construct one regular, single-architecture archive from an exact ordered
-- object sequence. Archives are flattened in-process; the configured tools
-- receive only uniquely staged ordinary objects.
function driver.build_static_archive(
        output, object_inputs, archive_inputs, target, verbose, ordered_inputs)
    if type(target) ~= "table" then
        return nil, "static archive construction requires a target fingerprint"
    end
    local output_ok, output_err = ensure_output_parent(output)
    if not output_ok then return nil, output_err end
    local stage = absolute_native_path(
        driver.sibling_temporary_path(output .. ".archive-stage"))
    local made, make_err = lfs.mkdir(stage)
    if not made then return nil, make_err end
    local temporary = stage .. "/output.a"
    local probe = stage .. "/tool-probe.a"
    local staged_paths = {}
    local manifest = {}
    local intended_entries = {}

    local function abort(message)
        remove_path(stage)
        return nil, message
    end

    local function stage_object(object, origin, leaf, source_ordinal)
        local matches, mismatch = staticmetadata.fingerprint_matches(
            object.fingerprint, target)
        if not matches then
            return nil, tostring(origin) .. " target mismatch: " .. mismatch
        end
        local ordinal = #manifest + 1
        local directory = stage .. "/" .. string.format("%06d", ordinal)
        local ok, err = lfs.mkdir(directory)
        if not ok then return nil, err end
        leaf = safe_staged_leaf(leaf, "member.o")
        local staged = directory .. "/" .. leaf
        ok, err = write_binary_file(staged, object.bytes)
        if not ok then return nil, err end
        staged_paths[#staged_paths + 1] = staged
        manifest[#manifest + 1] = {
            ordinal = ordinal,
            source_ordinal = source_ordinal,
            origin = origin,
            leaf = leaf,
            byte_length = #object.bytes,
            fingerprint = object.fingerprint,
            metadata = object.metadata,
            staged_file = staged,
        }
        local merged, merge_err =
            merge_manifest_entry(intended_entries, object.metadata)
        if not merged then return nil, merge_err end
        return true
    end

    local function add_object(input, ordinal)
        local parsed, parse_err = parsed_object_input(input, target)
        if not parsed then return abort(parse_err) end
        local path = parsed.path
        local leaf = path and path:match("([^/\\]+)$") or "object.o"
        local staged, stage_err = stage_object(
            parsed.object, parsed.origin, leaf, ordinal)
        if not staged then return abort(stage_err) end
        return true
    end

    local function add_archive(input, archive_ordinal)
        local parsed, parse_err = parsed_archive_input(input, target)
        if not parsed then return abort(parse_err) end
        for member_ordinal, member in ipairs(parsed.archive.members) do
            local staged, stage_err = stage_object(
                member.object, member.origin,
                member.display_name or "member.o", {
                    archive = archive_ordinal,
                    member = member_ordinal,
                })
            if not staged then return abort(stage_err) end
        end
        return true
    end

    if ordered_inputs then
        for ordinal, item in ipairs(ordered_inputs) do
            if type(item) ~= "table" or
               (item.kind ~= "object" and item.kind ~= "archive") then
                return abort("invalid ordered static archive input #" ..
                    tostring(ordinal))
            end
            local ok, input_err
            if item.kind == "object" then
                ok, input_err = add_object(item.input, ordinal)
            else
                ok, input_err = add_archive(item.input, ordinal)
            end
            if not ok then return nil, input_err end
        end
    else
        for ordinal, input in ipairs(object_inputs or {}) do
            local ok, input_err = add_object(input, ordinal)
            if not ok then return nil, input_err end
        end
        for archive_ordinal, input in ipairs(archive_inputs or {}) do
            local ok, input_err = add_archive(input, archive_ordinal)
            if not ok then return nil, input_err end
        end
    end

    local ar, ar_err = tool_argv(driver.AR, "AR")
    if not ar then return abort(ar_err) end
    local ranlib, ranlib_err = tool_argv(driver.RANLIB, "RANLIB")
    if not ranlib then return abort(ranlib_err) end
    local capability, capability_err = archive_tool_capabilities(
        ar, ranlib, probe, staged_paths[1], verbose)
    if not capability then return abort(capability_err) end

    os.remove(temporary)
    local fixed_size = #temporary + 16
    for _, batch in ipairs(archive_batches(staged_paths, fixed_size)) do
        local arguments = { capability.ar_mode, temporary }
        append_argv(arguments, batch)
        local ok, term, code =
            run_archive_tool(ar, arguments, verbose)
        if not ok then
            return abort("configured AR failed while building '" .. output ..
                "' (" .. tostring(term) .. ", exit " .. tostring(code) .. ")")
        end
    end
    local ranlib_arguments = {}
    if capability.ranlib_d then ranlib_arguments[#ranlib_arguments + 1] = "-D" end
    ranlib_arguments[#ranlib_arguments + 1] = temporary
    local indexed, index_term, index_code =
        run_archive_tool(ranlib, ranlib_arguments, verbose)
    if not indexed then
        return abort("configured RANLIB failed while indexing '" .. output ..
            "' (" .. tostring(index_term) .. ", exit " ..
            tostring(index_code) .. ")")
    end

    local verified, verify_err =
        staticmetadata.verify_regular_archive_manifest(temporary, manifest)
    if not verified then return abort(verify_err) end

    local produced, scan_err = staticmetadata.scan_archive(
        temporary, metadata_scan_options(target))
    if not produced then return abort(scan_err) end
    if produced.kind ~= "archive" then
        return abort("configured AR produced a non-regular archive")
    end
    if #produced.members ~= #manifest then
        return abort("produced archive member count differs: expected " ..
            tostring(#manifest) .. " but found " ..
            tostring(#produced.members))
    end
    for index, wanted in ipairs(manifest) do
        local found = produced.members[index]
        local matches, mismatch = staticmetadata.fingerprint_matches(
            found.fingerprint, wanted.fingerprint)
        if not matches then
            return abort("produced archive member #" .. tostring(index) ..
                " target differs from its manifest: " .. mismatch)
        end
    end
    local entries_ok, entries_err = driver.compare_archive_entries(
        produced.entries, intended_entries,
        "produced archive '" .. output .. "'")
    if not entries_ok then return abort(entries_err) end

    local published, publish_err = os.rename(temporary, output)
    if not published then return abort(publish_err) end
    produced.filename = output
    local result = {
        output = output,
        archive = produced,
        manifest = manifest,
        entries = intended_entries,
        deterministic = capability.deterministic,
    }
    remove_path(stage)
    return result
end

-- Build the private archive-backed sibling image through the same DSO link
-- policy. Callers validate its complete protocol set with
-- validate_library_image and remove it after use.
function driver.compile_archive_validation_image(
        output, archive, link, verbose, extra_objects)
    return driver.compile_library_output(
        output, {}, link, verbose, extra_objects, { archive })
end

function driver.compile_library_output(soname, libnames, link, verbose,
                                       extra_objects, static_archives,
                                       ordered_payload, install_name)
    local runtime_ok, runtime_err = check_runtime(verbose)
    if not runtime_ok then return nil, runtime_err end
    local output_ok, output_err = ensure_output_parent(soname)
    if not output_ok then return nil, output_err end
    os.remove(soname)
    remove_path(soname .. ".dSYM")

    local args, err = compiler_argv(false)
    if not args then return nil, err end
    append_argv(args, shared_flag())
    -- Darwin otherwise derives LC_ID_DYLIB from the unique staged `-o` path.
    -- Use the eventual public path so unchanged transactional relinks remain
    -- byte-identical and can preserve the published provider pair's mtimes.
    if driver.IS_DARWIN and install_name then
        append_argv(args, {
            "-Xlinker", "-install_name",
            "-Xlinker", install_name,
        })
    end
    append_argv(args, { "-o", soname })
    for _, libname in ipairs(libnames) do
        table.insert(args, libname)
    end
    append_force_loaded_archives(args, static_archives or {})
    if ordered_payload then
        for _, input in ipairs(ordered_payload) do
            if input.object then
                table.insert(args, assert(input.link_path or input.path))
            else
                append_force_loaded_archives(args, {
                    assert(input.link_path or input.path),
                })
            end
        end
    else
        for _, object in ipairs(extra_objects or {}) do
            table.insert(args, object)
        end
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

function driver.compile_library(modname, libnames, link, verbose, extra_objects,
                                static_archives)
    local soname = modname:gsub("[.]", "/") .. ".so"
    return driver.compile_library_output(
        soname, libnames, link, verbose, extra_objects, static_archives)
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

local function normalized_absolute_filename(filename)
    return normalize_absolute_path(absolute_filename(filename))
end

-- Canonicalize an existing pathname's parent through the filesystem. This
-- preserves POSIX symlink/.. resolution for alias and containment checks while
-- still giving a stable destination path when the final leaf does not exist.
local function physical_absolute_filename(filename)
    local raw = absolute_filename(filename)
    local mode = lfs.attributes(raw, "mode")
    local previous = lfs.currentdir()
    if mode == "directory" and lfs.chdir(raw) then
        local resolved = lfs.currentdir()
        assert(lfs.chdir(previous))
        return resolved
    end
    local parent, leaf = raw:match("^(.*)/([^/]*)$")
    if parent and leaf ~= "" and lfs.chdir(parent) then
        local resolved_parent = lfs.currentdir()
        assert(lfs.chdir(previous))
        return (resolved_parent == "/" and "/" or
            (resolved_parent .. "/")) .. leaf
    end
    return normalize_absolute_path(raw)
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

function driver.library_interface_entries(filename, module_names)
    filename = absolute_filename(filename)
    local entries = {}
    for _, modname in ipairs(module_names) do
        local status, value, metadata =
            probe_compiled_interface(modname, filename)
        if status ~= "valid" then
            if status == "nonclaim" then
                return nil, "linked container '" .. filename ..
                    "' does not contain metadata for module '" .. modname .. "'"
            end
            return nil, value
        end
        entries[modname] = metadata
    end
    return entries
end

function driver.validate_archive_library_equality(
        archive, filename, module_names, subject)
    local callable, callable_err =
        driver.library_interface_entries(filename, module_names)
    if not callable then return nil, callable_err end
    return driver.compare_archive_entries(
        archive.entries, callable,
        subject or ("archive and linked container '" .. filename .. "'"))
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

function driver.validate_library_image_fresh(
        filename, expected_entries, module_names, verbose)
    local expected = {}
    for _, modname in ipairs(module_names) do
        local entry = assert(expected_entries[modname])
        expected[#expected + 1] = string.format(
            "[%q] = { abi = %q, types = %q }",
            modname, entry.abi, entry.types)
    end
    local script_source = [[
local image, result = ...
local expected = { ]] .. table.concat(expected, ",\n") .. [[ }

local function finish(ok, message)
    local out = assert(io.open(result, "wb"))
    out:write(message)
    out:close()
    os.exit(ok and 0 or 1)
end

local support = require "titan"
for name, entry in pairs(expected) do
    local prefix = name:gsub("[.]", "_")
    for _, field in ipairs({ "abi", "types" }) do
        local symbol = prefix .. "_" .. field
        local fn, load_error = support._loadlib(image, symbol)
        if not fn then
            finish(false, "cannot resolve " .. symbol .. ": " ..
                tostring(load_error))
        end
        local values = table.pack(pcall(fn))
        if not values[1] then
            finish(false, symbol .. " failed: " .. tostring(values[2]))
        end
        if values.n ~= 2 or values[2] ~= entry[field] then
            finish(false, symbol .. " does not match embedded metadata")
        end
    end
    for _, symbol in ipairs({
        prefix .. "_init",
        "luaopen_" .. prefix,
    }) do
        local fn, load_error = support._loadlib(image, symbol)
        if not fn then
            finish(false, "cannot resolve " .. symbol .. ": " ..
                tostring(load_error))
        end
    end
end
finish(true, "ok")
]]
    local script = os.tmpname()
    local result = os.tmpname()
    local wrote, write_err = util.set_file_contents(script, script_source)
    if not wrote then
        os.remove(script)
        os.remove(result)
        return nil, write_err
    end
    local ran, term, code = run_argv({
        current_lua_executable(), "-E", script,
        absolute_filename(filename), result,
    }, verbose)
    local message = util.get_file_contents(result)
    os.remove(script)
    os.remove(result)
    if not ran or message ~= "ok" then
        return nil, "fresh-process validation of linked container '" ..
            tostring(filename) .. "' failed: " ..
            tostring(message or term) ..
            (code and (" (exit " .. tostring(code) .. ")") or "")
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

local function generated_shim_contents(provider, modname)
    return driver.GENERATED_SHIM_BANNER .. util.render(
        shim_template, {
            PROVIDER = string.format("%q", provider),
            ENTRY = string.format(
                "%q", "luaopen_" .. driver.mangle_module_name(modname)),
        })
end

local function same_existing_file(left, right)
    local left_attr = lfs.attributes(left)
    local right_attr = lfs.attributes(right)
    return left_attr and right_attr and
        left_attr.dev ~= nil and left_attr.ino ~= nil and
        left_attr.dev == right_attr.dev and left_attr.ino == right_attr.ino
end

local function same_file_contents(left, right)
    local left_attr = lfs.symlinkattributes(left)
    local right_attr = lfs.symlinkattributes(right)
    if not left_attr or not right_attr or
       left_attr.mode ~= "file" or right_attr.mode ~= "file" or
       left_attr.permissions ~= right_attr.permissions or
       left_attr.size ~= right_attr.size then
        return false
    end

    local left_file = io.open(left, "rb")
    if not left_file then return false end
    local right_file = io.open(right, "rb")
    if not right_file then
        left_file:close()
        return false
    end
    while true do
        local left_chunk, left_err = left_file:read(64 * 1024)
        local right_chunk, right_err = right_file:read(64 * 1024)
        if left_err or right_err or left_chunk ~= right_chunk then
            left_file:close()
            right_file:close()
            return false
        end
        if not left_chunk then
            left_file:close()
            right_file:close()
            return true
        end
    end
end

-- A supported archiver without deterministic `D` may vary the ownership,
-- mode, and timestamp fields in otherwise identical regular-archive records.
-- Compare every structural field and every record byte, including indexes and
-- long-name tables, while ignoring only those four fixed-width header fields.
local function same_regular_archive_contents(left, right)
    if same_file_contents(left, right) then return true end

    local left_attr = lfs.symlinkattributes(left)
    local right_attr = lfs.symlinkattributes(right)
    if not left_attr or not right_attr or
       left_attr.mode ~= "file" or right_attr.mode ~= "file" or
       left_attr.permissions ~= right_attr.permissions or
       left_attr.size ~= right_attr.size then
        return false
    end
    local left_file = io.open(left, "rb")
    if not left_file then return false end
    local right_file = io.open(right, "rb")
    if not right_file then
        left_file:close()
        return false
    end
    local function finish(result)
        left_file:close()
        right_file:close()
        return result
    end

    local left_magic, left_magic_err = left_file:read(8)
    local right_magic, right_magic_err = right_file:read(8)
    if left_magic_err or right_magic_err or
       left_magic ~= "!<arch>\n" or right_magic ~= left_magic then
        return finish(false)
    end

    local remaining = left_attr.size - 8
    while remaining ~= 0 do
        if remaining < 60 then return finish(false) end
        local left_header, left_header_err = left_file:read(60)
        local right_header, right_header_err = right_file:read(60)
        if left_header_err or right_header_err or
           not left_header or not right_header or
           left_header:sub(1, 16) ~= right_header:sub(1, 16) or
           left_header:sub(49, 60) ~= right_header:sub(49, 60) then
            return finish(false)
        end
        local size_digits =
            left_header:sub(49, 58):match("^ *(%d+) *$")
        local member_size = size_digits and tonumber(size_digits)
        local padding = member_size and (member_size % 2) or 0
        local record_size =
            member_size and (60 + member_size + padding) or nil
        if not record_size or record_size > remaining then
            return finish(false)
        end

        local unread = member_size
        while unread ~= 0 do
            local amount = math.min(64 * 1024, unread)
            local left_chunk, left_err = left_file:read(amount)
            local right_chunk, right_err = right_file:read(amount)
            if left_err or right_err or left_chunk ~= right_chunk or
               not left_chunk or #left_chunk ~= amount then
                return finish(false)
            end
            unread = unread - amount
        end
        if padding ~= 0 then
            local left_padding, left_padding_err = left_file:read(1)
            local right_padding, right_padding_err = right_file:read(1)
            if left_padding_err or right_padding_err or
               left_padding ~= "\n" or right_padding ~= left_padding then
                return finish(false)
            end
        end
        remaining = remaining - record_size
    end
    return finish(true)
end

local function directory_entries(path)
    local opened, iterator, state = pcall(lfs.dir, path)
    if not opened or type(iterator) ~= "function" then return nil end
    local entries = {}
    for name in iterator, state do
        if name ~= "." and name ~= ".." then
            entries[#entries + 1] = name
        end
    end
    table.sort(entries, util.bytewise_less)
    return entries
end

local function same_file_tree(left, right)
    local left_attr = lfs.symlinkattributes(left)
    local right_attr = lfs.symlinkattributes(right)
    if not left_attr or not right_attr or
       left_attr.mode ~= right_attr.mode or
       left_attr.permissions ~= right_attr.permissions then
        return false
    end
    if left_attr.mode == "file" then
        return same_file_contents(left, right)
    elseif left_attr.mode ~= "directory" then
        return false
    end

    local left_entries = directory_entries(left)
    local right_entries = directory_entries(right)
    if not left_entries or not right_entries or
       #left_entries ~= #right_entries then
        return false
    end
    for index, name in ipairs(left_entries) do
        if right_entries[index] ~= name or
           not same_file_tree(
               join_path(left, name), join_path(right, name)) then
            return false
        end
    end
    return true
end

function driver.validate_provider_output_paths(public_dso, native_inputs)
    local public_archive = public_dso:gsub("[.]so$", ".a")
    if public_archive == public_dso then
        return nil, "provider DSO path '" .. tostring(public_dso) ..
            "' does not end in .so"
    end
    for _, path in ipairs({ public_dso, public_archive }) do
        local ancestors_ok, ancestors_err = validate_output_ancestors(path)
        if not ancestors_ok then return nil, ancestors_err end
        local attr = lfs.symlinkattributes(path)
        if attr and attr.mode ~= "file" then
            return nil, "refusing to replace nonregular native provider path '" ..
                path .. "'"
        end
    end
    local dsym = public_dso .. ".dSYM"
    local dsym_attr = lfs.symlinkattributes(dsym)
    if dsym_attr and dsym_attr.mode ~= "directory" then
        return nil, "refusing to replace non-directory dSYM path '" ..
            dsym .. "'"
    end

    local outputs = {
        {
            raw = absolute_filename(public_dso),
            normalized = normalized_absolute_filename(public_dso),
            physical = physical_absolute_filename(public_dso),
        },
        {
            raw = absolute_filename(public_archive),
            normalized = normalized_absolute_filename(public_archive),
            physical = physical_absolute_filename(public_archive),
        },
        {
            raw = absolute_filename(dsym),
            normalized = normalized_absolute_filename(dsym),
            physical = physical_absolute_filename(dsym),
        },
    }
    for _, input in ipairs(native_inputs or {}) do
        local path = archive_input_path(input)
        if type(path) == "string" then
            local raw_input = absolute_filename(path)
            local absolute_input = normalized_absolute_filename(path)
            local physical_input = physical_absolute_filename(path)
            for _, output in ipairs(outputs) do
                if absolute_input == output.normalized or
                   physical_input == output.physical or
                   same_existing_file(raw_input, output.raw) or
                   absolute_input:sub(1, #output.normalized + 1) ==
                       output.normalized .. "/" or
                   physical_input:sub(1, #output.physical + 1) ==
                       output.physical .. "/" then
                    return nil, "native provider output '" ..
                        output.normalized ..
                        "' aliases input '" .. absolute_input .. "'"
                end
            end
        end
    end
    return true, public_archive
end

local function validate_generated_shim_destination(filename)
    local parents_ok, parents_err = validate_output_ancestors(filename)
    if not parents_ok then return nil, parents_err end
    local attr = lfs.symlinkattributes(filename)
    if not attr then return true end
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
    return true
end

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

        local destination_ok, destination_err =
            validate_generated_shim_destination(filename)
        if not destination_ok then return nil, destination_err end

        table.insert(plans, {
            modname = modname,
            filename = filename,
            contents = generated_shim_contents(provider, modname),
        })
    end
    return plans, provider_path
end

-- Publish one validated no-main bundle as a recoverable process-level
-- transaction. Shims, dSYM, and archive are committed before the DSO; the DSO
-- rename is the ordinary dynamic-path commit point. Tests may inject a caught
-- failure at a named boundary through options.fail_at.
function driver.publish_provider_bundle(
        staged_dso, staged_archive, public_dso, shim_plans, new_entries, options)
    options = options or {}
    shim_plans = shim_plans or {}
    new_entries = new_entries or {}
    local public_archive = options.public_archive or
        public_dso:gsub("[.]so$", ".a")
    if public_archive == public_dso then
        return nil, "provider DSO path '" .. tostring(public_dso) ..
            "' does not end in .so"
    end
    local outputs_ok, outputs_err =
        driver.validate_provider_output_paths(
            public_dso, options.native_inputs)
    if not outputs_ok then return nil, outputs_err end
    for _, input in ipairs({ staged_dso, staged_archive }) do
        if lfs.symlinkattributes(input, "mode") ~= "file" then
            return nil, "staged provider artifact '" .. tostring(input) ..
                "' is not a regular file"
        end
    end
    local distinct = {
        { staged_dso, staged_archive },
        { staged_dso, public_dso },
        { staged_archive, public_archive },
    }
    for _, pair in ipairs(distinct) do
        if absolute_filename(pair[1]) == absolute_filename(pair[2]) or
           same_existing_file(pair[1], pair[2]) then
            return nil, "staged provider artifact '" .. tostring(pair[1]) ..
                "' aliases destination/input '" .. tostring(pair[2]) .. "'"
        end
    end

    local staged_dsym = staged_dso .. ".dSYM"
    local public_dsym = public_dso .. ".dSYM"
    if driver.IS_DARWIN and
       lfs.symlinkattributes(staged_dsym, "mode") ~= "directory" then
        return nil, "staged provider DSO '" .. staged_dso ..
            "' has no companion dSYM"
    end

    local staged_shims = {}
    local new_shim_paths = {}
    local function cleanup_staged_shims()
        for _, staged in ipairs(staged_shims) do remove_path(staged.path) end
    end
    for _, plan in ipairs(shim_plans) do
        local destination_ok, destination_err =
            validate_generated_shim_destination(plan.filename)
        if not destination_ok then
            cleanup_staged_shims()
            return nil, destination_err
        end
        local output_ok, output_err = ensure_output_parent(plan.filename)
        if not output_ok then
            cleanup_staged_shims()
            return nil, output_err
        end
        local temporary = driver.sibling_temporary_path(
            plan.filename .. ".provider-stage")
        local wrote, write_err =
            util.set_file_contents(temporary, plan.contents)
        if not wrote then
            remove_path(temporary)
            cleanup_staged_shims()
            return nil, write_err
        end
        staged_shims[#staged_shims + 1] = {
            path = temporary,
            public = plan.filename,
        }
        new_shim_paths[plan.filename] = true
    end

    local stale_shims = {}
    local provider_name = options.provider or
        public_dso:match("([^/]+)[.]so$")
    if lfs.symlinkattributes(public_archive, "mode") == "file" then
        local previous = staticmetadata.scan_archive(
            public_archive, metadata_scan_options())
        if previous then
            for name in pairs(previous.entries or {}) do
                if not new_entries[name] then
                    local filename = safe_module_output_path(name, ".lua")
                    if filename and not new_shim_paths[filename] then
                        local attr = lfs.symlinkattributes(filename)
                        if attr then
                            if attr.mode ~= "file" then
                                cleanup_staged_shims()
                                return nil, "refusing to retire non-file old " ..
                                    "Lua shim path '" .. filename .. "'"
                            end
                            local input, read_err =
                                util.get_file_contents(filename)
                            if not input then
                                cleanup_staged_shims()
                                return nil, read_err
                            end
                            local expected = provider_name and
                                generated_shim_contents(provider_name, name)
                            if not expected or input ~= expected then
                                cleanup_staged_shims()
                                return nil, "refusing to retire unrecognized " ..
                                    "old Lua shim '" .. filename .. "'"
                            end
                            stale_shims[#stale_shims + 1] = filename
                        end
                    end
                end
            end
            table.sort(stale_shims, util.bytewise_less)
        end
    end

    local unchanged = #stale_shims == 0 and
        same_file_contents(staged_dso, public_dso) and
        same_regular_archive_contents(staged_archive, public_archive)
    if unchanged then
        for _, item in ipairs(staged_shims) do
            if not same_file_contents(item.path, item.public) then
                unchanged = false
                break
            end
        end
    end
    if unchanged then
        if driver.IS_DARWIN then
            unchanged = same_file_tree(staged_dsym, public_dsym)
        else
            unchanged = not lfs.symlinkattributes(public_dsym)
        end
    end
    if unchanged then
        remove_path(staged_dso)
        remove_path(staged_archive)
        remove_path(staged_dsym)
        cleanup_staged_shims()
        return true, public_archive
    end

    local backups = {}
    local installed = {}
    local backed_up = {}
    local function backup(public)
        if backed_up[public] then return true end
        backed_up[public] = true
        if not lfs.symlinkattributes(public, "mode") then return true end
        local old = driver.sibling_temporary_path(public .. ".old")
        local moved, move_err = os.rename(public, old)
        if not moved then return nil, move_err end
        backups[#backups + 1] = { public = public, old = old }
        return true
    end
    local function install(staged, public)
        local backed, backup_err = backup(public)
        if not backed then return nil, backup_err end
        local moved, move_err = os.rename(staged, public)
        if not moved then return nil, move_err end
        installed[#installed + 1] = public
        return true
    end
    local function inject(boundary)
        local requested = options.fail_at
        if requested == boundary then
            return nil, "injected provider publication failure at " .. boundary
        end
        if options.inject_failure then
            local ok, message = options.inject_failure(boundary)
            if ok == false or type(ok) == "string" then
                return nil, message or ok
            end
        end
        return true
    end
    local function rollback(message)
        for index = #installed, 1, -1 do
            remove_path(installed[index])
        end
        for index = #backups, 1, -1 do
            local item = backups[index]
            os.rename(item.old, item.public)
        end
        cleanup_staged_shims()
        return nil, message
    end
    local ok, err = inject("before-shims")
    if not ok then return rollback(err) end
    for _, item in ipairs(staged_shims) do
        ok, err = install(item.path, item.public)
        if not ok then return rollback(err) end
    end
    for _, filename in ipairs(stale_shims) do
        ok, err = backup(filename)
        if not ok then return rollback(err) end
    end
    ok, err = inject("after-shims")
    if not ok then return rollback(err) end

    if driver.IS_DARWIN then
        ok, err = install(staged_dsym, public_dsym)
        if not ok then return rollback(err) end
    else
        ok, err = backup(public_dsym)
        if not ok then return rollback(err) end
    end
    ok, err = inject("after-dsym")
    if not ok then return rollback(err) end

    ok, err = inject("before-archive")
    if not ok then return rollback(err) end
    ok, err = install(staged_archive, public_archive)
    if not ok then return rollback(err) end
    ok, err = inject("after-archive")
    if not ok then return rollback(err) end

    ok, err = inject("before-dso")
    if not ok then return rollback(err) end
    ok, err = install(staged_dso, public_dso)
    if not ok then return rollback(err) end
    ok, err = inject("after-dso")
    if not ok then return rollback(err) end

    for _, item in ipairs(backups) do remove_path(item.old) end
    cleanup_staged_shims()
    return true, public_archive
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

local function standalone_archive_probe_source(
        entries, module_names, validate_titan_support)
    local declarations = {}
    local checks = {}
    for index, modname in ipairs(module_names) do
        local entry = assert(entries[modname])
        local prefix = driver.mangle_module_name(modname)
        local abi_bytes = assert(staticmetadata.c_initializer(entry.abi))
        local types_bytes = assert(staticmetadata.c_initializer(entry.types))
        declarations[#declarations + 1] = string.format([[
extern int %s_abi(lua_State *L);
extern int %s_types(lua_State *L);
extern void *%s_init(lua_State *L);
extern int luaopen_%s(lua_State *L);
static void *(*volatile keep_init_%d)(lua_State *) = %s_init;
static int (*volatile keep_open_%d)(lua_State *) = luaopen_%s;
static const unsigned char expected_abi_%d[] = %s;
static const unsigned char expected_types_%d[] = %s;
]], prefix, prefix, prefix, prefix, index, prefix, index, prefix,
            index, abi_bytes, index, types_bytes)
        checks[#checks + 1] = string.format([[
    if (keep_init_%d == NULL || keep_open_%d == NULL) return 20;
    lua_settop(L, 0);
    if (%s_abi(L) != 1 || lua_type(L, -1) != LUA_TSTRING) return 21;
    value = lua_tolstring(L, -1, &length);
    if (length != %d || memcmp(value, expected_abi_%d, length) != 0) return 22;
    lua_settop(L, 0);
    if (%s_types(L) != 1 || lua_type(L, -1) != LUA_TSTRING) return 23;
    value = lua_tolstring(L, -1, &length);
    if (length != %d || memcmp(value, expected_types_%d, length) != 0) return 24;
]], index, index, prefix, #entry.abi, index, prefix, #entry.types, index)
    end
    local support_declaration = validate_titan_support and [[
extern int luaopen_titan(lua_State *L);
static int (*volatile keep_titan_support)(lua_State *) = luaopen_titan;
]] or ""
    local support_check = validate_titan_support and [[
    lua_settop(L, 0);
    if (keep_titan_support == NULL || luaopen_titan(L) != 1 ||
        lua_type(L, -1) != LUA_TTABLE) return 30;
    lua_getfield(L, -1, "_loadlib");
    if (lua_type(L, -1) != LUA_TFUNCTION) return 31;
    lua_pop(L, 1);
    lua_getfield(L, -1, "_loadlibglobal");
    if (lua_type(L, -1) != LUA_TFUNCTION) return 32;
    lua_settop(L, 0);
]] or ""
    return [[
#include <stddef.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
]] .. table.concat(declarations, "\n") .. support_declaration .. [[
int main(void) {
    lua_State *L = luaL_newstate();
    const char *value;
    size_t length;
    if (L == NULL) return 10;
]] .. table.concat(checks, "\n") .. support_check .. [[
    lua_close(L);
    return 0;
}
]]
end

-- Before publishing a standalone executable, prove that the selected
-- self-describing archives expose their callable protocols under ordinary
-- executable archive extraction (not whole-archive force loading).
function driver.run_standalone_archive_probe(
        entries, module_names, libnames, static_archives,
        link, verbose, extra_objects, validate_titan_support)
    if #module_names == 0 and not validate_titan_support then return true end
    local runtime_ok, runtime_err = check_runtime(verbose)
    if not runtime_ok then return nil, runtime_err end
    local base = os.tmpname()
    os.remove(base)
    local source = base .. ".c"
    local object = base .. ".o"
    local executable = base .. ".probe"
    local function cleanup()
        os.remove(source)
        os.remove(object)
        os.remove(executable)
        remove_path(executable .. ".dSYM")
    end
    local wrote, write_err = util.set_file_contents(
        source, standalone_archive_probe_source(
            entries, module_names, validate_titan_support))
    if not wrote then
        cleanup()
        return nil, write_err
    end

    local compile_args, flags_err = compiler_argv(true)
    if not compile_args then
        cleanup()
        return nil, flags_err
    end
    append_argv(compile_args, { "-c", source })
    append_compile_includes(compile_args)
    append_argv(compile_args, { "-o", object })
    local compiled, compile_term, compile_code =
        run_argv(compile_args, verbose)
    if not compiled then
        cleanup()
        return nil, "failed to compile static-provider executable probe (" ..
            tostring(compile_term) .. ", exit " ..
            tostring(compile_code) .. ")"
    end

    local args
    args, flags_err = compiler_argv(false)
    if not args then
        cleanup()
        return nil, flags_err
    end
    append_argv(args, { "-o", executable, object })
    append_argv(args, libnames or {})
    local runtime = runtime_link_inputs()
    append_argv(args, driver.standalone_native_link_inputs(
        static_archives, extra_objects, runtime))
    if link then
        for _, lib in ipairs(util.split_string(link, ",")) do
            table.insert(args, "-l" .. lib)
        end
    end
    append_argv(args, driver.EXTRA_LDFLAGS)
    local linked, link_term, link_code = run_argv(args, verbose)
    if not linked then
        cleanup()
        return nil, "selected static provider failed executable-context " ..
            "protocol linking (" .. tostring(link_term) .. ", exit " ..
            tostring(link_code) .. ")"
    end
    local ran, run_term, run_code = run_argv({ executable }, verbose)
    cleanup()
    if not ran then
        return nil, "selected static provider failed executable-context " ..
            "protocol validation (" .. tostring(run_term) .. ", exit " ..
            tostring(run_code) .. ")"
    end
    return true
end

function driver.compile_program(modname, libnames, link, verbose, extra_objects,
                                program_output, static_archives)
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
    local runtime = runtime_link_inputs()
    append_argv(args, driver.standalone_native_link_inputs(
        static_archives, extra_objects, runtime))
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
