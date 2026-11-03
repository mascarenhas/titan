local compiler_paths = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local cdriver = require "c-parser.cdriver"
local csemantics = require "titan-compiler.csemantics"
local incremental = require "titan-compiler.incremental"
local staticmetadata = require "titan-compiler.staticmetadata"
local sha256 = require "titan-compiler.sha256"
local util = require "titan-compiler.util"
local M = {}

M.EMSCRIPTEN_VERSION = "6.0.13"
local FEATURES = "+bulk-memory +bulk-memory-opt +call-indirect-overlong +multivalue " ..
    "+mutable-globals +nontrapping-fptoint +reference-types +sign-ext"
local BANNER = "# Lua 5.5.1 browser build record v1\n"
local RECORD_KEYS = { "fork_revision", "archive_sha256", "headers_sha256",
    "emscripten_version", "target", "wasm_features", "sjlj", "lua_defines", "numeric", "cflags" }
local TARGET_DEFINES = {
    "-DTITAN_TARGET_BROWSER=1",
    "-DTITAN_COROUTINE_STACK_SIZE=262144",
    "-DMCO_ASYNCFY_STACK_SIZE=65536",
}
local proxy_data = setmetatable({}, { __mode = "k" })

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

local function text(value)
    return type(value) == "string" and not value:find("[%z\r\n]")
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
    return text(value) and platform.is_absolute(value) and
        compiler_paths.to_slash(compiler_paths.normalize(value)) == compiler_paths.to_slash(value)
end

local function longjmp_mode(flags, index)
    local flag = flags[index]
    if flag == "-sSUPPORT_LONGJMP" or
        flag == "-s" and flags[index + 1] == "SUPPORT_LONGJMP" then return "emscripten" end
    local mode = flag:match("^%-sSUPPORT_LONGJMP=(.*)$") or
        flag == "-s" and (flags[index + 1] or ""):match("^SUPPORT_LONGJMP=(.*)$")
    return mode == "1" and "emscripten" or mode
end

local validate_record

local function descriptor_identity(data, context)
    return "browser:sha256:" .. incremental.digest(context or {}, "browser-target", data)
end

local function validate(data, context)
    if not fields(data, { "label", "triple", "memory_bits", "tools", "compile_flags",
            "include_dirs", "target_defines", "paths", "lua", "profile_data", "profile_identity",
            "fingerprint", "output_policy", "provider_policy", "identity" }, { "probe_cache_directory" }) or
        data.label ~= "browser" or data.triple ~= "wasm32-unknown-emscripten" or data.memory_bits ~= 32 or
        not argv(data.compile_flags) or not argv(data.include_dirs) or not argv(data.target_defines) then
        return nil, "invalid browser target descriptor"
    end
    local tools = data.tools
    if not fields(tools, { "cc", "ar", "ranlib", "version", "source", "location", "version_output" }) or
        tools.version ~= M.EMSCRIPTEN_VERSION or (tools.source ~= "EMSDK" and tools.source ~= "PATH") or
        not normalized_absolute(tools.location) or type(tools.version_output) ~= "string" then
        return nil, "invalid browser toolchain descriptor"
    end
    for _, item in ipairs({ { "cc", "emcc" }, { "ar", "emar" }, { "ranlib", "emranlib" } }) do
        local command = tools[item[1]]
        if not argv(command) or #command ~= 1 or not normalized_absolute(command[1]) or
            compiler_paths.to_slash(command[1]) ~=
                compiler_paths.to_slash(compiler_paths.join(tools.location, item[2])) then
            return nil, "invalid browser tool argv"
        end
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
    local supported, flag_error = M.validate_flags(data.compile_flags, "compile_flags")
    if not supported then return nil, flag_error end
    local seen, longjmp = {}, false
    for index, flag in ipairs(data.compile_flags) do
        seen[flag] = true
        if longjmp_mode(data.compile_flags, index) == "emscripten" then longjmp = true end
    end
    local required = { "--std=c99", table.unpack(TARGET_DEFINES) }
    for _, flag in ipairs(defines) do required[#required + 1] = flag end
    for _, flag in ipairs(required) do
        if not seen[flag] then
            return nil, "browser target descriptor is missing required compile flag " .. string.format("%q", flag)
        end
    end
    if not longjmp then return nil, "browser target descriptor is missing required SUPPORT_LONGJMP setting" end
    if #data.include_dirs < 2 or data.include_dirs[1] ~= data.paths.lua_source or
        data.include_dirs[2] == data.paths.lua_source then
        return nil, "browser include roots must put verified Lua first and Titan runtime second"
    end
    for _, directory in ipairs(data.include_dirs) do
        if not normalized_absolute(directory) then return nil, "invalid browser include path" end
    end
    if not fields(data.fingerprint, { "format", "word_size", "linking_version", "features" }) or
        data.fingerprint.format ~= "wasm" or data.fingerprint.word_size ~= 32 or
        data.fingerprint.linking_version ~= 2 or data.fingerprint.features ~= FEATURES then
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
    if data.lua.record.numeric ~= "integer=" .. profile.lua_integer .. ",float=" .. profile.lua_number then
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

local UNSUPPORTED = { ["-fPIC"] = true, ["-fpic"] = true, ["-fPIE"] = true,
    ["-fpie"] = true, ["-pie"] = true, ["-shared"] = true, ["-dynamiclib"] = true,
    ["-rdynamic"] = true, ["-pthread"] = true, ["-ffat-lto-objects"] = true,
    ["-m32"] = true, ["-m64"] = true, ["-fwasm-exceptions"] = true }

-- These choices preserve physical trace frames in every supported installation.
-- Internal descriptors contain them; trailing user options may not override them.
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
    for index, flag in ipairs(flags or {}) do
        local longjmp = longjmp_mode(flags, index)
        if UNSUPPORTED[flag] or flag == "-flto" or flag:match("^%-flto=") or
            flag:match("^%-march=") or flag:match("^%-mcpu=") or flag:match("^%-mtune=") or
            longjmp and longjmp ~= "emscripten" then
            local rejected = longjmp and flag == "-s" and flag .. " " .. flags[index + 1] or flag
            return nil, "browser target does not support " .. origin .. " flag " .. string.format("%q", rejected)
        end
    end
    return true
end

local function absolute(strategy, filename)
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

local function executable(strategy, filename)
    local info = strategy:stat(filename)
    return info and info.kind == "file" and type(strategy.executable) == "function" and
        strategy:executable(filename) == true
end

local INSTALL = "; install it with 'emsdk install 6.0.13 && emsdk activate 6.0.13' and source emsdk_env.sh"
local function tools(context)
    local strategy = context.io
    local emsdk, cc = platform.getenv("EMSDK")
    if emsdk and emsdk ~= "" then
        cc = assert(absolute(strategy, compiler_paths.join(emsdk, "upstream/emscripten/emcc")))
        if not executable(strategy, cc) then
            return nil, "browser target requires Emscripten 6.0.13: emcc not found at " ..
                string.format("%q", cc) .. " (EMSDK=" .. string.format("%q", emsdk) .. ")" .. INSTALL
        end
    else
        local separator = platform.windows and ";" or ":"
        for directory in ((platform.getenv("PATH") or "") .. separator):gmatch("(.-)" .. separator) do
            local candidate, err = absolute(strategy,
                compiler_paths.join(directory == "" and "." or directory, "emcc"))
            if not candidate then return nil, err end
            if executable(strategy, candidate) then cc = candidate; break end
        end
        if not cc then
            return nil, "browser target requires Emscripten 6.0.13: emcc not found (EMSDK unset; not on PATH)" .. INSTALL
        end
    end
    local result = strategy:run({ cc, "--version" }, { stderr_to_stdout = true })
    local found = type(result) == "table" and type(result.output) == "string" and
        result.output:match("emcc[^\n]- (%d+%.%d+%.%d+)") or "unknown"
    if type(result) ~= "table" or not result.ok or found ~= M.EMSCRIPTEN_VERSION then
        return nil, "browser target requires Emscripten 6.0.13: " .. string.format("%q", cc) ..
            " reports " .. found .. INSTALL
    end
    local location = compiler_paths.dirname(cc)
    local out = { cc = { cc }, version = found, source = emsdk and emsdk ~= "" and "EMSDK" or "PATH",
        location = location, version_output = result.output }
    for key, name in pairs({ ar = "emar", ranlib = "emranlib" }) do
        local filename = compiler_paths.join(location, name)
        if not executable(strategy, filename) then
            return nil, "browser target requires Emscripten 6.0.13: " .. name .. " not found at " ..
                string.format("%q", filename) .. " (emcc=" .. string.format("%q", cc) .. ")" .. INSTALL
        end
        out[key] = { filename }
    end
    return out
end

local function record_error(paths, kind, detail)
    return "browser Lua record " .. string.format("%q", paths.lua_record) .. " " .. kind ..
        ": " .. detail .. "; install it with 'make install-browser PREFIX=" .. paths.root .. "'"
end

local function mismatch(paths, record, key, expected, recorded)
    return record_error(paths, "field " .. key .. " mismatch",
        "recorded " .. string.format("%q", recorded or record[key] or "<missing>") ..
        ", expected " .. string.format("%q", expected) .. " (fork_revision=" .. record.fork_revision .. ")")
end

local function record_list(record, paths, key)
    local words, err = cdriver.split_shell_words(record[key])
    if not words then
        return nil, record_error(paths, "is malformed", "invalid field " .. string.format("%q", key) .. ": " .. err)
    end
    if table.concat(words, " ") ~= record[key] then
        return nil, record_error(paths, "is malformed", "invalid field " .. string.format("%q", key) .. ": noncanonical list")
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
    for _, item in ipairs({ { "sjlj", "emscripten" }, { "target", "wasm32-unknown-emscripten" },
            { "emscripten_version", M.EMSCRIPTEN_VERSION } }) do
        if record[item[1]] ~= item[2] then return nil, mismatch(paths, record, item[1], item[2]) end
    end
    local features, feature_error = record_list(record, paths, "wasm_features")
    if not features then return nil, feature_error end
    if record.wasm_features ~= FEATURES then return nil, mismatch(paths, record, "wasm_features", FEATURES) end
    local defines, split_error = record_list(record, paths, "lua_defines")
    if not defines then return nil, split_error end
    local previous
    for _, flag in ipairs(defines) do
        if not flag:match("^%-D[A-Za-z_][A-Za-z0-9_]*") or previous and not util.bytewise_less(previous, flag) then
            return nil, record_error(paths, "is malformed", "invalid field \"lua_defines\": expected sorted unique -D tokens")
        end
        previous = flag
    end
    local flags, flags_error = record_list(record, paths, "cflags")
    if not flags then return nil, flags_error end
    local flag_defines, seen, longjmp = {}, {}, nil
    for index, flag in ipairs(flags) do
        if flag:sub(1, 2) == "-D" and not seen[flag] then
            flag_defines[#flag_defines + 1] = flag
            seen[flag] = true
        end
        local mode = longjmp_mode(flags, index)
        if mode then longjmp = mode end
    end
    table.sort(flag_defines, util.bytewise_less)
    if table.concat(flag_defines, " ") ~= record.lua_defines then
        return nil, mismatch(paths, record, "lua_defines", table.concat(flag_defines, " "))
    end
    if longjmp ~= record.sjlj then
        return nil, mismatch(paths, record, "sjlj", longjmp or "<missing in cflags>")
    end
    local supported, unsupported = M.validate_flags(flags, "cflags")
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

local function header_digest(context, paths)
    local names, err = context.io:list(paths.lua_source)
    if not names then return nil, err end
    local headers = {}
    for _, name in ipairs(names) do if name:match("^[^/\\]+[.]h$") then headers[#headers + 1] = name end end
    table.sort(headers, util.bytewise_less)
    if #headers == 0 then return nil, "no installed Lua headers" end
    local lines = {}
    for _, name in ipairs(headers) do
        lines[#lines + 1] = name .. " " .. incremental.file_digest(context,
            compiler_paths.join(paths.lua_source, name)) .. "\n"
    end
    return sha256.hex_via(context.cache_adapter and context.cache_adapter.sha256_binary, table.concat(lines))
end

local function probe_fingerprint(context, descriptor)
    local source, err = context.io:tmpname()
    if not source then return nil, err end
    local object = source .. ".o"
    local function finish(value, failure)
        context.io:unlink(source)
        context.io:unlink(object)
        return value, failure
    end
    local written, write_error = context.io:write_file(source, "int titan_browser_target_probe(void) { return 0; }\n")
    if not written then return finish(nil, write_error) end
    local command = { table.unpack(descriptor.compiler_argv) }
    for _, flag in ipairs(descriptor.compile_flags) do command[#command + 1] = flag end
    command[#command + 1] = "-x"; command[#command + 1] = "c"
    command[#command + 1] = "-c"; command[#command + 1] = source
    command[#command + 1] = "-o"; command[#command + 1] = object
    local result = context.io:run(command, { stderr_to_stdout = true })
    if type(result) ~= "table" or not result.ok then
        return finish(nil, type(result) == "table" and (result.diagnostic or result.output) or "browser object probe failed")
    end
    local bytes, read_error = context.io:read_file(object)
    if not bytes then return finish(nil, read_error) end
    local parsed, parse_error = staticmetadata.classify_object(bytes, object)
    return finish(parsed and parsed.fingerprint, parse_error)
end

function M.build(context, inputs)
    local ok, descriptor, failure = pcall(function()
        local valid, flag_error = M.validate_flags(inputs.compile_flags, "compile_flags")
        if not valid then return nil, flag_error end
        for _, flag in ipairs(inputs.compile_flags or {}) do
            if not inputs.trace_control and M.trace_option(flag) then
                return nil, "browser target owns compile_flags option " .. flag
            end
        end
        local paths = inputs.paths
        local tool, tool_error = tools(context)
        if not tool then return nil, tool_error end
        local bytes, read_error = context.io:read_file(paths.lua_record)
        if not bytes then return nil, record_error(paths, "is unavailable", tostring(read_error)) end
        local record, defines = parse_record(bytes, paths)
        if not record then return nil, defines end
        local archive_ok, archive = pcall(incremental.file_digest, context, paths.liblua)
        if not archive_ok then
            if type(archive) ~= "string" then error(archive, 0) end
            return nil, mismatch(paths, record, "archive_sha256", "unavailable: " .. archive)
        elseif archive ~= record.archive_sha256 then return nil, mismatch(paths, record, "archive_sha256", archive) end
        local header_ok, headers, header_error = pcall(header_digest, context, paths)
        if not header_ok and type(headers) ~= "string" then error(headers, 0) end
        if not header_ok or not headers then
            return nil, mismatch(paths, record, "headers_sha256", "unavailable: " .. tostring(header_error or headers))
        elseif headers ~= record.headers_sha256 then return nil, mismatch(paths, record, "headers_sha256", headers) end
        -- Emscripten -g2 preserves names but strips object line tables.
        local flags = { "--std=c99", "-O1", "-fno-inline", "-fno-optimize-sibling-calls",
            "-Wall", "-Wno-unused-but-set-variable", "-Wno-unused-function", "-gline-tables-only",
            "-sSUPPORT_LONGJMP=emscripten" }
        for _, define in ipairs(defines) do flags[#flags + 1] = define end
        local target_defines = { table.unpack(TARGET_DEFINES) }
        for _, define in ipairs(target_defines) do flags[#flags + 1] = define end
        for _, flag in ipairs(inputs.compile_flags or {}) do flags[#flags + 1] = flag end
        local includes, include_error = cdriver.resolve_compiler_include_dirs(context.extra_ffi_include_dirs or {})
        if not includes then return nil, "invalid extra_ffi_include_dirs: " .. include_error end
        table.insert(includes, 1, inputs.runtime_include or paths.include)
        table.insert(includes, 1, paths.lua_source)
        for index, directory in ipairs(includes) do
            if not text(directory) or directory == "" then return nil, "invalid browser include path" end
            local resolved, resolve_error = include_root(context.io, directory)
            if not resolved then return nil, resolve_error end
            includes[index] = resolved
        end
        local provisional = { io = context.io, compiler_argv = tool.cc, compile_flags = flags,
            language_mode = "c99", language_flag = false, cppflags = {}, cflags = {}, include_dirs = includes }
        local profile_inputs, profile_error = cdriver.target_profile_inputs({ io = context.io,
            cache_adapter = context.cache_adapter, compiler = tool.cc, language_flag = false,
            compiler_include_dirs = includes, compile_flags = flags, language_mode = "c99" })
        if not profile_inputs then return nil, profile_error end
        local profile
        profile, profile_error = csemantics.build_profile(profile_inputs)
        if not profile then return nil, profile_error end
        local numeric = "integer=" .. profile.lua_integer .. ",float=" .. profile.lua_number
        if numeric ~= record.numeric then return nil, mismatch(paths, record, "numeric", numeric) end
        local fingerprint, fingerprint_error = probe_fingerprint(context, provisional)
        if not fingerprint then return nil, fingerprint_error end
        local expected = { format = "wasm", word_size = 32, linking_version = 2, features = FEATURES }
        local matches, mismatch_error = staticmetadata.fingerprint_matches(fingerprint, expected)
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
                diagnostic = diagnostic .. "; check the selected Emscripten " .. M.EMSCRIPTEN_VERSION .. " installation"
            end
            return nil, diagnostic
        end
        local data = { label = "browser", triple = "wasm32-unknown-emscripten", memory_bits = 32,
            tools = tool, compile_flags = flags, include_dirs = includes, target_defines = target_defines,
            paths = paths, lua = { path = paths.lua_record, record = record,
                record_sha256 = sha256.hex_via(context.cache_adapter and context.cache_adapter.sha256_binary, bytes) },
            profile_data = assert(csemantics.export_profile(profile)), profile_identity = profile.identity,
            fingerprint = expected, probe_cache_directory = inputs.probe_cache_directory,
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
