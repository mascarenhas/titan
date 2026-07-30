local h = require "spec.support.helpers"
local coder = require "titan-compiler.coder"
local types = require "titan-compiler.types"

local function with_header(contents, fn)
    local header = os.tmpname() .. ".h"
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
        }) do
            remove_module(name)
        end
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
                local c = foreign import "]] .. header .. [["

                local type Item = owned *c.ffi_item
                local type Items = owned c.ffi_item[]
                local type PointerSlot = owned *c.ffi_item_pointer

                record Holder
                    local item?: Item
                    local items: Items
                end

                function exercise(): integer
                    local one: Item = c.ffi_item.new()
                    local many: Items = c.ffi_item.new_array(2)
                    local slot: PointerSlot =
                        c.ffi_item_pointer.new()
                    local mutable: *c.ffi_item = one
                    local immutable: const *c.ffi_item = many
                    local erased: *c.ffi_void = one

                    c.ffi_write(mutable, 37)
                    c.ffi_write(
                        (many as *c.ffi_item) + 1, 41)
                    c.ffi_store_pointer(slot, one)

                    local holder = Holder.new(one, many)
                    return c.ffi_read(immutable)
                        + c.ffi_read(
                            (holder.items as *c.ffi_item) + 1)
                        + c.ffi_read_pointer(slot)
                        + c.ffi_present(erased)
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
                local c = foreign import "]] .. header .. [["

                local type Item = owned *c.ffi_item
                local type Items = owned c.ffi_item[]

                function exercise(): integer
                    local absent_item: Item? = nil
                    local present_item: Item? = c.ffi_item.new()
                    local absent_items: Items? = nil
                    local present_items: Items? =
                        c.ffi_item.new_array(2)
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
        h.run_coder([[
            local ffi = foreign import "titan/ffi.h"

            local type Chars = owned ffi.titan_ffi_char[]
            local type SignedChars =
                owned ffi.titan_ffi_signed_char[]
            local type UnsignedChars =
                owned ffi.titan_ffi_unsigned_char[]

            local module_bytes: Chars =
                ffi.titan_ffi_char.new_array(4)

            local record Box
                local bytes: Chars
            end

            local function fill(bytes: Chars)
                bytes[0] = 65 as ffi.titan_ffi_char
                bytes[1] = 0 as ffi.titan_ffi_char
                bytes[2] = 66 as ffi.titan_ffi_char
                bytes[3] = 0 as ffi.titan_ffi_char
            end

            local function captured(bytes: Chars): () -> string
                return function(): string
                    return bytes as string
                end
            end

            function zero(): string
                return ffi.titan_ffi_char.new_array(0) as string
            end

            function one(): string
                local bytes: Chars =
                    ffi.titan_ffi_char.new_array(1)
                bytes[0] = 90 as ffi.titan_ffi_char
                return bytes as string
            end

            function plain(): string
                local bytes: Chars =
                    ffi.titan_ffi_char.new_array(4)
                fill(bytes)
                return bytes as string
            end

            function signed_bytes(): string
                local bytes: SignedChars =
                    ffi.titan_ffi_signed_char.new_array(2)
                bytes[0] = (255 as ffi.titan_ffi_int)
                    as ffi.titan_ffi_signed_char
                bytes[1] = 0 as ffi.titan_ffi_signed_char
                return bytes as string
            end

            function unsigned_bytes(): string
                local bytes: UnsignedChars =
                    ffi.titan_ffi_unsigned_char.new_array(3)
                bytes[0] = 0 as ffi.titan_ffi_unsigned_char
                bytes[1] = 254 as ffi.titan_ffi_unsigned_char
                bytes[2] = 0 as ffi.titan_ffi_unsigned_char
                return bytes as string
            end

            function through_field_option_and_closure(): string
                local bytes: Chars =
                    ffi.titan_ffi_char.new_array(4)
                fill(bytes)
                local box = Box.new(bytes)
                local optional: Chars? = box.bytes
                return captured(optional as Chars)()
            end

            function pointer_string(): string
                local bytes: Chars =
                    ffi.titan_ffi_char.new_array(4)
                fill(bytes)
                return (bytes as *ffi.titan_ffi_char) as string
            end

            local predicate_calls = 0
            local function make_for_predicate(): Chars
                predicate_calls = predicate_calls + 1
                return ffi.titan_ffi_char.new_array(1)
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

    it("roots temporary counted character owners while strings allocate",
    function()
        local csrc = h.compile_and_read_c([[
            local ffi = foreign import "titan/ffi.h"
            local lua = foreign import "lua.h"

            local function temporary(size: integer): string
                return ffi.titan_ffi_char.new_array(size) as string
            end

            function stress(generational: boolean): integer
                if generational then
                    lua.lua_gc(L, lua.LUA_GCGEN, 0, 0)
                else
                    lua.lua_gc(L, lua.LUA_GCINC, 0, 0, 0)
                end
                local total = 0
                local i = 1
                while i <= 400 do
                    local bytes = temporary(i % 33)
                    total = total + #bytes
                    lua.lua_gc(L, lua.LUA_GCCOLLECT)
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

    it("casts a record identity to void pointer once and keeps it rooted",
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
                local c = foreign import "]] .. header .. [["
                local lua = foreign import "lua.h"

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
                    lua.lua_gc(L, lua.LUA_GCCOLLECT)
                    local i = 1
                    while i <= 128 do
                        local replacement = Owner.new(0 - i)
                        i = i + 1
                    end
                    lua.lua_gc(L, lua.LUA_GCCOLLECT)
                    return 11
                end

                function exercise(): integer
                    made = 0
                    local result = c.ffi_remember_record(
                        make_owner() as c.ffi_void_pointer,
                        collect_and_reuse())
                    local raw: value =
                        c.ffi_saved_record_udata()
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

    it("casts every stable GC representation and C function pointer to void",
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
                local c = foreign import "]] .. header .. [["
                local lua = foreign import "lua.h"

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

                local function make_function(): () -> integer
                    function_calls = function_calls + 1
                    local answer = 23
                    return function(): integer
                        return answer
                    end
                end

                local function collect_and_allocate(): integer
                    lua.lua_gc(L, lua.LUA_GCCOLLECT)
                    local i = 1
                    while i <= 128 do
                        local values = {i, i + 1, i + 2}
                        local by_name: {string: integer} =
                            { ["value"] = i }
                        i = i + 1
                    end
                    lua.lua_gc(L, lua.LUA_GCCOLLECT)
                    return 7
                end

                function identities(): integer
                    local values = make_array()
                    local by_name = make_map()
                    local callback = make_function()
                    local score = 0
                    if c.ffi_same_identity(
                        values as c.ffi_void_pointer,
                        values as c.ffi_void_pointer) ~= 0 then
                        score = score + 1
                    end
                    if c.ffi_same_identity(
                        by_name as c.ffi_void_pointer,
                        by_name as c.ffi_void_pointer) ~= 0 then
                        score = score + 2
                    end
                    if c.ffi_same_identity(
                        callback as c.ffi_void_pointer,
                        callback as c.ffi_void_pointer) ~= 0 then
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
                        c.ffi_present_after(
                            make_array() as c.ffi_void_pointer,
                            collect_and_allocate())
                        + c.ffi_present_after(
                            make_map() as c.ffi_void_pointer,
                            collect_and_allocate())
                        + c.ffi_present_after(
                            make_function() as c.ffi_void_pointer,
                            collect_and_allocate())
                    return score
                        + array_calls * 100
                        + map_calls * 10
                        + function_calls
                end

                function predicates(): boolean
                    function_calls = 0
                    local real =
                        make_function() is c.ffi_void_pointer
                    local raw: value = 42
                    local malformed: () -> () = raw
                    local fake =
                        malformed is c.ffi_void_pointer
                    return real and not fake and function_calls == 1
                end

                function malformed_function_cast(): integer
                    local raw: value = 42
                    local malformed: () -> () = raw
                    local pointer =
                        malformed as c.ffi_void_pointer
                    return c.ffi_present_after(pointer, 1)
                end

                function c_function_pointer(): integer
                    local callback = c.ffi_get_callback()
                    local pointer =
                        callback as c.ffi_void_pointer
                    return c.ffi_present_after(pointer, 1)
                end
            ]])

            assert.not_match("lua_togco", csrc, 1, true)
            assert.match("sethvalue", csrc, 1, true)
            assert.match("setobj2t", csrc, 1, true)
            assert.match("gcvalue%(&_tmp_%d+%)", csrc)
            assert.match("iscollectable%(&_tmp_%d+%)", csrc)
            assert.match(
                "titan_cast_func%(ffi_void_pointer, [_%w]+%)",
                csrc)

            local ok, err = h.call("test", [[
                assert(test.identities() == 66)
                assert(test.temporary_once() == 132)
                assert(test.predicates())
                assert(test.c_function_pointer() == 1)

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
                local c = foreign import "]] .. header .. [["
                local type ConstChars =
                    owned c.ffi_const_char[]

                function qualified_bytes(): string
                    local bytes: ConstChars =
                        c.ffi_const_char.new_array(3)
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
                local c = foreign import "]] .. header .. [["

                local type Item = owned *c.ffi_item
                local type Items = {Item}
                local type ByName = {string: Item}
                local type Transform = (Item) -> Item

                local function sum(...: Item): integer
                    local total = 0
                    local i = 1
                    while i <= #... do
                        total = total + c.ffi_read(...[i])
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
                    local first: Item = c.ffi_item.new()
                    local second: Item = c.ffi_item.new()
                    c.ffi_write(first, 11)
                    c.ffi_write(second, 13)

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
                        + c.ffi_read(restored_items[1] as Item)
                        + c.ffi_read(
                            restored_by_name["second"] as Item)
                        + c.ffi_read(restored_transform(first))
                end
            ]], [[
                assert(test.exercise() == 83)
            ]])
        end)
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
                local ok, err = h.generate_modules({
                    owned_tag_a = [[
                        local c = foreign import "]] ..
                            first_header .. [["
                        local type Owner = owned *c.ffi_same

                        local function read(owner: Owner): integer
                            return owner.left as integer
                        end

                        function expose(): value
                            return read
                        end
                    ]],
                    owned_tag_b = [[
                        local c = foreign import "]] ..
                            second_header .. [["
                        local a = import "owned_tag_a"
                        local type Owner = owned *c.ffi_same

                        function call_wrong(): integer
                            local raw: value = a.expose()
                            local read: (Owner) -> integer = raw
                            return read(c.ffi_same.new())
                        end
                    ]],
                }, "owned_tag_b")
                assert.truthy(ok, err)

                local called, message = h.call("owned_tag_b", [[
                    owned_tag_b.call_wrong()
                ]])
                assert.falsy(called)
                assert.match("expected owned", message)
            end)
        end)
    end)

    it("keeps same-spelled Titan and C callable tags distinct in one module",
    function()
        local titan_integer = types.Function(
            { types.Integer() }, { types.Integer() },
            false, false, false)
        local c_integer = types.CTypedef(
            "integer", types.CFloat("double"))
        local foreign_integer = types.Function(
            { c_integer }, { c_integer },
            false, false, false)

        assert.equal(
            types.tostring(titan_integer),
            types.tostring(foreign_integer))
        assert.not_equal(
            coder._function_type_tag_cache_key(titan_integer),
            coder._function_type_tag_cache_key(foreign_integer))
    end)
end)
