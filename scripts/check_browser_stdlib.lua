local checks = dofile("scripts/browser_stdlib.lua")
local staticmetadata = require "titan-compiler.staticmetadata"
local strategy = require("titan-compiler.io").new_sync()
local action, first, second, third = ...
local function need(ok, err)
    if not ok then io.stderr:write("browser-stdlib: ", tostring(err), "\n"); os.exit(1) end
    return ok
end
if action == "closure" then
    assert(first and second and third, "closure requires output root, provider and Wasm image")
    need(checks.check_output(strategy, first))
    need(checks.check_archive(second))
    need(checks.check_image(need(strategy:read_file(third)), third))
    print("Browser stdlib closure: provider, certified headers, objects and image have no forbidden dependencies.")
elseif action == "inventory" then
    assert(first and second, "inventory requires native and browser providers")
    local native = need(staticmetadata.scan_archive(first))
    local browser = need(staticmetadata.scan_archive(second))
    local rows = need(checks.inventory(native, browser))
    local text = checks.member_table(rows)
    if third then need(strategy:write_file(third, text)) else io.write(text) end
    print(string.format("Browser stdlib inventory: %d modules, %d public members, no differences.", #browser.key_order, #rows))
elseif action == "output" then
    assert(first and second, "output requires run log and roots file")
    local validate = dofile("spec/support/check_stdlib_test_output.lua")
    local roots, counts = {}, {}
    for root in need(strategy:read_file(second)):gmatch("[^\r\n]+") do
        roots[#roots + 1], counts[root] = root, 0
    end
    local result = need(validate(need(strategy:read_file(first)), roots,
        third ~= nil and third ~= ""))
    for name in pairs(result.cases) do
        for _, root in ipairs(roots) do
            if name:sub(1, #root + 1) == root .. "." then counts[root] = counts[root] + 1; break end
        end
    end
    for _, root in ipairs(roots) do print(string.format("Browser stdlib owner %s: %d cases", root, counts[root])) end
    print(string.format("Browser stdlib gate: selected=%d passed=%d skipped=%d failed=0 owners=%d/%d%s.",
        result.count, result.passed, result.skipped, result.owners, #roots, third ~= nil and third ~= "" and " (filtered)" or ""))
else
    error("usage: check_browser_stdlib.lua closure OUTPUT PROVIDER WASM | inventory NATIVE BROWSER [TABLE] | output LOG ROOTS [FILTER]")
end
