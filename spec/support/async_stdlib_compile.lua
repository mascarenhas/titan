-- Child-process compiler used by async standard-library specs. The parent
-- sets CWD to its unique workspace, so generated artifacts stay isolated.
local repo, source_root, modname = assert(arg[1]), assert(arg[2]), assert(arg[3])
package.path = repo .. "/?.lua;" .. repo .. "/?/init.lua;" .. package.path

local checker = require "titan-compiler.checker"
local driver = require "titan-compiler.driver"

driver.TITAN_SOURCE_PATH = source_root
driver.LUA_SOURCE_PATH = assert(arg[5])
driver.TITAN_RUNTIME_PATH = assert(arg[4]) .. "/"
driver.LIBBACKTRACE_PATH = repo .. "/libbacktrace"
local context = driver.new_resolver_context()
local completed, failure = xpcall(function()
    driver.configure_foreign_c(context)

    local extra_objects = {}
    for index = 6, #arg do
        extra_objects[#extra_objects + 1] = arg[index]
    end

    local loader = driver.defaultloader({}, {
        context = context, source_roots = { [modname] = true },
    })
    local root, errors = driver.with_loader(loader, function(loader)
        return checker.checkimport(modname, loader)
    end)
    if not root then error(errors, 0) end
    if #errors ~= 0 then error(table.concat(errors, "\n"), 0) end

    local has_main = checker.has_main(driver.imported[modname].ast)
    local objects = {}
    for name, imported in pairs(driver.imported) do
        if imported.ast then
            local ok, err = driver.compile_module(name, imported,
                imported.deps or {}, false)
            if not ok then error(err, 0) end
            for _, object in ipairs(driver.module_compiled_objects(imported)) do
                objects[#objects + 1] = object
            end
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
    end
end, function(err) return err end)
local closed = table.pack(pcall(driver.close_resolver_context, context))
if not completed then error(failure, 0) end
if not closed[1] then error(closed[2], 0) end
if not closed[2] then error(closed[3], 0) end
