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
                return Box.new(1)
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
