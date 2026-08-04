local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local driver = require "titan-compiler.driver"
local lfs = require "lfs"
local staticmetadata = require "titan-compiler.staticmetadata"

local REPO = lfs.currentdir()
local PREFIX = require("spec.support.installed_prefix").active()
local LUA = PREFIX .. "/bin/lua"
local USE_CHECKOUT_COMPILER =
    os.getenv("TITAN_TEST_USE_CHECKOUT_COMPILER") == "1"

local function exists(path)
    return lfs.attributes(path, "mode") ~= nil
end

local function quote_argv(argv)
    local quoted = {}
    for index, argument in ipairs(argv) do
        quoted[index] = assert(cdriver.shell_quote(argument))
    end
    return table.concat(quoted, " ")
end

local function run(argv, cwd)
    local previous = lfs.currentdir()
    assert.truthy(lfs.chdir(cwd))
    local pipe = assert(io.popen(quote_argv(argv) .. " 2>&1", "r"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    assert.truthy(lfs.chdir(previous))
    return ok == true, output, why, code
end

local function make_directory(path)
    if lfs.attributes(path, "mode") == "directory" then return end
    local parent = path:match("^(.+)/[^/]+$")
    if parent then make_directory(parent) end
    assert.truthy(lfs.mkdir(path), "could not create " .. path)
end

local function write_file(path, contents)
    local parent = assert(path:match("^(.+)/[^/]+$"))
    make_directory(parent)
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

local function compiler_argv(workspace, source_root, ...)
    local argv = {
        "env",
        "-u", "LUA_PATH", "-u", "LUA_PATH_5_5",
        "-u", "LUA_CPATH", "-u", "LUA_CPATH_5_5",
        "CCACHE_DISABLE=1",
        "TITAN_PATH_0_21=" .. workspace,
        "TITAN_PATH=",
        "PATH=" .. PREFIX .. "/bin:/usr/bin:/bin",
    }

    local installed = not USE_CHECKOUT_COMPILER and
        exists(PREFIX .. "/bin/titanc")
    if installed then
        argv[#argv + 1] = PREFIX .. "/bin/titanc"
    else
        argv[#argv + 1] = "TITAN_ROCKS_ROOT=" .. PREFIX
        argv[#argv + 1] = "LUA_CPATH=" .. REPO .. "/?.so;;"
        argv[#argv + 1] = LUA
        argv[#argv + 1] = "-e"
        argv[#argv + 1] = string.format(
            "package.path=%q..package.path", REPO .. "/?.lua;" ..
                REPO .. "/?/init.lua;")
        argv[#argv + 1] = REPO .. "/titanc"
    end

    argv[#argv + 1] = "--tree"
    argv[#argv + 1] = source_root
    for _, argument in ipairs({ ... }) do argv[#argv + 1] = argument end
    return argv
end

local function compile(workspace, source_root, ...)
    return run(compiler_argv(workspace, source_root, ...), workspace)
end

local function configured_words(command)
    return assert(cdriver.split_shell_words(command))
end

local function make_archive(path, object)
    local argv = configured_words(driver.AR)
    argv[#argv + 1] = "rcs"
    argv[#argv + 1] = path
    argv[#argv + 1] = object
    local ok, output = run(argv, path:match("^(.+)/[^/]+$"))
    assert.truthy(ok, output)

    argv = configured_words(driver.RANLIB)
    argv[#argv + 1] = path
    ok, output = run(argv, path:match("^(.+)/[^/]+$"))
    assert.truthy(ok, output)
end

local function metadata_options()
    return {
        expected_abi = driver.TITAN_VER,
        validate_types = function(name, serialized, origin)
            return driver.decode_module_interface(serialized, name, origin)
        end,
    }
end

local function scan_archive(path)
    local archive, err =
        staticmetadata.scan_archive(path, metadata_options())
    assert.truthy(archive, err)
    return archive
end

local function metadata_initializer(csource, modname)
    local symbol =
        driver.mangle_module_name(modname) .. "_titan_metadata"
    local header =
        "static const unsigned char " .. symbol .. "[] = "
    local _, header_end = csource:find(header, 1, true)
    assert.truthy(header_end, "missing generated metadata array " .. symbol)
    local value_start = header_end + 1
    assert.equal("{", csource:sub(value_start, value_start),
        "malformed generated metadata initializer for " .. symbol)
    local declaration_end = csource:find(";", value_start, true)
    assert.truthy(declaration_end,
        "missing generated metadata terminator for " .. symbol)
    local value_end = declaration_end - 1
    while csource:sub(value_end, value_end):match("%s") do
        value_end = value_end - 1
    end
    assert.equal("}", csource:sub(value_end, value_end),
        "malformed generated metadata terminator for " .. symbol)
    return csource:sub(value_start, value_end), value_start, value_end
end

local function callable_types_source(csource, modname)
    local prefix = driver.mangle_module_name(modname)
    local start_at = csource:find("int " .. prefix .. "_types(", 1, true)
    assert.truthy(start_at, "missing callable types function")
    local finish_at =
        csource:find("int " .. prefix .. "_abi(", start_at, true)
    assert.truthy(finish_at, "missing callable ABI function")
    return csource:sub(start_at, finish_at - 1)
end

local function compile_command(verbose_output, source)
    for line in verbose_output:gmatch("[^\r\n]+") do
        local argv = cdriver.split_shell_words(line)
        if argv then
            local has_source = false
            local compiles = false
            for _, argument in ipairs(argv) do
                if argument == source then has_source = true end
                if argument == "-c" then compiles = true end
            end
            if has_source and compiles then return argv end
        end
    end
    error("could not recover verbose compile command for " .. source, 0)
end

local function replace_argument(argv, old, new)
    local replaced = 0
    local copy = {}
    for index, argument in ipairs(argv) do
        if argument == old then
            copy[index] = new
            replaced = replaced + 1
        else
            copy[index] = argument
        end
    end
    assert.equal(1, replaced,
        "expected one command argument matching " .. old)
    return copy
end

local function insert_argument_before(argv, marker, argument)
    local inserted = 0
    local copy = {}
    for _, current in ipairs(argv) do
        if current == marker then
            copy[#copy + 1] = argument
            inserted = inserted + 1
        end
        copy[#copy + 1] = current
    end
    assert.equal(1, inserted,
        "expected one command argument matching " .. marker)
    return copy
end

local function assert_absent(path)
    assert.is_nil(lfs.symlinkattributes(path),
        "unexpected public output " .. path)
end

describe("forged static section/callable protocol mismatch", function()
    local workspace

    before_each(function()
        workspace = os.tmpname()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))
    end)

    after_each(function()
        if workspace then remove_tree(workspace) end
    end)

    it("rejects the selected archive before library or executable publication",
       function()
        local modname = "protocol.api"
        local original = workspace .. "/original"
        local alternate = workspace .. "/alternate"
        local original_source = original .. "/source"
        local alternate_source = alternate .. "/source"
        local original_titan =
            original_source .. "/protocol/api.titan"
        local alternate_titan =
            alternate_source .. "/protocol/api.titan"
        write_file(original_titan, [[
function stable(n: integer): integer
    return n
end
]])
        write_file(alternate_titan, [[
function stable(renamed: integer): integer
    return renamed
end
]])

        local ok, output, why, code =
            compile(original, original_source, "-v", modname)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local original_verbose = output
        ok, output, why, code =
            compile(alternate, alternate_source, modname)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        local original_c = original_titan:gsub("[.]titan$", ".c")
        local alternate_c = alternate_titan:gsub("[.]titan$", ".c")
        local original_o = original_titan:gsub("[.]titan$", ".o")
        local original_csource = read_file(original_c)
        local alternate_csource = read_file(alternate_c)
        local original_initializer, original_start, original_end =
            metadata_initializer(original_csource, modname)
        local alternate_initializer =
            metadata_initializer(alternate_csource, modname)
        assert.not_equal(original_initializer, alternate_initializer)

        local forged_c = workspace .. "/forged/protocol_api.c"
        local forged_o = workspace .. "/forged/protocol_api.o"
        local forged_csource =
            original_csource:sub(1, original_start - 1) ..
            alternate_initializer ..
            original_csource:sub(original_end + 1)
        write_file(forged_c, forged_csource)
        assert.equal(
            callable_types_source(original_csource, modname),
            callable_types_source(forged_csource, modname))
        assert.not_equal(
            callable_types_source(alternate_csource, modname),
            callable_types_source(forged_csource, modname))

        local argv =
            compile_command(original_verbose, original_c)
        argv = replace_argument(argv, original_c, forged_c)
        argv = replace_argument(argv, original_o, forged_o)
        ok, output, why, code = run(argv, workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        local selected_archive = workspace .. "/protocol/api.a"
        make_directory(workspace .. "/protocol")
        make_archive(selected_archive, forged_o)
        local original_archive =
            scan_archive(original .. "/protocol/api.a")
        local alternate_archive =
            scan_archive(alternate .. "/protocol/api.a")
        local forged_archive = scan_archive(selected_archive)
        local original_entry = original_archive.entries[modname]
        local alternate_entry = alternate_archive.entries[modname]
        local forged_entry = forged_archive.entries[modname]
        assert.not_equal(original_entry.types, alternate_entry.types)
        assert.equal(alternate_entry.types, forged_entry.types)
        assert.equal(original_entry.abi, forged_entry.abi)

        local validation_image =
            workspace .. "/forged/archive-validation.so"
        local linked, link_term, link_code =
            driver.compile_archive_validation_image(
                validation_image, selected_archive, nil, false)
        assert.truthy(linked, table.concat({
            tostring(link_term), tostring(link_code),
        }, ", "))
        local valid, validation_err =
            driver.validate_library_image(validation_image, { modname })
        assert.truthy(valid, validation_err)
        local callable, callable_err =
            driver.library_interface_entries(
                validation_image, { modname })
        assert.truthy(callable, callable_err)
        assert.equal(original_entry.types, callable[modname].types)
        assert.not_equal(forged_entry.types, callable[modname].types)

        local equal, equality_err =
            driver.validate_archive_library_equality(
                forged_archive, validation_image, { modname },
                "forged selected archive '" .. selected_archive .. "'")
        assert.falsy(equal)
        assert.truthy(equality_err:find(selected_archive, 1, true),
            equality_err)
        assert.truthy(equality_err:find(
            "type metadata for module 'protocol.api' differs", 1, true),
            equality_err)

        local consumer_source = workspace .. "/source"
        write_file(consumer_source .. "/consumer/lib.titan", [[
local api = import "protocol.api"

function read(): integer
    return api.stable(42)
end
]])
        ok, output, why, code = compile(
            workspace, consumer_source, "-v", "--static", "consumer.lib")
        assert.falsy(ok, output)
        assert.truthy(output:find(selected_archive, 1, true), output)
        assert.truthy(output:find(
            "staged provider pair for 'consumer.lib'", 1, true), output)
        assert.truthy(output:find(
            "type metadata for module 'protocol.api' differs", 1, true),
            output)
        assert_absent(workspace .. "/consumer/lib.so")
        assert_absent(workspace .. "/consumer/lib.a")
        assert_absent(workspace .. "/consumer/lib.lua")
        assert_absent(workspace .. "/protocol/api.so")
        assert_absent(workspace .. "/protocol/api.lua")

        write_file(consumer_source .. "/app.titan", [[
local api = import "protocol.api"

function main(args: {string}): integer
    return api.stable(0)
end
]])
        ok, output, why, code =
            compile(workspace, consumer_source, "-v", "--static", "app")
        assert.falsy(ok, output)
        assert.truthy(output:find(selected_archive, 1, true), output)
        assert.truthy(output:find(
            "selected static provider failed executable-context " ..
            "protocol validation", 1, true), output)
        assert.truthy(output:find("exit 24", 1, true), output)
        assert_absent(workspace .. "/app")
    end)

    it("rejects every missing selected-archive protocol before publication",
       function()
        local modname = "protocol.api"
        local provider = workspace .. "/provider"
        local provider_source = provider .. "/source"
        local provider_titan =
            provider_source .. "/protocol/api.titan"
        write_file(provider_titan, [[
function stable(n: integer): integer
    return n
end
]])

        local ok, output, why, code =
            compile(provider, provider_source, "-v", modname)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local provider_verbose = output
        local provider_c = provider_titan:gsub("[.]titan$", ".c")
        local provider_o = provider_titan:gsub("[.]titan$", ".o")
        local provider_archive = scan_archive(
            provider .. "/protocol/api.a")
        local provider_entry = assert(provider_archive.entries[modname])

        local consumer_source = workspace .. "/source"
        write_file(consumer_source .. "/consumer/lib.titan", [[
local api = import "protocol.api"

function read(): integer
    return api.stable(42)
end
]])
        write_file(consumer_source .. "/app.titan", [[
local api = import "protocol.api"

function main(args: {string}): integer
    return api.stable(0)
end
]])

        local prefix = driver.mangle_module_name(modname)
        local protocols = {
            { name = "ABI", symbol = prefix .. "_abi" },
            { name = "types", symbol = prefix .. "_types" },
            { name = "initializer", symbol = prefix .. "_init" },
            { name = "Lua open", symbol = "luaopen_" .. prefix },
        }
        local compile_template =
            compile_command(provider_verbose, provider_c)
        local forged_directory = workspace .. "/forged"
        local forged_o = forged_directory .. "/protocol_api.o"
        local selected_archive = workspace .. "/protocol/api.a"
        make_directory(forged_directory)
        make_directory(workspace .. "/protocol")

        for _, protocol in ipairs(protocols) do
            local argv = replace_argument(
                compile_template, provider_o, forged_o)
            argv = insert_argument_before(
                argv, provider_c,
                "-D" .. protocol.symbol .. "=" ..
                    protocol.symbol .. "_missing")
            ok, output, why, code = run(argv, workspace)
            assert.truthy(ok, protocol.name .. " forge failed:\n" ..
                output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")

            os.remove(selected_archive)
            make_archive(selected_archive, forged_o)
            local forged_archive = scan_archive(selected_archive)
            local forged_entry =
                assert(forged_archive.entries[modname])
            assert.equal(provider_entry.abi, forged_entry.abi)
            assert.equal(provider_entry.types, forged_entry.types)

            ok, output = compile(
                workspace, consumer_source, "-v", "--static",
                "consumer.lib")
            assert.falsy(ok, protocol.name ..
                " omission unexpectedly published a library pair:\n" ..
                output)
            assert.truthy(output:find(protocol.symbol, 1, true),
                protocol.name .. " library diagnostic:\n" .. output)
            assert_absent(workspace .. "/consumer/lib.so")
            assert_absent(workspace .. "/consumer/lib.a")
            assert_absent(workspace .. "/consumer/lib.lua")
            assert_absent(workspace .. "/protocol/api.so")
            assert_absent(workspace .. "/protocol/api.lua")

            ok, output = compile(
                workspace, consumer_source, "-v", "--static", "app")
            assert.falsy(ok, protocol.name ..
                " omission unexpectedly published an executable:\n" ..
                output)
            assert.truthy(output:find(
                "selected static provider failed executable-context " ..
                    "protocol linking", 1, true),
                protocol.name .. " executable diagnostic:\n" .. output)
            assert.truthy(output:find(protocol.symbol, 1, true),
                protocol.name .. " executable diagnostic:\n" .. output)
            assert_absent(workspace .. "/app")
        end
    end)
end)
