local h = require "spec.support.helpers"

local run_checker = h.run_checker
local run_checker_modules = h.run_checker_modules
local check_errs = h.check_errs

local function assert_check(source)
    local ok, err = run_checker(source)
    assert.truthy(ok, err)
end

local function assert_error(pattern, source)
    local ok, err = run_checker(source)
    assert.falsy(ok)
    assert.match(pattern, err)
    return err
end

describe("top-level declaration order", function()
    it("predeclares records, constructors, functions, and methods", function()
        assert_check([[
            local origin = Point.new { y = 2, x = 1 }
            local unit: Point = { x = 1, y = 1 }

            function Point.scaled(n: integer): Point
                return Point.new(n * 2, n * 3)
            end

            function Point:sum(): integer
                return self.x + self.y
            end

            record Point
                x: integer
                y: integer
            end

            function answer(): integer
                return origin:sum() + unit:sum() + Point.scaled(4):sum()
            end
        ]])
    end)

    it("uses the complete forward constructor signature", function()
        assert_error("types in argument 2 of call to function 'Point%.new' do not match, expected integer but found nil", [[
            local bad = Point.new(1)

            record Point
                x: integer
                y: integer
            end
        ]])
    end)

    it("lets signatures use an import written later", function()
        local ok, err = run_checker_modules({
            dep = [[
                record Point x: integer end
            ]],
            main = [[
                function read(point: dep.Point): integer
                    return point.x
                end

                record Holder
                    point: dep.Point
                end

                local dep = import "dep"
            ]],
        }, "main")
        assert.truthy(ok, err)
    end)

    it("keeps imports sequential for module-variable initializers", function()
        local ok, err = run_checker_modules({
            dep = [[
                record Point x: integer end
            ]],
            main = [[
                local point = dep.Point.new(1)
                local dep = import "dep"
            ]],
        }, "main")
        assert.falsy(ok)
        assert.match("variable 'dep' not declared", err)

        ok, err = run_checker_modules({
            dep = [[
                record Point x: integer end
            ]],
            main = [[
                local point: dep.Point? = nil
                local dep = import "dep"
            ]],
        }, "main")
        assert.falsy(ok)
        assert.match("module 'dep' referenced by type not found", err)
    end)

    it("lets qualified aliases use an import written later", function()
        local ok, err = run_checker_modules({
            dep = [[
                record Point x: integer end
            ]],
            main = [[
                type Point = dep.Point
                function read(point: Point): integer
                    return point.x
                end
                local dep = import "dep"
            ]],
        }, "main")
        assert.truthy(ok, err)
    end)

    it("keeps module variables sequential inside lambda initializers",
       function()
        assert_check([[
            local earlier = 1
            local read = function(): integer
                return earlier
            end
        ]])

        assert_error("variable 'later' not declared", [[
            local read = function(): integer
                return later
            end
            local later = 1
        ]])
    end)

    it("still rejects a record member whose owner is absent or not a record",
       function()
        assert_error("record referenced by method declaration 'Missing:get' does not exist", [[
            function Missing:get(): integer
                return 0
            end
        ]])

        assert_error("member referenced by record function declaration 'NotRecord.make' is not a record", [[
            function NotRecord.make(): integer
                return 0
            end
            local NotRecord = 1
        ]])
    end)

    it("rejects a reserved non-module in a qualified type cleanly", function()
        assert_error("module 'NotModule' referenced by type not found", [[
            function read(item: NotModule.Item): integer
                return 0
            end
            local NotModule = 1
        ]])
    end)

    it("checks forward record member conflicts", function()
        assert_error("cannot declare method 'Box:make' as field 'make' exists in record 'Box'", [[
            function Box:make()
            end
            record Box
                make: integer
            end
        ]])

        assert_error("redeclaration of record function 'Box%.new'", [[
            function Box.new(): Box
                return { n = 1 }
            end
            function Box.new(): Box
                return { n = 2 }
            end
            record Box
                n: integer
            end
        ]])
    end)

    it("reports only the written duplicate record", function()
        local errs = check_errs([[
            record Box
                x: integer
            end
            record Box
                y: string
            end
            local box = Box.new(1)
        ]])
        assert.equal(1, #errs)
        assert.match("duplicate declaration for Box, previous one at", errs[1])
    end)

    it("does not let an ignored record block its type alias", function()
        local errs = check_errs([[
            function Box(): integer
                return 1
            end
            type Box = integer
            record Box end
        ]])
        assert.equal(1, #errs)
        assert.match("duplicate declaration for Box, previous one at", errs[1])
    end)

    it("predeclares records but not later module variables", function()
        local err = assert_error("variable 'seed' not declared", [[
            local box = Box.new(seed)
            record Box
                n: integer
            end
            local seed = 1
        ]])
        assert.falsy(err:find("variable 'Box' not declared", 1, true))

        assert_error("variable 'current' not declared", [[
            local current = current
        ]])
    end)

    it("validates forward module-variable record annotations", function()
        assert_check([[
            local current: Runtime? = nil
            local record Runtime generation: integer end
        ]])

        assert_error("invalid type 'test%.Missing'", [[
            local current: Missing? = nil
        ]])
    end)
end)

describe("module initializer dependencies (typechecker)", function()
    it("accepts foreign constants, values, and calls for mutable and const slots",
       function()
        assert_check([[
            foreign import "limits.h"
            foreign import "stdlib.h"
            foreign import "stdio.h"
            local maximum: integer = ffi.LLONG_MAX as integer
            const native_maximum = ffi.INT_MAX
            const magnitude: integer = ffi.abs(-7)
            local stream = ffi.stderr
            const layout = foreign int.sizeof + foreign int.alignof
            local values = {ffi.abs(-1) as integer, ffi.INT_MAX as integer}
            foreign import "spec/fixtures/module_initializers.h"
            const enumeration: integer = ffi.INITIALIZER_ENUM
            local macro: integer = ffi.INITIALIZER_MACRO
            const foreign_value: integer = ffi.initializer_value
            local field: integer = ffi.initializer_object.number
            const element: integer = ffi.initializer_array[1]
            local indirect: integer = ffi.initializer_pointer(3)
            local owned = foreign int.new_array(ffi.initializer_count())
        ]])
    end)

    it("does not mistake the foreign namespace for a module named ffi", function()
        local ok, err = run_checker_modules({
            ffi = [[
                foreign import "stdlib.h"
                const magnitude: integer = ffi.abs(-7)
            ]],
        }, "ffi")
        assert.truthy(ok, err)
    end)

    it("accepts imported values, calls, aliases, methods, and bound methods",
       function()
        local ok, err = run_checker_modules({
            dep = [[
                const seed = 4
                record Box number: integer end
                type Alias = Box
                function Box.new(number: integer): Box
                    return {number = number}
                end
                function Box:read(): integer return self.number end
                function make(): Box return Box.new(seed) end
                function twice(number: integer): integer return number * 2 end
            ]],
            main = [[
                local dep = import "dep"
                type Alias = dep.Alias
                const seed = dep.seed
                local direct = dep.twice(dep.seed)
                const called = (dep.twice(3))
                const spread = dep.twice(...{3})
                local callable = dep.twice
                local box = dep.make()
                const custom = Alias(5)
                const member = dep.make().number
                local method = dep.make():read()
                const bound = dep.make():read
                local array = {dep.seed, dep.twice(3)}
                const indexed: integer = ({dep.twice(4)})[1]
                local map: {integer: integer} = {[dep.twice(1)] = dep.seed}
                const cast = dep.twice(2) as float
                local test = dep.make() is dep.Box
            ]],
        }, "main")
        assert.truthy(ok, err)
    end)

    it("preserves whole lambdas through implicit coercions and parentheses",
       function()
        assert_check([[
            local seed = 4
            local read = (function(): integer return seed end)
            const optional: (function(): integer)? =
                function(): integer return seed end
            local erased: value = function(): integer return seed end
            local adjusted: function(integer, integer): integer =
                function(number: integer): integer return number + seed end
        ]])
    end)

    it("preserves generated record and union construction through aliases",
       function()
        assert_check([[
            type Alias = Box
            const box = Alias {number = 4}
            local nested: {Box} = {Box(1), Alias.new(2)}
            record Box number: integer end
            union Result
                Some(number: integer)
                None()
            end
            type Choice = Result
            const present = Choice.Some(3)
            local absent = Result.None()
        ]])
    end)

    it("stores own bound methods and Interface implementations without invoking them",
       function()
        assert_check([[
            local seed: integer?
            record Box number: integer end
            type Alias = Box
            function Box:read(): integer return seed end
            union Choice Some() end
            function Choice:read(): integer return seed end
            const bare = Alias(8)
            const stored_union = Choice.Some()
            interface Reader function read(): integer end
            const bound = Alias(1):read
            const implicit: Reader = Box(2)
            const explicit = Box(3) as Reader
            const abstract_bound = (Box(4) as Reader):read
            local methods = {Alias(5):read}
            local readers: {Reader} = {Box(6)}
            const erased = (Box(7):read) as value
        ]])
    end)

    local stored_lambdas = {
        {"an Array", "{function(): integer return seed end}"},
        {"a Map value", '{["callback"] = function(): integer return seed end}'},
        {"a written cast", "(function(): integer return seed end) as value"},
        {"an operator", "true and function(): integer return seed end"},
        {"a generated record", "Holder(function(): integer return seed end)"},
        {"a named generated record", "Holder {callback = function(): integer return seed end}"},
        {"a generated union", "Choice.Some(function(): integer return seed end)"},
        {"a spread", "{...{function(): integer return seed end}}"},
        {"a constructor spread", "Holder(...{function(): integer return seed end})"},
        {"a C allocation count", "foreign int.new_array(#{function(): integer return seed end})"},
    }
    for _, case in ipairs(stored_lambdas) do
        it("accepts a stored lambda in " .. case[1], function()
            assert_check([[
                local seed: integer?
                record Holder callback: function(): integer end
                union Choice Some(function(): integer) end
                local stored = ]] .. case[2])
        end)
    end

    local dependencies = {
        {"an earlier variable", [[local bad = seed]]},
        {"a const variable", [[const bad = fixed]]},
        {"a nested variable", [[local bad = {seed + 1}]]},
        {"a map key", [[local bad: {integer: integer} = {[seed] = 1}]]},
        {"a cast operand", [[local bad = seed as float]]},
        {"a type-test operand", [[local bad = seed is integer]]},
        {"an indexed container", "local bad: integer = values[1]"},
        {"an index expression", "local bad: integer = ({1, 2})[seed]"},
        {"a function call", [[local bad = own()]]},
        {"a function value", [[const bad = own]]},
        {"a function inside a container", [[local bad = {own}]]},
        {"a generated constructor value", [[local bad = Box.new]]},
        {"a static call", [[local bad = Box.make()]]},
        {"an aliased static call", [[local bad = Alias.make()]]},
        {"an aliased static reference", [[local bad = Alias.make]]},
        {"a method call", [[local bad = Box(1):read()]]},
        {"a constructor argument", [[local bad = Box(seed)]]},
        {"a named constructor argument", [[local bad = Box {number = seed}]]},
        {"a foreign-call argument", [[local bad = ffi.abs(seed)]]},
        {"a spread subject", "local bad = {...values}"},
        {"a spread lower bound", "local bad = {...{1, 2}[seed, 2]}"},
        {"an adjusted spread upper bound", "local bad = (...{1, 2}[1, seed])"},
        {"a source foreign call", [[local bad = own_foreign()]]},
        {"a source foreign pointer", [[local bad = own_foreign as foreign function(): int]]},
    }
    for _, case in ipairs(dependencies) do
        it("rejects " .. case[1] .. " from its own module", function()
            assert_error("module variable initializer cannot reference", [[
                foreign import "stdlib.h"
                local seed = 1
                const fixed = 2
                local values = {1, 2}
                record Box number: integer end
                type Alias = Box
                function own(): integer return seed end
                local foreign function own_foreign(): int return 1 end
                function Box.make(): Box return {number = seed} end
                function Box:read(): integer return self.number end
            ]] .. case[2])
        end)
    end

    for _, expression in ipairs({"Box(1)", "Box.new(1)", "Alias(1)",
                                 "Alias.new {number = 1}"}) do
        it("rejects an own custom constructor through " .. expression,
           function()
            assert_error("module variable initializer cannot reference", [[
                record Box number: integer end
                type Alias = Box
                function Box.new(number: integer): Box
                    return {number = number}
                end
                local bad = ]] .. expression)
        end)
    end

    local exposed_lambdas = {
        {"a call argument", "dep.apply(function(): integer return 1 end)"},
        {"a surplus argument", "dep.zero(function(): integer return 1 end)"},
        {"a spread subject", "dep.zero(...{function(): integer return 1 end})"},
        {"a named argument", "dep.apply {callback = function(): integer return 1 end}"},
        {"an Array argument", "dep.zero({function(): integer return 1 end})"},
        {"a Map argument", 'dep.zero({["callback"] = function(): integer return 1 end})'},
        {"a cast argument", "dep.zero((function(): integer return 1 end) as value)"},
        {"an operator argument", "dep.zero(true and function(): integer return 1 end)"},
        {"a generated-record argument", "dep.zero(Holder(function(): integer return 1 end))"},
        {"a named generated-record argument", "dep.zero(Holder {callback = function(): integer return 1 end})"},
        {"a generated-union argument", "dep.zero(Choice.Some(function(): integer return 1 end))"},
        {"a nested constructor spread", "dep.zero(Holder(...{function(): integer return 1 end}))"},
        {"a C allocation count argument", "dep.zero(foreign int.new_array(#{function(): integer return 1 end}))"},
        {"an immediate callee", "(function(): integer return 1 end)()"},
        {"a cast callee", "((function(): integer return 1 end) as function(): integer)()"},
        {"an operator callee", "(true and function(): integer return 1 end)()"},
        {"an indexed callee", "({function(): integer return 1 end})[1]()"},
        {"a generated-record callee", "Holder(function(): integer return 1 end).callback()"},
        {"a spread callee", "({...{function(): integer return 1 end}})[1]()"},
    }
    for _, case in ipairs(exposed_lambdas) do
        it("rejects a call-exposed lambda in " .. case[1], function()
            local ok, err = run_checker_modules({
                dep = [[
                    function apply(callback: function(): integer): integer
                        return callback()
                    end
                    function zero(): integer return 0 end
                ]],
                main = [[
                    local dep = import "dep"
                    record Holder callback: function(): integer end
                    union Choice Some(function(): integer) end
                    local bad = ]] .. case[2],
            }, "main")
            assert.falsy(ok)
            assert.match("module variable initializer cannot expose an anonymous function to a call",
                err)
        end)
    end

    it("checks own references in imported-call arguments and discarded extras",
       function()
        for _, expression in ipairs({
            "dep.take(seed)",
            "dep.take {number = seed}",
            "dep.zero(seed)",
            "dep.take(1, own)",
            "dep.make():take(seed)",
            "dep.take(1, ...values)",
        }) do
            local ok, err = run_checker_modules({
                dep = [[
                    record Box number: integer end
                    function take(number: integer): integer return number end
                    function zero(): integer return 0 end
                    function make(): Box return Box(1) end
                    function Box:take(number: integer): integer return number end
                ]],
                main = [[
                    local dep = import "dep"
                    local seed = 1
                    local values = {1}
                    function own(): integer return seed end
                    local bad = ]] .. expression,
            }, "main")
            assert.falsy(ok)
            assert.match("module variable initializer cannot reference", err)
        end
    end)

    it("rejects own implementations exposed through Interface call arguments", function()
        for _, expression in ipairs({
            "dep.read(Box(1))",
            "dep.read {reader = Box(1)}",
            "dep.read_holder({reader = Box(1)})",
            "dep.read_many(Box(1))",
            "dep.read_many(...{Box(1)})",
        }) do
            local ok, err = run_checker_modules({
                dep = [[
                    interface Reader function read(): integer end
                    record Holder const reader: Reader end
                    function read(reader: Reader): integer return reader:read() end
                    function read_holder(holder: Holder): integer
                        return holder.reader:read()
                    end
                    function read_many(...: Reader): integer return ...[1]:read() end
                ]],
                main = [[
                    local dep = import "dep"
                    record Box number: integer end
                    function Box:read(): integer return self.number end
                    local bad = ]] .. expression,
            }, "main")
            assert.falsy(ok)
            assert.match("module variable initializer cannot reference", err)
        end
    end)

    local exposed_methods = {
        "dep.ignore(Box(1))",
        "dep.ignore({Box(1)})",
        "dep.ignore(Box(1) as value)",
        "dep.ignore(Choice.Some())",
        "dep.ignore(Box(1):read)",
        "dep.ignore({Box(1):read})",
        "dep.ignore((true and Box(1):read) as value)",
        "dep.ignore(Holder(Box(1):read))",
        "dep.ignore(Holder {callback = Box(1):read})",
        "dep.ignore(Holder(...{Box(1):read}))",
        "dep.ignore((Box(1) as Reader):read)",
        "dep.ignore(ReaderHolder(Box(1)))",
        "(Box(1):read)()",
        "((Box(1):read) as function(): integer)()",
        "(true and Box(1):read)()",
        "({Box(1):read})[1]()",
        "Holder(Box(1):read).callback()",
        "(Box(1) as Reader):read()",
        "((Box(1) as Reader):read)()",
        "(Box(1) as dep.Reader):read()",
        "((Box(1) as dep.Reader):read)()",
    }
    for _, expression in ipairs(exposed_methods) do
        it("rejects a call-exposed own implementation in " .. expression,
           function()
            local ok, err = run_checker_modules({
                dep = [[
                    interface Reader function read(): integer end
                    function ignore(item: value): integer return 0 end
                ]],
                main = [[
                    local dep = import "dep"
                    local seed: integer?
                    interface Reader function read(): integer end
                    record Box number: integer end
                    function Box:read(): integer return seed end
                    union Choice Some() end
                    function Choice:read(): integer return seed end
                    record Holder callback: function(): integer end
                    record ReaderHolder reader: Reader end
                    local bad = ]] .. expression,
            }, "main")
            assert.falsy(ok)
            assert.match("module variable initializer cannot reference", err)
        end)
    end

    it("keeps imported concrete methods safe through an own Interface", function()
        local ok, err = run_checker_modules({
            dep = [[
                record Box number: integer end
                function Box:read(): integer return self.number end
            ]],
            main = [[
                local dep = import "dep"
                interface Reader function read(): integer end
                const reader: Reader = dep.Box(7)
                const bound = (dep.Box(8) as Reader):read
                const dispatched = (dep.Box(9) as Reader):read()
                const called = ((dep.Box(10) as Reader):read)()
            ]],
        }, "main")
        assert.truthy(ok, err)
    end)

    it("does not treat an Interface satisfaction test as method capture", function()
        local ok, err = run_checker_modules({
            dep = [[interface Reader function read(): integer end]],
            main = [[
                local dep = import "dep"
                local seed = 1
                record Box number: integer end
                function Box:read(): integer return seed end
                const satisfies = Box(1) is dep.Reader
            ]],
        }, "main")
        assert.truthy(ok, err)
    end)

    it("preserves source-only visibility in imported initializer expressions",
       function()
        local modules = {
            dep = [[
                local const secret = 7
                local function read(): integer return secret end
            ]],
            main = [[
                local dep = import "dep.titan"
                const visible = dep.read() + dep.secret
            ]],
        }
        local ok, err = run_checker_modules(modules, "main", {interface = "source"})
        assert.truthy(ok, err)
        modules.main = [[
            local dep = import "dep"
            const hidden = dep.read() + dep.secret
        ]]
        ok, err = run_checker_modules(modules, "main", {interface = "source"})
        assert.falsy(ok)
        assert.match("member 'read' not found", err)
        assert.match("member 'secret' not found", err)
    end)
end)
