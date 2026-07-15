local symtab = {}

symtab.__index = symtab

function symtab.new(modname)
    local self = {
        blocks = { {} },
        type_aliases = {},
        foreign_types = {},
        foreign_names = {},
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
        if decl then
            break
        end
    end
    return decl
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
end

function symtab:find_foreign_type(name)
    return self.foreign_types[name]
end

function symtab:add_foreign_name(name, decl)
    self.foreign_names[name] = decl
end

function symtab:find_foreign_name(name)
    return self.foreign_names[name]
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
