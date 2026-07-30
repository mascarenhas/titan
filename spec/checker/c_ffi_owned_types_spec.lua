local h = require "spec.support.helpers"
local types = require "titan-compiler.types"

local probe_session

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

local declarations = [[
    typedef void ffi_void;
    typedef void *ffi_void_pointer;
    typedef int ffi_int;
    typedef char ffi_char;
    typedef signed char ffi_signed_char;
    typedef unsigned char ffi_unsigned_char;
    typedef ffi_unsigned_char ffi_byte;

    typedef struct ffi_item {
        int number;
    } ffi_item;
    typedef const ffi_item ffi_const_item;
    typedef ffi_item *ffi_item_pointer;

    typedef union ffi_cell {
        int integer_value;
        double number;
    } ffi_cell;

    typedef struct ffi_incomplete ffi_incomplete;
    typedef int ffi_row[4];
    typedef int ffi_callback(int);
    typedef int (*ffi_callback_pointer)(int);

    typedef struct ffi_flexible {
        int length;
        unsigned char bytes[];
    } ffi_flexible;

    static int ffi_read(const ffi_item *item) {
        return item->number;
    }
    static void ffi_write(ffi_item *item) {
        item->number = 41;
    }
    static int ffi_present(const void *pointer) {
        return pointer != 0;
    }
    static int ffi_pointer_present(ffi_item **pointer) {
        return pointer != 0;
    }
]]

local function check_with_header(header, body)
    return h.run_checker(
        'local c = foreign import "' .. header .. '"\n' .. body,
        probe_session)
end

describe("source-written owned C types", function()
    setup(function()
        probe_session = h.new_checker_probe_session()
    end)

    teardown(function()
        h.close_checker_probe_session(probe_session)
        probe_session = nil
    end)

    it("admits scalar and counted owners throughout local type shapes",
    function()
        with_header(declarations, function(header)
            local ok, err, ast = check_with_header(header, [[
                local type Item = owned *c.ffi_item
                local type Items = owned c.ffi_item[]
                local type OptionalItem = Item?
                local type Transform = (Item) -> Item

                local top: Item = c.ffi_item.new()
                local top_items: Items = c.ffi_item.new_array(2)

                record PublicHolder
                    local item?: Item
                    local items: Items
                    local transform: Transform
                end

                local function identity(
                    item: Item,
                    items: Items,
                    optional: OptionalItem
                ): (Item, Items, OptionalItem)
                    return item, items, optional
                end

                local function PublicHolder:replace(item: Item): Item
                    self.item = item
                    return item
                end

                local function use_locally(): integer
                    local one: Item = c.ffi_item.new()
                    local many: Items = c.ffi_item.new_array(3)
                    local optional: Item? = one
                    local owners: {Item} = { one }
                    local by_name: {string: Item} = {}
                    by_name["one"] = one

                    local transform: Transform =
                        function(item: Item): Item
                            item.number = 17
                            return item
                        end
                    local holder = PublicHolder.new(
                        optional, many, transform)
                    local again, all, maybe =
                        identity(
                            holder:replace(owners[1] as Item),
                            holder.items,
                            holder.item)
                    return c.ffi_read(transform(again))
                        + #all
                        + c.ffi_read(by_name["one"] as Item)
                        + c.ffi_read(maybe as Item)
                end

                function run(): integer
                    return use_locally() + c.ffi_read(top) + #top_items
                end
            ]])
            assert.truthy(ok, err)

            local item_alias = ast[2]._type
            local items_alias = ast[3]._type
            assert.equal("Type.COwned", item_alias._tag)
            assert.is_false(item_alias.count)
            assert.equal("owned *ffi_item", types.tostring(item_alias))
            assert.equal("Type.COwned", items_alias._tag)
            assert.is_true(items_alias.count)
            assert.equal("owned ffi_item[]", types.tostring(items_alias))
        end)
    end)

    it("adjusts owners to compatible pointers without discarding const",
    function()
        with_header(declarations, function(header)
            local ok, err = check_with_header(header, [[
                local function accepted(): integer
                    local item: owned *c.ffi_item = c.ffi_item.new()
                    local items: owned c.ffi_item[] =
                        c.ffi_item.new_array(2)
                    local slot: owned *c.ffi_item_pointer =
                        c.ffi_item_pointer.new()
                    local mutable: *c.ffi_item = item
                    local immutable: const *c.ffi_item = item
                    local erased: *c.ffi_void = item
                    local optional: owned *c.ffi_item? = item
                    c.ffi_write(item)
                    c.ffi_write(items)
                    c.ffi_write(optional as owned *c.ffi_item)
                    return c.ffi_read(mutable)
                        + c.ffi_read(immutable)
                        + c.ffi_present(erased)
                        + c.ffi_pointer_present(slot)
                end
            ]])
            assert.truthy(ok, err)

            ok, err = check_with_header(header, [[
                local function bad()
                    local item: owned *c.ffi_const_item =
                        c.ffi_const_item.new()
                    local mutable: *c.ffi_item = item
                end
            ]])
            assert.falsy(ok)
            assert.match("types in declaration", err)

            ok, err = check_with_header(header, [[
                local function bad()
                    local item: owned *c.ffi_const_item =
                        c.ffi_const_item.new()
                    local erased: *c.ffi_void = item
                end
            ]])
            assert.falsy(ok)
            assert.match("types in declaration", err)

            ok, err = check_with_header(header, [[
                local function bad()
                    local item: owned *c.ffi_item? =
                        c.ffi_item.new()
                    c.ffi_write(item)
                end
            ]])
            assert.falsy(ok)
            assert.match("argument", err)

            ok, err = check_with_header(header, [[
                local function accepted()
                    local item: owned *c.ffi_const_item =
                        c.ffi_const_item.new()
                    local immutable: const *c.ffi_item = item
                    local erased: const *c.ffi_void = item
                    c.ffi_present(erased)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("coerces scalar and counted owners through boolean contexts",
    function()
        with_header(declarations, function(header)
            local ok, err, ast = check_with_header(header, [[
                local type Item = owned *c.ffi_item
                local type Items = owned c.ffi_item[]

                local function accepted(
                    item: Item?,
                    items: Items?
                ): boolean
                    local missing_item = not item
                    local missing_items = not items
                    return missing_item or missing_items or
                           (true and item) or (false or items)
                end
            ]])
            assert.truthy(ok, err)

            local item = ast[2]._type
            local items = ast[3]._type
            assert.truthy(types.coercion(item, types.Boolean()))
            assert.truthy(types.coercion(items, types.Boolean()))
            assert.truthy(types.coercion(
                types.Option(item), types.Boolean()))
            assert.truthy(types.coercion(
                types.Option(items), types.Boolean()))
        end)
    end)

    it("allows binary casts only from counted character owners", function()
        with_header(declarations, function(header)
            local ok, err = check_with_header(header, [[
                local function accepted(): integer
                    local plain: owned c.ffi_char[] =
                        c.ffi_char.new_array(3)
                    local signed: owned c.ffi_signed_char[] =
                        c.ffi_signed_char.new_array(3)
                    local unsigned: owned c.ffi_unsigned_char[] =
                        c.ffi_unsigned_char.new_array(3)
                    local alias: owned c.ffi_byte[] =
                        c.ffi_byte.new_array(3)
                    local a = plain as string
                    local b = signed as string
                    local cs = unsigned as string
                    local d = alias as string
                    local predicate = plain is string
                    local temporary =
                        c.ffi_char.new_array(0) as string
                    local result = #a + #b + #cs + #d + #temporary
                    if predicate then
                        result = result + 1
                    end
                    return result
                end
            ]])
            assert.truthy(ok, err)

            for _, declaration in ipairs({
                "local text = c.ffi_char.new() as string",
                "local text = c.ffi_int.new_array(2) as string",
            }) do
                ok, err = check_with_header(header,
                    "local function bad()\n" .. declaration .. "\nend")
                assert.falsy(ok)
                assert.match("cannot cast", err)
            end
        end)
    end)

    it("keeps owner-bearing Titan composites on the boxed value path",
    function()
        with_header(declarations, function(header)
            local ok, err = check_with_header(header, [[
                local type Item = owned *c.ffi_item
                local type Items = {Item}
                local type ByName = {string: Item}
                local type Transform = (Item) -> Item

                local function through_value(
                    items: Items,
                    by_name: ByName,
                    transform: Transform
                ): (Items, ByName, Transform)
                    local raw_items: value = items
                    local raw_by_name: value = by_name
                    local raw_transform: value = transform
                    local restored_items: Items = raw_items
                    local restored_by_name: ByName = raw_by_name
                    local restored_transform: Transform = raw_transform
                    return restored_items,
                        restored_by_name,
                        restored_transform
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("casts stable GC identities explicitly to C void pointers", function()
        with_header(declarations, function(header)
            local ok, err = check_with_header(header, [[
                local record Owner
                    local marker: integer
                end
                local type Alias = Owner

                local function accepted(
                    owner: Alias,
                    owners: {Owner},
                    by_name: {string: Owner},
                    callback: () -> (),
                    c_callback: c.ffi_callback_pointer
                ): boolean
                    local raw: *c.ffi_void =
                        owner as *c.ffi_void
                    local named: c.ffi_void_pointer =
                        owner as c.ffi_void_pointer
                    local readonly: const *c.ffi_void =
                        owner as const *c.ffi_void
                    local array_pointer =
                        owners as c.ffi_void_pointer
                    local map_pointer =
                        by_name as c.ffi_void_pointer
                    local function_pointer =
                        callback as c.ffi_void_pointer
                    local c_function_pointer =
                        c_callback as c.ffi_void_pointer
                    return owner is c.ffi_void_pointer and
                        owners is c.ffi_void_pointer and
                        by_name is c.ffi_void_pointer and
                        callback is c.ffi_void_pointer
                end
            ]])
            assert.truthy(ok, err)

            ok, err = check_with_header(header, [[
                local record Owner end
                local function bad(owner: Owner)
                    local raw: c.ffi_void_pointer = owner
                end
            ]])
            assert.falsy(ok)
            assert.match("types in declaration", err)

            ok, err = check_with_header(header, [[
                local record Owner end
                local function bad(owner: Owner)
                    local raw = owner as *c.ffi_item
                end
            ]])
            assert.falsy(ok)
            assert.match("cannot cast", err)

            for _, declaration in ipairs({
                "local raw: c.ffi_void_pointer = owner",
                "local raw: c.ffi_void_pointer = owners",
                "local raw: c.ffi_void_pointer = by_name",
                "local raw: c.ffi_void_pointer = callback",
            }) do
                ok, err = check_with_header(header, [[
                    local record Owner end
                    local function bad(
                        owner: Owner,
                        owners: {Owner},
                        by_name: {string: Owner},
                        callback: () -> ()
                    )
                        ]] .. declaration .. [[
                    end
                ]])
                assert.falsy(ok)
                assert.match("types in declaration", err)
            end

            ok, err = check_with_header(header, [[
                local record Owner end
                local function bad(owner: Owner?)
                    local pointer =
                        owner as c.ffi_void_pointer
                end
            ]])
            assert.falsy(ok)
            assert.match("cannot cast", err)
        end)
    end)

    it("rejects option bases that cannot round-trip through a TValue",
    function()
        with_header(declarations, function(header)
            for _, typename in ipairs({
                "c.ffi_item",
                "c.ffi_cell",
                "c.ffi_row",
                "c.ffi_callback_pointer",
            }) do
                local ok, err = check_with_header(header,
                    "local item: " .. typename .. "? = nil\n")
                assert.falsy(ok)
                assert.match("has no TValue representation", err,
                    typename)
            end
        end)
    end)

    it("requires an optional owner to be unwrapped before pointer decay",
    function()
        with_header(declarations, function(header)
            local ok, err = check_with_header(header, [[
                local function bad()
                    local item: owned *c.ffi_item? =
                        c.ffi_item.new()
                    local pointer: *c.ffi_item? = item
                end
            ]])
            assert.falsy(ok)
            assert.match("types in declaration", err)

            ok, err = check_with_header(header, [[
                local function accepted()
                    local item: owned *c.ffi_item? =
                        c.ffi_item.new()
                    local pointer: *c.ffi_item =
                        item as owned *c.ffi_item
                    c.ffi_write(pointer)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("rejects C allocation and pointer syntax over owner composites",
    function()
        with_header(declarations, function(header)
            local ok, err = check_with_header(header, [[
                local type Item = owned *c.ffi_item
                local type Items = {Item}
                local type Bad = owned *Items
            ]])
            assert.falsy(ok)
            assert.match("C FFI object type", err)

            ok, err = check_with_header(header, [[
                local type Item = owned *c.ffi_item
                local type Bad = *Item
            ]])
            assert.falsy(ok)
            assert.match("C pointer type can only point to a C FFI type",
                err)
        end)
    end)

    for _, rejected in ipairs({
        {
            name = "Titan values",
            declaration = "local item: owned *integer = nil",
            diagnostic = "C FFI object type",
        },
        {
            name = "void",
            declaration = "local item: owned *c.ffi_void = nil",
            diagnostic = "void",
        },
        {
            name = "incomplete aggregates",
            declaration = "local item: owned *c.ffi_incomplete = nil",
            diagnostic = "incomplete",
        },
        {
            name = "C array typedefs",
            declaration = "local item: owned *c.ffi_row = nil",
            diagnostic = "array typedef",
        },
        {
            name = "flexible-array-member aggregates",
            declaration = "local item: owned *c.ffi_flexible = nil",
            diagnostic = "flexible array member",
        },
        {
            name = "nested owners",
            declaration = "local item: owned *owned *c.ffi_item = nil",
            diagnostic = "owned",
        },
    }) do
        it("rejects " .. rejected.name .. " as owner payloads", function()
            with_header(declarations, function(header)
                local ok, err = check_with_header(header,
                    "local function bad()\n"
                    .. rejected.declaration .. "\nend")
                assert.falsy(ok)
                assert.match(rejected.diagnostic, err)
            end)
        end)
    end

    for _, public_shape in ipairs({
        "type Public = owned *c.ffi_item",
        "type Public = owned *c.ffi_item?",
        "type Public = {owned *c.ffi_item}",
        "type Public = {string: owned *c.ffi_item}",
        "type Public = (owned *c.ffi_item) -> owned *c.ffi_item",
        "local type Private = owned *c.ffi_item\n"
            .. "type Public = Private",
        "state: owned *c.ffi_item = c.ffi_item.new()",
        "function expose(item: owned *c.ffi_item): integer return 0 end",
        "record Public item: owned *c.ffi_item end",
    }) do
        it("rejects an exported owner composed as " .. public_shape,
        function()
            with_header(declarations, function(header)
                local ok, err = check_with_header(header, public_shape)
                assert.falsy(ok)
                assert.match("cannot export C FFI type", err)
            end)
        end)
    end
end)
