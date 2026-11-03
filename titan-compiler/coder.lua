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
require "titan-compiler.coder.reflection"
require "titan-compiler.coder.nominal_codec"
require "titan-compiler.coder.closure_transfer"
require "titan-compiler.coder.module"
require "titan-compiler.coder.binary"
require "titan-compiler.coder.generate"

local implementation = core.coder

-- Supported compiler-facing API; implementation helpers live in the slices.
return {
    DEFAULT_SPLIT_THRESHOLD = implementation.DEFAULT_SPLIT_THRESHOLD,
    PRIVATE_HEADER_MARKER = implementation.PRIVATE_HEADER_MARKER,
    generate = implementation.generate,
    prepare_coverage = implementation.prepare_coverage,
    -- Emission policy is an explicit input of out-of-band renders (foreign
    -- headers), which happen before C generation.
    emission_policy = implementation.emission_policy,
    same_emission_policy = implementation.same_emission_policy,
    current_emission_policy = implementation.current_emission_policy,
    with_emission_policy = implementation.with_emission_policy,
    generate_ffi_header = implementation.generate_ffi_header,
    generate_foreign_header = implementation.generate_foreign_header,
    external_symbols = implementation.external_symbols,
    interface_external_symbols = implementation.interface_external_symbols,
    foreign_external_symbols = implementation.foreign_external_symbols,
}
