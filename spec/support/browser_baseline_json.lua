-- Shared encoding and statistics for the #329 baseline harness.
--
-- The harness publishes medians; keeping the statistic here lets the
-- capability spec exercise it with asymmetric three-sample inputs. The encoder
-- preserves dense-array order: sorted object keys must never reorder CLI
-- arguments or import lists.
local M = {}

-- Median of the finite numbers in `values`; even counts average the two middle
-- samples, and an empty or non-numeric set has no median.
function M.median(values)
    local numbers = {}
    for _, value in ipairs(values) do
        if type(value) == "number" and value == value and
                value ~= math.huge and value ~= -math.huge then
            numbers[#numbers + 1] = value
        end
    end
    if #numbers == 0 then return nil end
    table.sort(numbers)
    local lower = math.floor((#numbers + 1) / 2)
    local upper = math.ceil((#numbers + 1) / 2)
    return (numbers[lower] + numbers[upper]) / 2
end

local function is_dense_array(value)
    local count = #value
    if count == 0 then return false end
    for key in pairs(value) do
        if math.type(key) ~= "integer" or key < 1 or key > count then
            return false
        end
    end
    return true
end

local function quote(text)
    local escaped = tostring(text):gsub('[%z\1-\31\\"]', function(char)
        if char == '"' then return '\\"' end
        if char == "\\" then return "\\\\" end
        if char == "\n" then return "\\n" end
        if char == "\r" then return "\\r" end
        if char == "\t" then return "\\t" end
        return string.format("\\u%04x", char:byte())
    end)
    return '"' .. escaped .. '"'
end

function M.encode(value, indent)
    local kind = type(value)
    indent = indent or ""
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"
        end
        return string.format("%.9g", value)
    elseif kind == "string" then
        return quote(value)
    elseif kind == "boolean" then
        return tostring(value)
    elseif kind == "table" then
        local inner = indent .. "  "
        local parts = {}
        if is_dense_array(value) then
            -- Numeric sequence, never lexicographic: 2 must follow 1, not 10.
            for index = 1, #value do
                parts[#parts + 1] = inner .. M.encode(value[index], inner)
            end
            return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
        end
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        if #keys == 0 then return "{}" end
        table.sort(keys, function(left, right)
            return tostring(left) < tostring(right)
        end)
        for _, key in ipairs(keys) do
            parts[#parts + 1] = inner .. quote(tostring(key)) .. ": " ..
                M.encode(value[key], inner)
        end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    end
    return "null"
end

return M
