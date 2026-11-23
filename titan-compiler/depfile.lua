-- Native -MD/-MF output is data, not a Make program. Preserve prerequisite
-- order while decoding the escaping emitted by GCC and Clang on all hosts.
local platform = require "titan-compiler.platform"
local depfile = {}

local function parse(text, phony, main)
    if type(text) ~= "string" or text:find("\0", 1, true) then
        return nil, "depfile must be a NUL-free string"
    end
    local result, seen, token = main and { main } or {}, {}, {}
    local prerequisites, targets, rules = false, 0, 0
    local observed, remaining = phony and {} or nil, 0
    local target, has_input
    local duplicate
    local function flush()
        if #token == 0 then return end
        local name = table.concat(token)
        token = {}
        if prerequisites then
            if phony then
                has_input = true
                if rules == 0 then
                    observed[name] = (observed[name] or 0) + 1
                    remaining = remaining + 1
                end
            elseif not seen[name] then
                seen[name] = true
                result[#result + 1] = name
            end
        else
            targets = targets + 1
            target = name
        end
    end
    local function finish()
        flush()
        if targets ~= 0 and not prerequisites then
            return nil, "depfile rule has no target separator"
        end
        if prerequisites then
            if phony and rules > 0 then
                if targets ~= 1 or has_input then
                    return nil, "invalid phony dependency rule"
                end
                local count = observed[target] or 0
                if count == 0 then
                    return nil, "phony dependency is absent from the primary rule: " .. target
                end
                observed[target] = count - 1
                remaining = remaining - 1
                if seen[target] then
                    duplicate = duplicate or target
                else
                    seen[target] = true
                    result[#result + 1] = target
                end
            end
            rules = rules + 1
        end
        prerequisites, targets, has_input = false, 0, false
        return true
    end
    local index = 1
    while index <= #text do
        local ch, nextch = text:sub(index, index), text:sub(index + 1, index + 1)
        if ch == "\\" then
            if nextch == "\n" or (nextch == "\r" and text:sub(index + 2, index + 2) == "\n") then
                flush()
                index = index + (nextch == "\r" and 3 or 2)
            elseif nextch == " " or nextch == "\t" or nextch == "#"
                or nextch == ":" or nextch == "\\" then
                token[#token + 1] = nextch
                index = index + 2
            elseif nextch == "" then
                return nil, "depfile ends in an escape"
            else
                -- A Windows path separator is not a C-style escape.
                token[#token + 1] = ch
                index = index + 1
            end
        elseif ch == "$" then
            if nextch ~= "$" then return nil, "depfile contains a Make variable" end
            token[#token + 1] = "$"
            index = index + 2
        elseif ch == "#" then
            while index <= #text and text:sub(index, index) ~= "\n" do
                index = index + 1
            end
        elseif ch == "\n" or ch == "\r" then
            local ok, err = finish()
            if not ok then return nil, err end
            index = index + (ch == "\r" and nextch == "\n" and 2 or 1)
        elseif ch == " " or ch == "\t" then
            flush()
            index = index + 1
        elseif ch == ":" then
            local drive = #token == 1 and token[1]:match("^[A-Za-z]$")
                and (nextch == "/" or nextch == "\\")
            if drive then
                token[#token + 1] = ch
            elseif not prerequisites then
                flush()
                if targets == 0 then return nil, "depfile rule has no target" end
                prerequisites = true
            else
                return nil, "depfile contains an unescaped prerequisite colon"
            end
            index = index + 1
        else
            token[#token + 1] = ch
            index = index + 1
        end
    end
    local ok, err = finish()
    if not ok then return nil, err end
    if rules == 0 then return nil, "depfile contains no rules" end
    if phony and remaining ~= (main and 1 or 0) then
        return nil, "incomplete phony dependency inventory"
    end
    if duplicate then
        -- GCC can list the same header twice. The one word left over after
        -- matching the phony rules is the reported main, not necessarily the
        -- first prerequisite. If it retained a backslash, this was not the
        -- slash-folding reporter, so repeated header words are not collisions.
        if main then
            for spelling, count in pairs(observed) do
                if count == 1 and spelling:find("\\", 1, true) then return result end
            end
        end
        return nil, "ambiguous dependency spelling: " .. duplicate
    end
    return result
end

function depfile.parse(text)
    return parse(text)
end

-- Clang's POSIX Make writer can turn a literal backslash into a slash. With
-- -MP the phony targets describe the included files but never the main TU,
-- even when a distinct header has the same reported spelling as that TU.
function depfile.append_compiler_options(argv, source, report, target)
    local exact_main = not platform.windows and source:find("\\", 1, true) and source or nil
    argv[#argv + 1] = "-MD"
    if exact_main then argv[#argv + 1] = "-MP" end
    argv[#argv + 1] = "-MF"
    argv[#argv + 1] = report
    argv[#argv + 1] = "-MT"
    argv[#argv + 1] = target
    return exact_main
end

function depfile.compiler_inputs(text, exact_main)
    return parse(text, exact_main ~= nil, exact_main)
end

-- ELF LLD reports every input both as a prerequisite and as a phony rule.
function depfile.lld_inputs(text)
    return parse(text, true)
end

-- Publish the same provenance Titan certified, not the lossy compiler report.
function depfile.render(target, inputs)
    local words = { target .. ":" }
    for _, name in ipairs(inputs) do
        if name:find("[\r\n%z]") then return nil, "dependency path cannot be written to a depfile" end
        words[#words + 1] = (name:gsub("[\\ \t#:$]", function(byte)
            return byte == "$" and "$$" or "\\" .. byte
        end))
    end
    return table.concat(words, " ") .. "\n"
end

return depfile
