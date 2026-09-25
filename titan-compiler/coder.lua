local core = require "titan-compiler.coder.core"
require "titan-compiler.coder.names"
require "titan-compiler.coder.values"
require "titan-compiler.coder.flow"
require "titan-compiler.coder.nativeoption"
require "titan-compiler.coder.nominal"
require "titan-compiler.coder.nominalcalls"
require "titan-compiler.coder.interfaces"
require "titan-compiler.coder.numerics"
require "titan-compiler.coder.statements"
require "titan-compiler.coder.calls"
require "titan-compiler.coder.immediate"
require "titan-compiler.coder.expressions"
require "titan-compiler.coder.declarations"
require "titan-compiler.coder.native_record_fields"
require "titan-compiler.coder.module"
require "titan-compiler.coder.generate"

local implementation = core.coder

-- Supported compiler-facing API; implementation helpers live in the slices.
return {
    generate = implementation.generate,
    generate_ffi_header = implementation.generate_ffi_header,
    generate_foreign_header = implementation.generate_foreign_header,
    external_symbols = implementation.external_symbols,
    interface_external_symbols = implementation.interface_external_symbols,
}
