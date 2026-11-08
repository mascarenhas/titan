local h = require "spec.support.helpers"

describe("counted C pointer-to-string checking", function()
    for _, pointer in ipairs({
        "*char", "const *char", "*signed char", "const *signed char",
        "*unsigned char", "const *unsigned char", "*void", "const *void",
    }) do
        it("accepts a counted " .. pointer .. " and its predicate", function()
            local ok, err = h.run_checker([[
                local function copy(pointer: foreign ]] .. pointer .. [[,
                                     length: integer): string
                    return pointer as string(length)
                end
                local function accepts(pointer: foreign ]] .. pointer .. [[,
                                        length: integer): boolean
                    return pointer is string(length)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end

    it("retains pointer/count typedefs and a transparent string alias", function()
        local ok, err = h.run_checker([[
            foreign type BytesPointer = const *unsigned char
            foreign type ByteCount = unsigned long long
            local type Bytes = string
            local function copy(pointer: foreign BytesPointer,
                                 length: foreign ByteCount): Bytes
                return pointer as Bytes(length)
            end
            local function accepts(pointer: foreign BytesPointer,
                                    length: foreign ByteCount): boolean
                return pointer is Bytes(length)
            end
        ]])
        assert.truthy(ok, err)
    end)

    for _, case in ipairs({
        { name = "non-character object pointer", pointer = "foreign *int",
            length = "integer", target = "string", message = "requires a character or void pointer" },
        { name = "function pointer", pointer = "foreign function(): void",
            length = "integer", target = "string", message = "requires a character or void pointer" },
        { name = "dynamic pointer", pointer = "value",
            length = "integer", target = "string", message = "requires a character or void pointer" },
        { name = "non-string target", pointer = "foreign *char",
            length = "integer", target = "integer", message = "requires a character or void pointer" },
        { name = "optional string target", pointer = "foreign *char",
            length = "integer", target = "string?", message = "requires a character or void pointer" },
        { name = "float count", pointer = "foreign *char",
            length = "float", target = "string", message = "length must be an integer or C integer" },
        { name = "C float count", pointer = "foreign *char",
            length = "foreign double", target = "string", message = "length must be an integer or C integer" },
        { name = "boolean count", pointer = "foreign *char",
            length = "boolean", target = "string", message = "length must be an integer or C integer" },
        { name = "dynamic count", pointer = "foreign *char",
            length = "value", target = "string", message = "length must be an integer or C integer" },
        { name = "optional count", pointer = "foreign *char",
            length = "integer?", target = "string", message = "length must be an integer or C integer" },
    }) do
        it("rejects a counted conversion with a " .. case.name, function()
            for _, operation in ipairs({ "as", "is" }) do
                local ok, err = h.run_checker([[
                    local function copy(pointer: ]] .. case.pointer .. [[,
                                         length: ]] .. case.length .. [[)
                        local _ = pointer ]] .. operation .. " " .. case.target .. [[(length)
                    end
                ]])
                assert.falsy(ok)
                assert.truthy(err:find(case.message, 1, true), err)
            end
        end)
    end

    it("does not infer a pointer type for an untyped nil operand", function()
        local ok, err = h.run_checker([[
            local function copy(): string
                return nil as string(0)
            end
        ]])
        assert.falsy(ok)
        assert.truthy(err:find("requires a character or void pointer", 1, true), err)
    end)

    it("rejects counted strings in a restricted foreign body", function()
        local ok, err = h.run_checker([[
            foreign function copy(pointer: *char, length: unsigned long): *char
                return pointer as string(length)
            end
        ]])
        assert.falsy(ok)
        assert.truthy(err:find("counted string conversion", 1, true), err)
    end)

    it("checks names used only in the length operand", function()
        local ok, err = h.run_checker([[
            local function copy(pointer: foreign *char): string
                return pointer as string(missing_count)
            end
        ]])
        assert.falsy(ok)
        assert.truthy(err:find("missing_count", 1, true), err)
    end)

    it("admits an otherwise valid counted module initializer", function()
        local ok, err = h.run_checker([[
            local empty = (nil as foreign *char) as string(0)
            function copied(): string
                return empty
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("keeps own-function initializer restrictions in the length operand", function()
        local ok, err = h.run_checker([[
            local bytes = (nil as foreign *char) as string(own_count())
            local function own_count(): integer
                return 0
            end
        ]])
        assert.falsy(ok)
        assert.truthy(err:find("initializer", 1, true), err)
    end)

    it("keeps own-variable initializer restrictions in the length operand", function()
        local ok, err = h.run_checker([[
            local count = 0
            local bytes = (nil as foreign *char) as string(count)
        ]])
        assert.falsy(ok)
        assert.truthy(err:find("initializer", 1, true), err)
    end)
end)
