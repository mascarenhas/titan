-- Busted helper that runs exactly the tests in a Titan canary manifest.
-- Invoke it with:
--   busted --helper spec/support/canary_filter.lua \
--     -Xhelper /path/to/manifest SPEC...

local canary = require "spec.support.canary"

return function(busted, _, options)
    local arguments = options.arguments or {}
    if #arguments ~= 1 or arguments[1] == "" then
        error("canary_filter expects exactly one manifest path", 0)
    end

    local allowed = canary.load_manifest(arguments[1])
    local filter, seen = canary.make_registration_filter(busted, allowed)
    busted.subscribe({ "register", "it" }, filter, { priority = 1 })
    busted.subscribe({ "register", "pending" }, filter, { priority = 1 })
    busted.subscribe({ "suite", "end" }, function()
        canary.assert_all_seen(allowed, seen)
        return nil, true
    end, { priority = 1 })
    return true
end
