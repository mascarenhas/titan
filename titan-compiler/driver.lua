local parser = require  "titan-compiler.parser"
local util = require "titan-compiler.util"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local types = require "titan-compiler.types"
local location = require "titan-compiler.location"
local staticmetadata = require "titan-compiler.staticmetadata"
local cdriver = require "c-parser.cdriver"
local cprobe = require "titan-compiler.cprobe"
local cprobe_cache = require "titan-compiler.cprobe_cache"
local csemantics = require "titan-compiler.csemantics"
local compiler_io = require "titan-compiler.io"
local platform = require "titan-compiler.platform"
local path = require "titan-compiler.path"
local sourceinterface = require "titan-compiler.sourceinterface"
local version = require "titan-compiler.version"
local projectcache = require "titan-compiler.projectcache"
local cacheadapter = require "titan-compiler.cacheadapter"
local foreigncache = require "titan-compiler.foreigncache"
local graphcodec = require "titan-compiler.graphcodec"
local sha256 = require "titan-compiler.sha256"
local ffiheaders = require "titan-compiler.ffiheaders"
local objectmetadata = require "titan-compiler.objectmetadata"
local incremental = require "titan-compiler.incremental"
local documentation = require "titan-compiler.documentation"
local jobs = require "titan-compiler.jobs"
local progress = require "titan-compiler.progress"
local source_selection = require "titan-compiler.source_selection"

local lfs = require "lfs"

local driver = {}
driver._browser_target = require "titan-compiler.browsertarget"
driver.browserlink = require "titan-compiler.browserlink"

driver.imported = {}

-- Logical module names and FQTNs have one process-wide nominal closure.
-- Contexts survive only while that closure belongs to their target generation.
local semantic_target_identity
local semantic_cache_generation = 0

function driver.assert_target_context(context)
    if type(context) ~= "table" or context._semantic_cache_generation == nil then
        error("compiler target context is not initialized", 0)
    end
    if context._semantic_cache_generation ~= semantic_cache_generation then
        error("compiler caches now belong to target " ..
            semantic_target_identity .. "; create a new context", 0)
    end
    return true
end

function driver.activate_target_caches(context, identity)
    if context._semantic_cache_generation ~= nil then
        driver.assert_target_context(context)
    end
    assert(type(identity) == "string" and identity ~= "",
        "semantic cache target identity is required")
    if semantic_target_identity ~= identity then
        -- The first owner adopts tables installed by an embedding host.
        -- A real target change rebinds the complete nominal closure.
        if semantic_target_identity ~= nil then
            driver.imported = {}
            types.registry = {}
        end
        semantic_cache_generation = semantic_cache_generation + 1
        semantic_target_identity = identity
    end
    context._semantic_cache_generation = semantic_cache_generation
    return true
end

-- Compiled-module metadata encodes the monotonic ABI integer as its canonical
-- decimal string. The semantic release and its major/minor library namespace
-- are deliberately independent from that compatibility marker.
driver.TITAN_ABI_VERSION = version.TITAN_ABI_VERSION
driver.TITAN_VERSION = version.TITAN_VERSION
driver.TITAN_LIBRARY_VERSION = version.TITAN_LIBRARY_VERSION
driver.TITAN_LIBRARY_VERSION_SUFFIX = version.TITAN_LIBRARY_VERSION_SUFFIX
driver.LUA_VERSION = version.LUA_VERSION

-- Exact compiler contract consumed by the language server, independent from
-- TITAN_ABI_VERSION. Keep this marker at 1 until Titan's first public release.
-- It covers semantic AST/source manifests, analysis-owned I/O/checkpoints,
-- embedded interfaces/target profiles, exact C-header dependencies and
-- mtime-first observations, and compiler-owned persistent graph payloads.
-- Implementation notes: doc/implementation/driver.md#language-server-compiler-api
driver.LANGUAGE_SERVER_API_VERSION = 1
driver.PROJECT_CACHE_VERSION = projectcache.VERSION

driver.SOURCE_LABELS = source_selection.LABELS
local source_labels = {}
for _, label in ipairs(driver.SOURCE_LABELS) do source_labels[label] = true end

driver.classify_source_filename = source_selection.classify
driver.target_selection_labels = source_selection.target_labels
driver.target_label_applies = source_selection.applies

function driver.encode_project_entry(entry, options)
    return projectcache.encode(entry, options)
end

function driver.compact_project_entry(entry, options)
    return projectcache.compact(entry, options)
end

function driver.decode_project_entry(payload, options)
    return projectcache.decode(payload, options)
end

function driver.project_entries_registry(entries, options)
    return projectcache.registry(entries, options)
end

-- Recovered private signatures are validated with the producer's own direct
-- source capabilities. Keep this loader provenance separate from the public
-- Type.Module projection and from the consumer's symbol-table permissions.
local function source_import_permissions(entry)
    local permissions = {}
    if entry.ast then
        for _, node in ipairs(entry.ast) do
            if not node._ignore and node._tag == "Ast.TopLevelImport"
               and node._source_import then
                permissions[node.modname] = true
            end
        end
    else
        for _, name in ipairs(entry.source_imports or {}) do
            permissions[name] = true
        end
    end
    return permissions
end

function driver.compiler_cache_stats(options)
    local context = options and options.context
    local strategy = context and context.io
    return {
        headers = cdriver.process_cache_stats(strategy),
        conversion = foreigncache.stats(strategy),
    }
end

local perf = {}

function perf.compiler_file_contents(context, filename)
    local read_ok, contents = pcall(incremental.file_contents, context, filename)
    if not read_ok then
        if type(contents) ~= "string" then error(contents, 0) end
        return nil, contents
    end
    return contents
end

local function normalize_absolute_path(path)
    if platform.windows then return platform.path.normalize(path) end
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
    if platform.windows then
        if platform.is_absolute(filename) then
            return platform.absolute(filename, nil, strategy)
        end
        local cwd, cwd_error
        if strategy then cwd, cwd_error = strategy:cwd()
        else cwd, cwd_error = lfs.currentdir() end
        if not cwd then return nil, cwd_error end
        return platform.absolute(filename, cwd, strategy)
    end
    if filename:sub(1, 1) == "/" then return filename end
    if strategy then
        local current_dir, current_err = strategy:cwd()
        if not current_dir then return nil, current_err end
        return current_dir .. "/" .. filename
    end
    return lfs.currentdir() .. "/" .. filename
end

local function normalized_absolute_filename(filename)
    if platform.windows then
        return assert(normalize_absolute_path(assert(absolute_filename(filename))))
    end
    return normalize_absolute_path(absolute_filename(filename))
end

-- Canonicalize the longest existing pathname prefix through the filesystem.
-- This preserves POSIX symlink/.. resolution for alias and containment checks
-- while retaining every not-yet-created destination component.
local function physical_absolute_filename(filename, observe)
    if platform.windows then return normalized_absolute_filename(filename) end
    local raw = absolute_filename(filename)
    local previous = lfs.currentdir()
    local unresolved = {}
    local candidate = raw
    local seen = {}
    local seen_links = {}
    local link_hops = 0
    while candidate and candidate ~= "" and not seen[candidate] do
        seen[candidate] = true
        local attributes
        if observe then attributes = observe(candidate)
        else attributes = lfs.symlinkattributes(candidate) end
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
    if platform.windows then return false end
    local left_attr = lfs.attributes(left)
    local right_attr = lfs.attributes(right)
    return left_attr and right_attr and
        left_attr.dev ~= nil and left_attr.ino ~= nil and
        left_attr.dev == right_attr.dev and left_attr.ino == right_attr.ino
end

local function normalize_root(root, strategy)
    if type(root) ~= "string" or root == "" then return nil end
    if platform.windows then
        local absolute, absolute_error = absolute_filename(root, strategy)
        if not absolute then return nil, absolute_error end
        -- Ordinary Win32 roots apply dot normalization before filesystem
        -- traversal. Preserve that ordinary namespace for installed tools;
        -- handle realpath's extended spelling belongs to physical queries.
        -- Explicit extended roots retain their literal semantics below.
        return normalize_absolute_path(absolute)
    end
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

local function root_join(root, suffix)
    if platform.windows then return assert(platform.join(root, suffix)) end
    if root == "/" then return "/" .. suffix end
    return root .. "/" .. suffix
end

local function append_path(directory, suffix)
    if platform.windows then return assert(platform.join(directory, suffix)) end
    return directory .. "/" .. suffix
end

function driver.installed_paths(root, target)
    root = normalize_root(root)
    if not root then return nil end
    if target == "browser" then
        local titan_lib = root_join(root, "lib/titan-browser/" .. driver.TITAN_LIBRARY_VERSION)
        return {
            root = root, lua_source = root_join(root, "lib/browser/include"),
            include = root_join(root, "include"), lib = root_join(root, "lib/browser"),
            liblua = root_join(root, "lib/browser/liblua.a"),
            lua_record = root_join(root, "lib/browser/liblua-config.txt"),
            libtitan = root_join(titan_lib, "libtitan.a"), titan_bin = titan_lib,
            sdk_digests = root_join(titan_lib, incremental.SDK_DIGESTS),
        }
    end
    local titan_lib = root_join(
        root, "lib/titan/" .. driver.TITAN_LIBRARY_VERSION)
    return {
        root = root,
        lua_source = root_join(root, "src/lua-5.5.1"),
        include = root_join(root, "include"),
        lib = root_join(root, "lib"),
        libtitan = root_join(titan_lib, "libtitan.a"),
        libbacktrace = root_join(root, "lib/libbacktrace.a"),
        liblua = root_join(root, platform.windows and
            "lib/liblua55.a" or "lib/liblua.a"),
        titan_bin = titan_lib,
        sdk_digests = root_join(titan_lib, incremental.SDK_DIGESTS),
    }
end

function driver.source_checkout_from_driver_source(
        source, current_dir, strategy)
    if type(source) ~= "string" then return false end
    if source:sub(1, 1) ~= "@" then return false end
    source = source:sub(2)
    if platform.windows then
        if not platform.is_absolute(source) and not current_dir then
            if strategy then
                local current_error
                current_dir, current_error = strategy:cwd()
                if not current_dir then return false, current_error end
            else
                current_dir = lfs.currentdir()
            end
        end
        local absolute, absolute_error = platform.absolute(source, current_dir, strategy)
        if not absolute then return false, absolute_error end
        local root = absolute:match("^(.*)[/\\]titan%-compiler[/\\]driver[.]lua$")
        if not root then return false end
        local io_strategy = strategy or compiler_io.new_sync()
        local runtime, runtime_error = io_strategy:stat(root_join(root, "titan-runtime/titan.c"))
        if runtime_error then return false, runtime_error end
        local makefile, makefile_error = io_strategy:stat(root_join(root, "Makefile"))
        if makefile_error then return false, makefile_error end
        return runtime and runtime.kind == "file" and
            makefile and makefile.kind == "file" or false
    end
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
    if platform.windows then
        local absolute, absolute_error = absolute_filename(source, strategy)
        if not absolute then return nil, absolute_error end
        source = absolute
    elseif source:sub(1, 1) ~= "/" then
        local current_dir, current_error = strategy:cwd()
        if not current_dir then return nil, current_error end
        source = current_dir .. "/" .. source
    end
    local root = source:match(platform.windows and
        "^(.*)[/\\]titan%-compiler[/\\]driver[.]lua$" or
        "^(.*)/titan%-compiler/driver[.]lua$")
    if root then
        local checkout, checkout_error =
            driver.source_checkout_from_driver_source(
                "@" .. source, nil, strategy)
        if checkout_error then return nil, checkout_error end
        if checkout then return normalize_root(root, strategy) end
    end
    return nil
end

-- Root and Titan path policy come from the native support module, which
-- shares them with the runtime. A missing member means stale native support.
local function support_function(name)
    local loaded, support = pcall(require, "titan")
    if not loaded then
        -- require lists every searched path after its first line.
        return nil, "cannot load the Titan support module: " ..
            tostring(support):match("^[^\n]*")
    end
    local member = type(support) == "table" and support[name]
    if type(member) ~= "function" then
        return nil, "installed Titan native support lacks " .. name ..
            "; reinstall Titan"
    end
    return member
end

-- The compiler SDK root is a non-empty TITAN_ROOT, otherwise the parent of the
-- running interpreter's directory. Selecting it never starts another process.
local function executable_compiler_root()
    local compiler_root, support_error = support_function("_compiler_root")
    if not compiler_root then return nil, support_error end
    local root, root_error = compiler_root()
    if type(root) ~= "string" or root == "" then
        return nil, tostring(root_error)
    end
    return root
end

local explicit_root = platform.getenv("TITAN_ROOT")
if explicit_root == "" then explicit_root = nil end
local probe_prefix = platform.getenv("TITAN_PREFIX")
if probe_prefix == "" then probe_prefix = nil end
local probe_cache_disabled = platform.getenv("TITAN_PROBE_CACHE_DISABLE") == "1"
local configured_installation_root, installation_root_error = explicit_root, nil
if not configured_installation_root then
    configured_installation_root, installation_root_error =
        executable_compiler_root()
end
driver.TITAN_ROOT = configured_installation_root and
    platform.is_absolute(configured_installation_root) and
    normalize_absolute_path(configured_installation_root) or nil
local preliminary_probe_root = probe_prefix and
    platform.is_absolute(probe_prefix) and
    normalize_absolute_path(probe_prefix) or driver.TITAN_ROOT
driver.PROBE_CACHE_DIRECTORY = not probe_cache_disabled and
    preliminary_probe_root and root_join(preliminary_probe_root,
        "var/cache/titan-probes/" .. cprobe_cache.VERSION) or nil
-- A configured Titan path is expanded at lookup time against the current
-- layout's default; nil selects DEFAULT_TITAN_BIN_PATH unexpanded.
driver.TITAN_BIN_PATH =
    platform.getenv("TITAN_PATH" .. driver.TITAN_LIBRARY_VERSION_SUFFIX)
    or platform.getenv("TITAN_PATH")

-- Implementation notes: doc/implementation/driver.md#module-names-and-the-search-paths
function driver.compiler_root(strategy)
    if not configured_installation_root then
        return nil, installation_root_error
    end
    return normalize_root(configured_installation_root, strategy)
end

local function apply_layout(source_root)
    local previous_lua_default = driver._DEFAULT_LUA_SOURCE_PATH
    driver.SOURCE_CHECKOUT_ROOT = source_root
    driver.SOURCE_CHECKOUT = source_root ~= nil
    driver.INSTALLED = not driver.SOURCE_CHECKOUT
    driver.INSTALL_PATHS = driver.installed_paths(driver.TITAN_ROOT)
    driver.INSTALLATION_ERROR = driver.INSTALLED and
        not driver.INSTALL_PATHS and
        ("cannot locate the Titan installation root" ..
            (installation_root_error and (": " .. installation_root_error) or "") ..
            "; set TITAN_ROOT to the installation prefix") or nil

    driver.DEFAULT_TITAN_BIN_PATH = driver.INSTALL_PATHS and
        (".;" .. driver.INSTALL_PATHS.titan_bin) or "."

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
local lexical_source_root = not explicit_root and DRIVER_SOURCE and
    not platform.is_absolute(DRIVER_SOURCE:sub(2)) and
    DRIVER_SOURCE:sub(2):match(platform.windows and
        "^(.*)[/\\]titan%-compiler[/\\]driver[.]lua$" or
        "^(.*)/titan%-compiler/driver[.]lua$") or nil
apply_layout(lexical_source_root)

function driver.initialize_layout(context)
    if type(context) ~= "table" or context.io == nil then
        error("compiler layout initialization requires a resolver context", 2)
    end
    compiler_io.validate(context.io, 2)
    if not context._target_initializing then driver.assert_target_context(context) end
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
    if not explicit_root then
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
            "var/cache/titan-probes/" .. cprobe_cache.VERSION)
    else
        driver.PROBE_CACHE_DIRECTORY = nil
    end
    driver.TOOLCHAIN_ERROR = driver.INSTALLATION_ERROR or
        driver._TOOLCHAIN_FLAGS_ERROR
    context._layout_initialized = true
    return true
end

driver.TITAN_SOURCE_PATH = "."
driver.EMIT_LINE_DIRECTIVES = platform.getenv("TITAN_NO_LINE_DIRECTIVES") ~= "1"
-- Set by the titanc CLI when its live progress renderer owns terminal stderr:
-- build children are captured and replayed above that region. Otherwise build
-- commands inherit stderr; capability probes capture and discard independently.
driver.LIVE_PROGRESS = nil

-- A native batch waits in the private `_jobserver_wait` helper, which blocks
-- until a child finishes and runs no loop, so the live animation timer cannot
-- fire and the spinner freezes for the whole compile or link. While the CLI's
-- live reporter animates, each wait is bounded by one frame period and draws a
-- frame instead, which keeps about ten redraws a second. The hook only calls
-- the reporter: it never runs a loop, so nothing can re-enter the wait. Quiet,
-- plain, verbose and library callers get no hook and keep their blocking wait
-- and their byte-identical output.
local function idle_hook()
    local reporter = driver.LIVE_PROGRESS
    if not reporter or not reporter:animates() then return nil end
    return {
        interval = progress.FRAME_MILLISECONDS,
        tick = function() reporter:tick() end,
    }
end

driver.TITAN_RUNTIME_PATH = "titan-runtime/"
driver.LIBBACKTRACE_PATH = "libbacktrace"
driver.BUILD_PROFILE = platform.getenv("TITAN_BUILD_PROFILE") or "production"
local profile_error
if driver.BUILD_PROFILE ~= "production" and driver.BUILD_PROFILE ~= "validation" then
    profile_error = "TITAN_BUILD_PROFILE must be production or validation"
end
local profile_flags = driver.BUILD_PROFILE == "validation" and "-O0 -fno-lto" or "-O3"
-- Keep function DWARF for backtraces. Compiler-specific debug defaults are
-- selected lazily when a native command is needed, never during module load.
local base_cflags = "--std=c99 " .. profile_flags .. " -Wall -Wno-unused-but-set-variable -Wno-unused-function -fPIC"
local default_cflags = base_cflags .. " -g"
driver.CFLAGS = default_cflags

driver.CC = platform.getenv("CC") or (platform.windows and "clang.exe" or "cc")
driver.AR = platform.getenv("AR") or "ar"
driver.RANLIB = platform.getenv("RANLIB") or "ranlib"
driver.CLANG_FORMAT = platform.getenv("CLANG_FORMAT") or "clang-format"

driver.split_shell_words = cdriver.split_shell_words
driver.shell_quote = cdriver.shell_quote

local function parse_extra_flags(name)
    local words, err = cdriver.split_shell_words(platform.getenv(name) or "")
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
driver._TOOLCHAIN_FLAGS_ERROR = profile_error or cppflags_error or cflags_error or ldflags_error
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

local function select_platform_defaults(uname, is_darwin, compiler_family)
    local debug_flags = "-g"
    if driver.BUILD_PROFILE == "production" then
        if compiler_family == "gcc" then
            debug_flags = "-g1"
        elseif compiler_family == "clang" then
            -- Profiling records retain ordinary function names that Clang's
            -- line tables alone omit, without local-variable debug records.
            debug_flags = "-gline-tables-only -fdebug-info-for-profiling"
        end
    end
    local defaults = base_cflags .. " " .. debug_flags
    if uname == "Linux" and driver.BUILD_PROFILE == "production" then
        -- Fat objects retain the native sections needed by the metadata and
        -- target readers, plus IR for GCC/Clang's optimizing final link.
        defaults = defaults .. " -flto=auto -ffat-lto-objects"
    end
    if driver.CFLAGS == default_cflags then driver.CFLAGS = defaults end
    default_cflags = defaults
    driver.UNAME = uname
    driver.IS_DARWIN = is_darwin
end

-- Browser state is context-owned. Native process globals remain a host profile.
function driver._finish_target_initialization(context)
    if context.target == "browser" then
        if driver.EMIT_LINE_DIRECTIVES == false then
            return nil, "browser target owns option --no-line-directives (TITAN_NO_LINE_DIRECTIVES)"
        end
        -- Embedded inventories describe native host code and native C facts.
        -- Drop the complete state at the target boundary, before any browser
        -- descriptor/probe or resolver consumer can observe it.
        context.embedded_interface_provider = nil
        context.embedded_interface_provider_rejected = false
        context.embedded_interface_provider_overlap = nil
        context.used_embedded_target_profile_identity = nil
        if context.host_target ~= "linux" and context.host_target ~= "darwin" then
            return nil, "browser builds are supported from Linux and macOS hosts (host is " ..
                tostring(context.host_target) .. ")"
        end
        if not context.target_descriptor then
            for _, item in ipairs({
                { driver.EXTRA_CPPFLAGS, "TITAN_EXTRA_CPPFLAGS" },
                { driver.EXTRA_CFLAGS, "TITAN_EXTRA_CFLAGS" },
                { driver.EXTRA_LDFLAGS, "TITAN_EXTRA_LDFLAGS" },
                { driver.NATIVE_COMPILE_FLAGS, "--cflag" },
                { driver.NATIVE_LINK_FLAGS, "--ldflag" },
            }) do
                local valid, err = driver._browser_target.validate_flags(item[1], item[2])
                if not valid then return nil, err end
            end
            local paths = driver.installed_paths(driver.TITAN_ROOT, "browser")
            if not paths then
                return nil, "cannot locate the Titan installation root; set TITAN_ROOT to the installation prefix"
            end
            local probe_cache_directory
            if not probe_cache_disabled then
                local cache_root, cache_error = normalize_root(probe_prefix or driver.TITAN_ROOT, context.io)
                if not cache_root then return nil, cache_error end
                probe_cache_directory = root_join(cache_root, "var/cache/titan-probes/browser-" ..
                    driver._browser_target.EMSCRIPTEN_VERSION .. "/" .. cprobe_cache.VERSION)
            end
            local runtime_include = driver.SOURCE_CHECKOUT_ROOT and
                root_join(driver.SOURCE_CHECKOUT_ROOT, "titan-runtime") or paths.include
            local extras = {}
            if driver.NATIVE_COMPILE_FLAGS then
                for _, flag in ipairs(driver.NATIVE_COMPILE_FLAGS) do extras[#extras + 1] = flag end
            else
                for _, flag in ipairs(driver.EXTRA_CPPFLAGS or {}) do extras[#extras + 1] = flag end
                for _, flag in ipairs(driver.EXTRA_CFLAGS or {}) do extras[#extras + 1] = flag end
            end
            -- Measurement optimization is part of the descriptor, not a
            -- coordinator-only argv suffix: probes and imported workers must
            -- compile and certify exactly the same configuration.
            local optimization = driver.browser_link_options and driver.browser_link_options.optimization
            if optimization == "O1" or optimization == "O2" then
                extras[#extras + 1] = "-" .. optimization
            end
            local descriptor, err = driver._browser_target.build(context, {
                paths = paths, runtime_include = runtime_include, compile_flags = extras,
                build_profile = driver.BUILD_PROFILE,
                trace_control = driver.browser_link_options and
                    (driver.browser_link_options.purpose == "baseline" or
                     driver.browser_link_options.purpose == "minicoro" or
                     driver.browser_link_options.purpose == "budget"),
                probe_cache_directory = probe_cache_directory,
            })
            if not descriptor then return nil, err end
            if driver.browser_link_options then
                -- The image kind is not known yet (the driver learns it when
                -- it links), so only the options' shape is checked here; the
                -- kind check happens in browser_link_plan.
                if driver.browser_link_options.purpose == nil then
                    return nil, "browser link profile options require a purpose"
                end
                local plan, profile_error = driver.browserlink.profile(descriptor, driver.browser_link_options)
                if not plan then return nil, profile_error end
            end
            context.target_descriptor = descriptor
        end
        if not context.target_profile then
            local profile, err = csemantics.import_profile(
                driver._browser_target.export(context.target_descriptor.profile_data))
            if not profile then return nil, err end
            context.target_profile = profile
        end
    end
    driver.activate_target_caches(context,
        context.target_descriptor and context.target_descriptor.identity or context.target)
    return true
end

function driver.context_target_descriptor(context)
    if context == nil then return nil end
    driver.assert_target_context(context)
    if context.target ~= "browser" then return nil end
    local ok, err = driver.initialize_platform(context)
    if not ok then return nil, err end
    return context.target_descriptor
end

-- The link purpose of the image this context is building. A `--test` build
-- links a test image, and every other program link is a program image; harness
-- purposes (protocol, gate, minicoro, budget, baseline) are not image kinds.
function driver.browser_link_kind(context)
    return context and context.link_kind == "test" and "test" or "program"
end

-- Certify and link an image under its own kind's profile. A requested purpose
-- may only be a harness purpose or agree with the link kind: a test image that
-- was certified or linked as a program image would lose the frame-preserving
-- profile silently, so a disagreement is an error, not an override.
function driver.browser_link_purpose(context, purpose)
    if purpose == nil then return driver.browser_link_kind(context) end
    if (purpose == "program" or purpose == "test") and context and
            context.link_kind ~= nil and purpose ~= driver.browser_link_kind(context) then
        return nil, "browser link purpose " .. string.format("%q", purpose) ..
            " does not match this " .. driver.browser_link_kind(context) .. " image"
    end
    return purpose
end

function driver.browser_link_plan(context, purpose)
    local descriptor, err = driver.context_target_descriptor(context)
    if not descriptor then return nil, err end
    local options = driver.browser_link_options
    -- The requested purpose and the preset are both checked, because the
    -- preset is what the link and its certificate consume: a caller passing
    -- the image kind must not hide a contrary preset purpose.
    local resolved
    resolved, err = driver.browser_link_purpose(context, purpose)
    if not resolved then return nil, err end
    if options == nil then
        options = { purpose = resolved, assertions = 2 }
    elseif options.purpose == nil then
        -- A harness that presets link options must say which profile it wants;
        -- inheriting the image kind would silently give a measurement build a
        -- program or test image's flags.
        return nil, "browser link profile options require a purpose"
    else
        local preset
        preset, err = driver.browser_link_purpose(context, options.purpose)
        if not preset then return nil, err end
    end
    return driver.browserlink.profile(descriptor, options)
end

function driver.require_browser_sdk(context)
    local descriptor, err = driver.context_target_descriptor(context)
    if not descriptor then return nil, err end
    local rocks_tree = platform.getenv("ROCKS_TREE")
    if rocks_tree == "" then rocks_tree = nil end
    return driver.browserlink.require_sdk(context, descriptor, {
        prefix = driver.INSTALL_PATHS and driver.INSTALL_PATHS.root or descriptor.paths.root,
        rocks_tree = rocks_tree,
    })
end

function driver.browser_program_path(stem, explicit)
    local filename = explicit or (stem .. ".mjs")
    if not filename:match("[.]mjs$") then
        return nil, "browser executable output " .. string.format("%q", filename) .. " must end in .mjs"
    end
    local wasm = filename:gsub("[.]mjs$", ".wasm")
    return filename, wasm
end

function driver.context_target_identity(context)
    local descriptor, err = driver.context_target_descriptor(context)
    if err then return nil, err end
    if descriptor then return descriptor.identity end
    return driver.context_target(context)
end

local function initialize_source_target(context)
    context.host_target = context.uname == "Windows" and "windows" or
        context.uname == "Linux" and "linux" or
        context.is_darwin and "darwin" or "native"
    context.target = context.target or context.host_target
end

function perf.native_platform(strategy)
    if platform.windows then return "Windows", false end
    local result = strategy:run({ "uname" }, { stderr_to_stdout = true })
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
    return uname, uname:match("Darwin") ~= nil
end

function driver.initialize_platform(context)
    if type(context) ~= "table" or context.io == nil then
        error("platform initialization requires a resolver context", 2)
    end
    compiler_io.validate(context.io, 2)
    if not context._target_initializing then driver.assert_target_context(context) end
    if context._platform_initialized then
        initialize_source_target(context)
        if context.target ~= "browser" then select_platform_defaults(context.uname, context.is_darwin) end
        local ready, err = driver._finish_target_initialization(context)
        if not ready then return nil, err end
        return true, context.uname, context.is_darwin
    end

    local uname, is_darwin = perf.native_platform(context.io)
    if not uname then return nil, is_darwin end
    context.uname, context.is_darwin = uname, is_darwin
    context._platform_initialized = true
    initialize_source_target(context)

    -- Native publication retains its historical process-visible host fields.
    if context.target ~= "browser" then select_platform_defaults(uname, context.is_darwin) end
    local ready, err = driver._finish_target_initialization(context)
    if not ready then return nil, err end
    return true, uname, context.is_darwin
end

function driver.context_target(context)
    if type(context) == "table" and context.io and context.target then
        driver.assert_target_context(context)
        return context.target
    end
    local ok, err = driver.initialize_platform(context)
    if not ok then return nil, err end
    return context.target
end

function driver.validate_target(context, value, origin)
    local ok, err = driver.initialize_platform(context)
    if not ok then return nil, err end
    if value == nil or value == "" then return context.host_target end
    local prefix = origin == "TITAN_TARGET" and "TITAN_TARGET=" .. value or
        (origin or "--target") .. " " .. value
    if value == "native" then
        return nil, prefix .. ": 'native' selects source files for native hosts; " ..
            "it is not a compilation target"
    elseif value == "browser" then
        if context.host_target ~= "linux" and context.host_target ~= "darwin" then
            return nil, "browser builds are supported from Linux and macOS hosts (host is " ..
                context.host_target .. ")"
        end
        return value
    elseif value == "linux" or value == "darwin" or value == "windows" then
        if value == context.host_target then return value end
        return nil, prefix .. ": native cross-compilation is not supported " ..
            "(host is " .. context.host_target .. ")"
    end
    return nil, prefix .. ": unknown target '" .. value ..
        "': expected linux, darwin, windows or browser"
end

function driver.configure_foreign_c(context)
    if type(context) ~= "table" or context.io == nil then
        error("foreign C configuration requires a resolver context", 2)
    end
    compiler_io.validate(context.io, 2)
    driver.assert_target_context(context)
    local io_strategy = context.io
    local platform_ok, platform_result = driver.initialize_platform(context)
    local platform_err = not platform_ok and platform_result or nil
    if not platform_ok then return nil, platform_err end
    if context.target_descriptor then
        context.foreign_c_profile_error = nil
        context.foreign_c_configuration_id = driver.FOREIGN_C_CONFIGURATION_ID
        return true
    end

    -- Configuration is replaceable in embeddings and tests. A profile belongs
    -- to one exact compiler identity and must never survive a reconfiguration.
    driver.TARGET_PROFILE = nil
    local toolchain, toolchain_err
    if driver.toolchain_descriptor then
        toolchain, toolchain_err = driver.toolchain_descriptor(context)
    end
    local options = {
        io = io_strategy,
        cache_adapter = context.cache_adapter,
        header_observations = context.header_observations,
        process_trace = context.c_header_process_trace,
        process_analysis = context.c_header_analysis,
        compiler = driver.CC,
        language_mode = "c99",
        cppflags = toolchain and {} or (driver.EXTRA_CPPFLAGS or {}),
        compile_flags = toolchain and toolchain.compile_flags or {},
        compiler_include_dirs = driver.foreign_include_dirs(),
        toolchain = toolchain,
        probe_cache_directory = driver.PROBE_CACHE_DIRECTORY,
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
    options.cache_adapter = nil
    options.header_observations = nil
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
       not platform.is_absolute(provider_file) or
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

-- A context without a caller adapter digests through the native support
-- library when it is loadable, as titanc does: certified-file identities
-- otherwise rehash the compiler inventory in Lua for every context. A host
-- without that library keeps the dependency-free Lua digest. The adapter is
-- digest-only and offers no storage.
local function default_digest_adapter()
    local loaded, support = pcall(require, "titan")
    if not loaded or type(support) ~= "table" or
       type(support._sha256_binary) ~= "function" then
        return nil
    end
    local stream = support._sha256_stream
    return { sha256_binary = support._sha256_binary,
        sha256_stream = type(stream) == "function" and stream or nil }
end

-- Implementation notes: doc/implementation/driver.md#drivernew_resolver_contextoptions
function driver._new_resolver_context(options, target_descriptor)
    options = options or {}
    if type(options) ~= "table" then
        error("resolver context options must be a table", 2)
    end
    if options.target ~= nil and options.target ~= "" and
       not source_labels[options.target] then
        error("invalid source selection target '" .. tostring(options.target) .. "'", 2)
    end
    local cache_valid, cache_error = cacheadapter.validate(options.cache_adapter)
    if not cache_valid then error(cache_error, 2) end
    local embedded_interface_provider, embedded_error
    if options.target ~= "browser" then
        embedded_interface_provider, embedded_error =
            validate_embedded_interface_provider(options.embedded_interface_provider)
    end
    if embedded_error then
        error("invalid embedded_interface_provider: " .. embedded_error, 2)
    end
    local io_strategy = options.io
    if io_strategy == nil then io_strategy = compiler_io.new_sync() end
    compiler_io.validate(io_strategy, 2)
    if options.output_root then
        -- Retain the caller's I/O authority, while keeping checking headers
        -- and transient probe payloads under the invocation's output folder.
        -- Persistent probe-cache identities and destinations do not change.
        local underlying = io_strategy
        io_strategy = setmetatable({}, { __index = underlying })
        function io_strategy:tmpname()
            local reserved, reserve_error = underlying:tmpname()
            if not reserved then return nil, reserve_error end
            local relocated = path.join(options.output_root,
                ".titan-temporary-" .. path.basename(reserved))
            local removed, remove_error = underlying:unlink(reserved)
            if not removed then return nil, remove_error end
            -- The system temporary directory can be on another filesystem or
            -- Windows drive. Create the reservation at its final destination;
            -- write_file already stages atomically beside that destination.
            local written, write_error = underlying:write_file(relocated, "")
            if not written then return nil, write_error end
            return relocated
        end
    end
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
    -- The invocation's local native job cap (titanc's resolved --jobs). It
    -- bounds the speculative C probe batches of this resolver's checks; an
    -- absent cap or 1 keeps every probe synchronous.
    local jobs_cap = options.jobs
    if jobs_cap ~= nil and (math.type(jobs_cap) ~= "integer" or jobs_cap < 1) then
        error("jobs must be a positive integer", 2)
    end
    -- The real command-line script that loaded this compiler, or "api" for
    -- embedding callers. Only the configuration certificate consumes it.
    local frontend = options.frontend
    if frontend ~= nil and (type(frontend) ~= "string" or frontend == "") then
        error("frontend must be a nonempty path", 2)
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
        _target_initializing = true,
        target_descriptor = target_descriptor,
        io = io_strategy,
        target = options.target ~= "" and options.target or nil,
        cache_adapter = options.cache_adapter or default_digest_adapter(),
        header_observations = cdriver.header_observation_index(options.header_inputs),
        prefer_static = options.prefer_static == true,
        source_first = options.source_first == true,
        analysis_only = options.analysis_only == true,
        completion = options.completion,
        transient_caches = options.transient_caches == true,
        completion_closed_world = options.completion_closed_world == true,
        provider_cache = {},
        decoded_provider_cache = {},
        provider_cache_identity = {},
        contextual_types = {},
        contextual_resolutions = {},
        native_interface_types = {},
        nominal_layouts = {},
        nominal_layout_inventories = {},
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
        output_root = options.output_root,
        jobs = jobs_cap,
        frontend = frontend,
        -- One shared C-input revalidation pass for every certification in
        -- this invocation: each recorded header is checked at most once.
        header_validation = {},
    }
    local initialized, layout_error = driver.initialize_layout(context)
    if not initialized then
        context._target_initializing = nil
        error("cannot initialize compiler layout: " .. tostring(layout_error), 2)
    end
    if context.target and context.target ~= "browser" then
        driver.activate_target_caches(context, context.target)
    else
        local target_error
        initialized, target_error = driver.initialize_platform(context)
        if not initialized then
            context._target_initializing = nil
            driver.close_resolver_context(context)
            error(target_error, 0)
        end
    end
    context.relocation_roots = require("titan-compiler.relocation").roots(context.io, {
        sdk = configured_installation_root,
        compiler = driver.SOURCE_CHECKOUT_ROOT,
        output = context.output_root,
    })
    context._target_initializing = nil
    return context
end

function driver.new_resolver_context(options)
    return driver._new_resolver_context(options)
end

local function remember_used_compiled_interface(context, modname, modtype)
    context.used_compiled_interfaces =
        context.used_compiled_interfaces or {}
    local used = context.used_compiled_interfaces[modname]
    if not used then
        used = {}
        context.used_compiled_interfaces[modname] = used
    end
    -- Programmatic loaders can reuse and mutate a type descriptor. Preserve
    -- the semantics of every returned view, not only its current identity.
    used[types.serialize_semantic(modtype)] = true
end

-- Implementation notes: doc/implementation/source-import-visibility.md#loader-result-and-module-views
local function check_used_compiled_interface(
        context, modname, source_type, errors)
    if #errors ~= 0 then return end
    local used = context.used_compiled_interfaces and
        context.used_compiled_interfaces[modname]
    if not used then return end
    local source_interface = types.serialize_semantic(source_type)
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

function perf.tool_command(configured, label)
    local command, err = parsed_words(configured, label)
    if not command then return nil, err end
    -- A POSIX tool prefix may replace its command shell with this builtin.
    -- It is not an executable, so execution and identity use the same argv.
    if not platform.windows and command[1] == "exec" then
        table.remove(command, 1)
    end
    if #command == 0 then return nil, label .. " command is empty" end
    return command
end

local function command_argv(argv)
    if platform.windows then return platform.windows_command(argv, false) end
    local quoted = {}
    for i, arg in ipairs(argv) do
        local word, err = cdriver.shell_quote(arg)
        if not word then return nil, err end
        quoted[i] = word
    end
    return table.concat(quoted, " ")
end

local function rename_output(from, to)
    return compiler_io.new_sync():rename(from, to)
end

local function run_argv(argv, verbose, discard_output)
    local cmd, err = command_argv(argv)
    if not cmd then return nil, err end
    if verbose then io.stderr:write(cmd, "\n") end
    if discard_output or driver.LIVE_PROGRESS then
        -- Capability checks discard expected tool rejections even without a
        -- progress renderer. Other children replay captured output above the
        -- live region. Both paths preserve the command's exit status.
        local captured
        if platform.windows then
            captured = require("titan-compiler.process").capture(argv)
        else
            captured = require("titan-compiler.process").capture(
                { "/bin/sh", "-c", cmd }, {
                    inherit = driver.OUTPUT_LOCKS and
                        driver.OUTPUT_LOCKS:descriptors() or nil,
                })
        end
        if not discard_output and captured.output and captured.output ~= "" then
            driver.LIVE_PROGRESS:write(captured.output)
        end
        if not captured.started then
            if not discard_output and captured.diagnostic then
                driver.LIVE_PROGRESS:write(captured.diagnostic .. "\n")
            end
            return nil, "exit", 127
        end
        return captured.ok and true or nil, captured.why, captured.status
    end
    if platform.windows then return require("titan-compiler.process").run(argv) end
    if driver.OUTPUT_LOCKS then
        -- The coordinator's descriptors are close-on-exec. Give synchronous
        -- native writers the same leases as scheduler jobs, including shell
        -- wrappers and their descendants after the coordinator has died.
        return require("titan-compiler.process").run({ "/bin/sh", "-c", cmd }, {
            inherit = driver.OUTPUT_LOCKS:descriptors(),
        })
    end
    return os.execute(cmd)
end

-- Keep the configured compiler/wrapper prefix outside the response file.
-- Only Windows links need this transport; ordinary compile/tool commands and
-- every POSIX command retain their existing execution and diagnostics.
function driver.run_link_command(argv, verbose, output)
    if not platform.windows then return run_argv(argv, verbose) end
    if type(argv) ~= "table" or #argv == 0 then
        return nil, "link command must be a nonempty argument array"
    end
    local count = #argv
    for index = 1, count do
        if argv[index] == nil then
            return nil, "link command must be a dense argument array"
        end
    end
    for key in pairs(argv) do
        if type(key) ~= "number" or key < 1 or key > count or key % 1 ~= 0 then
            return nil, "link command must be a dense argument array"
        end
    end
    local command, err = perf.tool_command(driver.CC, "CC")
    if not command then return nil, err end
    for index = 1, #command do
        if argv[index] ~= command[index] then
            return nil, "link command does not match the configured CC command prefix"
        end
    end
    local arguments = { table.unpack(argv, #command + 1) }
    local contents
    contents, err = platform.windows_response_contents(arguments)
    if not contents then return nil, err end
    local response
    response, err = driver.sibling_temporary_path(output .. ".link.rsp")
    if not response then return nil, err end
    local file
    file, err = io.open(response, "wb")
    if not file then return nil, "failed to open link response file: " .. tostring(err) end
    local wrote, write_error = file:write(contents)
    local closed, close_error = file:close()
    if not wrote or not closed then
        os.remove(response)
        return nil, "failed to write link response file: " ..
            tostring(write_error or close_error)
    end
    command[#command + 1] = "@" .. response
    local called, ok, term, code = pcall(function()
        if verbose then
            local shown, show_error = command_argv(argv)
            if not shown then return nil, show_error end
            io.stderr:write(shown, "\n")
        end
        return run_argv(command, verbose)
    end)
    local removed, remove_error = os.remove(response)
    if not called then ok, term, code = nil, ok, nil end
    if not removed then
        return nil, (ok and "" or (tostring(term) .. "; ")) ..
            "failed to remove link response file '" .. response .. "': " ..
            tostring(remove_error), code
    end
    return ok, term, code
end

function driver.format_generated_file(
        filename, verbose, pretty_print, strategy, coverage_mode)
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
        local style = coverage_mode and
            "--style={BasedOnStyle: LLVM, IndentWidth: 4, SortIncludes: false, CommentPragmas: '^ TITAN_COVERAGE_'}" or
            "--style={BasedOnStyle: LLVM, IndentWidth: 4, SortIncludes: false}"
        append_argv(args, {
            "-i",
            style,
            "--",
            filename,
        })
        local ok, term, code
        if strategy then
            if verbose then io.stderr:write(assert(command_argv(args)), "\n") end
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
    -- Ordinary source maps place statements immediately after their directive.
    -- Coverage converts its region markers after formatting; authored C keeps
    -- its own physical-line progression, including blank lines after #line.
    local normalized = contents
    if not coverage_mode then
        local removed
        repeat
            normalized, removed = normalized:gsub(
                "([ \t]*#line[^\n]*\n)[ \t]*\n", "%1")
        until removed == 0
    end
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

local compiler_family_caches = setmetatable({}, { __mode = "k" })
local compiler_family_io

function perf.initialize_native_platform(context)
    if context then return driver.initialize_platform(context) end
    if type(driver.UNAME) == "string" and type(driver.IS_DARWIN) == "boolean" then
        return true
    end
    -- Native object/publication helpers need host flags, not semantic caches
    -- or resolver-owned probe services. Sync operations close their own I/O.
    compiler_family_io = compiler_family_io or compiler_io.new_sync()
    local uname, is_darwin = perf.native_platform(compiler_family_io)
    if not uname then return nil, is_darwin end
    select_platform_defaults(uname, is_darwin)
    return true
end

local function compiler_family(cc, strategy)
    local key_parts = {}
    for _, argument in ipairs(cc) do
        key_parts[#key_parts + 1] = #argument .. ":" .. argument
    end
    local key = table.concat(key_parts)
    local cache = compiler_family_caches[strategy]
    if cache and cache[key] then return cache[key] end

    -- This header-free bootstrap cannot use toolchain_descriptor/cprobe: their
    -- compile prefix already needs the compiler-specific defaults chosen here.
    local argv = { table.unpack(cc) }
    append_argv(argv, { "-dM", "-E", "-x", "c",
        platform.windows and "NUL" or "/dev/null" })
    local result = strategy:run(argv, { stderr_to_stdout = true })
    if type(result) ~= "table" or not result.started or not result.ok then
        local detail = type(result) == "table" and
            (result.diagnostic or result.output) or result
        return nil, "cannot identify C compiler family: " ..
            tostring(detail or "command failed")
    end
    local gcc, clang = false, false
    for line in tostring(result.output or ""):gmatch("[^\r\n]+") do
        local name = line:match("^%s*#%s*define%s+([%w_]+)")
        if name == "__clang__" then clang = true
        elseif name == "__GNUC__" then gcc = true end
    end
    local family = clang and "clang" or gcc and "gcc" or "unknown"
    if not cache then
        cache = {}
        compiler_family_caches[strategy] = cache
    end
    cache[key] = family
    return family
end

-- Titan-owned C consumes the controlled Windows Lua DLL: its public and
-- internal symbols are named imports, and MinGW auto-import is not part of the
-- contract. User-authored --c-source helpers keep stock Lua conventions.
local WINDOWS_LUA_DLL_IMPORTS = {
    "-DLUA_BUILD_AS_DLL",
    "-DLUAI_FUNC=__declspec(dllimport) extern",
    "-DLUAI_DDEC(dec)=__declspec(dllimport) extern dec",
    "-DLUAI_DDEF=",
}

local function compiler_argv(include_extra_compile_flags, context, user_c_helper)
    if context and context.target == "browser" then
        local descriptor, err = driver.context_target_descriptor(context)
        if not descriptor then return nil, err end
        local args = { table.unpack(descriptor.tools.cc) }
        append_argv(args, descriptor.compile_flags)
        return args
    end
    if driver.TOOLCHAIN_ERROR then return nil, driver.TOOLCHAIN_ERROR end
    local initialized, platform_error = perf.initialize_native_platform(context)
    if not initialized then return nil, platform_error end
    local cc, err = perf.tool_command(driver.CC, "CC")
    if not cc then return nil, err end
    if driver.BUILD_PROFILE == "production" and driver.CFLAGS == default_cflags then
        local strategy = context and context.io
        if not strategy then
            -- Object/link APIs have no resolver argument. Reuse their one lazy
            -- synchronous strategy so every object does not repeat this probe.
            compiler_family_io = compiler_family_io or compiler_io.new_sync()
            strategy = compiler_family_io
        end
        local family
        family, err = compiler_family(cc, strategy)
        if not family then return nil, err end
        select_platform_defaults(driver.UNAME, driver.IS_DARWIN, family)
    end
    local cflags
    cflags, err = parsed_words(driver.CFLAGS, "compiler defaults")
    if not cflags then return nil, err end
    local argv = {}
    append_argv(argv, cc)
    -- Normalized invocation extras (TITAN_EXTRA_* then CLI switches, in
    -- order) follow the profile defaults; without them the ambient
    -- environment flags keep their historical placement.
    local native = driver.NATIVE_COMPILE_FLAGS
    if include_extra_compile_flags and not native then
        append_argv(argv, driver.EXTRA_CPPFLAGS)
    end
    append_argv(argv, cflags)
    if driver.UNAME == "Windows" and not user_c_helper then
        append_argv(argv, WINDOWS_LUA_DLL_IMPORTS)
    end
    if include_extra_compile_flags then
        append_argv(argv, native or driver.EXTRA_CFLAGS)
    end
    return argv
end

local function append_compile_includes(args, context)
    local descriptor = context and context.target_descriptor
    for _, directory in ipairs(descriptor and descriptor.include_dirs or driver.foreign_include_dirs()) do
        append_argv(args, { "-I", directory })
    end
end

-- Exact command prefix shared by every generated C object compile. The
-- descriptor below represents this as compiler argv + compile flags + ordered
-- include roots; cprobe/cdriver reconstruct the same sequence before adding
-- their private source/output arguments.
function driver.generated_compile_prefix(context)
    local args, err = compiler_argv(true, context)
    if not args then return nil, err end
    append_compile_includes(args, context)
    return args
end

-- Authored --c-source helpers are the user's own C: they compile with stock
-- Lua conventions and never receive Titan's Windows DLL import definitions.
function driver.authored_c_compile_prefix(context)
    local args, err = compiler_argv(true, context, true)
    if not args then return nil, err end
    append_compile_includes(args, context)
    return args
end

-- Install one invocation's `nativeinputs.normalize` result: its ordered
-- compile extras follow the profile defaults in every generated-object,
-- probe and header-checking command (SDK include roots stay last), and its
-- ordered link extras keep their exact flag/library interleaving on every
-- link. Call before `driver.configure_foreign_c`.
function driver.apply_native_inputs(normalized)
    driver.NATIVE_COMPILE_FLAGS = { table.unpack(normalized.compile_argv or {}) }
    driver.NATIVE_LINK_FLAGS = { table.unpack(normalized.link_argv or {}) }
end

-- The link extras every native link appends: the normalized invocation
-- extras when installed, else the ambient TITAN_EXTRA_LDFLAGS.
function driver.link_extra_flags()
    return driver.NATIVE_LINK_FLAGS or driver.EXTRA_LDFLAGS or {}
end

function perf.dsymutil_executable(context)
    local ok, identity, selected, status = pcall(incremental.physical_executable,
        context or { io = compiler_io.new_sync() }, "dsymutil")
    if not ok then
        if type(identity) ~= "string" then error(identity, 0) end
        return nil, identity
    end
    if not identity then return nil, selected, status end
    -- Keep the admitted executable spelling: a symlink target may dispatch
    -- differently when invoked under its canonical basename.
    return selected
end

-- Describe only tools the requested output actually uses. Keep exact wrapper
-- arguments and share parsing with their execution sites.
function driver.output_tool_descriptors(context, kind)
    local argv, argv_error = compiler_argv(false, context)
    if not argv then return nil, argv_error end
    local descriptor, descriptor_error = driver.toolchain_descriptor(context)
    if not descriptor then return nil, descriptor_error end
    local tools, uncacheable = {}, nil
    local browser = context.target_descriptor
    if browser then
        tools.ar = { table.unpack(browser.tools.ar) }
        tools.ranlib = { table.unpack(browser.tools.ranlib) }
    elseif kind == "library" and not platform.windows then
        local ar, ar_error = perf.tool_command(driver.AR, "AR")
        if not ar then return nil, ar_error end
        local ranlib, ranlib_error = perf.tool_command(driver.RANLIB, "RANLIB")
        if not ranlib then return nil, ranlib_error end
        tools.ar, tools.ranlib = ar, ranlib
    elseif (kind == "program" or kind == "test") and platform.windows then
        local rc, rc_error =
            perf.tool_command(platform.getenv("RC") or "llvm-rc", "RC")
        if not rc then return nil, rc_error end
        tools.rc = rc
    end
    if kind and driver.IS_DARWIN and not browser then
        local dsymutil, dsymutil_error, dsymutil_status =
            perf.dsymutil_executable(context)
        if not dsymutil then
            if dsymutil_status ~= "uncertified" then return nil, dsymutil_error end
            dsymutil, uncacheable = "dsymutil", dsymutil_error
        end
        tools.dsymutil = { dsymutil }
    end
    local toolchain, details, status =
        incremental.toolchain_identity(context, descriptor)
    if not toolchain and status ~= "uncertified" then return nil, details end
    return {
        compiler_argv = argv,
        link_flags = driver.link_extra_flags(),
        toolchain = toolchain,
        compiler_stage_policy = toolchain and details.stage_policy or nil,
        -- The certified compiler and stage executables; uncertified names none.
        compiler_tools = toolchain and details.tools or nil,
        uncacheable = status == "uncertified" and details or uncacheable,
        directory = context.output_root or
            driver.TITAN_SOURCE_PATH:match("[^;]+") or ".",
        darwin = not browser and driver.IS_DARWIN == true,
        windows = not browser and platform.windows,
        tools = tools,
    }
end

-- Dependency-report support is memoized in this resolver and persisted by the
-- shared link-certificate owner under the observed native tool identities.
function driver.native_link_backend(context)
    if context.native_link_backend then return context.native_link_backend end
    local request, request_error = driver.output_tool_descriptors(context)
    if not request then return nil, request_error end
    local backend, backend_error, status = require("titan-compiler.linkcertificate")
        .linker_backend(context, request)
    if status == "uncertified" then return backend, backend_error, status end
    if not backend then return nil, backend_error end
    context.native_link_backend = backend
    return backend
end

-- One immutable description of the native compiler prefix used for generated
-- objects, predefined-macro/header discovery, and compile-only checker probes.
-- `compile_flags` deliberately includes Titan's fixed language selection, so
-- cprobe is told not to synthesize a second `-std` spelling.
function driver.toolchain_descriptor(context)
    if context and context.target == "browser" then
        local descriptor, err = driver.context_target_descriptor(context)
        if not descriptor then return nil, err end
        return {
            io = context.io, compiler_argv = { table.unpack(descriptor.tools.cc) },
            compile_flags = { table.unpack(descriptor.compile_flags) },
            language_mode = "c99", language_flag = false, cppflags = {}, cflags = {},
            include_dirs = { table.unpack(descriptor.include_dirs) },
            profile = context.target_profile, profile_identity = descriptor.profile_identity,
            target_identity = descriptor.identity,
            certification_target_identity = incremental.digest(context, "relocatable-browser-target",
                require("titan-compiler.relocation").browser(context, driver._browser_target.export(descriptor))),
        }
    end
    if driver.TOOLCHAIN_ERROR then return nil, driver.TOOLCHAIN_ERROR end
    local cc, err = perf.tool_command(driver.CC, "CC")
    if not cc then return nil, err end

    local effective, compile_err = compiler_argv(true, context)
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

-- Called by saved indexing to publish the eligible detached binary catalog.
-- No filesystem discovery is performed here; provider precedence is already
-- settled by this resolver's complete source inventory.
function driver.completion_binary_catalog(context)
    driver.assert_target_context(context)
    local result = {}
    -- Finalization selects whole archives, including siblings that ordinary
    -- imports never loaded. Capture their interfaces without selecting any
    -- additional providers or publishing siblings into driver.imported.
    for _, provider in ipairs(context.selected_static_providers or {}) do
        for name, entry in pairs(provider.entries) do
            result[name] = { serialized = types.serialize(entry.type),
                kind = "static", filename = provider.archive,
                documentation = entry.type._documentation and
                    documentation.copy(entry.type._documentation) }
        end
    end
    -- Eligible embedded interfaces take precedence over filesystem providers,
    -- followed by the resolver's actual imported selections below.
    local provider = available_embedded_interface_provider(context)
    if provider then
        for _, name in ipairs(provider.key_order) do
            local entry = provider.entries[name]
            local interface = entry.type
            result[name] = { serialized = entry.types, kind = "embedded",
                filename = provider.provider_file, documentation = interface and interface._documentation and
                    documentation.copy(interface._documentation) }
        end
    end
    for name, entry in pairs(driver.imported) do
        if entry ~= CIRCULAR_MARK then
            if entry.kind == "source" then result[name] = nil
            elseif entry.kind == "dynamic" or entry.kind == "static" or entry.kind == "embedded" then
                result[name] = { serialized = types.serialize(entry.type),
                    kind = entry.kind, filename = entry.filename or entry.static_archive or "",
                    documentation = entry.type._documentation and
                        documentation.copy(entry.type._documentation) }
            end
        end
    end
    return result
end

-- The local cap of this resolver's speculative C probe batches: titanc's
-- resolved job cap, except 1 for an explicit serial POSIX parent Make
-- (`make -j1`) and for analysis/completion resolvers. On POSIX each batch's
-- ledger joins the parent jobserver; Windows applies only the local cap.
-- Implementation notes: doc/implementation/c-ffi-expressions.md#speculative-batched-acceptance-probes
function driver.probe_batch_jobs(context)
    local cap = context.jobs
    if not cap or cap <= 1 or context.analysis_only or context.completion then
        return 1
    end
    if not platform.windows and
       jobs.make_policy(platform.getenv("MAKEFLAGS")).serial then return 1 end
    return cap
end

-- The invocation's content-digest memo, shared by object certification and
-- every C header/preamble read of a fresh check, so each distinct file is
-- hashed at most once per resolver context.
local function context_file_digest(context)
    if not context.file_digest then
        context.file_digest = function(path, bytes)
            local digest, digest_error =
                incremental.file_digest(context, path, bytes)
            if digest == nil then return nil, digest_error end
            return digest
        end
    end
    return context.file_digest
end

function driver.get_probe_service(context)
    driver.assert_target_context(context)
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
    if not context.target_descriptor then
        for _, directory in ipairs(context.extra_ffi_include_dirs or {}) do
            include_dirs[#include_dirs + 1] = directory
        end
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
        cache_adapter = context.cache_adapter,
        relocation_roots = context.relocation_roots,
        header_observations = context.header_observations,
        file_digest = context_file_digest(context),
        process_trace = context.c_header_process_trace,
        process_analysis = context.c_header_analysis,
        persistent_cache_trace = persistent_cache_trace,
        semantic_trace = semantic_trace,
        execution_trace = execution_trace,
        toolchain = toolchain,
        verbose = context.probe_verbose,
        cache_directory = context.transient_caches and "" or
            (context.target_descriptor and context.target_descriptor.probe_cache_directory or
                (not context.target_descriptor and driver.PROBE_CACHE_DIRECTORY or nil)),
        jobs = driver.probe_batch_jobs(context),
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
    driver.assert_target_context(context)
    if context.target == "browser" then
        local descriptor, err = driver.context_target_descriptor(context)
        if not descriptor then return nil, err end
        return context.target_profile
    end
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

-- Call once for each saved analysis, before reading project payloads. The host
-- adds its compiler-file/provider/configuration inventory to this identity.
-- SDK-free analysis still has an explicit native-unavailable identity when a
-- verified embedded profile supplies the semantic target.
function driver.language_server_cache_identity(options)
    local context = options and options.context
    if type(context) ~= "table" or context.io == nil then
        return nil, "cache identity requires a resolver context"
    end
    local profile, err = driver.get_target_profile(context)
    if not profile then return nil, err end
    local identity
    identity, err = csemantics.profile_identity(profile)
    if not identity then return nil, err end
    local cwd
    cwd, err = context.io:cwd()
    if not cwd then return nil, err end
    local service = driver.get_probe_service(context)
    local native_identity
    if service then
        local process_options
        process_options, err = service:cdriver_process_options()
        if not process_options then return nil, err end
        native_identity, err = cdriver.preprocessor_cache_identity(process_options)
        if not native_identity then return nil, err end
    else
        -- Failure diagnostics may contain unique probe temporary paths. Clean
        -- SDK-free semantics depend on the explicit unavailable state and
        -- requested configuration, not those presentation-only spellings.
        native_identity = "native-unavailable"
    end
    local pieces = {}
    for _, item in ipairs({
        "titan-language-server-cache-v1", driver.LANGUAGE_SERVER_API_VERSION,
        driver.TITAN_VERSION, driver.TITAN_LIBRARY_VERSION,
        driver.TITAN_ABI_VERSION, graphcodec.VERSION, projectcache.VERSION,
        foreigncache.VERSION, cdriver.HEADER_CACHE_VERSION, identity, cwd,
        driver.CC, driver.CFLAGS, driver._TOOLCHAIN_FLAGS_ERROR or "", native_identity,
    }) do
        item = tostring(item)
        pieces[#pieces + 1] = #item .. ":" .. item
    end
    for _, values in ipairs({
        driver.NATIVE_COMPILE_FLAGS or driver.EXTRA_CPPFLAGS or {},
        not driver.NATIVE_COMPILE_FLAGS and driver.EXTRA_CFLAGS or {},
        driver.foreign_include_dirs(), context.extra_ffi_include_dirs or {} }) do
        pieces[#pieces + 1] = "[" .. #values .. ":"
        for _, item in ipairs(values) do pieces[#pieces + 1] = #item .. ":" .. item end
        pieces[#pieces + 1] = "]"
    end
    return "titan-language-server-cache-v1:sha256:" .. sha256.hex(table.concat(pieces))
end

function driver.close_resolver_context(context)
    if not context then return true end
    if type(context) ~= "table" or context.io == nil then
        error("closing a resolver requires its compiler I/O strategy", 2)
    end
    compiler_io.validate(context.io, 2)
    local headers_closed, header_error = ffiheaders.close(context)
    local first_error = not headers_closed and header_error or nil
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
    -- Semantic preprocessing shares this resolver's cleanup boundary, just
    -- like deferred C-probe signals: deliver only after both owners retire.
    local signal = context.generated_c_cancelled_signal
    context.generated_c_cancelled_signal = nil
    jobs.propagate(signal)
    if first_error then return nil, first_error end
    return true
end

local function resolver_context_from_options(options, level)
    level = level or 3
    if options ~= nil and type(options) ~= "table" then
        error("resolver options must be a table", level)
    elseif options and options._resolver_context == true then
        driver.assert_target_context(options)
        compiler_io.validate(options.io, level)
        return options
    elseif options and options.context ~= nil then
        local context = options.context
        if type(context) ~= "table" or context.io == nil then
            error("options.context must be a resolver context", level)
        end
        driver.assert_target_context(context)
        compiler_io.validate(context.io, level)
        return context
    end
    error("resolver options require an explicit context", level)
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
        if kind ~= "file" and kind ~= "search" and kind ~= "origin" then
            return nil, label .. " entry " .. index ..
                " kind must be 'file', 'search', or 'origin'"
        elseif type(path) ~= "string" or not platform.is_absolute(path) or
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
            observation = cdriver.copy_header_observation(input.observation),
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
function driver.serialize_source_interface(entry, context)
    if type(entry) ~= "table" or entry.kind ~= "source"
       or (type(entry.ast) ~= "table" and entry._analysis_manifest ~= true)
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
    return sourceinterface.serialize(normalized, context)
end

-- File-only verification also serves publication's fresh digest/header memo;
-- that memo is not a semantic resolver and must not activate a target.
function perf.restat_c_header_dependencies(value, validation_options)
    local dependencies, err = copy_c_header_dependencies(value)
    if not dependencies then return nil, err end
    local result, changed, classified = {}, false, nil
    for index, dependency in ipairs(dependencies) do
        local current, identity_error, input_changed, reason =
            cdriver.revalidate_header_input(dependency, validation_options)
        if not current then
            return nil, "cannot fingerprint C header input '" ..
                dependency.path .. "': " .. tostring(identity_error),
                input_changed == true,
                reason and ("c-input " .. dependency.path .. ": " .. reason)
                    or nil
        end
        result[index] = current
        if input_changed and not classified then
            classified = "c-input " .. dependency.path .. ": " ..
                tostring(reason or "content")
        end
        changed = changed or input_changed
    end
    return result, nil, changed, classified
end

-- Recompute the identities of an already-resolved module header closure. This
-- never searches for a different header wholesale: `search` entries are the
-- exact ordered candidates cdriver consulted, including misses, so a new
-- earlier shadow changes identity without walking an include tree. `origin`
-- entries recheck the realpath that names a C declaration's nominal scope.
-- The fourth result classifies the first changed input as
-- `c-input <path>: content|provenance|missing|unreadable|candidate|changed-during-read`.
-- Implementation notes: doc/implementation/driver.md#driverrestat_c_header_dependenciesdependencies-options
function driver.restat_c_header_dependencies(value, options)
    local validation_options
    if options == nil or (type(options) == "table" and
       options._resolver_context ~= true and options.context == nil) then
        options = options or {}
        local valid, validation_error = cacheadapter.validate(options.cache_adapter)
        if not valid then error(validation_error, 2) end
        local strategy = options.io or compiler_io.new_sync()
        compiler_io.validate(strategy, 2)
        validation_options = {
            io = strategy,
            cache_adapter = options.cache_adapter or default_digest_adapter(),
            header_observations = cdriver.header_observation_index(options.header_inputs),
            header_validation = options.header_validation or {},
        }
    else
        local context = resolver_context_from_options(options, 2)
        validation_options = {
            io = context.io,
            cache_adapter = context.cache_adapter,
            header_observations = context.header_observations,
            header_validation = options.header_validation or context.header_validation or {},
        }
    end
    return perf.restat_c_header_dependencies(value, validation_options)
end

function driver.close_loader(loader)
    if loader ~= nil then loader_contexts[loader] = nil end
    return true
end

-- Execute a loader-scoped operation and release its bookkeeping on returns or
-- exceptions. The caller owns and closes the explicitly supplied context.
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
    driver.close_loader(loader)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

-- On Mach-O (macOS), libbacktrace needs a companion `.dSYM` bundle to symbolize
-- PCs to #line-attributed .titan file/line — the linker does NOT produce one, so
-- without `dsymutil` the native Titan frames are unsymbolized and dropped. Run
-- `dsymutil` after every final link on Darwin only; on Linux DWARF is embedded in
-- the binary and dsymutil may be absent, so it must be a no-op there.
local function run_dsymutil(output, verbose, stable_input_basename, executable)
    if not driver.IS_DARWIN then return true end
    if not executable then
        local executable_error, status
        executable, executable_error, status = perf.dsymutil_executable()
        if not executable then
            if status ~= "uncertified" then return nil, executable_error end
            executable = "dsymutil"
        end
    end
    -- An uncertified bare command has no absolute pin. Preserve its original
    -- launch cwd instead of resolving it after entering the private stage.
    if not stable_input_basename or not platform.is_absolute(executable) then
        return run_argv({ executable, output }, verbose)
    end

    -- A bundled dSYM records dsymutil's input spelling in
    -- Resources/Relocations/<arch>/<basename>.yml. Public providers link in a
    -- unique sibling stage, so passing the complete staged pathname would make
    -- an otherwise identical dSYM differ on every transaction. Run only these
    -- staged-provider invocations from the output directory and pass the
    -- stable leaf name. Darwin ld records absolute N_OSO object paths, so
    -- changing dsymutil's working directory does not change object discovery.
    local directory, basename = path.split(output)
    if directory == "" or basename == "" then
        return run_argv({ executable, output }, verbose)
    end
    local previous, current_err = lfs.currentdir()
    if not previous then return nil, current_err end
    local changed, change_err = lfs.chdir(directory)
    if not changed then return nil, change_err end
    local ok, term, code = run_argv({ executable, basename }, verbose)
    local restored, restore_err = lfs.chdir(previous)
    if not restored then
        return nil, "could not restore working directory after dsymutil: " ..
            tostring(restore_err)
    end
    return ok, term, code
end

-- Expand a configured Titan binary path with the runtime's rules: `;;`
-- inserts the default in place and `!` names the running interpreter's
-- directory. Empty path entries are separators, not directories.
function driver.titan_bin_path_entries(path, default_path)
    local expanded = default_path or driver.DEFAULT_TITAN_BIN_PATH
    if path ~= nil then
        local expand, support_error = support_function("_expand_titan_path")
        if not expand then return nil, support_error end
        local ok, result = pcall(expand, path, expanded)
        if not ok then
            return nil, "cannot expand Titan path '" .. path .. "': " ..
                tostring(result)
        end
        expanded = result
    end
    local entries = {}
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

function driver.generated_output_path(filename, output_root)
    if output_root then return path.join(output_root, filename) end
    return filename
end

-- A resolved module's logical path is relative to its selected source root.
-- Folder modules retain their canonical main's repeated final component.
-- This also handles absolute/external source roots without '..' escapes.
-- Implementation notes: doc/implementation/output-directory.md#one-source-identity-separate-artifact-locations
function driver.relocate_source_output(modname, source, output_root)
    if not output_root or source._output_root == output_root then return source end
    if source.kind ~= "generated" then
        if not staticmetadata.valid_module_name(modname) then
            return nil, "invalid logical Titan module name " .. string.format("%q", modname)
        end
        local relative = modname:gsub("[.]", "/")
        if source.kind == "folder" then
            relative = relative .. "/" .. modname:match("[^.]+$")
        end
        source.native_output = path.join(output_root, relative .. ".titan")
        source.program_output = path.join(output_root, source.program_output or
            modname:gsub("[.]", "/"))
    end
    source._output_root = output_root
    return source
end

-- Derive the physical provider for a no-main invocation from the longest
-- common sequence of complete dotted components. The returned root list is
-- deduplicated while retaining the CLI's first-occurrence order.
-- Implementation notes: doc/implementation/multi-module-libraries.md#provider-selection-for-a-library-invocation
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
    assert(suffix == ".so" or suffix == ".a" or
        (platform.windows and suffix == ".dll"),
        platform.windows and "compiled module candidates require .so, .a, or Windows .dll" or
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

-- Implementation notes: doc/implementation/multi-module-libraries.md#compiled-module-candidate-search
function driver.module_binary_candidates(modname)
    return driver.module_compiled_candidates(modname, platform.windows and ".dll" or ".so")
end

local function regular_file(filename, context)
    if platform.windows then
        local strategy = context and context.io or compiler_io.new_sync()
        local attributes, attribute_error = strategy:stat(filename)
        assert(not attribute_error, attribute_error)
        return attributes and attributes.kind == "file" or false
    end
    if context and context.io then
        local attributes = context.io:stat(filename)
        return attributes and attributes.kind == "file" or false
    end
    return lfs.attributes(filename, "mode") == "file"
end

local function select_source_family(filename, labels, context)
    local stem = filename:sub(1, -7)
    for _, label in ipairs(labels) do
        local candidate = stem .. "." .. label .. ".titan"
        if regular_file(candidate, context) then return candidate end
    end
    if regular_file(filename, context) then return filename end
end

-- Implementation notes: doc/implementation/folder-modules.md#tagged-source-resolution
local function source_resolution_in_root(root, modname, context)
    local module_path = modname:gsub("[.]", "/")
    local basename = modname:match("([^.]+)$")
    if not basename then return nil end
    local folder = append_path(root, module_path)
    local canonical_main = append_path(folder, basename .. ".titan")
    local folder_main = select_source_family(canonical_main, context.source_labels, context)

    if folder_main then
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

        local families = {}
        for _, name in ipairs(entries) do
            if name:sub(-6) == ".titan" and
               regular_file(append_path(folder, name), context) then
                local logical, label, name_error = driver.classify_source_filename(name)
                if name_error then return nil, name_error end
                if logical ~= basename .. ".titan" then
                    local family = families[logical]
                    if not family then family = {}; families[logical] = family end
                    family[label or "default"] = name
                end
            end
        end
        local contributors = {}
        local selected = {}
        for logical, family in pairs(families) do
            local name
            for _, label in ipairs(context.source_labels) do
                name = family[label]
                if name then break end
            end
            name = name or family.default
            if name then
                contributors[#contributors + 1] = logical
                selected[logical] = name
            end
        end
        table.sort(contributors, util.bytewise_less)

        local files = { folder_main }
        for _, logical in ipairs(contributors) do
            files[#files + 1] = append_path(folder, selected[logical])
        end
        return {
            kind = "folder",
            main = folder_main,
            files = files,
            native_output = canonical_main,
            program_output = module_path .. "__main",
        }
    end

    local canonical_flat = append_path(root, module_path .. ".titan")
    local flat = select_source_family(canonical_flat, context.source_labels, context)
    if not flat then return nil end

    local owner = modname:match("^(.*)[.][^.]+$")
    if owner then
        local owner_path = owner:gsub("[.]", "/")
        local owner_basename = owner:match("([^.]+)$")
        if not owner_basename then return nil end
        local owner_main = select_source_family(
            append_path(root, owner_path .. "/" .. owner_basename .. ".titan"),
            driver.SOURCE_LABELS, context)
        if owner_main then
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
        native_output = canonical_flat,
        program_output = module_path,
    }
end

local function resolve_source(paths, modname, context)
    local target, target_error = driver.context_target(context)
    if not target then return nil, target_error end
    context.source_labels = context.source_labels or driver.target_selection_labels(target)
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
        origin = true,
    },
    ["Type.CUnion"] = {
        _tag = true, cname = true, tagname = true, typedef = true,
        fields = true, complete = true, origin = true,
    },
    ["Type.CArray"] = {
        _tag = true, elem = true, len = true, quals = true,
    },
    ["Type.CTypedef"] = {
        _tag = true, name = true, target = true, quals = true, origin = true,
    },
    ["Type.CField"] = {
        _tag = true, owner = true, name = true, type = true,
        bitfield = true, flexible_array = true,
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
    if names == nil then return true end
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
    if value == nil then return "-" end
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
       or (scope.owner_fqtn ~= nil
           and not valid_qualified_nominal_name(scope.owner_fqtn))
       or (scope.callable_name ~= nil
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
    elseif scope == nil then
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
           or (typeparam.constraint ~= nil
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
        if constraint ~= nil then
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

    if typeparam.constraint == nil then
        if parameter.erased_constraint ~= nil then
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

    if callable.varargtype ~= nil then
        local ok, err = validate_interface_type(
            callable.varargtype, nested, seen)
        if not ok then return nil, err end
        if not types.valid_varg_element(callable.varargtype) then
            return nil, "variadic parameter has a noncanonical element type"
        end
    end
    if callable.flexrettype ~= nil then
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
    if type(record.custom_constructor) ~= "boolean" then
        return nil, "record has a noncanonical custom constructor flag"
    end
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
            callable_name = nil,
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
        if not types.has_tvalue_representation(field.type)
           and not require("titan-compiler.nominallayout").classify(field.type) then
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
    if not record.custom_constructor and not constructor
       and record.nfields == nfields then
        return nil, "all-public record is missing its constructor"
    end
    if constructor and not record.custom_constructor then
        if record.nfields ~= nfields
           or constructor.scope ~= nil
           or #constructor.typeparams ~= 0
           or constructor.varargtype ~= nil
           or constructor.flexrettype ~= nil
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
            callable_name = nil,
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
        local payload_params = #variant.parts
        if not constructor
           or constructor.scope ~= nil
           or #constructor.typeparams ~= 0
           or constructor.varargtype ~= nil
           or constructor.flexrettype ~= nil
           or type(constructor.paramnames) ~= "table"
           or #constructor.paramnames ~= payload_params
           or #constructor.params ~= payload_params
           or #constructor.rettypes ~= 1
           or not canonical_owner_application(
               constructor.rettypes[1], union) then
            return nil, "union constructor '" .. variant.name ..
                "' does not match its variant"
        end
        for index, part in ipairs(variant.parts) do
            if constructor.paramnames[index] ~= part.name
               or not types.equals(constructor.params[index], part.type) then
                return nil, "union constructor '" .. variant.name ..
                    "' does not match its variant"
            end
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
            callable_name = nil,
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
            owner_fqtn = nil,
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
       or (alias.target_alias_fqtn ~= nil
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
            callable_name = nil,
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

    if alias.target_alias_fqtn ~= nil then
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
        local surface, valid = types.parameter_surface_constraint(
            argument, validation.scope_bindings)
        return valid and surface ~= nil
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
    if concrete.scope ~= nil then
        concrete_ok, concrete_view = pcall(
            types.substitute, concrete, concrete.scope, argument.args or {})
    end
    local interface_ok, interface_view = true, interface
    if interface.scope ~= nil then
        interface_ok, interface_view = pcall(
            types.substitute, interface, interface.scope,
            constraint.args or {})
    end
    if not concrete_ok or not interface_ok then return false end
    local implementation = types.generic_interface_implementation(
        concrete_view, interface_view, {
            visibility = validation.modname,
        })
    return implementation ~= nil
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
        if typeparam.constraint ~= nil then
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
               and pointee_tag ~= "Type.CArray"
               and pointee_tag ~= "Type.CTypedef"
               and pointee_tag ~= "Type.CStruct"
               and pointee_tag ~= "Type.CUnion"
               and not types.is_c_lua_state(typ.pointee)) then
            return nil, "portable C pointer has a noncanonical shape"
        end
        local nested = value_context(context)
        nested.kind = "c-pointee"
        local valid, validation_error =
            validate_interface_type(typ.pointee, nested, seen)
        if not valid then return nil, validation_error end
        if not types.is_exportable_c_type_graph(typ) then
            return nil,
                "portable C pointer graph is cyclic or noncanonical"
        end
        return true
    elseif tag == "Type.CFunction" then
        if not context or (context.kind ~= "c-pointee"
                           and context.kind ~= "module-member")
           or dense_plain_list_length(typ.params) == nil
           or type(typ.ret) ~= "table"
           or typ.vararg ~= false or typ.abi ~= nil then
            return nil, "portable C function has a noncanonical shape"
        end
        local nested = value_context(context)
        nested.kind = "c-parameter"
        for _, param in ipairs(typ.params) do
            if type(param) ~= "table"
               or (param._tag ~= "Type.CInteger"
                   and param._tag ~= "Type.CFloat"
                   and param._tag ~= "Type.CPointer"
                   and param._tag ~= "Type.CTypedef"
                   and param._tag ~= "Type.CStruct"
                   and param._tag ~= "Type.CUnion") then
                return nil, "portable C function parameter has an invalid shape"
            end
            local ok, err = validate_interface_type(param, nested, seen)
            if not ok then return nil, err end
        end
        nested.kind = "c-return"
        if typ.ret._tag ~= "Type.CVoid"
           and typ.ret._tag ~= "Type.CInteger"
           and typ.ret._tag ~= "Type.CFloat"
           and typ.ret._tag ~= "Type.CPointer"
           and typ.ret._tag ~= "Type.CTypedef"
           and typ.ret._tag ~= "Type.CStruct"
           and typ.ret._tag ~= "Type.CUnion" then
            return nil, "portable C function return has an invalid shape"
        end
        return validate_interface_type(typ.ret, nested, seen)
    elseif tag == "Type.COwned" then
        local pointee_tag = type(typ.pointee) == "table"
            and typ.pointee._tag
        if type(typ.count) ~= "boolean"
           or (pointee_tag ~= "Type.CInteger"
               and pointee_tag ~= "Type.CFloat"
               and pointee_tag ~= "Type.CPointer"
               and pointee_tag ~= "Type.CTypedef"
               and pointee_tag ~= "Type.CStruct"
               and pointee_tag ~= "Type.CUnion"
               and pointee_tag ~= "Type.CArray") then
            return nil, "portable owned C type has a noncanonical shape"
        end
        local nested = value_context(context)
        nested.kind = "c-owned-payload"
        return validate_interface_type(typ.pointee, nested, seen)
    elseif tag == "Type.CTypedef" then
        local graph = context and context.kind == "c-pointee"
            and types.CPointer(typ, {}) or typ
        if not valid_source_identifier(typ.name) or type(typ.origin) ~= "string"
           or typ.origin == "" or not types.is_exportable_c_type_graph(graph) then
            return nil, "C typedef has an invalid declaration identity or target"
        end
        return validate_interface_type(typ.target, context, seen)
    elseif tag == "Type.CArray" then
        if not types.valid_c_extent(typ.len)
           or not types.is_exportable_c_type_graph(typ) then
            return nil, "C array has an invalid fixed extent or element type"
        end
        local nested = value_context(context)
        nested.kind = "c-field"
        return validate_interface_type(typ.elem, nested, seen)
    elseif tag == "Type.CStruct" or tag == "Type.CUnion" then
        if types.is_c_lua_state(typ) then
            if not context or context.kind ~= "c-pointee" then
                return nil, "C struct is not valid as a value-facing type"
            end
            return true
        end
        local graph = context and context.kind == "c-pointee"
            and types.CPointer(typ, {}) or typ
        if not types.is_exportable_c_type_graph(graph)
           or type(typ.origin) ~= "string" or typ.origin == ""
           or (typ.cname ~= nil and typ.cname ~= typ.tagname
               and typ.cname ~= typ.typedef
               and typ.cname ~= (tag == "Type.CStruct" and "struct " or "union ") ..
                   tostring(typ.tagname)) then
            return nil, "C aggregate has an invalid declaration identity or field graph"
        end
        local count = dense_array_length(typ.fields)
        if not count or not typ.complete and count ~= 0 then
            return nil, "C aggregate field list is invalid"
        end
        local names = {}
        local nested = value_context(context)
        nested.kind = "c-field"
        for _, field in ipairs(typ.fields) do
            local fields_ok, fields_err = validate_portable_c_descriptor_fields(field)
            if not fields_ok then return nil, fields_err end
            if not valid_source_identifier(field.name) or names[field.name]
               or field.owner ~= nil and field.owner ~= typ then
                return nil, "C aggregate field has an invalid owner or name"
            end
            names[field.name] = field
            local field_ok, field_err = validate_interface_type(field.type, nested, seen)
            if not field_ok then return nil, field_err end
        end
        for name, field in pairs(typ.fields) do
            if type(name) ~= "number" and names[name] ~= field then
                return nil, "C aggregate has an invalid named field projection"
            end
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
        if not types.valid_array_constness(typ.isconst) then
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
        if typ.varargtype ~= nil then
            local ok, err = validate_interface_type(
                typ.varargtype, nested, seen)
            if not ok then return nil, err end
            if not types.valid_varg_element(typ.varargtype) then
                return nil, "function variadic parameter has a noncanonical element type"
            end
        end
        if typ.flexrettype ~= nil then
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
        local count = dense_plain_list_length(typ.parts)
        if not count or count > 65534 then
            return nil, "union variant parts have an invalid schema"
        end
        local names = {}
        for index, part in ipairs(typ.parts) do
            if type(part) ~= "table" or part._tag ~= "Type.Field"
               or part.fqtn ~= typ.fqtn
               or not valid_source_identifier(part.name)
               or names[part.name] or math.type(part.index) ~= "integer"
               or part.index ~= index
               or part.islocal or part.isconst ~= false then
                return nil, "union variant part has an invalid schema"
            end
            names[part.name] = true
            local ok, err = validate_interface_type(
                part.type, value_context(context), seen)
            if not ok then return nil, err end
            if not types.has_tvalue_representation(part.type)
               and not require("titan-compiler.nominallayout").classify(part.type) then
                return nil, "union variant '" .. typ.name ..
                    "' payload has no TValue representation"
            end
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
           or member._foreign_source ~= nil
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
            if signature._tag == "Type.Function"
                    or signature._tag == "Type.CFunction" then
                if not validate_name_list(
                        member.paramnames, #signature.params) then
                    return nil, "module function '" .. member.name ..
                        "' has invalid parameter-name metadata"
                end
            elseif member.paramnames ~= nil then
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
           and member.type._tag ~= "Type.CFunction"
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

-- Implementation notes: doc/implementation/driver.md#interface-recovery-and-the-closed-validator
function driver.decode_module_interface(serialized, modname, origin)
    local modtf, load_err =
        load("return " .. serialized, "@" .. (origin or modname), "t", types)
    if not modtf then return nil, load_err end
    local decoded = table.pack(pcall(modtf))
    if not decoded[1] then return nil, tostring(decoded[2]) end
    if decoded.n ~= 2 then
        return nil, "serialized module interface must return exactly one value"
    end
    local references_ok, references_error = types.resolve_compiled_c_references(decoded[2])
    if not references_ok then return nil, references_error end
    local valid, validation_err =
        driver.validate_module_interface(decoded[2], modname)
    if not valid then return nil, validation_err end
    return decoded[2]
end

-- Physical nominal layout is deliberately absent from the semantic metadata
-- graph and analysis inventories. Only native provider selection loads it.
local function decode_nominal_layouts(modname, serialized)
    return require("titan-compiler.nominallayout").decode(serialized, modname)
end

local function remember_nominal_layouts(context, inventory, filename)
    if not context or context.analysis_only or not inventory then return end
    if filename then
        local provider = context.nominal_layout_inventories[filename]
        if not provider then
            provider = {}
            context.nominal_layout_inventories[filename] = provider
        end
        provider[inventory.module] = inventory
    end
    for name, plan in pairs(inventory.layouts) do
        context.nominal_layouts[name] = plan
    end
end

-- Decoded metadata is invocation-local and belongs to one observed physical
-- provider, not to the logical module name or one spelling of its pathname.
function perf.provider_decoding_cache(context, filename)
    if not (context and context._resolver_context and context.io) then return nil end
    local stat, stat_error = context.io:stat(filename)
    if stat_error and type(stat_error) ~= "string" then error(stat_error, 0) end
    if not stat or stat.kind ~= "file" then return nil end
    local physical, physical_error = context.io:realpath(filename)
    if physical_error and type(physical_error) ~= "string" then
        error(physical_error, 0)
    end
    if not physical then return nil end
    local key = stat.device ~= nil and stat.inode ~= nil and
        ("inode:" .. tostring(stat.device) .. ":" .. tostring(stat.inode)) or
        ("path:" .. physical)
    local observation = table.concat({
        tostring(stat.size), tostring(stat.mode),
        tostring(stat.modified_seconds), tostring(stat.modified_nanoseconds),
        tostring(stat.changed_seconds), tostring(stat.changed_nanoseconds),
        tostring(stat.time_precision),
    }, ":")
    local cache = context.decoded_provider_cache[key]
    if not cache or cache.observation ~= observation then
        -- `precise` is nil for a coarse or incomplete observation.
        cache = { observation = observation, types = {}, layouts = {},
            precise = incremental.precise_observation(stat) }
        context.decoded_provider_cache[key] = cache
    end
    return cache
end

function perf.decode_provider_interface(cache, modname, serialized, origin)
    local saved = cache and cache.types[modname]
    if saved and saved.serialized == serialized then return saved.type end
    local modtype, err = driver.decode_module_interface(serialized, modname, origin)
    if modtype and cache then
        cache.types[modname] = { serialized = serialized, type = modtype }
    end
    return modtype, err
end

function perf.decode_provider_layouts(cache, modname, serialized)
    local saved = cache and cache.layouts[modname]
    if saved and saved.serialized == serialized then return saved.inventory end
    local inventory, err = decode_nominal_layouts(modname, serialized)
    if inventory and cache then
        cache.layouts[modname] = { serialized = serialized, inventory = inventory }
    end
    return inventory, err
end

-- Probe one existing container for a logical module. A missing dlsym entry is
-- a membership absence; an open failure is terminal. Callers decide whether a
-- clean nonclaim is skippable (ancestor) or an error (exact candidate).
local function probe_compiled_interface(modname, binf, options)
    if options and options.target == "browser" then
        return "error", "browser providers require static archives"
    end
    local decoded = perf.provider_decoding_cache(options, binf)
    local prefix = driver.mangle_module_name(modname)
    local support = require("titan")
    local loadlib = support._loadlib
    local abiname = prefix .. "_abi"
    local typesname = prefix .. "_types"
    local native_abi
    if platform.windows then
        -- Resolve/call the plain-C query before invoking any provider Lua
        -- function. Legacy symbols may still be inspected for membership when
        -- the query is absent, but must never be called in that case.
        if type(support._abivalue) ~= "function" then
            return "error", "Windows Titan native ABI query support is unavailable"
        end
        local queryerr, querystage
        native_abi, queryerr, querystage = support._abivalue(binf, abiname .. "_value")
        if native_abi == nil then
            if querystage ~= "init" then
                return "error", "cannot inspect compiled module '" .. modname ..
                    "' in '" .. binf .. "': " .. tostring(queryerr)
            end
        elseif type(native_abi) ~= "string" then
            return "error", "compiled module ABI query '" .. abiname ..
                "_value' must return a string"
        elseif native_abi ~= driver.TITAN_ABI_VERSION then
            return "error", "compiled module '" .. modname ..
                "' ABI mismatch: expected " .. driver.TITAN_ABI_VERSION ..
                " but found " .. native_abi
        end
    end
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

    if not abif and not typesf and native_abi == nil then
        return "nonclaim", {
            abi = abierr,
            types = typeserr,
        }
    elseif not abif or not typesf then
        local missing = not abif and abiname or typesname
        return "error", "compiled container '" .. binf .. "' claims module '" ..
            modname .. "' but is missing metadata symbol '" .. missing .. "'"
    end

    if platform.windows and native_abi == nil then
        return "error", "compiled container '" .. binf .. "' claims module '" ..
            modname .. "' but is missing native ABI query '" .. abiname .. "_value'"
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
    local modt_or_err, validation_err = perf.decode_provider_interface(
        decoded, modname, types_or_err, binf .. ":" .. typesname)
    if not modt_or_err then
        return "error", "compiled container '" .. binf ..
            "' has invalid metadata for module '" .. modname .. "': " ..
            validation_err
    end
    local serialized_layouts, layout_inventory
    if not (options and options.analysis_only) then
        local layoutsname = prefix .. "_layouts"
        local layoutsf, layoutserr = loadlib(binf, layoutsname)
        if not layoutsf then
            return "error", "compiled container '" .. binf ..
                "' claims module '" .. modname ..
                "' but is missing metadata symbol '" .. layoutsname ..
                "': " .. tostring(layoutserr)
        end
        local layouts_call_err
        serialized_layouts, layouts_call_err = one_metadata_result(
            layoutsf, "compiled module layout metadata '" .. layoutsname .. "'")
        if not serialized_layouts then return "error", layouts_call_err end
        local layout_err
        layout_inventory, layout_err =
            perf.decode_provider_layouts(decoded, modname, serialized_layouts)
        if not layout_inventory then
            return "error", "compiled container '" .. binf ..
                "' has invalid nominal layout metadata for module '" ..
                modname .. "': " .. tostring(layout_err)
        end
    end
    -- Provider-relative binding lives on the module view. Keep it separate
    -- from the shared decoded graph, including when two paths name one inode.
    local module_view = {}
    for key, value in pairs(modt_or_err) do module_view[key] = value end
    return "valid", module_view, {
        module = modname,
        abi = abi_or_err,
        types = types_or_err,
        layouts = serialized_layouts,
        layout_inventory = layout_inventory,
        type = module_view,
        origin = binf,
    }
end
driver.probe_compiled_interface = probe_compiled_interface

local function join_path(root, relative)
    if platform.windows then return assert(platform.join(root, relative)) end
    if root:sub(-1) == "/" then return root .. relative end
    return root .. "/" .. relative
end

-- Locate a compiled logical module inside shallow-to-exact containers. Search
-- is root-major so an earlier local exact module wins over a later installed
-- shallow bundle. Once a relative candidate exists in one root it shadows the
-- same relative pathname in all later roots, even when it is a clean nonclaim.
-- Implementation notes: doc/implementation/multi-module-libraries.md#claim-and-terminal-error-states
function driver.find_dynamic_interface(paths, modname, context)
    if context then
        driver.assert_target_context(context)
        if context.target == "browser" then return nil end
    end
    local candidates = driver.module_binary_candidates(modname)
    if #candidates == 0 then return nil end
    local occupied = {}
    local windows_io = platform.windows and not (context and context.io) and
        compiler_io.new_sync() or nil

    local roots, roots_error = driver.titan_bin_path_entries(paths)
    if not roots then return nil, roots_error end
    for _, root in ipairs(roots) do
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
                elseif windows_io then
                    attributes, attribute_error = windows_io:lstat(filename)
                else
                    local mode = lfs.symlinkattributes(filename, "mode")
                    attributes = mode and { kind = mode } or nil
                end
                if attribute_error then
                    return nil, "cannot inspect compiled provider candidate '" ..
                        filename .. "': " .. tostring(attribute_error)
                elseif attributes then
                    occupied[relative] = true
                    local status, value, metadata =
                        probe_compiled_interface(modname, filename, context)
                    if status == "valid" then
                        value.file = relative
                        return value, filename, relative, metadata
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
    local decoded = perf.provider_decoding_cache(context, filename)
    local cached = context.provider_cache[filename]
    if cached and context.provider_cache_identity[filename] == decoded then
        if cached.error then return nil, cached.error end
        return cached
    end

    local browser, descriptor_error = driver.context_target_descriptor(context)
    if descriptor_error then return nil, descriptor_error end
    local options = {
        target = browser and browser.fingerprint or nil,
        io = context.io,
        expected_abi = driver.TITAN_ABI_VERSION,
        require_layouts = not context.analysis_only,
        validate_layouts = not context.analysis_only and function(name, serialized)
            return perf.decode_provider_layouts(decoded, name, serialized)
        end or nil,
        validate_types = function(name, serialized, origin)
            return perf.decode_provider_interface(decoded, name, serialized, origin)
        end,
    }
    -- A build worker reuses its coordinator's scan of the exact planned
    -- archive path only while it observes the same precise physical file
    -- state. Absent, coarse, changed or rejected plan metadata leaves the
    -- archive itself authoritative.
    local provider, scan_err
    local planned = not browser and decoded and decoded.precise and
        context.planned_archives and context.planned_archives[filename]
    if type(planned) == "table" and
       incremental.observations_equal(planned.observation, decoded.precise) then
        provider = staticmetadata.metadata_view(filename, planned.modules, options)
    end
    if not provider then
        provider, scan_err = staticmetadata.scan_archive(filename, options)
    end
    if provider and browser then
        local valid, validation_error = driver.validate_browser_provider(provider)
        if not valid then provider, scan_err = nil, validation_error end
    end
    context.provider_cache_identity[filename] = decoded
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
            modtype, type_err = perf.decode_provider_interface(
                decoded, name, entry.types, entry.origin or filename)
        end
        if not modtype then
            local err = "static provider '" .. filename ..
                "' has invalid types for module '" .. name .. "': " ..
                tostring(type_err)
            context.provider_cache[filename] = { error = err }
            return nil, err
        end
        entry.type = modtype
        entry.layout_inventory = entry.decoded_layouts
    end
    context.provider_cache[filename] = provider
    return provider
end

function driver.find_static_interface(paths, modname, context)
    driver.assert_target_context(context)
    local candidates =
        driver.module_compiled_candidates(modname, ".a")
    if #candidates == 0 then return nil end
    local occupied = {}

    local roots, roots_error
    if context.target == "browser" then
        local descriptor, descriptor_error = driver.context_target_descriptor(context)
        if not descriptor then return nil, descriptor_error end
        roots, roots_error = driver.titan_bin_path_entries(paths, ".")
        if roots then table.insert(roots, 1, descriptor.paths.titan_bin) end
    else
        roots, roots_error = driver.titan_bin_path_entries(paths)
    end
    if not roots then return nil, roots_error end
    for _, root in ipairs(roots) do
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
    driver.assert_target_context(context)
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
    driver.assert_target_context(context)
    local browser = context.target == "browser"
    local embedded = not browser and find_embedded_interface(modname, context) or nil
    if embedded then return embedded end
    local formats = browser and { "static" } or
        (context.prefer_static and { "static", "dynamic" } or { "dynamic", "static" })

    for _, format in ipairs(formats) do
        if format == "dynamic" then
            local modtype, filename, relative, metadata =
                driver.find_dynamic_interface(paths, modname, context)
            if modtype then
                remember_nominal_layouts(context, metadata.layout_inventory, filename)
                return {
                    kind = "dynamic",
                    type = modtype,
                    filename = filename,
                    relative = relative,
                    layouts = metadata.layouts,
                    layout_inventory = metadata.layout_inventory,
                }
            elseif filename then
                return nil, filename
            end
        else
            local modtype, filename, relative, provider =
                driver.find_static_interface(paths, modname, context)
            if modtype then
                local metadata = provider.entries[modname]
                remember_nominal_layouts(context, metadata.layout_inventory, filename)
                return {
                    kind = "static",
                    type = modtype,
                    filename = filename,
                    relative = relative,
                    static_archive = filename,
                    static_provider = provider,
                    layouts = metadata.layouts,
                    layout_inventory = metadata.layout_inventory,
                }
            elseif filename then
                return nil, filename
            end
        end
    end
    return nil
end

function driver.prepare_source_ffi_header(context, modname, ast, sourcef)
    local native_output = driver.module_output_stem(sourcef, modname) .. ".titan"
    return ffiheaders.prepare(context, modname, ast, native_output)
end

local function prepare_source_checking_header(context, modname, ast)
    if context.analysis_only then return nil end
    if not driver.ast_has_foreign_functions(ast) then return nil end
    local descriptor = assert(ast._ffi_header,
        "source foreign functions have no checking FFI header")
    local logical_name = modname:gsub("[.]", "/") .. ".titan.h"
    local filename, filename_err = ffiheaders.filename(context, logical_name)
    if not filename then return nil, filename_err end
    local contents = coder.generate_foreign_header(
        modname, ast, { module = modname }, {
            ffi_header = ffiheaders.relative(logical_name, descriptor.logical_name),
            source_header = function(node)
                local dependency = assert(node._ffi_header_descriptor)
                return ffiheaders.relative(logical_name,
                    dependency.logical_name:gsub("[.]ffi[.]h$", ".titan.h"))
            end,
        }, driver.header_policy(false))
    ffiheaders.remember_file(context, filename)
    local wrote, write_err = context.io:write_file(filename, contents)
    if not wrote then return nil, write_err end
    local formatted, format_err = driver.format_generated_file(
        filename, context.probe_verbose, context.pretty_print, context.io)
    if not formatted then return nil, format_err end
    return filename
end

-- `reparse()` returns a fresh root parsed from the same source inputs; with a
-- probe batch cap above one it lets the checker defer body-phase acceptance
-- probes and recheck a fresh parse when a deferred verdict fails.
local function check_source_module(
        context, modname, ast, input, filename, loader, source_output, reparse)
    local completion_request
    if context.completion then
        for _, node in ipairs(ast) do
            if node.loc and node.loc.filename == context.completion.filename then
                completion_request = context.completion
                break
            end
        end
    end
    local check_options = {
        analysis_only = context.analysis_only,
        completion = completion_request,
        cache_adapter = context.cache_adapter,
        header_observations = context.header_observations,
        file_digest = context_file_digest(context),
        target_profile_provider = function()
            return driver.get_target_profile(context)
        end,
        probe_service_provider = function()
            return driver.get_probe_service(context)
        end,
        prepare_ffi_header = function(checked_ast)
            return driver.prepare_source_ffi_header(
                context, modname, checked_ast, source_output or filename)
        end,
        reparse = driver.probe_batch_jobs(context) > 1 and reparse or nil,
    }
    return checker.check(
        modname, ast, input, filename, loader, check_options)
end

-- Certification facts; only `incremental_options` escapes this block.
local incremental_options
do

-- The directory holding the loaded `titan-compiler/` and `c-parser/` trees:
-- a source checkout root or an installed LuaRocks share directory. The
-- configuration certificate hashes the Lua that actually runs from here.
local function loaded_compiler_root(strategy)
    local source = DRIVER_SOURCE
    if not source then
        return nil, "cannot locate the loaded compiler driver source"
    end
    source = source:sub(2)
    if platform.windows then
        local absolute, absolute_error = absolute_filename(source, strategy)
        if not absolute then return nil, absolute_error end
        source = absolute
    elseif source:sub(1, 1) ~= "/" then
        local current_dir, current_error = strategy:cwd()
        if not current_dir then return nil, current_error end
        source = current_dir .. "/" .. source
    end
    local root = source:match(platform.windows and
        "^(.*)[/\\]titan%-compiler[/\\]driver[.]lua$" or
        "^(.*)/titan%-compiler/driver[.]lua$")
    if not root then
        return nil, "loaded compiler driver '" .. source ..
            "' is not titan-compiler/driver.lua"
    end
    return normalize_root(root, strategy)
end

-- Native flags a test owner's generated C is compiled with. Compilation and
-- certification share this decision: an object compiled without them can
-- never satisfy a `--test` build, whose runner relies on unoptimized sibling
-- calls for case locations. A browser test image under the production profile
-- also turns inlining off (D25): its objects would otherwise lose the physical
-- frames the exact trace gate asserts, which is the browser form of native
-- `--test`'s frame preservation.
function driver.test_owner_flags(test_build, test_functions, context)
    if test_build and type(test_functions) == "table" and
       #test_functions > 0 then
        local flags = {}
        if context and context.target == "browser" then
            -- The descriptor owns the profile, including in a build worker
            -- that inherited it (D26).
            local profile = context.target_descriptor and
                context.target_descriptor.build_profile or driver.BUILD_PROFILE
            if profile == "production" then flags[1] = "-fno-inline" end
        end
        for _, flag in ipairs(
            require("titan-compiler.test_runner").TEST_COMPILE_FLAGS) do
            flags[#flags + 1] = flag
        end
        return flags
    end
    return {}
end

-- The code-generation options an object must have been produced with under
-- one resolver policy (`c_parts`, `split_threshold`, `test`, `coverage`).
-- `native` is a record's object metadata or a fresh module's equivalent.
local function expected_codegen_options(policy, modname, native)
    native = native or {}
    local coverage
    if policy.coverage then
        coverage = {
            enabled = require("titan-compiler.coverage").matches(
                policy.coverage, modname,
                native.coverage_test_functions or native.test_functions) == true,
            backend = policy.coverage.backend,
        }
    end
    return {
        c_parts = driver.effective_c_parts(policy.c_parts),
        split_threshold = policy.split_threshold or coder.DEFAULT_SPLIT_THRESHOLD,
        test_flags = #driver.test_owner_flags(
            policy.test, native.test_functions) > 0,
        coverage = coverage,
    }
end

-- The physical output stem is used for I/O; certificates label its owned root.
local function certified_stem(modname, source)
    return normalized_absolute_filename(driver.module_output_stem(
        source.native_output or source.main, modname))
end

-- The generated-preamble probe translation unit has one stable path inside
-- the invocation's output domain, so expansions of `__FILE__` in forced
-- includes cannot vary between invocations.
local function preamble_probe_path(context)
    local root = context.output_root or
        driver.TITAN_SOURCE_PATH:match("^[^;]+") or "."
    return normalized_absolute_filename(path.join(root, ".titan", "preamble.c"))
end

-- The certification facts of one resolver context (`context.incremental_options`
-- for `titan-compiler.incremental`): the loaded compiler, the real frontend,
-- the exact generated-object native prefix and toolchain, code-generation
-- settings, and the per-module stem and expected-codegen callbacks.
function incremental_options(context)
    local root, root_error = loaded_compiler_root(context.io)
    if not root then
        return nil, "cannot certify compiler configuration: " ..
            tostring(root_error)
    end
    local prefix, prefix_error = driver.generated_compile_prefix(context)
    if not prefix then return nil, prefix_error end
    local toolchain, toolchain_error = driver.toolchain_descriptor(context)
    if not toolchain then return nil, toolchain_error end
    return {
        compiler_root = root,
        frontend = context.frontend or "api",
        compile_prefix = prefix,
        toolchain_descriptor = toolchain,
        build_profile = driver.BUILD_PROFILE,
        emit_line_directives = driver.EMIT_LINE_DIRECTIVES,
        pretty_print = context.pretty_print == true,
        extra_ffi_include_dirs = context.extra_ffi_include_dirs or {},
        titan_root = driver.TITAN_ROOT or "",
        relocation_roots = context.relocation_roots,
        preamble_path = preamble_probe_path(context),
        stem = certified_stem,
        codegen_options = function(modname, record)
            local native = type(record) == "table" and
                (record.object_metadata or record) or nil
            return expected_codegen_options(
                context.codegen_policy or {}, modname, native)
        end,
    }
end

end -- certification facts

-- Compute this invocation's configuration certificate once per resolver
-- context. Only explicit native-policy uncertainty disables certification
-- without disabling compilation. Inventory and operational failures remain
-- invocation errors; an uncertified context never contains a partial certificate.
function driver.incremental_configuration(context)
    if type(context) ~= "table" or context.io == nil then
        error("configuration certification requires a resolver context", 2)
    end
    driver.assert_target_context(context)
    if context.incremental_configuration then
        return context.incremental_configuration
    end
    if context.incremental_uncertified then
        return nil, context.incremental_uncertified, "uncertified"
    end
    local options, options_error = incremental_options(context)
    if not options then return nil, options_error end
    context.incremental_options = options
    local configuration, configuration_error, status =
        incremental.configuration(context, options)
    if not configuration then
        if status == "uncertified" then
            context.incremental_uncertified = configuration_error
            return nil, configuration_error, status
        end
        if type(configuration_error) ~= "string" then
            error(configuration_error, 0)
        end
        return nil, "cannot certify compiler configuration: " ..
            configuration_error
    end
    context.incremental_configuration = configuration
    return configuration
end

-- A module or contextual owner as this resolver currently knows it, with
-- whether it is compiled into the same image: an ordinary selection, a
-- recovered contextual owner, a member carried by a selected static provider,
-- or (type recovery only, without selecting anything) the provider ordinary
-- lookup would choose, which an exposer can reach only through globals.
local function certificate_dependency(context, name, linked_names)
    driver.assert_target_context(context)
    local mod = driver.imported[name]
    if mod and mod ~= CIRCULAR_MARK then
        return mod, linked_names[name] == true
    end
    local recovered = context.contextual_owner_entries and
        context.contextual_owner_entries[name]
    if recovered then return recovered, recovered.linked == true end
    for _, selected in pairs(driver.imported) do
        if selected ~= CIRCULAR_MARK and selected.kind == "static" and
           selected.static_provider and selected.static_provider.entries[name] then
            local carried = selected.static_provider.entries[name]
            return {
                kind = "static", type = carried.type, layouts = carried.layouts,
                filename = selected.static_archive,
                static_archive = selected.static_archive,
            }, true
        end
    end
    local resolved = driver.find_dependency_interface(
        driver.TITAN_BIN_PATH, name, context)
    return resolved, false
end

-- The certificate plan interface over this resolver's selection: `linked`
-- names are compiled into the same image (direct bindings), a dynamic
-- provider's file is the handle a direct import loads, and digests come from
-- producer-stored self digests or per-module binary provider metadata.
local function resolver_plan(context, linked_names)
    local plan = {}
    function plan.linked(name)
        local mod, linked = certificate_dependency(context, name, linked_names)
        if not mod then return nil end
        return linked
    end
    function plan.provider_file(name)
        driver.assert_target_context(context)
        local mod = driver.imported[name]
        if not mod or mod == CIRCULAR_MARK or mod.kind ~= "dynamic" then
            return nil
        end
        return mod.type and mod.type.file
    end
    function plan.digest(name, view)
        local mod = certificate_dependency(context, name, linked_names)
        if not mod then return nil, "unavailable" end
        return incremental.interface_digest(context, mod, view)
    end
    function plan.path(filename)
        return require("titan-compiler.relocation").path(context, filename)
    end
    return plan
end

-- A closed-data copy of a tagged source descriptor as build plans carry it:
-- no read bytes and no generated contents.
local function copy_source_descriptor(source)
    local files = {}
    for index, filename in ipairs(source.files) do files[index] = filename end
    return {
        kind = source.kind, main = source.main, files = files,
        native_output = source.native_output,
        program_output = source.program_output,
        _output_root = source._output_root,
        _coverage_output = source._coverage_output,
    }
end

-- Implementation notes: doc/implementation/driver.md#driverdefaultloaderstatic_deps-options
function driver.defaultloader(static_deps, options)
    static_deps = static_deps or {}
    options = options or {}
    local context = options.context
    driver.assert_target_context(context)
    local source_roots = options.source_roots or {}
    -- The object code-generation policy certification compares records
    -- against; compilation requests of the same invocation use these values.
    context.codegen_policy = {
        c_parts = options.c_parts,
        split_threshold = options.split_threshold or coder.DEFAULT_SPLIT_THRESHOLD,
        test = options.test == true,
        coverage = options.coverage,
    }
    -- Planning mode (the build coordinator): each source module is certified
    -- and its imports are followed without parsing or checking it, while
    -- binary providers are selected exactly as ordinary resolution selects
    -- them. driver.resolution_plan closes planning.
    local planning
    if options.plan_mode then
        if type(options.imports_for) ~= "function" then
            error("plan_mode requires an imports_for function", 2)
        end
        planning = { nodes = {}, unavailable = {}, open = true }
    end
    -- Worker mode: the coordinator's authoritative plan replaces discovery.
    -- Parent-certified dependencies are restored from their records without
    -- recertification; any request outside the plan is a divergence.
    local worker_plan = options.worker_plan
    if worker_plan ~= nil and (type(worker_plan) ~= "table"
            or type(worker_plan.modules) ~= "table") then
        error("worker_plan must be a build plan descriptor", 2)
    end
    local object_loaded = {}
    local source_overrides = options.source_overrides or {}
    local known_source_modules = options.known_source_modules or {}
    local cached_source_entries = options.cached_source_entries or {}
    local cached_interfaces = options.cached_interfaces or {}
    local cached_binary_interfaces = options.cached_binary_interfaces or {}
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
    if not context.completion_closed_world then
        reconcile_embedded_import_cache(context, static_deps)
    end

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

    local function validate_cached_source_entry(modname, candidate)
        if type(candidate) ~= "table" or candidate.kind ~= "source"
           or (type(candidate.ast) ~= "table" and candidate._analysis_manifest ~= true)
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
        if candidate._analysis_manifest and not context.analysis_only then
            return nil, "cached declared manifest for module '" .. modname ..
                "' requires an analysis-only resolver"
        end
        if candidate.ast and candidate.ast._analysis_only and not context.analysis_only then
            return nil, "cached analysis AST for module '" .. modname ..
                "' requires an analysis-only resolver"
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
        local source, source_error = resolve_source(
            driver.TITAN_SOURCE_PATH, modname, context)
        if source_error then return false, source_error end
        if not source or source.kind == "blocked" or source.main ~= filename or
           #source.files ~= #source_files then return nil end
        for index, selected in ipairs(source.files) do
            if selected ~= source_files[index] then return nil end
        end
        return source
    end

    local cached_source_loading, cached_source_loaded = {}, {}
    local load_cached_source_entry
    local function load_cached_source_entry_inner(modname, active_loader)
        local candidate = cached_source_entries[modname]
            or (driver.imported[modname] and driver.imported[modname]._analysis_manifest
                and driver.imported[modname])
        if candidate == nil then return nil end
        if cached_source_loaded[modname] == candidate then return candidate end
        local valid, validation_error =
            validate_cached_source_entry(modname, candidate)
        if not valid then return false, validation_error end
        if cached_source_loading[modname] then
            return false, "cached source entry cycle at module '" ..
                modname .. "'"
        end
        cached_source_loading[modname] = true

        if candidate._analysis_manifest then
            -- Declaration-only entries have an explicit source capability and
            -- ordered C environment. Neither private visibility nor restoring
            -- these headers requires an AST or a native .titan.h companion.
            local plan = candidate.ffi_header_descriptor
            for index, name in ipairs(candidate.source_imports) do
                local dependency = driver.imported[name]
                if not dependency or dependency._analysis_manifest then
                    local loaded, load_error = load_cached_source_entry(name, active_loader)
                    if loaded == false then cached_source_loading[modname] = nil; return false, load_error end
                    dependency = loaded or dependency
                end
                if not dependency or dependency.kind ~= "source" or dependency.type._source ~= true then
                    local ok, type_or_error, errors = active_loader(name, { kind = "source-import" })
                    if not ok or #errors ~= 0 then
                        cached_source_loading[modname] = nil
                        return false, ok and table.concat(errors, "\n") or type_or_error
                    end
                    dependency = driver.imported[name]
                end
                local current = dependency and (dependency.ffi_header_descriptor
                    or dependency.ast and dependency.ast._ffi_header)
                if not current or not plan or not plan.dependencies[index]
                    or current.digest ~= plan.dependencies[index].digest then
                    cached_source_loading[modname] = nil
                    return false, "cached source entry for module '" .. modname ..
                        "' has a stale source C environment for '" .. name .. "'"
                end
            end
            if plan then
                local restored, restore_error = ffiheaders.materialize(context, plan)
                if not restored then cached_source_loading[modname] = nil; return false, restore_error end
                candidate.ffi_header_descriptor = restored
                candidate.ffi_header, candidate.checking_ffi_header = restored.identity, restored.filename
            end
            candidate._cached_source_entry = true
            driver.imported[modname] = candidate
            context.source_modules[modname] = true
            cached_source_loaded[modname] = candidate
            cached_source_loading[modname] = nil
            return candidate
        end

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
                if not dependency or (not dependency.ast and not dependency._analysis_manifest) then
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
                   or (not dependency.ast and not dependency._analysis_manifest) then
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
                if probe_identity and not platform.is_absolute(probe_identity) then
                    local absolute, absolute_error = absolute_filename(
                        probe_identity, context.io)
                    if not absolute then
                        cached_source_loading[modname] = nil
                        return false, absolute_error
                    end
                    probe_identity = platform.windows and absolute or
                        normalize_absolute_path(absolute)
                end
                node._foreign_header_probe_identity = probe_identity
                node._ffi_header_descriptor = dependency.ffi_header_descriptor
                    or dependency.ast._ffi_header
                node._ffi_header = dependency.checking_ffi_header
                node._ffi_header_probe_identity = dependency.ffi_header
            end
        end

        local has_foreign = driver.ast_has_foreign_functions(candidate.ast)
        local foreign_header = has_foreign and
            (candidate.foreign_header or driver.foreign_header_filename(
                candidate.native_output or candidate.filename)) or nil
        local ffi_descriptor, ffi_error = driver.prepare_source_ffi_header(
            context, modname, candidate.ast,
            candidate.native_output or candidate.filename)
        if not ffi_descriptor then
            cached_source_loading[modname] = nil
            return false, ffi_error
        end
        local checking_foreign_header, header_error =
            prepare_source_checking_header(
                context, modname, candidate.ast)
        if header_error then
            cached_source_loading[modname] = nil
            return false, header_error
        end
        candidate.foreign_header = foreign_header
        candidate.checking_foreign_header = checking_foreign_header
        candidate.ffi_header = ffi_descriptor.identity
        candidate.checking_ffi_header = ffi_descriptor.filename
        candidate._cached_source_entry = true
        driver.imported[modname] = candidate
        context.source_modules[modname] = true
        cached_source_loaded[modname] = candidate
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
            native_output = source_selection.output_stem(filename, modname) .. ".titan",
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
            if types.serialize_semantic(old_type) ~= types.serialize_semantic(resolved.type) then
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
                if types.serialize_semantic(old_type) ~= types.serialize_semantic(dynamic_type) then
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
        if seen[modname] then return true end
        seen[modname] = true
        local mod = driver.imported[modname]
        if not mod or mod == CIRCULAR_MARK then return true end
        if mod.ast and mod.ast._analysis_only and not context.analysis_only then
            return nil, "cached analysis AST for module '" .. modname ..
                "' requires an analysis-only resolver"
        end
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
                    local retained, retain_error = remember_dependency_closure(depname, seen)
                    if not retained then return nil, retain_error end
                end
            end
        end
        return true
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

    -- Restore one accepted object record into this resolver without parsing
    -- or checking its source. The caller has already selected every recorded
    -- import. Returns the restored entry; `nil, code, detail` for a miss
    -- before any resolver mutation; `false, err` for a failure.
    local function restore_source_object(
            modname, source, record, active_loader, published)
        local entry = record
        local native = type(entry) == "table" and entry.object_metadata
        if type(native) ~= "table" or type(native.parts) ~= "table"
           or type(native.imports) ~= "table" then
            return nil, "record-unreadable", "record has no object metadata"
        end
        local native_output = source.native_output or source.main
        local stem = driver.module_output_stem(native_output, modname)
        local compiled_objects = {}
        for index, part in ipairs(native.parts) do
            compiled_objects[index] = stem .. part.object_suffix
        end
        local deps = {}
        for _, import in ipairs(native.imports) do
            local dependency = driver.imported[import.name]
            if not dependency or dependency == CIRCULAR_MARK then
                return nil, "dependency-unavailable", import.name
            end
            if dependency.ast or dependency.kind == "source" or
               dependency.kind == "static" then
                deps[import.name] = true
            end
        end

        -- Context-owned checking artifacts come first; they change no
        -- resolver state. Source C environments are reattached to the
        -- dependencies selected in this invocation, whose interfaces the
        -- verdict has already certified.
        local descriptor = entry.ffi_header_descriptor
        local restored_descriptor
        if descriptor then
            for index, name in ipairs(entry.source_imports or {}) do
                local dependency = driver.imported[name]
                local current = dependency and dependency ~= CIRCULAR_MARK and
                    (dependency.ffi_header_descriptor or
                        dependency.ast and dependency.ast._ffi_header)
                if not current then
                    return nil, "dependency-unavailable", name
                end
                descriptor.dependencies[index] = current
            end
            local restored, err = ffiheaders.materialize(context, descriptor)
            if not restored then return false, err end
            restored_descriptor = restored
        end
        local checking_foreign_header
        if native.foreign_header then
            local logical = modname:gsub("[.]", "/") .. ".titan.h"
            local filename, err = ffiheaders.filename(context, logical)
            if not filename then return false, err end
            local contents = ffiheaders.foreign_contents(native.foreign_header,
                ffiheaders.relative(logical, descriptor.logical_name), function(name)
                    return ffiheaders.relative(logical, name:gsub("[.]", "/") .. ".titan.h")
                end)
            ffiheaders.remember_file(context, filename)
            local wrote, write_error = context.io:write_file(filename, contents)
            if not wrote then return false, write_error end
            checking_foreign_header = filename
        end

        entry.filename, entry.source_files = source.main, source.files
        entry.native_output = native_output
        entry.program_output = source.program_output
        entry.compiled = compiled_objects[1]
        entry.compiled_objects = compiled_objects
        entry.has_main = native.has_main
        entry.test_functions = native.test_functions
        entry.external_symbols = native.external_symbols
        entry.private_symbols = native.private_symbols or {}
        entry.native_references = native.native_references
        entry.deps = deps
        entry.interface_digests = native.certificate
            and native.certificate.interface or nil
        if restored_descriptor then
            entry.ffi_header_descriptor = restored_descriptor
            entry.ffi_header = normalized_absolute_filename(
                driver.ffi_header_filename(native_output))
            entry.checking_ffi_header = restored_descriptor.filename
        end
        if native.foreign_header then
            entry.foreign_header = driver.foreign_header_filename(native_output)
            entry.checking_foreign_header = checking_foreign_header
        end
        for name, owner in pairs(entry.declared_registry or {}) do
            if name:match("^(.*)%.") == modname or not types.registry[name] then
                types.registry[name] = owner
            end
        end
        driver.imported[modname] = entry
        object_loaded[modname] = true
        static_deps[modname] = true
        local registered, register_error = checker.register_module_interface(
            modname, entry.type, active_loader, modname, {}, true, {},
            source_import_permissions(entry))
        if not registered then return false, register_error end
        -- A worker restores parent-certified records; the coordinator
        -- already reported their decision.
        if context.probe_verbose and not worker_plan and not published then
            io.stderr:write("Titan object hit ", modname, ": ",
                entry.compiled, "\n")
        end
        return entry
    end

    local function restored_source_info(entry)
        return {
            kind = "source", filename = entry.filename,
            foreign_header = entry.checking_foreign_header,
            foreign_header_for_check = entry.checking_foreign_header ~= nil,
            foreign_header_probe_identity = entry.foreign_header and
                normalized_absolute_filename(entry.foreign_header),
            ffi_header = entry.ffi_header,
            checking_ffi_header = entry.checking_ffi_header,
            ffi_header_descriptor = entry.ffi_header_descriptor,
        }
    end

    -- Certify an existing object instead of parsing its source: stage 1
    -- (`incremental.certify_local`) reads only the record, own sources and C
    -- inputs; the record's imports are then selected exactly as a fresh parse
    -- of the certified bytes would; stage 2 (`incremental.verdict`) compares
    -- the recorded interfaces and bindings with that selection. Only a hit
    -- restores anything. Every miss is reported with `-v` and parses fresh.
    -- Implementation notes: doc/implementation/incremental-compilation.md#resolver-and-cli-boundary
    local function load_source_object(modname, source, loader)
        if not options.incremental or source.contents then return nil end
        local function miss(code, detail)
            if context.probe_verbose then
                io.stderr:write("Titan object miss ", modname, ": ",
                    tostring(code), (detail ~= nil and detail ~= "")
                        and (" " .. tostring(detail)) or "", "\n")
            end
            return nil
        end
        local configuration, configuration_error, status =
            driver.incremental_configuration(context)
        if not configuration then
            if status == "uncertified" then
                return miss(status, configuration_error)
            end
            return false, configuration_error
        end
        local certified = incremental.certify_local(context, modname, source)
        if certified.status ~= "hit" then
            return miss(certified.reason, certified.detail)
        end

        -- Certified own-source bytes fix the record's imports to exactly the
        -- requests a fresh parse would make, so selecting them first changes
        -- nothing a miss would not. A dependency failure is that failure.
        driver.imported[modname] = CIRCULAR_MARK
        table.insert(dependency_stack, {})
        for _, import in ipairs(certified.imports) do
            local ok, result, errors = loader(import.name,
                import.source_required and { kind = "source-import" } or nil)
            if not ok or #errors ~= 0 then
                table.remove(dependency_stack)
                driver.imported[modname] = nil
                return false, ok and table.concat(errors, "\n") or result
            end
        end
        table.remove(dependency_stack)
        driver.imported[modname] = nil

        local verdict = incremental.verdict(
            certified.record, resolver_plan(context, static_deps))
        if verdict.status == "pending" then
            -- This resolver checks every module before generating any code,
            -- so a freshly checked producer has no self digest yet.
            return miss("dependency-rebuilt",
                table.concat(verdict.names or {}, " "))
        elseif verdict.status ~= "hit" then
            return miss(verdict.reason, verdict.detail)
        end
        local entry, restore_code, restore_detail = restore_source_object(
            modname, source, certified.record, loader)
        if entry == nil then return miss(restore_code, restore_detail) end
        if not entry then return false, restore_code end
        return true, entry.type, {}, restored_source_info(entry)
    end

    -- Planning: certify (stage 1 only) and follow the module's imports. The
    -- placeholder entry keeps ordinary selection state (dependency sets,
    -- source/provider overlap rebinding) without a checked type; the
    -- coordinator replaces it by restoring an accepted record. A failing
    -- import never stops planning: its importer misses and the worker's
    -- checker reports the located diagnostic.
    local function plan_source(modname, source, loader)
        local certified
        if options.incremental and not source.contents then
            local configuration, configuration_error, status =
                driver.incremental_configuration(context)
            if configuration then
                certified = incremental.certify_local(context, modname, source)
            elseif status ~= "uncertified" then
                return false, configuration_error
            end
        end
        local imports, imports_error =
            options.imports_for(modname, source, certified)
        if not imports then return false, imports_error end
        local node = {
            source = source, certified = certified, imports = imports,
            failed = {},
        }
        planning.nodes[modname] = node
        driver.imported[modname] = CIRCULAR_MARK
        local direct = {}
        table.insert(dependency_stack, direct)
        for _, import in ipairs(imports) do
            local ok, result, errors = loader(import.name,
                import.source_required and { kind = "source-import" } or nil)
            if not ok or #errors ~= 0 then
                local text = ok and table.concat(errors, "\n") or tostring(result)
                node.failed[import.name] = text
                if not planning.nodes[import.name] and
                   planning.unavailable[import.name] == nil then
                    planning.unavailable[import.name] = text
                end
            end
        end
        table.remove(dependency_stack)
        driver.imported[modname] = {
            kind = "source", _planned = true,
            filename = source.main, source_files = source.files,
            native_output = source.native_output or source.main,
            program_output = source.program_output, deps = direct,
        }
        static_deps[modname] = true
        return true, nil, {}, { kind = "source", filename = source.main }
    end

    -- Worker: restore a parent-certified dependency from its published record
    -- without recertifying it, after restoring its own recorded imports.
    local function restore_planned_source(modname, item, loader)
        local object = item.object
        if type(object) ~= "string" then
            return false, "build plan divergence: module '" .. modname ..
                "' has no accepted object"
        end
        local bytes, read_error = perf.compiler_file_contents(context, object)
        if not bytes then
            return false, "cannot read planned object for module '" ..
                modname .. "': " .. tostring(read_error)
        end
        local record, record_error = objectmetadata.read(bytes, object)
        if not record or type(record.object_metadata) ~= "table" then
            return false, "cannot decode planned object for module '" ..
                modname .. "': " .. tostring(record_error)
        end
        driver.imported[modname] = CIRCULAR_MARK
        table.insert(dependency_stack, {})
        for _, import in ipairs(record.object_metadata.imports or {}) do
            local ok, result, errors = loader(import.name,
                import.source_required and { kind = "source-import" } or nil)
            if not ok or #errors ~= 0 then
                table.remove(dependency_stack)
                driver.imported[modname] = nil
                return false, ok and table.concat(errors, "\n") or result
            end
        end
        table.remove(dependency_stack)
        driver.imported[modname] = nil
        local entry, code, detail = restore_source_object(
            modname, copy_source_descriptor(item.source), record, loader)
        if entry == nil then
            return false, "build plan divergence: module '" .. modname ..
                "' cannot be restored: " .. tostring(code) ..
                (detail and (" " .. tostring(detail)) or "")
        elseif not entry then
            return false, code
        end
        return true, entry.type, {}, restored_source_info(entry)
    end

    -- Worker: load exactly the provider the coordinator selected.
    local function load_planned_binary(modname, item)
        local resolved
        if item.kind == "dynamic" then
            local status, value, metadata =
                probe_compiled_interface(modname, item.file, context)
            if status ~= "valid" then
                return false, status == "error" and value or
                    ("planned provider '" .. tostring(item.file) ..
                        "' no longer claims module '" .. modname .. "'")
            end
            value.file = item.relative
            if item.provider_file ~= nil and value.file ~= item.provider_file then
                return false, "build plan divergence: module '" .. modname ..
                    "' provider file is '" .. tostring(value.file) ..
                    "', planned '" .. tostring(item.provider_file) .. "'"
            end
            remember_nominal_layouts(context, metadata.layout_inventory, item.file)
            resolved = {
                kind = "dynamic", type = value, filename = item.file,
                relative = item.relative, layouts = metadata.layouts,
                layout_inventory = metadata.layout_inventory,
            }
        elseif item.kind == "static" then
            local provider, provider_error = inspect_static_provider(
                context, item.archive, item.relative)
            if not provider then return false, provider_error end
            local metadata = provider.entries[modname]
            if not metadata then
                return false, "planned static provider '" ..
                    tostring(item.archive) .. "' contains no module '" ..
                    modname .. "'"
            end
            remember_nominal_layouts(context, metadata.layout_inventory, item.archive)
            resolved = {
                kind = "static", type = metadata.type, filename = item.archive,
                relative = item.relative, static_archive = item.archive,
                static_provider = provider, layouts = metadata.layouts,
                layout_inventory = metadata.layout_inventory,
            }
            static_deps[modname] = true
        else
            return false, "build plan divergence: module '" .. modname ..
                "' has unsupported planned kind '" .. tostring(item.kind) .. "'"
        end
        resolved.compiled = true
        driver.imported[modname] = resolved
        remember_direct_dependency(modname)
        remember_used_compiled_interface(context, modname, resolved.type)
        return true, resolved.type, {}, { kind = resolved.kind }
    end

    -- Implementation notes: doc/implementation/folder-modules.md#source-descriptors-are-not-ast-nodes
    local function parse_source_inner(modname, source, loader, profile_frame)
        -- Each input is read once. The checker's authoritative recheck after
        -- a failed speculative probe batch assembles a fresh root from the
        -- same strings. After a certification miss these are exactly the
        -- bytes certification hashed, so the new record certifies what this
        -- invocation compiled.
        local inputs = {}
        local function assemble(frame)
            local ast = {}
            local main_initializer
            for index, filename in ipairs(source.files) do
                local input = inputs[index]
                if input == nil then
                    local err
                    if source.contents then
                        input = source.contents[filename]
                        if input == nil then
                            return nil, "generated source has no contents for '" ..
                                filename .. "'"
                        end
                    elseif source.certified_contents and
                           source.certified_contents[filename] ~= nil then
                        input = source.certified_contents[filename]
                    else
                        input, err = perf.compiler_file_contents(context, filename)
                        if not input then return nil, err end
                    end
                    inputs[index] = input
                end
                local parse_started = frame and os.clock() or nil
                local nodes, perr = parser.parse(filename, input)
                if frame then
                    local parse_cpu_ms = (os.clock() - parse_started) * 1000
                    if parse_cpu_ms < 0 then parse_cpu_ms = 0 end
                    frame.parse_cpu_ms = frame.parse_cpu_ms + parse_cpu_ms
                end
                if not nodes then
                    return nil, parser.error_to_string(perr, filename)
                end

                if index == 1 then
                    ast._documentation = nodes._documentation
                    if nodes[#nodes] and
                       nodes[#nodes]._module_initializer then
                        main_initializer = table.remove(nodes)
                    end
                else
                    for _, node in ipairs(nodes) do
                        if node._module_initializer then
                            return nil, location.format_error(node.loc,
                                "module initializer is only allowed in the " ..
                                "folder main source '%s'", source.main)
                        end
                    end
                end

                for _, node in ipairs(nodes) do table.insert(ast, node) end
            end
            if main_initializer then table.insert(ast, main_initializer) end
            return ast
        end
        local on_phase = options.on_phase
        if on_phase then on_phase("parsing", modname) end
        local ast, parse_error = assemble(profile_frame)
        if not ast then return false, parse_error end
        if on_phase then on_phase("checking", modname) end
        local main_input = inputs[1]

        driver.imported[modname] = CIRCULAR_MARK
        local direct_deps = {}
        table.insert(dependency_stack, direct_deps)
        local check_started = profile_frame and os.clock() or nil
        local check_child_started = profile_frame
            and profile_frame.child_cpu_ms or 0
        local modt, errors = check_source_module(
            context, modname, ast, main_input, source.main, loader,
            source.native_output or source.main,
            function() return assemble(nil) end)
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
                    context, modname, ast)
            if header_error then errors[#errors + 1] = header_error end
        end
        -- Own-source certificate of the exact bytes parsed above. Generated
        -- sources and semantic-only resolvers never produce reusable objects.
        -- A string failure (a constituent vanished after it was read) leaves
        -- the object uncertified, so it can only miss later.
        local source_certificate
        if not source.contents and not context.analysis_only then
            local contents = {}
            for index, filename in ipairs(source.files) do
                contents[filename] = inputs[index]
            end
            source_certificate =
                incremental.source_certificate(context, source, contents)
        end
        local entry = {
            kind = "source",
            ast = ast,
            type = modt,
            filename = source.main,
            native_output = source.native_output or source.main,
            source_files = source.files,
            completion = ast._completion,
            program_output = source.program_output,
            deps = direct_deps,
            c_header_dependencies = ast._c_header_dependencies or {},
            foreign_header = foreign_header,
            checking_foreign_header = checking_foreign_header,
            ffi_header = ast._ffi_header and ast._ffi_header.identity,
            checking_ffi_header = ast._ffi_header and ast._ffi_header.filename,
            source_certificate = source_certificate,
        }
        local source_manifest, manifest_error =
            driver.serialize_source_interface(entry, context)
        if not source_manifest then
            -- Keep the checked source available to semantic clients even when
            -- its interface cannot be retained. Report this alongside checker
            -- diagnostics so callers do not lose either the AST or the
            -- original errors, and never leave a circularity sentinel behind.
            errors[#errors + 1] = location.format_error(
                location.new(source.main, 1, 1),
                "could not serialize source interface for module '%s': %s",
                modname, tostring(manifest_error))
        else
            entry.source_manifest = source_manifest
        end
        driver.imported[modname] = entry
        static_deps[modname] = true
        if foreign_header and not platform.is_absolute(foreign_header) then
            local absolute, absolute_error = absolute_filename(
                foreign_header, context.io)
            if not absolute then
                return false, absolute_error
            end
            foreign_header = platform.windows and absolute or
                normalize_absolute_path(absolute)
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
            ffi_header = entry.ffi_header,
            checking_ffi_header = entry.checking_ffi_header,
            ffi_header_descriptor = ast._ffi_header,
            source_permissions = source_import_permissions(entry),
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
            remember_nominal_layouts(context, cached.layout_inventory)
            remember_used_compiled_interface(
                context, modname, cached.type)
            return true, cached.type, {}
        end

        -- `layouts`/`linked` describe the recovered owner for object
        -- certificates: its provider's encoded layouts and whether the
        -- exposer carries it into the same image.
        local function remember_type(
                modtype, resolved, ordinary_lookup, inventory, layouts, linked)
            inventory = inventory or resolved.layout_inventory
            context.contextual_types[cache_key] = {
                type = modtype, layout_inventory = inventory,
            }
            remember_nominal_layouts(context, inventory,
                resolved.static_archive or resolved.filename)
            context.native_interface_types[modname] = modtype
            remember_used_compiled_interface(context, modname, modtype)
            remember_contextual_resolution(
                context, modname, exposing_name, resolved, ordinary_lookup,
                physical_identity)
            if layouts then
                context.contextual_owner_entries =
                    context.contextual_owner_entries or {}
                context.contextual_owner_entries[modname] = {
                    kind = linked and "static" or "dynamic",
                    type = modtype,
                    layouts = layouts,
                    filename = resolved.filename,
                    static_archive = linked and resolved.static_archive or nil,
                    linked = linked,
                }
            end
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
                return remember_type(entry.type, exposing, false,
                    entry.layout_inventory, entry.layouts,
                    exposing.kind == "static")
            end
        elseif exposing.kind == "dynamic" then
            local status, value, metadata =
                probe_compiled_interface(modname, exposing.filename, context)
            if status == "valid" then
                add_native_constraint(context, modname, "dynamic-global",
                    exposing.filename, exposing_name)
                return remember_type(value, exposing, false,
                    metadata.layout_inventory, metadata.layouts, false)
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
        return remember_type(resolved.type, resolved, true, nil,
            resolved.layouts, false)
    end

    local function loader(modname, request)
        driver.assert_target_context(context)
        if not staticmetadata.valid_module_name(modname) then
            return false, "invalid logical Titan module name " ..
                string.format("%q", modname)
        end
        -- A completion resolver consumes one caller-captured committed catalog.
        -- Missing descriptors are a conservative miss, never permission to read
        -- a newer source/provider or restore the saved workspace registry.
        if context.completion_closed_world then
            if not context.analysis_only then
                return false, "closed completion catalog requires analysis_only"
            end
            local existing = driver.imported[modname]
            local source_required = request and request.kind == "source-import"
            if existing and existing ~= CIRCULAR_MARK and source_required
               and existing.kind ~= "source" then
                return false, "source module '" .. modname .. "' is absent from completion catalog"
            end
            if not existing and not source_overrides[modname]
               and not cached_source_entries[modname] then
                local saved = cached_binary_interfaces[modname]
                if not saved or source_required then
                    return false, "module '" .. modname .. "' is absent from completion catalog"
                end
                if type(saved) ~= "table" or type(saved.serialized) ~= "string"
                   or (saved.kind ~= "dynamic" and saved.kind ~= "static"
                       and saved.kind ~= "embedded") then
                    return false, "invalid captured binary interface for '" .. modname .. "'"
                end
                local modtype, decode_error = driver.decode_module_interface(
                    saved.serialized, modname, saved.filename or modname)
                if not modtype then return false, decode_error end
                driver.imported[modname] = {
                    kind = saved.kind, type = modtype, filename = saved.filename,
                    compiled = true, deps = {},
                }
            end
        end
        -- A borrowed context may learn a complete known-source catalog after
        -- an earlier loader selected embedded entries. Reconcile that late
        -- whole-provider rejection before either cache reuse or contextual
        -- owner recovery can observe the stale selection.
        if not context.completion_closed_world then
            reconcile_embedded_import_cache(context, static_deps)
        end
        local embedded_overlap =
            context.embedded_interface_provider_overlap
        if embedded_overlap and not context.completion_closed_world then
            local rebound, rebound_error =
                rebind_overlapping_embedded_provider(embedded_overlap)
            if not rebound then return false, rebound_error end
        end
        if not context.completion_closed_world and request and request.kind == "nominal-owner" then
            local contextual_ok, contextual_type, contextual_errors =
                recover_contextual_owner(modname, request)
            if contextual_ok ~= nil then
                return contextual_ok, contextual_type, contextual_errors
            end
        end
        if driver.imported[modname] == CIRCULAR_MARK then
            return false, "circular reference to module"
        end
        if driver.imported[modname] and driver.imported[modname].object_metadata
            and not object_loaded[modname] then
            driver.imported[modname] = nil
        end
        -- A worker never discovers: its dependencies and their providers are
        -- the coordinator's plan. Only the module it compiles parses source.
        if worker_plan and not driver.imported[modname] then
            local item = worker_plan.modules[modname]
            if not item then
                return false, "build plan divergence: module '" .. modname ..
                    "' is not in the coordinator's plan"
            elseif item.kind == "unavailable" then
                return false, item.error
            elseif item.kind == "source" then
                if modname ~= worker_plan.modname then
                    return restore_planned_source(modname, item, loader)
                end
            elseif request and request.kind == "source-import" then
                return false, "build plan divergence: source-imported module '" ..
                    modname .. "' is planned as a " .. tostring(item.kind) ..
                    " provider"
            else
                return load_planned_binary(modname, item)
            end
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
            if context.completion_closed_world then
                return nil, "source module '" .. modname .. "' is absent from completion catalog"
            end
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
            local relocated, relocation_error = driver.relocate_source_output(
                modname, candidate, options.output_root)
            if not relocated then return false, relocation_error end
            if options.coverage then
                local prepared, coverage_error = require("titan-compiler.coverage").source(
                    options.coverage, modname, candidate)
                if not prepared then return false, coverage_error end
            end
            context.source_modules[modname] = true
            local rebound, rebound_err =
                rebind_overlapping_embedded_provider(modname)
            if not rebound then return false, rebound_err end
            rebound, rebound_err =
                rebind_overlapping_static_providers(modname)
            if not rebound then return false, rebound_err end
            if planning and planning.open then
                local ok, modt, errors, info = plan_source(modname, candidate, loader)
                if ok then remember_direct_dependency(modname) end
                return ok, modt, errors, info
            end
            local ok, modt, errors, info = load_source_object(modname, candidate, loader)
            if ok == nil then
                ok, modt, errors, info = parse_source(modname, candidate, loader)
            end
            if ok then remember_direct_dependency(modname) end
            return ok, modt, errors, info
        end

        -- Analysis manifests retain the declared source interface. Raw entries
        -- checked for native compilation remain usable by native clients. Only caller-
        -- certified clean modules are eligible; dirty roots, overrides and
        -- source-first builds always check source again.
        if (not driver.imported[modname] or driver.imported[modname]._analysis_manifest)
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
           ((not driver.imported[modname].ast and not object_loaded[modname] and
                not driver.imported[modname]._planned and
                (not driver.imported[modname]._analysis_manifest or context.source_first
                    or not context.analysis_only)) or
            (driver.imported[modname].ast and
             driver.imported[modname].ast._analysis_only and not context.analysis_only) or
            (dirty_source_requested and
             (driver.imported[modname]._cached_source_entry
                or driver.imported[modname]._analysis_manifest))) then
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
            if not context.analysis_only then
                -- A semantic-only selection may survive in the process cache.
                -- Native compilation must acquire the separate physical plan
                -- from that exact provider before reusing its interface.
                if mod.kind == "dynamic" and not mod.layout_inventory then
                    local status, value, metadata =
                        probe_compiled_interface(modname, mod.filename, context)
                    if status ~= "valid" then
                        return false, status == "error" and value or
                            ("cached provider no longer claims module '" .. modname .. "'")
                    end
                    if types.serialize_semantic(value) ~= types.serialize_semantic(mod.type) then
                        return false, "cached compiled interface for module '" ..
                            modname .. "' changed before native compilation"
                    end
                    mod.layouts, mod.layout_inventory =
                        metadata.layouts, metadata.layout_inventory
                elseif mod.kind == "static" and not mod.layout_inventory then
                    local provider, provider_error = inspect_static_provider(
                        context, mod.static_archive, mod.relative)
                    if not provider then return false, provider_error end
                    local metadata = provider.entries[modname]
                    if not metadata or types.serialize_semantic(metadata.type) ~= types.serialize_semantic(mod.type) then
                        return false, "cached compiled interface for module '" ..
                            modname .. "' changed before native compilation"
                    end
                    mod.static_provider = provider
                    mod.layouts, mod.layout_inventory =
                        metadata.layouts, metadata.layout_inventory
                end
                remember_nominal_layouts(context, mod.layout_inventory,
                    mod.static_archive or mod.filename)
            end
            local retained, retain_error = remember_dependency_closure(modname)
            if not retained then return false, retain_error end
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
                if foreign_header and not platform.is_absolute(foreign_header) then
                    local absolute, absolute_error = absolute_filename(
                        foreign_header, context.io)
                    if not absolute then return false, absolute_error end
                    foreign_header = platform.windows and absolute or
                        normalize_absolute_path(absolute)
                end
                local probe_identity = mod.foreign_header
                if probe_identity and not platform.is_absolute(probe_identity) then
                    local absolute, absolute_error = absolute_filename(
                        probe_identity, context.io)
                    if not absolute then return false, absolute_error end
                    probe_identity = platform.windows and absolute or
                        normalize_absolute_path(absolute)
                end
                info.filename = mod.filename
                info.foreign_header = foreign_header
                info.foreign_header_for_check =
                    mod.checking_foreign_header ~= nil
                info.foreign_header_probe_identity = probe_identity
                info.ffi_header = mod.ffi_header
                info.checking_ffi_header = mod.checking_ffi_header
                info.ffi_header_descriptor = mod.ffi_header_descriptor or mod.ast and mod.ast._ffi_header
                info.source_permissions = source_import_permissions(mod)
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
        restore = function(modname, source, record, published)
            return restore_source_object(
                modname, source, record, loader, published)
        end,
        planning = planning,
    }
    return loader
end

-- Restore an accepted object record through the loader bound to `context`,
-- after `incremental.verdict` returned a hit or after the coordinator
-- published a worker's object. `record` is the decoded record (or a
-- certification result carrying it); every recorded import must already be
-- selected. Nothing is parsed, checked, or compiled. `options.published`
-- suppresses the `-v` hit line for a module compiled in this invocation.
-- Returns the restored entry; `nil, code, detail` for a miss before any
-- resolver mutation; `false, err` for a failure.
-- Implementation notes: doc/implementation/incremental-compilation.md#resolver-and-cli-boundary
function driver.restore_source_object(context, modname, source, record, options)
    if type(context) ~= "table" or context.io == nil then
        error("restoring an object requires a resolver context", 2)
    end
    driver.assert_target_context(context)
    local binding = context.loader and loader_contexts[context.loader]
    if not binding or binding.context ~= context or not binding.restore then
        error("restoring an object requires a loader bound to its " ..
            "resolver context", 2)
    end
    if type(record) == "table" and record.object_metadata == nil and
       type(record.record) == "table" then
        record = record.record
    end
    return binding.restore(modname, source, record,
        options and options.published == true)
end

-- Ordinary tagged source lookup (folder before flat, blocked constituents
-- reported as such) over `source_path`, which defaults to the invocation's
-- `;`-separated source roots. Returns a descriptor, `nil, err`, or `nil` when
-- no root has the module.
function driver.resolve_source(context, modname, source_path)
    if type(context) ~= "table" or context.io == nil then
        error("source lookup requires a resolver context", 2)
    end
    driver.assert_target_context(context)
    return resolve_source(source_path or driver.TITAN_SOURCE_PATH, modname,
        context)
end

-- Coordinator and worker entry points; their private helpers stay local to
-- this block.
do

-- A module's current source descriptor exactly as this invocation's loader
-- would select it: relocated under the output root, and coverage-relocated
-- when sources are instrumented. Publication revalidates against it.
local function current_source_descriptor(context, modname)
    local source, source_error = resolve_source(
        driver.TITAN_SOURCE_PATH, modname, context)
    if not source then
        return nil, source_error or ("source module '" .. modname ..
            "' not found")
    elseif source.kind == "blocked" then
        return nil, blocked_source_error(modname, source)
    end
    local relocated, relocation_error = driver.relocate_source_output(
        modname, source, context.output_root)
    if not relocated then return nil, relocation_error end
    local policy = context.codegen_policy
    if policy and policy.coverage then
        local prepared, coverage_error = require("titan-compiler.coverage")
            .source(policy.coverage, modname, source)
        if not prepared then return nil, coverage_error end
    end
    return source
end

-- The coordinator's own scan of a selected archive as closed worker data: its
-- per-module canonical metadata and the precise observation taken right
-- before that scan. Nothing is returned when that observation is coarse or
-- this context's cache no longer holds the selected provider under it.
local function planned_archive_metadata(context, mod)
    local archive, provider = mod.static_archive, mod.static_provider
    local identity = context.provider_cache_identity[archive]
    if not provider or provider.archive ~= archive or
       context.provider_cache[archive] ~= provider or
       type(identity) ~= "table" or not identity.precise then
        return nil
    end
    return {
        observation = identity.precise,
        modules = staticmetadata.container_metadata(provider),
    }
end

-- Close planning and return the coordinator's authoritative plan over the
-- planning loader's selection. `modules[name]` is a planned source (its
-- descriptor, stage-1 certification, ordered imports and failed import
-- diagnostics), the exact selected dynamic or static provider, or an
-- unavailable name with its diagnostic. `archives[path]` carries the
-- coordinator's metadata scan of each selected archive. `order` lists source
-- modules with dependencies first and bytewise ties; import-cycle members
-- follow, bytewise, with `cyclic = true`. Interface digests of source modules
-- exist only once `update` accepts their certified record (hit or published).
-- Implementation notes: doc/implementation/incremental-compilation.md#resolver-and-cli-boundary
function driver.resolution_plan(context)
    if type(context) ~= "table" or context.io == nil then
        error("a resolution plan requires a resolver context", 2)
    end
    driver.assert_target_context(context)
    local binding = context.loader and loader_contexts[context.loader]
    local planning = binding and binding.planning
    if not planning or not planning.open then
        error("a resolution plan requires an open planning loader bound " ..
            "to its resolver context", 2)
    end
    planning.open = false

    local modules, linked, archives = {}, {}, {}
    for name, mod in pairs(driver.imported) do
        if mod ~= CIRCULAR_MARK then
            local node = mod._planned and planning.nodes[name]
            if node then
                modules[name] = {
                    kind = "source", source = node.source,
                    certified = node.certified, imports = node.imports,
                    failed = node.failed,
                }
                linked[name] = true
            elseif mod.kind == "dynamic" then
                modules[name] = {
                    kind = "dynamic", file = mod.filename,
                    relative = mod.relative,
                    provider_file = mod.type and mod.type.file,
                }
            elseif mod.kind == "static" then
                modules[name] = {
                    kind = "static", archive = mod.static_archive,
                    relative = mod.relative,
                }
                linked[name] = true
                for carried in pairs(mod.static_provider and
                        mod.static_provider.entries or {}) do
                    linked[carried] = true
                end
                local archive = mod.static_archive
                if archives[archive] == nil then
                    archives[archive] = planned_archive_metadata(context, mod)
                end
            end
        end
    end
    for name, text in pairs(planning.unavailable) do
        if not modules[name] then
            modules[name] = { kind = "unavailable", error = text }
        end
    end

    local names = {}
    for name, module in pairs(modules) do
        if module.kind == "source" then names[#names + 1] = name end
    end
    table.sort(names, util.bytewise_less)
    local waiting, dependents = {}, {}
    for _, name in ipairs(names) do
        local count, seen = 0, {}
        for _, import in ipairs(modules[name].imports) do
            local dependency = import.name
            if dependency == name then
                modules[name].cyclic = true
            elseif modules[dependency] and modules[dependency].kind == "source"
                   and not seen[dependency] then
                seen[dependency] = true
                count = count + 1
                dependents[dependency] = dependents[dependency] or {}
                table.insert(dependents[dependency], name)
            end
        end
        waiting[name] = count
    end
    local order, ready = {}, {}
    for _, name in ipairs(names) do
        if waiting[name] == 0 and not modules[name].cyclic then
            ready[#ready + 1] = name
        end
    end
    while #ready > 0 do
        table.sort(ready, util.bytewise_less)
        local name = table.remove(ready, 1)
        order[#order + 1] = name
        for _, dependent in ipairs(dependents[name] or {}) do
            waiting[dependent] = waiting[dependent] - 1
            if waiting[dependent] == 0 and not modules[dependent].cyclic then
                ready[#ready + 1] = dependent
            end
        end
    end
    for _, name in ipairs(names) do
        if waiting[name] > 0 or modules[name].cyclic then
            modules[name].cyclic = true
            order[#order + 1] = name
        end
    end

    local accepted = {}
    local plan = { modules = modules, order = order, archives = archives }
    function plan.linked(name)
        driver.assert_target_context(context)
        local module = modules[name]
        if module and module.kind == "unavailable" then return nil end
        local mod, is_linked = certificate_dependency(context, name, linked)
        if not mod then return nil end
        return is_linked
    end
    function plan.provider_file(name)
        driver.assert_target_context(context)
        local module = modules[name]
        return module and module.kind == "dynamic" and module.provider_file or nil
    end
    function plan.path(filename)
        return require("titan-compiler.relocation").path(context, filename)
    end
    function plan.digest(name, view)
        driver.assert_target_context(context)
        local module = modules[name]
        if module and module.kind == "unavailable" then
            return nil, "unavailable"
        elseif module and module.kind == "source" then
            local certified = accepted[name]
            if not certified then return nil, "pending" end
            return incremental.interface_digest(context, certified.record, view)
        end
        local mod = certificate_dependency(context, name, linked)
        if not mod then return nil, "unavailable" end
        return incremental.interface_digest(context, mod, view)
    end
    function plan.update(name, certified)
        driver.assert_target_context(context)
        local module = modules[name]
        if not module or module.kind ~= "source" then
            error("only planned source modules accept a certified record", 2)
        elseif type(certified) ~= "table" or type(certified.record) ~= "table" then
            error("a planned module update requires its certified record", 2)
        end
        accepted[name] = certified
    end
    function plan.accepted(name)
        driver.assert_target_context(context)
        return accepted[name]
    end
    return plan
end

-- The closed data a worker receives for one module: per planned name, the
-- source descriptor (with the accepted object of every certified
-- dependency), the exact selected provider, or the unavailable diagnostic,
-- each with its linked state; and the coordinator's archive metadata scans.
function driver.plan_descriptor(plan, modname)
    local target = plan.modules[modname]
    if not target or target.kind ~= "source" then
        error("the build plan has no source module '" .. tostring(modname) ..
            "'", 2)
    end
    local modules = {}
    for name, module in pairs(plan.modules) do
        local item = { kind = module.kind, linked = plan.linked(name) == true }
        if module.kind == "source" then
            item.source = copy_source_descriptor(module.source)
            if name ~= modname then
                local certified = plan.accepted(name)
                item.object = certified and certified.object or nil
            end
        elseif module.kind == "dynamic" then
            item.file, item.relative = module.file, module.relative
            item.provider_file = module.provider_file
        elseif module.kind == "static" then
            item.archive, item.relative = module.archive, module.relative
        else
            item.error = module.error
        end
        modules[name] = item
    end
    return {
        protocol = version.BUILD_WORKER_PROTOCOL,
        modname = modname,
        modules = modules,
        archives = plan.archives,
        reservations = plan.reservations,
    }
end

local function copy_strings(values)
    local copy = {}
    for index, value in ipairs(values or {}) do copy[index] = value end
    return copy
end

-- Everything a worker needs to reproduce this coordinator's compiler state,
-- as closed data: driver paths and flags, resolver and code-generation
-- policy, actual compiler inventory, and a certificate only when certifiable.
function driver.worker_configuration(context)
    local configuration, configuration_error, status =
        driver.incremental_configuration(context)
    if not configuration and status ~= "uncertified" then
        return nil, configuration_error
    end
    local compiler = configuration and configuration.compiler
    if not compiler then
        local compiler_error
        compiler, compiler_error = incremental.compiler_component(context)
        if not compiler then return nil, compiler_error end
    end
    -- This is requested lazily, after graph/output preflight and before the
    -- first worker starts. Source-checkout runtime builds belong exclusively
    -- to the coordinator, including a certified hit that falls back to a miss.
    if not context.target_descriptor then
        local runtime_ok, runtime_error = perf.check_runtime(context.probe_verbose)
        if not runtime_ok then return nil, runtime_error end
    end
    local policy = context.codegen_policy or {}
    return {
        protocol = version.BUILD_WORKER_PROTOCOL,
        target_descriptor = context.target_descriptor and
            driver._browser_target.export(context.target_descriptor) or nil,
        driver = {
            source_path = driver.TITAN_SOURCE_PATH,
            bin_path = driver.TITAN_BIN_PATH,
            lua_source_path = driver.LUA_SOURCE_PATH,
            emit_line_directives = driver.EMIT_LINE_DIRECTIVES,
            output_root = driver.OUTPUT_ROOT,
            clang_format = driver.CLANG_FORMAT,
            runtime_prepared = perf.runtime_checked == true,
            extra_cppflags = copy_strings(driver.EXTRA_CPPFLAGS),
            extra_cflags = copy_strings(driver.EXTRA_CFLAGS),
            native_compile_flags = driver.NATIVE_COMPILE_FLAGS and
                copy_strings(driver.NATIVE_COMPILE_FLAGS) or nil,
        },
        resolver = {
            target = assert(driver.context_target(context)),
            prefer_static = context.prefer_static,
            source_first = context.source_first,
            verbose = context.probe_verbose,
            pretty_print = context.pretty_print,
            output_root = context.output_root,
            jobs = context.jobs,
            frontend = context.frontend,
            extra_ffi_include_dirs = copy_strings(context.extra_ffi_include_dirs),
        },
        policy = {
            c_parts = policy.c_parts,
            split_threshold = policy.split_threshold,
            test = policy.test == true,
            coverage = policy.coverage,
        },
        compiler = compiler,
        uncertified = status == "uncertified" and configuration_error or nil,
        configuration = configuration,
    }
end

-- A worker's resolver context from `driver.worker_configuration` data. The
-- worker always verifies the compiler Lua it actually loaded. A complete
-- certificate or the coordinator's explicit uncertified policy is inherited.
function driver.new_worker_context(configuration, io_strategy)
    if type(configuration) ~= "table" or
       configuration.protocol ~= version.BUILD_WORKER_PROTOCOL or
       type(configuration.driver) ~= "table" or
       type(configuration.resolver) ~= "table" or
       type(configuration.policy) ~= "table" or
       type(configuration.compiler) ~= "string" or
       not ((type(configuration.configuration) == "table" and
             configuration.configuration.compiler == configuration.compiler and
             configuration.uncertified == nil) or
            (configuration.configuration == nil and
             type(configuration.uncertified) == "string")) then
        return nil, "incompatible build worker configuration"
    end
    local target_descriptor
    if configuration.resolver.target == "browser" then
        target_descriptor = driver._browser_target.import(configuration.target_descriptor)
        if not target_descriptor then return nil, "incompatible build worker configuration" end
    elseif configuration.target_descriptor ~= nil then
        return nil, "incompatible build worker configuration"
    end
    local settings = configuration.driver
    driver.TITAN_SOURCE_PATH = settings.source_path
    driver.TITAN_BIN_PATH = settings.bin_path
    driver.LUA_SOURCE_PATH = settings.lua_source_path
    driver.EMIT_LINE_DIRECTIVES = settings.emit_line_directives
    driver.OUTPUT_ROOT = settings.output_root
    driver.CLANG_FORMAT = settings.clang_format
    driver.EXTRA_CPPFLAGS = copy_strings(settings.extra_cppflags)
    driver.EXTRA_CFLAGS = copy_strings(settings.extra_cflags)
    driver.NATIVE_COMPILE_FLAGS = settings.native_compile_flags and
        copy_strings(settings.native_compile_flags) or nil
    local support_loaded, support = pcall(require, "titan")
    if not support_loaded or type(support) ~= "table" or
       type(support._sha256_binary) ~= "function" or
       type(support._sha256_stream) ~= "function" then
        return nil, "the installed Titan native support library is " ..
            "missing or stale (it lacks _sha256_binary or _sha256_stream)"
    end
    local resolver = configuration.resolver
    local initialized, context = pcall(driver._new_resolver_context, {
        io = io_strategy,
        target = resolver.target,
        cache_adapter = { sha256_binary = support._sha256_binary,
            sha256_stream = support._sha256_stream },
        prefer_static = resolver.prefer_static,
        source_first = resolver.source_first,
        verbose = resolver.verbose,
        pretty_print = resolver.pretty_print,
        output_root = resolver.output_root,
        jobs = resolver.jobs,
        frontend = resolver.frontend,
        extra_ffi_include_dirs = resolver.extra_ffi_include_dirs,
    }, target_descriptor)
    if not initialized then
        if type(context) ~= "string" then error(context, 0) end
        return nil, context
    end
    local function fail(message)
        driver.close_resolver_context(context)
        return nil, message
    end
    if driver.TOOLCHAIN_ERROR then return fail(driver.TOOLCHAIN_ERROR) end
    local configured, configure_error = driver.configure_foreign_c(context)
    if not configured and configure_error then return fail(configure_error) end
    local policy = configuration.policy
    context.codegen_policy = {
        c_parts = policy.c_parts,
        split_threshold = policy.split_threshold,
        test = policy.test == true,
        coverage = policy.coverage,
    }
    local options, options_error = incremental_options(context)
    if not options then return fail(options_error) end
    local compiler, compiler_error =
        incremental.compiler_component(context, options)
    if not compiler then
        return fail("cannot certify compiler configuration: " ..
            tostring(compiler_error))
    elseif compiler ~= configuration.compiler then
        return fail("compiler installation changed during build")
    end
    context.incremental_options = options
    context.incremental_configuration = configuration.configuration
    context.incremental_uncertified = configuration.uncertified
    perf.runtime_checked = settings.runtime_prepared == true
    return context
end

-- A path this invocation rewrites must be hashed afresh by any later reader:
-- forget its memoized digest under both its written and absolute spellings.
local function forget_digests(context, filenames)
    for _, filename in ipairs(filenames) do
        incremental.invalidate_file(context, filename)
        local called, absolute = pcall(normalized_absolute_filename, filename)
        if called and absolute ~= filename then
            incremental.invalidate_file(context, absolute)
        end
    end
end

-- Parent-only, right before a missed module's worker starts: retire its
-- committed object. The primary object is the commit marker, so it is
-- unlinked first; then the higher parts and coverage notes its record names.
-- An interruption at any later point leaves no acceptable object.
function driver.invalidate_source_object(context, modname, source)
    driver.assert_target_context(context)
    local stem = driver.module_output_stem(
        source.native_output or source.main, modname)
    local primary = stem .. ".o"
    local attributes = context.io:lstat(primary)
    if not attributes then return true end
    if attributes.kind == "directory" then
        return nil, "object output '" .. primary .. "' for module '" ..
            modname .. "' is a directory"
    end
    local prior = {}
    if attributes.kind == "file" then
        local bytes = perf.compiler_file_contents(context, primary)
        local record = bytes and objectmetadata.read(bytes, primary)
        local native = record and record.object_metadata
        if native and native.parts and objectmetadata.validate_parts(native) then
            for _, part in ipairs(native.parts) do
                if part.index >= 1 then
                    local part_stem = stem .. ".part" .. tostring(part.index)
                    prior[#prior + 1] = part_stem .. ".o"
                    prior[#prior + 1] = part_stem .. ".c"
                    prior[#prior + 1] = part_stem .. ".gcno"
                    prior[#prior + 1] = part_stem .. ".gcda"
                end
            end
        end
    end
    local removed, remove_error = context.io:unlink(primary)
    if not removed then
        return nil, "cannot invalidate object for module '" .. modname ..
            "': " .. tostring(remove_error)
    end
    for _, sibling in ipairs(prior) do
        if context.io:lstat(sibling) then context.io:unlink(sibling) end
    end
    forget_digests(context, prior)
    forget_digests(context, { primary })
    return true
end

-- Worker: check and compile exactly one planned module. `options.plan` is
-- `driver.plan_descriptor` data. Generated C and headers are written at their
-- final paths (the coordinator already retired the old primary); every
-- object part is compiled to a unique sibling temporary that only the
-- coordinator publishes. Returns `{ modname, object, objects, staged =
-- {{from, to, role}}, diagnostics = {} }` or `nil, diagnostics text`.
function driver.compile_planned_module(context, modname, options)
    driver.assert_target_context(context)
    options = options or {}
    local plan = options.plan
    if type(plan) ~= "table" or plan.protocol ~= version.BUILD_WORKER_PROTOCOL
       or plan.modname ~= modname or type(plan.modules) ~= "table"
       or type(plan.modules[modname]) ~= "table"
       or plan.modules[modname].kind ~= "source" then
        return nil, "invalid build plan for module '" .. tostring(modname) .. "'"
    end
    local policy = context.codegen_policy or {}
    local test = options.test
    if test == nil then test = policy.test end
    local c_parts = options.c_parts or policy.c_parts
    local verbose = options.verbose == true
    local coverage_build = policy.coverage
    local source = copy_source_descriptor(plan.modules[modname].source)
    -- The optional phase callback reports the boundaries a progress reporter
    -- shows; a compile started for any other module leaves it untouched.
    local on_phase = options.on_phase
    -- Provider inspection reuses the coordinator's archive metadata scans.
    context.planned_archives = type(plan.archives) == "table" and
        plan.archives or nil
    local loader = driver.defaultloader({}, {
        context = context,
        worker_plan = plan,
        source_roots = { [modname] = true },
        source_overrides = { [modname] = source },
        test = test,
        coverage = coverage_build,
        output_root = context.output_root,
        c_parts = c_parts,
        split_threshold = policy.split_threshold,
        on_phase = on_phase and function(phase, name)
            if name == modname then on_phase(phase) end
        end or nil,
    })
    local ok, errors = checker.checkimport(modname, loader)
    if not ok then return nil, tostring(errors) end
    if #errors > 0 then return nil, table.concat(errors, "\n") end
    local mod = driver.imported[modname]
    local header_inputs = {}
    for _, dependency in ipairs(mod.c_header_dependencies or {}) do
        if dependency.kind ~= "search" then
            header_inputs[#header_inputs + 1] = dependency.filename or dependency.path
        end
    end
    local reserved_ok, reserved_error = driver.validate_reserved_output_inputs(
        plan.reservations, header_inputs)
    if not reserved_ok then return nil, reserved_error end
    local finalized, finalize_errors = driver.finalize_resolver_context(context)
    if not finalized then return nil, table.concat(finalize_errors, "\n") end
    for name, planned in pairs(plan.modules) do
        local selected = driver.imported[name]
        if selected and selected ~= CIRCULAR_MARK and
           planned.kind ~= "unavailable" and
           (context.native_static_names[name] == true) ~= (planned.linked == true) then
            return nil, "build plan divergence: module '" .. name .. "' is " ..
                (planned.linked and "linked" or "not linked") ..
                " in the plan but not in the worker's selection"
        end
    end

    local extra_flags = {}
    local coverage_selected = false
    if coverage_build then
        local coverage = require("titan-compiler.coverage")
        coverage_selected = coverage.matches(coverage_build, modname,
            coverage.test_functions(mod.ast)) == true
        coverage_build.selected[modname] = coverage_selected or nil
        extra_flags = coverage.compile_flags(coverage_build, modname) or {}
    end
    coder.prepare_coverage(mod.ast, coverage_build ~= nil)
    local header_plans, header_error = driver.plan_foreign_headers(
        { modname }, driver.imported,
        function(name) return driver.header_policy(
            name == modname and coverage_selected) end)
    if not header_plans then return nil, header_error end
    local request = {
        modname = modname,
        mod = mod,
        static_deps = context.native_static_names,
        options = {
            context = context,
            test = test,
            pretty_print = context.pretty_print,
            nominal_layouts = context.nominal_layouts,
            extra_compile_flags = extra_flags,
            coverage = coverage_selected,
            coverage_backend = coverage_build and coverage_build.backend,
            c_parts = c_parts,
            split_threshold = policy.split_threshold,
            staged = true,
        },
    }
    if on_phase then on_phase("generating C") end
    local plans, plan_error = driver.plan_compile_requests(
        { request }, verbose, nil, nil, header_plans)
    if not plans then return nil, plan_error end
    local written, write_error = driver.write_foreign_header_plans(
        header_plans, verbose, context.pretty_print)
    if not written then return nil, write_error end
    local compilation, materialize_error = plans[1].materialize()
    plans[1].materialize = nil
    if not compilation then return nil, materialize_error end
    jobs.set_request_index(compilation, 1)

    local parallelism = options.jobs or context.jobs or 1
    -- The worker owns this phase on both paths: a multi-part compile is sent
    -- as a native batch by `run_prepared_compiles`, and a single part compiles
    -- right here. Native batches also carry the checker's speculative C-probe
    -- work, which belongs to `checking`, so the coordinator never infers this
    -- phase from a batch it receives or answers.
    if on_phase and #compilation.jobs > 0 then
        on_phase("compiling C", #compilation.jobs > 1 and
            (#compilation.jobs .. " parts") or nil)
    end
    local result, cancelled
    if parallelism > 1 and #compilation.jobs > 1 then
        local compiled
        compiled, cancelled = driver.run_prepared_compiles(
            { compilation }, parallelism, verbose)
        result = compiled[1]
    else
        result = { ok = true }
        for _, job in ipairs(compilation.jobs) do
            local job_ok, job_err = run_argv(job.argv, verbose)
            if result.ok and not job_ok then result = { err = job_err } end
        end
    end
    if cancelled or not result.ok then
        for _, job in ipairs(compilation.jobs) do
            os.remove(job.temporary_object)
        end
        jobs.propagate(cancelled)
        return nil, result.err
    end
    -- Every final path this worker wrote; the coordinator forgets their
    -- memoized digests before anything in its invocation reads them again.
    local written = {}
    for _, job in ipairs(compilation.jobs) do written[#written + 1] = job.c_path end
    if compilation.private_header then
        written[#written + 1] = compilation.private_header
    end
    for _, header in ipairs(header_plans) do
        if header.filename then written[#written + 1] = header.filename end
        if header.ffi_header and header.ffi_header.filename then
            written[#written + 1] = header.ffi_header.filename
        end
    end
    local staged = {}
    for index, job in ipairs(compilation.jobs) do
        staged[index] = {
            from = job.temporary_object,
            to = job.object_path,
            role = job.part_index == 0 and "primary" or "part",
        }
    end
    return {
        modname = modname,
        object = compilation.primary_object,
        objects = compilation.objects,
        staged = staged,
        written = written,
        -- Invocation-only input evidence, never an object certificate.
        source_snapshot = context.incremental_uncertified and
            mod.source_certificate or nil,
        diagnostics = {},
    }
end

local function revalidate_uncertified_module(context, modname, source, record, snapshot)
    if not record.type or record.type.name ~= modname or
       record.object_metadata.certificate ~= nil or type(snapshot) ~= "table" then
        return nil, "invalid uncertified worker input snapshot"
    end
    local fresh = incremental.fresh_context(context)
    fresh.header_validation, fresh.header_observations = {}, {}
    local current = incremental.source_certificate(fresh, {
        kind = source.kind, files = source.files,
    })
    if incremental.digest(fresh, "publication-sources", current) ~=
       incremental.digest(fresh, "publication-sources", snapshot) then
        return nil, "source-content"
    end
    for _, inputs in ipairs({
            record.c_header_dependencies or {},
            record.ffi_header_descriptor and
                record.ffi_header_descriptor.search_inputs or {} }) do
        local headers, header_error, changed, reason =
            perf.restat_c_header_dependencies(inputs, fresh)
        if not headers or changed then return nil, reason or header_error end
    end
    return true
end

-- Parent-only publication of a worker's staged object. The module's current
-- source descriptor is resolved afresh and its recorded own sources and C
-- inputs are revalidated with a fresh pass, so an edit during the build is
-- an error rather than a certified mismatch. Uncertified workers supply only
-- transient source evidence; their header inputs are still revalidated. Parts
-- are renamed first and the primary last; any failure leaves no primary.
-- Returns the published metadata (`status`, `record`, `object`, `objects`,
-- `imports`), with status `built` rather than `hit` when uncertified.
function driver.publish_staged_module(context, result)
    driver.assert_target_context(context)
    local modname = result.modname
    local primary, parts = nil, {}
    for _, staged in ipairs(result.staged or {}) do
        if staged.role == "primary" then primary = staged
        else parts[#parts + 1] = staged end
    end
    local function discard(message)
        for _, staged in ipairs(result.staged or {}) do
            if context.io:lstat(staged.from) then context.io:unlink(staged.from) end
        end
        return nil, message
    end
    if not primary then
        return discard("worker result for module '" .. tostring(modname) ..
            "' has no primary object")
    end
    local bytes, read_error = perf.compiler_file_contents(
        incremental.fresh_context(context), primary.from)
    if not bytes then
        return discard("cannot read staged object for module '" .. modname ..
            "': " .. tostring(read_error))
    end
    local record, record_error = objectmetadata.read(bytes, primary.to)
    if not record or type(record.object_metadata) ~= "table" then
        return discard("cannot decode staged object for module '" .. modname ..
            "': " .. tostring(record_error))
    end
    local source, source_error = current_source_descriptor(context, modname)
    if not source then
        return discard("cannot resolve module '" .. modname ..
            "' for publication: " .. tostring(source_error))
    end
    if context.incremental_uncertified then
        local called, valid, input_error = pcall(revalidate_uncertified_module,
            context, modname, source, record, result.source_snapshot)
        if not called and type(valid) ~= "string" then error(valid, 0) end
        if not called or not valid then
            return discard("inputs of module '" .. modname ..
                "' changed during the build: " .. tostring(called and input_error or valid))
        end
    else
        local check = incremental.revalidate_record(context, modname, source, record)
        if check.status ~= "hit" then
            return discard("inputs of module '" .. modname ..
                "' changed during the build: " .. tostring(check.reason) ..
                (check.detail and check.detail ~= "" and
                    (" " .. tostring(check.detail)) or ""))
        end
    end
    if context.io:lstat(primary.to) then
        local removed, remove_error = context.io:unlink(primary.to)
        if not removed then
            return discard("cannot replace object for module '" .. modname ..
                "': " .. tostring(remove_error))
        end
    end
    for index = #parts, 1, -1 do
        local renamed, rename_error =
            context.io:rename(parts[index].from, parts[index].to)
        if not renamed then
            return discard("cannot publish object part '" .. parts[index].to ..
                "': " .. tostring(rename_error))
        end
    end
    local renamed, rename_error = context.io:rename(primary.from, primary.to)
    if not renamed then
        if context.io:lstat(primary.to) then context.io:unlink(primary.to) end
        return discard("cannot publish object '" .. primary.to .. "': " ..
            tostring(rename_error))
    end
    -- Published objects and the worker's generated files replaced bytes this
    -- invocation may already have hashed (certification, link inputs).
    local rewritten = {}
    for _, staged in ipairs(result.staged or {}) do
        rewritten[#rewritten + 1] = staged.from
        rewritten[#rewritten + 1] = staged.to
    end
    for _, filename in ipairs(result.written or {}) do
        rewritten[#rewritten + 1] = filename
    end
    forget_digests(context, rewritten)
    return {
        status = context.incremental_uncertified and "built" or "hit",
        record = record,
        object = primary.to,
        objects = result.objects,
        imports = record.object_metadata.imports,
    }
end

end -- coordinator and worker entry points

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

    local context = resolver_context_from_options(options, 2)
    local results = {}
    local names = {}
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

perf.FINAL_SELECTION_FIELDS = {
    "kind", "compiled", "ast", "type", "filename", "relative",
    "static_archive", "static_provider", "embedded_provider",
    "object_metadata", "layout_inventory", "layouts",
}

function perf.resolver_selection(context, previous)
    if previous and
       (previous.loader ~= context.loader or
        previous.analysis_only ~= context.analysis_only or
        previous.embedded_provider ~= context.embedded_interface_provider or
        previous.embedded_rejected ~= context.embedded_interface_provider_rejected or
        previous.embedded_overlap ~= context.embedded_interface_provider_overlap) then
        return false
    end
    local snapshot = not previous and {
        modules = {}, resolutions = {},
        loader = context.loader, analysis_only = context.analysis_only,
        embedded_provider = context.embedded_interface_provider,
        embedded_rejected = context.embedded_interface_provider_rejected,
        embedded_overlap = context.embedded_interface_provider_overlap,
    } or nil
    local count = 0
    for name, mod in pairs(driver.imported) do
        count = count + 1
        local saved = previous and previous.modules[name]
        if previous and (not saved or saved.entry ~= mod) then return false end
        local entry = not previous and { entry = mod } or nil
        if mod ~= CIRCULAR_MARK then
            for _, field in ipairs(perf.FINAL_SELECTION_FIELDS) do
                if previous then
                    if saved[field] ~= mod[field] then return false end
                else entry[field] = mod[field] end
            end
            local provider_file = mod.type and mod.type.file
            if previous then
                if saved.provider_file ~= provider_file then return false end
            else entry.provider_file = provider_file end
        end
        if snapshot then snapshot.modules[name] = entry end
    end
    if previous and previous.module_count ~= count then return false end
    if snapshot then snapshot.module_count = count end
    count = 0
    for key, resolution in pairs(context.contextual_resolutions or {}) do
        count = count + 1
        if previous then
            if previous.resolutions[key] ~= resolution then return false end
        else snapshot.resolutions[key] = resolution end
    end
    if previous then return previous.resolution_count == count end
    snapshot.resolution_count = count
    return snapshot
end

function driver.finalize_resolver_context(context)
    driver.assert_target_context(context)
    reconcile_embedded_import_cache(context)
    if context.finalized_selection and
       perf.resolver_selection(context, context.finalized_selection) then
        return context
    end
    context.finalized_selection = nil
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

    -- Reused machine code has already chosen direct, handle, or global
    -- references. A later invocation may select different providers, but may
    -- not silently treat this object as freshly generated under that policy.
    for name in pairs(source_names) do
        local native = driver.imported[name].object_metadata
        if native then
            local imports
            for dependency, binding in pairs(native.bindings) do
                local selected = driver.imported[dependency]
                local expected = native_bindings[dependency]
                -- Codegen chooses a handle only for this module's written
                -- imports. An indirectly exposed dynamic owner uses globals
                -- even when another module independently imports its DSO.
                -- Keep absent owners absent and native-direct owners direct.
                if expected == "handle" or expected == "global" then
                    if not imports then
                        imports = {}
                        for _, imported in ipairs(native.imports) do
                            imports[imported.name] = true
                        end
                    end
                    expected = imports[dependency] and "handle" or "global"
                end
                if binding == "handle" and selected and selected.kind == "dynamic" then
                    if selected.type.file ~= native.providers[dependency] then
                        errors[#errors + 1] = "object for module '" .. name ..
                            "' loads a different provider for '" .. dependency ..
                            "'; rebuild it with the selected dependency providers"
                    end
                elseif expected ~= binding then
                    errors[#errors + 1] = "object for module '" .. name ..
                        "' requires " .. binding .. " binding for '" .. dependency ..
                        "'; rebuild it with the selected dependency providers"
                end
            end
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

    -- Rebuild the codegen-only map from surviving physical provenance. In
    -- particular, a source replacement must not inherit stale binary plans.
    context.nominal_layouts = {}
    for _, provider in ipairs(selected_static_providers) do
        for _, entry in pairs(provider.entries) do
            remember_nominal_layouts(context, entry.layout_inventory)
        end
    end
    for _, mod in pairs(dynamic_names) do
        remember_nominal_layouts(context, mod.layout_inventory)
    end
    for _, resolution in pairs(contextual_resolutions) do
        local provider = context.nominal_layout_inventories[resolution.provider_file]
        remember_nominal_layouts(context, provider and provider[resolution.owner])
    end

    if #errors ~= 0 then return nil, errors end
    context.finalized_selection = perf.resolver_selection(context)
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

-- Implementation notes: doc/implementation/driver.md#drivertableloadermodtable-imported-deps-options
function driver.tableloader(modtable, imported, deps, options)
    deps = deps or {}
    options = options or {}
    local context = options.context
    driver.assert_target_context(context)
    local source_view = options.interface == "source"

    local function source_requested(request)
        return request and request.kind == "source-import"
    end

    local function source_owner_requested(modname, request)
        if not request or request.kind ~= "nominal-owner"
           or type(request.exposer) ~= "string" then return false end
        local producer = imported[request.exposer]
        return type(producer) == "table" and producer.kind == "source"
            and producer.source_type ~= nil
            and source_import_permissions(producer)[modname] == true
    end

    local function selected_interface(modname, mod, request)
        -- A retained source producer may need an owner's private signatures to
        -- validate its own declarations. Recover that owner's source view only
        -- through the producer's checked direct source edge. Ordinary aliases
        -- keep the separately serialized public view and consumer permissions.
        if (source_view or source_requested(request)
            or source_owner_requested(modname, request)) and
           mod.kind == "source" and mod.source_type then
            return mod.source_type, {
                kind = "source",
                filename = mod.filename,
                foreign_header = mod.checking_foreign_header,
                foreign_header_for_check = mod.checking_foreign_header ~= nil,
                foreign_header_probe_identity = mod.foreign_header,
                ffi_header = mod.ffi_header,
                checking_ffi_header = mod.checking_ffi_header,
                ffi_header_descriptor = mod.ast and mod.ast._ffi_header,
                source_permissions = source_import_permissions(mod),
            }
        end
        return mod.type, { kind = mod.kind == "source"
            and "compiled" or mod.kind }
    end

    local function loader(modname, request)
        driver.assert_target_context(context)
        if not staticmetadata.valid_module_name(modname) then
            return false, "invalid logical Titan module name " ..
                string.format("%q", modname)
        end
        local source_required = source_requested(request)
            or source_owner_requested(modname, request)
        if imported[modname] == CIRCULAR_MARK then
            imported[modname] = nil
            return false, "circular reference to module"
        end
        if imported[modname] and imported[modname].ast and
           imported[modname].ast._analysis_only and not context.analysis_only then
            if modtable[modname] == nil then
                return false, "cached analysis AST for module '" .. modname ..
                    "' requires an analysis-only resolver"
            end
            imported[modname] = nil
        end
        if imported[modname] then
            local mod = imported[modname]
            if source_required and
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
                local modtype, info = selected_interface(modname, mod, request)
                return true, modtype, {}, info
            end
        end
        local modf = "./" .. modname .. ".titan"
        local input = modtable[modname]
        if input == nil then
            local message = source_required
                and ("source module '" .. modname .. "' not found")
                or ("module '" .. modname .. "' not found")
            return false, message
        end
        local ast, err = parser.parse(modf, input)
        if not ast then return false, parser.error_to_string(err, modf) end
        imported[modname] = CIRCULAR_MARK
        local source_type, errors = check_source_module(
            context, modname, ast, input, modf, loader, nil, function()
                local fresh, parse_err = parser.parse(modf, input)
                if not fresh then return nil, parser.error_to_string(parse_err, modf) end
                return fresh
            end)
        check_used_compiled_interface(
            context, modname, source_type, errors)
        local checking_foreign_header
        if #errors == 0 then
            local header_error
            checking_foreign_header, header_error =
                prepare_source_checking_header(context, modname, ast)
            if header_error then errors[#errors + 1] = header_error end
        end
        local foreign_header = driver.ast_has_foreign_functions(ast)
            and driver.foreign_header_filename(modf) or nil
        local ffi_descriptor = ast._ffi_header
        if #errors ~= 0 then
            imported[modname] = {
                kind = "source", ast = ast, type = source_type, completion = ast._completion,
                source_type = source_type, filename = modf,
                foreign_header = foreign_header,
                checking_foreign_header = checking_foreign_header,
                ffi_header = ffi_descriptor and ffi_descriptor.identity,
                checking_ffi_header = ffi_descriptor and ffi_descriptor.filename,
            }
            deps[modname] = true
            local modtype, info = selected_interface(
                modname, imported[modname], request)
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
        local references_ok, references_error = types.resolve_compiled_c_references(modt_or_err)
        if not references_ok then return false, references_error end
        imported[modname] = {
            kind = "source", ast = ast, type = modt_or_err, completion = ast._completion,
            source_type = source_type, filename = modf,
            foreign_header = foreign_header,
            checking_foreign_header = checking_foreign_header,
            ffi_header = ffi_descriptor and ffi_descriptor.identity,
            checking_ffi_header = ffi_descriptor and ffi_descriptor.filename,
        }
        deps[modname] = true
        local modtype, info = selected_interface(modname, imported[modname], request)
        return true, modtype, errors, info
    end
    loader_contexts[loader] = {
        context = context,
    }
    return loader
end

function driver.close_tableloader(loader)
    return driver.close_loader(loader)
end

-- Native publication may run before any semantic resolver. Recover only the
-- host platform; never activate or replace the process's semantic cache pair.
function driver.shared_library_flags(context)
    local initialized, platform_error = perf.initialize_native_platform(context)
    if not initialized then return nil, platform_error end

    local shared = { "-shared" }
    if platform.windows then
        table.insert(shared, "-Wl,--exclude-all-symbols")
    end
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
    if options and options.context then driver.assert_target_context(options.context) end
    if mod.compiled then return true, nil, nil end
    local ok, err, libname, native_references, objects = driver.compile(
        modname, mod.ast, mod.native_output or mod.filename,
        static_deps, verbose, options, mod)
    if not ok then return nil, err end
    mod.compiled = libname
    mod.compiled_objects = assert(objects)
    mod.native_references = native_references or {}
    return true, nil, libname
end

local RUNTIME_ARCHIVE_INPUTS = {
    "titan.c",
    "titan.h",
    "minicoro.c",
    "minicoro.h",
    "transfer.h",
    "titan/ffi.h",
    "titan_path.c",
    "ltitanlib.c",
}
local RUNTIME_ARCHIVE_MEMBERS = {
    "titan.o",
    "minicoro.o",
    "titan_path.o",
    "ltitanlib.o",
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
    local ar, err = parsed_words(platform.getenv("AR") or "ar", "AR")
    if not ar then return false, err end
    if #ar == 0 then return false, "AR command is empty" end
    append_argv(ar, { "t", runtime_lib })
    local cmd
    cmd, err = command_argv(ar)
    if not cmd then return false, err end
    if platform.windows or driver.OUTPUT_LOCKS then
        local options
        if not platform.windows then
            ar = { "/bin/sh", "-c", cmd }
            options = { inherit = driver.OUTPUT_LOCKS:descriptors() }
        end
        local result = require("titan-compiler.process").capture(ar, options)
        local output = result.output or result.diagnostic or ""
        return result.ok and driver.runtime_archive_members_are_exact(output), output
    end
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

function perf.check_runtime(verbose)
    perf.runtime_checked = perf.runtime_checked or driver.INSTALLED
    if perf.runtime_checked then return true end
    local runtime_lib = driver.TITAN_RUNTIME_PATH .. "libtitan.a"
    if platform.getenv("TITAN_RUNTIME_PREBUILT") ~= "1" then
        local make, err = parsed_words(platform.getenv("MAKE") or "make", "MAKE")
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
    perf.runtime_checked = true
    return true
end

function driver.installed_link_inputs(paths, is_darwin)
    if platform.windows then
        return { paths.libtitan, paths.libbacktrace, paths.liblua,
            "-static-libgcc" }
    end
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
    if platform.windows then
        return {
            driver.TITAN_RUNTIME_PATH .. "libtitan.a",
            lua_source_path .. "/../../lib/libbacktrace.a",
            lua_source_path .. "/../../lib/liblua55.a",
            "-static-libgcc",
        }
    end
    local lua_archive = lua_source_path .. "/liblua.a"
    if driver.INSTALL_PATHS and
       physical_absolute_filename(lua_source_path) ==
           physical_absolute_filename(driver.INSTALL_PATHS.lua_source) then
        -- The matching installed Lua SDK keeps its archive outside the
        -- internal source/header directory, including through prefix aliases.
        lua_archive = driver.INSTALL_PATHS.liblua
    end
    return {
        driver.TITAN_RUNTIME_PATH .. "libtitan.a",
        driver.LIBBACKTRACE_PATH .. "/.libs/libbacktrace.a",
        lua_archive,
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

driver.PRIVATE_HEADER_MARKER = coder.PRIVATE_HEADER_MARKER

driver.module_output_stem = source_selection.output_stem

function driver.foreign_header_filename(sourcef)
    assert(sourcef:sub(-6) == ".titan", "foreign header source path must end in .titan")
    return driver.module_output_stem(sourcef) .. ".titan.h"
end

function driver.ffi_header_filename(sourcef)
    assert(sourcef:sub(-6) == ".titan", "FFI header source path must end in .titan")
    return driver.module_output_stem(sourcef) .. ".ffi.h"
end

function driver.private_header_filename(sourcef)
    return driver.module_output_stem(sourcef) .. ".priv.h"
end

function driver.part_c_filename(stem, part_index)
    stem = driver.module_output_stem(stem)
    assert(type(part_index) == "number" and part_index >= 0
        and part_index % 1 == 0, "part_index must be a nonnegative integer")
    return part_index == 0 and (stem .. ".c")
        or (stem .. ".part" .. tostring(part_index) .. ".c")
end

function driver.part_object_filename(stem, part_index)
    stem = driver.module_output_stem(stem)
    assert(type(part_index) == "number" and part_index >= 0
        and part_index % 1 == 0, "part_index must be a nonnegative integer")
    return part_index == 0 and (stem .. ".o")
        or (stem .. ".part" .. tostring(part_index) .. ".o")
end

function driver.default_c_parts()
    if platform.windows or driver.IS_DARWIN then return 1 end
    if driver.UNAME and not driver.UNAME:find("Linux", 1, true) then
        return 1
    end
    return 4
end

function driver.parse_c_parts(value)
    if value == nil then return nil end
    if type(value) == "number" then
        if value >= 1 and value % 1 == 0 and value <= math.maxinteger then
            return value
        end
        return nil, "--c-parts and TITAN_C_PARTS require a positive integer"
    end
    if type(value) ~= "string" or not value:match("^[1-9][0-9]*$") then
        return nil, "--c-parts and TITAN_C_PARTS require a positive integer"
    end
    local parsed = tonumber(value)
    if not parsed or parsed > math.maxinteger then
        return nil, "--c-parts and TITAN_C_PARTS require a positive integer"
    end
    return parsed
end

function driver.effective_c_parts(override)
    if override ~= nil then
        return driver.parse_c_parts(override)
    end
    local env_val = platform.getenv("TITAN_C_PARTS")
    if env_val ~= nil then
        return driver.parse_c_parts(env_val)
    end
    return driver.default_c_parts()
end


function driver.module_compiled_objects(mod)
    assert(mod and type(mod.compiled_objects) == "table"
        and #mod.compiled_objects > 0, "module needs an explicit ordered object list")
    return mod.compiled_objects
end

function driver.record_module_symbols(symbol_owners, modname, symbols, errors)
    local coder_names = require "titan-compiler.coder.core"
    local linkage_fn = coder_names.coder and coder_names.coder._linkage_symbol_name
    for _, entry in ipairs(symbols or {}) do
        local key = linkage_fn and linkage_fn(entry.symbol) or entry.symbol
        local previous = symbol_owners[key]
        if previous and not (previous.module == modname and previous.owner == entry.owner) then
            errors[#errors + 1] = "cannot link C symbol '" ..
                entry.symbol .. "': " .. previous.owner ..
                " in logical module '" .. previous.module ..
                "' conflicts with " .. entry.owner ..
                " in logical module '" .. modname .. "'"
        else
            symbol_owners[key] = {
                module = modname,
                owner = entry.owner,
                symbol = entry.symbol,
            }
        end
    end
end
function driver.ast_has_foreign_functions(ast)
    for _, node in ipairs(ast or {}) do
        if not node._ignore and node._tag == "Ast.TopLevelForeignFunc" then
            return true
        end
    end
    return false
end

-- Foreign headers are rendered before, and for restored plans independently
-- of, C generation. Their line/coverage policy is therefore an explicit input
-- derived from the current options, never ambient coder state left by another
-- generation.
function driver.header_policy(coverage)
    -- Internal coder helper: the public facade exposes only supported APIs.
    local internal = require("titan-compiler.coder.core").coder
    return internal._emission_policy(driver.EMIT_LINE_DIRECTIVES, coverage)
end

function driver.plan_foreign_header(
        modname, ast, sourcef, defer_render, policy)
    sourcef = sourcef or modname:gsub("[.]", "/") .. ".titan"
    policy = policy or driver.header_policy(false)
    local headername = driver.foreign_header_filename(sourcef)
    local has_foreign = driver.ast_has_foreign_functions(ast)
    local absolute_header = normalized_absolute_filename(headername)
    local ffi_headername = driver.ffi_header_filename(sourcef)
    local absolute_ffi_header = normalized_absolute_filename(ffi_headername)
    ast._foreign_header_output = has_foreign and absolute_header or nil
    ast._ffi_header_output = absolute_ffi_header
    local internal = require("titan-compiler.coder.core").coder
    local contents, recipe
    if has_foreign and not defer_render then
        contents, recipe = coder.generate_foreign_header(
            modname, ast, { module = modname }, nil, policy)
    end
    return {
        modname = modname,
        ast = ast,
        filename = headername,
        absolute = absolute_header,
        marker = ffiheaders.FOREIGN_MARKER,
        has_foreign = has_foreign,
        contents = contents,
        recipe = recipe,
        -- The plan is one immutable published unit: policy, the checked module
        -- object it was rendered from, contents and the digest of the recipe
        -- (which includes the policy) that produced them. Its `ast` reference is
        -- what a later compile compares by identity.
        policy = policy,
        digest = internal._foreign_header_digest(recipe),
        ffi_header = {
            filename = ffi_headername,
            absolute = absolute_ffi_header,
            marker = ffiheaders.MARKER,
            contents = not defer_render
                and coder.generate_ffi_header(modname, ast) or nil,
        },
    }
end

local function generated_header_entries(plan)
    return plan.ffi_header and { plan.ffi_header, plan } or { plan }
end

local function validate_generated_header_entry(entry)
    local marker = entry.marker or ffiheaders.FOREIGN_MARKER
    -- LFS table queries can fail on Windows directory destinations.
    local mode = lfs.symlinkattributes(entry.filename, "mode")
    local existing = mode == "file"
        and util.get_file_contents(entry.filename) or nil
    local owned, err = ffiheaders.check_destination(
        entry.filename, marker, mode, existing)
    if entry.contents and err then return nil, err end
    entry.managed = entry.contents ~= nil or owned and true or false
    return true
end

function driver.validate_foreign_header_plan(plan)
    for _, entry in ipairs(generated_header_entries(plan)) do
        local ok, err = validate_generated_header_entry(entry)
        if not ok then return nil, err end
        if entry.contents and not entry.preserve and not entry.temporary then
            local temporary, reserve_err = driver.sibling_temporary_path(
                entry.filename .. ".format")
            if not temporary then return nil, reserve_err end
            -- Preserve C language inference across the random suffix.
            entry.temporary = temporary .. ".h"
        end
    end
    return true
end

function driver.write_foreign_header_plan(plan, verbose, pretty_print)
    return driver.write_foreign_header_plans({ plan }, verbose, pretty_print)
end

-- Implementation notes: doc/implementation/foreign-functions.md#final-planning-ownership-and-stale-cleanup
-- `policy_for(modname)` supplies the emission policy of each module's header;
-- the CLI and the per-module worker derive it from the same coverage selection
-- and line-directive option used for that module's C, so a header can never be
-- planned under a policy another generation left behind.
function driver.plan_foreign_headers(names, imported, policy_for)
    policy_for = policy_for or function() return driver.header_policy(false) end
    local plans = {}
    local by_name = {}
    local occupied = {}
    local plan_names, planned = {}, {}
    for _, name in ipairs(names) do
        plan_names[#plan_names + 1], planned[name] = name, true
    end
    local index = 1
    while plan_names[index] do
        local mod = assert(imported[plan_names[index]])
        local source_imports = mod.source_imports or {}
        if mod.ast then
            source_imports = {}
            for _, node in ipairs(mod.ast) do
                if not node._ignore and node._tag == "Ast.TopLevelImport"
                    and node._source_import then
                    source_imports[#source_imports + 1] = node.modname
                end
            end
        end
        for _, dependency in ipairs(source_imports) do
            local selected = imported[dependency]
            if selected and selected.object_metadata and not planned[dependency] then
                plan_names[#plan_names + 1], planned[dependency] = dependency, true
            end
        end
        index = index + 1
    end
    for _, name in ipairs(plan_names) do
        local mod = assert(imported[name])
        if (mod.ast and not mod.compiled) or mod.object_metadata then
            local plan
            if mod.object_metadata then
                local sourcef = mod.native_output or mod.filename
                local headername = driver.foreign_header_filename(sourcef)
                local ffi_headername = driver.ffi_header_filename(sourcef)
                plan = {
                    modname = name, mod = mod,
                    filename = headername,
                    absolute = normalized_absolute_filename(headername),
                    marker = ffiheaders.FOREIGN_MARKER,
                    -- Restored bytes are compiler-owned and carry the policy
                    -- their record was built under; the record identity owns
                    -- invalidation, so the plan states the current expectation.
                    policy = policy_for(name),
                    has_foreign = mod.object_metadata.foreign_header ~= nil,
                    ffi_header = {
                        filename = ffi_headername,
                        absolute = normalized_absolute_filename(ffi_headername),
                        marker = ffiheaders.MARKER,
                    },
                }
            else
                plan = driver.plan_foreign_header(
                    name, mod.ast, mod.native_output or mod.filename, true,
                    policy_for(name))
            end
            for _, entry in ipairs(generated_header_entries(plan)) do
                local identity = physical_absolute_filename(entry.filename):lower()
                local previous = occupied[identity]
                if previous and previous ~= name then
                    return nil, "generated foreign-header path '" .. entry.filename
                        .. "' is shared by source modules '" .. previous
                        .. "' and '" .. name .. "'"
                end
                occupied[identity] = name
            end
            plans[#plans + 1] = plan
            by_name[name] = plan
        end
    end

    local function dependency_plan(name)
        if by_name[name] then return by_name[name] end
        local selected = imported[name]
        if not selected or not selected.ast or not selected.compiled then return nil end
        local sourcef = selected.native_output or selected.filename
        return {
            has_foreign = driver.ast_has_foreign_functions(selected.ast),
            absolute = normalized_absolute_filename(driver.foreign_header_filename(sourcef)),
            ffi_header = { absolute = normalized_absolute_filename(driver.ffi_header_filename(sourcef)) },
        }
    end

    -- Header identity follows the finalized physical native output, not the
    -- source lookup filename. Resolve every direct source edge from the full
    -- plan before rendering any consumer header or C translation unit.
    for _, plan in ipairs(plans) do
        for _, node in ipairs(plan.ast or {}) do
            if not node._ignore and node._tag == "Ast.TopLevelImport"
               and node._source_import then
                local dependency = dependency_plan(node.modname)
                if not dependency then
                    return nil, "source import '" .. node.modname ..
                        "' has no native output header plan"
                end
                node._foreign_header = dependency and dependency.has_foreign
                    and dependency.absolute or nil
                node._ffi_header = dependency.ffi_header.absolute
            end
        end
    end
    for _, plan in ipairs(plans) do
        if plan.mod then
            local descriptor = plan.mod.ffi_header_descriptor
            local dependencies = {}
            for _, dependency in ipairs(descriptor.dependencies) do
                dependencies[#dependencies + 1] = {
                    logical_name = assert(dependency_plan(dependency.modname)).ffi_header.absolute,
                }
            end
            plan.ffi_header.contents = ffiheaders.plan_contents(
                plan.modname, plan.ffi_header.absolute, dependencies,
                descriptor.direct_includes, descriptor.typedef_declarations)
            if plan.has_foreign then
                plan.contents = ffiheaders.foreign_contents(
                    plan.mod.object_metadata.foreign_header,
                    plan.ffi_header.absolute, function(name)
                        return assert(dependency_plan(name)).absolute
                    end)
                plan.digest = require("titan-compiler.coder.core").coder
                    ._foreign_header_digest(
                        plan.mod.object_metadata.foreign_header)
            end
            for _, entry in ipairs(generated_header_entries(plan)) do
                entry.preserve = entry.contents ~= nil and
                    lfs.attributes(entry.filename, "mode") == "file" and
                    util.get_file_contents(entry.filename) == entry.contents
            end
        else
            plan.ffi_header.contents = coder.generate_ffi_header(
                plan.modname, plan.ast)
            if plan.has_foreign then
                plan.policy = plan.policy or policy_for(plan.modname)
                plan.contents, plan.recipe = coder.generate_foreign_header(
                    plan.modname, plan.ast, { module = plan.modname }, nil,
                    plan.policy)
                plan.digest = require("titan-compiler.coder.core").coder
                    ._foreign_header_digest(plan.recipe)
            end
        end
        local ok, err = driver.validate_foreign_header_plan(plan)
        if not ok then return nil, err end
    end
    return plans
end

function driver.write_foreign_header_plans(plans, verbose, pretty_print)
    local entries = {}
    for _, plan in ipairs(plans or {}) do
        local ok, err = driver.validate_foreign_header_plan(plan)
        if not ok then return nil, err end
        for _, entry in ipairs(generated_header_entries(plan)) do
            entries[#entries + 1] = entry
        end
    end
    local staged = {}
    local function abandon(message)
        for _, temporary in pairs(staged) do os.remove(temporary) end
        return nil, message
    end
    -- Format every new header before publishing either header of any module.
    -- A formatter failure must leave the existing environment and signatures
    -- together, including when several source modules are being compiled.
    for _, entry in ipairs(entries) do
        if entry.contents and not entry.preserve then
            local ok, err = ensure_output_parent(entry.filename)
            if not ok then return abandon(err) end
            local temporary = assert(entry.temporary)
            staged[entry] = temporary
            ok, err = util.set_file_contents(temporary, entry.contents)
            if not ok then return abandon(err) end
            ok, err = driver.format_generated_file(
                temporary, verbose, pretty_print)
            if not ok then return abandon(err) end
            if lfs.attributes(entry.filename, "mode") == "file" and
                util.get_file_contents(entry.filename) == util.get_file_contents(temporary) then
                local removed, remove_error = os.remove(temporary)
                if not removed then return abandon(remove_error) end
                staged[entry], entry.preserve = nil, true
            end
        end
    end
    for _, entry in ipairs(entries) do
        local ok, err
        if staged[entry] then
            ok, err = rename_output(staged[entry], entry.filename)
            if not ok then return abandon(err) end
            staged[entry] = nil
        elseif entry.managed and not entry.preserve then
            ok, err = os.remove(entry.filename)
            if not ok then return abandon(err) end
        end
    end
    return true
end

function driver.prepare_foreign_headers(
        names, imported, verbose, pretty_print, policy_for)
    local plans, err = driver.plan_foreign_headers(names, imported, policy_for)
    if not plans then return nil, err end
    local written, write_error =
        driver.write_foreign_header_plans(plans, verbose, pretty_print)
    if not written then return nil, write_error end
    -- The plan is the published unit; later compiles reuse it only when its
    -- recorded policy matches, so nothing has to be cached on the AST.
    for _, plan in ipairs(plans) do
        local entry = imported[plan.modname]
        if entry then entry.foreign_header_plan = plan end
    end
    return true
end

driver.GENERATED_C_MARKER = "/* Generated by Titan: module C translation unit. */"

local function prepare_compile(
        modname, ast, sourcef, static_deps, verbose, options, source_entry,
        header_plan)
    local context = options and options.context
    if context then driver.assert_target_context(context) end
    if not staticmetadata.valid_module_name(modname) then
        return nil, "invalid logical Titan module name " ..
            string.format("%q", modname)
    end
    local effective_c_parts, c_parts_err =
        driver.effective_c_parts(options and options.c_parts)
    if not effective_c_parts then return nil, c_parts_err end
    local split_threshold = (options and options.split_threshold ~= nil)
        and options.split_threshold or coder.DEFAULT_SPLIT_THRESHOLD
    if type(split_threshold) ~= "number" or split_threshold < 0
        or split_threshold % 1 ~= 0 then
        return nil, "split_threshold requires a nonnegative integer"
    end
    if context and context.target == "browser" then
        local supported, flag_error = driver._browser_target.validate_flags(
            options.extra_compile_flags, "--cflag")
        if not supported then return nil, flag_error end
    end
    if not (context and context.target == "browser") then
        local runtime_ok, runtime_err = perf.check_runtime(verbose)
        if not runtime_ok then return nil, runtime_err end
    end
    sourcef = sourcef or modname:gsub("[.]", "/") .. ".titan"
    static_deps = static_deps or {}
    local stem = driver.module_output_stem(sourcef, modname)
    local filename = stem .. ".c"
    local libname = stem .. ".o"
    local priv_header_path = stem .. ".priv.h"
    coder.prepare_coverage(ast, options and
        (options.coverage == true or options.coverage_backend ~= nil))
    -- A caller-supplied plan is the published unit for this build. Otherwise
    -- reuse this module's published plan only when it was rendered from this
    -- very checked module object and its emission policy matches; any other
    -- case plans and publishes afresh. Planning is cheap, so conservative
    -- replanning is preferred over trusting bytes we cannot prove current — a
    -- same-named source can be a different checked buffer (overridden or
    -- unsaved editor content) that no disk comparison would distinguish.
    local owns_header_plan = header_plan == nil
    if not header_plan then
        local policy = driver.header_policy(options and options.coverage == true)
        local published = source_entry and source_entry.foreign_header_plan
        if published and published.ast ~= nil and published.ast == ast
            and require("titan-compiler.coder.core").coder
                ._same_emission_policy(published.policy, policy) then
            header_plan = published
            owns_header_plan = false
        else
            header_plan = driver.plan_foreign_header(modname, ast, sourcef,
                false, policy)
            local valid, err = driver.validate_foreign_header_plan(header_plan)
            if not valid then return nil, err end
        end
    end
    local imported_layouts = options and options.nominal_layouts
    if not imported_layouts then
        imported_layouts = {}
        for _, imported in pairs(driver.imported) do
            local inventory = imported ~= CIRCULAR_MARK and imported.layout_inventory
            if inventory then
                for name, plan in pairs(inventory.layouts) do
                    imported_layouts[name] = plan
                end
            end
        end
    end
    local generated = coder.generate(
        modname, ast, static_deps, driver.TITAN_ABI_VERSION,
        driver.EMIT_LINE_DIRECTIVES, {
            target = context and context.target,
            nominal_layouts = imported_layouts,
            coverage = options and options.coverage == true,
            coverage_backend = options and options.coverage_backend,
            c_parts = effective_c_parts,
            split_threshold = split_threshold,
            private_header_output = normalized_absolute_filename(priv_header_path),
            source_output_stem = normalized_absolute_filename(stem),
            foreign_header_plan = header_plan,
        })
    local generated_parts = assert(generated and generated.parts)
    local native_references = generated.direct_native_modules
    local native_bindings = generated.native_bindings
    local encoded_layouts = generated.encoded_layouts
    local private_symbols = generated.private_symbols or {}
    -- Objects compiled through a resolver context from authored source carry
    -- a certificate. Producer self digests come from this coder output, so a
    -- fresh producer and its later restored record cannot disagree; consumers
    -- planned in the same invocation read them when their records render.
    local certify = context ~= nil and source_entry ~= nil and
        source_entry.source_certificate ~= nil
    if certify then
        local configuration, configuration_error, status =
            driver.incremental_configuration(context)
        if not configuration then
            if status ~= "uncertified" then return nil, configuration_error end
            certify = false
        else
            local digests, digest_error = incremental.producer_digests(
                context, source_entry, encoded_layouts,
                header_plan and header_plan.recipe)
            if not digests then
                return nil, "cannot certify object for module '" .. modname ..
                    "': " .. tostring(digest_error)
            end
            source_entry.interface_digests = digests
        end
    end
    local test_functions =
        require("titan-compiler.test_runner").function_names(ast)
    local test_flags = driver.test_owner_flags(
        options and options.test, test_functions, context)
    local imports, deps, providers = {}, {}, {}
    for _, node in ipairs(ast) do
        if not node._ignore and node._tag == "Ast.TopLevelImport" then
            imports[#imports + 1] = {
                name = node.modname, source_required = node._source_import == true,
            }
            if static_deps[node.modname] then deps[node.modname] = true
            else providers[node.modname] = node._type.file end
        end
    end
    local entry = {
        kind = "source", ast = ast,
        type = ast._declared_type or ast._type,
        filename = source_entry and source_entry.filename or sourcef,
        source_files = source_entry and source_entry.source_files
            or { source_entry and source_entry.filename or sourcef }, deps = deps,
        c_header_dependencies = ast._c_header_dependencies or {},
    }
    local recorded_parts = {}
    local ordered_objects = {}
    for i, part in ipairs(generated_parts) do
        local idx = part.index
        recorded_parts[i] = {
            index = idx,
            c_suffix = idx == 0 and ".c" or (".part" .. tostring(idx) .. ".c"),
            object_suffix = idx == 0 and ".o" or (".part" .. tostring(idx) .. ".o"),
        }
        ordered_objects[i] = driver.part_object_filename(stem, idx)
    end
    local coverage = require("titan-compiler.coverage")
    local native = {
        imports = imports, bindings = native_bindings, providers = providers,
        has_main = checker.has_main(ast) and true or false,
        test_functions = test_functions,
        coverage_test_functions = coverage.test_functions(ast),
        external_symbols = coder.external_symbols(modname, ast),
        private_symbols = private_symbols,
        native_references = native_references,
        foreign_header = header_plan and header_plan.recipe,
        layouts = encoded_layouts,
        parts_version = 1,
        c_parts = effective_c_parts,
        split_threshold = split_threshold,
        private_header = generated.private_header and ".priv.h" or nil,
        parts = recorded_parts,
    }
    if options and options.coverage_backend then
        native.coverage = { enabled = options.coverage == true,
            backend = options.coverage_backend }
    end
    local certificate_attempted = false
    local function metadata_code()
        if certify and not certificate_attempted then
            certificate_attempted = true
            local made, certificate = pcall(incremental.make_certificate,
                context, source_entry, native, {
                    source = source_entry.source_certificate,
                    stem = normalized_absolute_filename(stem),
                    codegen = {
                        c_parts = effective_c_parts,
                        split_threshold = split_threshold,
                        test_flags = #test_flags > 0,
                        coverage = options and options.coverage_backend and {
                            enabled = options.coverage == true,
                            backend = options.coverage_backend,
                        } or nil,
                    },
                    plan = resolver_plan(context, static_deps),
                    binary_usage = ast._binary_usage,
                    generated_parts = generated_parts,
                    private_header = generated.private_header,
                })
            if made then
                native.certificate = certificate
            elseif type(certificate) ~= "string" then
                error(certificate, 0)
            elseif context.probe_verbose then
                -- A dependency digest this resolver cannot supply (for
                -- example a producer compiled out of order by an API caller)
                -- leaves the object uncertified: it is correct but can only
                -- miss later.
                io.stderr:write("Titan object uncertified ", modname, ": ",
                    certificate, "\n")
            end
        end
        local payload, metadata_error = objectmetadata.encode(entry, native)
        if not payload then return nil, metadata_error end
        return "\n" .. objectmetadata.render(payload,
            "titan_object_source_" .. driver.mangle_module_name(modname))
    end
    -- Preflight an existing private header before any invalidation or file
    -- write.
    local priv_mode = lfs.symlinkattributes(priv_header_path, "mode")
    local priv_owned = false
    if priv_mode == "file" then
        local existing = util.get_file_contents(priv_header_path)
        priv_owned = existing and existing:sub(1, #driver.PRIVATE_HEADER_MARKER)
            == driver.PRIVATE_HEADER_MARKER or false
    end
    if generated.private_header and priv_mode then
        local existing = priv_mode == "file"
            and util.get_file_contents(priv_header_path) or nil
        local owned = existing and
            existing:sub(1, #driver.PRIVATE_HEADER_MARKER)
                == driver.PRIVATE_HEADER_MARKER
        if priv_mode ~= "file" or not owned then
            return nil, "refusing to overwrite user-owned generated-header path '"
                .. priv_header_path .. "'"
        end
    end

    -- Discover prior compiler-owned outputs from the existing primary record
    -- before invalidating it, so stale higher parts are removed even with
    -- holes. No directory is scanned and no other inventory is trusted.
    local prior_inventory = {}
    if priv_owned then prior_inventory[priv_header_path] = true end
    if lfs.symlinkattributes(libname, "mode") == "file" then
        local old_bytes = util.get_file_contents(libname, "rb")
        local old_entry = old_bytes and objectmetadata.read(old_bytes, libname) or nil
        local old_native = old_entry and old_entry.object_metadata or nil
        if old_native and old_native.parts and objectmetadata.validate_parts(old_native) then
            for _, old_part in ipairs(old_native.parts) do
                if old_part.index >= 1 then
                    prior_inventory[driver.part_c_filename(stem, old_part.index)] = true
                    prior_inventory[driver.part_object_filename(stem, old_part.index)] = true
                    prior_inventory[stem .. ".part" .. tostring(old_part.index) .. ".gcno"] = true
                    prior_inventory[stem .. ".part" .. tostring(old_part.index) .. ".gcda"] = true
                end
            end
        end
    end

    local base_args, flags_err = driver.generated_compile_prefix(context)
    if not base_args then return nil, flags_err end
    append_argv(base_args, test_flags)
    append_argv(base_args, options and options.extra_compile_flags)
    local lto, explicit_seed = false, false
    for _, argument in ipairs(base_args) do
        if argument == "-fno-lto" then lto = false
        elseif argument == "-flto" or argument:match("^%-flto=") then lto = true end
        if argument == "-frandom-seed" or argument:match("^%-frandom%-seed=") then
            explicit_seed = true
        end
    end

    local prepared_jobs = {}
    for i, part in ipairs(generated_parts) do
        local part_c = driver.part_c_filename(stem, part.index)
        local part_o = driver.part_object_filename(stem, part.index)
        local reserved, temporary, temporary_error = pcall(
            driver.sibling_temporary_path, part_o .. ".compile")
        if not reserved or not temporary then
            for prev = 1, i - 1 do
                os.remove(prepared_jobs[prev].temporary_object)
            end
            if not reserved then return nil, temporary end
            return nil, temporary_error
        end
        local part_args = {}
        append_argv(part_args, base_args)
        if part.index >= 1 then
            for arg_idx = 1, #part_args - 1 do
                if part_args[arg_idx] == "-dumpbase" then
                    part_args[arg_idx + 1] = path.basename(part_c)
                end
            end
        end
        if lto and not explicit_seed then
            local seed = (#generated_parts == 1) and modname
                or (modname .. ".part" .. tostring(part.index))
            append_argv(part_args, { "-frandom-seed=" .. seed })
        end
        append_argv(part_args, { static_flag(), part_c, "-o", temporary })
        prepared_jobs[i] = {
            module_index = 1,
            part_index = part.index,
            c_path = part_c,
            object_path = part_o,
            temporary_object = temporary,
            argv = part_args,
            cost_bytes = part.code_bytes,
        }
    end
    local outputs, output_paths = {}, {}
    local function output(path)
        if not output_paths[path] then
            output_paths[path] = true
            outputs[#outputs + 1] = {
                path = path, owner = "logical module '" .. modname .. "'",
            }
        end
    end
    if generated.private_header then output(priv_header_path) end
    for _, part in ipairs(generated_parts) do
        output(driver.part_c_filename(stem, part.index))
        output(driver.part_object_filename(stem, part.index))
        local part_stem = driver.part_object_filename(stem, part.index):gsub("[.]o$", "")
        output(part_stem .. ".gcno")
        output(part_stem .. ".gcda")
    end
    for _, job in ipairs(prepared_jobs) do output(job.temporary_object) end
    for prior_path in pairs(prior_inventory) do output(prior_path) end
    if header_plan then
        for _, header in ipairs(generated_header_entries(header_plan)) do
            if header.contents or header.managed then output(header.filename) end
            if header.temporary then output(header.temporary) end
        end
    end
    local inputs = {}
    for _, input in ipairs(entry.source_files) do inputs[#inputs + 1] = input end
    for _, dependency in ipairs(entry.c_header_dependencies) do
        inputs[#inputs + 1] = dependency.filename or dependency.path
    end
    for _, input in ipairs(options and options.native_inputs or {}) do
        inputs[#inputs + 1] = input
    end
    local function materialize()
        if context then driver.assert_target_context(context) end
        local output_ok, output_err = ensure_output_parent(filename)
        if not output_ok then return nil, output_err end
        if header_plan and owns_header_plan then
            local ok, err = driver.write_foreign_header_plan(
                header_plan, verbose, options and options.pretty_print)
            if not ok then return nil, err end
        end
        if header_plan and source_entry then
            source_entry.foreign_header_plan = header_plan
        end

        -- Invalidate the primary commit marker first, then remove prior
        -- sibling outputs. A staged worker compile never touches the
        -- primary name: its coordinator retired it before dispatch.
        if not (options and options.staged) then os.remove(libname) end
        os.remove(filename)
        os.remove(stem .. ".gcda")
        os.remove(stem .. ".gcno")
        for prior_path in pairs(prior_inventory) do
            os.remove(prior_path)
        end

        if generated.private_header then
            local ok, err = util.set_file_contents(
                priv_header_path, generated.private_header)
            if not ok then return nil, err end
            local format_ok, format_err = driver.format_generated_file(
                priv_header_path, verbose, options and options.pretty_print, nil, false)
            if not format_ok then
                os.remove(priv_header_path)
                return nil, format_err
            end
        end

        for _, part in ipairs(generated_parts) do
            local part_c = driver.part_c_filename(stem, part.index)
            local part_code = driver.GENERATED_C_MARKER .. "\n" .. part.code
            os.remove(part_c)
            local ok, err = util.set_file_contents(part_c, part_code)
            if not ok then return nil, err end
            local format_ok, format_err = driver.format_generated_file(
                part_c, verbose, options and options.pretty_print, nil,
                options and options.coverage)
            if not format_ok then return nil, format_err end
        end

        if options and options.coverage then
            local coverage_parts = {}
            local converted_codes = {}
            for i, part in ipairs(generated_parts) do
                local part_c = driver.part_c_filename(stem, part.index)
                local contents, read_error = util.get_file_contents(part_c)
                if not contents then return nil, read_error end
                local converted, conversion_error, anchors =
                    require("titan-compiler.coverage_lines").convert(contents, part_c)
                if not converted then return nil, conversion_error end
                coverage_parts[i] = { filename = part_c, anchors = anchors }
                converted_codes[i] = { filename = part_c, code = converted }
            end
            native.coverage = coverage.partial(coverage_parts,
                entry.source_files, options.coverage_backend)
            for _, item in ipairs(converted_codes) do
                local written, write_error =
                    util.set_file_contents(item.filename, item.code)
                if not written then return nil, write_error end
            end
        end
        if certify then
            native.generated_inputs = {}
            local preprocessing = {}
            for index, part in ipairs(generated_parts) do
                local filename = driver.part_c_filename(stem, part.index)
                local contents, err = util.get_file_contents(filename, "rb")
                if not contents then return nil, err end
                native.generated_inputs[index] = {
                    spelling = filename,
                    bytes = #contents, sha256 = incremental.digest(context, "generated-c", contents),
                }
                preprocessing[index] = { filename = filename, contents = contents }
            end
            local semantics, preprocessing_error =
                incremental.preprocessed_identities(context, preprocessing)
            if not semantics then return nil, preprocessing_error end
            for index, identity in ipairs(semantics) do native.generated_inputs[index].semantic = identity end
        end
        local metadata, metadata_error = metadata_code()
        if not metadata then return nil, metadata_error end
        local primary = driver.part_c_filename(stem, 0)
        local contents, read_error = util.get_file_contents(primary, "rb")
        if not contents then return nil, read_error end
        local written, write_error = util.set_file_contents(primary, contents .. metadata, "wb")
        if not written then return nil, write_error end
        if native.certificate then incremental.record_materialization(context, stem, native.certificate) end
        if source_entry then
            source_entry.coverage = native.coverage
            source_entry.private_symbols = private_symbols
        end

        return {
            modname = modname,
            request_index = 1,
            stem = stem,
            primary_object = libname,
            private_header = generated.private_header and priv_header_path or nil,
            jobs = prepared_jobs,
            objects = ordered_objects,
            source_record = native,
            prior_inventory = prior_inventory,
            native_references = native_references,
            private_symbols = private_symbols,
        }
    end
    return {
        modname = modname, outputs = outputs, inputs = inputs,
        private_symbols = private_symbols, source_record = native,
        part_count = #generated_parts, materialize = materialize,
    }
end

-- Sibling part objects are published first; the primary object is the
-- module's commit marker and is renamed last. Any failure removes the
-- primary marker and all temporary/sibling objects.
local function publish_compiled_object(prepared, ok, err)
    if ok then
        for index = #prepared.jobs, 2, -1 do
            local job = prepared.jobs[index]
            ok, err = rename_output(job.temporary_object, job.object_path)
            if not ok then break end
        end
    end
    if ok then
        local job0 = prepared.jobs[1]
        ok, err = rename_output(job0.temporary_object, job0.object_path)
    end
    if not ok then
        if prepared.primary_object then os.remove(prepared.primary_object) end
        for _, job in ipairs(prepared.jobs) do
            os.remove(job.temporary_object)
            os.remove(job.object_path)
        end
    end
    return ok, err
end

-- Implementation notes: doc/implementation/driver.md#compiling-one-module-drivercompile
function driver.compile(modname, ast, sourcef, static_deps, verbose, options, source_entry)
    local plan, prepare_err = prepare_compile(
        modname, ast, sourcef, static_deps, verbose, options, source_entry)
    if not plan then return nil, prepare_err end
    local valid, preflight_err = driver.validate_provider_output_paths(
        nil, plan.inputs, plan.outputs)
    if not valid then return nil, preflight_err end
    local symbols, errors = {}, {}
    driver.record_module_symbols(symbols, modname, plan.source_record.external_symbols, errors)
    driver.record_module_symbols(symbols, modname, plan.private_symbols, errors)
    if #errors > 0 then return nil, table.concat(errors, "\n") end
    local prepared, materialize_err = plan.materialize()
    plan.materialize = nil
    if not prepared then return nil, materialize_err end
    -- Serial compilation runs every part in order, as the batch does, so a
    -- failing part does not hide another part's diagnostics.
    local ok, err = true, nil
    for _, job in ipairs(prepared.jobs) do
        local job_ok, job_err = run_argv(job.argv, verbose)
        if ok and not job_ok then ok, err = job_ok, job_err end
    end
    ok, err = publish_compiled_object(prepared, ok, err)
    if ok then
        if source_entry then
            source_entry.compiled_objects = prepared.objects
            source_entry.private_symbols = prepared.private_symbols
        end
        return ok, nil, prepared.primary_object, prepared.native_references,
            prepared.objects
    else
        return nil, err
    end
end

local function create_compile_log()
    if driver.OUTPUT_ROOT then
        local filename, err = driver.sibling_temporary_path(
            path.join(driver.OUTPUT_ROOT, ".titan-temporary"))
        if not filename then return nil, err end
        local wrote, write_error = util.set_file_contents(filename, "")
        if not wrote then return nil, write_error end
        return filename
    end
    return compiler_io.new_sync():tmpname()
end

-- Native batch helpers. This chunk is near Lua's 200-active-local limit, so
-- the helpers are scoped to this block; only the scheduler entry point and
-- the launch/reap/replay table shared with provider links escape. The replay
-- owner routes captured bytes through the live reporter when one owns the
-- terminal (G2-1).
local run_prepared_compiles, compile_batch
do

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

local function create_compile_notification()
    return jobs.open_channel(create_compile_log)
end

local close_compile_notification = jobs.close_channel

local function show_parallel_command(command)
    local write_called, written, write_err =
        pcall(io.stderr.write, io.stderr, command .. "\n")
    if not write_called then return nil, written end
    if not written then return nil, write_err end
    local flush_called, flushed, flush_err =
        pcall(io.stderr.flush, io.stderr)
    if not flush_called then return nil, flushed end
    if not flushed then return nil, flush_err end
    return true
end

local function launch_prepared_compile(
        job, verbose, notification, completion_index)
    local command, command_err, executable
    if platform.windows then
        command, executable = platform.windows_process_command(job.argv)
        if not command then command_err = executable end
    else
        command, command_err = command_argv(job.argv)
    end
    if not command then return nil, command_err end

    local stdout_path, stdout_err = create_compile_log()
    if not stdout_path then return nil, stdout_err end
    local stderr_path, stderr_err = create_compile_log()
    if not stderr_path then
        protected_remove(stdout_path)
        return nil, stderr_err
    end
    local process, launch_err = jobs.launch(notification, job.argv, command,
        stdout_path, stderr_path, completion_index,
        verbose and function() return show_parallel_command(command) end,
        not platform.windows and driver.OUTPUT_LOCKS and {
            inherit = driver.OUTPUT_LOCKS:descriptors(),
        } or nil)
    if not process then
        protected_remove(stdout_path)
        protected_remove(stderr_path)
        return nil, launch_err
    end
    process.stdout_path, process.stderr_path = stdout_path, stderr_path
    return process
end

-- Captured child logs are replayed into the coordinator's stderr. A live
-- progress region owns that terminal, so the bytes go through its reporter:
-- it erases the region first, terminates a chunk that does not end in a
-- newline and redraws, so a following step event cannot erase the text. The
-- historical stream path (quiet, plain, verbose and every non-CLI caller)
-- keeps its write/flush success checks.
local function replay_sink()
    local reporter = driver.LIVE_PROGRESS
    if not reporter then return io.stderr end
    return {
        write = function(_, text)
            reporter:write(text)
            return true
        end,
        flush = function() return true end,
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

local reap_prepared_compile_without_throw = jobs.reap

local function finish_prepared_compile(process)
    if not process.reaped then jobs.reap(process) end
    local finish_errors = process.finish_errors
    local sink = replay_sink()

    local stdout_ok, stdout_err = protected_replay_compile_output(
        process.stdout_path, sink)
    if not stdout_ok then
        finish_errors[#finish_errors + 1] =
            "stdout: " .. tostring(stdout_err)
    end
    local stderr_ok, stderr_err = protected_replay_compile_output(
        process.stderr_path, sink)
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

-- Returns per-module results and the INT/TERM/HUP signal that cancelled the
-- batch, if any; the caller re-raises it after its own cleanup.
function run_prepared_compiles(prepared, parallelism, verbose)
    local entries, results = jobs.flatten(prepared)
    local slots
    if parallelism > 1 and #entries > 1 then
        local slots_err
        slots, slots_err = jobs.open_slots(parallelism, { idle = idle_hook() })
        if not slots then
            for _, entry in ipairs(entries) do jobs.record(entry, nil, slots_err) end
            return jobs.summarize(results)
        end
        -- Explicit `make -j1` or an unusable parent jobserver grants one slot.
        if slots.limit == 1 then
            slots:close()
            slots = nil
        end
    end
    if not slots then
        for _, entry in ipairs(entries) do
            jobs.record(entry, run_argv(entry.job.argv, verbose))
        end
        return jobs.summarize(results)
    end

    local created, notification, notification_err = pcall(create_compile_notification)
    if not created then notification_err, notification = notification, nil end
    if not notification then
        -- Closing restores the previous signal actions; a signal the guard
        -- caught before then still belongs to the caller.
        local closed, close_err = slots:close()
        if not closed then
            notification_err = tostring(notification_err) .. "; " .. tostring(close_err)
        end
        for _, entry in ipairs(entries) do
            jobs.record(entry, nil, notification_err)
        end
        return jobs.summarize(results), slots:cancelled()
    end

    -- The shared native loop launches larger units first, refills a slot as
    -- soon as any compiler finishes and reaps each child before its slot is
    -- released. A schedule position is also the completion index.
    local schedule = jobs.launch_order(entries)
    local next_schedule, completion_err, cancelled = jobs.drive(
        slots, notification, #schedule, function(position)
            local entry = schedule[position]
            -- An unexpected Lua error fails only this job; the batch goes on.
            local called, process, launch_err = pcall(launch_prepared_compile,
                entry.job, verbose, notification, position)
            if not called then process, launch_err = nil, process end
            entry.process = process
            return process, launch_err
        end, function(position, launch_err)
            jobs.record(schedule[position], nil, launch_err)
        end, "parallel C compiler")
    local function batch_failure(message)
        completion_err = completion_err and (completion_err .. "; " .. message) or
            message
    end

    local slots_ok, slots_err = slots:close()
    if not slots_ok then batch_failure(tostring(slots_err)) end
    cancelled = cancelled or slots:cancelled()
    local notification_ok, cleanup_err =
        close_compile_notification(notification)
    if not notification_ok then batch_failure(cleanup_err) end
    if cancelled then
        batch_failure("parallel C compilation interrupted by signal " ..
            tostring(cancelled))
    end
    if completion_err then
        for schedule_index = next_schedule, #schedule do
            jobs.record(schedule[schedule_index], nil, completion_err)
        end
    end

    -- Reaping follows actual completion so a free slot is refilled promptly,
    -- but diagnostics remain deterministic in module/part order.
    for _, entry in ipairs(entries) do
        local process = entry.process
        if process then
            local ok, err, code =
                finish_prepared_compile_without_throw(process)
            if completion_err then
                ok = nil
                err = err and (tostring(err) .. "; " .. completion_err) or
                    completion_err
            end
            jobs.record(entry, ok, err, code)
        end
    end
    return jobs.summarize(results), cancelled
end

-- The provider-link pipeline reuses the batch launcher, reaper, and replay.
compile_batch = {
    create_notification = create_compile_notification,
    close_notification = close_compile_notification,
    launch = launch_prepared_compile,
    reap = reap_prepared_compile_without_throw,
    finish = finish_prepared_compile_without_throw,
    show_command = show_parallel_command,
}

end -- native batch helpers

-- The scheduler over prepared-module records; publication stays with the
-- caller, which also re-raises a returned cancellation signal.
-- Implementation notes: doc/implementation/driver.md#parallel-generated-c-compilation
driver.run_prepared_compiles = run_prepared_compiles

function perf.assert_compile_request_contexts(requests)
    for _, request in ipairs(requests) do
        assert(type(request) == "table", "each compilation request must be a table")
        local context = request.options and request.options.context
        if context then driver.assert_target_context(context) end
    end
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
            libname = driver.module_output_stem(sourcef, request.modname) .. ".o"
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

-- Generation and ownership discovery do not mutate any output. The caller may
-- extend this plan with provider/entrypoint outputs before materialization.
function driver.plan_compile_requests(
        requests, verbose, native_inputs, symbol_owners, header_plans)
    perf.assert_compile_request_contexts(requests)
    validate_compile_requests(requests)
    local plans, outputs, inputs, symbols, errors = {}, {}, {}, {}, {}
    local input_seen, headers_by_name = {}, {}
    local function add_input(input)
        if input and not input_seen[input] then
            input_seen[input] = true
            inputs[#inputs + 1] = input
        end
    end
    for _, plan in ipairs(header_plans or {}) do headers_by_name[plan.modname] = plan end
    for symbol, owner in pairs(symbol_owners or {}) do symbols[symbol] = owner end
    for _, input in ipairs(native_inputs or {}) do add_input(input) end
    for index, request in ipairs(requests) do
        local mod = request.mod
        local native = mod.object_metadata
        if not mod.compiled then
            local plan, err = prepare_compile(request.modname, mod.ast,
                mod.native_output or mod.filename, request.static_deps,
                verbose, request.options, mod, headers_by_name[request.modname])
            if not plan then return nil, err end
            plans[index] = plan
            native = plan.source_record
            for _, output in ipairs(plan.outputs) do outputs[#outputs + 1] = output end
            for _, input in ipairs(plan.inputs) do add_input(input) end
        else
            plans[index] = false
            for _, object in ipairs(driver.module_compiled_objects(mod)) do
                add_input(object)
            end
            for _, input in ipairs(mod.source_files or { mod.filename }) do
                add_input(input)
            end
            for _, dependency in ipairs(mod.c_header_dependencies or {}) do
                add_input(dependency.filename or dependency.path)
            end
        end
        driver.record_module_symbols(symbols, request.modname,
            native and native.external_symbols or mod.external_symbols, errors)
        driver.record_module_symbols(symbols, request.modname,
            native and native.private_symbols or mod.private_symbols, errors)
    end
    if #errors > 0 then return nil, table.concat(errors, "\n") end
    local planned_paths = {}
    for _, output in ipairs(outputs) do planned_paths[output.path] = true end
    for _, plan in ipairs(header_plans or {}) do
        for _, header in ipairs(generated_header_entries(plan)) do
            if not header.preserve and (header.contents or header.managed)
                and not planned_paths[header.filename] then
                outputs[#outputs + 1] = {
                    path = header.filename,
                    owner = "generated header for logical module '" .. plan.modname .. "'",
                }
                planned_paths[header.filename] = true
            end
            if header.temporary and not planned_paths[header.temporary] then
                outputs[#outputs + 1] = {
                    path = header.temporary,
                    owner = "staged header for logical module '" .. plan.modname .. "'",
                }
                planned_paths[header.temporary] = true
            end
        end
    end
    local ok, err = driver.validate_provider_output_paths(nil, inputs, outputs)
    if not ok then return nil, err end
    plans.outputs, plans.inputs = outputs, inputs
    return plans
end

-- Generate and preflight the whole batch before invalidating any primary.
-- Only native object compilations ever overlap; diagnostics retain request
-- and part order even though larger jobs launch first.
function driver.compile_modules(requests, parallelism, verbose, plans)
    assert(type(requests) == "table", "requests must be a table")
    assert(type(parallelism) == "number" and parallelism >= 1 and
        parallelism % 1 == 0, "parallelism must be a positive integer")
    perf.assert_compile_request_contexts(requests)
    local results, plan_err = {}
    if not plans then plans, plan_err = driver.plan_compile_requests(requests, verbose) end
    if not plans then
        for index in ipairs(requests) do results[index] = { err = plan_err } end
        return results
    end

    local prepared = {}
    for index, request in ipairs(requests) do
        local mod = assert(request.mod)
        if mod.compiled then
            results[index] = {
                ok = true,
                libname = mod.compiled,
                objects = driver.module_compiled_objects(mod),
                native_references = mod.native_references or {},
            }
        else
            local compilation, prepare_err = plans[index].materialize()
            plans[index].materialize = nil
            if not compilation then
                results[index] = { err = prepare_err }
            else
                jobs.set_request_index(compilation, index)
                prepared[#prepared + 1] = compilation
            end
        end
    end

    local compiled, cancelled
    if parallelism == 1 then
        compiled = {}
        for index, compilation in ipairs(prepared) do
            local result = { ok = true }
            for _, job in ipairs(compilation.jobs) do
                local ok, err = run_argv(job.argv, verbose)
                if result.ok and not ok then result = { err = err } end
            end
            compiled[index] = result
        end
    else
        compiled, cancelled = run_prepared_compiles(prepared, parallelism, verbose)
    end
    for prepared_index, compilation in ipairs(prepared) do
        local result = compiled[prepared_index]
        result.ok, result.err = publish_compiled_object(compilation, result.ok, result.err)
        local request_index = compilation.request_index
        if result.ok then
            local request = requests[request_index]
            request.mod.compiled = compilation.primary_object
            request.mod.compiled_objects = compilation.objects
            request.mod.private_symbols = compilation.private_symbols or {}
            request.mod.native_references = compilation.native_references or {}
            results[request_index] = {
                ok = true,
                libname = compilation.primary_object,
                objects = compilation.objects,
                native_references = request.mod.native_references,
            }
        else
            results[request_index] = { err = result.err }
        end
    end
    -- A cancelled batch failed every module above, so no object was
    -- published; deliver the signal under the restored action now.
    jobs.propagate(cancelled)
    return results
end

-- Windows launchers live in bin; their file name is presentation only.
function driver.windows_launcher_name(modname, override)
    local name = override or modname
    if type(name) ~= "string" or name == "" or
       name:find('[%z\1-\31\127<>:"/\\|?*]') or name:find('[. ]$') then
        return nil, "--exe requires a valid Windows filename"
    end
    local length = utf8.len(name)
    if not length then return nil, "--exe requires valid UTF-8" end
    local stem = name:match("^[^.]*"):gsub(" +$", ""):upper()
    if stem == "CON" or stem == "PRN" or stem == "AUX" or stem == "NUL" or
       stem == "CONIN$" or stem == "CONOUT$" or
       stem:match("^COM[1-9]$") or stem:match("^LPT[1-9]$") or
       stem == "COM¹" or stem == "COM²" or stem == "COM³" or
       stem == "LPT¹" or stem == "LPT²" or stem == "LPT³" then
        return nil, "--exe cannot use a reserved Windows device name"
    end
    if name:sub(-4):lower() ~= ".exe" then name = name .. ".exe" end
    local units = 0
    for _, value in utf8.codes(name) do units = units + (value > 0xffff and 2 or 1) end
    if units > 255 then return nil, "--exe exceeds a Windows filename component" end
    return name
end

-- Windows launcher and provider paths. Without `exe` the launcher is
-- `<output>/bin/<logical>.exe`; `exe` is an exact destination relative to the
-- invocation directory (`.exe` appended when absent). The provider DLL always
-- stays under the output tree's `lib/titan/<version>`; the launcher names it
-- relative to its own default library directory `<exe dir>/../lib/titan/<version>`,
-- which must be on the provider's volume.
function driver.windows_program_paths(modname, exe, output_module, output_root)
    output_module = output_module or modname
    local relative = output_module:gsub("[.]", "/") .. ".dll"
    local result = {
        provider = "lib/titan/" .. driver.TITAN_LIBRARY_VERSION .. "/" .. relative,
        relative_provider = relative,
    }
    if output_root then result.provider = path.join(output_root, result.provider) end
    if exe == nil then
        local name, err = driver.windows_launcher_name(output_module)
        if not name then return nil, err end
        result.executable = "bin/" .. name
        if output_root then
            result.executable = path.join(output_root, result.executable)
        end
        return result
    end
    local name, err = driver.windows_launcher_name(output_module, path.basename(exe))
    if not name then return nil, err end
    local directory = path.dirname(exe)
    result.executable = path.join(directory, name)
    local library = normalized_absolute_filename(path.join(directory,
        "../lib/titan/" .. driver.TITAN_LIBRARY_VERSION))
    local provider = normalized_absolute_filename(result.provider)
    if (path.volume(library) or ""):lower() ~= (path.volume(provider) or ""):lower() then
        return nil, "--exe '" .. exe .. "' is on another volume than its " ..
            "provider '" .. provider .. "'"
    end
    local from, to = {}, {}
    for component in path.to_slash(library):gmatch("[^/]+") do from[#from + 1] = component end
    for component in path.to_slash(provider):gmatch("[^/]+") do to[#to + 1] = component end
    local common = 0
    while common < #from and common < #to - 1 and
          from[common + 1]:lower() == to[common + 1]:lower() do
        common = common + 1
    end
    local pieces = {}
    for _ = common + 1, #from do pieces[#pieces + 1] = ".." end
    for index = common + 1, #to do pieces[#pieces + 1] = to[index] end
    result.relative_provider = table.concat(pieces, "/")
    return result
end

-- These are actual producer definitions. All post-init native/data lookup
-- uses the already generated canonical callback; collision inventories also
-- contain hidden and source-only names and are not PE export inventories.
-- Implementation notes: doc/implementation/windows-build.md#windows-application-launchers
function driver.windows_provider_exports(module_names, interfaces, library_name)
    local names, seen = {}, {}
    for _, modname in ipairs(module_names) do
        local mangled = driver.mangle_module_name(modname)
        for _, suffix in ipairs({ "_abi_value", "_abi", "_types", "_layouts",
                                   "_compatibility", "_init" }) do
            local name = mangled .. suffix
            assert(not seen[name], "duplicate Windows module export " .. name)
            seen[name], names[#names + 1] = true, name
        end
        names[#names + 1] = "luaopen_" .. mangled
        local interface = interfaces and interfaces[modname]
        for _, symbol in ipairs(interface and
                coder.foreign_external_symbols(modname, interface) or {}) do
            assert(not seen[symbol], "duplicate Windows module export " .. symbol)
            seen[symbol], names[#names + 1] = true, symbol
        end
    end
    table.sort(names, util.bytewise_less)
    local library = library_name and
        ("LIBRARY " .. string.format("%q", path.basename(library_name)) .. "\n") or ""
    return library .. "EXPORTS\n    " .. table.concat(names, "\n    ") .. "\n", names
end

function driver.windows_launcher_manifest()
    return [[<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity name="Titan.Launcher" version="0.6.0.0" processorArchitecture="amd64" type="win32"/>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security><requestedPrivileges>
      <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
    </requestedPrivileges></security>
  </trustInfo>
  <application xmlns="urn:schemas-microsoft-com:asm.v3"><windowsSettings>
    <activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>
    <longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>
  </windowsSettings></application>
</assembly>
]]
end

function driver.windows_program_auxiliary_paths(entrypoint, provider)
    return { provider, provider .. ".def", entrypoint .. ".manifest",
        entrypoint .. ".rc", entrypoint .. ".res" }
end

local function c_string_contents(value)
    -- Literal dollar signs must survive recursive util.render expansion.
    return (value:gsub('[%z\1-\31\127-\255"\\$]', function(byte)
        return string.format("\\%03o", byte:byte())
    end))
end

function driver.windows_launcher_resource(manifest)
    -- Resource filenames do not interpret C octal byte escapes. Windows
    -- accepts forward slashes, so no resource-string escapes are necessary.
    assert(not manifest:find('[%z\1-\31"]'), "invalid Windows manifest path")
    return '#pragma code_page(65001)\n1 24 "' ..
        manifest:gsub("\\", "/") .. '"\n'
end

local unix_entrypoint_alerts = [[
/* portable alerts, from srlua */
#ifdef _WIN32
#include <windows.h>
#define alert(message)  MessageBox(NULL, message, progname, MB_ICONERROR | MB_OK)
#define getprogname()   char name[MAX_PATH]; argv[0]= GetModuleFileName(NULL,name,sizeof(name)) ? name : NULL;
#else
#define alert(message)  fprintf(stderr,"%s: %s\n", "$PROGNAME", message)
#define getprogname()
#endif]]

local windows_entrypoint_alerts = [[
/* A console launcher keeps diagnostics available to callers and editors. */
#define alert(message)  fprintf(stderr,"%s: %s\n", "$PROGNAME", message)
#define getprogname()]]

local windows_entrypoint_declarations = [[
/* The selected identity and provider do not depend on this EXE's basename. */
static int titan_open_main(lua_State *L) {
    TitanModuleProvider provider = titan_module_provider(L,
        "$MODNAME", "$PROVIDER");
    titan_check_module_abi(L, provider, "$ABI_FN", "$PROVIDER");
    lua_CFunction open = titan_cast_func(lua_CFunction,
        titan_module_symbol(L, provider, "$LUAOPEN_FN"));
    return open(L);
}]]

local entrypoint_template = [[

#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
#include "titan.h"

$PLATFORM_ALERTS

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

$ENTRYPOINT_DECLARATIONS

$COVERAGE_DECLARATIONS

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
    titan_install_searcher(L);
    $COVERAGE_PREPARE
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    lua_pushcfunction(L, $PRELOAD_FN);
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
    $COVERAGE_FINISH
    lua_close(L);
    return ret;
}

]]

-- Implementation notes: doc/implementation/driver.md#linking-a-standalone-program-drivercompile_program
function driver.entrypoint_contents(modname, program_name, options)
    options = options or {}
    local values = {
        PROGNAME = program_name or modname:gsub(".*[.]", ""),
        LUAOPEN_FN = "luaopen_" .. driver.mangle_module_name(modname),
        MODNAME = modname,
        SKIP_MAIN_BOOTSTRAP = options.no_uv_bootstrap and "1" or "0",
        COVERAGE_DECLARATIONS = "", COVERAGE_PREPARE = "", COVERAGE_FINISH = "",
    }
    if platform.windows then
        values.PROGNAME = c_string_contents(values.PROGNAME)
        values.ABI_FN = driver.mangle_module_name(modname) .. "_abi"
        values.PROVIDER = c_string_contents(assert(options.provider,
            "Windows entrypoint requires an explicit provider"))
        values.PRELOAD_FN = "titan_open_main"
        values.PLATFORM_ALERTS = util.render(windows_entrypoint_alerts, values)
        values.ENTRYPOINT_DECLARATIONS =
            util.render(windows_entrypoint_declarations, values)
    else
        values.PRELOAD_FN = values.LUAOPEN_FN
        values.PLATFORM_ALERTS = util.render(unix_entrypoint_alerts, values)
        values.ENTRYPOINT_DECLARATIONS =
            "int " .. values.LUAOPEN_FN .. "(lua_State* L);"
    end
    if options.coverage_runtime then
        local runtime_path = assert(package.searchpath(
            "titan-compiler.coverage_runtime", package.path))
        local runtime = assert(util.get_file_contents(runtime_path))
        local config = "return " .. require("titan-compiler.coverage").serialize(
            options.coverage_runtime)
        values.COVERAGE_DECLARATIONS = util.render([[
static const unsigned char titan_coverage_runtime[] = $RUNTIME;
static const unsigned char titan_coverage_config[] = $CONFIG;
static void titan_coverage_call(lua_State *L, const char *method) {
    int top = lua_gettop(L);
    lua_getfield(L, LUA_REGISTRYINDEX, "titan.coverage.runtime");
    lua_getfield(L, -1, method);
    lua_getfield(L, LUA_REGISTRYINDEX, "titan.coverage.config");
    if (lua_pcall(L, 1, 0, 0) != LUA_OK) fatal(lua_tostring(L, -1));
    lua_settop(L, top);
}
static void titan_coverage_prepare(lua_State *L) {
    if (luaL_loadbuffer(L, (const char *)titan_coverage_runtime,
        sizeof(titan_coverage_runtime), "@titan.coverage") != LUA_OK ||
        lua_pcall(L, 0, 1, 0) != LUA_OK) fatal(lua_tostring(L, -1));
    lua_setfield(L, LUA_REGISTRYINDEX, "titan.coverage.runtime");
    if (luaL_loadbuffer(L, (const char *)titan_coverage_config,
        sizeof(titan_coverage_config), "@titan.coverage.config") != LUA_OK ||
        lua_pcall(L, 0, 1, 0) != LUA_OK) fatal(lua_tostring(L, -1));
    lua_setfield(L, LUA_REGISTRYINDEX, "titan.coverage.config");
    titan_coverage_call(L, "prepare");
}
$DUMP
]], {
            RUNTIME = assert(staticmetadata.c_initializer(runtime)),
            CONFIG = assert(staticmetadata.c_initializer(config)),
            DUMP = platform.windows and util.render([[
static void titan_coverage_dump(lua_State *L) {
    /* This image-owned hook is outside the logical module export descriptor. */
    lua_CFunction dump = titan_cast_func(lua_CFunction,
        loadsym(L, loadlib(L, "$PROVIDER"), "_titan_coverage_dump"));
    dump(L);
}
]], values) or [[
extern void __gcov_dump(void);
static void titan_coverage_dump(lua_State *L) { (void)L; __gcov_dump(); }
]],
        })
        values.COVERAGE_PREPARE = "titan_coverage_prepare(L);"
        values.COVERAGE_FINISH = [[
    if (ret == 0) {
        titan_coverage_dump(L);
        titan_coverage_call(L, "finish");
    }
]]
    end
    return util.render(entrypoint_template, values)
end

function driver.browser_c_image_contents(worker, options)
    return require("titan-compiler.browserentry").contents(worker, options)
end

function driver.browser_entrypoint_contents(modname, program_name, options)
    options = options or {}
    local worker = [[
static char titan_main_array_writer_key;
static int titan_main_string_array_writer(lua_State *L) {
    if (lua_type(L, 1) != LUA_TSTRING)
        return luaL_error(L, "type error, expected string for standalone arguments");
    lua_settop(L, 1);
    return 1;
}
static int titan_browser_worker(lua_State *L) {
    struct titan_browser_arguments *args = lua_touserdata(L, 1);
    lua_Unsigned nargs = (lua_Unsigned)args->argc;
    Table *array_metatable, *arguments;
    TValue writer;
    Udata *proxy;
    int i;
    luaL_openlibs(L);
    titan_install_searcher(L);
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    lua_pushcfunction(L, luaopen_titan);
    lua_setfield(L, -2, "titan");
    lua_pushcfunction(L, $LUAOPEN);
    lua_setfield(L, -2, "$MODNAME");
    lua_settop(L, 0);
    lua_getglobal(L, "require");
    lua_pushliteral(L, "$MODNAME");
    lua_call(L, 1, 1);
    lua_getfield(L, -1, "main");
    lua_remove(L, -2);
    array_metatable = titan_array_metatable(L);
    lua_pushlightuserdata(L, &titan_main_array_writer_key);
    lua_pushcclosure(L, titan_main_string_array_writer, 1);
    writer = lua_totvalue(L, -1);
    lua_pushnil(L);
    arguments = titan_array_new(L, array_metatable, nargs, &writer, L->top.p - 1);
    lua_remove(L, -2);
    proxy = titan_array_require_proxy(arguments);
    setuvalue(L, s2v(L->top.p - 1), proxy);
    for (i = 0; i < args->argc; i++) {
        lua_pushlstring(L, args->lengths[i] ? (const char *)args->argv[i] : "", args->lengths[i]);
        titan_array_set_stack(L, arguments, (lua_Integer)i + 1, -1);
        lua_pop(L, 1);
    }
    titan_array_set_length(arguments, nargs);
    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_MAIN_BOOTSTRAP_KEY);
    if ($SKIP || lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_call(L, 1, 1);
    } else {
        lua_insert(L, 1);
        lua_call(L, 2, 1);
    }
    return 1;
}
]]
    local opener = "luaopen_" .. driver.mangle_module_name(modname)
    return driver.browser_c_image_contents(util.render(worker, {
        LUAOPEN = opener, MODNAME = c_string_contents(modname),
        SKIP = options.no_uv_bootstrap and "1" or "0",
    }), { declarations = "extern int luaopen_titan(lua_State *L);\nextern int " .. opener .. "(lua_State *L);",
        program_name = c_string_contents(program_name or modname:gsub(".*[.]", "")) })
end

local function write_entrypoint(modname, entrypoint_c, program_name,
                                options, verbose)
    options = options or {}
    entrypoint_c = entrypoint_c or
        (modname:gsub("[.]", "/") .. "__entrypoint.c")
    local contents = driver.entrypoint_contents(modname, program_name, options)
    local wrote, write_err = util.set_file_contents(entrypoint_c, contents)
    if not wrote then return nil, write_err end
    local formatted, format_err = driver.format_generated_file(
        entrypoint_c, verbose, options.pretty_print)
    if not formatted then return nil, format_err end
    return entrypoint_c
end

local function ensure_directory(path)
    if platform.windows then
        local strategy = compiler_io.new_sync()
        local attributes, attribute_error = strategy:stat(path)
        if attribute_error then return nil, attribute_error end
        if attributes then
            return attributes.kind == "directory" and true or nil,
                attributes.kind ~= "directory" and
                    ("output path '" .. path .. "' is not a directory") or nil
        end
        local parent = platform.parent(path)
        if parent and parent ~= path then
            local ok, err = ensure_directory(parent)
            if not ok then return nil, err end
        end
        local made, make_error = strategy:mkdir(path)
        if made then return true end
        local appeared, appeared_error = strategy:stat(path)
        if appeared_error then return nil, appeared_error end
        if appeared and appeared.kind == "directory" then return true end
        return nil, make_error
    end
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
    if platform.windows then
        local parent = platform.parent(filename)
        if not parent then return true end
        return ensure_directory(parent)
    end
    local parent = filename:match("^(.*)/[^/]+$")
    if not parent or parent == "" then return true end
    return ensure_directory(parent)
end

function driver.prepare_output_root(directory)
    if type(directory) ~= "string" or directory == "" or directory:find("[%z\r\n]") then
        return nil, "--output requires a nonempty folder path without control characters"
    end
    local absolute, absolute_error = absolute_filename(directory)
    if not absolute then return nil, absolute_error end
    -- Resolve existing ancestors before lexical joining can collapse '..'
    -- across a symlink. The destination follows ordinary mkdir -p semantics.
    local output = physical_absolute_filename(absolute)
    local ok, err = ensure_directory(output)
    if not ok then return nil, "cannot create output folder '" .. directory .. "': " .. tostring(err) end
    return output
end

-- Called under the output-domain lock. A host only observes markers; only an
-- explicitly owned, empty browser root can acquire one.
function driver.validate_output_target(context, directory, create)
    driver.assert_target_context(context)
    local strategy = context.io
    local selected = driver.context_target(context)
    local marker = path.join(directory, ".titan-target")
    local function read_error(reason)
        return nil, string.format("cannot read target marker %q: %s",
            marker, tostring(reason))
    end
    local stat, stat_error = strategy:lstat(marker)
    if stat_error then return read_error(stat_error) end
    if stat then
        if stat.kind ~= "file" or stat.size > 16 then
            return read_error("invalid target marker")
        end
        local contents, err = strategy:read_file(marker)
        if not contents then return read_error(err) end
        local marked = contents:match("^([a-z]+)\n$")
        if not marked or not source_labels[marked] then
            return read_error("invalid target marker")
        end
        if marked ~= selected then
            return nil, string.format(
                "output root %q belongs to target %q, not %q; use a separate --output directory",
                directory, marked, selected)
        end
        return true
    end
    if selected ~= "browser" or not create then return true end
    local entries, list_error = strategy:list(directory)
    if not entries then return read_error(list_error) end
    for _, name in ipairs(entries) do
        if name ~= "." and name ~= ".." and name ~= ".titan-build.lock" then
            return nil, string.format(
                "browser output root %q is not empty and has no .titan-target marker; use a separate --output directory",
                directory)
        end
    end
    local written, write_error = strategy:write_file(marker, "browser\n")
    if not written then
        return nil, string.format("cannot write target marker %q: %s",
            marker, tostring(write_error))
    end
    return true
end

function driver.sibling_temporary_path(filename, strategy)
    strategy = strategy or compiler_io.new_sync()
    local unique, temporary_error = strategy:tmpname()
    if not unique then return nil, temporary_error end
    local removed, remove_error = strategy:unlink(unique, true)
    if not removed then return nil, remove_error end
    return filename .. ".tmp." .. path.basename(unique)
end

local function sibling_temporary_directory(filename)
    local directory, temporary_error = driver.sibling_temporary_path(filename)
    if not directory then return nil, temporary_error end
    local made, err = compiler_io.new_sync():mkdir(directory)
    if not made then return nil, err end
    return directory
end

-- Keep the linked image's basename identical to its eventual public basename.
-- This matters on macOS: dsymutil names the inner DWARF payload after the input
-- file, and libbacktrace later looks it up using the loaded DSO basename. The
-- random component therefore belongs in a sibling directory, not in the DSO.
function driver.staged_library_output(publicname)
    local parent_ok, parent_err = ensure_output_parent(publicname)
    if not parent_ok then return nil, parent_err end
    local basename = publicname:match(
        platform.windows and "([^/\\]+)$" or "([^/]+)$")
    if not basename then return nil, "invalid library output path" end
    local directory, make_err = sibling_temporary_directory(publicname .. ".stage")
    if not directory then return nil, make_err end
    return append_path(directory, basename), directory
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

local function remove_staging_path(strategy, filename)
    local info, err = strategy:lstat(filename)
    if not info then
        if err then return nil, "cannot inspect '" .. filename .. "': " .. tostring(err) end
        return true
    end
    if info.kind == "directory" then
        local entries
        entries, err = strategy:list(filename)
        if not entries then return nil, "cannot list '" .. filename .. "': " .. tostring(err) end
        for _, name in ipairs(entries) do
            local removed, remove_error = remove_staging_path(
                strategy, append_path(filename, name))
            if not removed then return nil, remove_error end
        end
        local removed
        removed, err = strategy:rmdir(filename)
        if removed then return true end
    else
        local removed
        removed, err = strategy:unlink(filename)
        if removed then return true end
    end
    return nil, "cannot remove '" .. filename .. "': " .. tostring(err)
end

-- Attempt every reserved directory even when another image remains locked.
-- A successful publication is not rolled back when retiring its scratch fails.
function driver.cleanup_staging_directories(directories, strategy)
    strategy = strategy or compiler_io.new_sync()
    local errors = {}
    for _, directory in ipairs(directories) do
        local removed, err = remove_staging_path(strategy, directory)
        if not removed then errors[#errors + 1] = err end
    end
    if #errors > 0 then return nil, table.concat(errors, "\n") end
    return true
end

-- A held lock file's physical identity, observed without following its leaf.
-- A file without a native file ID never authorizes a domain.
local function staging_lock_identity(strategy, filename)
    local info, err = strategy:lstat(filename)
    if err then return nil, err end
    if not info or info.kind ~= "file" or info.device == nil or info.inode == nil then
        return false
    end
    return tostring(info.device) .. "\0" .. tostring(info.inode)
end

-- The basename-preserving staging namespace belongs to the corresponding
-- final output. Retire abandoned reservations before even a final-link hit,
-- but only while that output's domain remains exclusively locked, and never
-- over a path this invocation accepted or reserved. `protection.plan` is the
-- preflighted build plan, whose source modules the build has restored into
-- driver.imported; `protection.native_objects` are this invocation's
-- `nativeinputs.compile` results; `protection.link_inputs` are the prepared
-- final link's explicit inputs and `protection.native_policy` its native
-- library policy; `protection.compiler_tools` (nil when uncertified) and
-- `protection.output_tools` are the compiler and output-tool identities.
function driver.cleanup_stale_staging(context, outputs, locks, protection)
    driver.assert_target_context(context)
    if not platform.windows then return true end
    if not locks or not locks.entries or #locks.entries == 0 then
        return nil, "stale staging cleanup requires held output locks"
    end
    local strategy = context.io
    local function key(filename)
        return (filename:gsub("\\", "/"):gsub("/+$", ""):lower())
    end
    local domains = {}
    for _, entry in ipairs(locks.entries) do
        local directory, err = absolute_filename(entry.directory, strategy)
        if not directory then return nil, err end
        domains[#domains + 1] = key(directory)
    end
    -- Lock deduplication keeps one spelling per physical lock file. Any other
    -- admitted spelling of a held domain, such as a junction, reaches that
    -- very file from the output's parent or one of its ancestors.
    local held
    local function locked(parent)
        local parent_key = key(parent)
        for _, domain in ipairs(domains) do
            if parent_key == domain or
                    parent_key:sub(1, #domain + 1) == domain .. "/" then
                return true
            end
        end
        if not held then
            held = {}
            for _, entry in ipairs(locks.entries) do
                if entry.path then
                    local identity, err = staging_lock_identity(strategy, entry.path)
                    if identity == nil then return nil, err end
                    if identity then held[identity] = true end
                end
            end
        end
        if next(held) == nil then return false end
        local lock_name = require("titan-compiler.build").LOCK_NAME
        local directory = parent
        while directory do
            local identity, err = staging_lock_identity(
                strategy, append_path(directory, lock_name))
            if identity == nil then return nil, err end
            if identity and held[identity] then return true end
            directory = platform.parent(directory)
        end
        return false
    end
    local directories, order = {}, {}
    for _, output in ipairs(outputs) do
        if output.kind ~= "directory" then
            local filename, err = absolute_filename(output.path, strategy)
            if not filename then return nil, err end
            local parent, basename = platform.parent(filename)
            local covered
            covered, err = locked(parent)
            if covered == nil then return nil, err end
            if not covered then
                return nil, "stale staging cleanup has no output lock for '" .. filename .. "'"
            end
            local parent_key = key(parent)
            local directory = directories[parent_key]
            if not directory then
                directory = { path = parent, prefixes = {}, owners = {} }
                directories[parent_key] = directory
                order[#order + 1] = directory
            end
            directory.prefixes[#directory.prefixes + 1] = basename:lower() .. ".stage.tmp."
            directory.owners[#directory.owners + 1] = filename
        end
    end
    local plan = type(protection) == "table" and protection.plan or nil
    if type(plan) ~= "table" or type(plan.inputs) ~= "table" or
            type(plan.reservations) ~= "table" then
        return nil, "stale staging cleanup requires the invocation's " ..
            "preflighted inputs and reservations"
    end
    local native_objects = protection.native_objects
    if type(native_objects) ~= "table" then
        return nil, "stale staging cleanup requires the invocation's native C nodes"
    end
    for _, object in ipairs(native_objects) do
        if type(object) ~= "table" or type(object.source) ~= "string" or
                type(object.dependencies) ~= "table" then
            return nil, "stale staging cleanup requires each native C node's " ..
                "source and recorded dependencies"
        end
    end
    if type(protection.link_inputs) ~= "table" then
        return nil, "stale staging cleanup requires the invocation's final-link inputs"
    end
    if type(protection.native_policy) ~= "table" then
        return nil, "stale staging cleanup requires the invocation's prepared native link policy"
    end
    if (protection.compiler_tools ~= nil and type(protection.compiler_tools) ~= "table") or
            type(protection.output_tools) ~= "table" then
        return nil, "stale staging cleanup requires the invocation's native tool identities"
    end

    -- Observe every candidate's complete no-follow footprint before removing
    -- anything: one conflict retains all candidates, abandoned ones included.
    local candidates, footprint = {}, {}
    local function observe(filename, info, owner)
        local physical = physical_absolute_filename(filename)
        footprint[#footprint + 1] = {
            path = filename, owner = owner, mode = info.kind,
            raw = filename, normalized = normalize_absolute_path(filename),
            physical = physical, portable = physical:lower(),
            existing_mode = info.kind, device = info.device, inode = info.inode,
        }
        if info.kind ~= "directory" then return true end
        local entries, err = strategy:list(filename)
        if not entries then
            return nil, "cannot list '" .. filename .. "': " .. tostring(err)
        end
        for _, name in ipairs(entries) do
            local child = append_path(filename, name)
            local child_info
            child_info, err = strategy:lstat(child)
            if err then return nil, "cannot inspect '" .. child .. "': " .. tostring(err) end
            if child_info then
                local observed
                observed, err = observe(child, child_info, owner)
                if not observed then return nil, err end
            end
        end
        return true
    end
    for _, directory in ipairs(order) do
        local info, err = strategy:stat(directory.path)
        if err then return nil, err end
        if info then
            local entries
            entries, err = strategy:list(directory.path)
            if not entries then return nil, err end
            for _, name in ipairs(entries) do
                for index, prefix in ipairs(directory.prefixes) do
                    if #name > #prefix and name:sub(1, #prefix):lower() == prefix then
                        local filename = append_path(directory.path, name)
                        local candidate
                        candidate, err = strategy:lstat(filename)
                        if err then return nil, err end
                        -- Never traverse a matching user-authored link.
                        if candidate and candidate.kind == "directory" then
                            candidates[#candidates + 1] = filename
                            local observed
                            observed, err = observe(filename, candidate,
                                "final output '" .. directory.owners[index] .. "'")
                            if not observed then return nil, err end
                        end
                        break
                    end
                end
            end
        end
    end
    if #candidates == 0 then return true end

    -- Without a resolved native library inventory and known tool identities,
    -- a candidate may hold an input or tool no evidence names. Retain them all.
    local incomplete
    if type(protection.native_policy.files) ~= "table" then
        incomplete = protection.native_policy.reason or "native link libraries are unresolved"
    elseif protection.compiler_tools == nil then
        incomplete = "the compiler toolchain is uncertified"
    elseif protection.output_tools.uncertified ~= nil then
        incomplete = tostring(protection.output_tools.uncertified)
    end
    if incomplete then
        return nil, "refusing to retire stale Windows staging '" .. candidates[1] ..
            "': the native link and tool inventory is incomplete (" .. tostring(incomplete) .. ")"
    end

    -- Accepted inputs and reserved outputs, plus the source constituents and
    -- C headers the build recorded after preflight, each --c-source with the
    -- dependencies its one native preprocessing run recorded, the final link's
    -- inputs and policy-resolved libraries, and every active native tool.
    -- Spelling, hierarchy and physical-file aliases of any footprint entry
    -- refuse every candidate.
    local protected = {}
    for _, reserved in ipairs(plan.reservations) do protected[#protected + 1] = reserved.path end
    for _, input in ipairs(plan.inputs) do protected[#protected + 1] = input end
    for _, name in ipairs(plan.order or {}) do
        local mod = driver.imported[name]
        if mod and mod ~= CIRCULAR_MARK then
            for _, filename in ipairs(mod.source_files or {}) do
                protected[#protected + 1] = filename
            end
            for _, dependency in ipairs(mod.c_header_dependencies or {}) do
                if dependency.kind ~= "search" then
                    protected[#protected + 1] = dependency.filename or dependency.path
                end
            end
        end
    end
    for _, object in ipairs(native_objects) do
        protected[#protected + 1] = object.source
        for _, dependency in ipairs(object.dependencies) do
            protected[#protected + 1] = dependency
        end
    end
    for _, input in ipairs(protection.link_inputs) do protected[#protected + 1] = input end
    for _, filename in ipairs(protection.native_policy.files) do
        protected[#protected + 1] = filename
    end
    for _, identity in ipairs(protection.compiler_tools) do
        protected[#protected + 1] = identity.path
    end
    local roles = {}
    for role, tool in pairs(protection.output_tools) do
        if type(tool) == "table" then roles[#roles + 1] = role end
    end
    table.sort(roles)
    for _, role in ipairs(roles) do
        local tool = protection.output_tools[role]
        for _, selected in ipairs(role == "lto_plugins" and tool or { tool }) do
            protected[#protected + 1] = selected.identity and selected.identity.path
        end
    end
    local accepted, conflict = perf.new_output_path_index(
        "staging path", footprint, strategy).check_inputs(protected)
    if not accepted then
        return nil, "refusing to retire stale Windows staging: " .. tostring(conflict)
    end
    local removed, err = driver.cleanup_staging_directories(candidates, strategy)
    if not removed then
        return nil, "cannot retire stale Windows staging: " .. tostring(err)
    end
    return true
end

local function absolute_native_path(filename)
    if platform.windows then return assert(absolute_filename(filename)) end
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
        require_layouts = true,
        validate_layouts = decode_nominal_layouts,
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
        options.require_layouts = true
        options.validate_layouts = decode_nominal_layouts
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
function driver.derive_target_fingerprint(filename, expected_module, context)
    local descriptor, descriptor_error = driver.context_target_descriptor(context)
    if descriptor_error then return nil, descriptor_error end
    local parsed, scan_err = scan_native_file(
        filename, descriptor and descriptor.fingerprint or nil, true)
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

function driver.validate_generated_objects(objects, target, entries, context)
    if context then driver.assert_target_context(context) end
    local file_context = context
    for _, input in ipairs(objects or {}) do
        local filename = type(input) == "table" and input.filename or input
        local expected_module =
            type(input) == "table" and input.modname or nil
        local fingerprint, parsed_or_err =
            driver.derive_target_fingerprint(filename, expected_module, context)
        if not fingerprint then return nil, parsed_or_err end
        local matches, mismatch =
            staticmetadata.fingerprint_matches(fingerprint, target)
        if not matches then
            return nil, "generated module object '" .. tostring(filename) ..
                "' target mismatch: " .. tostring(mismatch)
        end
        if entries then
            local entry = parsed_or_err.metadata
            if entries[entry.module] then
                return nil, "duplicate generated module metadata '" .. entry.module .. "'"
            end
            entries[entry.module] = entry
        end
        local part_objects = type(input) == "table" and input.objects or nil
        for part_idx = 2, #(part_objects or {}) do
            local part_file = part_objects[part_idx]
            file_context = file_context or {
                io = compiler_io.new_sync(), cache_adapter = default_digest_adapter(),
            }
            if context and context.target == "browser" and
               not context.io:stat(part_file) then
                return nil, string.format(
                    "browser provider module %q is missing split part %d",
                    expected_module, part_idx - 1)
            end
            local part_fingerprint, part_err =
                incremental.part_fingerprint(file_context, part_file)
            if not part_fingerprint then
                return nil, "generated module part object '" ..
                    tostring(part_file) .. "': " .. tostring(part_err)
            end
            local part_matches, part_mismatch =
                staticmetadata.fingerprint_matches(part_fingerprint, target)
            if not part_matches then
                return nil, "generated module part object '" ..
                    tostring(part_file) .. "' target mismatch: " ..
                    tostring(part_mismatch)
            end
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
        if target.format == "wasm" then
            if not active.members then
                local scanned, err = staticmetadata.scan_archive(
                    provider.archive or provider.filename, metadata_scan_options(target))
                if not scanned then return nil, err end
                local equal, equality_error = driver.compare_archive_entries(
                    scanned.entries, provider.entries, "planned browser provider")
                if not equal then return nil, equality_error end
                provider.members, provider.records, provider.bytes =
                    scanned.members, scanned.records, scanned.bytes
                provider.kind, provider.format = "archive", "archive"
                active = provider
            end
            local valid, err = driver.validate_browser_provider(active)
            if not valid then return nil, err end
        end
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
        if found.layouts ~= wanted.layouts then
            return nil, subject .. " nominal layout metadata for module '" ..
                name .. "' differs"
        end
        if found.payload and wanted.payload and
           found.payload ~= wanted.payload then
            return nil, subject .. " canonical payload for module '" ..
                name .. "' differs"
        end
    end
    return true
end

-- Validate reader evidence only; browser providers are never host-loaded.
function driver.validate_browser_provider(archive, expected_entries, generated_objects)
    if expected_entries then
        local valid, err = driver.compare_archive_entries(
            archive.entries, expected_entries, "browser provider")
        if not valid then return nil, err end
    end
    local primaries, available = {}, generated_objects and {} or nil
    local function forbidden(name)
        return name == "dlopen" or name == "dlsym" or name == "dlerror" or
            type(name) == "string" and
            (name:match("^backtrace_") or name:match("^__backtrace_"))
    end
    for _, member in ipairs(archive.members or {}) do
        local object = member.object
        if object.format ~= "wasm" then
            return nil, tostring(member.origin) ..
                ": browser provider requires Wasm objects"
        end
        if available then
            available[object.bytes] = (available[object.bytes] or 0) + 1
        end
        if object.metadata then primaries[object.metadata.module] = member end
        for _, import in ipairs(object.imports or {}) do
            if forbidden(import.name) then
                return nil, string.format(
                    "%s: browser provider imports forbidden symbol %q",
                    member.origin, import.name)
            end
        end
        for _, symbol in ipairs(object.symbols or {}) do
            if not symbol.defined and forbidden(symbol.name) then
                return nil, string.format(
                    "%s: browser provider imports forbidden symbol %q",
                    member.origin, symbol.name)
            end
        end
    end
    for _, name in ipairs(archive.key_order or {}) do
        local primary = primaries[name]
        local defined = {}
        for _, symbol in ipairs(primary and primary.object.symbols or {}) do
            if symbol.defined and symbol.kind == "function" and
               symbol.binding == "global" then
                defined[symbol.name] = true
            end
        end
        local prefix = driver.mangle_module_name(name)
        for _, symbol in ipairs({ prefix .. "_abi", prefix .. "_types",
                prefix .. "_layouts", prefix .. "_init", "luaopen_" .. prefix }) do
            if not defined[symbol] then
                return nil, string.format(
                    "%s: browser provider module %q requires global non-weak function %q",
                    primary and primary.origin or archive.origin, name, symbol)
            end
        end
    end
    for _, generated in ipairs(generated_objects or {}) do
        for index, filename in ipairs(generated.objects or { generated.filename }) do
            local bytes = read_binary_file(filename)
            if bytes and (available[bytes] or 0) > 0 then
                available[bytes] = available[bytes] - 1
            elseif index > 1 then
                return nil, string.format(
                    "browser provider module %q is missing split part %d",
                    generated.modname, index - 1)
            else
                return nil, string.format(
                    "browser provider module %q is missing its primary member",
                    generated.modname)
            end
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


local function copy_argv(argv)
    local copy = {}
    append_argv(copy, argv)
    return copy
end

local function run_archive_tool(base, arguments, verbose, discard_output)
    local argv = copy_argv(base)
    append_argv(argv, arguments)
    return run_argv(argv, verbose, discard_output)
end

local function archive_tool_capabilities(ar, ranlib, probe, object, verbose)
    os.remove(probe)
    local ar_args = { "qDc", probe }
    if object then ar_args[#ar_args + 1] = object end
    local ar_d = run_archive_tool(ar, ar_args, verbose, true)
    if not ar_d then
        os.remove(probe)
        ar_args[1] = "qc"
        local ar_ok, ar_term, ar_code =
            run_archive_tool(ar, ar_args, verbose, true)
        if not ar_ok then
            os.remove(probe)
            return nil, "configured AR supports neither qDc nor qc (" ..
                tostring(ar_term) .. ", exit " .. tostring(ar_code) .. ")"
        end
    end

    local ranlib_d = run_archive_tool(ranlib, { "-D", probe }, verbose, true)
    if not ranlib_d then
        local ranlib_ok, ranlib_term, ranlib_code =
            run_archive_tool(ranlib, { probe }, verbose, true)
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
-- Implementation notes: doc/implementation/static-compiled-modules.md#native-composition
function driver.build_static_archive(
        output, object_inputs, archive_inputs, target, verbose, ordered_inputs, context)
    if type(target) ~= "table" then
        return nil, "static archive construction requires a target fingerprint"
    end
    local descriptor, descriptor_error = driver.context_target_descriptor(context)
    if descriptor_error then return nil, descriptor_error end
    if descriptor then
        local matches, mismatch = staticmetadata.fingerprint_matches(
            target, descriptor.fingerprint)
        if not matches then return nil, "browser archive target mismatch: " .. mismatch end
        target = descriptor.fingerprint
    end
    local output_ok, output_err = ensure_output_parent(output)
    if not output_ok then return nil, output_err end
    local stage, make_err = sibling_temporary_directory(output .. ".archive-stage")
    if not stage then return nil, make_err end
    stage = absolute_native_path(stage)
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

    local ar, ar_err = descriptor and copy_argv(descriptor.tools.ar) or nil
    if not ar then ar, ar_err = perf.tool_command(driver.AR, "AR") end
    if not ar then return abort(ar_err) end
    local ranlib, ranlib_err = descriptor and copy_argv(descriptor.tools.ranlib) or nil
    if not ranlib then ranlib, ranlib_err = perf.tool_command(driver.RANLIB, "RANLIB") end
    if not ranlib then return abort(ranlib_err) end
    local capability, capability_err = archive_tool_capabilities(
        ar, ranlib, probe, staged_paths[1], verbose)
    if not capability then return abort(capability_err) end
    if descriptor and not capability.deterministic then
        return abort("browser archive tools require deterministic qDc and -D modes")
    end

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

    local published, publish_err = rename_output(temporary, output)
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

function driver.stage_browser_provider(request)
    local staged, directory = driver.staged_library_output(request.public_dso)
    if not staged then return nil, directory end
    local result, err = driver.build_static_archive(
        staged, nil, nil, request.target, request.verbose,
        request.archive_inputs, request.context)
    if result then
        local expected = request.expected_entries or {}
        local valid
        valid, err = driver.validate_browser_provider(
            result.archive, expected, request.generated_objects)
        if valid then
            return { archive = staged, directory = directory, entries = expected }
        end
    end
    remove_path(directory)
    return nil, err
end

-- Build the private archive-backed sibling image through the same DSO link
-- policy. Callers validate its complete protocol set with
-- validate_library_image and remove it after use.
function driver.compile_archive_validation_image(
        output, archive, link, verbose, extra_objects, module_names)
    return driver.compile_library_output(
        output, {}, link, verbose, extra_objects, { archive }, nil, nil,
        module_names)
end

-- PE exports need the public raw declarations even when a fresh publication
-- process has only compile-only objects and their existing source metadata.
local function windows_link_interfaces(libnames, extra_objects, ordered_payload)
    local objects = { table.unpack(libnames or {}) }
    if ordered_payload then
        for _, input in ipairs(ordered_payload) do
            if input.object then
                objects[#objects + 1] = assert(input.link_path or input.path)
            end
        end
    else
        append_argv(objects, extra_objects or {})
    end
    local interfaces = {}
    for _, object in ipairs(objects) do
        if type(object) ~= "string"
           or not object:match("[.]part[1-9][0-9]*[.]o$") then
            local bytes = util.get_file_contents(object, "rb")
            local entry = bytes and objectmetadata.read(bytes, object)
            if entry then interfaces[entry.type.name] = entry.type end
        end
    end
    return interfaces
end

-- Provider link helpers stay block-scoped because the main chunk is near Lua's
-- 200-active-local limit; only driver fields escape.
do

-- Build one provider-shaped DSO link without running it. The record owns the
-- argv plus the Windows `.def` and Darwin dSYM obligations that
-- finish_library_link completes after the native command.
local function prepare_library_link(soname, libnames, link, verbose,
                                    extra_objects, static_archives,
                                    ordered_payload, install_name,
                                    module_names, dsymutil)
    if platform.windows and (not module_names or #module_names == 0) then
        return nil, "Windows DLL linking requires its logical module inventory"
    end
    local runtime_ok, runtime_err = perf.check_runtime(verbose)
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
    if platform.windows then
        -- COFF and PE debug-directory timestamps must not change an otherwise
        -- identical provider when an incremental build repeats its link.
        append_argv(args, { "-Xlinker", "--no-insert-timestamp" })
    end
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
    local export_file
    if platform.windows then
        local interfaces = windows_link_interfaces(
            libnames, extra_objects, ordered_payload)
        local exports = driver.windows_provider_exports(
            module_names, interfaces, install_name or soname)
        export_file = soname .. ".def"
        local wrote, write_error = util.set_file_contents(export_file, exports)
        if not wrote then return nil, write_error end
        table.insert(args, export_file)
    end
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
    append_argv(args, driver.link_extra_flags())
    return {
        argv = args,
        soname = soname,
        export_file = export_file,
        install_name = install_name,
        dsymutil = dsymutil,
    }
end

local function finish_library_link(prepared, verbose, ok, term, code)
    if prepared.export_file then os.remove(prepared.export_file) end
    if ok then
        local dsym_ok, dsym_term, dsym_code = run_dsymutil(
            prepared.soname, verbose, prepared.install_name ~= nil, prepared.dsymutil)
        if not dsym_ok then
            os.remove(prepared.soname)
            remove_path(prepared.soname .. ".dSYM")
            return nil, dsym_term, dsym_code
        end
    end
    return ok, term, code
end

-- Implementation notes: doc/implementation/driver.md#drivercompile_library_output
function driver.compile_library_output(soname, libnames, link, verbose,
                                       extra_objects, static_archives,
                                       ordered_payload, install_name,
                                       module_names)
    local prepared, err = prepare_library_link(soname, libnames, link,
        verbose, extra_objects, static_archives, ordered_payload,
        install_name, module_names)
    if not prepared then return nil, err end
    return finish_library_link(prepared, verbose,
        driver.run_link_command(prepared.argv, verbose, prepared.soname))
end

function driver.link_failure_message(kind, name, term, code)
    return string.format("failed to link %s '%s' (%s%s)",
        kind, name, tostring(term), code and (", " .. tostring(code)) or "")
end

-- Implementation notes: doc/implementation/static-compiled-modules.md#provider-link-pipeline
-- Link, archive, and validate one Unix provider pair in a private sibling
-- stage. The DSO link runs as a native child while the archive is built. The
-- archive-backed validation link joins it only with its own jobserver-granted
-- slot; otherwise the two links run in sequence. The first failure in serial
-- pipeline order is reported. Any failure or interruption drains running
-- links, discards their output, and removes the whole stage.
function driver.link_provider_pair(request)
    if request.context and request.context.target == "browser" then
        return driver.stage_browser_provider(request)
    end
    assert(not platform.windows, "Windows DLL providers have no paired archive")
    local provider, verbose = request.provider, request.verbose
    local module_names = request.module_names
    local link_failure = driver.link_failure_message
    local dso, directory = driver.staged_library_output(request.public_dso)
    if not dso then
        return nil, "failed to stage library '" .. provider .. "': " ..
            tostring(directory)
    end
    local archive = dso:gsub("[.]so$", ".a")
    local image = directory .. "/archive-validation.so"
    -- Even one slot runs its links as background children, so the
    -- cancellation guard must own INT/TERM/HUP for the whole transaction. A
    -- slow link also gets idle progress frames while it runs.
    local slots, slots_err = jobs.open_slots(request.parallelism,
        { guard = true, idle = idle_hook() })
    if not slots then
        remove_path(directory)
        return nil, slots_err
    end

    local interrupted = {}
    local notification, archive_result
    local links = {} -- [1] staged DSO, [2] archive-backed validation image

    local function check_interrupt()
        if slots:cancelled() then error(interrupted, 0) end
    end

    local function reap(index)
        compile_batch.reap(links[index].process)
        links[index].reaped = true
        return slots:release()
    end

    -- Reap the next completed link, or report a readable token when
    -- want_slot is set. Only this function consumes completion lines.
    local function await(want_slot)
        local event, detail = slots:wait(notification.file, want_slot)
        if event == "signal" then error(interrupted, 0) end
        if event ~= "completion" then return event, detail end
        local called, line, read_err =
            pcall(notification.file.read, notification.file, "*l")
        local index = called and tonumber(line)
        if not index or not links[index] or links[index].reaped then
            return nil, "failed to receive provider link completion: " ..
                tostring(called and (read_err or line) or line)
        end
        local released, release_err = reap(index)
        if not released then return nil, release_err end
        return event
    end

    local function wait_for(index)
        while not links[index].reaped do
            local event, err = await(false)
            if not event then return nil, err end
        end
        return true
    end

    -- The caller holds the slot; a failed launch returns it.
    local function launch(index, prepared, show)
        local called, process, launch_err = pcall(compile_batch.launch,
            prepared, show, notification, index)
        if not called then launch_err, process = process, nil end
        if not process then
            slots:release()
            return nil, launch_err
        end
        links[index] = { prepared = prepared, process = process }
        return true
    end

    local function launch_now(index, prepared, show)
        local acquired, acquire_err = slots:acquire_nowait()
        if not acquired then
            return nil, acquire_err or "no native job slot is available"
        end
        return launch(index, prepared, show)
    end

    -- Replay the captured output, then complete dSYM/.def obligations.
    local function finish(index)
        links[index].finished = true
        return finish_library_link(links[index].prepared, verbose,
            compile_batch.finish(links[index].process))
    end

    local function validate_image(filename, subject)
        local valid, err = driver.validate_library_image(filename, module_names)
        if valid then
            valid, err = driver.validate_archive_library_equality(
                archive_result.archive, filename, module_names, subject)
        end
        if valid then
            valid, err = driver.validate_library_image_fresh(
                filename, archive_result.entries, module_names, verbose)
        end
        return valid, err
    end

    -- Returns the first failure in serial pipeline order, or nil.
    local function run()
        local created, opened, open_err =
            pcall(compile_batch.create_notification)
        if not created then open_err, opened = opened, nil end
        if not opened then return open_err end
        notification = opened
        -- One native slot keeps the historical fully serial order.
        local overlap = slots.limit > 1

        local dso_link, dso_err = prepare_library_link(dso, request.libnames,
            request.link, verbose, nil, request.static_archives,
            request.ordered_payload, request.public_dso, module_names, request.dsymutil)
        -- The final-link certificate's linker dependency report belongs to
        -- the public DSO link only, never to the archive validation image.
        if dso_link then append_argv(dso_link.argv, request.final_link_flags) end
        local launched = dso_link
        if dso_link then launched, dso_err = launch_now(1, dso_link, verbose) end
        if not launched then return link_failure("library", provider, dso_err) end

        local archive_err
        local function build_archive()
            archive_result, archive_err = driver.build_static_archive(
                archive, nil, nil, request.target, verbose,
                request.archive_inputs, request.context)
            check_interrupt()
        end
        if overlap then build_archive() end

        -- Same link policy as compile_archive_validation_image.
        local image_link, image_err
        local function prepare_image()
            image_link, image_err = prepare_library_link(
                image, {}, request.link, verbose, nil, { archive },
                nil, nil, module_names, request.dsymutil)
            if not image_link then
                image_err = link_failure(
                    "archive validation image", provider, image_err)
            end
            return image_link
        end
        local function start_image(held)
            -- A pending interrupt must not start another child; closing the
            -- ledger returns a slot already held for it.
            check_interrupt()
            local started, start_err = (held and launch or launch_now)(
                2, image_link, false)
            if not started then
                image_err = link_failure(
                    "archive validation image", provider, start_err)
            end
        end
        -- Only a usable shared jobserver can grant the image link its own
        -- slot while the DSO link still occupies the recipe's slot.
        if overlap and slots.shared and archive_result and prepare_image() then
            while not links[1].reaped do
                local granted, grant_err = slots:acquire_nowait()
                if granted == nil then
                    -- Reported after the DSO link and validations it follows.
                    image_err = link_failure(
                        "archive validation image", provider, grant_err)
                    break
                end
                if granted then
                    start_image(true)
                    break
                end
                local event, err = await(true)
                if not event then return err end
            end
        end

        local waited, wait_err = wait_for(1)
        if not waited then return wait_err end
        local linked, term, code = finish(1)
        check_interrupt()
        if not linked then return link_failure("library", provider, term, code) end
        if not overlap then build_archive() end
        if not archive_result then
            return "failed to build static provider '" .. provider .. "': " ..
                tostring(archive_err)
        end

        -- The image command is shown at a fixed point in the pipeline,
        -- however early its slot was granted.
        local function announce_image()
            if not links[2] and not image_err and
               (image_link or prepare_image()) then
                start_image(false)
            end
            if links[2] and verbose then
                return compile_batch.show_command(
                    assert(command_argv(image_link.argv)))
            end
            return true
        end
        local shown, show_err = true, nil
        if overlap then shown, show_err = announce_image() end
        if not shown then return show_err end

        local valid, validation_err = validate_image(
            dso, "staged provider pair for '" .. provider .. "'")
        check_interrupt()
        if not valid then return validation_err end
        if not overlap then shown, show_err = announce_image() end
        if not shown then return show_err end
        if image_err then return image_err end

        waited, wait_err = wait_for(2)
        if not waited then return wait_err end
        linked, term, code = finish(2)
        check_interrupt()
        if not linked then
            return link_failure("archive validation image", provider, term, code)
        end
        valid, validation_err = validate_image(
            image, "archive-backed provider for '" .. provider .. "'")
        remove_path(image)
        remove_path(image .. ".dSYM")
        check_interrupt()
        if not valid then return validation_err end
    end

    local completed, failure = pcall(run)
    if not completed then
        failure = failure ~= interrupted and tostring(failure) or nil
    end
    -- Only failure paths still own running or unreplayed links.
    for index = 1, 2 do
        local link = links[index]
        if link and not link.finished then
            if not link.reaped then reap(index) end
            os.remove(link.process.stdout_path)
            os.remove(link.process.stderr_path)
        end
    end
    if notification then
        local closed, close_err = compile_batch.close_notification(notification)
        if not closed then failure = failure or close_err end
    end
    local closed, close_err = slots:close()
    if not closed then failure = failure or close_err end
    -- Closing records a signal that arrived after run's last check.
    local signal = slots:cancelled()
    if signal or failure then
        remove_path(directory)
        if signal then
            -- The caller releases its own resources, then calls
            -- jobs.propagate(signal) under the restored signal action.
            return nil, "provider link interrupted by signal " ..
                tostring(signal), signal
        end
        return nil, failure
    end
    return {
        dso = dso,
        archive = archive,
        directory = directory,
        entries = archive_result.entries,
    }
end

end -- provider link helpers

function driver.compile_library(modname, libnames, link, verbose, extra_objects,
                                static_archives)
    local soname = modname:gsub("[.]", "/") .. (platform.windows and ".dll" or ".so")
    return driver.compile_library_output(
        soname, libnames, link, verbose,
        extra_objects, static_archives,
        nil, nil, platform.windows and { modname } or nil)
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

local function current_lua_executable()
    if driver.INSTALL_PATHS then
        return root_join(driver.INSTALL_PATHS.root,
            platform.windows and "bin/lua.exe" or "bin/lua")
    end
    if platform.windows then
        local source_lua = driver.LUA_SOURCE_PATH .. "/lua.exe"
        if lfs.attributes(source_lua, "mode") == "file" then return source_lua end
        -- Native titanc.exe is a compiler frontend, never the Lua interpreter
        -- for validation subprocesses. Select the controlled interpreter by
        -- its real name rather than reusing the frontend's argv[-1].
        return "lua.exe"
    end
    local source_lua = driver.LUA_SOURCE_PATH .. "/lua"
    if lfs.attributes(source_lua, "mode") == "file" then return source_lua end
    if type(arg) == "table" and type(arg[-1]) == "string" and
       lfs.attributes(arg[-1], "mode") == "file" then
        return arg[-1]
    end
    return "lua"
end

-- Validate linked images in a fresh process so package.loaded or compiler-side
-- state cannot make an invalid image appear valid.
local function validation_temporary_pair()
    local script, script_error = create_compile_log()
    if not script then return nil, script_error end
    local result, result_error = create_compile_log()
    if not result then
        os.remove(script)
        return nil, result_error
    end
    return script, result
end

function driver.validate_library_image_fresh(
        filename, expected_entries, module_names, verbose)
    local expected, required = {}, {}
    for _, modname in ipairs(module_names) do
        required[#required + 1] = string.format("%q", modname)
        if expected_entries then
            local entry = assert(expected_entries[modname])
            expected[#expected + 1] = string.format(
                "[%q] = { abi = %q, types = %q, layouts = %q }",
                modname, entry.abi, entry.types, entry.layouts)
        end
    end
    -- A source-rock build can select its private native support bootstrap.
    -- Retain that search path while loading support afresh in the child.
    local script_source = "package.path = " ..
        string.format("%q", package.path) .. "\npackage.cpath = " ..
        string.format("%q", package.cpath) .. "\n" .. [[
local image, result = ...

local function finish(ok, message)
    local out = assert(io.open(result, "wb"))
    out:write(message)
    out:close()
    os.exit(ok and 0 or 1)
end

]]
    if not expected_entries then
        -- Reuse the compiler's metadata decoder and entry checks unchanged.
        -- Windows must never pin a staged DLL in the coordinator's loader.
        script_source = script_source .. [[
local validate = require("titan-compiler.driver").validate_library_image
local completed, valid, message = pcall(validate, image, { ]] ..
            table.concat(required, ", ") .. [[ })
if not completed then finish(false, tostring(valid)) end
finish(valid == true, valid and "ok" or tostring(message))
]]
    else
        script_source = script_source .. "local expected = { " ..
            table.concat(expected, ",\n") .. " }\n" .. [[
local support = require "titan"
for name, entry in pairs(expected) do
    local prefix = name:gsub("[%-.]", "_")
    if package.config:sub(1, 1) == "\\" then
        if type(support._abivalue) ~= "function" then
            finish(false, "Windows Titan support is missing its native ABI query helper")
        end
        local value, value_error = support._abivalue(image, prefix .. "_abi_value")
        if value ~= entry.abi then
            finish(false, prefix .. "_abi_value does not match embedded ABI: " ..
                tostring(value or value_error))
        end
    end
    for _, field in ipairs({ "abi", "types", "layouts" }) do
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
    end
    local script, result = validation_temporary_pair()
    if not script then return nil, result end
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

local function safe_provider_output_path(provider, extension)
    if not staticmetadata.valid_provider_prefix(provider) then return nil end
    local components = {}
    for component in provider:gmatch("[^.]+") do
        table.insert(components, component)
    end
    return table.concat(components, "/") .. extension
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

-- One filesystem observation per pathname, with prefix indexes for both
-- spelling and physical identity. No collision query performs filesystem I/O.
-- A caller may supply the resolver strategy that resolves relative input
-- spellings and, on Windows, observes them; the host strategy is the default.
function perf.new_output_path_index(label, reservations, strategy)
    local observations, attributes, outputs = {}, {}, {}
    local windows_io = platform.windows and (strategy or compiler_io.new_sync())
    local fields = { "normalized", "physical", "portable" }
    local exact, trees, identities = {}, {}, {}
    for _, field in ipairs(fields) do
        exact[field], trees[field] = {}, {}
    end

    local function file_mode(attr)
        if not attr then return nil end
        if windows_io then return attr.kind == "symlink" and "link" or attr.kind end
        return attr.mode
    end

    local function attrs(path)
        local cached = attributes[path]
        if cached == nil then
            if windows_io then
                -- The shared I/O boundary handles LFS's Windows directory
                -- table-query bug and retains complete no-follow metadata.
                local err
                cached, err = windows_io:lstat(path)
                if err then return nil, err end
            else
                cached = lfs.symlinkattributes(path)
            end
            cached = cached or false
            attributes[path] = cached
        end
        return cached or nil
    end

    local function follow(path, attr)
        if file_mode(attr) ~= "link" then return attr end
        if windows_io then return windows_io:stat(path) end
        local followed = lfs.attributes(path)
        return followed
    end

    local function observe(path)
        local raw, raw_error = absolute_filename(path, strategy)
        if not raw then return nil, raw_error end
        local cached = observations[raw]
        if cached then return cached end
        local attr, err = attrs(raw)
        if err then return nil, err end
        local followed
        followed, err = follow(raw, attr)
        if err then return nil, err end
        cached = {
            path = path,
            raw = raw,
            normalized = normalize_absolute_path(raw),
            physical = physical_absolute_filename(raw, attrs),
            existing_mode = file_mode(attr),
            -- The Windows I/O boundary omits weak LFS IDs but preserves the
            -- precise native IDs, which also identify aliases of held locks.
            device = followed and (windows_io and followed.device or followed.dev) or nil,
            inode = followed and (windows_io and followed.inode or followed.ino) or nil,
        }
        cached.portable = cached.physical:lower()
        observations[raw] = cached
        return cached
    end

    local function earlier(left, right)
        if not left or (right and right.index < left.index) then return right end
        return left
    end

    local function components(path)
        if platform.windows then path = path:gsub("\\", "/") end
        return path:gmatch("[^/]+")
    end

    local function tree_match(tree, path)
        local found = tree.terminal
        for component in components(path) do
            tree = tree.children and tree.children[component]
            if not tree then return found end
            found = earlier(found, tree.terminal)
        end
        return earlier(found, tree.first)
    end

    local function tree_insert(tree, path, output)
        tree.first = earlier(tree.first, output)
        for component in components(path) do
            if not tree.children then tree.children = {} end
            local child = tree.children[component]
            if not child then child = {}; tree.children[component] = child end
            tree = child
            tree.first = earlier(tree.first, output)
        end
        tree.terminal = output
    end

    local function match(observation)
        local found, alias
        local function consider(candidate, candidate_alias)
            if candidate and (not found or candidate.index < found.index) then
                found, alias = candidate, candidate_alias
            elseif candidate == found and candidate_alias then
                alias = true
            end
        end
        for _, field in ipairs(fields) do
            consider(exact[field][observation[field]], true)
            consider(tree_match(trees[field], observation[field]), false)
        end
        local device = observation.device and identities[observation.device]
        consider(device and device[observation.inode], true)
        return found, alias
    end

    local function insert(output)
        output.index = #outputs + 1
        outputs[#outputs + 1] = output
        for _, field in ipairs(fields) do
            exact[field][output[field]] = output
            tree_insert(trees[field], output[field], output)
        end
        if output.device ~= nil and output.inode ~= nil then
            local device = identities[output.device]
            if not device then device = {}; identities[output.device] = device end
            device[output.inode] = output
        end
    end

    local checked_parents = {}
    local function ancestors(path)
        local current = platform.windows and platform.parent(path) or
            path:match("^(.*)/[^/]+$")
        if not current or current == "" or checked_parents[current] then
            return true
        end
        local ok, err = ancestors(current)
        if not ok then return nil, err end
        local attr
        attr, err = attrs(current)
        if err then return nil, err end
        local followed
        followed, err = follow(current, attr)
        if err then return nil, err end
        if attr and (not followed or file_mode(followed) ~= "directory") then
            return nil, "output parent '" .. current .. "' is not a directory"
        end
        checked_parents[current] = true
        return true
    end

    local index = { outputs = outputs }
    function index.add(path, owner, mode)
        local observation, err = observe(path)
        if not observation then return nil, err end
        local ok
        ok, err = ancestors(observation.normalized)
        if not ok then return nil, err end
        if observation.existing_mode and observation.existing_mode ~= mode then
            local expected = mode == "directory" and
                "a nonlink directory" or "a regular nonlink file"
            return nil, label .. " '" .. observation.normalized .. "' for " ..
                owner .. " is not " .. expected
        end
        local previous, alias = match(observation)
        if previous then
            if alias then
                return nil, label .. " '" .. observation.normalized ..
                    "' for " .. owner .. " aliases output for " .. previous.owner
            end
            return nil, label .. " '" .. observation.normalized ..
                "' for " .. owner ..
                " has a path hierarchy conflict with output '" ..
                previous.normalized .. "' for " .. previous.owner
        end
        insert({
            path = path, owner = owner, mode = mode,
            raw = observation.raw, normalized = observation.normalized,
            physical = observation.physical, portable = observation.portable,
            existing_mode = observation.existing_mode,
            device = observation.device, inode = observation.inode,
        })
        return true
    end
    function index.check_inputs(inputs)
        for _, input in ipairs(inputs or {}) do
            local path = archive_input_path(input)
            if type(path) == "string" then
                local observation, err = observe(path)
                if not observation then return nil, err end
                local output, alias = match(observation)
                if output then
                    return nil, label .. " '" .. output.normalized ..
                        "' for " .. output.owner ..
                        (alias and " aliases input '" or
                            " has a path hierarchy conflict with input '") ..
                        observation.normalized .. "'"
                end
            end
        end
        return true
    end
    for _, output in ipairs(reservations or {}) do insert(output) end
    return index
end

function driver.validate_reserved_output_inputs(reservations, inputs)
    return perf.new_output_path_index("native provider output", reservations)
        .check_inputs(inputs)
end

function driver.validate_program_output_paths(
        source_outputs, executable, entrypoint_c, native_inputs, extra_outputs,
        planned_outputs, context)
    if type(executable) ~= "string" or executable == "" then
        return nil, "standalone executable path must be a nonempty string"
    end
    if type(entrypoint_c) ~= "string" or
       not entrypoint_c:match("[.]c$") then
        return nil, "standalone entrypoint path must end in .c"
    end
    local index = perf.new_output_path_index("program output")
    local add_output = index.add

    if planned_outputs then
        for _, output in ipairs(planned_outputs) do
            local ok, err = add_output(output.path, output.owner, output.mode or "file")
            if not ok then return nil, err end
        end
    else
    for _, source in ipairs(source_outputs or {}) do
        local stem = driver.module_output_stem(assert(source.output), source.modname)
        local owner = "logical module '" .. source.modname .. "'"
        local ok, err = add_output(stem .. ".c", owner, "file")
        if not ok then return nil, err end
        ok, err = add_output(stem .. ".o", owner, "file")
        if not ok then return nil, err end
        local max_parts = tonumber(source.c_parts) or 1
        local priv_path = stem .. ".priv.h"
        if max_parts > 1 then
            ok, err = add_output(priv_path,
                "generated private header for " .. owner, "file")
            if not ok then return nil, err end
            local priv_mode = lfs.symlinkattributes(priv_path, "mode")
            if priv_mode == "file" then
                local existing = util.get_file_contents(priv_path)
                if not existing or existing:sub(1, #driver.PRIVATE_HEADER_MARKER)
                   ~= driver.PRIVATE_HEADER_MARKER then
                    return nil, "refusing to overwrite user-owned generated-header path '"
                        .. priv_path .. "'"
                end
            end
        end
        for k = 1, max_parts - 1 do
            ok, err = add_output(driver.part_c_filename(stem, k), owner, "file")
            if not ok then return nil, err end
            ok, err = add_output(driver.part_object_filename(stem, k), owner, "file")
            if not ok then return nil, err end
        end
        if source.foreign_header then
            ok, err = add_output(source.foreign_header,
                "generated foreign header for logical module '" ..
                    source.modname .. "'", "file")
            if not ok then return nil, err end
        end
        if source.ffi_header then
            ok, err = add_output(source.ffi_header,
                "generated FFI header for logical module '" ..
                    source.modname .. "'", "file")
            if not ok then return nil, err end
        end
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
    for _, path in ipairs(extra_outputs or {}) do
        ok, err = add_output(path, "standalone native auxiliary output", "file")
        if not ok then return nil, err end
    end
    if driver.IS_DARWIN and not (context and context.target == "browser") then
        ok, err = add_output(
            executable .. ".dSYM", "standalone dSYM", "directory")
        if not ok then return nil, err end
    end

    return index.check_inputs(native_inputs)
end

-- A browser publication cannot safely claim ownership of old native files.
-- Refuse them, including symlinks and directories, without mutating either
-- the archive or the unknown companion.
function perf.check_browser_provider_companions(archive)
    local stem = archive:sub(1, -3)
    local filesystem = compiler_io.new_sync()
    for _, suffix in ipairs({ ".so", ".so.dSYM", ".dll", ".dll.def",
            ".dylib", ".dylib.dSYM", ".dll.a", ".lib", ".exp", ".pdb" }) do
        local companion = stem .. suffix
        local attributes, err = filesystem:lstat(companion)
        if err then
            return nil, string.format("cannot inspect browser provider companion %q: %s",
                companion, tostring(err))
        elseif attributes then
            return nil, string.format(
                "browser provider %q has native companion %q; use a separate --output directory",
                archive, companion)
        end
    end
    return true
end

function driver.validate_provider_output_paths(
        public_dso, native_inputs, generated_outputs, context)
    local browser = context and context.target == "browser"
    local public_archive = browser and public_dso or
        public_dso and not platform.windows and public_dso:gsub("[.]so$", ".a")
    if browser then
        if public_dso and not public_dso:match("[.]a$") then
            return nil, "browser provider path must end in .a"
        end
        if public_archive then
            local valid, err = perf.check_browser_provider_companions(public_archive)
            if not valid then return nil, err end
        end
        public_dso = nil
    elseif public_dso and platform.windows and not public_dso:match("[.]dll$") then
        return nil, "Windows provider path must end in .dll"
    elseif public_dso and public_archive == public_dso then
        return nil, "provider DSO path '" .. tostring(public_dso) ..
            "' does not end in .so"
    end

    local index = perf.new_output_path_index("native provider output")
    local add_output = index.add

    local ok, err
    if public_dso then
        ok, err = add_output(public_dso, "provider DSO", "file")
        if not ok then return nil, err end
    end
    if public_archive then
        ok, err = add_output(public_archive, "provider archive", "file")
        if not ok then return nil, err end
    end
    if public_dso and driver.IS_DARWIN then
        ok, err = add_output(
            public_dso .. ".dSYM", "provider dSYM", "directory")
        if not ok then return nil, err end
    end
    for _, generated in ipairs(generated_outputs or {}) do
        local path = assert(generated.path)
        ok, err = add_output(path,
            assert(generated.owner), generated.mode or "file")
        if not ok then return nil, err end
    end
    ok, err = index.check_inputs(native_inputs)
    if not ok then return nil, err end
    return true, public_archive, index.outputs
end

-- Reserve the whole invocation before the scheduler invalidates any object.
-- The maximum split inventory is compiler-owned even if code generation later
-- chooses fewer parts. The coordinator reads Titan declarations and existing
-- ownership markers only; fresh C-header discovery belongs to the workers.
-- Success records `plan.reservations` and the validated `plan.inputs`.
function driver.preflight_build_outputs(context, plan, options)
    driver.assert_target_context(context)
    if options.output_root then
        local valid, target_error = driver.validate_output_target(
            context, options.output_root, true)
        if not valid then return nil, target_error end
    end
    local inputs, input_seen, outputs, modules = {}, {}, {}, {}
    local output_owners, c_outputs = {}, {}
    local function input(filename)
        if filename and not input_seen[filename] then
            input_seen[filename] = true
            inputs[#inputs + 1] = filename
        end
    end
    local function output(filename, owner, mode, c_stem)
        if output_owners[filename] ~= owner then
            outputs[#outputs + 1] = { path = filename, owner = owner, mode = mode }
            output_owners[filename] = owner
        end
        if c_stem then c_outputs[filename] = c_stem end
    end
    for _, filename in ipairs(options.native_inputs or {}) do input(filename) end
    -- Coordination and metadata paths are invocation inputs, never legal
    -- destinations. The shared index rejects spelling, physical-file and
    -- hierarchy aliases before a worker invalidates any existing object.
    for _, entry in ipairs(options.locks and options.locks.entries or {}) do
        input(entry.path)
        if entry.directory then
            local valid, target_error = driver.validate_output_target(
                context, entry.directory, false)
            if not valid then return nil, target_error end
            input(path.join(entry.directory, ".titan-target"))
        end
    end
    if options.metadata_root then
        for _, name in ipairs({ ".titan", ".titan-links", ".native", ".titan-target" }) do
            input(path.join(options.metadata_root, name))
        end
    end
    local max_parts, parts_error = driver.effective_c_parts(options.c_parts)
    if not max_parts then return nil, parts_error end
    for _, name in ipairs(plan.order) do
        local selected = plan.modules[name]
        if selected.kind == "source" then
            local source, certified = selected.source, selected.certified
            local saved = certified and certified.status == "hit" and certified.record
            local info = { source = source, aliases = {}, imports = {}, saved = saved }
            modules[name] = info
            local stem = driver.module_output_stem(source.native_output or source.main, name)
            local owner = "logical module '" .. name .. "'"
            for index = 0, max_parts - 1 do
                output(driver.part_c_filename(stem, index), owner, nil, stem)
                output(driver.part_object_filename(stem, index), owner)
                local part_stem = driver.part_object_filename(stem, index):gsub("[.]o$", "")
                output(part_stem .. ".gcno", owner)
                output(part_stem .. ".gcda", owner)
            end
            -- A smaller new split policy can still retire the old inventory.
            local prior = certified and certified.record
            if not prior and context.io:lstat(stem .. ".o") then
                local bytes, read_error = perf.compiler_file_contents(context, stem .. ".o")
                if not bytes then return nil, read_error end
                prior = objectmetadata.read(bytes, stem .. ".o")
            end
            local native = prior and prior.object_metadata
            if native and native.parts and objectmetadata.validate_parts(native) then
                for _, part in ipairs(native.parts) do
                    output(stem .. part.c_suffix, owner, nil, stem)
                    output(stem .. part.object_suffix, owner)
                    local part_stem = (stem .. part.object_suffix):gsub("[.]o$", "")
                    output(part_stem .. ".gcno", owner)
                    output(part_stem .. ".gcda", owner)
                end
            end
            for _, header in ipairs({
                { suffix = ".priv.h", marker = driver.PRIVATE_HEADER_MARKER },
                { suffix = ".titan.h", marker = ffiheaders.FOREIGN_MARKER },
                { suffix = ".ffi.h", marker = ffiheaders.MARKER },
            }) do
                local filename = stem .. header.suffix
                output(filename, owner)
                local valid, header_error = validate_generated_header_entry({
                    filename = filename, marker = header.marker, contents = "",
                })
                if not valid then return nil, header_error end
            end
            for _, filename in ipairs(source.files) do input(filename) end
            if saved then
                info.has_main = saved.object_metadata.has_main
                info.type = saved.type
                for _, dependency in ipairs(saved.c_header_dependencies or {}) do
                    if dependency.kind ~= "search" then input(dependency.path) end
                end
            else
                local nodes = {}
                for _, filename in ipairs(source.files) do
                    local contents = source.contents and source.contents[filename] or
                        source.certified_contents and source.certified_contents[filename]
                    if not contents then
                        local read_error
                        contents, read_error = perf.compiler_file_contents(context, filename)
                        if not contents then return nil, read_error end
                    end
                    local parsed, parse_error = parser.parse(filename, contents)
                    if not parsed then return nil, parser.error_to_string(parse_error, filename) end
                    for _, node in ipairs(parsed) do
                        nodes[#nodes + 1] = node
                        if node._tag == "Ast.TopLevelTypeAlias" then
                            info.aliases[node.name] = node.type
                        elseif node._tag == "Ast.TopLevelImport" then
                            info.imports[node.localname] = node
                        end
                    end
                end
                info.nodes = nodes
            end
        end
    end
    local binary_names = {}
    for name, selected in pairs(plan.modules) do
        if selected.kind == "dynamic" or selected.kind == "static" then
            binary_names[#binary_names + 1] = name
        end
    end
    table.sort(binary_names, util.bytewise_less)
    for _, name in ipairs(binary_names) do
        local selected = plan.modules[name]
        input(selected.file or selected.archive)
    end

    -- Reject graph-wide native-name collisions before any worker generates C.
    -- Fresh sources contribute only declaration-independent symbols; checked
    -- method/slot/private inventories still receive the final complete check.
    do
        local native_names, carried_types = {}, {}
        for name in pairs(modules) do native_names[name] = true end
        for _, name in ipairs(binary_names) do
            native_names[name] = true
            local imported = driver.imported[name]
            local provider = imported and imported.static_provider
            for carried, entry in pairs(provider and provider.entries or {}) do
                native_names[carried] = true
                carried_types[carried] = entry.type
            end
        end
        for name in pairs(context.native_constraints) do native_names[name] = true end
        local names = {}
        for name in pairs(native_names) do names[#names + 1] = name end
        table.sort(names, util.bytewise_less)
        local mangled_owners, symbol_owners, errors = {}, {}, {}
        for _, name in ipairs(names) do
            local mangled = driver.mangle_module_name(name)
            local previous = mangled_owners[mangled]
            if previous and previous ~= name then
                errors[#errors + 1] = "cannot link logical modules '" ..
                    previous .. "' and '" .. name ..
                    "': both use C symbol prefix '" .. mangled .. "'"
            else
                mangled_owners[mangled] = name
                local info, imported = modules[name], driver.imported[name]
                if imported == CIRCULAR_MARK then imported = nil end
                local symbols, private_symbols
                if info and info.saved then
                    local native = info.saved.object_metadata
                    symbols = native.external_symbols or
                        coder.interface_external_symbols(name, info.type)
                    private_symbols = native.private_symbols
                elseif info then
                    -- An empty public interface avoids inferring unchecked
                    -- type-dependent slots while using the coder's own names.
                    local declarations = { _type = types.Module(name, {}) }
                    for _, node in ipairs(info.nodes) do
                        if node._tag == "Ast.TopLevelFunc" or
                           node._tag == "Ast.TopLevelForeignFunc" then
                            declarations[#declarations + 1] = node
                        end
                    end
                    symbols = coder.external_symbols(name, declarations)
                elseif imported and imported.external_symbols then
                    symbols, private_symbols =
                        imported.external_symbols, imported.private_symbols
                else
                    local interface = imported and imported.type or
                        carried_types[name] or context.native_interface_types[name]
                    if interface then
                        -- Recovered ABI-2 interfaces do not promise optional
                        -- exports such as the native ABI-value query.
                        symbols = coder.interface_external_symbols(name, interface)
                    end
                end
                driver.record_module_symbols(symbol_owners, name, symbols, errors)
                driver.record_module_symbols(symbol_owners, name, private_symbols, errors)
            end
        end
        if #errors > 0 then return nil, table.concat(errors, "\n") end
    end

    -- Resolve just the transparent signature shapes needed for main selection,
    -- including local/imported aliases; the ordinary checker remains authority
    -- for all declaration validity and function bodies.
    local function shape(name, typ, seen)
        if not typ then return nil end
        seen = seen or {}
        if seen[typ] then return nil end
        seen[typ] = true
        local tag, info = typ._tag, modules[name]
        if tag == "Ast.TypeInteger" or tag == "Type.Integer" then return "integer"
        elseif tag == "Ast.TypeString" or tag == "Type.String" then return "string"
        elseif (tag == "Ast.TypeArray" or tag == "Type.Array") and typ.isconst.tag == "no" then
            if shape(name, typ.subtype or typ.elem, seen) == "string" then return "{string}" end
        elseif tag == "Ast.TypeName" and #(typ.typeargs or {}) == 0 then
            return shape(name, info and info.aliases[typ.name], seen)
        elseif tag == "Ast.TypeQualName" and #(typ.typeargs or {}) == 0 then
            local import = info and info.imports[typ.module]
            local dependency = typ.module == "M" and name or import and import.modname
            local target = dependency and modules[dependency]
            if target and not target.saved then
                return shape(dependency, target.aliases[typ.name], seen)
            end
            local selected = dependency and driver.imported[dependency]
            local modtype = target and target.type or selected and selected.type
            if modtype then
                return shape(dependency, types.module_type_member(modtype, typ.name,
                    import and import.source_required), seen)
            end
        end
    end
    local main
    for _, name in ipairs(options.roots) do
        local info = modules[name]
        if info and not info.saved then
            for _, node in ipairs(info.nodes) do
                if node._tag == "Ast.TopLevelFunc" and node.name == "main"
                   and #node.params == 1 and node.params[1].name ~= "..."
                   and not node.flexrettype and #node.rettypes == 1
                   and shape(name, node.params[1].type) == "{string}"
                   and shape(name, node.rettypes[1]) == "integer" then
                    info.has_main = true
                end
            end
        end
        if not options.test and info and info.has_main and not options.compile_only then
            if main then
                return nil, name .. ": multiple main functions found (already declared in " .. main .. ")"
            end
            main = name
        end
    end
    local builds_program = not options.compile_only and (options.test or main ~= nil)
    if options.exe and not builds_program then
        return nil, "--exe is only valid when compiling a standalone or test executable"
    elseif options.no_uv_bootstrap and not builds_program then
        return nil, "--no-uv-bootstrap is only valid when compiling a standalone executable"
    elseif options.coverage and not options.compile_only and not builds_program then
        return nil, "--coverage requires a test or standalone executable; use -c for coverage objects"
    end
    if builds_program then
        local root = options.test and options.roots[1] or main
        if context.target == "browser" then
            local stem = options.exe or modules[options.test and options.roots[1] or main].source.program_output or
                driver.generated_output_path((options.test and options.roots[1] or main):gsub("[.]", "/"), options.output_root)
            local image, wasm = driver.browser_program_path(stem, options.exe)
            if not image then return nil, wasm end
            output(image, "browser executable")
            output(wasm, "browser Wasm")
            output(wasm .. ".map", "browser source map")
        elseif platform.windows then
            local paths, err = driver.windows_program_paths(
                options.test and require("titan-compiler.test_runner").MODULE_NAME or main,
                options.exe, options.test and root or nil, options.output_root)
            if not paths then return nil, err end
            output(paths.executable, "standalone executable")
            output(paths.provider, "standalone provider")
        else
            local executable = options.exe or modules[root].source.program_output or root:gsub("[.]", "/")
            output(executable, "standalone executable")
            if driver.IS_DARWIN then output(executable .. ".dSYM", "standalone dSYM", "directory") end
        end
    elseif not options.compile_only then
        local provider, _, left, right = driver.common_module_provider(options.roots)
        if not provider then
            return nil, "cannot link modules into one shared library: '" ..
                tostring(left) .. "' and '" .. tostring(right) .. "' have no common module prefix"
        end
        local library, library_err =
            driver.provider_output_path(provider, options.output_root, context)
        if not library then return nil, library_err end
        local browser = context.target == "browser"
        if browser then
            local valid, err = driver.validate_provider_output_paths(library, nil, nil, context)
            if not valid then return nil, err end
        end
        output(library, browser and "provider archive" or "provider DSO")
        if not browser and not platform.windows then
            output((library:gsub("[.]so$", ".a")), "provider archive")
            if driver.IS_DARWIN then output(library .. ".dSYM", "provider dSYM", "directory") end
        end
    end

    local valid, validation_error, reservations =
        driver.validate_provider_output_paths(nil, inputs, outputs)
    if not valid then return nil, validation_error end

    -- Old generated translation units predate the explicit marker. Recognize
    -- their exact fixed helper or split-header prefix without parsing C.
    -- Coverage conversion anchored each old generated line with a `#line`
    -- directive. An old split unit names the absolute private header it was
    -- generated beside, so a moved output tree keeps the old directory; that
    -- name is owned only beside a marker-owned private header of its leaf.
    local fixed = require("titan-compiler.cpreamble").fixed_prefix
    local fixed_helper = assert(fixed:match("(static TITAN_UNUSED inline int.-\n})"))
        :gsub("%s+", "")
    local split_push = "#ifdefined(__ELF__)#pragmaGCCvisibilitypush(protected)#endif"
    local function generated_private_header(filename)
        local marker = driver.PRIVATE_HEADER_MARKER
        local attributes = context.io:lstat(filename)
        local contents = attributes and attributes.kind == "file" and
            context.io:read_file(filename, #marker)
        return contents and contents:sub(1, #marker) == marker or false
    end
    for _, reserved in ipairs(reservations) do
        local stem = c_outputs[reserved.path]
        if stem and reserved.existing_mode == "file" then
            local contents, read_error = context.io:read_file(reserved.path, 16384)
            if not contents then return nil, read_error end
            -- Coverage conversion places its exact first line directive
            -- before the marker; retain its physical generated-line anchors.
            local marker_start = contents:match('^#line 2 "[^\r\n]*"\r?\n()') or 1
            local owned = contents:sub(marker_start,
                marker_start + #driver.GENERATED_C_MARKER - 1) == driver.GENERATED_C_MARKER
            if not owned then
                local compact = ("\n" .. contents):gsub('\n#line %d+ "[^\r\n]*"', "")
                    :gsub("%s+", "")
                owned = compact:find(fixed_helper, 1, true) ~= nil
            end
            if not owned then
                local header, after = contents:match(
                    '^[ \t]*#[ \t]*include[ \t]*"([^"\r\n]*)"[ \t]*\r?\n()')
                local private_header = stem .. ".priv.h"
                owned = header ~= nil and
                    contents:sub(after):gsub("%s+", ""):sub(1, #split_push) == split_push and
                    (ffiheaders.quote_header(normalized_absolute_filename(private_header))
                        == '"' .. header .. '"' or
                     path.is_absolute(header) and
                     path.basename(header) == path.basename(private_header) and
                     generated_private_header(private_header))
            end
            if not owned then
                return nil, "native provider output '" .. reserved.normalized ..
                    "' for " .. reserved.owner .. " aliases input '" ..
                    reserved.normalized .. "' (not compiler-generated C; " ..
                    "move it or use another output directory)"
            end
        end
    end
    -- Stale-staging retirement protects the same accepted inputs.
    plan.reservations, plan.inputs = reservations, inputs
    return true
end

-- The library DSO path of one provider prefix, below output_root if given.
function driver.provider_output_path(provider, output_root, context)
    local extension = context and context.target == "browser" and
        ".a" or (platform.windows and ".dll" or ".so")
    local provider_path = safe_provider_output_path(provider, extension)
    if not provider_path then
        return nil, "invalid library provider name '" .. tostring(provider) .. "'"
    end
    if output_root then provider_path = path.join(output_root, provider_path) end
    return provider_path
end

-- The child validator must have exited before this function is called. Unlike
-- the Unix pair publisher, this path never opens either provider in this Lua
-- state.
-- Implementation notes: doc/implementation/windows-build.md#windows-dll-publication
-- The synchronous filesystem operations of a recoverable Windows publication.
local function windows_publication_fs()
    local filesystem = compiler_io.new_sync()
    return {
        stat = function(filename)
            local metadata, err = filesystem:lstat(filename)
            return metadata, err, metadata == nil and err == nil and 2 or nil
        end,
        reserve = function(filename) return filesystem:reserve_sibling(filename) end,
        replace = function(from, to) return filesystem:rename(from, to) end,
        remove = os.remove,
    }
end

function driver.publish_windows_provider(staged, destination, before_commit)
    return require("titan-compiler.windows_publication").publish({
        { source = staged, destination = destination },
    }, windows_publication_fs(), { before_commit = before_commit })
end

-- Publish one validated no-main bundle as a recoverable process-level
-- transaction. The dSYM and archive are committed before the DSO; the DSO
-- rename is the ordinary dynamic-path commit point. Tests may inject a caught
-- failure at a named boundary through options.fail_at.
-- Implementation notes: doc/implementation/static-compiled-modules.md#publication-and-installation
function driver.publish_provider_bundle(
        staged_dso, staged_archive, public_dso, options)
    options = options or {}
    if options.archive_only then
        local valid, err = driver.validate_provider_output_paths(
            public_dso, options.native_inputs, nil, options.context)
        if not valid then return nil, err end
        if lfs.symlinkattributes(staged_archive, "mode") ~= "file" then
            return nil, "staged provider artifact '" .. tostring(staged_archive) ..
                "' is not a regular file"
        end
        if absolute_filename(staged_archive) == absolute_filename(public_dso) or
           same_existing_file(staged_archive, public_dso) then
            return nil, "staged provider artifact '" .. staged_archive ..
                "' aliases destination/input '" .. public_dso .. "'"
        end
        if options.context and options.context.target == "browser" then
            local descriptor, descriptor_error = driver.context_target_descriptor(options.context)
            if not descriptor then return nil, descriptor_error end
            local parsed, parse_error = parsed_archive_input(staged_archive, descriptor.fingerprint)
            if not parsed then return nil, parse_error end
            valid, err = driver.validate_browser_provider(parsed.archive)
            if not valid then return nil, err end
            valid, err = driver.run_standalone_archive_probe(parsed.archive.entries,
                parsed.archive.key_order, {}, { staged_archive }, nil, options.verbose, nil,
                { context = options.context })
            if not valid then return nil, err end
        end
        if same_regular_archive_contents(staged_archive, public_dso) then
            remove_path(staged_archive)
            return true, public_dso
        end
        if options.before_commit then
            valid, err = options.before_commit()
            if not valid then return nil, err end
            valid, err = perf.check_browser_provider_companions(public_dso)
            if not valid then return nil, err end
        end
        valid, err = rename_output(staged_archive, public_dso)
        if not valid then return nil, err end
        return true, public_dso
    end
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

    local unchanged = same_file_contents(staged_dso, public_dso) and
        same_regular_archive_contents(staged_archive, public_archive)
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
        return true, public_archive
    end

    local backups = {}
    local installed = {}
    local backed_up = {}
    local function backup(public)
        if backed_up[public] then return true end
        backed_up[public] = true
        if not lfs.symlinkattributes(public, "mode") then return true end
        local old, reserve_err = driver.sibling_temporary_path(public .. ".old")
        if not old then return nil, reserve_err end
        local moved, move_err = rename_output(public, old)
        if not moved then
            if platform.windows then os.remove(old) end
            return nil, move_err
        end
        backups[#backups + 1] = { public = public, old = old }
        return true
    end
    local function install(staged, public)
        local backed, backup_err = backup(public)
        if not backed then return nil, backup_err end
        local moved, move_err = rename_output(staged, public)
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
            rename_output(item.old, item.public)
        end
        return nil, message
    end
    local ok, err = inject("before-dsym")
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
    return true, public_archive
end

local function standalone_archive_probe_source(entries, module_names, browser)
    local declarations = {}
    local checks = {}
    for index, modname in ipairs(module_names) do
        local entry = assert(entries[modname])
        local prefix = driver.mangle_module_name(modname)
        local abi_bytes = assert(staticmetadata.c_initializer(entry.abi))
        local types_bytes = assert(staticmetadata.c_initializer(entry.types))
        local layouts_bytes = assert(staticmetadata.c_initializer(entry.layouts))
        declarations[#declarations + 1] = string.format([[
extern int %s_abi(lua_State *L);
extern int %s_types(lua_State *L);
extern int %s_layouts(lua_State *L);
extern void *%s_init(lua_State *L);
extern int luaopen_%s(lua_State *L);
static void *(*volatile keep_init_%d)(lua_State *) = %s_init;
static int (*volatile keep_open_%d)(lua_State *) = luaopen_%s;
static const unsigned char expected_abi_%d[] = %s;
static const unsigned char expected_types_%d[] = %s;
static const unsigned char expected_layouts_%d[] = %s;
]], prefix, prefix, prefix, prefix, prefix, index, prefix, index, prefix,
            index, abi_bytes, index, types_bytes, index, layouts_bytes)
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
    lua_settop(L, 0);
    if (%s_layouts(L) != 1 || lua_type(L, -1) != LUA_TSTRING) return 25;
    value = lua_tolstring(L, -1, &length);
    if (length != %d || memcmp(value, expected_layouts_%d, length) != 0) return 26;
]], index, index, prefix, #entry.abi, index, prefix, #entry.types, index,
            prefix, #entry.layouts, index)
    end
    if browser then
        local worker = [[
static int titan_browser_protocol(lua_State *L) {
    const char *value;
    size_t length;
]] .. table.concat(checks, "\n") .. [[
    return 0;
}
static int titan_browser_worker(lua_State *L) {
    int status = titan_browser_protocol(L);
    lua_pushinteger(L, status);
    return 1;
}
]]
        return driver.browser_c_image_contents(worker, {
            declarations = table.concat(declarations, "\n"),
            program_name = "titan-provider-probe", state_status = 10,
        })
    end
    return [[
#include <stddef.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
]] .. table.concat(declarations, "\n") .. [[
int main(void) {
    lua_State *L = luaL_newstate();
    const char *value;
    size_t length;
    if (L == NULL) return 10;
]] .. table.concat(checks, "\n") .. [[
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
        link, verbose, extra_objects, options)
    options = options or {}
    if #module_names == 0 then return true end
    if options.context and options.context.target == "browser" then
        local context = options.context
        local assets, err = driver.require_browser_sdk(context)
        if not assets then return nil, err end
        local ready
        ready, err = driver.browser_node_ready(context, assets)
        if not ready then return nil, err end
        -- Measurement overrides belong to the published image, not this
        -- fixed-profile protocol check. Validate them before making a copy.
        local extra_flags = driver.link_extra_flags()
        local valid
        valid, err = driver.browserlink.validate_extras(extra_flags,
            driver.browser_link_options, context.target_descriptor.build_profile)
        if not valid then return nil, err end
        local protocol_flags = {}
        local trace_option = require("titan-compiler.browsertarget").trace_option
        for _, flag in ipairs(extra_flags) do
            if not trace_option(flag) then protocol_flags[#protocol_flags + 1] = flag end
        end
        local base
        base, err = create_compile_log()
        if not base then return nil, err end
        os.remove(base)
        local source, image = base .. ".c", base .. ".mjs"
        local cleanup <close> = setmetatable({}, { __close = function()
            os.remove(source); os.remove(base .. ".o")
            os.remove(image); os.remove(base .. ".wasm"); os.remove(base .. ".wasm.map")
        end })
        local linked, term, code = driver.compile_browser_image(
            standalone_archive_probe_source(entries, module_names, true),
            source, image, libnames, static_archives, extra_objects, verbose,
            { context = context, profile = { purpose = "protocol", assertions = 2 },
              link_extra_flags = protocol_flags })
        if not linked then
            return nil, "selected static provider failed executable-context protocol linking (" ..
                tostring(term) .. (code and (", exit " .. tostring(code)) or "") .. ")"
        end
        local result = context.io:run({ assets.runner, "--engine", "node", image },
            { stderr_to_stdout = true })
        if type(result) ~= "table" or not result.ok then
            return nil, "selected static provider failed executable-context protocol validation " ..
                "(browser runner exit " .. tostring(type(result) == "table" and result.status or 75) .. ")"
        end
        return true
    end
    local runtime_ok, runtime_err = perf.check_runtime(verbose)
    if not runtime_ok then return nil, runtime_err end
    local base, base_error = create_compile_log()
    if not base then return nil, base_error end
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
        source, standalone_archive_probe_source(entries, module_names))
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
    append_argv(args, libnames)
    local runtime = runtime_link_inputs()
    append_argv(args, driver.standalone_native_link_inputs(
        static_archives, extra_objects, runtime))
    if link then
        for _, lib in ipairs(util.split_string(link, ",")) do
            table.insert(args, "-l" .. lib)
        end
    end
    append_argv(args, driver.link_extra_flags())
    local linked, link_term, link_code = driver.run_link_command(args, verbose, executable)
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

local function compile_windows_program(modname, libnames, link, verbose,
        extra_objects, static_archives, entrypoint_name, program_name, options)
    local paths, err = driver.windows_program_paths(
        modname, options.exe, options.output_module, options.output_root)
    if not paths then return nil, err end
    local ok
    ok, err = ensure_output_parent(paths.executable)
    if not ok then return nil, err end
    ok, err = ensure_output_parent(entrypoint_name)
    if not ok then return nil, err end
    local module_names = options.module_names or { modname }
    if options.coverage_runtime then
        -- Windows puts instrumented modules in a companion DLL, which owns
        -- its profile runtime. The uninstrumented launcher calls this hook.
        local dump_c = entrypoint_name:gsub("[.]c$", "__coverage_dump.c")
        local dump_o = dump_c:gsub("[.]c$", ".o")
        ok, err = util.set_file_contents(dump_c, [[
#include "lua.h"
extern void __gcov_dump(void);
__declspec(dllexport) int _titan_coverage_dump(lua_State *L) {
    (void)L;
    __gcov_dump();
    return 0;
}
]])
        if not ok then return nil, err end
        local dump_args
        dump_args, err = driver.generated_compile_prefix()
        if not dump_args then return nil, err end
        append_argv(dump_args, { "-c", dump_c, "-o", dump_o })
        local compiled, term, code = run_argv(dump_args, verbose)
        if not compiled then return nil, term, code end
        extra_objects = { table.unpack(extra_objects or {}) }
        extra_objects[#extra_objects + 1] = dump_o
    end
    -- Both images are staged and published as one recoverable set, the DLL
    -- before the launcher; a failure before publication leaves the previous
    -- set untouched.
    local staged_dll, dll_directory = driver.staged_library_output(paths.provider)
    if not staged_dll then return nil, dll_directory end
    local staged_exe, exe_directory = driver.staged_library_output(paths.executable)
    if not staged_exe then
        local cleaned, cleanup_error = driver.cleanup_staging_directories({ dll_directory })
        if not cleaned then
            return nil, tostring(exe_directory) .. "\nstaging cleanup failed: " .. cleanup_error
        end
        return nil, exe_directory
    end
    local function discard(term, code)
        local cleaned, cleanup_error =
            driver.cleanup_staging_directories({ dll_directory, exe_directory })
        if not cleaned then
            return nil, tostring(term) .. "\nstaging cleanup failed: " .. cleanup_error, code
        end
        return nil, term, code
    end
    local linked, term, code = driver.compile_library_output(staged_dll,
        libnames, link, verbose, extra_objects, static_archives,
        nil, paths.provider, module_names)
    if not linked then return discard(term, code) end
    ok, err = driver.validate_library_image_fresh(staged_dll, nil, module_names, verbose)
    if not ok then return discard(err) end
    if options.archive_names and #options.archive_names > 0 then
        ok, err = driver.validate_library_image_fresh(staged_dll,
            assert(options.archive_entries), options.archive_names, verbose)
        if not ok then return discard(err) end
    end

    local entry_options = {
        pretty_print = options.pretty_print,
        no_uv_bootstrap = options.no_uv_bootstrap,
        provider = paths.relative_provider,
        coverage_runtime = options.coverage_runtime,
    }
    local entrypoint_c
    entrypoint_c, err = write_entrypoint(modname, entrypoint_name,
        program_name or options.output_module or modname, entry_options, verbose)
    if not entrypoint_c then return discard(err) end
    local entrypoint_o = entrypoint_c:gsub("[.]c$", ".o")
    local compile_args
    compile_args, err = driver.generated_compile_prefix()
    if not compile_args then return discard(err) end
    append_argv(compile_args, { "-c", entrypoint_c, "-o", entrypoint_o })
    local compiled, cterm, ccode = run_argv(compile_args, verbose)
    if not compiled then return discard(cterm, ccode) end

    local manifest, resource_source, resource = entrypoint_c .. ".manifest",
        entrypoint_c .. ".rc", entrypoint_c .. ".res"
    ok, err = util.set_file_contents(manifest, driver.windows_launcher_manifest())
    if not ok then return discard(err) end
    ok, err = util.set_file_contents(resource_source,
        driver.windows_launcher_resource(absolute_filename(manifest)))
    if not ok then return discard(err) end
    local rc
    rc, err = perf.tool_command(platform.getenv("RC") or "llvm-rc", "RC")
    if not rc then return discard(err) end
    append_argv(rc, { "-FO", resource, resource_source })
    compiled, cterm, ccode = run_argv(rc, verbose)
    if not compiled then return discard(cterm, ccode) end

    local args
    args, err = compiler_argv(false)
    if not args then return discard(err) end
    append_argv(args, { "-o", staged_exe, entrypoint_o, resource })
    append_runtime_libraries(args)
    append_argv(args, driver.link_extra_flags())
    local exe_linked, exe_term, exe_code =
        driver.run_link_command(args, verbose, staged_exe)
    if not exe_linked then return discard(exe_term, exe_code) end
    local published, publish_error =
        require("titan-compiler.windows_publication").publish_program({
            provider = { source = staged_dll, destination = paths.provider },
            executable = { source = staged_exe, destination = paths.executable },
        }, windows_publication_fs(), { before_commit = options.before_commit })
    local cleaned, cleanup_error =
        driver.cleanup_staging_directories({ dll_directory, exe_directory })
    if not published then
        return nil, tostring(publish_error) ..
            (not cleaned and ("\nstaging cleanup failed: " .. cleanup_error) or "")
    end
    if not cleaned then
        return nil, "Windows program publication committed but staging cleanup failed: " ..
            cleanup_error
    end
    return true
end

-- Publish the extended map and Wasm before the mjs commit rename. Every
-- predecessor survives a rename or certificate failure.
function driver.compile_browser_image(contents, entrypoint, executable,
        objects, archives, extra_objects, verbose, options)
    options = options or {}
    local context = assert(options.context)
    local assets, err = driver.require_browser_sdk(context)
    if not assets then return nil, err end
    local plan
    -- A `--test` image is a distinguishable link purpose: it keeps the frames
    -- its exact trace gate asserts, where a program accepts inlining (D25).
    local purpose
    purpose, err = driver.browser_link_purpose(context, options.purpose)
    if not purpose then return nil, err end
    if options.profile then
        local agreed
        agreed, err = driver.browser_link_purpose(context, options.profile.purpose)
        if not agreed then return nil, err end
        plan, err = driver.browserlink.profile(context.target_descriptor, options.profile)
    else
        plan, err = driver.browser_link_plan(context, purpose)
    end
    if not plan then return nil, err end
    local build_profile = context.target_descriptor.build_profile
    local extra_flags = options.link_extra_flags or driver.link_extra_flags()
    local valid
    valid, err = driver.browserlink.validate_extras(extra_flags,
        options.profile or driver.browser_link_options, build_profile)
    if not valid then return nil, err end
    valid, err = driver.browserlink.validate_extras(options.final_link_flags,
        options.profile or driver.browser_link_options, build_profile)
    if not valid then return nil, err end
    local library_flags = { table.unpack(extra_flags) }
    append_argv(library_flags, options.final_link_flags)
    local libraries
    libraries, err = require("titan-compiler.linkcertificate").browser_trace_libraries(
        context, context.target_descriptor.tools.cc, library_flags)
    -- emcc also understands system/JS libraries the static resolver cannot
    -- inventory. Keep their flags in the identity; the CLI withholds reuse.
    libraries = libraries or {}
    local runtime
    runtime, err = parsed_archive_input(assets.runtime, context.target_descriptor.fingerprint)
    if not runtime then return nil, err end
    valid, err = driver.validate_browser_provider(runtime.archive)
    if not valid then return nil, err end
    local wasm
    executable, wasm = driver.browser_program_path(executable, executable)
    if not executable then return nil, wasm end
    local inputs = { assets.runtime, context.target_descriptor.paths.liblua,
        context.target_descriptor.paths.lua_record, assets.js_library, assets.trace_library }
    append_argv(inputs, objects)
    append_argv(inputs, archives)
    append_argv(inputs, extra_objects)
    append_argv(inputs, libraries)
    valid, err = driver.validate_program_output_paths({}, executable, entrypoint,
        inputs, { wasm, wasm .. ".map" }, {}, context)
    if not valid then return nil, err end
    valid, err = ensure_output_parent(executable)
    if not valid then return nil, err end
    valid, err = ensure_output_parent(entrypoint)
    if not valid then return nil, err end
    local browsertrace = require "titan-compiler.browsertrace"
    local object = entrypoint:gsub("[.]c$", ".o")
    local compile
    compile, err = driver.generated_compile_prefix(context)
    if not compile then return nil, err end
    append_argv(compile, plan.compile_flags)
    local identity_flags
    identity_flags, err = compiler_argv(false, context)
    if not identity_flags then return nil, err end
    append_argv(identity_flags, plan.link_flags)
    append_argv(identity_flags, { "-Wl,--start-group", assets.runtime })
    append_argv(identity_flags, archives)
    append_argv(identity_flags, { context.target_descriptor.paths.liblua, "-Wl,--end-group" })
    append_argv(identity_flags, extra_flags)
    append_argv(identity_flags, options.final_link_flags)
    local called, identity = pcall(browsertrace.identity, context, contents, compile, identity_flags,
        { objects or {}, archives or {}, extra_objects or {}, libraries,
          { assets.runtime, context.target_descriptor.paths.liblua,
            context.target_descriptor.paths.lua_record, assets.js_library, assets.trace_library } })
    if not called then
        if type(identity) ~= "string" then error(identity, 0) end
        return nil, identity
    end
    valid, err = util.set_file_contents(entrypoint, contents .. browsertrace.declaration(identity))
    if not valid then return nil, err end
    append_argv(compile, { "-c", entrypoint, "-o", object })
    local compiled, term, code = run_argv(compile, verbose)
    if not compiled then return nil, term, code end
    local staged, directory = driver.staged_library_output(executable)
    if not staged then return nil, directory end
    local cleanup <close> = setmetatable({}, { __close = function() remove_path(directory) end })
    local staged_wasm = staged:gsub("[.]mjs$", ".wasm")
    local staged_map, map = staged_wasm .. ".map", wasm .. ".map"
    local command
    command, err = compiler_argv(false, context)
    if not command then return nil, err end
    append_argv(command, plan.link_flags)
    append_argv(command, { "-o", staged, object })
    append_argv(command, objects)
    append_argv(command, archives)
    append_argv(command, extra_objects)
    append_argv(command, { "-Wl,--start-group", assets.runtime })
    append_argv(command, archives)
    append_argv(command, { context.target_descriptor.paths.liblua, "-Wl,--end-group" })
    append_argv(command, extra_flags)
    append_argv(command, options.final_link_flags)
    local linked, term, code
    if options.dependency_output then
        if verbose then io.stderr:write(assert(command_argv(command)), "\n") end
        local result = context.io:run(command, { stderr_to_stdout = false })
        if not result.started then return nil, result.diagnostic end
        if not result.ok then return nil, result.why, result.status end
        linked, err = context.io:write_file(options.dependency_output, result.output or "")
        if not linked then return nil, err end
    else
        linked, term, code = driver.run_link_command(command, verbose, staged)
        if not linked then return nil, term, code end
    end
    for _, filename in ipairs({ staged, staged_wasm, staged_map }) do
        if lfs.symlinkattributes(filename, "mode") ~= "file" then
            return nil, "staged browser image '" .. filename .. "' is not a regular file"
        end
    end
    local image_bytes
    image_bytes, err = context.io:read_file(staged_wasm)
    if not image_bytes then return nil, err end
    local inventory
    inventory, err = driver.browserlink.image_inventory(image_bytes)
    if not inventory then return nil, err end
    local map_bytes
    map_bytes, err = context.io:read_file(staged_map)
    if not map_bytes then return nil, err end
    map_bytes, err = browsertrace.rewrite(image_bytes, map_bytes, identity, staged_map)
    if not map_bytes then return nil, err end
    valid, err = context.io:write_file(staged_map, map_bytes)
    if not valid then return nil, err end
    if options.before_commit then
        valid, err = options.before_commit()
        if not valid then return nil, err end
    end
    local outputs = {
        { source = staged_map, destination = map },
        { source = staged_wasm, destination = wasm },
        { source = staged, destination = executable },
    }
    local function rollback(reason)
        for index = #outputs, 1, -1 do
            local output = outputs[index]
            if output.published then remove_path(output.destination) end
            if output.backed then
                local restored, restore_error = rename_output(output.backup, output.destination)
                if not restored then
                    reason = tostring(reason) .. "\ncannot restore browser artifact: " ..
                        tostring(restore_error) .. "; predecessor retained at " .. output.backup
                end
            end
        end
        return nil, reason
    end
    -- Reserve and validate all backup locations before touching any predecessor.
    for _, output in ipairs(outputs) do
        local mode = lfs.symlinkattributes(output.destination, "mode")
        if mode then
            if mode ~= "file" then
                return nil, "browser output '" .. output.destination .. "' is not a regular file"
            end
            output.backup, err = driver.sibling_temporary_path(output.destination .. ".old")
            if not output.backup then return nil, err end
        end
    end
    for _, output in ipairs(outputs) do
        if output.backup then
            valid, err = rename_output(output.destination, output.backup)
            if not valid then return rollback(err) end
            output.backed = true
        end
        valid, err = rename_output(output.source, output.destination)
        if not valid then return rollback(err) end
        output.published = true
    end
    if options.after_publish then
        local called, committed, commit_error = pcall(options.after_publish)
        if not called then
            local _, rollback_error = rollback(committed)
            if type(committed) ~= "string" then error(committed, 0) end
            return nil, rollback_error
        end
        if not committed then return rollback(commit_error) end
    end
    for _, output in ipairs(outputs) do
        if output.backed then
            valid, err = remove_path(output.backup)
            if not valid then return nil, err end
        end
    end
    return true
end

function driver.browser_node_ready(context, assets)
    local result = context.io:run({ assets.runner, "--probe" }, { stderr_to_stdout = true })
    if type(result) == "table" and result.ok then return true, nil, result.output end
    local detail = type(result) == "table" and (result.output or result.diagnostic) or "runner probe failed"
    local reason = detail and detail:match("Node 24 is required %((.-)%)%s*$")
    if reason then
        return nil, "browser provider validation requires Node 24: " .. reason ..
            "; set TITAN_NODE to a Node 24 executable"
    end
    return nil, detail
end

function driver.compile_program(modname, libnames, link, verbose, extra_objects,
                                program_output, static_archives,
                                entrypoint_output, program_name, options)
    options = options or {}
    if options.context and options.context.target == "browser" then
        local executable = program_output or driver.generated_output_path(
            (options.output_module or modname):gsub("[.]", "/"), options.output_root) .. ".mjs"
        local entrypoint = entrypoint_output or driver.generated_output_path(
            modname:gsub("[.]", "/") .. "__entrypoint.c", options.output_root)
        return driver.compile_browser_image(
            driver.browser_entrypoint_contents(modname, program_name, options),
            entrypoint, executable, libnames, static_archives, extra_objects, verbose, options)
    end
    local runtime_ok, runtime_err = perf.check_runtime(verbose)
    if not runtime_ok then return nil, runtime_err end
    if platform.windows then
        return compile_windows_program(modname, libnames, link, verbose,
            extra_objects, static_archives, entrypoint_output or
                driver.generated_output_path(modname:gsub("[.]", "/") .. "__entrypoint.c", options.output_root),
            program_name, options)
    end
    local execname = program_output or
        driver.generated_output_path(modname:gsub("[.]", "/"), options.output_root)
    local output_ok, output_err = ensure_output_parent(execname)
    if not output_ok then return nil, output_err end
    local entrypoint_name = entrypoint_output or
        driver.generated_output_path(modname:gsub("[.]", "/") .. "__entrypoint.c", options.output_root)
    output_ok, output_err = ensure_output_parent(entrypoint_name)
    if not output_ok then return nil, output_err end
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
    local staged, stage_directory = driver.staged_library_output(execname)
    if not staged then return nil, stage_directory end
    local stage_cleanup <close> = setmetatable({}, {
        __close = function() remove_path(stage_directory) end,
    })
    append_argv(args, { "-o", staged, entrypoint_o })
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
    append_argv(args, driver.link_extra_flags())
    -- The final-link certificate's linker dependency report, final image only.
    append_argv(args, options.final_link_flags)
    local ok, term, code = driver.run_link_command(args, verbose, staged)
    if not ok then return nil, term, code end
    if lfs.symlinkattributes(staged, "mode") ~= "file" then
        return nil, "staged executable '" .. staged .. "' is not a regular file"
    end
    ok, term, code = run_dsymutil(staged, verbose, true, options.dsymutil)
    if not ok then return nil, term, code end
    local staged_dsym, public_dsym = staged .. ".dSYM", execname .. ".dSYM"
    if driver.IS_DARWIN and
       (lfs.symlinkattributes(staged_dsym, "mode") ~= "directory" or
        lfs.symlinkattributes(path.join(staged_dsym, "Contents", "Resources",
            "DWARF", path.basename(staged)), "mode") ~= "file") then
        return nil, "staged executable '" .. staged .. "' has no complete companion dSYM"
    end
    if options.before_commit then
        local ready, commit_error = options.before_commit()
        if not ready then return nil, commit_error end
    end

    -- The image rename is the commit point. Darwin's companion moves first;
    -- a caught publication failure restores its predecessor without touching
    -- the old executable. A failed rollback retains the only backup.
    local backup
    if driver.IS_DARWIN then
        local previous = lfs.symlinkattributes(public_dsym, "mode")
        if previous and previous ~= "directory" then
            return nil, "executable dSYM output '" .. public_dsym ..
                "' is not a nonlink directory"
        end
        if previous then
            local reserve_error
            backup, reserve_error = driver.sibling_temporary_path(public_dsym .. ".old")
            if not backup then return nil, reserve_error end
            local moved, move_error = rename_output(public_dsym, backup)
            if not moved then return nil, move_error end
        end
        local moved, move_error = rename_output(staged_dsym, public_dsym)
        if not moved then
            if backup then
                local restored, restore_error = rename_output(backup, public_dsym)
                if not restored then
                    return nil, tostring(move_error) .. "\ncannot restore dSYM: " ..
                        tostring(restore_error) .. "; predecessor retained at " .. backup
                end
            end
            return nil, move_error
        end
    end
    local published, publish_error = rename_output(staged, execname)
    if not published then
        if driver.IS_DARWIN then
            remove_path(public_dsym)
            if backup then
                local restored, restore_error = rename_output(backup, public_dsym)
                if not restored then
                    return nil, tostring(publish_error) .. "\ncannot restore dSYM: " ..
                        tostring(restore_error) .. "; predecessor retained at " .. backup
                end
            end
        end
        return nil, publish_error
    end
    if backup then
        local removed, remove_error = remove_path(backup)
        if not removed then return nil, remove_error end
    end
    return true
end

return driver
