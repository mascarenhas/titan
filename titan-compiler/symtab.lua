local symtab = {}

symtab.__index = symtab

function symtab.new(modname)
    local self = {
        blocks = { {} },
        type_aliases = {},
        foreign_types = {},
        foreign_type_history = {},
        foreign_names = {},
        foreign_name_history = {},
        foreign_macro_definitions = nil,
        foreign_field_macro_cache = {},
        c_file_tags = {},
        c_prototype_tags = {},
        modname = modname
    }
    return setmetatable(self, symtab)
end

function symtab:open_block()
    table.insert(self.blocks, {})
end

function symtab:close_block()
    table.remove(self.blocks)
end

function symtab:with_block(body, ...)
    self:open_block()
    local res = body(...)
    self:close_block()
    return res
end

function symtab:add_symbol(name, decl)
    assert(#self.blocks > 0, "no blocks")
    local block = self.blocks
    block[#block][name] = decl
end

function symtab:find_symbol(name)
    local decl
    for i = #self.blocks, 1, -1 do
        decl = self.blocks[i][name]
        if decl and not self:hidden_from_initializer(decl) then
            break
        elseif decl then
            decl = nil
        end
    end
    return decl
end

-- Imports and module variables are the two sequential parts of top-level
-- checking. Declaration-signature passes publish every other top-level name
-- before module-variable initializers are checked, but an initializer must not
-- see an import written after it or itself/a later module variable.
function symtab:hidden_from_initializer(decl)
    local frontier = self.initializer_order
    if not frontier or type(decl) ~= "table" then return false end
    local order = decl._toplevel_order
    if not order then return false end
    if decl._tag == "Ast.TopLevelVar" then
        return order >= frontier
    end
    if decl._tag == "Ast.TopLevelImport" or
       decl._tag == "Ast.TopLevelForeignImport" then
        return order > frontier
    end
    return false
end

-- Titan type aliases live in a distinct, module-wide type namespace. They are
-- intentionally absent from `blocks`: an alias is not a run-time value and
-- must never resolve through VarName/VarDot or reach code generation.
function symtab:add_type_alias(name, decl)
    self.type_aliases[name] = decl
end

function symtab:find_type_alias(name)
    return self.type_aliases[name]
end

function symtab:add_foreign_type(name, decl)
    self.foreign_types[name] = decl
    local history = self.foreign_type_history[name]
    if not history then
        history = {}
        self.foreign_type_history[name] = history
    end
    history[#history + 1] = {
        order = self.current_toplevel_order or 0,
        decl = decl,
    }
end

function symtab:find_foreign_type(name)
    local frontier = self.initializer_order
    if frontier then
        local history = self.foreign_type_history[name] or {}
        for i = #history, 1, -1 do
            if history[i].order <= frontier then
                return history[i].decl
            end
        end
        return nil
    end
    return self.foreign_types[name]
end

function symtab:add_foreign_name(name, decl)
    self.foreign_names[name] = decl
    local history = self.foreign_name_history[name]
    if not history then
        history = {}
        self.foreign_name_history[name] = history
    end
    history[#history + 1] = {
        order = self.current_toplevel_order or 0,
        decl = decl,
    }
end

function symtab:find_foreign_name(name)
    local frontier = self.initializer_order
    if frontier then
        local history = self.foreign_name_history[name] or {}
        for i = #history, 1, -1 do
            if history[i].order <= frontier then
                return history[i].decl
            end
        end
        return nil
    end
    return self.foreign_names[name]
end

-- Generated C hoists every foreign include before declarations and function
-- bodies. Reconstruct that final raw macro environment by seeding it from the
-- first independently parsed header, then applying only the names actively
-- defined/redefined/undefined by each later header closure. Field projection
-- classification is lazy in the checker so a later change to a transitive
-- replacement dependency is reflected when the public field token is used.
function symtab:apply_foreign_macro_changes(changes, definitions)
    if not self.foreign_macro_definitions then
        self.foreign_macro_definitions = {}
        for name, definition in pairs(definitions or {}) do
            self.foreign_macro_definitions[name] = definition
        end
    else
        for name in pairs(changes or {}) do
            self.foreign_macro_definitions[name] =
                definitions and definitions[name] or nil
        end
    end
    self.foreign_field_macro_cache = {}
end

function symtab:find_foreign_macro_definition(name)
    if not self.foreign_macro_definitions then return nil, false end
    return self.foreign_macro_definitions[name], true
end

function symtab:foreign_macro_environment()
    return self.foreign_macro_definitions
end

function symtab:find_cached_foreign_field_macro(name)
    local cached = self.foreign_field_macro_cache[name]
    if cached == nil then return nil, false end
    return cached ~= false and cached or nil, true
end

function symtab:cache_foreign_field_macro(name, projection)
    self.foreign_field_macro_cache[name] = projection or false
end

local function c_tag_provenance(provenance)
    provenance = provenance or {}
    return {
        header = provenance.header or "<unknown>",
        declaration_order = provenance.declaration_order,
        scope = provenance.scope or "file",
        definition = provenance.definition and true or false,
    }
end

local function describe_c_tag_provenance(provenance)
    provenance = c_tag_provenance(provenance)
    local order = provenance.declaration_order
        and tostring(provenance.declaration_order) or "<unknown>"
    return ("header '%s', declaration %s, scope %s")
        :format(provenance.header, order, provenance.scope)
end

local function c_tag_conflict(name, previous, kind, provenance)
    return ("conflicting C tag kinds for '%s' across foreign imports: "
        .. "%s from %s conflicts with %s from %s")
        :format(name, previous.kind,
            describe_c_tag_provenance(previous.provenance),
            kind, describe_c_tag_provenance(provenance))
end

-- File-scope C tags use one module-wide namespace shared by struct, union, and
-- enum. Same-kind declarations append provenance and reuse the same record;
-- only struct/union records normally acquire a canonical Titan aggregate.
function symtab:register_c_file_tag(name, kind, provenance, canonical)
    if type(name) ~= "string" or name == "" then
        return nil, "a file-scope C tag requires a name"
    end
    if kind ~= "struct" and kind ~= "union" and kind ~= "enum" then
        return nil, "invalid C tag kind '" .. tostring(kind) .. "'"
    end

    provenance = c_tag_provenance(provenance)
    local previous = self.c_file_tags[name]
    if previous and previous.kind ~= kind then
        return nil, c_tag_conflict(name, previous, kind, provenance)
    end

    local record = previous
    if not record then
        record = {
            name = name,
            kind = kind,
            scope = "file",
            header = provenance.header,
            provenance = provenance,
            provenances = {},
            order = self.current_toplevel_order or 0,
        }
        self.c_file_tags[name] = record
    end
    record.provenances[#record.provenances + 1] = provenance
    if canonical and not record.canonical then
        record.canonical = canonical
    end
    return record
end

-- Enum tags have no source alias in the current feature, but registering their
-- metadata here is necessary to enforce C's shared tag namespace.
function symtab:register_c_enum_tag(name, provenance, canonical)
    return self:register_c_file_tag(name, "enum", provenance, canonical)
end

-- Retrieval is frontier-aware for future checker tag aliases. During ordered
-- import conversion initializer_order is unset, so prototype references see
-- precisely the file tags registered by prior/current imports.
function symtab:find_c_file_tag(name, kind)
    local record = self.c_file_tags[name]
    if not record or (kind and record.kind ~= kind) then
        return nil
    end
    local frontier = self.initializer_order
    if frontier and record.order > frontier then
        return nil
    end
    return record
end

-- Prototype tag scope numbers are only stable within one parsed header.
-- Nesting maps by header, then scope, then base name prevents equal numeric
-- scope ids in separate headers from accidentally sharing identity.
function symtab:bind_c_prototype_tag(name, kind, scope_id, provenance,
                                     allow_outer, canonical)
    if type(name) ~= "string" or name == "" then
        return nil, "a prototype-scope C tag requires a name"
    end
    if kind ~= "struct" and kind ~= "union" and kind ~= "enum" then
        return nil, "invalid C tag kind '" .. tostring(kind) .. "'"
    end
    if scope_id == nil then
        return nil, "a prototype-scope C tag requires a stable scope id"
    end

    provenance = c_tag_provenance(provenance)
    if provenance.header == "<unknown>" then
        return nil, "a prototype-scope C tag requires header provenance"
    end

    if allow_outer then
        local outer = self:find_c_file_tag(name)
        if outer then
            if outer.kind ~= kind then
                return nil, c_tag_conflict(
                    name, outer, kind, provenance)
            end
            return outer
        end
    end

    local header_scopes = self.c_prototype_tags[provenance.header]
    if not header_scopes then
        header_scopes = {}
        self.c_prototype_tags[provenance.header] = header_scopes
    end
    local scope = header_scopes[scope_id]
    if not scope then
        scope = {}
        header_scopes[scope_id] = scope
    end

    local previous = scope[name]
    if previous and previous.kind ~= kind then
        return nil, ("conflicting C tag kinds for '%s' in prototype scope %s: "
            .. "%s from %s conflicts with %s from %s")
            :format(name, tostring(scope_id), previous.kind,
                describe_c_tag_provenance(previous.provenance),
                kind, describe_c_tag_provenance(provenance))
    end

    local record = previous
    if not record then
        record = {
            name = name,
            kind = kind,
            scope = "prototype",
            scope_id = scope_id,
            header = provenance.header,
            provenance = provenance,
            provenances = {},
        }
        scope[name] = record
    end
    record.provenances[#record.provenances + 1] = provenance
    if canonical and not record.canonical then
        record.canonical = canonical
    end
    return record
end

function symtab:set_c_tag_canonical(record, canonical)
    if not record then
        return nil, "missing C tag record"
    end
    if record.canonical then
        return record.canonical
    end
    record.canonical = canonical
    return canonical
end

-- C struct/union objects are canonical and may be completed in place by a
-- later foreign import. Outside a module-variable declaration the complete
-- translation-unit view is correct; at an initializer frontier, expose that
-- definition only if its defining import has already occurred.
function symtab:foreign_definition_visible(decl)
    if not decl.complete then return false end
    local frontier = self.initializer_order
    local order = decl._definition_order
    return not frontier or not order or order <= frontier
end

function symtab:dump()
  for i, block in ipairs(self.blocks) do
    print("BLOCK " .. i .. ":")
    for name, decl in pairs(block) do
      print(name, decl)
    end
  end
end

function symtab:find_dup(name)
    return self.blocks[#self.blocks][name]
end

return symtab
