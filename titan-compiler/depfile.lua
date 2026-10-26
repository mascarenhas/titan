-- Native -MD/-MF output is data, not a Make program. Preserve prerequisite
-- order while decoding the escaping emitted by GCC and Clang on all hosts.
local depfile = {}

function depfile.parse(text)
    if type(text) ~= "string" or text:find("\0", 1, true) then
        return nil, "depfile must be a NUL-free string"
    end
    local result, seen, token = {}, {}, {}
    local prerequisites, targets, rules = false, 0, 0
    local function flush()
        if #token == 0 then return end
        local name = table.concat(token)
        token = {}
        if prerequisites then
            if not seen[name] then
                seen[name] = true
                result[#result + 1] = name
            end
        else
            targets = targets + 1
        end
    end
    local function finish()
        flush()
        if targets ~= 0 and not prerequisites then
            return nil, "depfile rule has no target separator"
        end
        if prerequisites then rules = rules + 1 end
        prerequisites, targets = false, 0
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
    return result
end

return depfile
