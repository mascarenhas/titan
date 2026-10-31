local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local fixtures = require "spec.support.browser_fixtures"
local lfs = require "lfs"
local layouts = require "titan-compiler.nominallayout"
local staticmetadata = require "titan-compiler.staticmetadata"
local temporary = require "spec.support.temporary"
local toolchain = require "spec.support.browser_toolchain"
local types = require "titan-compiler.types"

local function mkdir(directory)
    if lfs.attributes(directory, "mode") == "directory" then return end
    local parent = directory:match("^(.+)/[^/]+$")
    if parent then mkdir(parent) end
    assert(lfs.mkdir(directory))
end
local function write(filename, bytes)
    mkdir(assert(filename:match("^(.+)/[^/]+$")))
    local file = assert(io.open(filename, "wb"))
    assert(file:write(bytes)); assert(file:close())
end
local function read(filename)
    local file = assert(io.open(filename, "rb"))
    local bytes = file:read("a"); file:close(); return bytes
end
local function remove(directory)
    if lfs.symlinkattributes(directory, "mode") == "directory" then
        for name in lfs.dir(directory) do
            if name ~= "." and name ~= ".." then remove(directory .. "/" .. name) end
        end
        assert(lfs.rmdir(directory))
    elseif lfs.symlinkattributes(directory) then assert(os.remove(directory)) end
end
local function u32(number)
    local out = {}
    repeat
        local byte = number & 127
        number = number >> 7
        out[#out + 1] = string.char(byte | (number > 0 and 128 or 0))
    until number == 0
    return table.concat(out)
end
local function name(text) return u32(#text) .. text end
local function section(id, bytes) return string.char(id) .. u32(#bytes) .. bytes end
local function custom(label, bytes) return section(0, name(label) .. bytes) end
local function payload(module)
    return assert(staticmetadata.render(module, driver.TITAN_ABI_VERSION,
        'Module(' .. string.format('%q', module) .. ',{}, {})', assert(layouts.encode(module, {}))))
end
local function protocol(module)
    local prefix = driver.mangle_module_name(module)
    return { prefix .. "_abi", prefix .. "_types", prefix .. "_layouts",
        prefix .. "_init", "luaopen_" .. prefix }
end
-- A producer, not a reader: each function has an empty body and the only DATA
-- segment carries the canonical metadata. These objects are never executed.
local function wasm(module, options)
    options = options or {}
    local symbols = options.symbols or (module and protocol(module) or {})
    local imports = name("env") .. name("__linear_memory") .. "\2\0\0"
    local import_count, function_imports = 1, 0
    if options.import then
        imports = imports .. name("env") .. name(options.import) .. "\0\0"
        import_count, function_imports = 2, 1
    end
    local functions, bodies, records = {}, {}, {}
    for index, symbol in ipairs(symbols) do
        functions[index], bodies[index] = "\0", "\2\0\11"
        local flags = 64 | (options.weak == symbol and 1 or 0) |
            (options.local_symbol == symbol and 2 or 0)
        records[index] = "\0" .. u32(flags) .. u32(index - 1 + function_imports) .. name(symbol)
        if options.data_symbol == symbol then
            records[index] = "\1\0" .. name(symbol) .. "\0\0\0"
        end
    end
    if options.undefined then
        -- Undefined data symbols carry their name but no segment coordinates.
        records[#records + 1] = "\1\16" .. name(options.undefined)
    end
    local bytes = "\0asm\1\0\0\0" .. section(1, "\1\96\0\0") ..
        section(2, u32(import_count) .. imports)
    if #symbols > 0 then
        bytes = bytes .. section(3, u32(#symbols) .. table.concat(functions)) ..
            section(10, u32(#symbols) .. table.concat(bodies))
    end
    local linking = u32(2)
    if module then
        local data = payload(module)
        bytes = bytes .. section(11, "\1\0\65\0\11" .. name(data))
        linking = linking .. section(5, "\1" .. name(".titan.meta") .. "\0\0")
    end
    linking = linking .. section(8, u32(#records) .. table.concat(records))
    local features, count = {}, 0
    for feature in fixtures.features:gmatch("[^ ]+") do
        count = count + 1
        features[count] = feature:sub(1, 1) .. name(feature:sub(2))
    end
    return bytes .. custom("linking", linking) ..
        custom("target_features", u32(count) .. table.concat(features))
end
local function archive(members, names)
    local out = { "!<arch>\n" }
    local function field(value, size) return value .. string.rep(" ", size - #value) end
    for index, bytes in ipairs(members) do
        out[#out + 1] = field((names and names[index] or "m" .. index .. ".o") .. "/", 16) .. field("0", 12) ..
            field("0", 6) .. field("0", 6) .. field("644", 8) ..
            field(tostring(#bytes), 10) .. "`\n" .. bytes .. (#bytes % 2 == 1 and "\n" or "")
    end
    return table.concat(out)
end
local function scan(bytes)
    return assert(staticmetadata.scan_bytes(bytes, "fixture.a", {
        target = fixtures.fingerprint(), expected_abi = driver.TITAN_ABI_VERSION,
        require_layouts = true,
    }))
end
local function browser_context(root, options)
    local context = driver.new_resolver_context(options)
    context.target = "browser"
    context.target_descriptor = assert(require("titan-compiler.browsertarget").import(fixtures.descriptor(root)))
    driver.activate_target_caches(context, context.target_descriptor.identity)
    return context
end

describe("browser providers", function()
    local root, original_loadlib, original_execute, original_popen, original_source, original_bin
    before_each(function()
        root = temporary.name("-browser-providers"); mkdir(root)
        original_loadlib = require("titan")._loadlib
        require("titan")._loadlib = function() error("browser called _loadlib") end
        original_execute, original_popen = os.execute, io.popen
        original_source, original_bin = driver.TITAN_SOURCE_PATH, driver.TITAN_BIN_PATH
        driver.imported, types.registry = {}, {}
    end)
    after_each(function()
        require("titan")._loadlib = original_loadlib
        os.execute, io.popen = original_execute, original_popen
        driver.TITAN_SOURCE_PATH, driver.TITAN_BIN_PATH = original_source, original_bin
        driver.imported, types.registry = {}, {}
        remove(root)
    end)

    it("accepts the primary protocol and rejects sibling substitutes", function()
        local valid = scan(archive({ wasm("pkg.mod") }))
        assert.is_true(driver.validate_browser_provider(valid, valid.entries))
        local missing = protocol("pkg.mod"); table.remove(missing, 3)
        local invalid = scan(archive({ wasm("pkg.mod", { symbols = missing }), wasm(nil, {
            symbols = { protocol("pkg.mod")[3] },
        }) }))
        local ok, err = driver.validate_browser_provider(invalid)
        assert.is_nil(ok)
        assert.matches('browser provider module "pkg.mod" requires global non-weak function', err, 1, true)
        assert.matches(string.format("%q", protocol("pkg.mod")[3]), err, 1, true)
    end)

    for _, binding in ipairs({ "weak", "local_symbol", "data_symbol" }) do
        it("rejects " .. binding .. " protocol definitions", function()
            local options = { [binding] = protocol("pkg.mod")[1] }
            local ok, err = driver.validate_browser_provider(scan(archive({ wasm("pkg.mod", options) })))
            assert.is_nil(ok); assert.matches("requires global non-weak function", err, 1, true)
        end)
    end
    for _, symbol in ipairs({ "dlopen", "dlsym", "backtrace_full", "__backtrace_create_state" }) do
        for _, source in ipairs({ "import", "undefined" }) do
            it("rejects forbidden " .. source .. " " .. symbol .. " in every member", function()
                local parsed = scan(archive({ wasm("pkg.mod"), wasm(nil, { [source] = symbol }) }))
                local ok, err = driver.validate_browser_provider(parsed)
                assert.is_nil(ok)
                assert.matches('browser provider imports forbidden symbol "' .. symbol .. '"', err, 1, true)
                assert.matches("member #2", err, 1, true)
            end)
        end
    end
    it("compares the exact keys and each embedded protocol payload", function()
        local parsed = scan(archive({ wasm("pkg.mod") }))
        local ok, err = driver.validate_browser_provider(parsed, {})
        assert.is_nil(ok); assert.matches("logical key count differs", err, 1, true)
        for _, field in ipairs({ "abi", "types", "layouts" }) do
            local expected = {}
            for key, value in pairs(parsed.entries["pkg.mod"]) do expected[key] = value end
            expected[field] = "different"
            ok, err = driver.validate_browser_provider(parsed, { ["pkg.mod"] = expected })
            assert.is_nil(ok); assert.matches("differs", err, 1, true)
        end
    end)
    it("requires every planned split part with its original bytes", function()
        local primary, part = wasm("pkg.mod"), wasm(nil)
        write(root .. "/primary.o", primary); write(root .. "/part.o", part)
        local generated = { { modname = "pkg.mod", filename = root .. "/primary.o",
            objects = { root .. "/primary.o", root .. "/part.o" } } }
        assert.is_true(driver.validate_browser_provider(scan(archive({ primary, part })), nil, generated))
        local ok, err = driver.validate_browser_provider(scan(archive({ primary })), nil, generated)
        assert.is_nil(ok); assert.equal('browser provider module "pkg.mod" is missing split part 1', err)
    end)
    it("rescans metadata-only plans before trusting browser structure", function()
        local valid = scan(archive({ wasm("pkg.mod") }))
        local filename = root .. "/planned.a"
        local symbols = protocol("pkg.mod"); table.remove(symbols, 4)
        write(filename, archive({ wasm("pkg.mod", { symbols = symbols }) }))
        local summary = assert(staticmetadata.metadata_view(
            filename, staticmetadata.container_metadata(valid), { require_layouts = true }))
        summary.archive = filename
        local ok, err = driver.prepare_static_providers_for_target({ summary }, fixtures.fingerprint())
        assert.is_nil(ok)
        assert.matches("requires global non-weak function", err, 1, true)
    end)
    it("uses the SDK archive first and never has a DSO pass", function()
        local context = browser_context(root)
        local sdk = context.target_descriptor.paths.titan_bin
        write(sdk .. "/pkg.a", archive({ wasm("pkg.mod") }))
        write(root .. "/path/pkg.a", "native or broken archive must be shadowed")
        write(root .. "/path/pkg.so", "not loadable")
        local found = assert(driver.find_dependency_interface(root .. "/path", "pkg.mod", context))
        assert.equal("static", found.kind); assert.equal(sdk .. "/pkg.a", found.filename)
        assert.is_nil(driver.find_dynamic_interface(root .. "/path", "pkg.mod", context))
        assert.equal("error", driver.probe_compiled_interface(
            "pkg.mod", root .. "/path/pkg.so", context))
        driver.TITAN_BIN_PATH = root .. "/path"
        local loader = driver.defaultloader({}, { context = context })
        assert.is_true(loader("pkg.mod"))
        assert(driver.finalize_resolver_context(context))
        assert.equal("direct", context.native_bindings["pkg.mod"])
    end)
    it("ignores a native embedded inventory in a browser context", function()
        local context = browser_context(root, {
            analysis_only = true,
            embedded_interface_provider = {
                provider_file = root .. "/native-host.so",
                entries = { ["pkg.mod"] = {
                    abi = driver.TITAN_ABI_VERSION,
                    types = 'Module("pkg.mod",{}, {})',
                } },
            },
        })
        local sdk = context.target_descriptor.paths.titan_bin
        write(sdk .. "/pkg.a", archive({ wasm("pkg.mod") }))
        local found = assert(driver.find_dependency_interface("", "pkg.mod", context))
        assert.equal("static", found.kind)
        assert.equal(sdk .. "/pkg.a", found.filename)
    end)
    it("ignores native DSOs and falls back to browser source", function()
        local context = browser_context(root)
        write(root .. "/path/pkg.so", "native DSO")
        write(root .. "/src/pkg/mod.browser.titan", "function answer(): integer return 42 end\n")
        driver.TITAN_SOURCE_PATH, driver.TITAN_BIN_PATH = root .. "/src", root .. "/path"
        local loader = driver.defaultloader({}, { context = context })
        local ok, _, errors = loader("pkg.mod")
        assert.is_true(ok, errors and table.concat(errors, "\n"))
        assert.equal("source", driver.imported["pkg.mod"].kind)
    end)
    it("a native archive is terminal rather than a source fallback", function()
        local context = browser_context(root)
        local elf = "\127ELF\2\1\1" .. string.rep("\0", 9) ..
            string.pack("<I2I2I4I8I8I8I4I2I2I2I2I2I2",
                1, 62, 1, 0, 0, 64, 0, 64, 0, 0, 64, 2, 1) ..
            string.rep("\0", 64) ..
            string.pack("<I4I4I8I8I8I8I4I4I8I8", 0, 3, 0, 0, 192, 1, 0, 0, 1, 0) .. "\0"
        write(root .. "/path/pkg.a", archive({ elf }))
        write(root .. "/src/pkg/mod.browser.titan", "function answer(): integer return 42 end\n")
        driver.TITAN_SOURCE_PATH, driver.TITAN_BIN_PATH = root .. "/src", root .. "/path"
        local loader = driver.defaultloader({}, { context = context })
        local ok, err = loader("pkg.mod")
        assert.is_false(ok); assert.matches("target mismatch", err, 1, true)
        assert.matches("cannot inspect static provider", err, 1, true)
    end)
    for _, policy in ipairs({ "source_first", "explicit_source" }) do
        it("retains the " .. policy .. " selection policy", function()
            local context = browser_context(root, { source_first = policy == "source_first" })
            write(root .. "/path/pkg.a", archive({ wasm("pkg.mod") }))
            write(root .. "/src/pkg/mod.browser.titan", "function answer(): integer return 42 end\n")
            driver.TITAN_SOURCE_PATH, driver.TITAN_BIN_PATH = root .. "/src", root .. "/path"
            local loader = driver.defaultloader({}, { context = context })
            assert.is_true(loader("pkg.mod", policy == "explicit_source" and
                { kind = "source-import" } or nil))
            assert.equal("source", driver.imported["pkg.mod"].kind)
        end)
    end

    it("builds and publishes only an archive through the descriptor tools", function()
        local context = browser_context(root)
        local primary, part = wasm("pkg.mod"), wasm(nil)
        write(root .. "/primary.o", primary); write(root .. "/part.o", part)
        local built, commands = {}, {}
        os.execute = function(command)
            local argv = assert(cdriver.split_shell_words(command))
            commands[#commands + 1] = argv
            assert.is_true(argv[1] == context.target_descriptor.tools.ar[1] or
                argv[1] == context.target_descriptor.tools.ranlib[1], command)
            if argv[1] == context.target_descriptor.tools.ar[1] then
                assert.equal("qDc", argv[2])
                local output, members, names = argv[3], {}, {}
                local previous = built[output]
                if previous then
                    for index, bytes in ipairs(previous.members) do
                        members[index], names[index] = bytes, previous.names[index]
                    end
                end
                for index = 4, #argv do
                    members[#members + 1], names[#names + 1] =
                        read(argv[index]), argv[index]:match("([^/]+)$")
                end
                built[output] = { members = members, names = names }
                write(output, archive(members, names))
            else
                assert.equal("-D", argv[2])
            end
            return true, "exit", 0
        end
        io.popen = function() error("unexpected browser executing probe") end
        local expected = scan(archive({ primary })).entries
        local destination = assert(driver.provider_output_path("pkg", root .. "/out", context))
        local staged = assert(driver.link_provider_pair({
            context = context, provider = "pkg", public_dso = destination,
            target = fixtures.fingerprint(), expected_entries = expected,
            generated_objects = { { modname = "pkg.mod", filename = root .. "/primary.o",
                objects = { root .. "/primary.o", root .. "/part.o" } } },
            archive_inputs = {
                { kind = "object", input = root .. "/primary.o" },
                { kind = "object", input = root .. "/part.o" },
            },
        }))
        assert.is_nil(staged.dso)
        assert(driver.publish_provider_bundle(nil, staged.archive, destination, {
            archive_only = true, context = context,
        }))
        assert(driver.remove_path(staged.directory))
        assert.equal("file", lfs.attributes(root .. "/out/pkg.a", "mode"))
        assert.is_nil(lfs.attributes(root .. "/out/pkg.so"))
        assert.is_nil(lfs.attributes(root .. "/out/pkg.so.dSYM"))
        assert.is_true(driver.validate_browser_provider(scan(read(destination)), expected))
        assert.equal(4, #commands)
    end)

    it("stops program and executable probes before any process or loader call", function()
        local context = browser_context(root)
        os.execute = function() error("unexpected program process") end
        io.popen = function() error("unexpected program probe") end
        local ok, err = driver.compile_program("pkg.mod", {}, nil, false, nil,
            nil, nil, nil, nil, { context = context })
        assert.is_nil(ok); assert.equal("browser program linking is not available yet", err)
        ok, err = driver.run_standalone_archive_probe({}, {}, {}, {}, nil, false, nil, { context = context })
        assert.is_nil(ok); assert.equal("browser program linking is not available yet", err)
    end)
end)

local PROVIDER_HOOK = [[
local original_require = require
local hooked = false
function require(name)
    local module = original_require(name)
    if name == "titan" then
        module._loadlib = function() error("browser must not call _loadlib") end
    elseif name == "titan-compiler.driver" and not hooked then
        hooked = true
        for _, field in ipairs({ "compile_program", "run_standalone_archive_probe",
                "compile_library_output", "compile_archive_validation_image",
                "validate_library_image", "validate_library_image_fresh" }) do
            module[field] = function() error("browser entered executable path " .. field) end
        end
        local execute = os.execute
        os.execute = function(command)
            local argv = assert(original_require("c-parser.cdriver").split_shell_words(command))
            local tool = argv[1]:match("([^/]+)$")
            assert(tool == "emcc" or tool == "emar" or tool == "emranlib",
                "browser executed a non-compile/archive command: " .. command)
            local file = assert(io.open(assert(os.getenv("BROWSER_COMMAND_LOG")), "a"))
            file:write(tool, "\n"); file:close()
            return execute(command)
        end
        local stage = module.link_provider_pair
        module.link_provider_pair = function(request)
            local mode = os.getenv("BROWSER_CORRUPTION")
            local filename = request.generated_objects[1].filename
            if mode == "corrupt" then
                local file = assert(io.open(filename, "wb"))
                file:write("corrupt object"); file:close()
            elseif mode == "missing-symbol" or mode == "lto" then
                local metadata = original_require("titan-compiler.staticmetadata")
                local util = original_require("titan-compiler.util")
                local parsed = assert(metadata.classify_object(
                    assert(util.get_file_contents(filename, "rb")), filename, request.target))
                local entry = assert(parsed.metadata)
                local source = assert(metadata.source_declaration(entry.payload, "browser_fixture_metadata"))
                local prefix = module.mangle_module_name(entry.module)
                for _, symbol in ipairs({ prefix .. "_abi", prefix .. "_types",
                        prefix .. "_layouts", "luaopen_" .. prefix }) do
                    source = source .. "\nvoid " .. symbol .. "(void) {}\n"
                end
                if mode == "lto" then source = source .. "\nvoid " .. prefix .. "_init(void) {}\n" end
                local cfile = filename .. ".replacement.c"
                assert(util.set_file_contents(cfile, source))
                local argv = assert(module.generated_compile_prefix(request.context))
                if mode == "lto" then argv[#argv + 1] = "-flto" end
                for _, argument in ipairs({ "-c", cfile, "-o", filename }) do
                    argv[#argv + 1] = argument
                end
                local quoted = {}
                for index, argument in ipairs(argv) do
                    quoted[index] = assert(original_require("c-parser.cdriver").shell_quote(argument))
                end
                assert(os.execute(table.concat(quoted, " ")))
            end
            return stage(request)
        end
    end
    return module
end
]]

describe("browser providers real toolchain", function()
    local root, info, prefix, sdk, repo, log
    local function run_cli(corruption, ...)
        local argv = { "env", "-u", "LUA_PATH", "-u", "LUA_PATH_5_5",
            "-u", "LUA_CPATH", "-u", "LUA_CPATH_5_5", "-u", "LUA_INIT_5_5",
            "-u", "TITAN_JOBS", "-u", "MAKEFLAGS", "-u", "MFLAGS",
            "TITAN_ROOT=" .. prefix, "TITAN_PROBE_CACHE_DISABLE=1",
            "TITAN_PATH_0_6=" .. root .. "/providers", "TITAN_PATH=",
            "LUA_INIT=@" .. root .. "/hook.lua", "BROWSER_COMMAND_LOG=" .. log,
            "BROWSER_CORRUPTION=" .. (corruption or ""),
            info.prefix .. "/bin/lua", "-e",
            string.format("package.path=%q..package.path", repo .. "/?.lua;" .. repo .. "/?/init.lua;"),
            repo .. "/titanc", "-q", "--target", "browser",
            "--tree", root .. "/src", "-o", root .. "/out" }
        for _, argument in ipairs({ ... }) do argv[#argv + 1] = argument end
        return compiler_io.new_sync():run(argv, { stderr_to_stdout = true })
    end
    local function prepare(real_info)
        info = real_info
        root = temporary.name("-browser-real-provider"); mkdir(root)
        repo = assert(lfs.currentdir()); prefix = root .. "/prefix"
        mkdir(prefix .. "/lib")
        assert(lfs.link(info.prefix .. "/lib/browser", prefix .. "/lib/browser", true))
        assert(lfs.link(info.prefix .. "/include", prefix .. "/include", true))
        sdk = fixtures.paths(prefix).titan_bin; mkdir(sdk)
        log = root .. "/commands"
        write(root .. "/hook.lua", PROVIDER_HOOK)
        write(root .. "/src/pkg/left.titan", "function answer(): integer return 42 end\n")
        write(root .. "/src/pkg/right.titan", "function twice(n: integer): integer return n * 2 end\n")
    end
    after_each(function()
        if root then remove(root) end
        root = nil
    end)
    it("publishes an archive-only multi-module provider with an empty SDK", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        prepare(info)
        local entries = {}; for entry in lfs.dir(sdk) do entries[#entries + 1] = entry end
        table.sort(entries); assert.same({ ".", ".." }, entries)
        local result = run_cli(nil, "--c-parts", "3", "pkg.left", "pkg.right")
        assert.is_true(result.ok, result.output)
        local output = root .. "/out/pkg.a"
        assert.equal("file", lfs.attributes(output, "mode"))
        assert.is_nil(lfs.attributes(root .. "/out/pkg.so"))
        assert.is_nil(lfs.attributes(root .. "/out/pkg.so.dSYM"))
        local parsed = assert(staticmetadata.scan_archive(output, { target = fixtures.fingerprint() }))
        assert.same({ "pkg.left", "pkg.right" }, parsed.key_order)
        assert.is_true(driver.validate_browser_provider(parsed))
        local commands = read(log)
        assert.matches("emcc", commands, 1, true)
        assert.matches("emar", commands, 1, true)
        assert.matches("emranlib", commands, 1, true)
        write(root .. "/providers/pkg.a", read(output))
        write(root .. "/src/consumer.titan",
            'local left = import "pkg.left"\nfunction answer(): integer return left.answer() end\n')
        result = run_cli(nil, "-c", "consumer")
        assert.is_true(result.ok, result.output)
        local source_record = assert(require("titan-compiler.objectmetadata").read(
            read(root .. "/out/consumer.o"), root .. "/out/consumer.o"))
        assert.equal("direct", source_record.object_metadata.bindings["pkg.left"])
    end)
    for _, case in ipairs({
        { mode = "corrupt", message = "unsupported native object format" },
        { mode = "missing-symbol", message = "requires global non-weak function" },
        { mode = "lto", message = "LLVM bitcode (LTO) object is not supported" },
    }) do
        it("rejects " .. case.mode .. " and publishes nothing", function()
            local info, why = toolchain.require(); if not info then pending(why) return end
            prepare(info)
            local result = run_cli(case.mode, "pkg.left")
            assert.is_false(result.ok)
            assert.matches(case.message, result.output, 1, true)
            assert.is_nil(lfs.attributes(root .. "/out/pkg/left.a"))
            assert.is_nil(lfs.attributes(root .. "/out/pkg/left.so"))
            for entry in lfs.dir(root .. "/out/pkg") do
                assert.is_nil(entry:find(".stage.tmp.", 1, true), entry)
            end
        end)
    end
    for _, mode in ipairs({ "program", "test" }) do
        it("stops " .. mode .. " linking before executable synthesis", function()
            local info, why = toolchain.require(); if not info then pending(why) return end
            prepare(info)
            write(root .. "/src/pkg/program.titan",
                "function main(args: {string}): integer return 0 end\n")
            local result = mode == "test" and run_cli(nil, "--test", "pkg.left") or
                run_cli(nil, "pkg.program")
            assert.is_false(result.ok)
            assert.matches("browser program linking is not available yet", result.output, 1, true)
            assert.is_nil(lfs.attributes(root .. "/out/.titan-links"))
        end)
    end
end)
