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
    "wasi_sdk_version", "target", "wasm_features", "sjlj", "lua_defines", "numeric", "cflags" }
M.banner = "# Lua 5.5.1 browser build record v2\n"
M.sjlj_flags = { "-mexception-handling", "-mllvm", "-wasm-enable-sjlj",
    "-mllvm", "-wasm-use-legacy-eh=false" }
M.target_defines = {
    "-DTITAN_TARGET_BROWSER=1",
    "-DTITAN_COROUTINE_STACK_SIZE=262144",
}

-- POSIX host models must also use the real POSIX lexical path implementation,
-- even if the running interpreter loaded the Windows version of path.lua.
function M.with_posix_host(callback)
    local saved_windows = platform.windows
    local native, saved = require "titan-compiler.path", {}
    if saved_windows then
        local filename = assert(package.searchpath("titan-compiler.path", package.path))
        local environment = setmetatable({ package = { config = "/\n;\n?\n!\n-\n" } }, { __index = _G })
        local posix = assert(loadfile(filename, "t", environment))()
        for key, value in pairs(posix) do
            saved[key], native[key] = native[key], value
        end
    end
    platform.windows = false
    local ok, result = xpcall(callback, debug.traceback)
    platform.windows = saved_windows
    for key, value in pairs(saved) do native[key] = value end
    if not ok then error(result, 0) end
    return result
end

function M.fingerprint()
    return { format = "wasm", word_size = 32, linking_version = 2, features = M.features }
end

function M.profile_inputs()
    local macros = {
        __CHAR_BIT__ = "8", __SIZEOF_BOOL__ = "1", __SIZEOF_SHORT__ = "2",
        __SIZEOF_INT128__ = "16",
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
        wasi_sdk_version = "34.0", target = "wasm32-wasip1",
        wasm_features = M.features, sjlj = "wasm-exnref",
        lua_defines = "-DLUA_USE_BROWSER -D_WASI_EMULATED_PROCESS_CLOCKS",
        numeric = "integer=long long,float=double",
        cflags = "--target=wasm32-wasip1 -O2 -Wall -Wextra -DLUA_USE_BROWSER -D_WASI_EMULATED_PROCESS_CLOCKS " ..
            table.concat(M.sjlj_flags, " ") .. " -gdwarf-4 -gline-tables-only" }
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
    profile[#profile + 1] = "-gdwarf-4"
    profile[#profile + 1] = "-gline-tables-only"
    for _, flag in ipairs(M.sjlj_flags) do profile[#profile + 1] = flag end
    profile[#profile + 1] = "-D_WASI_EMULATED_PROCESS_CLOCKS"
end

function M.descriptor(root, overrides)
    local paths = M.paths(root)
    local record, record_text = M.record()
    local profile = M.profile_data()
    local sdk = (platform.windows and "C:" or "") .. "/wasi-sdk"
    local suffix = platform.windows and ".exe" or ""
    local build_profile = overrides and overrides.build_profile or "validation"
    local flags = { table.unpack(M.object_flags[build_profile] or {}) }
    for _, define in ipairs({ "-DLUA_USE_BROWSER", "-D_WASI_EMULATED_PROCESS_CLOCKS" }) do
        flags[#flags + 1] = define
    end
    for _, define in ipairs(M.target_defines) do flags[#flags + 1] = define end
    local data = { label = "browser", triple = "wasm32-wasip1", memory_bits = 32,
        build_profile = build_profile, trace_control = (overrides and overrides.trace_control) or nil,
        tools = { cc = { sdk .. "/bin/clang" .. suffix }, ar = { sdk .. "/bin/llvm-ar" .. suffix },
            ranlib = { sdk .. "/bin/llvm-ranlib" .. suffix }, ld = { sdk .. "/bin/wasm-ld" .. suffix },
            sysroot = sdk .. "/share/wasi-sysroot",
            version = "34.0", source = "WASI_SDK_PATH", location = sdk,
            version_output = "clang version 23.1.0-wasi-sdk\n",
            optimizer = { argv = { (platform.windows and "C:" or "") .. "/binaryen/bin/wasm-opt" .. suffix },
                version = "133", source = "BINARYEN_ROOT", version_output = "wasm-opt version 133 (version_133)\n" } },
        compile_flags = flags, include_dirs = { paths.lua_source, paths.include },
        target_defines = { table.unpack(M.target_defines) }, paths = paths,
        lua = { path = paths.lua_record, record = record, record_sha256 = sha256.hex(record_text) },
        profile_data = profile, profile_identity = profile.identity, fingerprint = M.fingerprint(),
        probe_cache_directory = paths.root .. "/var/cache/titan-probes/browser-34.0/" .. cprobe_cache.VERSION,
        output_policy = { requires_output = true, marker = ".titan-target", marker_contents = "browser\n" },
        provider_policy = { archive_only = true, sdk_first = true, dynamic = false } }
    for key, value in pairs(overrides or {}) do data[key] = value end
    return M.identify(data)
end

function M.leb(value)
    local out = {}
    repeat
        local digit = value & 127
        value = value >> 7
        out[#out + 1] = string.char(digit | (value > 0 and 128 or 0))
    until value == 0
    return table.concat(out)
end

function M.sleb(value)
    local out = {}
    while true do
        local digit = value & 127
        value = value >> 7
        if (value == 0 and digit < 64) or (value == -1 and digit >= 64) then
            out[#out + 1] = string.char(digit)
            return table.concat(out)
        end
        out[#out + 1] = string.char(digit | 128)
    end
end

function M.wasm_section(id, payload) return string.char(id) .. M.leb(#payload) .. payload end
function M.custom_section(name, payload) return M.wasm_section(0, M.leb(#name) .. name .. payload) end

-- DWARF v4 line-program opcodes for hand-made `.debug_line` sections.
M.line = {
    copy = "\1",
    end_sequence = "\0\1\1",
    set_address = function(address) return "\0\5\2" .. string.pack("<I4", address) end,
    advance_pc = function(delta) return "\2" .. M.leb(delta) end,
    advance_line = function(delta) return "\3" .. M.sleb(delta) end,
    set_file = function(index) return "\4" .. M.leb(index) end,
    set_column = function(column) return "\5" .. M.leb(column) end,
}

-- One 32-bit DWARF v4 `.debug_line` unit with clang's header layout
-- (line_base -5, line_range 14, opcode_base 13). `files` rows are
-- { name, directory_index }; `options` may override `version` and `max_ops`.
function M.line_unit(directories, files, program, options)
    options = options or {}
    local header = { string.pack("<BBBbBB", 1, options.max_ops or 1, 1, -5, 14, 13),
        "\0\1\1\1\1\0\0\0\1\0\0\1" }
    for _, directory in ipairs(directories) do header[#header + 1] = directory .. "\0" end
    header[#header + 1] = "\0"
    for _, file in ipairs(files) do header[#header + 1] = file[1] .. "\0" .. M.leb(file[2]) .. "\0\0" end
    header[#header + 1] = "\0"
    header = table.concat(header)
    local body = string.pack("<I2I4", options.version or 4, #header) .. header .. program
    return string.pack("<I4", #body) .. body
end

-- A valid, named (or deliberately unnamed) final module just above the JS
-- embedding body bound, as wasm-opt leaves it: its `.debug_line` maps the
-- body to `source` line 42, column 7. Real-link rejection specs replace only
-- the staged optimizer output.
function M.oversized_body(name, source)
    local function text(value) return M.leb(#value) .. value end
    local section = M.wasm_section
    local header = "\0asm\1\0\0\0" .. section(1, "\1\96\0\0") .. section(3, "\1\0")
    local body = "\0" .. string.rep("\1", 7654320) .. "\11"
    local prefix = "\1" .. M.leb(#body)
    local wasm = header .. section(10, prefix .. body)
    if name then wasm = wasm .. section(0, text("name") .. section(1, "\1\0" .. text(name))) end
    local program = ""
    if source then
        program = M.line.set_address(#prefix) .. M.line.set_column(7) .. M.line.advance_line(41) ..
            M.line.copy .. M.line.set_address(#prefix + #body) .. M.line.end_sequence
    end
    return wasm .. M.custom_section(".debug_line", M.line_unit({}, { { source or "unmapped.c", 0 } }, program))
end

return M
