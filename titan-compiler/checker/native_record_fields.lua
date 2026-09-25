-- Private compiler/runtime boundary for native callbacks in modules that
-- explicitly import titan/ffi.h. This is a compile-time field selection, not
-- reflection, conversion, or a new root for the supplied userdata owner.
local core = require "titan-compiler.checker.core"
local _ENV = core
local layout = require "titan-compiler.nominallayout"

local function result_type(slot, st)
    if slot.storage == "uv" then
        return assert(st:find_foreign_type("TValue")), false
    elseif slot.kind == "option" then
        return nil, "private record-field intrinsic cannot read optional native storage"
    elseif slot.kind == "aggregate" or slot.kind == "array" then
        return checker._nominal_storage_plan(slot.type).projection_type, true
    end
    local tag = slot.type._tag
    if tag == "Type.Integer" then
        return assert(st:find_foreign_type("lua_Integer")), false
    elseif tag == "Type.Float" then
        return assert(st:find_foreign_type("lua_Number")), false
    elseif tag == "Type.Boolean" or tag == "Type.Nil" then
        local profile = assert(ensure_c_profile(st))
        return profile.integers[profile.int].type, false
    end
    return slot.type, false
end

function checker._native_record_field_call(node, st, errors, demand)
    local exp = node.exp
    local var = exp and exp._tag == "Ast.ExpVar" and exp.var
    local base = var and var._tag == "Ast.VarDot" and var.exp
    local name = base and base._tag == "Ast.ExpVar" and base.var
    if not name or name._tag ~= "Ast.VarName" or name.name ~= "ffi"
       or var.name ~= "titan_record_field"
       or st:find_symbol("ffi") ~= st.ffi_namespace then
        return false
    end
    local function reject(message, ...)
        node._type = invalid(errors, node.loc, message, ...)
        return true
    end
    if not st._native_record_fields_enabled then
        return reject("private record-field intrinsic requires a direct foreign import of 'titan/ffi.h'")
    elseif checker._foreign_function_depth == 0 then
        return reject("private record-field intrinsic is only available inside a foreign function")
    elseif node.args._tag ~= "Ast.ArgsFunc" or #node.args.args ~= 3 then
        return reject("private record-field intrinsic requires an owner and literal record and field names")
    end
    local args = node.args.args
    for _, arg in ipairs(args) do checkexp(arg, st, errors) end
    if args[2]._tag ~= "Ast.ExpString" or args[3]._tag ~= "Ast.ExpString" then
        return reject("private record-field intrinsic requires literal record and field names")
    elseif not types.is_c_udata_pointer(args[1]._type) then
        return reject("private record-field intrinsic owner must have foreign type '*Udata'")
    end
    local declaration = st:find_symbol(args[2].value)
    local owner = declaration and declaration._tag == "Ast.TopLevelRecord"
        and declaration._type
    if not owner or owner.name ~= st.modname .. "." .. args[2].value then
        return reject("private record-field intrinsic requires a record declared in this module: '%s'", args[2].value)
    end
    local plan, err = layout.record(owner)
    if not plan then return reject("%s", err) end
    local slot = plan.by_name[args[3].value]
    if not slot then
        return reject("record '%s' has no field '%s'", args[2].value, args[3].value)
    end
    local typ, borrowed = result_type(slot, st)
    if not typ then return reject("%s", borrowed) end
    node._native_record_field = {
        owner = owner, index = slot.index, borrowed = borrowed, type = typ,
    }
    local function_node = st:find_symbol("$function")
    assert(function_node and function_node._tag == "Ast.TopLevelForeignFunc")
    function_node._native_record_fields = true
    local signature = types.CFunction({ args[1]._type }, typ, false, false)
    name._decl, name._type = st.ffi_namespace, st.ffi_namespace._type
    base._type = name._type
    var._decl = { _tag = "Checker.NativeRecordField", _type = signature }
    var._type, exp._type = signature, signature
    annotate_call_results(node, signature, demand, errors)
    return true
end

return core.checker
