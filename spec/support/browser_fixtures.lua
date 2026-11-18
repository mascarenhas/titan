-- Hand-made closed data for descriptor, isolation and Wasm reader specs.
-- No toolchain, installation or driver initialization is needed here.
local csemantics = require "titan-compiler.csemantics"
local incremental = require "titan-compiler.incremental"
local sha256 = require "titan-compiler.sha256"
local version = require "titan-compiler.version"
local cprobe_cache = require "titan-compiler.cprobe_cache"
local platform = require "titan-compiler.platform"
local M = {}

M.features = "+bulk-memory +bulk-memory-opt +call-indirect-overlong +exception-handling " ..
    "+multivalue +mutable-globals +nontrapping-fptoint +reference-types +sign-ext"
M.record_keys = { "fork_revision", "archive_sha256", "headers_sha256",
    "emscripten_version", "target", "wasm_features", "sjlj", "lua_defines", "numeric", "cflags" }
M.banner = "# Lua 5.5.1 browser build record v1\n"
M.target_defines = {
    "-DTITAN_TARGET_BROWSER=1",
    "-DTITAN_COROUTINE_STACK_SIZE=262144",
}

function M.fingerprint()
    return { format = "wasm", word_size = 32, linking_version = 2, features = M.features }
end

function M.profile_inputs()
    local macros = {
        __CHAR_BIT__ = "8", __SIZEOF_BOOL__ = "1", __SIZEOF_SHORT__ = "2",
        __SIZEOF_INT__ = "4", __SIZEOF_LONG__ = "4", __SIZEOF_LONG_LONG__ = "8",
        __SIZEOF_FLOAT__ = "4", __SIZEOF_DOUBLE__ = "8", __SIZEOF_LONG_DOUBLE__ = "16",
        __FLT_RADIX__ = "2", __FLT_MAX_EXP__ = "128", __DBL_MAX_EXP__ = "1024",
        __LDBL_MAX_EXP__ = "16384", __FLT_MANT_DIG__ = "24", __DBL_MANT_DIG__ = "53",
        __LDBL_MANT_DIG__ = "113", __SCHAR_MAX__ = "127", __SHRT_MAX__ = "32767",
        __INT_MAX__ = "2147483647", __LONG_MAX__ = "2147483647L",
        __LONG_LONG_MAX__ = "9223372036854775807LL",
    }
    return { macros = macros,
        lua_integer = "long long", lua_number = "double", size_t = "unsigned long",
        ptrdiff_t = "long", signed_minima = {
            ["signed char"] = "-128", short = "-32768", int = "-2147483648",
            long = "-2147483648", ["long long"] = "-9223372036854775808",
        } }
end

function M.profile()
    return assert(csemantics.build_profile(M.profile_inputs()))
end

function M.profile_data()
    return assert(csemantics.export_profile(M.profile()))
end

function M.paths(root)
    root = root or (platform.windows and "C:/browser-fixture" or "/browser-fixture")
    local sdk = root .. "/lib/titan-browser/" .. version.TITAN_LIBRARY_VERSION
    return { root = root, lua_source = root .. "/lib/browser/include",
        include = root .. "/include", lib = root .. "/lib/browser",
        liblua = root .. "/lib/browser/liblua.a",
        lua_record = root .. "/lib/browser/liblua-config.txt", titan_bin = sdk,
        libtitan = sdk .. "/libtitan.a", sdk_digests = sdk .. "/sdk-digests" }
end

function M.record(overrides)
    local archive = "hand-made browser Lua archive bytes"
    local headers = { ["lua.h"] = "/* fixture lua.h */\n",
        ["luaconf.h"] = "/* fixture luaconf.h */\n" }
    local header_lines = {}
    for _, name in ipairs({ "lua.h", "luaconf.h" }) do
        header_lines[#header_lines + 1] = name .. " " .. sha256.hex(headers[name]) .. "\n"
    end
    local record = { fork_revision = string.rep("a", 40),
        archive_sha256 = sha256.hex(archive), headers_sha256 = sha256.hex(table.concat(header_lines)),
        emscripten_version = "6.0.13", target = "wasm32-unknown-emscripten",
        wasm_features = M.features, sjlj = "wasm",
        lua_defines = "-DLUA_USE_BROWSER -DLUA_USE_POSIX",
        numeric = "integer=long long,float=double",
        cflags = "-O2 -Wall -Wextra -DLUA_USE_POSIX -DLUA_USE_BROWSER " ..
            "-sSUPPORT_LONGJMP=wasm -sWASM_LEGACY_EXCEPTIONS=1" }
    for key, value in pairs(overrides or {}) do record[key] = value end
    local text = { M.banner }
    for _, key in ipairs(M.record_keys) do text[#text + 1] = key .. "=" .. record[key] .. "\n" end
    return record, table.concat(text), archive, headers
end

function M.identify(data, context)
    data.identity = nil
    data.identity = "browser:sha256:" .. incremental.digest(context or {}, "browser-target", data)
    return data
end

-- The owned object prefix of each build profile, hand-written so the spec pins
-- the contract instead of borrowing the implementation.
M.object_flags = {
    validation = { "--std=c99", "-O1", "-fno-inline", "-fno-optimize-sibling-calls" },
    production = { "--std=c99", "-O3" },
}
for _, profile in pairs(M.object_flags) do
    profile[#profile + 1] = "-Wall"
    profile[#profile + 1] = "-Wno-unused-but-set-variable"
    profile[#profile + 1] = "-Wno-unused-function"
    profile[#profile + 1] = "-gline-tables-only"
    profile[#profile + 1] = "-sSUPPORT_LONGJMP=wasm"
    profile[#profile + 1] = "-sWASM_LEGACY_EXCEPTIONS=1"
end

function M.descriptor(root, overrides)
    local paths = M.paths(root)
    local record, record_text = M.record()
    local profile = M.profile_data()
    local tools = (platform.windows and "C:" or "") .. "/emsdk/upstream/emscripten/"
    local suffix = platform.windows and ".exe" or ""
    local build_profile = overrides and overrides.build_profile or "validation"
    local flags = { table.unpack(M.object_flags[build_profile] or {}) }
    for _, define in ipairs({ "-DLUA_USE_BROWSER", "-DLUA_USE_POSIX" }) do
        flags[#flags + 1] = define
    end
    for _, define in ipairs(M.target_defines) do flags[#flags + 1] = define end
    local data = { label = "browser", triple = "wasm32-unknown-emscripten", memory_bits = 32,
        build_profile = build_profile, trace_control = (overrides and overrides.trace_control) or nil,
        tools = { cc = { tools .. "emcc" .. suffix }, ar = { tools .. "emar" .. suffix },
            ranlib = { tools .. "emranlib" .. suffix }, version = "6.0.13", source = "EMSDK",
            location = tools:sub(1, -2), version_output = "emcc (Emscripten) 6.0.13\n" },
        compile_flags = flags, include_dirs = { paths.lua_source, paths.include },
        target_defines = { table.unpack(M.target_defines) }, paths = paths,
        lua = { path = paths.lua_record, record = record, record_sha256 = sha256.hex(record_text) },
        profile_data = profile, profile_identity = profile.identity, fingerprint = M.fingerprint(),
        probe_cache_directory = paths.root .. "/var/cache/titan-probes/browser-6.0.13/" .. cprobe_cache.VERSION,
        output_policy = { requires_output = true, marker = ".titan-target", marker_contents = "browser\n" },
        provider_policy = { archive_only = true, sdk_first = true, dynamic = false } }
    for key, value in pairs(overrides or {}) do data[key] = value end
    return M.identify(data)
end

-- A valid, named (or deliberately unnamed) final module just above the JS
-- embedding body bound. Real-link rejection specs replace only staged bytes.
function M.oversized_body(name, source)
    local function leb(value)
        local out = {}
        repeat
            local digit = value & 127
            value = value >> 7
            out[#out + 1] = string.char(digit | (value > 0 and 128 or 0))
        until value == 0
        return table.concat(out)
    end
    local function text(value) return leb(#value) .. value end
    local function section(id, payload) return string.char(id) .. leb(#payload) .. payload end
    local header = "\0asm\1\0\0\0" .. section(1, "\1\96\0\0") .. section(3, "\1\0")
    local body = "\0" .. string.rep("\1", 7654320) .. "\11"
    local prefix = "\1" .. leb(#body)
    local start = #header + 1 + #leb(#prefix + #body) + #prefix
    local wasm = header .. section(10, prefix .. body)
    if name then wasm = wasm .. section(0, text("name") .. section(1, "\1\0" .. text(name))) end
    local mappings = ""
    if source then
        local alphabet, value, digits = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", (start + 1) * 2, {}
        repeat
            local digit = value & 31
            value = value >> 5
            digits[#digits + 1] = alphabet:sub(digit + (value > 0 and 32 or 0) + 1,
                digit + (value > 0 and 32 or 0) + 1)
        until value == 0
        mappings = table.concat(digits) .. "AyCM" -- source 0, line 42, column 7
    end
    return wasm, '{"version":3,"sources":[' .. (source and string.format("%q", source) or "") ..
        '],"names":[],"mappings":"' .. mappings .. '"}'
end

return M
