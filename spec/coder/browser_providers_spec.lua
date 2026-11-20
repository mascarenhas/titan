local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local filesystem = require "spec.support.filesystem"
local files = require "spec.fixtures.target_selection.support"
local fixtures = require "spec.support.browser_fixtures"
local lfs = require "lfs"
local layouts = require "titan-compiler.nominallayout"
local path = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local staticmetadata = require "titan-compiler.staticmetadata"
local temporary = require "spec.support.temporary"
local toolchain = require "spec.support.browser_toolchain"
local process_audit = require "spec.support.browser_process_audit"
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
local function native_inventory(root)
    local context = driver.new_resolver_context({ analysis_only = true })
    local profile = assert(require("titan-compiler.csemantics").export_profile(
        assert(driver.get_target_profile(context))))
    assert(driver.close_resolver_context(context))
    local entries = {}
    for _, module in ipairs({ "pkg.mod", "app", "native.only" }) do
        entries[module] = { abi = driver.TITAN_ABI_VERSION,
            types = string.format('Module(%q,{}, {})', module) }
    end
    return { provider_file = root .. "/native-host.so", entries = entries, target_profile = profile }
end

local function browser_context(root, options)
    options = options or {}
    options.target = "browser"
    local descriptor = assert(require("titan-compiler.browsertarget").import(fixtures.descriptor(root)))
    return driver._new_resolver_context(options, descriptor)
end

describe("browser providers", function()
    local root, original_loadlib, original_execute, original_popen, original_source, original_bin
    local audit_guard, original_new_sync
    local original_process_run, original_process_capture
    before_each(function()
        root = temporary.name("-browser-providers"); mkdir(root)
        original_loadlib = require("titan")._loadlib
        require("titan")._loadlib = function() error("browser called _loadlib") end
        original_execute, original_popen = os.execute, io.popen
        original_new_sync = compiler_io.new_sync
        local process = require("titan-compiler.process")
        original_process_run, original_process_capture = process.run, process.capture
        original_source, original_bin = driver.TITAN_SOURCE_PATH, driver.TITAN_BIN_PATH
        driver.imported, types.registry = {}, {}
    end)
    after_each(function()
        if audit_guard then audit_guard.restore(); audit_guard = nil end
        compiler_io.new_sync = original_new_sync
        local process = require("titan-compiler.process")
        process.run, process.capture = original_process_run, original_process_capture
        require("titan")._loadlib = original_loadlib
        os.execute, io.popen = original_execute, original_popen
        driver.TITAN_SOURCE_PATH, driver.TITAN_BIN_PATH = original_source, original_bin
        driver.imported, types.registry = {}, {}
        remove(root)
    end)

    it("keeps the observed host when activating a browser provider context", function()
        local host = files.host()
        local context = browser_context(root)
        assert.equal(host, context.host_target)
        assert.equal("browser", context.target)
        assert.equal(context.target_descriptor, driver.context_target_descriptor(context))
        assert(driver.close_resolver_context(context))
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

    for _, changed in ipairs({ false, true }) do
        for _, suffix in ipairs({ ".so", ".so.dSYM", ".dll", ".dll.def", ".dylib",
                ".dylib.dSYM", ".dll.a", ".lib", ".exp", ".pdb" }) do
            it("refuses native companion " .. suffix .. " with " ..
                (changed and "changed" or "unchanged") .. " archive", function()
                local context = browser_context(root)
                local destination, staged = root .. "/out/pkg.a", root .. "/stage/pkg.a"
                local original = archive({ wasm("pkg.mod") })
                local replacement = changed and archive({ wasm("pkg.other") }) or original
                write(destination, original); write(staged, replacement)
                local companion = root .. "/out/pkg" .. suffix
                if suffix:match("dSYM$") then write(companion .. "/user-data", "preserve me")
                else write(companion, "preserve me") end
                local committed = false
                local ok, err = driver.publish_provider_bundle(nil, staged, destination, {
                    archive_only = true, context = context,
                    native_inputs = { companion },
                    before_commit = function() committed = true; return true end,
                })
                assert.is_nil(ok); assert.matches(companion, err, 1, true)
                assert.is_false(committed)
                assert.equal(original, read(destination)); assert.equal(replacement, read(staged))
                assert.equal("preserve me", read(suffix:match("dSYM$") and companion .. "/user-data" or companion))
            end)
        end
    end
    it("refuses symlink companions without touching their target", function()
        local available, message = filesystem.symlink_capability()
        if not available then
            pending("capability: " .. message)
            return
        end
        local context = browser_context(root)
        local destination, staged = root .. "/out/pkg.a", root .. "/stage/pkg.a"
        local original = archive({ wasm("pkg.mod") })
        write(destination, original); write(staged, original)
        write(root .. "/user-data", "preserve me")
        assert(lfs.link(root .. "/user-data", root .. "/out/pkg.so", true))
        local ok, err = driver.publish_provider_bundle(nil, staged, destination,
            { archive_only = true, context = context })
        assert.is_nil(ok); assert.matches(root .. "/out/pkg.so", err, 1, true)
        assert.equal("link", lfs.symlinkattributes(root .. "/out/pkg.so", "mode"))
        assert.equal("preserve me", read(root .. "/user-data")); assert.equal(original, read(destination))
    end)

    it("ignores native embedded profiles during browser probe acquisition", function()
        local inventory = native_inventory(root)
        local context = browser_context(root, { analysis_only = true, embedded_interface_provider = inventory })
        assert.is_nil(context.embedded_interface_provider)
        assert.is_nil(context.used_embedded_target_profile_identity)
        local calls = {}
        context.io.run = function(_, argv)
            calls[#calls + 1] = argv
            assert.equal("env", argv[1])
            assert.equal("EMCC_CFLAGS=", argv[2])
            assert.equal(context.target_descriptor.tools.cc[1], argv[3])
            return { started = true, ok = true, output = "", status = 0, why = "exit" }
        end
        local service = assert(driver.get_probe_service(context))
        assert.equal(context.target_descriptor.profile_identity, service.profile.identity)
        local result = service:_run_source("baseline", "typedef char browser_pointer[(sizeof(void*) == 4) ? 1 : -1];")
        assert.equal("success", result.classification, result.diagnostic)
        assert.is_true(#calls > 0)
        assert(driver.close_resolver_context(context))
    end)
    it("retains browser archive and source dependency closure across reconciliation", function()
        local context = browser_context(root, {
            analysis_only = true, embedded_interface_provider = native_inventory(root),
        })
        write(context.target_descriptor.paths.titan_bin .. "/pkg.a", archive({ wasm("pkg.mod") }))
        write(root .. "/src/app.browser.titan",
            'local pkg = import "pkg.mod"\nfunction answer(): integer return 42 end\n')
        driver.TITAN_SOURCE_PATH, driver.TITAN_BIN_PATH = root .. "/src", ""
        local dependencies = {}
        local loader = driver.defaultloader(dependencies, { context = context })
        assert.is_true(loader("pkg.mod"))
        local selected = driver.imported["pkg.mod"]
        assert.is_true(loader("pkg.mod"))
        assert.equal(selected, driver.imported["pkg.mod"])
        assert.is_true(dependencies["pkg.mod"])
        assert.is_true(loader("app"))
        dependencies["pkg.mod"] = nil
        assert.is_true(loader("app"))
        assert.is_true(dependencies["pkg.mod"])
        assert.equal(selected, driver.imported["pkg.mod"])
        assert.is_false(context.embedded_interface_provider_rejected)
        assert.is_nil(context.embedded_interface_provider_overlap)
        assert(driver.finalize_resolver_context(context))
        assert.equal("direct", context.native_bindings["pkg.mod"])
        assert(driver.close_resolver_context(context))
    end)
    it("excludes native embedded entries from the browser completion catalog", function()
        local context = browser_context(root, {
            analysis_only = true, embedded_interface_provider = native_inventory(root),
        })
        write(context.target_descriptor.paths.titan_bin .. "/pkg.a", archive({ wasm("pkg.mod") }))
        driver.TITAN_BIN_PATH = ""
        assert.is_true(driver.defaultloader({}, { context = context })("pkg.mod"))
        assert(driver.finalize_resolver_context(context))
        local catalog = driver.completion_binary_catalog(context)
        assert.equal("static", catalog["pkg.mod"].kind)
        assert.is_nil(catalog["native.only"])
        assert(driver.close_resolver_context(context))
    end)

    it("stages a structural bootstrap archive through descriptor tools without an image SDK", function()
        local context = browser_context(root)
        local primary, part = wasm("pkg.mod"), wasm(nil)
        write(root .. "/primary.o", primary); write(root .. "/part.o", part)
        local built, commands = {}, {}
        local function archive_tool(argv)
            if argv[1] == "/bin/sh" and argv[2] == "-c" then
                argv = assert(cdriver.split_shell_words(argv[3]))
            end
            commands[#commands + 1] = argv
            assert.is_true(argv[1] == context.target_descriptor.tools.ar[1] or
                argv[1] == context.target_descriptor.tools.ranlib[1], table.concat(argv, " "))
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
                        read(argv[index]), argv[index]:match("([^/\\]+)$")
                end
                built[output] = { members = members, names = names }
                write(output, archive(members, names))
            else
                assert.equal("-D", argv[2])
            end
            return true, "exit", 0
        end
        -- POSIX uses the shell path; Windows uses process.run directly. Keep
        -- every native transport synthetic while the shared audit checks it.
        os.execute = function(command)
            return archive_tool(assert(cdriver.split_shell_words(command)))
        end
        local process = require("titan-compiler.process")
        process.run = archive_tool
        process.capture = function(argv)
            archive_tool(argv)
            return { started = true, ok = true, why = "exit", status = 0, output = "" }
        end
        io.popen = function() error("unexpected browser executing probe") end
        audit_guard = process_audit.install({ tools = context.target_descriptor.tools })
        local expected = scan(archive({ primary })).entries
        local destination = assert(driver.provider_output_path("pkg", root .. "/out", context))
        local staged = assert(driver.stage_browser_provider({
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
        assert.equal("file", lfs.attributes(staged.archive, "mode"))
        assert.is_nil(lfs.attributes(destination))
        assert.is_true(driver.validate_browser_provider(scan(read(staged.archive)), expected))
        assert(driver.remove_path(staged.directory))
        assert.is_nil(lfs.attributes(staged.archive))
        assert.equal(4, #commands)
    end)

    it("names the browser archiver that fails its deterministic capability check", function()
        local platform = require "titan-compiler.platform"
        local process = require "titan-compiler.process"
        local primary = root .. "/primary.o"
        write(primary, wasm("pkg.mod"))
        local context = browser_context(root)
        local tools = context.target_descriptor.tools
        local destination = root .. "/out/pkg.a"
        for _, command in ipairs({ tools.ar[1], tools.ranlib[1] }) do
            process.capture = function(argv)
                if not platform.windows then argv = assert(cdriver.split_shell_words(argv[3])) end
                return { started = true, ok = argv[1] ~= command, why = "exit", status = 3, output = "" }
            end
            local staged, err = driver.stage_browser_provider({
                context = context, public_dso = destination, target = fixtures.fingerprint(),
                archive_inputs = { { kind = "object", input = primary } },
            })
            assert.is_nil(staged)
            assert.matches("browser archive tool " .. string.format("%q", command), err, 1, true)
            assert.matches("failed deterministic", err, 1, true)
        end
        assert(driver.close_resolver_context(context))
    end)

    it("does not add target probes to native provider lookup", function()
        local context = driver.new_resolver_context()
        context.io.run = function() error("unexpected native target probe") end
        os.execute = function() error("unexpected native process") end
        io.popen = function() error("unexpected native command capture") end
        assert.is_nil(driver.find_dynamic_interface(root .. "/empty", "pkg.mod", context))
        assert.is_nil(driver.find_static_interface(root .. "/empty", "pkg.mod", context))
        assert.is_nil(driver.find_dependency_interface(root .. "/empty", "pkg.mod", context))
        local expected = require("titan-compiler.platform").windows and ".dll" or ".so"
        assert.equal(path.join(root, "pkg" .. expected), driver.provider_output_path("pkg", root, context))
    end)

    for _, transport in ipairs({ "execute", "popen", "sync", "start", "run", "capture",
            "start_job", "batch", "jobs", "worker", "uv" }) do
        it("rejects image execution through " .. transport, function()
            local tools = { cc = { "/audit/emcc" }, ar = { "/audit/emar" }, ranlib = { "/audit/emranlib" } }
            local attempts = {}
            audit_guard = process_audit.install({
                tools = tools, record = function(_, operation) attempts[#attempts + 1] = operation end,
            })
            local argv = { tools.cc[1], root .. "/probe.c", "-o", root .. "/probe.js" }
            local process = require("titan-compiler.process")
            local batch = transport == "batch" and process.new_batch() or nil
            local action
            if transport == "execute" then action = function() return os.execute(table.concat(argv, " ")) end
            elseif transport == "popen" then action = function() return io.popen(table.concat(argv, " ")) end
            elseif transport == "sync" then action = function() return compiler_io.new_sync():run(argv) end
            elseif transport == "start_job" then
                action = function() return process.start_job(argv, root .. "/stdout", root .. "/stderr", function() end) end
            elseif transport == "batch" then
                action = function() return batch:spawn(argv, root .. "/stdout", root .. "/stderr", 1) end
            elseif transport == "jobs" then
                action = function() return require("titan-compiler.jobs").launch({}, argv, table.concat(argv, " "),
                    root .. "/stdout", root .. "/stderr", 1) end
            elseif transport == "worker" then action = function() return process.start_worker(argv, {}, {}) end
            elseif transport == "uv" then
                action = function() return process.library().spawn(argv[1], { args = { table.unpack(argv, 2) } }) end
            else action = function() return process[transport](argv) end end
            local ok, result = pcall(action)
            if batch then batch:close() end
            if transport == "sync" then
                assert.is_true(ok); assert.is_false(result.started)
                assert.matches("browser process audit rejected", result.diagnostic, 1, true)
            else
                assert.is_false(ok); assert.matches("browser process audit rejected", result, 1, true)
            end
            assert.same({ "rejected" }, attempts)
        end)
    end
    it("rejects another executable with the emcc basename", function()
        audit_guard = process_audit.install({ tools = fixtures.descriptor(root).tools })
        assert.has_error(function() os.execute("/another/emcc -c probe.c -o probe.o") end)
    end)
    it("rejects shell execution outside the compiler command", function()
        audit_guard = process_audit.install({
            tools = { cc = { "/audit/emcc" }, ar = { "/audit/emar" }, ranlib = { "/audit/emranlib" } },
        })
        assert.has_error(function() io.popen("/audit/emcc -c probe.c; node probe.js") end)
    end)

    it("diagnoses an incomplete SDK before linking and leaves an empty metadata probe independent", function()
        local context = browser_context(root)
        local attempts = {}
        audit_guard = process_audit.install({
            tools = context.target_descriptor.tools,
            record = function(...) attempts[#attempts + 1] = { ... } end,
        })
        local ok, err = driver.compile_program("pkg.mod", {}, nil, false, nil,
            nil, nil, nil, nil, { context = context })
        assert.is_nil(ok); assert.matches("browser SDK is incomplete: missing", err, 1, true)
        ok, err = driver.run_standalone_archive_probe({}, { "pkg.mod" }, {}, {}, nil, false, nil, { context = context })
        assert.is_nil(ok); assert.matches("browser SDK is incomplete: missing", err, 1, true)
        assert.is_true(driver.run_standalone_archive_probe({}, {}, {}, {}, nil, false, nil, { context = context }))
        assert.same({}, attempts)
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
        for _, field in ipairs({ "compile_library_output", "compile_archive_validation_image",
                "validate_library_image", "validate_library_image_fresh" }) do
            module[field] = function() error("browser entered executable path " .. field) end
        end
        local browser_active = false
        local finish = module._finish_target_initialization
        module._finish_target_initialization = function(context)
            if context.target == "browser" then browser_active = true end
            return finish(context)
        end
        local corrupted = {}
        local function after_tool(argv, tool)
            if tool ~= "emranlib" or os.getenv("BROWSER_CORRUPTION") ~= "corrupt-member" then return end
            local filename = argv[#argv]
            if not filename:match("[/\\]output[.]a$") or corrupted[filename] then return end
            corrupted[filename] = true
            local parsed = assert(original_require("titan-compiler.staticmetadata").scan_archive(filename))
            local file = assert(io.open(filename, "r+b"))
            assert(file:seek("set", parsed.members[1].data_offset))
            assert(file:write("X")); assert(file:close())
        end
        local process = original_require("titan-compiler.process")
        original_require("spec.support.browser_process_audit").install({
            active = function() return browser_active end,
            images = true,
            runner = module.browserlink.sdk_assets(module.installed_paths(assert(os.getenv("TITAN_ROOT")), "browser")).runner,
            module_check = module.browserlink.sdk_assets(
                module.installed_paths(assert(os.getenv("TITAN_ROOT")), "browser")).module_check,
            tools = { cc = { assert(os.getenv("BROWSER_CC")) },
                ar = { assert(os.getenv("BROWSER_AR")) },
                ranlib = { assert(os.getenv("BROWSER_RANLIB")) } },
            record = function(tool, operation)
                local file = assert(io.open(assert(os.getenv("BROWSER_COMMAND_LOG")), "ab"))
                file:write(tool, " ", operation, "\n"); file:close()
            end,
            after = after_tool,
            worker_argv = function()
                return { assert(process.library().exepath()), "-E", "-e", string.format(
                    "package.path = %q; package.cpath = %q; require(%q).main()",
                    package.path, package.cpath,
                    original_require("titan-compiler.build").WORKER_ENTRY) }
            end,
            worker_prefix = "dofile(" .. string.format("%q", assert(os.getenv("BROWSER_AUDIT_HOOK"))) .. "); ",
        })
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
                local source = '__attribute__((used, aligned(1), section(".titan.meta")))\n' ..
                    'static const unsigned char browser_fixture_metadata[] = ' ..
                    assert(metadata.c_initializer(entry.payload)) .. ';\n'
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
                local result = request.context.io:run(argv, { stderr_to_stdout = true })
                assert(result.ok, result.output or result.diagnostic)
            end
            return stage(request)
        end
    end
    return module
end
]]

describe("browser providers real toolchain", function()
    local root, info, prefix, sdk, repo, log
    local function lua_argv(corruption)
        return { "env", "-u", "LUA_PATH", "-u", "LUA_PATH_5_5",
            "-u", "LUA_CPATH", "-u", "LUA_CPATH_5_5", "-u", "LUA_INIT_5_5",
            "-u", "TITAN_JOBS", "-u", "MAKEFLAGS", "-u", "MFLAGS",
            "TITAN_ROOT=" .. prefix, "TITAN_PROBE_CACHE_DISABLE=1",
            "TITAN_PATH_0_6=" .. root .. "/providers", "TITAN_PATH=",
            "LUA_INIT=@" .. root .. "/hook.lua", "BROWSER_COMMAND_LOG=" .. log,
            "BROWSER_CC=" .. info.tools.cc[1], "BROWSER_AR=" .. info.tools.ar[1],
            "BROWSER_RANLIB=" .. info.tools.ranlib[1], "BROWSER_AUDIT_HOOK=" .. root .. "/hook.lua",
            "BROWSER_CORRUPTION=" .. (corruption or ""),
            info.lua, "-e",
            string.format("package.path=%q..package.path", repo .. "/?.lua;" .. repo .. "/?/init.lua;") }
    end
    local function run_at(tree, output, corruption, ...)
        local argv = lua_argv(corruption)
        for _, argument in ipairs({ repo .. "/titanc", "-q", "--target", "browser",
                "--tree", root .. "/" .. tree, "-o", root .. "/" .. output, ... }) do
            argv[#argv + 1] = argument
        end
        return compiler_io.new_sync():run(argv, { stderr_to_stdout = true })
    end
    local function run_cli(corruption, ...)
        return run_at("src", "out", corruption, ...)
    end
    local function prepare(real_info)
        -- Only runtime/JS assets are bootstrap prerequisites; deliberately omit
        -- the provider and manifest in this isolated publication destination.
        info = real_info
        root = temporary.name("-browser-real-provider"); mkdir(root)
        repo = toolchain.repository; prefix = root .. "/prefix"
        mkdir(prefix .. "/lib")
        toolchain.stage_lua(info, prefix)
        sdk = fixtures.paths(prefix).titan_bin; mkdir(sdk)
        log = root .. "/commands"
        write(root .. "/hook.lua", PROVIDER_HOOK)
        write(root .. "/src/pkg/left.titan", "function answer(): integer return 42 end\n")
        write(root .. "/src/pkg/right.titan", "function twice(n: integer): integer return n * 2 end\n")
    end
    local function stage_sdk()
        local assets = require("titan-compiler.browserlink").sdk_assets(fixtures.paths(prefix))
        local source = require("titan-compiler.browserlink").sdk_assets(fixtures.paths(info.prefix))
        for _, key in ipairs({ "runtime", "js_library", "bridge_library", "trace_library",
                "loader", "runner", "runner_module", "node_worker", "page", "module_check", "build_profile" }) do
            if platform.windows then
                files.copy(source[key], assets[key])
            else
                assert(lfs.link(source[key], assets[key], true))
            end
        end
        toolchain.stage_runner(info, prefix)
    end
    after_each(function()
        if root then remove(root) end
        root = nil
    end)
    it("diagnoses an empty SDK, then publishes without an installed provider or manifest", function()
        local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        prepare(info)
        local entries = {}; for entry in lfs.dir(sdk) do entries[#entries + 1] = entry end
        table.sort(entries); assert.same({ ".", ".." }, entries)
        local result = run_cli(nil, "--c-parts", "3", "pkg.left", "pkg.right")
        assert.is_false(result.ok, result.output)
        assert.matches("browser SDK is incomplete: missing", result.output, 1, true)
        assert.is_nil(lfs.attributes(root .. "/out/pkg.a"))
        stage_sdk()
        result = run_cli(nil, "--c-parts", "3", "pkg.left", "pkg.right")
        assert.is_true(result.ok, result.output)
        local output = root .. "/out/pkg.a"
        assert.equal("file", lfs.attributes(output, "mode"))
        assert.is_nil(lfs.attributes(root .. "/out/pkg.so"))
        assert.is_nil(lfs.attributes(root .. "/out/pkg.so.dSYM"))
        local parsed = assert(staticmetadata.scan_archive(output, { target = fixtures.fingerprint() }))
        assert.same({ "pkg.left", "pkg.right" }, parsed.key_order)
        assert.is_true(driver.validate_browser_provider(parsed))
        local commands = read(log)
        assert.matches("emcc compile", commands, 1, true)
        assert.matches("emar archive", commands, 1, true)
        assert.matches("emranlib archive", commands, 1, true)
        local allowed = { ["emcc compile"] = true, ["emcc preprocess"] = true, ["emcc query"] = true,
            ["emar archive"] = true, ["emranlib archive"] = true, ["compiler-worker frontend"] = true }
        allowed["emcc link"] = true
        allowed["browser-runner execute"] = true
        allowed["em-config query"] = true
        allowed["module-check check"] = true
        for operation in commands:gmatch("[^\n]+") do assert.is_true(allowed[operation], operation) end
        write(root .. "/providers/pkg.a", read(output))
        write(root .. "/src/consumer.titan",
            'local left = import "pkg.left"\nfunction answer(): integer return left.answer() end\n')
        result = run_cli(nil, "-c", "consumer")
        assert.is_true(result.ok, result.output)
        local source_record = assert(require("titan-compiler.objectmetadata").read(
            read(root .. "/out/consumer.o"), root .. "/out/consumer.o"))
        assert.equal("direct", source_record.object_metadata.bindings["pkg.left"])
    end)
    it("links one browser variant of an installed source used by two archives", function()
        local real_info, why = toolchain.require({ node = true, sdk = true })
        if not real_info then pending(why); return end
        prepare(real_info)
        stage_sdk()
        local installed = prefix .. "/lib/titan/" .. driver.TITAN_LIBRARY_VERSION
        write(installed .. "/counter.native.titan", "const native_only = true\n")
        local source = installed .. "/counter.browser.titan"
        write(source, [[
serial = 0

function next(): integer
  serial = serial + 1
  return serial
end

do
  serial = 40
end
]])
        write(installed .. "/counter" .. (platform.windows and ".dll" or ".so"),
            "not a browser input")
        write(root .. "/producer/left.titan", [[
local counter = import "counter"

function next(): integer
  return counter.next()
end
]])
        write(root .. "/producer/right.titan", [[
local counter = import "counter"

function current(): integer
  return counter.serial
end
]])
        for _, name in ipairs({ "left", "right" }) do
            local output = "built-" .. name
            local result = run_at("producer", output, nil, name)
            assert.is_true(result.ok, result.output)
            local archive = read(root .. "/" .. output .. "/" .. name .. ".a")
            local parsed = assert(staticmetadata.scan_bytes(archive, name, {
                target = fixtures.fingerprint(),
            }))
            assert.same({ name }, parsed.key_order)
            assert.same({ "counter" }, parsed.entries[name].source_requirements)
            assert.is_nil(lfs.attributes(root .. "/" .. output .. "/counter.o"))
            write(root .. "/providers/" .. name .. ".a", archive)
        end
        write(root .. "/app/demo.titan", [[
local left = import "left"
local right = import "right"

function main(args: {string}): integer
  if left.next() ~= 41 or right.current() ~= 41 then return 1 end
  if left.next() ~= 42 or right.current() ~= 42 then return 2 end
  return 0
end
]])
        local function build_and_run()
            local result = run_at("app", "application", nil, "--incremental", "demo")
            assert.is_true(result.ok, result.output)
            return compiler_io.new_sync():run(toolchain.runner(info, "--engine", "node",
                "--grace", "0", root .. "/application/demo.mjs"), { stderr_to_stdout = true })
        end
        local result = build_and_run()
        assert.is_true(result.ok, result.output)
        assert.equal("file", lfs.attributes(root .. "/application/counter.o", "mode"))
        assert.is_nil(lfs.attributes(installed .. "/counter.o"))
        local original = read(source)
        -- This alters the producer's slot numbering, not the used ABI.
        write(source, "const extra = 0\n" .. original)
        result = build_and_run()
        assert.is_true(result.ok, result.output)

        write(source, (original:gsub("function next%(%)", "function next(delta: integer)")))
        result = build_and_run()
        assert.is_false(result.ok, result.output)
        assert.matches("binary compatibility mismatch", result.output, 1, true)
        assert.matches("counter", result.output, 1, true)
    end)
    it("ignores a native profile in the real browser constructor and probe service", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        prepare(info)
        local profile = native_inventory(root).target_profile
        local encoded = assert(require("titan-compiler.graphcodec").encode(profile))
        local filename = root .. "/native-profile"
        write(filename, encoded)
        local script = string.format([[
local driver = require("titan-compiler.driver")
local file = assert(io.open(%q, "rb"))
local native = assert(require("titan-compiler.graphcodec").decode(assert(file:read("a"))))
assert(file:close())
local context = driver.new_resolver_context({
    target = "browser", analysis_only = true,
    embedded_interface_provider = { provider_file = "/native-host.so",
        entries = { ["native.only"] = { abi = driver.TITAN_ABI_VERSION,
            types = 'Module("native.only",{}, {})' } }, target_profile = native },
})
assert(context.embedded_interface_provider == nil)
local service = assert(driver.get_probe_service(context))
assert(service.profile.identity == context.target_descriptor.profile_identity)
assert(service.profile.identity ~= native.identity)
local result = service:_run_source("baseline", "typedef char browser_pointer[(sizeof(void*) == 4) ? 1 : -1];")
assert(result.classification == "success", result.diagnostic)
assert(driver.close_resolver_context(context))
]], filename)
        local argv = lua_argv()
        argv[#argv + 1], argv[#argv + 2] = "-e", script
        local result = compiler_io.new_sync():run(argv, { stderr_to_stdout = true })
        assert.is_true(result.ok, result.output or result.diagnostic)
    end)
    it("refuses a stale native companion before a warm archive certificate hit", function()
        local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        prepare(info)
        stage_sdk()
        local result = run_cli(nil, "--incremental", "pkg.left")
        assert.is_true(result.ok, result.output)
        local archive_path, companion = root .. "/out/pkg/left.a", root .. "/out/pkg/left.so"
        local original = read(archive_path)
        write(companion, "preserve me")
        result = run_cli(nil, "--incremental", "pkg.left")
        assert.is_false(result.ok)
        assert.matches("has native companion", result.output, 1, true)
        local diagnostic = platform.windows and path.to_slash(result.output:gsub("\\\\", "\\")) or result.output
        assert.matches(companion, diagnostic, 1, true)
        assert.equal(original, read(archive_path)); assert.equal("preserve me", read(companion))
    end)

    for _, case in ipairs({
        { mode = "corrupt", message = "unsupported native container format" },
        { mode = "corrupt-member", message = "differs byte-for-byte" },
        { mode = "missing-symbol", message = "requires global non-weak function" },
        { mode = "lto", message = "LLVM bitcode (LTO) object is not supported" },
    }) do
        it("rejects " .. case.mode .. " and publishes nothing", function()
            local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
            prepare(info)
            stage_sdk()
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
        it("diagnoses missing browser SDK for " .. mode .. " linking before executable synthesis", function()
            local info, why = toolchain.require(); if not info then pending(why) return end
            prepare(info)
            write(root .. "/src/pkg/program.titan",
                "function main(args: {string}): integer return 0 end\n")
            local output = root .. "/out/pkg/" .. (mode == "test" and "left" or "program")
            local result = mode == "test" and run_cli(nil, "--test", "pkg.left") or
                run_cli(nil, "pkg.program")
            assert.is_false(result.ok)
            assert.matches("browser SDK is incomplete: missing", result.output, 1, true)
            assert.is_nil(lfs.attributes(root .. "/out/.titan-links"))
            for _, suffix in ipairs({ ".mjs", ".wasm", ".wasm.map", ".wasm.trace" }) do
                assert.is_nil(lfs.attributes(output .. suffix), output .. suffix)
            end
        end)
    end
end)
