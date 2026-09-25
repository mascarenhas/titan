local core = require "titan-compiler.coder.core"
local _ENV = core

function coder._foreign_record_field_read(ctx, node)
    local field = assert(node._native_record_field)
    local plan = coder._nominal_plan(ctx, field.owner)
    local slot = assert(plan.by_index[field.index])
    local stats, owner = coder._foreign_freeze(
        ctx, node.args.args[1], nil, "record_owner")
    local value
    if slot.storage == "uv" then
        value = "*(" .. coder._nominal_uv(slot, owner) .. ")"
    else
        value = coder._nominal_member(plan, slot, owner)
        if field.borrowed and slot.kind ~= "array" then
            value = "&(" .. value .. ")"
        end
    end
    local declaration, result = coder._foreign_temp(ctx, field.type, "field")
    return table.concat({ stats, declaration, result .. " = " .. value .. ";" }, "\n"), result
end

return core.coder
