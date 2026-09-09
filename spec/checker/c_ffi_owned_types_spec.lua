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

    typedef struct ffi_wide_flexible {
        int tag;
        int items[];
    } ffi_wide_flexible;

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
        "foreign import \"" .. header .. '"\n' .. body,
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
        with_header([[
            typedef struct ffi_item {
                int number;
            } ffi_item;
            static int ffi_read(const ffi_item *item) {
                return item->number;
            }
        ]], function(header)
            local ok, err, ast = check_with_header(header, [[
                local type Item = owned *ffi.ffi_item
                local type Items = owned ffi.ffi_item[]
                local type Transform = (Item) -> Item

                record PublicHolder
                    local item: Item
                    local items: Items
                    local transform: Transform
                end

                local function use_locally(): integer
                    local one: Item = ffi.ffi_item.new()
                    local many: Items = ffi.ffi_item.new_array(3)
                    local transform: Transform =
                        function(item: Item): Item
                            item.number = 17
                            return item
                        end
                    local holder = PublicHolder.new(one, many, transform)
                    return ffi.ffi_read(holder.transform(holder.item))
                        + #holder.items
                end
            ]])
            assert.truthy(ok, err)

            local item_alias = ast[2]._type
            local items_alias = ast[3]._type
            assert.equal("Type.COwned", item_alias._tag)
            assert.is_false(item_alias.count)
            assert.equal("owned *test.ffi.ffi_item",
                types.tostring(item_alias))
            assert.equal("Type.COwned", items_alias._tag)
            assert.is_true(items_alias.count)
            assert.equal("owned test.ffi.ffi_item[]",
                types.tostring(items_alias))
        end)
    end)

    it("adjusts owners to compatible pointers without discarding const",
    function()
        with_header(declarations, function(header)
            local ok, err = check_with_header(header, [[
                local function accepted(): integer
                    local item: owned *ffi.ffi_item = ffi.ffi_item.new()
                    local items: owned ffi.ffi_item[] =
                        ffi.ffi_item.new_array(2)
                    local slot: owned *ffi.ffi_item_pointer =
                        ffi.ffi_item_pointer.new()
                    local mutable: *ffi.ffi_item = item
                    local immutable: const *ffi.ffi_item = item
                    local erased: *ffi.ffi_void = item
                    local optional: owned *ffi.ffi_item? = item
                    ffi.ffi_write(item)
                    ffi.ffi_write(items)
                    ffi.ffi_write(optional as owned *ffi.ffi_item)
                    return ffi.ffi_read(mutable)
                        + ffi.ffi_read(immutable)
                        + ffi.ffi_present(erased)
                        + ffi.ffi_pointer_present(slot)
                end
            ]])
            assert.truthy(ok, err)

            ok, err = check_with_header(header, [[
                local function bad()
                    local item: owned *ffi.ffi_const_item =
                        ffi.ffi_const_item.new()
                    local mutable: *ffi.ffi_item = item
                end
            ]])
            assert.falsy(ok)
            assert.match("types in declaration", err)

            ok, err = check_with_header(header, [[
                local function bad()
                    local item: owned *ffi.ffi_const_item =
                        ffi.ffi_const_item.new()
                    local erased: *ffi.ffi_void = item
                end
            ]])
            assert.falsy(ok)
            assert.match("types in declaration", err)

            ok, err = check_with_header(header, [[
                local function bad()
                    local item: owned *ffi.ffi_item? =
                        ffi.ffi_item.new()
                    ffi.ffi_write(item)
                end
            ]])
            assert.falsy(ok)
            assert.match("argument", err)

            ok, err = check_with_header(header, [[
                local function accepted()
                    local item: owned *ffi.ffi_const_item =
                        ffi.ffi_const_item.new()
                    local immutable: const *ffi.ffi_item = item
                    local erased: const *ffi.ffi_void = item
                    ffi.ffi_present(erased)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("coerces scalar and counted owners through boolean contexts",
    function()
        with_header(declarations, function(header)
            local ok, err, ast = check_with_header(header, [[
                local type Item = owned *ffi.ffi_item
                local type Items = owned ffi.ffi_item[]

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
                    local plain: owned ffi.ffi_char[] =
                        ffi.ffi_char.new_array(3)
                    local signed: owned ffi.ffi_signed_char[] =
                        ffi.ffi_signed_char.new_array(3)
                    local unsigned: owned ffi.ffi_unsigned_char[] =
                        ffi.ffi_unsigned_char.new_array(3)
                    local alias: owned ffi.ffi_byte[] =
                        ffi.ffi_byte.new_array(3)
                    local a = plain as string
                    local b = signed as string
                    local cs = unsigned as string
                    local d = alias as string
                    local predicate = plain is string
                    local temporary =
                        ffi.ffi_char.new_array(0) as string
                    local result = #a + #b + #cs + #d + #temporary
                    if predicate then
                        result = result + 1
                    end
                    return result
                end
            ]])
            assert.truthy(ok, err)

            for _, declaration in ipairs({
                "local text = ffi.ffi_char.new() as string",
                "local text = ffi.ffi_int.new_array(2) as string",
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
                local type Item = owned *ffi.ffi_item
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
                    c_callback: ffi.ffi_callback_pointer
                ): boolean
                    local raw: *ffi.ffi_void =
                        owner as *ffi.ffi_void
                    local named: ffi.ffi_void_pointer =
                        owner as ffi.ffi_void_pointer
                    local readonly: const *ffi.ffi_void =
                        owner as const *ffi.ffi_void
                    local array_pointer =
                        owners as ffi.ffi_void_pointer
                    local map_pointer =
                        by_name as ffi.ffi_void_pointer
                    local function_pointer =
                        callback as ffi.ffi_void_pointer
                    local c_function_pointer =
                        c_callback as ffi.ffi_void_pointer
                    return owner is ffi.ffi_void_pointer and
                        owners is ffi.ffi_void_pointer and
                        by_name is ffi.ffi_void_pointer and
                        callback is ffi.ffi_void_pointer
                end
            ]])
            assert.truthy(ok, err)

            ok, err = check_with_header(header, [[
                local record Owner end
                local function bad(owner: Owner)
                    local raw: ffi.ffi_void_pointer = owner
                end
            ]])
            assert.falsy(ok)
            assert.match("types in declaration", err)

            ok, err = check_with_header(header, [[
                local record Owner end
                local function bad(owner: Owner)
                    local raw = owner as *ffi.ffi_item
                end
            ]])
            assert.falsy(ok)
            assert.match("cannot cast", err)

            for _, declaration in ipairs({
                "local raw: ffi.ffi_void_pointer = owner",
                "local raw: ffi.ffi_void_pointer = owners",
                "local raw: ffi.ffi_void_pointer = by_name",
                "local raw: ffi.ffi_void_pointer = callback",
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
                        owner as ffi.ffi_void_pointer
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
                "ffi.ffi_item",
                "ffi.ffi_cell",
                "ffi.ffi_row",
            }) do
                local ok, err = check_with_header(header,
                    "local item: " .. typename .. "? = nil\n")
                assert.falsy(ok)
                assert.match("has no TValue representation", err,
                    typename)
            end
        end)
    end)

    it("admits optional C function pointers as boxed values", function()
        with_header(declarations, function(header)
            local ok, err = check_with_header(header, [[
                local callback: ffi.ffi_callback_pointer? = nil
                local function box(pointer: ffi.ffi_callback_pointer): value
                    local optional: ffi.ffi_callback_pointer? = pointer
                    return optional
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("requires an optional owner to be unwrapped before pointer decay",
    function()
        with_header(declarations, function(header)
            local ok, err = check_with_header(header, [[
                local function bad()
                    local item: owned *ffi.ffi_item? =
                        ffi.ffi_item.new()
                    local pointer: *ffi.ffi_item? = item
                end
            ]])
            assert.falsy(ok)
            assert.match("types in declaration", err)

            ok, err = check_with_header(header, [[
                local function accepted()
                    local item: owned *ffi.ffi_item? =
                        ffi.ffi_item.new()
                    local pointer: *ffi.ffi_item =
                        item as owned *ffi.ffi_item
                    ffi.ffi_write(pointer)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("rejects C allocation and pointer syntax over owner composites",
    function()
        with_header(declarations, function(header)
            local ok, err = check_with_header(header, [[
                local type Item = owned *ffi.ffi_item
                local type Items = {Item}
                local type Bad = owned *Items
            ]])
            assert.falsy(ok)
            assert.match("C FFI object type", err)

            ok, err = check_with_header(header, [[
                local type Item = owned *ffi.ffi_item
                local type Bad = *Item
            ]])
            assert.falsy(ok)
            assert.match("C pointer type can only point to a C FFI type",
                err)
        end)
    end)

    it("allocates flexible-array-member structs with count provenance",
    function()
        with_header(declarations, function(header)
            local ok, err, ast = check_with_header(header, [[
                local function allocations(count: integer)
                    local automatic = ffi.ffi_flexible.new(4)
                    local owner: owned *ffi.ffi_flexible =
                        ffi.ffi_flexible.new(count)
                    local dynamic = ffi.ffi_flexible.new(count)

                    automatic.bytes[3] = 1
                    owner.bytes[0] = 2
                    local automatic_count = #automatic.bytes
                    local owner_count = #owner.bytes
                end
            ]])
            assert.truthy(ok, err)

            local stats = ast[2].block.stats
            local automatic = stats[1].decls[1]
            local owner = stats[2].decls[1]
            local dynamic = stats[3].decls[1]
            assert.equal("automatic_fam",
                automatic._c_allocation_plan.storage)
            assert.equal(4,
                automatic._c_allocation_plan.fam_count_literal)
            assert.equal("Type.CStruct",
                types.resolve_c_typedef(automatic._type)._tag)

            assert.equal("owned",
                stats[2].exps[1]._c_allocation_plan.storage)
            assert.equal("Type.COwned", owner._type._tag)
            assert.equal("owned",
                stats[3].exps[1]._c_allocation_plan.storage)
            assert.equal("Type.COwned", dynamic._type._tag)

            local automatic_length = stats[6].exps[1]
            local owner_length = stats[7].exps[1]
            assert.equal("automatic", automatic_length._c_fam_access.kind)
            assert.equal(4, automatic_length._c_fam_access.count)
            assert.same(automatic,
                automatic_length._c_fam_access.root)
            assert.equal("owned", owner_length._c_fam_access.kind)
        end)
    end)

    it("rejects overflowing automatic flexible-array extents", function()
        with_header(declarations, function(header)
            local ok, err = check_with_header(header, [[
                local function bad()
                    local item = ffi.ffi_wide_flexible.new(4611686018427387904)
                end
            ]])
            assert.falsy(ok)
            assert.match("flexible%-array field '.-ffi_wide_flexible%.items'", err)
            assert.match("count 4611686018427387904 exceeds SIZE_MAX", err)

            ok, err = check_with_header(header, [[
                local function keep_owned()
                    local item: owned *ffi.ffi_flexible =
                        ffi.ffi_flexible.new(4611686018427387904)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("restricts FAM constructors and erases counts at raw-pointer views",
    function()
        with_header(declarations, function(header)
            local rejected = {
                {
                    [[local function bad()
                          local item = ffi.ffi_flexible.new()
                      end]],
                    "expects 1",
                },
                {
                    [[local function bad()
                          local items = ffi.ffi_flexible.new_array(2)
                      end]],
                    "'.new_array' is unavailable.*flexible array member",
                },
                {
                    [[local function bad(count: integer)
                          local item: ffi.ffi_flexible =
                              ffi.ffi_flexible.new(count)
                      end]],
                    "types in declaration",
                },
                {
                    [[local function bad(count: integer)
                          local owner: owned *ffi.ffi_flexible =
                              ffi.ffi_flexible.new(count)
                          local raw: *ffi.ffi_flexible = owner
                          local length = #raw.bytes
                      end]],
                    "trying to take the length",
                },
                {
                    [[local function bad(count: integer)
                          local raw: *ffi.ffi_flexible =
                              ffi.ffi_flexible.new(count)
                          local length = #raw.bytes
                      end]],
                    "trying to take the length",
                },
            }
            for _, case in ipairs(rejected) do
                local ok, err = check_with_header(header, case[1])
                assert.falsy(ok)
                assert.match(case[2], err)
            end
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
            declaration = "local item: owned *ffi.ffi_void = nil",
            diagnostic = "void",
        },
        {
            name = "incomplete aggregates",
            declaration = "local item: owned *ffi.ffi_incomplete = nil",
            diagnostic = "incomplete",
        },
        {
            name = "C array typedefs",
            declaration = "local item: owned *ffi.ffi_row = nil",
            diagnostic = "array typedef",
        },
        {
            name = "nested owners",
            declaration = "local item: owned *owned *ffi.ffi_item = nil",
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
        "type Public = owned *ffi.ffi_item",
        "type Public = owned *ffi.ffi_item?",
        "type Public = {owned *ffi.ffi_item}",
        "type Public = {string: owned *ffi.ffi_item}",
        "type Public = (owned *ffi.ffi_item) -> owned *ffi.ffi_item",
        "local type Private = owned *ffi.ffi_item\n"
            .. "type Public = Private",
        "state: owned *ffi.ffi_item = ffi.ffi_item.new()",
        "function expose(item: owned *ffi.ffi_item): integer return 0 end",
        "record Public item: owned *ffi.ffi_item end",
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
