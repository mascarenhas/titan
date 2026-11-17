-- Run the commands that a manual chapter documents, exactly as written.
--
-- A fenced block takes part only when an HTML comment marker, which Markdown
-- renders invisibly, comes right before it:
--
--   <!-- doc-check: file=site/index.html -->  write the block to that workspace path
--   <!-- doc-check: run -->                   run the `sh` block
--   <!-- doc-check: setup=checkout -->        run the `sh` block that clones Titan
--   <!-- doc-check: expect=page -->           expected text, for the caller to compare
--
-- Every other block is never run. The marked blocks of all documents become one
-- `set -eu` shell script, so `cd`, `export` and the files a block writes carry
-- over to later blocks; each document starts in the workspace. Commands get a
-- short, fixed list of substitutions (`M.substitutions`), each printed when it
-- applies. A block that needs a substitution whose option is missing, and an
-- option that no block needs, are errors.
--
--   lua scripts/doc_check.lua --workspace DIR [--checkout DIR] [--prefix DIR]
--       [--source DIR] [--vite-root DIR] [--expect-dir DIR] DOCUMENT...
local M = {}

local function quote(text)
    return "'" .. text:gsub("'", "'\\''") .. "'"
end

-- Documented spelling -> replacement, for command blocks only. `option` names
-- the value that the replacement needs; `setup` substitutions apply only to the
-- checkout block, which must contain theirs.
M.substitutions = {
    { option = "checkout", setup = true,
        from = "git clone --recurse-submodules https://github.com/mascarenhas/titan",
        -- A fresh clone of the commit under test; local submodule clones need
        -- the file transport that Git 2.38 and newer refuse by default.
        to = function(path)
            return "git -c protocol.file.allow=always clone --recurse-submodules " .. quote(path) .. " titan"
        end },
    { option = "prefix", from = "$HOME/.local/titan/my-project",
        to = function(path) return path end },
    { option = "source", from = "/path/to/titan",
        to = function(path) return path end },
    { option = "vite_root", from = "npm install --save-dev vite",
        to = function(path) return "ln -s " .. quote(path .. "/node_modules") .. " node_modules" end },
}

local function marker(line)
    local value = line:match("^%s*<!%-%-%s*doc%-check:%s*(.-)%s*%-%->%s*$")
    if value then return value end
    if line:match("^%s*<!%-%-%s*doc%-check") then return false end
    return nil
end

local function parse_marker(value, where)
    if value == "run" then return { kind = "run" } end
    if value == "setup=checkout" then return { kind = "setup" } end
    local path = value:match("^file=(.+)$")
    if path then
        if not path:match("^[%w._%-/]+$") or path:sub(1, 1) == "/" or path:sub(-1) == "/" then
            return nil, where .. ": file path " .. path .. " is not a plain relative path"
        end
        for component in path:gmatch("[^/]+") do
            if component == "." or component == ".." then
                return nil, where .. ": file path " .. path .. " leaves the workspace"
            end
        end
        return { kind = "file", path = path }
    end
    local label = value:match("^expect=([%w_%-]+)$")
    if label then return { kind = "expect", label = label } end
    return nil, where .. ": unknown doc-check marker '" .. value .. "'"
end

-- The marked blocks of one document, in order: { kind, line, info, body, ... }.
function M.parse(text, name)
    local lines = {}
    for line in (text:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    local blocks = {}
    local index = 1
    while index <= #lines do
        local value = marker(lines[index])
        if value == false then
            return nil, name .. ":" .. index .. ": malformed doc-check marker"
        elseif value then
            local where = name .. ":" .. index
            local block, err = parse_marker(value, where)
            if not block then return nil, err end
            local fence_line = index + 1
            while lines[fence_line] and lines[fence_line]:match("^%s*$") do fence_line = fence_line + 1 end
            local indent, fence, info = (lines[fence_line] or ""):match("^(%s*)(```+)%s*([^`]*)$")
            if not fence then
                return nil, where .. ": doc-check marker is not followed by a fenced block"
            end
            info = info:match("^(%S*)")
            local body = {}
            local closing = fence_line + 1
            while true do
                local line = lines[closing]
                if not line then return nil, where .. ": unterminated fenced block" end
                local close = line:match("^%s*(```+)%s*$")
                if close and #close >= #fence then break end
                if line:sub(1, #indent) == indent then
                    line = line:sub(#indent + 1)
                elseif not line:match("^%s*$") then
                    return nil, name .. ":" .. closing .. ": line is indented less than its fence"
                end
                body[#body + 1] = line
                closing = closing + 1
            end
            if (block.kind == "run" or block.kind == "setup") and info ~= "sh" then
                return nil, where .. ": doc-check " .. block.kind .. " needs an sh block, not '" .. info .. "'"
            end
            block.document, block.line, block.info = name, fence_line, info
            block.body = table.concat(body, "\n") .. "\n"
            blocks[#blocks + 1] = block
            index = closing + 1
        else
            -- A marker spelled inside an unmarked block is only text.
            local fence = lines[index]:match("^%s*(```+)")
            index = index + 1
            while fence and lines[index] do
                local close = lines[index]:match("^%s*(```+)%s*$")
                index = index + 1
                if close and #close >= #fence then break end
            end
        end
    end
    return blocks
end

-- One `## heading` section of a document, up to the next `## ` heading outside
-- a fenced block, for a caller that checks a single section. The other lines
-- become empty, so diagnostics keep the document's line numbers.
function M.section(text, heading)
    local lines, inside, found, fence = {}, false, false, nil
    for line in (text:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
        local ticks = line:match("^%s*(```+)")
        if fence then
            if ticks and #ticks >= #fence and line:match("^%s*```+%s*$") then fence = nil end
        elseif ticks then
            fence = ticks
        elseif line:match("^## ") then
            inside = line == "## " .. heading
            found = found or inside
        end
        lines[#lines + 1] = inside and line or ""
    end
    if not found then return nil, "no section '## " .. heading .. "'" end
    return table.concat(lines, "\n")
end

-- Apply the substitutions to one command block. `used` collects the options
-- that applied; `log` receives one line per applied substitution.
local function substitute(block, options, used, log)
    local body = block.body
    for _, rule in ipairs(M.substitutions) do
        local found = body:find(rule.from, 1, true)
        if rule.setup and block.kind == "setup" and not found then
            return nil, block.document .. ":" .. block.line .. ": the checkout block does not run '" .. rule.from .. "'"
        end
        if found and (not rule.setup or block.kind == "setup") then
            local value = options[rule.option]
            if not value then
                return nil, block.document .. ":" .. block.line .. ": '" .. rule.from .. "' needs --" ..
                    rule.option:gsub("_", "-")
            end
            local replacement = rule.to(value)
            body = body:gsub(rule.from:gsub("%p", "%%%0"), (replacement:gsub("%%", "%%%%")))
            used[rule.option] = true
            log[#log + 1] = block.document .. ":" .. block.line .. ": " .. rule.from .. " -> " .. replacement
        end
    end
    return body
end

-- The shell script and the expected texts for documents { name, text }.
-- options: workspace (required) and the substitution values.
function M.plan(documents, options)
    assert(options.workspace, "doc-check needs a workspace")
    local script = { "set -eu", "" }
    local expectations, log, used, heredocs = {}, {}, {}, 0
    for _, document in ipairs(documents) do
        local blocks, err = M.parse(document.text, document.name)
        if not blocks then return nil, err end
        script[#script + 1] = "cd " .. quote(options.workspace)
        for _, block in ipairs(blocks) do
            local where = block.document .. ":" .. block.line
            if block.kind == "expect" then
                if expectations[block.label] then
                    return nil, where .. ": expect=" .. block.label .. " appears twice"
                end
                expectations[block.label] = block.body
            elseif block.kind == "file" then
                heredocs = heredocs + 1
                local delimiter = "DOC_CHECK_EOF_" .. heredocs
                if ("\n" .. block.body):find("\n" .. delimiter .. "\n", 1, true) then
                    return nil, where .. ": block contains its heredoc delimiter"
                end
                local target = options.workspace .. "/" .. block.path
                script[#script + 1] = "echo " .. quote("doc-check: " .. where .. " file=" .. block.path)
                script[#script + 1] = "mkdir -p " .. quote(target:match("^(.*)/"))
                script[#script + 1] = "cat > " .. quote(target) .. " <<'" .. delimiter .. "'"
                script[#script + 1] = block.body .. delimiter
            else
                local body, substitution_error = substitute(block, options, used, log)
                if not body then return nil, substitution_error end
                script[#script + 1] = "echo " .. quote("doc-check: " .. where .. " " .. block.kind)
                script[#script + 1] = body
            end
        end
    end
    for _, rule in ipairs(M.substitutions) do
        if options[rule.option] and not used[rule.option] then
            return nil, "--" .. rule.option:gsub("_", "-") .. " given, but no block runs '" .. rule.from .. "'"
        end
    end
    return { script = table.concat(script, "\n") .. "\n", expectations = expectations, substitutions = log }
end

-- Run a plan's script with `sh`, streaming its output, with the variables of
-- `environment` (name -> value, or false to unset) set. Returns true on success.
function M.run(plan, environment)
    for _, line in ipairs(plan.substitutions) do io.stdout:write("doc-check substitution: ", line, "\n") end
    io.stdout:flush()
    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))
    assert(file:write(plan.script)); assert(file:close())
    local names = {}
    for name in pairs(environment or {}) do names[#names + 1] = name end
    table.sort(names)
    local command = { "env" }
    -- env takes its -u options before any assignment.
    for _, name in ipairs(names) do
        if environment[name] == false then command[#command + 1] = "-u " .. quote(name) end
    end
    for _, name in ipairs(names) do
        local value = environment[name]
        if value ~= false then command[#command + 1] = quote(name .. "=" .. value) end
    end
    command[#command + 1] = "sh " .. quote(path)
    local ok, how, status = os.execute(table.concat(command, " "))
    os.remove(path)
    if ok then return true end
    return nil, "doc-check script failed (" .. tostring(how) .. " " .. tostring(status) .. ")"
end

local function main(arguments)
    local options, names = {}, {}
    local index = 1
    while index <= #arguments do
        local argument = arguments[index]
        local option = argument:match("^%-%-([%w%-]+)$")
        if option then
            local key = option:gsub("%-", "_")
            local value = arguments[index + 1]
            if not value then error("--" .. option .. " needs a value", 0) end
            if key ~= "workspace" and key ~= "expect_dir" then
                local known = false
                for _, rule in ipairs(M.substitutions) do known = known or rule.option == key end
                if not known then error("unknown option --" .. option, 0) end
            end
            options[key] = value
            index = index + 2
        else
            names[#names + 1] = argument
            index = index + 1
        end
    end
    if not options.workspace or #names == 0 then
        error("usage: doc_check.lua --workspace DIR [--checkout DIR] [--prefix DIR] " ..
            "[--source DIR] [--vite-root DIR] [--expect-dir DIR] DOCUMENT...", 0)
    end
    local documents = {}
    for _, name in ipairs(names) do
        local file = assert(io.open(name, "rb"))
        documents[#documents + 1] = { name = name, text = assert(file:read("a")) }
        file:close()
    end
    local plan = assert(M.plan(documents, options))
    if options.expect_dir then
        for label, text in pairs(plan.expectations) do
            local file = assert(io.open(options.expect_dir .. "/" .. label .. ".txt", "wb"))
            assert(file:write(text)); assert(file:close())
        end
    end
    assert(M.run(plan))
end

if arg and arg[0] and arg[0]:match("doc_check%.lua$") then
    local ok, err = pcall(main, arg)
    if not ok then io.stderr:write("doc-check: ", tostring(err), "\n"); os.exit(1) end
    os.exit(0)
end

return M
