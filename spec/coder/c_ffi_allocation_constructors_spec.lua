local temporary = require "spec.support.temporary"
local h = require "spec.support.helpers"

local function with_header(contents, body)
    local path = temporary.name(".h")
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
    local results = table.pack(xpcall(function() return body(path) end,
        debug.traceback))
    os.remove(path)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

local function cleanup()
    for _, path in ipairs({
        "test.c", "test.o", "test.so", "test.a", "test.titan.h",
    }) do
        os.remove(path)
    end
    os.execute("rm -rf test.so.dSYM")
end

describe("constructor-selected C allocation code generation", function()
    after_each(cleanup)

    it("uses automatic objects and arrays and copies them into owners", function()
        with_header([[
            typedef struct ffi_pair {
                int left;
                int right;
            } ffi_pair;
            typedef ffi_pair ffi_pair_row[2];
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function exercise(): integer
                    local pair = foreign ffi_pair.new()
                    pair.left = 10
                    pair.right = 2

                    local pairs = foreign ffi_pair.new_array(2)
                    pairs[0].left = pair.left
                    pairs[1].right = 7

                    local copy: owned *ffi_pair = pair
                    local copied_pairs: owned ffi_pair[] = pairs
                    pair.left = 99
                    pairs[0].left = 88

                    return (copy.left as integer)
                        + (copied_pairs[0].left as integer)
                        + (copied_pairs[1].right as integer)
                end

                function nested_arrays(): integer
                    local rows =
                        foreign ffi_pair_row.new_array(2)
                    rows[0][1].left = 13
                    rows[1][0].right = 17
                    return rows[0][1].left as integer
                        + rows[1][0].right as integer
                end
            ]], [[
                assert(test.exercise() == 27)
                assert(test.nested_arrays() == 30)
            ]])
        end)
    end)

    it("allocates automatic and owned flexible tails with exact counts", function()
        with_header([[
            typedef int ffi_int;
            typedef struct ffi_packet {
                int tag;
                int items[];
            } ffi_packet;
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function automatic(): integer
                    local packet = foreign ffi_packet.new(3)
                    packet.tag = 4
                    packet.items[0] = 5
                    packet.items[1] = 6
                    packet.items[2] = 7
                    local copy: owned *ffi_packet = packet
                    packet.items[1] = 90
                    return packet.tag as integer + #packet.items
                        + copy.items[0] as integer
                        + copy.items[1] as integer
                        + copy.items[2] as integer
                        + #copy.items
                end

                function dynamic_owned(count: integer): integer
                    local packet: owned *ffi_packet =
                        foreign ffi_packet.new(count as foreign ffi_int)
                    packet.items[count - 1] = 11
                    return #packet.items
                        + packet.items[count - 1] as integer
                end
            ]], [[
                assert(test.automatic() == 28)
                assert(test.dynamic_owned(5) == 16)
            ]])
        end)
    end)

    it("spills automatic object, array, and FAM backing across a caught raise",
    function()
        with_header([[
            typedef struct ffi_pair { int value; } ffi_pair;
            typedef struct ffi_packet { int tag; int items[]; } ffi_packet;
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                local function fail()
                    raise "expected"
                end

                function exercise(): integer
                    local pair = foreign ffi_pair.new()
                    local pairs = foreign ffi_pair.new_array(2)
                    local packet = foreign ffi_packet.new(2)
                    pair.value = 3
                    pairs[1].value = 5
                    packet.items[1] = 7
                    do
                        fail()
                    catch
                    end
                    return pair.value as integer
                        + pairs[1].value as integer
                        + packet.items[1] as integer
                end
            ]], [[assert(test.exercise() == 15)]])
        end)
    end)

    it("keeps automatic pointer-view slots live through captured and deferred use",
    function()
        h.run_coder([[
            foreign import "stdlib.h"
            foreign type RawSlot = *void

            local foreign function release_slot(slot: *(*void)): int
                local raw = slot[0]
                slot[0] = nil
                if raw == nil then return 0 end
                ffi.free(raw)
                return 1
            end

            function plain(): integer
                local slot: foreign *RawSlot = foreign RawSlot.new_array(1)
                local empty: foreign *RawSlot = foreign RawSlot.new_array(1)
                if slot[0] ~= nil or empty[0] ~= nil then
                    raise "plain pointer slots were not zero-initialized"
                end
                slot[0] = empty as foreign *void
                if slot[0] ~= empty as foreign *void or empty[0] ~= nil then
                    raise "distinct automatic pointer slots shared backing"
                end
                slot[0] = nil
                return 1
            end

            function ordinary(): integer
                local released = 0
                local observed = 0
                do
                    local slot: foreign *RawSlot = foreign RawSlot.new_array(1)
                    local empty: foreign *RawSlot = foreign RawSlot.new_array(1)
                    defer do
                        released = released + (release_slot(slot) as integer)
                        released = released + (release_slot(empty) as integer)
                    end
                    if slot[0] ~= nil or empty[0] ~= nil then
                        raise "automatic pointer slots were not zero-initialized"
                    end
                    slot[0] = ffi.malloc(foreign int.sizeof as foreign size_t)
                    if slot[0] == nil then raise "could not allocate slot payload" end
                    local payload = slot[0] as foreign *int
                    payload[0] = 41
                    observed = payload[0] as integer
                end
                return observed + released
            end

            function captured(fail: boolean): integer
                local released = 0
                local observed = 0
                do
                    local slot: foreign *RawSlot = foreign RawSlot.new_array(1)
                    local empty: foreign *RawSlot = foreign RawSlot.new_array(1)
                    defer do
                        released = released + (release_slot(slot) as integer)
                        released = released + (release_slot(empty) as integer)
                    end
                    local action = function ()
                        if slot[0] ~= nil or empty[0] ~= nil then
                            raise "captured pointer slots were not zero-initialized"
                        end
                        slot[0] = ffi.malloc(foreign int.sizeof as foreign size_t)
                        if slot[0] == nil then raise "could not allocate slot payload" end
                        local payload = slot[0] as foreign *int
                        payload[0] = 43
                        observed = payload[0] as integer
                        if fail then raise "expected pointer-slot unwind" end
                    end
                    action()
                catch
                    if not fail or error ~= "expected pointer-slot unwind" then
                        raise error
                    end
                end
                return observed + released
            end
        ]], [[
            assert(test.plain() == 1)
            assert(test.ordinary() == 42)
            assert(test.captured(false) == 44)
            assert(test.captured(true) == 44)
        ]])
    end)

    it("preserves borrowed automatic array pointers across caught-error reassignments and C out-parameters",
    function()
        h.with_extra_cflags({ "-O2" }, function()
            with_header([[
                typedef struct ffi_pair {
                    int left;
                    int right;
                } ffi_pair;

                static void ffi_advance_pair(ffi_pair **cursor, int step) {
                    *cursor = *cursor + step;
                }

                static void ffi_repoint_pair(
                    ffi_pair **cursor,
                    ffi_pair *target
                ) {
                    *cursor = target;
                }
            ]], function(header)
                h.run_coder([[
                    foreign import "]] .. header .. [["

                    local function fail()
                        raise "expected"
                    end

                    function reassigned(): integer
                        local cursor: foreign *ffi_pair =
                            foreign ffi_pair.new_array(2)
                        local other: foreign *ffi_pair =
                            foreign ffi_pair.new_array(1)
                        cursor[0].left = 11
                        cursor[1].left = 17
                        other[0].left = 29
                        do
                            cursor = cursor + 1
                        catch
                        end
                        cursor[0].right = 23
                        do
                            fail()
                        catch
                        end
                        local stepped = (cursor[0].left as integer) * 100
                            + (cursor[0].right as integer)
                        do
                            cursor = other
                        catch
                        end
                        cursor[0].right = 31
                        do
                            fail()
                        catch
                        end
                        return stepped * 10000
                            + (cursor[0].left as integer) * 100
                            + (cursor[0].right as integer)
                    end

                    function out_param(): integer
                        local cursor: foreign *ffi_pair =
                            foreign ffi_pair.new_array(2)
                        local other: foreign *ffi_pair =
                            foreign ffi_pair.new_array(1)
                        cursor[0].left = 37
                        cursor[1].left = 41
                        other[0].left = 43
                        do
                            ffi.ffi_advance_pair(cursor, 1)
                        catch
                        end
                        cursor[0].right = 47
                        do
                            fail()
                        catch
                        end
                        local stepped = (cursor[0].left as integer) * 100
                            + (cursor[0].right as integer)
                        do
                            ffi.ffi_repoint_pair(cursor, other)
                        catch
                        end
                        cursor[0].right = 53
                        do
                            fail()
                        catch
                        end
                        return stepped * 10000
                            + (cursor[0].left as integer) * 100
                            + (cursor[0].right as integer)
                    end
                ]], [[
                    assert(test.reassigned() == 17232931)
                    assert(test.out_param() == 41474353)
                ]])
            end)
        end)
    end)

    it("spills bare foreign function-pointer locals across caught errors",
    function()
        with_header([[
            static int ffi_step_value(int value) {
                return value + 7;
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                local function fail()
                    raise "expected"
                end

                function exercise(): integer
                    local cb: foreign function(int): int = nil
                    do
                        cb = ffi.ffi_step_value
                        fail()
                    catch
                    end
                    return cb(5) as integer
                end
            ]], [[
                assert(test.exercise() == 12)
            ]])
        end)
    end)

    it("keeps loop-scoped borrowed pointer slots live for deferred release after a caught error before decode",
    function()
        h.run_coder([[
            foreign import "stdlib.h"
            foreign type RawSlot = *void

            local foreign function acquire_slot(slot: *(*void), tag: int): int
                local raw = ffi.malloc(foreign int.sizeof as foreign size_t)
                if raw == nil then return 0 end
                local payload = raw as foreign *int
                payload[0] = tag
                slot[0] = raw
                return 1
            end

            local foreign function decode_slot(slot: *(*void)): int
                local raw = slot[0]
                slot[0] = nil
                if raw == nil then return -1 end
                local payload = raw as foreign *int
                local tag = payload[0]
                ffi.free(raw)
                return tag
            end

            local foreign function release_slot(slot: *(*void)): int
                local raw = slot[0]
                slot[0] = nil
                if raw == nil then return 0 end
                local payload = raw as foreign *int
                local tag = payload[0]
                ffi.free(raw)
                return tag
            end

            local function fail_before_decode()
                raise "expected before decode"
            end

            function exercise(): integer
                local released = 0
                local decoded = 0
                local caught = 0
                for attempt = 1, 2 do
                    local slot: foreign *RawSlot = foreign RawSlot.new_array(1)
                    defer do
                        released = released + (release_slot(slot) as integer)
                    end
                    if slot[0] ~= nil then
                        raise "loop pointer slot was not zero-initialized"
                    end
                    if acquire_slot(slot, (attempt * 10 + 7) as foreign int) == 0 then
                        raise "could not allocate slot payload"
                    end
                    if attempt == 1 then
                        fail_before_decode()
                    end
                    decoded = decoded + (decode_slot(slot) as integer)
                catch
                    if error ~= "expected before decode" then
                        raise error
                    end
                    caught = caught + 1
                end
                return caught * 10000 + released * 100 + decoded
            end
        ]], [[
            assert(test.exercise() == 11727)
        ]])
    end)
end)
