-- Typechecker tests for the error-handling construct (`catch`/`finally`/`raise`).
-- These run the type checker only; end-to-end code generation coverage lives in
-- the coder specs.
--
-- Surface syntax (no `try` keyword): `catch`/`finally` attach to any block as
-- optional trailers, parsing into a `StatTry { block, catchblock, finallyblock }`
-- wrapper (each clause `false` when absent). The checker:
--   * checks the body, catch, and finally in SIBLING scopes (body locals are not
--     visible in catch/finally);
--   * binds two implicit locals in the catch scope, `error: value` and
--     `traceback: string`;
--   * allows a bare `raise` (re-raise) only lexically inside a catch;
--   * forbids any control transfer that statically leaves a finally (`return`
--     and a finally-escaping `break`), while allowing `raise` and a `break` to a
--     loop written inside the finally;
--   * all four context counters reset across a nested function body, so a
--     `raise`/`return`/`break` in a lambda is governed by the lambda.
--
-- (Titan has no `print` builtin, so a top-level `nop(n: integer): nil` helper is
-- prepended to every module to stand in for an arbitrary side-effecting
-- statement.)
local h = require 'spec.support.helpers'

local run_checker = h.run_checker
local check_errs = h.check_errs

-- Prepend a `nop` helper so the bodies can do a typechecking statement without a
-- `print` builtin.
local PRELUDE = [[
    function nop(n: integer): nil
    end
]]

-- Assert the checker accepts `code` (with the nop prelude).
local function ok(code)
    local good, err = run_checker(PRELUDE .. code)
    assert.truthy(good, err)
end

-- Assert the checker rejects `code` (with the nop prelude) with an error
-- matching `pat`.
local function bad(pat, code)
    local errs = check_errs(PRELUDE .. code)
    assert.truthy(#errs > 0, "expected a checker error matching " .. pat)
    assert.match(pat, table.concat(errs, "\n"))
end

describe("error handling (typechecker)", function()

    describe("positives", function()
        it("typechecks a try+catch", function()
            ok([[
                function f(): nil
                    nop(1)
                catch
                    nop(2)
                end
            ]])
        end)

        it("typechecks a try+catch with defer", function()
            ok([[
                function f(): nil
                    defer nop(3)
                    nop(1)
                catch
                    nop(2)
                end
            ]])
        end)

        it("typechecks a deferred cleanup", function()
            ok([[
                function f(): nil
                    defer nop(2)
                    nop(1)
                end
            ]])
        end)

        it("catch can read `error` as a value", function()
            ok([[
                function f(): nil
                    nop(1)
                catch
                    local e: value = error
                end
            ]])
        end)

        it("catch can read `traceback` as a string", function()
            ok([[
                function f(): nil
                    nop(1)
                catch
                    local s: string = traceback
                    nop(#s)
                end
            ]])
        end)

        it("catch can concatenate `traceback` (it is a string)", function()
            ok([[
                function f(): string
                    nop(1)
                    return ""
                catch
                    return "trace: " .. traceback
                end
            ]])
        end)

        it("accepts a bare `raise` inside a catch", function()
            ok([[
                function f(): nil
                    nop(1)
                catch
                    raise
                end
            ]])
        end)

        it("accepts `raise <exp>` inside a catch", function()
            ok([[
                function f(): nil
                    nop(1)
                catch
                    raise "rethrown: " .. traceback
                end
            ]])
        end)

        it("accepts `raise <exp>` in a defer", function()
            ok([[
                function f(): nil
                    defer raise "boom"
                    nop(1)
                end
            ]])
        end)

        it("accepts a break to a loop written INSIDE a defer", function()
            ok([[
                function f(): nil
                    defer while true do
                        break
                    end
                    nop(1)
                end
            ]])
        end)

        it("accepts return/break inside a lambda defined in a defer", function()
            ok([[
                function f(): nil
                    defer do
                        local g: () -> integer = function(): integer
                            while true do
                                break
                            end
                            return 1
                        end
                        nop(g())
                    end
                    nop(1)
                end
            ]])
        end)

        it("accepts a bare raise inside a catch written in an inner lambda's catch",
        function()
            -- The lambda has its own catch, so its bare raise is governed by it.
            ok([[
                function f(): nil
                    local g: () -> nil = function(): nil
                        nop(1)
                    catch
                        raise
                    end
                    g()
                end
            ]])
        end)

        it("needs no trailing return when body+catch both return", function()
            ok([[
                function f(): integer
                    return 1
                catch
                    return 2
                end
            ]])
        end)

        it("needs no trailing return when an unconditional defer raise terminates",
        function()
            ok([[
                function f(): integer
                    defer raise "always"
                    nop(1)
                end
            ]])
        end)

        it("body+catch returning satisfies always-returns through a straight-line "
           .. "defer", function()
            ok([[
                function f(): integer
                    defer nop(3)
                    return 1
                catch
                    return 2
                end
            ]])
        end)
    end)

    describe("negatives", function()
        it("rejects a bare raise outside any catch", function()
            bad("bare 'raise'", [[
                function f(): nil
                    raise
                end
            ]])
        end)

        it("rejects a bare raise in a try body", function()
            bad("bare 'raise'", [[
                function f(): nil
                    raise
                catch
                    nop(1)
                end
            ]])
        end)

        it("rejects a bare raise in a defer statement", function()
            bad("bare 'raise'", [[
                function f(): nil
                    defer raise
                    return
                end
            ]])
        end)

        it("rejects a bare raise inside a lambda nested in a catch", function()
            -- The lambda resets catch_depth, so its bare raise has no in-flight
            -- error of its own and is rejected.
            bad("bare 'raise'", [[
                function f(): nil
                    nop(1)
                catch
                    local g: () -> nil = function(): nil
                        raise
                    end
                    g()
                end
            ]])
        end)

        it("rejects a return inside a defer", function()
            bad("cannot 'return' from inside a finally", [[
                function f(): integer
                    defer do
                        return 2
                    end
                    return 1
                end
            ]])
        end)

        it("rejects a break that escapes a defer", function()
            bad("'break' cannot escape a finally", [[
                function f(): nil
                    while true do
                        defer break
                        nop(1)
                    end
                end
            ]])
        end)

        it("rejects a body local referenced in the catch (sibling scope)", function()
            bad("variable 'x' not declared", [[
                function f(): nil
                    local x: integer = 1
                    nop(x)
                catch
                    nop(x)
                end
            ]])
        end)

        it("rejects assignment to the implicit catch error local", function()
            bad("cannot assign to catch local 'error'", [[
                function f(): value
                    nop(1)
                catch
                    error = "replacement"
                    return error
                end
            ]])
        end)

        it("rejects assignment to the implicit catch traceback local", function()
            bad("cannot assign to catch local 'traceback'", [[
                function f(): string
                    nop(1)
                catch
                    traceback = "replacement"
                    return traceback
                end
            ]])
        end)
    end)
end)
