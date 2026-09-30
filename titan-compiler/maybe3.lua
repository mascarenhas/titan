-- Explicit state for an analysis result that has not necessarily been computed.
-- Payloads may themselves be false; only nil means there is no payload.
local maybe3 = {}

function maybe3.unknown()
    return { tag = "unknown" }
end

function maybe3.none()
    return { tag = "none" }
end

function maybe3.just(value)
    assert(value ~= nil, "Maybe3.just requires a value")
    return { tag = "just", value = value }
end

function maybe3.from_optional(value)
    if value == nil then return maybe3.none() end
    return maybe3.just(value)
end

function maybe3.validate(state)
    if type(state) ~= "table" or getmetatable(state) ~= nil then return false end
    if state.tag ~= "unknown" and state.tag ~= "none" and state.tag ~= "just" then
        return false
    end
    for key in pairs(state) do
        if key ~= "tag" and (key ~= "value" or state.tag ~= "just") then
            return false
        end
    end
    return state.tag ~= "just" or state.value ~= nil
end

function maybe3.get_checked(state, context)
    context = context or "analysis result"
    assert(maybe3.validate(state), context .. " has an invalid Maybe3 state")
    assert(state.tag ~= "unknown", context .. " has not been computed")
    if state.tag == "just" then return state.value end
    return nil
end

return maybe3
