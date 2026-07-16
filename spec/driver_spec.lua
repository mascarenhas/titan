local lfs = require "lfs"
local assert = require "luassert"

local driver = require "titan-compiler.driver"
local types = require "titan-compiler.types"
local util = require "titan-compiler.util"
local titan = require "titan"

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    file:write(contents)
    file:close()
end

local function remove_tree(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        assert(lfs.rmdir(path))
    elseif mode then
        assert(os.remove(path))
    end
end

describe("compiler installation discovery", function()
    it("uses the first literal Lua 5.5 C-module prefix", function()
        local cpath = table.concat({
            "/first prefix/lib/titan/0.15/?.so",
            "/wrong/lib/lua/5.4/?.so",
            "/also-wrong/lib/lua/5.5/?.dylib",
            "/first prefix/lib/lua/5.5/?.so",
            "/second/lib/lua/5.5/?.so",
        }, ";")
        assert.equal("/first prefix",
            driver.root_from_package_cpath(cpath))
    end)

    it("rejects suffix lookalikes and handles the filesystem root", function()
        assert.is_nil(driver.root_from_package_cpath(table.concat({
            "/prefix/lib/lua/5.5/?x.so",
            "/prefix/lib/lua/5.5/?.so.debug",
            "/prefix/lib/lua/5.5/sub/?.so",
        }, ";")))
        assert.equal("/", driver.root_from_package_cpath(
            "/lib/lua/5.5/?.so;/later/lib/lua/5.5/?.so"))
        assert.is_nil(driver.root_from_package_cpath(nil))
    end)

    it("gives the internal installation override precedence", function()
        assert.equal("/post-install/tree", driver.resolve_installation_root(
            "/lua/prefix/lib/lua/5.5/?.so", "/post-install/tree/"))
        assert.equal("/lua/prefix", driver.resolve_installation_root(
            "/lua/prefix/lib/lua/5.5/?.so", ""))
    end)

    it("derives all installed compiler paths from one root", function()
        local paths = assert(driver.installed_paths("/opt/titan/"))
        assert.same({
            root = "/opt/titan",
            lua_source = "/opt/titan/src/lua-5.5.0",
            include = "/opt/titan/include",
            lib = "/opt/titan/lib",
            libtitan = "/opt/titan/lib/libtitan.a",
            libbacktrace = "/opt/titan/lib/libbacktrace.a",
            liblua = "/opt/titan/lib/liblua.a",
            titan_bin = "/opt/titan/lib/titan/0.15",
            lua_cpath = "/opt/titan/lib/titan/0.15/?.so",
        }, paths)

        assert.same({
            "/opt/titan/lib/libtitan.a",
            "/opt/titan/lib/libbacktrace.a",
            "/opt/titan/lib/liblua.a",
            "-ldl", "-lm",
        }, driver.installed_link_inputs(paths, false))
        assert.same({
            "/opt/titan/lib/libtitan.a",
            "/opt/titan/lib/libbacktrace.a",
            "/opt/titan/lib/liblua.a",
            "-lm",
        }, driver.installed_link_inputs(paths, true))
    end)

    it("identifies a checkout from driver provenance, not the working directory",
       function()
        local checkout = lfs.currentdir()
        assert.is_true(driver.source_checkout_from_driver_source(
            "@" .. checkout .. "/titan-compiler/driver.lua", "/tmp"))
        assert.is_true(driver.source_checkout_from_driver_source(
            "@./titan-compiler/driver.lua", checkout))
        assert.is_false(driver.source_checkout_from_driver_source(
            "@/opt/titan/share/lua/5.5/titan-compiler/driver.lua",
            checkout))
    end)

    it("requires exactly the three runtime archive members", function()
        assert.is_true(driver.runtime_archive_members_are_exact(
            "titan.o\ntitan_coro.o\ntitan_uv.o\n"))
        assert.is_true(driver.runtime_archive_members_are_exact(
            "__.SYMDEF SORTED\ntitan.o\ntitan_coro.o\ntitan_uv.o\n"))
        assert.is_true(driver.runtime_archive_members_are_exact(
            "__.SYMDEF_64\ntitan.o\ntitan_coro.o\ntitan_uv.o\n"))
        assert.is_false(driver.runtime_archive_members_are_exact(
            "titan.o\ntitan_coro.o\ntitan_uv.o\nstale.o\n"))
        assert.is_false(driver.runtime_archive_members_are_exact(
            "__.SYMDEF\ntitan.o\ntitan_coro.o\ntitan_uv.o\nstale.o\n"))
        assert.is_false(driver.runtime_archive_members_are_exact(
            "titan_coro.o\ntitan.o\ntitan_uv.o\n"))
    end)

    it("links source builds through the complete runtime archive", function()
        assert.same({
            "titan-runtime/libtitan.a",
            "libbacktrace/.libs/libbacktrace.a",
            "lua-5.5.0/src/liblua.a",
            "-ldl", "-lm",
        }, driver.source_link_inputs("lua-5.5.0/src"))
    end)
end)

describe("compiler module loader", function()
    local root
    local source
    local binary
    local previous

    before_each(function()
        root = os.tmpname()
        assert(os.remove(root))
        assert(lfs.mkdir(root))
        source = root .. "/source"
        binary = root .. "/binary"
        assert(lfs.mkdir(source))
        assert(lfs.mkdir(binary))
        assert(lfs.mkdir(source .. "/titan"))
        assert(lfs.mkdir(binary .. "/titan"))

        previous = {
            source_path = driver.TITAN_SOURCE_PATH,
            bin_path = driver.TITAN_BIN_PATH,
            imported = driver.imported,
            registry = types.registry,
            loadlib = titan._loadlib,
        }
        driver.TITAN_SOURCE_PATH = source
        driver.TITAN_BIN_PATH = binary
        driver.imported = {}
        types.registry = {}
    end)

    after_each(function()
        driver.TITAN_SOURCE_PATH = previous.source_path
        driver.TITAN_BIN_PATH = previous.bin_path
        driver.imported = previous.imported
        types.registry = previous.registry
        titan._loadlib = previous.loadlib
        remove_tree(root)
    end)

    it("uses binaries for dependencies and source for explicit roots", function()
        assert(lfs.mkdir(source .. "/titan/timer"))
        write_file(source .. "/titan/timer/timer.titan", [[
            function marker(): integer
                return 1
            end
        ]])
        write_file(binary .. "/titan/timer.so", "mock interface\n")

        local symbols = {}
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. "/titan/timer.so", filename)
            symbols[#symbols + 1] = symbol
            if symbol == "titan_timer_abi" then
                return function() return driver.TITAN_VER end
            elseif symbol == "titan_timer_types" then
                return function() return "Module('titan.timer',{})" end
            end
            return nil, "unexpected symbol " .. symbol
        end

        local ok, modtype, errors =
            driver.defaultloader({})("titan.timer")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.same({ "titan_timer_abi", "titan_timer_types" }, symbols)
        assert.is_nil(driver.imported["titan.timer"].ast)

        -- A later explicit build request replaces a cached binary interface
        -- with the source root instead of silently treating compilation as a
        -- no-op.
        local deps = {}
        ok, modtype, errors = driver.defaultloader(deps, {
            source_roots = { ["titan.timer"] = true },
        })("titan.timer")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.is_table(driver.imported["titan.timer"].ast)
        assert.equal(true, deps["titan.timer"])
        assert.equal(source .. "/titan/timer/timer.titan",
            driver.imported["titan.timer"].filename)
        assert.equal("titan/timer__main",
            driver.imported["titan.timer"].program_output)
    end)

    it("assembles a folder module in deterministic source order", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(source .. "/titan/sample.titan", [[
            local decoy: integer = 99
        ]])
        write_file(folder .. "/sample.titan", [[
            local from_main: integer = 1
            do
                from_main = from_main + from_A()
            end
        ]])
        -- Deliberately create contributors in an order unrelated to the
        -- required raw-byte basename order.
        write_file(folder .. "/z.titan",
            "local from_z: integer = 1\n")
        write_file(folder .. "/a.titan",
            "local from_a: integer = 1\n")
        write_file(folder .. "/A.titan", [[
            function from_A(): integer
                do
                    return 1
                end
            end
        ]])
        write_file(folder .. "/aa.titan",
            "local from_aa: integer = 1\n")
        write_file(folder .. "/\195\169.titan",
            "local from_utf8: integer = 1\n")
        write_file(folder .. "/ignored.lua", "return {}\n")
        assert(lfs.mkdir(folder .. "/nested.titan"))

        local ok, modtype, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")

        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        local imported = driver.imported["titan.sample"]
        assert.equal(folder .. "/sample.titan", imported.filename)
        assert.equal("titan/sample__main", imported.program_output)
        assert.equal(7, #imported.ast)
        assert.same({
            folder .. "/sample.titan",
            folder .. "/A.titan",
            folder .. "/a.titan",
            folder .. "/aa.titan",
            folder .. "/z.titan",
            folder .. "/\195\169.titan",
            folder .. "/sample.titan",
        }, {
            imported.ast[1].loc.filename,
            imported.ast[2].loc.filename,
            imported.ast[3].loc.filename,
            imported.ast[4].loc.filename,
            imported.ast[5].loc.filename,
            imported.ast[6].loc.filename,
            imported.ast[7].loc.filename,
        })
        assert.equal("Ast.StatBlock", imported.ast[7]._tag)
    end)

    it("honors source-root order across flat and folder representations",
       function()
        local later = root .. "/later"
        assert(lfs.mkdir(later))
        assert(lfs.mkdir(later .. "/titan"))
        assert(lfs.mkdir(later .. "/titan/sample"))
        write_file(source .. "/titan/sample.titan",
            "local from_flat: integer = 1\n")
        write_file(later .. "/titan/sample/sample.titan",
            "local from_folder: integer = 1\n")

        driver.TITAN_SOURCE_PATH = source .. ";" .. later
        local loader = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })
        local ok, _, errors = loader("titan.sample")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal(source .. "/titan/sample.titan",
            driver.imported["titan.sample"].filename)
        assert.equal("titan/sample",
            driver.imported["titan.sample"].program_output)

        driver.imported = {}
        types.registry = {}
        driver.TITAN_SOURCE_PATH = later .. ";" .. source
        loader = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })
        ok, _, errors = loader("titan.sample")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal(later .. "/titan/sample/sample.titan",
            driver.imported["titan.sample"].filename)
        assert.equal("titan/sample__main",
            driver.imported["titan.sample"].program_output)
    end)

    it("blocks constituent flat sources but permits a deeper folder module",
       function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/child.titan",
            "local constituent: integer = 1\n")

        local child_loader = driver.defaultloader({}, {
            source_roots = { ["titan.sample.child"] = true },
        })
        local ok, message = child_loader("titan.sample.child")
        assert.falsy(ok)
        assert.match("source module 'titan.sample.child' cannot be loaded directly",
            message, 1, true)
        assert.match(folder .. "/child.titan", message, 1, true)
        assert.match("folder module 'titan.sample'", message, 1, true)
        assert.match(folder .. "/sample.titan", message, 1, true)

        ok, message = driver.defaultloader({}, {
            source_roots = { ["titan.sample.sample"] = true },
        })("titan.sample.sample")
        assert.falsy(ok)
        assert.match("source module 'titan.sample.sample' cannot be loaded directly",
            message, 1, true)

        assert(lfs.mkdir(folder .. "/child"))
        write_file(folder .. "/child/child.titan", [[
            function distinct(): integer
                return 2
            end
        ]])
        ok, _, message = driver.defaultloader({}, {
            source_roots = { ["titan.sample.child"] = true },
        })("titan.sample.child")
        assert.truthy(ok)
        assert.equal(0, #message)
        assert.equal(folder .. "/child/child.titan",
            driver.imported["titan.sample.child"].filename)
    end)

    it("does not fall through a blocked constituent in an earlier root",
       function()
        local later = root .. "/later"
        assert(lfs.mkdir(later))
        assert(lfs.mkdir(later .. "/titan"))
        assert(lfs.mkdir(later .. "/titan/sample"))
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/child.titan",
            "local constituent: integer = 1\n")
        write_file(later .. "/titan/sample/child.titan", [[
            function later_module(): integer
                return 3
            end
        ]])
        driver.TITAN_SOURCE_PATH = source .. ";" .. later

        local ok, message = driver.defaultloader({}, {
            source_roots = { ["titan.sample.child"] = true },
        })("titan.sample.child")
        assert.falsy(ok)
        assert.match(folder .. "/child.titan", message, 1, true)
        assert.not_match(later, message, 1, true)
    end)

    it("allows a later nested flat module when the earlier constituent is absent",
       function()
        local later = root .. "/later"
        assert(lfs.mkdir(later))
        assert(lfs.mkdir(later .. "/titan"))
        assert(lfs.mkdir(later .. "/titan/sample"))
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(later .. "/titan/sample/child.titan", [[
            function later_module(): integer
                return 3
            end
        ]])
        driver.TITAN_SOURCE_PATH = source .. ";" .. later

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample.child"] = true },
        })("titan.sample.child")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal(later .. "/titan/sample/child.titan",
            driver.imported["titan.sample.child"].filename)
    end)

    it("uses an exact child binary before applying folder-source privacy",
       function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/child.titan",
            "local constituent: integer = 1\n")
        assert(lfs.mkdir(binary .. "/titan/sample"))
        local child_binary = binary .. "/titan/sample/child.so"
        write_file(child_binary, "mock interface\n")

        titan._loadlib = function(filename, symbol)
            assert.equal(child_binary, filename)
            if symbol == "titan_sample_child_abi" then
                return function() return driver.TITAN_VER end
            elseif symbol == "titan_sample_child_types" then
                return function()
                    return "Module('titan.sample.child',{})"
                end
            end
            return nil, "unexpected symbol " .. symbol
        end

        local ok, modtype, errors =
            driver.defaultloader({})("titan.sample.child")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.equal(child_binary,
            driver.imported["titan.sample.child"].filename)
        assert.is_nil(driver.imported["titan.sample.child"].ast)
    end)

    it("reports folder enumeration failure without falling back", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(source .. "/titan/sample.titan",
            "local decoy: integer = 1\n")

        local real_dir = lfs.dir
        lfs.dir = function(path)
            if path == folder then error("permission denied") end
            return real_dir(path)
        end
        local called, ok, message = pcall(driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        }), "titan.sample")
        lfs.dir = real_dir

        assert.truthy(called)
        assert.falsy(ok)
        assert.match("cannot enumerate folder module 'titan.sample'",
            message, 1, true)
        assert.match(folder .. "/sample.titan", message, 1, true)
        assert.match("permission denied", message, 1, true)
        assert.is_nil(driver.imported["titan.sample"])
    end)

    it("treats a selected contributor read failure as a hard error",
       function()
        local folder = source .. "/titan/sample"
        local part = folder .. "/part.titan"
        assert(lfs.mkdir(folder))
        write_file(source .. "/titan/sample.titan",
            "local decoy: integer = 1\n")
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(part, "local contributor: integer = 2\n")

        local real_get_file_contents = util.get_file_contents
        util.get_file_contents = function(path)
            if path == part then
                return false, part .. ": forced read failure"
            end
            return real_get_file_contents(path)
        end
        local called, ok, message = pcall(driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        }), "titan.sample")
        util.get_file_contents = real_get_file_contents

        assert.truthy(called)
        assert.falsy(ok)
        assert.equal(part .. ": forced read failure", message)
        assert.is_nil(driver.imported["titan.sample"])
    end)

    it("rejects a contributor initializer at its exact source location",
       function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/part.titan",
            "\ndo\n    local invalid: integer = 1\nend\n")

        local ok, message = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.falsy(ok)
        assert.match(folder .. "/part.titan:2:1", message, 1, true)
        assert.match("module initializer is only allowed", message, 1, true)
        assert.match(folder .. "/sample.titan", message, 1, true)
        assert.is_nil(driver.imported["titan.sample"])
    end)

    it("rejects a protected contributor initializer by its parser role",
       function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/part.titan", [[

do
    raise "expected"
catch
    local caught: value = error
finally
    local cleaned: boolean = true
end
]])

        local called, ok, message = pcall(driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        }), "titan.sample")
        assert.truthy(called)
        assert.falsy(ok)
        assert.match(folder .. "/part.titan:2:1", message, 1, true)
        assert.match("module initializer is only allowed", message, 1, true)
        assert.is_nil(driver.imported["titan.sample"])
    end)

    it("moves a protected main initializer after contributor declarations",
       function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan", [[
answer: integer = 0

do
    raise "expected"
catch
    answer = contributor_answer()
finally
    answer = answer + 1
end
]])
        write_file(folder .. "/part.titan", [[
local function contributor_answer(): integer
    return 41
end
]])

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.truthy(ok)
        assert.equal(0, #errors)
        local combined = driver.imported["titan.sample"].ast
        assert.equal("Ast.TopLevelFunc", combined[#combined - 1]._tag)
        assert.equal("contributor_answer", combined[#combined - 1].name)
        assert.equal("Ast.StatTry", combined[#combined]._tag)
        assert.is_true(combined[#combined]._module_initializer)
    end)

    it("reports a syntax error from the failing contributor", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(source .. "/titan/sample.titan",
            "local decoy: integer = 1\n")
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/broken.titan", "function broken(\n")

        local ok, message = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.falsy(ok)
        assert.match(folder .. "/broken.titan:2:1: syntax error:",
            message, 1, true)
        assert.is_nil(driver.imported["titan.sample"])
    end)

    it("reports an exact type-error location from a contributor", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/part.titan",
            "local invalid: integer = \"not an integer\"\n")

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.truthy(ok)
        assert.equal(1, #errors)
        assert.match(folder .. "/part.titan:1:1: type error:",
            errors[1], 1, true)
        assert.match("declaration of module variable invalid", errors[1],
            1, true)
    end)

    it("tracks contributor imports in one logical dependency closure",
       function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(source .. "/titan/alpha.titan", [[
            function alpha(): integer return 1 end
        ]])
        write_file(source .. "/titan/beta.titan", [[
            function beta(): integer return 2 end
        ]])
        write_file(folder .. "/sample.titan", [[
            local alpha = import "titan.alpha"
            function from_main(): integer return alpha.alpha() end
        ]])
        write_file(folder .. "/part.titan", [[
            local beta = import "titan.beta"
            function from_part(): integer return beta.beta() end
        ]])

        local static_deps = {}
        local loader = driver.defaultloader(static_deps, {
            source_roots = { ["titan.sample"] = true },
        })
        local ok, modtype, errors = loader("titan.sample")
        assert.truthy(ok)
        assert.equal(0, #errors)
        local imported = driver.imported["titan.sample"]
        local original_ast = imported.ast
        assert.same({
            ["titan.alpha"] = true,
            ["titan.beta"] = true,
        }, imported.deps)
        assert.same({
            ["titan.sample"] = true,
            ["titan.alpha"] = true,
            ["titan.beta"] = true,
        }, driver.dependency_closure("titan.sample"))
        assert.same(driver.dependency_closure("titan.sample"), static_deps)

        local cached_ok, cached_type, cached_errors = loader("titan.sample")
        assert.truthy(cached_ok)
        assert.equal(modtype, cached_type)
        assert.equal(0, #cached_errors)
        assert.equal(original_ast, driver.imported["titan.sample"].ast)
    end)

    it("keeps folder identity marked across repeated self-imports", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local self_main = import \"titan.sample\"\n")
        write_file(folder .. "/part.titan",
            "\nlocal self_part = import \"titan.sample\"\n")

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.truthy(ok)
        assert.equal(2, #errors)
        local all_errors = table.concat(errors, "\n")
        assert.match(folder .. "/sample.titan:1:1", all_errors, 1, true)
        assert.match(folder .. "/part.titan:2:1", all_errors, 1, true)
        assert.match("circular reference to module", all_errors, 1, true)
        assert.is_table(driver.imported["titan.sample"].ast)
        local cache_entries = 0
        for _ in pairs(driver.imported) do
            cache_entries = cache_entries + 1
        end
        assert.equal(1, cache_entries)
    end)

    it("attributes a blocked sibling import to its contributor", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/part.titan",
            "local sibling = import \"titan.sample.part\"\n")

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.truthy(ok)
        assert.equal(1, #errors)
        assert.match(folder .. "/part.titan:1:1", errors[1], 1, true)
        assert.match("source module 'titan.sample.part' cannot be loaded " ..
            "directly", errors[1], 1, true)
        assert.match(folder .. "/part.titan", errors[1], 1, true)
        assert.is_nil(driver.imported["titan.sample.part"])
    end)

    it("reports both files for cross-file duplicate declarations", function()
        local folder = source .. "/titan/sample"
        local main = folder .. "/sample.titan"
        local part = folder .. "/part.titan"
        assert(lfs.mkdir(folder))
        write_file(main, table.concat({
            "record Box end",
            "type Count = integer",
            "local item = 1",
            "",
        }, "\n"))
        write_file(part, table.concat({
            "type Count = string",
            "type Box = integer",
            "local item = 2",
            "",
        }, "\n"))

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.truthy(ok)
        assert.equal(3, #errors)
        local all_errors = table.concat(errors, "\n")
        assert.match(part .. ":1:1: type error: duplicate type alias for " ..
            "Count, previous one at " .. main .. ":2:1",
            all_errors, 1, true)
        assert.match(part .. ":2:1: type error: type alias 'Box' conflicts " ..
            "with record declared at " .. main .. ":1:1",
            all_errors, 1, true)
        assert.match(part .. ":3:1: type error: duplicate declaration for " ..
            "item, previous one at " .. main .. ":3:1",
            all_errors, 1, true)
    end)

    it("rejects malformed module names without crashing", function()
        local malformed = { "", ".", "titan.", ".titan", "titan..timer" }
        local source_roots = {}
        for _, name in ipairs(malformed) do source_roots[name] = true end
        local loader = driver.defaultloader({}, {
            source_roots = source_roots,
        })

        for _, name in ipairs(malformed) do
            local called, ok, message = pcall(loader, name)
            assert.truthy(called)
            assert.falsy(ok)
            assert.equal("source module '" .. name .. "' not found", message)
        end
    end)

    it("requires source for an explicit build root", function()
        write_file(binary .. "/titan/timer.so", "existing binary\n")
        titan._loadlib = function()
            error("an explicit source build must not load its existing binary")
        end

        local ok, message = driver.defaultloader({}, {
            source_roots = { ["titan.timer"] = true },
        })("titan.timer")

        assert.falsy(ok)
        assert.equal("source module 'titan.timer' not found", message)
        assert.is_nil(driver.imported["titan.timer"])
    end)

    it("reports a missing ABI entry from the internal loader", function()
        write_file(binary .. "/extension.so", "mock image\n")
        local calls = 0
        titan._loadlib = function(filename, symbol)
            calls = calls + 1
            assert.equal(binary .. "/extension.so", filename)
            assert.equal("extension_abi", symbol)
            return nil, "undefined symbol: extension_abi", "init"
        end

        local ok, message = driver.defaultloader({})("extension")
        assert.falsy(ok)
        assert.match("has no compatible Titan ABI marker", message)
        assert.equal(1, calls)
    end)

    it("records a cached table-loader import as a dependency", function()
        local modtype = types.Module("cached", {})
        local imported = { cached = { type = modtype } }
        local deps = {}

        local ok, loaded, errors =
            driver.tableloader({}, imported, deps)("cached")

        assert.truthy(ok)
        assert.equal(modtype, loaded)
        assert.equal(0, #errors)
        assert.equal(true, deps.cached)
    end)
end)
