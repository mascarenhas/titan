local h = require "spec.support.helpers"
local driver = require "titan-compiler.driver"

local MODULE = "ffi_stack_objects"

local function clean_module(name)
    for _, suffix in ipairs({
        ".c", ".o", ".so", ".a", ".lua", ".titan.h",
        "__entrypoint.c", "__entrypoint.o",
    }) do
        os.remove(name .. suffix)
    end
    os.execute("rm -rf " .. name .. ".so.dSYM")
    os.execute("rm -rf " .. name .. ".dSYM")
end

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

describe("automatic C object code generation", function()
    local saved_cflags

    before_each(function ()
        saved_cflags = driver.CFLAGS
    end)

    after_each(function()
        driver.CFLAGS = saved_cflags
        if not h.verbose then clean_module(MODULE) end
    end)

    local declarations = [[
        #include <string.h>

        typedef int ffi_int;

        typedef struct ffi_point {
            int x;
            int y;
        } ffi_point;

        typedef struct ffi_other_point {
            int x;
            int y;
        } ffi_other_point;

        typedef union ffi_cell {
            int count;
            double number;
        } ffi_cell;

        struct ffi_tag_point {
            int count;
        };

        union ffi_tag_cell {
            int count;
            double number;
        };

        typedef struct ffi_anonymous_holder {
            union {
                int count;
                double number;
            } cell;
            struct {
                int number;
            } items[2];
        } ffi_anonymous_holder;

        typedef ffi_int ffi_row[2];

        static int ffi_all_zero(
            ffi_point *point,
            ffi_cell *cell,
            ffi_int *values,
            ffi_row *matrix,
            struct ffi_tag_point *tag_point,
            union ffi_tag_cell *tag_cell
        ) {
            return point->x == 0 && point->y == 0
                && cell->count == 0
                && values[0] == 0 && values[1] == 0 && values[2] == 0
                && matrix[0][0] == 0 && matrix[0][1] == 0
                && matrix[1][0] == 0 && matrix[1][1] == 0
                && tag_point->count == 0 && tag_cell->count == 0;
        }

        static void ffi_fill_point(ffi_point *point) {
            point->x = 17;
            point->y = 23;
        }

        static void ffi_fill_values(ffi_int *values) {
            values[0] = 31;
            values[1] = 37;
            values[2] = 41;
        }

        static void ffi_fill_other_point(ffi_other_point *point) {
            const int fields[2] = {67, 71};
            memcpy(point, fields, sizeof(fields));
        }

        static ffi_point ffi_make_point(int x, int y) {
            ffi_point point = { x, y };
            return point;
        }

        static int ffi_read_anonymous(ffi_anonymous_holder *holder) {
            return holder->cell.count + holder->items[1].number;
        }
    ]]

    it("emits exact zero-initialized declarations and distinct address rules",
    function()
        with_header(declarations, function(header)
            local source = [[
                foreign import "]] .. header .. [["

                anonymous_seen: integer = 0

                local function anonymous_index(): integer
                    anonymous_seen = anonymous_seen * 10 + 1
                    return 1
                end

                local function anonymous_rhs(): integer
                    anonymous_seen = anonymous_seen * 10 + 2
                    return 17
                end

                function all_zero(): boolean
                    local point = ffi.ffi_point.new()
                    local cell = ffi.ffi_cell.new()
                    local values: ffi.ffi_int[3] = ffi.ffi_int.new_array(3)
                    local matrix: ffi.ffi_row[2] = ffi.ffi_row.new_array(2)
                    local tag_point = ffi.ffi_tag_point.new()
                    local tag_cell = ffi.ffi_tag_cell.new()
                    return ffi.ffi_all_zero(
                        point, cell, values, matrix, tag_point, tag_cell
                    ) ~= 0
                end

                function direct_fill(): integer
                    local point = ffi.ffi_point.new()
                    local values: ffi.ffi_int[3] = ffi.ffi_int.new_array(3)
                    ffi.ffi_fill_point(point)
                    ffi.ffi_fill_values(values)
                    return point.x as integer
                        + point.y as integer
                        + values[0] as integer
                        + values[1] as integer
                        + values[2] as integer
                        + #values
                end

                function pointer_fill(): integer
                    local point = ffi.ffi_point.new()
                    local values: ffi.ffi_int[3] = ffi.ffi_int.new_array(3)
                    local point_pointer: *ffi.ffi_point = point
                    local values_pointer: *ffi.ffi_int = values
                    ffi.ffi_fill_point(point_pointer)
                    ffi.ffi_fill_values(values_pointer)
                    return point_pointer.x as integer
                        + values_pointer[2] as integer
                end

                function indexed(): integer
                    local values: ffi.ffi_int[3] = ffi.ffi_int.new_array(3)
                    values[0] = 5
                    values[1] = 7
                    values[2] = 11
                    return values[0] as integer
                        + values[1] as integer
                        + values[2] as integer
                        + #values
                end

                function out_of_range(): integer
                    local values: ffi.ffi_int[3] = ffi.ffi_int.new_array(3)
                    return values[3] as integer
                end

                function struct_copy(): integer
                    local source: ffi.ffi_point =
                        ffi.ffi_make_point(43, 47)
                    local target = ffi.ffi_point.new()
                    target = source
                    return target.x as integer + target.y as integer
                end

                function anonymous_subobjects(): integer
                    local holder = ffi.ffi_anonymous_holder.new()
                    anonymous_seen = 0
                    holder.cell.count = 13
                    holder.items[anonymous_index()].number =
                        anonymous_rhs()
                    return anonymous_seen * 100
                        + ffi.ffi_read_anonymous(holder) as integer
                end

                function anonymous_longjmp(): integer
                    local holder = ffi.ffi_anonymous_holder.new()
                    do
                        holder.cell.count = 19
                        holder.items[1].number = 23
                        raise "anonymous"
                    catch
                        return ffi.ffi_read_anonymous(holder) as integer
                    end
                end
            ]]

            driver.CFLAGS = driver.CFLAGS .. " -Wno-array-bounds"
            local csrc = h.compile_and_read_c(source, MODULE)
            assert.match(
                "ffi_point _local_point_%d+ = %{0%};", csrc)
            assert.match(
                "ffi_cell _local_cell_%d+ = %{0%};", csrc)
            assert.match(
                "ffi_int _local_values_%d+%[3%] = %{0%};", csrc)
            assert.match(
                "ffi_row _local_matrix_%d+%[2%] = %{0%};", csrc)
            assert.match(
                "struct ffi_tag_point _local_tag_point_%d+ = %{0%};",
                csrc)
            assert.match(
                "union ffi_tag_cell _local_tag_cell_%d+ = %{0%};",
                csrc)
            assert.match(
                "ffi_anonymous_holder _local_holder_%d+ = %{0%};",
                csrc)
            assert.match(
                "unsigned char volatile _spill_local_holder_%d+"
                    .. "%[sizeof%(_local_holder_%d+%)%];",
                csrc)

            -- Struct/union arguments take their local address. Arrays use
            -- their ordinary decay expression and must never become
            -- pointer-to-array through `&array`.
            assert.match("%(&%(_local_point_%d+%)%)", csrc)
            assert.match("%(&%(_local_cell_%d+%)%)", csrc)
            assert.match("%(&%(_local_tag_point_%d+%)%)", csrc)
            assert.match("%(&%(_local_tag_cell_%d+%)%)", csrc)
            assert.not_match("&%(_local_values_%d+%)", csrc)
            assert.not_match("&%(_local_matrix_%d+%)", csrc)

            local ok, out = h.call(MODULE, [[
                assert(ffi_stack_objects.all_zero())
                assert(ffi_stack_objects.direct_fill() == 152)
                assert(ffi_stack_objects.pointer_fill() == 58)
                assert(ffi_stack_objects.indexed() == 26)
                assert(ffi_stack_objects.struct_copy() == 90)
                assert(ffi_stack_objects.anonymous_subobjects() == 1230)
                assert(ffi_stack_objects.anonymous_longjmp() == 42)
            ]])
            assert.truthy(ok, out)
            assert.equal("", out)

            ok, out = h.call(MODULE, [[
                ffi_stack_objects.out_of_range()
            ]])
            assert.falsy(ok)
            assert.match("C index", out)
        end)
    end)

    it("commits aggregate representations across longjmp boundaries",
    function()
        with_header(declarations .. [[
            #include <stdarg.h>

            typedef void (*ffi_variadic_fill_fn)(int tag, ...);

            static void ffi_variadic_fill(int tag, ...) {
                va_list args;
                ffi_point *point;
                va_start(args, tag);
                point = va_arg(args, ffi_point *);
                va_end(args);
                point->x = tag * 10 + 1;
                point->y = tag * 10 + 2;
            }

            static ffi_variadic_fill_fn ffi_get_variadic_fill(void) {
                return ffi_variadic_fill;
            }
        ]], function(header)
            local source = [[
                foreign import "]] .. header .. [["

                local function cleanup()
                end

                function direct_writes(): integer
                    local point = ffi.ffi_point.new()
                    local values: ffi.ffi_int[3] = ffi.ffi_int.new_array(3)
                    do
                        point.x = 5
                        values[0] = 7
                        raise "direct"
                    catch
                        return point.x as integer
                            + values[0] as integer
                    end
                end

                function foreign_writes(): integer
                    local point = ffi.ffi_point.new()
                    local values: ffi.ffi_int[3] = ffi.ffi_int.new_array(3)
                    do
                        ffi.ffi_fill_point(point)
                        ffi.ffi_fill_values(values)
                        raise "foreign"
                    catch
                        return point.x as integer
                            + point.y as integer
                            + values[0] as integer
                            + values[1] as integer
                            + values[2] as integer
                    end
                end

                function unsafe_foreign_write(): integer
                    local point = ffi.ffi_point.new()
                    do
                        ffi.ffi_fill_other_point(point)
                        raise "unsafe-foreign"
                    catch
                        return point.x as integer
                            + point.y as integer
                    end
                end

                function variadic_foreign_writes(): integer
                    local direct = ffi.ffi_point.new()
                    local indirect = ffi.ffi_point.new()
                    do
                        ffi.ffi_variadic_fill(
                            3, direct as *ffi.ffi_point)
                        local fill = ffi.ffi_get_variadic_fill()
                        fill(4, indirect as *ffi.ffi_point)
                        raise "variadic-foreign"
                    catch
                        return direct.x as integer
                            + direct.y as integer
                            + indirect.x as integer
                            + indirect.y as integer
                    end
                end

                function nested_unsafe_foreign_write(): integer
                    local point = ffi.ffi_point.new()
                    do
                        ffi.ffi_fill_other_point(
                            point as *ffi.ffi_point)
                        raise "nested-unsafe-foreign"
                    catch
                        return point.x as integer
                            + point.y as integer
                    end
                end

                function nested(): integer
                    local point = ffi.ffi_point.new()
                    do
                        do
                            point.x = 11
                            raise "inner"
                        catch
                            point.y = 13
                            raise "outer"
                        end
                    catch
                        return point.x as integer
                            + point.y as integer
                    end
                end

                function catch_finally(): integer
                    local point = ffi.ffi_point.new()
                    do
                        defer point.y =
                            (point.x as integer + 19) as ffi.ffi_int
                        do
                            raise "body"
                        catch
                            point.x = 17
                            raise "catch"
                        end
                    catch
                        return point.y as integer
                    end
                end

                function loop_edges(): integer
                    local values: ffi.ffi_int[3] = ffi.ffi_int.new_array(3)
                    local i: integer = 0
                    while i < 3 do
                        do
                            values[i] = i + 1
                            raise "next"
                        catch
                            i = i + 1
                        end
                    end
                    return values[0] as integer
                        + values[1] as integer
                        + values[2] as integer
                end

                function defer_tail(): integer
                    defer cleanup()
                    local point = ffi.ffi_point.new()
                    do
                        point.x = 61
                        raise "defer-tail"
                    catch
                        return point.x as integer
                    end
                end

                function alias_untracked(): integer
                    local aliased = ffi.ffi_point.new()
                    local pointer: *ffi.ffi_point = aliased
                    do
                        ffi.ffi_fill_point(pointer)
                        raise "unsafe-alias"
                    catch
                        return aliased.x as integer
                    end
                end
            ]]

            local csrc = h.compile_and_read_c(source, MODULE)
            assert.match(
                "unsigned char volatile _spill_local_point_%d+"
                    .. "%[sizeof%(_local_point_%d+%)%];",
                csrc)
            assert.match(
                "unsigned char volatile _spill_local_values_%d+"
                    .. "%[sizeof%(_local_values_%d+%)%];",
                csrc)
            assert.match(
                "%(%(const unsigned char %*%)"
                    .. "&%(_local_point_%d+%)%)%[_spill_i%]",
                csrc)
            assert.match(
                "%(%(unsigned char %*%)"
                    .. "&%(_local_point_%d+%)%)%[_spill_i%]",
                csrc)
            assert.not_match("memcpy", csrc)
            assert.not_match(
                "%(%(unsigned char %*%)_spill", csrc)
            assert.not_match("_spill_local_aliased", csrc)

            local ok, err = h.call(MODULE, [[
                assert(ffi_stack_objects.direct_writes() == 12)
                assert(ffi_stack_objects.foreign_writes() == 149)
                assert(ffi_stack_objects.unsafe_foreign_write() == 138)
                assert(
                    ffi_stack_objects.variadic_foreign_writes() == 146)
                assert(
                    ffi_stack_objects.nested_unsafe_foreign_write() == 138)
                assert(ffi_stack_objects.nested() == 24)
                assert(ffi_stack_objects.catch_finally() == 36)
                assert(ffi_stack_objects.loop_edges() == 6)
                assert(ffi_stack_objects.defer_tail() == 61)
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("builds a nested process-options, stdio-array, and tagged address shape",
    function()
        with_header([[
            typedef struct ffi_stream { int state; } ffi_stream;
            typedef struct ffi_pipe { int state; } ffi_pipe;

            typedef union ffi_stdio_data {
                ffi_stream *stream;
                int descriptor;
            } ffi_stdio_data;

            typedef struct ffi_stdio_container {
                unsigned int flags;
                ffi_stdio_data data;
            } ffi_stdio_container;

            typedef struct ffi_process_options {
                ffi_stdio_container *stdio;
                int stdio_count;
            } ffi_process_options;

            struct ffi_address {
                int flags;
                struct ffi_address *next;
            };

            static ffi_pipe *ffi_pipe_pointer;
            static int ffi_stream_matches_pipe(
                ffi_stdio_container *stdio,
                ffi_pipe *pipe
            ) {
                return stdio[0].data.stream == (ffi_stream *)pipe;
            }
        ]], function(header)
            local source = [[
                foreign import "]] .. header .. [["

                function shape(): integer
                    local options = ffi.ffi_process_options.new()
                    local stdio: ffi.ffi_stdio_container[3] =
                        ffi.ffi_stdio_container.new_array(3)
                    local address = ffi.ffi_address.new()

                    options.stdio = stdio
                    options.stdio_count = #stdio
                    stdio[0].data.stream =
                        ffi.ffi_pipe_pointer as *ffi.ffi_stream
                    address.flags = 0
                    return options.stdio_count as integer
                        + address.flags as integer
                        + ffi.ffi_stream_matches_pipe(
                            stdio, ffi.ffi_pipe_pointer
                          ) as integer
                end
            ]]
            local csrc = h.compile_and_read_c(source, MODULE)
            assert.match(
                "ffi_process_options _local_options_%d+ = %{0%};",
                csrc)
            assert.match(
                "ffi_stdio_container _local_stdio_%d+%[3%] = %{0%};",
                csrc)
            assert.match(
                "struct ffi_address _local_address_%d+ = %{0%};", csrc)

            local ok, out = h.call(MODULE, [[
                assert(ffi_stack_objects.shape() == 4)
            ]])
            assert.truthy(ok, out)
            assert.equal("", out)
        end)
    end)
end)
