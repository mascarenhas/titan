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
