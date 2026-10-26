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
local incremental = {}

local function state(context)
    if not context.incremental then
        context.incremental = { files = {}, aliases = {}, providers = {},
            counters = { file_hashes = 0, file_reads = 0, file_bytes = 0,
                digest_calls = 0, files = {} } }
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
    if value == nil then
        if err ~= nil and type(err) ~= "string" then error(err, 0) end
        error((path and (path .. ": ") or "") .. (err or "input is missing"), 0)
    end
    return value
end

local function absolute(context, path)
    return required(platform.absolute(path, required(context.io:cwd())))
end

local function observation(context, path)
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
            time_precision = value.time_precision }
    end
    return canonical({ fields(stat), fields(link) }, {})
end

function incremental.file_digest(context, path, bytes)
    local memo = state(context)
    local key = memo.aliases[path]
    if not key then
        key = required(context.io:realpath(path))
        memo.aliases[path] = key
    end
    local saved = memo.files[key]
    if saved then
        if bytes ~= nil and bytes ~= saved.bytes then
            error(path .. ": file changed during build", 0)
        end
        return saved.digest, saved.bytes
    end
    local counters = memo.counters
    local count = counters.files[key] or { hashes = 0, reads = 0, bytes = 0 }
    counters.files[key] = count
    if bytes == nil then
        local before = observation(context, path)
        bytes = required(context.io:read_file(path))
        counters.file_reads = counters.file_reads + 1
        count.reads = count.reads + 1
        if before ~= observation(context, path) or key ~= required(context.io:realpath(path)) then
            error(path .. ": file changed while it was read", 0)
        end
    end
    assert(type(bytes) == "string", "file digest requires byte contents")
    local digest = hash(context, bytes)
    counters.file_hashes = counters.file_hashes + 1
    counters.file_bytes = counters.file_bytes + #bytes
    count.hashes, count.bytes = count.hashes + 1, count.bytes + #bytes
    memo.files[key] = { digest = digest, bytes = bytes }
    context.io:yield()
    return digest, bytes
end

-- Only a publisher may retire evidence for an output it has replaced. Fresh
-- input revalidation uses a separate context instead of invalidating inputs.
function incremental.invalidate_file(context, path)
    local memo = state(context)
    local key = memo.aliases[path]
    if not key then return end
    memo.files[key] = nil
    for alias, target in pairs(memo.aliases) do
        if target == key then memo.aliases[alias] = nil end
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
                local digest, bytes = incremental.file_digest(context, paths.join(root, relative))
                inventory[#inventory + 1] = { path = relative, length = #bytes, sha256 = digest }
            end
        end
    end
    local frontend = opts.frontend or "api"
    if frontend == "api" then
        inventory[#inventory + 1] = { path = "titanc", api = true }
    else
        local digest, bytes = incremental.file_digest(context, frontend)
        inventory[#inventory + 1] = { path = "titanc", length = #bytes, sha256 = digest }
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

function incremental.physical_executable(context, command)
    local executable = type(command) == "table" and command[1] or command
    assert(type(executable) == "string" and executable ~= "", "tool executable is required")
    local candidates = {}
    if executable:find("[/\\]") or executable:match("^%a:") then
        candidates[1] = absolute(context, executable)
    else
        local separator = platform.windows and ";" or ":"
        local search = context.executable_path or platform.getenv("PATH") or ""
        for directory in (search .. separator):gmatch("(.-)" .. separator) do
            local candidate = paths.join(directory ~= "" and directory or ".", executable)
            candidates[#candidates + 1] = candidate
            if platform.windows and not executable:match("%.[^/\\]+$") then
                candidates[#candidates + 1] = candidate .. ".exe"
            end
        end
    end
    for _, candidate in ipairs(candidates) do
        local stat, err = context.io:stat(candidate)
        if err then required(nil, err, candidate) end
        if stat and stat.kind == "file" and context.io:readable(candidate)
            and (platform.windows or (stat.mode and stat.mode & 0x49 ~= 0)) then
            return { path = required(context.io:realpath(candidate)), size = stat.size,
                device = stat.device, inode = stat.inode, mode = stat.mode,
                modified_seconds = stat.modified_seconds,
                modified_nanoseconds = stat.modified_nanoseconds,
                changed_seconds = stat.changed_seconds,
                changed_nanoseconds = stat.changed_nanoseconds,
                time_precision = stat.time_precision or "coarse" }
        end
    end
    error("cannot resolve native tool executable: " .. executable, 0)
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
    local configured = {}
    for key, value in pairs(descriptor) do configured[key] = value end
    configured.io = context.io
    configured.cache_adapter = context.cache_adapter
    configured.file_digest = function(path, bytes)
        return incremental.file_digest(context, path, bytes)
    end
    local preprocessor, probe_error, probed_banner = descriptor.preprocessor_identity
    if not preprocessor then
        preprocessor, probe_error, probed_banner =
            require("c-parser.cdriver").preprocessor_cache_identity(configured)
        preprocessor = required(preprocessor, probe_error)
    end
    local null = platform.windows and "NUL" or "/dev/null"
    local banner = descriptor.banner or probed_banner or run(context, append({ table.unpack(cc) },
        { "-E", "-v", "-x", "c", null, "-o", null }))
    local tools = { incremental.physical_executable(context, cc) }
    local wrapper = paths.basename(cc[1]):lower():gsub("%.exe$", "")
    if wrapper == "ccache" or wrapper == "sccache" or wrapper == "distcc" then
        assert(cc[2] and cc[2]:sub(1, 1) ~= "-", "wrapped compiler must be explicit")
        tools[#tools + 1] = incremental.physical_executable(context, cc[2])
    end
    local stages = descriptor.stage_tools
    if not stages then
        stages = {}
        local clang = banner:lower():find("clang", 1, true)
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
        tools[#tools + 1] = incremental.physical_executable(context, stage)
    end
    local details = { preprocessor = preprocessor, banner = banner, tools = tools,
        target = descriptor.target_identity or descriptor.profile_identity or "" }
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
            required(context.io:read_file(dep))))
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
        return incremental.digest(context, "preamble", { expanded = expanded, inputs = inputs }), inputs
    end)
    local removed, removeerr = context.io:unlink(dep)
    if not ok then error(result, 0) end
    required(removed, removeerr, dep)
    return result, inventory
end

function incremental.configuration(context, value)
    if context.incremental_configuration then return context.incremental_configuration end
    local opts = options(context, value)
    local ok, result = pcall(function()
        local compiler = required(incremental.compiler_component(context, opts))
        local toolchain = incremental.toolchain_identity(context, assert(opts.toolchain_descriptor))
        local preamble = incremental.preamble_identity(context, opts)
        local compile_options = { compile_prefix = opts.compile_prefix,
            build_profile = opts.build_profile, emit_line_directives = opts.emit_line_directives,
            pretty_print = opts.pretty_print, extra_ffi_include_dirs = opts.extra_ffi_include_dirs or {},
            titan_root = opts.titan_root }
        local certificate = { compiler = compiler, toolchain = toolchain, preamble = preamble,
            options = incremental.digest(context, "compile-options", compile_options) }
        certificate.digest = incremental.digest(context, "configuration", certificate)
        return certificate
    end)
    if not ok then
        if type(result) ~= "string" then error(result, 0) end
        error("cannot certify compiler configuration: " .. result, 0)
    end
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
    local private = entry.source_manifest
        or required(require("titan-compiler.sourceinterface").serialize(entry))
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
    local result = { configuration = assert(context.incremental_configuration),
        layout = source.layout, sources = source.sources, stem = inputs.stem,
        codegen = inputs.codegen, imports = {}, owners = {},
        bindings = native.bindings or {}, providers = native.providers or {},
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
        local _, partbytes = incremental.file_digest(context, path)
        local part, parterr = staticmetadata.scan_bytes(partbytes, path,
            { expected_abi = version.TITAN_ABI_VERSION })
        if not part or part.kind ~= "object" then return miss("parts", parterr or path) end
        if part.metadata ~= nil or objectmetadata.read(partbytes, path) ~= nil then
            return miss("parts", "sidecar part object contains metadata: " .. path)
        end
        local matches, mismatch = staticmetadata.fingerprint_matches(part.fingerprint, primary.fingerprint)
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
        local _, bytes = incremental.file_digest(context, path)
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
        for _, component in ipairs({ "compiler", "preamble", "toolchain", "options" }) do
            if cert.configuration[component] ~= current[component] then
                return miss("configuration", component)
            end
        end
        if not source_ok then return miss("source-content", source.main) end
        if sources.status ~= "hit" then return sources end
        if cert.stem ~= stem then return miss("output-moved") end
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
    local fresh = { io = context.io, cache_adapter = context.cache_adapter,
        header_validation = {}, header_observations = {} }
    local descriptor = { kind = source.kind, main = source.main, files = source.files }
    local ok, result = pcall(function()
        local sources = source_verdict(fresh, descriptor, cert)
        if sources.status ~= "hit" then return sources end
        return check_headers(fresh, record)
    end)
    local counters = incremental.counters(context)
    local total = counters.revalidation or { passes = 0, file_hashes = 0,
        file_reads = 0, file_bytes = 0, digest_calls = 0, files = {} }
    counters.revalidation = total
    total.passes = total.passes + 1
    local current = incremental.counters(fresh)
    for _, key in ipairs({ "file_hashes", "file_reads", "file_bytes", "digest_calls" }) do
        total[key] = total[key] + current[key]
    end
    for path, counts in pairs(current.files) do
        local saved = total.files[path] or { hashes = 0, reads = 0, bytes = 0 }
        total.files[path] = saved
        for _, key in ipairs({ "hashes", "reads", "bytes" }) do
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
