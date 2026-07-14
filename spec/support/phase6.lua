local lfs = require "lfs"
local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local phase2 = require "spec.support.phase2"

local M = {}

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

function M.workspace(label)
    local standard = phase2.standard_dir()
    assert.truthy(lfs.attributes(standard .. "/os.so"),
        "Phase 6 specs require prebuilt os.so; run make stdlib first")
    return phase2.workspace("phase6-os-" .. (label or "runtime"))
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
    local standard = phase2.standard_dir()
    assert.truthy(lfs.attributes(standard .. "/os.so"),
        "Phase 6 specs require prebuilt os.so; run make stdlib first")
    return phase2.compile(workspace, modname, options)
end

function M.libuv_cppflags()
    local cppflags = phase2.host_libuv_config()
    return cppflags
end

M.cleanup = phase2.cleanup
M.run = phase2.run
M.lua_command = phase2.lua_command
M.repo = phase2.repo
return M
