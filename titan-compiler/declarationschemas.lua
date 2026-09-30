-- Closed semantic declaration fields shared by project and C-header manifests.
-- Consumers add their own root/container roles without expanding Type.C graphs.
-- A question mark marks an optional field; all other fields are required.
-- Hybrid member lists derive string keys from their ordered descriptors.
local schemas = {
    completion_fact = {
        name = "string", kind = "integer", detail = "string",
        lookup_domain = "string", lookup_key = "string", type_key = "string",
        scope_id = "integer", scope_depth = "integer", declaration_order = "integer",
        available = "boolean", islocal = "boolean", visibility = "string",
        owner_key = "string", access_mode = "string",
    },
    ["Type.Invalid"] = {}, ["Type.Nil"] = {}, ["Type.Void"] = {},
    ["Type.Boolean"] = {}, ["Type.Integer"] = {}, ["Type.Float"] = {},
    ["Type.String"] = {}, ["Type.Value"] = {},
    ["Type.Module"] = {
        name = "string", prefix = "string", file = "string", members = "members",
        type_members = "type_map", _source = "boolean", source_members = "members",
        source_type_members = "type_map",
    },
    ["Type.ModuleMember"] = {
        _c_integer_constant = "string?",
        modname = "string", name = "string", type = "type", paramnames = "names?",
        islocal = "boolean?", _foreign_source = "boolean?",
    },
    ["Type.ModuleVariable"] = {
        modname = "string", name = "string", type = "type", isconst = "boolean",
        islocal = "boolean?",
    },
    ["Type.GenericScope"] = {
        modname = "string", owner_fqtn = "string?", callable_name = "string?",
        role = "string", declaration_kind = "string",
    },
    ["Type.TypeParameter"] = { name = "string", constraint = "type?" },
    ["Type.Parameter"] = {
        scope = "type", index = "integer", diagnostic_name = "string",
        erased_constraint = "type?",
    },
    ["Type.FunctionScheme"] = {
        scope = "type", typeparams = "types", signature = "type", _generic_parameters = "types?",
    },
    ["Type.GenericAlias"] = {
        module = "string", name = "string", locality = "boolean",
        target_owner_fqtn = "string", target_alias_fqtn = "string?",
        target_scope = "type", typeparams = "types",
    },
    ["Type.Function"] = {
        params = "types", rettypes = "types", vararg = "boolean",
        varargtype = "type?", flexrettype = "type?",
    },
    ["Type.Array"] = { elem = "type", isconst = "array_constness" },
    ["Type.Map"] = { keys = "type", values = "type" },
    ["Type.Nominal"] = { fqtn = "string", args = "types" },
    ["Type.Option"] = { base = "type" },
    ["Type.Record"] = {
        name = "string", fields = "members", functions = "type_map", methods = "type_map",
        nfields = "integer", scope = "type?", typeparams = "types", islocal = "boolean?",
        _source_complete = "boolean?", _generic_parameters = "types?",
    },
    ["Type.Union"] = {
        name = "string", variants = "members", functions = "type_map", methods = "type_map",
        nvariants = "integer", scope = "type?", typeparams = "types", islocal = "boolean?",
        _source_complete = "boolean?", _generic_parameters = "types?",
    },
    ["Type.Interface"] = {
        name = "string", fields = "members", methods = "members", scope = "type?",
        typeparams = "types", islocal = "boolean?", _source_complete = "boolean?",
        _generic_parameters = "types?",
    },
    ["Type.Field"] = {
        fqtn = "string", name = "string", type = "type", index = "integer",
        isconst = "boolean", islocal = "boolean?",
    },
    ["Type.Variant"] = {
        fqtn = "string", name = "string", parts = "types", index = "integer", islocal = "boolean?",
    },
    ["Type.Method"] = {
        fqtn = "string", name = "string", params = "types", rettypes = "types",
        varargtype = "type?", flexrettype = "type?", paramnames = "names?",
        scope = "type?", typeparams = "types", islocal = "boolean?",
    },
    ["Type.StaticMethod"] = {
        fqtn = "string", name = "string", params = "types", rettypes = "types",
        varargtype = "type?", flexrettype = "type?", paramnames = "names?",
        scope = "type?", typeparams = "types", islocal = "boolean?",
    },
    -- Keep semantic C declarations, including recursive aggregate fields and
    -- exact extents. Do not retain raw C declarations, macro environments,
    -- converted namespaces, parser annotations or checker plans.
    ["Type.CVoid"] = {},
    ["Type.CInteger"] = {
        spelling = "string", signed = "boolean", rank = "integer?", bits = "integer?",
        _c_enum_identity = "string?", _c_declaration_spelling = "string?",
        _c_enum_enumerator = "string?", _c_enum_probe_spelling = "string?",
        _c_enum_unspellable = "boolean?", _c_enum_owner = "type?",
        _c_completion_int_enum = "boolean?", _c_enum_validated = "boolean?",
        _c_numeric = "numeric?", _c_numeric_carriers = "carriers?",
    },
    ["Type.CFloat"] = { spelling = "string", _c_numeric = "numeric?", _c_numeric_carriers = "carriers?" },
    ["Type.CPointer"] = { pointee = "type", quals = "names" },
    ["Type.CArray"] = { elem = "type", len = "extent?", quals = "names" },
    ["Type.CFunction"] = {
        params = "types", ret = "type", vararg = "boolean", abi = "string?",
        _paramstyle = "string?", _return_declaration_qualifiers = "names?",
    },
    ["Type.CStruct"] = {
        cname = "c_name?", tagname = "c_name?", typedef = "c_name?",
        fields = "members", complete = "boolean", has_fam = "boolean",
        _c_tag_scope = "string?", _definition_order = "integer?",
    },
    ["Type.CUnion"] = {
        cname = "c_name?", tagname = "c_name?", typedef = "c_name?",
        fields = "members", complete = "boolean", _c_tag_scope = "string?", _definition_order = "integer?",
    },
    ["Type.CField"] = {
        owner = "type?", name = "string", type = "type", bitfield = "extent?", flexible_array = "boolean",
    },
    ["Type.CTypedef"] = { name = "c_name", target = "type", quals = "names" },
    ["Type.COwned"] = { pointee = "type", count = "boolean" },
    header = {
        modname = "string", logical_name = "string", identity = "string",
        contents = "string", direct_includes = "names", dependencies = "headers",
        typedef_declarations = "names",
        search_inputs = "inputs", digest = "string",
    },
    include = {
        original = "string?", resolved = "string?", include_kind = "string?",
        include_name = "string?", rendered = "string", generated_header = "header?",
        c_header_dependencies = "inputs?", c_header_search_inputs = "inputs?",
    },
    input = {
        kind = "string", path = "string", identity = "string", restat = "boolean?", observation = "observation?",
    },
    observation = {
        modified_seconds = "integer", modified_nanoseconds = "integer", physical_identity = "string",
    },
    numeric = {
        kind = "string", spelling = "string", signed = "boolean?", rank = "integer", bits = "integer",
        precision = "integer?", minimum = "atom?", maximum = "atom?", unsigned = "string?",
        maximum_exponent = "integer?", maximum_macro = "string?", radix = "integer?", mantissa_digits = "integer?",
    },
    carriers = {
        identity = "string", lua_integer = "numeric", lua_number = "numeric", size_t = "numeric",
        ptrdiff_t = "numeric", long_double = "numeric",
    },
    -- The bounded declaration grammar understood by cdeclarator. It has no
    -- Titan syntax, statements, inline definitions or CPP sidecars.
    extent = {
        op = "string?", unop = "string?", postfix = "extent?", idx = "extent?",
        args = "extent?", dot = "string?", arrow = "string?", type = "extent?",
        id = "extent?", declarator = "extent?", params = "extent?", param = "extent?",
        paramstyle = "string?", name = "string?", array_static = "atom?", array_qualifiers = "names?",
    },
}
for tag, schema in pairs(schemas) do
    if tag:match("^Type%.C") then
        schema._ffi_scope, schema._c_origin_header = "string?", "include?"
    end
end

return schemas
