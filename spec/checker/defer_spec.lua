-- Typechecker tests for `defer <statement>`. The parser lowers each defer into
-- a `StatTry` with a synthetic `finally`, so these tests pin the user-visible
-- semantic consequences without duplicating the full error-handling suite.
local h = require 'spec.support.helpers'

local run_checker = h.run_checker
local check_errs = h.check_errs

local PRELUDE = [[
    function nop(n: integer): nil
    end
]]

local function ok(code)
    local good, err = run_checker(PRELUDE .. code)
    assert.truthy(good, err)
end

local function bad(pat, code)
    local errs = check_errs(PRELUDE .. code)
    assert.truthy(#errs > 0, "expected a checker error matching " .. pat)
    assert.match(pat, table.concat(errs, "\n"))
end

describe("defer statement (typechecker)", function()
    it("checks deferred statements in the scope where the defer appears", function()
        ok([[
            function f(): nil
                local n = 1
                defer nop(n)
                n = 2
            end
        ]])
    end)

    it("does not let a deferred statement see locals declared later", function()
        bad("variable 'later' not declared", [[
            function f(): nil
                defer nop(later)
                local later = 1
            end
        ]])
    end)

    it("rejects return from a deferred statement", function()
        bad("cannot 'return' from inside a finally block", [[
            function f(): integer
                defer do
                    return 1
                end
                return 2
            end
        ]])
    end)

    it("allows multiple statements through `defer do ... end`", function()
        ok([[
            function f(): nil
                local n = 1
                defer do
                    nop(n)
                    n = n + 1
                end
                n = n + 1
            end
        ]])
    end)

    it("keeps repeat until conditions in scope of locals declared after defer", function()
        ok([[
            function f(): nil
                repeat
                    defer nop(1)
                    local done = true
                until done
            end
        ]])
    end)

    it("does not let repeat cleanup see locals declared after defer", function()
        bad("variable 'done' not declared", [[
            function f(): nil
                repeat
                    defer do
                        if done then
                            nop(1)
                        end
                    end
                    local done = true
                until done
            end
        ]])
    end)
end)
