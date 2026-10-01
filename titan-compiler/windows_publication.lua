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
            local key = entry.destination:gsub("\\", "/"):lower()
            need(not destinations[key], "duplicate publication destination: " .. entry.destination)
            destinations[key] = true
            local existing = regular(entry.destination, true)
            if entry.source then
                local source = regular(entry.source)
                need(not existing or source.device ~= existing.device or
                    source.inode ~= existing.inode,
                    "publication source aliases destination: " .. entry.destination)
            end
            if options.validate_existing then
                need(options.validate_existing(entry, existing))
            end
            local item = { public = entry.destination, remove = entry.remove }
            prepared[#prepared + 1] = item
            if not entry.remove then
                item.stage = need(fs.reserve(entry.destination))
                if entry.contents ~= nil then
                    local file = need(io.open(item.stage, "wb"))
                    local wrote, write_error = file:write(entry.contents)
                    local closed, close_error = file:close()
                    need(wrote and closed, write_error or close_error)
                else
                    need(copy_file(assert(entry.source), item.stage))
                end
            end
        end
        -- Copy predecessors without renaming them. Windows can rename a mapped
        -- image, but rejects replacing that image; keep it at the public path
        -- until the replacement itself succeeds.
        for _, item in ipairs(prepared) do
            if regular(item.public, true) then
                item.backup = need(fs.reserve(item.public))
                need(copy_file(item.public, item.backup))
            end
        end
        -- The caller orders the provider last, after its exact shim/source set.
        for index, item in ipairs(prepared) do
            if item.stage then
                need(fs.replace(item.stage, item.public))
                item.stage = nil
                item.committed = true
            elseif item.backup then
                need(fs.remove(item.public))
                item.committed = true
            end
            if options.after_commit then need(options.after_commit(index, item.public)) end
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
            if item.committed then
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

return publication
