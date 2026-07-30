local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local checker = require "titan-compiler.checker"
local driver = require "titan-compiler.driver"
local lfs = require "lfs"
local parser = require "titan-compiler.parser"
local staticmetadata = require "titan-compiler.staticmetadata"
local types = require "titan-compiler.types"

local PREFIX = require("spec.support.installed_prefix").active()
local LUA = PREFIX .. "/bin/lua"

local function quote_argv(argv)
    local quoted = {}
    for index, argument in ipairs(argv) do
        quoted[index] = assert(cdriver.shell_quote(argument))
    end
    return table.concat(quoted, " ")
end

local function run(argv)
    local pipe = assert(io.popen(quote_argv(argv) .. " 2>&1", "r"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    return ok == true, output, why, code
end

local function configured_words(command)
    return assert(cdriver.split_shell_words(command))
end

local function tool_command(configured, ...)
    local argv = configured_words(configured)
    for _, argument in ipairs({ ... }) do argv[#argv + 1] = argument end
    return argv
end

local function make_directory(path)
    if lfs.attributes(path, "mode") == "directory" then return end
    local parent = path:match("^(.+)/[^/]+$")
    if parent then make_directory(parent) end
    assert.truthy(lfs.mkdir(path), "cannot create " .. path)
end

local function write_file(path, contents)
    local parent = path:match("^(.+)/[^/]+$")
    if parent then make_directory(parent) end
    local file = assert(io.open(path, "wb"))
    assert.truthy(file:write(contents))
    assert.truthy(file:close())
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        assert.truthy(lfs.rmdir(path))
    elseif mode then
        assert.truthy(os.remove(path))
    end
end

local function in_directory(path, callback)
    local previous = lfs.currentdir()
    assert.truthy(lfs.chdir(path))
    local results = table.pack(pcall(callback))
    assert.truthy(lfs.chdir(previous))
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

local function compile_c(source, object, body, shared)
    write_file(source, body)
    local argv = configured_words(driver.CC)
    argv[#argv + 1] = shared and "-shared" or "-c"
    argv[#argv + 1] = "-fPIC"
    argv[#argv + 1] = source
    argv[#argv + 1] = "-o"
    argv[#argv + 1] = object
    local ok, output = run(argv)
    assert.truthy(ok, output)
end

local function compile_titan_object(workspace)
    types.registry = {}
    driver.imported = {}
    local source = [[
interface Dynamic
    function convert(input: value): value
end

record Box
    n: integer
end

function Box:convert(input: integer): integer
    return self.n + input
end

function answer(): integer
    local dynamic: Dynamic = Box.new(20)
    return dynamic:convert(22 as value) as integer
end
]]
    local filename = workspace .. "/fixture_target.titan"
    local ast, parse_err = parser.parse(filename, source)
    assert.truthy(ast, parse_err)
    local _, errors = checker.check(
        "fixture.target", ast, source, filename)
    assert.equal(0, #errors, table.concat(errors, "\n"))
    local ok, compile_err, object =
        driver.compile("fixture.target", ast, filename, {}, false)
    assert.truthy(ok, compile_err)
    return object
end

local function make_archive(path, inputs)
    os.remove(path)
    local argv = tool_command(driver.AR, "qD", path)
    for _, input in ipairs(inputs) do argv[#argv + 1] = input end
    local ok, output = run(argv)
    if not ok then
        argv = tool_command(driver.AR, "q", path)
        for _, input in ipairs(inputs) do argv[#argv + 1] = input end
        ok, output = run(argv)
    end
    assert.truthy(ok, output)
    local indexed, index_output =
        run(tool_command(driver.RANLIB, path))
    assert.truthy(indexed, index_output)
end

local function ar_field(value, width)
    local text = tostring(value)
    assert.is_true(#text <= width)
    return text .. string.rep(" ", width - #text)
end

local function archive_bytes(members)
    local records = { "!<arch>\n" }
    for _, member in ipairs(members) do
        local data = member.data
        records[#records + 1] =
            ar_field(member.name, 16) ..
            ar_field(0, 12) ..
            ar_field(0, 6) ..
            ar_field(0, 6) ..
            ar_field(100644, 8) ..
            ar_field(#data, 10) ..
            "`\n" ..
            data ..
            (#data % 2 == 1 and "\n" or "")
    end
    return table.concat(records)
end

local function encode_u32(value, endian)
    local encoded = {}
    for _ = 1, 4 do
        encoded[#encoded + 1] = string.char(value & 0xff)
        value = value >> 8
    end
    if endian == "big" then
        encoded = { encoded[4], encoded[3], encoded[2], encoded[1] }
    end
    return table.concat(encoded)
end

local function patch_target_fingerprint(bytes, fingerprint)
    local offset
    local value
    if fingerprint.format == "elf" then
        offset = fingerprint.class == 64 and 48 or 36
        value = fingerprint.flags ~ 1
    elseif fingerprint.format == "macho" then
        offset = 8 -- Mach-O cpusubtype
        value = fingerprint.cpusubtype ~ 1
    else
        error("unsupported native target in focused test: " ..
            tostring(fingerprint.format))
    end
    local encoded = encode_u32(value, fingerprint.endian)
    return bytes:sub(1, offset) .. encoded ..
        bytes:sub(offset + 5)
end

local function prepare_publication_dsym(staged_dso, public_dso)
    if not driver.IS_DARWIN then return end
    write_file(staged_dso .. ".dSYM/Contents/test-marker", "new dSYM")
    write_file(public_dso .. ".dSYM/Contents/test-marker", "old dSYM")
end

local function executable_script(path, contents)
    write_file(path, contents)
    local ok, output = run({ "chmod", "u+x", path })
    assert.truthy(ok, output)
end

describe("static compiled-module native containers", function()
    local workspace
    local target_object
    local target
    local plain_object
    local input_archive
    local duplicate_one
    local duplicate_two
    local original_ar
    local original_ranlib

    setup(function()
        workspace = os.tmpname() .. " static modules"
        make_directory(workspace)
        original_ar = driver.AR
        original_ranlib = driver.RANLIB

        target_object = compile_titan_object(workspace)
        target = assert(driver.derive_target_fingerprint(
            target_object, "fixture.target"))
        assert.truthy(target.format == "elf" or target.format == "macho",
            "focused suite requires an ELF or Mach-O target")

        plain_object = workspace .. "/-plain payload.o"
        compile_c(workspace .. "/plain payload.c", plain_object,
            "int static_payload(void) { return 7; }\n")

        local first_dir = workspace .. "/first duplicate"
        local second_dir = workspace .. "/second duplicate"
        make_directory(first_dir)
        make_directory(second_dir)
        duplicate_one = first_dir .. "/duplicate.o"
        duplicate_two = second_dir .. "/duplicate.o"
        compile_c(first_dir .. "/duplicate.c", duplicate_one,
            "int first_duplicate(void) { return 1; }\n")
        compile_c(second_dir .. "/duplicate.c", duplicate_two,
            "int second_duplicate(void) { return 2; }\n")
        input_archive = workspace .. "/input payload.a"
        make_archive(input_archive, { duplicate_one, duplicate_two })
    end)

    teardown(function()
        driver.AR = original_ar
        driver.RANLIB = original_ranlib
        driver.imported = {}
        types.registry = {}
        if workspace then remove_tree(workspace) end
    end)

    after_each(function()
        driver.AR = original_ar
        driver.RANLIB = original_ranlib
    end)

    it("derives the authoritative target from one generated module object",
       function()
        local fingerprint, parsed = assert(
            driver.derive_target_fingerprint(
                target_object, "fixture.target"))
        assert.same(target, fingerprint)
        assert.equal("fixture.target", parsed.metadata.module)
        assert.equal(driver.TITAN_VER, parsed.metadata.abi)

        local generated = read_file(workspace .. "/fixture_target.c")
        assert.match(
            '#define TITAN_META_NO_ADDRESS_SANITIZE',
            generated, 1, true)
        assert.match(
            '__attribute__((no_sanitize("address")))',
            generated, 1, true)
        assert.match(
            "TITAN_META_SECTION TITAN_META_NO_ADDRESS_SANITIZE",
            generated, 1, true)

        local wrong, err = driver.derive_target_fingerprint(
            plain_object, "fixture.target")
        assert.falsy(wrong)
        assert.match("has no Titan metadata section", err, 1, true)
    end)

    it("classifies ordered metadata-free -X objects and archives", function()
        local plan = assert(driver.classify_native_payloads({
            plain_object,
            input_archive,
        }, target))
        assert.equal(2, #plan.inputs)
        assert.equal(plain_object, plan.inputs[1].path)
        assert.equal(input_archive, plan.inputs[2].path)
        assert.equal(1, #plan.objects)
        assert.equal(1, #plan.archives)
        assert.equal(2, #plan.archives[1].members)
        assert.equal("duplicate.o",
            plan.archives[1].members[1].display_name)
        assert.equal("duplicate.o",
            plan.archives[1].members[2].display_name)
    end)

    it("rejects metadata-bearing, raw, DSO, thin, nested, and wrong-target -X",
       function()
        local raw = workspace .. "/raw linker script.txt"
        write_file(raw, "INPUT(-lc)\n")

        local dso = workspace .. "/payload.so"
        compile_c(workspace .. "/payload shared.c", dso,
            "int shared_payload(void) { return 3; }\n", true)

        local raw_archive = workspace .. "/raw payload.a"
        -- Darwin ranlib may discard a non-object archive member and leave a
        -- valid empty archive. Write the malformed fixtures directly so this
        -- test exercises Titan's classifier rather than host-tool filtering.
        write_file(raw_archive, archive_bytes({
            { name = "raw.txt/", data = read_file(raw) },
        }))

        local nested_archive = workspace .. "/nested payload.a"
        write_file(nested_archive, archive_bytes({
            { name = "nested.a/", data = read_file(input_archive) },
        }))

        local thin_archive = workspace .. "/thin payload.a"
        local thin_ok = run(
            tool_command(driver.AR, "crT", thin_archive, plain_object))
        local thin_magic = thin_ok and
            read_file(thin_archive):sub(1, 8) == "!<thin>\n"

        local wrong_target = workspace .. "/wrong target.o"
        write_file(wrong_target,
            patch_target_fingerprint(read_file(plain_object), target))

        local cases = {
            { target_object, "contains Titan module metadata" },
            { raw, "unsupported native container format" },
            { dso, "not a relocatable object" },
            { raw_archive, "unsupported native object format" },
            { nested_archive, "nested archive" },
            { wrong_target, "target mismatch" },
        }
        -- GNU ar uses T for a thin archive; Darwin ar uses it to truncate
        -- member names and emits an ordinary archive. Exercise this real-tool
        -- case only when the output itself proves GNU thin semantics.
        if thin_magic then
            cases[#cases + 1] = { thin_archive, "thin archives" }
        end
        for _, case in ipairs(cases) do
            local plan, err =
                driver.classify_native_payloads({ case[1] }, target)
            assert.falsy(plan)
            assert.match(case[2], err, 1, true)
        end
    end)

    it("rejects raw GNU/ELF whole-archive members and retains metadata objects",
       function()
        if driver.IS_DARWIN or target.format ~= "elf" then return end

        local linker_version = configured_words(driver.CC)
        linker_version[#linker_version + 1] = "-Wl,--version"
        local version_ok, version_output = run(linker_version)
        -- mold advertises itself as "compatible with GNU ld", but its
        -- diagnostics are intentionally different. Gate only on GNU BFD
        -- ld's own version line.
        if not version_ok or
           not ("\n" .. version_output):find("\nGNU ld ", 1, true) then
            return
        end

        local raw = workspace .. "/raw metadata.txt"
        write_file(raw, "titan metadata is not an object file\n")
        local raw_archive = workspace .. "/raw member.a"
        local archived, archive_output =
            run(tool_command(driver.AR, "q", raw_archive, raw))
        assert.truthy(archived, archive_output)
        assert.truthy(read_file(raw_archive):find(
            "titan metadata is not an object file", 1, true))

        local function whole_archive(input, output)
            local argv = configured_words(driver.CC)
            for _, argument in ipairs({
                "-r",
                "-Wl,--whole-archive",
                input,
                "-Wl,--no-whole-archive",
                "-o",
                output,
            }) do
                argv[#argv + 1] = argument
            end
            return run(argv)
        end

        local raw_output = workspace .. "/raw linked.o"
        local linked, link_output =
            whole_archive(raw_archive, raw_output)
        assert.falsy(linked, link_output)
        assert.truthy(
            link_output:find("is not an object", 1, true) or
            link_output:find("file format not recognized", 1, true),
            link_output)

        local object_archive = workspace .. "/metadata object.a"
        make_archive(object_archive, { target_object })
        local object_output = workspace .. "/metadata linked.o"
        linked, link_output =
            whole_archive(object_archive, object_output)
        assert.truthy(linked, link_output)

        local fingerprint, parsed = driver.derive_target_fingerprint(
            object_output, "fixture.target")
        assert.truthy(fingerprint, parsed)
        assert.same(target, fingerprint)
        assert.equal("fixture.target", parsed.metadata.module)
        assert.equal(driver.TITAN_VER, parsed.metadata.abi)
    end)

    it("renders platform force-load arguments without losing awkward paths",
       function()
        assert.same({
            "-Wl,--whole-archive",
            input_archive,
            "-Wl,--no-whole-archive",
        }, driver.force_load_arguments({ input_archive }, false))

        local darwin = driver.force_load_arguments({
            { path = input_archive },
        }, true)
        assert.equal("-Xlinker", darwin[1])
        assert.equal("-force_load", darwin[2])
        assert.equal("-Xlinker", darwin[3])
        assert.equal(input_archive, darwin[4])
    end)

    it("builds a flattened ordered archive with duplicate leaf names", function()
        local output = workspace .. "/flattened output.a"
        local result = assert(driver.build_static_archive(
            output,
            { target_object, plain_object },
            { input_archive },
            target,
            false))
        assert.equal("file", lfs.attributes(output, "mode"))
        assert.equal(4, #result.manifest)
        assert.equal(4, #result.archive.members)
        assert.equal("fixture.target",
            result.archive.entries["fixture.target"].module)
        assert.equal(read_file(target_object),
            result.archive.members[1].bytes)
        assert.equal(read_file(plain_object),
            result.archive.members[2].bytes)
        assert.equal(read_file(duplicate_one),
            result.archive.members[3].bytes)
        assert.equal(read_file(duplicate_two),
            result.archive.members[4].bytes)
        assert.equal("duplicate.o",
            result.archive.members[3].display_name)
        assert.equal("duplicate.o",
            result.archive.members[4].display_name)

        local second_output = workspace .. "/flattened again.a"
        local second = assert(driver.build_static_archive(
            second_output,
            { target_object, plain_object },
            { input_archive },
            target,
            false))
        if result.deterministic and second.deterministic then
            assert.equal(read_file(output), read_file(second_output))
        end
    end)

    it("observes configured AR/RANLIB and falls back without deterministic D",
       function()
        local ar_marker = workspace .. "/ar marker"
        local ranlib_marker = workspace .. "/ranlib marker"
        local ar_wrapper = workspace .. "/configured ar"
        local ranlib_wrapper = workspace .. "/configured ranlib"
        executable_script(ar_wrapper, string.format([[#!/bin/sh
printf '%%s\n' "$*" >> %s
if [ "$1" = "qD" ]; then exit 64; fi
exec %s "$@"
]], assert(cdriver.shell_quote(ar_marker)),
            assert(cdriver.shell_quote(configured_words(original_ar)[1]))))
        executable_script(ranlib_wrapper, string.format([[#!/bin/sh
printf '%%s\n' "$*" >> %s
if [ "$1" = "-D" ]; then exit 64; fi
exec %s "$@"
]], assert(cdriver.shell_quote(ranlib_marker)),
            assert(cdriver.shell_quote(configured_words(original_ranlib)[1]))))
        driver.AR = assert(cdriver.shell_quote(ar_wrapper))
        driver.RANLIB = assert(cdriver.shell_quote(ranlib_wrapper))

        local result = assert(driver.build_static_archive(
            workspace .. "/fallback archive.a",
            { target_object, plain_object },
            {},
            target,
            false))
        assert.is_false(result.deterministic)
        local ar_calls = read_file(ar_marker)
        local ranlib_calls = read_file(ranlib_marker)
        assert.match("qD", ar_calls, 1, true)
        assert.match("q ", ar_calls, 1, true)
        assert.match("-D", ranlib_calls, 1, true)
    end)

    it("leaves an existing output untouched when configured AR fails", function()
        local output = workspace .. "/preserved output.a"
        write_file(output, "old output")
        local failing = workspace .. "/failing ar"
        executable_script(failing, "#!/bin/sh\nexit 9\n")
        driver.AR = assert(cdriver.shell_quote(failing))

        local result, err = driver.build_static_archive(
            output, { target_object }, {}, target, false)
        assert.falsy(result)
        assert.match("configured AR", err, 1, true)
        assert.equal("old output", read_file(output))
    end)

    it("links and validates an Interface archive-backed private image",
       function()
        local archive = workspace .. "/protocol archive.a"
        local built = assert(driver.build_static_archive(
            archive, { target_object }, {}, target, false))
        local embedded = assert(built.archive.entries["fixture.target"])
        assert.truthy(embedded.types:find(
            'Interface("fixture.target.Dynamic"', 1, true))
        local image = workspace .. "/archive validation.so"
        local linked, link_err =
            driver.compile_archive_validation_image(
                image, archive, nil, false)
        assert.truthy(linked, link_err)
        local valid, validation_err =
            driver.validate_library_image(
                image, { "fixture.target" })
        assert.truthy(valid, validation_err)

        local equal, equality_err =
            driver.validate_archive_library_equality(
                built.archive, image, { "fixture.target" })
        assert.truthy(equal, equality_err)

        local executed, execution_output = run({
            LUA, "-e", string.format([[
local open = assert(package.loadlib(%q, "luaopen_fixture_target"))
local target = open()
assert(target.answer() == 42)
]], image),
        })
        assert.truthy(executed, execution_output)

        local original = embedded
        local forged = {
            entries = {
                ["fixture.target"] = {
                    abi = original.abi,
                    types = original.types .. " ",
                    payload = original.payload,
                },
            },
        }
        equal, equality_err = driver.validate_archive_library_equality(
            forged, image, { "fixture.target" }, "forged three-way input")
        assert.falsy(equal)
        assert.match("type metadata", equality_err, 1, true)
    end)

    it("compares exact archive logical protocols", function()
        local entry = {
            abi = driver.TITAN_VER,
            types = "Module('fixture.target',{}, {})",
            payload = "canonical",
        }
        assert(driver.compare_archive_entries(
            { ["fixture.target"] = entry },
            { ["fixture.target"] = entry }))
        local ok, err = driver.compare_archive_entries(
            { ["fixture.target"] = entry },
            { ["fixture.target"] = {
                abi = driver.TITAN_VER,
                types = "different",
                payload = "canonical",
            } })
        assert.falsy(ok)
        assert.match("type metadata", err, 1, true)
    end)

    it("rolls back every caught publication boundary including stale shims",
       function()
        local seed = workspace .. "/old-provider-seed.a"
        assert(driver.build_static_archive(
            seed, { target_object }, {}, target, false))
        local old_archive = read_file(seed)
        local public_dso = workspace .. "/provider.so"
        local public_archive = workspace .. "/provider.a"
        local stale_shim = workspace .. "/fixture/target.lua"
        local new_shim = workspace .. "/new/module.lua"
        local old_shim = in_directory(workspace, function()
            return assert(driver.plan_module_shims(
                "provider", { "fixture.target" }))[1].contents
        end)

        for _, failpoint in ipairs({
            "before-shims",
            "after-shims",
            "after-dsym",
            "before-archive",
            "after-archive",
            "before-dso",
            "after-dso",
        }) do
            write_file(public_dso, "old dso")
            write_file(public_archive, old_archive)
            write_file(stale_shim, old_shim)
            os.remove(new_shim)

            local staged_dso = workspace .. "/staged-" .. failpoint .. ".so"
            local staged_archive =
                workspace .. "/staged-" .. failpoint .. ".a"
            write_file(staged_dso, "new dso")
            write_file(staged_archive, read_file(input_archive))
            prepare_publication_dsym(staged_dso, public_dso)

            local published, publish_err = in_directory(workspace, function()
                return driver.publish_provider_bundle(
                    staged_dso, staged_archive, public_dso, {
                        {
                            filename = "new/module.lua",
                            contents = driver.GENERATED_SHIM_BANNER ..
                                "return 'new'\n",
                        },
                    }, {}, {
                        fail_at = failpoint,
                        public_archive = public_archive,
                        provider = "provider",
                    })
            end)
            assert.falsy(published)
            assert.match("injected provider publication failure at " ..
                failpoint, publish_err, 1, true)
            assert.equal("old dso", read_file(public_dso))
            assert.equal(old_archive, read_file(public_archive))
            assert.equal(old_shim, read_file(stale_shim))
            assert.is_nil(lfs.symlinkattributes(new_shim))
            if driver.IS_DARWIN then
                assert.equal("old dSYM", read_file(
                    public_dso .. ".dSYM/Contents/test-marker"))
            end
            os.remove(staged_dso)
            os.remove(staged_archive)
            if lfs.symlinkattributes(staged_dso .. ".dSYM") then
                remove_tree(staged_dso .. ".dSYM")
            end
        end
    end)

    it("preserves an identical recursive Darwin dSYM tree", function()
        local original_is_darwin = driver.IS_DARWIN
        local checked = table.pack(pcall(function()
            driver.IS_DARWIN = true
            local public_dso = workspace .. "/darwin-provider.so"
            local public_archive = workspace .. "/darwin-provider.a"
            local staged_dso = workspace .. "/darwin-staged.so"
            local staged_archive = workspace .. "/darwin-staged.a"
            local public_shim = workspace .. "/same/module.lua"
            local shim_contents = driver.GENERATED_SHIM_BANNER ..
                "return 'same'\n"
            local dso_contents = "identical provider DSO"
            local archive_contents = read_file(input_archive)
            write_file(public_dso, dso_contents)
            write_file(staged_dso, dso_contents)
            write_file(public_archive, archive_contents)
            write_file(staged_archive, archive_contents)
            write_file(public_shim, shim_contents)

            local relative_marker =
                ".dSYM/Contents/Resources/DWARF/provider"
            write_file(public_dso .. relative_marker, "identical symbols")
            write_file(staged_dso .. relative_marker, "identical symbols")
            write_file(public_dso .. ".dSYM/Contents/Info.plist",
                "identical metadata")
            write_file(staged_dso .. ".dSYM/Contents/Info.plist",
                "identical metadata")

            local preserved_mtime = os.time() + 60
            for _, path in ipairs({
                public_dso,
                public_archive,
                public_shim,
                public_dso .. relative_marker,
            }) do
                assert.truthy(lfs.touch(
                    path, preserved_mtime, preserved_mtime))
            end

            local published, public_static =
                driver.publish_provider_bundle(
                    staged_dso, staged_archive, public_dso, {
                        {
                            filename = public_shim,
                            contents = shim_contents,
                        },
                    }, {}, {
                        public_archive = public_archive,
                        provider = "darwin-provider",
                    })
            assert.truthy(published, public_static)
            assert.equal(public_archive, public_static)
            assert.is_nil(lfs.symlinkattributes(staged_dso))
            assert.is_nil(lfs.symlinkattributes(staged_archive))
            assert.is_nil(lfs.symlinkattributes(staged_dso .. ".dSYM"))
            assert.equal(preserved_mtime,
                lfs.attributes(public_dso, "modification"))
            assert.equal(preserved_mtime,
                lfs.attributes(public_archive, "modification"))
            assert.equal(preserved_mtime,
                lfs.attributes(public_shim, "modification"))
            assert.equal(preserved_mtime, lfs.attributes(
                public_dso .. relative_marker, "modification"))
        end))
        driver.IS_DARWIN = original_is_darwin
        if not checked[1] then error(checked[2], 0) end
    end)

    it("retires only exact old-provider stale shims on successful publication",
       function()
        local seed = workspace .. "/old-provider-seed.a"
        assert(driver.build_static_archive(
            seed, { target_object }, {}, target, false))
        local old_archive = read_file(seed)
        local public_dso = workspace .. "/provider.so"
        local public_archive = workspace .. "/provider.a"
        local stale_shim = workspace .. "/fixture/target.lua"
        local old_shim = in_directory(workspace, function()
            return assert(driver.plan_module_shims(
                "provider", { "fixture.target" }))[1].contents
        end)

        local function publish_with_shim(contents)
            write_file(public_dso, "old dso")
            write_file(public_archive, old_archive)
            write_file(stale_shim, contents)
            local staged_dso = workspace .. "/staged-provider.so"
            local staged_archive = workspace .. "/staged-provider.a"
            write_file(staged_dso, "new dso")
            write_file(staged_archive, read_file(input_archive))
            prepare_publication_dsym(staged_dso, public_dso)
            local published, public_static = in_directory(
                workspace, function()
                    return driver.publish_provider_bundle(
                        staged_dso, staged_archive, public_dso, {}, {}, {
                            public_archive = public_archive,
                            provider = "provider",
                        })
                end)
            return published, public_static
        end

        local published, public_static = publish_with_shim(old_shim)
        assert.truthy(published, public_static)
        assert.equal(public_archive, public_static)
        assert.equal("new dso", read_file(public_dso))
        assert.equal(read_file(input_archive), read_file(public_archive))
        assert.is_nil(lfs.symlinkattributes(stale_shim))

        -- The banner alone is not ownership: provider and entry must still
        -- match the exact old generated template.
        local modified = old_shim .. "-- user modification\n"
        published, public_static = publish_with_shim(modified)
        assert.falsy(published)
        assert.match("refusing to retire unrecognized old Lua shim",
            public_static, 1, true)
        assert.equal("old dso", read_file(public_dso))
        assert.equal(old_archive, read_file(public_archive))
        assert.equal(modified, read_file(stale_shim))
    end)

    it("rejects nonregular provider destinations and native input aliases",
       function()
        local public_dso = workspace .. "/unsafe.so"
        local public_archive = workspace .. "/unsafe.a"
        make_directory(public_archive)
        local ok, err =
            driver.validate_provider_output_paths(public_dso, {})
        assert.falsy(ok)
        assert.match("nonregular native provider path", err, 1, true)
        remove_tree(public_archive)

        write_file(public_dso, "selected dynamic input")
        ok, err = driver.validate_provider_output_paths(
            public_dso, { public_dso })
        assert.falsy(ok)
        assert.match("aliases input", err, 1, true)

        local real = workspace .. "/real"
        make_directory(real .. "/sub")
        local real_provider = real .. "/provider.so"
        write_file(real_provider, "same selected provider")
        local linked, link_output = run({
            "ln", "-s", real .. "/sub", workspace .. "/provider-link",
        })
        assert.truthy(linked, link_output)
        ok, err = driver.validate_provider_output_paths(
            real_provider, {
                workspace .. "/provider-link/../provider.so",
            })
        assert.falsy(ok)
        assert.match("aliases input", err, 1, true)
    end)

    it("rechecks planned shim ownership at publication", function()
        local plans, public_dso = in_directory(workspace, function()
            return driver.plan_module_shims(
                "provider", { "fixture.target" })
        end)
        assert.truthy(plans, public_dso)
        local public_shim = workspace .. "/fixture/target.lua"
        write_file(public_shim, "return 'user file'\n")
        local staged_dso = workspace .. "/staged-provider.so"
        local staged_archive = workspace .. "/staged-provider.a"
        write_file(staged_dso, "new dso")
        write_file(staged_archive, read_file(input_archive))
        prepare_publication_dsym(
            staged_dso, workspace .. "/provider.so")

        local published, publish_err = in_directory(workspace, function()
            return driver.publish_provider_bundle(
                staged_dso, staged_archive, public_dso,
                plans, {}, { provider = "provider" })
        end)
        assert.falsy(published)
        assert.match("refusing to overwrite unrecognized Lua file",
            publish_err, 1, true)
        assert.equal("return 'user file'\n", read_file(public_shim))
        assert.equal("new dso", read_file(staged_dso))
        assert.equal(read_file(input_archive), read_file(staged_archive))
    end)
end)
