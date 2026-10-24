-- Native compile-job scheduling helpers shared by the driver's serial and
-- parallel object paths.
-- Implementation notes: doc/implementation/driver.md#parallel-generated-c-compilation
local jobs = {}

-- The batch caller assigns each prepared module its original request index;
-- every job inherits it as its owning module index.
function jobs.set_request_index(prepared, request_index)
    prepared.request_index = request_index
    for _, job in ipairs(prepared.jobs) do job.module_index = request_index end
end

-- Flatten every prepared module's native jobs while retaining ownership.
-- `ordinal` is module/part order: the completion identity and the order in
-- which diagnostics are replayed and results are reported.
function jobs.flatten(prepared)
    local entries, results = {}, {}
    for module_position, compilation in ipairs(prepared) do
        local module_result = { jobs = {} }
        results[module_position] = module_result
        for job_position, job in ipairs(compilation.jobs) do
            entries[#entries + 1] = {
                ordinal = #entries + 1,
                job = job,
                job_position = job_position,
                module_result = module_result,
            }
        end
    end
    return entries, results
end

function jobs.record(entry, ok, err, code)
    entry.module_result.jobs[entry.job_position] = {
        ok = ok, err = err, code = code,
    }
end

-- A module succeeds only when every part compiled. Its error is the first
-- failing part's, in part order; every part's result remains in `jobs`.
function jobs.summarize(results)
    for _, result in ipairs(results) do
        result.ok = true
        for _, job_result in ipairs(result.jobs) do
            if result.ok and not job_result.ok then
                result.ok = nil
                result.err, result.code = job_result.err, job_result.code
            end
        end
    end
    return results
end

-- Largest estimated cost first; ties keep the original module request
-- order and then part order, so the launch sequence is deterministic.
function jobs.launch_order(entries)
    local schedule = {}
    for index, entry in ipairs(entries) do schedule[index] = entry end
    table.sort(schedule, function(left, right)
        local left_cost = left.job.cost_bytes or 0
        local right_cost = right.job.cost_bytes or 0
        if left_cost ~= right_cost then return left_cost > right_cost end
        local left_module = left.job.module_index or 0
        local right_module = right.job.module_index or 0
        if left_module ~= right_module then return left_module < right_module end
        local left_part = left.job.part_index or 0
        local right_part = right.job.part_index or 0
        if left_part ~= right_part then return left_part < right_part end
        return left.ordinal < right.ordinal
    end)
    return schedule
end

return jobs
