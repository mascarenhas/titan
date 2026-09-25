local core = require "titan-compiler.coder.core"
local _ENV = core

-- Foreign numerics can exceed Lua's integer range or floating precision.
-- Their exact Option carrier must therefore remain native through locals,
-- arguments, returns, and nominal slots. Boxing is an explicit boundary.
local spellings = {
    "_Bool", "char", "signed char", "unsigned char", "short",
    "unsigned short", "int", "unsigned int", "long", "unsigned long",
    "long long", "unsigned long long", "float", "double", "long double",
}
local names = {}
for i, spelling in ipairs(spellings) do
    names[spelling] = "titan_native_option_" .. tostring(i)
end

function coder._is_native_option(typ)
    if typ._tag ~= "Type.Option" then return false end
    local base = types.resolve_c_typedef(typ.base)
    return base._tag == "Type.CInteger" or base._tag == "Type.CFloat"
end

function coder._native_option_ctype(typ)
    assert(coder._is_native_option(typ), "expected native numeric Option")
    local base = types.resolve_c_typedef(typ.base)
    return (assert(names[base.spelling], "unsupported native Option scalar"))
end

function coder._native_option_declarations()
    local result = { "#ifndef TITAN_NATIVE_NUMERIC_OPTIONS",
        "#define TITAN_NATIVE_NUMERIC_OPTIONS" }
    for _, spelling in ipairs(spellings) do
        local name = names[spelling]
        result[#result + 1] = "typedef struct " .. name
            .. " { int present; " .. spelling .. " value; } " .. name .. ";"
        result[#result + 1] = "typedef struct { lu_byte n_args; "
            .. name .. " *args; } " .. name .. "_varg;"
    end
    result[#result + 1] = "#endif"
    return table.concat(result, "\n")
end

function coder._option_present(typ, source)
    if coder._is_native_option(typ) then
        return "(" .. source .. ").present"
    end
    return "!ttisnil(&(" .. source .. "))"
end

function coder._option_nil(typ, destination)
    if coder._is_native_option(typ) then
        return destination .. " = (" .. coder._native_option_ctype(typ)
            .. "){0};"
    end
    return "setnilvalue(&(" .. destination .. "));"
end

function coder._option_wrap(typ, destination, source)
    if coder._is_native_option(typ) then
        return destination .. " = (" .. coder._native_option_ctype(typ)
            .. "){1, " .. source .. "};"
    end
    return setslot(typ.base, "&(" .. destination .. ")", source)
end

function coder._option_get(typ, destination, source)
    if coder._is_native_option(typ) then
        return (destination and destination .. " = " or "")
            .. "(" .. source .. ").value"
    end
    return getslot(typ.base, destination, "&(" .. source .. ")")
end

-- Flexible result adjustment flattens an already optional element. It can
-- also produce `value`, whose nil-capable representation remains boxed.
function coder._optional_result_store(typ, element, destination, source)
    if coder._is_native_option(typ) then
        if coder._is_native_option(element) then
            return destination .. " = " .. source .. ";"
        end
        return coder._option_wrap(typ, destination, source)
    end
    return setslot(element, "&(" .. destination .. ")", source)
end

function coder._native_option_box(typ, destination, source)
    return render([[
        do {
            $TYPE _titan_option = $SOURCE;
            TValue _titan_option_boxed = {{0}, 0};
            if (_titan_option.present) {
                $BOX
            } else {
                setnilvalue(&_titan_option_boxed);
            }
            setobj2t(L, $DESTINATION, &_titan_option_boxed);
        } while (0);
    ]], {
        TYPE = coder._native_option_ctype(typ),
        SOURCE = source,
        DESTINATION = destination,
        BOX = setslot(typ.base, "&_titan_option_boxed", "_titan_option.value"),
    })
end

function coder._native_option_from_slot(typ, source)
    return "(" .. coder._native_option_ctype(typ)
        .. "){ !ttisnil(" .. source .. "), ttisnil(" .. source .. ") ? 0 : ("
        .. getslot(typ.base, nil, source) .. ") }"
end

return coder
