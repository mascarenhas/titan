local assert = require "luassert"
local browser = require "titan-compiler.browsertarget"
local cdriver = require "c-parser.cdriver"
local csemantics = require "titan-compiler.csemantics"
local compiler_io = require "titan-compiler.io"
local process = require "titan-compiler.process"
local staticmetadata = require "titan-compiler.staticmetadata"
local fixtures = require "spec.support.browser_fixtures"
local gate = require "spec.support.browser_toolchain"
local platform = require "titan-compiler.platform"
local cprobe_cache = require "titan-compiler.cprobe_cache"
local cprobe = require "titan-compiler.cprobe"
local incremental = require "titan-compiler.incremental"
local types = require "titan-compiler.types"
local path = require "titan-compiler.path"
local lfs = require "lfs"
local files = require "spec.fixtures.target_selection.support"
local temporary = require "spec.support.temporary"
local graphcodec = require "titan-compiler.graphcodec"
local version = require "titan-compiler.version"
local other_library_series = require "spec.support.other_library_series"
local FAKE_ROOT = platform.windows and "C:/fake" or "/fake"
local LUA_REMEDY = platform.windows and "mingw32-make -f Makefile.win lua-browser" or "make install-browser"
local PATH_SEPARATOR = platform.windows and ";" or ":"
local SDK_INSTALL = "; install wasi-sdk 34.0 (https://github.com/WebAssembly/wasi-sdk/releases/tag/wasi-sdk-34)" ..
    " and set WASI_SDK_PATH to its root"
local OPTIMIZER_INSTALL = "; install Binaryen version_133" ..
    " (https://github.com/WebAssembly/binaryen/releases/tag/version_133)" ..
    " and set BINARYEN_ROOT to its root or WASM_OPT to its wasm-opt"
local CLANG_VERSION = "clang version 23.1.0-wasi-sdk\nTarget: wasm32-unknown-wasip1\nThread model: single\n"
local OPTIMIZER_VERSION = "wasm-opt version 133 (version_133)\n"
-- The environment variables toolchain discovery reads. Specs give each one
-- an explicit value (or none) so an ambient installation cannot leak in.
local TOOLCHAIN_VARIABLES = { WASI_SDK_PATH = true, BINARYEN_ROOT = true, WASM_OPT = true, PATH = true }
local function tool_suffix()
    return platform.windows and ".exe" or ""
end

-- The `--version` query discovery runs through the compiler argv policy.
local function version_query(tools)
    local argv = browser.compiler_argv(tools)
    argv[#argv + 1] = "--version"
    return argv
end

local function fresh_driver()
    local saved = package.loaded["titan-compiler.driver"]
    package.loaded["titan-compiler.driver"] = nil
    local subject = require "titan-compiler.driver"
    package.loaded["titan-compiler.driver"] = saved
    return subject
end

-- A fake filesystem holding the browser Lua installation, one wasi-sdk 34.0
-- (`<tool_root>/wasi-sdk`) and one Binaryen 133 (`<tool_root>/binaryen`).
-- `missing` names one installed file to remove: "clang", "llvm-ar",
-- "llvm-ranlib", "wasm-ld", "wasm-opt" or "VERSION". `unstartable` and `failing` name a
-- tool whose `--version` run does not start or exits nonzero.
local function fake_context(options)
    options = options or {}
    local function key(filename)
        -- NTFS accepts either separator; an exact-string map must model that.
        return (platform.windows or options.windows_paths) and
            assert(platform.path.normalize(filename)) or filename
    end
    local paths = fixtures.paths(options.root)
    local record, record_text, archive, headers = fixtures.record(options.record)
    local files = { [key(paths.lua_record)] = options.record_text or record_text,
        [key(paths.liblua)] = options.archive or archive }
    for name, contents in pairs(headers) do files[key(paths.lua_source .. "/" .. name)] = contents end
    if options.header then files[key(paths.lua_source .. "/lua.h")] = options.header end
    local tool_root = options.tool_root or FAKE_ROOT
    local sdk = tool_root .. "/wasi-sdk"
    local suffix = tool_suffix()
    local installed = { VERSION = sdk .. "/VERSION", ["wasm-opt"] = tool_root .. "/binaryen/bin/wasm-opt" .. suffix }
    for _, tool in ipairs({ "clang", "llvm-ar", "llvm-ranlib", "wasm-ld" }) do
        installed[tool] = sdk .. "/bin/" .. tool .. suffix
    end
    for _, filename in pairs(installed) do files[key(filename)] = "fake launcher" end
    files[key(installed.VERSION)] = options.version_file or "34.0\nwasi-libc: fixture\nllvm: fixture\n"
    if options.missing then files[key(installed[options.missing])] = nil end
    if options.missing_record then files[key(paths.lua_record)] = nil end
    if options.missing_archive then files[key(paths.liblua)] = nil end
    local calls, serial = {}, 0
    local directories = { [key(paths.lua_source)] = true }
    if not options.missing_sysroot then directories[key(sdk .. "/share/wasi-sysroot")] = true end
    local strategy = setmetatable({}, { __index = compiler_io.new_sync() })
    function strategy:cwd() return tool_root end
    function strategy:realpath(filename) return key(filename) end
    function strategy:stat(filename)
        filename = key(filename)
        if directories[filename] then return { kind = "directory", size = 0, mode = 0x41ed } end
        local bytes = files[filename]
        if bytes then return { kind = "file", size = #bytes, mode = 0x81ed,
            modified_seconds = 1, changed_seconds = 1, device = 1, inode = 1 } end
        return nil
    end
    strategy.lstat = strategy.stat
    function strategy:readable(filename) return files[key(filename)] ~= nil end
    function strategy:executable(filename) return files[key(filename)] ~= nil end
    function strategy:read_file(filename)
        local bytes = files[key(filename)]
        return bytes, bytes == nil and "not found" or nil
    end
    function strategy:list(filename)
        if key(filename) ~= key(paths.lua_source) then return {} end
        return { "luaconf.h", "lua.h", "not-a-header.txt" }
    end
    function strategy:write_file(filename, bytes) files[key(filename)] = bytes; return true end
    function strategy:unlink(filename) files[key(filename)] = nil; return true end
    function strategy:mkdir(filename) directories[key(filename)] = true; return true end
    function strategy:rmdir(filename) directories[key(filename)] = nil; return true end
    function strategy:tmpname() serial = serial + 1; return tool_root .. "/probe-" .. serial end
    function strategy:run(argv)
        calls[#calls + 1] = { table.unpack(argv) }
        if argv[1] == "uname" then return { started = true, ok = true, output = options.uname or "Linux\n" } end
        if argv[#argv] == "--version" then
            -- The physical tool follows an `env NAME=` launch wrapper.
            local index = 1
            if argv[1] == "env" then
                index = 2
                while argv[index]:find("=", 1, true) do index = index + 1 end
            end
            local tool = key(argv[index]):match("([^/\\]+)$"):gsub("%.exe$", "")
            if options.unstartable == tool then
                return { started = false, ok = false, diagnostic = "not a Windows executable" }
            end
            if options.failing == tool then
                return { started = true, ok = false, output = "fixture: unsupported option\n",
                    why = "exit", status = 1 }
            end
            if tool == "wasm-opt" then
                return { started = true, ok = true, output = options.optimizer_output or OPTIMIZER_VERSION }
            end
            return { started = true, ok = true, output = CLANG_VERSION }
        end
        for index, flag in ipairs(argv) do
            if flag == "-o" then files[key(argv[index + 1])] = "fake relocatable Wasm object" end
        end
        return { started = true, ok = true, output = "", why = "exit", status = 0 }
    end
    return { io = strategy, extra_ffi_include_dirs = {} },
        { paths = paths, runtime_include = paths.include,
            build_profile = options.build_profile or "validation",
            probe_cache_directory = tool_root .. "/probes/browser-34.0/" .. cprobe_cache.VERSION },
        calls, files, record, directories
end

local function contains(message, fragment)
    assert.is_string(message)
    assert.truthy(message:find(fragment, 1, true), message)
end

local function remove_flag(data, flag)
    for index = #data.compile_flags, 1, -1 do
        if data.compile_flags[index] == flag then table.remove(data.compile_flags, index) end
    end
end

describe("browser target descriptor", function()
    local saved_getenv, saved_profile, saved_classify, saved_registry, saved_windows
    local workspace
    -- Discovery sees exactly `values` for the toolchain variables; every
    -- other variable keeps its real value.
    local function environment(values)
        return function(name)
            if TOOLCHAIN_VARIABLES[name] then return values[name] end
            return saved_getenv(name)
        end
    end
    before_each(function()
        saved_registry, saved_windows = types.registry, platform.windows
        saved_getenv, saved_profile, saved_classify = platform.getenv,
            cdriver.target_profile_inputs, staticmetadata.classify_object
        platform.getenv = environment({ WASI_SDK_PATH = FAKE_ROOT .. "/wasi-sdk",
            BINARYEN_ROOT = FAKE_ROOT .. "/binaryen", PATH = FAKE_ROOT .. "/wasi-sdk/bin" })
        cdriver.target_profile_inputs = function() return fixtures.profile_inputs() end
        staticmetadata.classify_object = function() return { fingerprint = fixtures.fingerprint() } end
    end)
    after_each(function()
        platform.getenv, cdriver.target_profile_inputs, staticmetadata.classify_object =
            saved_getenv, saved_profile, saved_classify
        types.registry, platform.windows = saved_registry, saved_windows
        if workspace then files.remove(workspace); workspace = nil end
    end)

    it("models Windows separator aliases in every fake SDK filesystem operation", function()
        local context, inputs = fake_context({ root = "C:/fixture", windows_paths = true })
        local strategy = context.io
        local forward = inputs.paths.lua_source .. "/lua.h"
        local backward = forward:gsub("/", "\\")
        assert.same(strategy:stat(forward), strategy:stat(backward))
        assert.same(strategy:lstat(forward), strategy:lstat(backward))
        assert.is_true(strategy:readable(backward))
        assert.is_true(strategy:executable(backward))
        assert.equal(assert(strategy:read_file(forward)), assert(strategy:read_file(backward)))
        assert.equal(forward, strategy:realpath(backward))
        assert.same(strategy:list(inputs.paths.lua_source), strategy:list(inputs.paths.lua_source:gsub("/", "\\")))
        assert(strategy:write_file(backward, "replacement"))
        assert.equal("replacement", strategy:read_file(forward))
        assert(strategy:unlink(backward))
        assert.is_nil(strategy:read_file(forward))
        local directory = inputs.paths.root .. "/temporary"
        assert(strategy:mkdir(directory:gsub("/", "\\")))
        assert.equal("directory", strategy:stat(directory).kind)
        assert(strategy:rmdir(directory:gsub("/", "\\")))
        assert.is_nil(strategy:stat(directory))
    end)

    it("pins wasi-sdk 34.0, Binaryen 133, the target compiler argv and both object profiles", function()
        assert.equal("34.0", browser.WASI_SDK_VERSION)
        assert.equal("133", browser.BINARYEN_VERSION)
        assert.is_nil(browser.EMSCRIPTEN_VERSION)
        -- One launch envelope empties every variable clang reads to edit its
        -- command line, search paths or linker (D11), around the physical clang.
        local envelope = { "env", "CCC_OVERRIDE_OPTIONS=", "CPATH=", "C_INCLUDE_PATH=", "CPLUS_INCLUDE_PATH=",
            "OBJC_INCLUDE_PATH=", "LIBRARY_PATH=", "COMPILER_PATH=" }
        assert.same({ "env", "CCC_OVERRIDE_OPTIONS=", "CPATH=", "C_INCLUDE_PATH=", "CPLUS_INCLUDE_PATH=",
            "OBJC_INCLUDE_PATH=", "LIBRARY_PATH=", "COMPILER_PATH=", "/sdk/bin/clang", "--target=wasm32-wasip1",
            "--sysroot=/sdk/share/wasi-sysroot" },
            browser.compiler_argv({ cc = { "/sdk/bin/clang" }, sysroot = "/sdk/share/wasi-sysroot" }))
        local descriptor = assert(browser.import(fixtures.descriptor()))
        local argv = browser.compiler_argv(descriptor.tools)
        assert.same(envelope, { table.unpack(argv, 1, #envelope) })
        assert.same({ descriptor.tools.cc[1], "--target=wasm32-wasip1", "--sysroot=" .. descriptor.tools.sysroot },
            { table.unpack(argv, #envelope + 1) })
        assert.equal(fixtures.descriptor().tools.cc[1], descriptor.tools.cc[1])
        argv[1] = "changed by a caller"
        assert.equal("env", browser.compiler_argv(descriptor.tools)[1])
        for build_profile, flags in pairs(fixtures.object_flags) do
            assert.is_true(browser.valid_profile(build_profile))
            assert.same(flags, browser.object_flags(build_profile))
        end
        local flags = browser.object_flags("validation")
        flags[1] = "changed by a caller"
        assert.equal("--std=c99", browser.object_flags("validation")[1])
        assert.is_false(browser.valid_profile("release"))
        assert.is_nil(browser.object_flags("release"))
    end)

    it("builds a verified closed descriptor, retains all record facts, and freezes every level", function()
        local context, inputs, calls = fake_context()
        local descriptor = assert(browser.build(context, inputs))
        local sdk, suffix = FAKE_ROOT .. "/wasi-sdk", tool_suffix()
        local clang, sysroot = sdk .. "/bin/clang" .. suffix, sdk .. "/share/wasi-sysroot"
        local optimizer = FAKE_ROOT .. "/binaryen/bin/wasm-opt" .. suffix
        assert.equal("browser", descriptor.label)
        assert.equal("wasm32-wasip1", descriptor.triple)
        assert.same({ cc = { clang }, ar = { sdk .. "/bin/llvm-ar" .. suffix },
            ranlib = { sdk .. "/bin/llvm-ranlib" .. suffix }, ld = { sdk .. "/bin/wasm-ld" .. suffix },
            sysroot = sysroot, version = "34.0",
            source = "WASI_SDK_PATH", location = sdk, version_output = CLANG_VERSION,
            optimizer = { argv = { optimizer }, version = "133", source = "BINARYEN_ROOT",
                version_output = OPTIMIZER_VERSION } }, browser.export(descriptor.tools))
        assert.same({ inputs.paths.lua_source, inputs.paths.include }, browser.export(descriptor.include_dirs))
        assert.equal("integer=long long,float=double", descriptor.lua.record.numeric)
        assert.equal("wasm-exnref", descriptor.lua.record.sjlj)
        assert.equal("wasm32-wasip1", descriptor.lua.record.target)
        assert.equal("34.0", descriptor.lua.record.wasi_sdk_version)
        assert.equal(32, descriptor.profile_data.integers.long.bits)
        assert.equal(64, descriptor.profile_data.integers["long long"].bits)
        assert.equal(fixtures.features, descriptor.fingerprint.features)
        assert.has_error(function() descriptor.label = "linux" end, "browser target descriptor is immutable")
        assert.has_error(function() descriptor.extra = true end, "browser target descriptor is immutable")
        assert.has_error(function() descriptor.tools.cc[1] = "cc" end, "browser target descriptor is immutable")
        assert.has_error(function() descriptor.tools.optimizer.argv[1] = "wasm-opt" end,
            "browser target descriptor is immutable")
        assert.has_error(function() descriptor.lua.record.sjlj = "wasm" end, "browser target descriptor is immutable")
        assert.has_error(function() table.insert(descriptor.compile_flags, "-flto") end,
            "browser target descriptor is immutable")
        assert.equal(3, #calls)
        assert.same(version_query(descriptor.tools), calls[1])
        assert.equal(clang, calls[1][#calls[1] - 3])
        assert.same({ optimizer, "--version" }, calls[2])
        local probe = calls[#calls]
        local compiler = browser.compiler_argv(descriptor.tools)
        assert.same(compiler, { table.unpack(probe, 1, #compiler) })
        local flags = table.concat(probe, " ")
        contains(flags, "-c")
        contains(flags, "-gdwarf-4 -gline-tables-only " .. table.concat(fixtures.sjlj_flags, " ") ..
            " -D_WASI_EMULATED_PROCESS_CLOCKS")
        contains(flags, "-DTITAN_TARGET_BROWSER=1")
        contains(flags, "-DTITAN_COROUTINE_STACK_SIZE=262144")
        assert.same(fixtures.target_defines, browser.export(descriptor.target_defines))
        for _, absent in ipairs({ "-fPIC", "-flto", "EMCC_CFLAGS", "-sSUPPORT_LONGJMP", "-sWASM_LEGACY_EXCEPTIONS" }) do
            assert.is_nil(flags:find(absent, 1, true), absent)
        end
    end)

    it("compiles a raw .s reservation as C and cleans up exactly its files in the fingerprint probe", function()
        local context, inputs, calls, storage = fake_context()
        local reservation = inputs.paths.root .. "/fingerprint.s"
        function context.io:tmpname()
            storage[reservation] = ""
            return reservation
        end
        local unlinked = {}
        local unlink = context.io.unlink
        function context.io:unlink(filename)
            unlinked[#unlinked + 1] = filename
            return unlink(self, filename)
        end
        assert(browser.build(context, inputs))
        local command = calls[#calls]
        assert.same({ "-x", "c", "-c", reservation, "-o", reservation .. ".o" },
            { table.unpack(command, #command - 5) })
        table.sort(unlinked)
        assert.same({ reservation, reservation .. ".o" }, unlinked)
        for _, filename in ipairs({ reservation, reservation .. ".o" }) do
            assert.is_nil(storage[filename])
        end
    end)

    it("round-trips transport data without running tools or reading the record", function()
        local context, inputs, calls = fake_context()
        local descriptor = assert(browser.build(context, inputs))
        local data = browser.export(descriptor)
        assert.is_nil(getmetatable(data))
        local rebuilt = assert(browser.import(data))
        assert.same(data, browser.export(rebuilt))
        assert.equal(descriptor.identity, rebuilt.identity)
        assert.equal(3, #calls)
        data.compile_flags[1] = "changed after import"
        assert.equal("--std=c99", rebuilt.compile_flags[1])
        assert.is_nil(browser.import(data))
    end)

    it("round-trips data-only semantic profiles for both build profiles without tools", function()
        local provider, absent = ("a"):rep(64), ("b"):rep(64)
        for _, build_profile in ipairs({ "production", "validation" }) do
            local descriptor = assert(browser.import(fixtures.descriptor(nil, { build_profile = build_profile })))
            local bytes = assert(browser.encode_analysis(nil, descriptor, provider, absent))
            local data = assert(browser.decode_analysis(nil, bytes))
            assert.equal(build_profile, data.build_profile)
            assert.equal("wasm32-wasip1", data.triple)
            assert.equal("34.0", data.wasi_sdk_version)
            assert.is_nil(data.emscripten_version)
            assert.equal(provider, data.provider_sha256)
            assert.equal(absent, data.absent_sha256)
            assert.equal(descriptor.lua.record.numeric, data.lua.numeric)
            assert.same(browser.export(descriptor.fingerprint), data.fingerprint)
            assert.same(browser.export(descriptor.profile_data), data.profile_data)
            assert.is_nil(data.tools)
            assert.is_nil(data.paths)
        end
        assert.has_error(function() browser.encode_analysis(nil, {}, provider, absent) end)
        local descriptor = assert(browser.import(fixtures.descriptor()))
        assert.has_error(function() browser.encode_analysis(nil, descriptor, "bad", absent) end)
    end)

    it("admits semantic profiles from the library series regardless of patch release", function()
        local descriptor = assert(browser.import(fixtures.descriptor()))
        local bytes = assert(browser.encode_analysis(nil, descriptor, ("a"):rep(64), ("b"):rep(64)))
        local data = assert(browser.decode_analysis(nil, bytes))
        for _, patch in ipairs({ "0", "99" }) do
            local release = version.TITAN_LIBRARY_VERSION .. "." .. patch
            data.release = release
            local decoded = assert(browser.decode_analysis(nil, assert(browser.encode_analysis_data(nil, data))))
            assert.equal(release, decoded.release)
        end
        for _, series in ipairs(other_library_series) do
            data.release = series .. ".0"
            local decoded, err = browser.decode_analysis(nil, assert(browser.encode_analysis_data(nil, data)))
            assert.is_nil(decoded)
            assert.equal("incompatible browser semantic target", err)
        end
    end)

    it("publishes identical semantic descriptor bytes from separate Lua states", function()
        local strategy = compiler_io.new_sync()
        local prefix = require("spec.support.installed_prefix").active()
        local lua = path.join(prefix, platform.windows and "bin/lua.exe" or "bin/lua")
        local source = [[
local filename = ...
package.path = "./?.lua;./?/init.lua;" .. package.path
local browser = require "titan-compiler.browsertarget"
local fixtures = require "spec.support.browser_fixtures"
local built = assert(browser.import(fixtures.descriptor()))
local bytes = assert(browser.encode_analysis(nil, built, ("a"):rep(64), ("b"):rep(64)))
local data = assert(browser.decode_analysis(nil, bytes))
assert(bytes == assert(browser.encode_analysis_data(nil, data)))
local file = assert(io.open(filename, "wb"))
assert(file:write(bytes))
assert(file:close())
]]
        local script = assert(strategy:tmpname())
        local first, second = assert(strategy:tmpname()), assert(strategy:tmpname())
        local cleanup <close> = setmetatable({}, { __close = function()
            strategy:unlink(script)
            strategy:unlink(first)
            strategy:unlink(second)
        end })
        assert(strategy:write_file(script, source))
        for _, filename in ipairs({ first, second }) do
            local run = strategy:run({ lua, "-E", script, filename })
            assert.is_true(run.ok, run.output or run.diagnostic)
        end
        local bytes = assert(strategy:read_file(first))
        assert(browser.decode_analysis(nil, bytes))
        assert.equal(bytes, assert(strategy:read_file(second)))
    end)

    it("rejects malformed semantic data even with a valid graph checksum", function()
        local descriptor = assert(browser.import(fixtures.descriptor()))
        local bytes = assert(browser.encode_analysis(nil, descriptor, ("a"):rep(64), ("b"):rep(64)))
        for _, case in ipairs({
            { "incompatible", function(data) data.target = "linux" end },
            { "incompatible", function(data) data.triple = "wasm64" end },
            { "incompatible", function(data) data.triple = "wasm32-unknown-emscripten" end },
            { "incompatible", function(data) data.abi = "1" end },
            { "incompatible", function(data) data.release = version.TITAN_LIBRARY_VERSION end },
            { "incompatible", function(data) data.release = version.TITAN_LIBRARY_VERSION .. ".01" end },
            { "incompatible", function(data) data.release = {} end },
            { "incompatible", function(data) data.build_profile = "debug" end },
            { "incompatible", function(data) data.wasi_sdk_version = "33.0" end },
            { "incompatible", function(data) data.wasi_sdk_version = nil end },
            { "incompatible", function(data) data.wasi_sdk_version = nil; data.emscripten_version = "6.0.13" end },
            { "incompatible", function(data) data.emscripten_version = "6.0.13" end },
            { "incompatible", function(data) data.paths = {} end },
            { "fingerprint", function(data) data.fingerprint.features = "" end },
            { "Lua facts", function(data) data.lua.headers_sha256 = nil end },
            { "Lua facts", function(data) data.lua.fork_revision = "bad" end },
            { "inconsistent browser numeric profile", function(data) data.lua.numeric = "integer=int,float=double" end },
            { "asset digests", function(data) data.provider_sha256 = "" end },
            { "asset digests", function(data) data.absent_sha256 = ("Z"):rep(64) end },
            { "target profile data", function(data) data.profile_data = {} end },
        }) do
            local data = assert(browser.decode_analysis(nil, bytes))
            case[2](data)
            local decoded, err = browser.decode_analysis(nil, assert(graphcodec.encode(data)))
            assert.is_nil(decoded)
            contains(err, case[1])
        end
        for _, case in ipairs({
            { "-DFOO=1", "requires LUA_USE_BROWSER" },
            { "-D_WASI_EMULATED_PROCESS_CLOCKS", "requires LUA_USE_BROWSER" },
            { " '-DLUA_USE_BROWSER' ", "noncanonical list" },
            { "-DLUA_USE_BROWSER!bad", "expected sorted unique -D tokens" },
            { "-D_WASI_EMULATED_PROCESS_CLOCKS -DLUA_USE_BROWSER", "expected sorted unique -D tokens" },
            { "-DLUA_USE_BROWSER -DLUA_USE_BROWSER", "expected sorted unique -D tokens" },
            { "-DLUA_USE_BROWSER=\255", "text encoding" },
            { "-DLUA_USE_BROWSER -DLUA_USE_DLOPEN=1", "LUA_USE_DLOPEN is unavailable for browser Lua" },
            { "-DLUA_USE_BROWSER -DLUA_USE_POSIX", "LUA_USE_POSIX is unavailable for browser Lua" },
            { "-DLUA_USE_BROWSER -DLUA_USE_LINUX", "LUA_USE_LINUX is unavailable for browser Lua" },
            { "-DLUA_USE_BROWSER -DLUA_USE_MACOSX", "LUA_USE_MACOSX is unavailable for browser Lua" },
        }) do
            local data = assert(browser.decode_analysis(nil, bytes))
            data.lua.defines = case[1]
            local decoded, err = browser.decode_analysis(nil, assert(graphcodec.encode(data)))
            assert.is_nil(decoded)
            assert.equal("invalid browser Lua defines: " .. case[2], err)
        end
        local data = assert(browser.decode_analysis(nil, bytes))
        local profile = assert(csemantics.import_profile(data.profile_data))
        local extended = profile.floats["long double"]
        extended.bits, extended.mantissa_digits, extended.maximum_exponent = 64, 53, 1024
        profile.integers["__int128"], profile.integers["unsigned __int128"] = nil, nil
        data.profile_data = assert(csemantics.export_profile(profile))
        local decoded, err = browser.decode_analysis(nil, assert(graphcodec.encode(data)))
        assert.is_nil(decoded)
        contains(err, "does not describe the browser's wasm32 target")
        -- Full build descriptors still carry the actual configured C facts;
        -- do not impose the editor pack's pinned C profile on ordinary builds.
        local build = fixtures.descriptor(nil, {
            profile_data = data.profile_data, profile_identity = data.profile_data.identity,
        })
        local built = assert(browser.import(build))
        local encoded, encode_error = browser.encode_analysis(nil, built, ("a"):rep(64), ("b"):rep(64))
        assert.is_nil(encoded)
        contains(encode_error, "does not describe the browser's wasm32 target")
    end)

    it("rejects unknown, cyclic and executable transport fields", function()
        for _, change in ipairs({
            function(data) data.unknown = true end,
            function(data) data.tools.execute = function() end end,
            function(data) data.tools.optimizer.execute = function() end end,
            function(data) data.paths.root = data end,
            function(data) data.lua.record.sjlj = "wasm"; fixtures.identify(data) end,
        }) do
            local data = fixtures.descriptor()
            change(data)
            assert.is_nil(browser.import(data))
        end
    end)

    it("rejects an Emscripten-era transported Lua record", function()
        for _, change in ipairs({
            function(record) record.emscripten_version = "6.0.13" end,
            function(record) record.emscripten_version, record.wasi_sdk_version = "6.0.13", nil end,
        }) do
            local data = fixtures.descriptor()
            change(data.lua.record)
            fixtures.identify(data)
            local descriptor, err = browser.import(data)
            assert.is_nil(descriptor)
            assert.equal("invalid browser Lua descriptor", err)
        end
    end)

    it("requires the wasi-sdk tool layout and a Binaryen optimizer in transported descriptors", function()
        local suffix = tool_suffix()
        for _, case in ipairs({
            { "invalid browser toolchain descriptor", function(tools) tools.sysroot = nil end },
            { "invalid browser toolchain descriptor", function(tools) tools.sysroot = tools.location .. "/sysroot" end },
            { "invalid browser toolchain descriptor", function(tools) tools.version = "33.0" end },
            { "invalid browser toolchain descriptor", function(tools) tools.source = "EMSDK" end },
            { "invalid browser toolchain descriptor", function(tools) tools.version_output = false end },
            { "invalid browser toolchain descriptor", function(tools) tools.location = "./wasi-sdk" end },
            { "invalid browser toolchain descriptor", function(tools) tools.optimizer = nil end },
            { "invalid browser toolchain descriptor", function(tools) tools.clang = { tools.cc[1] } end },
            { "invalid browser tool argv", function(tools) tools.cc = { tools.cc[1], "--target=wasm32-wasip2" } end },
            { "invalid browser tool argv", function(tools) tools.cc = tools.cc[1] end },
            { "invalid browser tool argv", function(tools) tools.cc[1] = tools.location .. "/emcc" .. suffix end },
            { "invalid browser tool argv", function(tools) tools.ar[1] = tools.location .. "/bin/emar" .. suffix end },
            { "invalid browser tool argv", function(tools) tools.ar = {} end },
            { "invalid browser toolchain descriptor", function(tools) tools.ld = nil end },
            { "invalid browser tool argv", function(tools) tools.ld = { tools.ld[1], "--no-entry" } end },
            { "invalid browser tool argv", function(tools) tools.ld[1] = tools.location .. "/bin/lld" .. suffix end },
            { "invalid browser tool argv", function(tools)
                tools.ld[1] = tools.location .. "/bin/./wasm-ld" .. suffix
            end },
            { "invalid browser tool argv", function(tools) tools.ld[1] = "wasm-ld" .. suffix end },
            { "invalid browser tool argv", function(tools)
                tools.ranlib[1] = tools.location .. "/bin/llvm-ar" .. suffix
            end },
            { "invalid browser optimizer descriptor", function(tools) tools.optimizer = "wasm-opt" end },
            { "invalid browser optimizer descriptor", function(tools) tools.optimizer.version = "132" end },
            { "invalid browser optimizer descriptor", function(tools) tools.optimizer.source = "EMSDK" end },
            { "invalid browser optimizer descriptor", function(tools) tools.optimizer.argv = { "wasm-opt" } end },
            { "invalid browser optimizer descriptor", function(tools) tools.optimizer.argv[2] = "-O2" end },
            { "invalid browser optimizer descriptor", function(tools)
                tools.optimizer.argv[1] = tools.optimizer.argv[1]:gsub("/bin/", "/./bin/")
            end },
            { "invalid browser optimizer descriptor", function(tools) tools.optimizer.version_output = nil end },
            { "invalid browser optimizer descriptor", function(tools) tools.optimizer.passes = { "-O2" } end },
        }) do
            local data = fixtures.descriptor()
            case[2](data.tools)
            fixtures.identify(data)
            local descriptor, err = browser.import(data)
            assert.is_nil(descriptor)
            assert.equal(case[1], err)
        end
        for _, source in ipairs({ "WASM_OPT", "BINARYEN_ROOT", "PATH" }) do
            local data = fixtures.descriptor()
            data.tools.optimizer.source = source
            fixtures.identify(data)
            assert(browser.import(data))
        end
        local data = fixtures.descriptor()
        data.tools.source = "PATH"
        fixtures.identify(data)
        assert(browser.import(data))
    end)

    for _, case in ipairs({
        { "empty include roots", function(data) data.include_dirs = {} end },
        { "missing runtime root", function(data) data.include_dirs = { data.paths.lua_source } end },
        { "relative Lua root", function(data) data.include_dirs[1] = "relative/include" end },
        { "relative runtime root", function(data) data.include_dirs[2] = "relative/runtime" end },
        { "relative extra root", function(data) data.include_dirs[3] = "./extra-ffi" end },
        { "unnormalized include root", function(data) data.include_dirs[2] = data.paths.include .. "/./runtime" end },
        { "reversed include roots", function(data)
            data.include_dirs[1], data.include_dirs[2] = data.include_dirs[2], data.include_dirs[1]
        end },
        { "duplicate Lua instead of runtime", function(data) data.include_dirs[2] = data.paths.lua_source end },
        { "sparse include roots", function(data) data.include_dirs[3], data.include_dirs[2] = data.include_dirs[2], nil end },
        { "missing browser flags", function(data) data.compile_flags = { "--std=c99" } end },
        { "missing C99 flag", function(data) remove_flag(data, "--std=c99") end },
        { "missing target define", function(data) remove_flag(data, "-DTITAN_TARGET_BROWSER=1") end },
        { "missing coroutine stack define", function(data) remove_flag(data, "-DTITAN_COROUTINE_STACK_SIZE=262144") end },
        { "inconsistent target defines", function(data) data.target_defines = { "-DTITAN_TARGET_BROWSER=1" } end },
        { "missing Lua define", function(data) remove_flag(data, "-DLUA_USE_BROWSER") end },
        { "missing WASI clock emulation", function(data) remove_flag(data, "-D_WASI_EMULATED_PROCESS_CLOCKS") end },
        { "missing exception handling", function(data) remove_flag(data, "-mexception-handling") end },
        { "missing setjmp/longjmp lowering", function(data) remove_flag(data, "-wasm-enable-sjlj") end },
        { "missing exnref EH encoding", function(data) remove_flag(data, "-wasm-use-legacy-eh=false") end },
        { "missing DWARF version", function(data) remove_flag(data, "-gdwarf-4") end },
        { "LTO flag", function(data) data.compile_flags[#data.compile_flags + 1] = "-flto" end },
        { "PIC flag", function(data) data.compile_flags[#data.compile_flags + 1] = "-fPIC" end },
        { "split conflicting LLVM option", function(data)
            data.compile_flags[#data.compile_flags + 1] = "-mllvm"
            data.compile_flags[#data.compile_flags + 1] = "-wasm-enable-sjlj=false"
        end },
        { "joined conflicting EH encoding", function(data)
            data.compile_flags[#data.compile_flags + 1] = "-mllvm=-wasm-use-legacy-eh=true"
        end },
        { "conflicting target", function(data)
            data.compile_flags[#data.compile_flags + 1] = "--target=wasm32-wasip2"
        end },
        { "conflicting sysroot", function(data)
            data.compile_flags[#data.compile_flags + 1] = "--sysroot=/elsewhere"
        end },
        { "sparse flags", function(data) data.compile_flags[2] = nil end },
        { "relative tool location", function(data) data.tools.location = "./wasi-sdk" end },
        { "unnormalized tool location", function(data) data.tools.location = data.tools.location .. "/." end },
        { "unnormalized tool argv", function(data)
            data.tools.cc[1] = data.tools.location .. "/bin/./clang" .. tool_suffix()
        end },
        { "tool outside its installation", function(data)
            data.tools.ar[1] = data.tools.location .. "/other/llvm-ar" .. tool_suffix()
        end },
        { "linker outside its installation", function(data)
            data.tools.ld[1] = data.tools.location .. "/other/wasm-ld" .. tool_suffix()
        end },
        { "sysroot outside its installation", function(data)
            data.tools.sysroot = data.tools.location .. "/sysroot"
        end },
        { "relative optimizer", function(data) data.tools.optimizer.argv[1] = "wasm-opt" .. tool_suffix() end },
        { "unnormalized probe root", function(data) data.probe_cache_directory = data.probe_cache_directory .. "/." end },
        { "invalid cflags syntax", function(data) data.lua.record.cflags = "'" end },
        { "inconsistent Lua defines", function(data) data.lua.record.lua_defines = "-DINVALID" end },
    }) do
        it("rejects re-identified transport with " .. case[1], function()
            local data = fixtures.descriptor()
            case[2](data)
            fixtures.identify(data)
            local descriptor, err = browser.import(data)
            assert.is_nil(descriptor, case[1])
            assert.is_string(err)
        end)
    end

    for _, key in ipairs(fixtures.record_keys) do
        it("rejects empty and invalid UTF-8 transported record field " .. key, function()
            for _, value in ipairs({ "", "\255" }) do
                local data = fixtures.descriptor()
                data.lua.record[key] = value
                fixtures.identify(data)
                local descriptor, err = browser.import(data)
                assert.is_nil(descriptor)
                contains(err, 'invalid field "' .. key .. '"')
            end
        end)
    end

    it("requires every transported installation path to be normalized and absolute", function()
        for key, value in pairs(fixtures.paths()) do
            for _, replacement in ipairs({ "relative/path", value .. "/." }) do
                local data = fixtures.descriptor()
                data.paths[key] = replacement
                fixtures.identify(data)
                local descriptor, err = browser.import(data)
                assert.is_nil(descriptor, key)
                contains(err, "invalid browser path")
            end
        end
    end)

    it("normalizes relative API runtime and extra FFI roots before build and transport", function()
        local context, inputs = fake_context()
        inputs.runtime_include = "./checkout/titan-runtime"
        context.extra_ffi_include_dirs = { "./nested/../extra-ffi", "headers/../other-ffi" }
        inputs.compile_flags = { "-fno-lto" }
        local descriptor = assert(browser.build(context, inputs))
        assert.same({ inputs.paths.lua_source, FAKE_ROOT .. "/checkout/titan-runtime",
            FAKE_ROOT .. "/extra-ffi", FAKE_ROOT .. "/other-ffi" }, browser.export(descriptor.include_dirs))
        local data = browser.export(descriptor)
        assert.same(data, browser.export(assert(browser.import(data))))
        assert.same({ "./nested/../extra-ffi", "headers/../other-ffi" }, context.extra_ffi_include_dirs)
    end)

    for _, role in ipairs({ "runtime", "extra FFI" }) do
        for _, spelling in ipairs({ "absolute", "relative" }) do
            it("preserves " .. spelling .. " symlink-parent " .. role .. " lookup and transport", function()
                if platform.windows then
                    pending("platform: Windows resolves a link followed by .. lexically, not as a POSIX symlink parent")
                    return
                end
                workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
                files.mkdir(workspace .. "/physical/nested")
                files.mkdir(workspace .. "/physical/include")
                files.mkdir(workspace .. "/include")
                files.write(workspace .. "/physical/include/selected.h",
                    "typedef int titan_browser_symlink_parent_value;\n")
                files.write(workspace .. "/include/selected.h",
                    "typedef double titan_browser_symlink_parent_value;\n")
                assert(lfs.link("physical/nested", workspace .. "/sdk-link", true))
                local real = compiler_io.new_sync()
                local raw = workspace .. "/sdk-link/../include"
                local relative = "sdk-link/../include"
                local root_index = role == "runtime" and 2 or 3
                local function build(directory)
                    local context, inputs = fake_context()
                    local fixture_stat = context.io.stat
                    local fixture_realpath = context.io.realpath
                    function context.io:cwd() return workspace end
                    function context.io:realpath(filename)
                        if filename:sub(1, #workspace + 1) == workspace .. "/" then
                            return real:realpath(filename)
                        end
                        return fixture_realpath(self, filename)
                    end
                    function context.io:stat(filename)
                        if filename:sub(1, #workspace + 1) == workspace .. "/" then
                            return real:stat(filename)
                        end
                        return fixture_stat(self, filename)
                    end
                    if role == "runtime" then inputs.runtime_include = directory
                    else context.extra_ffi_include_dirs = { directory } end
                    return assert(browser.build(context, inputs))
                end
                local descriptor = build(spelling == "absolute" and raw or relative)
                assert.equal(assert(real:realpath(workspace .. "/physical/include")),
                    descriptor.include_dirs[root_index])
                local native_types, native_error = cdriver.process_file("selected.h", {
                    source_dir = workspace, compiler_include_dirs = { raw },
                })
                assert.truthy(native_types, native_error)
                local selected_types, selected_error = cdriver.process_file("selected.h", {
                    source_dir = workspace, compiler_include_dirs = browser.export(descriptor.include_dirs),
                })
                assert.truthy(selected_types, selected_error)
                assert.same({ "int" }, selected_types.titan_browser_symlink_parent_value.def)
                assert.same(native_types.titan_browser_symlink_parent_value.def,
                    selected_types.titan_browser_symlink_parent_value.def)
                local other = build(spelling == "absolute" and relative or raw)
                assert.equal(descriptor.identity, other.identity)
                local data = browser.export(descriptor)
                assert.same(data, browser.export(assert(browser.import(data))))
            end)
        end

        it("matches native missing-root and resolution-error handling for " .. role .. " roots", function()
            if platform.windows then
                pending("platform: Windows normalizes .. before filesystem lookup; the fixture injects POSIX lookup errors")
                return
            end
            for _, state in ipairs({ "missing", "existing", "stat failure" }) do
                local context, inputs = fake_context()
                local raw = FAKE_ROOT .. "/unresolved/../include"
                local looked_up = {}
                local fixture_realpath = context.io.realpath
                function context.io:realpath(filename)
                    if filename == raw then
                        looked_up[#looked_up + 1] = filename
                        return nil, "injected realpath failure"
                    end
                    return fixture_realpath(self, filename)
                end
                local fixture_stat = context.io.stat
                function context.io:stat(filename)
                    if filename == raw then
                        if state == "existing" then return { kind = "directory" } end
                        if state == "stat failure" then return nil, "injected stat failure" end
                        return nil
                    end
                    return fixture_stat(self, filename)
                end
                if role == "runtime" then inputs.runtime_include = raw
                else context.extra_ffi_include_dirs = { raw } end
                local descriptor, err = browser.build(context, inputs)
                if state == "missing" then
                    assert.truthy(descriptor, err)
                    assert.equal(FAKE_ROOT .. "/include", descriptor.include_dirs[role == "runtime" and 2 or 3])
                else
                    assert.is_nil(descriptor)
                    assert.equal(state == "existing" and "injected realpath failure" or "injected stat failure", err)
                end
                assert.same({ raw }, looked_up)
            end
        end)
    end

    it("validates direct build compile extras before tool discovery", function()
        for _, flags in ipairs({
            { "-fPIC" }, { "-flto" }, { "-mllvm", "-wasm-enable-sjlj=false" },
            { "-mllvm", "-wasm-use-legacy-eh=true" }, { "--target=wasm32-wasip2" },
            { "--sysroot=/elsewhere" }, { "-mno-exception-handling" },
            "not an array", { [1] = "-O0", [3] = "-g" }, { debug = "-O0" }, { true },
        }) do
            local context, inputs, calls = fake_context()
            inputs.compile_flags = flags
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            contains(err, "compile_flags")
            assert.equal(0, #calls)
        end
    end)

    for _, flag in ipairs({
        "-O0", "-O2", "-O3", "-Os", "-g", "-g0", "-g2", "-gline-tables-only", "-gdwarf-4", "-gdwarf-5",
        "-finline-functions", "-fno-inline", "-fno-inline-functions",
        "-foptimize-sibling-calls", "-fno-optimize-sibling-calls",
        "-fomit-frame-pointer", "-fno-omit-frame-pointer",
    }) do
        it("rejects the profile-owned compile option " .. flag .. " before tool discovery", function()
            local context, inputs, calls = fake_context()
            inputs.compile_flags = { flag }
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            assert.equal('browser validation profile owns compile option "' .. flag .. '"', err)
            assert.equal(0, #calls)
        end)
    end

    it("names the production profile when it refuses an owned option before tool discovery", function()
        local context, inputs, calls = fake_context()
        inputs.build_profile = "production"
        inputs.compile_flags = { "-gdwarf-5" }
        local descriptor, err = browser.build(context, inputs)
        assert.is_nil(descriptor)
        assert.equal('browser production profile owns compile option "-gdwarf-5"', err)
        assert.equal(0, #calls)
    end)

    it("rejects an unknown build profile", function()
        local context, inputs, calls = fake_context()
        inputs.build_profile = "release"
        local descriptor, err = browser.build(context, inputs)
        assert.is_nil(descriptor)
        assert.equal('invalid browser build profile "release"', err)
        assert.equal(0, #calls)
    end)

    it("changes identity for record revision, effective flags, paths and profile facts", function()
        local baseline = fixtures.descriptor()
        for _, change in ipairs({
            function(data) data.lua.record.fork_revision = string.rep("b", 40) end,
            function(data) data.compile_flags[#data.compile_flags + 1] = "-DCHANGED=1" end,
            function(data) data.include_dirs[1] = "/other/lua" end,
            function(data) data.probe_cache_directory = "/other/probes" end,
        }) do
            local data = fixtures.descriptor()
            change(data); fixtures.identify(data)
            assert.not_equal(baseline.identity, data.identity)
        end
        -- The build profile is part of the identity even where flags agree:
        -- the two installations are separate targets (D26).
        local production = fixtures.descriptor(nil, { build_profile = "production" })
        assert.not_equal(baseline.identity, production.identity)
        assert.equal("production", production.build_profile)
    end)

    it("builds the production object profile from the profile, not from flags", function()
        local context, inputs, calls = fake_context({ build_profile = "production" })
        local descriptor = assert(browser.build(context, inputs))
        assert.equal("production", descriptor.build_profile)
        assert.same({
            "--std=c99", "-O3", "-Wall", "-Wno-unused-but-set-variable", "-Wno-unused-function",
            "-gdwarf-4", "-gline-tables-only", "-mexception-handling", "-mllvm", "-wasm-enable-sjlj",
            "-mllvm", "-wasm-use-legacy-eh=false", "-D_WASI_EMULATED_PROCESS_CLOCKS",
            "-DLUA_USE_BROWSER", "-D_WASI_EMULATED_PROCESS_CLOCKS", table.unpack(fixtures.target_defines),
        }, descriptor.compile_flags)
        assert.is_true(#calls > 0, "the production build never probed its toolchain")
        -- The same inputs under the validation profile produce #330's frozen set.
        local validation = assert(browser.build(fake_context()))
        assert.same({
            "--std=c99", "-O1", "-fno-inline", "-fno-optimize-sibling-calls",
            "-Wall", "-Wno-unused-but-set-variable", "-Wno-unused-function",
            "-gdwarf-4", "-gline-tables-only", "-mexception-handling", "-mllvm", "-wasm-enable-sjlj",
            "-mllvm", "-wasm-use-legacy-eh=false", "-D_WASI_EMULATED_PROCESS_CLOCKS",
            "-DLUA_USE_BROWSER", "-D_WASI_EMULATED_PROCESS_CLOCKS", table.unpack(fixtures.target_defines),
        }, validation.compile_flags)
        assert.not_equal(descriptor.identity, validation.identity)
    end)

    it("refuses every target-owned code-generation spelling before tool discovery", function()
        for _, extras in ipairs({
            { "-mllvm", "-wasm-enable-sjlj" }, { "-mllvm=-wasm-use-legacy-eh=true" },
            { "-mexception-handling" }, { "-mno-exception-handling" },
            { "-mlegacy-exception-handling" }, { "-mno-legacy-exception-handling" },
            { "-fwasm-exceptions" }, { "-fno-wasm-exceptions" },
            { "--target=wasm32-wasip2" }, { "-target", "wasm32-wasip1" },
            { "--sysroot=/elsewhere" }, { "--sysroot", "/elsewhere" },
            { "-mexec-model=reactor" }, { "-Xclang", "-target-feature" }, { "-Xclang=-mllvm" },
            { "--config", "browser.cfg" }, { "--config=browser.cfg" }, { "--config-system-dir=/etc/clang" },
            { "@browser.rsp" },
        }) do
            local context, inputs, calls = fake_context()
            inputs.compile_flags = extras
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            assert.equal('browser target does not support compile_flags flag "' .. extras[1] .. '"', err)
            assert.equal(0, #calls)
        end
    end)

    it("refuses a second measurement level and non-level overrides before tool discovery", function()
        for _, extras in ipairs({ { "-O2", "-O1" }, { "-O2", "-g2" }, { "-g2" } }) do
            local context, inputs, calls = fake_context()
            inputs.trace_control = true
            inputs.compile_flags = extras
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            assert.equal('browser validation profile owns compile option "' ..
                extras[#extras] .. '"', err)
            assert.equal(0, #calls)
        end
        local context, inputs, calls = fake_context()
        inputs.trace_control = true
        inputs.compile_flags = { "-O2" }
        assert(browser.build(context, inputs))
        assert.is_true(#calls > 0)
    end)

    it("refuses a descriptor whose flags belong to the other profile", function()
        local data = fixtures.descriptor()
        data.compile_flags[2] = "-O3"
        fixtures.identify(data)
        local imported, err = browser.import(data)
        assert.is_nil(imported)
        assert.equal("browser validation profile compile flags do not match its object profile", err)
    end)

    it("accepts exactly one certified measurement level for a trace-control build", function()
        for _, level in ipairs({ "-O1", "-O2" }) do
            local data = fixtures.descriptor(nil, { trace_control = true })
            data.compile_flags[#data.compile_flags + 1] = level
            fixtures.identify(data)
            assert(browser.import(data))
            -- The measurement override is descriptor data: it changes identity.
            local plain = fixtures.descriptor()
            assert.not_equal(plain.identity, data.identity)
        end
        local twice = fixtures.descriptor(nil, { trace_control = true })
        twice.compile_flags[#twice.compile_flags + 1] = "-O2"
        twice.compile_flags[#twice.compile_flags + 1] = "-O1"
        fixtures.identify(twice)
        local imported, err = browser.import(twice)
        assert.is_nil(imported)
        assert.equal('browser validation profile owns compile option "-O1"', err)
        -- A non-level owned option needs no trace control and is refused.
        local gated = fixtures.descriptor(nil, { trace_control = true })
        gated.compile_flags[#gated.compile_flags + 1] = "-g2"
        fixtures.identify(gated)
        local denied, deny_error = browser.import(gated)
        assert.is_nil(denied)
        assert.equal('browser validation profile owns compile option "-g2"', deny_error)
    end)

    it("refuses a profile-owned option smuggled in after the profile flags", function()
        for _, flag in ipairs({ "-O2", "-g2", "-gdwarf-5", "-fno-inline", "-foptimize-sibling-calls" }) do
            local data = fixtures.descriptor()
            data.compile_flags[#data.compile_flags + 1] = flag
            fixtures.identify(data)
            local imported, err = browser.import(data)
            assert.is_nil(imported)
            assert.equal('browser validation profile owns compile option "' .. flag .. '"', err)
        end
    end)

    it("compares the owned object prefix exactly and applies the user-flag policy only to its tail", function()
        -- The profile's own setjmp/longjmp selection is outside the user-flag
        -- policy: the descriptor compares it rather than filtering it.
        local refused, policy_error = browser.validate_flags(fixtures.object_flags.validation, "compile_flags")
        assert.is_nil(refused)
        assert.equal('browser target does not support compile_flags flag "-mexception-handling"', policy_error)
        assert(browser.import(fixtures.descriptor()))
        for _, case in ipairs({
            { "-mexception-handling", "-mno-exception-handling" },
            { "-wasm-enable-sjlj", "-wasm-enable-eh" },
            { "-wasm-use-legacy-eh=false", "-wasm-use-legacy-eh=true" },
            { "-gdwarf-4", "-gdwarf-5" },
            { "-D_WASI_EMULATED_PROCESS_CLOCKS", "-DOTHER" },
        }) do
            local data = fixtures.descriptor()
            for index, flag in ipairs(data.compile_flags) do
                if flag == case[1] then data.compile_flags[index] = case[2]; break end
            end
            fixtures.identify(data)
            local imported, err = browser.import(data)
            assert.is_nil(imported, case[2])
            assert.equal("browser validation profile compile flags do not match its object profile", err)
        end
        for _, extras in ipairs({
            { "-mllvm", "-wasm-enable-sjlj" }, { "-mllvm=-wasm-use-legacy-eh=true" },
            { "-mexception-handling" }, { "-mno-exception-handling" }, { "--target=wasm32-wasip2" },
            { "-target", "wasm32-wasip1" }, { "--sysroot=/elsewhere" }, { "--sysroot", "/elsewhere" },
            { "-mexec-model=reactor" }, { "-fPIC" }, { "-flto" }, { "-Xclang", "-target-feature" },
            { "--config=browser.cfg" }, { "@browser.rsp" },
        }) do
            local data = fixtures.descriptor()
            for _, flag in ipairs(extras) do data.compile_flags[#data.compile_flags + 1] = flag end
            fixtures.identify(data)
            local imported, err = browser.import(data)
            assert.is_nil(imported, extras[1])
            assert.equal('browser target does not support compile_flags flag "' .. extras[1] .. '"', err)
        end
    end)

    do
        local sdk, suffix = FAKE_ROOT .. "/wasi-sdk", platform.windows and ".exe" or ""
        local optimizer = FAKE_ROOT .. "/binaryen/bin/wasm-opt" .. suffix
        local function requires_sdk(detail)
            return "browser target requires wasi-sdk 34.0: " .. detail .. SDK_INSTALL
        end
        local function requires_optimizer(detail)
            return "browser target requires Binaryen version_133 wasm-opt: " .. detail .. OPTIMIZER_INSTALL
        end
        -- { case, fake options, tool runs before the diagnostic, diagnostic }
        for _, case in ipairs({
            { "a missing clang", { missing = "clang" }, 0, requires_sdk(string.format(
                "%q is not an executable (WASI_SDK_PATH=%q)", sdk .. "/bin/clang" .. suffix, sdk)) },
            { "a different wasi-sdk release", { version_file = "33.0\nwasi-libc: fixture\n" }, 0,
                requires_sdk(string.format("%q reports 33.0", sdk .. "/VERSION")) },
            { "a missing wasi-sdk VERSION", { missing = "VERSION" }, 0,
                requires_sdk(string.format("%q reports unknown", sdk .. "/VERSION")) },
            { "a missing WASI sysroot", { missing_sysroot = true }, 0,
                requires_sdk(string.format("no sysroot at %q", sdk .. "/share/wasi-sysroot")) },
            { "a failing clang", { failing = "clang" }, 1, requires_sdk(string.format(
                "cannot execute %q: fixture: unsupported option", sdk .. "/bin/clang" .. suffix)) },
            { "a missing llvm-ar", { missing = "llvm-ar" }, 1, requires_sdk(string.format(
                "llvm-ar not found at %q", sdk .. "/bin/llvm-ar" .. suffix)) },
            { "a missing llvm-ranlib", { missing = "llvm-ranlib" }, 1, requires_sdk(string.format(
                "llvm-ranlib not found at %q", sdk .. "/bin/llvm-ranlib" .. suffix)) },
            { "a missing wasm-ld", { missing = "wasm-ld" }, 1, requires_sdk(string.format(
                "wasm-ld not found at %q", sdk .. "/bin/wasm-ld" .. suffix)) },
            { "a missing wasm-opt", { missing = "wasm-opt" }, 1, requires_optimizer(string.format(
                "%q is not an executable (BINARYEN_ROOT=%q)", optimizer, FAKE_ROOT .. "/binaryen")) },
            { "a different wasm-opt release", { optimizer_output = "wasm-opt version 132 (version_132)\n" }, 2,
                requires_optimizer(string.format("%q reports version 132", optimizer)) },
            { "an unrecognized wasm-opt version", { optimizer_output = "Binaryen 133\n" }, 2,
                requires_optimizer(string.format("%q reports version unknown", optimizer)) },
            { "a failing wasm-opt", { failing = "wasm-opt" }, 2, requires_optimizer(string.format(
                "cannot execute %q: fixture: unsupported option", optimizer)) },
        }) do
            it("diagnoses " .. case[1] .. " with its location and install instructions", function()
                local context, inputs, calls = fake_context(case[2])
                local descriptor, err = browser.build(context, inputs)
                assert.is_nil(descriptor)
                assert.equal(case[4], err)
                assert.equal(case[3], #calls)
            end)
        end
    end

    it("reads the wasi-sdk release from the first line of its VERSION file", function()
        for _, row in ipairs({ { "34.0\r\nwasi-libc: fixture\r\n", true }, { "34.0", true },
                { "34.0.1\n", false }, { "34\n", false }, { "\n34.0\n", false } }) do
            local context, inputs = fake_context({ version_file = row[1] })
            local descriptor, err = browser.build(context, inputs)
            if row[2] then
                assert.truthy(descriptor, err)
                assert.equal("34.0", descriptor.tools.version)
            else
                assert.is_nil(descriptor)
                contains(err, '/wasi-sdk/VERSION" reports ')
            end
        end
    end)

    it("searches PATH for a wasi-sdk clang only when WASI_SDK_PATH is unset or empty", function()
        local suffix = tool_suffix()
        for _, configured in ipairs({ false, "" }) do
            platform.getenv = environment({ WASI_SDK_PATH = configured or nil,
                BINARYEN_ROOT = FAKE_ROOT .. "/binaryen",
                PATH = "usr/bin" .. PATH_SEPARATOR .. "wasi-sdk/bin" })
            local context, inputs, _, storage = fake_context()
            -- A host clang without a sibling ../VERSION is not a wasi-sdk clang.
            storage[FAKE_ROOT .. "/usr/bin/clang" .. suffix] = "host clang"
            local descriptor = assert(browser.build(context, inputs))
            assert.equal("PATH", descriptor.tools.source)
            assert.equal(FAKE_ROOT .. "/wasi-sdk", descriptor.tools.location)
            assert.equal(FAKE_ROOT .. "/wasi-sdk/bin/clang" .. suffix, descriptor.tools.cc[1])
            assert.equal(FAKE_ROOT .. "/wasi-sdk/bin/wasm-ld" .. suffix, descriptor.tools.ld[1])
            assert.equal(FAKE_ROOT .. "/wasi-sdk/share/wasi-sysroot", descriptor.tools.sysroot)
        end
        local empty = "browser target requires wasi-sdk 34.0: no wasi-sdk clang on PATH " ..
            "(WASI_SDK_PATH unset; a wasi-sdk clang has a sibling ../VERSION)" .. SDK_INSTALL
        for _, search in ipairs({ FAKE_ROOT .. "/usr/bin", false }) do
            platform.getenv = environment({ BINARYEN_ROOT = FAKE_ROOT .. "/binaryen", PATH = search or nil })
            local context, inputs, calls, storage = fake_context()
            storage[FAKE_ROOT .. "/usr/bin/clang" .. suffix] = "host clang"
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            assert.equal(empty, err)
            assert.equal(0, #calls)
        end
    end)

    it("selects wasm-opt from WASM_OPT, then BINARYEN_ROOT, then PATH", function()
        local suffix = tool_suffix()
        local sdk = FAKE_ROOT .. "/wasi-sdk"
        local installed = FAKE_ROOT .. "/binaryen/bin/wasm-opt" .. suffix
        local explicit = FAKE_ROOT .. "/tools/wasm-opt" .. suffix
        for _, row in ipairs({
            { { WASM_OPT = explicit, BINARYEN_ROOT = FAKE_ROOT .. "/binaryen" }, "WASM_OPT", explicit },
            { { WASM_OPT = "tools/wasm-opt" .. suffix }, "WASM_OPT", explicit },
            { { WASM_OPT = "", BINARYEN_ROOT = FAKE_ROOT .. "/binaryen", PATH = FAKE_ROOT .. "/tools" },
                "BINARYEN_ROOT", installed },
            { { BINARYEN_ROOT = "binaryen" }, "BINARYEN_ROOT", installed },
            { { WASM_OPT = "", BINARYEN_ROOT = "", PATH = sdk .. "/bin" .. PATH_SEPARATOR .. "binaryen/bin" ..
                PATH_SEPARATOR .. FAKE_ROOT .. "/tools" }, "PATH", installed },
        }) do
            local values = row[1]
            values.WASI_SDK_PATH = sdk
            platform.getenv = environment(values)
            local context, inputs, calls, storage = fake_context()
            storage[explicit] = "another wasm-opt launcher"
            local descriptor = assert(browser.build(context, inputs))
            assert.same({ argv = { row[3] }, version = "133", source = row[2], version_output = OPTIMIZER_VERSION },
                browser.export(descriptor.tools.optimizer))
            assert.same({ row[3], "--version" }, calls[2])
        end
        platform.getenv = environment({ WASI_SDK_PATH = sdk, WASM_OPT = "", BINARYEN_ROOT = "", PATH = sdk .. "/bin" })
        local context, inputs, calls = fake_context()
        local descriptor, err = browser.build(context, inputs)
        assert.is_nil(descriptor)
        assert.equal("browser target requires Binaryen version_133 wasm-opt: wasm-opt not found " ..
            "(WASM_OPT and BINARYEN_ROOT unset; not on PATH)" .. OPTIMIZER_INSTALL, err)
        assert.equal(1, #calls)
        -- An explicit WASM_OPT that names no executable never falls back.
        local missing = FAKE_ROOT .. "/missing/wasm-opt"
        platform.getenv = environment({ WASI_SDK_PATH = sdk, WASM_OPT = missing,
            BINARYEN_ROOT = FAKE_ROOT .. "/binaryen", PATH = FAKE_ROOT .. "/binaryen/bin" })
        context, inputs, calls = fake_context()
        descriptor, err = browser.build(context, inputs)
        assert.is_nil(descriptor)
        assert.equal(string.format("browser target requires Binaryen version_133 wasm-opt: " ..
            "%q is not an executable (WASM_OPT=%q)", missing, missing) .. OPTIMIZER_INSTALL, err)
        assert.equal(1, #calls)
    end)

    it("uses native Windows executable names for both routes and transported sibling tools", function()
        platform.windows = true
        local root = "C:/Windows fixture"
        local sdk = root .. "/wasi-sdk"
        local binaryen = root .. "/binaryen/bin"
        for _, route in ipairs({ "WASI_SDK_PATH", "PATH" }) do
            platform.getenv = function(name)
                if route == "WASI_SDK_PATH" and name == "WASI_SDK_PATH" then return sdk end
                if route == "WASI_SDK_PATH" and name == "BINARYEN_ROOT" then return root .. "/binaryen" end
                if name == "PATH" then
                    return [["D:\missing; not a delimiter";D:/not-empty;"]] .. sdk .. '/bin";' .. binaryen
                end
            end
            local context, inputs, calls, files = fake_context({ root = root, tool_root = root })
            -- Windows spawn lookup would append these; only the exact .exe counts.
            for _, name in ipairs({ "clang.com", "clang.bat", "wasm-opt.com", "wasm-opt.bat" }) do
                files["D:/not-empty/" .. name] = "not the pinned SDK executable"
            end
            local descriptor = assert(browser.build(context, inputs))
            assert.equal(route, descriptor.tools.source)
            assert.equal(route == "PATH" and "PATH" or "BINARYEN_ROOT", descriptor.tools.optimizer.source)
            assert.equal(sdk, descriptor.tools.location)
            assert.equal(sdk .. "/bin/clang.exe", descriptor.tools.cc[1])
            assert.equal(sdk .. "/bin/llvm-ar.exe", descriptor.tools.ar[1])
            assert.equal(sdk .. "/bin/llvm-ranlib.exe", descriptor.tools.ranlib[1])
            assert.equal(sdk .. "/bin/wasm-ld.exe", descriptor.tools.ld[1])
            assert.equal(sdk .. "/share/wasi-sysroot", descriptor.tools.sysroot)
            assert.equal(binaryen .. "/wasm-opt.exe", descriptor.tools.optimizer.argv[1])
            assert.equal(3, #calls, "descriptor creation never launches archive tools")
            local data = browser.export(descriptor)
            assert(browser.import(data))
            data.tools.cc[1] = data.tools.cc[1]:gsub("/", "\\")
            fixtures.identify(data)
            local invalid, spelling_error = browser.import(data)
            assert.is_nil(invalid)
            assert.equal("invalid browser tool argv", spelling_error)
            data.tools.cc[1] = sdk .. "/bin/clang.exe"
            data.tools.ranlib[1] = sdk .. "/bin/llvm-ranlib"
            fixtures.identify(data)
            local imported, err = browser.import(data)
            assert.is_nil(imported)
            assert.equal("invalid browser tool argv", err)
            data.tools.ranlib[1] = sdk .. "/bin/llvm-ranlib.exe"
            data.tools.ld[1] = sdk .. "/bin/wasm-ld"
            fixtures.identify(data)
            imported, err = browser.import(data)
            assert.is_nil(imported)
            assert.equal("invalid browser tool argv", err)
            data.tools.ld[1] = sdk .. "/bin/wasm-ld.exe"
            data.tools.optimizer.argv[1] = data.tools.optimizer.argv[1]:gsub("/", "\\")
            fixtures.identify(data)
            imported, err = browser.import(data)
            assert.is_nil(imported)
            assert.equal("invalid browser optimizer descriptor", err)
            data.tools.optimizer.argv[1] = binaryen .. "/wasm-opt.exe"
            data.tools.sysroot = data.tools.sysroot:gsub("/", "\\")
            fixtures.identify(data)
            imported, err = browser.import(data)
            assert.is_nil(imported)
            assert.equal("invalid browser toolchain descriptor", err)
            data.tools.sysroot = sdk .. "/share/wasi-sysroot"
            fixtures.identify(data)
            assert(browser.import(data))
        end
    end)

    it("resolves Win32 WASI_SDK_PATH roots without destroying their root or namespace", function()
        platform.windows = true
        local optimizer = "C:/project/binaryen/bin/wasm-opt.exe"
        for _, row in ipairs({
            { [[\kit]], "C:/kit", "/" },
            { "D:kit", "D:/per-drive/kit", "/" },
            { [[\\?\C:\long root\kit]], [[\\?\C:\long root\kit]], "\\" },
        }) do
            local input, resolved, sep = table.unpack(row)
            platform.getenv = function(name)
                if name == "WASI_SDK_PATH" then return input end
                if name == "WASM_OPT" then return optimizer end
            end
            local context, _, calls, storage, _, directories =
                fake_context({ root = "C:/project", tool_root = "C:/project" })
            function context.io:absolute(filename)
                assert.equal("D:kit", filename)
                return resolved
            end
            local function installed(...) return table.concat({ resolved, ... }, sep) end
            for _, name in ipairs({ "clang", "llvm-ar", "llvm-ranlib", "wasm-ld" }) do
                storage[installed("bin", name .. ".exe")] = "launcher"
            end
            storage[installed("VERSION")] = "34.0\n"
            directories[installed("share", "wasi-sysroot")] = true
            local tools = assert(browser.discover_tools(context))
            assert.equal(resolved, tools.location)
            assert.same({ installed("bin", "clang.exe") }, tools.cc)
            assert.same({ installed("bin", "llvm-ar.exe") }, tools.ar)
            assert.same({ installed("bin", "llvm-ranlib.exe") }, tools.ranlib)
            assert.same({ installed("bin", "wasm-ld.exe") }, tools.ld)
            assert.equal(installed("share", "wasi-sysroot"), tools.sysroot)
            assert.same(version_query(tools), calls[1])
            assert.equal("WASM_OPT", tools.optimizer.source)
            assert.same({ optimizer }, tools.optimizer.argv)
        end
    end)

    it("reports a relative toolchain root lookup error without a Lua source location", function()
        for _, windows in ipairs({ false, true }) do
            local root = windows and "C:/project" or "/project"
            local function check()
                for _, row in ipairs({
                    { { WASI_SDK_PATH = "kit" }, "wasi-sdk 34.0", "kit", SDK_INSTALL },
                    { { WASI_SDK_PATH = root .. "/wasi-sdk", BINARYEN_ROOT = "binaryen" },
                        "Binaryen version_133 wasm-opt", "binaryen", OPTIMIZER_INSTALL },
                    { { WASI_SDK_PATH = root .. "/wasi-sdk", WASM_OPT = "bin/wasm-opt" },
                        "Binaryen version_133 wasm-opt", "bin/wasm-opt", OPTIMIZER_INSTALL },
                    { { PATH = "relative/bin" }, "wasi-sdk 34.0", "relative/bin", SDK_INSTALL },
                    { { WASI_SDK_PATH = root .. "/wasi-sdk", PATH = "relative/bin" },
                        "Binaryen version_133 wasm-opt", "relative/bin", OPTIMIZER_INSTALL },
                }) do
                    platform.getenv = function(name) return row[1][name] end
                    local context = fake_context({ root = root, tool_root = root })
                    function context.io:cwd() return nil, "injected cwd failure" end
                    local tools, err = browser.discover_tools(context)
                    assert.is_nil(tools)
                    assert.equal("browser target requires " .. row[2] .. ": cannot resolve " ..
                        string.format("%q", row[3]) .. ": injected cwd failure" .. row[4], err)
                end
            end
            if windows then
                platform.windows = true
                check()
            else
                fixtures.with_posix_host(check)
            end
        end
    end)

    it("does not continue past an existing Windows candidate with a resolution error", function()
        platform.windows = true
        local root = "C:/fixture"
        for _, row in ipairs({
            { "clang", false, root .. "/wasi-sdk/bin", "wasi-sdk 34.0", 0 },
            { "wasm-opt", root .. "/wasi-sdk", root .. "/binaryen/bin", "Binaryen version_133 wasm-opt", 1 },
        }) do
            local tool, configured, directory, requirement, launched = table.unpack(row)
            local candidate = "D:/unresolved/" .. tool .. ".exe"
            platform.getenv = function(name)
                if name == "WASI_SDK_PATH" then return configured or nil end
                if name == "PATH" then return "D:/unresolved;" .. directory end
            end
            local context, inputs, calls, files = fake_context({ root = root, tool_root = root })
            files[candidate] = "candidate with inaccessible metadata"
            local lstat = context.io.lstat
            function context.io:lstat(filename)
                if filename == candidate then return nil, "fixture access denied" end
                return lstat(self, filename)
            end
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            contains(err, "browser target requires " .. requirement .. ": cannot resolve")
            contains(err, candidate)
            contains(err, "fixture access denied")
            assert.equal(launched, #calls)
        end
    end)

    it("stops at a configured Windows tool whose metadata cannot be resolved", function()
        platform.windows = true
        local root = "C:/fixture"
        platform.getenv = function(name)
            if name == "WASI_SDK_PATH" then return root .. "/wasi-sdk" end
            if name == "BINARYEN_ROOT" then return root .. "/binaryen" end
        end
        for _, row in ipairs({
            { root .. "/wasi-sdk/bin/clang.exe", "wasi-sdk 34.0", SDK_INSTALL, 0 },
            { root .. "/wasi-sdk/bin/llvm-ar.exe", "wasi-sdk 34.0", SDK_INSTALL, 1 },
            { root .. "/wasi-sdk/bin/llvm-ranlib.exe", "wasi-sdk 34.0", SDK_INSTALL, 1 },
            { root .. "/wasi-sdk/bin/wasm-ld.exe", "wasi-sdk 34.0", SDK_INSTALL, 1 },
            { root .. "/binaryen/bin/wasm-opt.exe", "Binaryen version_133 wasm-opt", OPTIMIZER_INSTALL, 1 },
        }) do
            local candidate, requirement, install, launched = table.unpack(row)
            local context, inputs, calls = fake_context({ root = root, tool_root = root })
            local lstat = context.io.lstat
            function context.io:lstat(filename)
                if filename == candidate then return nil, "fixture access denied" end
                return lstat(self, filename)
            end
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            contains(err, "browser target requires " .. requirement .. ": cannot resolve " ..
                string.format("%q", candidate) .. ": ")
            contains(err, "fixture access denied")
            assert.equal(install, err:sub(-#install))
            assert.equal(launched, #calls)
        end
    end)

    it("diagnoses a malformed Windows PATH in either tool search", function()
        platform.windows = true
        local root = "C:/fixture"
        for _, row in ipairs({
            { false, "wasi-sdk 34.0", SDK_INSTALL, 0 },
            { root .. "/wasi-sdk", "Binaryen version_133 wasm-opt", OPTIMIZER_INSTALL, 1 },
        }) do
            local configured, requirement, install, launched = table.unpack(row)
            platform.getenv = function(name)
                if name == "WASI_SDK_PATH" then return configured or nil end
                if name == "PATH" then return '"' end
            end
            local context, inputs, calls = fake_context({ root = root, tool_root = root })
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            assert.equal("browser target requires " .. requirement ..
                ': cannot resolve "PATH": malformed Windows executable PATH' .. install, err)
            assert.equal(launched, #calls)
        end
    end)

    it("reports a Windows tool launch failure without mistaking it for a missing file", function()
        platform.windows = true
        local root = "C:/fixture"
        platform.getenv = function(name)
            if name == "WASI_SDK_PATH" then return root .. "/wasi-sdk" end
            if name == "BINARYEN_ROOT" then return root .. "/binaryen" end
        end
        for _, row in ipairs({
            { "clang", root .. "/wasi-sdk/bin/clang.exe", "wasi-sdk 34.0", SDK_INSTALL },
            { "wasm-opt", root .. "/binaryen/bin/wasm-opt.exe", "Binaryen version_133 wasm-opt", OPTIMIZER_INSTALL },
        }) do
            local context, inputs = fake_context({ root = root, tool_root = root, unstartable = row[1] })
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            assert.equal("browser target requires " .. row[3] .. ": cannot execute " ..
                string.format("%q", row[2]) .. ": not a Windows executable" .. row[4], err)
        end
    end)

    it("diagnoses a missing Lua record with the exact host install command and raw prefix", function()
        for _, row in ipairs({
            { false, "/fake", "./sdk", "make install-browser PREFIX=./sdk" },
            { true, "C:/fake", [[C:\sdk]], [[mingw32-make -f Makefile.win lua-browser PREFIX=C:\sdk]] },
        }) do
            local windows, root, prefix, command = table.unpack(row)
            local function check()
                platform.getenv = function(name)
                    if name == "WASI_SDK_PATH" then return root .. "/wasi-sdk" end
                    if name == "BINARYEN_ROOT" then return root .. "/binaryen" end
                end
                local context, inputs = fake_context({ root = root, tool_root = root, missing_record = true })
                inputs.install_prefix = prefix
                local descriptor, err = browser.build(context, inputs)
                assert.is_nil(descriptor)
                assert.equal(string.format("browser Lua record %q is unavailable: not found; install it with '%s'",
                    inputs.paths.lua_record, command), err)
            end
            if windows then
                platform.windows = true
                check()
            else
                fixtures.with_posix_host(check)
            end
        end
    end)

    for _, case in ipairs({
        { "unknown field", function(text) return text .. "unknown=yes\n" end, 'unknown field "unknown"' },
        { "Emscripten-era field", function(text)
            return text:gsub("wasi_sdk_version=[^\n]*", "emscripten_version=6.0.13")
        end, 'unknown field "emscripten_version"' },
        { "duplicate field", function(text) return text .. "sjlj=wasm-exnref\n" end, 'duplicate field "sjlj"' },
        { "missing field", function(text) return text:gsub("sjlj=wasm%-exnref\n", "") end, 'missing field "sjlj"' },
        { "banner", function(text) return text:gsub("record v2", "record v1") end, "invalid banner" },
        { "revision", function(text) return text:gsub("fork_revision=[^\n]*", "fork_revision=bad") end, 'invalid field "fork_revision"' },
        { "digest", function(text) return text:gsub("archive_sha256=[^\n]*", "archive_sha256=bad") end, 'invalid field "archive_sha256"' },
        { "UTF-8", function(text) return text .. "\255\n" end, "text encoding" },
    }) do
        it("rejects malformed record " .. case[1], function()
            local _, text = fixtures.record()
            local context, inputs = fake_context({ record_text = case[2](text) })
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor); contains(err, case[3])
            contains(err, LUA_REMEDY .. " PREFIX=" .. inputs.paths.root)
        end)
    end

    for _, key in ipairs({ "cflags", "lua_defines", "wasm_features" }) do
        for _, case in ipairs({
            { "leading space", function(value) return " " .. value end },
            { "trailing space", function(value) return value .. " " end },
            { "repeated spaces", function(value) return value:gsub(" ", "  ", 1) end },
            { "tab separator", function(value) return value:gsub(" ", "\t", 1) end },
            { "shell quoting", function(value) return "'" .. value .. "'" end },
        }) do
            it("rejects noncanonical " .. key .. " " .. case[1] .. " in records and transport", function()
                local record = fixtures.record()
                local changed = case[2](record[key])
                local context, inputs = fake_context({ record = { [key] = changed } })
                local descriptor, err = browser.build(context, inputs)
                assert.is_nil(descriptor)
                contains(err, 'invalid field "' .. key .. '": noncanonical list')
                contains(err, LUA_REMEDY .. " PREFIX=" .. inputs.paths.root)
                local data = fixtures.descriptor()
                data.lua.record[key] = changed
                fixtures.identify(data)
                descriptor, err = browser.import(data)
                assert.is_nil(descriptor)
                contains(err, 'invalid field "' .. key .. '": noncanonical list')
            end)
        end
    end

    for _, case in ipairs({
        { "wasi_sdk_version", "33.0" }, { "target", "wasm32-unknown-emscripten" },
        { "sjlj", "wasm" }, { "wasm_features", "+sign-ext" },
        { "numeric", "integer=int,float=float" },
        { "archive_sha256", string.rep("0", 64) }, { "headers_sha256", string.rep("0", 64) },
        { "lua_defines", "-DEXTRA -DLUA_USE_BROWSER -D_WASI_EMULATED_PROCESS_CLOCKS" },
    }) do
        it("identifies mismatched record field " .. case[1], function()
            local context, inputs = fake_context({ record = { [case[1]] = case[2] } })
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor); contains(err, "field " .. case[1] .. " mismatch")
            contains(err, "recorded"); contains(err, "expected"); contains(err, "fork_revision=")
            contains(err, LUA_REMEDY .. " PREFIX=" .. inputs.paths.root)
        end)
    end

    it("rejects host Lua configurations in browser Lua records and transport", function()
        local record = fixtures.record()
        local cases = {}
        for _, name in ipairs({ "POSIX", "DLOPEN", "LINUX", "MACOSX" }) do
            cases[#cases + 1] = { {
                lua_defines = "-DLUA_USE_BROWSER -DLUA_USE_" .. name .. " -D_WASI_EMULATED_PROCESS_CLOCKS",
                cflags = record.cflags .. " -DLUA_USE_" .. name,
            }, "LUA_USE_" .. name .. " is unavailable for browser Lua" }
        end
        cases[#cases + 1] = { { lua_defines = "-D_WASI_EMULATED_PROCESS_CLOCKS",
            cflags = (record.cflags:gsub(" %-DLUA_USE_BROWSER", "")) }, "requires LUA_USE_BROWSER" }
        for _, case in ipairs(cases) do
            local context, inputs = fake_context({ record = case[1] })
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            contains(err, 'is malformed: invalid field "lua_defines": ' .. case[2])
            contains(err, LUA_REMEDY .. " PREFIX=" .. inputs.paths.root)
            local data = fixtures.descriptor()
            data.lua.record = fixtures.record(case[1])
            fixtures.identify(data)
            descriptor, err = browser.import(data)
            assert.is_nil(descriptor)
            contains(err, 'invalid field "lua_defines": ' .. case[2])
        end
    end)

    it("keeps invalid record features distinct from user compile flags", function()
        local context, inputs = fake_context({ record = { wasm_features = "+sign-ext" } })
        inputs.compile_flags = { "-msimd128" }
        local descriptor, err = browser.build(context, inputs)
        assert.is_nil(descriptor)
        contains(err, "field wasm_features mismatch")
        contains(err, LUA_REMEDY .. " PREFIX=" .. inputs.paths.root)
        assert.is_nil(err:find("browser target compiler probe", 1, true))
    end)

    it("names user flags in a probed feature mismatch without blaming the record", function()
        local context, inputs = fake_context()
        inputs.compile_flags = { "-DUSER_FEATURE=1", "-msimd128" }
        staticmetadata.classify_object = function()
            local fingerprint = fixtures.fingerprint()
            fingerprint.features = fingerprint.features .. " +simd128"
            return { fingerprint = fingerprint }
        end
        local descriptor, err = browser.build(context, inputs)
        assert.is_nil(descriptor)
        contains(err, "browser target compiler probe")
        contains(err, "+simd128")
        contains(err, 'user compile flags: "-DUSER_FEATURE=1" "-msimd128"')
        contains(err, "remove feature-changing flags")
        contains(err, "TITAN_EXTRA_CPPFLAGS/TITAN_EXTRA_CFLAGS/--cflag")
        assert.is_nil(err:find("browser Lua record", 1, true))
        assert.is_nil(err:find(LUA_REMEDY, 1, true))
    end)

    it("attributes feature drift without user flags to the selected toolchain", function()
        local context, inputs = fake_context()
        staticmetadata.classify_object = function()
            local fingerprint = fixtures.fingerprint()
            fingerprint.features = fingerprint.features .. " +simd128"
            return { fingerprint = fingerprint }
        end
        local descriptor, err = browser.build(context, inputs)
        assert.is_nil(descriptor)
        contains(err, "browser target compiler probe")
        contains(err, "check the selected wasi-sdk 34.0 installation")
        assert.is_nil(err:find("user compile flags", 1, true))
        assert.is_nil(err:find("browser Lua record", 1, true))
        assert.is_nil(err:find("make install-browser", 1, true))
    end)

    for _, case in ipairs({ { "sjlj", "wasm" }, { "target", "wasm32-unknown-emscripten" },
            { "wasi_sdk_version", "33.0" } }) do
        it("prioritizes fixed field " .. case[1] .. " over conflicting cflags", function()
            local record = fixtures.record()
            local conflicting = record.cflags:gsub("legacy%-eh=false", "legacy-eh=true"):gsub("wasip1", "wasip2")
            local context, inputs = fake_context({ record = { [case[1]] = case[2], cflags = conflicting } })
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            contains(err, "field " .. case[1] .. " mismatch")
            contains(err, 'recorded "' .. case[2] .. '"')
            contains(err, "expected"); contains(err, "fork_revision=" .. record.fork_revision)
            local data = fixtures.descriptor()
            data.lua.record = fixtures.record({ [case[1]] = case[2], cflags = conflicting })
            fixtures.identify(data)
            descriptor, err = browser.import(data)
            assert.is_nil(descriptor)
            contains(err, "field " .. case[1] .. " mismatch")
        end)
    end

    it("verifies archive and header contents rather than trusting their record hashes", function()
        for _, change in ipairs({ { archive = "changed" }, { header = "changed" }, { missing_archive = true } }) do
            local context, inputs = fake_context(change)
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            contains(err, change.header and "headers_sha256" or "archive_sha256")
        end
    end)

    it("identifies unsupported effective Lua cflags", function()
        local _, _, _, _, record = fake_context()
        for _, flag in ipairs({ "-fPIC", "-flto", "-target wasm32-wasip1", "--sysroot=/elsewhere",
                "-mno-exception-handling", "-fwasm-exceptions", "-mllvm=-wasm-enable-sjlj",
                "-mexec-model=reactor", "-Xclang -target-feature", "--config=browser.cfg",
                "--config browser.cfg", "--config-user-dir=/home/user", "@browser.rsp" }) do
            local context, inputs = fake_context({ record = { cflags = record.cflags .. " " .. flag } })
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            contains(err, 'invalid field "cflags": browser target does not support cflags flag "' ..
                flag:match("^%S+") .. '"')
            contains(err, LUA_REMEDY .. " PREFIX=" .. inputs.paths.root)
        end
    end)

    it("diagnoses host-only flags including ambient LTO without using native defaults", function()
        for _, flag in ipairs({ "-fPIC", "-fpic", "-fPIE", "-fpie", "-pie", "-shared", "-dynamiclib",
                "-rdynamic", "-pthread", "-flto", "-flto=thin", "-ffat-lto-objects", "-march=native",
                "-mcpu=native", "-mtune=native", "-m32", "-m64", "-fwasm-exceptions",
                "-fno-wasm-exceptions", "-mexception-handling", "-mno-exception-handling",
                "-mlegacy-exception-handling", "-mno-legacy-exception-handling",
                "-mllvm", "-mllvm=-wasm-enable-sjlj", "-target", "--target=wasm32-wasip1",
                "--sysroot", "--sysroot=/usr", "-mexec-model=reactor", "-Xclang", "-Xclang=-mllvm",
                "--config", "--config=browser.cfg", "--config-system-dir=/etc/clang",
                "--config-user-dir=/home/user", "@browser.rsp", "@" }) do
            local ok, err = browser.validate_flags({ flag }, "TITAN_EXTRA_CFLAGS")
            assert.is_nil(ok); assert.equal('browser target does not support TITAN_EXTRA_CFLAGS flag "' .. flag .. '"', err)
        end
        assert(browser.validate_flags({ "-fno-lto", "-msimd128", "-DUSER=1", "-Wextra", "-Iinclude" }, "--cflag"))
        assert(browser.validate_flags(nil, "--cflag"))
        local shaped, shape_error = browser.validate_flags({ "-O2", [3] = "-g" }, "--cflag")
        assert.is_nil(shaped)
        assert.equal("invalid browser --cflag flags: expected a dense array of strings", shape_error)
        local subject = fresh_driver()
        subject.EXTRA_CFLAGS = { "-flto" }
        local context = { target = "browser", host_target = "linux" }
        local ok, err = subject._finish_target_initialization(context)
        assert.is_nil(ok); contains(err, 'TITAN_EXTRA_CFLAGS flag "-flto"')
        subject = fresh_driver()
        subject.EXTRA_CPPFLAGS = { "--sysroot=/usr" }
        ok, err = subject._finish_target_initialization({ target = "browser", host_target = "linux" })
        assert.is_nil(ok)
        assert.equal('browser target does not support TITAN_EXTRA_CPPFLAGS flag "--sysroot=/usr"', err)
    end)

    it("rejects every LTO spelling through CLI and ambient flag origins", function()
        for _, origin in ipairs({ "TITAN_EXTRA_CPPFLAGS", "TITAN_EXTRA_CFLAGS",
                "TITAN_EXTRA_LDFLAGS", "--cflag", "--ldflag", "compile_flags", "cflags" }) do
            for _, flag in ipairs({ "-flto", "-flto=full", "-flto=thin", "-ffat-lto-objects" }) do
                local ok, err = browser.validate_flags({ flag }, origin)
                assert.is_nil(ok)
                assert.equal("browser target does not support " .. origin ..
                    " flag " .. string.format("%q", flag), err)
            end
        end
        assert.is_true(browser.validate_flags({
            "-fno-lto", "-fsanitize=address", "-fsanitize=undefined", "-fsanitize=leak",
        }, "--cflag"))
    end)

    it("rejects every target-owned SJLJ, EH, target and sysroot setting through every flag origin", function()
        for _, origin in ipairs({ "TITAN_EXTRA_CPPFLAGS", "TITAN_EXTRA_CFLAGS", "TITAN_EXTRA_LDFLAGS",
                "--cflag", "--ldflag", "compile_flags", "cflags" }) do
            for _, flags in ipairs({
                { "-mllvm", "-wasm-enable-sjlj" }, { "-mllvm", "-wasm-enable-sjlj=false" },
                { "-mllvm", "-wasm-use-legacy-eh=false" }, { "-mllvm", "-wasm-use-legacy-eh=true" },
                { "-mllvm=-wasm-enable-sjlj" }, { "-mllvm=-wasm-use-legacy-eh=true" },
                { "-mexception-handling" }, { "-mno-exception-handling" },
                { "-mlegacy-exception-handling" }, { "-mno-legacy-exception-handling" },
                { "-fwasm-exceptions" }, { "-fno-wasm-exceptions" },
                { "--target=wasm32-wasip1" }, { "--target=wasm32-unknown-emscripten" },
                { "-target", "wasm32-wasip1" }, { "--sysroot=/elsewhere" }, { "--sysroot", "/elsewhere" },
                { "-mexec-model=command" }, { "-mexec-model=reactor" },
                { "-Xclang", "-mllvm" }, { "-Xclang", "-target-feature" }, { "-Xclang=-mllvm" },
                { "--config", "browser.cfg" }, { "--config=browser.cfg" },
                { "--config-system-dir=/etc/clang" }, { "--config-user-dir=/home/user" },
                { "@browser.rsp" }, { "@/tmp/flags" },
            }) do
                local ok, err = browser.validate_flags(flags, origin)
                assert.is_nil(ok)
                assert.equal("browser target does not support " .. origin ..
                    " flag " .. string.format("%q", flags[1]), err)
            end
            local ok, err = browser.validate_flags({ "-DUSER=1", "-mllvm", "-wasm-enable-sjlj" }, origin)
            assert.is_nil(ok)
            assert.equal("browser target does not support " .. origin .. ' flag "-mllvm"', err)
            -- Even the profile's own setjmp/longjmp selection is target-owned.
            ok, err = browser.validate_flags(fixtures.sjlj_flags, origin)
            assert.is_nil(ok)
            assert.equal("browser target does not support " .. origin .. ' flag "-mexception-handling"', err)
        end
    end)

    it("rejects missing or wrong effective record SJLJ lowering in builds and transport", function()
        local record = fixtures.record()
        local expected = 'field sjlj mismatch: recorded "wasm-exnref", expected "<missing in cflags>"'
        for _, cflags in ipairs({
            (record.cflags:gsub(" %-mexception%-handling", "")),
            (record.cflags:gsub(" %-mllvm %-wasm%-enable%-sjlj", "")),
            (record.cflags:gsub(" %-mllvm %-wasm%-use%-legacy%-eh=false", "")),
            (record.cflags:gsub("legacy%-eh=false", "legacy-eh=true")),
            (record.cflags:gsub("enable%-sjlj", "enable-eh")),
            record.cflags .. " -mllvm -wasm-enable-sjlj",
            record.cflags .. " -mllvm -wasm-enable-eh",
            record.cflags .. " -mllvm",
        }) do
            local context, inputs = fake_context({ record = { cflags = cflags } })
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            contains(err, expected)
            contains(err, LUA_REMEDY .. " PREFIX=" .. inputs.paths.root)
            local data = fixtures.descriptor()
            data.lua.record.cflags = cflags
            fixtures.identify(data)
            descriptor, err = browser.import(data)
            assert.is_nil(descriptor)
            contains(err, expected)
        end
    end)

    it("rejects a missing or different effective record target in builds and transport", function()
        local record = fixtures.record()
        for _, case in ipairs({
            { (record.cflags:gsub("%-%-target=wasm32%-wasip1 ", "")), "<missing in cflags>" },
            { (record.cflags:gsub("wasm32%-wasip1", "wasm32-wasip2")), "wasm32-wasip2" },
            { (record.cflags:gsub("wasm32%-wasip1", "wasm32-unknown-emscripten")), "wasm32-unknown-emscripten" },
            { record.cflags .. " --target=wasm32-wasip2", "wasm32-wasip2" },
        }) do
            local expected = 'field target mismatch: recorded "wasm32-wasip1", expected "' .. case[2] .. '"'
            local context, inputs = fake_context({ record = { cflags = case[1] } })
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            contains(err, expected)
            contains(err, LUA_REMEDY .. " PREFIX=" .. inputs.paths.root)
            local data = fixtures.descriptor()
            data.lua.record.cflags = case[1]
            fixtures.identify(data)
            descriptor, err = browser.import(data)
            assert.is_nil(descriptor)
            contains(err, expected)
        end
    end)

    it("accepts equivalent orderings of the record's target and SJLJ cflags", function()
        local record = fixtures.record()
        local sjlj = " %-mexception%-handling %-mllvm %-wasm%-enable%-sjlj %-mllvm %-wasm%-use%-legacy%-eh=false"
        local unselected = record.cflags:gsub("^%-%-target=wasm32%-wasip1 ", ""):gsub(sjlj, "")
        for _, cflags in ipairs({
            (record.cflags:gsub(sjlj, " -mllvm -wasm-use-legacy-eh=false -mllvm -wasm-enable-sjlj -mexception-handling")),
            unselected .. " -mllvm -wasm-enable-sjlj --target=wasm32-wasip1 -mexception-handling" ..
                " -mllvm -wasm-use-legacy-eh=false",
        }) do
            assert.not_equal(record.cflags, cflags)
            local context, inputs = fake_context({ record = { cflags = cflags } })
            local descriptor = assert(browser.build(context, inputs))
            assert.equal(cflags, descriptor.lua.record.cflags)
            local data = fixtures.descriptor()
            data.lua.record.cflags = cflags
            fixtures.identify(data)
            assert(browser.import(data))
        end
    end)

    it("validates foreign C flags before discovering only the compiler for analysis", function()
        local paths = fixtures.paths()
        for _, case in ipairs({
            { { "-mllvm", "-wasm-enable-sjlj" },
                'browser target does not support browser foreign C flags flag "-mllvm"' },
            { { "--sysroot=/elsewhere" },
                'browser target does not support browser foreign C flags flag "--sysroot=/elsewhere"' },
            { { "-O2" }, 'browser production profile owns compile option "-O2"' },
            { { "-gdwarf-5" }, 'browser production profile owns compile option "-gdwarf-5"' },
        }) do
            local context, _, calls = fake_context()
            local config, err = browser.analysis_toolchain(context,
                { target = { build_profile = "production" }, paths = paths }, paths.lua_source, case[1])
            assert.is_nil(config)
            assert.equal(case[2], err)
            assert.equal(0, #calls)
        end
        -- An analysis context compiles C but never links: it needs no wasm-opt.
        local context, _, calls, _, record = fake_context({ missing = "wasm-opt" })
        local config, err = browser.analysis_toolchain(context, { target = { build_profile = "production",
            lua = { headers_sha256 = record.headers_sha256 } }, paths = paths }, paths.lua_source)
        assert.is_nil(config)
        contains(err, "minicoro.h: matching Titan SDK header is required")
        assert.same({ version_query({ cc = { FAKE_ROOT .. "/wasi-sdk/bin/clang" .. tool_suffix() },
            sysroot = FAKE_ROOT .. "/wasi-sdk/share/wasi-sysroot" }) }, calls)
        context, _, calls = fake_context({ missing = "clang" })
        config, err = browser.analysis_toolchain(context,
            { target = { build_profile = "production" }, paths = paths }, paths.lua_source)
        assert.is_nil(config)
        assert.equal(string.format("browser target requires wasi-sdk 34.0: %q is not an executable (WASI_SDK_PATH=%q)",
            FAKE_ROOT .. "/wasi-sdk/bin/clang" .. tool_suffix(), FAKE_ROOT .. "/wasi-sdk") .. SDK_INSTALL, err)
        assert.equal(0, #calls)
    end)

    it("preserves native installed paths and exposes only browser sibling SDK paths", function()
        local subject = fresh_driver()
        local root = platform.windows and "C:/prefix" or "/prefix"
        local native = subject.installed_paths(root)
        for _, target in ipairs({ "linux", "darwin", "windows", "native" }) do
            assert.same(native, subject.installed_paths(root, target))
        end
        assert.same(fixtures.paths(root), subject.installed_paths(root, "browser"))
        assert.is_nil(subject.installed_paths(root, "browser").libbacktrace)
        assert.is_nil(subject.context_target_descriptor(nil))
        local context = subject.new_resolver_context({ target = "linux" })
        assert.is_nil(subject.context_target_descriptor(context))
        assert(subject.close_resolver_context(context))
    end)

    for _, origin in ipairs({ "CLI", "environment" }) do
        it("rejects disabled browser line directives from " .. origin .. " while leaving native policy optional", function()
            local getenv = platform.getenv
            platform.getenv = function(name)
                if name == "TITAN_NO_LINE_DIRECTIVES" then return origin == "environment" and "1" or "0" end
                return getenv(name)
            end
            local subject = fresh_driver()
            if origin == "CLI" then subject.EMIT_LINE_DIRECTIVES = false end
            assert.is_false(subject.EMIT_LINE_DIRECTIVES)
            local native = subject.new_resolver_context({ target = files.host() })
            assert.is_true(subject.initialize_platform(native))
            assert(subject.close_resolver_context(native))
            local line_error = "browser target owns option --no-line-directives (TITAN_NO_LINE_DIRECTIVES)"
            local ready, err = subject._finish_target_initialization({
                target = "browser", host_target = files.host(),
            })
            assert.is_nil(ready)
            assert.equal(line_error, err)
            local strategy = compiler_io.new_sync()
            local root, prefix = assert(strategy:cwd()), require("spec.support.installed_prefix").active()
            workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
            local argv = { prefix .. "/bin/lua" .. (platform.windows and ".exe" or ""), "-E", "-e",
                string.format("package.path=%q..package.path;", root .. "/?.lua;" .. root .. "/?/init.lua;"),
                root .. "/titanc", "-q", "--target", "browser", "-c", "-o", workspace .. "/out" }
            if origin == "CLI" then argv[#argv + 1] = "--no-line-directives" end
            argv[#argv + 1] = "never_compiled"
            local result = process.capture(argv, {
                env = { TITAN_ROOT = prefix, TITAN_TARGET = "", TITAN_EXTRA_CPPFLAGS = "",
                    TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "",
                    TITAN_NO_LINE_DIRECTIVES = origin == "environment" and "1" or "0" },
                stderr_to_stdout = true,
            })
            assert.is_true(result.started)
            assert.is_false(result.ok)
            assert.equal(1, result.status)
            contains(result.output, line_error)
            assert.is_nil(result.output:find("stack traceback", 1, true))
        end)
    end

    it("rejects an unlabeled browser host before tool discovery", function()
        local subject = fresh_driver()
        local ok, err = subject._finish_target_initialization({ target = "browser", host_target = "native" })
        assert.is_nil(ok)
        assert.equal("browser builds are supported from Linux, macOS and Windows hosts (host is native)", err)
    end)

    it("admits the browser target from Windows without admitting native cross-compilation", function()
        local subject = fresh_driver()
        local context = subject.new_resolver_context()
        context.uname, context.is_darwin = "Windows", false
        assert.equal("browser", subject.validate_target(context, "browser", "--target"))
        local target, err = subject.validate_target(context, "linux", "--target")
        assert.is_nil(target)
        contains(err, "native cross-compilation is not supported (host is windows)")
        assert(subject.close_resolver_context(context))
    end)
    it("builds once per context and keeps the browser probe namespace out of native globals", function()
        local getenv = platform.getenv
        platform.getenv = function(name)
            if name == "TITAN_PROBE_CACHE_DISABLE" then return nil end
            if name == "TITAN_PREFIX" then return FAKE_ROOT .. "/cache-prefix" end
            return getenv(name)
        end
        local subject = fresh_driver()
        subject.EXTRA_CPPFLAGS, subject.EXTRA_CFLAGS, subject.EXTRA_LDFLAGS = {}, {}, {}
        local template, inputs, calls = fake_context({ root = subject.TITAN_ROOT })
        local native_cache, cc, flags, ar, ranlib, profile = subject.PROBE_CACHE_DIRECTORY,
            subject.CC, subject.CFLAGS, subject.AR, subject.RANLIB, subject.TARGET_PROFILE
        local initialize = subject.initialize_platform
        subject.initialize_platform = function(ctx)
            if type(ctx) == "table" and ctx.io ~= nil and ctx._target_initializing then
                ctx._platform_initialized, ctx.uname, ctx.is_darwin = true, "Linux", false
            end
            return initialize(ctx)
        end
        assert.has_error(function() subject.initialize_platform() end,
            "platform initialization requires a resolver context")
        assert.has_error(function() subject.initialize_platform({}) end,
            "platform initialization requires a resolver context")
        local context = subject.new_resolver_context({ io = template.io, target = "browser" })
        local descriptor = assert(subject.context_target_descriptor(context))
        assert.equal(descriptor, subject.context_target_descriptor(context))
        assert.equal(3, #calls)
        assert.equal(FAKE_ROOT .. "/cache-prefix/var/cache/titan-probes/browser-34.0/" ..
            cprobe_cache.VERSION, descriptor.probe_cache_directory)
        assert.equal(native_cache, subject.PROBE_CACHE_DIRECTORY)
        assert.equal(cc, subject.CC); assert.equal(flags, subject.CFLAGS)
        assert.equal(ar, subject.AR); assert.equal(ranlib, subject.RANLIB)
        assert.equal(profile, subject.TARGET_PROFILE)
        local service = assert(subject.get_probe_service(context))
        local location, key = service:_cache_location("int same_raw_probe;")
        assert.equal(descriptor.probe_cache_directory .. "/" .. key .. ".result", location)
        assert.not_equal(native_cache .. "/" .. key .. ".result", location)
        assert.same({ inputs.paths.lua_source, inputs.paths.include },
            service:cdriver_process_options().compiler_include_dirs)
        assert(subject.close_resolver_context(context))
    end)

    it("ignores an unresolvable cache prefix while browser probe caching is disabled", function()
        local getenv = platform.getenv
        platform.getenv = function(name)
            if name == "TITAN_PROBE_CACHE_DISABLE" then return "1" end
            if name == "TITAN_PREFIX" then return "./disabled-cache-root" end
            return getenv(name)
        end
        local subject = fresh_driver()
        subject.EXTRA_CPPFLAGS, subject.EXTRA_CFLAGS, subject.EXTRA_LDFLAGS = {}, {}, {}
        local context = fake_context({ root = subject.TITAN_ROOT })
        context.target, context.host_target = "browser", "linux"
        context._platform_initialized, context.uname, context.is_darwin = true, "Linux", false
        function context.io:cwd() return nil, "disabled cache prefix must not request cwd" end
        assert(subject._finish_target_initialization(context))
        -- The fake context models an initialized supported host. Reentry must
        -- use that complete observation even when the actual host is Windows.
        local windows = platform.windows
        platform.windows = true
        local ok, descriptor, descriptor_error = pcall(subject.context_target_descriptor, context)
        platform.windows = windows
        assert.is_true(ok, descriptor)
        assert.truthy(descriptor, descriptor_error)
        assert.equal("linux", context.host_target)
        assert.is_nil(descriptor.probe_cache_directory)
        assert.is_nil(subject.PROBE_CACHE_DIRECTORY)
        assert(subject.close_resolver_context(context))
    end)

    it("rebuilds worker descriptor data without version queries or Lua record reads", function()
        local subject = fresh_driver()
        local strategy = compiler_io.new_sync()
        local runs = 0
        local guarded = setmetatable({}, { __index = strategy })
        function guarded:run() runs = runs + 1; error("worker must not reprobe tools") end
        function guarded:read_file(filename)
            assert.is_nil(filename:find("/lib/browser/", 1, true), "worker must not reread verified Lua inputs")
            return strategy:read_file(filename)
        end
        subject._browser_target = setmetatable({ build = function(_, inputs)
            return assert(browser.import(fixtures.descriptor(inputs.paths.root)))
        end }, { __index = browser })
        local initialize = subject.initialize_platform
        subject.initialize_platform = function(ctx)
            if type(ctx) == "table" and ctx.io ~= nil and ctx._target_initializing then
                ctx._platform_initialized, ctx.uname, ctx.is_darwin = true, "Linux", false
            end
            return initialize(ctx)
        end
        assert.has_error(function() subject.initialize_platform() end,
            "platform initialization requires a resolver context")
        assert.has_error(function() subject.initialize_platform({}) end,
            "platform initialization requires a resolver context")
        local context = subject.new_resolver_context({ io = guarded, target = "browser" })
        local driver_source = assert(debug.getinfo(subject.new_worker_context, "S").source:match("^@(.*)$"))
        local compiler_root = assert(strategy:realpath(path.dirname(path.dirname(driver_source))))
        context.incremental_configuration = {
            compiler = assert(incremental.compiler_component(context, {
                compiler_root = compiler_root, frontend = "api" })),
            digest = string.rep("1", 64), toolchain = string.rep("2", 64),
            preamble = string.rep("3", 64), options = string.rep("4", 64),
        }
        local wire = assert(subject.worker_configuration(context))
        assert.is_nil(getmetatable(wire.target_descriptor))
        local worker = assert(subject.new_worker_context(wire, guarded))
        assert.equal(context.target_descriptor.identity, worker.target_descriptor.identity)
        assert.same(wire.target_descriptor, browser.export(worker.target_descriptor))
        assert.equal(0, runs)
        assert.equal(context.incremental_configuration, worker.incremental_configuration)
        assert(subject.close_resolver_context(worker))
        assert(subject.close_resolver_context(context))
        wire.compiler = string.rep("0", 64)
        wire.configuration.compiler = wire.compiler
        local rejected, err = subject.new_worker_context(wire, guarded)
        assert.is_nil(rejected); assert.equal("compiler installation changed during build", err)
        assert.equal(0, runs)
        wire.resolver.target = "linux"
        rejected, err = subject.new_worker_context(wire, guarded)
        assert.is_nil(rejected); assert.equal("incompatible build worker configuration", err)
    end)
    it("never reuses an identical native probe source from the browser cache directory", function()
        local context, _, calls, contents = fake_context()
        local source = "int identical_raw_probe_source;"
        local native_path = FAKE_ROOT .. "/probes/" .. cprobe_cache.VERSION
        local browser_path = FAKE_ROOT .. "/probes/browser-34.0/" .. cprobe_cache.VERSION
        local function service(directory)
            return assert(cprobe.new_service({ io = context.io, profile = fixtures.profile(),
                toolchain = { compiler_argv = { "fake-compiler" }, compile_flags = {},
                    include_dirs = {}, profile = fixtures.profile() }, cache_directory = directory }))
        end
        local native = service(native_path)
        local first = native:_run_source("baseline", source)
        assert.equal("success", first.classification, first.diagnostic)
        local before = #calls
        local browser_service = service(browser_path)
        local second = browser_service:_run_source("baseline", source)
        assert.equal("success", second.classification, second.diagnostic)
        assert.equal(before + 1, #calls)
        browser_service:_run_source("baseline", source)
        assert.equal(before + 1, #calls)
        local key = browser_service:_digest(source)
        assert.is_string(contents[native_path .. "/" .. key .. ".result"])
        assert.is_string(contents[browser_path .. "/" .. key .. ".result"])
        assert(native:close()); assert(browser_service:close())
    end)
    it("raises a constructor's descriptor diagnostic without activating a failed target", function()
        local subject = fresh_driver()
        local native = subject.new_resolver_context({ target = "linux" })
        local retained = {}
        subject.imported.retained = retained
        subject._browser_target = setmetatable({ build = function()
            return nil, "browser Lua record fixture: sjlj mismatch"
        end }, { __index = browser })
        local initialize = subject.initialize_platform
        subject.initialize_platform = function(ctx)
            if type(ctx) == "table" and ctx.io ~= nil and ctx._target_initializing then
                ctx._platform_initialized, ctx.uname, ctx.is_darwin = true, "Linux", false
            end
            return initialize(ctx)
        end
        assert.has_error(function() subject.initialize_platform() end,
            "platform initialization requires a resolver context")
        assert.has_error(function() subject.initialize_platform({}) end,
            "platform initialization requires a resolver context")
        local template = fake_context({ root = subject.TITAN_ROOT })
        assert.has_error(function()
            subject.new_resolver_context({ io = template.io, target = "browser" })
        end, "browser Lua record fixture: sjlj mismatch")
        assert(subject.assert_target_context(native))
        assert.equal(retained, subject.imported.retained)
        assert(subject.close_resolver_context(native))
    end)

    it("reports constructor raises through the normal CLI diagnostic without a traceback", function()
        local strategy = compiler_io.new_sync()
        local root = assert(strategy:cwd())
        local prefix = require("spec.support.installed_prefix").active()
        local code = string.format("package.path=%q..package.path; ", root .. "/?.lua;" .. root .. "/?/init.lua;") ..
            "require('titan-compiler.driver').new_resolver_context=function() error('browser descriptor fixture failure',0) end"
        local result = process.capture({ prefix .. "/bin/lua" .. (platform.windows and ".exe" or ""),
            "-E", "-e", code, root .. "/titanc", "-q", "-c", "never_compiled" },
            { env = { TITAN_ROOT = prefix, TITAN_TARGET = "", TITAN_EXTRA_CPPFLAGS = "",
                TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "" }, stderr_to_stdout = true })
        assert.is_true(result.started)
        assert.is_false(result.ok)
        assert.equal(1, result.status)
        contains(result.output, "browser descriptor fixture failure")
        assert.is_nil(result.output:find("stack traceback", 1, true))
    end)

    for _, selection in ipairs({ "CLI", "environment" }) do
        for _, mode in ipairs({ "objects", "library", "tests", "C-only" }) do
            it("rejects browser coverage before tool discovery for " ..
                selection .. " selection in " .. mode .. " mode", function()
                workspace = temporary.name()
                assert(os.remove(workspace))
                files.mkdir(workspace)
                local strategy = compiler_io.new_sync()
                local root = assert(strategy:cwd())
                local prefix = require("spec.support.installed_prefix").active()
                local code = string.format("package.path=%q..package.path; ",
                    root .. "/?.lua;" .. root .. "/?/init.lua;") .. [[
require("titan-compiler.browsertarget").build = function()
    error("browser tool discovery must not run", 0)
end
require("titan-compiler.coverage").prepare = function()
    error("native coverage preparation must not run", 0)
end
]]
                local argv = { prefix .. "/bin/lua" .. (platform.windows and ".exe" or ""),
                    "-E", "-e", code, root .. "/titanc", "-q", "--coverage",
                    "--coverage-backend=llvm-gcov", "--output", workspace .. "/out" }
                if selection == "CLI" then
                    argv[#argv + 1] = "--target=browser"
                end
                if mode == "objects" or mode == "C-only" then
                    argv[#argv + 1] = "-c"
                elseif mode == "tests" then
                    argv[#argv + 1] = "--test"
                end
                if mode == "C-only" then
                    argv[#argv + 1] = "--c-source"
                    argv[#argv + 1] = workspace .. "/never_compiled.c"
                else
                    argv[#argv + 1] = "never_compiled"
                end
                local result = process.capture(argv, {
                    env = { TITAN_ROOT = prefix,
                        TITAN_TARGET = selection == "environment" and "browser" or "",
                        TITAN_EXTRA_CPPFLAGS = "", TITAN_EXTRA_CFLAGS = "",
                        TITAN_EXTRA_LDFLAGS = "" },
                    stderr_to_stdout = true,
                })
                assert.is_true(result.started)
                assert.is_false(result.ok)
                assert.equal(1, result.status)
                contains(result.output, "--coverage is not supported for --target browser")
                assert.is_nil(result.output:find("must not run", 1, true))
                assert.is_nil(result.output:find("stack traceback", 1, true))
                assert.is_nil(lfs.attributes(workspace .. "/out/.titan-target"))
                assert.is_nil(lfs.attributes(workspace .. "/out/never_compiled.c"))
                assert.is_nil(lfs.attributes(workspace .. "/out/never_compiled.o"))
            end)
        end
    end

    it("exposes a 2 MiB native coroutine stack and a 256 KiB browser linear stack", function()
        local strategy = compiler_io.new_sync()
        local root = assert(strategy:cwd())
        local prefix = require("spec.support.installed_prefix").active()
        local runtime_dir = root .. "/titan-runtime"
        local lua_dir = prefix .. "/src/lua-5.5.1"
        if not strategy:stat(lua_dir .. "/lua.h") then lua_dir = root .. "/lua-5.5.1/src" end
        local profile = fixtures.profile()
        local native_types, native_err = cdriver.process_file("titan.h", {
            compiler_include_dirs = { lua_dir, runtime_dir },
            cppflags = {},
        })
        assert.truthy(native_types, native_err)
        local native_stack = assert(csemantics.evaluate_macro_expression(
            profile, native_types.TITAN_COROUTINE_STACK_SIZE.macro_expression))
        assert.equal(2 * 1024 * 1024, tonumber(native_stack.value))

        local browser_types, browser_err = cdriver.process_file("titan.h", {
            compiler_include_dirs = { lua_dir, runtime_dir },
            cppflags = { table.unpack(fixtures.target_defines) },
        })
        assert.truthy(browser_types, browser_err)
        local browser_stack = assert(csemantics.evaluate_macro_expression(
            profile, browser_types.TITAN_COROUTINE_STACK_SIZE.macro_expression))
        assert.equal(262144, tonumber(browser_stack.value))

        assert.is_nil(browser_types.MCO_DEFAULT_STACK_SIZE)
        assert.is_nil(browser_types.MCO_MIN_STACK_SIZE)
        local mco_source = assert(strategy:read_file(runtime_dir .. "/minicoro.h"))
        contains(mco_source, "#ifndef MCO_MIN_STACK_SIZE\n#define MCO_MIN_STACK_SIZE 32768")

        local coro_source = assert(strategy:read_file(root .. "/titan/coroutine.titan"))
        contains(coro_source, 'foreign import "titan.h"')
        contains(coro_source, "ffi.TITAN_COROUTINE_STACK_SIZE")
        assert.is_nil(coro_source:find("local STACK_SIZE =", 1, true))
    end)

    it("shares the native codec depth policy and has no target JSON writer cap", function()
        local strategy = compiler_io.new_sync()
        local root = assert(strategy:cwd())
        local prefix = require("spec.support.installed_prefix").active()
        local runtime_dir = root .. "/titan-runtime"
        local lua_dir = prefix .. "/src/lua-5.5.1"
        if not strategy:stat(lua_dir .. "/lua.h") then lua_dir = root .. "/lua-5.5.1/src" end
        local profile = fixtures.profile()
        for _, browser in ipairs({ false, true }) do
            local flags = browser and { table.unpack(fixtures.target_defines) } or {}
            local types, err = cdriver.process_file("transfer.h", {
                compiler_include_dirs = { lua_dir, runtime_dir }, cppflags = flags,
            })
            assert.truthy(types, err)
            local limit = assert(csemantics.evaluate_macro_expression(
                profile, types.TITAN_CODEC_DEPTH_LIMIT.macro_expression))
            assert.equal(128, tonumber(limit.value))
            local runtime = assert(cdriver.process_file("titan.h", {
                compiler_include_dirs = { lua_dir, runtime_dir }, cppflags = flags,
            }))
            assert.is_nil(runtime.TITAN_JSON_WRITER_DEPTH_LIMIT)
        end
    end)
end)

describe("browser real-toolchain pending policy", function()
    it("returns a reason to the test body and raises only in the explicit strict lane", function()
        local detect, getenv = gate.detect, os.getenv
        local ok, err = pcall(function()
            gate.detect = function() return nil, "missing fixture tool" end
            os.getenv = function(name) if name == "TITAN_REQUIRE_BROWSER_TOOLCHAIN" then return nil end; return getenv(name) end
            local info, why = gate.require()
            assert.is_nil(info); contains(why, "missing fixture tool")
            os.getenv = function(name) if name == "TITAN_REQUIRE_BROWSER_TOOLCHAIN" then return "1" end; return getenv(name) end
            assert.has_error(function() gate.require() end, "browser toolchain unavailable: missing fixture tool")
        end)
        gate.detect, os.getenv = detect, getenv
        assert.is_true(ok, err)
    end)
end)
