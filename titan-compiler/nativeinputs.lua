-- Normalize native policy once, and own authored C nodes separately from Titan
-- objects. All filesystem/native work uses the coordinator's resolver I/O.
local cdriver = require "c-parser.cdriver"
local depfile = require "titan-compiler.depfile"
local incremental = require "titan-compiler.incremental"
local certificate = require "titan-compiler.linkcertificate"
local paths = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local version = require "titan-compiler.version"
local native = {}

local function append(out, items)
    for _, item in ipairs(items or {}) do out[#out + 1] = item end
end

local function words(value, name, tokenize)
    if type(value) == "table" then return value end
    local result, err = tokenize(value or "")
    if not result then return nil, "invalid " .. name .. ": " .. tostring(err) end
    return result
end

function native.normalize(options)
    options = options or {}
    local defaults, environment, cli = options.defaults or {}, options.env or {}, options.cli or {}
    local tokenize = options.tokenize or cdriver.split_shell_words
    local result = { cppflags = {}, cflags = {}, ldflags = {}, libraries = {},
        compile_argv = {}, link_argv = {}, c_sources = {}, exe = cli.exe }
    local ambient_flags = {}
    for _, phase in ipairs({ "cppflags", "cflags", "ldflags" }) do
        local name = "TITAN_EXTRA_" .. phase:upper()
        local ambient = environment[name]
        if ambient == nil then ambient = environment[phase:upper()] end
        local base, err = words(defaults[phase], phase, tokenize)
        if not base then return nil, err end
        local extra
        extra, err = words(ambient, name, tokenize)
        if not extra then return nil, err end
        append(result[phase], base)
        append(result[phase], extra)
        ambient_flags[phase] = extra
        append(phase == "ldflags" and result.link_argv or result.compile_argv, base)
    end
    for _, library in ipairs(defaults.libraries or {}) do
        result.libraries[#result.libraries + 1] = library
        result.link_argv[#result.link_argv + 1] = "-l" .. library
    end
    append(result.compile_argv, ambient_flags.cppflags)
    append(result.compile_argv, ambient_flags.cflags)
    append(result.link_argv, ambient_flags.ldflags)
    for _, option in ipairs(cli.ordered or {}) do
        local kind, value = option.kind, option.value
        if type(value) ~= "string" or value:find("\0", 1, true) then
            return nil, "native argument must be a NUL-free string"
        end
        if kind == "include" or kind == "define" then
            local flag = (kind == "include" and "-I" or "-D") .. value
            result.cppflags[#result.cppflags + 1] = flag
            result.compile_argv[#result.compile_argv + 1] = flag
        elseif kind == "cflag" then
            result.cflags[#result.cflags + 1] = value
            result.compile_argv[#result.compile_argv + 1] = value
        elseif kind == "libdir" or kind == "ldflag" then
            local flag = kind == "libdir" and "-L" .. value or value
            result.ldflags[#result.ldflags + 1] = flag
            result.link_argv[#result.link_argv + 1] = flag
        elseif kind == "library" then
            -- Existing --link comma lists and repeated -l values have the same
            -- ordered representation. Deliberately retain repeated libraries.
            if value == "" or value:match("^,") or value:match(",$") or value:find(",,", 1, true) then
                return nil, "library list contains an empty name"
            end
            for library in value:gmatch("[^,]+") do
                result.libraries[#result.libraries + 1] = library
                result.link_argv[#result.link_argv + 1] = "-l" .. library
            end
        else
            return nil, "unknown native argument kind: " .. tostring(kind)
        end
    end
    append(result.c_sources, cli.c_sources)
    return result
end

local function need(value, err)
    if value == nil or value == false then error(err or "native input operation failed", 0) end
    return value
end

local function guarded(fn)
    local ok, value, err = pcall(fn)
    if not ok then
        if type(value) ~= "string" then error(value, 0) end
        return nil, value
    end
    return value, err
end

local function run(context, request, argv, phase)
    local result = request.run and request.run(argv, phase) or context.io:run(argv)
    need(type(result) == "table" and result.started and result.ok,
        type(result) == "table" and (result.diagnostic or result.output) or "native command failed")
end

local function regular(context, filename)
    local stat, err = context.io:lstat(filename)
    if err then error(err, 0) end
    if not stat or stat.kind ~= "file" then return nil end
    return stat
end

local function native_record(record)
    if type(record) ~= "table" or getmetatable(record) ~= nil or
        record.schema ~= version.TITAN_NATIVE_RECORD_SCHEMA or
        record.digest ~= version.CERTIFICATE_DIGEST or
        record.canonicalization ~= version.CERTIFICATE_CANONICALIZATION or
        type(record.input) ~= "string" or type(record.object) ~= "string" or
        #record.input ~= 64 or #record.object ~= 64 or
        record.input:find("[^0-9a-f]") or record.object:find("[^0-9a-f]") then return false end
    for key in pairs(record) do
        if key ~= "schema" and key ~= "digest" and key ~= "canonicalization" and
            key ~= "input" and key ~= "object" then return false end
    end
    return true
end

local function unlink(context, filename)
    local stat, err = context.io:lstat(filename)
    if err then error(err, 0) end
    if stat then
        need(stat.kind == "file", "refusing to remove nonfile native artifact: " .. filename)
        need(context.io:unlink(filename))
    end
end

local function reserve(context, filename)
    if platform.windows then return need(context.io:reserve_sibling(filename)) end
    local temporary = need(context.io:tmpname())
    need(context.io:unlink(temporary))
    local staged = filename .. "." .. paths.basename(temporary) .. ".tmp"
    need(not context.io:lstat(staged), "native stage already exists: " .. staged)
    need(context.io:write_file(staged, ""))
    return staged
end

local function cacheable_policy(argv)
    for _, flag in ipairs(argv) do
        if flag:sub(1, 1) == "@" or flag:match("^%-fplugin") or
            flag:match("^%-%-?specs") or flag == "-Xclang" or flag == "-wrapper" then
            return false
        end
    end
    return true
end

local function compile_node(context, request, source, stem)
    local preprocessed, dependencies = stem .. ".i", stem .. ".d"
    local object, sidecar = stem .. ".o", stem .. ".record"
    local cacheable = cacheable_policy(request.compile_argv)
    local argv = {}
    append(argv, request.compile_argv)
    append(argv, { "-E", "-MD", "-MF", dependencies, "-MT", "titan-native", source, "-o", preprocessed })
    -- Always execute preprocessing: its output covers negative __has_include
    -- decisions that cannot be represented by a positive dependency list.
    run(context, request, argv, "native-preprocess")
    incremental.invalidate_file(context, preprocessed)
    local files = need(depfile.parse(need(context.io:read_file(dependencies))))
    local recipe = { source = source, argv = request.compile_argv, toolchain = request.toolchain,
        authored = incremental.file_digest(context, source),
        preprocessed = incremental.file_digest(context, preprocessed),
        dependencies = certificate.files(context, files) }
    local input = incremental.digest(context, "native-c-input", recipe)
    local record = certificate.read_record(context, sidecar)
    if cacheable and request.incremental and native_record(record) and record.input == input and regular(context, object) then
        local identity = incremental.file_digest(context, object)
        if identity == record.object then
            return { path = object, identity = identity, source = source, hit = true, cacheable = true }
        end
    end
    local staged = reserve(context, object)
    local completed, result = pcall(function()
        local command = {}
        append(command, request.compile_argv)
        append(command, { "-c", source, "-o", staged })
        run(context, request, command, "native-compile")
        need(regular(context, staged), "native compiler produced no regular object")
        local current = { io = context.io, cache_adapter = context.cache_adapter }
        need(incremental.file_digest(current, source) == recipe.authored,
            "native source changed during compilation: " .. source)
        local observed = certificate.files(current, recipe.dependencies)
        need(incremental.digest(context, "native-dependencies", observed) ==
            incremental.digest(context, "native-dependencies", recipe.dependencies),
            "native dependency changed during compilation: " .. source)
        local identity = incremental.file_digest(current, staged)
        local next_record = { schema = version.TITAN_NATIVE_RECORD_SCHEMA,
            digest = version.CERTIFICATE_DIGEST, canonicalization = version.CERTIFICATE_CANONICALIZATION,
            input = input, object = identity }
        if request.publish then
            need(request.publish({ staged = staged, object = object, record = sidecar,
                metadata = next_record, cacheable = cacheable }))
        else
            -- The object is the commit marker. Remove it before replacing its
            -- sidecar, then publish the already validated primary last.
            unlink(context, object)
            if cacheable then need(certificate.write_record(context, sidecar, next_record))
            else unlink(context, sidecar) end
            need(context.io:rename(staged, object))
        end
        incremental.invalidate_file(context, object)
        return { path = object, identity = identity, source = source, hit = false, cacheable = cacheable }
    end)
    unlink(context, staged)
    if not completed then error(result, 0) end
    return result
end

-- compile_argv is the complete compiler + effective CPP/C policy, excluding
-- Titan-only test-owner/coverage flags. run participates in the shared ledger;
-- publish, if supplied, is coordinator-owned and commits the primary last.
function native.compile(context, request)
    return guarded(function()
        need(type(request.output_root) == "string", "native output root is required")
        need(type(request.compile_argv) == "table" and #request.compile_argv > 0,
            "native compiler argv is required")
        if type(request.toolchain) == "table" then
            local resolved = {}
            for key, value in pairs(request) do resolved[key] = value end
            resolved.toolchain = incremental.toolchain_identity(context, request.toolchain)
            request = resolved
        end
        need(type(request.toolchain) == "string", "native toolchain identity is required")
        local directory = paths.join(request.output_root, ".native")
        certificate.make_directory(context, directory)
        local result, seen = {}, {}
        for _, source in ipairs(request.sources or {}) do
            need(type(source) == "string" and source ~= "", "C source path is required")
            local canonical = certificate.canonical_path(context, source)
            if not seen[canonical] then
                seen[canonical] = true
                local stem = paths.join(directory, incremental.digest(context, "native-c-source-path", canonical))
                -- Keep the authored spelling stable for __FILE__ and diagnostics.
                result[#result + 1] = compile_node(context, request, source, stem)
            end
        end
        return result
    end)
end

return native
