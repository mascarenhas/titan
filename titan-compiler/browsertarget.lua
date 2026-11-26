local compiler_paths = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local browserlink = require "titan-compiler.browserlink"
local cdriver = require "c-parser.cdriver"
local graphcodec = require "titan-compiler.graphcodec"
local csemantics = require "titan-compiler.csemantics"
local incremental = require "titan-compiler.incremental"
local staticmetadata = require "titan-compiler.staticmetadata"
local sha256 = require "titan-compiler.sha256"
local version = require "titan-compiler.version"
local util = require "titan-compiler.util"
local M = {}

M.WASI_SDK_VERSION = "34.0"
M.BINARYEN_VERSION = "133"
local FEATURES = "+bulk-memory +bulk-memory-opt +call-indirect-overlong +exception-handling " ..
    "+multivalue +mutable-globals +nontrapping-fptoint +reference-types +sign-ext"
local TRIPLE = "wasm32-wasip1"
-- wasi-sdk's setjmp/longjmp lowering: Wasm exception handling in the standard
-- (exnref) encoding, which LLVM does not select by default.
local SJLJ = "wasm-exnref"
local SJLJ_FLAGS = { "-mexception-handling", "-mllvm", "-wasm-enable-sjlj",
    "-mllvm", "-wasm-use-legacy-eh=false" }
local FINGERPRINT = { format = "wasm", word_size = 32, linking_version = 2, features = FEATURES }
local ANALYSIS_LIMIT = 64 * 1024
M.SDK_HEADERS = { "minicoro.h", "titan.h", "transfer.h", "titan/ffi.h", "titan/browser.h" }
local BANNER = "# Lua 5.5.1 browser build record v2\n"
local RECORD_KEYS = { "fork_revision", "archive_sha256", "headers_sha256",
    "wasi_sdk_version", "target", "wasm_features", "sjlj", "lua_defines", "numeric", "cflags" }
local TARGET_DEFINES = {
    "-DTITAN_TARGET_BROWSER=1",
    "-DTITAN_COROUTINE_STACK_SIZE=262144",
}
-- One object profile per build profile (D26). `production` optimizes as native
-- production does and accepts the frames inlining costs, keeping the object
-- line tables the trace contract needs. `validation` freezes #330's exact
-- physical-frame profile. The production level is one named constant, chosen
-- by measurement (D34; the numbers are in the implementation manual's
-- measurements section).
local PRODUCTION_LEVEL = "-O3"
local PROFILES = {
    validation = { level = "-O1", frames = { "-fno-inline", "-fno-optimize-sibling-calls" } },
    production = { level = PRODUCTION_LEVEL, frames = {} },
}
local proxy_data = setmetatable({}, { __mode = "k" })

function M.valid_profile(build_profile)
    return PROFILES[build_profile] ~= nil
end

-- The owned object compile flags of one build profile. Every consumer compiles
-- from the descriptor, so this list is the single source of the object profile.
-- The DWARF v4 line tables are the trace's only source (browsertrace.dwarf_map).
function M.object_flags(build_profile)
    local profile = PROFILES[build_profile]
    if not profile then return nil end
    local flags = { "--std=c99", profile.level }
    for _, flag in ipairs(profile.frames) do flags[#flags + 1] = flag end
    flags[#flags + 1] = "-Wall"
    flags[#flags + 1] = "-Wno-unused-but-set-variable"
    flags[#flags + 1] = "-Wno-unused-function"
    flags[#flags + 1] = "-gdwarf-4"
    flags[#flags + 1] = "-gline-tables-only"
    for _, flag in ipairs(SJLJ_FLAGS) do flags[#flags + 1] = flag end
    flags[#flags + 1] = "-D_WASI_EMULATED_PROCESS_CLOCKS"
    return flags
end

-- All browser compiler execution goes through this argv policy, including
-- probes, links and coordinator jobs: the frozen clang, the target and the
-- SDK's sysroot, whatever its configuration file says. The `env` launch
-- wrapper empties the variables clang would otherwise read to edit its own
-- command line (and so the setjmp/longjmp ABI), add include or library
-- directories, or find another linker (D11).
local AMBIENT = { "CCC_OVERRIDE_OPTIONS=", "CPATH=", "C_INCLUDE_PATH=", "CPLUS_INCLUDE_PATH=",
    "OBJC_INCLUDE_PATH=", "LIBRARY_PATH=", "COMPILER_PATH=" }
function M.compiler_argv(tools)
    local argv = { "env", table.unpack(AMBIENT) }
    argv[#argv + 1] = tools.cc[1]
    argv[#argv + 1] = "--target=" .. TRIPLE
    argv[#argv + 1] = "--sysroot=" .. tools.sysroot
    return argv
end

local function hex(value, length)
    return type(value) == "string" and #value == length and not value:find("[^0-9a-f]")
end

local function copy(value, seen)
    if type(value) ~= "table" then
        if type(value) ~= "string" and type(value) ~= "boolean" and type(value) ~= "number" then
            error("browser descriptor contains non-data value", 0)
        end
        return value
    end
    local source = proxy_data[value] or value
    if source == value and getmetatable(value) ~= nil then
        error("browser descriptor data must be plain tables", 0)
    end
    seen = seen or {}
    if seen[source] then error("browser descriptor data contains a cycle", 0) end
    seen[source] = true
    local out = {}
    for key, item in pairs(source) do
        if type(key) ~= "string" and math.type(key) ~= "integer" then
            error("browser descriptor contains invalid key", 0)
        end
        out[key] = copy(item, seen)
    end
    seen[source] = nil
    return out
end

local function freeze(data)
    local backing = {}
    for key, value in pairs(data) do
        backing[key] = type(value) == "table" and freeze(value) or value
    end
    local proxy = setmetatable({}, {
        __index = backing, __len = function() return #backing end,
        __pairs = function() return next, backing, nil end,
        __newindex = function() error("browser target descriptor is immutable", 2) end,
        __metatable = false,
    })
    proxy_data[proxy] = backing
    return proxy
end

local function fields(data, keys, optional)
    if type(data) ~= "table" or getmetatable(data) ~= nil then return false end
    local allowed = {}
    for _, key in ipairs(keys) do
        allowed[key] = true
        if data[key] == nil then return false end
    end
    for _, key in ipairs(optional or {}) do allowed[key] = true end
    for key in pairs(data) do if not allowed[key] then return false end end
    return true
end

local function valid_fingerprint(data)
    if not fields(data, { "format", "word_size", "linking_version", "features" }) then return false end
    for key, expected in pairs(FINGERPRINT) do
        if data[key] ~= expected then return false end
    end
    return true
end

local function text(value)
    return type(value) == "string" and not value:find("[%z\r\n]")
end

local function canonical_words(value)
    local words, err = cdriver.split_shell_words(value)
    if not words then return nil, err end
    if table.concat(words, " ") ~= value then return nil, "noncanonical list" end
    return words
end

local function lua_defines(value)
    if not text(value) or not utf8.len(value) then return nil, "text encoding" end
    local defines, err = canonical_words(value)
    if not defines then return nil, err end
    local previous, browser
    for _, flag in ipairs(defines) do
        local name = flag:match("^%-D([A-Za-z_][A-Za-z0-9_]*)$") or
            flag:match("^%-D([A-Za-z_][A-Za-z0-9_]*)=[^%s]+$")
        if not name or previous and not util.bytewise_less(previous, flag) then
            return nil, "expected sorted unique -D tokens"
        end
        if name == "LUA_USE_POSIX" or name == "LUA_USE_DLOPEN" or name == "LUA_USE_LINUX" or
                name == "LUA_USE_MACOSX" then
            return nil, name .. " is unavailable for browser Lua"
        end
        if name == "LUA_USE_BROWSER" then browser = true end
        previous = flag
    end
    if not browser then return nil, "requires LUA_USE_BROWSER" end
    return defines
end

local function lua_numeric(profile)
    return "integer=" .. profile.lua_integer .. ",float=" .. profile.lua_number
end

-- These are physical C ABI traits of the pinned wasm32-wasip1 target,
-- not defaults from the analysis host. Lua's typedefs are separately
-- configurable and compared to the validated browser Lua record.
local function validate_browser_profile(profile, numeric)
    if numeric ~= lua_numeric(profile) then return nil, "inconsistent browser numeric profile" end
    local error_message = "C profile does not describe the browser's wasm32 target"
    if profile.char_bit ~= 8 or not profile.char_signed or
        profile.size_t ~= "unsigned long" or profile.ptrdiff_t ~= "long" then
        return nil, error_message
    end
    for _, pair in ipairs({
        { "_Bool", 8 }, { "char", 8 }, { "signed char", 8 }, { "unsigned char", 8 },
        { "short", 16 }, { "unsigned short", 16 }, { "int", 32 }, { "unsigned int", 32 },
        { "long", 32 }, { "unsigned long", 32 }, { "long long", 64 }, { "unsigned long long", 64 },
        { "__int128", 128 }, { "unsigned __int128", 128 },
    }) do
        local entry = profile.integers[pair[1]]
        local bits = pair[2]
        local precision = entry and (pair[1] == "_Bool" and 1 or bits - (entry.type.signed and 1 or 0))
        if not entry or entry.type.bits ~= bits or entry.precision ~= precision then
            return nil, error_message
        end
    end
    for _, traits in ipairs({ { "float", 32, 24, 128 }, { "double", 64, 53, 1024 },
            { "long double", 128, 113, 16384 } }) do
        local entry = profile.floats[traits[1]]
        if entry.radix ~= 2 or entry.bits ~= traits[2] or
            entry.mantissa_digits ~= traits[3] or entry.maximum_exponent ~= traits[4] then
            return nil, error_message
        end
    end
    return true
end

local function argv(value)
    if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
    for index = 1, #value do if not text(value[index]) then return false end end
    for key in pairs(value) do
        if math.type(key) ~= "integer" or key < 1 or key > #value then return false end
    end
    return true
end

local function normalized_absolute(value)
    if not text(value) or not platform.is_absolute(value) then return false end
    if platform.windows then return platform.path.normalize(value) == value end
    return compiler_paths.normalize(value) == value
end

local function tool_path(directory, name)
    if platform.windows then return platform.join(directory, name .. ".exe") end
    return compiler_paths.join(directory, name)
end

local function sdk_path(root, ...)
    for _, name in ipairs({ ... }) do root = platform.join(root, name) end
    return root
end

local validate_record

-- Everything after a profile's owned compile prefix is refused when it is
-- owned, except one trailing level flag in a trace-control measurement build.
-- The admitted set is `-O0`…`-O3` and `-Os`, not only the `optimization`
-- override's `-O1`/`-O2`: a harness may also pass its measurement level through
-- `--cflag`, which `browserlink.validate_extras` admits for the `baseline`,
-- `minicoro` and `budget` purposes.
local function check_owned_tail(flags, first, trace_control, build_profile)
    local override
    for index = first, #flags do
        local owned = M.trace_option(flags[index]) and flags[index]
        if owned then
            if trace_control and override == nil and owned:match("^%-O[0-3s]$") then
                override = owned
            else
                return nil, "browser " .. build_profile ..
                    " profile owns compile option " .. string.format("%q", owned)
            end
        end
    end
    return true
end

local function descriptor_identity(data, context)
    return "browser:sha256:" .. incremental.digest(context or {}, "browser-target", data)
end

local function validate(data, context)
    if not fields(data, { "label", "triple", "memory_bits", "tools", "build_profile", "compile_flags",
            "include_dirs", "target_defines", "paths", "lua", "profile_data", "profile_identity",
            "fingerprint", "output_policy", "provider_policy", "identity" },
            { "probe_cache_directory", "trace_control" }) or
        data.label ~= "browser" or data.triple ~= TRIPLE or data.memory_bits ~= 32 or
        not M.valid_profile(data.build_profile) or not argv(data.compile_flags) or
        not argv(data.include_dirs) or not argv(data.target_defines) then
        return nil, "invalid browser target descriptor"
    end
    local tools = data.tools
    if not fields(tools, { "cc", "ar", "ranlib", "ld", "sysroot", "version", "source", "location",
            "version_output", "optimizer" }) or
        tools.version ~= M.WASI_SDK_VERSION or (tools.source ~= "WASI_SDK_PATH" and tools.source ~= "PATH") or
        not normalized_absolute(tools.location) or type(tools.version_output) ~= "string" or
        tools.sysroot ~= sdk_path(tools.location, "share", "wasi-sysroot") then
        return nil, "invalid browser toolchain descriptor"
    end
    for _, item in ipairs({ { "cc", "clang" }, { "ar", "llvm-ar" }, { "ranlib", "llvm-ranlib" },
            { "ld", "wasm-ld" } }) do
        local command = tools[item[1]]
        if not argv(command) or #command ~= 1 or not normalized_absolute(command[1]) or
            command[1] ~= tool_path(sdk_path(tools.location, "bin"), item[2]) then
            return nil, "invalid browser tool argv"
        end
    end
    local optimizer = tools.optimizer
    if not fields(optimizer, { "argv", "version", "source", "version_output" }) or
        optimizer.version ~= M.BINARYEN_VERSION or not argv(optimizer.argv) or #optimizer.argv ~= 1 or
        not normalized_absolute(optimizer.argv[1]) or type(optimizer.version_output) ~= "string" or
        (optimizer.source ~= "WASM_OPT" and optimizer.source ~= "BINARYEN_ROOT" and optimizer.source ~= "PATH") then
        return nil, "invalid browser optimizer descriptor"
    end
    if not fields(data.paths, { "root", "lua_source", "include", "lib", "libtitan", "liblua",
            "lua_record", "titan_bin", "sdk_digests" }) then return nil, "invalid browser paths" end
    for _, value in pairs(data.paths) do
        if not normalized_absolute(value) then return nil, "invalid browser path" end
    end
    if not fields(data.lua, { "path", "record", "record_sha256" }) or
        data.lua.path ~= data.paths.lua_record or not hex(data.lua.record_sha256, 64) or
        not fields(data.lua.record, RECORD_KEYS) then return nil, "invalid browser Lua descriptor" end
    local record, defines = validate_record(data.lua.record, data.paths)
    if not record then return nil, defines end
    if #data.target_defines ~= #TARGET_DEFINES then
        return nil, "inconsistent browser target defines"
    end
    for index, expected_define in ipairs(TARGET_DEFINES) do
        if data.target_defines[index] ~= expected_define then
            return nil, "inconsistent browser target defines"
        end
    end
    if data.trace_control ~= nil and type(data.trace_control) ~= "boolean" then
        return nil, "invalid browser target descriptor"
    end
    -- Every consumer of the descriptor compiles, certifies and probes from
    -- these flags, so they must be exactly one object profile (D26). A
    -- trace-control measurement build (baseline, minicoro, budget) may add one
    -- trailing level flag, the only owned option it may override.
    local owned_flags = M.object_flags(data.build_profile)
    for index, flag in ipairs(owned_flags) do
        if data.compile_flags[index] ~= flag then
            return nil, "browser " .. data.build_profile ..
                " profile compile flags do not match its object profile"
        end
    end
    local supported, flag_error = M.validate_flags({ table.unpack(data.compile_flags, #owned_flags + 1) },
        "compile_flags")
    if not supported then return nil, flag_error end
    local tail, tail_error = check_owned_tail(data.compile_flags,
        #owned_flags + 1, data.trace_control == true, data.build_profile)
    if not tail then return nil, tail_error end
    local seen = {}
    for _, flag in ipairs(data.compile_flags) do seen[flag] = true end
    local required = { "--std=c99", table.unpack(TARGET_DEFINES) }
    for _, flag in ipairs(defines) do required[#required + 1] = flag end
    for _, flag in ipairs(required) do
        if not seen[flag] then
            return nil, "browser target descriptor is missing required compile flag " .. string.format("%q", flag)
        end
    end
    if #data.include_dirs < 2 or data.include_dirs[1] ~= data.paths.lua_source or
        data.include_dirs[2] == data.paths.lua_source then
        return nil, "browser include roots must put verified Lua first and Titan runtime second"
    end
    for _, directory in ipairs(data.include_dirs) do
        if not normalized_absolute(directory) then return nil, "invalid browser include path" end
    end
    if not valid_fingerprint(data.fingerprint) then
        return nil, "invalid browser Wasm fingerprint"
    end
    if not fields(data.output_policy, { "requires_output", "marker", "marker_contents" }) or
        data.output_policy.requires_output ~= true or data.output_policy.marker ~= ".titan-target" or
        data.output_policy.marker_contents ~= "browser\n" or
        not fields(data.provider_policy, { "archive_only", "sdk_first", "dynamic" }) or
        data.provider_policy.archive_only ~= true or data.provider_policy.sdk_first ~= true or
        data.provider_policy.dynamic ~= false then return nil, "invalid browser target policy" end
    if data.probe_cache_directory ~= nil and not normalized_absolute(data.probe_cache_directory) then
        return nil, "invalid browser probe cache path"
    end
    local profile, err = csemantics.import_profile(data.profile_data)
    if not profile then return nil, err end
    if data.profile_identity ~= profile.identity then return nil, "invalid browser profile identity" end
    if data.lua.record.numeric ~= lua_numeric(profile) then
        return nil, "inconsistent browser numeric profile"
    end
    local identity = data.identity
    data.identity = nil
    local expected = descriptor_identity(data, context)
    data.identity = identity
    if identity ~= expected then return nil, "invalid browser target identity" end
    return true
end

function M.export(descriptor)
    return copy(descriptor)
end

function M.import(data)
    local ok, result, err = pcall(function()
        local plain = copy(data)
        local valid, failure = validate(plain)
        if not valid then return nil, failure end
        return freeze(plain)
    end)
    if not ok then
        if type(result) ~= "string" then error(result, 0) end
        return nil, result
    end
    return result, err
end

local function analysis_codec_options(context)
    return {
        max_bytes = ANALYSIS_LIMIT, max_string_bytes = ANALYSIS_LIMIT,
        max_nodes = 128, max_entries = 1024,
        canonical_string_keys = true,
        sha256_binary = context and context.cache_adapter and context.cache_adapter.sha256_binary,
    }
end

-- Only semantic facts from the validated build descriptor belong here. The
-- asset hashes bind the publication across moves, unlike the build manifest's
-- path/stat observations.
function M.encode_analysis(context, descriptor, provider_sha256, absent_sha256)
    local data = proxy_data[descriptor]
    assert(data and data.tools, "browser build descriptor required")
    assert(hex(provider_sha256, 64) and hex(absent_sha256, 64), "browser asset digests required")
    local profile_data = copy(data.profile_data)
    local profile, err = csemantics.import_profile(profile_data)
    if not profile then return nil, err end
    local valid
    valid, err = validate_browser_profile(profile, data.lua.record.numeric)
    if not valid then return nil, err end
    return M.encode_analysis_data(context, {
        target = data.label, triple = data.triple, fingerprint = copy(data.fingerprint),
        abi = version.TITAN_ABI_VERSION, release = version.TITAN_VERSION,
        wasi_sdk_version = data.tools.version, build_profile = data.build_profile,
        profile_data = profile_data,
        lua = {
            fork_revision = data.lua.record.fork_revision,
            headers_sha256 = data.lua.record.headers_sha256,
            defines = data.lua.record.lua_defines,
            numeric = data.lua.record.numeric,
        },
        provider_sha256 = provider_sha256, absent_sha256 = absent_sha256,
    })
end

-- Companion tools that rebind a decoded descriptor to a real subset archive
-- use the same bounded deterministic encoding as the SDK publisher.
function M.encode_analysis_data(context, data)
    return graphcodec.encode(data, analysis_codec_options(context))
end

function M.decode_analysis(context, bytes)
    local data, err = graphcodec.decode(bytes, analysis_codec_options(context))
    if not data then return nil, err end
    if not fields(data, { "target", "triple", "fingerprint", "abi", "release",
        "wasi_sdk_version", "build_profile", "profile_data", "lua",
        "provider_sha256", "absent_sha256" }) or data.target ~= "browser" or
        data.triple ~= TRIPLE or data.abi ~= version.TITAN_ABI_VERSION or
        version.library_series(data.release) ~= version.TITAN_LIBRARY_VERSION or
        data.wasi_sdk_version ~= M.WASI_SDK_VERSION or
        not M.valid_profile(data.build_profile) then
        return nil, "incompatible browser semantic target"
    end
    if not valid_fingerprint(data.fingerprint) then return nil, "invalid browser Wasm fingerprint" end
    if not fields(data.lua, { "fork_revision", "headers_sha256", "defines", "numeric" }) or
        not hex(data.lua.fork_revision, 40) or not hex(data.lua.headers_sha256, 64) then
        return nil, "invalid browser Lua facts"
    end
    local defines, define_error = lua_defines(data.lua.defines)
    if not defines then return nil, "invalid browser Lua defines: " .. define_error end
    if not hex(data.provider_sha256, 64) or not hex(data.absent_sha256, 64) then
        return nil, "invalid browser semantic asset digests"
    end
    local profile
    profile, err = csemantics.import_profile(data.profile_data)
    if not profile then return nil, err end
    local browser_profile, profile_error = validate_browser_profile(profile, data.lua.numeric)
    if not browser_profile then return nil, profile_error end
    return data
end

-- The target owns its triple, sysroot, execution model, exception handling
-- and LLVM code-generation options; a trailing user option would change the
-- setjmp/longjmp lowering or the ABI every archive shares. `-mllvm` and
-- `-Xclang` reach the backend directly, and a configuration or response
-- file could carry either.
local UNSUPPORTED = { ["-fPIC"] = true, ["-fpic"] = true, ["-fPIE"] = true,
    ["-fpie"] = true, ["-pie"] = true, ["-shared"] = true, ["-dynamiclib"] = true,
    ["-rdynamic"] = true, ["-pthread"] = true, ["-ffat-lto-objects"] = true,
    ["-m32"] = true, ["-m64"] = true, ["-fwasm-exceptions"] = true,
    ["-fno-wasm-exceptions"] = true, ["-mexception-handling"] = true,
    ["-mno-exception-handling"] = true, ["-mlegacy-exception-handling"] = true,
    ["-mno-legacy-exception-handling"] = true, ["-mllvm"] = true, ["-target"] = true }

-- Optimization, inlining, sibling-call, frame-pointer and debug choices belong
-- to the build profile; internal descriptors contain them and trailing user
-- options may not override them.
function M.trace_option(flag)
    local positive = flag:gsub("^%-fno%-", "-f")
    return flag:match("^%-O") or flag:match("^%-g") or
        positive:match("^%-finline") or positive:match("^%-foptimize%-sibling%-calls") or
        positive:match("^%-fomit%-frame%-pointer")
end

function M.validate_flags(flags, origin)
    if flags ~= nil and not argv(flags) then
        return nil, "invalid browser " .. origin .. " flags: expected a dense array of strings"
    end
    for _, flag in ipairs(flags or {}) do
        if UNSUPPORTED[flag] or flag == "-flto" or flag:match("^%-flto=") or
            flag:match("^%-march=") or flag:match("^%-mcpu=") or flag:match("^%-mtune=") or
            flag:match("^%-mllvm=") or flag:match("^%-Xclang") or flag:match("^%-%-target=") or
            flag:match("^%-%-sysroot") or flag:match("^%-mexec%-model") or flag:match("^%-%-config") or
            flag:sub(1, 1) == "@" then
            return nil, "browser target does not support " .. origin .. " flag " .. string.format("%q", flag)
        end
    end
    return true
end

local function absolute(strategy, filename)
    if platform.windows then
        local cwd, err
        if not platform.is_absolute(filename) then
            cwd, err = strategy:cwd()
            if not cwd then return nil, err end
        end
        local resolved
        resolved, err = platform.absolute(filename, cwd, strategy)
        if not resolved then return nil, err end
        return platform.path.normalize(resolved)
    end
    if platform.is_absolute(filename) then return compiler_paths.to_slash(compiler_paths.normalize(filename)) end
    local cwd, err = strategy:cwd()
    if not cwd then return nil, err end
    return compiler_paths.to_slash(compiler_paths.normalize(compiler_paths.join(cwd, filename)))
end

local function include_root(strategy, directory)
    if platform.windows then return absolute(strategy, directory) end
    if not platform.is_absolute(directory) then
        local cwd, err = strategy:cwd()
        if not cwd then return nil, err end
        -- Unlike lexical path.join, this preserves symlink/.. traversal.
        directory = cwd .. "/" .. directory
    end
    if ("/" .. directory .. "/"):find("/../", 1, true) then
        -- Match driver.normalize_root: resolve existing POSIX roots before
        -- normalization, retain its absent-root fallback, and surface errors.
        local resolved, resolve_error = strategy:realpath(directory)
        if resolved then return compiler_paths.to_slash(compiler_paths.normalize(resolved)) end
        local info, stat_error = strategy:stat(directory)
        if stat_error then return nil, stat_error end
        if info then return nil, resolve_error end
    end
    return compiler_paths.to_slash(compiler_paths.normalize(directory))
end

local function tool_candidate(context, filename)
    local strategy = context.io
    local info, stat_error = strategy:stat(filename)
    if platform.windows then
        -- An absent exact .exe may continue a PATH walk; an exact candidate
        -- with a resolution error stops it. A resolved name still has to
        -- launch at its execution boundary. Never accept libuv's appended
        -- extension fallback.
        if stat_error then return nil, stat_error end
        if not info then return false end
        local ok, identity, selected = pcall(incremental.physical_executable, context, filename)
        if not ok then
            if type(identity) ~= "string" then error(identity, 0) end
            return nil, identity
        end
        if not identity then return nil, selected end
        if selected ~= filename then
            return nil, "physical resolver selected " .. string.format("%q", selected)
        end
        return true
    end
    return info and info.kind == "file" and type(strategy.executable) == "function" and
        strategy:executable(filename) == true
end

local SDK = "wasi-sdk " .. M.WASI_SDK_VERSION
local SDK_INSTALL = "; install wasi-sdk " .. M.WASI_SDK_VERSION ..
    " (https://github.com/WebAssembly/wasi-sdk/releases/tag/wasi-sdk-34) and set WASI_SDK_PATH to its root"
local OPTIMIZER = "Binaryen version_" .. M.BINARYEN_VERSION .. " wasm-opt"
local OPTIMIZER_INSTALL = "; install Binaryen version_" .. M.BINARYEN_VERSION ..
    " (https://github.com/WebAssembly/binaryen/releases/tag/version_133) and set BINARYEN_ROOT to its root" ..
    " or WASM_OPT to its wasm-opt"
local function resolution_error(requirement, filename, reason, install)
    return "browser target requires " .. requirement .. ": cannot resolve " ..
        string.format("%q", filename) .. ": " .. reason .. install
end

local function parent(filename)
    return platform.windows and platform.parent(filename) or compiler_paths.dirname(filename)
end

-- The first executable `name` on PATH whose directory `accept` takes; false
-- when there is none.
local function search_path(context, name, requirement, install, accept)
    local search = platform.getenv("PATH") or ""
    local directories = platform.windows and platform.windows_path_entries(search, true) or
        (search .. ":"):gmatch("(.-):")
    while true do
        local directory, err = directories()
        if err then return nil, resolution_error(requirement, "PATH", err, install) end
        if not directory then return false end
        local root
        root, err = absolute(context.io, directory == "" and "." or directory)
        if not root then return nil, resolution_error(requirement, directory, err, install) end
        local candidate = tool_path(root, name)
        local present, reason = tool_candidate(context, candidate)
        if reason then return nil, resolution_error(requirement, candidate, reason, install) end
        if present and accept(root) then return candidate end
    end
end

-- The tool at an explicitly configured location.
local function configured_tool(context, filename, variable, value, requirement, install)
    local present, reason = tool_candidate(context, filename)
    if reason then return nil, resolution_error(requirement, filename, reason, install) end
    if not present then
        return nil, "browser target requires " .. requirement .. ": " .. string.format("%q", filename) ..
            " is not an executable (" .. variable .. "=" .. string.format("%q", value) .. ")" .. install
    end
    return filename
end

-- `executable` names the physical tool when `command` runs it through a wrapper.
local function version_output(context, command, executable, requirement, install)
    command[#command + 1] = "--version"
    local result = context.io:run(command, { stderr_to_stdout = true })
    if type(result) ~= "table" or not result.ok then
        local detail = type(result) == "table" and (result.output or result.diagnostic) or tostring(result)
        return nil, "browser target requires " .. requirement .. ": cannot execute " ..
            string.format("%q", executable) .. ": " .. tostring(detail):gsub("%s+$", "") .. install
    end
    return result.output
end

-- wasi-sdk from WASI_SDK_PATH, else the first clang on PATH that sits in a
-- wasi-sdk `bin` directory (one with a sibling `../VERSION`). The SDK's
-- VERSION file names its release; clang reports only its LLVM version.
local function discover_compiler(context)
    local strategy = context.io
    local configured, root, cc, err = platform.getenv("WASI_SDK_PATH")
    if configured and configured ~= "" then
        root, err = absolute(strategy, configured)
        if not root then return nil, resolution_error(SDK, configured, err, SDK_INSTALL) end
        cc, err = configured_tool(context, tool_path(sdk_path(root, "bin"), "clang"),
            "WASI_SDK_PATH", configured, SDK, SDK_INSTALL)
        if not cc then return nil, err end
    else
        cc, err = search_path(context, "clang", SDK, SDK_INSTALL, function(directory)
            local info = strategy:stat(sdk_path(parent(directory), "VERSION"))
            return info and info.kind == "file"
        end)
        if cc == nil then return nil, err end
        if not cc then
            return nil, "browser target requires " .. SDK .. ": no wasi-sdk clang on PATH " ..
                "(WASI_SDK_PATH unset; a wasi-sdk clang has a sibling ../VERSION)" .. SDK_INSTALL
        end
        root = parent(parent(cc))
    end
    local version_file = sdk_path(root, "VERSION")
    local recorded = strategy:read_file(version_file, 64)
    local found = recorded and recorded:match("^([^\r\n]*)") or "unknown"
    if found ~= M.WASI_SDK_VERSION then
        return nil, "browser target requires " .. SDK .. ": " .. string.format("%q", version_file) ..
            " reports " .. found .. SDK_INSTALL
    end
    local tools = { cc = { cc }, sysroot = sdk_path(root, "share", "wasi-sysroot"), version = found,
        source = configured and configured ~= "" and "WASI_SDK_PATH" or "PATH", location = root }
    local info = strategy:stat(tools.sysroot)
    if not (info and info.kind == "directory") then
        return nil, "browser target requires " .. SDK .. ": no sysroot at " ..
            string.format("%q", tools.sysroot) .. SDK_INSTALL
    end
    tools.version_output, err = version_output(context, M.compiler_argv(tools), cc, SDK, SDK_INSTALL)
    if not tools.version_output then return nil, err end
    return tools
end

-- wasm-opt from WASM_OPT, else BINARYEN_ROOT, else PATH.
local function discover_optimizer(context)
    local filename, source, err
    for _, variable in ipairs({ "WASM_OPT", "BINARYEN_ROOT" }) do
        local value = platform.getenv(variable)
        if value and value ~= "" then
            local resolved
            resolved, err = absolute(context.io, value)
            if not resolved then return nil, resolution_error(OPTIMIZER, value, err, OPTIMIZER_INSTALL) end
            if variable == "BINARYEN_ROOT" then resolved = tool_path(sdk_path(resolved, "bin"), "wasm-opt") end
            filename, err = configured_tool(context, resolved, variable, value, OPTIMIZER, OPTIMIZER_INSTALL)
            if not filename then return nil, err end
            source = variable
            break
        end
    end
    if not filename then
        filename, err = search_path(context, "wasm-opt", OPTIMIZER, OPTIMIZER_INSTALL, function() return true end)
        if filename == nil then return nil, err end
        if not filename then
            return nil, "browser target requires " .. OPTIMIZER .. ": wasm-opt not found " ..
                "(WASM_OPT and BINARYEN_ROOT unset; not on PATH)" .. OPTIMIZER_INSTALL
        end
        source = "PATH"
    end
    local output
    output, err = version_output(context, { filename }, filename, OPTIMIZER, OPTIMIZER_INSTALL)
    if not output then return nil, err end
    local found = output:match("^wasm%-opt version (%d+)") or "unknown"
    if found ~= M.BINARYEN_VERSION then
        return nil, "browser target requires " .. OPTIMIZER .. ": " .. string.format("%q", filename) ..
            " reports version " .. found .. OPTIMIZER_INSTALL
    end
    return { argv = { filename }, version = found, source = source, version_output = output }
end

function M.discover_tools(context)
    local tools, err = discover_compiler(context)
    if not tools then return nil, err end
    -- clang drives the SDK's own wasm-ld; the descriptor names it so link
    -- certificates and image identities cover its bytes.
    for _, item in ipairs({ { "ar", "llvm-ar" }, { "ranlib", "llvm-ranlib" }, { "ld", "wasm-ld" } }) do
        local filename = tool_path(sdk_path(tools.location, "bin"), item[2])
        local present, reason = tool_candidate(context, filename)
        if reason then return nil, resolution_error(SDK, filename, reason, SDK_INSTALL) end
        if not present then
            return nil, "browser target requires " .. SDK .. ": " .. item[2] .. " not found at " ..
                string.format("%q", filename) .. SDK_INSTALL
        end
        tools[item[1]] = { filename }
    end
    tools.optimizer, err = discover_optimizer(context)
    if not tools.optimizer then return nil, err end
    return tools
end

local function record_error(paths, kind, detail)
    return "browser Lua record " .. string.format("%q", paths.lua_record) .. " " .. kind ..
        ": " .. detail .. "; install it with '" .. browserlink.install_command("lua", paths.root) .. "'"
end

local function mismatch(paths, record, key, expected, recorded)
    return record_error(paths, "field " .. key .. " mismatch",
        "recorded " .. string.format("%q", recorded or record[key] or "<missing>") ..
        ", expected " .. string.format("%q", expected) .. " (fork_revision=" .. record.fork_revision .. ")")
end

local function record_list(record, paths, key)
    local words, err = canonical_words(record[key])
    if not words then
        return nil, record_error(paths, "is malformed", "invalid field " .. string.format("%q", key) .. ": " .. err)
    end
    return words
end

validate_record = function(record, paths)
    for _, key in ipairs(RECORD_KEYS) do
        local value = record[key]
        local detail
        if value == nil then detail = "missing field " .. string.format("%q", key)
        elseif not text(value) or not utf8.len(value) then
            detail = "invalid field " .. string.format("%q", key) .. ": text encoding"
        elseif value == "" then detail = "invalid field " .. string.format("%q", key) .. ": empty value" end
        if detail then return nil, record_error(paths, "is malformed", detail) end
    end
    for _, item in ipairs({ { "fork_revision", 40 }, { "archive_sha256", 64 }, { "headers_sha256", 64 } }) do
        if not hex(record[item[1]], item[2]) then
            return nil, record_error(paths, "is malformed", "invalid field " .. string.format("%q", item[1]) .. ": invalid hexadecimal value")
        end
    end
    for _, item in ipairs({ { "sjlj", SJLJ }, { "target", TRIPLE },
            { "wasi_sdk_version", M.WASI_SDK_VERSION } }) do
        if record[item[1]] ~= item[2] then return nil, mismatch(paths, record, item[1], item[2]) end
    end
    local features, feature_error = record_list(record, paths, "wasm_features")
    if not features then return nil, feature_error end
    if record.wasm_features ~= FEATURES then return nil, mismatch(paths, record, "wasm_features", FEATURES) end
    local defines, define_error = lua_defines(record.lua_defines)
    if not defines then
        return nil, record_error(paths, "is malformed", "invalid field \"lua_defines\": " .. define_error)
    end
    local flags, flags_error = record_list(record, paths, "cflags")
    if not flags then return nil, flags_error end
    -- The record's target and setjmp/longjmp lowering are the ones its cflags
    -- select; every other cflag obeys the user-flag policy.
    local flag_defines, seen, others, llvm, exceptions, target = {}, {}, {}, {}, false, nil
    local index = 1
    while index <= #flags do
        local flag = flags[index]
        if flag == "-mllvm" then
            index = index + 1
            llvm[#llvm + 1] = flags[index] or "<missing>"
        elseif flag == "-mexception-handling" then
            exceptions = true
        elseif flag:match("^%-%-target=") then
            target = flag:sub(#"--target=" + 1)
        else
            if flag:sub(1, 2) == "-D" and not seen[flag] then
                flag_defines[#flag_defines + 1] = flag
                seen[flag] = true
            end
            others[#others + 1] = flag
        end
        index = index + 1
    end
    table.sort(flag_defines, util.bytewise_less)
    if table.concat(flag_defines, " ") ~= record.lua_defines then
        return nil, mismatch(paths, record, "lua_defines", table.concat(flag_defines, " "))
    end
    table.sort(llvm, util.bytewise_less)
    local sjlj = exceptions and table.concat(llvm, " ") == "-wasm-enable-sjlj -wasm-use-legacy-eh=false" and
        SJLJ or nil
    if sjlj ~= record.sjlj then
        return nil, mismatch(paths, record, "sjlj", sjlj or "<missing in cflags>")
    end
    if target ~= record.target then
        return nil, mismatch(paths, record, "target", target or "<missing in cflags>")
    end
    local supported, unsupported = M.validate_flags(others, "cflags")
    if not supported then return nil, record_error(paths, "is malformed", "invalid field \"cflags\": " .. unsupported) end
    return record, defines
end

local function parse_record(bytes, paths)
    if bytes:sub(1, #BANNER) ~= BANNER or bytes:find("[%z\r]") or
        not utf8.len(bytes) or bytes:sub(-1) ~= "\n" then
        return nil, record_error(paths, "is malformed", "invalid banner or text encoding")
    end
    local allowed, record = {}, {}
    for _, key in ipairs(RECORD_KEYS) do allowed[key] = true end
    for line in bytes:sub(#BANNER + 1):gmatch("([^\n]*)\n") do
        local key, value = line:match("^([a-z][a-z0-9_]*)=(.*)$")
        local detail
        if not key then detail = "invalid key=value line"
        elseif not allowed[key] then detail = "unknown field " .. string.format("%q", key)
        elseif record[key] ~= nil then detail = "duplicate field " .. string.format("%q", key) end
        if detail then return nil, record_error(paths, "is malformed", detail) end
        record[key] = value
    end
    return validate_record(record, paths)
end

local function header_digest(context, directory)
    local names, err = context.io:list(directory)
    if not names then return nil, err end
    local headers = {}
    for _, name in ipairs(names) do if name:match("^[^/\\]+[.]h$") then headers[#headers + 1] = name end end
    table.sort(headers, util.bytewise_less)
    if #headers == 0 then return nil, "no installed Lua headers" end
    local lines = {}
    for _, name in ipairs(headers) do
        lines[#lines + 1] = name .. " " .. incremental.file_digest(context,
            compiler_paths.join(directory, name)) .. "\n"
    end
    return sha256.hex_via(context.cache_adapter and context.cache_adapter.sha256_binary, table.concat(lines))
end

local function probe_fingerprint(context, descriptor)
    local reservation, err = context.io:tmpname()
    if not reservation then return nil, err end
    -- The explicit `-x c` compiles the reservation as C whatever its suffix.
    local source, object = reservation, reservation .. ".o"
    local cleanup <close> = setmetatable({}, { __close = function()
        context.io:unlink(source)
        context.io:unlink(object)
    end })
    local written, write_error = context.io:write_file(source, "int titan_browser_target_probe(void) { return 0; }\n")
    if not written then return nil, write_error end
    local command = { table.unpack(descriptor.compiler_argv) }
    for _, flag in ipairs(descriptor.compile_flags) do command[#command + 1] = flag end
    command[#command + 1] = "-x"; command[#command + 1] = "c"
    command[#command + 1] = "-c"; command[#command + 1] = source
    command[#command + 1] = "-o"; command[#command + 1] = object
    local result = context.io:run(command, { stderr_to_stdout = true })
    if type(result) ~= "table" or not result.ok then
        return nil, type(result) == "table" and (result.diagnostic or result.output) or "browser object probe failed"
    end
    local bytes, read_error = context.io:read_file(object)
    if not bytes then return nil, read_error end
    local parsed, parse_error = staticmetadata.classify_object(bytes, object)
    return parsed and parsed.fingerprint, parse_error
end

-- Common compile and profile inputs, shared by the full SDK build and the
-- smaller C-only capability of a browser analysis context.
local function compiler_configuration(context, tool, build_profile, defines, lua_source, runtime_include, extras)
    local flags = M.object_flags(build_profile)
    for _, define in ipairs(defines) do flags[#flags + 1] = define end
    for _, define in ipairs(TARGET_DEFINES) do flags[#flags + 1] = define end
    for _, flag in ipairs(extras or {}) do flags[#flags + 1] = flag end
    local includes, include_error =
        cdriver.resolve_compiler_include_dirs(context.extra_ffi_include_dirs or {}, context.io)
    if not includes then return nil, "invalid extra_ffi_include_dirs: " .. include_error end
    table.insert(includes, 1, runtime_include)
    table.insert(includes, 1, lua_source)
    for index, directory in ipairs(includes) do
        if not text(directory) or directory == "" then return nil, "invalid browser include path" end
        local resolved, resolve_error = include_root(context.io, directory)
        if not resolved then return nil, resolve_error end
        includes[index] = resolved
    end
    local compiler = M.compiler_argv(tool)
    local inputs, err = cdriver.target_profile_inputs({ io = context.io,
        cache_adapter = context.cache_adapter, compiler = compiler, language_flag = false,
        compiler_include_dirs = includes, compile_flags = flags, language_mode = "c99" })
    if not inputs then return nil, err end
    local profile
    profile, err = csemantics.build_profile(inputs)
    if not profile then return nil, err end
    return { io = context.io, compiler_argv = compiler, stage_tools = { tool.cc[1] },
        compile_flags = flags, language_mode = "c99", language_flag = false,
        cppflags = {}, cflags = {}, include_dirs = includes,
        profile = profile, profile_identity = profile.identity }
end

function M.analysis_toolchain(context, semantic, packaged_lua_source, flags)
    local data, paths = semantic.target, semantic.paths
    flags = flags or {}
    local valid, err = M.validate_flags(flags, "browser foreign C flags")
    if not valid then return nil, err end
    valid, err = check_owned_tail(flags, 1, false, data.build_profile)
    if not valid then return nil, err end
    local tool
    tool, err = discover_compiler(context)
    if not tool then return nil, err end
    local lua_source = paths.lua_source
    local installed, stat_error = context.io:lstat(lua_source)
    if stat_error then return nil, stat_error end
    if not installed then lua_source = packaged_lua_source end
    local headers, header_error = header_digest(context, lua_source)
    if headers ~= data.lua.headers_sha256 then
        return nil, lua_source .. ": matching SDK Lua headers are required" ..
            (header_error and (": " .. header_error) or " (digest disagrees with analysis-target)")
    end
    local titan_headers = {}
    for _, relative in ipairs(M.SDK_HEADERS) do
        local filename = compiler_paths.join(paths.include, relative)
        local info, stat_error = context.io:stat(filename)
        if stat_error ~= nil and type(stat_error) ~= "string" then error(stat_error, 0) end
        if not info or info.kind ~= "file" or info.size == 0 then
            return nil, filename .. ": matching Titan SDK header is required" ..
                (stat_error and (": " .. stat_error) or "")
        end
        titan_headers[relative] = incremental.file_digest(context, filename)
    end
    local defines = assert(cdriver.split_shell_words(data.lua.defines))
    local config
    config, err = compiler_configuration(context, tool, data.build_profile,
        defines, lua_source, paths.include, flags)
    if not config then return nil, err end
    if config.profile_identity ~= data.profile_data.identity then
        return nil, "live C profile disagrees with analysis-target"
    end
    local fingerprint
    fingerprint, err = probe_fingerprint(context, config)
    if not fingerprint then return nil, err end
    local matches
    matches, err = staticmetadata.fingerprint_matches(fingerprint, data.fingerprint)
    if not matches then return nil, "live Wasm fingerprint disagrees with analysis-target: " .. err end
    config.target_identity = "browser-foreign:sha256:" .. incremental.digest(context, "browser-foreign-tool", {
        semantic = semantic.identity, executable = tool.cc[1], version = tool.version_output,
        executable_digest = incremental.file_digest(context, tool.cc[1]),
        titan_headers = titan_headers,
    })
    return config
end

function M.build(context, inputs)
    local ok, descriptor, failure = pcall(function()
        local build_profile = inputs.build_profile
        if not M.valid_profile(build_profile) then
            return nil, "invalid browser build profile " ..
                string.format("%q", tostring(build_profile))
        end
        local valid, flag_error = M.validate_flags(inputs.compile_flags, "compile_flags")
        if not valid then return nil, flag_error end
        -- The same owned-tail rule the descriptor validator applies, checked
        -- here before any tool discovery or probe.
        local tail, tail_error = check_owned_tail(inputs.compile_flags or {}, 1,
            inputs.trace_control == true, build_profile)
        if not tail then return nil, tail_error end
        local paths = inputs.paths
        local remedy_paths = { root = inputs.install_prefix or paths.root, lua_record = paths.lua_record }
        local tool, tool_error = M.discover_tools(context)
        if not tool then return nil, tool_error end
        local bytes, read_error = context.io:read_file(paths.lua_record)
        if not bytes then return nil, record_error(remedy_paths, "is unavailable", tostring(read_error)) end
        local record, defines = parse_record(bytes, remedy_paths)
        if not record then return nil, defines end
        local archive_ok, archive = pcall(incremental.file_digest, context, paths.liblua)
        if not archive_ok then
            if type(archive) ~= "string" then error(archive, 0) end
            return nil, mismatch(remedy_paths, record, "archive_sha256", "unavailable: " .. archive)
        elseif archive ~= record.archive_sha256 then return nil, mismatch(remedy_paths, record, "archive_sha256", archive) end
        local header_ok, headers, header_error = pcall(header_digest, context, paths.lua_source)
        if not header_ok and type(headers) ~= "string" then error(headers, 0) end
        if not header_ok or not headers then
            return nil, mismatch(remedy_paths, record, "headers_sha256", "unavailable: " .. tostring(header_error or headers))
        elseif headers ~= record.headers_sha256 then return nil, mismatch(remedy_paths, record, "headers_sha256", headers) end
        local config, profile_error = compiler_configuration(context, tool, build_profile,
            defines, paths.lua_source, inputs.runtime_include or paths.include, inputs.compile_flags)
        if not config then return nil, profile_error end
        local profile = config.profile
        local numeric = lua_numeric(profile)
        if numeric ~= record.numeric then return nil, mismatch(remedy_paths, record, "numeric", numeric) end
        local fingerprint, fingerprint_error = probe_fingerprint(context, config)
        if not fingerprint then return nil, fingerprint_error end
        local matches, mismatch_error = staticmetadata.fingerprint_matches(fingerprint, FINGERPRINT)
        if not matches then
            local diagnostic = "browser target compiler probe does not match the required Wasm target: " ..
                tostring(mismatch_error)
            if inputs.compile_flags and #inputs.compile_flags > 0 then
                local extras = {}
                for _, flag in ipairs(inputs.compile_flags) do
                    extras[#extras + 1] = string.format("%q", flag)
                end
                diagnostic = diagnostic .. "; user compile flags: " .. table.concat(extras, " ") ..
                    "; remove feature-changing flags from TITAN_EXTRA_CPPFLAGS/TITAN_EXTRA_CFLAGS/--cflag"
            else
                diagnostic = diagnostic .. "; check the selected " .. SDK .. " installation"
            end
            return nil, diagnostic
        end
        local data = { label = "browser", triple = TRIPLE, memory_bits = 32,
            tools = tool, build_profile = build_profile, compile_flags = config.compile_flags,
            trace_control = inputs.trace_control == true,
            include_dirs = config.include_dirs, target_defines = { table.unpack(TARGET_DEFINES) },
            paths = paths, lua = { path = paths.lua_record, record = record,
                record_sha256 = sha256.hex_via(context.cache_adapter and context.cache_adapter.sha256_binary, bytes) },
            profile_data = assert(csemantics.export_profile(profile)), profile_identity = profile.identity,
            fingerprint = FINGERPRINT, probe_cache_directory = inputs.probe_cache_directory,
            output_policy = { requires_output = true, marker = ".titan-target", marker_contents = "browser\n" },
            provider_policy = { archive_only = true, sdk_first = true, dynamic = false } }
        data.identity = descriptor_identity(data, context)
        local validated, validation_error = validate(data, context)
        if not validated then return nil, validation_error end
        return freeze(data)
    end)
    if not ok then
        if type(descriptor) ~= "string" then error(descriptor, 0) end
        return nil, descriptor
    end
    return descriptor, failure
end

return M
