-- Native gate against a private installed compiler snapshot and matching SDK.
assert(package.config:sub(1, 1) == "\\", "native Windows Lua is required")
local sdk, clang, parent = assert(arg[1]), assert(arg[2]), assert(arg[3])
local platform = require "titan-compiler.platform"
local driver = require "titan-compiler.driver"
local compiler_io = require "titan-compiler.io"
local cdriver = require "c-parser.cdriver"
local cprobe = require "titan-compiler.cprobe"
local lfs = require "lfs"
local sync = compiler_io.new_sync()
local function same_path(a, b)
    return platform.path.normalize(assert(sync:absolute(a))):lower() ==
        platform.path.normalize(assert(sync:absolute(b))):lower()
end
local context = driver.new_resolver_context()
assert(driver.initialize_layout(context))
assert(driver.initialize_platform(context))
assert(driver.INSTALLED and not driver.SOURCE_CHECKOUT)
assert(same_path(driver.INSTALL_PATHS.root, sdk))
assert(same_path(driver.INSTALL_PATHS.lua_source, sdk .. "/src/lua-5.5.1"))
assert(same_path(driver.INSTALL_PATHS.liblua, sdk .. "/lib/liblua55.a"))
assert(driver.INSTALL_PATHS.lua_cpath:sub(-5) == "?.dll")
assert(table.concat(driver.module_binary_candidates("one.two.leaf"), ";") ==
    "one.dll;one/two.dll;one/two/leaf.dll")
assert(driver.close_resolver_context(context))
assert(package.loadlib(sdk .. "/lib/lua/5.5/titan.dll", "luaopen_titan"))

local root = assert(sync:reserve_sibling(parent .. "/driver-path-gate", true))
local unicode = root .. "/headers ação-日本語-😀"
assert(lfs.mkdir(unicode))
local child = unicode .. "/child.h"
local header = unicode .. "/parent.h"
local function write(path, contents)
    local file = assert(io.open(path, "wb")); assert(file:write(contents)); assert(file:close())
end
local service
local okay, problem = xpcall(function()
    write(child, "typedef int native_path_integer;\n")
    write(header, '#include "child.h"\ntypedef native_path_integer native_path_alias;\n')
    local options = { compiler = { clang }, compiler_include_dirs = {},
        source_dir = unicode, io = sync, cppflags = {} }
    for _, spelling in ipairs({ header, (header:gsub("/", "\\")) }) do
        local definitions, err, include = cdriver.process_file(spelling, options)
        assert(definitions, err)
        assert(definitions.native_path_integer and definitions.native_path_alias)
        assert(include.include_kind == "quote")
        assert(#include.c_header_dependencies == 2)
        for _, input in ipairs(include.c_header_dependencies) do
            assert(platform.is_absolute(input.path), input.path)
            assert(input.observation == nil)
            assert(type(input.identity) == "string" and input.identity ~= "")
        end
    end
    service = assert(cprobe.new_service({ compiler_argv = { clang },
        include_dirs = { sdk .. "/include", sdk .. "/src/lua-5.5.1" },
        io = sync, cache_directory = nil }))
    local module = assert(service:module_context({ source_dir = unicode,
        includes = { { include_kind = "quote", include_name = "parent.h" } } }))
    local result = module:validate_baseline()
    assert(result.status == "success", result.message or result.diagnostic or result.status)
    assert(service:close()); service = nil
end, debug.traceback)
if service then assert(service:close()) end
for _, file in ipairs({ header, child }) do
    if lfs.attributes(file) then assert(os.remove(file)) end
end
assert(lfs.rmdir(unicode)); assert(lfs.rmdir(root))
assert(okay, problem)
print("Windows installed compiler layout and Unicode C-header/probe gate passed: " .. parent)
