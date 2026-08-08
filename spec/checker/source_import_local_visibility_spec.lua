local driver = require "titan-compiler.driver"
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

local function check_modules(modules, main)
    local ok, err = h.run_checker_modules(modules, main)
    assert.truthy(ok, err)
end

local function build_binary_provider(name, source)
    generated_modules[name] = true
    local ok, err = h.generate_modules({ [name] = source }, name)
    assert.truthy(ok, err)

    local target, target_err = driver.derive_target_fingerprint(
        name .. ".o", name)
    assert.truthy(target, target_err)
    local archive, archive_err = driver.build_static_archive(
        name .. ".a", { name .. ".o" }, {}, target, h.verbose)
    assert.truthy(archive, archive_err)
end

describe("source-import local visibility (checker)", function()
    after_each(clean_generated_modules)

    it("exposes a direct source module's own local declarations", function()
        check_modules({
            source_local_provider = [[
                local type Count = integer

                local function increment(n: Count): Count
                    return n + 1
                end

                local record Token
                    count: Count
                end

                local union Result
                    ready: Token
                    failed: string
                end
            ]],
            source_local_consumer = [[
                local provider = import "source_local_provider"

                function inspect(): integer
                    local token: provider.Token = provider.Token.new(40)
                    token.count = provider.increment(token.count)
                    local count: provider.Count = token.count
                    local result: provider.Result =
                        provider.Result.ready(token)
                    case result
                    when ready: found then
                        return found.count + count
                    when failed: message then
                        return #message
                    end
                end
            ]],
        }, "source_local_consumer")
    end)

    it("exposes local fields, constructors, statics, methods, and variants " ..
       "of a direct source nominal", function()
        check_modules({
            source_member_provider = [[
                record Box
                    local hidden: integer
                    shown: integer
                end

                local function Box.make(hidden: integer,
                                        shown: integer): Box
                    return Box.new(hidden, shown)
                end

                local function Box:secret(): integer
                    return self.hidden
                end

                union Choice
                    local hidden: integer
                    shown: integer
                end
            ]],
            source_member_consumer = [[
                local provider = import "source_member_provider"

                function inspect(): integer
                    local construct: (integer, integer) -> provider.Box =
                        provider.Box.new
                    local make: (integer, integer) -> provider.Box =
                        provider.Box.make
                    local box = construct(10, 20)
                    box.hidden = make(30, 40):secret()
                    local secret: () -> integer = box:secret
                    local choice = provider.Choice.hidden(secret())
                    case choice
                    when hidden: n then
                        return n + box.shown
                    when shown: n then
                        return n
                    end
                end
            ]],
        }, "source_member_consumer")
    end)

    it("keeps local module variables private from direct source imports", function()
        local ok, err = h.run_checker_modules({
            source_variable_provider = [[
                local secret: integer = 41

                function visible(): integer
                    return secret + 1
                end
            ]],
            source_variable_consumer = [[
                local provider = import "source_variable_provider"

                function inspect(): integer
                    return provider.visible() + provider.secret
                end
            ]],
        }, "source_variable_consumer")
        assert.falsy(ok)
        assert.match(
            "member 'secret' not found inside module 'source_variable_provider'",
            err)
    end)

    it("does not grant local nominal-member visibility transitively", function()
        local modules = {
            source_visibility_leaf = [[
                record Secret
                    local hidden: integer
                end

                local function Secret:reveal(): integer
                    return self.hidden
                end
            ]],
            source_visibility_bridge = [[
                local leaf = import "source_visibility_leaf"
                local type Borrowed = leaf.Secret

                local function borrow(): Borrowed
                    return leaf.Secret.new(42)
                end

                local function read_directly(): integer
                    return borrow():reveal()
                end
            ]],
            source_visibility_field_consumer = [[
                local bridge = import "source_visibility_bridge"

                function inspect(): integer
                    local secret: bridge.Borrowed = bridge.borrow()
                    return bridge.read_directly() + secret.hidden
                end
            ]],
        }

        local ok, err = h.run_checker_modules(
            modules, "source_visibility_field_consumer")
        assert.falsy(ok)
        assert.falsy(err:find("type 'Borrowed' not found", 1, true), err)
        assert.match(
            "field 'hidden' not found in record 'source_visibility_leaf%.Secret'",
            err)

        modules.source_visibility_field_consumer = nil
        modules.source_visibility_method_consumer = [[
            local bridge = import "source_visibility_bridge"

            function inspect(): integer
                local secret: bridge.Borrowed = bridge.borrow()
                return secret:reveal()
            end
        ]]
        ok, err = h.run_checker_modules(
            modules, "source_visibility_method_consumer")
        assert.falsy(ok)
        assert.falsy(err:find("type 'Borrowed' not found", 1, true), err)
        assert.match(
            "method 'reveal' not found in record 'source_visibility_leaf%.Secret'",
            err)

        modules.source_visibility_method_consumer = nil
        modules.source_visibility_direct_consumer = [[
            local bridge = import "source_visibility_bridge"
            local leaf = import "source_visibility_leaf"

            function inspect(): integer
                local secret: leaf.Secret = bridge.borrow()
                return bridge.read_directly()
                    + secret.hidden + secret:reveal()
            end
        ]]
        check_modules(modules, "source_visibility_direct_consumer")
    end)

    it("keeps DSO and static-metadata imports projected to public members", function()
        local name = "source_visibility_binary"
        build_binary_provider(name, [[
            local function hidden(): integer
                return 1
            end

            local type Hidden = integer

            record Box
                local hidden: integer
                shown: integer
            end

            local function Box:secret(): integer
                return self.hidden
            end

            function visible(): integer
                return 2
            end

            function make(): Box
                return Box.new(3, 4)
            end
        ]])

        local function check_projection(kind)
            local ok, err = h.run_checker([[
                local provider = import "source_visibility_binary"

                function inspect(): integer
                    local box = provider.make()
                    return provider.visible() + box.shown
                end
            ]])
            assert.truthy(ok, err)
            assert.equal(kind, driver.imported[name].kind)

            local rejected = {
                {
                    [[
                        local provider = import "source_visibility_binary"
                        function inspect(): integer
                            return provider.hidden()
                        end
                    ]],
                    "member 'hidden' not found inside module " ..
                        "'source_visibility_binary'",
                },
                {
                    [[
                        local provider = import "source_visibility_binary"
                        function inspect(item: provider.Hidden): integer
                            return item
                        end
                    ]],
                    "type 'Hidden' not found inside module 'source_visibility_binary'",
                },
                {
                    [[
                        local provider = import "source_visibility_binary"
                        function inspect(): integer
                            return provider.make().hidden
                        end
                    ]],
                    "field 'hidden' not found in record " ..
                        "'source_visibility_binary%.Box'",
                },
                {
                    [[
                        local provider = import "source_visibility_binary"
                        function inspect(): integer
                            return provider.make():secret()
                        end
                    ]],
                    "method 'secret' not found in record " ..
                        "'source_visibility_binary%.Box'",
                },
            }
            for _, case in ipairs(rejected) do
                ok, err = h.run_checker(case[1])
                assert.falsy(ok)
                assert.match(case[2], err)
                assert.equal(kind, driver.imported[name].kind)
            end
        end

        check_projection("dynamic")
        remove_tree(name .. ".so")
        remove_tree(name .. ".so.dSYM")
        check_projection("static")
    end)
end)
