-- Focused coverage for the memoized nominal-owner index used while recovering
-- a compiled module interface. The lookup is a private checker helper, so this
-- spec exercises it directly instead of compiling fixture modules.
local checker = require "titan-compiler.checker.imports"
local types = require "titan-compiler.types"

local function lookup(module, fqtn)
    return checker._recovered_nominal_owner(module, fqtn)
end

local function interface(owner)
    return types.Interface(owner, {
        types.Field(owner, "value", types.Integer(), 0, true),
    }, {})
end

describe("recovered nominal owner index", function()
    it("returns the first record or union in member order", function()
        local first = types.Record("recovered_index.Thing", {}, {}, {}, 0)
        local second = types.Record("recovered_index.Thing", {}, {}, {}, 0)
        local module = types.Module("recovered_index", {
            types.ModuleMember("recovered_index", "Thing", first, nil),
            types.ModuleMember("recovered_index", "Thing", second, nil),
        })

        assert.equal(first, lookup(module, "recovered_index.Thing"))
        -- The memoized index must keep answering with the same first match.
        assert.equal(first, lookup(module, "recovered_index.Thing"))
    end)

    it("keeps a member record ahead of the interface fallback", function()
        local record = types.Record("recovered_shadow.Owner", {}, {}, {}, 0)
        local interface = interface("recovered_shadow.Owner")
        local module = types.Module("recovered_shadow", {
            types.ModuleMember("recovered_shadow", "Owner", record, nil),
        }, { Owner = interface })

        assert.equal(record, lookup(module, "recovered_shadow.Owner"))
    end)

    it("ignores interface members; only the type_members fallback sees them",
    function()
        local interface = interface("recovered_member_iface.View")
        local module = types.Module("recovered_member_iface", {
            types.ModuleMember(
                "recovered_member_iface", "View", interface, nil),
        })

        assert.is_nil(lookup(module, "recovered_member_iface.View"))
    end)

    it("rebuilds when the members array grows after the first lookup",
    function()
        local early = types.Record("recovered_growth.Early", {}, {}, {}, 0)
        local late = types.Union("recovered_growth.Late", {}, {}, {}, 0)
        local module = types.Module("recovered_growth", {
            types.ModuleMember("recovered_growth", "Early", early, nil),
        })

        assert.equal(early, lookup(module, "recovered_growth.Early"))
        assert.is_nil(lookup(module, "recovered_growth.Late"))

        table.insert(module.members, types.ModuleMember(
            "recovered_growth", "Late", late, nil))

        assert.equal(late, lookup(module, "recovered_growth.Late"))
        assert.equal(early, lookup(module, "recovered_growth.Early"))
    end)

    it("rebuilds when module.members is replaced", function()
        local early = types.Record("recovered_replace.Early", {}, {}, {}, 0)
        local module = types.Module("recovered_replace", {
            types.ModuleMember("recovered_replace", "Early", early, nil),
        })

        assert.equal(early, lookup(module, "recovered_replace.Early"))

        local replacement =
            types.Record("recovered_replace.Replaced", {}, {}, {}, 0)
        module.members = {
            types.ModuleMember(
                "recovered_replace", "Replaced", replacement, nil),
        }

        assert.equal(replacement, lookup(module, "recovered_replace.Replaced"))
        assert.is_nil(lookup(module, "recovered_replace.Early"))
    end)

    it("falls back to type_members for an exact interface owner", function()
        local shape = interface("recovered_interface.Shape")
        local module = types.Module(
            "recovered_interface", {}, { Shape = shape })

        assert.equal(shape, lookup(module, "recovered_interface.Shape"))
        assert.is_nil(lookup(module, "other_interface.Shape"))
    end)
end)
