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
elseif action == "inventory" or action == "inventory-fixture" then
    assert(first and (action == "inventory-fixture" or second), "inventory requires native and browser providers")
    local native, browser, table_path
    if action == "inventory-fixture" then
        native, browser, table_path = checks.native_fixture(), need(staticmetadata.scan_archive(first)), second
        print("Browser stdlib native interface oracle: checked-in native fixture")
    else
        native, browser, table_path = need(staticmetadata.scan_archive(first)), need(staticmetadata.scan_archive(second)), third
    end
    local rows, modules, recorded = checks.inventory(native, browser)
    need(rows, modules)
    need(checks.check_status(native, browser))
    local text = checks.member_table(rows, recorded)
    if table_path then need(strategy:write_file(table_path, text)) else io.write(text) end
    print(string.format("Browser stdlib inventory: %d modules, %d public members, %d absent members, " ..
        "every status row consistent.", modules, #rows, #recorded))
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
    -- A filtered run may leave inventory tests unselected; a complete run must
    -- show every image test that the status inventory names as passed.
    if second == "" then
        local image_owners = {}
        for _, root in ipairs(roots) do image_owners[root] = true end
        need(checks.require_evidence(checks.status_inventory, contents, image_owners))
        print("Browser stdlib inventory evidence: every named image test passed.")
    end
elseif action == "fixture" then
    assert(first, "fixture requires the browser provider")
    local text = checks.type_fixture(need(staticmetadata.scan_archive(first)))
    if second then need(strategy:write_file(second, text)) else io.write(text) end
elseif action == "imports" then
    assert(first and second, "imports requires a comma-separated class list and at least one Wasm image")
    local classes = {}
    for class in first:gmatch("[^,]+") do classes[#classes + 1] = class end
    for index = 3, #arguments do
        need(checks.check_imports(need(strategy:read_file(arguments[index])), arguments[index], classes))
    end
    print(string.format("Browser image imports: %d image(s) use only imports listed for %s.",
        #arguments - 2, first))
elseif action == "lint-roots" then
    -- The lint gates cover the whole test tree: every `.titan` file there is
    -- a selected source of a listed native or browser lint root.
    local driver = require "titan-compiler.driver"
    local path = require "titan-compiler.path"
    local roots, target = { native = {}, browser = {} }, nil
    for index = 3, #arguments do
        local word = arguments[index]
        if word == "--native" or word == "--browser" then
            target = word:sub(3)
        else
            assert(target, "lint-roots requires --native or --browser before its roots")
            roots[target][#roots[target] + 1] = word
        end
    end
    assert(first and target, "lint-roots requires a test tree and its --native and --browser roots")
    local function key(file) return path.normalize((file:gsub("\\", "/"))) end
    local covered = {}
    for _, name in ipairs({ "native", "browser" }) do
        -- Browser selection reads the installed browser SDK, as `titanc --lint` does.
        local context = driver.new_resolver_context(name == "browser" and { io = strategy,
            target = "browser", analysis_only = true,
            browser_analysis_target = need(driver.browser_analysis_target(nil)) } or { io = strategy })
        for _, root in ipairs(roots[name]) do
            local source, err = driver.resolve_source(context, root, first)
            if not source or source.kind == "blocked" then
                driver.close_resolver_context(context)
                need(nil, err or name .. " lint root " .. root .. " is not a source module under " .. first)
            end
            for _, file in ipairs(source.files) do covered[key(file)] = true end
        end
        need(driver.close_resolver_context(context))
    end
    local missing, count = {}, 0
    local function visit(directory)
        local entries = need(strategy:list(directory))
        table.sort(entries)
        for _, name in ipairs(entries) do
            local file = directory .. "/" .. name
            local info = need(strategy:stat(file))
            if info.kind == "directory" then
                visit(file)
            elseif info.kind == "file" and name:match("%.titan$") then
                count = count + 1
                if not covered[key(file)] then missing[#missing + 1] = file end
            end
        end
    end
    visit(first)
    if #missing > 0 then
        need(nil, "no native or browser lint root selects these test sources (add their owners to " ..
            "spec/support/stdlib_test_modules.mk):\n  " .. table.concat(missing, "\n  "))
    end
    print(string.format("Stdlib lint roots: %d native and %d browser roots select all %d test sources.",
        #roots.native, #roots.browser, count))
else
    error("usage: check_browser_stdlib.lua closure OUTPUT PROVIDER WASM [SOURCE_TREE] | inventory NATIVE BROWSER [TABLE] | " ..
        "inventory-fixture BROWSER [TABLE] | " ..
        "output ROOTS FILTER LOG | fixture BROWSER [FILE] | imports CLASS[,CLASS...] WASM... | " ..
        "lint-roots TREE --native ROOT... --browser ROOT...")
end
