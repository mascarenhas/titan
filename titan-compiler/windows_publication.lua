-- Publish already validated Windows files. This module never loads Titan or
-- a provider; the caller supplies its filesystem helpers and ordered entries.
-- Caught failures roll back. Concurrent readers and power loss are not atomic.
local publication = {}

local function copy_file(source, destination)
    local input, err = io.open(source, "rb")
    if not input then return nil, err end
    local output
    output, err = io.open(destination, "wb")
    if not output then input:close(); return nil, err end
    while true do
        local bytes, read_error = input:read(65536)
        if read_error then
            input:close(); output:close(); return nil, read_error
        end
        if not bytes then break end
        local wrote, write_error = output:write(bytes)
        if not wrote then
            input:close(); output:close(); return nil, write_error
        end
    end
    local input_ok, input_error = input:close()
    local output_ok, output_error = output:close()
    return input_ok and output_ok, input_error or output_error
end

local function same_file_contents(left, right)
    local input = io.open(left, "rb")
    if not input then return false end
    local existing = io.open(right, "rb")
    if not existing then input:close(); return false end
    local same = true
    while true do
        local bytes, read_error = input:read(65536)
        local previous, previous_error = existing:read(65536)
        if read_error or previous_error or bytes ~= previous then
            same = false
            break
        end
        if not bytes then break end
    end
    input:close()
    existing:close()
    return same
end

function publication.publish(entries, fs, options)
    options = options or {}
    local prepared = {}
    local function need(ok, err)
        if not ok then error(tostring(err), 0) end
        return ok
    end
    local function regular(path, optional)
        local attr, err, code = fs.stat(path)
        if not attr then
            if optional and (code == 2 or code == 3) then return nil end
            error(err or ("cannot inspect " .. path), 0)
        end
        need(attr.kind == "file", "publication path is not a regular nonlink file: " .. path)
        return attr
    end
    local completed, failure = pcall(function()
        local destinations = {}
        for _, entry in ipairs(entries) do
            need(type(entry.destination) == "string", "missing publication destination")
            need(type(entry.source) == "string", "missing publication source")
            local key = entry.destination:gsub("\\", "/"):lower()
            need(not destinations[key], "duplicate publication destination: " .. entry.destination)
            destinations[key] = true
            local existing = regular(entry.destination, true)
            need(entry.source:gsub("\\", "/"):lower() ~= key,
                "publication source aliases destination: " .. entry.destination)
            local source = regular(entry.source)
            need(not existing or source.device == nil or source.inode == nil or
                source.device ~= existing.device or source.inode ~= existing.inode,
                "publication source aliases destination: " .. entry.destination)
            local item = { public = entry.destination }
            prepared[#prepared + 1] = item
            item.stage = need(fs.reserve(entry.destination))
            need(copy_file(entry.source, item.stage))
            item.unchanged = existing and
                same_file_contents(item.stage, item.public)
        end
        -- Copy predecessors without renaming them. Windows can rename a mapped
        -- image, but rejects replacing that image; keep it at the public path
        -- until the replacement itself succeeds.
        for _, item in ipairs(prepared) do
            if not item.unchanged and regular(item.public, true) then
                item.backup = need(fs.reserve(item.public))
                need(copy_file(item.public, item.backup))
            end
        end
        -- A final-link success marker must disappear before the first public
        -- mutation. Preparation/backups above leave the predecessor intact.
        if options.before_commit then need(options.before_commit()) end
        -- The caller orders its commit point (the provider or launcher) last.
        for index, item in ipairs(prepared) do
            if not item.unchanged then
                item.replacement_attempted = true
                need(fs.replace(item.stage, item.public))
                item.stage = nil
                item.committed = true
            end
            if not item.unchanged and options.after_commit then
                need(options.after_commit(index, item.public))
            end
        end
    end)
    local cleanup_errors = {}
    local function record(ok, err)
        if not ok then cleanup_errors[#cleanup_errors + 1] = tostring(err) end
        return ok
    end
    if not completed then
        for index = #prepared, 1, -1 do
            local item = prepared[index]
            local restore = item.committed
            if not restore and item.backup and item.replacement_attempted then
                -- Ordinary Windows replacement can delete the destination
                -- before a failed rename. A mapped image remains present.
                local existing, _, code = fs.stat(item.public)
                restore = not existing and (code == 2 or code == 3)
            end
            if restore then
                if item.backup then
                    if record(fs.replace(item.backup, item.public)) then
                        item.backup = nil
                    else
                        -- Preserve the only saved predecessor for manual repair.
                        item.keep_backup = true
                    end
                else
                    record(fs.remove(item.public))
                end
            end
        end
    end
    for _, item in ipairs(prepared) do
        if item.stage then record(fs.remove(item.stage)) end
        if item.backup and not item.keep_backup then record(fs.remove(item.backup)) end
    end
    if not completed or #cleanup_errors > 0 then
        return nil, (completed and "publication committed but cleanup failed" or tostring(failure)) ..
            (#cleanup_errors > 0 and ("\npublication cleanup: " .. table.concat(cleanup_errors, "; ")) or "")
    end
    return true
end

-- A standalone Windows program owns both images, even with an external --exe
-- destination. Commit the launcher last and roll the whole set back on any
-- caught failure; an interrupted set has no success certificate.
function publication.publish_program(request, fs, options)
    if type(request) ~= "table" or type(request.provider) ~= "table" or
        type(request.executable) ~= "table" or not request.provider.source or
        not request.executable.source then
        return nil, "Windows program publication requires staged DLL and EXE"
    end
    return publication.publish({ request.provider, request.executable }, fs, options)
end

return publication
