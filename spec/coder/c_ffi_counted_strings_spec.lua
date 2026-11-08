local h = require "spec.support.helpers"

describe("counted C pointer-to-string code generation", function()
    after_each(function()
        os.remove("test.o")
        os.remove("test.so")
        os.remove("test.a")
        if not h.verbose then os.remove("test.c") end
        os.execute("rm -rf test.so.dSYM")
    end)

    it("copies an exact binary prefix through every supported pointer family", function()
        h.run_coder([[
            function copy(kind: integer): string
                local bytes = foreign unsigned char.new_array(5)
                bytes[0] = 65
                bytes[1] = 0
                bytes[2] = 66
                bytes[3] = 255
                bytes[4] = 0
                local pointer: foreign *unsigned char = bytes
                local text = ""
                if kind == 1 then
                    text = pointer as string(4)
                elseif kind == 2 then
                    text = (pointer as foreign const *char) as string(4)
                elseif kind == 3 then
                    text = (pointer as foreign const *signed char) as string(4)
                else
                    text = (pointer as foreign const *void) as string(4)
                end
                bytes[0] = 90
                return text
            end
            function legacy(): string
                local pointer: foreign const *char = "A\0B"
                return pointer as string
            end
        ]], [[
            for kind = 1, 4 do
                local text = test.copy(kind)
                collectgarbage("collect")
                assert(text == "A\0B\255" and #text == 4)
            end
            assert(test.legacy() == "A")
        ]])
    end)

    it("accepts zero-length NULL and non-NULL copies without reading the pointer", function()
        h.run_coder([[
            function empty_null(): string
                local pointer: foreign *char = nil
                return pointer as string(0)
            end
            function empty_present(): string
                local pointer: foreign const *void = "x"
                return pointer as string(0)
            end
            function null_copy(length: integer): string
                local pointer: foreign *char = nil
                return pointer as string(length)
            end
            function null_accepts(length: integer): boolean
                local pointer: foreign *char = nil
                return pointer is string(length)
            end
            function present_accepts(length: integer): boolean
                local pointer: foreign const *char = "x"
                return pointer is string(length)
            end
            function legacy_null_accepts(): boolean
                local pointer: foreign *char = nil
                return pointer is string
            end
        ]], [[
            assert(test.empty_null() == "" and test.empty_present() == "")
            assert(test.null_accepts(0) and not test.null_accepts(1))
            assert(not test.legacy_null_accepts())
            assert(test.present_accepts(0) and test.present_accepts(1))
            -- The predicate does not inspect the source allocation's extent.
            assert(test.present_accepts(1024 * 1024))
            assert(not test.null_accepts(-1) and not test.present_accepts(-1))
            local ok, err = pcall(test.null_copy, 1)
            assert(not ok and err:find("pointer was NULL", 1, true), tostring(err))
        ]])
    end)

    it("checks signed, unsigned and oversized native counts before copying", function()
        h.run_coder([[
            foreign type Count = unsigned long long
            local type Bytes = string
            function negative(length: integer): string
                local pointer: foreign const *char = "x"
                return pointer as string(length)
            end
            function negative_native(): string
                local pointer: foreign const *char = "x"
                local length = -1 as foreign long long
                return pointer as string(length)
            end
            function huge(): string
                local pointer: foreign const *char = "x"
                local length = (-1 as foreign long long) as foreign Count
                return pointer as string(length)
            end
            function huge_accepts(): boolean
                local pointer: foreign const *char = "x"
                local length = (-1 as foreign long long) as foreign Count
                return pointer is string(length)
            end
            function native_count(): Bytes
                local pointer: foreign const *unsigned char = "A\0B"
                local length = 3 as foreign Count
                return pointer as Bytes(length)
            end
        ]], [[
            for _, action in ipairs({
                function() return test.negative(-1) end,
                test.negative_native,
                test.huge,
            }) do
                local ok, err = pcall(action)
                assert(not ok and type(err) == "string", tostring(err))
            end
            assert(not test.huge_accepts())
            assert(test.native_count() == "A\0B")
        ]])
    end)

    it("evaluates pointer then length once on success, empty and rejected paths", function()
        h.run_coder([[
            local buffer: owned char[] = foreign char.new_array(1)
            local seen = 0
            local function next_pointer(missing: boolean): foreign *char
                seen = seen * 10 + 1
                if missing then return nil end
                return buffer
            end
            local function next_length(length: integer): integer
                seen = seen * 10 + 2
                return length
            end
            function copy(length: integer, missing: boolean): string
                seen = 0
                return next_pointer(missing) as string(next_length(length))
            end
            function accepts(length: integer, missing: boolean): boolean
                seen = 0
                return next_pointer(missing) is string(next_length(length))
            end
            function observed(): integer
                return seen
            end
            function freezes_pointer(): string
                local pointer: foreign *char = buffer
                return pointer as string((function(): integer
                    pointer = nil
                    return 1
                end)())
            end
        ]], [[
            assert(test.copy(1, false) == "\0" and test.observed() == 12)
            assert(test.copy(0, true) == "" and test.observed() == 12)
            for _, row in ipairs({ {1, true}, {-1, false} }) do
                local ok = pcall(test.copy, row[1], row[2])
                assert(not ok and test.observed() == 12)
            end
            assert(test.accepts(0, true) and test.observed() == 12)
            assert(not test.accepts(1, true) and test.observed() == 12)
            assert(not test.accepts(-1, false) and test.observed() == 12)
            assert(test.freezes_pointer() == "\0")
        ]])
    end)

    it("captures mutable lengths and lowers generic expressions used only as counts", function()
        h.run_coder([[
            local buffer: owned char[] = foreign char.new_array(4)
            record Sized<|T|>
                length: integer
                item: T
            end
            local function prefix<|T|>(sized: Sized<|T|>): string
                local pointer: foreign *char = buffer
                return pointer as string(sized.length)
            end
            function make(): function(): string
                local pointer: foreign *char = buffer
                local length = 1
                local copy = function(): string
                    return pointer as string(length)
                end
                length = 3
                return copy
            end
            function generic_copy(): string
                return prefix(Sized(2, true))
            end
            function generic_accepts<|T|>(sized: Sized<|T|>): boolean
                local pointer: foreign *char = buffer
                return pointer is string(sized.length)
            end
            function generic_predicate(): boolean
                return generic_accepts(Sized(-1, "unused"))
            end
        ]], [[
            local copy = test.make()
            collectgarbage("collect")
            assert(copy() == "\0\0\0")
            assert(test.generic_copy() == "\0\0")
            assert(not test.generic_predicate())
        ]])
    end)

    it("retains native writes and length-only reads across catch recovery", function()
        h.with_extra_cflags({ "-O2" }, function()
            h.run_coder([[
                local foreign function fill_length(length: *int): int
                    length[0] = 3
                    return 3
                end
                function recovered(): integer
                    local bytes = foreign char.new_array(4)
                    local pointer: foreign *char = bytes
                    local length = 1 as foreign int
                    do
                        local _ = pointer as string(fill_length(length))
                        raise "after copy"
                    catch
                        return length
                    end
                    return -1
                end
                function failing_count(): integer
                    local bytes = foreign char.new_array(4)
                    local pointer: foreign *char = bytes
                    local length = 1
                    do
                        local _ = pointer as string((function(): integer
                            length = 3
                            raise "count failure"
                        end)())
                    catch
                        return length
                    end
                    return -1
                end
            ]], [[
                assert(test.recovered() == 3)
                assert(test.failing_count() == 3)
            ]])
        end)
    end)

    it("performs the counted copy when used directly as a C argument or initializer", function()
        h.run_coder([[
            foreign import "string.h"
            local empty = (nil as foreign *char) as string(0)
            function prefix_length(): integer
                local pointer: foreign const *char = "abcdef"
                return ffi.strlen(pointer as string(3))
            end
            function empty_length(): integer
                local pointer: foreign const *char = nil
                return ffi.strlen(pointer as string(0))
            end
            function module_empty(): string
                return empty
            end
        ]], [[
            assert(test.prefix_length() == 3)
            assert(test.empty_length() == 0)
            assert(test.module_empty() == "")
        ]])
    end)

    it("keeps the result alive after native source disposal and collection", function()
        h.run_coder([[
            foreign import "stdlib.h"
            function detached(): string
                local pointer = ffi.malloc(4)
                if pointer == nil then raise "fixture allocation failed" end
                defer ffi.free(pointer)
                local bytes = pointer as foreign *unsigned char
                bytes[0] = 65
                bytes[1] = 0
                bytes[2] = 66
                bytes[3] = 255
                return pointer as string(4)
            end
        ]], [[
            local text = test.detached()
            collectgarbage("collect")
            assert(text == "A\0B\255")
        ]])
    end)
end)
