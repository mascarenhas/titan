local assert = require "luassert"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local filesystem = require "spec.support.filesystem"
local lfs = require "lfs"
local path = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local temporary = require "spec.support.temporary"
local testroots = require "titan-compiler.testroots"
local util = require "titan-compiler.util"

local REPO = path.to_slash(assert(
    compiler_io.new_sync():realpath(assert(lfs.currentdir()))))

local IO_METHODS = {
    "cwd", "realpath", "stat", "lstat", "readable", "read_file",
    "write_file", "list", "mkdir", "unlink", "rmdir", "rename",
    "tmpname", "run", "run_batch", "yield",
}

local function joined(root, name)
    return root .. "/" .. name
end

local function slashed(value)
    return path.to_slash(value)
end

local function sorted(names)
    local copy = {}
    for index, name in ipairs(names) do copy[index] = name end
    table.sort(copy, util.bytewise_less)
    return copy
end

local function keys(values)
    local names = {}
    for name in pairs(values) do names[#names + 1] = name end
    return names
end

local function basenames(values)
    local names = {}
    for index, value in ipairs(values) do
        names[index] = path.basename(value)
    end
    return names
end

local function mkdirs(target)
    local mode = lfs.attributes(target, "mode")
    if mode == "directory" then return end
    local parent = path.dirname(target)
    if parent ~= "." and parent ~= target then mkdirs(parent) end
    assert(lfs.mkdir(target))
end

local function put(root, name, contents)
    local target = joined(root, name)
    local parent = target:match("^(.*)/[^/]+$")
    if parent then mkdirs(parent) end
    local file = assert(io.open(target, "wb"))
    assert(file:write(contents or ""))
    assert(file:close())
    return target
end

local function remove_tree(target)
    local mode = lfs.symlinkattributes(target, "mode")
    if mode == "directory" then
        for name in lfs.dir(target) do
            if name ~= "." and name ~= ".." then
                remove_tree(joined(target, name))
            end
        end
        assert(lfs.rmdir(target))
    elseif mode then
        assert(os.remove(target))
    end
end

local function canonical(filename)
    return path.to_slash(assert(compiler_io.new_sync():realpath(filename)))
end

local function workspace()
    local reservation = temporary.name()
    local root = canonical(reservation)
    assert(os.remove(reservation))
    assert(lfs.mkdir(root))
    return root
end

local function require_symlink_capability()
    local available, message = filesystem.symlink_capability()
    if not available then
        pending(message)
        return false
    end
    return true
end

local function discovery_context(io_strategy)
    return driver.new_resolver_context({
        io = io_strategy or compiler_io.new_sync(),
    })
end

-- Observe the compiler I/O strategy handed to discovery. Discovery may list,
-- stat, resolve paths, and yield; it must never read, write, or run anything.
local function observed(overrides)
    local base = compiler_io.new_sync()
    local calls = { methods = {}, yields = {} }
    local strategy = {}
    for _, name in ipairs(IO_METHODS) do
        local method = name
        strategy[method] = function(_, ...)
            calls.methods[method] = (calls.methods[method] or 0) + 1
            if method == "yield" then
                calls.yields[#calls.yields + 1] = ...
            end
            local override = overrides and overrides[method]
            if override then return override(...) end
            return base[method](base, ...)
        end
    end
    return strategy, calls
end

describe("automatic test-root discovery", function()
    local created = {}

    local function make(files)
        local root = workspace()
        created[#created + 1] = root
        for name, contents in pairs(files or {}) do
            if contents == false then
                mkdirs(joined(root, name))
            else
                put(root, name, contents)
            end
        end
        return root
    end

    after_each(function()
        local roots = created
        created = {}
        for _, root in ipairs(roots) do remove_tree(root) end
    end)

    describe("root naming", function()
        it("discovers every conventional root name and ignores other files",
           function()
            local root = make({
                ["test.titan"] = "",
                ["tests.titan"] = "",
                ["spec.titan"] = "",
                ["specs.titan"] = "",
                ["alpha_test.titan"] = "",
                ["beta_tests.titan"] = "",
                ["gamma_spec.titan"] = "",
                ["delta_specs.titan"] = "",
                ["nested/epsilon_test.titan"] = "",
                ["check.titan"] = "",
                ["test_helper.titan"] = "",
                ["pretest.titan"] = "",
                ["tests_extra.titan"] = "",
                ["notes.txt"] = "not a module",
                ["helper.c"] = "int helper(void) { return 0; }\n",
            })

            local roots, sources = testroots.discover(discovery_context(),
                { root }, {}, {}, root)

            assert.same({
                "alpha_test",
                "beta_tests",
                "delta_specs",
                "gamma_spec",
                "nested.epsilon_test",
                "spec",
                "specs",
                "test",
                "tests",
            }, roots)
            assert.same(roots, sorted(keys(sources)))
        end)

        it("orders automatic roots bytewise, not by locale or enumeration",
           function()
            local root = make({
                ["A_z_test.titan"] = "",
                ["a_a_test.titan"] = "",
                ["_alpha_test.titan"] = "",
                ["a-b_test.titan"] = "",
            })

            local roots = testroots.discover(discovery_context(),
                { root }, {}, {}, root)

            assert.same({
                "A_z_test",
                "_alpha_test",
                "a-b_test",
                "a_a_test",
            }, roots)
        end)

        it("keeps an arbitrary explicit root that no convention would find",
           function()
            local root = make({ ["helper.titan"] = "" })

            local missing, message = testroots.discover(discovery_context(),
                { root }, {}, {}, root)
            assert.is_nil(missing)
            assert.equal("no test modules found", message)

            local roots, sources = testroots.discover(discovery_context(),
                { root }, {}, { "helper", "helper", "custom_root" }, root)
            assert.same({ "helper", "custom_root" }, roots)
            assert.same({}, sources)
        end)

        it("places explicit roots in command-line order before automatic roots",
           function()
            local root = make({
                ["a_test.titan"] = "",
                ["z_test.titan"] = "",
            })

            local roots = testroots.discover(discovery_context(),
                { root }, {}, { "z_manual", "a_manual" }, root)

            assert.same({ "z_manual", "a_manual", "a_test", "z_test" },
                roots)
        end)
    end)

    describe("selection", function()
        it("excludes automatic roots only and lets an explicit root win",
           function()
            local root = make({
                ["a_test.titan"] = "",
                ["b_test.titan"] = "",
            })

            local roots = testroots.discover(discovery_context(),
                { root }, { "a_test" }, {}, root)
            assert.same({ "b_test" }, roots)

            roots = testroots.discover(discovery_context(),
                { root }, { "a_test" }, { "a_test" }, root)
            assert.same({ "a_test", "b_test" }, roots)

            roots = testroots.discover(discovery_context(),
                { root }, { "b_test" }, { "a_test" }, root)
            assert.same({ "a_test" }, roots)

            local missing, message = testroots.discover(discovery_context(),
                { root }, { "a_test", "b_test" }, {}, root)
            assert.is_nil(missing)
            assert.equal("no test modules found", message)
        end)

        it("rejects a test-exclude name that is not a logical module",
           function()
            local root = make({ ["a_test.titan"] = "" })

            local missing, message = testroots.discover(discovery_context(),
                { root }, { "not a module" }, {}, root)

            assert.is_nil(missing)
            assert.equal("invalid --test-exclude module name 'not a module'",
                message)
        end)

        it("deduplicates repeated and overlapping discovery directories",
           function()
            local root = make({
                ["tests/beta_test.titan"] = "",
                ["tests/unit/alpha_test.titan"] = "",
            })
            local unit = joined(root, "tests/unit")
            local tests = joined(root, "tests")

            local expected = { "tests.beta_test", "tests.unit.alpha_test" }

            assert.same(expected, testroots.discover(discovery_context(),
                { tests, tests, joined(root, "./tests") }, {}, {}, root))
            assert.same(expected, testroots.discover(discovery_context(),
                { unit, tests, unit }, {}, {}, root))
        end)

        it("requires at least one discovery directory", function()
            local missing, message = testroots.discover(discovery_context(),
                {}, {}, {}, ".")

            assert.is_nil(missing)
            assert.equal(
                "test-root discovery requires at least one --test-dir " ..
                "directory", message)
        end)

        it("requires a resolver I/O context", function()
            for _, context in ipairs({ false, {} }) do
                local ok, message = pcall(testroots.discover, context or nil,
                    { "." }, {}, {}, ".")
                assert.is_false(ok)
                assert.truthy(tostring(message):find(
                    "testroots.discover requires an I/O context", 1, true))
            end
        end)

        it("rejects an explicit root that is not a logical module name",
           function()
            local root = make({ ["a_test.titan"] = "" })

            local missing, message = testroots.discover(discovery_context(),
                { root }, {}, { "a_test", "not a module" }, root)

            assert.is_nil(missing)
            assert.equal('invalid logical Titan module name "not a module"',
                message)
        end)

        it("rejects empty and NUL-bearing discovery directory spellings",
           function()
            local root = make({ ["a_test.titan"] = "" })
            for _, dir in ipairs({ "", root .. "\0suffix" }) do
                local missing, message = testroots.discover(discovery_context(),
                    { root, dir }, {}, {}, root)
                assert.is_nil(missing)
                assert.equal("invalid --test-dir directory path", message)
            end
        end)
    end)

    describe("source roots", function()
        it("derives the logical prefix from the first containing source root",
           function()
            local root = make({
                ["src/tests/inner_test.titan"] = "",
                ["loader/tests/outer_test.titan"] = "",
            })
            local source_path = joined(root, "src") .. ";" ..
                joined(root, "loader")

            local roots = testroots.discover(discovery_context(),
                { joined(root, "loader/tests") }, {}, {}, source_path)

            assert.same({ "tests.outer_test" }, roots)
        end)

        it("preserves logical prefixes across different spellings of a symlinked parent",
           function()
            if not require_symlink_capability() then return end
            local root = make({ ["physical"] = false })
            assert(lfs.link(joined(root, "physical"), joined(root, "alias"), true))
            put(root, "alias/src/tests/alpha_tests.titan", "")
            local physical_tree = canonical(joined(root, "physical/src"))
            local alias_tree = joined(root, "alias/src")
            local expected_source = canonical(joined(physical_tree, "tests/alpha_tests.titan"))
            for _, source_path in ipairs({ physical_tree, alias_tree }) do
                for _, directory in ipairs({
                    joined(physical_tree, "tests"), joined(alias_tree, "tests"),
                }) do
                    local roots, sources = testroots.discover(discovery_context(),
                        { directory }, {}, {}, source_path)
                    assert.same({ "tests.alpha_tests" }, roots)
                    assert.equal(expected_source, canonical(sources["tests.alpha_tests"].main))
                end
                local roots = testroots.discover(discovery_context(),
                    { joined(alias_tree, "tests"), joined(physical_tree, "tests") },
                    {}, {}, source_path)
                assert.same({ "tests.alpha_tests" }, roots)
            end
        end)

        it("keeps first-containing-tree order across parent symlinks",
           function()
            if not require_symlink_capability() then return end
            local root = make({ ["physical/src/tests/alpha_tests.titan"] = "" })
            local parent_alias = joined(root, "alias")
            assert(lfs.link(joined(root, "physical"), parent_alias, true))
            local physical_tree = canonical(joined(root, "physical/src"))
            local directory = joined(physical_tree, "tests")
            local roots = testroots.discover(discovery_context(),
                { directory }, {}, {}, parent_alias .. ";" .. physical_tree)
            assert.same({ "src.tests.alpha_tests" }, roots)
            roots = testroots.discover(discovery_context(),
                { directory }, {}, {}, physical_tree .. ";" .. parent_alias)
            assert.same({ "tests.alpha_tests" }, roots)
        end)

        it("keeps nested containing trees ordered rather than choosing the longest prefix",
           function()
            local root = make({ ["suite/alpha_tests.titan"] = "" })
            local nested = joined(root, "suite")
            local roots = testroots.discover(discovery_context(),
                { nested }, {}, {}, root .. ";" .. nested)
            assert.same({ "suite.alpha_tests" }, roots)
            roots = testroots.discover(discovery_context(),
                { nested }, {}, {}, nested .. ";" .. root)
            assert.same({ "alpha_tests" }, roots)
        end)

        it("does not treat an empty matching directory as another tree's source module",
           function()
            local root = make({
                ["earlier/alpha_tests.titan"] = "",
                ["later/alpha_tests"] = false,
                ["later/selected_specs.titan"] = "",
            })
            local roots = testroots.discover(discovery_context(),
                { joined(root, "later") }, {}, {},
                joined(root, "earlier") .. ";" .. joined(root, "later"))
            assert.same({ "selected_specs" }, roots)
        end)

        it("diagnoses a discovery area shadowed by an earlier source root",
           function()
            local root = make({
                ["a/shadow_test.titan"] = "",
                ["b/shadow_test.titan"] = "",
            })
            local a = joined(root, "a")
            local b = joined(root, "b")

            local missing, message = testroots.discover(discovery_context(),
                { b }, {}, {}, a .. ";" .. b)
            assert.is_nil(missing)
            assert.truthy(message:find("shadowed by", 1, true))
            assert.truthy(message:find("'shadow_test'", 1, true))
            assert.truthy(slashed(message):find(slashed(joined(a, "shadow_test.titan")),
                1, true))
            assert.truthy(slashed(message):find(slashed(joined(b, "shadow_test.titan")),
                1, true))
            assert.truthy(message:find("reorder --tree roots or narrow --test-dir", 1, true))

            local roots, sources = testroots.discover(discovery_context(),
                { b }, {}, {}, b .. ";" .. a)
            assert.same({ "shadow_test" }, roots)
            assert.equal(slashed(joined(b, "shadow_test.titan")),
                slashed(sources["shadow_test"].main))
        end)

        it("diagnoses a root blocked by an earlier tree's folder constituents",
           function()
            local root = make({
                ["earlier/pkg/pkg.titan"] = "",
                ["earlier/pkg/alpha_tests.titan"] = "",
                ["later/pkg/alpha_tests.titan"] = "",
            })
            local roots, message = testroots.discover(discovery_context(),
                { joined(root, "later") }, {}, {},
                joined(root, "earlier") .. ";" .. joined(root, "later"))
            assert.is_nil(roots)
            assert.truthy(message:find("shadowed by folder module 'pkg'", 1, true))
            assert.truthy(message:find("'pkg.alpha_tests'", 1, true))
            assert.truthy(slashed(message):find(slashed(joined(root,
                "later/pkg/alpha_tests.titan")), 1, true))
            assert.truthy(slashed(message):find(slashed(joined(root,
                "earlier/pkg/pkg.titan")), 1, true))
            assert.truthy(message:find("reorder --tree roots or narrow --test-dir", 1, true))
        end)

        it("deduplicates one logical module claimed by two discovery areas",
           function()
            local root = make({
                ["a/tests/same_test.titan"] = "",
                ["b/tests/same_test.titan"] = "",
            })

            local roots, sources = testroots.discover(discovery_context(),
                { joined(root, "a/tests"), joined(root, "b/tests") },
                {}, {}, joined(root, "a") .. ";" .. joined(root, "b"))

            assert.same({ "tests.same_test" }, roots)
            assert.equal(slashed(joined(root, "a/tests/same_test.titan")),
                slashed(sources["tests.same_test"].main))
        end)

        it("rejects a discovery directory outside every source root",
           function()
            local root = make({})
            local other = make({ ["elsewhere_test.titan"] = "" })

            local missing, message = testroots.discover(discovery_context(),
                { other }, {}, {}, root)

            assert.is_nil(missing)
            assert.truthy(message:find("is outside every --tree source root",
                1, true))
            assert.truthy(message:find(other, 1, true))
        end)
    end)

    describe("folder modules", function()
        it("recognizes one folder module and never treats contributors as roots",
           function()
            local root = make({
                ["pkg/tests/tests.titan"] = "",
                ["pkg/tests/extra_test.titan"] = "",
                ["pkg/tests/helpers.titan"] = "",
                ["pkg/tests/nested/deep_spec.titan"] = "",
                ["pkg/tests.titan"] = "",
                ["single/tests.titan"] = "",
            })

            local roots, sources = testroots.discover(discovery_context(),
                { root }, {}, {}, root)

            assert.same({ "pkg.tests", "pkg.tests.nested.deep_spec",
                "single.tests" }, roots)

            local folder = sources["pkg.tests"]
            assert.equal("folder", folder.kind)
            assert.equal(slashed(joined(root, "pkg/tests/tests.titan")),
                slashed(folder.main))
            assert.same({
                "tests.titan",
                "extra_test.titan",
                "helpers.titan",
            }, basenames(folder.files))
            assert.equal("flat", sources["single.tests"].kind)
        end)

        it("skips a directory whose logical module is a sibling flat source",
           function()
            local root = make({
                ["orphan/sibling_test.titan"] = "",
                ["orphan/sibling_test"] = false,
            })

            local roots, sources = testroots.discover(discovery_context(),
                { root }, {}, {}, root)

            assert.same({ "orphan.sibling_test" }, roots)
            assert.equal("flat", sources["orphan.sibling_test"].kind)
        end)

        it("includes a selected directory that is itself a folder module",
           function()
            local root = make({
                ["pkg/tests/tests.titan"] = "",
                ["pkg/tests/extra_test.titan"] = "",
                ["pkg/tests/nested/other_test.titan"] = "",
            })

            local roots = testroots.discover(discovery_context(),
                { joined(root, "pkg/tests") }, {}, {}, root)

            assert.same({ "pkg.tests", "pkg.tests.nested.other_test" }, roots)
        end)

        it("re-inventories a folder module when its contributors change",
           function()
            local root = make({
                ["pkg/tests/tests.titan"] = "",
                ["pkg/tests/first.titan"] = "",
            })
            local tests = joined(root, "pkg/tests")

            local roots, sources = testroots.discover(discovery_context(),
                { root }, {}, {}, root)
            assert.same({ "pkg.tests" }, roots)
            assert.same({ "tests.titan", "first.titan" },
                basenames(sources["pkg.tests"].files))

            assert(os.rename(joined(tests, "first.titan"),
                joined(tests, "second.titan")))

            roots, sources = testroots.discover(discovery_context(),
                { root }, {}, {}, root)
            assert.same({ "pkg.tests" }, roots)
            assert.same({ "tests.titan", "second.titan" },
                basenames(sources["pkg.tests"].files))
        end)
    end)

    describe("symbolic links and traversal", function()
        it("resolves a file symlink through the ordinary source resolver",
           function()
            if not require_symlink_capability() then return end
            local root = make({ ["target.titan"] = "" })
            assert(lfs.link(joined(root, "target.titan"),
                joined(root, "linked_test.titan"), true))

            local roots, sources = testroots.discover(discovery_context(),
                { root }, {}, {}, root)

            assert.same({ "linked_test" }, roots)
            assert.equal(slashed(joined(root, "linked_test.titan")),
                slashed(sources["linked_test"].main))
        end)

        it("does not descend through a directory symlink", function()
            if not require_symlink_capability() then return end
            local outside = make({
                ["linked_tests/linked_tests.titan"] = "",
                ["linked_tests/inner_test.titan"] = "",
                ["linked_tests/nested/deep_spec.titan"] = "",
                ["plain/deep_test.titan"] = "",
            })
            local root = make({})
            assert(lfs.link(joined(outside, "linked_tests"),
                joined(root, "linked_tests"), true))
            assert(lfs.link(joined(outside, "plain"),
                joined(root, "linked_plain"), true))

            local roots, sources = testroots.discover(discovery_context(),
                { root }, {}, {}, root)

            assert.same({ "linked_tests" }, roots)
            assert.equal("folder", sources["linked_tests"].kind)
            assert.same({ "linked_tests.titan", "inner_test.titan" },
                basenames(sources["linked_tests"].files))
        end)

        it("recurses through a symlinked search directory only when it is explicitly supplied",
           function()
            if not require_symlink_capability() then return end
            local external = make({ ["nested/alpha_tests.titan"] = "" })
            local root = make({ ["visible_tests.titan"] = "" })
            local alias = joined(root, "alias")
            assert(lfs.link(external, alias, true))
            assert(lfs.link(root, joined(external, "cycle"), true))
            local roots = testroots.discover(discovery_context(),
                { root }, {}, {}, root)
            assert.same({ "visible_tests" }, roots)
            roots = testroots.discover(discovery_context(),
                { alias }, {}, {}, root)
            assert.same({ "alias.nested.alpha_tests" }, roots)
        end)

        it("ignores unrelated broken links instead of resolving unselected files",
           function()
            if not require_symlink_capability() then return end
            local root = make({ ["visible_tests.titan"] = "" })
            assert(lfs.link(joined(root, "missing"), joined(root, "notes.txt"), true))
            local roots = testroots.discover(discovery_context(), { root }, {}, {}, root)
            assert.same({ "visible_tests" }, roots)
        end)

        it("skips hidden descendant directories", function()
            local root = make({
                [".hidden/secret_test.titan"] = "",
                ["visible_test.titan"] = "",
            })

            local roots = testroots.discover(discovery_context(),
                { root }, {}, {}, root)

            assert.same({ "visible_test" }, roots)
        end)

        it("reports no test modules when only hidden directories match",
           function()
            local root = make({ [".hidden/secret_test.titan"] = "" })

            local missing, message = testroots.discover(discovery_context(),
                { root }, {}, {}, root)

            assert.is_nil(missing)
            assert.equal("no test modules found", message)
        end)
    end)

    describe("filesystem errors", function()
        it("reports a missing selected directory", function()
            local root = make({})

            local missing, message = testroots.discover(discovery_context(),
                { joined(root, "absent") }, {}, {}, root)

            assert.is_nil(missing)
            assert.truthy(message:find("cannot resolve test directory", 1, true))
            assert.truthy(message:find("absent", 1, true))
        end)

        it("rejects a selected path that is not a directory", function()
            local root = make({ ["notes.txt"] = "text" })
            local notes = joined(root, "notes.txt")

            local missing, message = testroots.discover(discovery_context(),
                { notes }, {}, {}, root)

            assert.is_nil(missing)
            assert.equal("test directory '" .. notes ..
                "' is not a directory", message)
        end)

        it("reports an unreadable discovery directory", function()
            local root = make({ ["one_test.titan"] = "" })
            local strategy = observed({
                list = function() return nil, "permission denied" end,
            })

            local missing, message = testroots.discover(
                discovery_context(strategy), { root }, {}, {}, root)

            assert.is_nil(missing)
            assert.equal("cannot enumerate test directory '" .. root ..
                "': permission denied", message)
        end)

        it("reports requested-directory metadata failures explicitly", function()
            local root = make({ ["one_test.titan"] = "" })
            local base = compiler_io.new_sync()
            local strategy = observed({
                stat = function(filename)
                    if path.normalize(filename) == path.normalize(root) then
                        return nil, "permission denied while inspecting directory"
                    end
                    return base:stat(filename)
                end,
            })
            local roots, message = testroots.discover(
                discovery_context(strategy), { root }, {}, {}, root)
            assert.is_nil(roots)
            assert.equal("cannot resolve test directory '" .. root ..
                "': permission denied while inspecting directory", message)
        end)

        it("reports a requested directory whose physical path cannot be resolved",
           function()
            local root = make({ ["tests/one_test.titan"] = "" })
            local tests = joined(root, "tests")
            local base = compiler_io.new_sync()
            local strategy = observed({
                realpath = function(filename)
                    if path.normalize(filename) == path.normalize(tests) then
                        return nil, "realpath denied"
                    end
                    return base:realpath(filename)
                end,
            })
            local roots, message = testroots.discover(
                discovery_context(strategy), { tests }, {}, {}, root)
            assert.is_nil(roots)
            assert.equal("cannot resolve test directory '" .. tests ..
                "': realpath denied", message)
        end)

        it("reports a selected source that disappears before resolution",
           function()
            local root = make({ ["one_test.titan"] = "" })
            local base = compiler_io.new_sync()
            local ghost = joined(root, "ghost_test.titan")
            local listed = false
            local strategy = observed({
                list = function(directory)
                    local entries, err = base:list(directory)
                    if entries and path.normalize(directory) == path.normalize(root) then
                        entries[#entries + 1] = "ghost_test.titan"
                    end
                    return entries, err
                end,
                lstat = function(filename)
                    if path.normalize(filename) == path.normalize(ghost) and not listed then
                        listed = true
                        return { kind = "file", size = 0 }
                    end
                    return base:lstat(filename)
                end,
            })
            local roots, message = testroots.discover(
                discovery_context(strategy), { root }, {}, {}, root)
            assert.is_true(listed)
            assert.is_nil(roots)
            assert.equal("cannot resolve test module 'ghost_test' at '" .. ghost ..
                "': source disappeared during discovery", message)
        end)

        it("reports a symbolic link whose target cannot be inspected", function()
            if not require_symlink_capability() then return end
            local root = make({ ["target.titan"] = "" })
            local link = joined(root, "linked_test.titan")
            assert(lfs.link(joined(root, "target.titan"), link, true))
            local base = compiler_io.new_sync()
            local strategy = observed({
                stat = function(filename)
                    if path.normalize(filename) == path.normalize(link) then
                        return nil, "permission denied"
                    end
                    return base:stat(filename)
                end,
            })
            local roots, message = testroots.discover(
                discovery_context(strategy), { root }, {}, {}, root)
            assert.is_nil(roots)
            assert.equal("cannot inspect symbolic link '" .. link ..
                "': permission denied", message)
        end)

        it("reports an inspection failure instead of skipping an entry",
           function()
            local root = make({ ["one_test.titan"] = "" })
            local strategy = observed({
                lstat = function() return nil, "stale file handle" end,
            })

            local missing, message = testroots.discover(
                discovery_context(strategy), { root }, {}, {}, root)

            assert.is_nil(missing)
            assert.equal("cannot inspect '" .. joined(root, "one_test.titan") ..
                "': stale file handle", message)
        end)

        it("reports a broken symbolic link", function()
            if not require_symlink_capability() then return end
            local root = make({})
            assert(lfs.link(joined(root, "absent.titan"),
                joined(root, "broken_test.titan"), true))

            local missing, message = testroots.discover(discovery_context(),
                { root }, {}, {}, root)

            assert.is_nil(missing)
            assert.truthy(message:find("cannot inspect symbolic link", 1, true))
            assert.truthy(message:find("broken_test.titan", 1, true))
        end)

        it("propagates cooperative cancellation from the I/O strategy",
           function()
            local root = make({
                ["one_test.titan"] = "",
                ["two_test.titan"] = "",
            })
            local strategy = observed({
                yield = function()
                    error("cancelled while listing test roots", 0)
                end,
            })

            local ok, message = pcall(testroots.discover,
                discovery_context(strategy), { root }, {}, {}, root)

            assert.is_false(ok)
            assert.equal("cancelled while listing test roots", message)
        end)

        it("preserves non-string cancellation during an unselected-file inventory",
           function()
            local root = make({ ["unrelated.titan"] = "", ["selected_tests.titan"] = "" })
            local cancelled = {}
            local strategy = observed({
                yield = function(name)
                    if name and name:find(root, 1, true) then error(cancelled, 0) end
                end,
            })
            local ok, message = pcall(testroots.discover,
                discovery_context(strategy), { root }, {}, {}, root)
            assert.is_false(ok)
            assert.equal(cancelled, message)
        end)
    end)

    describe("warm inventory", function()
        it("lists and resolves without reading or writing source bytes",
           function()
            local root = make({
                ["selected_test.titan"] = "this is not valid Titan source",
                ["unrelated.titan"] = "this is not valid Titan source either",
                ["nested/other_spec.titan"] = "",
                ["data.txt"] = "text",
            })
            local strategy, calls = observed()

            local roots = testroots.discover(discovery_context(strategy),
                { root }, {}, {}, root)

            assert.same({ "nested.other_spec", "selected_test" }, roots)
            assert.is_nil(calls.methods.read_file)
            assert.is_nil(calls.methods.write_file)
            assert.is_nil(calls.methods.readable)
            assert.is_nil(calls.methods.run)
            assert.is_nil(calls.methods.run_batch)
            assert.is_nil(calls.methods.tmpname)
            assert.is_nil(calls.methods.mkdir)
            assert.is_nil(calls.methods.unlink)
            assert.is_nil(calls.methods.rmdir)
            assert.is_nil(calls.methods.rename)
            assert.is_truthy(calls.methods.list)
            assert.is_truthy(calls.methods.yield)
        end)


        it("re-inventories added, renamed, and removed roots per invocation",
           function()
            local root = make({ ["alpha_test.titan"] = "" })
            local function current()
                return testroots.discover(discovery_context(),
                    { root }, {}, {}, root)
            end

            assert.same({ "alpha_test" }, current())

            put(root, "beta_spec.titan", "")
            assert.same({ "alpha_test", "beta_spec" }, current())

            assert(os.rename(joined(root, "alpha_test.titan"),
                joined(root, "gamma_test.titan")))
            assert.same({ "beta_spec", "gamma_test" }, current())

            assert(os.remove(joined(root, "beta_spec.titan")))
            assert.same({ "gamma_test" }, current())
        end)
    end)

    describe("repository inventory", function()
        -- Reference inventory from spec/support/stdlib_test_modules.mk. It is
        -- an audit expectation, not a list supplied to the compiler.
        local expected = {
            "async.tests", "coroutine.tests", "fs.tests", "gc.tests", "http.tests",
            "io.tests", "iteration.tests", "json.tests", "lua.tests", "math.tests",
            "net.tests", "os.process_tests", "os.tests", "path.tests", "peg.tests",
            "protobuf.tests", "reflect.tests", "sqlite3.tests", "ssl.tests",
            "string.core_test", "string.format_pack_test", "string.regex_test",
            "test.tests", "thread.tests", "timer.tests", "url.tests", "uv.public_tests",
            "uv.runtime_tests", "uv.task_tests", "websocket.tests",
        }

        it("discovers exactly the standard-library native test owners",
           function()
            local tree = joined(REPO, "spec/stdlib/titan")
            local roots, sources = testroots.discover(discovery_context(),
                { tree }, {}, {}, tree)

            assert.same(sorted(expected), roots)
            for _, name in ipairs(roots) do
                assert.truthy(sources[name] and sources[name].main)
                assert.truthy(slashed(sources[name].main):find(
                    slashed(tree) .. "/", 1, true))
            end
        end)

        it("preserves an explicit aggregate owner before the automatic inventory",
           function()
            local tree = joined(REPO, "spec/stdlib/titan")
            local roots = testroots.discover(discovery_context(),
                { tree }, {}, { "test.tests" }, tree)
            local explicit_first = { "test.tests" }
            for _, name in ipairs(expected) do
                if name ~= "test.tests" then explicit_first[#explicit_first + 1] = name end
            end
            assert.same(explicit_first, roots)
        end)

        it("recovers the Foundry seventeen-owner and Windows sixteen-owner policies",
           function()
            local names = {
                "tests.api_test", "tests.browser_test", "tests.cdp_test",
                "tests.foundry_session_test", "tests.integration_test", "tests.log_test",
                "tests.logging_http_test", "tests.process_test", "tests.protocol_test",
                "tests.replies_test", "tests.router_test", "tests.session_crypto_test",
                "tests.session_http_test", "tests.sessions_test", "tests.store_concurrency_test",
                "tests.store_test", "tests.threading_test",
            }
            local root = make({})
            for _, name in ipairs(names) do
                put(root, name:gsub("%.", "/") .. ".titan", "")
            end
            put(root, "tests/helper.titan", "")
            local roots = testroots.discover(discovery_context(),
                { joined(root, "tests") }, {}, {}, root)
            assert.same(names, roots)
            local windows = {}
            for _, name in ipairs(names) do
                if name ~= "tests.process_test" then windows[#windows + 1] = name end
            end
            roots = testroots.discover(discovery_context(),
                { joined(root, "tests") }, { "tests.process_test" }, {}, root)
            assert.same(windows, roots)
        end)
    end)
end)

describe("automatic test roots through the CLI", function()
    local suite, tree, output
    local prefix = require("spec.support.installed_prefix").active()
    local lua = prefix .. "/bin/lua" .. (platform.windows and ".exe" or "")

    local function read(filename)
        local file = assert(io.open(filename, "rb"))
        local contents = assert(file:read("a"))
        assert(file:close())
        return contents
    end

    local function source(name, contents, folder)
        local stem = name:gsub("%.", "/")
        if folder then stem = stem .. "/" .. name:match("[^.]+$") end
        return put(tree, stem .. ".titan", contents)
    end

    local function test_source(name)
        return 'local test = import "titan.test"\nfunction ' ..
            (name or "test_pass") .. [[(context: test.Context)
    test.assert(context:name() ~= "")
end
]]
    end

    local function contains(text, expected)
        assert.truthy(text:find(expected, 1, true), text)
    end

    local function absent(text, unexpected)
        assert.falsy(text:find(unexpected, 1, true), text)
    end

    local function run(argv)
        if platform.windows and argv[1] == "env" then argv[1] = "env.exe" end
        local result = compiler_io.new_sync():run(argv)
        local text = result.output or result.diagnostic or ""
        if platform.windows then
            text = text:gsub("\r\n", "\n")
            text = text:gsub('%^"(.-)%^"', function(word)
                return assert(require("c-parser.cdriver").shell_quote(
                    (word:gsub("%^(.)", "%1"))))
            end)
        end
        return result.started and result.ok, text
    end

    local function compile_with(bootstrap, ...)
        local arguments = { ... }
        local compile_only = false
        for _, argument in ipairs(arguments) do
            if argument == "-c" or argument == "--compile-only" then compile_only = true end
        end
        local extension = platform.windows and ".dll" or ".so"
        local argv = {
            "env", "TITAN_RUNTIME_PREBUILT=1", "CCACHE_DISABLE=1",
            "TITAN_PROBE_CACHE_DISABLE=1", "TITAN_ROCKS_ROOT=" .. prefix,
            "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=-O0 -fno-lto",
            "TITAN_EXTRA_LDFLAGS=-fno-lto", "TITAN_FILTER=",
            lua, "-E", "-e",
            string.format("package.path = %q .. package.path; package.cpath = %q .. package.cpath; ",
                REPO .. "/?.lua;" .. REPO .. "/?/init.lua;",
                REPO .. "/titan-runtime/bootstrap/?" .. extension .. ";") .. (bootstrap or ""),
            REPO .. "/titanc", "--tree", tree, "--output", output,
            "-v",
        }
        if not compile_only then argv[#argv + 1] = "--no-uv-bootstrap" end
        for _, argument in ipairs(arguments) do argv[#argv + 1] = argument end
        return run(argv)
    end

    local function compile(...)
        return compile_with(nil, ...)
    end

    local function compiled(...)
        local ok, text = compile(...)
        assert.is_true(ok, text)
        return text
    end

    local function executable(owner)
        if platform.windows then
            return assert(driver.windows_program_paths(owner, nil, nil, output)).executable
        end
        return joined(output, owner:gsub("%.", "/"))
    end

    local function destination(name)
        return joined(suite, name .. (platform.windows and ".exe" or ""))
    end

    local function cases(program, ...)
        local argv = {
            "env", "TITAN_PATH_0_6=" .. prefix .. "/lib/titan/0.6;;", "TITAN_FILTER=",
        }
        if platform.windows then
            table.insert(argv, 2, "MSYS2_ENV_CONV_EXCL=TITAN_PATH_0_6")
        end
        argv[#argv + 1] = program
        for _, argument in ipairs({ ... }) do argv[#argv + 1] = argument end
        local ok, text = run(argv)
        assert.is_true(ok, text)
        local names = {}
        for name in text:gmatch("%[ RUN      %] ([^\n]+)") do names[#names + 1] = name end
        return names, text
    end

    local function native_work_absent(text)
        for line in text:gmatch("[^\n]+") do
            local function argument(value)
                return line:find("'" .. value .. "'", 1, true) or
                    line:find('"' .. value .. '"', 1, true)
            end
            assert.falsy(argument("-c"), line)
            if not argument("-E") then assert.falsy(argument("-o"), line) end
        end
    end

    local function unchanged_artifacts(program)
        local saved = {}
        local function collect(directory)
            for entry in lfs.dir(directory) do
                if entry ~= "." and entry ~= ".." then
                    local filename = joined(directory, entry)
                    if lfs.symlinkattributes(filename, "mode") == "directory" then
                        collect(filename)
                    elseif filename:sub(-2) == ".o" or
                           filename:sub(-2) == ".c" and entry ~= "preamble.c" then
                        saved[filename] = {
                            bytes = read(filename),
                            modified = lfs.attributes(filename, "modification"),
                        }
                    end
                end
            end
        end
        collect(output)
        saved[program] = { bytes = read(program), modified = lfs.attributes(program, "modification") }
        return function()
            for filename, previous in pairs(saved) do
                assert.equal(previous.bytes, read(filename), filename)
                assert.equal(previous.modified, lfs.attributes(filename, "modification"), filename)
            end
        end
    end

    before_each(function()
        suite = workspace()
        tree, output = joined(suite, "src"), joined(suite, "out")
        mkdirs(tree)
    end)

    after_each(function()
        local root = suite
        suite, tree, output = nil, nil, nil
        if root then remove_tree(root) end
    end)

    it("uses bytewise automatic order for the default executable owner", function()
        source("z_tests", test_source())
        source("A_tests", test_source())
        compiled("--test", "--test-dir", tree)
        assert.equal("file", lfs.attributes(executable("A_tests"), "mode"))
        assert.is_nil(lfs.attributes(executable("z_tests")))
        assert.same({ "A_tests.test_pass", "z_tests.test_pass" }, cases(executable("A_tests")))
    end)

    it("builds and certifies discovery through a differently spelled source-tree parent", function()
        if not require_symlink_capability() then return end
        source("suite.alpha_tests", test_source("test_alias"))
        local physical_tree = tree
        local alias_tree = joined(suite, "source-alias")
        assert(lfs.link(physical_tree, alias_tree, true))
        tree = alias_tree
        local program = destination("aliased-tests")
        compiled("--test", "--test-dir", joined(physical_tree, "suite"),
            "--incremental", "--exe", program)
        assert.same({ "suite.alpha_tests.test_alias" }, cases(program))
        local assert_unchanged = unchanged_artifacts(program)
        local text = compiled("--test", "--test-dir", joined(alias_tree, "suite"),
            "--incremental", "--exe", program)
        contains(text, "Titan object hit suite.alpha_tests:")
        absent(text, "Titan object miss ")
        native_work_absent(text)
        assert_unchanged()
        assert.same({ "suite.alpha_tests.test_alias" }, cases(program))
    end)

    it("keeps the explicit CLI owner first and honors an exact executable destination", function()
        source("z_custom", test_source())
        source("a_tests", test_source())
        compiled("--test", "--test-dir", tree, "z_custom", "z_custom")
        assert.equal("file", lfs.attributes(executable("z_custom"), "mode"))
        local program = destination("product/tests")
        compiled("--test", "--test-dir", tree, "--exe", program, "z_custom")
        assert.same({ "a_tests.test_pass", "z_custom.test_pass" }, cases(program))
    end)

    it("keeps semantic case signatures independent of matching filenames", function()
        source("signatures_tests", [[
local test = import "titan.test"
type Context = test.Context
record Lookalike end
function test_valid(context: Context): integer
    test.assert(context:name() == "signatures_tests.test_valid")
    return 7
end
local function test_local(context: test.Context) raise "local function ran" end
function test_no_parameter() raise "zero-parameter function ran" end
function test_wrong_parameter(context: Lookalike) raise "lookalike function ran" end
function test_extra_parameter(context: test.Context, extra: integer) raise "two-parameter function ran" end
function test_variadic(context: test.Context, ...: integer) raise "variadic function ran" end
function ordinary(context: test.Context) raise "non-test function ran" end
]])
        source("empty_specs", "function helper(): integer return 1 end\n")
        compiled("--test", "--test-dir", tree)
        assert.same({ "signatures_tests.test_valid" }, cases(executable("empty_specs")))
    end)

    it("ignores unrelated malformed source but diagnoses selected roots and contributors", function()
        source("alpha_tests", test_source())
        source("unused", "this is invalid Titan\n")
        compiled("--test", "--test-dir", tree)
        assert.same({ "alpha_tests.test_pass" }, cases(executable("alpha_tests")))
        local selected = source("broken_specs", "this is invalid Titan\n")
        local ok, text = compile("--test", "--test-dir", tree)
        assert.is_false(ok)
        contains(text, "broken_specs.titan")
        assert(os.remove(selected))
        source("folder_tests", test_source(), true)
        put(tree, "folder_tests/contributor.titan", "this is invalid Titan\n")
        ok, text = compile("--test", "--test-dir", tree)
        assert.is_false(ok)
        contains(text, "contributor.titan")
    end)

    it("reports unreadable selected mains and contributors rather than dropping their cases", function()
        local filename = source("alpha_tests", test_source())
        source("folder_tests", test_source(), true)
        local contributor = put(tree, "folder_tests/extra.titan",
            "function test_extra(context: test.Context) test.assert(true) end\n")
        for _, unreadable in ipairs({ filename, contributor }) do
            local bootstrap = string.format([[
local compiler_io = require("titan-compiler.io")
local original_new = compiler_io.new_sync
compiler_io.new_sync = function()
    local strategy = original_new()
    local original_read = strategy.read_file
    function strategy:read_file(path, ...)
        if require("titan-compiler.path").normalize(path) ==
           require("titan-compiler.path").normalize(%q) then
            return nil, "permission denied for selected source"
        end
        return original_read(self, path, ...)
    end
    return strategy
end
]], unreadable)
            local ok, text = compile_with(bootstrap, "--test", "--test-dir", tree)
            assert.is_false(ok)
            contains(text, "permission denied for selected source")
        end
    end)

    it("deduplicates automatic explicit and imported owners while exclusions remain nontransitive", function()
        source("suite.alpha_tests", test_source())
        source("outside", test_source("test_outside"))
        source("suite.beta_tests", 'local alpha = import "suite.alpha_tests"\n' ..
            'local outside = import "outside"\n' .. test_source())
        source("suite.unselected_tests", "invalid excluded Titan source\n")
        local program = destination("selected-tests")
        compiled("--test", "--test-dir", joined(tree, "suite"), "--test-dir", tree,
            "--test-exclude", "suite.alpha_tests", "--test-exclude", "suite.unselected_tests",
            "--exe", program,
            "suite.alpha_tests", "suite.beta_tests", "suite.alpha_tests")
        local expected = {
            "outside.test_outside", "suite.alpha_tests.test_pass", "suite.beta_tests.test_pass",
        }
        assert.same(expected, cases(program))
        compiled("--test", "--test-dir", joined(tree, "suite"),
            "--test-exclude", "suite.alpha_tests", "--test-exclude", "suite.unselected_tests",
            "--exe", program)
        assert.same(expected, cases(program))
    end)

    it("performs owner selection in object-only mode and certifies those objects at final link", function()
        source("alpha_tests", test_source())
        local first = compiled("--test", "--test-dir", tree, "-c", "--incremental")
        contains(first, "-fno-optimize-sibling-calls")
        assert.equal("file", lfs.attributes(joined(output, "alpha_tests.o"), "mode"))
        assert.is_nil(lfs.attributes(executable("alpha_tests")))
        local second = compiled("--test", "--test-dir", tree, "-c", "--incremental")
        contains(second, "Titan object hit alpha_tests:")
        native_work_absent(second)
        local final = compiled("--test", "--test-dir", tree, "--incremental")
        contains(final, "Titan object hit alpha_tests:")
        assert.same({ "alpha_tests.test_pass" }, cases(executable("alpha_tests")))
        local forced = compiled("--test", "--test-dir", tree, "-c")
        absent(forced, "Titan object hit alpha_tests:")
        contains(forced, "alpha_tests.c")
    end)

    it("rejects invalid discovery option combinations and empty selections in both modes", function()
        source("ordinary", "function helper(): integer return 1 end\n")
        for _, arguments in ipairs({
            { "--test-dir", tree, "ordinary" },
            { "--test-exclude", "ordinary", "ordinary" },
            { "--test", "--test-exclude", "ordinary", "ordinary" },
        }) do
            local ok, text = compile(table.unpack(arguments))
            assert.is_false(ok)
            contains(text, "--test")
        end
        for _, mode in ipairs({ {}, { "-c" } }) do
            local arguments = { "--test", "--test-dir", tree }
            for _, value in ipairs(mode) do arguments[#arguments + 1] = value end
            local ok, text = compile(table.unpack(arguments))
            assert.is_false(ok)
            contains(text, "no test modules found")
        end
        compiled("--test", "--test-dir", tree, "ordinary")
        assert.same({}, cases(executable("ordinary")))
    end)

    it("preserves explicit-only selection when no discovery directory is supplied", function()
        source("custom", test_source())
        source("unselected_tests", "invalid Titan source\n")
        compiled("--test", "custom")
        assert.same({ "custom.test_pass" }, cases(executable("custom")))
    end)

    it("uses certified saved test functions on a warm build without parsing checking compilation or linking", function()
        source("suite.alpha_tests", test_source("test_alpha"))
        source("suite.beta_specs", test_source("test_beta"))
        local program = destination("warm-tests")
        compiled("--test", "--test-dir", tree, "--incremental", "--exe", program)
        local assert_unchanged = unchanged_artifacts(program)
        local ok, text = compile_with([[
require("titan-compiler.parser").parse = function() error("warm build parsed source") end
require("titan-compiler.checker").check = function() error("warm build checked source") end
require("titan-compiler.test_runner").render = function() error("warm build rendered a runner") end
]], "--test", "--test-dir", joined(tree, "suite"), "--test-dir", tree,
            "--incremental", "--exe", program)
        assert.is_true(ok, text)
        contains(text, "Titan object hit suite.alpha_tests:")
        contains(text, "Titan object hit suite.beta_specs:")
        absent(text, "Titan object miss ")
        native_work_absent(text)
        assert_unchanged()
        assert.same({ "suite.alpha_tests.test_alpha", "suite.beta_specs.test_beta" }, cases(program))
    end)

    it("refreshes added removed and renamed roots without linking stale unreferenced objects", function()
        local alpha = source("alpha_tests", test_source("test_alpha"))
        source("zeta_tests", test_source("test_zeta"))
        local program = destination("inventory-tests")
        compiled("--test", "--test-dir", tree, "--incremental", "--exe", program)
        local zeta_object = read(joined(output, "zeta_tests.o"))
        local beta = source("beta_tests", test_source("test_beta"))
        local added = compiled("--test", "--test-dir", tree, "--incremental", "--exe", program)
        contains(added, "Titan object miss beta_tests: no-object")
        contains(added, "Titan object hit zeta_tests:")
        assert.same({ "alpha_tests.test_alpha", "beta_tests.test_beta", "zeta_tests.test_zeta" }, cases(program))
        assert(os.remove(alpha))
        assert(os.rename(beta, joined(tree, "gamma_tests.titan")))
        local changed = compiled("--test", "--test-dir", tree, "--incremental", "--exe", program)
        contains(changed, "Titan object miss gamma_tests: no-object")
        absent(changed, "Titan object hit alpha_tests:")
        absent(changed, "Titan object hit beta_tests:")
        assert.same({ "gamma_tests.test_beta", "zeta_tests.test_zeta" }, cases(program))
        assert.equal(zeta_object, read(joined(output, "zeta_tests.o")))
    end)

    it("invalidates saved cases for preserved-mtime source changes", function()
        local filename = source("alpha_tests", test_source("test_old"))
        local program = destination("changed-cases")
        compiled("--test", "--test-dir", tree, "--incremental", "--exe", program)
        local attributes = assert(lfs.attributes(filename))
        put(tree, "alpha_tests.titan", test_source("test_new"))
        assert(lfs.touch(filename, attributes.access, attributes.modification))
        local text = compiled("--test", "--test-dir", tree, "--incremental", "--exe", program)
        contains(text, "Titan object miss alpha_tests: source-content")
        assert.same({ "alpha_tests.test_new" }, cases(program))
    end)

    it("refreshes folder contributor additions removals and their case inventory", function()
        source("folder_tests", test_source("test_main"), true)
        local program = destination("folder-cases")
        compiled("--test", "--test-dir", tree, "--incremental", "--exe", program)
        local contributor = put(tree, "folder_tests/extra_specs.titan",
            "function test_added(context: test.Context) test.assert(true) end\n")
        local added = compiled("--test", "--test-dir", tree, "--incremental", "--exe", program)
        contains(added, "Titan object miss folder_tests: source-set")
        assert.same({ "folder_tests.test_added", "folder_tests.test_main" }, cases(program))
        assert(os.remove(contributor))
        local removed = compiled("--test", "--test-dir", tree, "--incremental", "--exe", program)
        contains(removed, "Titan object miss folder_tests: source-set")
        assert.same({ "folder_tests.test_main" }, cases(program))
    end)

    it("retries a failed selected source change without accepting stale saved cases", function()
        source("alpha_tests", test_source("test_before"))
        source("zeta_tests", test_source("test_zeta"))
        local program = destination("retry-tests")
        compiled("--test", "--test-dir", tree, "--incremental", "--exe", program)
        put(tree, "alpha_tests.titan", "invalid Titan source\n")
        local ok, text = compile("--test", "--test-dir", tree, "--incremental", "--exe", program)
        assert.is_false(ok)
        contains(text, "alpha_tests.titan")
        put(tree, "alpha_tests.titan", test_source("test_after"))
        local retried = compiled("--test", "--test-dir", tree, "--incremental", "--exe", program)
        contains(retried, "Titan object hit zeta_tests:")
        assert.same({ "alpha_tests.test_after", "zeta_tests.test_zeta" }, cases(program))
    end)

    it("keeps runtime case filters independent of the compiled root inventory", function()
        source("alpha_tests", test_source("test_alpha"))
        source("beta_tests", test_source("test_beta"))
        local program = destination("filtered-tests")
        compiled("--test", "--test-dir", tree, "--incremental", "--exe", program)
        assert.same({ "alpha_tests.test_alpha" }, cases(program, "--filter=alpha_tests[.]test_alpha$"))
        local text = compiled("--test", "--test-dir", tree, "--incremental", "--exe", program)
        contains(text, "Titan object hit alpha_tests:")
        contains(text, "Titan object hit beta_tests:")
        native_work_absent(text)
        assert.same({ "alpha_tests.test_alpha", "beta_tests.test_beta" }, cases(program))
    end)
end)
