-- Repository-native gate, not a change to titan.test's public reporting/API.
-- Loaded without arguments, this returns the validators for build-harness tests.
local function timed_line(line, total)
    local body, whole, fraction = line:match(
        "^(.-) %((%d+)%.(%d%d) ms" .. (total and " total" or "") .. "%)$")
    if not body then return nil end
    whole, fraction = math.tointeger(tonumber(whole)), tonumber(fraction)
    if not whole or whole > (math.maxinteger - fraction) // 100 then return nil end
    return body, whole * 100 + fraction
end

local function duration_text(hundredths)
    return string.format("%d.%02d", hundredths // 100, hundredths % 100)
end

local function final_counts(contents)
    local counts, headers = { owner_times = {} }, 0
    for raw_line in (contents .. "\n"):gmatch("([^\n]*)\n") do
        local line = raw_line:gsub("\r$", "")
        if line == "[==========] Running Titan tests." then headers = headers + 1 end
        local body, elapsed = timed_line(line, true)
        local owner = body and body:match("^%[----------%] ([%w_.]+)$")
        if owner then
            if counts.owner_times[owner] then return nil end
            counts.owner_times[owner] = elapsed
        end
        for key, pattern in pairs({
            count = "^%[==========%] (%d+) tests? ran%.$",
            passed = "^%[  PASSED  %] (%d+) tests?%.$",
            skipped = "^%[  SKIPPED %] (%d+) tests?%.$",
            failed = "^%[  FAILED  %] (%d+) tests?%.$",
        }) do
            local number = (key == "count" and (body or "") or line):match(pattern)
            if number then
                if counts[key] then return nil end
                counts[key] = tonumber(number)
                if key == "count" then counts.elapsed = elapsed end
            end
        end
    end
    if headers ~= 1 or counts.count == nil or counts.passed == nil then return nil end
    counts.skipped, counts.failed = counts.skipped or 0, counts.failed or 0
    if counts.count ~= counts.passed + counts.skipped + counts.failed then return nil end
    return counts
end

local function validate(contents, roots, filtered, allow_empty)
    local inventory, seen_owners = {}, {}
    for _, root in ipairs(roots) do
        if inventory[root] then return nil, "duplicate native test root: " .. root end
        inventory[root] = true
    end
    if #roots == 0 then return nil, "empty native test root inventory" end
    local started, terminal, summaries, cases = {}, {}, {}, {}
    local owner_times, top_times, top_counts = {}, {}, {}
    local active, top_cases = {}, {}
    local categories = { platform = 0, capability = 0, unsupported = 0, portability = 0 }
    local result = {
        passed = 0,
        skipped = 0,
        count = 0,
        owners = 0,
        categories = categories,
        cases = cases,
        owner_times = owner_times,
    }
    local began = false
    local function owner_of(name)
        for _, root in ipairs(roots) do
            if name:sub(1, #root + 1) == root .. "." and
               name:sub(#root + 2):match("^test_") then return root end
        end
    end
    for raw_line in (contents .. "\n"):gmatch("([^\n]*)\n") do
        local line = raw_line:gsub("\r$", "")
        if line == "[==========] Running Titan tests." then
            if began then return nil, "duplicate native runner header" end
            began = true
        elseif line:match("^%[  FAILED  %]") then
            return nil, "native test failure: " .. line
        else
            local body, total_elapsed = timed_line(line, true)
            local summary, number
            for key, pattern in pairs({
                count = "^%[==========%] (%d+) tests? ran%.$",
                passed = "^%[  PASSED  %] (%d+) tests?%.$",
                skipped = "^%[  SKIPPED %] (%d+) tests?%.$",
            }) do
                local count = (key == "count" and (body or "") or line):match(pattern)
                if count then summary, number = key, tonumber(count); break end
            end
            if summary then
                if summaries[summary] then return nil, "duplicate native " .. summary .. " summary" end
                summaries[summary] = number
                if summary == "count" then result.elapsed = total_elapsed end
            else
                local owner = body and body:match("^%[----------%] ([%w_.]+)$")
                if owner then
                    if not began then return nil, "native timing precedes runner header" end
                    if not inventory[owner] then return nil, "timing outside native root inventory: " .. owner end
                    if owner_times[owner] then return nil, "duplicate native owner timing: " .. owner end
                    owner_times[owner] = total_elapsed
                elseif line:match("^%[----------%] ") and not line:match("^%[----------%] .-: ") then
                    return nil, "malformed native owner timing: " .. line
                elseif line:match("^%[==========%] ") then
                    return nil, "malformed native run timing: " .. line
                end
                local outcome, elapsed = timed_line(line, false)
                local running = line:match("^%[ RUN      %] (.+)$")
                local passing = outcome and outcome:match("^%[       OK %] (.+)$")
                local skipping = outcome and outcome:match("^%[  SKIPPED %] (.+)$")
                if not outcome and (line:match("^%[       OK %]") or line:match("^%[  SKIPPED %]")) then
                    return nil, "malformed native case timing: " .. line
                end
                local name, reason = running or passing
                if skipping then name, reason = skipping:match("^(.-) %((.*)%)$") end
                if running or passing or skipping then
                    if not began then return nil, "native result precedes runner header" end
                    if not name then return nil, "native skip omitted its name or reason: " .. skipping end
                    local owner = owner_of(name)
                    if not owner then return nil, "result outside native root inventory: " .. name end
                    if running then
                        if started[name] or terminal[name] then return nil, "duplicate native case: " .. name end
                        started[name] = true
                        if #active == 0 then top_cases[name] = true end
                        active[#active + 1] = name
                    else
                        if terminal[name] then return nil, "duplicate native result: " .. name end
                        if started[name] then
                            if active[#active] ~= name then return nil, "native case finished out of order: " .. name end
                            active[#active] = nil
                        end
                        if top_cases[name] then
                            top_times[owner] = (top_times[owner] or 0) + elapsed
                            top_counts[owner] = (top_counts[owner] or 0) + 1
                        end
                        terminal[name] = true
                        if not seen_owners[owner] then
                            seen_owners[owner] = true
                            result.owners = result.owners + 1
                        end
                        result.count = result.count + 1
                        if passing then
                            if not started[name] then return nil, "passed case was never started: " .. name end
                            result.passed = result.passed + 1
                            cases[name] = "passed"
                        else
                            local inherited = false
                            while reason:sub(1, 16) == "parent skipped: " do
                                inherited = true
                                reason = reason:sub(17)
                            end
                            if not started[name] and not inherited then
                                return nil, "skipped case was never started: " .. name
                            end
                            if not started[name] and elapsed ~= 0 then
                                return nil, "uninvoked native child has nonzero timing: " .. name
                            end
                            local category, detail = reason:match("^([a-z]+): (.+)$")
                            if not category or categories[category] == nil or not detail:match("%S") then
                                return nil, "unclassified native skip: " .. name .. " (" .. reason .. ")"
                            end
                            categories[category] = categories[category] + 1
                            result.skipped = result.skipped + 1
                            cases[name] = "skipped"
                        end
                    end
                end
            end
        end
    end
    if not began or (result.count == 0 and not (filtered and allow_empty)) then
        return nil, "native suite selected no cases"
    end
    for name in pairs(started) do
        if not terminal[name] then return nil, "native case did not finish: " .. name end
    end
    if summaries.count ~= result.count or summaries.passed ~= result.passed or
       (summaries.skipped or 0) ~= result.skipped then
        return nil, "native summary differs from named case results"
    end
    local owner_elapsed = 0
    for owner in pairs(seen_owners) do
        local elapsed = owner_times[owner]
        if elapsed == nil then return nil, "missing native owner timing: " .. owner end
        if not top_times[owner] or
           math.abs(elapsed - top_times[owner]) > top_counts[owner] // 2 then
            return nil, "native owner timing differs from top-level cases: " .. owner
        end
        owner_elapsed = owner_elapsed + elapsed
    end
    for owner in pairs(owner_times) do
        if not seen_owners[owner] then return nil, "timing for unexecuted native owner: " .. owner end
    end
    if not result.elapsed or result.elapsed + result.owners // 2 < owner_elapsed then
        return nil, "native run timing is shorter than owner intervals"
    end
    if not filtered then
        for _, root in ipairs(roots) do
            if not seen_owners[root] then return nil, "native root did not execute: " .. root end
        end
    end
    if categories.portability > 0 then
        return nil, "native suite retains " .. categories.portability .. " unfinished portability skips"
    end
    return result
end

local function validate_union(groups, roots, filtered)
    local root_inventory = {}
    for _, root in ipairs(roots or {}) do
        if root_inventory[root] then return nil, "duplicate native test root: " .. root end
        root_inventory[root] = true
    end
    if not roots or #roots == 0 then return nil, "empty native test root inventory" end
    if type(groups) ~= "table" or #groups == 0 then
        return nil, "empty native parallel group list"
    end

    local planned_owners = {}
    local combined_cases = {}
    local categories = { platform = 0, capability = 0, unsupported = 0, portability = 0 }
    local owner_times, group_results = {}, {}
    local combined = {
        passed = 0,
        skipped = 0,
        count = 0,
        owners = 0,
        groups = #groups,
        categories = categories,
        cases = combined_cases,
        owner_times = owner_times,
        group_results = group_results,
    }

    for index, group in ipairs(groups) do
        local label = tostring(group and group.id or index)
        if type(group) ~= "table" or type(group.owners) ~= "table" or #group.owners == 0 then
            return nil, "group " .. label .. ": empty native owner group"
        end
        for _, owner in ipairs(group.owners) do
            if not root_inventory[owner] then
                return nil, "group " .. label .. ": planned owner outside native root inventory: " .. tostring(owner)
            end
            if planned_owners[owner] then
                return nil, "group " .. label .. ": duplicate planned native owner: " .. owner
            end
            planned_owners[owner] = label
        end

        local group_result, group_err = validate(group.contents or "", group.owners, filtered, filtered)
        if not group_result then
            return nil, "group " .. label .. ": " .. group_err
        end
        group_results[#group_results + 1] = { id = label, result = group_result }
        for owner, elapsed in pairs(group_result.owner_times) do
            owner_times[owner] = elapsed
        end

        for case_name, status in pairs(group_result.cases) do
            if combined_cases[case_name] then
                return nil, "group " .. label .. ": duplicate native case across groups: " .. case_name
            end
            combined_cases[case_name] = status
        end

        combined.count = combined.count + group_result.count
        combined.passed = combined.passed + group_result.passed
        combined.skipped = combined.skipped + group_result.skipped
        combined.owners = combined.owners + group_result.owners
        for key, value in pairs(group_result.categories) do
            categories[key] = categories[key] + value
        end
    end

    for _, root in ipairs(roots) do
        if not planned_owners[root] then
            return nil, "native root did not execute: " .. root
        end
    end
    if combined.count == 0 then return nil, "native suite selected no cases" end
    if not filtered and combined.owners ~= #roots then
        return nil, "native owner union count differs from root inventory"
    end
    return combined
end

if select("#", ...) == 0 then return validate, final_counts, validate_union end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("a"))
    assert(file:close())
    return contents
end

local function read_lines(path)
    local items = {}
    for item in read(assert(path)):gmatch("[^\r\n]+") do
        if item ~= "" then items[#items + 1] = item end
    end
    return items
end

local function report_owners(stream, owner_times, roots)
    for _, owner in ipairs(roots) do
        local elapsed = owner_times[owner]
        if elapsed then
            stream:write(string.format("Native stdlib owner %s report: (%s ms total).\n",
                owner, duration_text(elapsed)))
        end
    end
end

local function report_counts(stream, label, counts, roots)
    stream:write(string.format(
        "%s: selected=%d passed=%d skipped=%d failed=%d. (%s ms total)\n",
        label, counts.count, counts.passed, counts.skipped, counts.failed or 0,
        duration_text(counts.elapsed)))
    report_owners(stream, counts.owner_times, roots)
end

local first_arg = select(1, ...)
if first_arg == "--union" then
    local argc = select("#", ...)
    if argc < 4 or (argc - 2) % 3 ~= 0 then
        io.stderr:write("usage: check_stdlib_test_output.lua --union ROOTS_FILE (GROUP_ID LOG_FILE OWNERS_FILE)...\n")
        os.exit(2)
    end
    local roots = read_lines(select(2, ...))
    local groups = {}
    for index = 3, argc, 3 do
        local group_id = select(index, ...)
        local log_path = select(index + 1, ...)
        local owners_path = select(index + 2, ...)
        local log_file = io.open(log_path, "rb")
        local contents = log_file and log_file:read("a") or ""
        if log_file then log_file:close() end
        local owners_file = io.open(owners_path, "rb")
        local owners = {}
        if owners_file then
            local owners_text = owners_file:read("a") or ""
            owners_file:close()
            for item in owners_text:gmatch("[^\r\n]+") do
                if item ~= "" then owners[#owners + 1] = item end
            end
        end
        groups[#groups + 1] = {
            id = group_id,
            contents = contents,
            owners = owners,
        }
    end
    local result, err = validate_union(groups, roots)
    if not result then
        for _, group in ipairs(groups) do
            local counts = final_counts(group.contents or "")
            if counts then
                report_counts(io.stderr, "Native stdlib group " .. tostring(group.id) ..
                    " report", counts, group.owners)
            else
                io.stderr:write(string.format(
                    "Native stdlib group %s report: incomplete; final counts unavailable.\n",
                    tostring(group.id)))
            end
        end
        io.stderr:write("Native stdlib gate: " .. err .. "\n")
        os.exit(1)
    end
    for index, group in ipairs(result.group_results) do
        report_counts(io.stdout, "Native stdlib group " .. group.id .. " report",
            group.result, groups[index].owners)
    end
    print(string.format(
        "Native stdlib gate: selected=%d passed=%d skipped=%d failed=0 owners=%d/%d groups=%d.",
        result.count, result.passed, result.skipped, result.owners, #roots, result.groups))
    print(string.format(
        "Classified skips: platform=%d capability=%d unsupported=%d portability=%d.",
        result.categories.platform, result.categories.capability,
        result.categories.unsupported, result.categories.portability))
    os.exit(0)
end

local output_path, roots_path, filter = ...
local roots = read_lines(assert(roots_path))
local contents = read(assert(output_path))
local result, err = validate(contents, roots, filter ~= nil and filter ~= "")
if not result then
    local counts = final_counts(contents)
    if counts then
        report_counts(io.stderr, "Native stdlib report", counts, roots)
    else
        io.stderr:write("Native stdlib report: incomplete; final counts unavailable.\n")
    end
    io.stderr:write("Native stdlib gate: " .. err .. "\n")
    os.exit(1)
end
report_owners(io.stdout, result.owner_times, roots)
print(string.format("Native stdlib gate: selected=%d passed=%d skipped=%d failed=0 owners=%d/%d%s. (%s ms total)",
    result.count, result.passed, result.skipped, result.owners, #roots,
    filter ~= nil and filter ~= "" and " (filtered)" or "", duration_text(result.elapsed)))
print(string.format("Classified skips: platform=%d capability=%d unsupported=%d portability=%d.",
    result.categories.platform, result.categories.capability,
    result.categories.unsupported, result.categories.portability))
