local h = require "spec.support.helpers"
local types = require "titan-compiler.types"

local probe_session
local module_name = "native_record_fields"
local preamble = [[
    foreign import "titan/ffi.h"
    local record Owner
        local count: integer
        local hidden: string
        label: string
        local state: foreign *lua_State
        local flag: boolean
        local precise: foreign long double
    end
]]

local function declaration(ast, name)
    for _, node in ipairs(ast) do
        if node.name == name then return node end
    end
    error("missing declaration " .. name)
end

local function return_expression(node)
    local exp = node.block.stats[1].exps[1]
    while exp._tag == "Ast.ExpCast" do exp = exp.exp end
    return exp
end

local function check(body, prefix)
    return h.run_checker((prefix or preamble) .. body, probe_session)
end

local function rejected(body, message, prefix)
    local ok, err = check(body, prefix)
    assert.falsy(ok)
    assert.truthy(err:find(message, 1, true), err)
end

describe("trusted native record-field intrinsic", function()
    setup(function() probe_session = h.new_checker_probe_session() end)
    teardown(function() h.close_checker_probe_session(probe_session) end)
    after_each(function()
        for _, suffix in ipairs({ ".c", ".o", ".so", ".a", ".titan.h", ".ffi.h" }) do
            os.remove(module_name .. suffix)
        end
        os.execute("rm -rf " .. module_name .. ".so.dSYM")
    end)

    it("selects logical field identity with exact native and traced result types", function()
        local ok, err, ast = check([[
            foreign function count(owner: *Udata): lua_Integer
                return ffi.titan_record_field(owner, "Owner", "count")
            end
            foreign function hidden(owner: *Udata): TValue
                return ffi.titan_record_field(owner, "Owner", "hidden")
            end
            foreign function state(owner: *Udata): *lua_State
                return ffi.titan_record_field(owner, "Owner", "state")
            end
            foreign function flag(owner: *Udata): int
                return ffi.titan_record_field(owner, "Owner", "flag")
            end
            foreign function precise(owner: *Udata): long double
                return ffi.titan_record_field(owner, "Owner", "precise")
            end
        ]])
        assert.truthy(ok, err)
        for index, name in ipairs({ "count", "hidden", "state", "flag", "precise" }) do
            local node = declaration(ast, name)
            assert.is_true(node._native_record_fields)
            local read = return_expression(node)._native_record_field
            assert.equal(({ 0, 1, 3, 4, 5 })[index], read.index)
            assert.equal("test.Owner", read.owner.name)
            assert.is_false(read.borrowed)
        end
        assert.is_true(types.is_c_tvalue(return_expression(declaration(ast, "hidden"))._type))
        assert.equal("long double", types.resolve_c_typedef(
            return_expression(declaration(ast, "precise"))._type).spelling)
    end)

    it("restricts access to current-module records and literal names in native callbacks", function()
        rejected([[
            foreign function bad(owner: *Udata): lua_Integer
                return ffi.titan_record_field(owner, "Owner", "count")
            end
        ]], "requires a direct foreign import", 'foreign import "lobject.h"\n')
        rejected([[
            function bad(owner: foreign *Udata): foreign lua_Integer
                return ffi.titan_record_field(owner, "Owner", "count")
            end
        ]], "only available inside a foreign function")
        rejected([[
            foreign function bad(owner: *void): lua_Integer
                return ffi.titan_record_field(owner, "Owner", "count")
            end
        ]], "owner must have foreign type '*Udata'")
        rejected([[
            foreign function bad(owner: *Udata, name: const *char): lua_Integer
                return ffi.titan_record_field(owner, name, "count")
            end
        ]], "requires literal record and field names")
        rejected([[
            foreign function bad(owner: *Udata): lua_Integer
                return ffi.titan_record_field(owner, "Elsewhere.Owner", "count")
            end
        ]], "record declared in this module")
        rejected([[
            foreign function bad(owner: *Udata): lua_Integer
                return ffi.titan_record_field(owner, "Owner", "missing")
            end
        ]], "has no field 'missing'")
        rejected([[
            foreign function bad(owner: *Udata): lua_Integer
                local callback = ffi.titan_record_field
                return 0
            end
        ]], "titan_record_field")
    end)

    it("rejects native option reads without inventing a nullable C return", function()
        rejected([[
            local record Optional
                local count: integer?
            end
            foreign function bad(owner: *Udata): lua_Integer
                return ffi.titan_record_field(owner, "Optional", "count")
            end
        ]], "cannot read optional native storage")
    end)

    it("borrows embedded aggregate and array storage without copying their owner", function()
        local header = os.tmpname() .. ".h"
        local file = assert(io.open(header, "wb"))
        file:write([[
            typedef struct native_field_point { int x; } native_field_point;
            typedef int native_field_row[3];
        ]])
        file:close()
        local checked = table.pack(pcall(function()
            local ok, err, ast = check([[
                local record Embedded
                    local point: foreign native_field_point
                    local row: foreign native_field_row
                end
                foreign function point(owner: *Udata): *native_field_point
                    return ffi.titan_record_field(owner, "Embedded", "point")
                end
                foreign function row(owner: *Udata): *int
                    return ffi.titan_record_field(owner, "Embedded", "row")
                end
            ]], preamble .. 'foreign import "' .. header .. '"\n')
            assert.truthy(ok, err)
            local point = return_expression(declaration(ast, "point"))
            local row = return_expression(declaration(ast, "row"))
            assert.is_true(point._native_record_field.borrowed)
            assert.is_true(row._native_record_field.borrowed)
            assert.equal("Type.CStruct", types.resolve_c_typedef(point._type.pointee)._tag)
            assert.equal("int", row._type.pointee.spelling)
        end))
        os.remove(header)
        assert.truthy(checked[1], checked[2])
    end)

    it("emits producer-only callbacks with dense UV and native payload reads", function()
        local csrc, ast = h.compile_and_read_c(preamble .. [[
            foreign function read_count(owner: *Udata): lua_Integer
                return ffi.titan_record_field(owner, "Owner", "count")
            end
            foreign function read_hidden(owner: *Udata): TValue
                return ffi.titan_record_field(owner, "Owner", "hidden")
            end
            foreign function read_label(owner: *Udata): TValue
                return ffi.titan_record_field(owner, "Owner", "label")
            end
        ]], module_name)
        local file = assert(io.open(module_name .. ".titan.h", "rb"))
        local header = assert(file:read("*a"))
        file:close()
        assert.falsy(header:find("getudatamem", 1, true))
        assert.falsy(header:find("_nominal_", 1, true))
        assert.falsy(header:find("static inline", 1, true))
        assert.truthy(csrc:find("->f0", 1, true))
        assert.truthy(csrc:find("->uv[1].uv", 1, true))
        assert.truthy(csrc:find("->uv[0].uv", 1, true))
        assert.falsy(csrc:find("titan_record_field(", 1, true))
        assert.is_false(declaration(ast, "read_count")._foreign_inline)
    end)

    it("reads live fields with one owner evaluation and borrows native objects", function()
        local header = os.tmpname() .. ".h"
        local file = assert(io.open(header, "wb"))
        file:write([[
            #include "titan/ffi.h"
            typedef struct native_field_point { int x; } native_field_point;
            typedef int native_field_row[3];
            static native_field_row native_field_values = { 10, 20, 30 };
            static int native_field_calls;
            static Udata *native_field_owner(Udata *owner) {
                native_field_calls++; return owner;
            }
            static int native_field_call_count(void) { return native_field_calls; }
            static int native_field_short_length(TValue value) {
                return ttisshrstring(&value) ? tsvalue(&value)->shrlen : -1000;
            }
        ]])
        file:close()
        local checked = table.pack(pcall(function()
            h.compile_and_read_c(preamble .. 'foreign import "' .. header .. '"\n' .. [[
                local record Embedded
                    local point: foreign native_field_point
                    local row: foreign native_field_row
                end
                foreign function read_count(owner: *Udata): lua_Integer
                    return ffi.titan_record_field(ffi.native_field_owner(owner), "Owner", "count")
                end
                foreign function read_label(owner: *Udata): TValue
                    return ffi.titan_record_field(owner, "Owner", "label")
                end
                foreign function mutate(owner: *Udata)
                    local point = ffi.titan_record_field(owner, "Embedded", "point")
                    local row = ffi.titan_record_field(owner, "Embedded", "row")
                    point.x = 40
                    row[1] = 50
                    ffi.titan_record_field(owner, "Embedded", "point")
                end
                function exercise(): integer
                    local owner = Owner.new(23, "hidden", "label", nil, true, 1.5)
                    local raw = ffi.lmacro_uvalue(owner as foreign TValue)
                    local point = foreign native_field_point.new()
                    local embedded = Embedded.new(point, ffi.native_field_values)
                    mutate(ffi.lmacro_uvalue(embedded as foreign TValue))
                    local count: integer = read_count(raw)
                    local length = ffi.native_field_short_length(read_label(raw))
                    return count + length + ffi.native_field_call_count()
                        + embedded.point.x + embedded.row[1]
                end
            ]], module_name)
            local ok, err = h.call(module_name,
                "assert(" .. module_name .. ".exercise() == 119)")
            assert.truthy(ok, err)
        end))
        os.remove(header)
        assert.truthy(checked[1], checked[2])
    end)
end)
