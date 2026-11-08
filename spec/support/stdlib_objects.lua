-- The generated object of a standard-library module, named as the compiler
-- names it: the selected source (flat or folder) relocated under the output
-- root. The Windows stdlib-check gate and the Unix artifact audits share it,
-- so splitting a module into a folder never leaves a reader on a flat path.
local driver = require "titan-compiler.driver"

local M = {}

function M.object(context, modname, source_root, output_root)
    local selected = assert(driver.resolve_source(context, modname, source_root))
    assert(selected.kind == "flat" or selected.kind == "folder",
        modname .. " has no selected source for this target")
    assert(driver.relocate_source_output(modname, selected, output_root))
    return driver.module_output_stem(selected.native_output, modname) .. ".o"
end

return M
