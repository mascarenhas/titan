-- Compile against one DSO, replace only that DSO, then load the unchanged
-- consumer in a fresh Lua process. No source file or paired archive is ever
-- available to turn these checks into source/static linking accidentally.
local h = require "spec.support.helpers"
local lfs = require "lfs"
local driver = require "titan-compiler.driver"

local generated = {}
local serial = 0

-- Native interface inspection deliberately caches dlopen handles for the
-- process lifetime. Different cases need different logical/provider names;
-- replacement within one case keeps exactly the same names and paths.
local function scoped(text)
    return (text:gsub("bc180_", "bc180_" .. serial .. "_"))
end

local function call(code)
    return h.call("string", scoped(code))
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        assert(lfs.rmdir(path))
    elseif mode then
        assert(os.remove(path))
    end
end

local function read(path)
    local file = assert(io.open(scoped(path), "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local function build(modules)
    for _, module in ipairs(modules) do
        module.name, module.src = scoped(module.name), scoped(module.src)
        generated[module.name] = true
        assert.is_nil(lfs.attributes(module.name .. ".titan"))
        assert.is_nil(lfs.attributes(module.name .. ".a"))
    end
    local ok, err = h.build_so_chain(modules)
    assert.truthy(ok, err)
    for _, module in ipairs(modules) do
        assert.is_nil(lfs.attributes(module.name .. ".a"))
    end
end

local function fixture(provider, consumer)
    build({
        { name = "bc180_provider", src = provider },
        { name = "bc180_consumer", src = consumer },
    })
    return read("bc180_consumer.so")
end

local function replace(provider, consumer_image)
    build({ { name = "bc180_provider", src = provider } })
    assert.truthy(read("bc180_consumer.so") == consumer_image,
        "provider replacement changed the consumer binary")
end

local function runs(body)
    local ok, out = call([[
        local consumer = require "bc180_consumer"
    ]] .. body)
    assert.truthy(ok, out)
end

local function rejects(entity)
    local ok, out = call(string.format([[
        for attempt = 1, 2 do
            local ok, err = pcall(require, "bc180_consumer")
            assert(not ok, "incompatible replacement loaded on attempt " .. attempt)
            assert(type(err) == "string", "load failure was not a diagnostic")
            assert(err:lower():find("compatib", 1, true), err)
            assert(err:find(%q, 1, true), err)
        end
    ]], entity))
    assert.truthy(ok, out)
end

describe("selective binary dependency compatibility", function()
    before_each(function() serial = serial + 1 end)
    after_each(function()
        for name in pairs(generated) do
            for _, suffix in ipairs({ ".c", ".o", ".so", ".a",
                    ".ffi.h", ".titan.h", ".so.dSYM" }) do
                remove_tree(name .. suffix)
            end
        end
        generated = {}
    end)

    it("accepts removal, addition and type changes of unused declarations", function()
        local image = fixture([[
            unused: integer = 7
            function removed(): integer return 5 end
            function changed(input: integer): integer return input end
            function answer(): integer return 41 end
            record Unused item: integer end
        ]], [[
            local p = import "bc180_provider"
            function run(): integer return p.answer() end
        ]])
        runs("assert(consumer.run() == 41)")
        replace([[
            function added(): string return "new" end
            function answer(): integer return 42 end
            function changed(input: string): string return input end
            unused: string = "changed"
            record Unused item: string; extra: boolean end
        ]], image)
        runs("assert(consumer.run() == 42)")
    end)

    it("resolves moved variable and canonical callable slots without changing direct calls", function()
        local image = fixture([[
            counter: integer = 10
            spare: integer = 2
            function answer(input: integer): integer return input + counter end
            function unused(): integer return -1 end
            record Box n: integer end
            function Box.answer(input: integer): integer return input + 100 end
        ]], [[
            local p = import "bc180_provider"
            function run(): integer
                p.counter = p.counter + 1
                local answer = p.answer
                local static = p.Box.answer
                return p.answer(1) + answer(2) + static(3) + p.counter
            end
            function get_function(): function(integer): integer
                return p.answer
            end
            function get_static(): function(integer): integer
                return p.Box.answer
            end
        ]])
        runs([[
            local p = require "bc180_provider"
            assert(rawequal(consumer.get_function(), p.answer))
            assert(rawequal(consumer.get_static(), p.Box.answer))
            assert(consumer.run() == 139)
            assert(p.counter == 11 and p.spare == 2)
        ]])
        replace([[
            extra: string = "shifts every later slot"
            spare: integer = 9
            counter: integer = 20
            function unused(): integer return -2 end
            function added(): integer return -3 end
            function answer(input: integer): integer return input + counter end
            record Earlier n: integer end
            record Box n: integer end
            function Box.aaa(): integer return -4 end
            function Box.answer(input: integer): integer return input + 200 end
        ]], image)
        runs([[
            local p = require "bc180_provider"
            assert(rawequal(consumer.get_function(), p.answer))
            assert(rawequal(consumer.get_static(), p.Box.answer))
            assert(consumer.run() == 269)
            assert(p.counter == 21 and p.spare == 9)
            assert(p.extra == "shifts every later slot")
        ]])
    end)

    local changed_functions = {
        { name = "parameter type", replacement = [[
            function consume(input: string): integer return 42 end
        ]] },
        { name = "parameter name", replacement = [[
            function consume(renamed: integer): integer return renamed end
        ]] },
        { name = "result type", replacement = [[
            function consume(input: integer): string return "changed" end
        ]] },
        { name = "variadic input", replacement = [[
            function consume(input: integer, ...: integer): integer return input end
        ]] },
        { name = "flexible results", replacement = [[
            function consume(input: integer): (...: integer) return input end
        ]] },
        { name = "removal", replacement = [[
            function other(input: integer): integer return input end
        ]] },
    }
    for _, case in ipairs(changed_functions) do
        it("rejects a used function's changed " .. case.name, function()
            local image = fixture([[
                function consume(input: integer): integer return input end
            ]], [[
                local p = import "bc180_provider"
                function run(): integer return p.consume { input = 42 } end
            ]])
            replace(case.replacement, image)
            rejects("consume")
        end)
    end

    it("checks a nominal-only dependency when another image owns canonical state", function()
        build({ { name = "bc180_consumer", src = [[
            function seed(): integer return 1 end
        ]] } })
        local seed = assert(io.open(scoped("bc180_seed.so"), "wb"))
        seed:write(read("bc180_consumer.so"))
        seed:close()
        generated[scoped("bc180_seed")] = true
        local image = fixture([[
            record Box n: integer end
        ]], [[
            local p = import "bc180_provider"
            function read(box: p.Box): integer return box.n end
        ]])
        replace("record Box n: string end", image)
        local ok, out = call([[
            local seed = assert(package.loadlib("./bc180_seed.so",
                "luaopen_bc180_consumer"))()
            assert(seed.seed() == 1)
            -- Select the second physical image while retaining the first
            -- image's canonical registry userdata.
            package.preload.bc180_consumer = nil
            for attempt = 1, 2 do
                local ok, err = pcall(require, "bc180_consumer")
                assert(not ok, "reused state bypassed the only dependency check")
                assert(err:find("compatibility", 1, true), err)
                assert(err:find("Box", 1, true), err)
            end
        ]])
        assert.truthy(ok, out)
    end)

    it("keeps verification independent of mutable Lua globals", function()
        local image = fixture([[
            function answer(): integer return 1 end
        ]], [[
            local p = import "bc180_provider"
            function run(): integer return p.answer() end
        ]])
        replace("function answer(): string return 'changed' end", image)
        local ok, out = call([[
            type = function() return "table" end
            next = function() return nil end
            error = function() end
            local ok, err = pcall(require, "bc180_consumer")
            assert(not ok, "mutable globals disabled the verifier")
            assert(err:find("compatibility", 1, true), err)
            assert(err:find("answer", 1, true), err)
        ]])
        assert.truthy(ok, out)
    end)

    it("tracks writes even when an imported variable is never read", function()
        local image = fixture("target: integer = 1", [[
            local p = import "bc180_provider"
            function store() p.target = 42 end
        ]])
        replace("target: string = \"changed\"", image)
        rejects("target")
    end)

    it("rejects a mutable imported variable becoming const", function()
        local image = fixture("target: integer = 1", [[
            local p = import "bc180_provider"
            function run(): integer return p.target end
        ]])
        replace("const target: integer = 1", image)
        rejects("target")
    end)

    it("checks canonical generic signatures rather than individual instantiations", function()
        local image = fixture([[
            record Box<|T|> item: T end
            function identity<|T|>(input: T): T return input end
            function make<|T|>(input: T): Box<|T|> return Box.new(input) end
        ]], [[
            local p = import "bc180_provider"
            function number(): integer return p.identity<|integer|>(42) end
            function text(): string return p.identity<|string|>("forty-two") end
            function boxed(): integer return p.make<|integer|>(42).item end
        ]])
        runs([[
            assert(consumer.number() == 42)
            assert(consumer.text() == "forty-two")
            assert(consumer.boxed() == 42)
        ]])
        replace([[
            function unused(): string return "new" end
            record Box<|Element|> item: Element end
            function make<|Element|>(input: Element): Box<|Element|>
                return Box.new(input)
            end
            function identity<|Element|>(input: Element): Element return input end
        ]], image)
        runs([[
            assert(consumer.number() == 42)
            assert(consumer.text() == "forty-two")
            assert(consumer.boxed() == 42)
        ]])
    end)

    it("accepts changed private record storage and unused concrete members", function()
        local image = fixture([[
            record Box
                local hidden: integer
                n: integer
                text: string
            end
            function make(): Box return Box.new(1, 40, "old") end
            function Box:read(): integer return self.n end
            function Box:unused(): integer return 1 end
            function Box.unused_static(): integer return 2 end
        ]], [[
            local p = import "bc180_provider"
            function run(): integer
                local box = p.make()
                box.n = box.n + 2
                return box:read()
            end
            function text(): string return p.make().text end
        ]])
        local function public_prefix()
            return assert(read("bc180_provider.c"):match(
                "typedef struct {([^{}]*)} _titan_nominal_[%w_]+_public_payload;"))
        end
        local prefix = public_prefix()
        replace([[
            record Box
                local hidden: string
                local extra: integer
                n: integer
                local another: string
                text: string
            end
            function Box:read(): integer return self.n end
            function make(): Box return Box.new("private", 7, 50, "more", "new") end
            function Box:added(): string return "new" end
        ]], image)
        assert.equal(prefix, public_prefix(),
            "private changes altered the compatible public C prefix")
        runs([[
            assert(consumer.run() == 52)
            assert(consumer.text() == "new")
        ]])
    end)

    local record_changes = {
        { name = "type", fields = "n: string; text: string", args = '"1", "x"' },
        { name = "order", fields = "text: string; n: integer", args = '"x", 1' },
        { name = "constness", fields = "const n: integer; text: string", args = '1, "x"' },
        { name = "addition", fields = "n: integer; text: string; more: integer", args = '1, "x", 2' },
    }
    for _, case in ipairs(record_changes) do
        it("rejects a referenced record's changed public field " .. case.name, function()
            local image = fixture([[
                record Box n: integer; text: string end
                function make(): Box return Box.new(1, "x") end
            ]], [[
                local p = import "bc180_provider"
                function run(): integer return p.make().n end
            ]])
            replace("record Box " .. case.fields .. " end\n" ..
                "function make(): Box return Box.new(" .. case.args .. ") end", image)
            rejects("Box")
        end)
    end

    it("accepts the first private record field for accessor-only consumers", function()
        local image = fixture([[
            record Box n: integer end
            function make(): Box return Box.new(41) end
        ]], [[
            local p = import "bc180_provider"
            function run(): integer return p.make().n end
        ]])
        replace([[
            record Box n: integer; local hidden: string end
            function make(): Box return Box.new(42, "private") end
        ]], image)
        runs("assert(consumer.run() == 42)")
    end)

    it("rejects removal of public new used implicitly by a record literal", function()
        local image = fixture("record Box n: integer end", [[
            local p = import "bc180_provider"
            function run(): integer
                local box: p.Box = { n = 42 }
                return box.n
            end
        ]])
        runs("assert(consumer.run() == 42)")
        replace("record Box n: integer; local hidden: string end", image)
        rejects("new")
    end)

    it("tracks a bound method even when no direct method call exists", function()
        local image = fixture([[
            record Box n: integer end
            function Box:add(amount: integer): integer return self.n + amount end
        ]], [[
            local p = import "bc180_provider"
            function run(box: p.Box): function(integer): integer
                return box:add
            end
        ]])
        replace([[
            record Box n: integer end
            function Box:add(renamed: integer): integer return self.n + renamed end
        ]], image)
        rejects("add")
    end)

    it("keeps public union tags stable across private additions and ordinary fallthrough", function()
        local image = fixture([[
            union Choice first(n: integer); second(text: string) end
            function make(which: integer): Choice
                if which == 1 then return Choice.first(41) end
                return Choice.second("public")
            end
        ]], [[
            local p = import "bc180_provider"
            function run(which: integer): integer
                local result = 99
                case p.make(which)
                when first(n) then result = n
                when second(text) then result = #text
                end
                return result
            end
        ]])
        replace([[
            union Choice
                local hidden()
                first(n: integer)
                local another(value: string)
                second(text: string)
            end
            function make(which: integer): Choice
                if which == 1 then return Choice.first(42) end
                if which == 2 then return Choice.second("public") end
                return Choice.hidden()
            end
        ]], image)
        runs([[
            assert(consumer.run(1) == 42)
            assert(consumer.run(2) == 6)
            assert(consumer.run(3) == 99)
        ]])
    end)

    local union_changes = {
        { name = "variant order", declaration = "second(); first(n: integer)" },
        { name = "payload name", declaration = "first(renamed: integer); second()" },
        { name = "payload type", declaration = "first(n: string); second()" },
        { name = "public addition", declaration = "first(n: integer); second(); third()" },
    }
    for _, case in ipairs(union_changes) do
        it("rejects a referenced union's changed " .. case.name, function()
            local image = fixture([[
                union Choice first(n: integer); second() end
            ]], [[
                local p = import "bc180_provider"
                function run(choice: p.Choice): integer
                    local result = 0
                    case choice
                    when first(n) then result = n
                    end
                    return result
                end
            ]])
            replace("union Choice " .. case.declaration .. " end", image)
            rejects("Choice")
        end)
    end

    for _, trailing_else in ipairs({ "", "else local unreachable = 1" }) do
        local label = trailing_else == "" and "without else" or "with a falling-through else"
        it("rejects private union additions invalidating a return proof " .. label, function()
            local image = fixture("union Choice first(); second() end", [[
                local p = import "bc180_provider"
                function run(choice: p.Choice): string
                    case choice
                    when first() then return "first"
                    when second() then return "second"
            ]] .. trailing_else .. [[
                    end
                end
            ]])
            replace("union Choice local hidden(); first(); second() end", image)
            rejects("Choice")
        end)
    end

    it("accepts private union additions when an else independently returns", function()
        local image = fixture([[
            union Choice first(); second() end
            function make(): Choice return Choice.first() end
        ]], [[
            local p = import "bc180_provider"
            function run(): string
                case p.make()
                when first() then return "first"
                when second() then return "second"
                else return "private"
                end
            end
        ]])
        replace([[
            union Choice local hidden(); first(); second() end
            function make(): Choice return Choice.hidden() end
        ]], image)
        runs('assert(consumer.run() == "private")')
    end)

    it("checks every Interface method even when the consumer calls only one", function()
        local image = fixture([[
            interface Reader
                function read(): integer
                function unused(limit: integer): integer
            end
        ]], [[
            local p = import "bc180_provider"
            function run(reader: p.Reader): integer return reader:read() end
        ]])
        replace([[
            interface Reader
                function read(): integer
                function unused(renamed: integer): integer
            end
        ]], image)
        rejects("Reader")
    end)

    it("checks ordered Interface fields even when the consumer reads only one", function()
        local image = fixture([[
            interface Reader first: integer; second: integer end
        ]], [[
            local p = import "bc180_provider"
            function run(reader: p.Reader): integer return reader.first end
        ]])
        replace("interface Reader second: integer; first: integer end", image)
        rejects("Reader")
    end)

    it("tracks concrete methods used only by implicit Interface conversion", function()
        local image = fixture([[
            record Box n: integer end
            function make(): Box return Box.new(40) end
            function Box:add(amount: integer): integer return self.n + amount end
        ]], [[
            local p = import "bc180_provider"
            interface Adder function add(amount: integer): integer end
            function run(): integer
                local wrapped: Adder = p.make()
                return wrapped:add(2)
            end
        ]])
        runs("assert(consumer.run() == 42)")
        replace([[
            record Box n: integer end
            function make(): Box return Box.new(40) end
            function Box:add(renamed: integer): integer return self.n + renamed end
        ]], image)
        rejects("add")
    end)

    it("checks transitive nominal-owner methods without requiring a direct import", function()
        build({
            { name = "bc180_owner", src = [[
                record Box n: integer end
                function make(): Box return Box.new(42) end
                function Box:read(): integer return self.n end
            ]] },
            { name = "bc180_provider", src = [[
                local owner = import "bc180_owner"
                type Item = owner.Box
                function make(): Item return owner.make() end
            ]] },
            { name = "bc180_consumer", src = [[
                local p = import "bc180_provider"
                function run(): integer return p.make():read() end
            ]] },
        })
        local consumer_image = read("bc180_consumer.so")
        local provider_image = read("bc180_provider.so")
        runs("assert(consumer.run() == 42)")
        build({ { name = "bc180_owner", src = [[
            record Box n: integer end
            function make(): Box return Box.new(42) end
            function Box:read(): string return "changed" end
        ]] } })
        assert.truthy(read("bc180_consumer.so") == consumer_image)
        assert.truthy(read("bc180_provider.so") == provider_image)
        rejects("read")
    end)

    it("requires a referenced nominal alias to remain exposed", function()
        build({ { name = "bc180_owner", src = "record Box n: integer end" } })
        local image = fixture([[
            local owner = import "bc180_owner"
            type Item = owner.Box
        ]], [[
            local p = import "bc180_provider"
            function run(item: p.Item): integer return item.n end
        ]])
        replace([[
            local owner = import "bc180_owner"
            type Renamed = owner.Box
        ]], image)
        rejects("Item")
    end)

    it("rejects rebinding a nominal alias to a structurally identical owner", function()
        build({
            { name = "bc180_owner", src = "record Box n: integer end" },
            { name = "bc180_other", src = "record Box n: integer end" },
        })
        local image = fixture([[
            local owner = import "bc180_owner"
            type Item = owner.Box
        ]], [[
            local p = import "bc180_provider"
            function run(item: p.Item): integer return item.n end
        ]])
        replace([[
            local owner = import "bc180_other"
            type Item = owner.Box
        ]], image)
        rejects("Item")
    end)

    local function fake_provider(body)
        local file = assert(io.open(scoped("bc180_provider.c"), "w"))
        file:write([[
            typedef struct lua_State lua_State;
            extern const char *lua_pushstring(lua_State *, const char *);
        ]], scoped(body))
        file:close()
        local shared = driver.IS_DARWIN and "-shared -undefined dynamic_lookup" or "-shared"
        local ok = os.execute(table.concat({ driver.CC, "-fPIC", shared,
            scoped("-o bc180_provider.so bc180_provider.c") }, " "))
        assert.truthy(ok, "could not compile protocol fixture")
    end

    it("does not consult replacement DSOs for a same-binary source dependency", function()
        local sources = {
            bc180_provider = "function answer(): integer return 42 end",
            bc180_consumer = [[
                local p = import "bc180_provider"
                function run(): integer return p.answer() end
            ]],
        }
        local modules = {}
        for name, source in pairs(sources) do
            modules[scoped(name)] = scoped(source)
            generated[scoped(name)] = true
        end
        local ok, err = h.generate_modules(modules, scoped("bc180_consumer"))
        assert.truthy(ok, err)
        local image = read("bc180_consumer.so")
        fake_provider([[
            int bc180_provider_abi(lua_State *L) {
                lua_pushstring(L, "wrong ABI"); return 1;
            }
        ]])
        assert.truthy(read("bc180_consumer.so") == image)
        runs("assert(consumer.run() == 42)")
    end)

    it("checks ABI before looking for compatibility metadata", function()
        fixture("function answer(): integer return 42 end", [[
            local p = import "bc180_provider"
            function run(): integer return p.answer() end
        ]])
        fake_provider([[
            int bc180_provider_abi(lua_State *L) {
                lua_pushstring(L, "wrong ABI"); return 1;
            }
        ]])
        local ok, out = call([[
            local ok, err = pcall(require, "bc180_consumer")
            assert(not ok, "wrong ABI loaded")
            assert(err:find("ABI", 1, true), err)
            assert(not err:lower():find("compatib", 1, true), err)
        ]])
        assert.truthy(ok, out)
    end)

    it("rejects a missing compatibility entry before resolving native functions", function()
        fixture("function answer(): integer return 42 end", [[
            local p = import "bc180_provider"
            function run(): integer return p.answer() end
        ]])
        fake_provider([[
            int bc180_provider_abi(lua_State *L) {
                lua_pushstring(L, "2"); return 1;
            }
        ]])
        rejects("missing")
    end)

    it("rejects a malformed compatibility chunk before initialization", function()
        fixture("function answer(): integer return 42 end", [[
            local p = import "bc180_provider"
            function run(): integer return p.answer() end
        ]])
        fake_provider([[
            int bc180_provider_abi(lua_State *L) {
                lua_pushstring(L, "2"); return 1;
            }
            int bc180_provider_compatibility(lua_State *L) {
                lua_pushstring(L, "this is not a valid Lua chunk"); return 1;
            }
        ]])
        rejects("compatib")
    end)

    describe("incremental replacement", function()
        local workspace

        before_each(function()
            workspace = os.tmpname()
            assert(os.remove(workspace))
            assert(lfs.mkdir(workspace))
        end)

        after_each(function()
            remove_tree(workspace)
            remove_tree(scoped("bc180_consumer.lua"))
        end)

        it("retains dynamic slots and transitive checks through compile-only and warm final links", function()
            local cdriver = require "c-parser.cdriver"
            local repository = assert(lfs.currentdir())
            local prefix = os.getenv("TITAN_ROCKS_ROOT")
            if not prefix or prefix == "" then prefix = os.getenv("PREFIX") end
            if not prefix or prefix == "" then
                for template in package.cpath:gmatch("[^;]+") do
                    prefix = template:match("^(.*)/lib/lua/5[.]5/[?][.]so$")
                    if prefix then break end
                end
            end
            assert(prefix, "incremental compatibility requires an installed SDK")
            local function compile(...)
                local argv = {
                    "env", "TITAN_RUNTIME_PREBUILT=1", "CCACHE_DISABLE=1",
                    "TITAN_PROBE_CACHE_DISABLE=1", "TITAN_ROCKS_ROOT=" .. prefix,
                    "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=-O0 -fno-lto",
                    "TITAN_EXTRA_LDFLAGS=-fno-lto", prefix .. "/bin/lua", "-E", "-e",
                    string.format("package.path = %q .. package.path; package.cpath = %q .. package.cpath",
                        repository .. "/?.lua;" .. repository .. "/?/init.lua;",
                        repository .. "/titan-runtime/bootstrap/?.so;"),
                    repository .. "/titanc", "--tree", workspace,
                }
                for _, argument in ipairs({ ... }) do
                    argv[#argv + 1] = scoped(argument)
                end
                local quoted = {}
                for i, argument in ipairs(argv) do
                    quoted[i] = assert(cdriver.shell_quote(argument))
                end
                local pipe = assert(io.popen(table.concat(quoted, " ") .. " 2>&1", "r"))
                local output = assert(pipe:read("*a"))
                local ok = pipe:close()
                assert.is_true(ok, output)
            end

            build({
                { name = "bc180_owner", src = [[
                    record Item n: integer end
                    function make(): Item return Item.new(7) end
                    function Item:read(): integer return self.n end
                ]] },
                { name = "bc180_provider", src = [[
                    local owner = import "bc180_owner"
                    counter: integer = 10
                    function answer(delta: integer): integer return counter + delta end
                    function make(): owner.Item return owner.make() end
                    record Box n: integer end
                    function Box.answer(): integer return 100 end
                ]] },
            })
            local stem = workspace .. "/bc180_consumer"
            local file = assert(io.open(scoped(stem .. ".titan"), "w"))
            assert(file:write(scoped([[
                local p = import "bc180_provider"
                function run(): integer
                    p.counter = p.counter + 1
                    local answer = p.answer
                    local static = p.Box.answer
                    local item = p.make()
                    local method = item:read
                    return answer(1) + p.answer(2) + static() + method()
                end
            ]])))
            assert(file:close())
            generated[scoped("bc180_consumer")] = true

            compile("-c", "--incremental", "bc180_consumer")
            local object = read(stem .. ".o")
            local future = os.time() + 60
            assert(lfs.touch(scoped(stem .. ".o"), future))
            for _ = 1, 2 do
                compile("--incremental", "bc180_consumer")
                assert.equal(future, lfs.attributes(scoped(stem .. ".o"), "modification"))
                assert.truthy(read(stem .. ".o") == object,
                    "warm final link rebuilt the compile-only consumer object")
                runs("assert(consumer.run() == 132)")
            end

            local image = read("bc180_consumer.so")
            replace([[
                local owner = import "bc180_owner"
                unrelated: string = "moves variable and closure slots"
                counter: integer = 20
                function unused(): integer return -1 end
                function make(): owner.Item return owner.make() end
                function answer(delta: integer): integer return counter + delta end
                record Box n: integer end
                function Box.aaa(): integer return -2 end
                function Box.answer(): integer return 200 end
            ]], image)
            runs("assert(consumer.run() == 252)")
            build({ { name = "bc180_owner", src = [[
                record Item n: integer end
                function make(): Item return Item.new(7) end
                function Item:read(): string return "incompatible" end
            ]] } })
            assert.truthy(read("bc180_consumer.so") == image)
            assert.truthy(read(stem .. ".o") == object)
            rejects("read")
        end)
    end)
end)
