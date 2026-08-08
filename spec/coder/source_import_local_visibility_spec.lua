local lfs = require "lfs"
local h = require "spec.support.helpers"

local generated_modules = {}

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        assert.truthy(lfs.rmdir(path))
    elseif mode then
        assert.truthy(os.remove(path))
    end
end

local function clean_generated_modules()
    for name in pairs(generated_modules) do
        for _, suffix in ipairs({ ".c", ".o", ".so", ".a" }) do
            remove_tree(name .. suffix)
        end
        remove_tree(name .. ".so.dSYM")
    end
    generated_modules = {}
end

local function generate(modules, main)
    for name in pairs(modules) do generated_modules[name] = true end
    local ok, err = h.generate_modules(modules, main)
    assert.truthy(ok, err)
end

local function call(module, source)
    local ok, err = h.call(module, source)
    assert.truthy(ok, err)
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

describe("source-import local visibility (end-to-end)", function()
    after_each(clean_generated_modules)

    it("calls direct and first-class local functions, statics, and bound " ..
       "methods", function()
        generate({
            source_runtime_members = [[
                local total: integer = 0
                local messages: {string} = { "" }

                local function combine(left: integer,
                                       right: integer): integer
                    return left + right
                end

                record Counter
                    local current: integer
                end

                local function Counter.from(initial: integer): Counter
                    return Counter.new(initial)
                end

                local function Counter:bump(delta: integer): integer
                    self.current = self.current + delta
                    return self.current
                end
            ]],
            source_runtime_member_consumer = [[
                local provider = import "source_runtime_members"

                function direct(): integer
                    provider.total = 40
                    return provider.combine(provider.total, 2)
                end

                function first_class(): integer
                    local combine: (integer, integer) -> integer =
                        provider.combine
                    local make: (integer) -> provider.Counter =
                        provider.Counter.from
                    local counter = make(10)
                    local bump: (integer) -> integer = counter:bump
                    return combine(bump(5), 27)
                end

                function stable_identity(): boolean
                    return provider.combine == provider.combine
                        and provider.Counter.from == provider.Counter.from
                end

                function remember(message: string)
                    provider.messages = { message }
                end

                function remembered_length(): integer
                    return #provider.messages[1]
                end
            ]],
        }, "source_runtime_member_consumer")

        call("source_runtime_member_consumer", [[
            assert(source_runtime_member_consumer.direct() == 42)
            assert(source_runtime_member_consumer.first_class() == 42)
            assert(source_runtime_member_consumer.stable_identity())

            collectgarbage("collect")
            collectgarbage("generational")
            collectgarbage("collect")
            local message = string.rep("source-private module value", 1024)
            local expected = #message
            source_runtime_member_consumer.remember(message)
            message = nil
            for i = 1, 20000 do
                local garbage = { i, tostring(i), {} }
            end
            for _ = 1, 20 do collectgarbage("step", 1000) end
            assert(source_runtime_member_consumer.remembered_length() == expected)
            collectgarbage("incremental")

            local provider = require "source_runtime_members"
            assert(not pcall(function() return provider.total end))
            assert(not pcall(function() return provider.messages end))
            assert(not pcall(function() return provider.combine end))
            assert(provider.Counter ~= nil)
            assert(provider.Counter.new == nil)
            assert(provider.Counter.from == nil)
        ]])
    end)

    it("constructs local records and dispatches local unions across a " ..
       "source import", function()
        generate({
            source_runtime_nominals = [[
                local record Pair
                    left: integer
                    right: integer
                end

                local union Outcome
                    ready: Pair
                    failed: string
                end
            ]],
            source_runtime_nominal_consumer = [[
                local provider = import "source_runtime_nominals"

                function run(): integer
                    local first = provider.Pair.new(10, 20)
                    local second: provider.Pair = { left = 1, right = 2 }
                    first.left = first.left + second.left
                    first.right = first.right + second.right

                    local outcome: provider.Outcome =
                        provider.Outcome.ready(first)
                    case outcome
                    when ready: pair then
                        return pair.left + pair.right + 9
                    when failed: message then
                        return #message
                    end
                end
            ]],
        }, "source_runtime_nominal_consumer")

        call("source_runtime_nominal_consumer", [[
            assert(source_runtime_nominal_consumer.run() == 42)
        ]])
    end)

    it("propagates FFI pointer types and the transitive generated " ..
       "include closure", function()
        generate({
            source_runtime_ffi_leaf = [[
                local stdio = foreign import "stdio.h"
                local type File = stdio.FILE

                local function open(): *File
                    return stdio.tmpfile()
                end

                local function write(file: *File): integer
                    return stdio.fputs("source visibility", file) as integer
                end

                local function close(file: *File): integer
                    return stdio.fclose(file) as integer
                end
            ]],
            source_runtime_ffi_bridge = [[
                local leaf = import "source_runtime_ffi_leaf"

                local function open(): *leaf.File
                    return leaf.open()
                end

                local function write(file: *leaf.File): integer
                    return leaf.write(file)
                end

                local function close(file: *leaf.File): integer
                    return leaf.close(file)
                end
            ]],
            source_runtime_ffi_consumer = [[
                local bridge = import "source_runtime_ffi_bridge"

                function run(): integer
                    local open = bridge.open
                    local write = bridge.write
                    local close = bridge.close
                    local file = open()
                    if file == nil then return -1 end
                    local written = write(file)
                    local closed = close(file)
                    if written < 0 or closed ~= 0 then
                        return -1
                    end
                    return 42
                end
            ]],
        }, "source_runtime_ffi_consumer")

        for _, name in ipairs({
            "source_runtime_ffi_bridge",
            "source_runtime_ffi_consumer",
        }) do
            local generated = read_file(name .. ".c")
            assert.truthy(generated:find(
                "#include <stdio.h>", 1, true), name .. ".c")
        end

        call("source_runtime_ffi_consumer", [[
            assert(source_runtime_ffi_consumer.run() == 42)
        ]])
    end)
end)
