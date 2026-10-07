local temporary = require "spec.support.temporary"
local h = require "spec.support.helpers"
local types = require "titan-compiler.types"
local parser = require "titan-compiler.parser"

local function with_header(contents, body)
    local path = temporary.name(".h")
    local file = assert(io.open(path, "w"))
    assert(file:write(contents))
    assert(file:close())
    local results = table.pack(xpcall(function() return body(path) end, debug.traceback))
    os.remove(path)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

describe("foreign type declarations", function()
    local session
    setup(function() session = h.new_checker_probe_session() end)
    teardown(function() h.close_checker_probe_session(session) end)

    local function check(source)
        return h.run_checker(source, session)
    end

    it("keeps foreign and Titan aliases in separate namespaces", function()
        local ok, err, ast = check([[
            type Number = integer
            foreign type Number = long
            local function consume(x: Number, y: foreign Number): integer
                return x + (y as integer)
            end
        ]])
        assert.truthy(ok, err)
        assert.equal("Type.Integer", ast[1]._type._tag)
        assert.equal("Type.CTypedef", ast[2]._type._tag)
        assert.equal("Number", ast[2]._type.name)
        assert.equal("long", types.resolve_c_typedef(ast[2]._type).spelling)
    end)

    it("retains defining C scopes through owned pointer aliases", function()
        with_header("typedef struct scoped_item { int member; } scoped_item;", function(header)
            local ok, err, ast = check(string.format([[
                foreign import %q
                foreign type ItemPointer = *scoped_item
                foreign type ItemPointerPointer = *(*scoped_item)
                foreign type ItemCallback = function(*scoped_item): void
                local type DirectOwner = owned *scoped_item
                local type PointerOwner = owned ItemPointer
                local type PointerCell = owned ItemPointerPointer
                local type CallbackCell = owned *ItemCallback
                local type PlainOwner = owned *int
                local type BuiltinCallback = owned *(function(*lua_State): void)
            ]], header))
            assert.truthy(ok, err)
            local alias_scope = ast[2]._type._ffi_scope
            local payload_scope = ast[5]._type.pointee._ffi_scope
            assert.matches("^c%-header%-%x+%.typedef$", alias_scope)
            assert.matches("^c%-header%-%x+%.typedef$", payload_scope)
            assert.not_equal(alias_scope, payload_scope)
            assert.equal(alias_scope, ast[3]._type._ffi_scope)
            assert.equal(alias_scope, ast[4]._type._ffi_scope)
            assert.equal(payload_scope, ast[6]._type.pointee._ffi_scope)
            assert.equal("Type.CPointer", ast[7]._type.pointee._tag)
            assert.equal(payload_scope, ast[7]._type.pointee.pointee._ffi_scope)
            assert.equal(alias_scope, ast[8]._type.pointee._ffi_scope)
            assert.is_nil(ast[9]._type.pointee._ffi_scope)
            local callback = ast[10]._type.pointee.pointee
            assert.is_nil(callback.params[1].pointee._ffi_scope)
        end)
    end)

    it("distinguishes anonymous declaration sites while sharing one typedef base", function()
        with_header([[
            typedef struct { int number; } *First, *Same;
            typedef struct { int number; } *Different;
            typedef struct { struct { int number; } left; struct { int number; } right; } Envelope;
        ]], function(header)
            local ok, err, ast = check(string.format([[
                foreign import %q
                local type FirstOwner = owned First
                local type SameOwner = owned Same
                local type OtherOwner = owned Different
            ]], header))
            assert.truthy(ok, err)
            assert.equal(types.runtime_identity(ast[2]._type), types.runtime_identity(ast[3]._type))
            assert.not_equal(types.runtime_identity(ast[2]._type), types.runtime_identity(ast[4]._type))
            local envelope = types.resolve_c_typedef(ast._ffi_namespace._type.type_members.Envelope)
            assert.not_equal(envelope.fields.left.type._ffi_scope, envelope.fields.right.type._ffi_scope)
            assert.matches("%.site%d+_%d+$", envelope.fields.left.type._ffi_scope)
        end)
    end)

    it("uses a complete tag's definition origin rather than an earlier forward header", function()
        with_header("struct completed_item;\n", function(forward)
            with_header("struct completed_item { int number; };\n", function(definition)
                local ok, err, imported = h.run_checker_modules({
                    scope_with_forward = string.format([[
                        foreign import %q
                        foreign import %q
                        local type Owner = owned *completed_item
                    ]], forward, definition),
                    scope_definition_only = string.format([[
                        foreign import %q
                        local type Owner = owned *completed_item
                    ]], definition),
                    scope_both = [[
                        local first = import "scope_with_forward"
                        local second = import "scope_definition_only"
                    ]],
                }, "scope_both")
                assert.truthy(ok, err)
                local first = imported.scope_with_forward.source_type.source_type_members.Owner
                local second = imported.scope_definition_only.source_type.source_type_members.Owner
                assert.equal(types.runtime_identity(first), types.runtime_identity(second))
            end)
        end)
    end)

    it("resolves forward dependencies and emits real ordered typedefs", function()
        local ok, err, ast = check([[
            foreign type Pointer = *Word
            foreign type Word = unsigned long
            local function use(p: foreign Pointer): integer
                return p[0] as integer
            end
        ]])
        assert.truthy(ok, err)
        local plan = assert(ast._ffi_header)
        assert.equal(2, #plan.typedef_declarations)
        assert.equal("typedef unsigned long Word;", plan.typedef_declarations[1])
        assert.matches("typedef Word %*Pointer;", plan.typedef_declarations[2])
        assert.equal("Type.CTypedef", ast[1]._type._tag)
        assert.equal("Type.CPointer", types.resolve_c_typedef(ast[1]._type)._tag)
    end)

    it("diagnoses cycles and duplicates in the foreign namespace", function()
        for _, case in ipairs({
            { "foreign type A = B\nforeign type B = A", "cyclic foreign type alias" },
            { "foreign type A = int\nforeign type A = long", "duplicate foreign type alias" },
        }) do
            local ok, err = check(case[1])
            assert.falsy(ok)
            assert.matches(case[2], err, 1, true)
        end
    end)

    it("retains function-pointer and grouped pointer structure in C typedefs", function()
        local ok, err, ast = check([[
            foreign type Callback = function(int): int
            foreign type PointerPointer = *(*int)
        ]])
        assert.truthy(ok, err)
        local callback = types.resolve_c_typedef(ast[1]._type)
        assert.equal("Type.CPointer", callback._tag)
        assert.equal("Type.CFunction", types.resolve_c_typedef(callback.pointee)._tag)
        local pointer = types.resolve_c_typedef(ast[2]._type)
        assert.equal("Type.CPointer", pointer._tag)
        assert.equal("Type.CPointer", types.resolve_c_typedef(pointer.pointee)._tag)
    end)

    it("rejects owned storage rather than erasing its ownership in a typedef", function()
        local ast = parser.parse("foreign-owned.titan", "foreign type Buffer = owned char[]")
        assert.falsy(ast)
    end)

    it("admits owned Titan aliases over resolved foreign pointer and array aliases", function()
        local ok, err, ast = check([[
            foreign type IntPointer = *int
            foreign type IntArray = int[]
            type Object = owned IntPointer
            type Buffer = owned IntArray
        ]])
        assert.truthy(ok, err)
        assert.equal("Type.COwned", ast[3]._type._tag)
        assert.is_false(ast[3]._type.count)
        assert.equal("Type.COwned", ast[4]._type._tag)
        assert.is_true(ast[4]._type.count)
        local scalar_ok, scalar_err = check("type Bad = owned int")
        assert.falsy(scalar_ok)
        assert.matches("requires a foreign pointer or array", scalar_err, 1, true)
    end)

    it("rejects outer const on directly written owned pointer and array types", function()
        for _, operand in ipairs({ "const *int", "const int[]" }) do
            local ok, err = check("type InvalidOwner = owned " .. operand)
            assert.falsy(ok, operand)
            assert.matches("owned type cannot have outer foreign pointer or array qualifiers",
                err, 1, true)
        end
    end)

    it("rejects outer const reached through foreign alias chains", function()
        for _, operand in ipairs({ "const *int", "const int[]" }) do
            local ok, err = check("foreign type Qualified = " .. operand .. [[
                foreign type Alias = Qualified
                type InvalidOwner = owned Alias
            ]])
            assert.falsy(ok, operand)
            assert.matches("owned type cannot have outer foreign pointer or array qualifiers",
                err, 1, true)
        end
    end)

    it("retains outer qualification when resolving imported typedef operands", function()
        with_header([[
            typedef int * const ConstPointer;
            typedef const int ConstArray[2];
        ]], function(header)
            for _, operand in ipairs({ "ConstPointer", "ConstArray" }) do
                local ok, err = check(string.format(
                    "foreign import %q\nlocal type InvalidOwner = owned %s", header, operand))
                assert.falsy(ok, operand)
                assert.matches("owned type cannot have outer foreign pointer or array qualifiers",
                    err, 1, true)
            end
        end)
    end)

    it("preserves nested pointee constness in owned pointer cells and arrays", function()
        local ok, err, ast = check([[
            foreign type ReadPointer = const *int
            local type PointerCell = owned *(const *int)
            local type PointerArray = owned (const *int)[]
            local type AliasCell = owned *ReadPointer
        ]])
        assert.truthy(ok, err)
        for index = 2, 4 do
            local owner = ast[index]._type
            assert.equal("Type.COwned", owner._tag)
            assert.equal(index == 3, owner.count)
            local payload = types.resolve_c_typedef(owner.pointee)
            assert.equal("Type.CPointer", payload._tag)
            assert.same({ "const" }, payload.quals)
        end
    end)

    it("rejects parenthesized ordinary aliases of direct foreign types", function()
        for _, rhs in ipairs({ "(foreign int)", "((foreign int))" }) do
            local ok, err = check("type Native = " .. rhs)
            assert.falsy(ok)
            assert.matches("cannot name a direct foreign type", err, 1, true)
        end
        local ok, err = check([[
            type NativeOption = (foreign int)?
            type NativeArray = {foreign int}
        ]])
        assert.truthy(ok, err)
    end)

    it("does not resolve Titan names as foreign names", function()
        local ok, err = check([[
            record Item end
            foreign type Native = Item
        ]])
        assert.falsy(ok)
        assert.matches("foreign type 'Item' is not declared", err, 1, true)
    end)

    it("keeps the builtin ffi visible before a later module shadow declaration", function()
        local ok, err = check([[
            foreign import "limits.h"
            local bits: function(): integer = function(): integer
                return ffi.CHAR_BIT as integer
            end
            local ffi: integer = 7
            function total(): integer return bits() + ffi end
        ]])
        assert.truthy(ok, err)
    end)

    it("uses M for keyword-named module types and bypasses generic type binders", function()
        local ok, err = check([[
            record nil value: integer end
            record T value: integer end
            local function inspect<|T|>(input: T): integer
                local n: M.nil = M.nil.new(20)
                local t: M.T = M.T.new(22)
                return n.value + t.value
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("keeps a legitimate imported module M usable in signatures", function()
        local ok, err = h.run_checker_modules({
            foreign_alias_m_provider = [[record Item value: integer end]],
            foreign_alias_m_consumer = [[
                local M = import "foreign_alias_m_provider"
                function read(item: M.Item): integer return item.value end
            ]],
        }, "foreign_alias_m_consumer")
        assert.truthy(ok, err)
    end)

    it("allows Titan nominal names that are contextual C words", function()
        local ok, err = check([[
            record int value: integer end
            local function read(v: int): integer return v.value end
        ]])
        assert.truthy(ok, err)
    end)

    it("imports raw typedefs through direct and transitive source headers", function()
        local ok, err = h.run_checker_modules({
            foreign_alias_origin = [[foreign type NativeWord = unsigned long]],
            foreign_alias_middle = [[
                local origin = import "foreign_alias_origin.titan"
            ]],
            foreign_alias_leaf = [[
                local middle = import "foreign_alias_middle.titan"
                local function read(v: foreign NativeWord): integer
                    return v as integer
                end
            ]],
        }, "foreign_alias_leaf")
        assert.truthy(ok, err)
    end)

    it("preserves header guards through source-import diamonds", function()
        local ok, err = h.run_checker_modules({
            foreign_alias_diamond_origin = [[foreign type Word = int]],
            foreign_alias_diamond_left = [[
                local origin = import "foreign_alias_diamond_origin.titan"
            ]],
            foreign_alias_diamond_right = [[
                local origin = import "foreign_alias_diamond_origin.titan"
            ]],
            foreign_alias_diamond = [[
                local left = import "foreign_alias_diamond_left.titan"
                local right = import "foreign_alias_diamond_right.titan"
                local function read(v: foreign Word): integer return v as integer end
            ]],
        }, "foreign_alias_diamond")
        assert.truthy(ok, err)
    end)

    it("diagnoses conflicting typedefs in combined source environments", function()
        local ok = h.run_checker_modules({
            foreign_alias_conflict_left = [[foreign type Word = int]],
            foreign_alias_conflict_right = [[foreign type Word = double]],
            foreign_alias_conflict = [[
                local left = import "foreign_alias_conflict_left.titan"
                local right = import "foreign_alias_conflict_right.titan"
            ]],
        }, "foreign_alias_conflict")
        assert.falsy(ok)
    end)

    it("does not import typedefs through ordinary Titan imports", function()
        local ok, err = h.run_checker_modules({
            foreign_alias_private = [[foreign type NativeWord = unsigned long]],
            foreign_alias_public_import = [[
                local provider = import "foreign_alias_private"
                local function read(v: foreign NativeWord): integer
                    return v as integer
                end
            ]],
        }, "foreign_alias_public_import", { interface = "source" })
        assert.falsy(ok)
        assert.matches("foreign type 'NativeWord' is not declared", err, 1, true)
    end)

    it("leaves C keyword and ordinary-identifier conflicts to the C environment", function()
        for _, source in ipairs({
            "foreign type int = long",
            'foreign import "stdio.h"\nforeign type puts = int',
        }) do
            local ok = check(source)
            assert.falsy(ok)
        end
    end)
end)
