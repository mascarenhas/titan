local temporary = require "spec.support.temporary"
local lfs = require "lfs"
local h = require "spec.support.helpers"
local driver = require "titan-compiler.driver"
local platform = require "titan-compiler.platform"
local SHARED_SUFFIX = platform.windows and ".dll" or ".so"

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
        for _, suffix in ipairs({ ".c", ".o", ".so", ".dll", ".def", ".dll.def",
                                 ".a", ".ffi.h", ".titan.h" }) do
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
                local provider = import "source_runtime_members.titan"

                function direct(): integer
                    provider.total = 40
                    return provider.combine(provider.total, 2)
                end

                function first_class(): integer
                    local combine: function (integer, integer): integer =
                        provider.combine
                    local make: function (integer): provider.Counter =
                        provider.Counter.from
                    local counter = make(10)
                    local bump: function (integer): integer = counter:bump
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

    it("keeps the source marker out of logical and manifest identities",
    function()
        local provider = "source_marker_manifest_provider"
        local consumer = "source_marker_manifest_consumer"
        generate({
            [provider] = [[
                local function answer(): integer return 42 end
            ]],
            [consumer] = [[
                local provider =
                    import "source_marker_manifest_provider.titan"
                function read(): integer return provider.answer() end
            ]],
        }, consumer)

        local fingerprint, parsed = driver.derive_target_fingerprint(
            provider .. ".o", provider)
        assert.truthy(fingerprint, parsed)
        assert.equal(provider, parsed.metadata.module)
        assert.falsy(parsed.metadata.module:find(".titan", 1, true))

        call(consumer, [[
            assert(source_marker_manifest_consumer.read() == 42)
        ]])
    end)

    it("rejects canonical state from another physical provider", function()
        local owner = "source_runtime_identity_owner"
        local consumer = "source_runtime_identity_consumer"
        generate({
            [owner] = [[
                local pad: integer = 111
                local secret: integer = 42
                function visible(): integer return secret end
            ]],
        }, owner)

        local old_provider = temporary.name("-source-identity-owner" .. SHARED_SUFFIX)
        local file = assert(io.open(old_provider, "wb"))
        assert(file:write(read_file(owner .. SHARED_SUFFIX)))
        assert(file:close())

        generate({
            [owner] = [[
                local secret: integer = 42
                function visible(): integer return secret end
            ]],
            [consumer] = string.format([[
                local owner = import %q
                function read(): integer return owner.secret end
            ]], owner .. ".titan"),
        }, consumer)

        local preloader = "source_runtime_identity_preloader"
        local preloader_file = preloader .. ".lua"
        file = assert(io.open(preloader_file, "wb"))
        assert(file:write(string.format([[
            local open = assert(package.loadlib(%q, %q))
            assert(type(open()) == "userdata")
            local ok, err = pcall(require, %q)
            assert(not ok)
            assert(tostring(err):find(
                "different physical provider", 1, true), tostring(err))
            return true
        ]], old_provider, "luaopen_" .. owner, consumer)))
        assert(file:close())

        local ok, err = h.call(preloader, "")
        os.remove(preloader_file)
        os.remove(old_provider)
        assert.truthy(ok, err)
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
                    ready(Pair)
                    failed(string)
                end
            ]],
            source_runtime_nominal_consumer = [[
                local provider = import "source_runtime_nominals.titan"

                function run(): integer
                    local first = provider.Pair.new(10, 20)
                    local second: provider.Pair = { left = 1, right = 2 }
                    first.left = first.left + second.left
                    first.right = first.right + second.right

                    local outcome: provider.Outcome =
                        provider.Outcome.ready(first)
                    case outcome
                    when ready(pair) then
                        return pair.left + pair.right + 9
                    when failed(message) then
                        return #message
                    end
                end
            ]],
        }, "source_runtime_nominal_consumer")

        call("source_runtime_nominal_consumer", [[
            assert(source_runtime_nominal_consumer.run() == 42)
        ]])
    end)

    it("preserves producer-owned C identity across source calls", function()
        local header = temporary.name("-source-owned-runtime.h")
        local file = assert(io.open(header, "wb"))
        assert(file:write([[
#pragma once
struct SourceOwnedRuntime { int field; };
]]))
        assert(file:close())

        generate({
            source_runtime_owned_owner = string.format([[
                foreign import %q
                foreign type Item = SourceOwnedRuntime

                local function make(): owned *Item
                    return foreign Item.new()
                end

                local function id(
                    item: owned *Item
                ): owned *Item
                    return item
                end
            ]], header),
            source_runtime_owned_forwarder = [[
                local owner = import "source_runtime_owned_owner.titan"

                local function make(): owned *Item
                    return owner.make()
                end

                local function id(
                    item: owned *Item
                ): owned *Item
                    return owner.id(item)
                end
            ]],
            source_runtime_owned_consumer = [[
                local forwarder = import "source_runtime_owned_forwarder.titan"
                local owner = import "source_runtime_owned_owner.titan"

                function run(): integer
                    local item: owned *Item = forwarder.make()
                    item.field = 42
                    return forwarder.id(item).field as integer
                end
            ]],
        }, "source_runtime_owned_consumer")

        local owner = read_file("source_runtime_owned_owner.ffi.h")
        assert.truthy(owner:find(header, 1, true), owner)
        local forwarder = read_file("source_runtime_owned_forwarder.ffi.h")
        assert.truthy(forwarder:find('/source_runtime_owned_owner.ffi.h"', 1, true), forwarder)
        local consumer = read_file("source_runtime_owned_consumer.ffi.h")
        assert.truthy(consumer:find('/source_runtime_owned_forwarder.ffi.h"', 1, true), consumer)
        assert.truthy(consumer:find('/source_runtime_owned_owner.ffi.h"', 1, true), consumer)
        os.remove(header)

        call("source_runtime_owned_consumer", [[
            assert(source_runtime_owned_consumer.run() == 42)
        ]])
    end)


    it("shares the producer header spelling for source-imported FILE-sized layouts", function()
        local header = "source_runtime_file_macro.h"
        local file = assert(io.open(header, "wb"))
        assert(file:write([[
#pragma once
struct SourceRuntimeFileMacro {
    char pad[sizeof(__FILE__)];
    int tail;
};
static struct SourceRuntimeFileMacro source_runtime_file_macro_object = {
    { 0 }, 1234
};
static struct SourceRuntimeFileMacro *source_runtime_file_macro_make(void) {
    return &source_runtime_file_macro_object;
}
]]))
        assert(file:close())

        generate({
            source_runtime_file_macro_owner = string.format([[
                foreign import %q
                foreign type Item = SourceRuntimeFileMacro

                local function get(): foreign *Item
                    return ffi.source_runtime_file_macro_make()
                end
            ]], header),
            source_runtime_file_macro_consumer = [[
                local owner = import "source_runtime_file_macro_owner.titan"

                function run(): integer
                    local item = owner.get()
                    return item.tail as integer
                end
            ]],
        }, "source_runtime_file_macro_consumer")
        local owner_include = read_file(
            "source_runtime_file_macro_owner.ffi.h"):match(
                "#include [^\n]*source_runtime_file_macro%.h[^\n]*")
        assert.truthy(owner_include)
        local consumer = read_file("source_runtime_file_macro_consumer.ffi.h")
        assert.truthy(consumer:find('/source_runtime_file_macro_owner.ffi.h"', 1, true), consumer)
        os.remove(header)

        call("source_runtime_file_macro_consumer", [[
            assert(source_runtime_file_macro_consumer.run() == 1234)
        ]])
    end)


    it("adds source origins to C operator and pointer probes", function()
        local count_header = "source_runtime_probe_count.h"
        local count_file = assert(io.open(count_header, "wb"))
        assert(count_file:write([[
            typedef int source_runtime_count;
            static source_runtime_count source_runtime_count_value(void) {
                return 21;
            }
        ]]))
        assert(count_file:close())
        local left_header = "source_runtime_probe_left.h"
        local left_file = assert(io.open(left_header, "wb"))
        assert(left_file:write([[
            struct SourceRuntimeLeft { int value; };
            static struct SourceRuntimeLeft source_runtime_left_value = { 7 };
            static struct SourceRuntimeLeft *source_runtime_left(void) {
                return &source_runtime_left_value;
            }
        ]]))
        assert(left_file:close())
        local right_header = "source_runtime_probe_right.h"
        local right_file = assert(io.open(right_header, "wb"))
        assert(right_file:write([[
            struct SourceRuntimeRight { int value; };
        ]]))
        assert(right_file:close())

        generate({
            source_runtime_probe_owner = string.format([[
                foreign import %q
                foreign import %q
                foreign import %q
                foreign type Count = source_runtime_count
                foreign type Left = SourceRuntimeLeft
                foreign type Right = SourceRuntimeRight

                local function count(): foreign Count
                    return ffi.source_runtime_count_value()
                end

                local function left(): foreign *Left
                    return ffi.source_runtime_left()
                end
            ]], count_header, left_header, right_header),
            source_runtime_probe_consumer = [[
                local owner = import "source_runtime_probe_owner.titan"

                function run(): integer
                    local count = owner.count()
                    local doubled = count + count
                    local right = owner.left() as foreign *Right
                    if right == nil then return -1 end
                    return doubled as integer
                end
            ]],
        }, "source_runtime_probe_consumer")
        os.remove(count_header)
        os.remove(left_header)
        os.remove(right_header)

        local owner = read_file("source_runtime_probe_owner.ffi.h")
        assert.truthy(owner:find(count_header, 1, true), owner)
        assert.truthy(owner:find(left_header, 1, true), owner)
        assert.truthy(owner:find(right_header, 1, true), owner)
        local consumer = read_file("source_runtime_probe_consumer.ffi.h")
        assert.truthy(consumer:find('/source_runtime_probe_owner.ffi.h"', 1, true), consumer)
        call("source_runtime_probe_consumer", [[
            assert(source_runtime_probe_consumer.run() == 42)
        ]])
    end)


    it("inherits the complete producer environment through a retained C typedef", function()
        local base_header = "source_runtime_retained_base.h"
        local alias_header = "source_runtime_retained_alias.h"
        local base = assert(io.open(base_header, "wb"))
        assert(base:write([[
            #ifndef SOURCE_RUNTIME_RETAINED_BASE_H
            #define SOURCE_RUNTIME_RETAINED_BASE_H
            struct SourceRuntimeRetained { int value; };
            #endif
        ]]))
        assert(base:close())
        local alias = assert(io.open(alias_header, "wb"))
        assert(alias:write(string.format([[
            #include %q
            typedef struct SourceRuntimeRetained SourceRuntimeRetainedAlias;
            static SourceRuntimeRetainedAlias source_runtime_retained = { 33 };
            static SourceRuntimeRetainedAlias *source_runtime_retained_get(void) {
                return &source_runtime_retained;
            }
        ]], base_header)))
        assert(alias:close())

        generate({
            source_runtime_retained_owner = string.format([[
                foreign import %q
                foreign import %q
                foreign type Retained = SourceRuntimeRetainedAlias

                local function get(): foreign *Retained
                    return ffi.source_runtime_retained_get()
                end
            ]], base_header, alias_header),
            source_runtime_retained_consumer = [[
                local owner = import "source_runtime_retained_owner.titan"
                function run(): integer
                    local pointer = owner.get()
                    if pointer == nil then return -1 end
                    return pointer.value as integer
                end
            ]],
        }, "source_runtime_retained_consumer")
        os.remove(base_header)
        os.remove(alias_header)

        local owner = read_file("source_runtime_retained_owner.ffi.h")
        local base_include = assert(owner:find(base_header, 1, true))
        local alias_include = assert(owner:find(alias_header, 1, true))
        assert.is_true(base_include < alias_include)
        local consumer = read_file("source_runtime_retained_consumer.ffi.h")
        assert.truthy(consumer:find('/source_runtime_retained_owner.ffi.h"', 1, true), consumer)
        call("source_runtime_retained_consumer", [[
            assert(source_runtime_retained_consumer.run() == 33)
        ]])
    end)

    it("inherits all authored C headers through transitive source imports",
    function()
        generate({
            source_runtime_ffi_leaf = [[
                foreign import "stdio.h"
                foreign import "stdatomic.h"
                foreign type File = FILE

                local function open(): foreign *File
                    return ffi.tmpfile()
                end

                local function write(file: foreign *File): integer
                    return ffi.fputs("source visibility", file) as integer
                end

                local function close(file: foreign *File): integer
                    return ffi.fclose(file) as integer
                end
            ]],
            source_runtime_ffi_bridge = [[
                local leaf = import "source_runtime_ffi_leaf.titan"

                local function open(): foreign *File
                    return leaf.open()
                end

                local function write(file: foreign *File): integer
                    return leaf.write(file)
                end

                local function close(file: foreign *File): integer
                    return leaf.close(file)
                end
            ]],
            source_runtime_ffi_consumer = [[
                local bridge = import "source_runtime_ffi_bridge.titan"

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

        local leaf = read_file("source_runtime_ffi_leaf.ffi.h")
        assert.truthy(leaf:find("#include <stdio.h>", 1, true), leaf)
        assert.truthy(leaf:find("#include <stdatomic.h>", 1, true), leaf)
        local bridge = read_file("source_runtime_ffi_bridge.ffi.h")
        assert.truthy(bridge:find('/source_runtime_ffi_leaf.ffi.h"', 1, true), bridge)
        local consumer = read_file("source_runtime_ffi_consumer.ffi.h")
        assert.truthy(consumer:find('/source_runtime_ffi_bridge.ffi.h"', 1, true), consumer)

        call("source_runtime_ffi_consumer", [[
            assert(source_runtime_ffi_consumer.run() == 42)
        ]])
    end)
end)
