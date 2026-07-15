-- Child-process compiler used by async standard-library specs. The parent
-- sets CWD to its unique workspace, so generated artifacts stay isolated.
local repo, source_root, modname = assert(arg[1]), assert(arg[2]), assert(arg[3])
package.path = repo .. "/?.lua;" .. repo .. "/?/init.lua;" .. package.path

local checker = require "titan-compiler.checker"
local driver = require "titan-compiler.driver"

driver.TITAN_SOURCE_PATH = source_root
driver.LUA_SOURCE_PATH = repo .. "/lua-5.5.0/src/"
driver.TITAN_RUNTIME_PATH = assert(arg[4]) .. "/"
driver.LIBBACKTRACE_PATH = repo .. "/libbacktrace"
driver.configure_foreign_c()

local extra_objects = {}
for index = 5, #arg do
    extra_objects[#extra_objects + 1] = arg[index]
end

local root, errors = checker.checkimport(modname, driver.defaultloader({}, {
    source_roots = { [modname] = true },
}))
if not root then error(errors, 0) end
if #errors ~= 0 then error(table.concat(errors, "\n"), 0) end

local objects = {}
for name, imported in pairs(driver.imported) do
    if imported.ast then
        local ok, err, object = driver.compile_module(name, imported,
            imported.deps or {}, false)
        if not ok then error(err, 0) end
        objects[#objects + 1] = object
    end
end

if checker.has_main(driver.imported[modname].ast) then
    local ok, err = driver.compile_program(modname, objects, nil, false,
        extra_objects)
    if not ok then error(err, 0) end
else
    local ok, err = driver.compile_library(modname, objects, nil, false,
        extra_objects)
    if not ok then error(err, 0) end
end
