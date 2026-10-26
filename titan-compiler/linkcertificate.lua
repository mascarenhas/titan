-- Final-output certificates are data, never executable cache entries. The
-- coordinator holds the output-domain locks for this module's entire lifetime.
local incremental = require "titan-compiler.incremental"
local depfile = require "titan-compiler.depfile"
local graphcodec = require "titan-compiler.graphcodec"
local paths = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local version = require "titan-compiler.version"
local util = require "titan-compiler.util"

local certificate = {}
local RECORD_LIMIT = 16 * 1024 * 1024
local RECIPE_FIELDS = {
    "roots", "entry", "kind", "no_uv_bootstrap", "argv", "toolchain",
    "test_cases", "templates", "coverage", "companions", "policy",
    "bindings", "target", "environment",
}
local FILE_FIELDS = { "objects", "c_objects", "payloads", "providers", "archives", "runtime" }

local function need(value, err)
    if value == nil or value == false then error(err or "certificate operation failed", 0) end
    return value
end

local function fresh(context)
    return { io = context.io, cache_adapter = context.cache_adapter }
end

local function absolute(context, path)
    local cwd = need(context.io:cwd())
    return need(platform.absolute(path, cwd))
end

local function canonical(context, path)
    -- realpath also accepts a missing leaf with Sync; hosts may require the
    -- nearest existing parent. Preserve that physical parent's spelling.
    path = absolute(context, path)
    local missing, current = {}, path
    while true do
        local stat, err = context.io:lstat(current)
        if err then error(err, 0) end
        if stat then
            current = need(context.io:realpath(current))
            break
        end
        local parent = paths.dirname(current)
        need(parent ~= current, "cannot canonicalize output path: " .. path)
        table.insert(missing, 1, paths.basename(current))
        current = parent
    end
    for _, leaf in ipairs(missing) do current = paths.join(current, leaf) end
    return platform.windows and current:gsub("\\", "/"):lower() or current
end
certificate.canonical_path = canonical

local function mkdir(context, directory)
    local stat, err = context.io:lstat(directory)
    if err then error(err, 0) end
    if stat then
        need(stat.kind == "directory", "certificate directory is not a nonlink directory: " .. directory)
        return
    end
    local parent = paths.dirname(directory)
    if parent ~= directory then mkdir(context, parent) end
    need(context.io:mkdir(directory))
end
certificate.make_directory = mkdir

local function data_only(value, seen)
    local kind = type(value)
    if kind == "nil" or kind == "string" or kind == "boolean" then return true end
    if kind == "number" then return value == value and value ~= math.huge and value ~= -math.huge end
    if kind ~= "table" or getmetatable(value) ~= nil then return false end
    seen = seen or {}
    if seen[value] then return false end
    seen[value] = true
    for key, item in pairs(value) do
        if (type(key) ~= "string" and math.type(key) ~= "integer") or not data_only(item, seen) then
            return false
        end
    end
    seen[value] = nil
    return true
end

local function closed(value, fields)
    if type(value) ~= "table" or getmetatable(value) then return false end
    for key in pairs(value) do if not fields[key] then return false end end
    return true
end

local function digest_string(value)
    return type(value) == "string" and #value == 64 and not value:find("[^0-9a-f]")
end

local function dense(list)
    if type(list) ~= "table" then return false end
    for key in pairs(list) do
        if math.type(key) ~= "integer" or key < 1 or key > #list then return false end
    end
    return true
end

local function valid_files(files)
    if not dense(files) then return false end
    for _, file in ipairs(files) do
        if not closed(file, { path = true, identity = true }) or
            type(file.path) ~= "string" or not digest_string(file.identity) then return false end
    end
    return true
end

local function valid_snapshot(snapshot)
    if not closed(snapshot, { path = true, kind = true, mode = true, identity = true, entries = true }) or
        type(snapshot.path) ~= "string" or math.type(snapshot.mode) ~= "integer" then return false end
    if snapshot.kind == "file" then
        return digest_string(snapshot.identity) and snapshot.entries == nil
    elseif snapshot.kind == "directory" and snapshot.identity == nil and dense(snapshot.entries) then
        for _, entry in ipairs(snapshot.entries) do if not valid_snapshot(entry) then return false end end
        return true
    end
    return false
end

local function record_valid(record)
    if not data_only(record) then return false end
    if not closed(record, { schema = true, digest = true, canonicalization = true, input = true,
        outputs = true, native = true }) or record.schema ~= version.TITAN_LINK_RECORD_SCHEMA or
        record.digest ~= version.CERTIFICATE_DIGEST or
        record.canonicalization ~= version.CERTIFICATE_CANONICALIZATION or
        not digest_string(record.input) or not dense(record.outputs) or not valid_files(record.native) then
        return false
    end
    for _, output in ipairs(record.outputs) do if not valid_snapshot(output) then return false end end
    return true
end

local function codec_options(context)
    return { max_bytes = RECORD_LIMIT, max_nodes = 100000, max_entries = 400000,
        max_string_bytes = RECORD_LIMIT, sha256_binary = context.cache_adapter and
            context.cache_adapter.sha256_binary }
end

function certificate.read_record(context, filename)
    local stat, err = context.io:lstat(filename)
    if not stat then return nil, err or "missing record" end
    if stat.kind ~= "file" or stat.size > RECORD_LIMIT then return nil, "invalid record file" end
    local bytes
    bytes, err = context.io:read_file(filename, RECORD_LIMIT)
    if not bytes then return nil, err end
    return graphcodec.decode(bytes, codec_options(context))
end

function certificate.write_record(context, filename, record)
    local bytes, err = graphcodec.encode(record, codec_options(context))
    if not bytes then return nil, err end
    return context.io:write_file(filename, bytes)
end

function certificate.files(context, files)
    local result = {}
    for _, file in ipairs(files or {}) do
        local filename = type(file) == "table" and file.path or file
        need(type(filename) == "string", "native input must name a file")
        filename = absolute(context, filename)
        result[#result + 1] = { path = filename, identity = incremental.file_digest(context, filename) }
    end
    return result
end

local function output_snapshot(context, output)
    local filename = output.path
    local stat, err = context.io:lstat(filename)
    need(stat, err or ("missing output: " .. filename))
    need(stat.kind == "file" or stat.kind == "directory", "output is not a nonlink file/directory: " .. filename)
    if output.kind then need(stat.kind == output.kind, "output kind changed: " .. filename) end
    if output.executable and not platform.windows then
        need((stat.mode & 0x49) ~= 0, "output is not executable: " .. filename)
    end
    local result = { path = filename, kind = stat.kind, mode = stat.mode }
    if stat.kind == "file" then
        result.identity = incremental.file_digest(context, filename)
    else
        result.entries = {}
        local names = need(context.io:list(filename))
        table.sort(names, util.bytewise_less)
        for _, name in ipairs(names) do
            need(name ~= "." and name ~= ".." and not name:find("[/\\]"), "invalid directory member")
            result.entries[#result.entries + 1] = output_snapshot(context, { path = paths.join(filename, name) })
        end
    end
    return result
end

local function compiler_libraries(context, request)
    if type(request.compiler_argv) ~= "table" or #request.compiler_argv == 0 then
        return nil, "native library fallback requires compiler argv"
    end
    local directories, libraries, static = {}, {}, request.static or false
    local argv, index = {}, 1
    for _, flag in ipairs(request.argv or {}) do
        if flag:sub(1, 4) == "-Wl," then
            for part in flag:sub(5):gmatch("[^,]+") do argv[#argv + 1] = part end
        else argv[#argv + 1] = flag end
    end
    while index <= #argv do
        local flag = argv[index]
        if flag == "-L" or flag == "-l" then
            index = index + 1
            local value = argv[index]
            if not value then return nil, "incomplete native library option" end
            if flag == "-L" then directories[#directories + 1] = value
            else libraries[#libraries + 1] = { name = value, static = static } end
        elseif flag:sub(1, 2) == "-L" then directories[#directories + 1] = flag:sub(3)
        elseif flag:sub(1, 2) == "-l" then libraries[#libraries + 1] = { name = flag:sub(3), static = static }
        elseif flag == "-static" or flag == "-Bstatic" then static = true
        elseif flag == "-Bdynamic" then static = false
        elseif flag == "-T" or flag:sub(1, 2) == "-T" or flag:find("--script", 1, true) then
            return nil, "linker scripts require dependency output"
        end
        index = index + 1
    end
    for _, directory in ipairs(request.library_dirs or {}) do directories[#directories + 1] = directory end
    for _, library in ipairs(request.libraries or {}) do
        libraries[#libraries + 1] = { name = library, static = static }
    end
    local files = {}
    for _, item in ipairs(libraries) do
        local library, candidates = item.name
        if library:sub(1, 1) == ":" then candidates = { library:sub(2) }
        elseif item.static then candidates = { "lib" .. library .. ".a" }
        elseif platform.windows then
            candidates = { "lib" .. library .. ".dll.a", library .. ".lib", "lib" .. library .. ".a" }
        elseif request.darwin then candidates = { "lib" .. library .. ".dylib", "lib" .. library .. ".a" }
        else candidates = { "lib" .. library .. ".so", "lib" .. library .. ".a" } end
        local selected
        for _, directory in ipairs(directories) do
            for _, candidate in ipairs(candidates) do
                local filename = paths.join(directory, candidate)
                local stat, err = context.io:stat(filename)
                if err then error(err, 0) end
                if stat and stat.kind == "file" and context.io:readable(filename) then selected = filename; break end
            end
            if selected then break end
        end
        if not selected then
            for _, candidate in ipairs(candidates) do
                local command = { table.unpack(request.compiler_argv) }
                command[#command + 1] = "-print-file-name=" .. candidate
                local result = context.io:run(command)
                if result.started and result.ok then
                    local filename = (result.output or ""):match("^%s*(.-)%s*$")
                    if filename ~= "" and filename ~= candidate and not filename:find("[\r\n]") then
                        local stat, err = context.io:stat(filename)
                        if err then error(err, 0) end
                        if stat and stat.kind == "file" then selected = filename; break end
                    end
                end
            end
        end
        if not selected then return nil, "cannot resolve native library: " .. library end
        files[#files + 1] = selected
    end
    return files
end

-- The supported-linker policy records successful read inputs. It deliberately
-- does not rewalk earlier -L candidates on hits. Linkers without dependency
-- output use the compiler's resolved library paths instead.
function certificate.native_library_policy(context, request)
    request = request or {}
    local backend, filename = request.backend, request.dependency_file
    if request.uncacheable then
        return { cacheable = false, backend = backend or "none", argv = {}, reason = request.uncacheable }
    end
    for _, flag in ipairs(request.argv or {}) do
        if flag:sub(1, 1) == "@" or flag:find(",@", 1, true) or
            flag:match("^%-fplugin") or flag:match("^%-%-?plugin") or
            flag:find(",-plugin", 1, true) or flag == "-Xlinker" then
            return { cacheable = false, backend = backend or "none", argv = {},
                reason = "opaque linker input mechanism: " .. flag }
        end
    end
    if backend == "gnu" or backend == "lld" then
        need(type(filename) == "string", "link dependency output path is required")
        return { cacheable = true, backend = backend, dependency_file = filename,
            argv = { "-Wl,--dependency-file=" .. filename } }
    elseif backend == "darwin" then
        need(type(filename) == "string", "link dependency output path is required")
        return { cacheable = true, backend = backend, dependency_file = filename,
            argv = { "-Wl,-dependency_info," .. filename } }
    end
    local files, err = compiler_libraries(context, request)
    if files then return { cacheable = true, backend = "compiler", files = files, argv = {} } end
    return { cacheable = false, backend = backend or "none", argv = {}, reason = err }
end

-- GNU ld's write_dependency_file does not Make-escape filenames. It emits
-- one literal input per continuation line, then repeats the complete input
-- list as one literal phony target per line. Decode that second stanza, whose
-- final colon is the only delimiter; spaces, #, $, colons and backslashes
-- inside a path are data. LLD and native -MD output use the Make decoder.
local function gnu_link_dependencies(bytes)
    need(not bytes:find("\0", 1, true), "NUL in GNU linker dependency output")
    bytes = bytes:gsub("\r\n", "\n")
    local separator = need(bytes:find("\n\n", 1, true),
        "GNU linker dependency output has no phony input stanza")
    local result, seen = {}, {}
    for line in (bytes:sub(separator + 2) .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then
            need(line:sub(-1) == ":", "invalid GNU linker dependency input")
            local filename = line:sub(1, -2)
            need(filename ~= "", "empty GNU linker dependency input")
            if not seen[filename] then
                seen[filename] = true
                result[#result + 1] = filename
            end
        end
    end
    return result
end

local function native_dependencies(context, policy)
    if not policy.cacheable then return nil, policy.reason end
    if not policy.dependency_file then return certificate.files(context, policy.files) end
    local bytes = need(context.io:read_file(policy.dependency_file))
    local files
    if policy.backend == "darwin" then
        files = {}
        local offset = 1
        while offset <= #bytes do
            local opcode = bytes:byte(offset)
            local finish = bytes:find("\0", offset + 1, true)
            need(finish, "truncated Darwin linker dependency output")
            local value = bytes:sub(offset + 1, finish - 1)
            -- ld64: version=0x00, input-found=0x10, input-not-found=0x11,
            -- output=0x40. Only input-found records are successful reads.
            if opcode == 0x10 then files[#files + 1] = value
            else need(opcode == 0x00 or opcode == 0x11 or opcode == 0x40,
                "unknown Darwin linker dependency opcode") end
            offset = finish + 1
        end
    elseif policy.backend == "gnu" then
        files = gnu_link_dependencies(bytes)
    else
        files = need(depfile.parse(bytes))
    end
    local filtered, seen = {}, {}
    for _, filename in ipairs(files) do
        filename = absolute(context, filename)
        if not policy.exclude[filename] and not seen[filename] then
            seen[filename] = true
            filtered[#filtered + 1] = filename
        end
    end
    return certificate.files(context, filtered)
end

function certificate.prepare(context, spec)
    need(type(spec) == "table" and type(spec.output_root) == "string", "link output root is required")
    need(type(spec.outputs) == "table" and #spec.outputs > 0, "link output set is required")
    local outputs, keys, seen = {}, {}, {}
    for _, output in ipairs(spec.outputs) do
        if type(output) == "string" then output = { path = output } end
        local filename = absolute(context, need(output.path))
        local key = canonical(context, filename)
        need(not seen[key], "duplicate final output: " .. filename)
        seen[key] = true
        outputs[#outputs + 1] = { path = filename, executable = output.executable or false,
            kind = output.kind or "file" }
        keys[#keys + 1] = key
    end
    table.sort(keys, util.bytewise_less)
    local key = incremental.digest(context, "final-output-set", keys)
    local directory = paths.join(absolute(context, spec.output_root), ".titan-links", key)
    local input = { outputs = outputs }
    for _, field in ipairs(RECIPE_FIELDS) do input[field] = spec[field] end
    for _, field in ipairs(FILE_FIELDS) do input[field] = certificate.files(context, spec[field]) end
    need(data_only(input), "link recipe must contain only acyclic data")
    local native_request = {}
    for name, value in pairs(spec.native_libraries or {}) do native_request[name] = value end
    native_request.argv = native_request.argv or spec.argv
    native_request.dependency_file = native_request.dependency_file or paths.join(directory, "link.d")
    for _, file in ipairs(spec.c_objects or {}) do
        if type(file) == "table" and file.cacheable == false then
            native_request.uncacheable = "opaque native C input mechanism"
        end
    end
    local policy = certificate.native_library_policy(context, native_request)
    policy.exclude = {}
    for _, output in ipairs(outputs) do policy.exclude[output.path] = true end
    -- Staged object/synthetic paths reported by the linker are reconstructed
    -- from the recipe. Track real libraries, scripts and all other read files.
    for _, filename in ipairs(spec.dependency_excludes or {}) do policy.exclude[absolute(context, filename)] = true end
    input.native_policy = { backend = policy.backend, cacheable = policy.cacheable,
        files = policy.files and certificate.files(context, policy.files) or nil }
    return { key = key, directory = directory, synthetic_directory = paths.join(directory, "synthetic"),
        record = paths.join(directory, "record"), input = incremental.digest(context, "final-link", input),
        recipe = input, outputs = outputs, native_policy = policy, cacheable = policy.cacheable,
        dependency_argv = policy.argv }
end

function certificate.check(context, ticket)
    if not ticket.cacheable then return false, ticket.native_policy.reason end
    local record, err = certificate.read_record(context, ticket.record)
    if not record then return false, err end
    local validated, valid = pcall(record_valid, record)
    if not validated and type(valid) ~= "string" then error(valid, 0) end
    if not validated or not valid then return false, "link record schema" end
    if record.input ~= ticket.input then return false, "link inputs changed" end
    if #record.outputs ~= #ticket.outputs then return false, "link output set changed" end
    local called, current = pcall(function()
        return { outputs = (function()
            local result = {}
            for _, output in ipairs(ticket.outputs) do result[#result + 1] = output_snapshot(context, output) end
            return result
        end)(), native = certificate.files(context, record.native) }
    end)
    if not called then
        if type(current) ~= "string" then error(current, 0) end
        return false, current
    end
    if incremental.digest(context, "link-outputs", current.outputs) ~=
        incremental.digest(context, "link-outputs", record.outputs) then return false, "link outputs changed" end
    if incremental.digest(context, "native-link-inputs", current.native) ~=
        incremental.digest(context, "native-link-inputs", record.native) then return false, "native libraries changed" end
    return true
end

function certificate.invalidate(context, ticket)
    local stat, err = context.io:lstat(ticket.record)
    if not stat then return err == nil, err end
    need(stat.kind == "file", "link record is not a regular file")
    return context.io:unlink(ticket.record)
end

function certificate.commit(context, ticket)
    -- Call only after the complete validated output set has been published.
    -- Recheck input bytes afresh; a memo from before linking cannot bless a race.
    local current = fresh(context)
    for _, field in ipairs(FILE_FIELDS) do
        local files = certificate.files(current, ticket.recipe[field])
        need(incremental.digest(context, field, files) == incremental.digest(context, field, ticket.recipe[field]),
            "link input changed during build: " .. field)
    end
    if not ticket.cacheable then return true end
    local outputs = {}
    for _, output in ipairs(ticket.outputs) do outputs[#outputs + 1] = output_snapshot(current, output) end
    local native, err = native_dependencies(current, ticket.native_policy)
    if not native then return nil, err end
    if ticket.native_policy.files then
        need(incremental.digest(context, "native-fallback", native) ==
            incremental.digest(context, "native-fallback", ticket.recipe.native_policy.files),
            "native library changed during build")
    end
    mkdir(context, ticket.directory)
    return certificate.write_record(context, ticket.record, {
        schema = version.TITAN_LINK_RECORD_SCHEMA, digest = version.CERTIFICATE_DIGEST,
        canonicalization = version.CERTIFICATE_CANONICALIZATION,
        input = ticket.input, outputs = outputs, native = native,
    })
end

return certificate
