-- Embedded in coverage test executables. The compiler supplies the exact
-- generated-file list; collection needs only Lua's standard libraries.
local coverage = {}
local windows = package.config:sub(1, 1) == "\\"

local function quote(word)
    if not windows then return "'" .. word:gsub("'", "'\\''") .. "'" end
    -- Preserve the CRT argument through cmd, as in the compiler's platform
    -- command renderer. In particular, spaces and shell metacharacters remain
    -- part of one argument.
    local parts, slashes = { '"' }, 0
    for character in word:gmatch(".") do
        if character == "\\" then
            slashes = slashes + 1
        else
            parts[#parts + 1] = string.rep("\\", character == '"' and slashes * 2 + 1 or slashes)
            parts[#parts + 1] = character
            slashes = 0
        end
    end
    parts[#parts + 1] = string.rep("\\", slashes * 2) .. '"'
    return (table.concat(parts):gsub('[%(%)%[%]%%!%^"`<>&|;, *?\t]', '^%0'))
end

local function run(argv, cwd)
    local words = {}
    for index, word in ipairs(argv) do
        if windows and index == 1 then word = word:gsub("/", "\\") end
        words[#words + 1] = quote(word)
    end
    local command
    if windows then
        command = 'set "LANG=C"&&set "LC_ALL=C"&&cd /d ' .. quote(cwd) ..
            '&&' .. table.concat(words, " ") .. ' 2>&1'
    else
        command = 'cd ' .. quote(cwd) .. ' && LC_ALL=C ' .. table.concat(words, " ") .. ' 2>&1'
    end
    local pipe, err = io.popen(command, "r")
    assert(pipe, err)
    local output = assert(pipe:read("a"))
    local ok, reason, status = pipe:close()
    assert(ok, table.concat(argv, " ") .. " failed (" .. tostring(reason) .. " " ..
        tostring(status) .. "):\n" .. output)
    return output
end

local function write(filename, text)
    local file = assert(io.open(filename, "wb"))
    assert(file:write(text))
    assert(file:close())
end

local function normalize(filename, cwd)
    if windows then filename = filename:gsub("\\", "/") end
    if not filename:match("^/") and not filename:match("^%a:/") then
        filename = cwd .. "/" .. filename
    end
    local prefix = filename:match("^%a:/") or (filename:sub(1, 2) == "//" and "//" or "/")
    local parts = {}
    for part in filename:sub(#prefix + 1):gmatch("[^/]+") do
        if part == ".." then parts[#parts] = nil
        elseif part ~= "." then parts[#parts + 1] = part end
    end
    filename = prefix .. table.concat(parts, "/")
    return windows and filename:lower() or filename
end

local function json_string(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(byte)
        if byte == '"' then return '\\"' end
        if byte == "\\" then return "\\\\" end
        return string.format("\\u%04x", byte:byte())
    end) .. '"'
end

-- Both gcov backends support annotated stdout. Use only real executable-line
-- records and source anchors; generated C functions/branches are not metrics.
local function collect(text, sources, anchors, cwd, counts)
    local current, allowed
    for line in text:gmatch("[^\n]+") do
        local count, number, body = line:match("^%s*([^:]+):%s*(%d+):(.*)$")
        number = tonumber(number)
        if number == 0 and body:sub(1, 7) == "Source:" then
            local source = normalize(body:sub(8):gsub("\r$", ""), cwd)
            current = sources[source]
            allowed = anchors and anchors[source]
        elseif current and number and number > 0 and (not anchors or allowed and allowed[number]) then
            count = count:match("^%s*(.-)%s*$"):gsub("%*$", "")
            local value = tonumber(count)
            if count:match("^[#=]+$") then value = 0 end
            if value then counts[current][number] = (counts[current][number] or 0) + value end
        end
    end
end

local HTML_TEMPLATE = [=[{% extends "base.html" %}
{% block summary %}
<p>{{info.lines.exec}} of {{info.lines.total}} executable lines covered ({{info.lines.coverage}}%).</p>
{% endblock %}
{% block content %}
<table class="file-list"><thead><tr><th>Source</th><th>Covered lines</th><th>Executable lines</th><th>Coverage</th></tr></thead><tbody>
{% for directory in directories %}{% for row in directory.entries %}
<tr><td>{% if row.link is not none %}<a href="#{{row.link}}">{{row.filename}}</a>{% else %}{{row.filename}}{% endif %}</td><td>{{row.lines.exec}}</td><td>{{row.lines.total}}</td><td>{{row.lines.coverage}}%</td></tr>
{% endfor %}{% endfor %}
</tbody></table>
{% for file in files %}
<section id="{{file.link}}"><h2>{{file.filename}}</h2>
<p>{{file.lines.exec}} of {{file.lines.total}} executable lines covered ({{file.lines.coverage}}%).</p>
<table><thead><tr><th>Line</th><th>Count</th><th>Source</th></tr></thead><tbody>
{% for row in file.source_lines %}
<tr class="source-line"><td class="lineno">{{row.lineno}}</td><td class="linecount {{row.covclass}}">{% if row.covclass == "uncoveredLine" %}0{% else %}{{row.linecount}}{% endif %}</td><td class="src {{row.covclass}}">{{row.source}}</td></tr>
{% endfor %}
</tbody></table></section>
{% endfor %}
{% endblock %}
]=]

local function rich_report(config, counts)
    local files, names = {}, {}
    for filename in pairs(counts) do names[#names + 1] = filename end
    table.sort(names)
    for _, filename in ipairs(names) do
        local lines, numbers = {}, {}
        for number in pairs(counts[filename]) do numbers[#numbers + 1] = number end
        table.sort(numbers)
        for _, number in ipairs(numbers) do
            lines[#lines + 1] = '{"line_number":' .. number .. ',"count":' ..
                counts[filename][number] .. ',"branches":[]}'
        end
        files[#files + 1] = '{"file":' .. json_string(filename) ..
            ',"functions":[],"lines":[' .. table.concat(lines, ",") .. ']}'
    end
    local trace = config.output .. "/lines.json"
    write(trace, '{"gcovr/format_version":"0.14","files":[' .. table.concat(files, ",") .. ']}\n')
    local empty_config = config.output .. "/gcovr.cfg"
    write(empty_config, "")
    local argv = { table.unpack(config.gcovr or { os.getenv("GCOVR") or "gcovr" }) }
    for _, argument in ipairs({ "--config", empty_config, "--root", config.root,
        "--add-tracefile", trace, "--no-markers", "--no-exclude-noncode-lines" }) do
        argv[#argv + 1] = argument
    end
    for _, format in ipairs(config.formats) do
        if format == "html" then
            write(config.output .. "/single_page.html", HTML_TEMPLATE)
            for _, value in ipairs({ "--html-details", config.output .. "/coverage.html",
                "--html-single-page", "static", "--html-template-dir", config.output,
                "--html-title", "Titan executable-line coverage" }) do argv[#argv + 1] = value end
        elseif format == "lcov" then
            argv[#argv + 1] = "--lcov"; argv[#argv + 1] = config.output .. "/coverage.info"
        elseif format == "cobertura" then
            argv[#argv + 1] = "--cobertura"; argv[#argv + 1] = config.output .. "/coverage.xml"
        else
            error("unknown coverage report format: " .. tostring(format))
        end
    end
    io.write(run(argv, config.root))
    -- LCOV interchange declares only the supported line metric.
    for _, format in ipairs(config.formats) do
        if format == "lcov" then
            local filename = config.output .. "/coverage.info"
            local file = assert(io.open(filename, "rb"))
            local text = assert(file:read("a")); assert(file:close())
            local lines = {}
            for line in text:gmatch("[^\r\n]+") do
                if not line:match("^FN[FH]?:") and not line:match("^BR[FH]?:") and
                    not line:match("^FNDA:") and not line:match("^BRDA:") then
                    -- Tracefiles need no per-line checksum. gcovr 8.4 writes
                    -- the literal None when the optional JSON checksum is
                    -- absent; omit that third LCOV field.
                    lines[#lines + 1] = (line:gsub("^(DA:%d+,%d+),None$", "%1"))
                end
            end
            write(filename, table.concat(lines, "\n") .. "\n")
        end
    end
end

function coverage.prepare(config)
    for _, filename in ipairs(config.files) do
        local data = filename:gsub("[.]c$", ".gcda")
        local ok, err, code = os.remove(data)
        if not ok and code ~= 2 then error("cannot reset coverage counters: " .. tostring(err)) end
    end
    return true
end

-- Implementation notes: doc/implementation/native-coverage.md#direct-execution-and-reports
function coverage.finish(config)
    local sources, counts = {}, {}
    local cwd = config.working_directory or config.root
    for _, filename in ipairs(config.sources) do
        sources[normalize(filename, cwd)] = filename
        counts[filename] = {}
    end
    local native_output = {}
    for _, filename in ipairs(config.files) do
        local argv = { table.unpack(config.gcov) }
        for _, argument in ipairs({ "-t", "-p", (filename:gsub("[.]c$", ".gcno")) }) do
            argv[#argv + 1] = argument
        end
        local output = run(argv, cwd)
        native_output[#native_output + 1] = output
        local anchors
        if config.anchors then
            anchors = {}
            for source, numbers in pairs(config.anchors[filename] or {}) do
                local lines = {}
                for _, number in ipairs(numbers) do lines[number] = true end
                anchors[normalize(source, cwd)] = lines
            end
        end
        collect(output, sources, anchors, cwd, counts)
    end
    write(config.output .. "/coverage.gcov", table.concat(native_output, "\n"))
    local total, covered = 0, 0
    for _, lines in pairs(counts) do
        for _, count in pairs(lines) do
            total = total + 1
            if count > 0 then covered = covered + 1 end
        end
    end
    io.write(string.format("Titan executable lines: %d/%d (%.1f%%)\n", covered, total,
        total > 0 and 100 * covered / total or 0))
    io.write("Coverage report: " .. config.output .. "/coverage.gcov\n")
    if config.formats and #config.formats > 0 then rich_report(config, counts) end
    return true
end

return coverage
