local parser = require  "titan-compiler.parser"
local util = require "titan-compiler.util"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local types = require "titan-compiler.types"
local location = require "titan-compiler.location"
local staticmetadata = require "titan-compiler.staticmetadata"
local cdriver = require "c-parser.cdriver"
local cprobe = require "titan-compiler.cprobe"
local csemantics = require "titan-compiler.csemantics"
local compiler_io = require "titan-compiler.io"
local sourceinterface = require "titan-compiler.sourceinterface"
local version = require "titan-compiler.version"

local lfs = require "lfs"

local driver = {}

driver.imported = {}

-- Compiled-module metadata encodes the monotonic ABI integer as its canonical
-- decimal string. The semantic release and its major/minor library namespace
-- are deliberately independent from that compatibility marker.
driver.TITAN_ABI_VERSION = version.TITAN_ABI_VERSION
driver.TITAN_VERSION = version.TITAN_VERSION
driver.TITAN_LIBRARY_VERSION = version.TITAN_LIBRARY_VERSION
driver.TITAN_LIBRARY_VERSION_SUFFIX = version.TITAN_LIBRARY_VERSION_SUFFIX
driver.LUA_VERSION = version.LUA_VERSION

-- Version of the additive compiler contract consumed by the Titan language
-- server. This is intentionally independent from TITAN_ABI_VERSION: matching the
-- generated-code ABI does not imply support for semantic AST metadata,
-- incremental source/interface caches, analysis-local FFI include paths, or
-- cooperative scheduling. API 2 additionally guarantees exact C-header
-- dependency metadata and driver.restat_c_header_dependencies. API 3 owns all
-- analysis I/O and cooperative checkpoints through one resolver strategy and
-- publishes an opaque source-visible manifest for every clean source entry.
-- API 4 additionally accepts one validated, analysis-only embedded interface
-- provider whose entries never become native link inputs. API 5 admits its
-- verified build-target numeric profile for SDK-free semantic analysis while
-- retaining live native-toolchain checks for actual C probes.
driver.LANGUAGE_SERVER_API_VERSION = 5

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

local function absolute_filename(filename, strategy)
    if filename:sub(1, 1) == "/" then return filename end
    if strategy then
        local current_dir, current_err = strategy:cwd()
        if not current_dir then return nil, current_err end
        return current_dir .. "/" .. filename
    end
    return lfs.currentdir() .. "/" .. filename
end

local function normalized_absolute_filename(filename)
    return normalize_absolute_path(absolute_filename(filename))
end

-- Canonicalize the longest existing pathname prefix through the filesystem.
-- This preserves POSIX symlink/.. resolution for alias and containment checks
-- while retaining every not-yet-created destination component.
local function physical_absolute_filename(filename)
    local raw = absolute_filename(filename)
    local previous = lfs.currentdir()
    local unresolved = {}
    local candidate = raw
    local seen = {}
    local seen_links = {}
    local link_hops = 0
    while candidate and candidate ~= "" and not seen[candidate] do
        seen[candidate] = true
        local attributes = lfs.symlinkattributes(candidate)
        if attributes and attributes.mode == "link" and attributes.target then
            link_hops = link_hops + 1
            local identity = attributes.dev ~= nil and
                attributes.ino ~= nil and
                (tostring(attributes.dev) .. ":" .. tostring(attributes.ino))
            if link_hops > 40 or (identity and seen_links[identity]) then
                break
            end
            if identity then seen_links[identity] = true end
            if attributes.target:sub(1, 1) == "/" then
                candidate = attributes.target
            else
                local parent = candidate:match("^(.*)/[^/]*$") or "."
                candidate = parent .. "/" .. attributes.target
            end
        elseif lfs.chdir(candidate) then
            local resolved = lfs.currentdir()
            assert(lfs.chdir(previous))
            for _, component in ipairs(unresolved) do
                resolved = (resolved == "/" and "/" or
                    (resolved .. "/")) .. component
            end
            return normalize_absolute_path(resolved)
        else
            local parent, leaf = candidate:match("^(.*)/([^/]*)$")
            if not parent then break end
            table.insert(unresolved, 1, leaf)
            candidate = parent == "" and "/" or parent
        end
    end
    return normalize_absolute_path(raw)
end

local function same_existing_file(left, right)
    local left_attr = lfs.attributes(left)
    local right_attr = lfs.attributes(right)
    return left_attr and right_attr and
        left_attr.dev ~= nil and left_attr.ino ~= nil and
        left_attr.dev == right_attr.dev and left_attr.ino == right_attr.ino
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

local function normalize_root(root, strategy)
    if type(root) ~= "string" or root == "" then return nil end
    local current_dir
    if root:sub(1, 1) ~= "/" then
        if strategy then
            local current_err
            current_dir, current_err = strategy:cwd()
            if not current_dir then return nil, current_err end
        else
            current_dir = lfs.currentdir()
        end
        root = current_dir .. "/" .. root
    end
    -- A literal `..` after a symlink must be resolved by the filesystem:
    -- lexical normalization would name a different directory. Ordinary roots
    -- keep their normalized pathname spelling (notably macOS /tmp rather than
    -- /private/tmp), preserving the existing loader-path contract.
    if ("/" .. root .. "/"):find("/../", 1, true) then
        if strategy then
            local resolved, resolve_error = strategy:realpath(root)
            if resolved then return resolved end
            local attributes, attribute_error = strategy:stat(root)
            if attribute_error then return nil, attribute_error end
            if attributes then return nil, resolve_error end
            return normalize_absolute_path(root)
        end
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

function driver.probe_cache_directory(cpath, override, abi)
    local root = driver.resolve_installation_root(cpath, override)
    if not root then return nil end
    return root_join(root, "var/cache/titan-probes/" ..
        tostring(abi or driver.TITAN_ABI_VERSION))
end

function driver.installed_paths(root)
    root = normalize_root(root)
    if not root then return nil end
    local titan_lib = root_join(
        root, "lib/titan/" .. driver.TITAN_LIBRARY_VERSION)
    return {
        root = root,
        lua_source = root_join(root, "src/lua-5.5.1"),
        include = root_join(root, "include"),
        lib = root_join(root, "lib"),
        libtitan = titan_lib .. "/libtitan.a",
        libbacktrace = root_join(root, "lib/libbacktrace.a"),
        liblua = root_join(root, "lib/liblua.a"),
        titan_bin = titan_lib,
        lua_cpath = titan_lib .. "/?.so",
        test_source = root_join(root, "share/titan/" ..
            driver.TITAN_LIBRARY_VERSION .. "/src/titan/test.titan"),
    }
end

function driver.source_checkout_from_driver_source(
        source, current_dir, strategy)
    if type(source) ~= "string" then return false end
    if source:sub(1, 1) ~= "@" then return false end
    source = source:sub(2)
    if source:sub(1, 1) ~= "/" then
        if not current_dir and strategy then
            local current_error
            current_dir, current_error = strategy:cwd()
            if not current_dir then return false, current_error end
        end
        source = (current_dir or lfs.currentdir()) .. "/" .. source
    end
    local root = source:match("^(.*)/titan%-compiler/driver[.]lua$")
    if not root then return false end
    if strategy then
        local runtime, runtime_error =
            strategy:stat(root .. "/titan-runtime/titan.c")
        if runtime_error then return false, runtime_error end
        local makefile, makefile_error = strategy:stat(root .. "/Makefile")
        if makefile_error then return false, makefile_error end
        return runtime and runtime.kind == "file" and
            makefile and makefile.kind == "file" or false
    end
    return lfs.attributes(root .. "/titan-runtime/titan.c", "mode") ==
        "file" and lfs.attributes(root .. "/Makefile", "mode") == "file"
end

local function driver_source()
    if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then
        return nil
    end
    local source = debug.getinfo(1, "S").source
    if type(source) ~= "string" or source:sub(1, 1) ~= "@" then return nil end
    return source
end

local DRIVER_SOURCE = driver_source()

local function source_checkout_root(strategy)
    local source = DRIVER_SOURCE
    if not source then return nil end
    source = source:sub(2)
    if source:sub(1, 1) ~= "/" then
        local current_dir, current_error = strategy:cwd()
        if not current_dir then return nil, current_error end
        source = current_dir .. "/" .. source
    end
    local root = source:match("^(.*)/titan%-compiler/driver[.]lua$")
    if root then
        local checkout, checkout_error =
            driver.source_checkout_from_driver_source(
                "@" .. source, nil, strategy)
        if checkout_error then return nil, checkout_error end
        if checkout then return normalize_root(root, strategy) end
    end
    return nil
end

local internal_root = os.getenv("TITAN_ROCKS_ROOT")
if internal_root == "" then internal_root = nil end
local probe_prefix = os.getenv("TITAN_PREFIX")
if probe_prefix == "" then probe_prefix = nil end
local probe_cache_disabled = os.getenv("TITAN_PROBE_CACHE_DISABLE") == "1"
local configured_installation_root =
    internal_root or driver.root_from_package_cpath(package.cpath)
driver.TITAN_ROOT = configured_installation_root and
    configured_installation_root:sub(1, 1) == "/" and
    normalize_absolute_path(configured_installation_root) or nil
local preliminary_probe_root = probe_prefix and
    probe_prefix:sub(1, 1) == "/" and
    normalize_absolute_path(probe_prefix) or driver.TITAN_ROOT
driver.PROBE_CACHE_DIRECTORY = not probe_cache_disabled and
    preliminary_probe_root and root_join(preliminary_probe_root,
        "var/cache/titan-probes/" .. driver.TITAN_ABI_VERSION) or nil
local probe_cache_identity = os.getenv("TITAN_PROBE_CACHE_IDENTITY")
if probe_cache_identity == "" then probe_cache_identity = nil end
driver.PROBE_CACHE_IDENTITY = probe_cache_identity
local configured_titan_bin_path =
    os.getenv("TITAN_PATH" .. driver.TITAN_LIBRARY_VERSION_SUFFIX)
    or os.getenv("TITAN_PATH")

local function apply_layout(source_root)
    local previous_bin_default = driver.DEFAULT_TITAN_BIN_PATH
    local previous_lua_default = driver._DEFAULT_LUA_SOURCE_PATH
    driver.SOURCE_CHECKOUT_ROOT = source_root
    driver.SOURCE_CHECKOUT = source_root ~= nil
    driver.INSTALLED = not driver.SOURCE_CHECKOUT
    driver.INSTALL_PATHS = driver.installed_paths(driver.TITAN_ROOT)
    driver.TEST_SUPPORT_SOURCE_PATH = driver.SOURCE_CHECKOUT and
        (source_root .. "/titan/test.titan") or
        (driver.INSTALL_PATHS and driver.INSTALL_PATHS.test_source or nil)
    driver.INSTALLATION_ERROR = driver.INSTALLED and
        not driver.INSTALL_PATHS and
        ("cannot locate the Titan installation: package.cpath has no entry " ..
            "ending in '" .. LUA_CPATH_SUFFIX .. "'") or nil

    local bin_default = driver.INSTALL_PATHS and
        (".;" .. driver.INSTALL_PATHS.titan_bin) or
        (".;/usr/local/lib/titan/" .. driver.TITAN_LIBRARY_VERSION)
    driver.DEFAULT_TITAN_BIN_PATH = bin_default
    if driver.TITAN_BIN_PATH == nil or
       driver.TITAN_BIN_PATH == previous_bin_default then
        driver.TITAN_BIN_PATH = configured_titan_bin_path or bin_default
    end

    local lua_default = driver.INSTALLED and driver.INSTALL_PATHS and
        driver.INSTALL_PATHS.lua_source or "lua-5.5.1/src"
    driver._DEFAULT_LUA_SOURCE_PATH = lua_default
    if driver.LUA_SOURCE_PATH == nil or
       driver.LUA_SOURCE_PATH == previous_lua_default then
        driver.LUA_SOURCE_PATH = lua_default
    end
    driver.INCLUDE_PATH = driver.INSTALLED and driver.INSTALL_PATHS and
        driver.INSTALL_PATHS.include or nil
end

-- Keep module loading purely lexical. A relative driver source is the ordinary
-- checkout shape; every real filesystem check and canonicalization is repeated
-- through the first resolver context below before compiler work begins.
local lexical_source_root = not internal_root and DRIVER_SOURCE and
    DRIVER_SOURCE:sub(2, 2) ~= "/" and
    DRIVER_SOURCE:sub(2):match("^(.*)/titan%-compiler/driver[.]lua$") or nil
apply_layout(lexical_source_root)

function driver.initialize_layout(context)
    if type(context) ~= "table" or context.io == nil then
        error("compiler layout initialization requires a resolver context", 2)
    end
    compiler_io.validate(context.io, 2)
    if context._layout_initialized then return true end

    local installation_root
    if configured_installation_root then
        local installation_error
        installation_root, installation_error = normalize_root(
            configured_installation_root, context.io)
        if not installation_root then return nil, installation_error end
    end
    driver.TITAN_ROOT = installation_root

    local checkout_root, checkout_error
    if not internal_root then
        checkout_root, checkout_error = source_checkout_root(context.io)
        if checkout_error then return nil, checkout_error end
    end
    apply_layout(checkout_root)

    local cache_root = probe_prefix or installation_root
    if not probe_cache_disabled and cache_root then
        local cache_error
        cache_root, cache_error = normalize_root(cache_root, context.io)
        if not cache_root then return nil, cache_error end
        driver.PROBE_CACHE_DIRECTORY = root_join(cache_root,
            "var/cache/titan-probes/" .. driver.TITAN_ABI_VERSION)
    else
        driver.PROBE_CACHE_DIRECTORY = nil
    end
    driver.TOOLCHAIN_ERROR = driver.INSTALLATION_ERROR or
        driver._TOOLCHAIN_FLAGS_ERROR
    context._layout_initialized = true
    return true
end

driver.TITAN_SOURCE_PATH = "."
driver.EMIT_LINE_DIRECTIVES = os.getenv("TITAN_NO_LINE_DIRECTIVES") ~= "1"
driver.TITAN_RUNTIME_PATH = "titan-runtime/"
driver.LIBBACKTRACE_PATH = "libbacktrace"
driver.CFLAGS = "--std=c99 -O2 -Wall -Wno-unused-but-set-variable -Wno-unused-function -fPIC -g"

function driver.test_support_source_descriptor(context)
    local filename = driver.TEST_SUPPORT_SOURCE_PATH
    local is_file
    if filename and context and context.io then
        local attributes = context.io:stat(filename)
        is_file = attributes and attributes.kind == "file"
    else
        is_file = filename and lfs.attributes(filename, "mode") == "file"
    end
    if not is_file then
        return nil, "Titan test support source is missing" ..
            (filename and (" at '" .. filename .. "'") or "")
    end
    return {
        kind = "flat",
        main = filename,
        files = { filename },
        program_output = "titan/test",
    }
end
driver.CC = os.getenv("CC") or "cc"
driver.AR = os.getenv("AR") or "ar"
driver.RANLIB = os.getenv("RANLIB") or "ranlib"
driver.CLANG_FORMAT = os.getenv("CLANG_FORMAT") or "clang-format"

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
driver._TOOLCHAIN_FLAGS_ERROR = cppflags_error or cflags_error or ldflags_error
driver.TOOLCHAIN_ERROR = driver.INSTALLATION_ERROR or
    driver._TOOLCHAIN_FLAGS_ERROR
driver.FOREIGN_C_CONFIGURATION_ID = 0

function driver.foreign_include_dirs()
    local include_dirs
    if driver.INSTALLED then
        include_dirs = { driver.INCLUDE_PATH, driver.LUA_SOURCE_PATH }
    else
        include_dirs = {
            driver.TITAN_RUNTIME_PATH,
            driver.LUA_SOURCE_PATH,
            driver.LIBBACKTRACE_PATH,
        }
    end
    return include_dirs
end

function driver.initialize_platform(context)
    context = context or driver.new_resolver_context()
    if type(context) ~= "table" or context.io == nil then
        error("platform initialization requires a resolver context", 2)
    end
    compiler_io.validate(context.io, 2)
    if context._platform_initialized then
        return true, context.uname, context.is_darwin
    end

    local result = context.io:run({ "uname" }, {
        stderr_to_stdout = true,
    })
    if type(result) ~= "table" or not result.started or not result.ok then
        local detail = type(result) == "table" and
            (result.diagnostic or result.output) or result
        return nil, "cannot determine the native platform with uname: " ..
            tostring(detail or "command failed")
    end
    local uname = tostring(result.output or ""):match("^%s*(.-)%s*$")
    if uname == "" then
        return nil, "cannot determine the native platform with uname: " ..
            "command produced no output"
    end
    context.uname = uname
    context.is_darwin = uname:match("Darwin") ~= nil
    context._platform_initialized = true

    -- Retain the historical process-visible fields for build/publication APIs.
    -- The subprocess which populates them now belongs to an explicit resolver
    -- context instead of running while this module is loaded.
    driver.UNAME = uname
    driver.IS_DARWIN = context.is_darwin
    return true, uname, context.is_darwin
end

function driver.configure_foreign_c(context)
    context = context or driver.new_resolver_context()
    if type(context) ~= "table" or context.io == nil then
        error("foreign C configuration requires a resolver context", 2)
    end
    compiler_io.validate(context.io, 2)
    local io_strategy = context.io
    local platform_ok, platform_result = driver.initialize_platform(context)
    local platform_err = not platform_ok and platform_result or nil

    -- Configuration is replaceable in embeddings and tests. A profile belongs
    -- to one exact compiler identity and must never survive a reconfiguration.
    driver.TARGET_PROFILE = nil
    local toolchain, toolchain_err
    if driver.toolchain_descriptor then
        toolchain, toolchain_err = driver.toolchain_descriptor(context)
    end
    local options = {
        io = io_strategy,
        process_trace = context.c_header_process_trace,
        process_analysis = context.c_header_analysis,
        compiler = driver.CC,
        language_mode = "c99",
        cppflags = toolchain and {} or (driver.EXTRA_CPPFLAGS or {}),
        compile_flags = toolchain and toolchain.compile_flags or {},
        compiler_include_dirs = driver.foreign_include_dirs(),
        toolchain = toolchain,
        probe_cache_directory = driver.PROBE_CACHE_DIRECTORY,
        probe_cache_identity = driver.PROBE_CACHE_IDENTITY,
    }
    if toolchain then options.language_flag = false end

    local profile_error
    if not (driver.TOOLCHAIN_ERROR or toolchain_err) then
        local inputs
        inputs, profile_error = cdriver.target_profile_inputs(options)
        if inputs then
            driver.TARGET_PROFILE, profile_error =
                csemantics.build_profile(inputs)
        end
    end
    if driver.TARGET_PROFILE then
        options.profile = driver.TARGET_PROFILE
        toolchain.profile = driver.TARGET_PROFILE
        toolchain.profile_identity = driver.TARGET_PROFILE.identity
    end
    context.foreign_c_profile_error = driver.TOOLCHAIN_ERROR or platform_err
        or toolchain_err or profile_error
    driver.FOREIGN_C_CONFIGURATION_ID =
        driver.FOREIGN_C_CONFIGURATION_ID + 1
    context.foreign_c_configuration_id =
        driver.FOREIGN_C_CONFIGURATION_ID
    -- Driver-backed checks acquire their probe service from the resolver
    -- context below. Keep analysis-scoped reuse and telemetry out of the
    -- checker module's process-global fallback configuration so the last root
    -- cannot retain a completed analysis (or its per-root trace closure) while
    -- the language server is idle.
    options.process_trace = nil
    options.process_analysis = nil
    checker.configure_foreign_c(
        options, driver.TOOLCHAIN_ERROR or platform_err or toolchain_err or
            profile_error)
    if not platform_ok then return nil, platform_err end
    return true
end

local CIRCULAR_MARK = {}
local loader_contexts = setmetatable({}, { __mode = "k" })
local embedded_interface_provider_snapshots =
    setmetatable({}, { __mode = "k" })

local function unexpected_closed_field(value, allowed)
    local unexpected = {}
    for key in pairs(value) do
        if not allowed[key] then
            unexpected[#unexpected + 1] = string.format("%q", tostring(key))
        end
    end
    table.sort(unexpected, util.bytewise_less)
    return unexpected[1]
end

local function copy_embedded_interface_provider_snapshot(snapshot)
    local provider = {
        provider_file = snapshot.provider_file,
        entries = {},
        key_order = {},
        analysis_only = true,
    }
    local memo = {}
    if snapshot.target_profile then
        provider.target_profile = types.clone_graph(snapshot.target_profile, memo)
    end
    for index, name in ipairs(snapshot.key_order) do
        local entry = snapshot.entries[name]
        provider.key_order[index] = name
        provider.entries[name] = {
            abi = entry.abi,
            types = entry.types,
            type = types.clone_graph(entry.type, memo),
            origin = entry.origin,
        }
    end
    return provider
end

-- A trusted semantic host may carry the compiler-facing interfaces for
-- modules already linked into its own process. Copy and validate that closed
-- manifest eagerly: resolver code must never retain caller-owned entry tables
-- or discover native metadata by opening the host executable. A successfully
-- validated raw table is an immutable host snapshot by contract. Reusing that
-- same table identity clones a private decoded graph from a weak-keyed cache;
-- later caller mutation neither changes nor invalidates the accepted snapshot.
local function validate_embedded_interface_provider(candidate)
    if candidate == nil then return nil end
    if type(candidate) ~= "table" then
        return nil, "must be a plain table"
    end
    local snapshot = embedded_interface_provider_snapshots[candidate]
    if snapshot then
        return copy_embedded_interface_provider_snapshot(snapshot)
    end
    if getmetatable(candidate) ~= nil then
        return nil, "must be a plain table"
    end
    local unexpected = unexpected_closed_field(candidate, {
        provider_file = true,
        entries = true,
        target_profile = true,
    })
    if unexpected then
        return nil, "contains unexpected field " .. unexpected
    end

    local provider_file = rawget(candidate, "provider_file")
    if type(provider_file) ~= "string" or
       provider_file:sub(1, 1) ~= "/" or
       provider_file:find("\0", 1, true) then
        return nil, "provider_file must be an absolute NUL-free pathname"
    end
    local candidate_entries = rawget(candidate, "entries")
    if type(candidate_entries) ~= "table" or
       getmetatable(candidate_entries) ~= nil then
        return nil, "entries must be a plain module-keyed table"
    end

    local provider = {
        provider_file = provider_file,
        entries = {},
        key_order = {},
        analysis_only = true,
    }
    local profile_data = rawget(candidate, "target_profile")
    if profile_data ~= nil then
        local profile, profile_error = csemantics.import_profile(profile_data)
        if not profile then
            return nil, "target_profile is invalid: " .. tostring(profile_error)
        end
        provider.target_profile = profile
    end
    local symbol_owners = {}
    for name, candidate_entry in pairs(candidate_entries) do
        if not staticmetadata.valid_module_name(name) then
            return nil, "entries contains invalid logical module name " ..
                string.format("%q", tostring(name))
        elseif type(candidate_entry) ~= "table" or
               getmetatable(candidate_entry) ~= nil then
            return nil, "entry for module '" .. name ..
                "' must be a plain table"
        end
        unexpected = unexpected_closed_field(candidate_entry, {
            abi = true,
            types = true,
        })
        if unexpected then
            return nil, "entry for module '" .. name ..
                "' contains unexpected field " .. unexpected
        end

        local abi = rawget(candidate_entry, "abi")
        local serialized = rawget(candidate_entry, "types")
        if type(abi) ~= "string" then
            return nil, "entry for module '" .. name ..
                "' ABI must be a string"
        elseif abi ~= driver.TITAN_ABI_VERSION then
            return nil, "entry for module '" .. name ..
                "' ABI mismatch: expected " .. driver.TITAN_ABI_VERSION ..
                " but found " .. tostring(abi)
        elseif type(serialized) ~= "string" then
            return nil, "entry for module '" .. name ..
                "' types must be a serialized module string"
        end

        local prefix = driver.mangle_module_name(name)
        local previous = symbol_owners[prefix]
        if previous then
            return nil, "entries for modules '" .. previous .. "' and '" ..
                name .. "' duplicate native symbol prefix '" .. prefix .. "'"
        end
        symbol_owners[prefix] = name

        local origin = provider_file .. ":" .. name
        local modtype, decode_error = driver.decode_module_interface(
            serialized, name, origin)
        if not modtype then
            return nil, "entry for module '" .. name ..
                "' has invalid types: " .. tostring(decode_error)
        end
        if provider.target_profile then
            local normalized, profile_error =
                types.normalize_portable_c_numeric_types(
                    modtype, provider.target_profile)
            if not normalized then
                return nil, "entry for module '" .. name ..
                    "' disagrees with target_profile: " .. tostring(profile_error)
            end
        end
        provider.entries[name] = {
            abi = abi,
            types = serialized,
            type = modtype,
            origin = origin,
        }
        provider.key_order[#provider.key_order + 1] = name
    end
    table.sort(provider.key_order, util.bytewise_less)
    embedded_interface_provider_snapshots[candidate] = provider
    return copy_embedded_interface_provider_snapshot(provider)
end

-- Long-lived compiler clients use one explicit C-analysis authority across
-- their short-lived resolver contexts. It owns completed header graphs plus
-- semantic baseline/probe verdicts; it remains intentionally separate from
-- the I/O provider and never admits infrastructure failures.
function driver.new_c_header_analysis()
    return cdriver.new_process_analysis()
end

function driver.new_resolver_context(options)
    options = options or {}
    if type(options) ~= "table" then
        error("resolver context options must be a table", 2)
    end
    local embedded_interface_provider, embedded_error =
        validate_embedded_interface_provider(
            options.embedded_interface_provider)
    if embedded_error then
        error("invalid embedded_interface_provider: " .. embedded_error, 2)
    end
    local io_strategy = options.io
    if io_strategy == nil then io_strategy = compiler_io.new_sync() end
    compiler_io.validate(io_strategy, 2)
    local source_process_trace = options.source_process_trace
    if source_process_trace ~= nil and
       type(source_process_trace) ~= "function" then
        error("source_process_trace must be a function", 2)
    end
    local c_probe_cache_trace = options.c_probe_cache_trace
    if c_probe_cache_trace ~= nil and
       type(c_probe_cache_trace) ~= "function" then
        error("c_probe_cache_trace must be a function", 2)
    end
    local c_probe_semantic_trace = options.c_probe_semantic_trace
    if c_probe_semantic_trace ~= nil and
       type(c_probe_semantic_trace) ~= "function" then
        error("c_probe_semantic_trace must be a function", 2)
    end
    local c_probe_execution_trace = options.c_probe_execution_trace
    if c_probe_execution_trace ~= nil and
       type(c_probe_execution_trace) ~= "function" then
        error("c_probe_execution_trace must be a function", 2)
    end
    local source_profile_stack = {}
    local client_header_trace = options.c_header_process_trace
    if client_header_trace ~= nil and
       type(client_header_trace) ~= "function" then
        error("c_header_process_trace must be a function", 2)
    end
    local c_header_process_trace = client_header_trace
    if source_process_trace ~= nil then
        -- A complete header request and its later Titan FFI conversion are
        -- child work of the source check which requested them. Preserve the
        -- existing phase stream while recording only those two non-overlapping
        -- terminal durations for exclusive source-module attribution.
        c_header_process_trace = function(
                filename, resolved, phase, outcome, cpu_ms, identity)
            local frame = source_profile_stack[#source_profile_stack]
            if frame and type(cpu_ms) == "number" and
               (phase == "process_total" or
                phase == "downstream_ffi_conversion") then
                frame.child_cpu_ms = frame.child_cpu_ms + cpu_ms
            end
            if client_header_trace ~= nil then
                return client_header_trace(
                    filename, resolved, phase, outcome, cpu_ms, identity)
            end
        end
    end
    local extra_ffi_include_dirs, include_error =
        cdriver.resolve_compiler_include_dirs(
            options.extra_ffi_include_dirs or {}, io_strategy)
    if not extra_ffi_include_dirs then
        error("invalid extra_ffi_include_dirs: " .. tostring(include_error), 2)
    end
    local context = {
        _resolver_context = true,
        io = io_strategy,
        prefer_static = options.prefer_static == true,
        source_first = options.source_first == true,
        provider_cache = {},
        contextual_types = {},
        contextual_resolutions = {},
        native_interface_types = {},
        native_constraints = {},
        source_modules = {},
        embedded_interface_provider = embedded_interface_provider,
        embedded_interface_provider_rejected = false,
        checked_source_modules = {},
        used_compiled_interfaces = {},
        probe_verbose = options.verbose == true,
        pretty_print = options.pretty_print == true,
        c_header_process_trace = c_header_process_trace,
        c_header_analysis = options.c_header_analysis,
        source_process_trace = source_process_trace,
        c_probe_cache_trace = c_probe_cache_trace,
        c_probe_semantic_trace = c_probe_semantic_trace,
        c_probe_execution_trace = c_probe_execution_trace,
        _source_profile_stack = source_profile_stack,
        extra_ffi_include_dirs = extra_ffi_include_dirs,
    }
    local initialized, layout_error = driver.initialize_layout(context)
    if not initialized then
        error("cannot initialize compiler layout: " ..
            tostring(layout_error), 2)
    end
    return context
end

local function remember_used_compiled_interface(context, modname, modtype)
    context.used_compiled_interfaces =
        context.used_compiled_interfaces or {}
    local used = context.used_compiled_interfaces[modname]
    if not used then
        used = {}
        context.used_compiled_interfaces[modname] = used
    end
    used[types.serialize(modtype)] = true
end

local function check_used_compiled_interface(
        context, modname, source_type, errors)
    if #errors ~= 0 then return end
    local used = context.used_compiled_interfaces and
        context.used_compiled_interfaces[modname]
    if not used then return end
    local source_interface = types.serialize(source_type)
    for compiled_interface in pairs(used) do
        if compiled_interface ~= source_interface then
            errors[#errors + 1] = "source module '" .. modname ..
                "' does not match a compiled interface already used in " ..
                "this compilation"
            return
        end
    end
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

-- Contextual nominal-owner recovery is intentionally not an ordinary import:
-- it must not populate driver.imported or select another archive for linking.
-- Long-lived semantic clients still need the narrow physical provenance that
-- supplied the recovered interface so they can invalidate cached consumers.
local function remember_contextual_resolution(
        context, owner, exposer, resolved, ordinary_lookup, exposer_file)
    local kind = resolved and resolved.kind
    local provider_file = resolved and
        (resolved.static_archive or resolved.filename)
    if (kind ~= "dynamic" and kind ~= "static" and kind ~= "embedded") or
       type(provider_file) ~= "string" then
        return
    end
    context.contextual_resolutions =
        context.contextual_resolutions or {}
    local key = table.concat({
        owner or "", exposer or "", kind, provider_file,
        ordinary_lookup and "ordinary" or "carried",
    }, "\0")
    context.contextual_resolutions[key] = {
        owner = owner,
        exposer = exposer,
        kind = kind,
        provider_file = provider_file,
        exposer_file = exposer_file,
        ordinary_lookup = ordinary_lookup == true,
    }
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

function driver.format_generated_file(
        filename, verbose, pretty_print, strategy)
    local label = "generated file '" .. tostring(filename) .. "'"
    if pretty_print then
        local args, err = parsed_words(driver.CLANG_FORMAT, "CLANG_FORMAT")
        if not args then
            return nil, "failed to format " .. label .. ": " .. tostring(err)
        end
        if #args == 0 then
            return nil, "failed to format " .. label ..
                ": CLANG_FORMAT command is empty"
        end
        append_argv(args, {
            "-i",
            "--style={BasedOnStyle: LLVM, IndentWidth: 4, SortIncludes: false}",
            "--",
            filename,
        })
        local ok, term, code
        if strategy then
            if verbose then print(assert(command_argv(args))) end
            local result = strategy:run(args, { stderr_to_stdout = true })
            ok = type(result) == "table" and result.started and result.ok
            term = type(result) == "table" and
                (result.why or result.diagnostic) or result
            code = type(result) == "table" and result.status or nil
        else
            ok, term, code = run_argv(args, verbose)
        end
        if not ok then
            local detail
            if code ~= nil then
                detail = " (" .. tostring(term) .. ", exit " ..
                    tostring(code) .. ")"
            else
                detail = ": " .. tostring(term)
            end
            return nil, "failed to format " .. label ..
                " with clang-format" .. detail
        end
    end

    local contents, read_err
    if strategy then
        contents, read_err = strategy:read_file(filename)
    else
        contents, read_err = util.get_file_contents(filename)
    end
    if not contents then
        return nil, "failed to normalize " .. label ..
            (pretty_print and " after clang-format" or "") ..
            ": " .. tostring(read_err)
    end
    -- Formatting is presentation-only. Always enforce the source-map
    -- invariant that a `#line` directive maps the immediately following
    -- physical statement rather than a blank line.
    local normalized = contents
    local removed
    repeat
        normalized, removed = normalized:gsub(
            "([ \t]*#line[^\n]*\n)[ \t]*\n", "%1")
    until removed == 0
    if normalized ~= contents then
        local write_ok, write_err
        if strategy then
            write_ok, write_err = strategy:write_file(filename, normalized)
        else
            write_ok, write_err = util.set_file_contents(filename, normalized)
        end
        if not write_ok then
            return nil, "failed to normalize " .. label ..
                (pretty_print and " after clang-format" or "") ..
                ": " .. tostring(write_err)
        end
    end
    return true
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

local function append_compile_includes(args)
    for _, directory in ipairs(driver.foreign_include_dirs()) do
        append_argv(args, { "-I", directory })
    end
end

-- Exact command prefix shared by every generated C object compile. The
-- descriptor below represents this as compiler argv + compile flags + ordered
-- include roots; cprobe/cdriver reconstruct the same sequence before adding
-- their private source/output arguments.
function driver.generated_compile_prefix()
    local args, err = compiler_argv(true)
    if not args then return nil, err end
    append_compile_includes(args)
    return args
end

-- One immutable description of the native compiler prefix used for generated
-- objects, predefined-macro/header discovery, and compile-only checker probes.
-- `compile_flags` deliberately includes Titan's fixed language selection, so
-- cprobe is told not to synthesize a second `-std` spelling.
function driver.toolchain_descriptor(context)
    if driver.TOOLCHAIN_ERROR then return nil, driver.TOOLCHAIN_ERROR end
    local cc, err = parsed_words(driver.CC, "CC")
    if not cc then return nil, err end
    if #cc == 0 then return nil, "CC command is empty" end

    local effective, compile_err = compiler_argv(true)
    if not effective then return nil, compile_err end
    local flags = {}
    for index = #cc + 1, #effective do
        flags[#flags + 1] = effective[index]
    end
    return {
        io = context and context.io or nil,
        compiler_argv = cc,
        compile_flags = flags,
        language_mode = "c99",
        language_flag = false,
        cppflags = {},
        cflags = {},
        include_dirs = driver.foreign_include_dirs(),
        profile = driver.TARGET_PROFILE,
        profile_identity = driver.TARGET_PROFILE
            and driver.TARGET_PROFILE.identity or "",
    }
end

local function available_embedded_interface_provider(context)
    local provider = context.embedded_interface_provider
    if not provider or context.embedded_interface_provider_rejected then
        return nil
    end
    for _, name in ipairs(provider.key_order) do
        local imported = driver.imported[name]
        local cached_source = imported and imported ~= CIRCULAR_MARK and
            (imported.ast or imported.kind == "source")
        if context.source_modules[name] or cached_source then
            -- One source identity rejects the complete physical inventory. This
            -- mirrors archive overlap rather than mixing independently selected
            -- entries from one embedded executable with project source. A
            -- process-global source cache is still selected source provenance,
            -- even when this context did not rediscover its project catalog.
            context.embedded_interface_provider_rejected = true
            context.embedded_interface_provider_overlap = name
            return nil
        end
    end
    return provider
end

function driver.get_probe_service(context)
    if context.foreign_c_configuration_id ~=
       driver.FOREIGN_C_CONFIGURATION_ID then
        local configured, configure_err = driver.configure_foreign_c(context)
        if not configured then
            context.probe_service_error = configure_err
            return nil, configure_err
        end
    end
    local configuration_id = driver.FOREIGN_C_CONFIGURATION_ID
    if context.probe_configuration_id ~= configuration_id then
        if context.probe_service then
            local closed, close_err = context.probe_service:close()
            if not closed then
                context.probe_service_error = close_err
                return nil, close_err
            end
        end
        context.probe_service = nil
        context.probe_service_error = nil
        context.probe_configuration_id = configuration_id
    end
    if context.probe_service then return context.probe_service end
    if context.probe_service_error then
        return nil, context.probe_service_error
    end
    local toolchain, err = driver.toolchain_descriptor(context)
    if not toolchain then
        context.probe_service_error = err
        return nil, err
    end
    local provider = available_embedded_interface_provider(context)
    local declared_profile = provider and provider.target_profile
    local declared_identity = declared_profile and declared_profile.identity
        or context.used_embedded_target_profile_identity
    if declared_identity then
        -- A build profile is authority for this analysis target, never a
        -- substitute for the native compiler/header environment of a probe.
        -- Do not let missing SDK inputs or a different live target borrow the
        -- embedded profile and manufacture a successful native service.
        local live_identity, profile_error =
            csemantics.profile_identity(toolchain.profile)
        if not live_identity then
            context.probe_service_error = context.foreign_c_profile_error
                or profile_error or "native target profile is unavailable"
            return nil, context.probe_service_error
        elseif live_identity ~= declared_identity then
            context.probe_service_error =
                "native C target profile disagrees with embedded target_profile"
            return nil, context.probe_service_error
        end
    end
    -- Project include roots belong to one resolver/analysis. Extend the fresh
    -- descriptor rather than reconfiguring the process-global checker and
    -- target profile shared by other compiler clients in this Lua state.
    local include_dirs = {}
    for _, directory in ipairs(toolchain.include_dirs or {}) do
        include_dirs[#include_dirs + 1] = directory
    end
    for _, directory in ipairs(context.extra_ffi_include_dirs or {}) do
        include_dirs[#include_dirs + 1] = directory
    end
    toolchain.include_dirs = include_dirs
    local service
    local persistent_cache_trace
    local semantic_trace
    local execution_trace
    if context.c_probe_cache_trace ~= nil then
        persistent_cache_trace = function(stage, hit, key, path, module_name)
            return context.c_probe_cache_trace(
                module_name or "", stage, hit, key, path)
        end
    end
    if context.c_probe_semantic_trace ~= nil then
        semantic_trace = function(event)
            return context.c_probe_semantic_trace(event)
        end
    end
    if context.c_probe_execution_trace ~= nil then
        execution_trace = function(event)
            return context.c_probe_execution_trace(event)
        end
    end
    service, err = cprobe.new_service({
        io = context.io,
        process_trace = context.c_header_process_trace,
        process_analysis = context.c_header_analysis,
        persistent_cache_trace = persistent_cache_trace,
        semantic_trace = semantic_trace,
        execution_trace = execution_trace,
        toolchain = toolchain,
        verbose = context.probe_verbose,
        cache_directory = driver.PROBE_CACHE_DIRECTORY,
        cache_identity = driver.PROBE_CACHE_IDENTITY,
    })
    if not service then
        context.probe_service_error = err
        return nil, err
    end
    context.probe_service = service
    return service
end

-- Pure numeric type decisions may use the trusted semantic host's target
-- without touching a C compiler or SDK. Each checker clones this profile;
-- every native probe still crosses get_probe_service's live-target boundary.
function driver.get_target_profile(context)
    local provider = available_embedded_interface_provider(context)
    if provider and provider.target_profile then
        context.used_embedded_target_profile_identity =
            provider.target_profile.identity
        return provider.target_profile
    end
    local service, err = driver.get_probe_service(context)
    if not service then return nil, err end
    if type(service.profile) ~= "table" then
        return nil, "the C probe service has no authoritative target profile"
    end
    local previous_identity = context.used_embedded_target_profile_identity
    if previous_identity then
        local identity, profile_error = csemantics.profile_identity(service.profile)
        if not identity then return nil, profile_error end
        if identity ~= previous_identity then
            return nil, "source overlap changed the semantic C target profile"
        end
        context.used_embedded_target_profile_identity = nil
    end
    return service.profile
end

function driver.close_resolver_context(context)
    if not context then return true end
    if type(context) ~= "table" or context.io == nil then
        error("closing a resolver requires its compiler I/O strategy", 2)
    end
    compiler_io.validate(context.io, 2)
    local first_error
    local remaining_headers = {}
    for _, filename in ipairs(
            context.source_foreign_header_temporaries or {}) do
        local attributes, attribute_err = context.io:lstat(filename)
        if attributes then
            local removed, remove_err = context.io:unlink(filename)
            if not removed and not first_error then
                first_error = remove_err or
                    ("could not remove temporary source foreign header '" ..
                        filename .. "'")
            end
            if not removed then remaining_headers[#remaining_headers + 1] = filename end
        elseif attribute_err and not first_error then
            first_error = attribute_err
            remaining_headers[#remaining_headers + 1] = filename
        end
    end
    context.source_foreign_header_temporaries =
        #remaining_headers > 0 and remaining_headers or nil
    if context.probe_service then
        local service = context.probe_service
        local ok, err = service:close()
        -- A thrown cancellation leaves this assignment unreached so an
        -- uncancelled owner can retry. Ordinary returned close failures keep
        -- their historical terminal behavior.
        context.probe_service = nil
        if ok then
            context.probe_service_error = nil
        else
            context.probe_service_error = err
            first_error = first_error or err
        end
    end
    if first_error then return nil, first_error end
    return true
end

local function resolver_context_from_options(options, level)
    level = level or 3
    if options == nil then
        return driver.new_resolver_context(), true
    elseif type(options) ~= "table" then
        error("resolver options must be a table", level)
    elseif options._resolver_context == true then
        compiler_io.validate(options.io, level)
        return options, false
    elseif options.context ~= nil then
        local context = options.context
        if type(context) ~= "table" or context.io == nil then
            error("options.context must be a resolver context", level)
        end
        compiler_io.validate(context.io, level)
        return context, false
    end
    return driver.new_resolver_context(options), true
end

local function copy_c_header_dependencies(value, label)
    label = label or "C header dependencies"
    if value == nil then return {} end
    if type(value) ~= "table" then
        return nil, label .. " must be an ordered array"
    end
    local result = {}
    local seen = {}
    for index = 1, #value do
        local input = value[index]
        if type(input) ~= "table" then
            return nil, label .. " entry " .. index .. " must be a table"
        end
        local kind = input.kind
        local path = input.path
        local identity = input.identity
        if kind ~= "file" and kind ~= "search" then
            return nil, label .. " entry " .. index ..
                " kind must be 'file' or 'search'"
        elseif type(path) ~= "string" or path:sub(1, 1) ~= "/" or
               path:find("\0", 1, true) then
            return nil, label .. " entry " .. index ..
                " path must be an absolute NUL-free pathname"
        elseif type(identity) ~= "string" or identity == "" then
            return nil, label .. " entry " .. index ..
                " must have a nonempty identity"
        end
        local key = kind .. "\0" .. path
        if seen[key] then
            return nil, label .. " repeats " .. kind .. " input '" ..
                path .. "'"
        end
        seen[key] = true
        result[index] = {
            kind = kind,
            path = path,
            identity = identity,
        }
    end
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key > #value
        or key % 1 ~= 0 then
            return nil, label .. " must be a dense ordered array"
        end
    end
    return result
end

local function valid_source_files(value, main_filename)
    if type(value) ~= "table" then return false end
    local count, maximum = 0, 0
    for key, filename in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0
           or type(filename) ~= "string" or filename == "" then
            return false
        end
        count = count + 1
        maximum = math.max(maximum, key)
    end
    return count > 0 and count == maximum and value[1] == main_filename
end

-- Produce the equality-only source interface consumed by incremental semantic
-- clients. Unlike `types.serialize`, this is not executable metadata: it also
-- covers declarations visible only through an explicit `.titan` import and
-- their exact C-header inputs.
function driver.serialize_source_interface(entry)
    if type(entry) ~= "table" or entry.kind ~= "source"
       or type(entry.ast) ~= "table"
       or type(entry.type) ~= "table"
       or entry.type._tag ~= "Type.Module"
       or entry.type._source ~= true
       or type(entry.type.name) ~= "string"
       or type(entry.filename) ~= "string" or entry.filename == ""
       or type(entry.source_files) ~= "table" then
        return nil, "source interface entry is not a complete checked source module"
    end
    if not valid_source_files(entry.source_files, entry.filename) then
        return nil, "source interface entry has invalid source_files"
    end
    if type(entry.deps) ~= "table" then
        return nil, "source interface entry has no dependency map"
    end
    for dependency, present in pairs(entry.deps) do
        if not staticmetadata.valid_module_name(dependency)
           or present ~= true then
            return nil, "source interface entry has an invalid dependency map"
        end
    end
    local headers, header_error = copy_c_header_dependencies(
        entry.c_header_dependencies,
        "source interface entry C header dependencies")
    if not headers then return nil, header_error end
    local normalized = {
        kind = "source",
        type = entry.type,
        c_header_dependencies = headers,
    }
    return sourceinterface.serialize(normalized)
end

-- Recompute the identities of an already-resolved module header closure. This
-- never searches for a different header wholesale: `search` entries are the
-- exact ordered candidates cdriver consulted, including misses, so a new
-- earlier shadow changes identity without walking an include tree.
function driver.restat_c_header_dependencies(value, options)
    local context, owns_context =
        resolver_context_from_options(options, 2)
    local dependencies, err = copy_c_header_dependencies(value)
    if not dependencies then
        if owns_context then driver.close_resolver_context(context) end
        return nil, err
    end
    local result = {}
    for index, dependency in ipairs(dependencies) do
        local identity, identity_error = cdriver.header_input_identity(
            dependency.kind, dependency.path, context.io)
        if not identity then
            if owns_context then driver.close_resolver_context(context) end
            return nil, "cannot fingerprint C header input '" ..
                dependency.path .. "': " .. tostring(identity_error)
        end
        result[index] = {
            kind = dependency.kind,
            path = dependency.path,
            identity = identity,
        }
    end
    if owns_context then
        local closed, close_error = driver.close_resolver_context(context)
        if not closed then return nil, close_error end
    end
    return result
end

function driver.close_loader(loader)
    local binding = loader_contexts[loader]
    if not binding then return true end
    if not binding.owned then
        loader_contexts[loader] = nil
        return true
    end
    local closed, close_error =
        driver.close_resolver_context(binding.context)
    -- A thrown cancellation leaves this assignment unreached so an
    -- uncancelled owner can retry. Ordinary returned success or failure keeps
    -- close_loader's historical terminal behavior.
    loader_contexts[loader] = nil
    return closed, close_error
end

-- Execute a loader-scoped operation and close an internally owned resolver on
-- both returns and exceptions. A caller which injected `options.context`
-- retains ownership of that context; close_loader is then an idempotent no-op.
function driver.with_loader(loader, body, ...)
    if type(loader) ~= "function" then
        error("loader must be a function", 2)
    elseif type(body) ~= "function" then
        error("loader body must be a function", 2)
    end
    local arguments = table.pack(...)
    local results = table.pack(xpcall(function()
        return body(loader, table.unpack(arguments, 1, arguments.n))
    end, function(err) return err end))
    local close_call = table.pack(pcall(driver.close_loader, loader))
    if not results[1] then
        error(results[2], 0)
    elseif not close_call[1] then
        error(close_call[2], 0)
    elseif not close_call[2] then
        error("failed to close loader resolver context: " ..
            tostring(close_call[3]), 0)
    end
    return table.unpack(results, 2, results.n)
end

-- On Mach-O (macOS), libbacktrace needs a companion `.dSYM` bundle to symbolize
-- PCs to #line-attributed .titan file/line — the linker does NOT produce one, so
-- without `dsymutil` the native Titan frames are unsymbolized and dropped. Run
-- `dsymutil` after every final link on Darwin only; on Linux DWARF is embedded in
-- the binary and dsymutil may be absent, so it must be a no-op there.
local function run_dsymutil(output, verbose, stable_input_basename)
    if not driver.IS_DARWIN then return true end
    if not stable_input_basename then
        return run_argv({ "dsymutil", output }, verbose)
    end

    -- A bundled dSYM records dsymutil's input spelling in
    -- Resources/Relocations/<arch>/<basename>.yml. Public providers link in a
    -- unique sibling stage, so passing the complete staged pathname would make
    -- an otherwise identical dSYM differ on every transaction. Run only these
    -- staged-provider invocations from the output directory and pass the
    -- stable leaf name. Darwin ld records absolute N_OSO object paths, so
    -- changing dsymutil's working directory does not change object discovery.
    local directory, basename = output:match("^(.*)/([^/]+)$")
    if not directory or directory == "" then
        return run_argv({ "dsymutil", output }, verbose)
    end
    local previous, current_err = lfs.currentdir()
    if not previous then return nil, current_err end
    local changed, change_err = lfs.chdir(directory)
    if not changed then return nil, change_err end
    local ok, term, code = run_argv({ "dsymutil", basename }, verbose)
    local restored, restore_err = lfs.chdir(previous)
    if not restored then
        return nil, "could not restore working directory after dsymutil: " ..
            tostring(restore_err)
    end
    return ok, term, code
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
    if not staticmetadata.valid_module_name(modname) then return {} end
    local components = {}
    for component in modname:gmatch("[^.]+") do
        table.insert(components, component)
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

local function regular_file(filename, context)
    if context and context.io then
        local attributes = context.io:stat(filename)
        return attributes and attributes.kind == "file" or false
    end
    return lfs.attributes(filename, "mode") == "file"
end

local function source_resolution_in_root(root, modname, context)
    local module_path = modname:gsub("[.]", "/")
    local basename = modname:match("([^.]+)$")
    if not basename then return nil end
    local folder = root .. "/" .. module_path
    local folder_main = folder .. "/" .. basename .. ".titan"

    if regular_file(folder_main, context) then
        local entries
        if context and context.io then
            local list_err
            entries, list_err = context.io:list(folder)
            if not entries then
                return nil, "cannot enumerate folder module '" .. modname ..
                    "' at '" .. folder_main .. "': " .. tostring(list_err)
            end
        else
            local opened, iterator, state = pcall(lfs.dir, folder)
            if not opened or type(iterator) ~= "function" then
                local detail = opened and state or iterator
                return nil, "cannot enumerate folder module '" .. modname ..
                    "' at '" .. folder_main .. "': " .. tostring(detail)
            end
            entries = {}
            local enumerated, enumeration_error = pcall(function()
                for name in iterator, state do entries[#entries + 1] = name end
            end)
            if not enumerated then
                return nil, "cannot enumerate folder module '" .. modname ..
                    "' at '" .. folder_main .. "': " ..
                    tostring(enumeration_error)
            end
        end

        if type(entries) ~= "table" then
            return nil, "cannot enumerate folder module '" .. modname ..
                "' at '" .. folder_main .. "': invalid directory entries"
        end

        local contributors = {}
        for _, name in ipairs(entries) do
            if name ~= "." and name ~= ".." and
               name ~= basename .. ".titan" and
               name:sub(-6) == ".titan" and
               regular_file(folder .. "/" .. name, context) then
                table.insert(contributors, name)
            end
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
    if not regular_file(flat, context) then return nil end

    local owner = modname:match("^(.*)[.][^.]+$")
    if owner then
        local owner_path = owner:gsub("[.]", "/")
        local owner_basename = owner:match("([^.]+)$")
        if not owner_basename then return nil end
        local owner_main = root .. "/" .. owner_path .. "/" ..
            owner_basename .. ".titan"
        if regular_file(owner_main, context) then
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

local function resolve_source(paths, modname, context)
    for root in paths:gmatch("[^;]+") do
        local source, err = source_resolution_in_root(root, modname, context)
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

local function dense_array_length(value)
    if type(value) ~= "table" then return nil end
    local count, maximum = 0, 0
    for key in pairs(value) do
        if type(key) == "number" then
            if key < 1 or key % 1 ~= 0 then return nil end
            count = count + 1
            maximum = math.max(maximum, key)
        end
    end
    if count ~= maximum then return nil end
    return maximum
end

local function dense_plain_list_length(value)
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do
        if type(key) ~= "number" then return nil end
    end
    return dense_array_length(value)
end

local portable_c_descriptor_fields = {
    ["Type.CVoid"] = {
        _tag = true,
    },
    ["Type.CInteger"] = {
        _tag = true,
        spelling = true,
        signed = true,
        rank = true,
        bits = true,
    },
    ["Type.CFloat"] = {
        _tag = true,
        spelling = true,
    },
    ["Type.CPointer"] = {
        _tag = true,
        pointee = true,
        quals = true,
    },
    ["Type.CFunction"] = {
        _tag = true,
        params = true,
        ret = true,
        vararg = true,
        abi = true,
    },
    ["Type.COwned"] = {
        _tag = true,
        pointee = true,
        count = true,
    },
    ["Type.CStruct"] = {
        _tag = true,
        cname = true,
        tagname = true,
        typedef = true,
        fields = true,
        complete = true,
        has_fam = true,
    },
}

local function validate_portable_c_descriptor_fields(typ)
    local allowed = portable_c_descriptor_fields[typ._tag]
    if not allowed then return true end
    for key in pairs(typ) do
        if not allowed[key] then
            return nil, typ._tag .. " contains unexpected field " ..
                string.format("%q", tostring(key))
        end
    end
    return true
end

local validate_interface_type

local function valid_source_identifier(name)
    return type(name) == "string"
       and name:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function valid_qualified_nominal_name(name)
    if type(name) ~= "string" then return false end
    local modname, nominal = name:match("^(.*)%.([A-Za-z_][A-Za-z0-9_]*)$")
    return modname ~= nil and valid_source_identifier(nominal)
       and staticmetadata.valid_module_name(modname)
end

local function validate_name_list(names, expected_length)
    if names == false then return true end
    local length = dense_plain_list_length(names)
    if not length or length ~= expected_length then return nil end
    local seen = {}
    for index = 1, length do
        local name = names[index]
        if not valid_source_identifier(name) or seen[name] then
            return nil
        end
        seen[name] = true
    end
    return true
end

local function generic_scope_component(value)
    if value == false then return "-" end
    if type(value) ~= "string" then return nil end
    return #value .. ":" .. value
end

local function generic_scope_key(scope)
    if type(scope) ~= "table" or scope._tag ~= "Type.GenericScope" then
        return nil
    end
    local components = {
        generic_scope_component(scope.modname),
        generic_scope_component(scope.owner_fqtn),
        generic_scope_component(scope.callable_name),
        generic_scope_component(scope.role),
        generic_scope_component(scope.declaration_kind),
    }
    for _, component in ipairs(components) do
        if component == nil then return nil end
    end
    return table.concat(components, "|")
end

local function copy_scope_bindings(bindings)
    local copy = {}
    for key, binding in pairs(bindings or {}) do copy[key] = binding end
    return copy
end

local function validate_generic_scope(scope, expected)
    local key = generic_scope_key(scope)
    if not key
       or not staticmetadata.valid_module_name(scope.modname)
       or (scope.owner_fqtn ~= false
           and not valid_qualified_nominal_name(scope.owner_fqtn))
       or (scope.callable_name ~= false
           and not valid_source_identifier(scope.callable_name))
       or not valid_source_identifier(scope.role)
       or not valid_source_identifier(scope.declaration_kind) then
        return nil, "generic scope has an invalid schema"
    end
    if expected and
       (scope.modname ~= expected.modname
        or scope.owner_fqtn ~= expected.owner_fqtn
        or scope.callable_name ~= expected.callable_name
        or scope.role ~= expected.role
        or scope.declaration_kind ~= expected.declaration_kind) then
        return nil, "generic scope does not match its declaration"
    end
    return key
end

local function typeparameter_lists_alpha_equal(left, right)
    local left_length = dense_plain_list_length(left)
    local right_length = dense_plain_list_length(right)
    if not left_length or left_length ~= right_length then return false end
    for index = 1, left_length do
        if not types.alpha_equals(left[index], right[index]) then
            return false
        end
    end
    return true
end

local function value_context(context, scopes)
    return {
        kind = "value",
        scopes = scopes or (context and context.scopes) or {},
        validation = context and context.validation,
    }
end

local function validation_context_key(context)
    local scope_keys = {}
    for key, binding in pairs(context and context.scopes or {}) do
        scope_keys[#scope_keys + 1] = key .. "@" ..
            tostring(binding.typeparams)
    end
    table.sort(scope_keys, util.bytewise_less)
    return tostring(context and context.kind or "value") .. "\0" ..
        table.concat(scope_keys, "\0")
end

local function mark_validation_seen(seen, typ, context)
    local contexts = seen[typ]
    local key = validation_context_key(context)
    if contexts and contexts[key] then return true end
    if not contexts then
        contexts = {}
        seen[typ] = contexts
    end
    contexts[key] = true
    return false
end

local function validate_generic_binders(
        scope, typeparams, expected, context, seen)
    local count = dense_plain_list_length(typeparams)
    if not count then
        return nil, "generic binder list is not dense"
    elseif scope == false then
        if count ~= 0 then
            return nil, "generic binder list has no scope"
        end
        return (context and context.scopes) or {}
    elseif count == 0 then
        return nil, "generic scope has an empty binder list"
    end

    local key, scope_error = validate_generic_scope(scope, expected)
    if not key then return nil, scope_error end
    local scopes = copy_scope_bindings(context and context.scopes)
    if scopes[key] then
        return nil, "generic scope is bound more than once"
    end

    local names = {}
    for _, binding in pairs(context and context.scopes or {}) do
        for _, typeparam in ipairs(binding.typeparams) do
            names[typeparam.name] = true
        end
    end
    for index = 1, count do
        local typeparam = typeparams[index]
        if type(typeparam) ~= "table"
           or typeparam._tag ~= "Type.TypeParameter"
           or not valid_source_identifier(typeparam.name)
           or names[typeparam.name]
           or (typeparam.constraint ~= false
               and type(typeparam.constraint) ~= "table") then
            return nil, "generic binder " .. index .. " has an invalid schema"
        end
        names[typeparam.name] = true
    end
    scopes[key] = { scope = scope, typeparams = typeparams }
    local validation = context and context.validation
    if validation then
        local previous = validation.scope_bindings[key]
        local same_ok, same = true, true
        if previous then
            same_ok, same = pcall(
                typeparameter_lists_alpha_equal, previous, typeparams)
        end
        if not same_ok or not same then
            return nil, "generic scope has conflicting binder declarations"
        end
        validation.scope_bindings[key] = previous or typeparams
    end

    for index = 1, count do
        local constraint = typeparams[index].constraint
        if constraint ~= false then
            if constraint._tag ~= "Type.Nominal" then
                return nil, "generic binder constraint is not an Interface application"
            end
            local valid, constraint_error = validate_interface_type(
                constraint, value_context(context, scopes), seen)
            if not valid then return nil, constraint_error end
            local validation = context and context.validation
            local owner = validation and validation.owners[constraint.fqtn]
            if owner and owner._tag ~= "Type.Interface" then
                return nil, "generic binder constraint does not name an Interface"
            end
        end
    end
    return scopes
end

local function validate_parameter_descriptor(parameter, context, seen)
    local key, scope_error = validate_generic_scope(parameter.scope)
    if not key then return nil, scope_error end
    local binding = context and context.scopes and context.scopes[key]
    if not binding
       or not types.same_generic_scope(parameter.scope, binding.scope) then
        return nil, "generic Parameter has a free scope reference"
    end
    if type(parameter.index) ~= "number"
       or math.type(parameter.index) ~= "integer"
       or parameter.index < 1
       or parameter.index > #binding.typeparams then
        return nil, "generic Parameter has an invalid binder index"
    end
    local typeparam = binding.typeparams[parameter.index]
    if not valid_source_identifier(parameter.diagnostic_name)
       or parameter.diagnostic_name ~= typeparam.name then
        return nil, "generic Parameter has a noncanonical diagnostic name"
    end

    if typeparam.constraint == false then
        if parameter.erased_constraint ~= false then
            return nil, "generic Parameter has a noncanonical erased constraint"
        end
        return true
    elseif type(parameter.erased_constraint) ~= "table"
       or parameter.erased_constraint._tag ~= "Type.Nominal"
       or dense_plain_list_length(parameter.erased_constraint.args) == nil then
        return nil, "generic Parameter has a noncanonical erased constraint"
    end

    local erased_ok, expected = pcall(
        types.erase_constraint, typeparam.constraint)
    if not erased_ok or not types.alpha_equals(parameter.erased_constraint, expected) then
        return nil, "generic Parameter has a noncanonical erased constraint"
    end
    local erased_context = value_context(context, {})
    erased_context.kind = "erased-constraint"
    return validate_interface_type(
        parameter.erased_constraint, erased_context, seen)
end

local function validate_callable_descriptor(callable, owner, kind, seen, context)
    if type(callable) ~= "table"
       or callable._tag ~= kind
       or callable.fqtn ~= owner.name
       or not valid_source_identifier(callable.name)
       or callable.islocal
       or not dense_plain_list_length(callable.params)
       or not dense_plain_list_length(callable.rettypes)
       or not validate_name_list(
           callable.paramnames, #callable.params) then
        return nil, "callable member has an invalid schema"
    end

    local role = kind == "Type.Method" and "method" or "static"
    local scopes, generic_error = validate_generic_binders(
        callable.scope, callable.typeparams, {
            modname = context.validation.modname,
            owner_fqtn = owner.name,
            callable_name = callable.name,
            role = role,
            declaration_kind = role,
        }, context, seen)
    if not scopes then return nil, generic_error end
    local nested = value_context(context, scopes)

    if callable.varargtype ~= false then
        local ok, err = validate_interface_type(
            callable.varargtype, nested, seen)
        if not ok then return nil, err end
        if not types.valid_varg_element(callable.varargtype) then
            return nil, "variadic parameter has a noncanonical element type"
        end
    end
    if callable.flexrettype ~= false then
        local ok, err = validate_interface_type(
            callable.flexrettype, nested, seen)
        if not ok then return nil, err end
        if not types.valid_varg_element(callable.flexrettype) then
            return nil, "flexible return has a noncanonical element type"
        end
    end
    for _, param in ipairs(callable.params) do
        local ok, err = validate_interface_type(param, nested, seen)
        if not ok then return nil, err end
    end
    for _, rettype in ipairs(callable.rettypes) do
        local ok, err = validate_interface_type(rettype, nested, seen)
        if not ok then return nil, err end
    end
    return true
end

local function validate_nominal_member_maps(owner, seen, context)
    if type(owner.functions) ~= "table"
       or type(owner.methods) ~= "table" then
        return nil, "nominal member maps have an invalid schema"
    end
    for name, fn in pairs(owner.functions) do
        if not valid_source_identifier(name)
           or type(fn) ~= "table" or fn.name ~= name then
            return nil, "nominal function map has an invalid entry"
        end
        local ok, err = validate_callable_descriptor(
            fn, owner, "Type.StaticMethod", seen, context)
        if not ok then return nil, err end
    end
    for name, method in pairs(owner.methods) do
        if not valid_source_identifier(name)
           or type(method) ~= "table" or method.name ~= name then
            return nil, "nominal method map has an invalid entry"
        elseif owner.functions[name] then
            return nil, "nominal function and method maps collide at '" ..
                name .. "'"
        end
        local ok, err = validate_callable_descriptor(
            method, owner, "Type.Method", seen, context)
        if not ok then return nil, err end
    end
    return true
end

local function canonical_owner_application(nominal, owner)
    if type(nominal) ~= "table" or nominal._tag ~= "Type.Nominal"
       or nominal.fqtn ~= owner.name then
        return false
    end
    local argument_count = dense_plain_list_length(nominal.args)
    local parameter_count = dense_plain_list_length(owner.typeparams)
    if not argument_count or not parameter_count
       or argument_count ~= parameter_count then
        return false
    end
    if parameter_count == 0 then return true end
    for index = 1, parameter_count do
        local argument = nominal.args[index]
        if type(argument) ~= "table"
           or argument._tag ~= "Type.Parameter"
           or argument.index ~= index
           or not types.same_generic_scope(argument.scope, owner.scope) then
            return false
        end
    end
    return true
end

local function validate_record_interface(record, context, seen)
    if not context or context.kind ~= "module-member"
       or record.name ~= context.modname .. "." .. context.name
       or record.islocal
       or type(record.nfields) ~= "number"
       or math.type(record.nfields) ~= "integer"
       or record.nfields < 0 then
        return nil, "record has a noncanonical owner or field count"
    end
    local scopes, generic_error = validate_generic_binders(
        record.scope, record.typeparams, {
            modname = context.modname,
            owner_fqtn = record.name,
            callable_name = false,
            role = "owner",
            declaration_kind = "record",
        }, context, seen)
    if not scopes then return nil, generic_error end
    local owner_context = {
        kind = context.kind,
        modname = context.modname,
        name = context.name,
        scopes = scopes,
        validation = context.validation,
    }

    local nfields = dense_plain_list_length(record.fields)
    if not nfields then return nil, "record field list is not dense" end
    local names, indexes = {}, {}
    local previous_index = -1
    for _, field in ipairs(record.fields) do
        if type(field) ~= "table" or field._tag ~= "Type.Field"
           or field.fqtn ~= record.name
           or not valid_source_identifier(field.name)
           or field.islocal
           or type(field.isconst) ~= "boolean"
           or type(field.index) ~= "number"
           or math.type(field.index) ~= "integer"
           or field.index < 0 or field.index >= record.nfields
           or field.index <= previous_index
           or names[field.name] or indexes[field.index] then
            return nil, "record field has an invalid schema"
        end
        names[field.name], indexes[field.index] = true, true
        previous_index = field.index
        local ok, err = validate_interface_type(
            field.type, value_context(owner_context), seen)
        if not ok then return nil, err end
        if not types.has_tvalue_representation(field.type) then
            return nil, "record field '" .. field.name ..
                "' has no TValue representation"
        end
    end
    local ok, err = validate_nominal_member_maps(
        record, seen, owner_context)
    if not ok then return nil, err end
    for name in pairs(record.functions) do
        if names[name] then
            return nil, "record field and function maps collide at '" ..
                name .. "'"
        end
    end
    for name in pairs(record.methods) do
        if names[name] then
            return nil, "record field and method maps collide at '" ..
                name .. "'"
        end
    end

    local constructor = record.functions.new
    if not constructor and record.nfields == nfields then
        return nil, "all-public record is missing its constructor"
    end
    if constructor then
        if record.nfields ~= nfields
           or constructor.scope ~= false
           or #constructor.typeparams ~= 0
           or constructor.varargtype ~= false
           or constructor.flexrettype ~= false
           or type(constructor.paramnames) ~= "table"
           or #constructor.paramnames ~= nfields
           or #constructor.params ~= nfields
           or #constructor.rettypes ~= 1
           or not canonical_owner_application(
               constructor.rettypes[1], record) then
            return nil, "record constructor does not match its owner"
        end
        for index, field in ipairs(record.fields) do
            if constructor.paramnames[index] ~= field.name
               or not types.equals(
                   constructor.params[index], field.type) then
                return nil, "record constructor does not match its fields"
            end
        end
    end
    return true
end

local function validate_union_interface(union, context, seen)
    if not context or context.kind ~= "module-member"
       or union.name ~= context.modname .. "." .. context.name
       or union.islocal
       or type(union.nvariants) ~= "number"
       or math.type(union.nvariants) ~= "integer"
       or union.nvariants <= 0 then
        return nil, "union has a noncanonical owner or variant count"
    end
    local scopes, generic_error = validate_generic_binders(
        union.scope, union.typeparams, {
            modname = context.modname,
            owner_fqtn = union.name,
            callable_name = false,
            role = "owner",
            declaration_kind = "union",
        }, context, seen)
    if not scopes then return nil, generic_error end
    local owner_context = {
        kind = context.kind,
        modname = context.modname,
        name = context.name,
        scopes = scopes,
        validation = context.validation,
    }

    local npublic = dense_array_length(union.variants)
    if not npublic then return nil, "union variant list is not dense" end

    local names, indexes = {}, {}
    local previous_index = -1
    for index = 1, npublic do
        local variant = union.variants[index]
        if type(variant) ~= "table"
           or variant._tag ~= "Type.Variant"
           or variant.fqtn ~= union.name
           or not valid_source_identifier(variant.name)
           or variant.islocal
           or type(variant.index) ~= "number"
           or math.type(variant.index) ~= "integer"
           or variant.index < 0 or variant.index >= union.nvariants
           or variant.index <= previous_index
           or names[variant.name] or indexes[variant.index]
           or union.variants[variant.name] ~= variant then
            return nil, "union variant has an invalid schema"
        end
        names[variant.name], indexes[variant.index] = variant, true
        previous_index = variant.index
        local ok, err = validate_interface_type(variant, {
            kind = "union-variant",
            owner = union,
            scopes = owner_context.scopes,
            validation = context.validation,
        }, seen)
        if not ok then return nil, err end
        if variant.payload ~= false
           and not types.has_tvalue_representation(variant.payload) then
            return nil, "union variant '" .. variant.name ..
                "' payload has no TValue representation"
        end
    end
    for key, variant in pairs(union.variants) do
        if type(key) == "string" and names[key] ~= variant then
            return nil, "union variant map has an invalid entry"
        elseif type(key) ~= "string" and type(key) ~= "number" then
            return nil, "union variant table has an invalid key"
        end
    end

    local ok, err = validate_nominal_member_maps(
        union, seen, owner_context)
    if not ok then return nil, err end
    for _, variant in ipairs(union.variants) do
        if union.methods[variant.name] then
            return nil, "union variant and method maps collide at '" ..
                variant.name .. "'"
        end
        local constructor = union.functions[variant.name]
        local payload_params = variant.payload == false and 0 or 1
        if not constructor
           or constructor.scope ~= false
           or #constructor.typeparams ~= 0
           or constructor.varargtype ~= false
           or constructor.flexrettype ~= false
           or constructor.paramnames ~= false
           or #constructor.params ~= payload_params
           or #constructor.rettypes ~= 1
           or not canonical_owner_application(
               constructor.rettypes[1], union)
           or (variant.payload ~= false
               and not types.equals(
                   constructor.params[1], variant.payload)) then
            return nil, "union constructor '" .. variant.name ..
                "' does not match its variant"
        end
    end
    return true
end

local function validate_declared_interface(interface, context, seen)
    if not context or context.kind ~= "interface-type-member"
       or interface.name ~= context.modname .. "." .. context.name
       or interface.islocal then
        return nil, "interface has a noncanonical owner or locality"
    end

    local canonical, canonical_err =
        types.validate_interface_descriptor(interface)
    if not canonical then
        return nil, "interface member projection is invalid: " ..
            tostring(canonical_err)
    end

    local scopes, generic_error = validate_generic_binders(
        interface.scope, interface.typeparams, {
            modname = context.modname,
            owner_fqtn = interface.name,
            callable_name = false,
            role = "owner",
            declaration_kind = "interface",
        }, context, seen)
    if not scopes then return nil, generic_error end
    local owner_context = {
        kind = context.kind,
        modname = context.modname,
        name = context.name,
        scopes = scopes,
        validation = context.validation,
    }

    for _, field in ipairs(interface.fields) do
        local ok, err = validate_interface_type(
            field.type, value_context(owner_context), seen)
        if not ok then return nil, err end
        if not types.has_tvalue_representation(field.type) then
            return nil, "interface field '" .. field.name ..
                "' has no TValue representation"
        end
    end
    for _, method in ipairs(interface.methods) do
        if type(method.paramnames) ~= "table" then
            return nil,
                "interface method parameter names have an invalid schema"
        end
        local ok, err = validate_callable_descriptor(
            method, interface, "Type.Method", seen, owner_context)
        if not ok then return nil, err end
    end
    return true
end

local function validate_function_scheme(scheme, context, seen)
    if not context or context.kind ~= "module-member"
       or type(scheme.signature) ~= "table"
       or scheme.signature._tag ~= "Type.Function" then
        return nil, "FunctionScheme is not a module function declaration"
    end
    local scopes, generic_error = validate_generic_binders(
        scheme.scope, scheme.typeparams, {
            modname = context.modname,
            owner_fqtn = false,
            callable_name = context.name,
            role = "function",
            declaration_kind = "function",
        }, context, seen)
    if not scopes then return nil, generic_error end
    return validate_interface_type(
        scheme.signature, value_context(context, scopes), seen)
end

local function validate_generic_alias(alias, context, seen)
    if not context or context.kind ~= "generic-alias-type-member"
       or alias.module ~= context.modname
       or alias.name ~= context.name
       or alias.locality ~= false
       or not valid_qualified_nominal_name(alias.target_owner_fqtn)
       or (alias.target_alias_fqtn ~= false
           and not valid_qualified_nominal_name(alias.target_alias_fqtn))
       or type(alias.target_scope) ~= "table"
       or alias.target_scope._tag ~= "Type.GenericScope"
       or (alias.target_scope.declaration_kind ~= "record"
           and alias.target_scope.declaration_kind ~= "union"
           and alias.target_scope.declaration_kind ~= "interface") then
        return nil, "GenericAlias has an invalid schema"
    end
    local target_module = alias.target_owner_fqtn:match("^(.*)%.[^.]+$")
    local scopes, generic_error = validate_generic_binders(
        alias.target_scope, alias.typeparams, {
            modname = target_module,
            owner_fqtn = alias.target_owner_fqtn,
            callable_name = false,
            role = "owner",
            declaration_kind = alias.target_scope.declaration_kind,
        }, context, seen)
    if not scopes then return nil, generic_error end

    local owner = context.validation.owners[alias.target_owner_fqtn]
    if owner then
        if owner._tag ~= "Type.Record" and owner._tag ~= "Type.Union"
           and owner._tag ~= "Type.Interface" then
            return nil, "GenericAlias target is not a nominal owner"
        elseif not types.same_generic_scope(
                alias.target_scope, owner.scope)
           or not typeparameter_lists_alpha_equal(
                alias.typeparams, owner.typeparams) then
            return nil, "GenericAlias projection does not match its target owner"
        end
    elseif target_module == context.modname then
        return nil, "GenericAlias target owner is missing from its module"
    end
    return true
end

local function validate_local_alias_projection(
        alias, validation, resolving, validated)
    local fqtn = alias.module .. "." .. alias.name
    if validated[fqtn] then return true end
    if resolving[fqtn] then
        return nil, "GenericAlias chain is cyclic at '" .. fqtn .. "'"
    end
    resolving[fqtn] = true

    if alias.target_alias_fqtn ~= false then
        local target_module =
            alias.target_alias_fqtn:match("^(.*)%.[^.]+$")
        if target_module == validation.modname then
            local target = validation.aliases[alias.target_alias_fqtn]
            if not target then
                return nil, "GenericAlias target alias is missing from its module"
            end
            local ok, err = validate_local_alias_projection(
                target, validation, resolving, validated)
            if not ok then return nil, err end
            if target.target_owner_fqtn ~= alias.target_owner_fqtn
               or not types.same_generic_scope(
                    target.target_scope, alias.target_scope)
               or not typeparameter_lists_alpha_equal(
                    target.typeparams, alias.typeparams) then
                return nil,
                    "GenericAlias projection does not match its target alias"
            end
        end
    end

    resolving[fqtn] = nil
    validated[fqtn] = true
    return true
end

function driver._metadata_generic_constraint_satisfied(
        argument, constraint, validation)
    if argument._tag == "Type.Parameter" then
        local surface = types.parameter_surface_constraint(
            argument, validation.scope_bindings)
        return surface ~= nil and surface ~= false
            and types.equals(surface, constraint)
    elseif argument._tag ~= "Type.Nominal" then
        return false
    elseif types.equals(argument, constraint) then
        return true
    end

    local concrete = validation.owners[argument.fqtn]
    local interface = validation.owners[constraint.fqtn]
    if not concrete or not interface then
        return nil -- an external canonical owner is recovered by the checker
    elseif (concrete._tag ~= "Type.Record"
            and concrete._tag ~= "Type.Union")
       or interface._tag ~= "Type.Interface" then
        return false
    end

    local concrete_ok, concrete_view = true, concrete
    if concrete.scope ~= false then
        concrete_ok, concrete_view = pcall(
            types.substitute, concrete, concrete.scope, argument.args or {})
    end
    local interface_ok, interface_view = true, interface
    if interface.scope ~= false then
        interface_ok, interface_view = pcall(
            types.substitute, interface, interface.scope,
            constraint.args or {})
    end
    if not concrete_ok or not interface_ok then return false end
    local implementation = types.generic_interface_implementation(
        concrete_view, interface_view, {
            visibility = validation.modname,
        })
    return implementation ~= false
end

function driver._validate_metadata_generic_application(
        application, validation)
    local nominal, owner = application.nominal, application.owner
    local reconstructed, reconstruction_error = pcall(
        types.substitute, owner, owner.scope, nominal.args or {})
    if not reconstructed then
        return nil, "generic application '" .. types.tostring(nominal) ..
            "' is not canonical: " .. tostring(reconstruction_error)
    end

    for index, typeparam in ipairs(owner.typeparams or {}) do
        if typeparam.constraint ~= false then
            local closed, constraint = pcall(
                types.substitute, typeparam.constraint,
                owner.scope, nominal.args or {})
            if not closed then
                return nil, "generic constraint " .. index ..
                    " could not be reconstructed: " .. tostring(constraint)
            end
            local satisfied =
                driver._metadata_generic_constraint_satisfied(
                    nominal.args[index], constraint, validation)
            if satisfied == false then
                return nil, "type argument " .. index .. " ('" ..
                    types.tostring(nominal.args[index]) ..
                    "') does not satisfy constraint '" ..
                    types.tostring(constraint) .. "'"
            end
        end
    end
    return true
end

validate_interface_type = function(typ, context, seen)
    if type(typ) ~= "table" or type(typ._tag) ~= "string" then
        return nil, "type graph contains an invalid descriptor"
    end
    if typ._source_complete ~= nil or typ._ffi_scope ~= nil
       or typ._c_numeric ~= nil or typ._c_numeric_carriers ~= nil
       or typ._c_enum_identity ~= nil or typ._c_origin_header ~= nil
       or typ._return_declaration_qualifiers ~= nil then
        return nil, "type graph contains compiler-only source state"
    end
    local tag = typ._tag
    if tag == "Type.Variant"
       and (not context or context.kind ~= "union-variant"
            or context.owner.name ~= typ.fqtn) then
        return nil, "Type.Variant is only valid inside its owning union"
    elseif tag == "Type.Record"
       and (not context or context.kind ~= "module-member") then
        return nil, "Type.Record is only valid as its owning module member"
    elseif tag == "Type.Union"
       and (not context or context.kind ~= "module-member") then
        return nil, "Type.Union is only valid as its owning module member"
    elseif tag == "Type.Interface"
       and (not context
            or context.kind ~= "interface-type-member") then
        return nil,
            "Type.Interface is only valid as its owning module type member"
    elseif tag == "Type.FunctionScheme"
       and (not context or context.kind ~= "module-member") then
        return nil,
            "Type.FunctionScheme is only valid as a module function declaration"
    elseif tag == "Type.GenericAlias"
       and (not context
            or context.kind ~= "generic-alias-type-member") then
        return nil,
            "Type.GenericAlias is only valid as a module type member"
    elseif tag == "Type.Parameter" then
        -- Parameter legality depends on the enclosing binder environment, so
        -- check it before the shared-graph memo just like declaration wrappers.
        return validate_parameter_descriptor(typ, context, seen)
    elseif tag == "Type.GenericScope" or tag == "Type.TypeParameter"
           or tag == "Type.Field" or tag == "Type.Method"
           or tag == "Type.StaticMethod"
           or tag == "Type.ModuleMember"
           or tag == "Type.ModuleVariable" then
        -- Test context-sensitive wrappers before the shared-graph memo. A
        -- hostile cyclic graph must not make an already visited declaration
        -- descriptor legal in a value-facing position.
        return nil, tag .. " is not valid in a value-facing type graph"
    end
    local exact_fields, fields_error =
        validate_portable_c_descriptor_fields(typ)
    if not exact_fields then return nil, fields_error end
    if mark_validation_seen(seen, typ, context) then return true end
    if tag == "Type.Nil" or tag == "Type.Boolean"
       or tag == "Type.Integer" or tag == "Type.Float"
       or tag == "Type.String" or tag == "Type.Value" then
        return true
    elseif tag == "Type.CVoid" then
        if not context or (context.kind ~= "c-pointee"
                           and context.kind ~= "c-return"
                           and context.kind ~= "type-member") then
            return nil, "C void is not valid as a value-facing type"
        end
        return true
    elseif tag == "Type.CInteger" or tag == "Type.CFloat" then
        if not types.is_portable_c_primitive(typ) then
            return nil, "C primitive type is outside the portable surface set"
        end
        return true
    elseif tag == "Type.CPointer" then
        local qualifier_count = dense_plain_list_length(typ.quals)
        local pointee_tag = type(typ.pointee) == "table"
            and typ.pointee._tag
        if not qualifier_count or qualifier_count > 1
           or (qualifier_count == 1 and typ.quals[1] ~= "const")
           or (pointee_tag ~= "Type.CVoid"
               and pointee_tag ~= "Type.CInteger"
               and pointee_tag ~= "Type.CFloat"
               and pointee_tag ~= "Type.CPointer"
               and pointee_tag ~= "Type.CFunction"
               and not types.is_c_lua_state(typ.pointee)) then
            return nil, "portable C pointer has a noncanonical shape"
        end
        local nested = value_context(context)
        nested.kind = "c-pointee"
        local valid, validation_error =
            validate_interface_type(typ.pointee, nested, seen)
        if not valid then return nil, validation_error end
        if not types.is_portable_c_type_graph(typ) then
            return nil,
                "portable C pointer graph is cyclic or noncanonical"
        end
        return true
    elseif tag == "Type.CFunction" then
        if not context or context.kind ~= "c-pointee"
           or dense_plain_list_length(typ.params) == nil
           or type(typ.ret) ~= "table"
           or typ.vararg ~= false or typ.abi ~= false then
            return nil, "portable C function has a noncanonical shape"
        end
        local nested = value_context(context)
        nested.kind = "c-parameter"
        for _, param in ipairs(typ.params) do
            if type(param) ~= "table"
               or (param._tag ~= "Type.CInteger"
                   and param._tag ~= "Type.CFloat"
                   and param._tag ~= "Type.CPointer") then
                return nil, "portable C function parameter has an invalid shape"
            end
            local ok, err = validate_interface_type(param, nested, seen)
            if not ok then return nil, err end
        end
        nested.kind = "c-return"
        if typ.ret._tag ~= "Type.CVoid"
           and typ.ret._tag ~= "Type.CInteger"
           and typ.ret._tag ~= "Type.CFloat"
           and typ.ret._tag ~= "Type.CPointer" then
            return nil, "portable C function return has an invalid shape"
        end
        return validate_interface_type(typ.ret, nested, seen)
    elseif tag == "Type.COwned" then
        local pointee_tag = type(typ.pointee) == "table"
            and typ.pointee._tag
        if type(typ.count) ~= "boolean"
           or (pointee_tag ~= "Type.CInteger"
               and pointee_tag ~= "Type.CFloat"
               and pointee_tag ~= "Type.CPointer") then
            return nil, "portable owned C type has a noncanonical shape"
        end
        local nested = value_context(context)
        nested.kind = "c-owned-payload"
        return validate_interface_type(typ.pointee, nested, seen)
    elseif tag == "Type.CStruct" then
        if not types.is_c_lua_state(typ) or not context
           or context.kind ~= "c-pointee" then
            return nil, "C struct is not valid as a value-facing type"
        end
        return true
    elseif tag == "Type.Nominal" then
        local argument_count = dense_plain_list_length(typ.args)
        if not valid_qualified_nominal_name(typ.fqtn) then
            return nil, "nominal type has an invalid qualified name"
        elseif not argument_count then
            return nil, "nominal type argument list is not dense"
        end
        local validation = context and context.validation
        local owner = validation and validation.owners[typ.fqtn]
        if owner then
            local parameter_count = dense_plain_list_length(owner.typeparams)
            local expected_arguments = parameter_count
            if not parameter_count or argument_count ~= expected_arguments then
                return nil, "nominal type has the wrong generic arity"
            end
        end
        for index, argument in ipairs(typ.args) do
            local ok, err = validate_interface_type(
                argument, value_context(context), seen)
            if not ok then return nil, err end
            if not types.transient_roundtrip(argument) then
                return nil, "nominal type argument " .. index ..
                    " has no sound transient round trip"
            end
        end
        if owner and argument_count > 0 then
            validation.applications[#validation.applications + 1] = {
                nominal = typ,
                owner = owner,
            }
        end
        return true
    elseif tag == "Type.Array" then
        if type(typ.isconst) ~= "boolean" and typ.isconst ~= "maybe" then
            return nil, "array type has a noncanonical const qualifier"
        end
        return validate_interface_type(
            typ.elem, value_context(context), seen)
    elseif tag == "Type.Map" then
        if type(typ.keys) ~= "table" or type(typ.values) ~= "table"
           or typ.keys._tag == "Type.Nil"
           or typ.keys._tag == "Type.Option" then
            return nil, "map type has a noncanonical key shape"
        end
        local ok, err = validate_interface_type(
            typ.keys, value_context(context), seen)
        if not ok then return nil, err end
        return validate_interface_type(
            typ.values, value_context(context), seen)
    elseif tag == "Type.Option" then
        if type(typ.base) ~= "table"
           or typ.base._tag == "Type.Option"
           or typ.base._tag == "Type.Value" then
            return nil, "option type has an invalid schema"
        end
        return validate_interface_type(
            typ.base, value_context(context), seen)
    elseif tag == "Type.Function" then
        local nparams = dense_plain_list_length(typ.params)
        local nreturns = dense_plain_list_length(typ.rettypes)
        if not nparams or not nreturns
           or typ.vararg ~= false then
            return nil, "function type has an invalid schema"
        end
        local nested = value_context(context)
        for _, param in ipairs(typ.params) do
            local ok, err = validate_interface_type(param, nested, seen)
            if not ok then return nil, err end
        end
        for _, rettype in ipairs(typ.rettypes) do
            local ok, err = validate_interface_type(rettype, nested, seen)
            if not ok then return nil, err end
        end
        if typ.varargtype ~= false then
            local ok, err = validate_interface_type(
                typ.varargtype, nested, seen)
            if not ok then return nil, err end
            if not types.valid_varg_element(typ.varargtype) then
                return nil, "function variadic parameter has a noncanonical element type"
            end
        end
        if typ.flexrettype ~= false then
            local ok, err = validate_interface_type(
                typ.flexrettype, nested, seen)
            if not ok then return nil, err end
            if not types.valid_varg_element(typ.flexrettype) then
                return nil, "function flexible return has a noncanonical element type"
            end
        end
        return true
    elseif tag == "Type.FunctionScheme" then
        return validate_function_scheme(typ, context, seen)
    elseif tag == "Type.GenericAlias" then
        return validate_generic_alias(typ, context, seen)
    elseif tag == "Type.Record" then
        return validate_record_interface(typ, context, seen)
    elseif tag == "Type.Union" then
        return validate_union_interface(typ, context, seen)
    elseif tag == "Type.Interface" then
        return validate_declared_interface(typ, context, seen)
    elseif tag == "Type.Variant" then
        if typ.payload ~= false then
            return validate_interface_type(
                typ.payload, value_context(context), seen)
        end
        return true
    end
    -- This walk is the closed value-facing descriptor language. Error-recovery
    -- and no-value markers, modules, C FFI descriptors, legacy wrappers, and
    -- unknown tags must not survive into code generation merely because
    -- `types.serialize` happens to have a spelling for some of them.
    return nil, tag .. " is not valid in a value-facing type graph"
end

function driver.validate_module_interface(modtype, modname)
    if not staticmetadata.valid_module_name(modname) then
        return nil, "invalid logical Titan module name " ..
            string.format("%q", modname)
    end
    if type(modtype) ~= "table" or modtype._tag ~= "Type.Module"
       or modtype.islocal then
        return nil, "metadata did not deserialize to a Type.Module"
    end
    if modtype._source ~= nil or modtype.source_members ~= nil
       or modtype.source_type_members ~= nil
       or modtype._source_foreign_includes ~= nil
       or modtype._source_c_context ~= nil then
        return nil, "metadata contains compiler-only source interface state"
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

    -- Index this module's public nominal and alias declarations before walking
    -- signatures. Generic constraints and applications may reference later
    -- declarations, just as the source checker reserves every owner first.
    local validation = {
        modname = modname,
        owners = {},
        aliases = {},
        applications = {},
        scope_bindings = {},
    }
    for index = 1, maximum_index do
        local member = modtype.members[index]
        local typ = type(member) == "table" and member.type or nil
        if type(typ) == "table"
           and (typ._tag == "Type.Record" or typ._tag == "Type.Union")
           and type(member.name) == "string"
           and typ.name == modname .. "." .. member.name then
            validation.owners[typ.name] = typ
        end
    end
    for name, typ in pairs(modtype.type_members) do
        if type(name) == "string" and type(typ) == "table" then
            local fqtn = modname .. "." .. name
            if typ._tag == "Type.Interface" and typ.name == fqtn then
                validation.owners[fqtn] = typ
            elseif typ._tag == "Type.GenericAlias"
               and typ.module == modname and typ.name == name then
                validation.aliases[fqtn] = typ
            end
        end
    end

    local names = {}
    for index = 1, maximum_index do
        local member = modtype.members[index]
        if type(member) ~= "table" or
           (member._tag ~= "Type.ModuleMember" and
            member._tag ~= "Type.ModuleVariable") or
           member.modname ~= modname or
           not valid_source_identifier(member.name) or member.islocal
           or type(member.type) ~= "table" or
           type(member.type._tag) ~= "string" then
            return nil, "module member " .. index .. " has an invalid schema"
        end
        if member._tag == "Type.ModuleVariable"
           and type(member.isconst) ~= "boolean" then
            return nil, "module variable '" .. member.name ..
                "' has a noncanonical const qualifier"
        end
        if names[member.name] then
            return nil, "module interface contains duplicate member '" ..
                member.name .. "'"
        end
        if member._tag == "Type.ModuleMember" then
            local signature = member.type
            if signature._tag == "Type.FunctionScheme" then
                signature = signature.signature
            end
            if signature._tag == "Type.Function" then
                if not validate_name_list(
                        member.paramnames, #signature.params) then
                    return nil, "module function '" .. member.name ..
                        "' has invalid parameter-name metadata"
                end
            elseif member.paramnames ~= false then
                return nil, "non-function module member '" .. member.name ..
                    "' has parameter-name metadata"
            end
        end
        names[member.name] = member
        if modtype.members[member.name] ~= member then
            return nil, "module member map does not match member '" ..
                member.name .. "'"
        end
        local valid_type, type_err = validate_interface_type(member.type, {
            kind = member._tag == "Type.ModuleMember"
                and "module-member" or "value",
            modname = modname,
            name = member.name,
            scopes = {},
            validation = validation,
        }, {})
        if not valid_type then
            return nil, "module member '" .. member.name ..
                "' has an invalid type graph: " .. type_err
        end
        if member._tag == "Type.ModuleVariable"
           and not types.has_tvalue_representation(member.type) then
            return nil, "module variable '" .. member.name ..
                "' has no TValue representation"
        end
        if member._tag == "Type.ModuleMember"
           and member.type._tag ~= "Type.Function"
           and member.type._tag ~= "Type.FunctionScheme"
           and member.type._tag ~= "Type.Record"
           and member.type._tag ~= "Type.Union" then
            return nil, "module member '" .. member.name ..
                "' has invalid declaration type " .. member.type._tag
        end
    end
    for key, member in pairs(modtype.members) do
        if type(key) == "string" and names[key] ~= member then
            return nil, "module member map contains an invalid entry '" ..
                key .. "'"
        end
    end
    for name, member in pairs(modtype.type_members) do
        if not valid_source_identifier(name) or type(member) ~= "table" or
           type(member._tag) ~= "string" then
            return nil, "module type-member table has an invalid schema"
        elseif member._tag == "Type.GenericAlias"
           and (member.module ~= modname or member.name ~= name) then
            return nil, "GenericAlias is published under a noncanonical name"
        end
        local kind = member._tag == "Type.Interface"
            and "interface-type-member"
            or member._tag == "Type.GenericAlias"
                and "generic-alias-type-member"
                or "type-member"
        local context = {
            kind = kind,
            modname = modname,
            name = name,
            scopes = {},
            validation = validation,
        }
        local valid_type, type_err =
            validate_interface_type(member, context, {})
        if not valid_type then
            return nil, "module type member '" .. name ..
                "' has an invalid type graph: " .. type_err
        end
    end

    local resolving, validated = {}, {}
    for _, alias in pairs(validation.aliases) do
        local ok, alias_error = validate_local_alias_projection(
            alias, validation, resolving, validated)
        if not ok then return nil, alias_error end
    end
    for _, application in ipairs(validation.applications) do
        local ok, application_error =
            driver._validate_metadata_generic_application(
                application, validation)
        if not ok then return nil, application_error end
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
    if abi_or_err ~= driver.TITAN_ABI_VERSION then
        return "error", "compiled module '" .. modname
            .. "' ABI mismatch: expected " .. driver.TITAN_ABI_VERSION
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
function driver.find_dynamic_interface(paths, modname, context)
    local candidates = driver.module_binary_candidates(modname)
    if #candidates == 0 then return nil end
    local occupied = {}

    for _, root in ipairs(driver.titan_bin_path_entries(paths)) do
        local absolute_root, root_error = normalize_root(
            root, context and context.io or nil)
        if not absolute_root then return nil, root_error end
        for index, relative in ipairs(candidates) do
            if not occupied[relative] then
                local filename = join_path(absolute_root, relative)
                -- lstat semantics are intentional: a broken symlink or other
                -- occupied pathname is a broken selected candidate, not an
                -- invitation to fall through to a later Titan path root.
                local attributes, attribute_error
                if context and context.io then
                    attributes, attribute_error = context.io:lstat(filename)
                else
                    local mode = lfs.symlinkattributes(filename, "mode")
                    attributes = mode and { kind = mode } or nil
                end
                if attribute_error then
                    return nil, "cannot inspect compiled provider candidate '" ..
                        filename .. "': " .. tostring(attribute_error)
                elseif attributes then
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
                            driver.TITAN_ABI_VERSION .. "): " ..
                            tostring(value and value.abi)
                    end
                end
            end
        end
    end
    return nil
end

-- Compatibility wrapper for callers which predate static providers.
function driver.find_compiled_interface(paths, modname, context)
    return driver.find_dynamic_interface(paths, modname, context)
end

local function inspect_static_provider(context, filename, relative)
    local cached = context.provider_cache[filename]
    if cached then
        if cached.error then return nil, cached.error end
        return cached
    end

    local provider, scan_err = staticmetadata.scan_archive(filename, {
        io = context.io,
        expected_abi = driver.TITAN_ABI_VERSION,
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
        local absolute_root, root_error = normalize_root(root, context.io)
        if not absolute_root then return nil, root_error end
        for index, relative in ipairs(candidates) do
            if not occupied[relative] then
                local filename = join_path(absolute_root, relative)
                local attributes, attribute_error = context.io:lstat(filename)
                if attribute_error then
                    return nil, "cannot inspect static provider candidate '" ..
                        filename .. "': " .. tostring(attribute_error)
                elseif attributes then
                    occupied[relative] = true
                    -- Preserve lstat occupancy (including usable symlinks),
                    -- but never open a FIFO/device/directory as an archive.
                    local followed, followed_error = context.io:stat(filename)
                    if followed_error then
                        return nil, "cannot inspect static provider candidate '" ..
                            filename .. "': " .. tostring(followed_error)
                    elseif not followed or followed.kind ~= "file" then
                        return nil, "static provider candidate '" ..
                            filename .. "' for module '" .. modname ..
                            "' is not a readable regular file"
                    end
                    local provider, provider_err =
                        inspect_static_provider(context, filename, relative)
                    if not provider then return nil, provider_err end
                    local overlaps_source = false
                    for carried_name in pairs(provider.entries) do
                        if context.source_modules[carried_name] then
                            overlaps_source = true
                            break
                        end
                    end
                    if not overlaps_source then
                        local entry = provider.entries[modname]
                        if entry then
                            return entry.type, filename, relative, provider
                        elseif index == #candidates then
                            return nil, "exact static provider '" .. filename ..
                                "' contains no metadata for module '" ..
                                modname .. "'"
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- `driver.imported` intentionally remains a process-global compiler cache,
-- but an embedded interface inventory belongs to exactly one resolver
-- context. Reconcile only the entries whose meaning depends on that context:
-- discard embedded selections owned by another context, and let the current
-- embedded inventory replace cached disk selections for its complete physical
-- inventory. Entries carried together are not unrelated: finalization replays
-- their complete contextual type closure. Source and every other cache entry
-- retain their existing semantics.
--
-- A rejected current provider keeps its own already-selected entries long
-- enough for the loader's whole-provider overlap rebind to replace them (or
-- report that no compatible disk fallback exists).
local function reconcile_embedded_import_cache(context, static_deps)
    local provider = available_embedded_interface_provider(context)
    local configured = context.embedded_interface_provider
    if provider and static_deps then
        -- The dependency set can outlive or be pruned independently from the
        -- global import cache. Clear the complete active inventory rather than
        -- only names which still have a cached static entry.
        for _, name in ipairs(provider.key_order) do
            static_deps[name] = nil
        end
    end
    local remove = {}
    for name, mod in pairs(driver.imported) do
        if mod ~= CIRCULAR_MARK then
            if mod.kind == "embedded" then
                if mod.embedded_provider ~= configured then
                    remove[#remove + 1] = { name = name }
                end
            elseif static_deps and provider and provider.entries[name] and
                   (mod.kind == "dynamic" or mod.kind == "static") then
                remove[#remove + 1] = {
                    name = name,
                }
            end
        end
    end
    for _, candidate in ipairs(remove) do
        driver.imported[candidate.name] = nil
    end
    return provider
end

local function find_embedded_interface(modname, context)
    local provider = available_embedded_interface_provider(context)
    local entry = provider and provider.entries[modname]
    if not entry then return nil end
    return {
        kind = "embedded",
        type = entry.type,
        filename = provider.provider_file,
        embedded_provider = provider,
    }
end

function driver.find_dependency_interface(paths, modname, context)
    context = context or driver.new_resolver_context()
    local embedded = find_embedded_interface(modname, context)
    if embedded then return embedded end
    local formats = context.prefer_static
        and { "static", "dynamic" } or { "dynamic", "static" }

    for _, format in ipairs(formats) do
        if format == "dynamic" then
            local modtype, filename, relative =
                driver.find_dynamic_interface(paths, modname, context)
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

local function check_source_module(
        context, modname, ast, input, filename, loader)
    local check_options = {
        target_profile_provider = function()
            return driver.get_target_profile(context)
        end,
        probe_service_provider = function()
            return driver.get_probe_service(context)
        end,
    }
    return checker.check(
        modname, ast, input, filename, loader, check_options)
end

function driver.defaultloader(static_deps, options)
    static_deps = static_deps or {}
    options = options or {}
    local owns_context = options.context == nil
    local context = options.context or driver.new_resolver_context(options)
    local source_roots = options.source_roots or {}
    local source_overrides = options.source_overrides or {}
    local known_source_modules = options.known_source_modules or {}
    local cached_source_entries = options.cached_source_entries or {}
    local cached_interfaces = options.cached_interfaces or {}
    if type(known_source_modules) ~= "table" then
        error("known_source_modules must be a module-keyed table", 2)
    elseif type(cached_source_entries) ~= "table" then
        error("cached_source_entries must be a module-keyed table", 2)
    elseif type(cached_interfaces) ~= "table" then
        error("cached_interfaces must be a module-keyed table", 2)
    elseif options.after_source_check ~= nil then
        error("after_source_check is no longer supported; provide " ..
            "options.io with a yield method", 2)
    end
    local dependency_stack = {}
    local source_process_trace = context.source_process_trace
    local source_profile_stack = context._source_profile_stack or {}
    local function begin_source_profile()
        if source_process_trace == nil then return nil end
        local frame = {
            started = os.clock(),
            child_cpu_ms = 0,
            parse_cpu_ms = 0,
            check_cpu_ms = 0,
        }
        source_profile_stack[#source_profile_stack + 1] = frame
        return frame
    end

    local function finish_source_profile(
            frame, modname, filename, outcome)
        if frame == nil then return nil end
        local total_cpu_ms = (os.clock() - frame.started) * 1000
        if total_cpu_ms < 0 then total_cpu_ms = 0 end
        local self_cpu_ms = total_cpu_ms - frame.child_cpu_ms
        if self_cpu_ms < 0 then self_cpu_ms = 0 end
        source_profile_stack[#source_profile_stack] = nil
        local parent = source_profile_stack[#source_profile_stack]
        if parent then
            parent.child_cpu_ms = parent.child_cpu_ms + total_cpu_ms
        end
        pcall(source_process_trace, modname, tostring(filename or ""),
            outcome, self_cpu_ms, total_cpu_ms,
            frame.parse_cpu_ms or 0, frame.check_cpu_ms or 0)
        return parent
    end
    for name in pairs(source_roots) do
        context.source_modules[name] = true
    end
    for name in pairs(source_overrides) do
        context.source_modules[name] = true
    end
    for name, present in pairs(known_source_modules) do
        if not staticmetadata.valid_module_name(name) or present ~= true then
            error("known_source_modules must contain valid module names " ..
                "mapped to true", 2)
        end
        context.source_modules[name] = true
    end
    reconcile_embedded_import_cache(context, static_deps)

    local function cached_string_list(value, label)
        if value == nil then return {} end
        if type(value) ~= "table" then
            return nil, label .. " must be a dense ordered string array"
        end
        local copy = {}
        for index = 1, #value do
            if type(value[index]) ~= "string" or value[index] == "" then
                return nil, label .. " entry " .. index ..
                    " must be a nonempty string"
            end
            copy[index] = value[index]
        end
        for key in pairs(value) do
            if type(key) ~= "number" or key % 1 ~= 0
               or key < 1 or key > #value then
                return nil, label .. " must be a dense ordered string array"
            end
        end
        return copy
    end

    local function prepare_source_checking_header(
            modname, ast, foreign_header)
        if not foreign_header then return nil end
        local checking_foreign_header, temporary_error =
            driver.sibling_temporary_path(
                foreign_header .. ".check", context.io)
        if not checking_foreign_header then
            return nil, "could not prepare source foreign header: " ..
                tostring(temporary_error)
        end
        if checking_foreign_header:sub(1, 1) ~= "/" then
            local absolute, absolute_error = absolute_filename(
                checking_foreign_header, context.io)
            if not absolute then return nil, absolute_error end
            checking_foreign_header = normalize_absolute_path(absolute)
        end
        -- Register ownership before publishing any bytes. A strategy method may
        -- suspend or raise for cancellation after the destination exists; the
        -- resolver close path must already know the exact physical pathname.
        context.source_foreign_header_temporaries =
            context.source_foreign_header_temporaries or {}
        context.source_foreign_header_temporaries[
            #context.source_foreign_header_temporaries + 1] =
                checking_foreign_header
        local contents = coder.generate_foreign_header(
            modname, ast, { module = modname })
        local wrote, write_err = contents and context.io:write_file(
            checking_foreign_header, contents)
        local formatted, format_err
        if wrote then
            formatted, format_err = driver.format_generated_file(
                checking_foreign_header, context.probe_verbose,
                context.pretty_print, context.io)
        end
        if not wrote or not formatted then
            local existing = context.io:lstat(checking_foreign_header)
            if existing then context.io:unlink(checking_foreign_header) end
            return nil, "could not prepare source foreign header '" ..
                checking_foreign_header .. "': " ..
                tostring(write_err or format_err or
                    "no generated contents")
        end
        return checking_foreign_header
    end

    local function validate_cached_source_entry(modname, candidate)
        if type(candidate) ~= "table" or candidate.kind ~= "source"
           or type(candidate.ast) ~= "table"
           or type(candidate.type) ~= "table"
           or candidate.type._tag ~= "Type.Module"
           or candidate.type._source ~= true
           or candidate.type.name ~= modname
           or type(candidate.type.source_members) ~= "table"
           or type(candidate.type.source_type_members) ~= "table"
           or type(candidate.filename) ~= "string"
           or candidate.filename == ""
           or not valid_source_files(
                candidate.source_files, candidate.filename)
           or type(candidate.deps) ~= "table"
           or type(candidate.source_manifest) ~= "string"
           or candidate.source_manifest == "" then
            return nil, "cached source entry for module '" .. modname ..
                "' is not a complete checked source module"
        end
        for dependency, present in pairs(candidate.deps) do
            if not staticmetadata.valid_module_name(dependency)
               or present ~= true then
                return nil, "cached source entry for module '" .. modname ..
                    "' has an invalid dependency map"
            end
        end
        local header_dependencies, header_error =
            copy_c_header_dependencies(candidate.c_header_dependencies,
                "cached source entry for module '" .. modname ..
                "' C header dependencies")
        if not header_dependencies then return nil, header_error end
        candidate.c_header_dependencies = header_dependencies
        return true
    end

    local function cached_interface_source_descriptor(modname)
        local candidate = cached_interfaces[modname]
        if candidate == nil then return nil end
        if type(candidate) ~= "table" then
            return false, "cached interface for module '" .. modname ..
                "' must be a table"
        end
        if type(candidate.serialized) ~= "string" then
            return false, "cached interface for module '" .. modname ..
                "' has no serialized manifest"
        end
        local filename = candidate.filename
        if type(filename) ~= "string" or filename == "" then
            return false, "cached interface for module '" .. modname ..
                "' has no source filename"
        end
        local source_files, files_error = cached_string_list(
            candidate.source_files, "cached interface for module '" ..
                modname .. "' source_files")
        if not source_files then return false, files_error end
        if #source_files == 0 then source_files[1] = filename end
        if source_files[1] ~= filename then
            return false, "cached interface for module '" .. modname ..
                "' must list its main source filename first"
        end
        return {
            kind = #source_files == 1 and "flat" or "folder",
            main = filename,
            files = source_files,
            native_output = filename,
        }
    end

    local cached_source_loading = {}
    local load_cached_source_entry
    local function load_cached_source_entry_inner(modname, active_loader)
        local candidate = cached_source_entries[modname]
        if candidate == nil then return nil end
        local valid, validation_error =
            validate_cached_source_entry(modname, candidate)
        if not valid then return false, validation_error end
        if cached_source_loading[modname] then
            return false, "cached source entry cycle at module '" ..
                modname .. "'"
        end
        cached_source_loading[modname] = true

        -- Rehydrate source-required dependency headers first. Their paths are
        -- context-owned temporaries too, and the retained import annotations
        -- necessarily point at files removed with the previous resolver.
        for _, node in ipairs(candidate.ast) do
            if node._tag == "Ast.TopLevelImport" and node._source_import then
                local dependency = driver.imported[node.modname]
                if not dependency then
                    local loaded, load_error =
                        load_cached_source_entry(node.modname, active_loader)
                    if loaded == false then
                        cached_source_loading[modname] = nil
                        return false, load_error
                    end
                    dependency = loaded
                end
                if not dependency or not dependency.ast then
                    -- External source ASTs are intentionally not retained by
                    -- language-server clients. A caller-certified cached
                    -- interface may already have been selected by an ordinary
                    -- import in this analysis. It still carries the exact
                    -- selected source constituent list, so recheck that source
                    -- transiently to recover source-private declarations and a
                    -- fresh resolver-owned foreign header.
                    if cached_interfaces[node.modname] ~= nil then
                        local ok, type_or_error, errors = active_loader(
                            node.modname, { kind = "source-import" })
                        if not ok then
                            cached_source_loading[modname] = nil
                            return false, type_or_error
                        elseif #errors ~= 0 then
                            cached_source_loading[modname] = nil
                            return false, table.concat(errors, "\n")
                        end
                        dependency = driver.imported[node.modname]
                    end
                end
                if not dependency or dependency.kind ~= "source"
                   or not dependency.ast then
                    cached_source_loading[modname] = nil
                    return false, "cached source entry for module '" ..
                        modname .. "' requires clean source dependency '" ..
                        node.modname .. "'"
                end
                node._foreign_header =
                    dependency.checking_foreign_header or
                    dependency.foreign_header
                node._foreign_header_for_check =
                    dependency.checking_foreign_header ~= nil
                local probe_identity = dependency.foreign_header
                if probe_identity and probe_identity:sub(1, 1) ~= "/" then
                    local absolute, absolute_error = absolute_filename(
                        probe_identity, context.io)
                    if not absolute then
                        cached_source_loading[modname] = nil
                        return false, absolute_error
                    end
                    probe_identity = normalize_absolute_path(absolute)
                end
                node._foreign_header_probe_identity = probe_identity
            end
        end

        local has_foreign = driver.ast_has_foreign_functions(candidate.ast)
        local foreign_header = has_foreign and
            (candidate.foreign_header or driver.foreign_header_filename(
                candidate.native_output or candidate.filename)) or nil
        local checking_foreign_header, header_error =
            prepare_source_checking_header(
                modname, candidate.ast, foreign_header)
        if header_error then
            cached_source_loading[modname] = nil
            return false, header_error
        end
        candidate.foreign_header = foreign_header
        candidate.checking_foreign_header = checking_foreign_header
        candidate._cached_source_entry = true
        driver.imported[modname] = candidate
        context.source_modules[modname] = true
        cached_source_loading[modname] = nil
        return candidate
    end

    load_cached_source_entry = function(modname, active_loader)
        local candidate = cached_source_entries[modname]
        if source_process_trace == nil or candidate == nil then
            return load_cached_source_entry_inner(modname, active_loader)
        end
        local frame = begin_source_profile()
        local loaded, load_error =
            load_cached_source_entry_inner(modname, active_loader)
        local filename = type(candidate) == "table"
            and candidate.filename or ""
        finish_source_profile(frame, modname, filename,
            loaded and "complete" or "failed")
        return loaded, load_error
    end

    -- Decode clean project interfaces lazily, only when a dirty module imports
    -- one. These entries deliberately have source provenance but no AST: this
    -- is an analysis-only seam, and a source-required edge still reparses the
    -- real module below so private declarations remain available.
    local function load_cached_interface(modname)
        local candidate = cached_interfaces[modname]
        if candidate == nil then return nil end
        if type(candidate) ~= "table" then
            return false, "cached interface for module '" .. modname ..
                "' must be a table"
        end
        local serialized = candidate.serialized
        if type(serialized) ~= "string" then
            return false, "cached interface for module '" .. modname ..
                "' has no serialized manifest"
        end
        local filename = candidate.filename
        if type(filename) ~= "string" or filename == "" then
            return false, "cached interface for module '" .. modname ..
                "' has no source filename"
        end
        local source_files, files_error = cached_string_list(
            candidate.source_files, "cached interface for module '" ..
                modname .. "' source_files")
        if not source_files then return false, files_error end
        if #source_files == 0 then source_files[1] = filename end
        local dependencies, dependencies_error = cached_string_list(
            candidate.dependencies, "cached interface for module '" ..
                modname .. "' dependencies")
        if not dependencies then return false, dependencies_error end
        local header_dependencies, header_error =
            copy_c_header_dependencies(candidate.c_header_dependencies,
                "cached interface for module '" .. modname ..
                "' C header dependencies")
        if not header_dependencies then return false, header_error end
        local deps = {}
        for _, dependency in ipairs(dependencies) do
            if not staticmetadata.valid_module_name(dependency) then
                return false, "cached interface for module '" .. modname ..
                    "' has invalid dependency name " ..
                    string.format("%q", dependency)
            end
            deps[dependency] = true
        end
        local modtype, decode_error = driver.decode_module_interface(
            serialized, modname, "cached interface for " .. modname)
        if not modtype then
            return false, "invalid cached interface for module '" ..
                modname .. "': " .. tostring(decode_error)
        end
        local entry = {
            kind = "source",
            type = modtype,
            filename = filename,
            source_files = source_files,
            deps = deps,
            c_header_dependencies = header_dependencies,
            _cached_interface = true,
        }
        driver.imported[modname] = entry
        context.source_modules[modname] = true
        return entry
    end

    -- A source-first traversal can select an embedded entry before reaching a
    -- source key carried by that same closed inventory. Reject the complete
    -- analysis-only provider and re-resolve every prior selection through the
    -- ordinary disk formats before checking continues.
    local function rebind_overlapping_embedded_provider(source_name)
        local provider = context.embedded_interface_provider
        if not provider or not provider.entries[source_name] then return true end
        context.embedded_interface_provider_rejected = true
        context.embedded_interface_provider_overlap = source_name

        -- Numeric conversions may already hold traits from this inventory's
        -- build target. Before any source replacement or later implicit
        -- conversion can continue, require the ordinary live target to agree.
        -- An upfront source catalog never consumes the rejected build profile
        -- and therefore retains unrestricted ordinary target selection.
        if context.used_embedded_target_profile_identity then
            local profile, profile_error = driver.get_target_profile(context)
            if not profile then
                return nil, "cannot continue analysis after embedded provider " ..
                    "source overlap: " .. tostring(profile_error)
            end
        end

        local selected_names = {}
        for name, mod in pairs(driver.imported) do
            if mod ~= CIRCULAR_MARK and mod.kind == "embedded" and
               mod.embedded_provider == provider then
                selected_names[#selected_names + 1] = name
            end
        end
        table.sort(selected_names, util.bytewise_less)

        local replacements = {}
        for _, name in ipairs(selected_names) do
            local resolved, resolve_error = driver.find_dependency_interface(
                driver.TITAN_BIN_PATH, name, context)
            if not resolved then
                return nil, "embedded interface provider '" ..
                    provider.provider_file .. "' carries source-selected module '" ..
                    source_name .. "', and its selected module '" .. name ..
                    "' has no compatible disk-provider fallback" ..
                    (resolve_error and (": " .. tostring(resolve_error)) or "")
            end
            local old_type = driver.imported[name].type
            if types.serialize(old_type) ~= types.serialize(resolved.type) then
                return nil, "disk-provider fallback '" ..
                    tostring(resolved.static_archive or resolved.filename) ..
                    "' for module '" .. name ..
                    "' does not match embedded interface provider '" ..
                    provider.provider_file .. "'"
            end
            replacements[#replacements + 1] = {
                name = name,
                old_type = old_type,
                resolved = resolved,
                file = resolved.type.file,
            }
        end

        for _, replacement in ipairs(replacements) do
            replacement.old_type.file = replacement.file
            replacement.resolved.type = replacement.old_type
            replacement.resolved.compiled = true
            driver.imported[replacement.name] = replacement.resolved
            if replacement.resolved.kind == "static" then
                static_deps[replacement.name] = true
            else
                static_deps[replacement.name] = nil
            end
        end
        return true
    end

    -- A source-first traversal may select one key from a static container
    -- before reaching a source key carried by that same container. Once the
    -- source identity is known, move every already-selected key from that
    -- container to an interface-identical DSO before checking continues. The
    -- source import remains authoritative and the finalizer never has to
    -- weaken its physical-provider identity check.
    local function rebind_overlapping_static_providers(source_name)
        local providers = {}
        for _, mod in pairs(driver.imported) do
            if mod ~= CIRCULAR_MARK and mod.kind == "static" and
               mod.static_provider and
               mod.static_provider.entries[source_name] then
                providers[mod.static_provider.archive] = mod.static_provider
            end
        end

        local provider_paths = {}
        for path in pairs(providers) do
            provider_paths[#provider_paths + 1] = path
        end
        table.sort(provider_paths, util.bytewise_less)

        for _, path in ipairs(provider_paths) do
            local provider = providers[path]
            local selected_names = {}
            for name, mod in pairs(driver.imported) do
                if mod ~= CIRCULAR_MARK and mod.kind == "static" and
                   mod.static_provider == provider then
                    selected_names[#selected_names + 1] = name
                end
            end
            table.sort(selected_names, util.bytewise_less)

            local replacements = {}
            for _, name in ipairs(selected_names) do
                local dynamic_type, filename, relative =
                    driver.find_dynamic_interface(
                        driver.TITAN_BIN_PATH, name, context)
                if not dynamic_type then
                    return nil, "static provider '" .. path ..
                        "' carries source-selected module '" .. source_name ..
                        "', and its selected module '" .. name ..
                        "' has no compatible dynamic-provider fallback" ..
                        (filename and (": " .. tostring(filename)) or "")
                end
                local old_type = driver.imported[name].type
                if types.serialize(old_type) ~= types.serialize(dynamic_type) then
                    return nil, "dynamic-provider fallback '" .. filename ..
                        "' for module '" .. name ..
                        "' does not match static provider '" .. path .. "'"
                end
                replacements[#replacements + 1] = {
                    name = name,
                    type = old_type,
                    file = dynamic_type.file,
                    filename = filename,
                    relative = relative,
                }
            end

            for _, replacement in ipairs(replacements) do
                replacement.type.file = replacement.file
                driver.imported[replacement.name] = {
                    kind = "dynamic",
                    type = replacement.type,
                    filename = replacement.filename,
                    relative = replacement.relative,
                    compiled = true,
                }
                static_deps[replacement.name] = nil
            end
        end
        return true
    end

    local function remember_dependency_closure(modname, seen)
        seen = seen or {}
        if seen[modname] then return end
        seen[modname] = true
        local mod = driver.imported[modname]
        if not mod or mod == CIRCULAR_MARK then return end
        if mod.ast or mod.kind == "source" or mod.kind == "static" then
            static_deps[modname] = true
            local embedded_provider =
                available_embedded_interface_provider(context)
            for depname in pairs(mod.deps or {}) do
                -- A reusable source/static dependency closure can outlive the
                -- disk selection it described. The current closed embedded
                -- inventory supplies analysis metadata only, so do not revive
                -- one of its carried names as a native link input.
                if not (embedded_provider and
                        embedded_provider.entries[depname]) then
                    static_deps[depname] = true
                    remember_dependency_closure(depname, seen)
                end
            end
        end
    end

    local function remember_direct_dependency(modname)
        local direct = dependency_stack[#dependency_stack]
        if not direct then return end
        local mod = driver.imported[modname]
        if mod and mod ~= CIRCULAR_MARK and
           (mod.ast or mod.kind == "source" or mod.kind == "static") then
            direct[modname] = true
        end
    end

    local function parse_source_inner(modname, source, loader, profile_frame)
        local ast = {}
        local main_input
        local main_initializer

        for index, filename in ipairs(source.files) do
            local input, err
            if source.contents then
                input = source.contents[filename]
                if input == nil then
                    return false, "generated source has no contents for '" ..
                        filename .. "'"
                end
            else
                input, err = context.io:read_file(filename)
                if not input then return false, err end
            end
            local parse_started = profile_frame and os.clock() or nil
            local nodes, perr = parser.parse(filename, input)
            if profile_frame then
                local parse_cpu_ms = (os.clock() - parse_started) * 1000
                if parse_cpu_ms < 0 then parse_cpu_ms = 0 end
                profile_frame.parse_cpu_ms =
                    profile_frame.parse_cpu_ms + parse_cpu_ms
            end
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
        local check_started = profile_frame and os.clock() or nil
        local check_child_started = profile_frame
            and profile_frame.child_cpu_ms or 0
        local modt, errors = check_source_module(
            context, modname, ast, main_input, source.main, loader)
        if profile_frame then
            local inclusive_check_cpu_ms =
                (os.clock() - check_started) * 1000
            local child_check_cpu_ms =
                profile_frame.child_cpu_ms - check_child_started
            local check_cpu_ms =
                inclusive_check_cpu_ms - child_check_cpu_ms
            if check_cpu_ms < 0 then check_cpu_ms = 0 end
            profile_frame.check_cpu_ms = check_cpu_ms
        end
        table.remove(dependency_stack)
        check_used_compiled_interface(context, modname, modt, errors)
        local has_foreign = driver.ast_has_foreign_functions(ast)
        local foreign_header = has_foreign and driver.foreign_header_filename(
            source.native_output or source.main) or nil
        local checking_foreign_header
        if has_foreign and #errors == 0 then
            local header_error
            checking_foreign_header, header_error =
                prepare_source_checking_header(
                    modname, ast, foreign_header)
            if header_error then errors[#errors + 1] = header_error end
        end
        local entry = {
            kind = "source",
            ast = ast,
            type = modt,
            filename = source.main,
            native_output = source.native_output or source.main,
            source_files = source.files,
            program_output = source.program_output,
            deps = direct_deps,
            c_header_dependencies = ast._c_header_dependencies or {},
            foreign_header = foreign_header,
            checking_foreign_header = checking_foreign_header,
        }
        if #errors == 0 then
            local source_manifest, manifest_error =
                driver.serialize_source_interface(entry)
            if not source_manifest then
                errors[#errors + 1] = "could not serialize source interface " ..
                    "for module '" .. modname .. "': " ..
                    tostring(manifest_error)
            else
                entry.source_manifest = source_manifest
            end
        end
        driver.imported[modname] = entry
        static_deps[modname] = true
        if foreign_header and foreign_header:sub(1, 1) ~= "/" then
            local absolute, absolute_error = absolute_filename(
                foreign_header, context.io)
            if not absolute then
                return false, absolute_error
            end
            foreign_header = normalize_absolute_path(absolute)
        end
        -- The context strategy owns cooperative suspension. This module is
        -- fully published and its dependency frame has been popped. Recursive
        -- callers can still be mid-check, so a client which abandons the Task
        -- must close the resolver and discard the whole analysis state.
        context.checked_source_modules[
            #context.checked_source_modules + 1] = modname
        return true, modt, errors, {
            kind = "source",
            filename = source.main,
            foreign_header = checking_foreign_header,
            foreign_header_for_check = checking_foreign_header ~= nil,
            foreign_header_probe_identity = foreign_header,
        }
    end

    local function parse_source(modname, source, loader)
        if source_process_trace == nil then
            local ok, modtype, errors, info =
                parse_source_inner(modname, source, loader, nil)
            if ok then context.io:yield(modname) end
            return ok, modtype, errors, info
        end

        local frame = begin_source_profile()
        local ok, modtype, errors, info =
            parse_source_inner(modname, source, loader, frame)
        local parent = finish_source_profile(
            frame, modname, source.main, ok and "complete" or "failed")
        if ok then
            -- The module itself is complete before this cooperative checkpoint.
            -- Its caller's frame is still live, so exclude process CPU consumed
            -- by other Tasks while this source-check Task is suspended rather
            -- than charging that scheduler work to the importing module.
            local yield_started = os.clock()
            context.io:yield(modname)
            if parent then
                local yield_cpu_ms = (os.clock() - yield_started) * 1000
                if yield_cpu_ms > 0 then
                    parent.child_cpu_ms =
                        parent.child_cpu_ms + yield_cpu_ms
                end
            end
        end
        return ok, modtype, errors, info
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
        if exposing.kind == "embedded" then
            local provider = available_embedded_interface_provider(context)
            if not provider or exposing.embedded_provider ~= provider then
                return false, "embedded interface provider for module '" ..
                    tostring(exposing_name) ..
                    "' is not available in this resolver context"
            end
        end
        if modname == exposing_name then
            remember_used_compiled_interface(
                context, modname, exposing.type)
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
            remember_used_compiled_interface(
                context, modname, cached.type)
            return true, cached.type, {}
        end

        local function remember_type(modtype, resolved, ordinary_lookup)
            context.contextual_types[cache_key] = { type = modtype }
            context.native_interface_types[modname] = modtype
            remember_used_compiled_interface(context, modname, modtype)
            remember_contextual_resolution(
                context, modname, exposing_name, resolved, ordinary_lookup,
                physical_identity)
            return true, modtype, {}
        end

        if exposing.kind == "static" or exposing.kind == "embedded" then
            local provider = exposing.kind == "static" and
                exposing.static_provider or exposing.embedded_provider
            local entry = provider and provider.entries[modname]
            if entry then
                if exposing.kind == "static" then
                    add_native_constraint(context, modname, "direct-carried",
                        exposing.static_archive, exposing_name)
                end
                return remember_type(entry.type, exposing, false)
            end
        elseif exposing.kind == "dynamic" then
            local status, value =
                probe_compiled_interface(modname, exposing.filename)
            if status == "valid" then
                add_native_constraint(context, modname, "dynamic-global",
                    exposing.filename, exposing_name)
                return remember_type(value, exposing, false)
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
            if exposing.kind ~= "embedded" then
                add_native_constraint(context, modname, "dynamic-global",
                    exposing.static_archive or exposing.filename, exposing_name)
            end
            return remember_type(ordinary.type, ordinary, true)
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
        if exposing.kind ~= "embedded" then
            add_native_constraint(context, modname, "dynamic-global",
                exposing.static_archive or exposing.filename, exposing_name)
        end
        return remember_type(resolved.type, resolved, true)
    end

    local function loader(modname, request)
        if not staticmetadata.valid_module_name(modname) then
            return false, "invalid logical Titan module name " ..
                string.format("%q", modname)
        end
        -- A borrowed context may learn a complete known-source catalog after
        -- an earlier loader selected embedded entries. Reconcile that late
        -- whole-provider rejection before either cache reuse or contextual
        -- owner recovery can observe the stale selection.
        reconcile_embedded_import_cache(context, static_deps)
        local embedded_overlap =
            context.embedded_interface_provider_overlap
        if embedded_overlap then
            local rebound, rebound_error =
                rebind_overlapping_embedded_provider(embedded_overlap)
            if not rebound then return false, rebound_error end
        end
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

        -- Command-line roots and `.titan` import spellings both require a
        -- source implementation. The latter is an edge-local request: it may
        -- replace an already cached binary selection, and a clean source miss
        -- is terminal instead of falling back to a provider.
        local source_required = source_roots[modname] == true or
            (request and request.kind == "source-import")
        local source_preferred = source_required or context.source_first or
            source_overrides[modname] ~= nil
        local source, source_err
        local source_checked = false
        local function find_source()
            if source_checked then return source, source_err end
            source_checked = true
            source = source_overrides[modname]
            if source then return source end
            if source_required then
                source, source_err =
                    cached_interface_source_descriptor(modname)
                if source == false then
                    source = nil
                    return nil, source_err
                elseif source then
                    return source
                end
            end
            source, source_err = resolve_source(
                driver.TITAN_SOURCE_PATH, modname, context)
            return source, source_err
        end
        local function load_source(candidate)
            if candidate.kind == "blocked" then
                return false, blocked_source_error(modname, candidate)
            end
            context.source_modules[modname] = true
            local rebound, rebound_err =
                rebind_overlapping_embedded_provider(modname)
            if not rebound then return false, rebound_err end
            rebound, rebound_err =
                rebind_overlapping_static_providers(modname)
            if not rebound then return false, rebound_err end
            local ok, modt, errors, info =
                parse_source(modname, candidate, loader)
            if ok then remember_direct_dependency(modname) end
            return ok, modt, errors, info
        end

        -- Raw entries retain the complete annotated AST and source-private
        -- interface required by `.titan` imports. Only caller-certified clean
        -- modules are eligible; explicit dirty roots, source overrides, and
        -- source-first compiler builds always check source again.
        if not driver.imported[modname]
           and not context.source_first
           and source_roots[modname] ~= true
           and source_overrides[modname] == nil then
            local cached, cached_error =
                load_cached_source_entry(modname, loader)
            if cached == false then return false, cached_error end
        end

        -- Source-required roots and invocation-wide source-first builds may
        -- replace a binary left in this process-global cache by an earlier
        -- compilation. A source error is terminal; a clean source miss lets a
        -- source-first dependency retain/fall back to its compiled identity.
        local dirty_source_requested = source_roots[modname] == true or
            source_overrides[modname] ~= nil
        if source_preferred and driver.imported[modname] and
           (not driver.imported[modname].ast or
            (dirty_source_requested and
             driver.imported[modname]._cached_source_entry)) then
            local candidate, candidate_err = find_source()
            if candidate_err then return false, candidate_err end
            if candidate then
                driver.imported[modname] = nil
            elseif source_required then
                return false, "source module '" .. modname .. "' not found"
            end
        end
        if not source_preferred and not driver.imported[modname] then
            local cached, cached_error = load_cached_interface(modname)
            if cached == false then return false, cached_error end
        end
        if driver.imported[modname] then
            local mod = driver.imported[modname]
            remember_dependency_closure(modname)
            remember_direct_dependency(modname)
            if mod.kind == "dynamic" or mod.kind == "static" or
               mod.kind == "embedded" or mod.compiled then
                remember_used_compiled_interface(
                    context, modname, mod.type)
            end
            local info = { kind = mod.kind }
            if mod.kind == "source" and mod.filename then
                local foreign_header = mod.checking_foreign_header
                    or mod.foreign_header
                if foreign_header and foreign_header:sub(1, 1) ~= "/" then
                    local absolute, absolute_error = absolute_filename(
                        foreign_header, context.io)
                    if not absolute then return false, absolute_error end
                    foreign_header = normalize_absolute_path(absolute)
                end
                local probe_identity = mod.foreign_header
                if probe_identity and probe_identity:sub(1, 1) ~= "/" then
                    local absolute, absolute_error = absolute_filename(
                        probe_identity, context.io)
                    if not absolute then return false, absolute_error end
                    probe_identity = normalize_absolute_path(absolute)
                end
                info.filename = mod.filename
                info.foreign_header = foreign_header
                info.foreign_header_for_check =
                    mod.checking_foreign_header ~= nil
                info.foreign_header_probe_identity = probe_identity
            end
            return true, mod.type, {}, info
        end

        if source_preferred then
            local candidate, candidate_err = find_source()
            if candidate_err then return false, candidate_err end
            if candidate then return load_source(candidate) end
            if source_required then
                return false, "source module '" .. modname .. "' not found"
            end
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
            remember_used_compiled_interface(
                context, modname, resolved.type)
            return true, resolved.type, {}, { kind = resolved.kind }
        elseif compiled_err then
            return false, compiled_err
        end

        if not source_checked then
            local candidate, candidate_err = find_source()
            if candidate_err then return false, candidate_err end
        end
        if not source then return false, "module '" .. modname .. "' not found" end
        return load_source(source)
    end
    context.loader = loader
    loader_contexts[loader] = {
        context = context,
        owned = owns_context,
    }
    return loader
end

-- Resolve the physical identity of already-known external dependencies without
-- parsing source or retaining compiler state. Language-server clients use this
-- as a cheap topology probe before deciding whether a cached project AST is
-- still valid. `requests` maps logical module names to the edge requirement:
-- true means an explicit `.titan` import and therefore source-only lookup;
-- false uses the ordinary compiled-first policy. `known_source_modules` is the
-- complete project catalog, not just the dirty work set, so static providers
-- which overlap project source are rejected exactly as they are by the loader.
function driver.resolve_external_modules(
        requests, known_source_modules, options)
    requests = requests or {}
    known_source_modules = known_source_modules or {}
    if type(requests) ~= "table" then
        error("external resolution requests must be a module-keyed table", 2)
    elseif type(known_source_modules) ~= "table" then
        error("known_source_modules must be a module-keyed table", 2)
    end

    local context, owns_context =
        resolver_context_from_options(options, 2)
    local results = {}
    local names = {}
    local ok, failure = xpcall(function()
        for name, present in pairs(known_source_modules) do
            if not staticmetadata.valid_module_name(name) or present ~= true then
                error("known_source_modules must contain valid module names " ..
                    "mapped to true", 2)
            end
            context.source_modules[name] = true
        end
        for name, source_required in pairs(requests) do
            if not staticmetadata.valid_module_name(name) or
               type(source_required) ~= "boolean" then
                error("external resolution requests must contain valid " ..
                    "module names mapped to booleans", 2)
            end
            names[#names + 1] = name
            if source_required then context.source_modules[name] = true end
        end
        table.sort(names, util.bytewise_less)

        for _, name in ipairs(names) do
            local source_required = requests[name]
            if not source_required then
                local resolved, compiled_error =
                    driver.find_dependency_interface(
                        driver.TITAN_BIN_PATH, name, context)
                if resolved then
                    results[name] = {
                        kind = resolved.kind,
                        provider_file = resolved.static_archive or
                            resolved.filename,
                    }
                elseif compiled_error then
                    results[name] = {
                        kind = "error",
                        message = compiled_error,
                    }
                end
            end

            if not results[name] then
                local source, source_error = resolve_source(
                    driver.TITAN_SOURCE_PATH, name, context)
                if source_error then
                    results[name] = {
                        kind = "error",
                        message = source_error,
                    }
                elseif source and source.kind == "blocked" then
                    results[name] = {
                        kind = "error",
                        message = blocked_source_error(name, source),
                    }
                elseif source then
                    local files = {}
                    for index, filename in ipairs(source.files) do
                        files[index] = filename
                    end
                    results[name] = {
                        kind = "source",
                        main_file = source.main,
                        source_files = files,
                    }
                elseif source_required then
                    results[name] = {
                        kind = "error",
                        message = "source module '" .. name .. "' not found",
                    }
                else
                    results[name] = { kind = "missing" }
                end
            end
        end
    end, function(err) return err end)
    local closed, close_error = true
    if owns_context then
        closed, close_error = driver.close_resolver_context(context)
    end
    if not ok then error(failure, 0) end
    if not closed then
        error("failed to close external resolver context: " ..
            tostring(close_error), 0)
    end
    return results
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
    reconcile_embedded_import_cache(context)
    local source_names = {}
    local dynamic_names = {}
    local selected_embedded_modules = {}
    local selected_static_modules = {}
    local embedded_providers_by_path = {}
    local providers_by_path = {}

    for name, mod in pairs(driver.imported) do
        if mod ~= CIRCULAR_MARK then
            if mod.kind == "static" then
                selected_static_modules[name] = mod
                providers_by_path[mod.static_archive] = mod.static_provider
            elseif mod.kind == "embedded" then
                selected_embedded_modules[name] = mod
                embedded_providers_by_path[mod.filename] =
                    mod.embedded_provider
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

    local selected_embedded_providers = {}
    for _, provider in pairs(embedded_providers_by_path) do
        selected_embedded_providers[
            #selected_embedded_providers + 1] = provider
    end
    table.sort(selected_embedded_providers, function(left, right)
        return util.bytewise_less(
            left.provider_file, right.provider_file)
    end)
    if context.embedded_interface_provider_rejected and
       next(selected_embedded_modules) ~= nil then
        return nil, {
            "embedded interface provider '" ..
            tostring(context.embedded_interface_provider and
                context.embedded_interface_provider.provider_file) ..
            "' overlaps source module '" ..
            tostring(context.embedded_interface_provider_overlap) ..
            "' after an embedded interface was selected",
        }
    end

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
            local registered, register_error =
                checker.register_module_interface(
                    name, mod.type, context.loader, {
                        name = name,
                        kind = "dynamic",
                        type = mod.type,
                        filename = mod.filename,
                    })
            if not registered then return nil, {register_error} end
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
                local registered, register_error =
                    checker.register_module_interface(
                        name, entry.type, context.loader, {
                            name = name,
                            kind = "static",
                            type = entry.type,
                            filename = provider.archive,
                            static_archive = provider.archive,
                            static_provider = provider,
                        })
                if not registered then return nil, {register_error} end
            end
        end
    end

    -- Embedded inventories have the same carried-interface closure as static
    -- providers for nominal-owner recovery, but they are semantic data only.
    -- Replay every carried interface without creating native constraints or
    -- adding the host executable to static-provider bookkeeping.
    if context.loader then
        for _, provider in ipairs(selected_embedded_providers) do
            for _, name in ipairs(provider.key_order) do
                local entry = provider.entries[name]
                local registered, register_error =
                    checker.register_module_interface(
                        name, entry.type, context.loader, {
                            name = name,
                            kind = "embedded",
                            type = entry.type,
                            filename = provider.provider_file,
                            embedded_provider = provider,
                        })
                if not registered then return nil, {register_error} end
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
    context.selected_embedded_modules = selected_embedded_modules
    context.selected_embedded_providers = selected_embedded_providers
    context.selected_static_modules = selected_static_modules
    context.selected_static_providers = selected_static_providers
    context.native_static_names = native_static_names
    context.native_bindings = native_bindings
    context.physical_owner = physical_owner

    -- Simple recovered aliases may reuse a canonical registry owner while
    -- final interfaces are replayed, so contextual resolution callbacks are
    -- not guaranteed to fire again. Retain provisional metadata only when its
    -- exposing compiled module survived final resolver selection with the
    -- same physical identity; this rejects entries made obsolete by a later
    -- source-root or provider replacement without relying on registry replay.
    local contextual_resolutions = {}
    for key, resolution in pairs(
            context.contextual_resolutions or {}) do
        local exposer = driver.imported[resolution.exposer]
        local exposer_file = exposer and
            (exposer.static_archive or exposer.filename)
        local compiled = exposer and exposer ~= CIRCULAR_MARK and
            (exposer.kind == "static" or exposer.kind == "dynamic" or
             exposer.kind == "embedded")
        local carried_matches = resolution.ordinary_lookup or
            resolution.provider_file == exposer_file
        if compiled and exposer_file == resolution.exposer_file and
           carried_matches then
            contextual_resolutions[key] = resolution
        end
    end
    context.contextual_resolutions = contextual_resolutions

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

function driver.tableloader(modtable, imported, deps, options)
    deps = deps or {}
    options = options or {}
    local owns_context = options.context == nil
    local context = options.context or driver.new_resolver_context(options)
    local source_view = options.interface == "source"

    local function source_requested(request)
        return request and request.kind == "source-import"
    end

    local function selected_interface(mod, request)
        if (source_view or source_requested(request)) and
           mod.kind == "source" and mod.source_type then
            local header = mod.filename and mod.ast
                and driver.ast_has_foreign_functions(mod.ast)
                and driver.foreign_header_filename(
                    mod.native_output or mod.filename) or nil
            return mod.source_type, {
                kind = "source",
                filename = mod.filename,
                foreign_header = header,
            }
        end
        return mod.type, { kind = mod.kind == "source"
            and "compiled" or mod.kind }
    end

    local function loader(modname, request)
        if not staticmetadata.valid_module_name(modname) then
            return false, "invalid logical Titan module name " ..
                string.format("%q", modname)
        end
        if imported[modname] == CIRCULAR_MARK then
            imported[modname] = nil
            return false, "circular reference to module"
        end
        if imported[modname] then
            local mod = imported[modname]
            if source_requested(request) and
               (mod.kind ~= "source" or not mod.source_type) then
                if modtable[modname] == nil then
                    return false,
                        "source module '" .. modname .. "' not found"
                end
                imported[modname] = nil
            else
                deps[modname] = true
                if mod.kind ~= "source" then
                    remember_used_compiled_interface(
                        context, modname, mod.type)
                end
                local modtype, info = selected_interface(mod, request)
                return true, modtype, {}, info
            end
        end
        local modf = "./" .. modname .. ".titan"
        local input = modtable[modname]
        if input == nil then
            local message = request and request.kind == "source-import"
                and ("source module '" .. modname .. "' not found")
                or ("module '" .. modname .. "' not found")
            return false, message
        end
        local ast, err = parser.parse(modf, input)
        if not ast then return false, parser.error_to_string(err, modf) end
        imported[modname] = CIRCULAR_MARK
        local source_type, errors = check_source_module(
            context, modname, ast, input, modf, loader)
        check_used_compiled_interface(
            context, modname, source_type, errors)
        if #errors ~= 0 then
            imported[modname] = {
                kind = "source", ast = ast, type = source_type,
                source_type = source_type, filename = modf,
            }
            deps[modname] = true
            local modtype, info = selected_interface(
                imported[modname], request)
            return true, modtype, errors, info
        end

        -- Retain both products. The decoded type deliberately strips every
        -- compiler-only source field and remains the tableloader default for
        -- existing metadata-projection tests. Callers that explicitly request
        -- `interface = "source"` receive the trusted raw view plus provenance.
        local mods = types.serialize(source_type)
        local modtf, load_err = load("return " .. mods, modname, "t", types)
        if not modtf then return false, load_err end
        local ok, modt_or_err = pcall(modtf)
        if not ok then return false, modt_or_err end
        imported[modname] = {
            kind = "source", ast = ast, type = modt_or_err,
            source_type = source_type, filename = modf,
        }
        deps[modname] = true
        local modtype, info = selected_interface(imported[modname], request)
        return true, modtype, errors, info
    end
    loader_contexts[loader] = {
        context = context,
        owned = owns_context,
    }
    return loader
end

function driver.close_tableloader(loader)
    return driver.close_loader(loader)
end

-- Native publication can run in a fresh Lua process after the compiler has
-- already produced its objects (for example stdlib_installer.lua validating a
-- staged archive). Module loading deliberately performs no subprocess I/O, so
-- recover the platform through an explicit resolver strategy when no earlier
-- compiler operation initialized it.
function driver.shared_library_flags(context)
    local owns_context = context == nil
    if context ~= nil or type(driver.UNAME) ~= "string"
       or type(driver.IS_DARWIN) ~= "boolean" then
        context = context or driver.new_resolver_context()
        local initialized, platform_error = driver.initialize_platform(context)
        local closed, close_error = true
        if owns_context then
            closed, close_error = driver.close_resolver_context(context)
        end
        if not initialized then return nil, platform_error end
        if not closed then return nil, close_error end
    end

    local shared = { "-shared" }
    if driver.IS_DARWIN then
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
    local ok, err, libname, native_references = driver.compile(
        modname, mod.ast, mod.native_output or mod.filename,
        static_deps, verbose, options)
    if not ok then return nil, err end
    mod.compiled = libname
    mod.native_references = native_references or {}
    return true, nil, libname
end

local RUNTIME_ARCHIVE_INPUTS = {
    "titan.c",
    "titan.h",
    "minicoro.c",
    "minicoro.h",
    "titan/ffi.h",
}
local RUNTIME_ARCHIVE_MEMBERS = {
    "titan.o",
    "minicoro.o",
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
    runtime_checked = runtime_checked or driver.INSTALLED
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

function driver.installed_link_inputs(paths, is_darwin)
    local inputs = {
        paths.libtitan,
        paths.libbacktrace,
        paths.liblua
    }
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

local ensure_output_parent

driver.FOREIGN_HEADER_MARKER =
    "/* Generated by Titan: source foreign function interface. */"

function driver.foreign_header_filename(sourcef)
    local stem, count = sourcef:gsub("[.]titan$", "")
    assert(count == 1, "foreign header source path must end in .titan")
    return stem .. ".titan.h"
end

function driver.ast_has_foreign_functions(ast)
    for _, node in ipairs(ast or {}) do
        if not node._ignore and node._tag == "Ast.TopLevelForeignFunc" then
            return true
        end
    end
    return false
end

function driver.plan_foreign_header(modname, ast, sourcef, defer_render)
    sourcef = sourcef or modname:gsub("[.]", "/") .. ".titan"
    local headername = driver.foreign_header_filename(sourcef)
    local has_foreign = driver.ast_has_foreign_functions(ast)
    if not has_foreign then ast._foreign_header_include_keys = nil end
    local absolute_header = headername
    if absolute_header:sub(1, 1) ~= "/" then
        absolute_header = normalize_absolute_path(
            lfs.currentdir() .. "/" .. absolute_header)
    end
    ast._foreign_header_output = has_foreign and absolute_header or nil
    local contents
    if has_foreign and not defer_render then
        contents = coder.generate_foreign_header(
            modname, ast, { module = modname })
    end
    return {
        modname = modname,
        ast = ast,
        filename = headername,
        absolute = absolute_header,
        has_foreign = has_foreign,
        contents = contents,
    }
end

function driver.validate_foreign_header_plan(plan)
    local attr = lfs.symlinkattributes(plan.filename)
    local existing = attr and attr.mode == "file"
        and util.get_file_contents(plan.filename) or nil
    local owned = existing
        and existing:sub(1, #driver.FOREIGN_HEADER_MARKER)
            == driver.FOREIGN_HEADER_MARKER
    if plan.contents and attr and (attr.mode ~= "file" or not owned) then
        return nil, "refusing to overwrite user-owned generated-header path '"
            .. plan.filename .. "'"
    end
    plan.managed = plan.contents ~= nil or owned and true or false
    return true
end

function driver.write_foreign_header_plan(plan, verbose, pretty_print)
    local ok, err = driver.validate_foreign_header_plan(plan)
    if not ok then return nil, err end
    local parent_ok, parent_err = ensure_output_parent(plan.filename)
    if not parent_ok then return nil, parent_err end
    local existing = util.get_file_contents(plan.filename)
    local owned = existing and
        existing:sub(1, #driver.FOREIGN_HEADER_MARKER) ==
            driver.FOREIGN_HEADER_MARKER

    if plan.contents then
        -- Keep the public header untouched until formatting succeeds. Header
        -- ownership was validated for every plan before this write phase.
        local temporary = driver.sibling_temporary_path(
            plan.filename .. ".format")
        local write_ok, write_err = util.set_file_contents(
            temporary, plan.contents)
        if not write_ok then
            os.remove(temporary)
            return nil, write_err
        end
        local format_ok, format_err =
            driver.format_generated_file(temporary, verbose, pretty_print)
        if not format_ok then
            os.remove(temporary)
            return nil, format_err
        end
        local moved, move_err = os.rename(temporary, plan.filename)
        if not moved then
            os.remove(temporary)
            return nil, move_err
        end
    elseif owned then
        local removed, remove_err = os.remove(plan.filename)
        if not removed then return nil, remove_err end
    end
    plan.ast._foreign_header_contents = plan.contents
    plan.ast._foreign_header_prepared = true
    return true
end

function driver.plan_foreign_headers(names, imported)
    local plans = {}
    local by_name = {}
    local occupied = {}
    for _, name in ipairs(names) do
        local mod = assert(imported[name])
        if mod.ast and not mod.compiled then
            local plan = driver.plan_foreign_header(
                name, mod.ast, mod.native_output or mod.filename, true)
            local previous = occupied[plan.absolute]
            if previous and previous ~= name then
                return nil, "generated foreign-header path '" .. plan.filename
                    .. "' is shared by source modules '" .. previous
                    .. "' and '" .. name .. "'"
            end
            occupied[plan.absolute] = name
            plans[#plans + 1] = plan
            by_name[name] = plan
        end
    end

    -- Header identity follows the finalized physical native output, not the
    -- source lookup filename. Resolve every direct source edge from the full
    -- plan before rendering any consumer header or C translation unit.
    for _, plan in ipairs(plans) do
        for _, node in ipairs(plan.ast) do
            if not node._ignore and node._tag == "Ast.TopLevelImport"
               and node._source_import then
                local dependency = by_name[node.modname]
                node._foreign_header = dependency and dependency.has_foreign
                    and dependency.absolute or nil
            end
        end
    end
    for _, plan in ipairs(plans) do
        if plan.has_foreign then
            plan.contents = coder.generate_foreign_header(
                plan.modname, plan.ast, { module = plan.modname })
        end
        local ok, err = driver.validate_foreign_header_plan(plan)
        if not ok then return nil, err end
    end
    return plans
end

function driver.write_foreign_header_plans(plans, verbose, pretty_print)
    for _, plan in ipairs(plans or {}) do
        local ok, err = driver.write_foreign_header_plan(
            plan, verbose, pretty_print)
        if not ok then return nil, err end
    end
    return true
end

function driver.prepare_foreign_headers(
        names, imported, verbose, pretty_print)
    local plans, err = driver.plan_foreign_headers(names, imported)
    if not plans then return nil, err end
    return driver.write_foreign_header_plans(plans, verbose, pretty_print)
end

local function prepare_compile(
        modname, ast, sourcef, static_deps, verbose, options)
    if not staticmetadata.valid_module_name(modname) then
        return nil, "invalid logical Titan module name " ..
            string.format("%q", modname)
    end
    local runtime_ok, runtime_err = check_runtime(verbose)
    if not runtime_ok then return nil, runtime_err end
    sourcef = sourcef or modname:gsub("[.]", "/") .. ".titan"
    static_deps = static_deps or {}
    local filename = sourcef:gsub("[.]titan$", "") .. ".c"
    local libname = sourcef:gsub("[.]titan$", "") .. ".o"
    if not ast._foreign_header_prepared then
        local header_plan = driver.plan_foreign_header(modname, ast, sourcef)
        local header_ok, header_err = driver.write_foreign_header_plan(
            header_plan, verbose, options and options.pretty_print)
        if not header_ok then return nil, header_err end
    end
    local code, native_references =
        coder.generate(modname, ast, static_deps, driver.TITAN_ABI_VERSION,
            driver.EMIT_LINE_DIRECTIVES)
    local output_ok, output_err = ensure_output_parent(filename)
    if not output_ok then return nil, output_err end
    os.remove(filename)
    os.remove(libname)
    local ok, err = util.set_file_contents(filename, code)
    if not ok then return nil, err end
    local format_ok, format_err = driver.format_generated_file(
        filename, verbose, options and options.pretty_print)
    if not format_ok then return nil, format_err end
    local args, flags_err = driver.generated_compile_prefix()
    if not args then return nil, flags_err end
    append_argv(args, options and options.extra_compile_flags)
    append_argv(args, { static_flag(), filename })
    append_argv(args, { "-o", libname })
    return {
        args = args,
        libname = libname,
        native_references = native_references,
        generated_bytes = #code,
    }
end

function driver.compile(modname, ast, sourcef, static_deps, verbose, options)
    local prepared, prepare_err = prepare_compile(
        modname, ast, sourcef, static_deps, verbose, options)
    if not prepared then return nil, prepare_err end
    local ok, err = run_argv(prepared.args, verbose)
    if ok then
        return ok, nil, prepared.libname, prepared.native_references
    else
        return nil, err
    end
end

local function protected_remove(path)
    if not path then return true end
    local called, removed, remove_err = pcall(os.remove, path)
    if not called then return nil, removed end
    return removed, remove_err
end

local function replay_compile_output(filename, stream)
    local open_called, file, open_err = pcall(io.open, filename, "rb")
    if not open_called then
        protected_remove(filename)
        return nil, file
    end
    if not file then
        protected_remove(filename)
        return nil, open_err
    end

    local errors = {}
    local read_called, output, read_err = pcall(file.read, file, "*a")
    if not read_called then
        errors[#errors + 1] = "read: " .. tostring(output)
        output = nil
    elseif not output then
        errors[#errors + 1] = "read: " .. tostring(read_err)
    end
    local close_called, closed, close_err = pcall(file.close, file)
    if not close_called then
        errors[#errors + 1] = "close: " .. tostring(closed)
    elseif not closed then
        errors[#errors + 1] = "close: " .. tostring(close_err)
    end
    local removed, remove_err = protected_remove(filename)
    if not removed then
        errors[#errors + 1] = "remove: " .. tostring(remove_err)
    end

    if output and output ~= "" then
        local write_called, written, write_err =
            pcall(stream.write, stream, output)
        if not write_called then
            errors[#errors + 1] = "write: " .. tostring(written)
        elseif not written then
            errors[#errors + 1] = "write: " .. tostring(write_err)
        else
            local flush_called, flushed, flush_err =
                pcall(stream.flush, stream)
            if not flush_called then
                errors[#errors + 1] = "flush: " .. tostring(flushed)
            elseif not flushed then
                errors[#errors + 1] = "flush: " .. tostring(flush_err)
            end
        end
    end
    if #errors ~= 0 then return nil, table.concat(errors, "; ") end
    return true
end

local function create_compile_log()
    local called, path = pcall(os.tmpname)
    if not called then return nil, path end
    if not path then return nil, "os.tmpname returned no path" end
    return path
end

local function create_compile_notification()
    local path, path_err = create_compile_log()
    if not path then return nil, path_err end
    local removed, remove_err = protected_remove(path)
    if not removed then
        return nil, "failed to prepare parallel compiler completion FIFO: " ..
            tostring(remove_err)
    end
    local made, term, code = run_argv({ "mkfifo", "-m", "600", path }, false)
    if not made then
        protected_remove(path)
        return nil, "failed to create parallel compiler completion FIFO" ..
            (code ~= nil and " (" .. tostring(term) .. ", exit " ..
                tostring(code) .. ")" or ": " .. tostring(term))
    end
    -- Linux and Darwin both define a read/write FIFO open to return without a
    -- peer. Keeping that descriptor's writer alive avoids blocking before the
    -- first worker and prevents a transient EOF while a slot is refilled.
    local open_called, file, open_err = pcall(io.open, path, "r+")
    if not open_called then
        protected_remove(path)
        return nil, file
    end
    if not file then
        protected_remove(path)
        return nil, open_err
    end
    local quoted_path, quote_err = cdriver.shell_quote(path)
    if not quoted_path then
        pcall(file.close, file)
        protected_remove(path)
        return nil, quote_err
    end
    return {
        file = file,
        path = path,
        quoted_path = quoted_path,
    }
end

local function close_compile_notification(notification)
    local errors = {}
    local close_called, closed, close_err =
        pcall(notification.file.close, notification.file)
    if not close_called then
        errors[#errors + 1] = "close: " .. tostring(closed)
    elseif not closed then
        errors[#errors + 1] = "close: " .. tostring(close_err)
    end
    local removed, remove_err = protected_remove(notification.path)
    if not removed then
        errors[#errors + 1] = "remove: " .. tostring(remove_err)
    end
    if #errors ~= 0 then
        return nil, "failed to clean parallel compiler completion FIFO (" ..
            table.concat(errors, "; ") .. ")"
    end
    return true
end

local function show_parallel_command(command)
    local write_called, written, write_err =
        pcall(io.stdout.write, io.stdout, command .. "\n")
    if not write_called then return nil, written end
    if not written then return nil, write_err end
    local flush_called, flushed, flush_err =
        pcall(io.stdout.flush, io.stdout)
    if not flush_called then return nil, flushed end
    if not flushed then return nil, flush_err end
    return true
end

local function launch_prepared_compile(
        prepared, verbose, notification, completion_index)
    local command, command_err = command_argv(prepared.args)
    if not command then return nil, command_err end

    local stdout_path, stdout_err = create_compile_log()
    if not stdout_path then return nil, stdout_err end
    local stderr_path, stderr_err = create_compile_log()
    if not stderr_path then
        protected_remove(stdout_path)
        return nil, stderr_err
    end
    local quoted_stdout, quote_err = cdriver.shell_quote(stdout_path)
    if not quoted_stdout then
        protected_remove(stdout_path)
        protected_remove(stderr_path)
        return nil, quote_err
    end
    local quoted_stderr
    quoted_stderr, quote_err = cdriver.shell_quote(stderr_path)
    if not quoted_stderr then
        protected_remove(stdout_path)
        protected_remove(stderr_path)
        return nil, quote_err
    end
    local quoted_index
    quoted_index, quote_err = cdriver.shell_quote(tostring(completion_index))
    if not quoted_index then
        protected_remove(stdout_path)
        protected_remove(stderr_path)
        return nil, quote_err
    end
    if verbose then
        local shown, show_err = show_parallel_command(command)
        if not shown then
            protected_remove(stdout_path)
            protected_remove(stderr_path)
            return nil, show_err
        end
    end
    local notified_command = "(" .. command .. ") >" .. quoted_stdout ..
        " 2>" .. quoted_stderr ..
        "; _titan_compile_status=$?; printf '%s\\n' " .. quoted_index ..
        " >" .. notification.quoted_path ..
        "; exit $_titan_compile_status"
    local popen_called, pipe, popen_err =
        pcall(io.popen, notified_command, "r")
    if not popen_called then
        protected_remove(stdout_path)
        protected_remove(stderr_path)
        return nil, pipe
    end
    if not pipe then
        protected_remove(stdout_path)
        protected_remove(stderr_path)
        return nil, popen_err
    end
    return {
        pipe = pipe,
        stdout_path = stdout_path,
        stderr_path = stderr_path,
    }
end

local function protected_replay_compile_output(filename, stream)
    local called, ok, err = pcall(replay_compile_output, filename, stream)
    if not called then
        protected_remove(filename)
        return nil, ok
    end
    return ok, err
end

local function reap_prepared_compile(process)
    process.finish_errors = {}
    local close_called, ok, term, code =
        pcall(process.pipe.close, process.pipe)
    if not close_called then
        process.finish_errors[#process.finish_errors + 1] =
            "reap: " .. tostring(ok)
        pcall(process.pipe.close, process.pipe)
        ok, term, code = nil, nil, nil
    end
    process.ok = ok
    process.term = term
    process.code = code
    process.reaped = true
end

local function reap_prepared_compile_without_throw(process)
    local called, err = pcall(reap_prepared_compile, process)
    if called then return end
    pcall(process.pipe.close, process.pipe)
    process.finish_errors = {
        "reap: failed to finish parallel C compiler: " .. tostring(err),
    }
    process.ok, process.term, process.code = nil, nil, nil
    process.reaped = true
end

local function finish_prepared_compile(process)
    if not process.reaped then reap_prepared_compile(process) end
    local finish_errors = process.finish_errors

    local stdout_ok, stdout_err = protected_replay_compile_output(
        process.stdout_path, io.stdout)
    if not stdout_ok then
        finish_errors[#finish_errors + 1] =
            "stdout: " .. tostring(stdout_err)
    end
    local stderr_ok, stderr_err = protected_replay_compile_output(
        process.stderr_path, io.stderr)
    if not stderr_ok then
        finish_errors[#finish_errors + 1] =
            "stderr: " .. tostring(stderr_err)
    end
    if #finish_errors ~= 0 then
        return nil, "failed to finish parallel C compiler (" ..
            table.concat(finish_errors, "; ") .. ")"
    end
    return process.ok, process.term, process.code
end

local function finish_prepared_compile_without_throw(process)
    local called, ok, err, code = pcall(finish_prepared_compile, process)
    if called then return ok, err, code end

    -- A final guard for an unexpected Lua exception: reap the child and remove
    -- both logs before allowing the rest of the independent batch to continue.
    if not process.reaped then pcall(process.pipe.close, process.pipe) end
    protected_remove(process.stdout_path)
    protected_remove(process.stderr_path)
    return nil, "failed to finish parallel C compiler: " .. tostring(ok)
end

local function oldest_pending_process(pending, count)
    for index = 1, count do
        if pending[index] then return index, pending[index] end
    end
end

local function run_prepared_compiles(prepared, parallelism, verbose)
    local results = {}
    if parallelism == 1 or #prepared <= 1 then
        for index, compilation in ipairs(prepared) do
            local ok, err, code = run_argv(compilation.args, verbose)
            results[index] = { ok = ok, err = err, code = code }
        end
        return results
    end

    local notification, notification_err = create_compile_notification()
    if not notification then
        for index = 1, #prepared do
            results[index] = { err = notification_err }
        end
        return results
    end

    local schedule = {}
    for index, compilation in ipairs(prepared) do
        schedule[index] = {
            index = index,
            compilation = compilation,
        }
    end
    table.sort(schedule, function(left, right)
        local left_bytes = left.compilation.generated_bytes or 0
        local right_bytes = right.compilation.generated_bytes or 0
        if left_bytes ~= right_bytes then return left_bytes > right_bytes end
        return left.index < right.index
    end)

    local pending = {}
    local processes = {}
    local pending_count = 0
    local next_schedule = 1
    local completion_err
    while (not completion_err and next_schedule <= #schedule) or
            pending_count ~= 0 do
        while not completion_err and pending_count < parallelism and
                next_schedule <= #schedule do
            local entry = schedule[next_schedule]
            local index = entry.index
            local launch_called, process, launch_err = pcall(
                launch_prepared_compile, entry.compilation, verbose,
                notification, index)
            if not launch_called then
                launch_err, process = process, nil
            end
            if process then
                process.index = index
                pending[index] = process
                processes[index] = process
                pending_count = pending_count + 1
            else
                results[index] = { err = launch_err }
            end
            next_schedule = next_schedule + 1
        end
        if pending_count ~= 0 then
            local completed_index, process
            if not completion_err then
                local read_called, line, read_err =
                    pcall(notification.file.read, notification.file, "*l")
                if read_called then
                    completed_index = tonumber(line)
                    process = completed_index and pending[completed_index]
                end
                if not process then
                    completion_err = "failed to receive parallel C compiler " ..
                        "completion: " .. tostring(read_called and
                            (read_err or line) or line)
                end
            end
            if completion_err then
                completed_index, process =
                    oldest_pending_process(pending, #prepared)
            end
            pending[completed_index] = nil
            pending_count = pending_count - 1
            reap_prepared_compile_without_throw(process)
        end
    end

    local notification_ok, cleanup_err =
        close_compile_notification(notification)
    if not notification_ok then
        completion_err = completion_err and
            (completion_err .. "; " .. cleanup_err) or cleanup_err
    end
    if completion_err then
        for schedule_index = next_schedule, #schedule do
            local index = schedule[schedule_index].index
            results[index] = { err = completion_err }
        end
    end

    -- Reaping follows actual completion so a free slot is refilled promptly,
    -- but diagnostics remain deterministic in the original request order.
    for index = 1, #prepared do
        local process = processes[index]
        if process then
            local ok, err, code =
                finish_prepared_compile_without_throw(process)
            if completion_err then
                ok = nil
                err = err and (tostring(err) .. "; " .. completion_err) or
                    completion_err
            end
            results[index] = { ok = ok, err = err, code = code }
        end
    end
    return results
end

local function validate_compile_requests(requests)
    local module_indices = {}
    local outputs = {}
    for index, request in ipairs(requests) do
        assert(type(request) == "table", "each compilation request must be a table")
        assert(type(request.modname) == "string",
            "each compilation request needs a logical module name")
        local previous_index = module_indices[request.modname]
        assert(not previous_index,
            string.format("duplicate compilation request for logical module %q " ..
                "at indices %d and %d", request.modname, previous_index or 0,
                index))
        module_indices[request.modname] = index

        local mod = assert(request.mod,
            "each compilation request needs a module")
        local libname = mod.compiled
        if not libname then
            local sourcef = mod.native_output or mod.filename or
                request.modname:gsub("[.]", "/") .. ".titan"
            assert(type(sourcef) == "string",
                "each compilation request needs a source output path")
            libname = sourcef:gsub("[.]titan$", "") .. ".o"
        end
        assert(type(libname) == "string",
            "each compilation request needs an object output path")
        local output = {
            owner = request.modname,
            raw = absolute_filename(libname),
            normalized = normalized_absolute_filename(libname),
            physical = physical_absolute_filename(libname),
        }
        -- Reject a batch that is safe only on a case-sensitive checkout.
        output.portable = output.physical:lower()
        for _, previous in ipairs(outputs) do
            local aliases = output.normalized == previous.normalized or
                output.physical == previous.physical or
                output.portable == previous.portable or
                same_existing_file(output.raw, previous.raw)
            assert(not aliases,
                string.format("compilation requests for logical modules %q " ..
                    "and %q share object output %q", previous.owner,
                    request.modname, output.normalized))
        end
        outputs[#outputs + 1] = output
    end
end

-- With a bound above one, generate module C serially, launch larger units
-- first, and keep at most `parallelism` compiler processes busy by consuming
-- actual completion notifications. The one-job path retains the historical
-- per-module phase order. Only native object compilations ever overlap.
function driver.compile_modules(requests, parallelism, verbose)
    assert(type(requests) == "table", "requests must be a table")
    assert(type(parallelism) == "number" and parallelism >= 1 and
        parallelism % 1 == 0, "parallelism must be a positive integer")
    validate_compile_requests(requests)

    local results = {}
    if parallelism == 1 then
        for index, request in ipairs(requests) do
            local mod = assert(request.mod)
            if mod.compiled then
                results[index] = {
                    ok = true,
                    libname = mod.compiled,
                    native_references = mod.native_references or {},
                }
            else
                local ok, err, libname = driver.compile_module(
                    request.modname, mod, request.static_deps,
                    verbose, request.options)
                if ok then
                    results[index] = {
                        ok = true,
                        libname = libname,
                        native_references = mod.native_references or {},
                    }
                else
                    results[index] = { err = err }
                end
            end
        end
        return results
    end

    local prepared = {}
    for index, request in ipairs(requests) do
        local mod = assert(request.mod)
        if mod.compiled then
            results[index] = {
                ok = true,
                libname = mod.compiled,
                native_references = mod.native_references or {},
            }
        else
            local compilation, prepare_err = prepare_compile(
                request.modname, mod.ast, mod.native_output or mod.filename,
                request.static_deps, verbose, request.options)
            if not compilation then
                results[index] = { err = prepare_err }
            else
                compilation.request_index = index
                prepared[#prepared + 1] = compilation
            end
        end
    end

    local compiled = run_prepared_compiles(prepared, parallelism, verbose)
    for prepared_index, compilation in ipairs(prepared) do
        local result = compiled[prepared_index]
        local request_index = compilation.request_index
        if result.ok then
            local request = requests[request_index]
            request.mod.compiled = compilation.libname
            request.mod.native_references = compilation.native_references or {}
            results[request_index] = {
                ok = true,
                libname = compilation.libname,
                native_references = request.mod.native_references,
            }
        else
            results[request_index] = { err = result.err }
        end
    end
    return results
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
 * lua_tostring, then __tostring if present and string-valued, otherwise a typed
 * placeholder. */
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

static char titan_main_array_writer_key;

static int titan_main_string_array_writer(lua_State *L) {
    if (lua_type(L, 1) != LUA_TSTRING)
        return luaL_error(L,
            "type error, expected string for standalone arguments");
    lua_settop(L, 1);
    return 1;
}

/* main script launcher, based on srlua */
static int pmain(lua_State *L) {
    int argc = lua_tointeger(L, 1);
    char** argv = lua_touserdata(L, 2);
    int i;

    /* Publish the original process arguments before loading the main module.
     * A transitive titan.uv import may pass them through uv_setup_args and
     * replace the argv pointer in the private registry slot. Keeping that call
     * in titan.uv leaves its canonical shared object as the sole libuv
     * provider. */
    lua_pushinteger(L, argc);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_MAIN_ARGC_KEY);
    lua_pushlightuserdata(L, argv);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_MAIN_ARGV_KEY);

    /* Requiring the main module first initializes every transitive import. An
     * async standard module may install the private bootstrap hook while that
     * happens, but it must not change which main callable this executable
     * invokes. Retrieve main before consulting the hook, then invoke either
     * path inside main()'s existing outer lua_pcall. */
    lua_settop(L, 0);
    lua_getglobal(L, "require");
    lua_pushliteral(L, "$MODNAME");
    lua_call(L, 1, 1);
    lua_getfield(L, -1, "main");
    lua_remove(L, -2);                 /* leave the main callable */

    /* uv_setup_args may return replacement storage. Use the pointer published
     * by titan.uv when constructing the Titan argument table. */
    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_MAIN_ARGV_KEY);
    argv = lua_touserdata(L, -1);
    lua_pop(L, 1);

    {
        lua_Unsigned nargs = argc > 0 ? (lua_Unsigned)(argc - 1) : 0u;
        Table *array_metatable = titan_array_metatable(L);
        TValue writer;
        Table *arguments;
        lua_pushlightuserdata(L, &titan_main_array_writer_key);
        lua_pushcclosure(L, titan_main_string_array_writer, 1);
        writer = lua_totvalue(L, -1);
        lua_pushnil(L);                 /* traced constructor result slot */
        arguments = titan_array_new(
            L, array_metatable, nargs, &writer, L->top.p - 1);
        lua_remove(L, -2);              /* discard writer, keep backing */
        Udata *proxy =
            titan_array_require_proxy(arguments);

        /* Root the canonical proxy/backing cycle before allocating argv
         * strings. The program name is deliberately excluded: Titan's
         * positive-only argument Array is argv[1..argc-1] at indices
         * 1..argc-1, and index 0 remains the private owner backlink. */
        setuvalue(L, s2v(L->top.p - 1), proxy);
        for (i = 1; i < argc; i++) {
            lua_pushstring(L, argv[i]);
            titan_array_set_stack(L, arguments, (lua_Integer)i, -1);
            lua_pop(L, 1);
        }
        titan_array_set_length(arguments, nargs);
    }

    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_MAIN_BOOTSTRAP_KEY);
    if ($SKIP_MAIN_BOOTSTRAP || lua_isnil(L, -1)) {
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
     * errorhandler captures the raw unified Lua+Titan trace into
     * registry[TITAN_BACKTRACE_KEY] and returns the original error object, so it
     * is still available here after lua_pcall. main() then adds the standalone
     * Lua-style presentation: "<progname>: <message>", "stack traceback:", and
     * the raw trace with a tab prepended to each frame line. */
    if (lua_pcall(L, 2, 1, -4) != 0) {
        const char *report;
        if (lua_getfield(L, LUA_REGISTRYINDEX, TITAN_BACKTRACE_KEY) == LUA_TSTRING) {
            const char *trace = lua_tostring(L, -1);
            report_titan_error(errmsg_tostring(L, -2), trace);
        }
        lua_pop(L, 1);                     /* nil/non-string trace slot */
        report = errmsg_tostring(L, -1);
        fatal(report);
    }
    ret = lua_tointeger(L, -1);
    lua_close(L);
    return ret;
}

]]

local function write_entrypoint(modname, entrypoint_c, program_name,
                                options, verbose)
    options = options or {}
    entrypoint_c = entrypoint_c or
        (modname:gsub("[.]", "/") .. "__entrypoint.c")
    local contents = util.render(entrypoint_template, {
        PROGNAME = program_name or modname:gsub(".*[.]", ""),
        LUAOPEN_FN = "luaopen_" .. modname:gsub("[.]", "_"),
        MODNAME = modname,
        SKIP_MAIN_BOOTSTRAP = options.no_uv_bootstrap and "1" or "0",
    })
    local wrote, write_err = util.set_file_contents(entrypoint_c, contents)
    if not wrote then return nil, write_err end
    local formatted, format_err = driver.format_generated_file(
        entrypoint_c, verbose, options.pretty_print)
    if not formatted then return nil, format_err end
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

ensure_output_parent = function(filename)
    local parent = filename:match("^(.*)/[^/]+$")
    if not parent or parent == "" then return true end
    return ensure_directory(parent)
end

function driver.sibling_temporary_path(filename, strategy)
    local unique
    if strategy then
        local temporary_error
        unique, temporary_error = strategy:tmpname()
        if not unique then return nil, temporary_error end
        -- tmpname's contract leaves one caller-owned regular file. Release it
        -- immediately, with no intervening cancellation point at which the
        -- unique path could be lost before ownership reaches the sibling.
        local removed, remove_error = strategy:unlink(unique, true)
        if not removed then return nil, remove_error end
    else
        unique = os.tmpname()
        os.remove(unique)
    end
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
        expected_abi = driver.TITAN_ABI_VERSION,
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
        expected_abi = driver.TITAN_ABI_VERSION,
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
    local ar_args = { "qDc", probe }
    if object then ar_args[#ar_args + 1] = object end
    local ar_d = run_archive_tool(ar, ar_args, verbose)
    if not ar_d then
        os.remove(probe)
        ar_args[1] = "qc"
        local ar_ok, ar_term, ar_code =
            run_archive_tool(ar, ar_args, verbose)
        if not ar_ok then
            os.remove(probe)
            return nil, "configured AR supports neither qDc nor qc (" ..
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
        ar_mode = ar_d and ranlib_d and "qDc" or "qc",
        ranlib_d = ar_d and ranlib_d and true or false,
    }
end

-- run_argv renders argv as one quoted command passed to os.execute, so on
-- POSIX the complete rendering becomes the single `sh -c` argument. Linux
-- limits one argument to 128 KiB independently of its larger ARG_MAX. Keep a
-- deliberately conservative portable ceiling and measure the exact quoted
-- rendering, including a configured multi-word AR command.
local ARCHIVE_SHELL_COMMAND_LIMIT = 64 * 1024

local function shell_argv_size(argv)
    local size = 0
    for index, argument in ipairs(argv) do
        local quoted, quote_err = cdriver.shell_quote(argument)
        if not quoted then return nil, quote_err end
        if index ~= 1 then size = size + 1 end
        size = size + #quoted
    end
    return size
end

local function archive_batches(paths, prefix)
    local batches = {}
    local batch = {}
    local fixed_size, size_err = shell_argv_size(prefix)
    if not fixed_size then return nil, size_err end
    if fixed_size > ARCHIVE_SHELL_COMMAND_LIMIT then
        return nil, "configured AR command prefix exceeds the safe shell " ..
            "command limit"
    end
    local size = fixed_size
    for _, path in ipairs(paths) do
        local quoted, quote_err = cdriver.shell_quote(path)
        if not quoted then return nil, quote_err end
        local contribution = #quoted + 1
        if #batch ~= 0 and
           size + contribution > ARCHIVE_SHELL_COMMAND_LIMIT then
            batches[#batches + 1] = batch
            batch = {}
            size = fixed_size
        end
        if size + contribution > ARCHIVE_SHELL_COMMAND_LIMIT then
            return nil, "archive member path exceeds the safe shell command " ..
                "limit: " .. path
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
    local archive_prefix = copy_argv(ar)
    archive_prefix[#archive_prefix + 1] = capability.ar_mode
    archive_prefix[#archive_prefix + 1] = temporary
    local batches, batch_err = archive_batches(staged_paths, archive_prefix)
    if not batches then return abort(batch_err) end
    for _, batch in ipairs(batches) do
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
    local shared, shared_error = driver.shared_library_flags()
    if not shared then return nil, shared_error end
    append_argv(args, shared)
    -- Darwin otherwise derives LC_ID_DYLIB from the unique staged `-o` path,
    -- while its debug map records volatile input-object modification times.
    -- Use the eventual public identity and reproducible-link mode so unchanged
    -- transactional relinks remain byte-identical and can preserve the
    -- published provider pair's mtimes.
    if driver.IS_DARWIN and install_name then
        append_argv(args, {
            "-Xlinker", "-reproducible",
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
        local dsym_ok, dsym_term, dsym_code =
            run_dsymutil(soname, verbose, install_name ~= nil)
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

local function safe_provider_output_path(provider, extension)
    if not staticmetadata.valid_provider_prefix(provider) then return nil end
    local components = {}
    for component in provider:gmatch("[^.]+") do
        table.insert(components, component)
    end
    return table.concat(components, "/") .. extension
end

local function validate_output_ancestors(filename)
    local normalized = normalized_absolute_filename(filename)
    local parent = normalized:match("^(.*)/[^/]+$")
    local parents = {}
    while parent and parent ~= "" and parent ~= "/" do
        table.insert(parents, 1, parent)
        parent = parent:match("^(.*)/[^/]+$")
    end
    for _, current in ipairs(parents) do
        local attr = lfs.symlinkattributes(current)
        if attr and attr.mode ~= "directory" then
            local followed = attr.mode == "link" and lfs.attributes(current)
            if not followed or followed.mode ~= "directory" then
                return nil, "output parent '" .. current ..
                    "' is not a directory"
            end
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

function driver.validate_program_output_paths(
        source_outputs, executable, entrypoint_c, native_inputs)
    if type(executable) ~= "string" or executable == "" then
        return nil, "standalone executable path must be a nonempty string"
    end
    if type(entrypoint_c) ~= "string" or
       not entrypoint_c:match("[.]c$") then
        return nil, "standalone entrypoint path must end in .c"
    end
    local outputs = {}

    local function below(path, parent)
        return #path > #parent and
            path:sub(1, #parent + 1) == parent .. "/"
    end

    local function add_output(path, owner, mode)
        local ancestors_ok, ancestors_err =
            validate_output_ancestors(path)
        if not ancestors_ok then return nil, ancestors_err end
        local attr = lfs.symlinkattributes(path)
        if attr and attr.mode ~= mode then
            local expected = mode == "directory" and
                "a nonlink directory" or "a regular nonlink file"
            return nil, "program output '" ..
                normalized_absolute_filename(path) .. "' for " .. owner ..
                " is not " .. expected
        end

        local output = {
            path = path,
            owner = owner,
            mode = mode,
            raw = absolute_filename(path),
            normalized = normalized_absolute_filename(path),
            physical = physical_absolute_filename(path),
        }
        output.portable = output.physical:lower()
        for _, previous in ipairs(outputs) do
            if output.normalized == previous.normalized or
               output.physical == previous.physical or
               output.portable == previous.portable or
               same_existing_file(output.raw, previous.raw) then
                return nil, "program output '" .. output.normalized ..
                    "' for " .. owner .. " aliases output for " ..
                    previous.owner
            end
            if below(output.normalized, previous.normalized) or
               below(previous.normalized, output.normalized) or
               below(output.physical, previous.physical) or
               below(previous.physical, output.physical) or
               below(output.portable, previous.portable) or
               below(previous.portable, output.portable) then
                return nil, "program output '" .. output.normalized ..
                    "' for " .. owner ..
                    " has a path hierarchy conflict with output '" ..
                    previous.normalized .. "' for " .. previous.owner
            end
        end
        outputs[#outputs + 1] = output
        return true
    end

    for _, source in ipairs(source_outputs or {}) do
        local stem = assert(source.output):gsub("[.]titan$", "")
        local ok, err = add_output(stem .. ".c",
            "logical module '" .. source.modname .. "'", "file")
        if not ok then return nil, err end
        ok, err = add_output(stem .. ".o",
            "logical module '" .. source.modname .. "'", "file")
        if not ok then return nil, err end
        if source.foreign_header then
            ok, err = add_output(source.foreign_header,
                "generated foreign header for logical module '" ..
                    source.modname .. "'", "file")
            if not ok then return nil, err end
        end
    end
    local ok, err = add_output(
        entrypoint_c, "standalone entrypoint", "file")
    if not ok then return nil, err end
    ok, err = add_output(entrypoint_c:gsub("[.]c$", ".o"),
        "standalone entrypoint", "file")
    if not ok then return nil, err end
    ok, err = add_output(executable, "standalone executable", "file")
    if not ok then return nil, err end
    if driver.IS_DARWIN then
        ok, err = add_output(
            executable .. ".dSYM", "standalone dSYM", "directory")
        if not ok then return nil, err end
    end

    for _, input in ipairs(native_inputs or {}) do
        local path = archive_input_path(input)
        if type(path) == "string" then
            local raw_input = absolute_filename(path)
            local normalized_input = normalized_absolute_filename(path)
            local physical_input = physical_absolute_filename(path)
            local portable_input = physical_input:lower()
            for _, output in ipairs(outputs) do
                if normalized_input == output.normalized or
                   physical_input == output.physical or
                   portable_input == output.portable or
                   same_existing_file(raw_input, output.raw) then
                    return nil, "program output '" .. output.normalized ..
                        "' for " .. output.owner .. " aliases input '" ..
                        normalized_input .. "'"
                end
                if below(normalized_input, output.normalized) or
                   below(output.normalized, normalized_input) or
                   below(physical_input, output.physical) or
                   below(output.physical, physical_input) or
                   below(portable_input, output.portable) or
                   below(output.portable, portable_input) then
                    return nil, "program output '" .. output.normalized ..
                        "' for " .. output.owner ..
                        " has a path hierarchy conflict with input '" ..
                        normalized_input .. "'"
                end
            end
        end
    end
    return true
end

function driver.validate_provider_output_paths(
        public_dso, native_inputs, generated_outputs)
    local public_archive = public_dso:gsub("[.]so$", ".a")
    if public_archive == public_dso then
        return nil, "provider DSO path '" .. tostring(public_dso) ..
            "' does not end in .so"
    end

    local outputs = {}
    local function below(path, parent)
        return #path > #parent
            and path:sub(1, #parent + 1) == parent .. "/"
    end
    local function add_output(path, owner, mode)
        local ancestors_ok, ancestors_err = validate_output_ancestors(path)
        if not ancestors_ok then return nil, ancestors_err end
        local attr = lfs.symlinkattributes(path)
        if attr and attr.mode ~= mode then
            local expected = mode == "directory"
                and "a nonlink directory" or "a regular nonlink file"
            return nil, "native provider output '" ..
                normalized_absolute_filename(path) .. "' for " .. owner ..
                " is not " .. expected
        end
        local output = {
            raw = absolute_filename(path),
            normalized = normalized_absolute_filename(path),
            physical = physical_absolute_filename(path),
            owner = owner,
            mode = mode,
        }
        output.portable = output.physical:lower()
        for _, previous in ipairs(outputs) do
            if output.normalized == previous.normalized
               or output.physical == previous.physical
               or output.portable == previous.portable
               or same_existing_file(output.raw, previous.raw) then
                return nil, "native provider output '" .. output.normalized ..
                    "' for " .. owner .. " aliases output for " ..
                    previous.owner
            end
            if below(output.normalized, previous.normalized)
               or below(previous.normalized, output.normalized)
               or below(output.physical, previous.physical)
               or below(previous.physical, output.physical)
               or below(output.portable, previous.portable)
               or below(previous.portable, output.portable) then
                return nil, "native provider output '" .. output.normalized ..
                    "' for " .. owner ..
                    " has a path hierarchy conflict with output '" ..
                    previous.normalized .. "' for " .. previous.owner
            end
        end
        outputs[#outputs + 1] = output
        return true
    end

    local ok, err = add_output(public_dso, "provider DSO", "file")
    if not ok then return nil, err end
    ok, err = add_output(public_archive, "provider archive", "file")
    if not ok then return nil, err end
    if driver.IS_DARWIN then
        ok, err = add_output(
            public_dso .. ".dSYM", "provider dSYM", "directory")
        if not ok then return nil, err end
    end
    for _, generated in ipairs(generated_outputs or {}) do
        ok, err = add_output(assert(generated.path),
            assert(generated.owner), generated.mode or "file")
        if not ok then return nil, err end
    end

    for _, input in ipairs(native_inputs or {}) do
        local path = archive_input_path(input)
        if type(path) == "string" then
            local raw_input = absolute_filename(path)
            local normalized_input = normalized_absolute_filename(path)
            local physical_input = physical_absolute_filename(path)
            local portable_input = physical_input:lower()
            for _, output in ipairs(outputs) do
                if normalized_input == output.normalized
                   or physical_input == output.physical
                   or portable_input == output.portable
                   or same_existing_file(raw_input, output.raw) then
                    return nil, "native provider output '" ..
                        output.normalized .. "' for " .. output.owner ..
                        " aliases input '" .. normalized_input .. "'"
                end
                if below(normalized_input, output.normalized)
                   or below(output.normalized, normalized_input)
                   or below(physical_input, output.physical)
                   or below(output.physical, physical_input)
                   or below(portable_input, output.portable)
                   or below(output.portable, portable_input) then
                    return nil, "native provider output '" ..
                        output.normalized .. "' for " .. output.owner ..
                        " has a path hierarchy conflict with input '" ..
                        normalized_input .. "'"
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
    local provider_path = safe_provider_output_path(provider, ".so")
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
        link, verbose, extra_objects, validate_titan_support, options)
    options = options or {}
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
    local formatted, format_err = driver.format_generated_file(
        source, verbose, options.pretty_print)
    if not formatted then
        cleanup()
        return nil, format_err
    end

    local compile_args, flags_err = driver.generated_compile_prefix()
    if not compile_args then
        cleanup()
        return nil, flags_err
    end
    append_argv(compile_args, { "-c", source })
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
                                program_output, static_archives,
                                entrypoint_output, program_name, options)
    options = options or {}
    local runtime_ok, runtime_err = check_runtime(verbose)
    if not runtime_ok then return nil, runtime_err end
    local execname = program_output or modname:gsub("[.]", "/")
    local output_ok, output_err = ensure_output_parent(execname)
    if not output_ok then return nil, output_err end
    local entrypoint_name = entrypoint_output or
        (modname:gsub("[.]", "/") .. "__entrypoint.c")
    output_ok, output_err = ensure_output_parent(entrypoint_name)
    if not output_ok then return nil, output_err end
    os.remove(execname)
    local entrypoint_o = entrypoint_name:gsub("[.]c$", ".o")
    os.remove(entrypoint_o)

    local entrypoint_c, err = write_entrypoint(
        modname, entrypoint_name, program_name, options, verbose)
    if err then return nil, err end

    local compile_args
    compile_args, err = driver.generated_compile_prefix()
    if not compile_args then return nil, err end
    append_argv(compile_args, { "-c", entrypoint_c })
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
