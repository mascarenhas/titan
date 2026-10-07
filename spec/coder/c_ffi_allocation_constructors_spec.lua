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
end)
