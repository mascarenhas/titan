-- Deterministic LPT partition and inventory validator for Busted compiler/runtime specs.
-- Loaded without arguments, returns the module table for unit tests.

local M = {}

M.DEFAULT_PARTITION_FILE = "spec/support/ci_compiler_test_groups.txt"
M.DEFAULT_STDLIB_FILE = "spec/support/ci_stdlib_compiler_test_files.txt"
M.DEFAULT_STRESS_FILE = "spec/support/ci_compiler_stress_files.txt"
-- These files count overlapping real C/compiler processes against their own
-- caps, drive real parent Make jobservers, or install process-global signal
-- guards. They run alone, never beside another Busted worker or native build.
M.EXCLUSIVE_SPECS = {
    ["spec/coder/build_coordination_spec.lua"] = true,
    ["spec/coder/build_scheduler_spec.lua"] = true,
    ["spec/coder/parallel_compilation_spec.lua"] = true,
    ["spec/coder/jobserver_spec.lua"] = true,
}

M.DEFAULT_RETAINED_SPECS = {
    "spec/asan_generated_c_context_spec.lua",
    "spec/dense_array_runtime_spec.lua",
    "spec/libuv_build_spec.lua",
    "spec/lpeglabel_build_spec.lua",
    "spec/minicoro_spec.lua",
    "spec/rockspec_spec.lua",
    "spec/titan_install_spec.lua",
}

M.UNIT_SPECS = {
    ["spec/driver_spec.lua"] = true,
    ["spec/foreigntypes_spec.lua"] = true,
    ["spec/stdlib_compiler_spec.lua"] = true,
    ["spec/types_spec.lua"] = true,
}

M.ISOLATED_COVERAGE_SPECS = {
    ["spec/coder/build_coordination_spec.lua"] = true,
    ["spec/coder/build_scheduler_spec.lua"] = true,
    ["spec/compiler_environment_spec.lua"] = true,
    ["spec/cprobe_cache_spec.lua"] = true,
    ["spec/cprobe_spec.lua"] = true,
    ["spec/parser_spec.lua"] = true,
    ["spec/sha256_spec.lua"] = true,
    ["spec/union_interface_spec.lua"] = true,
    ["spec/checker/static_compiled_modules_spec.lua"] = true,
    ["spec/coder/multi_module_libraries_spec.lua"] = true,
    ["spec/coder/native_coverage_spec.lua"] = true,
    ["spec/coder/jobserver_spec.lua"] = true,
    ["spec/coder/parallel_compilation_spec.lua"] = true,
    ["spec/coder/static_compiled_modules_spec.lua"] = true,
    ["spec/coder/static_dynamic_facade_spec.lua"] = true,
    ["spec/coder/static_protocol_mismatch_spec.lua"] = true,
    ["spec/staticmetadata_spec.lua"] = true,
    ["spec/titanc_parallel_spec.lua"] = true,
}

function M.parse_positive_integer(value)
    if type(value) == "number" then
        if value >= 1 and math.floor(value) == value and value < 1e9 then
            return value
        end
        return nil
    end
    if type(value) ~= "string" or not value:match("^[1-9][0-9]*$") or #value > 9 then
        return nil
    end
    return tonumber(value)
end

local function default_read_file(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local contents = file:read("*a")
    file:close()
    return contents
end

local function discover_spec_files(root)
    local ok_lfs, lfs = pcall(require, "lfs")
    local files = {}
    if ok_lfs and lfs then
        local function walk(dir)
            for entry in lfs.dir(dir) do
                if entry ~= "." and entry ~= ".." then
                    local full = dir .. "/" .. entry
                    local mode = lfs.attributes(full, "mode")
                    if mode == "directory" then
                        walk(full)
                    elseif mode == "file" and entry:match("_spec%.lua$") then
                        files[#files + 1] = full
                    end
                end
            end
        end
        if lfs.attributes(root, "mode") == "directory" then
            walk(root)
        end
    else
        local pipe = assert(io.popen("find " .. root .. " -type f -name '*_spec.lua' -print"))
        for line in pipe:lines() do
            files[#files + 1] = line:gsub("\r$", "")
        end
        pipe:close()
    end
    table.sort(files)
    return files
end

local function is_valid_spec_path(path)
    return type(path) == "string" and path:match("^spec/.+_spec%.lua$") ~= nil
end

local function parse_nonnegative_number(token)
    if type(token) ~= "string" then return nil end
    if not token:match("^[0-9]+$") and not token:match("^[0-9]+%.[0-9]+$") then
        return nil
    end
    return tonumber(token)
end

local function split_words(line)
    local words = {}
    for word in line:gmatch("%S+") do
        words[#words + 1] = word
    end
    return words
end

function M.load(options)
    options = options or {}
    local read_file = options.read_file or default_read_file
    local partition_file = options.partition_file or M.DEFAULT_PARTITION_FILE
    local stdlib_file = options.stdlib_file or M.DEFAULT_STDLIB_FILE
    local stress_file = options.stress_file or M.DEFAULT_STRESS_FILE

    local retained_list = options.retained_files
    if not retained_list then
        if options.use_env_retained and os.getenv("TITAN_ROCK_TEST_STDLIB_SPECS") and
           os.getenv("TITAN_ROCK_TEST_STDLIB_SPECS") ~= "" then
            retained_list = split_words(os.getenv("TITAN_ROCK_TEST_STDLIB_SPECS"))
        else
            retained_list = M.DEFAULT_RETAINED_SPECS
        end
    end

    local retained_set = {}
    local retained_seen = {}
    for _, path in ipairs(retained_list) do
        if not is_valid_spec_path(path) then
            return nil, "invalid retained runtime/packaging spec: " .. tostring(path)
        end
        if retained_set[path] then
            return nil, "duplicate retained runtime/packaging entry: " .. path
        end
        retained_set[path] = true
    end

    local partition_contents, partition_err = read_file(partition_file)
    if not partition_contents then
        return nil, "could not read compiler timing dataset: " .. tostring(partition_err)
    end

    local metadata = {}
    local partition_rows = {}
    local partition_by_path = {}
    local partition_seen = {}
    for raw_line in (partition_contents .. "\n"):gmatch("([^\n]*)\n") do
        local line = raw_line:gsub("\r$", "")
        local meta_key, meta_val = line:match("^#%s*([A-Za-z_][A-Za-z0-9_-]*):%s*(.+)$")
        if meta_key and meta_val then
            metadata[meta_key:lower()] = meta_val
        end
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            local words = split_words(trimmed)
            local domain, test_file, local_sec_str, ci_sec_str, extra =
                words[1], words[2], words[3], words[4], words[5]
            if (domain ~= "compiler" and domain ~= "stdlib" and domain ~= "retained") or
               not is_valid_spec_path(test_file) or
               not parse_nonnegative_number(local_sec_str) or
               (ci_sec_str ~= nil and ci_sec_str ~= "-" and not parse_nonnegative_number(ci_sec_str)) or
               extra ~= nil then
                return nil, "invalid compiler partition row: " .. trimmed
            end
            if partition_by_path[test_file] then
                return nil, "duplicate compiler partition entry: " .. test_file
            end
            local local_sec = parse_nonnegative_number(local_sec_str)
            local ci_sec = (ci_sec_str and ci_sec_str ~= "-") and parse_nonnegative_number(ci_sec_str) or local_sec
            local row = {
                domain = domain,
                path = test_file,
                local_validation_seconds = local_sec,
                ci_covered_seconds = ci_sec,
                has_explicit_ci_seconds = (ci_sec_str ~= nil and ci_sec_str ~= "-"),
            }
            partition_rows[#partition_rows + 1] = row
            partition_by_path[test_file] = row
        end
    end

    local stdlib_contents, stdlib_err = read_file(stdlib_file)
    if not stdlib_contents then
        return nil, "could not read stdlib compiler manifest: " .. tostring(stdlib_err)
    end
    local stdlib_list = {}
    local stdlib_set = {}
    local stdlib_seen = {}
    for raw_line in (stdlib_contents .. "\n"):gmatch("([^\n]*)\n") do
        local trimmed = raw_line:gsub("\r$", ""):match("^%s*(.-)%s*$")
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            local words = split_words(trimmed)
            local test_file, extra = words[1], words[2]
            if not is_valid_spec_path(test_file) or extra ~= nil then
                return nil, "invalid stdlib compiler row: " .. trimmed
            end
            if stdlib_set[test_file] then
                return nil, "duplicate stdlib compiler entry: " .. test_file
            end
            if retained_set[test_file] then
                return nil, "stdlib compiler spec overlaps retained specs: " .. test_file
            end
            local row = partition_by_path[test_file]
            if row and row.domain == "compiler" then
                return nil, "compiler spec appears in both partitions: " .. test_file
            end
            stdlib_list[#stdlib_list + 1] = test_file
            stdlib_set[test_file] = true
        end
    end

    local stress_contents, stress_err = read_file(stress_file)
    if not stress_contents then
        return nil, "could not read compiler stress manifest: " .. tostring(stress_err)
    end
    local stress_list = {}
    local stress_set = {}
    local stress_seen = {}
    for raw_line in (stress_contents .. "\n"):gmatch("([^\n]*)\n") do
        local trimmed = raw_line:gsub("\r$", ""):match("^%s*(.-)%s*$")
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            local words = split_words(trimmed)
            local test_file, extra = words[1], words[2]
            if not is_valid_spec_path(test_file) or extra ~= nil then
                return nil, "invalid compiler stress row: " .. trimmed
            end
            if stress_set[test_file] then
                return nil, "duplicate compiler stress entry: " .. test_file
            end
            stress_list[#stress_list + 1] = test_file
            stress_set[test_file] = true
        end
    end

    local discovered = options.discovered_files or discover_spec_files("spec")
    local items = {}
    local by_path = {}
    local domain_lists = {
        retained = {},
        stdlib = {},
        compiler = {},
    }

    for _, test_file in ipairs(discovered) do
        local expected_domain
        if retained_set[test_file] then
            expected_domain = "retained"
            retained_seen[test_file] = true
        elseif stdlib_set[test_file] then
            expected_domain = "stdlib"
            stdlib_seen[test_file] = true
        else
            expected_domain = "compiler"
        end

        local row = partition_by_path[test_file]
        if not row then
            return nil, "compiler spec is missing from " .. partition_file .. ": " .. test_file
        end
        if row.domain ~= expected_domain then
            if row.domain == "compiler" and expected_domain == "stdlib" then
                return nil, "compiler spec appears in both partitions: " .. test_file
            end
            return nil, string.format(
                "spec %s has domain %s in %s but belongs to %s",
                test_file, row.domain, partition_file, expected_domain)
        end
        partition_seen[test_file] = true

        local file_contents = read_file(test_file)
        if not file_contents then
            return nil, "missing spec file on disk: " .. test_file
        end
        local has_stress_tag = file_contents:find("#stress", 1, true) ~= nil
        local in_stress_manifest = stress_set[test_file] == true
        if in_stress_manifest then
            stress_seen[test_file] = true
        end

        if expected_domain == "retained" then
            if in_stress_manifest then
                return nil, "stress spec is outside the compiler/language group: " .. test_file
            end
        else
            if has_stress_tag and not in_stress_manifest then
                return nil, "tagged compiler stress spec is missing from " .. stress_file .. ": " .. test_file
            elseif not has_stress_tag and in_stress_manifest then
                return nil, "listed compiler stress spec has no #stress tag: " .. test_file
            end
        end

        local category
        if expected_domain == "retained" then
            category = "retained"
        elseif M.UNIT_SPECS[test_file] then
            category = "unit"
        elseif M.ISOLATED_COVERAGE_SPECS[test_file] then
            category = "isolated"
        else
            category = "main"
        end

        local item = {
            path = test_file,
            domain = expected_domain,
            category = category,
            stress = in_stress_manifest,
            exclusive = (M.EXCLUSIVE_SPECS[test_file] == true),
            local_validation_seconds = row.local_validation_seconds,
            ci_covered_seconds = row.ci_covered_seconds,
            has_explicit_ci_seconds = row.has_explicit_ci_seconds,
        }
        items[#items + 1] = item
        by_path[test_file] = item
        domain_lists[expected_domain][#domain_lists[expected_domain] + 1] = item
    end

    for _, row in ipairs(partition_rows) do
        if not partition_seen[row.path] then
            return nil, "stale or excluded compiler partition entry: " .. row.path
        end
    end
    for _, path in ipairs(stdlib_list) do
        if not stdlib_seen[path] then
            return nil, "stale or excluded stdlib compiler entry: " .. path
        end
    end
    for _, path in ipairs(retained_list) do
        if not retained_seen[path] then
            return nil, "stale or excluded retained runtime/packaging entry: " .. path
        end
    end
    for _, path in ipairs(stress_list) do
        if not stress_seen[path] then
            return nil, "stale compiler stress entry: " .. path
        end
    end

    return {
        items = items,
        by_path = by_path,
        retained = domain_lists.retained,
        stdlib = domain_lists.stdlib,
        compiler = domain_lists.compiler,
        metadata = metadata,
    }
end

local function cost_for_profile(item, profile)
    if profile == "ci_covered" or profile == "ci" then
        return item.ci_covered_seconds or item.local_validation_seconds or 0
    end
    return item.local_validation_seconds or 0
end

function M.partition_lpt(items, requested_n, profile)
    local n = M.parse_positive_integer(requested_n)
    if not n then
        return nil, "worker count must be a positive integer"
    end
    local count = #items
    if count == 0 then
        return {}, 0
    end
    local effective_n = math.min(n, count)
    local sorted = {}
    local seen = {}
    for index, item in ipairs(items) do
        if type(item) ~= "table" or not is_valid_spec_path(item.path) then
            return nil, "invalid item at index " .. tostring(index)
        end
        if seen[item.path] then
            return nil, "duplicate item in partition input: " .. item.path
        end
        seen[item.path] = true
        sorted[index] = item
    end

    table.sort(sorted, function(a, b)
        local ca = cost_for_profile(a, profile)
        local cb = cost_for_profile(b, profile)
        if ca ~= cb then
            return ca > cb
        end
        return a.path < b.path
    end)

    local workers = {}
    for worker_index = 1, effective_n do
        workers[worker_index] = {
            index = worker_index,
            load = 0,
            items = {},
            files = {},
        }
    end

    for _, item in ipairs(sorted) do
        local best = workers[1]
        for worker_index = 2, effective_n do
            local candidate = workers[worker_index]
            if candidate.load < best.load then
                best = candidate
            end
        end
        best.items[#best.items + 1] = item
        best.load = best.load + cost_for_profile(item, profile)
    end

    for _, worker in ipairs(workers) do
        table.sort(worker.items, function(a, b)
            return a.path < b.path
        end)
        for index, item in ipairs(worker.items) do
            worker.files[index] = item.path
        end
    end

    return workers, effective_n
end

function M.plan_local(inventory, requested_n, profile)
    local n = M.parse_positive_integer(requested_n)
    if not n then
        return nil, "TITAN_ROCK_TEST_JOBS must be a positive integer"
    end
    local exclusive = {}
    local ordinary = {}
    for _, item in ipairs(inventory.items) do
        if item.exclusive then
            exclusive[#exclusive + 1] = item
        else
            ordinary[#ordinary + 1] = item
        end
    end
    local workers, err = M.partition_lpt(ordinary, n, profile or "local_validation")
    if not workers then
        return nil, err
    end
    local exclusive_files = {}
    for index, item in ipairs(exclusive) do
        exclusive_files[index] = item.path
    end
    return {
        requested_jobs = n,
        effective_jobs = #workers,
        exclusive_items = exclusive,
        exclusive_files = exclusive_files,
        workers = workers,
        total_files = #ordinary + #exclusive,
    }
end

-- Linux CI runs this fixed four-way covered plan as two shard-pair jobs.
M.CI_SHARDS = 4

function M.plan_ci(inventory, requested_n, profile)
    local n = M.parse_positive_integer(requested_n or M.CI_SHARDS)
    if not n then
        return nil, "CI shard count must be a positive integer"
    end
    return M.partition_lpt(inventory.compiler, n, profile or "ci_covered")
end

-- The stdlib job runs its installed-stdlib integrations as this many
-- concurrent workers on one four-CPU runner.
M.CI_STDLIB_WORKERS = 2

-- Ordinary stdlib files are balanced by LPT. Exclusive files run alone after
-- every ordinary worker finishes, so they do not count toward that balance;
-- each joins the least-loaded worker only to share its extraction and LuaCov
-- stats.
function M.plan_ci_stdlib(inventory, requested_n, profile)
    local n = M.parse_positive_integer(requested_n or M.CI_STDLIB_WORKERS)
    if not n then
        return nil, "CI stdlib worker count must be a positive integer"
    end
    profile = profile or "ci_covered"
    local ordinary, exclusive = {}, {}
    for _, item in ipairs(inventory.stdlib) do
        if item.exclusive then
            exclusive[#exclusive + 1] = item
        else
            ordinary[#ordinary + 1] = item
        end
    end
    local workers, err = M.partition_lpt(ordinary, n, profile)
    if not workers then
        return nil, err
    end
    if #workers == 0 and #exclusive > 0 then
        workers[1] = { index = 1, load = 0, items = {}, files = {} }
    end
    table.sort(exclusive, function(a, b) return a.path < b.path end)
    for _, item in ipairs(exclusive) do
        local best = workers[1]
        for worker_index = 2, #workers do
            if workers[worker_index].load < best.load then
                best = workers[worker_index]
            end
        end
        best.items[#best.items + 1] = item
        best.load = best.load + cost_for_profile(item, profile)
    end
    for _, worker in ipairs(workers) do
        table.sort(worker.items, function(a, b) return a.path < b.path end)
        for index, item in ipairs(worker.items) do
            worker.files[index] = item.path
        end
    end
    return workers
end

if select("#", ...) == 0 then
    return M
end

local command = select(1, ...)
if command == "check" then
    local inventory, err = M.load()
    if not inventory then
        io.stderr:write(err .. "\n")
        os.exit(2)
    end
    for _, key in ipairs({ "schema", "host", "profile", "date", "compiler" }) do
        if not inventory.metadata[key] or inventory.metadata[key] == "" then
            io.stderr:write("missing timing dataset metadata header: " .. key .. "\n")
            os.exit(2)
        end
    end
    os.exit(0)
elseif command == "ci-select" then
    -- CI shard-pair jobs select from the generated four-way covered plan and
    -- the stdlib job's workers from the two-way installed-stdlib plan.
    -- PHASE "ordinary" omits the exclusive files and "exclusive" selects only
    -- them, so a runner can execute them after its concurrent shards finish.
    local group = select(2, ...) or ""
    local phase = select(3, ...) or "all"
    if phase ~= "all" and phase ~= "ordinary" and phase ~= "exclusive" then
        io.stderr:write("invalid CI selection phase: " .. tostring(phase) .. "\n")
        os.exit(2)
    end
    local inventory, err = M.load()
    if not inventory then
        io.stderr:write(err .. "\n")
        os.exit(2)
    end

    local selected_items = {}
    if group == "compiler" then
        selected_items = inventory.compiler
    elseif group == "compiler-uncovered" then
        for _, item in ipairs(inventory.items) do
            if item.domain == "compiler" or item.domain == "stdlib" then
                selected_items[#selected_items + 1] = item
            end
        end
    elseif group == "stdlib-compiler" or group == "stdlib-compiler-uncovered" then
        selected_items = inventory.stdlib
    else
        local stdlib_str = group:match("^stdlib%-compiler%-shard%-(%d+)$")
        local shard_str = stdlib_str or group:match("^compiler%-shard%-(%d+)$")
        local shard = shard_str and M.parse_positive_integer(shard_str) or nil
        local limit = stdlib_str and M.CI_STDLIB_WORKERS or M.CI_SHARDS
        if not shard or shard > limit then
            io.stderr:write("invalid CI group selector: " .. tostring(group) .. "\n")
            os.exit(2)
        end
        local workers, plan_err
        if stdlib_str then
            workers, plan_err = M.plan_ci_stdlib(inventory, limit, "ci_covered")
        else
            workers, plan_err = M.plan_ci(inventory, limit, "ci_covered")
        end
        if not workers then
            io.stderr:write(plan_err .. "\n")
            os.exit(2)
        end
        selected_items = workers[shard] and workers[shard].items or {}
    end

    for _, item in ipairs(selected_items) do
        if phase == "all" or (phase == "exclusive") == item.exclusive then
            io.write(item.category, "\t", item.path, "\n")
            if item.stress then
                io.write("stress_" .. item.category, "\t", item.path, "\n")
            end
        end
    end
    os.exit(0)
elseif command == "local-plan" then
    local jobs_arg = select(2, ...)
    local output_dir = select(3, ...)
    local n = M.parse_positive_integer(jobs_arg)
    if not n then
        io.stderr:write("TITAN_ROCK_TEST_JOBS must be a positive integer\n")
        os.exit(2)
    end
    if not output_dir or output_dir == "" then
        io.stderr:write("local-plan requires an output directory\n")
        os.exit(2)
    end
    local inventory, err = M.load({ use_env_retained = true })
    if not inventory then
        io.stderr:write(err .. "\n")
        os.exit(2)
    end
    local group = select(4, ...) or "all"
    if group == "retained" then
        inventory = { items = inventory.retained }
    elseif group ~= "all" then
        local shard
        if group ~= "compiler-uncovered" then
            shard = tonumber(group:match("^hosted%-compiler%-shard%-(%d+)$"))
            if not shard or shard < 1 or shard > M.CI_SHARDS then
                io.stderr:write("invalid hosted compiler shard: " .. group .. "\n")
                os.exit(2)
            end
        end
        local compiler_items = {}
        for _, item in ipairs(inventory.items) do
            if item.domain ~= "retained" then
                compiler_items[#compiler_items + 1] = item
            end
        end
        if shard then
            local shards = assert(M.partition_lpt(compiler_items, M.CI_SHARDS, "local_validation"))
            compiler_items = assert(shards[shard], "empty hosted compiler shard").items
        end
        inventory = { items = compiler_items }
    end
    local plan, plan_err = M.plan_local(inventory, n, "local_validation")
    if not plan then
        io.stderr:write(plan_err .. "\n")
        os.exit(2)
    end

    local function write_lines(path, lines)
        local f = assert(io.open(path, "wb"))
        for _, line in ipairs(lines) do
            assert(f:write(line, "\n"))
        end
        assert(f:close())
    end

    write_lines(output_dir .. "/plan.summary", {
        "requested_jobs=" .. tostring(plan.requested_jobs),
        "effective_jobs=" .. tostring(plan.effective_jobs),
        "exclusive_count=" .. tostring(#plan.exclusive_files),
        "total_files=" .. tostring(plan.total_files),
    })
    if #plan.exclusive_files > 0 then
        write_lines(output_dir .. "/files-exclusive.txt", plan.exclusive_files)
    end
    for index, worker in ipairs(plan.workers) do
        write_lines(output_dir .. "/files-" .. tostring(index) .. ".txt", worker.files)
    end
    os.exit(0)
else
    io.stderr:write("usage: compiler_test_groups.lua {check|ci-select GROUP [all|ordinary|exclusive]|local-plan JOBS DIR [GROUP]}\n")
    os.exit(2)
end
