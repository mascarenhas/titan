local temporary = require "spec.support.temporary"
require "titan-compiler.coder.core"
local h = require "spec.support.helpers"
local coder = require "titan-compiler.coder"
local coder_names = require "titan-compiler.coder.names"
local types = require "titan-compiler.types"
local driver = require "titan-compiler.driver"

local function with_header(contents, fn)
    local header = temporary.name(".h")
    local file = assert(io.open(header, "w"))
    assert(file:write(contents))
    assert(file:close())

    local results = { pcall(fn, header) }
    os.remove(header)
    if not results[1] then error(results[2], 0) end
    table.remove(results, 1)
    return table.unpack(results)
end

local function remove_module(name)
    os.remove(name .. ".c")
    os.remove(name .. ".o")
    os.remove(name .. ".so")
    os.remove(name .. ".a")
    os.execute("rm -rf " .. name .. ".so.dSYM")
end

describe("source-written owned C type code generation", function()
    after_each(function()
        for _, name in ipairs({
            "test",
            "owned_tag_a",
            "owned_tag_b",
            "owned_tag_middle",
        }) do
            remove_module(name)
        end
    end)

    it("publishes owned-C metatables only after initialization succeeds",
    function()
        with_header([[
            typedef struct ffi_item {
                int value;
            } ffi_item;
        ]], function(header)
            local csrc = h.with_extra_cflags({ '-DTITAN_COMPILER_TESTS' }, function ()
              return h.compile_and_read_c([[
                foreign import "]] .. header .. [["
                local type Item = owned *ffi_item
                local item: Item = foreign ffi_item.new()
                function ready(): boolean
                    return true
                end
                function make(): value
                    local made: Item = foreign ffi_item.new()
                    return made
                end
              ]])
            end)
            local lookup = assert(csrc:find(
                "luaL_getmetatable(L, \"Titan owned C", 1, true))
            local construct = assert(csrc:find(
                "lua_newtable(L);", lookup, true))
            local name = assert(csrc:find(
                "lua_setfield(L, -2, \"__name\");", construct, true))
            local type_key = assert(csrc:find(
                "lua_rawsetp(L, -2, TITAN_MT_TYPE);", name, true))
            local metatable_key = assert(csrc:find(
                "lua_pushliteral(L, \"__metatable\");", type_key, true))
            local metatable = assert(csrc:find(
                "lua_settable(L, -3);", metatable_key, true))
            local publish = assert(csrc:find(
                "lua_setfield(L, LUA_REGISTRYINDEX", type_key, true))
            assert.is_true(lookup < construct and construct < name)
            assert.is_true(name < type_key and type_key < metatable_key and
                metatable_key < metatable and metatable < publish)
            assert.truthy(csrc:find(
                "invalid Titan owned C metatable registry entry", publish,
                true))

            local ok, err = h.call("test", [[
                local registry = debug.getregistry()
                local item = test.make()
                local public_name = getmetatable(item)
                local metatable = debug.getmetatable(item)
                assert(type(public_name) == "string")
                assert(type(metatable) == "table")
                assert(metatable.__name == public_name)
                assert(metatable[registry.TITAN_BRAND] == 6)
                local types = require "titan-compiler.types"
                local descriptor = assert(load(
                    "return " .. metatable[registry.TITAN_MT_TYPE],
                    "owned C descriptor", "t", types))()
                assert(descriptor._tag == "Type.COwned" and not descriptor.count)
                local alias = descriptor.pointee
                assert(alias._tag == "Type.CTypedef" and alias.name == "ffi_item")
                local structure = alias.target
                assert(structure._tag == "Type.CStruct")
                assert(structure.tagname == "ffi_item" and structure.complete)
                assert(not structure.has_fam and #structure.fields == 1)
                local field = structure.fields[1]
                assert(field._tag == "Type.CField" and field.name == "value")
                assert(field.type._tag == "Type.CInteger")
                assert(field.type.spelling == "int" and field.type.signed)
                assert(not field.bitfield and not field.flexible_array)
                assert(tostring(item):sub(1, #public_name + 2) ==
                       public_name .. ": ")
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("uses source annotations for scalar, counted, and pointer payloads",
    function()
        with_header([[
            typedef void ffi_void;
            typedef struct ffi_item {
                int value;
            } ffi_item;
            typedef ffi_item *ffi_item_pointer;

            static void ffi_write(ffi_item *item, int value) {
                item->value = value;
            }
            static int ffi_read(const ffi_item *item) {
                return item->value;
            }
            static void ffi_store_pointer(
                ffi_item **slot,
                ffi_item *item
            ) {
                *slot = item;
            }
            static int ffi_read_pointer(ffi_item **slot) {
                return (*slot)->value;
            }
            static int ffi_present(const void *pointer) {
                return pointer != 0;
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                local type Item = owned *ffi_item
                local type Items = owned ffi_item[]
                local type PointerSlot = owned *ffi_item_pointer

                record Holder
                    local item: Item?
                    local items: Items
                end

                function exercise(): integer
                    local one: Item = foreign ffi_item.new()
                    local many: Items = foreign ffi_item.new_array(2)
                    local slot: PointerSlot =
                        foreign ffi_item_pointer.new()
                    local mutable: foreign *ffi_item = one
                    local immutable: foreign const *ffi_item = many
                    local erased: foreign *ffi_void = one

                    ffi.ffi_write(mutable, 37)
                    ffi.ffi_write(
                        (many as foreign *ffi_item) + 1, 41)
                    ffi.ffi_store_pointer(slot, one)

                    local holder = Holder.new(one, many)
                    return ffi.ffi_read(immutable)
                        + ffi.ffi_read(
                            (holder.items as foreign *ffi_item) + 1)
                        + ffi.ffi_read_pointer(slot)
                        + ffi.ffi_present(erased)
                        + #holder.items
                end
            ]], [[
                local result = test.exercise()
                assert(result == 81, "result=" .. tostring(result))
            ]])
        end)
    end)

    it("implements optional owner truthiness in boolean expressions",
    function()
        with_header([[
            typedef struct ffi_item {
                int value;
            } ffi_item;
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                local type Item = owned *ffi_item
                local type Items = owned ffi_item[]

                function exercise(): integer
                    local absent_item: Item? = nil
                    local present_item: Item? = foreign ffi_item.new()
                    local absent_items: Items? = nil
                    local present_items: Items? =
                        foreign ffi_item.new_array(2)
                    local result = 0

                    if not absent_item then result = result + 1 end
                    if not present_item then result = result + 100 end
                    if not absent_items then result = result + 2 end
                    if not present_items then result = result + 100 end

                    if true and present_item then
                        result = result + 4
                    end
                    if true and absent_item then
                        result = result + 100
                    end
                    if false or present_items then
                        result = result + 8
                    end
                    if false or absent_items then
                        result = result + 100
                    end

                    return result
                end
            ]], [[
                assert(test.exercise() == 15)
            ]])
        end)
    end)

    it("casts counted character owners with their exact binary length",
    function()
        with_header([[
            typedef char ffi_char;
            typedef signed char ffi_signed_char;
            typedef unsigned char ffi_unsigned_char;
            typedef int ffi_int;
        ]], function(header)
            h.run_coder([[
            foreign import "]] .. header .. [["

            local type Chars = owned ffi_char[]
            local type SignedChars =
                owned ffi_signed_char[]
            local type UnsignedChars =
                owned ffi_unsigned_char[]

            local module_bytes: Chars =
                foreign ffi_char.new_array(4)

            local record Box
                local bytes: Chars
            end

            local function fill(bytes: Chars)
                bytes[0] = 65 as foreign ffi_char
                bytes[1] = 0 as foreign ffi_char
                bytes[2] = 66 as foreign ffi_char
                bytes[3] = 0 as foreign ffi_char
            end

            local function captured(bytes: Chars): function (): string
                return function(): string
                    return bytes as string
                end
            end

            function zero(): string
                return foreign ffi_char.new_array(0) as string
            end

            function one(): string
                local bytes: Chars =
                    foreign ffi_char.new_array(1)
                bytes[0] = 90 as foreign ffi_char
                return bytes as string
            end

            function plain(): string
                local bytes: Chars =
                    foreign ffi_char.new_array(4)
                fill(bytes)
                return bytes as string
            end

            function signed_bytes(): string
                local bytes: SignedChars =
                    foreign ffi_signed_char.new_array(2)
                bytes[0] = (255 as foreign ffi_int)
                    as foreign ffi_signed_char
                bytes[1] = 0 as foreign ffi_signed_char
                return bytes as string
            end

            function unsigned_bytes(): string
                local bytes: UnsignedChars =
                    foreign ffi_unsigned_char.new_array(3)
                bytes[0] = 0 as foreign ffi_unsigned_char
                bytes[1] = 254 as foreign ffi_unsigned_char
                bytes[2] = 0 as foreign ffi_unsigned_char
                return bytes as string
            end

            function through_field_option_and_closure(): string
                local bytes: Chars =
                    foreign ffi_char.new_array(4)
                fill(bytes)
                local box = Box.new(bytes)
                local optional: Chars? = box.bytes
                return captured(optional as Chars)()
            end

            function pointer_string(): string
                local bytes: Chars =
                    foreign ffi_char.new_array(4)
                fill(bytes)
                return (bytes as foreign *ffi_char) as string
            end

            local predicate_calls = 0
            local function make_for_predicate(): Chars
                predicate_calls = predicate_calls + 1
                return foreign ffi_char.new_array(1)
            end

            function predicate_once(): boolean
                predicate_calls = 0
                local result = make_for_predicate() is string
                return result and predicate_calls == 1
            end

            function module_value(): string
                fill(module_bytes)
                return module_bytes as string
            end
            ]], [[
                assert(test.zero() == "")
                assert(test.one() == "Z")
                assert(test.plain() == "A\0B\0")
                assert(#test.plain() == 4)
                assert(test.signed_bytes() == string.char(255, 0))
                assert(test.unsigned_bytes() == string.char(0, 254, 0))
                assert(test.through_field_option_and_closure() == "A\0B\0")
                assert(test.pointer_string() == "A")
                assert(test.predicate_once())
                assert(test.module_value() == "A\0B\0")
            ]])
        end)
    end)

    it("covers temporary counted-character owner rooting during string creation",
    function()
        with_header([[
            typedef char ffi_char;
        ]], function(header)
            local csrc = h.compile_and_read_c([[
                foreign import "]] .. header .. [["

                function temporary(size: integer): string
                    return foreign ffi_char.new_array(size) as string
                end
            ]])

            assert.matches("luaS_newlstr", csrc, 1, true)
            assert.matches("getudatamem", csrc, 1, true)
            assert.matches("%->len", csrc)

            local ok, err = h.call("test", [[
                assert(#test.temporary(4) == 4)
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("roots temporary counted character owners while strings allocate #stress",
    function()
        local csrc = h.compile_and_read_c([[
            foreign import "titan/ffi.h"
            foreign import "lua.h"

            local function temporary(size: integer): string
                return foreign char.new_array(size) as string
            end

            function stress(generational: boolean): integer
                if generational then
                    ffi.lua_gc(L, ffi.LUA_GCGEN, 0, 0)
                else
                    ffi.lua_gc(L, ffi.LUA_GCINC, 0, 0, 0)
                end
                local total = 0
                local i = 1
                while i <= 400 do
                    local bytes = temporary(i % 33)
                    total = total + #bytes
                    ffi.lua_gc(L, ffi.LUA_GCCOLLECT)
                    i = i + 1
                end
                return total
            end
        ]])

        assert.matches("luaS_newlstr", csrc, 1, true)
        assert.matches("getudatamem", csrc, 1, true)
        assert.matches("%->len", csrc)

        local ok, err = h.call("test", [[
            assert(test.stress(false) == 6346)
            assert(test.stress(true) == 6346)
        ]])
        assert.truthy(ok, err)
    end)

    it("covers a temporary record identity cast before a later argument call",
    function()
        with_header([[
            typedef void *ffi_void_pointer;
            static int ffi_present_record(void *record, int marker) {
                return record != 0 ? marker : 0;
            }
        ]], function(header)
            local csrc = h.compile_and_read_c([[
                foreign import "]] .. header .. [["

                local record Owner
                    local marker: integer
                end

                local function make_owner(): Owner
                    return Owner.new(57)
                end

                local function later_argument(): integer
                    return 11
                end

                function exercise(): integer
                    return ffi.ffi_present_record(
                        make_owner() as foreign ffi_void_pointer,
                        later_argument()) as integer
                end
            ]])

            assert.not_match("lua_togco", csrc, 1, true)
            assert.match("setuvalue", csrc, 1, true)
            assert.match("%(ffi_void_pointer%)%(_tmp_%d+%)", csrc)

            local ok, err = h.call("test", [[
                assert(test.exercise() == 11)
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("casts a record identity to void pointer once and keeps it rooted #stress",
    function()
        with_header([[
            #include "titan/ffi.h"

            typedef void *ffi_void_pointer;
            static void *ffi_saved_record;

            static int ffi_remember_record(
                void *record,
                int marker
            ) {
                ffi_saved_record = record;
                return marker;
            }

            static Udata *ffi_saved_record_udata(void) {
                return (Udata *)ffi_saved_record;
            }
        ]], function(header)
            local csrc = h.compile_and_read_c([[
                foreign import "]] .. header .. [["
                foreign import "lua.h"

                local record Owner
                    local marker: integer
                end
                local type Alias = Owner
                local made = 0

                local function make_owner(): Alias
                    made = made + 1
                    return Owner.new(57)
                end

                local function collect_and_reuse(): integer
                    ffi.lua_gc(L, ffi.LUA_GCCOLLECT)
                    local i = 1
                    while i <= 128 do
                        local replacement = Owner.new(0 - i)
                        i = i + 1
                    end
                    ffi.lua_gc(L, ffi.LUA_GCCOLLECT)
                    return 11
                end

                function exercise(): integer
                    made = 0
                    local result = ffi.ffi_remember_record(
                        make_owner() as foreign ffi_void_pointer,
                        collect_and_reuse())
                    local raw: value =
                        ffi.ffi_saved_record_udata()
                    local restored: Owner = raw
                    return result as integer
                        + restored.marker
                        + made * 100
                end
            ]])

            assert.not_match("lua_togco", csrc, 1, true)
            assert.match("setuvalue", csrc, 1, true)
            assert.match("%(ffi_void_pointer%)%(_tmp_%d+%)", csrc)

            local ok, err = h.call("test", [[
                assert(test.exercise() == 168)
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("covers stable GC identities and a C function pointer cast to void",
    function()
        with_header([[
            typedef void *ffi_void_pointer;
            typedef int (*ffi_callback_pointer)(int);

            static int ffi_same_identity(
                const void *left,
                const void *right
            ) {
                return left == right;
            }

            static int ffi_increment(int value) {
                return value + 1;
            }

            static ffi_callback_pointer ffi_get_callback(void) {
                return ffi_increment;
            }
        ]], function(header)
            local csrc = h.compile_and_read_c([[
                foreign import "]] .. header .. [["

                function identities(): integer
                    local values: {integer} = {17}
                    local by_name: {string: integer} = {
                        ["answer"] = 19
                    }
                    local answer = 23
                    local callback = function(): integer
                        return answer
                    end
                    local score = 0
                    if ffi.ffi_same_identity(
                        values as foreign ffi_void_pointer,
                        values as foreign ffi_void_pointer) ~= 0 then
                        score = score + 1
                    end
                    if ffi.ffi_same_identity(
                        by_name as foreign ffi_void_pointer,
                        by_name as foreign ffi_void_pointer) ~= 0 then
                        score = score + 2
                    end
                    if ffi.ffi_same_identity(
                        callback as foreign ffi_void_pointer,
                        callback as foreign ffi_void_pointer) ~= 0 then
                        score = score + 4
                    end
                    return score + values[1]
                        + by_name["answer"] + callback()
                end

                function roundtrip_c_function_pointer(): integer
                    local pointer =
                        ffi.ffi_get_callback() as foreign ffi_void_pointer
                    local callback = pointer as foreign ffi_callback_pointer
                    return callback(41) as integer
                end
            ]])

            assert.not_match("lua_togco", csrc, 1, true)
            assert.match("sethvalue", csrc, 1, true)
            assert.match("setobj2t", csrc, 1, true)
            assert.match("gcvalue%(&_tmp_%d+%)", csrc)
            assert.match("iscollectable%(&_tmp_%d+%)", csrc)
            assert.match(
                "titan_cast_func%s*%(%s*ffi_void_pointer,%s*[_%w]+%s*%)",
                csrc)

            local ok, err = h.call("test", [[
                assert(test.identities() == 66)
                assert(test.roundtrip_c_function_pointer() == 42)
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("casts every stable GC representation and C function pointer to void #stress",
    function()
        with_header([[
            typedef void *ffi_void_pointer;
            typedef int (*ffi_callback_pointer)(int);

            static int ffi_same_identity(
                const void *left,
                const void *right
            ) {
                return left == right;
            }

            static int ffi_present_after(
                const void *pointer,
                int marker
            ) {
                return pointer != 0 ? marker : 0;
            }

            static int ffi_increment(int value) {
                return value + 1;
            }

            static ffi_callback_pointer ffi_get_callback(void) {
                return ffi_increment;
            }
        ]], function(header)
            local csrc = h.compile_and_read_c([[
                foreign import "]] .. header .. [["
                foreign import "lua.h"

                local array_calls = 0
                local map_calls = 0
                local function_calls = 0

                local function make_array(): {integer}
                    array_calls = array_calls + 1
                    return {17}
                end

                local function make_map(): {string: integer}
                    map_calls = map_calls + 1
                    return { ["answer"] = 19 }
                end

                local function make_function(): function (): (integer)
                    function_calls = function_calls + 1
                    local answer = 23
                    return function(): integer
                        return answer
                    end
                end

                local function collect_and_allocate(): integer
                    ffi.lua_gc(L, ffi.LUA_GCCOLLECT)
                    local i = 1
                    while i <= 128 do
                        local values = {i, i + 1, i + 2}
                        local by_name: {string: integer} =
                            { ["value"] = i }
                        i = i + 1
                    end
                    ffi.lua_gc(L, ffi.LUA_GCCOLLECT)
                    return 7
                end

                function identities(): integer
                    local values = make_array()
                    local by_name = make_map()
                    local callback = make_function()
                    local score = 0
                    if ffi.ffi_same_identity(
                        values as foreign ffi_void_pointer,
                        values as foreign ffi_void_pointer) ~= 0 then
                        score = score + 1
                    end
                    if ffi.ffi_same_identity(
                        by_name as foreign ffi_void_pointer,
                        by_name as foreign ffi_void_pointer) ~= 0 then
                        score = score + 2
                    end
                    if ffi.ffi_same_identity(
                        callback as foreign ffi_void_pointer,
                        callback as foreign ffi_void_pointer) ~= 0 then
                        score = score + 4
                    end
                    return score + values[1]
                        + by_name["answer"] + callback()
                end

                function temporary_once(): integer
                    array_calls = 0
                    map_calls = 0
                    function_calls = 0
                    local score =
                        ffi.ffi_present_after(
                            make_array() as foreign ffi_void_pointer,
                            collect_and_allocate())
                        + ffi.ffi_present_after(
                            make_map() as foreign ffi_void_pointer,
                            collect_and_allocate())
                        + ffi.ffi_present_after(
                            make_function() as foreign ffi_void_pointer,
                            collect_and_allocate())
                    return score
                        + array_calls * 100
                        + map_calls * 10
                        + function_calls
                end

                function predicates(): boolean
                    function_calls = 0
                    local real =
                        make_function() is foreign ffi_void_pointer
                    local raw: value = 42
                    local malformed: function (): () = raw
                    local fake =
                        malformed is foreign ffi_void_pointer
                    return real and not fake and function_calls == 1
                end

                function malformed_function_cast(): integer
                    local raw: value = 42
                    local malformed: function (): () = raw
                    local pointer =
                        malformed as foreign ffi_void_pointer
                    return ffi.ffi_present_after(pointer, 1)
                end

                function c_function_pointer(): integer
                    local callback = ffi.ffi_get_callback()
                    local pointer =
                        callback as foreign ffi_void_pointer
                    return ffi.ffi_present_after(pointer, 1)
                end

                function roundtrip_c_function_pointer(): integer
                    local pointer =
                        ffi.ffi_get_callback() as foreign ffi_void_pointer
                    local callback = pointer as foreign ffi_callback_pointer
                    return callback(41) as integer
                end
            ]])

            assert.not_match("lua_togco", csrc, 1, true)
            assert.match("sethvalue", csrc, 1, true)
            assert.match("setobj2t", csrc, 1, true)
            assert.match("gcvalue%(&_tmp_%d+%)", csrc)
            assert.match("iscollectable%(&_tmp_%d+%)", csrc)
            assert.match(
                "titan_cast_func%s*%(%s*ffi_void_pointer,%s*[_%w]+%s*%)",
                csrc)

            local ok, err = h.call("test", [[
                assert(test.identities() == 66)
                assert(test.temporary_once() == 132)
                assert(test.predicates())
                assert(test.c_function_pointer() == 1)
                assert(test.roundtrip_c_function_pointer() == 42)

                local cast_ok, cast_error =
                    pcall(test.malformed_function_cast)
                assert(not cast_ok)
                assert(tostring(cast_error):match(
                    "function value has no GC identity"))
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("casts typedef-qualified counted character owners by exact length",
    function()
        with_header([[
            typedef const char ffi_const_char;
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["
                local type ConstChars =
                    owned ffi_const_char[]

                function qualified_bytes(): string
                    local bytes: ConstChars =
                        foreign ffi_const_char.new_array(3)
                    return bytes as string
                end
            ]], [[
                local result = test.qualified_bytes()
                assert(#result == 3)
                assert(result == "\0\0\0")
            ]])
        end)
    end)

    it("uses owner descriptors for variadic parameters and flexible returns",
    function()
        with_header([[
            typedef struct ffi_item {
                int value;
            } ffi_item;

            static void ffi_write(ffi_item *item, int value) {
                item->value = value;
            }
            static int ffi_read(const ffi_item *item) {
                return item->value;
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                local type Item = owned *ffi_item
                local type Items = {Item}
                local type ByName = {string: Item}
                local type Transform = function (Item): (Item)

                local function sum(...: Item): integer
                    local total = 0
                    local i = 1
                    while i <= #... do
                        total = total + ffi.ffi_read(...[i])
                        i = i + 1
                    end
                    return total
                end

                local function emit(
                    first: Item,
                    second: Item
                ): (...: Item)
                    return first, second
                end

                local function identity(item: Item): Item
                    return item
                end

                function exercise(): integer
                    local first: Item = foreign ffi_item.new()
                    local second: Item = foreign ffi_item.new()
                    ffi.ffi_write(first, 11)
                    ffi.ffi_write(second, 13)

                    local items: Items = { first, second }
                    local raw_items: value = items
                    local restored_items: Items = raw_items

                    local by_name: ByName = {}
                    by_name["second"] = second
                    local raw_by_name: value = by_name
                    local restored_by_name: ByName = raw_by_name

                    local transform: Transform = identity
                    local raw_transform: value = transform
                    local restored_transform: Transform = raw_transform

                    return sum(first, second)
                        + sum(emit(first, second))
                        + ffi.ffi_read(restored_items[1] as Item)
                        + ffi.ffi_read(
                            restored_by_name["second"] as Item)
                        + ffi.ffi_read(restored_transform(first))
                end
            ]], [[
                assert(test.exercise() == 83)
            ]])
        end)
    end)

    it("inherits C scopes through direct and transitive source imports", function()
        with_header([[
            struct inherited_item { int number; };
            typedef struct inherited_item *InheritedPointer;
            typedef struct inherited_item InheritedArray[];
        ]], function(header)
            for _, transitive in ipairs({ false, true }) do
                local upstream = transitive and "owned_tag_middle" or "owned_tag_a"
                local modules = {
                    owned_tag_a = string.format([[
                        foreign import %q
                        foreign type Item = inherited_item
                        function make_alias(): value
                            local item: owned *Item = foreign Item.new()
                            item.number = 11
                            return item
                        end
                        function make_raw(): value
                            local item: owned InheritedPointer = foreign inherited_item.new()
                            item.number = 13
                            return item
                        end
                        function make_array(): value
                            local items: owned InheritedArray = foreign inherited_item.new_array(2)
                            items[0].number = 17
                            items[1].number = 19
                            return items
                        end
                        local function read(item: owned *Item): integer
                            return item.number as integer
                        end
                        function reader(): value return read end
                    ]], header),
                    owned_tag_b = string.format([[
                        local a = import %q
                        local record Holder item: owned *Item end
                        local function accept(item: owned *Item): integer
                            return item.number as integer
                        end
                        function acceptor(): value return accept end
                        function holder(): value return Holder.new(a.make_alias()) end
                        function array(): value
                            local items: {owned *Item} = {}
                            return items
                        end
                        function exercise(): integer
                            local item: owned *Item = a.make_alias()
                            local raw: owned InheritedPointer = a.make_raw()
                            local items: owned InheritedArray = a.make_array()
                            local read: function(owned *Item): integer = a.reader()
                            return item.number + raw.number + items[0].number
                                + items[1].number + read(item)
                        end
                    ]], upstream .. ".titan"),
                }
                if transitive then
                    modules.owned_tag_middle = [[
                        local a = import "owned_tag_a.titan"
                        function make_alias(): value return a.make_alias() end
                        function make_raw(): value return a.make_raw() end
                        function make_array(): value return a.make_array() end
                        function reader(): value return a.reader() end
                    ]]
                end
                local ok, err = h.generate_modules(modules, "owned_tag_b")
                assert.truthy(ok, err)
                local called, message = h.call("owned_tag_b", [[
                    local a = require "owned_tag_a"
                    assert(owned_tag_b.exercise() == 71)
                    assert(owned_tag_b.acceptor()(a.make_alias()) == 11)
                    local holder = owned_tag_b.holder()
                    holder.item = a.make_alias()
                    local items = owned_tag_b.array()
                    items[1] = a.make_alias()
                    assert(#items == 1)
                ]])
                assert.truthy(called, message)
            end
        end)
    end)

    local function shared_header_owners(forced)
        with_header([[
            #ifndef TITAN_SHARED_OWNER_HEADER
            #define TITAN_SHARED_OWNER_HEADER
            struct shared_payload { int number; };
            typedef struct shared_payload *NativePointer;
            typedef struct shared_payload NativeArray[];
            #endif
        ]], function(header)
            local previous = driver.EXTRA_CPPFLAGS
            if forced then
                driver.EXTRA_CPPFLAGS = { table.unpack(previous or {}) }
                driver.EXTRA_CPPFLAGS[#driver.EXTRA_CPPFLAGS + 1] = "-include"
                driver.EXTRA_CPPFLAGS[#driver.EXTRA_CPPFLAGS + 1] = header
                assert(driver.configure_foreign_c())
            end
            local ok, failure = xpcall(function()
                local imports = forced and "" or string.format("foreign import %q\n", header)
                local function producer(value)
                    return imports .. string.format([[
                        foreign type Pointer = NativePointer
                        foreign type Array = NativeArray
                        function make(): value
                            local item: owned Pointer = foreign shared_payload.new()
                            item.number = %d
                            return item
                        end
                        function make_array(): value
                            local items: owned Array = foreign shared_payload.new_array(1)
                            items[0].number = %d
                            return items
                        end
                        local function read(item: owned Pointer): integer
                            return item.number as integer
                        end
                        function reader(): value return read end
                    ]], value, value)
                end
                for _, reversed in ipairs({ false, true }) do
                    local first = reversed and "owned_tag_b" or "owned_tag_a"
                    local second = reversed and "owned_tag_a" or "owned_tag_b"
                    local modules = {
                        owned_tag_a = producer(41),
                        owned_tag_b = producer(43),
                        owned_tag_middle = string.format([[
                            local first = import %q
                            local second = import %q
                            function exercise(): integer
                                local a: owned Pointer = first.make()
                                local b: owned Pointer = second.make()
                                local aa: owned Array = first.make_array()
                                local bb: owned Array = second.make_array()
                                local ar: function(owned Pointer): integer = first.reader()
                                local br: function(owned Pointer): integer = second.reader()
                                return ar(a) + br(b) + aa[0].number + bb[0].number
                            end
                        ]], first .. ".titan", second .. ".titan"),
                    }
                    local generated, err = h.generate_modules(modules, "owned_tag_middle")
                    assert.truthy(generated, err)
                    local called, message = h.call("owned_tag_middle", [[
                        assert(owned_tag_middle.exercise() == 168)
                    ]])
                    assert.truthy(called, message)
                end
            end, debug.traceback)
            driver.EXTRA_CPPFLAGS = previous
            assert(driver.configure_foreign_c())
            assert.truthy(ok, failure)
        end)
    end

    it("shares declaration scopes for independent users of one physical header", function()
        shared_header_owners(false)
    end)

    it("shares forced-header scopes through two providers and both import orders", function()
        shared_header_owners(true)
    end)

    it("scopes C-bearing callable tags to their defining module", function()
        with_header([[
            typedef struct ffi_same {
                int left;
            } ffi_same;
        ]], function(first_header)
            with_header([[
                typedef struct ffi_same {
                    double unrelated;
                    int right;
                } ffi_same;
            ]], function(second_header)
                -- Model separate compilation deliberately: source views would
                -- carry the defining C scope across this synthetic module set.
                local ok, err = h.generate_modules({
                    owned_tag_a = [[
                        foreign import "]] ..
                            first_header .. [["
                        local type Owner = owned *ffi_same

                        local function read(owner: Owner): integer
                            return owner.left as integer
                        end

                        function expose(): value
                            return read
                        end
                    ]],
                    owned_tag_b = [[
                        foreign import "]] ..
                            second_header .. [["
                        local a = import "owned_tag_a"
                        local type Owner = owned *ffi_same

                        function call_wrong(): integer
                            local raw: value = a.expose()
                            local read: function (Owner): integer = raw
                            return read(foreign ffi_same.new())
                        end
                    ]],
                }, "owned_tag_b", nil, { interface = "compiled" })
                assert.truthy(ok, err)

                local called, message = h.call("owned_tag_b", [[
                    owned_tag_b.call_wrong()
                ]])
                assert.falsy(called)
                assert.match("expected owned", message)
            end)
        end)
    end)
end)
