local lfs = require "lfs"
local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local phase2 = require "spec.support.phase2"

local M = {}

local function quote(word)
    return "'" .. tostring(word):gsub("'", "'\\''") .. "'"
end

local function write(path, contents)
    local file = assert(io.open(path, "wb"))
    file:write(contents)
    file:close()
end

local function append(destination, source)
    for _, value in ipairs(source) do
        destination[#destination + 1] = value
    end
end

local function shell_command(argv)
    local quoted = {}
    for index, word in ipairs(argv) do
        quoted[index] = assert(cdriver.shell_quote(word))
    end
    return table.concat(quoted, " ")
end

local function shell_words(command, label)
    local words, err = cdriver.split_shell_words(command)
    assert.truthy(words, (label or "command") .. ": " .. tostring(err))
    return words
end

local function compiler_command()
    local lua = lfs.attributes(M.repo .. "/lua") and
        M.repo .. "/lua" or M.repo .. "/.lua/bin/lua"
    return quote(lua) .. " -e " .. quote(
        "package.path=\"" .. M.repo .. "/?.lua;" .. M.repo ..
        "/?/init.lua;\" .. package.path") .. " " .. quote(M.repo .. "/titanc")
end

local function build_os(workspace)
    write(workspace .. "/stdlib/os.titan",
        phase2.read(M.repo .. "/stdlib/os.titan"))
    local cflags = os.getenv("TITAN_TEST_EXTRA_CFLAGS") or ""
    local ldflags = os.getenv("TITAN_TEST_EXTRA_LDFLAGS") or ""
    local command = table.concat({
        "env CCACHE_DISABLE=1", "TITAN_PATH_0_11=", "TITAN_PATH=",
        "TITAN_STDLIB_PATH=" .. quote(workspace),
        "TITAN_EXTRA_CPPFLAGS=''",
        "TITAN_EXTRA_CFLAGS=" .. quote(cflags),
        "TITAN_EXTRA_LDFLAGS=" .. quote(ldflags),
        compiler_command(), "--stdlib-build --tree",
        quote(workspace .. "/stdlib"), "--lua-name titan.os os",
    }, " ")
    local ok, _, output = phase2.run(command, workspace)
    assert.truthy(ok, output)
    ok, _, output = phase2.run("ln -s ../os.so titan/os.so", workspace)
    assert.truthy(ok, output)
end

local function build_process_child(workspace)
    local cppflags, ldflags, archive = phase2.host_libuv_config()
    local argv = { "env", "CCACHE_DISABLE=1" }
    append(argv, shell_words(os.getenv("CC") or "cc", "CC"))
    append(argv, {
        "-std=c99", "-O2", "-Wall", "-Wextra", "-Werror",
    })
    local sanitizer_cflags = os.getenv("TITAN_TEST_EXTRA_CFLAGS")
    if sanitizer_cflags and #sanitizer_cflags > 0 then
        append(argv, shell_words(sanitizer_cflags,
            "TITAN_TEST_EXTRA_CFLAGS"))
    end
    append(argv, shell_words(cppflags, "libuv CPPFLAGS"))
    append(argv, {
        M.repo .. "/spec/fixtures/uv/phase6/process_child.c",
        archive,
    })
    append(argv, shell_words(ldflags, "libuv LDFLAGS"))
    local sanitizer_ldflags = os.getenv("TITAN_TEST_EXTRA_LDFLAGS")
    if sanitizer_ldflags and #sanitizer_ldflags > 0 then
        append(argv, shell_words(sanitizer_ldflags,
            "TITAN_TEST_EXTRA_LDFLAGS"))
    end
    append(argv, { "-o", workspace .. "/process_child" })
    local ok, _, output = phase2.run(shell_command(argv), workspace)
    assert.truthy(ok, output)
end

local PHASE6_TRANSFORMER =
    "spec/support/make_phase6_test_variant.lua"

function M.workspace()
    return phase2.cached_workspace(
        "phase6-os:" .. PHASE6_TRANSFORMER, function()
            local workspace = phase2.variant_workspace(PHASE6_TRANSFORMER)
            build_os(workspace)
            return workspace
        end)
end

function M.process_child(workspace)
    local path = workspace .. "/process_child"
    if not lfs.attributes(path) then build_process_child(workspace) end
    return path
end

function M.copy_fixture(workspace, fixture, modname)
    write(workspace .. "/src/" .. modname .. ".titan",
        phase2.read(M.repo .. "/spec/fixtures/uv/phase6/" .. fixture))
end

function M.compile(workspace, modname, options)
    options = options or {}
    options.stdlib = options.stdlib or workspace
    return phase2.compile(workspace, modname, options)
end

M.cleanup = phase2.cleanup
M.read = phase2.read
M.run = phase2.run
M.lua_command = phase2.variant_lua_command
M.variant_lua_command = phase2.variant_lua_command
M.repo = phase2.repo
return M
