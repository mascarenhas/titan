local h = require "spec.support.helpers"

local function clean()
    for _, name in ipairs({"test", "nominal_provider", "nominal_consumer"}) do
        for _, ext in ipairs({"c", "o", "so", "a", "ffi.h", "titan.h"}) do
            os.remove(name .. "." .. ext)
        end
    end
end

describe("native nominal storage", function()
    after_each(clean)

    it("keeps raw fields out of UVs and public GC slots before private slots", function()
        h.run_coder([[
            record Mixed
                local hidden: string
                count: integer
                label: string
                enabled: boolean
                local secret: integer
                optional: integer?
            end
            record Raw
                count: integer
                ratio: float
                flag: boolean
            end
            function make(): Mixed
                return Mixed.new("private", 41, "public", true, 7, nil)
            end
            function raw(): Raw return Raw.new(9, 1.5, false) end
            function check(r: Mixed): integer
                r.count = r.count + r.secret
                r.optional = 12
                return r.count + (r.optional as integer)
            end
        ]], [[
            local r = test.make()
            assert(r.count == 41 and r.label == 'public' and r.enabled)
            assert(r.optional == nil)
            assert(debug.getuservalue(r, 1) == 'public')
            assert(debug.getuservalue(r, 2) == 'private')
            local _, present = debug.getuservalue(r, 3)
            assert(not present)
            assert(test.check(r) == 60)
            assert(r.optional == 12)
            r.optional = nil
            assert(r.optional == nil)
            local raw = test.raw()
            assert(raw.count == 9 and raw.ratio == 1.5 and raw.flag == false)
            _, present = debug.getuservalue(raw, 1)
            assert(not present)
        ]])
    end)

    it("reconstructs only the public prefix across a source-free DSO", function()
        local header = os.tmpname() .. ".h"
        local file = assert(io.open(header, "w"))
        file:write([[
            typedef struct private_native { long double precise; int tag; } private_native;
        ]])
        file:close()
        local ok, err = h.build_so_chain({{
            name = "nominal_provider",
            src = 'foreign import "' .. header .. '"\n' .. [[
                record State
                    local const native: foreign private_native
                    local hidden: string
                    count: integer
                    label: string
                    local tail: foreign long double
                end
                function make(): State
                    local native = foreign private_native.new()
                    native.tag = 11
                    return State.new(native, "private", 40, "hi", 1.5)
                end
                function check(s: State): integer
                    return s.count + s.native.tag + #s.label
                end
            ]],
        }, {
            name = "nominal_consumer",
            src = [[
                local provider = import "nominal_provider"
                function run(): integer
                    local s = provider.make()
                    s.count = s.count + #s.label
                    s.label = "changed"
                    return provider.check(s)
                end
            ]],
        }})
        os.remove(header)
        assert.truthy(ok, err)
        local cfile = assert(io.open("nominal_consumer.c"))
        local csource = cfile:read("a")
        cfile:close()
        assert.falsy(csource:find("private_native", 1, true))
        local ran, output = h.call("nominal_consumer", [[
            assert(nominal_consumer.run() == 60)
        ]])
        assert.truthy(ran, output)
    end)

    it("uses a native tag and variant-specific dense traced payloads", function()
        h.run_coder([[
            union Item
                empty()
                number(integer)
                pair(number: integer, label: string)
            end
            function read(item: Item): integer
                case item
                when empty() then return 0
                when number(n) then return n
                when pair(n, text) then return n + #text
                end
            end
        ]], [[
            local a, b, c = test.Item.empty(), test.Item.number(42),
                test.Item.pair(40, 'hi')
            assert(test.read(a) == 0 and test.read(b) == 42 and test.read(c) == 42)
            local _, present = debug.getuservalue(a, 1)
            assert(not present)
            _, present = debug.getuservalue(b, 1)
            assert(not present)
            assert(debug.getuservalue(c, 1) == 'hi')
            _, present = debug.getuservalue(c, 2)
            assert(not present)
        ]])
    end)

    it("preserves erased generic fields in traced slots", function()
        h.run_coder([[
            record Box<|T|>
                index: integer
                item: T
            end
            function make(): Box<|integer|> return Box.new(7, 35) end
            function read(box: Box<|integer|>): integer return box.index + box.item end
        ]], [[
            local b = test.make()
            assert(test.read(b) == 42)
            assert(debug.getuservalue(b, 1) == 35)
            local _, present = debug.getuservalue(b, 2)
            assert(not present)
        ]])
    end)

    it("defers wide native conversion until a boxed accessor is requested", function()
        h.run_coder([[
            foreign import "limits.h"
            record Wide
                value: foreign unsigned long long
            end
            function make(): Wide return Wide.new(ffi.ULLONG_MAX) end
            function exact(w: Wide): boolean return w.value == ffi.ULLONG_MAX end
        ]], [[
            local w = test.make()
            assert(test.exact(w))
            assert(not pcall(function() return w.value end))
            assert(test.exact(w))
            w.value = 42
            assert(w.value == 42)
            assert(not pcall(function() w.value = 'wrong' end))
            assert(w.value == 42)
        ]])
    end)

    it("fuses fresh const arrays with lexical checks and distinct empty tails", function()
        local csrc = h.compile_and_read_c([[
            foreign import "spec/fixtures/nominal_allocation_probe.h"
            record NativeIntArray
                const length: integer
                local const array: foreign int[]
            end
            function NativeIntArray.make(len: integer): NativeIntArray
                return NativeIntArray.new(len, foreign int.new_array(len))
            end
            function NativeIntArray:set(i: integer, n: integer)
                self.array[i] = n
            end
            function NativeIntArray:get(i: integer): integer return self.array[i] end
            function measured(len: integer): (NativeIntArray, integer, integer)
                ffi.nominal_probe_begin(L)
                local array = NativeIntArray.make(len)
                local count = ffi.nominal_probe_end(L)
                return array, count, ffi.nominal_probe_size()
            end
            local record Pair
                local const left: foreign int[]
                local const right: foreign double[]
                local const last: integer
            end
            effects: integer = 0
            local function mark(n: integer): integer
                effects = effects * 10 + n
                return n
            end
            function empty(): boolean
                local pair = Pair.new(foreign int.new_array(0),
                    foreign double.new_array(0), 0)
                return pair.left ~= nil and pair.right ~= nil
                    and (pair.left as foreign *void) ~= (pair.right as foreign *void)
            end
            function ordered(): float
                effects = 0
                local pair = Pair.new { right = foreign double.new_array(mark(2)),
                    last = mark(3), left = foreign int.new_array(mark(1)) }
                pair.left[0] = 19
                pair.right[0] = 23
                return pair.left[0] + pair.right[0]
            end
            function negative()
                effects = 0
                local pair = Pair.new(foreign int.new_array(-mark(1)),
                    foreign double.new_array(mark(2)), mark(3))
            end
        ]])
        -- The named make body contains exactly its final userdata allocation;
        -- no owned-array allocator or automatic backing buffer is present.
        local signature = "test_\\u2133_NativeIntArray_\\u2131_make_titanstatic("
        local start = assert(csrc:find(signature, 1, true))
        start = assert(csrc:find(signature, start + 1, true))
        local stop = assert(csrc:find("static int ", start, true))
        local body = csrc:sub(start, stop - 1)
        local _, allocations = body:gsub("luaS_newudata", "")
        assert.equal(1, allocations)
        assert.falsy(body:find("_backing", 1, true))
        local ok, err = h.call("test", [[
            local a = test.NativeIntArray.make(4)
            for i = 0, 3 do assert(a:get(i) == 0) end
            a:set(2, 42)
            collectgarbage('collect')
            assert(a:get(2) == 42)
            local _, present = debug.getuservalue(a, 1)
            assert(not present)
            for _, n in ipairs({0, 1, 16, 1024}) do
                local measured, count, bytes = test.measured(n)
                assert(measured.length == n and count == 1 and bytes > 0)
            end
            assert(test.empty())
            assert(test.ordered() == 42 and test.effects == 231)
            local ok, message = pcall(test.negative)
            assert(not ok and message:find('count cannot be negative', 1, true))
            assert(test.effects == 1)
            ok, message = pcall(test.NativeIntArray.make, math.maxinteger)
            assert(not ok and message:find('size overflow', 1, true))
        ]])
        assert.truthy(ok, err)
    end)

    it("copies fixed objects and snapshots arrays before later argument effects", function()
        local header = os.tmpname() .. ".h"
        local file = assert(io.open(header, "w"))
        file:write([[
            typedef struct embedded_point { int x; int y; } embedded_point;
            typedef int embedded_row[3];
            static embedded_row embedded_source = {10, 20, 30};
        ]])
        file:close()
        local outcome = table.pack(pcall(function()
            h.run_coder('foreign import "' .. header .. '"\n' .. [[
                local record Box
                    const point: foreign embedded_point
                    const row: foreign embedded_row
                    const effect: integer
                end
                local function change(): integer
                    ffi.embedded_source[0] = 99
                    return 7
                end
                function copy(): integer
                    local point = foreign embedded_point.new()
                    point.x = 12
                    local box = Box.new(point, ffi.embedded_source, change())
                    point.x = 99
                    local interior = box.point
                    interior.y = 20
                    return box.point.x + box.point.y + box.row[0]
                end
                function zero(): integer
                    local box = Box.new(foreign embedded_point.new(),
                        foreign int.new_array(3), 0)
                    local point = box.point
                    local row = box.row
                    point.x = 40
                    row[2] = 2
                    return point.x + point.y + row[0] + row[1] + row[2]
                end
            ]], [[ assert(test.copy() == 42); assert(test.zero() == 42) ]])
        end))
        os.remove(header)
        assert.truthy(outcome[1], outcome[2])
    end)

    it("initializes C-qualified aggregate and array members without C assignment", function()
        local header = os.tmpname() .. ".h"
        local file = assert(io.open(header, "w"))
        file:write([[
            typedef struct const_point { int x; int y; } const_point;
            typedef const const_point const_point_view;
            typedef const int const_row[3];
            typedef struct const_member { const int value; } const_member;
            typedef struct nested_const_member { const_member inner; } nested_const_member;
            static const_point_view qualified_point = {11, 13};
            static const_row qualified_row = {17, 19, 23};
            static nested_const_member qualified_nested = {{29}};
        ]])
        file:close()
        local outcome = table.pack(pcall(function()
            h.run_coder('foreign import "' .. header .. '"\n' .. [[
                local record Readonly
                    const point: foreign const_point_view
                    const row: foreign const_row
                    const nested: foreign nested_const_member
                end
                local union Qualified
                    some(point: foreign const_point_view, nested: foreign nested_const_member)
                end
                function read(): integer
                    local holder = Readonly.new(ffi.qualified_point,
                        ffi.qualified_row, ffi.qualified_nested)
                    local sum = holder.point.x + holder.point.y + holder.row[0]
                        + holder.row[1] + holder.row[2] + holder.nested.inner.value
                    case Qualified.some(ffi.qualified_point, ffi.qualified_nested)
                    when some(point, nested) then
                        return sum + point.x + nested.inner.value
                    end
                end
            ]], [[ assert(test.read() == 152) ]])
        end))
        os.remove(header)
        assert.truthy(outcome[1], outcome[2])
    end)

    it("copies qualified numeric typedefs into mutable native value carriers", function()
        local header = os.tmpname() .. ".h"
        local file = assert(io.open(header, "w"))
        file:write([[
            typedef const int const_integer;
            typedef const double const_double;
            static const_integer qualified_integer = 7;
            static const_double qualified_double = 2.5;
        ]])
        file:close()
        local outcome = table.pack(pcall(function()
            h.run_coder('foreign import "' .. header .. '"\n' .. [[
                local record Scalars
                    integer: foreign const_integer
                    floating: foreign const_double
                    optional: (foreign const_integer)?
                end
                local union Number
                    some(foreign const_integer)
                end
                foreign function copied(value: const_integer): const_integer
                    local copy = value
                    return copy
                end
                local function pair(integer: foreign const_integer,
                                     floating: foreign const_double):
                    (foreign const_integer, foreign const_double)
                    return integer, floating
                end
                function read(): boolean
                    local integer, floating = pair(
                        ffi.qualified_integer, ffi.qualified_double)
                    local holder = Scalars.new(integer, floating, integer)
                    holder.integer = copied(integer)
                    holder.optional = nil
                    holder.optional = integer
                    case Number.some(holder.integer)
                    when some(value) then
                        return value == 7 and holder.floating == 2.5
                            and (holder.optional as foreign const_integer) == 7
                    end
                end
            ]], [[ assert(test.read()) ]])
        end))
        os.remove(header)
        assert.truthy(outcome[1], outcome[2])
    end)

    it("copies fixed array replacements before later right-hand-side effects", function()
        local header = os.tmpname() .. ".h"
        local file = assert(io.open(header, "w"))
        file:write([[
            typedef int replacement_row[3];
            static replacement_row replacement_source = {10, 20, 30};
        ]])
        file:close()
        local outcome = table.pack(pcall(function()
            h.run_coder('foreign import "' .. header .. '"\n' .. [[
                local record Box
                    row: foreign replacement_row
                    marker: integer
                end
                local function change(): integer
                    ffi.replacement_source[0] = 99
                    return 7
                end
                function replace(): integer
                    local holder = Box.new(foreign int.new_array(3), 0)
                    holder.row, holder.marker = ffi.replacement_source, change()
                    return holder.row[0] + holder.row[1] + holder.row[2]
                        + holder.marker
                end
                function single(): integer
                    local holder = Box.new(foreign int.new_array(3), 0)
                    holder.row = ffi.replacement_source
                    ffi.replacement_source[0] = 1
                    return holder.row[0]
                end
            ]], [[ assert(test.replace() == 67); assert(test.single() == 99) ]])
        end))
        os.remove(header)
        assert.truthy(outcome[1], outcome[2])
    end)

    it("aligns multiple array and FAM union tails after their fixed payload", function()
        local header = os.tmpname() .. ".h"
        local file = assert(io.open(header, "w"))
        file:write([[
            #include <stdint.h>
            typedef struct embedded_packet { int tag; long double values[]; } embedded_packet;
            static int packet_aligned(embedded_packet *p) {
                return (uintptr_t)p % _Alignof(embedded_packet) == 0;
            }
            static int fill_packet(embedded_packet *p) {
                p->values[0] = 11;
                p->values[1] = 12;
                return p->tag + (int)p->values[0] + (int)p->values[1];
            }
        ]])
        file:close()
        local outcome = table.pack(pcall(function()
            h.run_coder('foreign import "' .. header .. '"\n' .. [[
                local union Payload
                    data(bytes: foreign *char, packet: foreign *embedded_packet)
                end
                function run(n: integer): integer
                    local payload = Payload.data(foreign char.new_array(n),
                        foreign embedded_packet.new(2))
                    case payload
                    when data(bytes, packet) then
                        if ffi.packet_aligned(packet) == 0 then return -1 end
                        packet.tag = 19
                        return ffi.fill_packet(packet)
                    end
                end
            ]], [[ for n = 0, 17 do assert(test.run(n) == 42) end ]])
        end))
        os.remove(header)
        assert.truthy(outcome[1], outcome[2])
    end)
end)
