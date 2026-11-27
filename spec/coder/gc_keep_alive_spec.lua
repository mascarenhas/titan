-- Direct `gc.keep_alive` calls lower as a compiler intrinsic; first-class and
-- Lua uses call the ordinary titan.gc entry. The fixtures import the installed
-- standard provider, so this spec is listed in
-- spec/support/ci_stdlib_compiler_test_files.txt. Public behavior on native
-- and browser targets lives in spec/stdlib/titan/gc/tests.titan.
-- Implementation notes: doc/implementation/gc-library.md#keep-alive-intrinsic
local h = require "spec.support.helpers"
local temporary = require "spec.support.temporary"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local coder_names = require "titan-compiler.coder.names"
local driver = require "titan-compiler.driver"

local KEEP_ALIVE_PREFIX = coder_names._function_prefix("titan.gc", "keep_alive")
local KEEP_ALIVE_ENTRY = KEEP_ALIVE_PREFIX .. "_titan"

local function clean()
    for _, suffix in ipairs({ ".c", ".o", ".so", ".dll", ".a", ".ffi.h",
                              ".titan.h", ".priv.h", ".parts" }) do
        os.remove("test" .. suffix)
    end
    local removed, remove_error = driver.remove_path("test.so.dSYM")
    assert.truthy(removed, remove_error)
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("a")
    file:close()
    return contents
end

local function build(source)
    local ok, err = h.build_so_chain({ { name = "test", src = source } })
    assert.truthy(ok, err)
    return read_file("test.c")
end

local function native_body(csrc, name)
    local symbol = coder_names._function_prefix("test", name) .. "_titan"
    return assert(csrc:match("[^\n]*" .. symbol .. "%b()%s*(%b{})"), symbol)
end

local function contains(text, needle)
    return text:find(needle, 1, true) ~= nil
end

local function count(text, needle)
    local total, start = 0, 1
    while true do
        local first, last = text:find(needle, start, true)
        if not first then return total end
        total, start = total + 1, last + 1
    end
end

-- The provider generated from the checkout's titan/gc.titan source.
local function provider_c()
    local source = read_file("titan/gc.titan")
    h.reset(true)
    local ast = assert(h.parse(source, "titan/gc.titan"))
    return h.with_resolver_context(nil, function(context)
        local loader = driver.defaultloader({}, { context = context })
        return driver.with_loader(loader, function(active)
            local _, errors = checker.check(
                "titan.gc", ast, source, "titan/gc.titan", active)
            assert.equal(0, #errors, table.concat(errors, "\n"))
            local generated = coder.generate(
                "titan.gc", ast, {}, driver.TITAN_ABI_VERSION)
            local parts = {}
            for _, part in ipairs(generated.parts) do parts[#parts + 1] = part.code end
            return table.concat(parts, "\n")
        end)
    end)
end

describe("gc.keep_alive intrinsic", function()
    after_each(clean)

    it("calls no entry and boxes no stable argument at direct call sites", function()
        local provider = provider_c()
        assert.truthy(provider:find(KEEP_ALIVE_ENTRY .. "%b()%s*{"), KEEP_ALIVE_ENTRY)

        local csrc = build([[
            local gc = import "gc"
            local collector = import "gc"

            interface Named
                name: string
            end

            record Box
                const name: string
            end

            function direct(text: string, named: Named, slice: owned int[],
                            box: Box?)
                gc.keep_alive(text)
                gc.keep_alive(named)
                gc.keep_alive(42)
                gc.keep_alive { v = slice }
                gc.keep_alive<|Box?|>(box)
                collector.keep_alive(text)
            end

            function rooted_field(box: Box)
                gc.keep_alive(box.name)
            end

            function ordinary_direct()
                gc.collect()
            end

            function indirect(text: string)
                const f: function (string): () = gc.keep_alive
                f(text)
            end
        ]])
        local direct = native_body(csrc, "direct")
        for _, forbidden in ipairs({ KEEP_ALIVE_PREFIX, "titan_wrap_interface",
                                     "setivalue", "setsvalue", "setuvalue",
                                     "setobj", "luaC_checkGC", "_base_off" }) do
            assert.falsy(contains(direct, forbidden), forbidden .. "\n" .. direct)
        end
        assert.equal(6, count(direct, "(void)(_tmp_"), direct)

        -- A field read is re-read from a home other code can overwrite, so
        -- the intrinsic roots it in one borrowed frame slot without a call.
        local field = native_body(csrc, "rooted_field")
        assert.falsy(contains(field, KEEP_ALIVE_PREFIX), field)
        assert.equal(1, count(field, "setsvalue(L, s2v((restorestack(L, _base_off) + 0))"), field)

        -- Controls: an ordinary direct call references its entry, and a
        -- first-class keep_alive loads the provider's closure.
        assert.truthy(contains(native_body(csrc, "ordinary_direct"),
            coder_names._function_prefix("titan.gc", "collect") .. "_titan"))
        local indirect = native_body(csrc, "indirect")
        assert.truthy(contains(indirect, KEEP_ALIVE_PREFIX .. "_closure_slot"), indirect)
    end)

    it("keeps a reentrantly retired value reachable under -O2", function()
        h.with_extra_cflags({ "-O2" }, function()
            build([[
                local gc = import "gc"

                record Payload
                    const label: string
                end

                record Owner
                    slot: Payload?
                end

                record Probe
                    const weak: {value: value}
                    finalized: integer
                    live_in_callback: boolean
                end

                local function track(probe: Probe, owner: Owner)
                    const payload = Payload("tracked")
                    probe.weak[1] = payload
                    gc.finalizable<|Payload|>(payload, function(_: Payload)
                        probe.finalized = probe.finalized + 1
                    end)
                    owner.slot = payload
                end

                local function deliver(owner: Owner, callback: function (Owner))
                    const kept? = owner.slot
                    owner.slot = Payload("replacement")
                    callback(owner)
                    gc.keep_alive(kept)
                end

                -- Oracle control: a delivery that retains nothing.
                local function deliver_unkept(owner: Owner, callback: function (Owner))
                    owner.slot = Payload("replacement")
                    callback(owner)
                end

                function new_probe(): Probe
                    const weak: {value: value} = {}
                    gc.weak(weak)
                    return Probe(weak, 0, false)
                end

                function run(probe: Probe, kept: boolean, fail: boolean): boolean
                    const owner = Owner(nil)
                    track(probe, owner)
                    const callback = function(target: Owner)
                        target.slot = Payload("callback")
                        for index = 1, 256 do
                            const churn = { Payload("churn " .. index) }
                            if #churn ~= 1 then raise "lost churn" end
                        end
                        gc.collect()
                        gc.collect()
                        probe.live_in_callback = probe.weak[1] ~= nil
                            and probe.finalized == 0
                        if fail then raise "boom" end
                    end
                    local raised = false
                    do
                        if kept then
                            deliver(owner, callback)
                        else
                            deliver_unkept(owner, callback)
                        end
                    catch
                        raised = error == "boom"
                    end
                    return raised
                end
            ]])
        end)
        local ok, err = h.call("test", [[
            local function after(probe)
                collectgarbage("collect")
                collectgarbage("collect")
                return probe.finalized, probe.weak[1]
            end
            local probe = test.new_probe()
            assert(test.run(probe, true, false) == false)
            assert(probe.live_in_callback, "rooted payload died during delivery")
            local finalized, weak = after(probe)
            assert(finalized == 1 and weak == nil, "rooted payload outlived its frame")

            probe = test.new_probe()
            assert(test.run(probe, true, true) == true)
            assert(probe.live_in_callback, "rooted payload died before raise")
            finalized, weak = after(probe)
            assert(finalized == 1 and weak == nil, "raised frame retained its payload")

            probe = test.new_probe()
            assert(test.run(probe, false, false) == false)
            assert(not probe.live_in_callback, "the oracle missed an unkept payload")
            assert(probe.finalized == 1)
        ]])
        assert.truthy(ok, err)
    end)

    it("preserves argument order, effects and raises", function()
        build([[
            local gc = import "gc"

            log: {string} = {}

            local function note(label: string): string
                log[#log + 1] = label
                return label
            end

            local function nothing()
                log[#log + 1] = "nothing"
            end

            local function fail(): string
                raise "boom"
            end

            local function forward(label: string)
                return gc.keep_alive(note(label))
            end

            local function joined(): string
                local text = ""
                for index = 1, #log do text = text .. log[index] .. ";" end
                return text
            end

            function run(): string
                log = {}
                gc.keep_alive(note("positional"))
                gc.keep_alive { v = note("named") }
                gc.keep_alive(note("first"), note("surplus"), nothing())
                forward("tail")
                do
                    gc.keep_alive(note("before"), fail())
                catch
                    log[#log + 1] = error as string
                end
                return joined()
            end
        ]])
        local ok, err = h.call("test", [[
            local text = test.run()
            assert(text == "positional;named;first;surplus;nothing;tail;before;boom;", text)
        ]])
        assert.truthy(ok, err)
    end)

    it("admits the generic entry's types on direct and first-class uses", function()
        h.assert_type_check([[
            local gc = import "gc"

            record Box
                const name: string
            end

            local function hold<|U|>(item: U)
                gc.keep_alive(item)
            end

            function forms(box: Box, text: string?, cells: (owned int[])?,
                           any: value)
                gc.keep_alive(box)
                gc.keep_alive(text)
                gc.keep_alive(cells)
                gc.keep_alive(any)
                gc.keep_alive(nil)
                gc.keep_alive()
                gc.keep_alive<|integer|>(1)
                hold(box)
                const f: function (Box?): () = gc.keep_alive
                f(box)
            end
        ]])
    end)

    it("rejects borrowed C carriers, void and zero-result values", function()
        local header = temporary.name(".h")
        local file = assert(io.open(header, "wb"))
        assert(file:write([[
typedef int keep_alive_cells[4];
typedef struct keep_alive_pair { int left; int right; } keep_alive_pair;
typedef int (*keep_alive_compare)(const void *, const void *);
]]))
        assert(file:close())
        local transient = "has no sound transient round trip"
        local no_values = "a function returning no values cannot be used as a value"
        local cases = {
            { transient, [[function bad(p: foreign *int) gc.keep_alive(p) end]] },
            { transient,
              [[function bad(p: foreign *int) gc.keep_alive<|foreign *int|>(p) end]] },
            { transient, [[
                function bad(p: foreign *int)
                    const f: function (foreign *int): () = gc.keep_alive
                    f(p)
                end]] },
            { transient,
              [[function bad() gc.keep_alive<|foreign keep_alive_cells|>(nil) end]] },
            { transient,
              [[function bad(pair: foreign keep_alive_pair) gc.keep_alive(pair) end]] },
            { transient, [[
                function bad(compare: foreign keep_alive_compare)
                    gc.keep_alive(compare)
                end]] },
            { transient, [[
                function bad()
                    const f: function (foreign keep_alive_compare): () = gc.keep_alive
                end]] },
            { transient, [[function bad() gc.keep_alive<|foreign void|>(nil) end]] },
            -- A zero-result call is not a value for keep_alive, exactly as for
            -- any other call; only the void type argument is a type error.
            { no_values, [[
                local function nothing() end
                function bad() gc.keep_alive(nothing()) end]] },
            { no_values, [[function bad() local result = gc.keep_alive(1) end]] },
        }
        local completed, failure = pcall(function()
            for _, case in ipairs(cases) do
                local ok, err = h.run_checker('local gc = import "gc"\n'
                    .. 'foreign import "' .. header .. '"\n' .. case[2])
                assert.falsy(ok, case[2])
                assert.truthy(contains(err, case[1]), case[2] .. "\n" .. err)
            end
        end)
        os.remove(header)
        assert.truthy(completed, failure)
    end)
end)
