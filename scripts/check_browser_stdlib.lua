local checks = dofile("scripts/browser_stdlib.lua")
local staticmetadata = require "titan-compiler.staticmetadata"
local strategy = require("titan-compiler.io").new_sync()
local action, first, second, third = ...
local arguments = { ... }
local function read_lines(path)
    local result = {}
    local contents, err = strategy:read_file(path)
    assert(contents, err)
    for line in contents:gmatch("[^\r\n]+") do result[#result + 1] = line end
    return result
end
local function need(ok, err)
    if not ok then io.stderr:write("browser-stdlib: ", tostring(err), "\n"); os.exit(1) end
    return ok
end
if action == "closure" then
    assert(first and second and third, "closure requires output root, provider and Wasm image")
    local driver = require "titan-compiler.driver"
    local context = driver.new_resolver_context({ io = strategy, target = "browser" })
    local source_ok, source_error = checks.check_sources(context, arguments[5] or ".")
    local closed, close_error = driver.close_resolver_context(context)
    need(source_ok, source_error)
    need(closed, close_error)
    need(checks.check_output(strategy, first))
    need(checks.check_archive(second))
    need(checks.check_image(need(strategy:read_file(third)), third))
    print("Browser stdlib closure: selected sources, provider, certified headers, objects and image have no forbidden dependencies.")
elseif action == "inventory" then
    assert(first and second, "inventory requires native and browser providers")
    local native = need(staticmetadata.scan_archive(first))
    local browser = need(staticmetadata.scan_archive(second))
    local rows, modules, recorded = checks.inventory(native, browser)
    need(rows, modules)
    local text = checks.member_table(rows, recorded)
    if third then need(strategy:write_file(third, text)) else io.write(text) end
    print(string.format("Browser stdlib inventory: %d modules, %d public members, %d recorded differences, no others.",
        modules, #rows, #recorded))
elseif action == "output" then
    assert(first and second and third and #arguments == 4,
        "output requires roots file, filter and stdout log")
    local _, final_counts, validate_union = dofile("spec/support/check_stdlib_test_output.lua")
    local roots, counts = read_lines(first), {}
    for _, root in ipairs(roots) do counts[root] = 0 end
    local contents = need(strategy:read_file(third))
    local result, err = validate_union({ { id = "stdlib", contents = contents, owners = roots } },
        roots, second ~= "")
    local summary = final_counts(contents)
    local cases = result and result.cases or {}
    if not result then
        -- Only timed terminal outcomes count, never the untimed final failure
        -- list, malformed timing suffixes, or a CR without its real LF.
        for raw_line, ending in (contents .. "\n"):gmatch("([^\n]*)\n()") do
            local line = ending <= #contents + 1 and raw_line:gsub("\r$", "") or raw_line
            local outcome = line:match("^(.-) %(%d+%.%d%d ms%)$")
            local name = outcome and (outcome:match("^%[       OK %] (.+)$") or
                outcome:match("^%[  FAILED  %] (.+)$"))
            local skipped = outcome and outcome:match("^%[  SKIPPED %] (.+)$")
            if skipped then name = skipped:match("^(.-) %((.*)%)$") end
            if name then cases[name] = true end
        end
    end
    local owners = 0
    for name in pairs(cases) do
        for _, root in ipairs(roots) do
            if name:sub(1, #root + 1) == root .. "." then counts[root] = counts[root] + 1; break end
        end
    end
    local function duration_text(hundredths)
        return string.format("%d.%02d", hundredths // 100, hundredths % 100)
    end
    if summary then
        print(string.format("Browser stdlib image stdlib: %d cases (%s ms total)",
            summary.count, duration_text(summary.elapsed)))
    else
        print("Browser stdlib image stdlib: incomplete; timing unavailable.")
    end
    for _, root in ipairs(roots) do
        local elapsed = summary and summary.owner_times[root]
        print(string.format("Browser stdlib owner %s: %d cases%s", root, counts[root],
            elapsed and (" (" .. duration_text(elapsed) .. " ms total)") or ""))
        if counts[root] > 0 then owners = owners + 1 end
    end
    if summary then
        print(string.format("Browser stdlib gate: selected=%d passed=%d skipped=%d failed=%d owners=%d/%d images=1%s.",
            summary.count, summary.passed, summary.skipped, summary.failed, owners, #roots,
            second ~= "" and " (filtered)" or ""))
    else
        print("Browser stdlib gate: incomplete; final counts unavailable.")
    end
    need(result, err)
else
    error("usage: check_browser_stdlib.lua closure OUTPUT PROVIDER WASM [SOURCE_TREE] | inventory NATIVE BROWSER [TABLE] | output ROOTS FILTER LOG")
end
