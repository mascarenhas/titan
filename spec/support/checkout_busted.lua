local root = os.getenv("TITAN_ROOT")
if not root or root == "" then
    error("the checkout Busted profile requires TITAN_ROOT to select " ..
        "a prepared, ABI-matched installation; run " ..
        'TITAN_ROOT="$PREFIX" TITAN_PROBE_CACHE_DISABLE=1 ' ..
        "busted --run=checkout <spec>", 0)
end

local driver = require "titan-compiler.driver"
-- Creating the context initializes the existing driver layout. Configure the
-- direct checker's C-header lookup with the same installed SDK before tests.
local context = driver.new_resolver_context()
local ok, err = xpcall(function()
    assert(driver.configure_foreign_c(context))
end, debug.traceback)
local closed, close_error = driver.close_resolver_context(context)
if not ok then error(err, 0) end
assert(closed, close_error)
