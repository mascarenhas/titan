-- A tiny terminal for assertions on reporter output: printable bytes, CR, LF,
-- cursor up/down and erase-from-cursor, the subset the live renderer emits.
-- `render` returns the visible rows of the final screen, so a test can prove
-- that text survived later redraws instead of only that the bytes were written.
local M = {}

local function row_of(rows, index)
    while #rows < index do rows[#rows + 1] = {} end
    return rows[index]
end

function M.render(text)
    local rows, row, column = { {} }, 1, 1
    local index = 1
    while index <= #text do
        local byte = text:sub(index, index)
        if byte == "\27" then
            local params, code = text:match("^\27%[([0-9;]*)(%a)", index)
            if not params then break end
            if code == "J" then
                local current = row_of(rows, row)
                for cell = column, #current do current[cell] = nil end
                for beyond = row + 1, #rows do rows[beyond] = nil end
            elseif code == "K" then
                local current = row_of(rows, row)
                for cell = column, #current do current[cell] = nil end
            elseif code == "A" then
                row = math.max(1, row - (tonumber(params) or 1))
            elseif code == "B" then
                row = row + (tonumber(params) or 1)
            end
            index = index + #params + 3
        elseif byte == "\r" then
            column = 1
            index = index + 1
        elseif byte == "\n" then
            row, column = row + 1, 1
            index = index + 1
        else
            local current = row_of(rows, row)
            while #current < column - 1 do current[#current + 1] = " " end
            current[column] = byte
            column = column + 1
            index = index + 1
        end
    end
    local lines = {}
    for position = 1, #rows do
        lines[position] = (table.concat(rows[position]):gsub("%s+$", ""))
    end
    return lines
end

-- True when some visible row contains `text`.
function M.shows(screen, text)
    for _, line in ipairs(screen) do
        if line:find(text, 1, true) then return true end
    end
    return false
end

return M
