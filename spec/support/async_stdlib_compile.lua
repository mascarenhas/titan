-- Child-process compiler used by async standard-library specs. The parent
-- sets CWD to its unique workspace, so generated artifacts stay isolated.
local repo, source_root, modname = assert(arg[1]), assert(arg[2]), assert(arg[3])
package.path = repo .. "/?.lua;" .. repo .. "/?/init.lua;" .. package.path

local checker = require "titan-compiler.checker"
local driver = require "titan-compiler.driver"

driver.TITAN_SOURCE_PATH = source_root
driver.LUA_SOURCE_PATH = repo .. "/lua-5.5.1/src/"
driver.TITAN_RUNTIME_PATH = assert(arg[4]) .. "/"
driver.LIBBACKTRACE_PATH = repo .. "/libbacktrace"
driver.configure_foreign_c()

local extra_objects = {}
for index = 5, #arg do
    extra_objects[#extra_objects + 1] = arg[index]
end

local loader = driver.defaultloader({}, {
    source_roots = { [modname] = true },
})
local root, errors = driver.with_loader(loader, function(loader)
    return checker.checkimport(modname, loader)
end)
if not root then error(errors, 0) end
if #errors ~= 0 then error(table.concat(errors, "\n"), 0) end

local has_main = checker.has_main(driver.imported[modname].ast)
local shim_plans
if not has_main then
    local shim_error
    shim_plans, shim_error = driver.plan_module_shims(modname, { modname })
    if not shim_plans then error(shim_error, 0) end
end

local objects = {}
for name, imported in pairs(driver.imported) do
    if imported.ast then
        local ok, err, object = driver.compile_module(name, imported,
            imported.deps or {}, false)
        if not ok then error(err, 0) end
        objects[#objects + 1] = object
    end
end

if has_main then
    local ok, err = driver.compile_program(modname, objects, nil, false,
        extra_objects, driver.imported[modname].program_output)
    if not ok then error(err, 0) end
else
    local ok, err = driver.compile_library(modname, objects, nil, false,
        extra_objects)
    if not ok then error(err, 0) end
    local wrote, write_error = driver.write_module_shims(shim_plans)
    if not wrote then error(write_error, 0) end
end
