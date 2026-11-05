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
elseif action == "size" then
    assert(first and second, "size requires Wasm image and manifest byte budget")
    local info = need(strategy:lstat(first))
    need(info.kind == "file", "browser stdlib image must be a regular file: " .. first)
    local size = info.size
    local budget = tonumber(second)
    need(checks.check_image_size(size, budget, first))
    print(string.format("Browser stdlib image %s: %d bytes (budget %d).", first, size, budget))
elseif action == "output" then
    assert(first and second and #arguments >= 6 and (#arguments - 3) % 3 == 0,
        "output requires roots file, filter and (image id, stdout log, owners file) triples")
    local _, final_counts, validate_union = dofile("spec/support/check_stdlib_test_output.lua")
    local roots, counts = read_lines(first), {}
    for _, root in ipairs(roots) do counts[root] = 0 end
    local groups = {}
    for index = 4, #arguments, 3 do
        groups[#groups + 1] = {
            id = arguments[index],
            contents = need(strategy:read_file(arguments[index + 1])),
            owners = read_lines(arguments[index + 2]),
        }
    end
    local result, err = validate_union(groups, roots, second ~= "")
    local image_summaries, owner_times = {}, {}
    local summary = { count = 0, passed = 0, skipped = 0, failed = 0 }
    local complete = true
    local function duration_text(hundredths)
        return string.format("%d.%02d", hundredths // 100, hundredths % 100)
    end
    for index, group in ipairs(groups) do
        local image_summary = final_counts(group.contents)
        image_summaries[index] = image_summary
        if image_summary then
            for _, key in ipairs({ "count", "passed", "skipped", "failed" }) do
                summary[key] = summary[key] + image_summary[key]
            end
            for owner, elapsed in pairs(image_summary.owner_times) do
                owner_times[owner] = elapsed
            end
        else
            complete = false
        end
    end
    local cases = result and result.cases or {}
    if not result then
        -- Count only timed terminal outcomes, never the untimed final failure
        -- list or malformed/missing timing suffixes.
        for _, group in ipairs(groups) do
            for raw_line, ending in (group.contents .. "\n"):gmatch("([^\n]*)\n()") do
                local line = ending <= #group.contents + 1 and raw_line:gsub("\r$", "") or raw_line
                local outcome = line:match("^(.-) %(%d+%.%d%d ms%)$")
                local name = outcome and (outcome:match("^%[       OK %] (.+)$") or
                    outcome:match("^%[  FAILED  %] (.+)$"))
                local skipped = outcome and outcome:match("^%[  SKIPPED %] (.+)$")
                if skipped then name = skipped:match("^(.-) %((.*)%)$") end
                if name then cases[name] = true end
            end
        end
    end
    local owners = 0
    for name in pairs(cases) do
        for _, root in ipairs(roots) do
            if name:sub(1, #root + 1) == root .. "." then counts[root] = counts[root] + 1; break end
        end
    end
    for index, group in ipairs(groups) do
        local image_summary = image_summaries[index]
        if image_summary then
            print(string.format("Browser stdlib image %s: %d cases (%s ms total)",
                group.id, image_summary.count, duration_text(image_summary.elapsed)))
        else
            print(string.format("Browser stdlib image %s: incomplete; timing unavailable.", group.id))
        end
    end
    for _, root in ipairs(roots) do
        local elapsed = owner_times[root]
        print(string.format("Browser stdlib owner %s: %d cases%s", root, counts[root],
            elapsed and " (" .. duration_text(elapsed) .. " ms total)" or ""))
        if counts[root] > 0 then owners = owners + 1 end
    end
    if complete then
        print(string.format("Browser stdlib gate: selected=%d passed=%d skipped=%d failed=%d owners=%d/%d images=%d%s.",
            summary.count, summary.passed, summary.skipped, summary.failed, owners, #roots, #groups,
            second ~= "" and " (filtered)" or ""))
    else
        print("Browser stdlib gate: incomplete; final counts unavailable.")
    end
    need(result, err)
else
    error("usage: check_browser_stdlib.lua closure OUTPUT PROVIDER WASM | inventory NATIVE BROWSER [TABLE] | size WASM MAX_BYTES | output ROOTS FILTER (IMAGE LOG OWNERS)...")
end
