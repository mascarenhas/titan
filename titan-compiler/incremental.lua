-- Source-object certification has no resolver side effects. Local evidence is
-- checked before restoring declarations; dependency evidence uses the final plan.
local sha256 = require "titan-compiler.sha256"
local version = require "titan-compiler.version"
local paths = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local util = require "titan-compiler.util"
local types = require "titan-compiler.types"
local objectmetadata = require "titan-compiler.objectmetadata"
local staticmetadata = require "titan-compiler.staticmetadata"
local graphcodec = require "titan-compiler.graphcodec"
local relocation = require "titan-compiler.relocation"
local incremental = {}

local function state(context)
    if not context.incremental then
        context.incremental = { files = {}, aliases = {}, providers = {},
            counters = { file_hashes = 0, file_reads = 0, file_bytes = 0,
                observation_reuses = 0, sdk_reuses = 0, digest_calls = 0, files = {} } }
    end
    return context.incremental
end

function incremental.counters(context)
    return state(context).counters
end

local function hash(context, bytes)
    local counters = state(context).counters
    counters.digest_calls = counters.digest_calls + 1
    return sha256.hex_via(context.cache_adapter and
        context.cache_adapter.sha256_binary, bytes)
end

-- Maps are bytewise sorted; arrays keep their numeric order. Type tags and
-- lengths distinguish absent/false/empty, scalar types and nested boundaries.
local function canonical(value, active)
    local kind = type(value)
    if kind == "nil" then return "n" end
    if kind == "boolean" then return value and "b1" or "b0" end
    if kind == "string" then return "s" .. #value .. ":" .. value end
    if kind == "number" then
        assert(value == value and value ~= math.huge and value ~= -math.huge,
            "certificate numbers must be finite")
        local text = math.type(value) == "integer" and tostring(value)
            or string.format("%a", value)
        return "d" .. #text .. ":" .. text
    end
    assert(kind == "table", "unsupported certificate value " .. kind)
    assert(not active[value], "cyclic certificate value")
    active[value] = true
    local keys = {}
    for key in pairs(value) do
        local kt = type(key)
        assert(kt == "string" or kt == "number" or kt == "boolean",
            "certificate maps require scalar keys")
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        local left, right = type(a), type(b)
        if left ~= right then return left < right end
        if left == "string" then return util.bytewise_less(a, b) end
        if left == "boolean" then return not a and b end
        return a < b
    end)
    local out = { "t", tostring(#keys), ":" }
    for _, key in ipairs(keys) do
        out[#out + 1] = canonical(key, active)
        out[#out + 1] = canonical(value[key], active)
    end
    active[value] = nil
    return table.concat(out)
end

function incremental.digest(context, tag, value)
    return hash(context, canonical({ version.CERTIFICATE_CANONICALIZATION,
        tag, value }, {}))
end

local function required(value, err, path)
    if not value then
        if err ~= nil and type(err) ~= "string" then error(err, 0) end
        error((path and (path .. ": ") or "") .. (err or "input is missing"), 0)
    end
    return value
end

local function absolute(context, path)
    return required(platform.absolute(path, required(context.io:cwd())))
end

local OBSERVATION_FIELDS = { "kind", "dev", "ino", "size", "mode", "mtime_ns", "ctime_ns" }

local function precise_observation(stat)
    if type(stat) ~= "table" or getmetatable(stat) ~= nil or stat.precision ~= "ns"
        or type(stat.kind) ~= "string" or type(stat.dev) ~= "string" or stat.dev == ""
        or type(stat.ino) ~= "string" or stat.ino == "" then return nil end
    for _, field in ipairs({ "size", "mode", "mtime_ns", "ctime_ns" }) do
        if math.type(stat[field]) ~= "integer" then return nil end
    end
    if stat.size < 0 then return nil end
    local result = { precision = "ns" }
    for _, field in ipairs(OBSERVATION_FIELDS) do result[field] = stat[field] end
    return result
end

-- The closed precise observation of an already-taken stat, or nil when it is
-- coarse or lacks a physical identity.
incremental.precise_observation = precise_observation

function incremental.observation(context, path, follow)
    local ok, stat, err = pcall(follow == false and context.io.lstat or context.io.stat,
        context.io, path)
    if not ok then
        if type(stat) ~= "string" then error(stat, 0) end
        return nil, stat
    end
    if err ~= nil and type(err) ~= "string" then error(err, 0) end
    if err ~= nil then return nil, err end
    return precise_observation(stat), err
end

function incremental.observations_equal(left, right)
    left, right = precise_observation(left), precise_observation(right)
    if not left or not right then return false end
    for _, field in ipairs(OBSERVATION_FIELDS) do
        if left[field] ~= right[field] then return false end
    end
    return true
end

local function read_observation(context, path)
    local stat, err = context.io:stat(path)
    stat = required(stat, err, path)
    assert(stat.kind == "file", path .. ": input is not a regular file")
    local link, linkerr = context.io:lstat(path)
    link = required(link, linkerr, path)
    local function fields(value)
        return { kind = value.kind, mode = value.mode, size = value.size,
            device = value.device, inode = value.inode,
            modified_seconds = value.modified_seconds,
            modified_nanoseconds = value.modified_nanoseconds,
            changed_seconds = value.changed_seconds,
            changed_nanoseconds = value.changed_nanoseconds,
            time_precision = value.time_precision, precision = value.precision,
            dev = value.dev, ino = value.ino, mtime_ns = value.mtime_ns, ctime_ns = value.ctime_ns }
    end
    return canonical({ fields(stat), fields(link) }, {}),
        err == nil and linkerr == nil and precise_observation(stat) or nil, stat.size
end

local function file_count(memo, key)
    local count = memo.counters.files[key]
    if not count then
        count = { hashes = 0, reads = 0, bytes = 0, observation_reuses = 0, sdk_reuses = 0 }
        memo.counters.files[key] = count
    end
    return count
end

local function cache_file(context, path, digest, observation)
    local cache = state(context).persistent
    if not cache or not observation then return end
    path = absolute(context, path)
    local previous = cache.files[path]
    if not previous or previous.digest ~= digest
        or not incremental.observations_equal(previous.observation, observation) then
        cache.files[path] = { digest = digest, observation = observation }
        cache.dirty = true
    end
end

-- A file larger than STREAM_THRESHOLD_BYTES whose digest alone is demanded is
-- hashed through the native `sha256_stream` when the adapter supplies it and
-- the strategy supplies `absorb_file`; its bytes are never materialized or
-- retained. Anything else is read whole.
local STREAM_THRESHOLD_BYTES = 4 * 1024 * 1024
incremental.STREAM_THRESHOLD_BYTES = STREAM_THRESHOLD_BYTES

local function read_evidence(context, path, key, count, max_bytes, stream)
    local before, observed, size = read_observation(context, path)
    local new_stream = stream and context.cache_adapter and context.cache_adapter.sha256_stream
    local bytes, digest
    if new_stream and context.io.absorb_file and math.type(size) == "integer"
       and size > STREAM_THRESHOLD_BYTES then
        local sha = new_stream()
        size = required(context.io:absorb_file(path, sha))
        digest = sha:finish()
        assert(type(digest) == "string" and #digest == 32,
            "sha256_stream must finish with a 32-byte digest")
        digest = sha256.to_hex(digest)
    else
        bytes = required(context.io:read_file(path, max_bytes))
        size = #bytes
    end
    state(context).counters.file_reads = state(context).counters.file_reads + 1
    count.reads = count.reads + 1
    if max_bytes and size > max_bytes then error(path .. ": file exceeds read limit", 0) end
    local after = read_observation(context, path)
    if before ~= after or (observed and size ~= observed.size)
        or key ~= required(context.io:realpath(path)) then
        error(path .. ": file changed while it was read", 0)
    end
    return bytes, observed, digest, size
end

-- Record a file's content digest: hashed here from whole `bytes`, or already
-- streamed (`digest` and `size`, without bytes).
local function hash_file(context, path, key, bytes, observed, count, digest, size)
    local memo = state(context)
    if digest then
        memo.counters.digest_calls = memo.counters.digest_calls + 1
    else
        digest, size = hash(context, bytes), #bytes
    end
    memo.counters.file_hashes = memo.counters.file_hashes + 1
    memo.counters.file_bytes = memo.counters.file_bytes + size
    count.hashes, count.bytes = count.hashes + 1, count.bytes + size
    -- Length is content evidence even when no precise observation is reusable.
    memo.files[key] = { digest = digest, bytes = bytes, observation = observed, size = size }
    cache_file(context, path, digest, observed)
    context.io:yield()
    return digest, bytes, observed, size
end

local function digest_file(context, path, bytes, max_bytes, want_bytes)
    local memo = state(context)
    local key = memo.aliases[path]
    if not key then
        key = required(context.io:realpath(path))
        memo.aliases[path] = key
    end
    local count = file_count(memo, key)
    local saved = memo.files[key]
    if saved then
        if bytes ~= nil then
            if saved.bytes == nil then
                local digest = hash(context, bytes)
                if digest ~= saved.digest then error(path .. ": file changed during build", 0) end
                memo.counters.file_hashes = memo.counters.file_hashes + 1
                memo.counters.file_bytes = memo.counters.file_bytes + #bytes
                count.hashes, count.bytes = count.hashes + 1, count.bytes + #bytes
                saved.bytes = bytes
            elseif bytes ~= saved.bytes then
                error(path .. ": file changed during build", 0)
            end
        end
        return saved.digest, saved.bytes, saved.observation, saved.size
    end
    -- Content digests are file identity. Any recorded digest is reused while
    -- the file's precise observation, change time included, still equals the
    -- recorded one: the parent memo of a re-observing context, the installed
    -- SDK's manifest, or the output tree's persistent cache. A changed or
    -- coarse observation reads and rehashes the bytes.
    if bytes == nil then
        local parent = memo.parent and memo.parent.files[key]
        local sdk = memo.sdk and memo.sdk.files[key]
        local persisted = memo.persistent and memo.persistent.files[absolute(context, path)]
        if parent or sdk or persisted then
            local current = incremental.observation(context, path)
            local recorded, counter
            if current and current.kind == "file" then
                if parent and incremental.observations_equal(current, parent.observation) then
                    recorded, counter = parent, "observation_reuses"
                elseif sdk and incremental.observations_equal(current, sdk.observation) then
                    recorded, counter = sdk, "sdk_reuses"
                elseif persisted and incremental.observations_equal(current, persisted.observation) then
                    recorded, counter = persisted, "observation_reuses"
                end
            end
            if recorded and context.io:readable(path) then
                memo.files[key] = { digest = recorded.digest, observation = current, size = current.size }
                memo.counters[counter] = memo.counters[counter] + 1
                count[counter] = count[counter] + 1
                return recorded.digest, nil, current, current.size
            end
        end
    end
    local observed, digest, size
    if bytes == nil then
        bytes, observed, digest, size =
            read_evidence(context, path, key, count, max_bytes, not want_bytes)
    end
    assert(digest ~= nil or type(bytes) == "string", "file digest requires byte contents")
    return hash_file(context, path, key, bytes, observed, count, digest, size)
end

function incremental.file_digest(context, path, bytes)
    local digest, contents, observed = digest_file(context, path, bytes)
    return digest, contents, observed
end

-- A digest cache hit deliberately has no bytes. Byte-demand consumers use this
-- operation to materialize them once under the same read-race guard.
function incremental.file_contents(context, path, max_bytes)
    if max_bytes ~= nil then
        assert(math.type(max_bytes) == "integer" and max_bytes >= 0, "invalid file read limit")
        local stat, err = context.io:stat(path)
        stat = required(stat, err, path)
        if stat.size > max_bytes then error(path .. ": file exceeds read limit", 0) end
    end
    local digest, bytes, observed = digest_file(context, path, nil, max_bytes, true)
    if bytes == nil then
        local memo = state(context)
        local key = memo.aliases[path]
        local current
        bytes, current = read_evidence(context, path, key, file_count(memo, key), max_bytes)
        -- A streamed digest may lack a precise observation; its content then
        -- has to match instead.
        if not incremental.observations_equal(observed, current) and
           (observed ~= nil or hash(context, bytes) ~= digest) then
            error(path .. ": file changed during build", 0)
        end
        memo.files[key].bytes = bytes
    end
    if max_bytes and #bytes > max_bytes then error(path .. ": file exceeds read limit", 0) end
    return bytes
end

-- Post-build verification re-observes its inputs instead of trusting this
-- invocation's memo: the fresh context starts with an empty memo and reuses a
-- digest from the parent memo, SDK manifest or persistent cache only under an
-- equal precise observation. Changed files are reread and rehashed, and that
-- verified evidence primes the persistent cache for the next invocation.
function incremental.fresh_context(context)
    local fresh = { io = context.io, cache_adapter = context.cache_adapter }
    fresh.relocation_roots, fresh.incremental_options =
        context.relocation_roots, context.incremental_options
    local memo = state(context)
    state(fresh).parent = memo
    state(fresh).persistent = memo.persistent
    state(fresh).sdk = memo.sdk
    return fresh
end

-- Only a publisher may retire evidence for an output it has replaced. Fresh
-- input revalidation uses a separate context instead of invalidating inputs.
function incremental.invalidate_file(context, path)
    local memo = state(context)
    local key = memo.aliases[path]
    if key then
        memo.files[key] = nil
        for alias, target in pairs(memo.aliases) do
            if target == key then memo.aliases[alias] = nil end
        end
    end
    local cache = memo.persistent
    if cache then
        local spelling = absolute(context, path)
        if cache.files[spelling] then
            cache.files[spelling], cache.dirty = nil, true
        end
    end
end

local function options(context, value)
    return value or assert(context.incremental_options,
        "incremental context has no incremental_options")
end

local function compiler_inventory(context, value)
    local opts = options(context, value)
    local root = assert(opts.compiler_root, "loaded compiler root is required")
    local inventory = {}
    for _, directory in ipairs({ "titan-compiler", "titan-compiler/checker",
            "titan-compiler/coder", "c-parser" }) do
        local names, err = context.io:list(paths.join(root, directory))
        names = required(names, err, paths.join(root, directory))
        table.sort(names, util.bytewise_less)
        for _, name in ipairs(names) do
            if name:match("%.lua$") then
                local relative = directory .. "/" .. name
                local digest, _, _, size = digest_file(context, paths.join(root, relative))
                inventory[#inventory + 1] = { path = relative,
                    length = size, sha256 = digest }
            end
        end
    end
    local frontend = opts.frontend or "api"
    if frontend == "api" then
        inventory[#inventory + 1] = { path = "titanc", api = true }
    else
        local digest, _, _, size = digest_file(context, frontend)
        inventory[#inventory + 1] = { path = "titanc",
            length = size, sha256 = digest }
    end
    table.sort(inventory, function(a, b) return util.bytewise_less(a.path, b.path) end)
    return incremental.digest(context, "compiler", inventory), inventory
end

function incremental.compiler_component(context, value)
    local ok, digest = pcall(compiler_inventory, context, value)
    if not ok then
        if type(digest) ~= "string" then error(digest, 0) end
        return nil, digest
    end
    return digest
end

local function run(context, argv)
    local result = context.io:run(argv)
    if not result.ok then
        required(nil, result.diagnostic or result.output or "native probe failed")
    end
    return result.output or ""
end

local function append(target, values)
    for _, value in ipairs(values or {}) do target[#target + 1] = value end
    return target
end

-- Temporary translation units use the actual generated filename for macro
-- expansion. Expanded C strings remain semantic input, unlike #line markers.
function incremental.preprocessed_identity(context, filename, contents)
    local opts = options(context)
    local temporary = required(context.io:tmpname())
    local ok, result = pcall(function()
        required(context.io:write_file(temporary, contents))
        local argv = append({ table.unpack(opts.compile_prefix) }, {
            "-iquote", paths.dirname(absolute(context, filename)),
            "-fmacro-prefix-map=" .. temporary .. "=" .. filename,
            "-E", "-P", "-x", "c", temporary })
        local expanded = run(context, argv)
        local counters = state(context).counters
        counters.relocation_preprocesses = (counters.relocation_preprocesses or 0) + 1
        return incremental.digest(context, "generated-c-semantics", expanded)
    end)
    local removed, err = context.io:unlink(temporary)
    incremental.invalidate_file(context, temporary)
    if not ok then error(result, 0) end
    required(removed, err, temporary)
    return result
end

local function physical_tool_identity(context, filename, stat)
    return { path = required(context.io:realpath(filename)), size = stat.size,
        device = stat.device, inode = stat.inode, mode = stat.mode,
        modified_seconds = stat.modified_seconds, modified_nanoseconds = stat.modified_nanoseconds,
        changed_seconds = stat.changed_seconds, changed_nanoseconds = stat.changed_nanoseconds,
        precision = stat.precision, dev = stat.dev, ino = stat.ino,
        mtime_ns = stat.mtime_ns, ctime_ns = stat.ctime_ns,
        time_precision = stat.time_precision or "coarse" }
end

function incremental.physical_tool_file(context, path)
    local filename = absolute(context, path)
    local stat, err = context.io:stat(filename)
    stat = required(stat, err, filename)
    assert(stat.kind == "file" and context.io:readable(filename),
        "cannot resolve loadable native tool: " .. path)
    return physical_tool_identity(context, filename, stat)
end

local function uncertified_tool(reason)
    return nil, reason, "uncertified"
end

local function windows_physical_executable(context, executable, selection)
    local explicit = executable:find("[/\\:]") ~= nil
    if selection ~= nil and selection ~= "llvm" then
        return uncertified_tool("unknown Windows native tool selection policy")
    elseif selection == "llvm" and not explicit then
        return uncertified_tool("bare Windows compiler stage has no proven selection policy")
    end
    local cwd
    local function candidate(filename)
        if not platform.is_absolute(filename) then
            cwd = cwd or required(context.io:cwd())
        end
        local resolved, resolve_error = platform.absolute(filename, cwd)
        if not resolved then
            return uncertified_tool("cannot prove Windows tool path: " ..
                tostring(resolve_error))
        end
        local entry, entry_error = context.io:lstat(resolved)
        if entry_error ~= nil then required(nil, entry_error, resolved) end
        if not entry or entry.kind ~= "symlink" then return resolved, entry end
        local stat, err = context.io:stat(resolved)
        if err ~= nil then required(nil, err, resolved) end
        if not stat then
            return uncertified_tool("cannot prove existing Windows tool entry: " .. resolved)
        end
        local attributes = entry.windows_attributes
        if math.type(attributes) ~= "integer" or attributes < 0 or attributes >= 0xffffffff then
            return uncertified_tool("cannot prove Windows tool link attributes: " .. resolved)
        end
        if ((attributes & 0x10) ~= 0) ~= (stat.kind == "directory") then
            return uncertified_tool("Windows tool link entry and target kinds differ: " .. resolved)
        end
        return resolved, stat
    end
    if selection == "llvm" then
        -- LLVM Execute uses the exact path when it exists, otherwise +".exe".
        -- An existing directory must not be bypassed: LLVM would launch it.
        for index = 1, 2 do
            local filename, stat, status = candidate(
                index == 1 and executable or executable .. ".exe")
            if status then return nil, stat, status end
            if stat then
                if stat.kind ~= "file" then
                    error("cannot resolve native tool executable: nonregular LLVM stage " ..
                        filename, 0)
                end
                return physical_tool_identity(context, filename, stat), filename
            end
        end
        error("cannot resolve native tool executable: " .. executable, 0)
    end

    -- Match bundled libuv's Windows spawn search, not LLVM's stage launcher.
    -- With no exact-name flag, only a nonempty extension enables exact lookup;
    -- .com and .exe are then appended even to an already-suffixed request.
    local basename = executable:match("([^/\\:]*)$")
    local dot = basename:find(".", 1, true)
    local has_extension = dot ~= nil and dot < #basename
    local suffix_dot = basename:sub(-1) == "." and "" or "."
    local function probe(filename)
        local resolved, stat, status = candidate(filename)
        if status then return nil, stat, status end
        if not stat or stat.kind == "directory" then return nil end
        if stat.kind ~= "file" then
            return uncertified_tool("cannot prove Windows executable file kind: " .. resolved)
        end
        return resolved, stat
    end
    local function in_directory(directory)
        local filename = executable
        if directory ~= nil and directory ~= "" then
            local last = directory:sub(-1)
            filename = directory ..
                ((last == "/" or last == "\\" or last == ":") and "" or "/") ..
                executable
        end
        if has_extension then
            local found, stat, status = probe(filename)
            if found or status then return found, stat, status end
        end
        local found, stat, status = probe(filename .. suffix_dot .. "com")
        if found or status then return found, stat, status end
        return probe(filename .. suffix_dot .. "exe")
    end
    local function in_path()
        local search = context.executable_path or platform.getenv("PATH") or ""
        local start = 1
        while start <= #search do
            local first = search:sub(start, start)
            local quoted = first == '"' or first == "'"
            local after_quote = quoted and
                (search:find(first, start + 1, true) or #search + 1) or start
            local finish = search:find(";", after_quote, true) or #search + 1
            local directory = search:sub(start, finish - 1)
            if directory ~= "" then
                if quoted then
                    if #directory == 1 then
                        return uncertified_tool("cannot prove malformed Windows executable PATH")
                    end
                    directory = directory:sub(2)
                end
                local last = directory:sub(-1)
                if last == '"' or last == "'" then directory = directory:sub(1, -2) end
                local found, stat, status = in_directory(directory)
                if found or status then return found, stat, status end
            end
            start = finish + 1
        end
    end
    local function identity(filename, stat)
        return physical_tool_identity(context, filename, stat), filename
    end
    if executable == "." then
        error("cannot resolve native tool executable: " .. executable, 0)
    elseif explicit then
        local found, stat, status = in_directory(nil)
        if status then return nil, stat, status end
        if found then return identity(found, stat) end
    else
        local search_cwd
        if type(context.io.executable_search_cwd) == "function" then
            local allowed, err = context.io:executable_search_cwd()
            if err ~= nil and type(err) ~= "string" then error(err, 0) end
            if err == nil and (allowed == true or allowed == false) then
                search_cwd = allowed
            end
        end
        local current, current_stat, current_status
        if search_cwd ~= false then
            cwd = cwd or required(context.io:cwd())
            current, current_stat, current_status = in_directory(cwd)
            if current_status then return nil, current_stat, current_status end
            if current and search_cwd == true then return identity(current, current_stat) end
        end
        local found, stat, status = in_path()
        if status then return nil, stat, status end
        if current and current ~= found then
            return uncertified_tool("cannot determine Windows current-directory tool selection")
        end
        if found then return identity(found, stat) end
    end
    error("cannot resolve native tool executable: " .. executable, 0)
end

-- Return canonical physical identity plus the admitted absolute command
-- spelling, retaining symlink/multicall names when execution changes cwd.
-- Windows defaults to bundled-libuv spawn lookup; "llvm" selects an explicit
-- compiler-reported stage. Policy uncertainty returns nil, reason, "uncertified";
-- callers must still execute valid raw commands without reusable records.
function incremental.physical_executable(context, command, selection)
    local executable = type(command) == "table" and command[1] or command
    assert(type(executable) == "string" and executable ~= "", "tool executable is required")
    if platform.windows then
        return windows_physical_executable(context, executable, selection)
    end
    local candidates = {}
    if executable:find("/", 1, true) then
        candidates[1] = absolute(context, executable)
    else
        local search = context.executable_path or platform.getenv("PATH")
        if search == nil then
            -- An unset PATH uses the launcher's default, not an empty CWD entry.
            return uncertified_tool("cannot determine POSIX default executable search path")
        end
        for directory in (search .. ":"):gmatch("(.-):") do
            -- Preserve POSIX symlink/.. spelling through admission and execution.
            candidates[#candidates + 1] = platform.join(
                directory ~= "" and directory or ".", executable)
        end
    end
    for _, candidate in ipairs(candidates) do
        local stat, err = context.io:stat(candidate)
        if err then required(nil, err, candidate) end
        if stat and stat.kind == "file" then
            assert(type(context.io.executable) == "function",
                "cannot determine native tool execution eligibility: " ..
                "compiler I/O strategy lacks executable")
            local allowed, access_error = context.io:executable(candidate)
            if access_error ~= nil then required(nil, access_error, candidate) end
            if allowed ~= true and allowed ~= false then
                required(nil, "cannot determine native tool execution eligibility", candidate)
            end
            if allowed then
                return physical_tool_identity(context, candidate, stat),
                    platform.is_absolute(candidate) and candidate or absolute(context, candidate)
            end
        end
    end
    error("cannot resolve native tool executable: " .. executable, 0)
end

local function stable_toolchain_banner(output)
    local cpp = require "c-parser.cpp"
    local lines = {}
    for raw_line in (output .. "\n"):gmatch("(.-)\r?\n") do
        local line = raw_line
        -- Clang prints its generated cc1 action as well as its stable banner.
        -- These two directory operands describe the caller, not the compiler.
        -- Preserve every other action argument and all version/search metadata.
        local argv = line:find("-cc1", 1, true) and cpp.split_shell_words(line)
        if argv and argv[2] == "-cc1" and argv[3] and argv[3]:sub(1, 1) == "-" then
            local quoted, index = {}, 1
            while index <= #argv do
                local argument = argv[index]
                local option = argument:match("^(%-f[%w%-]+)=") or argument
                if option == "-fdebug-compilation-dir" or option == "-fcoverage-compilation-dir" then
                    if argument == option and argv[index + 1] then index = index + 1 end
                    argument = option .. "=<compilation-directory>"
                end
                quoted[#quoted + 1] = assert(cpp.shell_quote(argument))
                index = index + 1
            end
            line = " " .. table.concat(quoted, " ")
        end
        lines[#lines + 1] = line
    end
    return table.concat(lines, "\n")
end

-- Tool identity policy: self-description plus physical driver/named-stage
-- identity. Keep this policy in one boundary, shared with native/link inputs.
function incremental.toolchain_identity(context, descriptor)
    local cc = assert(descriptor.compiler_argv, "toolchain compiler_argv is required")
    local memo = state(context)
    memo.toolchains = memo.toolchains or {}
    local key = canonical({ compiler_argv = cc, compile_flags = descriptor.compile_flags,
        language_mode = descriptor.language_mode, language_flag = descriptor.language_flag,
        cppflags = descriptor.cppflags, cflags = descriptor.cflags, include_dirs = descriptor.include_dirs,
        target = descriptor.target_identity or descriptor.profile_identity,
        preprocessor_identity = descriptor.preprocessor_identity, banner = descriptor.banner,
        stage_tools = descriptor.stage_tools, executable_path = context.executable_path }, {})
    local saved = memo.toolchains[key]
    if saved then return saved.digest, saved.details end
    local wrapper = paths.basename(cc[1]):lower():gsub("%.exe$", "")
    local wrapped = wrapper == "ccache" or wrapper == "sccache" or wrapper == "distcc"
    local description_argv = { table.unpack(cc) }
    -- The tokenized CC command is opaque: later words may name an interpreter
    -- script, wrapper arguments or compiler options. Preserve it verbatim, and
    -- omit only the separately supplied effective compilation flags.
    memo.toolchain_descriptions = memo.toolchain_descriptions or {}
    local description_key = canonical({ argv = description_argv,
        preprocessor = descriptor.preprocessor_identity, banner = descriptor.banner }, {})
    local description = memo.toolchain_descriptions[description_key]
    if not description then
        local null = platform.windows and "NUL" or "/dev/null"
        description = {
            preprocessor = descriptor.preprocessor_identity or required(
                require("c-parser.cpp").cached_command(append({ table.unpack(description_argv) },
                    { "-dM", "-E", "-x", "c", null }), false, context.io)),
            banner = stable_toolchain_banner(descriptor.banner or required(
                require("c-parser.cpp").cached_command(append({ table.unpack(description_argv) },
                    { "-E", "-v", "-x", "c", null, "-o", null }), true, context.io))),
        }
        memo.toolchain_descriptions[description_key] = description
    end
    local preprocessor, banner = description.preprocessor, description.banner
    -- Inventory and launch policy share a compiler version-line classification;
    -- an incidental "clang" installation path must not omit GCC's stages.
    local clang = banner:match("^[%w ()+._-]*clang version %d") or
        banner:match("\n[%w ()+._-]*clang version %d")
    local stage_policy = clang and "llvm" or nil
    local primary, primary_error, primary_status =
        incremental.physical_executable(context, cc)
    if not primary then return nil, primary_error, primary_status end
    local tools = { primary }
    if wrapped then
        assert(cc[2] and cc[2]:sub(1, 1) ~= "-", "wrapped compiler must be explicit")
        local delegate, delegate_error, delegate_status =
            incremental.physical_executable(context, cc[2], "unknown")
        if not delegate then return nil, delegate_error, delegate_status end
        tools[#tools + 1] = delegate
    end
    local stages = descriptor.stage_tools
    if not stages then
        stages = {}
        local query = append(append(append({ table.unpack(cc) }, descriptor.compile_flags),
            descriptor.cppflags), descriptor.cflags)
        local external_assembler = false
        for _, flag in ipairs(query) do
            if flag == "-fno-integrated-as" then external_assembler = true
            elseif flag == "-fintegrated-as" then external_assembler = false end
        end
        local names = not clang and { "cc1", "as" } or (external_assembler and { "as" } or {})
        for _, name in ipairs(names) do
            local stage = run(context, append({ table.unpack(query) },
                { "-print-prog-name=" .. name })):match("^%s*(.-)%s*$")
            assert(stage ~= "", "native compiler did not name stage " .. name)
            stages[#stages + 1] = stage
        end
    end
    for _, stage in ipairs(stages) do
        local identity, identity_error, identity_status =
            incremental.physical_executable(context, stage, stage_policy or "unknown")
        if not identity then return nil, identity_error, identity_status end
        tools[#tools + 1] = identity
    end
    local details = { preprocessor = preprocessor, banner = banner, tools = tools,
        stage_policy = stage_policy }
    if descriptor.target_identity ~= nil then
        details.target_identity = descriptor.certification_target_identity or descriptor.target_identity
    end
    local digest = incremental.digest(context, "toolchain", details)
    memo.toolchains[key] = { digest = digest, details = details }
    return digest, details
end

local function mkdir(context, directory)
    local stat, err = context.io:stat(directory)
    if err then required(nil, err, directory) end
    if stat then
        assert(stat.kind == "directory", directory .. ": expected directory")
        return
    end
    local parent = paths.dirname(directory)
    if parent ~= directory and parent ~= "." then mkdir(context, parent) end
    required(context.io:mkdir(directory))
end

local DIGEST_CACHE_LIMIT = 32 * 1024 * 1024

local function cache_codec_options(context)
    return { max_bytes = DIGEST_CACHE_LIMIT, max_nodes = 300000, max_entries = 2000000,
        max_string_bytes = DIGEST_CACHE_LIMIT, yield = function() context.io:yield() end,
        sha256_binary = context.cache_adapter and context.cache_adapter.sha256_binary }
end

local function closed_cache_table(value, fields)
    if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
    for key in pairs(value) do if not fields[key] then return false end end
    return true
end

local function digest_string(value)
    return type(value) == "string" and #value == 64 and not value:find("[^0-9a-f]")
end

local function bytewise_less(a, b)
    for index = 1, math.min(#a, #b) do
        local left, right = a:byte(index), b:byte(index)
        if left ~= right then return left < right end
    end
    return #a < #b
end

local function valid_wasm_features(features)
    if type(features) ~= "string" then return false end
    if features == "" then return true end
    local seen, previous, position = {}, nil, 1
    while true do
        local space = features:find(" ", position, true)
        local token = features:sub(position, space and space - 1 or #features)
        local name = token:match("^[+%-=]([!-\126]+)$")
        if not name or seen[name] or (previous and not bytewise_less(previous, token)) then
            return false
        end
        seen[name], previous = true, token
        if not space then return true end
        position = space + 1
    end
end

local function valid_fingerprint(value)
    if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
    if value.format == "wasm" then
        return closed_cache_table(value, { format = true, word_size = true,
                linking_version = true, features = true })
            and math.type(value.word_size) == "integer" and value.word_size == 32
            and math.type(value.linking_version) == "integer" and value.linking_version == 2
            and valid_wasm_features(value.features)
    end
    if not closed_cache_table(value, { format = true, class = true, word_size = true,
        endian = true, machine = true, flags = true, cputype = true, cpusubtype = true }) then
        return false
    end
    if value.endian ~= "little" and value.endian ~= "big" then return false end
    local width = value.format == "elf" and value.class or value.word_size
    if width ~= 32 and width ~= 64 then return false end
    local fields = value.format == "elf" and { "machine", "flags" }
        or value.format == "macho" and { "cputype", "cpusubtype" }
        or value.format == "coff" and { "machine" }
    if not fields then return false end
    for _, key in ipairs(fields) do if math.type(value[key]) ~= "integer" then return false end end
    return true
end

local NATIVE_KINDS = { archive = true, object = true, shared = true, thin = true, unknown = true }

local function valid_file_entries(files)
    if type(files) ~= "table" or getmetatable(files) ~= nil then return false end
    for path, entry in pairs(files) do
        if type(path) ~= "string" or not platform.is_absolute(path) or path:find("\0", 1, true)
            or not closed_cache_table(entry, { digest = true, observation = true })
            or not digest_string(entry.digest) or not precise_observation(entry.observation)
            or entry.observation.kind ~= "file" then return false end
    end
    return true
end

local function valid_digest_cache(record)
    if not closed_cache_table(record, { schema = true, digest = true, canonicalization = true,
        abi = true, files = true, objects = true })
        or record.schema ~= version.DIGEST_CACHE_SCHEMA or record.digest ~= version.CERTIFICATE_DIGEST
        or record.canonicalization ~= version.CERTIFICATE_CANONICALIZATION
        or record.abi ~= version.TITAN_ABI_VERSION or not valid_file_entries(record.files)
        or type(record.objects) ~= "table" or getmetatable(record.objects) ~= nil then return false end
    for digest, fact in pairs(record.objects) do
        if not digest_string(digest) or not closed_cache_table(fact,
            { fingerprint = true, kind = true, lto = true }) then return false end
        if fact.fingerprint ~= nil and not valid_fingerprint(fact.fingerprint) then return false end
        if fact.kind ~= nil and not NATIVE_KINDS[fact.kind] then return false end
        if fact.lto ~= nil and (fact.kind == nil or type(fact.lto) ~= "boolean") then return false end
        if fact.fingerprint == nil and fact.kind == nil then return false end
    end
    return true
end

-- A missing, oversized, unreadable or undecodable record reads as nil;
-- cancellation and other non-string errors propagate unchanged.
local function read_cache_record(context, filename)
    local ok, record = pcall(function()
        local stat, staterr = context.io:lstat(filename)
        if staterr ~= nil and type(staterr) ~= "string" then error(staterr, 0) end
        if not stat or stat.kind ~= "file" or stat.size > DIGEST_CACHE_LIMIT then return end
        local bytes, err = context.io:read_file(filename, DIGEST_CACHE_LIMIT)
        if err ~= nil and type(err) ~= "string" then error(err, 0) end
        if not bytes or #bytes > DIGEST_CACHE_LIMIT then return end
        return graphcodec.decode(bytes, cache_codec_options(context))
    end)
    if not ok then
        if type(record) ~= "string" then error(record, 0) end
        return nil
    end
    return record
end

-- Only the coordinator calls these two functions, while holding its output
-- lock. Cache transport failure never makes a correct build depend on storage.
function incremental.load_digest_cache(context, output_root)
    local memo = state(context)
    if output_root == nil then return true end
    local filename = paths.join(absolute(context, output_root), ".titan", "digests")
    if memo.persistent then
        if memo.persistent.path == filename then return true end
        return nil, "digest cache already belongs to another output tree"
    end
    local cache = { path = filename, owner = context, files = {}, objects = {}, dirty = true }
    memo.persistent = cache
    local record = read_cache_record(context, filename)
    if valid_digest_cache(record) then
        cache.files, cache.objects, cache.dirty = record.files, record.objects, false
    end
    return true
end

function incremental.save_digest_cache(context)
    local cache = state(context).persistent
    if not cache or cache.owner ~= context or not cache.dirty then return true end
    local staging
    local ok, result = pcall(function()
        local directory = paths.dirname(cache.path)
        local stat, err = context.io:lstat(directory)
        if err then required(nil, err, directory) end
        if stat then
            assert(stat.kind == "directory", directory .. ": digest cache directory must not be a link")
        else
            mkdir(context, directory)
        end
        local bytes = required(graphcodec.encode({ schema = version.DIGEST_CACHE_SCHEMA,
            digest = version.CERTIFICATE_DIGEST, canonicalization = version.CERTIFICATE_CANONICALIZATION,
            abi = version.TITAN_ABI_VERSION, files = cache.files, objects = cache.objects },
            cache_codec_options(context)))
        local reserved = required(context.io:tmpname())
        staging = cache.path .. ".tmp." .. paths.basename(reserved)
        required(context.io:unlink(reserved))
        required(context.io:write_file(staging, bytes))
        required(context.io:rename(staging, cache.path))
        staging = nil
        cache.dirty = false
        return true
    end)
    if staging then pcall(context.io.unlink, context.io, staging) end
    if not ok then
        if type(result) ~= "string" then error(result, 0) end
        return nil, result
    end
    return result
end

-- An installed SDK's digest manifest. The installer, never titanc, records
-- the content digests of the installation's own native link inputs with
-- their precise observations; titanc only reads it, as one more recorded
-- digest source. An absent, malformed or foreign-schema manifest simply
-- provides no entries.
incremental.SDK_DIGESTS = "sdk-digests"

local function valid_sdk_digests(record)
    return closed_cache_table(record, { schema = true, digest = true,
            canonicalization = true, abi = true, files = true })
        and record.schema == version.SDK_DIGEST_SCHEMA
        and record.digest == version.CERTIFICATE_DIGEST
        and record.canonicalization == version.CERTIFICATE_CANONICALIZATION
        and record.abi == version.TITAN_ABI_VERSION and valid_file_entries(record.files)
end

function incremental.load_sdk_digests(context, filename)
    local memo = state(context)
    memo.sdk = nil
    local record = read_cache_record(context, filename)
    if valid_sdk_digests(record) then memo.sdk = { path = filename, files = record.files } end
    return true
end

-- Installer only: hash each input under the ordinary read-race guard and
-- atomically replace the manifest. Inputs without a precise observation get
-- no entry, so titanc always reads them.
function incremental.write_sdk_digests(context, filename, inputs)
    local memo, files = state(context), {}
    for _, path in ipairs(inputs) do
        local key = required(context.io:realpath(path))
        local bytes, observed, digest =
            read_evidence(context, path, key, file_count(memo, key), nil, true)
        if observed then files[key] = { digest = digest or hash(context, bytes), observation = observed } end
    end
    local bytes = required(graphcodec.encode({ schema = version.SDK_DIGEST_SCHEMA,
        digest = version.CERTIFICATE_DIGEST, canonicalization = version.CERTIFICATE_CANONICALIZATION,
        abi = version.TITAN_ABI_VERSION, files = files }, cache_codec_options(context)))
    local reserved = required(context.io:tmpname())
    local staging = filename .. ".tmp." .. paths.basename(reserved)
    required(context.io:unlink(reserved))
    local ok, err = pcall(function()
        required(context.io:write_file(staging, bytes))
        required(context.io:rename(staging, filename))
    end)
    if not ok then
        pcall(context.io.unlink, context.io, staging)
        error(err, 0)
    end
    return true
end

local NATIVE_MACH = {
    ["\206\250\237\254"] = { true, 28 }, ["\254\237\250\206"] = { false, 28 },
    ["\207\250\237\254"] = { true, 32 }, ["\254\237\250\207"] = { false, 32 },
}
local NATIVE_FAT = {
    ["\202\254\186\190"] = { false, 4 }, ["\190\186\254\202"] = { true, 4 },
    ["\202\254\186\191"] = { false, 8 }, ["\191\186\254\202"] = { true, 8 },
}

-- Only binary headers and section names are inspected here. In particular,
-- native archives/import libraries must not enter Titan metadata restoration.
-- The result is a pure content fact, shared by fallback links and LTO selection.
local function native_format(bytes, first, last, depth)
    if depth > 8 or last - first + 1 < 4 then return "unknown", false end
    local function uint(position, width, little)
        if position < first or position + width - 1 > last then return nil end
        local value = 0
        for index = 0, width - 1 do
            if value > math.maxinteger // 256 then return nil end
            value = value * 256 + bytes:byte(position + (little and width - index - 1 or index))
        end
        return value
    end
    local magic = bytes:sub(first, first + 3)
    if magic == "BC\192\222" or magic == "\222\192\023\011" then return "object", true end
    if magic == "\0asm" then
        if last - first + 1 < 8 or uint(first + 4, 4, true) ~= 1 then return "unknown", false end
        local position, linked = first + 8, false
        while position <= last do
            local id, count, size, shift = bytes:byte(position), 0, 0, 1
            position = position + 1
            if id > 13 then return "unknown", false end
            while true do
                if position > last or count == 5 then return "unknown", false end
                local digit = bytes:byte(position)
                position, count = position + 1, count + 1
                if count == 5 and digit > 0x0f then return "unknown", false end
                size, shift = size + (digit & 0x7f) * shift, shift * 128
                if digit < 0x80 then break end
            end
            if size > last - position + 1 then return "unknown", false end
            if id == 0 then
                local np, ncount, nsize, nshift = position, 0, 0, 1
                while true do
                    if np >= position + size or ncount == 5 then return "unknown", false end
                    local digit = bytes:byte(np)
                    np, ncount = np + 1, ncount + 1
                    if ncount == 5 and digit > 0x0f then return "unknown", false end
                    nsize, nshift = nsize + (digit & 0x7f) * nshift, nshift * 128
                    if digit < 0x80 then break end
                end
                if nsize > position + size - np then return "unknown", false end
                local name = bytes:sub(np, np + nsize - 1)
                if name == "dylink.0" or name == "dylink" then return "unknown", false end
                if name == "linking" then linked = true end
            end
            position = position + size
        end
        return linked and "object" or "unknown", false
    end
    local archive = bytes:sub(first, math.min(last, first + 7))
    if archive == "!<thin>\n" then return "thin", false end
    if archive == "!<arch>\n" then
        local position, lto = first + 8, false
        while position <= last do
            if position + 59 > last or bytes:sub(position + 58, position + 59) ~= "`\n" then
                return "unknown", false
            end
            local size = tonumber(bytes:sub(position + 48, position + 57):match("^%s*(%d+)%s*$"))
            if not size or size > last - position - 59 then return "unknown", false end
            local start, finish = position + 60, position + 59 + size
            local name_size = tonumber(bytes:sub(position, position + 15):match("^#1/(%d+)"))
            if name_size then
                if name_size > size then return "unknown", false end
                start = start + name_size
            end
            local _, member_lto = native_format(bytes, start, finish, depth + 1)
            lto = lto or member_lto
            position = finish + 1 + size % 2
        end
        return "archive", lto
    end
    if magic == "\127ELF" then
        local class, order = bytes:byte(first + 4, first + 5)
        if (class ~= 1 and class ~= 2) or (order ~= 1 and order ~= 2)
            or last - first + 1 < (class == 1 and 52 or 64) then return "unknown", false end
        local little, wide = order == 1, class == 2
        local kind = uint(first + 16, 2, little)
        kind = kind == 1 and "object" or kind == 3 and "shared" or "unknown"
        local offset = uint(first + (wide and 40 or 32), wide and 8 or 4, little)
        local stride = uint(first + (wide and 58 or 46), 2, little)
        local count = uint(first + (wide and 60 or 48), 2, little)
        local strings_index = uint(first + (wide and 62 or 50), 2, little)
        if not offset then return "unknown", false end
        if offset == 0 then return kind, false end
        if stride < (wide and 64 or 40) or offset > last - first then return "unknown", false end
        if count == 0 then count = uint(first + offset + (wide and 32 or 20), wide and 8 or 4, little) end
        if strings_index == 0xffff then strings_index = uint(first + offset + (wide and 40 or 24), 4, little) end
        if not count or count > (last - first + 1 - offset) // stride
            or not strings_index or strings_index >= count then return "unknown", false end
        local header = first + offset + stride * strings_index
        local strings = uint(header + (wide and 24 or 16), wide and 8 or 4, little)
        local size = uint(header + (wide and 32 or 20), wide and 8 or 4, little)
        if not strings or not size or strings > last - first + 1
            or size > last - first + 1 - strings then return "unknown", false end
        for index = 0, count - 1 do
            local name = uint(first + offset + stride * index, 4, little)
            if name and name + 9 <= size
                and bytes:sub(first + strings + name, first + strings + name + 8) == ".gnu.lto_" then
                return kind, true
            end
        end
        return kind, false
    end
    if NATIVE_MACH[magic] then
        if last - first + 1 < NATIVE_MACH[magic][2] then return "unknown", false end
        local kind = uint(first + 12, 4, NATIVE_MACH[magic][1])
        return kind == 1 and "object" or (kind == 6 or kind == 8) and "shared" or "unknown", false
    end
    if NATIVE_FAT[magic] then
        local little, width = table.unpack(NATIVE_FAT[magic])
        local count, stride = uint(first + 4, 4, little), width == 4 and 20 or 32
        if not count or count == 0 or count > (last - first - 7) // stride then return "unknown", false end
        local kind, lto
        for index = 0, count - 1 do
            local header = first + 8 + stride * index
            local offset, size = uint(header + 8, width, little), uint(header + 8 + width, width, little)
            if not offset or not size or size == 0 or offset > last - first
                or size > last - first + 1 - offset then return "unknown", false end
            local member, member_lto = native_format(bytes, first + offset, first + offset + size - 1, depth + 1)
            if member == "unknown" or member == "thin" or (kind and kind ~= member) then return "unknown", false end
            kind, lto = member, lto or member_lto
        end
        return kind, not not lto
    end
    if bytes:sub(first, first + 1) == "MZ" then
        local offset = uint(first + 60, 4, true)
        if offset and offset <= last - first - 23
            and bytes:sub(first + offset, first + offset + 3) == "PE\0\0" then
            local flags = uint(first + offset + 22, 2, true)
            if flags & 0x2000 ~= 0 then return "shared", false end
        end
        return "unknown", false
    end
    local machine, sections = uint(first, 2, true), uint(first + 2, 2, true)
    local header, symbols, symbol_count, symbol_width = first + 20, nil, nil, 18
    if magic == "\0\0\255\255" then
        machine = uint(first + 6, 2, true)
        if machine ~= 0x14c and machine ~= 0x8664 and machine ~= 0xaa64 then return "unknown", false end
        if uint(first + 4, 2, true) == 0 and last - first + 1 >= 20 then return "object", false end
        if bytes:sub(first + 12, first + 27) ~=
            "\199\161\186\209\238\186\169\75\175\32\250\246\106\164\220\184" then return "unknown", false end
        sections, symbols, symbol_count = uint(first + 44, 4, true), uint(first + 48, 4, true), uint(first + 52, 4, true)
        header, symbol_width = first + 56, 20
    elseif machine == 0x14c or machine == 0x8664 or machine == 0xaa64 then
        local optional = uint(first + 16, 2, true)
        if not optional then return "unknown", false end
        header, symbols, symbol_count = header + optional, uint(first + 8, 4, true), uint(first + 12, 4, true)
    else return "unknown", false end
    if not sections or sections > (last - header + 1) // 40 then return "unknown", false end
    local strings = symbols and symbol_count and first + symbols + symbol_count * symbol_width
    local string_size = strings and uint(strings, 4, true)
    for index = 0, sections - 1 do
        local position = header + index * 40
        local name = bytes:sub(position, position + 7)
        local offset = tonumber(name:match("^/(%d+)%z*$"))
        if offset and string_size and offset >= 4 and offset + 9 <= string_size
            and strings + string_size - 1 <= last then
            name = bytes:sub(strings + offset, strings + offset + 8)
        end
        if name == ".gnu.lto_" or name == ".llvm.lto" then return "object", true end
    end
    return "object", false
end

function incremental.native_input_kind(context, path)
    local ok, kind, err, lto = pcall(function()
        local digest = incremental.file_digest(context, path)
        local cache = state(context).persistent
        local fact = cache and cache.objects[digest]
        if not fact or fact.kind == nil or fact.lto == nil then
            local bytes = incremental.file_contents(context, path)
            local format, has_lto = native_format(bytes, 1, #bytes, 0)
            fact = fact or {}
            fact.kind, fact.lto = format, has_lto
            if cache then cache.objects[digest], cache.dirty = fact, true end
        end
        if fact.kind == "thin" then return nil, "thin native archives require external member tracking" end
        if fact.kind == "unknown" then return nil, "native input is not a recognized object, archive or shared library" end
        return fact.kind, nil, fact.lto
    end)
    if not ok then
        if type(kind) ~= "string" then error(kind, 0) end
        return nil, "cannot read native input '" .. path .. "': " .. kind
    end
    return kind, err, lto
end

-- A part scan is a pure content fact: no paths, observations, module views or
-- target selections enter the persisted value. Callers compare its target.
function incremental.part_fingerprint(context, path)
    local ok, fingerprint, err = pcall(function()
        local digest = incremental.file_digest(context, path)
        local cache = state(context).persistent
        local fact = cache and cache.objects[digest]
        if fact and fact.fingerprint then return fact.fingerprint end
        local bytes = incremental.file_contents(context, path)
        local part, scan_error = staticmetadata.scan_bytes(bytes, path,
            { expected_abi = version.TITAN_ABI_VERSION })
        if not part then return nil, scan_error end
        if part.kind ~= "object" then return nil, "not a single-architecture relocatable object" end
        if part.metadata ~= nil or objectmetadata.read(bytes, path) ~= nil then
            return nil, "unexpectedly contains Titan module metadata"
        end
        local result = part.fingerprint
        if cache and valid_fingerprint(result) then
            fact = fact or {}
            fact.fingerprint = result
            cache.objects[digest], cache.dirty = fact, true
        end
        return result
    end)
    if not ok then
        if type(fingerprint) ~= "string" then error(fingerprint, 0) end
        return nil, "cannot read native input '" .. path .. "': " .. fingerprint
    end
    return fingerprint, err
end

function incremental.preamble_identity(context, value)
    local opts = options(context, value)
    local source = absolute(context, assert(opts.preamble_path, "stable preamble_path is required"))
    mkdir(context, paths.dirname(source))
    local contents = require("titan-compiler.cpreamble").certification_includes
    local stat, staterr = context.io:stat(source)
    if staterr then required(nil, staterr, source) end
    local existing
    if stat then existing = required(context.io:read_file(source)) end
    if existing ~= contents then required(context.io:write_file(source, contents)) end
    local dep = required(context.io:tmpname())
    local ok, result, inventory = pcall(function()
        local argv = append({ table.unpack(assert(opts.compile_prefix)) },
            { "-E", "-dD", "-P", "-MD", "-MF", dep, "-MT", "titan-preamble",
                "-x", "c", source })
        local expanded = run(context, argv)
        local dependencies = required(require("titan-compiler.depfile").parse(
            incremental.file_contents(context, dep)))
        local inputs = {}
        local synthetic = required(context.io:realpath(source))
        for _, path in ipairs(dependencies) do
            local real = required(context.io:realpath(path))
            -- The TU is generated from the already-certified compiler include
            -- constants. Its output-tree path is not an external header input.
            if real ~= synthetic then
                local digest = incremental.file_digest(context, path)
                inputs[#inputs + 1] = { path = path, realpath = real, sha256 = digest }
            end
        end
        return incremental.digest(context, "preamble", {
            expanded = expanded, inputs = relocation.files(context, inputs) }), inputs
    end)
    local removed, removeerr = context.io:unlink(dep)
    incremental.invalidate_file(context, dep)
    if not ok then error(result, 0) end
    required(removed, removeerr, dep)
    return result, inventory
end

function incremental.configuration(context, value)
    if context.incremental_configuration then return context.incremental_configuration end
    local opts = options(context, value)
    local ok, result, reason, status = pcall(function()
        local compiler = required(incremental.compiler_component(context, opts))
        local toolchain, toolchain_error, toolchain_status =
            incremental.toolchain_identity(context, assert(opts.toolchain_descriptor))
        if not toolchain then
            if toolchain_status == "uncertified" then
                return nil, toolchain_error, toolchain_status
            end
            required(nil, toolchain_error)
        end
        local preamble = incremental.preamble_identity(context, opts)
        local ffi_dirs = {}
        for index, path in ipairs(opts.extra_ffi_include_dirs or {}) do
            ffi_dirs[index] = relocation.path(context, path)
        end
        local compile_options = { compile_prefix = relocation.argv(context, opts.compile_prefix),
            build_profile = opts.build_profile, emit_line_directives = opts.emit_line_directives,
            pretty_print = opts.pretty_print, extra_ffi_include_dirs = ffi_dirs,
            titan_root = relocation.path(context, opts.titan_root) }
        local certificate = { compiler = compiler, toolchain = toolchain, preamble = preamble,
            options = incremental.digest(context, "compile-options", compile_options) }
        certificate.digest = incremental.digest(context, "configuration", certificate)
        return certificate
    end)
    if not ok then
        if type(result) ~= "string" then error(result, 0) end
        error("cannot certify compiler configuration: " .. result, 0)
    end
    if not result then return nil, reason, status end
    context.incremental_configuration = result
    return result
end

function incremental.source_certificate(context, source, contents_by_path)
    local result = { layout = source.kind, sources = {} }
    local inputs = contents_by_path or source.certified_contents or {}
    for index, path in ipairs(source.files) do
        local digest, bytes = incremental.file_digest(context, path, inputs[path])
        result.sources[index] = { path = path, sha256 = digest }
        inputs[path] = bytes
    end
    source.certified_contents = inputs
    return result
end

function incremental.producer_digests(context, entry, layouts, recipe)
    assert(type(layouts) == "string", "producer must supply coder layout bytes")
    local helper = ""
    if recipe then
        helper = require("titan-compiler.ffiheaders").foreign_contents(recipe,
            "module.ffi.h", function(name) return name .. ".titan.h" end)
    end
    local public = incremental.digest(context, "public-interface", {
        types.serialize_semantic(entry.type), layouts, helper })
    local private = not next(context.relocation_roots or {}) and entry.source_manifest
        or required(require("titan-compiler.sourceinterface").serialize(entry, context))
    return { public = public,
        source = incremental.digest(context, "source-interface", { public, private }) }
end

function incremental.interface_digest(context, entry, view)
    view = view or "public"
    assert(view == "public" or view == "source", "unknown interface view")
    local native = entry.object_metadata
    if entry.kind == "source" then
        local self = entry.interface_digests
            or native and native.certificate and native.certificate.interface
        if not self or not self[view] then return nil, "pending" end
        return self[view]
    end
    if view == "source" then return nil end
    local provider, name = assert(entry.static_archive or entry.filename or entry.type.file),
        assert(entry.type.name)
    local memo = state(context).providers
    memo[provider] = memo[provider] or {}
    if not memo[provider][name] then
        local layouts = entry.layouts or native and native.layouts
        assert(type(layouts) == "string", "binary provider must supply its own layout bytes")
        memo[provider][name] = incremental.digest(context, "public-interface", {
            types.serialize_semantic(entry.type), layouts, "" })
    end
    return memo[provider][name]
end

function incremental.make_certificate(context, entry, native, inputs)
    local source = assert(inputs.source, "precomputed own-source certificate is required")
    assert(type(source.sources) == "table" and (source.layout == "flat" or source.layout == "folder"),
        "make_certificate requires the exact parsed own-source certificate")
    local providers = {}
    for name, filename in pairs(native.providers or {}) do
        providers[name] = relocation.path(context, filename)
    end
    local result = { configuration = assert(context.incremental_configuration),
        layout = source.layout, sources = source.sources,
        stem = relocation.path(context, inputs.stem),
        roots = context.relocation_roots or {}, generated = native.generated_inputs or {},
        codegen = inputs.codegen, imports = {}, owners = {},
        bindings = native.bindings or {}, providers = providers,
        interface = entry.interface_digests
            or incremental.producer_digests(context, entry, native.layouts, native.foreign_header) }
    local direct = {}
    for _, import in ipairs(native.imports or {}) do
        local name, view = import.name, import.source_required and "source" or "public"
        direct[name] = true
        local digest, status = inputs.plan.digest(name, view)
        assert(digest, "cannot certify dependency " .. name .. ": " .. tostring(status))
        result.imports[#result.imports + 1] = { name = name,
            source_required = import.source_required == true, view = view, interface = digest }
    end
    local owners = {}
    for name in pairs(inputs.binary_usage or {}) do owners[name] = true end
    for name in pairs(native.bindings or {}) do owners[name] = true end
    owners[entry.type.name] = nil
    for name in pairs(direct) do owners[name] = nil end
    local names = {}
    for name in pairs(owners) do names[#names + 1] = name end
    table.sort(names, util.bytewise_less)
    for _, name in ipairs(names) do
        local digest, status = inputs.plan.digest(name, "public")
        assert(digest, "cannot certify contextual owner " .. name .. ": " .. tostring(status))
        result.owners[#result.owners + 1] = { name = name, interface = digest }
    end
    local parts = {}
    for index, part in ipairs(inputs.generated_parts or {}) do
        parts[index] = { index = part.index, code = part.code }
    end
    result.object_identity = incremental.digest(context, "object-recipe", {
        configuration = result.configuration.digest, module = entry.type.name,
        stem = result.stem, codegen = result.codegen, parts = parts,
        private_header = inputs.private_header or "" })
    return result
end

local function miss(reason, detail)
    return { status = "miss", reason = reason, detail = detail }
end

local function dense(value, item_valid)
    if type(value) ~= "table" then return false end
    local count = 0
    for key, item in pairs(value) do
        if math.type(key) ~= "integer" or key < 1 or key > #value
            or not item_valid(item) then return false end
        count = count + 1
    end
    return count == #value
end

local function valid_certificate(value, modname)
    if type(value) ~= "table" or type(value.configuration) ~= "table"
        or type(value.configuration.digest) ~= "string"
        or (value.layout ~= "flat" and value.layout ~= "folder")
        or type(value.stem) ~= "string" or type(value.codegen) ~= "table"
        or type(value.bindings) ~= "table" or type(value.providers) ~= "table"
        or type(value.interface) ~= "table" or type(value.interface.public) ~= "string"
        or type(value.interface.source) ~= "string" or type(value.object_identity) ~= "string" then
        return false
    end
    if type(value.roots) ~= "table" or not dense(value.generated, function(part)
        return type(part) == "table" and math.type(part.bytes) == "integer" and part.bytes >= 0
            and type(part.sha256) == "string" and type(part.semantic) == "string"
    end) or #value.generated == 0 then return false end
    local policy = value.codegen
    if math.type(policy.c_parts) ~= "integer" or policy.c_parts < 1
        or math.type(policy.split_threshold) ~= "integer" or policy.split_threshold < 0
        or type(policy.test_flags) ~= "boolean" then return false end
    if policy.coverage ~= nil and (type(policy.coverage) ~= "table"
        or type(policy.coverage.enabled) ~= "boolean"
        or type(policy.coverage.backend) ~= "string") then return false end
    for _, key in ipairs({ "compiler", "preamble", "toolchain", "options" }) do
        if type(value.configuration[key]) ~= "string" then return false end
    end
    local seen = {}
    if not dense(value.sources, function(input)
        if type(input) ~= "table" or type(input.path) ~= "string"
            or type(input.sha256) ~= "string" or seen[input.path] then return false end
        seen[input.path] = true
        return true
    end) or #value.sources == 0 then return false end
    seen = {}
    local function dependency(item, imported)
        if type(item) ~= "table" or type(item.name) ~= "string"
            or type(item.interface) ~= "string" or (not imported and seen[item.name]) then return false end
        if imported and (type(item.source_required) ~= "boolean"
            or item.view ~= (item.source_required and "source" or "public")) then return false end
        seen[item.name] = true
        return true
    end
    if not dense(value.imports, function(item) return dependency(item, true) end)
        or not dense(value.owners, function(item) return dependency(item, false) end) then return false end
    if modname then seen[modname] = true end
    for name, binding in pairs(value.bindings) do
        if not seen[name] or (binding ~= "direct" and binding ~= "handle" and binding ~= "global") then
            return false
        end
    end
    for name, provider in pairs(value.providers) do
        if not seen[name] or type(provider) ~= "string" then return false end
    end
    return true
end

local function source_verdict(context, source, certificate)
    local current = { layout = source.kind, sources = {} }
    for index, path in ipairs(source.files) do current.sources[index] = { path = path } end
    local old, new = {}, {}
    for _, input in ipairs(certificate.sources) do old[input.path] = true end
    for _, input in ipairs(current.sources) do new[input.path] = true end
    for _, input in ipairs(certificate.sources) do
        if not new[input.path] then return miss("source-set", "removed " .. input.path) end
    end
    for _, input in ipairs(current.sources) do
        if not old[input.path] then return miss("source-set", "added " .. input.path) end
    end
    if certificate.layout ~= current.layout then
        return miss("source-set", "added " .. source.main)
    end
    source.certified_contents = source.certified_contents or {}
    for index, input in ipairs(current.sources) do
        local saved = certificate.sources[index]
        if saved.path ~= input.path then return miss("source-set", "added " .. input.path) end
        local ok, digest, bytes = pcall(incremental.file_digest, context, input.path,
            source.certified_contents[input.path])
        if not ok then
            if type(digest) ~= "string" then error(digest, 0) end
            return miss("source-content", input.path)
        end
        source.certified_contents[input.path] = bytes
        if saved.sha256 ~= digest then return miss("source-content", input.path) end
    end
    return { status = "hit" }
end

local function check_parts(context, record, stem, bytes)
    local native = record.object_metadata
    local valid, err = objectmetadata.validate_parts(native)
    if not valid then return miss("parts", err) end
    local companions = {}
    for _, part in ipairs(native.parts) do companions[#companions + 1] = stem .. part.c_suffix end
    if native.private_header then companions[#companions + 1] = stem .. native.private_header end
    for _, path in ipairs(companions) do
        local stat, staterr = context.io:lstat(path)
        if staterr ~= nil and type(staterr) ~= "string" then error(staterr, 0) end
        if not stat or stat.kind ~= "file" then
            return miss("parts", staterr or ("missing or nonregular generated companion: " .. path))
        end
    end
    local primary, primaryerr = staticmetadata.scan_bytes(bytes, stem .. ".o",
        { expected_abi = version.TITAN_ABI_VERSION })
    if not primary or primary.kind ~= "object" then
        return miss("parts", primaryerr or "invalid primary object")
    end
    local objects = { stem .. ".o" }
    for index = 2, #native.parts do
        local path = stem .. native.parts[index].object_suffix
        local stat, staterr = context.io:lstat(path)
        if staterr ~= nil and type(staterr) ~= "string" then error(staterr, 0) end
        if not stat or stat.kind ~= "file" then
            return miss("parts", staterr or ("missing or nonregular part object: " .. path))
        end
        local fingerprint, part_error = incremental.part_fingerprint(context, path)
        if not fingerprint then return miss("parts", path .. ": " .. tostring(part_error)) end
        local matches, mismatch = staticmetadata.fingerprint_matches(fingerprint, primary.fingerprint)
        if not matches then return miss("parts", "part object target mismatch: " .. tostring(mismatch)) end
        objects[index] = path
    end
    return { status = "hit", objects = objects }
end

local function check_coverage(context, native, stem)
    if native.coverage and native.coverage.enabled then
        if type(native.coverage.files) ~= "table" or #native.coverage.files ~= #native.parts then
            return miss("coverage-artifacts", stem .. ".gcno")
        end
        for _, part in ipairs(native.parts) do
            local source = stem .. part.c_suffix
            for _, path in ipairs({ source, (source:gsub("%.c$", ".gcno")) }) do
                local stat, err = context.io:lstat(path)
                if err ~= nil and type(err) ~= "string" then error(err, 0) end
                if not stat or stat.kind ~= "file" then return miss("coverage-artifacts", path) end
            end
        end
    end
    return { status = "hit" }
end

local function check_headers(context, record)
    local cpp = require "c-parser.cpp"
    local inputs, seen = {}, {}
    local function add(list)
        for _, input in ipairs(list or {}) do
            local key = input.kind .. "\0" .. input.path
            if seen[key] and seen[key] ~= input.identity then
                return miss("c-input", input.path .. ": content")
            elseif not seen[key] then
                seen[key] = input.identity
                inputs[#inputs + 1] = input
            end
        end
    end
    local failed = add(record.c_header_dependencies)
        or add(record.ffi_header_descriptor and record.ffi_header_descriptor.search_inputs)
    if failed then return failed end
    context.header_validation = context.header_validation or {}
    local opts = { io = context.io, cache_adapter = context.cache_adapter,
        header_validation = context.header_validation, header_observations = context.header_observations,
        file_digest = function(path, bytes) return incremental.file_digest(context, path, bytes) end }
    for _, input in ipairs(inputs) do
        local ok, refreshed, err, changed, reason = pcall(cpp.revalidate_header_input, input, opts)
        if not ok then
            if type(refreshed) ~= "string" then error(refreshed, 0) end
            local race = refreshed:find("changed while", 1, true)
                or refreshed:find("changed during", 1, true)
            return miss("c-input", input.path .. ": " .. (race and "changed-during-read" or "unreadable"))
        end
        if not refreshed or changed then
            if err ~= nil and type(err) ~= "string" then error(err, 0) end
            return miss("c-input", input.path .. ": " .. (reason or "unreadable"))
        end
    end
    return { status = "hit" }
end

-- Rebind explicit filesystem fields only. Source paths, C values and foreign
-- helper bodies are not a general graph/string relocation surface.
local function rebound_record(context, record, roots)
    local function inputs(list)
        for _, input in ipairs(list or {}) do
            input.path = relocation.rebind(context, input.path, roots)
            if input.kind == "origin" then
                local prefix = version.C_HEADER_ORIGIN_PROTOCOL .. ";real="
                if input.identity:sub(1, #prefix) == prefix then
                    input.identity = prefix .. relocation.rebind(context, input.identity:sub(#prefix + 1), roots)
                end
            end
        end
    end
    inputs(record.c_header_dependencies)
    local visited, companions, outputs = {}, {}, {}
    local function write(filename, contents)
        local stat, err = context.io:lstat(filename)
        if err then required(nil, err, filename) end
        if stat then
            assert(stat.kind == "file", "nonregular generated header: " .. filename)
            if context.io:read_file(filename) == contents then
                companions[#companions + 1] = filename
                return
            end
        end
        mkdir(context, paths.dirname(filename))
        required(context.io:write_file(filename, contents))
        incremental.invalidate_file(context, filename)
        companions[#companions + 1] = filename
    end
    local function descriptor(item)
        if not item or visited[item] then return end
        visited[item] = true
        item.contents = relocation.generated(context, item.contents, roots)
        item.roots = context.relocation_roots
        for index, include in ipairs(item.direct_includes or {}) do
            item.direct_includes[index] = relocation.includes(context, "#include " .. include, roots)
                :match("^#include (.*)$")
        end
        inputs(item.search_inputs)
        for _, dependency in ipairs(item.dependencies or {}) do descriptor(dependency) end
        local filename = relocation.resolve(context, item.identity)
        if platform.is_absolute(filename) then
            outputs[item.modname] = filename:gsub("%.ffi%.h$", ".titan.h")
            write(filename, item.contents)
            local helper = outputs[item.modname]
            local stat = context.io:lstat(helper)
            if stat and stat.kind == "file" then
                write(helper, relocation.generated(context, required(context.io:read_file(helper)), roots))
            end
        end
    end
    descriptor(record.ffi_header_descriptor)
    local native = record.object_metadata
    if native.foreign_header then
        native.foreign_header.prefix = relocation.generated(context, native.foreign_header.prefix, roots)
        local own = assert(outputs[record.type.name], "missing generated header output")
        write(own, require("titan-compiler.ffiheaders").foreign_contents(
            native.foreign_header, own:gsub("%.titan%.h$", ".ffi.h"),
            function(name) return assert(outputs[name], "missing source header output: " .. name) end))
    end
    if native.coverage then
        for index, filename in ipairs(native.coverage.files or {}) do
            native.coverage.files[index] = relocation.rebind(context, filename, roots)
        end
        local anchors = {}
        for filename, mapping in pairs(native.coverage.anchors or {}) do
            anchors[relocation.rebind(context, filename, roots)] = mapping
        end
        native.coverage.anchors = anchors
    end
    return companions
end

local function check_relocation(context, record, stem)
    local native, cert = record.object_metadata, record.object_metadata.certificate
    if not relocation.changed(context, cert.roots) then return { status = "hit" } end
    if #cert.generated ~= #native.parts then return miss("record-schema", "missing generated-C semantics") end
    local companions = rebound_record(context, record, cert.roots)
    if native.private_header then
        local filename = stem .. native.private_header
        local contents = required(context.io:read_file(filename))
        local rebound = relocation.generated(context, contents, cert.roots)
        if rebound ~= contents then
            required(context.io:write_file(filename, rebound))
            incremental.invalidate_file(context, filename)
        end
        companions[#companions + 1] = filename
    end
    local headers = check_headers(context, record)
    if headers.status ~= "hit" then return headers end
    local sources, evidence = {}, {
        roots = context.relocation_roots, object = incremental.file_digest(context, stem .. ".o") }
    for index, part in ipairs(native.parts) do
        local path, input = stem .. part.c_suffix, cert.generated[index]
        if type(input) ~= "table" or math.type(input.bytes) ~= "integer" or input.bytes < 0
            or type(input.sha256) ~= "string" or type(input.semantic) ~= "string" then
            return miss("record-schema", "invalid generated-C semantics")
        end
        local bytes = incremental.file_contents(context, path):sub(1, input.bytes)
        if incremental.digest(context, "generated-c", bytes) ~= input.sha256 then
            return miss("parts", path .. ": generated source changed")
        end
        sources[index] = relocation.generated(context, bytes, cert.roots)
        evidence[index] = incremental.file_digest(context, path)
    end
    evidence.companions = {}
    for index, filename in ipairs(companions) do
        evidence.companions[index] = incremental.file_digest(context, filename)
    end
    -- A disposable receipt avoids repeating relocation preprocessing on later
    -- unchanged builds. It is bound to the exact object/generated bytes and
    -- concrete current roots; header/source/configuration checks still run.
    local receipt = stem .. ".relocation"
    local key = incremental.digest(context, "relocated-generated-c", evidence)
    local stat = context.io:lstat(receipt)
    if stat and stat.kind == "file" and context.io:read_file(receipt, 65) == key then
        return { status = "hit" }
    end
    for index, part in ipairs(native.parts) do
        local spelling = relocation.rebind(context,
            cert.generated[index].spelling or (stem .. part.c_suffix), cert.roots)
        if incremental.preprocessed_identity(context, spelling, sources[index])
            ~= cert.generated[index].semantic then
            return miss("c-input", "relocated generated-C semantics")
        end
    end
    required(context.io:write_file(receipt .. ".tmp", key))
    required(context.io:rename(receipt .. ".tmp", receipt))
    return { status = "hit" }
end

function incremental.certify_local(context, modname, source)
    local opts = options(context)
    local stem = opts.stem(modname, source)
    local path = stem .. ".o"
    local stage, detail = "record-unreadable", path
    local record, imports
    local ok, result = pcall(function()
        local stat, err = context.io:lstat(path)
        if err ~= nil and type(err) ~= "string" then error(err, 0) end
        if err then return miss("record-unreadable", err) end
        if not stat or stat.kind ~= "file" then return miss("no-object") end
        local bytes = incremental.file_contents(context, path)
        local readerr, readreason
        record, readerr, readreason = objectmetadata.read(bytes, path)
        if not record then return miss(readreason or "record-unreadable", readerr) end
        local cert = record.object_metadata and record.object_metadata.certificate
        if not valid_certificate(cert, modname) then return miss("record-schema", "missing or invalid certificate") end
        if not record.type or record.type.name ~= modname then
            return miss("record-schema", "module name mismatch")
        end
        -- Imports depend only on own sources, not configuration or C inputs.
        stage, detail = "source-content", source.main
        local source_ok, sources = pcall(source_verdict, context, source, cert)
        if not source_ok and type(sources) ~= "string" then error(sources, 0) end
        if source_ok and sources.status == "hit" then imports = cert.imports end
        local current = assert(context.incremental_configuration,
            "configuration must be computed before local certification")
        for _, component in ipairs({ "compiler", "toolchain", "options", "preamble" }) do
            if cert.configuration[component] ~= current[component] then
                return miss("configuration", component)
            end
        end
        if not source_ok then return miss("source-content", source.main) end
        if sources.status ~= "hit" then return sources end
        if cert.stem ~= relocation.path(context, stem) then return miss("output-moved") end
        local codegen = opts.codegen_options(modname, record)
        for _, key in ipairs({ "c_parts", "split_threshold", "test_flags", "coverage" }) do
            if canonical(cert.codegen[key], {}) ~= canonical(codegen[key], {}) then
                return miss("codegen-options", key)
            end
        end
        stage, detail = "parts", path
        local parts = check_parts(context, record, stem, bytes)
        if parts.status ~= "hit" then return parts end
        stage = "coverage-artifacts"
        local covered = check_coverage(context, record.object_metadata, stem)
        if covered.status ~= "hit" then return covered end
        local relocated = check_relocation(context, record, stem)
        if relocated.status ~= "hit" then return relocated end
        stage = "c-input"
        local headers = check_headers(context, record)
        if headers.status ~= "hit" then return headers end
        return { status = "hit", object = path, objects = parts.objects }
    end)
    if not ok then
        if type(result) ~= "string" then error(result, 0) end
        result = miss(stage, stage == "source-content" and detail or result)
    end
    result.record, result.imports = record, imports
    return result
end

-- The caller supplies a newly resolved descriptor, including its current exact
-- folder membership. Never reuse pre-compile source bytes or C-input memos.
function incremental.revalidate_record(context, modname, source, record)
    local cert = record.object_metadata and record.object_metadata.certificate
    if not valid_certificate(cert, modname) or not record.type or record.type.name ~= modname then
        return miss("record-schema", "missing or invalid certificate")
    end
    local fresh = incremental.fresh_context(context)
    fresh.header_validation, fresh.header_observations = {}, {}
    local descriptor = { kind = source.kind, main = source.main, files = source.files }
    local ok, result = pcall(function()
        local sources = source_verdict(fresh, descriptor, cert)
        if sources.status ~= "hit" then return sources end
        return check_headers(fresh, record)
    end)
    local counters = incremental.counters(context)
    local total = counters.revalidation or { passes = 0, file_hashes = 0, file_reads = 0,
        file_bytes = 0, observation_reuses = 0, sdk_reuses = 0, digest_calls = 0, files = {} }
    counters.revalidation = total
    total.passes = total.passes + 1
    local current = incremental.counters(fresh)
    for _, key in ipairs({ "file_hashes", "file_reads", "file_bytes", "observation_reuses",
            "sdk_reuses", "digest_calls" }) do
        total[key] = total[key] + current[key]
    end
    for path, counts in pairs(current.files) do
        local saved = total.files[path] or { hashes = 0, reads = 0, bytes = 0,
            observation_reuses = 0, sdk_reuses = 0 }
        total.files[path] = saved
        for _, key in ipairs({ "hashes", "reads", "bytes", "observation_reuses", "sdk_reuses" }) do
            saved[key] = saved[key] + counts[key]
        end
    end
    if not ok then
        if type(result) ~= "string" then error(result, 0) end
        return miss("source-content", source.main)
    end
    return result
end

function incremental.verdict(record, plan)
    local cert = record.object_metadata and record.object_metadata.certificate
    local modname = record.type and record.type.name
    if not valid_certificate(cert, modname) then return miss("record-schema", "missing or invalid certificate") end
    local direct, pending, pending_set, known = {}, {}, {}, {}
    if modname then direct[modname], known[modname] = true, true end
    local function dependency(item, owner)
        local name = item.name
        known[name] = true
        if not owner then direct[name] = true end
        local view = owner and "public" or item.view
        local digest, status = plan.digest(name, view)
        if not digest then
            if status == "pending" then
                if not pending_set[name] then pending_set[name] = true; pending[#pending + 1] = name end
                return
            end
            return miss("dependency-unavailable", name)
        end
        if digest ~= item.interface then
            return miss(owner and "owner-interface" or "import-interface",
                owner and name or (name .. " (" .. view .. ")"))
        end
    end
    for _, item in ipairs(cert.imports) do
        local failed = dependency(item, false)
        if failed then return failed end
    end
    for _, item in ipairs(cert.owners) do
        local failed = dependency(item, true)
        if failed then return failed end
    end
    local names = {}
    for name in pairs(cert.bindings) do names[#names + 1] = name end
    for name in pairs(cert.providers) do
        if not cert.bindings[name] then names[#names + 1] = name end
    end
    table.sort(names, util.bytewise_less)
    for _, name in ipairs(names) do
        if not known[name] then return miss("record-schema", "uncertified binding " .. name) end
        local linked = name == modname or plan.linked(name)
        local provider = name ~= modname and plan.provider_file(name) or nil
        local expected = linked and "direct" or (direct[name] and provider and "handle" or "global")
        local binding = cert.bindings[name]
        -- Providers also record selected direct imports that the native binding
        -- inventory does not use. Those still certify exact provider selection.
        local expected_provider = not linked and direct[name] and provider or nil
        if expected_provider and plan.path then expected_provider = plan.path(expected_provider) end
        if (binding ~= nil and binding ~= expected)
            or cert.providers[name] ~= expected_provider then
            local before = tostring(binding) .. (cert.providers[name] and ("@" .. cert.providers[name]) or "")
            local after = expected .. (expected_provider and ("@" .. expected_provider) or "")
            return miss(direct[name] and "import-binding" or "owner-binding",
                name .. ": " .. before .. " -> " .. after)
        end
    end
    if #pending > 0 then
        table.sort(pending, util.bytewise_less)
        return { status = "pending", names = pending }
    end
    return { status = "hit" }
end

return incremental
