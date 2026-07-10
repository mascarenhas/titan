local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"

local STDLIB_MODULES = { "coroutine", "uv" }

local function quote(word)
    local quoted = assert(cdriver.shell_quote(word))
    return quoted
end

local function run(argv, environment)
    local words = {}
    for _, word in ipairs(argv) do table.insert(words, quote(word)) end
    local command = table.concat(words, " ")
    if environment then command = environment .. " " .. command end
    local pipe = assert(io.popen(command .. " 2>&1", "r"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    return ok == true, output, why, code
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                remove_tree(path .. "/" .. entry)
            end
        end
        lfs.rmdir(path)
    elseif mode then
        os.remove(path)
    end
end

local function assert_relative_alias(canonical, alias, expected_target)
    assert.equal("file", lfs.attributes(canonical, "mode"))
    assert.equal("link", lfs.symlinkattributes(alias, "mode"))
    local readlink = assert(io.popen("readlink " .. quote(alias)))
    assert.equal(expected_target, readlink:read("*l"))
    assert.truthy(readlink:close())

    local ca, aa = assert(lfs.attributes(canonical)),
        assert(lfs.attributes(alias))
    if ca.dev and ca.ino and aa.dev and aa.ino then
        assert.equal(ca.dev, aa.dev)
        assert.equal(ca.ino, aa.ino)
    end
end

local function assert_uv_load_order(raw_lua, environment, canonical,
                                    canonical_first)
    local program = string.format([[
        local canonical = %q
        local open = assert(package.loadlib(canonical, "luaopen_titan_uv"))
        local first, second
        if %s then
            first = open()
            second = require "titan.uv"
        else
            first = require "titan.uv"
            second = open()
        end
        assert(type(first) == "userdata")
        assert(rawequal(first, second))
        assert(rawequal(second, package.loaded["titan.uv"]))
        assert(type(second.version()) == "string")
    ]], canonical, tostring(canonical_first))
    local ok, output, why, code = run({ raw_lua, "-e", program }, environment)
    assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
        tostring(code) .. ")")
end

describe("LuaRocks standard-library packaging", function()
    local tree
    local rock

    teardown(function()
        if tree then remove_tree(tree) end
        if rock then os.remove(rock) end
    end)

    it("packs, installs, aliases, and uninstalls every managed stdlib image",
       function()
        tree = os.tmpname()
        os.remove(tree)
        assert(lfs.mkdir(tree))

        local ok, output, why, code = run({
            "./luarocks", "pack", "titan", "dev-1",
        })
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        rock = assert(output:match("Packed:%s+([^\n]+)"), output)

        ok, output, why, code = run({
            "./luarocks", "install", "--tree", tree, rock,
            "--deps-mode=none",
        })
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        local libdir = tree .. "/lib/lua/5.5/titan"
        for _, module in ipairs(STDLIB_MODULES) do
            assert_relative_alias(
                libdir .. "/stdlib_0_11/" .. module .. ".so",
                libdir .. "/" .. module .. ".so",
                "stdlib_0_11/" .. module .. ".so")
        end

        local manifest_path = tree ..
            "/lib/luarocks/rocks-5.5/titan/dev-1/rock_manifest"
        local manifest = assert(io.open(manifest_path, "rb"))
        local manifest_text = manifest:read("*a")
        manifest:close()
        assert.truthy(manifest_text:find("stdlib_0_11", 1, true))
        for _, module in ipairs(STDLIB_MODULES) do
            assert.truthy(manifest_text:find(module .. ".so", 1, true))
        end
        assert.falsy(manifest_text:find("coro.so", 1, true))

        local raw_lua = ".lua/bin/lua"
        local stdlib_dir = libdir .. "/stdlib_0_11"
        local environment = "env LUA_CPATH=" .. quote(
            tree .. "/lib/lua/5.5/?.so;;") ..
            " TITAN_STDLIB_PATH=" .. quote(stdlib_dir)
        ok, output, why, code = run({ raw_lua, "-e", [[
            local builtin = require "coroutine"
            local standard_coroutine = require "titan.coroutine"
            local standard_uv = require "titan.uv"
            assert(type(builtin) == "table")
            assert(type(standard_coroutine) == "userdata")
            assert(type(standard_uv) == "userdata")
            assert(type(standard_uv.version()) == "string")
        ]] }, environment)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        local uv_canonical = stdlib_dir .. "/uv.so"
        assert_uv_load_order(raw_lua, environment, uv_canonical, false)
        assert_uv_load_order(raw_lua, environment, uv_canonical, true)

        local host_ok, host_output = run({ "uname", "-s" })
        assert.truthy(host_ok, host_output)
        local dependency_argv = host_output:match("^Darwin")
            and { "otool", "-L", uv_canonical }
            or { "readelf", "-d", uv_canonical }
        local deps_ok, deps_output, deps_why, deps_code =
            run(dependency_argv)
        assert.truthy(deps_ok, deps_output .. "\n(" ..
            tostring(deps_why) .. ", " .. tostring(deps_code) .. ")")
        assert.falsy(deps_output:lower():find("libuv", 1, true), deps_output)

        ok, output, why, code = run({
            "./luarocks", "remove", "--tree", tree, "titan", "--force",
            "--deps-mode=none",
        })
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        for _, module in ipairs(STDLIB_MODULES) do
            assert.falsy(lfs.symlinkattributes(
                libdir .. "/" .. module .. ".so"))
            assert.falsy(lfs.attributes(
                libdir .. "/stdlib_0_11/" .. module .. ".so"))
        end
    end)

    it("installs every canonical image and alias under a manual prefix",
       function()
        tree = os.tmpname()
        os.remove(tree)
        assert(lfs.mkdir(tree))

        local ok, output, why, code = run({
            "make", "--no-print-directory", "install-stdlib",
            "PREFIX=" .. tree,
        }, "env CCACHE_DISABLE=1")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        for _, module in ipairs(STDLIB_MODULES) do
            assert_relative_alias(
                tree .. "/lib/titan/0.11/" .. module .. ".so",
                tree .. "/lib/lua/5.5/titan/" .. module .. ".so",
                "../../../titan/0.11/" .. module .. ".so")
        end

        local environment = "env LUA_CPATH=" .. quote(
            tree .. "/lib/lua/5.5/?.so;;") ..
            " TITAN_STDLIB_PATH=" .. quote(
                tree .. "/lib/titan/0.11")
        ok, output, why, code = run({ ".lua/bin/lua", "-e", [[
            local uv = require "titan.uv"
            assert(type(uv) == "userdata")
            assert(type(uv.version()) == "string")
        ]] }, environment)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end)
end)
