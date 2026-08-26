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

    it("selects automatic, owned, and borrowed allocation storage from the local sink",
    function()
        with_header(objects, function(header)
            local ok, err, ast = check_with_header(header, [[
                local function allocations(count: integer)
                    local inferred = c.ffi_point.new()
                    local exact: c.ffi_point = c.ffi_point.new()
                    local cell = c.ffi_cell.new()
                    local owner: owned *c.ffi_point = c.ffi_point.new()
                    local borrowed: *c.ffi_point = c.ffi_point.new()

                    local literal = c.ffi_point.new_array(3)
                    local dynamic = c.ffi_point.new_array(count)
                    local fixed: c.ffi_point[3] =
                        c.ffi_point.new_array(3)
                    local array_owner: owned c.ffi_point[] =
                        c.ffi_point.new_array(3)
                    local literal_view: c.ffi_point[] =
                        c.ffi_point.new_array(3)
                    local dynamic_view: c.ffi_point[] =
                        c.ffi_point.new_array(count)
                    local zero = c.ffi_point.new_array(0)
                end
            ]])
            assert.truthy(ok, err)

            local stats = ast[2].block.stats
            local function decl(index)
                return stats[index].decls[1]
            end
            local function plan(index)
                return decl(index)._c_allocation_plan
                    or stats[index].exps[1]._c_allocation_plan
            end

            assert.equal("automatic_object", plan(1).storage)
            assert.equal("Type.CStruct",
                types.resolve_c_typedef(decl(1)._type)._tag)
            assert.equal("automatic_object", plan(2).storage)
            assert.equal("automatic_object", plan(3).storage)
            assert.equal("Type.CUnion",
                types.resolve_c_typedef(decl(3)._type)._tag)

            assert.equal("owned", plan(4).storage)
            assert.equal("Type.COwned", decl(4)._type._tag)
            assert.is_false(decl(4)._type.count)
            assert.equal("owned_borrow", plan(5).storage)
            assert.equal("Type.CPointer", decl(5)._type._tag)

            assert.equal("automatic_array", plan(6).storage)
            assert.equal("Type.CArray", decl(6)._type._tag)
            assert.equal(3, decl(6)._type.len)
            assert.equal(3, plan(6).array_count_literal)

            assert.equal("owned", plan(7).storage)
            assert.equal("Type.COwned", decl(7)._type._tag)
            assert.is_true(decl(7)._type.count)
            assert.equal("automatic_array", plan(8).storage)
            assert.equal(3, decl(8)._type.len)
            assert.equal("owned", plan(9).storage)
            assert.equal("automatic_array_borrow", plan(10).storage)
            assert.equal("Type.CPointer", decl(10)._type._tag)
            assert.equal("owned_borrow", plan(11).storage)
            assert.equal("Type.CPointer", decl(11)._type._tag)

            -- A zero count is not a positive C fixed-array extent, so inferred
            -- allocation retains the counted owner representation.
            assert.equal("owned", plan(12).storage)
            assert.equal("Type.COwned", decl(12)._type._tag)
            assert.is_true(decl(12)._type.count)
        end)
    end)

    it("diagnoses invalid automatic-allocation targets and counts", function()
        with_header(objects, function(header)
            local rejected = {
                {
                    [[local function bad()
                          local object = c.ffi_opaque.new()
                      end]],
                    "cannot allocate incomplete C struct type",
                },
                {
                    [[local function bad()
                          local object = c.ffi_row.new()
                      end]],
                    "cannot allocate C array typedefs",
                },
                {
                    [[local function bad(count: integer)
                          local objects = c.ffi_row.new_array(count)
                      end]],
                    "cannot allocate C array typedefs as owned storage",
                },
                {
                    [[local function bad(count: integer)
                          local objects: c.ffi_point[3] =
                              c.ffi_point.new_array(count)
                      end]],
                    "requires a compile%-time integer literal allocation count",
                },
                {
                    [[local function bad()
                          local objects: c.ffi_point[3] =
                              c.ffi_point.new_array(2)
                      end]],
                    "has extent 3 but '.new_array' allocates 2 element",
                },
                {
                    [[local function bad()
                          local objects: c.ffi_point[0] =
                              c.ffi_point.new_array(0)
                      end]],
                    "requires a positive extent",
                },
                {
                    [[local function bad()
                          local object: c.ffi_int = c.ffi_int.new()
                      end]],
                    "types in declaration",
                },
            }
            for _, case in ipairs(rejected) do
                local ok, err = check_with_header(header, case[1])
                assert.falsy(ok)
                assert.match(case[2], err)
            end
        end)
    end)

    it("rejects transitively GC-bearing automatic allocation storage", function()
        with_header([[
            typedef struct TValue {
                int placeholder;
            } TValue;
            typedef struct Udata Udata;

            typedef struct ffi_value_holder {
                TValue value;
            } ffi_value_holder;

            typedef struct ffi_owner_holder {
                Udata *owner;
            } ffi_owner_holder;
        ]], function(header)
            local ok, err = check_with_header(header, [[
                local function bad()
                    local inferred = c.ffi_value_holder.new()
                    local exact: c.ffi_value_holder =
                        c.ffi_value_holder.new()
                    local owner_pointer = c.ffi_owner_holder.new()
                    local inferred_array =
                        c.ffi_value_holder.new_array(2)
                    local exact_array: c.ffi_value_holder[2] =
                        c.ffi_value_holder.new_array(2)
                end
            ]])
            assert.falsy(ok)
            local _, bearing = err:gsub("GC%-bearing FFI storage", "")
            local _, tracing = err:gsub("do not trace", "")
            assert.equal(5, bearing)
            assert.equal(5, tracing)
        end)
    end)

    it("rejects whole-array copies, assignments, and returns", function()
        with_header(objects, function(header)
            for _, body in ipairs({
                [[
                    local function bad()
                        local source = c.ffi_int.new_array(3)
                        local copy: c.ffi_int[3] = source
                    end
                ]],
                [[
                    local function bad()
                        local source = c.ffi_int.new_array(3)
                        local copy = source
                    end
                ]],
                [[
                    local function bad()
                        local source = c.ffi_int.new_array(3)
                        local target = c.ffi_int.new_array(3)
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
                    local point = c.ffi_point.new()
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

    it("treats T[] constructor targets as uncounted borrowed views", function()
        with_header(objects, function(header)
            local ok, err, ast = check_with_header(header, [[
                local function accepted(count: integer)
                    local literal: c.ffi_point[] =
                        c.ffi_point.new_array(3)
                    local dynamic: c.ffi_point[] =
                        c.ffi_point.new_array(count)
                    literal[0].x = 1
                    dynamic[0].x = 2
                end
            ]])
            assert.truthy(ok, err)

            local literal = ast[2].block.stats[1].decls[1]
            local dynamic = ast[2].block.stats[2].decls[1]
            assert.equal("Type.CPointer", literal._type._tag)
            assert.equal("automatic_array_borrow",
                literal._c_allocation_plan.storage)
            assert.equal("Type.CPointer", dynamic._type._tag)
            assert.equal("owned_borrow",
                dynamic._c_allocation_plan.storage)

            for _, allocation in ipairs({
                "c.ffi_point.new_array(3)",
                "c.ffi_point.new_array(count)",
            }) do
                ok, err = check_with_header(header, [[
                    local function bad(count: integer)
                        local view: c.ffi_point[] = ]] .. allocation .. [[
                        local length = #view
                    end
                ]])
                assert.falsy(ok)
                assert.match("trying to take the length", err)
            end
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
                    local point = c.ffi_point.new()
                    local vector = c.ffi_int.new_array(3)
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
                    local direct = c.ffi_point.new()
                    local indirect = c.ffi_point.new()
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
