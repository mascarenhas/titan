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
local FAKE_ROOT = platform.windows and "C:/fake" or "/fake"

local function fresh_driver()
    local saved = package.loaded["titan-compiler.driver"]
    package.loaded["titan-compiler.driver"] = nil
    local subject = require "titan-compiler.driver"
    package.loaded["titan-compiler.driver"] = saved
    return subject
end

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
    local directory = FAKE_ROOT .. "/emsdk/upstream/emscripten"
    for _, tool in ipairs({ "emcc", "emar", "emranlib" }) do files[key(directory .. "/" .. tool)] = "fake launcher" end
    if options.missing then files[key(directory .. "/" .. options.missing)] = nil end
    if options.missing_record then files[key(paths.lua_record)] = nil end
    if options.missing_archive then files[key(paths.liblua)] = nil end
    local calls, serial = {}, 0
    local directories = { [key(paths.lua_source)] = true }
    local strategy = setmetatable({}, { __index = compiler_io.new_sync() })
    function strategy:cwd() return FAKE_ROOT end
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
    function strategy:tmpname() serial = serial + 1; return FAKE_ROOT .. "/probe-" .. serial end
    function strategy:run(argv)
        calls[#calls + 1] = { table.unpack(argv) }
        if argv[1] == "uname" then return { started = true, ok = true, output = options.uname or "Linux\n" } end
        if argv[#argv] == "--version" then
            return { started = true, ok = true, output = "emcc (Emscripten) " .. (options.version or "6.0.13") .. "\n" }
        end
        for index, flag in ipairs(argv) do
            if flag == "-o" then files[key(argv[index + 1])] = "fake relocatable Wasm object" end
        end
        return { started = true, ok = true, output = "", why = "exit", status = 0 }
    end
    return { io = strategy, extra_ffi_include_dirs = {} },
        { paths = paths, runtime_include = paths.include,
            build_profile = options.build_profile or "validation",
            probe_cache_directory = FAKE_ROOT .. "/probes/browser-6.0.13/" .. cprobe_cache.VERSION },
        calls, files, record
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
    local saved_getenv, saved_profile, saved_classify, saved_registry
    local workspace
    before_each(function()
        saved_registry = types.registry
        saved_getenv, saved_profile, saved_classify = platform.getenv,
            cdriver.target_profile_inputs, staticmetadata.classify_object
        platform.getenv = function(name)
            if name == "EMSDK" then return FAKE_ROOT .. "/emsdk" end
            if name == "PATH" then return FAKE_ROOT .. "/emsdk/upstream/emscripten" end
            return saved_getenv(name)
        end
        cdriver.target_profile_inputs = function() return fixtures.profile_inputs() end
        staticmetadata.classify_object = function() return { fingerprint = fixtures.fingerprint() } end
    end)
    after_each(function()
        platform.getenv, cdriver.target_profile_inputs, staticmetadata.classify_object =
            saved_getenv, saved_profile, saved_classify
        types.registry = saved_registry
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

    it("builds a verified closed descriptor, retains all record facts, and freezes every level", function()
        local context, inputs, calls = fake_context()
        local descriptor = assert(browser.build(context, inputs))
        assert.equal("browser", descriptor.label)
        assert.equal("6.0.13", descriptor.tools.version)
        assert.equal("EMSDK", descriptor.tools.source)
        assert.same({ inputs.paths.lua_source, inputs.paths.include }, browser.export(descriptor.include_dirs))
        assert.equal("integer=long long,float=double", descriptor.lua.record.numeric)
        assert.equal(32, descriptor.profile_data.integers.long.bits)
        assert.equal(64, descriptor.profile_data.integers["long long"].bits)
        assert.equal(fixtures.features, descriptor.fingerprint.features)
        assert.has_error(function() descriptor.label = "linux" end, "browser target descriptor is immutable")
        assert.has_error(function() descriptor.extra = true end, "browser target descriptor is immutable")
        assert.has_error(function() descriptor.tools.cc[1] = "cc" end, "browser target descriptor is immutable")
        assert.has_error(function() descriptor.lua.record.sjlj = "emscripten" end, "browser target descriptor is immutable")
        assert.has_error(function() table.insert(descriptor.compile_flags, "-flto") end,
            "browser target descriptor is immutable")
        assert.equal(2, #calls)
        assert.same({ "env", "EMCC_CFLAGS=", descriptor.tools.cc[1], "--version" }, calls[1])
        local flags = table.concat(calls[2], " ")
        contains(flags, "-c")
        contains(flags, "-sSUPPORT_LONGJMP=wasm")
        contains(flags, "-sWASM_LEGACY_EXCEPTIONS=1")
        contains(flags, "-DTITAN_TARGET_BROWSER=1")
        contains(flags, "-DTITAN_COROUTINE_STACK_SIZE=262144")
        assert.same(fixtures.target_defines, browser.export(descriptor.target_defines))
        assert.is_nil(flags:find("-fPIC", 1, true))
        assert.is_nil(flags:find("-flto", 1, true))
    end)

    it("round-trips transport data without running tools or reading the record", function()
        local context, inputs, calls = fake_context()
        local descriptor = assert(browser.build(context, inputs))
        local data = browser.export(descriptor)
        assert.is_nil(getmetatable(data))
        local rebuilt = assert(browser.import(data))
        assert.same(data, browser.export(rebuilt))
        assert.equal(descriptor.identity, rebuilt.identity)
        assert.equal(2, #calls)
        data.compile_flags[1] = "changed after import"
        assert.equal("--std=c99", rebuilt.compile_flags[1])
        assert.is_nil(browser.import(data))
    end)

    it("rejects unknown, cyclic and executable transport fields", function()
        for _, change in ipairs({
            function(data) data.unknown = true end,
            function(data) data.tools.execute = function() end end,
            function(data) data.paths.root = data end,
            function(data) data.lua.record.sjlj = "emscripten"; fixtures.identify(data) end,
        }) do
            local data = fixtures.descriptor()
            change(data)
            assert.is_nil(browser.import(data))
        end
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
        { "missing longjmp mode", function(data) remove_flag(data, "-sSUPPORT_LONGJMP=wasm") end },
        { "missing legacy EH encoding", function(data) remove_flag(data, "-sWASM_LEGACY_EXCEPTIONS=1") end },
        { "LTO flag", function(data) data.compile_flags[#data.compile_flags + 1] = "-flto" end },
        { "PIC flag", function(data) data.compile_flags[#data.compile_flags + 1] = "-fPIC" end },
        { "split conflicting longjmp flag", function(data)
            data.compile_flags[#data.compile_flags + 1] = "-s"
            data.compile_flags[#data.compile_flags + 1] = "SUPPORT_LONGJMP=emscripten"
        end },
        { "split conflicting EH encoding", function(data)
            data.compile_flags[#data.compile_flags + 1] = "-s"
            data.compile_flags[#data.compile_flags + 1] = "WASM_LEGACY_EXCEPTIONS=0"
        end },
        { "sparse flags", function(data) data.compile_flags[2] = nil end },
        { "relative tool location", function(data) data.tools.location = "./emscripten" end },
        { "unnormalized tool location", function(data) data.tools.location = data.tools.location .. "/." end },
        { "unnormalized tool argv", function(data)
            data.tools.cc[1] = data.tools.location .. "/./emcc"
        end },
        { "tool outside its installation", function(data)
            data.tools.ar[1] = data.tools.location .. "/other/emar"
        end },
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
                if platform.windows then pending("POSIX symlink-parent include lookup"); return end
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
            if platform.windows then pending("POSIX filesystem-aware root resolution"); return end
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
            { "-fPIC" }, { "-flto" }, { "-s", "SUPPORT_LONGJMP=emscripten" },
            { "-s", "WASM_LEGACY_EXCEPTIONS=0" },
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
        "-O0", "-O3", "-Os", "-g", "-g0", "-g2", "-gline-tables-only",
        "-finline-functions", "-fno-inline", "-fno-inline-functions",
        "-foptimize-sibling-calls", "-fno-optimize-sibling-calls",
        "-fomit-frame-pointer", "-fno-omit-frame-pointer",
        "-sBINARYEN_EXTRA_PASSES=--coalesce-locals", "-sBINARYEN_EXTRA_PASSES",
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

    it("rejects the two-token Binaryen extras spelling naming the profile", function()
        local context, inputs, calls = fake_context()
        inputs.build_profile = "production"
        inputs.compile_flags = { "-s", "BINARYEN_EXTRA_PASSES=--coalesce-locals" }
        local descriptor, err = browser.build(context, inputs)
        assert.is_nil(descriptor)
        assert.equal('browser production profile owns compile option "-s BINARYEN_EXTRA_PASSES=--coalesce-locals"', err)
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
            "-gline-tables-only", "-sSUPPORT_LONGJMP=wasm", "-sWASM_LEGACY_EXCEPTIONS=1",
            "-DLUA_USE_BROWSER", "-DLUA_USE_POSIX", table.unpack(fixtures.target_defines),
        }, descriptor.compile_flags)
        assert.is_true(#calls > 0, "the production build never probed its toolchain")
        -- The same inputs under the validation profile produce #330's frozen set.
        local validation = assert(browser.build(fake_context()))
        assert.same({
            "--std=c99", "-O1", "-fno-inline", "-fno-optimize-sibling-calls",
            "-Wall", "-Wno-unused-but-set-variable", "-Wno-unused-function",
            "-gline-tables-only", "-sSUPPORT_LONGJMP=wasm", "-sWASM_LEGACY_EXCEPTIONS=1",
            "-DLUA_USE_BROWSER", "-DLUA_USE_POSIX", table.unpack(fixtures.target_defines),
        }, validation.compile_flags)
        assert.not_equal(descriptor.identity, validation.identity)
    end)

    it("refuses every spelling of the owned pass list before tool discovery", function()
        for _, extras in ipairs({
            { "-s", "BINARYEN_EXTRA_PASSES" },
            { "-s", "BINARYEN_EXTRA_PASSES=--coalesce-locals" },
            { "-sBINARYEN_EXTRA_PASSES" },
            { "-sBINARYEN_EXTRA_PASSES=--coalesce-locals" },
            { "-sNO_BINARYEN_EXTRA_PASSES=1" },
            { "-s", "NO_BINARYEN_EXTRA_PASSES=1" },
        }) do
            local context, inputs, calls = fake_context()
            inputs.compile_flags = extras
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            local expected = extras[1]
            if extras[1] == "-s" then expected = "-s " .. extras[2] end
            assert.equal('browser validation profile owns compile option "' .. expected .. '"', err)
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
        for _, flag in ipairs({ "-O2", "-g2", "-fno-inline", "-foptimize-sibling-calls",
            "-sBINARYEN_EXTRA_PASSES=--coalesce-locals" }) do
            local data = fixtures.descriptor()
            data.compile_flags[#data.compile_flags + 1] = flag
            fixtures.identify(data)
            local imported, err = browser.import(data)
            assert.is_nil(imported)
            assert.equal('browser validation profile owns compile option "' .. flag .. '"', err)
        end
    end)

    for _, case in ipairs({
        { "missing emcc", { missing = "emcc" }, "emcc not found at" },
        { "wrong emcc", { version = "6.0.12" }, "reports 6.0.12" },
        { "missing emar", { missing = "emar" }, "emar not found at" },
        { "missing emranlib", { missing = "emranlib" }, "emranlib not found at" },
    }) do
        it("diagnoses " .. case[1] .. " with location and install instructions", function()
            local context, inputs = fake_context(case[2])
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            contains(err, case[3]); contains(err, "/fake/emsdk/upstream/emscripten/")
            contains(err, "emsdk install 6.0.13 && emsdk activate 6.0.13")
        end)
    end

    it("searches PATH only when EMSDK is absent and diagnoses an empty search", function()
        platform.getenv = function(name)
            if name == "EMSDK" then return nil end
            if name == "PATH" then return FAKE_ROOT .. "/emsdk/upstream/emscripten" end
            return saved_getenv(name)
        end
        local context, inputs = fake_context()
        assert.equal("PATH", assert(browser.build(context, inputs)).tools.source)
        platform.getenv = function(name) if name == "PATH" or name == "EMSDK" then return nil end; return saved_getenv(name) end
        local _, err = browser.build(context, inputs)
        contains(err, "emcc not found (EMSDK unset; not on PATH)")
    end)

    it("diagnoses a missing record with the fork install command", function()
        local context, inputs = fake_context({ missing_record = true })
        local descriptor, err = browser.build(context, inputs)
        assert.is_nil(descriptor)
        contains(err, "is unavailable"); contains(err, "make install-browser PREFIX=" .. inputs.paths.root)
    end)

    for _, case in ipairs({
        { "unknown field", function(text) return text .. "unknown=yes\n" end, 'unknown field "unknown"' },
        { "duplicate field", function(text) return text .. "sjlj=wasm\n" end, 'duplicate field "sjlj"' },
        { "missing field", function(text) return text:gsub("sjlj=wasm\n", "") end, 'missing field "sjlj"' },
        { "banner", function(text) return text:gsub("record v1", "record v0") end, "invalid banner" },
        { "revision", function(text) return text:gsub("fork_revision=[^\n]*", "fork_revision=bad") end, 'invalid field "fork_revision"' },
        { "digest", function(text) return text:gsub("archive_sha256=[^\n]*", "archive_sha256=bad") end, 'invalid field "archive_sha256"' },
        { "UTF-8", function(text) return text .. "\255\n" end, "text encoding" },
    }) do
        it("rejects malformed record " .. case[1], function()
            local _, text = fixtures.record()
            local context, inputs = fake_context({ record_text = case[2](text) })
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor); contains(err, case[3])
            contains(err, "make install-browser PREFIX=" .. inputs.paths.root)
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
                contains(err, "make install-browser PREFIX=" .. inputs.paths.root)
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
        { "emscripten_version", "6.0.12" }, { "target", "wasm64-unknown-emscripten" },
        { "sjlj", "emscripten" }, { "wasm_features", "+sign-ext" },
        { "numeric", "integer=int,float=float" },
        { "archive_sha256", string.rep("0", 64) }, { "headers_sha256", string.rep("0", 64) },
        { "lua_defines", "-DLUA_USE_POSIX" },
    }) do
        it("identifies mismatched record field " .. case[1], function()
            local context, inputs = fake_context({ record = { [case[1]] = case[2] } })
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor); contains(err, "field " .. case[1] .. " mismatch")
            contains(err, "recorded"); contains(err, "expected"); contains(err, "fork_revision=")
            contains(err, "make install-browser PREFIX=" .. inputs.paths.root)
        end)
    end

    it("keeps invalid record features distinct from user compile flags", function()
        local context, inputs = fake_context({ record = { wasm_features = "+sign-ext" } })
        inputs.compile_flags = { "-msimd128" }
        local descriptor, err = browser.build(context, inputs)
        assert.is_nil(descriptor)
        contains(err, "field wasm_features mismatch")
        contains(err, "make install-browser PREFIX=" .. inputs.paths.root)
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
        assert.is_nil(err:find("make install-browser", 1, true))
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
        contains(err, "check the selected Emscripten 6.0.13 installation")
        assert.is_nil(err:find("user compile flags", 1, true))
        assert.is_nil(err:find("browser Lua record", 1, true))
        assert.is_nil(err:find("make install-browser", 1, true))
    end)

    for _, case in ipairs({ { "sjlj", "emscripten" }, { "target", "wasm64-unknown-emscripten" },
            { "emscripten_version", "6.0.12" } }) do
        it("prioritizes fixed field " .. case[1] .. " over conflicting cflags", function()
            local record = fixtures.record()
            local context, inputs = fake_context({ record = {
                [case[1]] = case[2],
                cflags = record.cflags:gsub("SUPPORT_LONGJMP=wasm", "SUPPORT_LONGJMP=emscripten"),
            } })
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            contains(err, "field " .. case[1] .. " mismatch")
            contains(err, 'recorded "' .. case[2] .. '"')
            contains(err, "expected"); contains(err, "fork_revision=" .. record.fork_revision)
            local data = fixtures.descriptor()
            data.lua.record = fixtures.record({
                [case[1]] = case[2],
                cflags = record.cflags:gsub("SUPPORT_LONGJMP=wasm", "SUPPORT_LONGJMP=emscripten"),
            })
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
        local context, inputs = fake_context({ record = { cflags = record.cflags .. " -fPIC" } })
        local descriptor, err = browser.build(context, inputs)
        assert.is_nil(descriptor); contains(err, 'invalid field "cflags"')
        contains(err, "make install-browser PREFIX=" .. inputs.paths.root)
    end)

    it("diagnoses host-only flags including ambient LTO without using native defaults", function()
        for _, flag in ipairs({ "-fPIC", "-fpic", "-fPIE", "-fpie", "-pie", "-shared", "-dynamiclib",
                "-rdynamic", "-pthread", "-flto", "-flto=thin", "-ffat-lto-objects", "-march=native",
                "-mcpu=native", "-mtune=native", "-m32", "-m64", "-fwasm-exceptions",
                "-fno-wasm-exceptions", "-mexception-handling", "-mno-exception-handling",
                "-mlegacy-exception-handling", "-mno-legacy-exception-handling",
                "-sSUPPORT_LONGJMP=emscripten" }) do
            local ok, err = browser.validate_flags({ flag }, "TITAN_EXTRA_CFLAGS")
            assert.is_nil(ok); assert.equal('browser target does not support TITAN_EXTRA_CFLAGS flag "' .. flag .. '"', err)
        end
        assert(browser.validate_flags({ "-fno-lto", "-sSUPPORT_LONGJMP=wasm",
            "-sWASM_LEGACY_EXCEPTIONS=1" }, "--cflag"))
        local subject = fresh_driver()
        subject.EXTRA_CFLAGS = { "-flto" }
        local context = { target = "browser", host_target = "linux" }
        local ok, err = subject._finish_target_initialization(context)
        assert.is_nil(ok); contains(err, 'TITAN_EXTRA_CFLAGS flag "-flto"')
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

    it("rejects every conflicting SJLJ and EH setting through every flag origin", function()
        for _, origin in ipairs({ "TITAN_EXTRA_CPPFLAGS", "TITAN_EXTRA_CFLAGS", "TITAN_EXTRA_LDFLAGS",
                "--cflag", "--ldflag", "compile_flags", "cflags" }) do
            for _, setting in ipairs({ "SUPPORT_LONGJMP=emscripten", "SUPPORT_LONGJMP=0",
                    "SUPPORT_LONGJMP=1", "SUPPORT_LONGJMP", "NO_SUPPORT_LONGJMP",
                    "NO_SUPPORT_LONGJMP=0", "NO_SUPPORT_LONGJMP=1",
                    "WASM_LEGACY_EXCEPTIONS=0", "NO_WASM_LEGACY_EXCEPTIONS",
                    "NO_WASM_LEGACY_EXCEPTIONS=1" }) do
                for _, flags in ipairs({ { "-s" .. setting }, { "-s", setting } }) do
                    local ok, err = browser.validate_flags(flags, origin)
                    assert.is_nil(ok)
                    assert.equal("browser target does not support " .. origin ..
                        " flag " .. string.format("%q", table.concat(flags, " ")), err)
                end
            end
        end
        assert(browser.validate_flags({ "-sSUPPORT_LONGJMP=wasm", "-s", "SUPPORT_LONGJMP=wasm",
            "-sWASM_LEGACY_EXCEPTIONS", "-s", "WASM_LEGACY_EXCEPTIONS=1",
            "-sNO_WASM_LEGACY_EXCEPTIONS=0", "-s", "NO_WASM_LEGACY_EXCEPTIONS=0" }, "--cflag"))
    end)

    it("rejects missing or wrong effective record EH encoding in builds and transport", function()
        local record = fixtures.record()
        local without = record.cflags:gsub(" %-sWASM_LEGACY_EXCEPTIONS=1", "")
        for _, cflags in ipairs({ without, record.cflags .. " -sWASM_LEGACY_EXCEPTIONS=0",
                record.cflags .. " -s NO_WASM_LEGACY_EXCEPTIONS",
                record.cflags .. " -s NO_WASM_LEGACY_EXCEPTIONS=1" }) do
            local context, inputs = fake_context({ record = { cflags = cflags } })
            local descriptor, err = browser.build(context, inputs)
            assert.is_nil(descriptor)
            contains(err, "required -sWASM_LEGACY_EXCEPTIONS=1")
            contains(err, "make install-browser PREFIX=" .. inputs.paths.root)
            local data = fixtures.descriptor()
            data.lua.record.cflags = cflags
            fixtures.identify(data)
            descriptor, err = browser.import(data)
            assert.is_nil(descriptor)
            contains(err, "required -sWASM_LEGACY_EXCEPTIONS=1")
        end
    end)

    it("accepts the explicit equivalent legacy EH record spellings", function()
        local record = fixtures.record()
        for _, setting in ipairs({ "-sWASM_LEGACY_EXCEPTIONS", "-s WASM_LEGACY_EXCEPTIONS=1",
                "-sNO_WASM_LEGACY_EXCEPTIONS=0", "-s NO_WASM_LEGACY_EXCEPTIONS=0" }) do
            local cflags = record.cflags:gsub("%-sWASM_LEGACY_EXCEPTIONS=1", setting)
            local context, inputs = fake_context({ record = { cflags = cflags } })
            assert(browser.build(context, inputs))
        end
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
            -- CLI target validation precedes the browser option policy on an
            -- unsupported host; neither rejection reaches tool discovery.
            contains(result.output, platform.windows and
                "browser builds are supported from Linux and macOS hosts (host is windows)" or line_error)
            assert.is_nil(result.output:find("stack traceback", 1, true))
        end)
    end

    it("rejects Windows and other unsupported hosts before tool discovery", function()
        local subject = fresh_driver()
        for _, target in ipairs({ "windows", "native" }) do
            local context = { target = "browser", host_target = target }
            local ok, err = subject._finish_target_initialization(context)
            assert.is_nil(ok)
            assert.equal("browser builds are supported from Linux and macOS hosts (host is " .. target .. ")", err)
        end
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
        assert.equal(2, #calls)
        assert.equal(FAKE_ROOT .. "/cache-prefix/var/cache/titan-probes/browser-6.0.13/" ..
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
        local browser_path = FAKE_ROOT .. "/probes/browser-6.0.13/" .. cprobe_cache.VERSION
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
