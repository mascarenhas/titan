-- Deterministic, source-aware selection for Busted canary runs.
--
-- Busted 2.3 can shuffle tests, but it cannot run a percentage sample. Its
-- --name filter also cannot distinguish equal test names in different files.
-- Canary manifests therefore use the source-file, source-line, full test name,
-- and registration occurrence. The occurrence distinguishes table-generated
-- tests that Busted lists with otherwise identical identities.

local M = {}

local MANIFEST_HEADER = "# titan-busted-canary-v1"

local function fail(message)
    error(message, 0)
end

function M.normalize_path(path)
    path = assert(path, "missing path"):gsub("\\", "/")
    while path:sub(1, 2) == "./" do path = path:sub(3) end
    path = path:gsub("/%./", "/")
    return path
end

function M.base_identity(path, line, fullname)
    path = M.normalize_path(path)
    line = assert(tonumber(line), "invalid source line")
    assert(line >= 1 and line == math.floor(line), "invalid source line")
    assert(type(fullname) == "string", "invalid full test name")
    return string.format("%s:%d: %s", path, line, fullname)
end

function M.identity(path, line, occurrence, fullname)
    path = M.normalize_path(path)
    line = assert(tonumber(line), "invalid source line")
    occurrence = assert(tonumber(occurrence), "invalid test occurrence")
    assert(line >= 1 and line == math.floor(line), "invalid source line")
    assert(occurrence >= 1 and occurrence == math.floor(occurrence),
        "invalid test occurrence")
    assert(type(fullname) == "string", "invalid full test name")
    return string.format("%s:%d@%d: %s", path, line, occurrence, fullname)
end

function M.parse_identity(text)
    local path, line, occurrence, fullname =
        text:match("^(.-):(%d+)@(%d+): (.*)$")
    if not path then return nil, "invalid canary test identity: " .. text end
    return {
        file = M.normalize_path(path),
        line = tonumber(line),
        occurrence = tonumber(occurrence),
        fullname = fullname,
        base_identity = M.base_identity(path, line, fullname),
        identity = M.identity(path, line, occurrence, fullname),
    }
end

local function parse_busted_identity(text)
    local path, line, fullname = text:match("^(.-):(%d+): (.*)$")
    if not path then return nil, "invalid Busted test identity: " .. text end
    return {
        file = M.normalize_path(path),
        line = tonumber(line),
        fullname = fullname,
        base_identity = M.base_identity(path, line, fullname),
    }
end

local function collect_lines(source)
    if type(source) == "function" then
        return source
    elseif type(source) == "table" then
        local index = 0
        return function()
            index = index + 1
            return source[index]
        end
    end
    fail("lines must be an iterator or table")
end

function M.parse_busted_list(lines, input_files)
    assert(type(input_files) == "table", "input files must be a table")
    if #input_files == 0 then fail("at least one input spec file is required") end

    local by_file = {}
    local file_order = {}
    for _, path in ipairs(input_files) do
        local normalized = M.normalize_path(path)
        if by_file[normalized] then
            fail("duplicate input spec file: " .. normalized)
        end
        by_file[normalized] = {}
        table.insert(file_order, normalized)
    end

    local identities = {}
    local occurrences = {}
    for text in collect_lines(lines) do
        if text ~= "" then
            local record, err = parse_busted_identity(text)
            if not record then fail(err) end
            if not by_file[record.file] then
                fail("Busted listed a test outside the input specs: " ..
                    record.base_identity)
            end
            local occurrence = (occurrences[record.base_identity] or 0) + 1
            occurrences[record.base_identity] = occurrence
            record.occurrence = occurrence
            record.identity = M.identity(record.file, record.line,
                occurrence, record.fullname)
            if identities[record.identity] then
                fail("duplicate Busted test identity: " .. record.identity)
            end
            identities[record.identity] = true
            table.insert(by_file[record.file], record)
        end
    end

    for _, path in ipairs(file_order) do
        if #by_file[path] == 0 then
            fail("Busted listed no tests for input spec: " .. path)
        end
    end

    return {
        by_file = by_file,
        file_order = file_order,
    }
end

-- FNV-1a is used as a stable pseudo-random ranking, rather than math.random,
-- whose sequence is not a cross-platform interface. Two independent 32-bit
-- scores make hash ties vanishingly unlikely; the identity is the final,
-- deterministic tie breaker. Every byte of the seed participates in both.
local function fnv1a(text)
    local hash = 2166136261
    for index = 1, #text do
        hash = ((hash ~ text:byte(index)) * 16777619) & 0xffffffff
    end
    return hash
end

local function validate_seed(seed)
    if type(seed) ~= "string" or seed == "" then
        fail("the canary seed must be a non-empty string")
    end
    if seed:find("[\r\n]") then
        fail("the canary seed must not contain a newline")
    end
end

function M.select(parsed, percent, seed)
    percent = tonumber(percent)
    if not percent or percent <= 0 or percent > 100 then
        fail("sample percent must be greater than 0 and at most 100")
    end
    validate_seed(seed)

    local selected = {}
    local summaries = {}
    local total = 0

    for _, path in ipairs(parsed.file_order) do
        local ranked = {}
        for _, record in ipairs(parsed.by_file[path]) do
            local key = seed .. "\0" .. record.identity
            table.insert(ranked, {
                record = record,
                high = fnv1a("first\0" .. key),
                low = fnv1a("second\0" .. key),
            })
        end
        table.sort(ranked, function(left, right)
            if left.high ~= right.high then return left.high < right.high end
            if left.low ~= right.low then return left.low < right.low end
            return left.record.identity < right.record.identity
        end)

        local count = math.ceil(#ranked * percent / 100)
        local file_selected = {}
        for index = 1, count do
            table.insert(file_selected, ranked[index].record)
        end
        table.sort(file_selected, function(left, right)
            if left.line ~= right.line then return left.line < right.line end
            return left.identity < right.identity
        end)
        for _, record in ipairs(file_selected) do
            table.insert(selected, record)
        end
        table.insert(summaries, {
            file = path,
            selected = count,
            total = #ranked,
        })
        total = total + #ranked
    end

    return {
        seed = seed,
        percent = percent,
        selected = selected,
        summaries = summaries,
        total = total,
    }
end

function M.render_manifest(selection)
    local lines = {
        MANIFEST_HEADER,
        "# seed: " .. selection.seed,
        string.format("# percent-per-file: %.17g", selection.percent),
        string.format("# totals: %d selected of %d tests across %d files",
            #selection.selected, selection.total, #selection.summaries),
    }
    for _, summary in ipairs(selection.summaries) do
        table.insert(lines, string.format("# file: %s (%d selected of %d)",
            summary.file, summary.selected, summary.total))
    end
    for _, record in ipairs(selection.selected) do
        table.insert(lines, record.identity)
    end
    return table.concat(lines, "\n") .. "\n"
end

function M.parse_manifest(lines)
    local iterator = collect_lines(lines)
    local header = iterator()
    if header ~= MANIFEST_HEADER then
        fail("not a Titan Busted canary manifest")
    end

    local allowed = {}
    local count = 0
    for text in iterator do
        if text ~= "" and text:sub(1, 1) ~= "#" then
            local record, err = M.parse_identity(text)
            if not record then fail(err) end
            if allowed[record.identity] then
                fail("duplicate test in canary manifest: " .. record.identity)
            end
            allowed[record.identity] = true
            count = count + 1
        end
    end
    if count == 0 then fail("canary manifest selects no tests") end
    return allowed, count
end

function M.load_manifest(path)
    local file, err = io.open(path, "r")
    if not file then fail("cannot open canary manifest " .. path .. ": " .. err) end
    local ok, allowed, count = pcall(M.parse_manifest, file:lines())
    file:close()
    if not ok then fail(allowed) end
    return allowed, count
end

local function full_test_name(busted, name)
    local parent = busted.context.get()
    local names = { name }
    while parent and (parent.name or parent.descriptor) and
            parent.descriptor ~= "file" do
        table.insert(names, 1, parent.name or parent.descriptor)
        parent = busted.context.parent(parent)
    end
    return table.concat(names, " ")
end

function M.registration_base_identity(busted, name, trace)
    if not trace or not trace.short_src or not trace.currentline then
        fail("Busted did not provide a source identity for test " ..
            tostring(name))
    end
    return M.base_identity(trace.short_src, trace.currentline,
        full_test_name(busted, name))
end

function M.make_registration_filter(busted, allowed)
    local seen = {}
    local occurrences = {}
    local function filter(name, _, trace)
        local base_identity = M.registration_base_identity(busted, name, trace)
        local occurrence = (occurrences[base_identity] or 0) + 1
        occurrences[base_identity] = occurrence
        local record = assert(parse_busted_identity(base_identity))
        local identity = M.identity(record.file, record.line, occurrence,
            record.fullname)
        if not allowed[identity] then return nil, false end
        if seen[identity] then
            fail("Busted registered a selected canary test twice: " .. identity)
        end
        seen[identity] = true
        return nil, true
    end
    return filter, seen
end

function M.assert_all_seen(allowed, seen)
    local missing = {}
    for identity in pairs(allowed) do
        if not seen[identity] then table.insert(missing, identity) end
    end
    table.sort(missing)
    if #missing > 0 then
        fail("canary manifest tests were not registered:\n" ..
            table.concat(missing, "\n"))
    end
end

return M
