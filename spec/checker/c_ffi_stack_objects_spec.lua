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

local function check_with_header(header, body)
    return h.run_checker(
        'local c = foreign import "' .. header .. '"\n' .. body,
        probe_session)
end

describe("automatic C objects and fixed arrays", function()
    setup(function()
        probe_session = h.new_checker_probe_session()
    end)

    teardown(function()
        h.close_checker_probe_session(probe_session)
        probe_session = nil
    end)

    local objects = [[
        typedef int ffi_int;
        typedef int *ffi_int_pointer;
        typedef void ffi_void;
        typedef int ffi_callback(void);

        typedef struct ffi_point {
            int x;
            int y;
        } ffi_point;

        typedef union ffi_cell {
            int count;
            double number;
        } ffi_cell;

        struct ffi_tag_point {
            int number;
        };

        union ffi_tag_cell {
            int integer_value;
            double number;
        };

        struct ffi_opaque;
        typedef struct ffi_opaque *ffi_opaque_pointer;

        typedef int ffi_row[2];
        typedef int ffi_vector[3];
        typedef int ffi_unsized[];

        typedef struct ffi_flexible {
            int length;
            unsigned char bytes[];
        } ffi_flexible;

        static ffi_vector ffi_global_vector;
    ]]

    it("marks exactly the admitted zero-initialized object declarations",
    function()
        with_header(objects, function(header)
            local ok, err, ast = check_with_header(header, [[
                local function accepted()
                    local point: c.ffi_point
                    local cell: c.ffi_cell
                    local tag_point: c.ffi_tag_point
                    local tag_cell: c.ffi_tag_cell
                    local integers: c.ffi_int[3]
                    local pointers: c.ffi_opaque_pointer[2]
                    local matrix: c.ffi_row[4]
                    local vector: c.ffi_vector

                    point.x = 1
                    cell.count = 2
                    tag_point.number = 3
                    tag_cell.integer_value = 4
                    integers[0] = 5
                    pointers[0] = nil
                    local matrix_length = #matrix
                    vector[0] = 7
                end
            ]])
            assert.truthy(ok, err)

            local stats = ast[2].block.stats
            for i = 1, 8 do
                assert.is_true(stats[i]._c_zero_init)
                assert.is_true(stats[i].decls[1]._c_zero_init)
                assert.is_true(stats[i].decls[1]._c_automatic_object)
            end
            assert.equal("Type.CStruct",
                types.resolve_c_typedef(
                    stats[1].decls[1]._type)._tag)
            assert.equal("Type.CUnion",
                types.resolve_c_typedef(
                    stats[2].decls[1]._type)._tag)
            assert.equal("Type.CArray",
                stats[5].decls[1]._type._tag)
            assert.equal(3, stats[5].decls[1]._type.len)
            assert.equal("Type.CTypedef",
                stats[7].decls[1]._type.elem._tag)
            assert.equal("Type.CArray",
                stats[8].decls[1]._type.target._tag)
        end)
    end)

    for _, rejected in ipairs({
        {
            name = "standalone scalar",
            declaration = "local object: c.ffi_int",
            diagnostic = "complete C struct, union, or fixed array",
        },
        {
            name = "standalone pointer",
            declaration = "local object: c.ffi_int_pointer",
            diagnostic = "complete C struct, union, or fixed array",
        },
        {
            name = "void",
            declaration = "local object: c.ffi_void",
            diagnostic = "complete C struct, union, or fixed array",
        },
        {
            name = "incomplete struct",
            declaration = "local object: c.ffi_opaque",
            diagnostic = "incomplete or not yet visible",
        },
        {
            name = "flexible-array-member struct",
            declaration = "local object: c.ffi_flexible",
            diagnostic = "flexible array member",
        },
        {
            name = "unsized imported array",
            declaration = "local object: c.ffi_unsized",
            diagnostic = "positive compile%-time integer literal extent",
        },
        {
            name = "zero source extent",
            declaration = "local object: c.ffi_int[0]",
            diagnostic = "positive compile%-time integer literal extent",
        },
        {
            name = "negative source extent",
            declaration = "local object: c.ffi_int[-2]",
            diagnostic = "positive compile%-time integer literal extent",
        },
        {
            name = "array of incomplete objects",
            declaration = "local object: c.ffi_opaque[2]",
            diagnostic = "incomplete or not yet visible",
        },
    }) do
        it("rejects " .. rejected.name, function()
            with_header(objects, function(header)
                local ok, err = check_with_header(header,
                    "local function bad()\n"
                    .. rejected.declaration .. "\nend")
                assert.falsy(ok)
                assert.match(rejected.diagnostic, err)
            end)
        end)
    end

    it("rejects a Titan object in the no-RHS form", function()
        local ok, err = h.run_checker_modules({
            provider = [[
                record Item
                    number: integer
                end
            ]],
            consumer = [[
                local provider = import "provider"
                local function bad()
                    local item: provider.Item
                end
            ]],
        }, "consumer")
        assert.falsy(ok)
        assert.match("complete C struct, union, or fixed array", err)
    end)

    it("rejects transitively GC-bearing C aggregate storage", function()
        with_header([[
            typedef struct TValue {
                unsigned long bits;
            } TValue;
            typedef struct Udata Udata;

            typedef struct ffi_value_holder {
                TValue value;
            } ffi_value_holder;

            typedef struct ffi_owner_holder {
                Udata *owner;
            } ffi_owner_holder;

            typedef TValue ffi_values[2];
        ]], function(header)
            for _, declaration in ipairs({
                "local object: c.TValue",
                "local object: c.ffi_value_holder",
                "local object: c.ffi_owner_holder",
                "local object: c.ffi_values",
                "local object: c.TValue[2]",
            }) do
                local ok, err = check_with_header(header,
                    "local function bad()\n"
                    .. declaration .. "\nend")
                assert.falsy(ok)
                assert.match("GC%-bearing FFI storage", err)
                assert.match("do not trace", err)
            end
        end)
    end)

    it("rejects whole-array copies, assignments, and returns", function()
        with_header(objects, function(header)
            for _, body in ipairs({
                [[
                    local function bad()
                        local source: c.ffi_vector
                        local copy: c.ffi_vector = source
                    end
                ]],
                [[
                    local function bad()
                        local source: c.ffi_vector
                        local copy = source
                    end
                ]],
                [[
                    local function bad()
                        local source: c.ffi_vector
                        local target: c.ffi_vector
                        target = source
                    end
                ]],
                [[
                    local function bad(): c.ffi_vector
                        return c.ffi_global_vector
                    end
                ]],
            }) do
                local ok, err = check_with_header(header, body)
                assert.falsy(ok)
                assert.match("whole C array", err)
            end
        end)
    end)

    it("rejects aggregate capture but permits pointer capture", function()
        with_header(objects .. [[
            static ffi_point ffi_make_point(void) {
                ffi_point point = { 9, 0 };
                return point;
            }
        ]], function(header)
            local ok, err = check_with_header(header, [[
                local function bad(): integer
                    local point: c.ffi_point
                    local read = function(): integer
                        return point.x as integer
                    end
                    return read()
                end
            ]])
            assert.falsy(ok)
            assert.match("cannot capture C aggregate variable 'point'", err)

            ok, err = check_with_header(header, [[
                local function accepted(): integer
                    local point: c.ffi_point = c.ffi_make_point()
                    local pointer: *c.ffi_point = point
                    local read = function(): integer
                        return pointer.x as integer
                    end
                    return read()
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("keeps owned allocation constructors unchanged", function()
        with_header(objects, function(header)
            local ok, err = check_with_header(header, [[
                local function accepted()
                    local point = c.ffi_point.new()
                    local points = c.ffi_point.new_array(3)
                    point.x = 1
                    points[0].x = 2
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("records only direct mutable-address call roots", function()
        with_header(objects .. [[
            typedef struct ffi_other_point {
                int x;
                int y;
            } ffi_other_point;

            static void ffi_fill_point(ffi_point *point) {
                point->x = 1;
            }
            static void ffi_fill_other_point(ffi_other_point *point) {
                point->x = 3;
            }
            static void ffi_fill_vector(int *values) {
                values[0] = 2;
            }
            static void ffi_read_point(const ffi_point *point) {
                (void)point;
            }
        ]], function(header)
            local ok, err, ast = check_with_header(header, [[
                local function calls()
                    local point: c.ffi_point
                    local vector: c.ffi_vector
                    local pointer: *c.ffi_point = point
                    c.ffi_fill_point(point)
                    c.ffi_fill_vector(vector)
                    c.ffi_fill_point(pointer)
                    c.ffi_read_point(point)
                    c.ffi_fill_other_point(point)
                    c.ffi_fill_other_point(
                        point as *c.ffi_point)
                end
            ]])
            assert.truthy(ok, err)

            local stats = ast[2].block.stats
            local point = stats[1].decls[1]
            local vector = stats[2].decls[1]
            assert.same({point},
                stats[4].callexp._c_mutated_decls)
            assert.same({vector},
                stats[5].callexp._c_mutated_decls)
            assert.is_false(
                stats[6].callexp._c_mutated_decls)
            assert.is_false(
                stats[7].callexp._c_mutated_decls)
            assert.same({point},
                stats[8].callexp._c_mutated_decls)
            assert.equal("address_then_unsafe_object_pointer",
                stats[8].callexp.args.args[1]._c_conversion.kind)
            assert.same({point},
                stats[9].callexp._c_mutated_decls)
            local nested = stats[9].callexp.args.args[1]
            assert.equal("unsafe_object_pointer",
                nested._c_conversion.kind)
            assert.equal("Ast.ExpCast", nested.exp._tag)
            assert.equal("Ast.ExpVar", nested.exp.exp._tag)
        end)
    end)

    it("records direct mutable-address roots in C variadic tails", function()
        with_header(objects .. [[
            typedef void (*ffi_variadic_fill_fn)(int tag, ...);
            extern void ffi_variadic_fill(int tag, ...);
            extern ffi_variadic_fill_fn ffi_get_variadic_fill(void);
        ]], function(header)
            local ok, err, ast = check_with_header(header, [[
                local function calls()
                    local direct: c.ffi_point
                    local indirect: c.ffi_point
                    c.ffi_variadic_fill(
                        1, direct as *c.ffi_point)
                    local fill = c.ffi_get_variadic_fill()
                    fill(2, indirect as *c.ffi_point)
                end
            ]])
            assert.truthy(ok, err)

            local stats = ast[2].block.stats
            local direct = stats[1].decls[1]
            local indirect = stats[2].decls[1]
            assert.same({direct},
                stats[3].callexp._c_mutated_decls)
            assert.same({indirect},
                stats[5].callexp._c_mutated_decls)
        end)
    end)
end)
