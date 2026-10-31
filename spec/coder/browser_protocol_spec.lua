local assert = require "luassert"
local browserlink = require "titan-compiler.browserlink"
local compiler_io = require "titan-compiler.io"
local files = require "spec.fixtures.target_selection.support"
local fixtures = require "spec.support.browser_fixtures"
local lfs = require "lfs"
local temporary = require "spec.support.temporary"
local toolchain = require "spec.support.browser_toolchain"
local repository = assert(lfs.currentdir())
local workspace, prefix, effective_root

-- Deliberately callable, structurally valid corruption. The executing probe,
-- not missing symbols or malformed metadata, must reject these providers.
local HOOK = [[
local driver = require "titan-compiler.driver"
local metadata = require "titan-compiler.staticmetadata"
local util = require "titan-compiler.util"
local cdriver = require "c-parser.cdriver"
local original = driver.link_provider_pair
function driver.link_provider_pair(request)
    local mode = os.getenv("TITAN_PROTOCOL_CORRUPTION")
    if mode and mode ~= "" then
        local filename = request.generated_objects[1].filename
        local parsed = assert(metadata.classify_object(assert(util.get_file_contents(filename, "rb")),
            filename, request.target))
        local entry = assert(parsed.metadata)
        local symbol = driver.mangle_module_name(entry.module)
        local source = '#include "titan.h"\n' ..
            '__attribute__((used, aligned(1), section(".titan.meta")))\n' ..
            'static const unsigned char fixture_metadata[] = ' .. assert(metadata.c_initializer(entry.payload)) .. ';\n'
        for _, field in ipairs({ "abi", "types", "layouts" }) do
            local value = entry[field]
            if mode == field .. "-bytes" then value = value .. "corrupt" end
            source = source .. 'static const unsigned char fixture_' .. field .. '[] = ' ..
                assert(metadata.c_initializer(value)) .. ';\nint ' .. symbol .. '_' .. field .. '(lua_State *L) { '
            if mode == field .. "-shape" then
                source = source .. 'lua_pushinteger(L, 9); return 1; }\n'
            else
                source = source .. 'lua_pushlstring(L, (const char *)fixture_' .. field .. ', ' .. #value .. '); return 1; }\n'
            end
        end
        source = source .. 'void *' .. symbol .. '_init(lua_State *L) { (void)L; return NULL; }\n' ..
            'int luaopen_' .. symbol .. '(lua_State *L) { (void)L; return 0; }\n'
        local cfile = filename .. '.protocol-fixture.c'
        assert(util.set_file_contents(cfile, source))
        local argv = assert(driver.generated_compile_prefix(request.context))
        for _, argument in ipairs({ "-c", cfile, "-o", filename }) do argv[#argv + 1] = argument end
        local quoted = {}
        for index, argument in ipairs(argv) do quoted[index] = assert(cdriver.shell_quote(argument)) end
        assert(os.execute(table.concat(quoted, " ")))
    end
    return original(request)
end
local probe = driver.run_standalone_archive_probe
function driver.run_standalone_archive_probe(...)
    local file = assert(io.open(assert(os.getenv("TITAN_PROTOCOL_LOG")), "ab"))
    assert(file:write("execute\n")); assert(file:close())
    return probe(...)
end
local image = driver.compile_browser_image
function driver.compile_browser_image(contents, entrypoint, executable, objects, archives, extra, verbose, options)
    if options.profile and options.profile.purpose == "protocol" then
        local file = assert(io.open(assert(os.getenv("TITAN_PROTOCOL_IMAGES")), "ab"))
        assert(file:write(entrypoint, "\n", executable, "\n")); assert(file:close())
    end
    return image(contents, entrypoint, executable, objects, archives, extra, verbose, options)
end
]]

local function prepare(info)
    workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
    prefix = workspace .. "/prefix"; effective_root = prefix
    files.mkdir(prefix .. "/lib")
    assert(lfs.link(info.prefix .. "/lib/browser", prefix .. "/lib/browser", true))
    assert(lfs.link(info.prefix .. "/include", prefix .. "/include", true))
    local source = browserlink.sdk_assets(fixtures.paths(info.prefix))
    local destination = browserlink.sdk_assets(fixtures.paths(prefix))
    for _, key in ipairs({ "runtime", "js_library", "loader", "runner", "runner_module", "node_worker", "page" }) do
        files.copy(source[key], destination[key])
    end
    -- The source launcher is executable; binary copying alone does not retain it.
    assert(compiler_io.new_sync():run({ "chmod", "+x", destination.runner }).ok)
    files.write(workspace .. "/hook.lua", HOOK)
    files.write(workspace .. "/src/pkg/left.titan", "function answer(): integer return 42 end\n")
    files.write(workspace .. "/src/pkg/right.titan", "function twice(n: integer): integer return n * 2 end\n")
end

local function cli(info, mode, ...)
    local setup = string.format("package.path=%q..package.path; dofile(%q);",
        repository .. "/?.lua;" .. repository .. "/?/init.lua;", workspace .. "/hook.lua")
    local argv = { "env", "TITAN_ROOT=" .. effective_root, "TITAN_TARGET=", "TITAN_PATH_0_6=" .. workspace .. "/providers",
        "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
        "TITAN_PROTOCOL_CORRUPTION=" .. (mode or ""), "TITAN_PROTOCOL_LOG=" .. workspace .. "/executions",
        "TITAN_PROTOCOL_IMAGES=" .. workspace .. "/probe-images",
        info.prefix .. "/bin/lua", "-E", "-e", setup, repository .. "/titanc", "-q", "--target", "browser",
        "--tree", workspace .. "/src", "--output", workspace .. "/out" }
    for _, argument in ipairs({ ... }) do argv[#argv + 1] = argument end
    return compiler_io.new_sync():run(argv, { stderr_to_stdout = true })
end

local function no_staged_images(directory)
    if directory == workspace .. "/out" then
        for filename in files.read(workspace .. "/probe-images"):gmatch("[^\n]+") do
            assert.is_nil(lfs.symlinkattributes(filename), filename)
            assert.is_nil(lfs.symlinkattributes((filename:gsub("[.]c$", ".o"))), filename)
            assert.is_nil(lfs.symlinkattributes((filename:gsub("[.]mjs$", ".wasm"))), filename)
        end
    end
    if lfs.symlinkattributes(directory, "mode") ~= "directory" then return end
    for entry in lfs.dir(directory) do
        if entry ~= "." and entry ~= ".." then
            assert.is_nil(entry:find(".stage.tmp.", 1, true), entry)
            assert.is_nil(entry:match("[.]mjs$"), entry)
            assert.is_nil(entry:match("[.]wasm$"), entry)
            no_staged_images(directory .. "/" .. entry)
        end
    end
end

describe("browser executing provider protocol", function()
    after_each(function()
        if workspace then files.remove(workspace); workspace = nil end
    end)

    for _, case in ipairs({ { "abi-shape", 21 }, { "abi-bytes", 22 }, { "types-shape", 23 },
            { "types-bytes", 24 }, { "layouts-shape", 25 }, { "layouts-bytes", 26 } }) do
        it("executes and rejects " .. case[1] .. " without publishing an archive", function()
            local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
            prepare(info)
            local result = cli(info, case[1], "pkg.left")
            assert.is_false(result.ok, result.output)
            assert.truthy(result.output:find("selected static provider failed executable-context protocol validation " ..
                "(browser runner exit " .. case[2] .. ")", 1, true), result.output)
            assert.is_nil(lfs.attributes(workspace .. "/out/pkg/left.a"))
            assert.equal("execute\n", files.read(workspace .. "/executions"))
            no_staged_images(workspace .. "/out")
        end)
    end

    it("preserves a predecessor and removes staged images when callable protocol bytes change", function()
        local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        prepare(info)
        local result = cli(info, nil, "--incremental", "pkg.left")
        assert.is_true(result.ok, result.output)
        local filename = workspace .. "/out/pkg/left.a"
        local predecessor = files.read(filename)
        files.write(workspace .. "/src/pkg/left.titan", "function answer(): integer return 43 end\n")
        result = cli(info, "types-bytes", "--incremental", "pkg.left")
        assert.is_false(result.ok, result.output)
        assert.truthy(result.output:find("browser runner exit 24", 1, true), result.output)
        assert.equal(predecessor, files.read(filename))
        no_staged_images(workspace .. "/out")
    end)

    it("executes again before identical-archive reuse when a required JS input changes", function()
        local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        prepare(info)
        local result = cli(info, nil, "--incremental", "pkg.left")
        assert.is_true(result.ok, result.output)
        local filename = workspace .. "/out/pkg/left.a"
        local predecessor = files.read(filename)
        local library = browserlink.sdk_assets(fixtures.paths(prefix)).js_library
        files.write(library, files.read(library) .. "\n// Required-input identity mutation.\n")
        result = cli(info, nil, "--incremental", "pkg.left")
        assert.is_true(result.ok, result.output)
        assert.equal(predecessor, files.read(filename))
        assert.equal("execute\nexecute\n", files.read(workspace .. "/executions"))
        no_staged_images(workspace .. "/out")
    end)

    it("runs an archive-only consumer with the producer source hidden on both engines", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true }); if not info then pending(why) return end
        prepare(info)
        local result = cli(info, nil, "pkg.left", "pkg.right")
        assert.is_true(result.ok, result.output)
        files.copy(workspace .. "/out/pkg.a", workspace .. "/providers/pkg.a")
        assert(os.rename(workspace .. "/src/pkg", workspace .. "/hidden-producer"))
        assert.is_nil(lfs.attributes(workspace .. "/src/pkg"))
        files.write(workspace .. "/src/consumer.titan", [[
local test = import "test"
local left = import "pkg.left"
local right = import "pkg.right"
function test_left(context: test.Context)
    test.assert(left.answer() == 42)
end
function test_right(context: test.Context)
    test.assert(right.twice(21) == 42)
end
]])
        effective_root = info.prefix
        result = cli(info, nil, "--test", "--incremental", "consumer")
        assert.is_true(result.ok, result.output)
        for _, engine in ipairs({ "node", "chromium" }) do
            local argv = { info.sdk_root .. "/titan-browser-run", "--engine", engine, "--grace", "0" }
            if engine == "chromium" then argv[#argv + 1] = "--chrome"; argv[#argv + 1] = info.chrome.path end
            argv[#argv + 1] = workspace .. "/out/consumer.mjs"
            result = compiler_io.new_sync():run(argv, { stderr_to_stdout = true })
            assert.is_true(result.ok, result.output)
            assert.truthy(result.output:find("[==========] 2 tests ran.", 1, true), result.output)
            assert.truthy(result.output:find("[  PASSED  ] 2 tests.", 1, true), result.output)
        end
    end)
end)
