local core = require "titan-compiler.checker.core"
require "titan-compiler.checker.c_types"
require "titan-compiler.checker.common"
require "titan-compiler.checker.binary_usage"
require "titan-compiler.checker.interfaces"
require "titan-compiler.checker.type_syntax"
require "titan-compiler.checker.expression_lists"
require "titan-compiler.checker.statements"
require "titan-compiler.checker.variables"
require "titan-compiler.checker.calls"
require "titan-compiler.checker.native_record_fields"
require "titan-compiler.checker.expressions"
require "titan-compiler.checker.declarations"
require "titan-compiler.checker.imports"
require "titan-compiler.checker.linear"
require "titan-compiler.checker.lowering"
require "titan-compiler.checker.completion"
require "titan-compiler.checker.entry"

local implementation = core.checker

-- Supported compiler-facing API; implementation helpers live in the slices.
return {
    configure_foreign_c = implementation.configure_foreign_c,
    check = implementation.check,
    register_module_interface = implementation.register_module_interface,
    checkimport = implementation.checkimport,
    has_main = implementation.has_main,
}
