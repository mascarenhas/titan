local assert = require "luassert"

local canary = require "spec.support.canary"

local function listed(path, count, prefix, first_line)
    local lines = {}
    first_line = first_line or 10
    for index = 1, count do
        table.insert(lines, string.format("%s:%d: %s test %d", path,
            first_line + index - 1, prefix, index))
    end
    return lines
end

local function append(destination, source)
    for _, value in ipairs(source) do table.insert(destination, value) end
end

local function check_error(expected, fn)
    local ok, err = pcall(fn)
    assert.falsy(ok)
    assert.equal(expected, err)
end

describe("macOS canary selection", function()
    it("selects a reproducible rounded-up percentage from every spec file",
       function()
        local lines = listed("./spec/alpha_spec.lua", 20, "alpha")
        append(lines, listed("spec/beta_spec.lua", 21, "beta"))
        local parsed = canary.parse_busted_list(lines, {
            "spec/alpha_spec.lua", "./spec/beta_spec.lua",
        })

        local first = canary.select(parsed, 5,
            "0123456789abcdef0123456789abcdef01234567")
        local second = canary.select(parsed, 5,
            "0123456789abcdef0123456789abcdef01234567")

        assert.equal(3, #first.selected)
        assert.equal(1, first.summaries[1].selected)
        assert.equal(2, first.summaries[2].selected)
        assert.same(first.selected, second.selected)
    end)

    it("uses the complete seed and keeps source-identical names distinct",
       function()
        local lines = listed("spec/alpha_spec.lua", 100, "same suite")
        append(lines, listed("spec/beta_spec.lua", 100, "same suite"))
        local parsed = canary.parse_busted_list(lines, {
            "spec/alpha_spec.lua", "spec/beta_spec.lua",
        })
        local prefix = "0123456789abcdef0123456789abcdef0123456"
        local first = canary.select(parsed, 5, prefix .. "7")
        local second = canary.select(parsed, 5, prefix .. "8")

        assert.not_same(first.selected, second.selected)
        assert.equal(10, #first.selected)
        assert.not_equal(first.selected[1].identity,
            first.selected[6].identity)
    end)

    it("renders a human-readable manifest that round-trips exactly",
       function()
        local parsed = canary.parse_busted_list({
            "spec/alpha_spec.lua:12: suite duplicate name",
            "spec/beta_spec.lua:12: suite duplicate name",
        }, { "spec/alpha_spec.lua", "spec/beta_spec.lua" })
        local selection = canary.select(parsed, 100, "full-sha-seed")
        local manifest = canary.render_manifest(selection)
        local manifest_lines = {}
        for line in manifest:gmatch("([^\n]*)\n") do
            table.insert(manifest_lines, line)
        end
        local allowed, count = canary.parse_manifest(manifest_lines)

        assert.equal(2, count)
        assert.truthy(manifest:find("# seed: full-sha-seed", 1, true))
        assert.truthy(allowed[
            "spec/alpha_spec.lua:12@1: suite duplicate name"])
        assert.truthy(allowed[
            "spec/beta_spec.lua:12@1: suite duplicate name"])
    end)

    it("filters by source identity rather than Busted's name alone",
       function()
        local file = { descriptor = "file", name = "spec/selected_spec.lua" }
        local describe = { descriptor = "describe", name = "suite" }
        local busted = {
            context = {
                get = function() return describe end,
                parent = function(context)
                    if context == describe then return file end
                    return nil
                end,
            },
        }
        local selected =
            "spec/selected_spec.lua:22@2: suite duplicate name"
        local filter, seen = canary.make_registration_filter(busted,
            { [selected] = true })

        local _, continue = filter("duplicate name", function() end, {
            short_src = "spec/unselected_spec.lua", currentline = 22,
        })
        assert.falsy(continue)
        _, continue = filter("duplicate name", function() end, {
            short_src = "./spec/selected_spec.lua", currentline = 22,
        })
        assert.falsy(continue)
        _, continue = filter("duplicate name", function() end, {
            short_src = "./spec/selected_spec.lua", currentline = 22,
        })
        assert.truthy(continue)
        assert.has_no.errors(function()
            canary.assert_all_seen({ [selected] = true }, seen)
        end)
    end)

    it("rejects incomplete inputs and stale manifests", function()
        check_error("Busted listed no tests for input spec: " ..
            "spec/empty_spec.lua", function()
            canary.parse_busted_list({}, { "spec/empty_spec.lua" })
        end)
        check_error("Busted listed a test outside the input specs: " ..
            "spec/other_spec.lua:1: other test", function()
            canary.parse_busted_list({
                "spec/other_spec.lua:1: other test",
            }, { "spec/wanted_spec.lua" })
        end)
        check_error("canary manifest selects no tests", function()
            canary.parse_manifest({
                "# titan-busted-canary-v1",
                "# no selected tests",
            })
        end)
        check_error("canary manifest tests were not registered:\n" ..
            "spec/a.lua:1@1: missing", function()
            canary.assert_all_seen({ ["spec/a.lua:1@1: missing"] = true }, {})
        end)
    end)
end)
