local lfs = require "lfs"
local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local async_stdlib = require "spec.support.async_stdlib"

local M = {}

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
    local cppflags, ldflags, archive = async_stdlib.host_libuv_config()
    local argv = { "env", "CCACHE_DISABLE=1" }
    append(argv, shell_words(os.getenv("CC") or "cc", "CC"))
    append(argv, {
        "-std=c99", "-Wall", "-Wextra", "-Werror",
    })
    local profile = os.getenv("TITAN_BUILD_PROFILE") or "validation"
    assert(profile == "validation" or profile == "production", "invalid TITAN_BUILD_PROFILE")
    append(argv, profile == "validation" and { "-O0", "-fno-lto" } or { "-O3" })
    local extra_cflags = os.getenv("TITAN_EXTRA_CFLAGS")
    if extra_cflags and #extra_cflags > 0 then append(argv, shell_words(extra_cflags, "TITAN_EXTRA_CFLAGS")) end
    local sanitizer_cflags = os.getenv("TITAN_TEST_EXTRA_CFLAGS")
    if sanitizer_cflags and #sanitizer_cflags > 0 then
        append(argv, shell_words(sanitizer_cflags,
            "TITAN_TEST_EXTRA_CFLAGS"))
    end
    append(argv, shell_words(cppflags, "libuv CPPFLAGS"))
    append(argv, {
        M.repo .. "/spec/fixtures/stdlib/native/os_process_child.c",
        archive,
    })
    append(argv, shell_words(ldflags, "libuv LDFLAGS"))
    local extra_ldflags = os.getenv("TITAN_EXTRA_LDFLAGS")
    if extra_ldflags and #extra_ldflags > 0 then append(argv, shell_words(extra_ldflags, "TITAN_EXTRA_LDFLAGS")) end
    local sanitizer_ldflags = os.getenv("TITAN_TEST_EXTRA_LDFLAGS")
    if sanitizer_ldflags and #sanitizer_ldflags > 0 then
        append(argv, shell_words(sanitizer_ldflags,
            "TITAN_TEST_EXTRA_LDFLAGS"))
    end
    append(argv, { "-o", workspace .. "/process_child" })
    local ok, _, output = async_stdlib.run(shell_command(argv), workspace)
    assert.truthy(ok, output)
end

function M.workspace(label)
    local standard = async_stdlib.standard_layout()
    assert.truthy(lfs.attributes(standard.container),
        "os specs require prebuilt titan.so; run make stdlib first")
    assert.truthy(lfs.attributes(standard.shim_root .. "/titan/os.lua"),
        "os specs require the generated titan/os.lua shim")
    return async_stdlib.workspace("os-" .. (label or "runtime"))
end

function M.process_child(workspace)
    local path = workspace .. "/process_child"
    if not lfs.attributes(path) then build_process_child(workspace) end
    return path
end

function M.compile(workspace, modname, options)
    local standard = async_stdlib.standard_layout()
    assert.truthy(lfs.attributes(standard.container),
        "os specs require prebuilt titan.so; run make stdlib first")
    assert.truthy(lfs.attributes(standard.shim_root .. "/titan/os.lua"),
        "os specs require the generated titan/os.lua shim")
    options = options or {}
    options.layout = options.layout or standard
    return async_stdlib.compile(workspace, modname, options)
end

function M.libuv_cppflags()
    local cppflags = async_stdlib.host_libuv_config()
    return cppflags
end

M.cleanup = async_stdlib.cleanup
M.run_lua_source = async_stdlib.run_lua_source
M.run_app = async_stdlib.run_app
M.write_source = async_stdlib.write_source
M.repo = async_stdlib.repo
return M
