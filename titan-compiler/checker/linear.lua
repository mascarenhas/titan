local core = require "titan-compiler.checker.core"
local _ENV = core

-- A mutable Array may be frozen in place only when the checker can prove that
-- the cast consumes the allocation's last mutable reference. Copying remains
-- the semantic default. The proof follows one fresh local through an ordinary
-- builder phase:
--
--     local a = { ... }
--     while more() do
--         a[#a + 1] = next_element()
--     end
--     return a as const { T }
--
-- Before the terminal cast, only length and indexed access may name the Array;
-- arbitrary control flow, calls, and unrelated closures are fine when they do
-- not receive or actually reference/capture it. Thus element-producing calls
-- in a loop remain eligible, while passing,
-- storing, aliasing, returning, rebinding, capturing, or otherwise exposing the
-- Array does not. A complete scan after the cast proves the mutable binding is
-- dead. Any use that this deliberately narrow classifier does not recognize
-- conservatively keeps the shallow-copy lowering.

local function syntax_children(node, visit, seen)
    if type(node) ~= "table" then return end
    if not node._tag then
        for _, item in ipairs(node) do
            if type(item) == "table" then visit(item, seen) end
        end
        return
    end
    for key, child in pairs(node) do
        if type(key) == "string"
           and key:sub(1, 1) ~= "_"
           and key ~= "loc"
           and key ~= "type"
           and key ~= "target"
           and key ~= "rettypes"
           and key ~= "typeparams"
           and type(child) == "table" then
            if child._tag then
                visit(child, seen)
            else
                for _, item in ipairs(child) do
                    if type(item) == "table" then visit(item, seen) end
                end
            end
        end
    end
end

local function count_decl_uses(root, decl)
    local count = 0
    local function visit(node, seen)
        if type(node) ~= "table" or seen[node] then return end
        if node._tag == "Ast.VarName" and node._decl == decl then
            count = count + 1
        end
        syntax_children(node, visit, seen)
    end
    visit(root, {})
    return count
end

local function builder_uses_are_non_escaping(root, decl, ret_stat)
    local function visit(node, context, seen)
        if type(node) ~= "table" or seen[node] then return true end
        seen[node] = true
        if ret_stat and node == ret_stat then
            return true
        end

        if node._tag == "Ast.VarName" and node._decl == decl then
            return context == "array_base" or context == "length_operand"
        elseif node._tag == "Ast.ExpVar"
           and node.var and node.var._tag == "Ast.VarName"
           and node.var._decl == decl then
            return context == "array_base" or context == "length_operand"
        elseif node._tag == "Ast.VarBracket" then
            return visit(node.exp1, "array_base", seen)
               and visit(node.exp2, "ordinary", seen)
        elseif node._tag == "Ast.ExpUnop" and node.op == "#" then
            return visit(node.exp, "length_operand", seen)
        elseif (node._tag == "Ast.ExpAdjust"
                or (node._tag == "Ast.ExpCast" and node._implicit_coercion))
           and (context == "array_base" or context == "length_operand") then
            return visit(node.exp, context, seen)
        end

        if not node._tag then
            for _, item in ipairs(node) do
                if not visit(item, "ordinary", seen) then return false end
            end
            return true
        end
        for key, child in pairs(node) do
            if type(key) == "string"
               and key:sub(1, 1) ~= "_"
               and key ~= "loc"
               and key ~= "type"
               and key ~= "target"
               and key ~= "rettypes"
               and key ~= "typeparams"
               and type(child) == "table" then
                if child._tag then
                    if not visit(child, "ordinary", seen) then return false end
                else
                    for _, item in ipairs(child) do
                        if type(item) == "table"
                           and not visit(item, "ordinary", seen) then
                            return false
                        end
                    end
                end
            end
        end
        return true
    end
    return visit(root, "ordinary", {})
end

local function is_fresh_mutable_array_exp(exp)
    while exp and exp._tag == "Ast.ExpAdjust" do exp = exp.exp end
    while exp and exp._tag == "Ast.ExpCast" and exp._implicit_coercion do
        exp = exp.exp
    end
    if not exp or not exp._type or exp._type._tag ~= "Type.Array"
       or exp._type.isconst ~= false then
        return false
    end
    if exp._tag == "Ast.ExpInitList" then
        return true
    elseif exp._type.linear == true then
        return true
    end
    return false
end

local function fresh_mutable_array_declaration(stat)
    if stat._tag ~= "Ast.StatDecl"
       or #stat.decls ~= 1
       or #stat.exps ~= 1 then
        return nil
    end
    local decl = stat.decls[1]
    local typ = decl._type
    if not typ or typ._tag ~= "Type.Array" or typ.isconst ~= false
       or decl._captured then
        return nil
    end
    if not is_fresh_mutable_array_exp(stat.exps[1]) then
        return nil
    end
    return decl
end

local function sole_consuming_cast(stat, decl)
    if (stat._tag ~= "Ast.StatDecl" and stat._tag ~= "Ast.StatReturn")
       or #stat.exps ~= 1 then
        return nil
    end
    local cast = stat.exps[1]
    if cast._tag ~= "Ast.ExpCast"
       or not cast._written_cast
       or cast._written_cast.op ~= "array_freeze"
       or cast._written_cast.mode ~= "copy" then
        return nil
    end
    local source = cast.exp
    if not source or source._tag ~= "Ast.ExpVar"
       or not source.var or source.var._tag ~= "Ast.VarName"
       or source.var._decl ~= decl
       or count_decl_uses(stat, decl) ~= 1 then
        return nil
    end
    return cast
end

local function select_block_linear_array_freezes(block)
    local stats = block.stats or {}
    for index = 1, #stats - 1 do
        local decl = fresh_mutable_array_declaration(stats[index])
        if decl then
            for terminal = index + 1, #stats do
                local cast = sole_consuming_cast(stats[terminal], decl)
                if cast then
                    local later_use = false
                    for later = terminal + 1, #stats do
                        if count_decl_uses(stats[later], decl) ~= 0 then
                            later_use = true
                            break
                        end
                    end
                    if not later_use then
                        cast._written_cast.mode = "freeze"
                        cast._linear_array_freeze = true
                    end
                    break
                elseif count_decl_uses(stats[terminal], decl) ~= 0
                   and not builder_uses_are_non_escaping(
                        stats[terminal], decl) then
                    -- This statement may have published or rebound the Array;
                    -- no later cast can prove unique mutable ownership.
                    break
                end
            end
        end
    end
end

local function is_linear_returned_value(block, ret_stat, exp)
    while exp and exp._tag == "Ast.ExpAdjust" do exp = exp.exp end
    while exp and exp._tag == "Ast.ExpCast" and exp._implicit_coercion do
        exp = exp.exp
    end
    if not exp or not exp._type or exp._type._tag ~= "Type.Array"
       or exp._type.isconst ~= false then
        return false
    end

    if exp._tag == "Ast.ExpInitList" then
        return true
    end

    if exp._type.linear == true then
        return true
    end

    if exp._tag == "Ast.ExpVar"
       and exp.var and exp.var._tag == "Ast.VarName"
       and exp.var._decl then
        local decl = exp.var._decl
        if decl._tag == "Ast.Decl" and not decl._captured and decl._init_exp then
            if is_fresh_mutable_array_exp(decl._init_exp) then
                if builder_uses_are_non_escaping(block, decl, ret_stat) then
                    if count_decl_uses(ret_stat, decl) == 1 then
                        return true
                    end
                end
            end
        end
    end

    return false
end

function annotate_linear_function_returns(node)
    if not node.rettypes or #node.rettypes == 0
       or not node._signature or not node._signature.rettypes
       or #node._signature.rettypes == 0 then
        return
    end

    local returns = {}
    local function find_returns(n, seen)
        if type(n) ~= "table" or seen[n] then return end
        seen[n] = true
        if n._tag == "Ast.ExpFunction" then
            return
        end
        if n._tag == "Ast.StatReturn" then
            table.insert(returns, n)
        end
        syntax_children(n, find_returns, seen)
    end
    find_returns(node.block, {})

    if #returns == 0 then
        return
    end

    for ret_idx = 1, #node._signature.rettypes do
        local rettype = node._signature.rettypes[ret_idx]
        if rettype._tag == "Type.Array" and rettype.isconst == false then
            local all_linear = true
            for _, ret_stat in ipairs(returns) do
                local exp = ret_stat.exps and ret_stat.exps[ret_idx]
                if not exp or not is_linear_returned_value(node.block, ret_stat, exp) then
                    all_linear = false
                    break
                end
            end
            if all_linear then
                local linear_array = types.Array(rettype.elem, false)
                linear_array.linear = true
                node._signature.rettypes[ret_idx] = linear_array
                if node._type and node._type._tag == "Type.FunctionScheme"
                   and node._type.signature and node._type.signature.rettypes then
                    node._type.signature.rettypes[ret_idx] = linear_array
                elseif node._type and node._type._tag == "Type.Function"
                   and node._type.rettypes then
                    node._type.rettypes[ret_idx] = linear_array
                end
            end
        end
    end
end

function select_linear_array_freezes(root)
    local function visit(node, seen)
        if type(node) ~= "table" or seen[node] then return end
        if node._tag == "Ast.StatBlock" then
            select_block_linear_array_freezes(node)
        end
        syntax_children(node, visit, seen)
    end
    visit(root, {})
end

return core.select_linear_array_freezes
