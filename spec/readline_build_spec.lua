local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"

local REPO_ROOT = assert(lfs.currentdir())
local MAKEFILE = REPO_ROOT .. "/Makefile"
local READLINE_PATCH =
    REPO_ROOT .. "/vendor/readline/readline-8.3-p1-p3.patch"
local READLINE_LICENSE = REPO_ROOT .. "/LICENSES/readline-LICENSE"
local READLINE_UPSTREAM = REPO_ROOT .. "/vendor/readline/UPSTREAM.md"
local OLD_MTIME = 946684800

local HOST_CC = os.getenv("CC") or "cc"
local HOST_AR = os.getenv("AR") or "ar"
local HOST_RANLIB = os.getenv("RANLIB") or "ranlib"

local EXPECTED_HASHES = {
    READLINE_SHA256 =
        "fe5383204467828cd495ee8d1d3c037a7eba1389c22bc6a041f627976f9061cc",
    READLINE_COMBINED_PATCH_SHA256 =
        "70cbc596c0a7b3a35fabb8a05711a60e2695bd2d06a4e2f46f6f168f84403f96",
    READLINE_LICENSE_SHA256 =
        "8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903",
    READLINE_PATCH_001_SHA256 =
        "21f0a03106dbe697337cd25c70eb0edbaa2bdb6d595b45f83285cdd35bac84de",
    READLINE_PATCH_002_SHA256 =
        "e27364396ba9f6debf7cbaaf1a669e2b2854241ae07f7eca74ca8a8ba0c97472",
    READLINE_PATCH_003_SHA256 =
        "72dee13601ce38f6746eb15239999a7c56f8e1ff5eb1ec8153a1f213e4acdb29",
}

local function quote(word)
    return assert(cdriver.shell_quote(word))
end

local function run(argv, cwd)
    local words = {}
    for index, word in ipairs(argv) do words[index] = quote(word) end
    local command = table.concat(words, " ")
    if cwd then command = "cd " .. quote(cwd) .. " && " .. command end
    local pipe = assert(io.popen(command .. " 2>&1", "r"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    return ok == true, output, why, code
end

local function configured_argv(environment, fallback, ...)
    local argv = assert(cdriver.split_shell_words(
        os.getenv(environment) or fallback))
    for _, word in ipairs({ ... }) do argv[#argv + 1] = word end
    return argv
end

local function with_ccache_disabled(argv)
    local wrapped = { "env", "CCACHE_DISABLE=1" }
    for _, word in ipairs(argv) do wrapped[#wrapped + 1] = word end
    return wrapped
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    assert.truthy(file:close())
    return contents
end

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    assert.truthy(file:write(contents))
    assert.truthy(file:close())
end

local function make_directory(path)
    if lfs.symlinkattributes(path, "mode") == "directory" then return end
    local parent = path:match("^(.+)/[^/]+$")
    if parent then make_directory(parent) end
    assert.truthy(lfs.mkdir(path), path)
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

local function temporary_directory(label)
    local path = os.tmpname() .. "-titan-" .. label
    os.remove(path)
    assert.truthy(lfs.mkdir(path))
    return path
end

local function command_succeeded(ok, output, why, code)
    assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
        tostring(code) .. ")")
end

local function command_failed(ok, output, why, code)
    assert.falsy(ok, output .. "\n(" .. tostring(why) .. ", " ..
        tostring(code) .. ")")
end

local function make_variables(contents)
    local variables = {}
    for line in contents:gmatch("[^\r\n]+") do
        local name, value = line:match(
            "^([A-Z][A-Z0-9_]*)%s*:?=%s*(.-)%s*$")
        if name then variables[name] = value end
    end
    return variables
end

local function sha256(path)
    local attempts = {
        { "sha256sum", path },
        { "shasum", "-a", "256", path },
    }
    local failures = {}
    for _, argv in ipairs(attempts) do
        local ok, output, why, code = run(argv)
        if ok then
            return assert(output:match("^([0-9a-fA-F]+)")):lower()
        end
        failures[#failures + 1] = output .. " (" .. tostring(why) ..
            ", " .. tostring(code) .. ")"
    end
    error("neither sha256sum nor shasum could hash " .. path .. ":\n" ..
        table.concat(failures, "\n"))
end

local function prefix_from_cpath(cpath)
    for template in (cpath .. ";"):gmatch("(.-);") do
        local root = template:match("^(.*)/lib/lua/5%.5/%?%.so$")
        if root then return root end
    end
end

describe("GNU Readline selection", function()
    local workspace
    local prefix = (os.getenv("PREFIX") or prefix_from_cpath(package.cpath) or ""):gsub("/+$", "")
    local selection_config

    before_each(function()
        workspace = temporary_directory("readline-build")
        prefix = workspace .. "/prefix"
        selection_config =
            workspace .. "/lua-5.5.1/.titan-readline-8.3-p3.config"
    end)

    after_each(function()
        remove_tree(workspace)
    end)

    local function make_readline(extra)
        local argv = {
            "env", "CCACHE_DISABLE=1",
            "make", "--no-print-directory", "-f", MAKEFILE,
            "PREFIX=" .. prefix,
            "LUA_PLATFORM=linux-readline",
            "READLINE_PKG_CONFIG=false",
            "LUA_CC=" .. HOST_CC,
            "AR=" .. HOST_AR,
            "RANLIB=" .. HOST_RANLIB,
            "LUA_MYCFLAGS=",
            "LUA_MYLDFLAGS=",
            "LUA_MYLIBS=",
        }
        for _, word in ipairs(extra or {}) do argv[#argv + 1] = word end
        argv[#argv + 1] = "readline"
        return run(argv, workspace)
    end

    local function assert_no_fallback_tree()
        for _, path in ipairs({
            workspace .. "/readline-8.3",
            workspace .. "/readline-build",
            workspace .. "/readline-8.3.tar.gz",
        }) do
            assert.falsy(lfs.symlinkattributes(path, "mode"), path)
        end
    end

    local function assert_no_selection_config()
        assert.falsy(lfs.symlinkattributes(selection_config, "mode"),
            selection_config)
        assert_no_fallback_tree()
    end

    local function build_fake_readline()
        local root = workspace .. "/fake-readline"
        local include = root .. "/include/readline"
        local lib = root .. "/lib"
        local source = root .. "/readline.c"
        local object = root .. "/readline.o"
        local archive = lib .. "/libreadline.a"
        make_directory(include)
        make_directory(lib)
        write_file(include .. "/readline.h", [[
#ifndef TITAN_TEST_READLINE_H
#define TITAN_TEST_READLINE_H
extern char *rl_readline_name;
char *readline(const char *prompt);
#endif
]])
        write_file(include .. "/history.h", [[
#ifndef TITAN_TEST_HISTORY_H
#define TITAN_TEST_HISTORY_H
void add_history(const char *line);
#endif
]])
        write_file(source, [[
#include <stddef.h>
#include <readline/readline.h>
#include <readline/history.h>
char *rl_readline_name = "titan-test";
char *readline(const char *prompt) { (void)prompt; return NULL; }
void add_history(const char *line) { (void)line; }
]])

        local ok, output, why, code = run(with_ccache_disabled(configured_argv(
            "CC", "cc", "-I" .. root .. "/include", "-c", source,
            "-o", object)))
        command_succeeded(ok, output, why, code)
        ok, output, why, code = run(with_ccache_disabled(configured_argv(
            "AR", "ar", "rcs", archive, object)))
        command_succeeded(ok, output, why, code)
        ok, output, why, code = run(with_ccache_disabled(configured_argv(
            "RANLIB", "ranlib", archive)))
        command_succeeded(ok, output, why, code)
        return root
    end

    it("rejects an invalid provider mode before provisioning", function()
        local ok, output, why, code = make_readline({
            "READLINE_MODE=not-a-mode",
        })
        command_failed(ok, output, why, code)
        assert.truthy(output:find(
            "ERROR: READLINE_MODE must be auto, system, or bundled " ..
            "(got 'not-a-mode').", 1, true), output)
        assert_no_selection_config()
    end)

    it("reports an unusable compiler before classifying Readline", function()
        local missing_cc = workspace .. "/missing-cc"
        local ok, output, why, code = make_readline({
            "READLINE_MODE=system",
            "LUA_CC=" .. missing_cc,
        })
        command_failed(ok, output, why, code)
        assert.truthy(output:find(
            "ERROR: Lua compiler/linker sanity probe failed before " ..
            "Readline selection.", 1, true), output)
        assert.truthy(output:find(missing_cc, 1, true), output)
        assert.falsy(output:find(
            "readline header/library probe failed", 1, true), output)
        assert_no_selection_config()
    end)

    it("reports invalid fallback flags before terminal-library selection",
        function()
        local missing_header = workspace .. "/missing-readline-flag.h"
        local ok, output, why, code = make_readline({
            "READLINE_MODE=bundled",
            "READLINE_CPPFLAGS=-include " .. missing_header,
            "READLINE_PATCH_FILE=" .. READLINE_PATCH,
            "READLINE_LICENSE_SOURCE=" .. READLINE_LICENSE,
        })
        command_failed(ok, output, why, code)
        assert.truthy(output:find(
            "ERROR: Readline fallback compiler/linker sanity probe failed " ..
            "before terminal-library selection.", 1, true), output)
        assert.truthy(output:find(missing_header, 1, true), output)
        assert.falsy(output:find(
            "prefix-local Readline needs a usable", 1, true), output)
        assert_no_selection_config()
    end)

    it("makes forced-system probe failure terminal", function()
        local missing_archive =
            workspace .. "/missing/libtitan-readline-probe.a"
        local ok, output, why, code = make_readline({
            "READLINE_MODE=system",
            "READLINE_SYSTEM_CPPFLAGS=",
            "READLINE_SYSTEM_LDFLAGS=",
            "READLINE_SYSTEM_LIBS=" .. missing_archive,
        })
        command_failed(ok, output, why, code)
        assert.truthy(output:find(
            "ERROR: READLINE_MODE=system, but the readline " ..
            "header/library probe failed.", 1, true), output)
        assert_no_selection_config()
    end)

    it("binds the vendored patch to the recorded upstream hashes", function()
        local makefile = read_file(MAKEFILE)
        local variables = make_variables(makefile)
        local upstream = read_file(READLINE_UPSTREAM)
        for name, expected in pairs(EXPECTED_HASHES) do
            assert.equal(expected, variables[name], name)
            assert.truthy(upstream:find(expected, 1, true), name)
        end
        assert.equal(EXPECTED_HASHES.READLINE_COMBINED_PATCH_SHA256,
            sha256(READLINE_PATCH))
        assert.equal(EXPECTED_HASHES.READLINE_LICENSE_SHA256,
            sha256(READLINE_LICENSE))
    end)

    it("keeps the bundled headers and archive authoritative", function()
        local makefile = read_file(MAKEFILE)
        local recipes = makefile:gsub("\\\n", " "):gsub("%s+", " ")
        assert.truthy(recipes:find(
            '$(LUA_CC) -I"$(READLINE_PRIVATE_INCLUDEDIR)"', 1, true))
        assert.truthy(recipes:find(
            '"$(READLINE_STATIC_LIB)" $(LUA_MYLIBS) $$termcap', 1, true))
        assert.truthy(recipes:find(
            '$(LUA_CC) -I"$$stage/include"', 1, true))
        assert.truthy(recipes:find(
            '"$$stage/lib/libreadline.a" $(LUA_MYLIBS)', 1, true))
        assert.truthy(recipes:find(
            'lua_mycflags="-I$(abspath $(READLINE_PRIVATE_INCLUDEDIR)) ' ..
            '$$lua_mycflags";', 1, true))
        assert.truthy(recipes:find(
            'lua_myldflags="-L$(abspath $(READLINE_PRIVATE_LIBDIR)) ' ..
            '$$lua_myldflags";', 1, true))
        assert.truthy(recipes:find(
            'rm -rf "$$stage/lib/pkgconfig";', 1, true))
    end)
end)
