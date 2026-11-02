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

local function browser_descriptor(context)
    local descriptor = context.target_descriptor
    return descriptor and descriptor.label == "browser" and descriptor or nil
end

local function need(value, err)
    if value == nil or value == false then error(err or "certificate operation failed", 0) end
    return value
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

local function output_path(context, path)
    path = absolute(context, path)
    -- Resolve ancestors, not the output leaf: snapshots must still reject a
    -- substituted symlink even if its target has a valid output certificate.
    local parent = path:match(platform.windows and "^(.*[/\\])[^/\\]+[/\\]*$" or "^(.*/)[^/]+/*$")
    if not parent then return canonical(context, path) end
    local trimmed = parent:gsub(platform.windows and "[/\\]+$" or "/+$", "")
    if platform.is_absolute(trimmed) then parent = trimmed end
    local filename = paths.join(canonical(context, parent), paths.basename(path))
    return platform.windows and filename:gsub("\\", "/"):lower() or filename
end

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
    local called, bytes = pcall(incremental.file_contents, context, filename, RECORD_LIMIT)
    if not called then
        if type(bytes) ~= "string" then error(bytes, 0) end
        return nil, bytes
    end
    return graphcodec.decode(bytes, codec_options(context))
end

function certificate.write_record(context, filename, record)
    local bytes, err = graphcodec.encode(record, codec_options(context))
    if not bytes then return nil, err end
    local written, write_error = context.io:write_file(filename, bytes)
    if written then incremental.invalidate_file(context, filename) end
    return written, write_error
end

local compiler_libraries

local function link_job_name(name)
    return name == "collect2" or name == "link" or name == "lld" or name == "lld-link"
        or name == "ld" or name:match("^ld[.%-]") or name:match("^ld64[.%-]") or name:match("%-ld$")
end

local function compiler_query(context, argv, message)
    local result = context.io:run(argv, { stderr_to_stdout = true })
    need(type(result) == "table" and result.started and not result.interrupted and result.why ~= "signal",
        type(result) == "table" and (result.diagnostic or result.output) or message)
    if not result.ok then
        need(result.why == "exit" and math.type(result.status) == "integer" and result.status ~= 0,
            result.diagnostic or result.output or message)
        return nil, result.diagnostic or result.output or message, "uncertified"
    end
    return result.output or ""
end

local function describe_link(context, argv, windows)
    local query = { table.unpack(argv) }
    local null = windows and "NUL" or "/dev/null"
    for _, word in ipairs({ "-###", "-x", "c", null, "-o", null }) do query[#query + 1] = word end
    return compiler_query(context, query, "cannot describe selected native link job")
end

-- Resolve once per coordinator, but again in every invocation. Both the final
-- recipe and dependency-feature memo consume this same physical selection.
local function selected_linker(context, request)
    need(type(request.compiler_argv) == "table" and #request.compiler_argv > 0,
        "linker inventory requires compiler argv")
    need(type(request.toolchain) == "string", "linker inventory requires toolchain identity")
    local argv = { table.unpack(request.compiler_argv) }
    for _, flag in ipairs(request.link_flags or {}) do argv[#argv + 1] = flag end
    local compiler_identity = request.compiler_identity or
        (context.incremental_configuration and context.incremental_configuration.compiler)
    local request_key = incremental.digest(context, "selected-linker-request", {
        argv = argv, toolchain = request.toolchain, compiler_identity = compiler_identity,
        darwin = request.darwin, windows = request.windows, stage_policy = request.compiler_stage_policy,
        executable_path = context.executable_path or platform.getenv("PATH"),
    })
    context.link_certificate_tools = context.link_certificate_tools or {}
    local saved = context.link_certificate_tools[request_key]
    if saved then return saved end
    local linker_name, explicit_linker, fused_path = "ld"
    for index, flag in ipairs(argv) do
        local selected = flag:match("^%-fuse%-ld=(.+)$")
        if selected then
            if selected:find("[/\\]") then fused_path = selected
            else linker_name, fused_path = "ld." .. selected, nil end
        elseif flag:match("^%-%-ld%-path=") then
            explicit_linker = flag:match("^%-%-ld%-path=(.*)$")
        elseif flag == "--ld-path" then
            explicit_linker = need(argv[index + 1], "--ld-path requires a linker path")
        end
    end
    explicit_linker = explicit_linker or fused_path
    local description
    if not explicit_linker and linker_name == "ld" then
        -- Clang's -print-prog-name=ld is a program search, not its configured
        -- default linker selection (notably CLANG64's ld.lld). Read the job.
        local reason, status
        description, reason, status = describe_link(context, argv, request.windows)
        if not description then return nil, reason, status end
        local split, collect2 = require("c-parser.cpp").split_shell_words, false
        for line in (description .. "\n"):gmatch("(.-)\r?\n") do
            local job = line:match("^%s") and split(line)
            if job and job[1] then
                local name = paths.basename(job[1]):lower():gsub("%.exe$", "")
                if name == "collect2" then collect2 = true
                elseif link_job_name(name) then explicit_linker = job[1] end
            end
        end
        -- GCC's collect2 delegates to the compiler's named ld; Clang names the
        -- actual linker directly. Never substitute a guessed default.
        if not explicit_linker and not collect2 then
            return nil, "compiler did not name a selected native linker", "uncertified"
        end
    end
    if not explicit_linker then
        local query = { table.unpack(argv) }
        query[#query + 1] = "-print-prog-name=" .. linker_name
        local output, reason, status = compiler_query(context, query, "cannot resolve native linker")
        if not output then return nil, reason, status end
        explicit_linker = output:match("^%s*(.-)%s*$")
        if explicit_linker == "" or explicit_linker:find("[\r\n]") then
            return nil, "compiler did not name one native linker", "uncertified"
        end
    end
    local compiler, reason, status = incremental.physical_executable(context, request.compiler_argv)
    if not compiler then return nil, reason, status end
    local linker
    linker, reason, status = incremental.physical_executable(context, explicit_linker,
        request.compiler_stage_policy or "unknown")
    if not linker then return nil, reason, status end
    local selected = {
        argv = argv, name = explicit_linker, description = description,
        compiler = compiler, linker = linker,
    }
    selected.key = incremental.digest(context, "linker-dependency-feature", {
        argv = argv, toolchain = request.toolchain, compiler = selected.compiler,
        linker = selected.linker, compiler_identity = compiler_identity,
    })
    context.link_certificate_tools[request_key] = selected
    return selected
end

function certificate.linker_backend(context, request)
    request = request or {}
    if browser_descriptor(context) then
        local kind = request.kind or context.link_kind
        local backend = (kind == "program" or kind == "test") and "wasm" or "archive"
        if request.uncacheable then
            return backend, request.uncacheable, "uncertified"
        end
        return backend
    end
    if request.uncacheable then return "none", request.uncacheable, "uncertified" end
    local report
    local function discard_report()
        if not report then return end
        local stat, err = context.io:lstat(report)
        if err then error(err, 0) end
        if stat then
            need(stat.kind == "file", "linker probe report is not a regular file")
            need(context.io:unlink(report))
        end
        incremental.invalidate_file(context, report)
        report = nil
    end
    local completed, backend, reason, status = pcall(function()
        local selected, reason, status = selected_linker(context, request)
        if not selected then
            need(status == "uncertified", reason)
            return "none", reason, status
        end
        if request.darwin then return "darwin" end
        if request.windows then return "none" end
        if selected.backend then return selected.backend end
        need(type(request.directory) == "string", "linker probe requires an output directory")
        local directory = paths.join(absolute(context, request.directory), ".titan")
        local filename = paths.join(directory, "linker-feature")
        local record = certificate.read_record(context, filename)
        if closed(record, { key = true, backend = true, digest = true, canonicalization = true }) and
            record.key == selected.key and record.digest == version.CERTIFICATE_DIGEST and
            record.canonicalization == version.CERTIFICATE_CANONICALIZATION and
            (record.backend == "gnu" or record.backend == "lld" or record.backend == "none") then
            selected.backend = record.backend
            return record.backend
        end
        report = need(context.io:tmpname())
        local probe = { table.unpack(selected.argv) }
        probe[#probe + 1] = "-Wl,--dependency-file=" .. report
        probe[#probe + 1] = "-Wl,--version"
        local result = context.io:run(probe, { stderr_to_stdout = true })
        need(type(result) == "table" and result.started and not result.interrupted and result.why ~= "signal",
            type(result) == "table" and (result.diagnostic or result.output) or "linker feature probe failed")
        local backend = "none"
        if result.ok then
            local banner = result.output or result.diagnostic or ""
            -- GCC's --version also echoes linker argv; paths are not banners.
            for line in banner:gmatch("[^\r\n]+") do
                if line:match("^%s*[%w_.%- ]*LLD%s+%d") then backend = "lld"; break
                elseif line:match("^%s*GNU ld[%s%.]") then backend = "gnu"; break end
            end
        end
        discard_report()
        mkdir(context, directory)
        need(certificate.write_record(context, filename, {
            key = selected.key, backend = backend, digest = version.CERTIFICATE_DIGEST,
            canonicalization = version.CERTIFICATE_CANONICALIZATION,
        }))
        selected.backend = backend
        return backend
    end)
    local cleaned, cleanup_error = pcall(discard_report)
    if not completed and type(backend) ~= "string" then error(backend, 0) end
    if not cleaned and type(cleanup_error) ~= "string" then error(cleanup_error, 0) end
    if not completed then return nil, backend end
    if not cleaned then return nil, cleanup_error end
    return backend, reason, status
end

local function lto_setting(argv)
    local enabled
    for _, flag in ipairs(argv or {}) do
        if flag == "-flto" or flag:match("^%-flto=") then enabled = true
        elseif flag == "-fno-lto" then enabled = false end
    end
    return enabled
end

local function selected_link_stages(context, request, selected, tools)
    local description, reason, status = selected.description
    if not description then
        description, reason, status = describe_link(context, selected.argv, request.windows)
        if not description then return nil, reason, status end
    end
    selected.description = description
    local split = require("c-parser.cpp").split_shell_words
    local wrapper, collect2, found, declared_wrapper
    local function executable(role, path)
        local identity, reason, status = incremental.physical_executable(context, path,
            request.compiler_stage_policy or "unknown")
        if not identity then return nil, reason, status end
        tools[role] = { argv = { path }, identity = identity }
        return true
    end
    local function plugin(path)
        tools.lto_plugins = tools.lto_plugins or {}
        tools.lto_plugins[#tools.lto_plugins + 1] = {
            argv = { path }, identity = incremental.physical_tool_file(context, path),
        }
    end
    local selected_name = paths.basename(selected.linker.path):lower():gsub("%.exe$", "")
    for line in (description .. "\n"):gmatch("(.-)\r?\n") do
        declared_wrapper = line:match("^COLLECT_LTO_WRAPPER=(.+)$") or declared_wrapper
        local argv = line:match("^%s") and split(line)
        if argv and argv[1] then
            local name = paths.basename(argv[1]):lower():gsub("%.exe$", "")
            if link_job_name(name) or name == selected_name then
                found = true
                if name == "collect2" then collect2 = argv[1] end
                local index = 2
                while index <= #argv do
                    local flag = argv[index]
                    if flag == "-plugin" or flag == "--plugin" or flag == "-lto_library" then
                        index = index + 1
                        plugin(need(argv[index], "selected LTO plugin path is missing"))
                    elseif flag:match("^%-%-?plugin=") then
                        plugin(flag:match("=(.*)$"))
                    elseif flag:match("^%-plugin%-opt=") then
                        local path = flag:match("^%-plugin%-opt=(.+)$")
                        if path:sub(1, 1) ~= "-" and paths.basename(path):match("^lto%-wrapper") then wrapper = path end
                    end
                    index = index + 1
                end
            end
        end
    end
    if not found then return nil, "compiler did not describe a selected native link job", "uncertified" end
    if collect2 then
        local resolved, reason, status = executable("link_driver", collect2)
        if not resolved then return nil, reason, status end
        -- collect2 and every advertised plugin are native link inputs even
        -- when no IR is present. Only its conditional LTO delegates are gated.
        local setting = lto_setting(selected.argv)
        if setting == false then return true end
        local enabled = setting == true or lto_setting(request.compile_argv) == true
        if not enabled then
            local inputs = { table.unpack(request.inputs or {}) }
            local native_files = compiler_libraries(context, {
                compiler_argv = request.compiler_argv, argv = request.link_flags,
                darwin = request.darwin, windows = request.windows,
            })
            if not native_files then enabled = true
            else for _, path in ipairs(native_files) do inputs[#inputs + 1] = path end end
            for _, input in ipairs(inputs) do
                local kind, _, lto = incremental.native_input_kind(context,
                    type(input) == "table" and input.path or input)
                -- An opaque payload may select IR indirectly. Inventory its
                -- compiler-selected pipeline rather than assuming it is native.
                if not kind or lto then enabled = true; break end
            end
        end
        if not enabled then return true end
        local function named_stage(name)
            local command = { table.unpack(selected.argv) }
            command[#command + 1] = "-print-prog-name=" .. name
            local output, reason, status = compiler_query(context, command, "cannot resolve selected LTO stage: " .. name)
            if not output then return nil, reason, status end
            local path = output:match("^%s*(.-)%s*$")
            if path == "" or path:find("[\r\n]") then
                return nil, "compiler did not name one LTO stage: " .. name, "uncertified"
            end
            return path
        end
        local path = wrapper or declared_wrapper
        if not path then
            path, reason, status = named_stage("lto-wrapper")
            if not path then return nil, reason, status end
        end
        resolved, reason, status = executable("lto_wrapper", path)
        if not resolved then return nil, reason, status end
        path, reason, status = named_stage("lto1")
        if not path then return nil, reason, status end
        resolved, reason, status = executable("lto_compiler", path)
        if not resolved then return nil, reason, status end
    end
    return true
end

function certificate.output_tools(context, request)
    local ok, tools = pcall(function()
        if request.uncacheable then return { uncertified = request.uncacheable } end
        local function uncertified(reason, status)
            need(status == "uncertified", reason)
            return { uncertified = reason }
        end
        local selected, result
        if browser_descriptor(context) then
            result = {}
        else
            local reason, status
            selected, reason, status = selected_linker(context, request)
            if not selected then return uncertified(reason, status) end
            result = { linker = { argv = { selected.name },
                driver_argv = selected.argv, identity = selected.linker } }
        end
        for role, argv in pairs(request.tools or {}) do
            need(role ~= "linker" and role ~= "uncertified", "reserved native tool role: " .. tostring(role))
            local identity, reason, status = incremental.physical_executable(context, argv)
            if not identity then return uncertified(reason, status) end
            result[role] = { argv = { table.unpack(argv) }, identity = identity }
        end
        if selected then
            local resolved, reason, status =
                selected_link_stages(context, request, selected, result)
            if not resolved then return uncertified(reason, status) end
        end
        return result
    end)
    if not ok then
        if type(tools) ~= "string" then error(tools, 0) end
        return nil, tools
    end
    return tools
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

-- Fallback deliberately has a finite grammar: an unknown option may name a
-- file (or make a tool read one), so skipping it cannot certify a complete set.
local INPUT_FREE_LINK_FLAGS = {
    ["-pthread"] = true, ["-pthreads"] = true, ["-shared"] = true, ["-pie"] = true,
    ["-no-pie"] = true, ["-static-pie"] = true, ["-rdynamic"] = true, ["-s"] = true,
    ["-g"] = true, ["-nostdlib"] = true, ["-nodefaultlibs"] = true, ["-nostartfiles"] = true,
    ["-static-libgcc"] = true, ["-shared-libgcc"] = true, ["-static-libstdc++"] = true,
    ["-fno-lto"] = true, ["-flto"] = true, ["-fuse-linker-plugin"] = true,
    ["-fno-use-linker-plugin"] = true, ["-m32"] = true, ["-m64"] = true,
    ["--as-needed"] = true, ["--no-as-needed"] = true, ["--whole-archive"] = true,
    ["--no-whole-archive"] = true, ["--start-group"] = true, ["--end-group"] = true,
    ["-("] = true, ["-)"] = true, ["--gc-sections"] = true, ["--no-gc-sections"] = true,
    ["--strip-all"] = true, ["--strip-debug"] = true, ["--export-dynamic"] = true,
    ["--no-undefined"] = true, ["--allow-shlib-undefined"] = true,
    ["--exclude-all-symbols"] = true,
}
local LINK_VALUE_FLAGS = {
    ["-u"] = true, ["--undefined"] = true, ["-e"] = true, ["--entry"] = true,
    ["-soname"] = true, ["--soname"] = true, ["-install_name"] = true,
    ["-z"] = true, ["--ld-path"] = true,
}
local LINK_FILE_FLAGS = { ["--just-symbols"] = true, ["--retain-symbols-file"] = true }

local function link_arguments(arguments)
    local argv, forwarded = {}, {}
    for _, flag in ipairs(arguments or {}) do
        if flag:sub(1, 4) == "-Wl," then
            for part in (flag:sub(5) .. ","):gmatch("(.-),") do
                argv[#argv + 1], forwarded[#argv + 1] = part, true
            end
        else argv[#argv + 1] = flag end
    end
    return argv, forwarded
end

compiler_libraries = function(context, request)
    if type(request.compiler_argv) ~= "table" or #request.compiler_argv == 0 then
        return nil, "native library fallback requires compiler argv"
    end
    local directories, inputs, static = {}, {}, request.static or false
    local argv, forwarded = link_arguments(request.argv)
    local index = 1
    while index <= #argv do
        local flag = argv[index]
        local option, attached = flag:match("^(%-%-[%w%-]+)=(.*)$")
        if flag == "-L" or flag == "-l" then
            index = index + 1
            local value = argv[index]
            if not value or value == "" then return nil, "incomplete native library option" end
            if flag == "-L" then directories[#directories + 1] = value
            else inputs[#inputs + 1] = { name = value, static = static } end
        elseif flag:sub(1, 2) == "-L" then directories[#directories + 1] = flag:sub(3)
        elseif flag:sub(1, 2) == "-l" then inputs[#inputs + 1] = { name = flag:sub(3), static = static }
        elseif flag == "-static" then static = true
        elseif forwarded[index] and flag == "-Bstatic" then static = true
        elseif forwarded[index] and flag == "-Bdynamic" then static = false
        elseif LINK_FILE_FLAGS[option or flag] then
            if attached == nil then index = index + 1; attached = argv[index] end
            if not attached or attached == "" then return nil, "incomplete native file option: " .. flag end
            inputs[#inputs + 1] = { path = attached, binary = false }
        elseif LINK_VALUE_FLAGS[option or flag] or
            ((request.windows or platform.windows) and (option or flag) == "--stack") then
            -- PE reserve[,commit] is one scalar argument, never a file.
            if attached == nil then index = index + 1; attached = argv[index] end
            if not attached or attached == "" then return nil, "incomplete native linker option: " .. flag end
        elseif INPUT_FREE_LINK_FLAGS[flag] or flag:match("^%-O[0-3sgz]$")
            or flag == "-Ofast" or flag:match("^%-flto=[%w%-]+$")
            or flag:match("^%-fuse%-ld=.+$") or flag:match("^%-%-build%-id[=]?[%w%-]*$")
            or flag:match("^%-%-hash%-style=[%w]+$") then
            -- Its complete effect is already in the ordered recipe argv.
        elseif flag:sub(1, 1) ~= "-" and flag ~= "" then
            inputs[#inputs + 1] = { path = flag, binary = true }
        else
            return nil, "unsupported native linker input mechanism: " .. flag
        end
        index = index + 1
    end
    for _, directory in ipairs(request.library_dirs or {}) do directories[#directories + 1] = directory end
    for _, library in ipairs(request.libraries or {}) do
        inputs[#inputs + 1] = { name = library, static = static }
    end
    local files = {}
    for _, item in ipairs(inputs) do
        if item.path then
            local filename = absolute(context, item.path)
            local stat, err = context.io:stat(filename)
            if err ~= nil then error(err, 0) end
            if not stat or stat.kind ~= "file" then return nil, "cannot resolve native file: " .. item.path end
            if item.binary then
                local kind, kind_error = incremental.native_input_kind(context, filename)
                if not kind then return nil, filename .. ": " .. tostring(kind_error) end
            end
            files[#files + 1] = filename
        else
        local library, candidates = item.name
        if library:sub(1, 1) == ":" then candidates = { library:sub(2) }
        elseif request.windows or platform.windows then
            -- MinGW searches every directory before advancing to the next;
            -- .lib is a static candidate too, after the prefixed archive.
            candidates = item.static and { "lib" .. library .. ".a", library .. ".lib" } or {
                "lib" .. library .. ".dll.a", library .. ".dll.a",
                "lib" .. library .. ".a", library .. ".lib",
                "lib" .. library .. ".dll", library .. ".dll",
            }
        elseif item.static then candidates = { "lib" .. library .. ".a" }
        elseif request.darwin then candidates = { "lib" .. library .. ".dylib", "lib" .. library .. ".a" }
        else candidates = { "lib" .. library .. ".so", "lib" .. library .. ".a" } end
        local selected
        for _, directory in ipairs(directories) do
            for _, candidate in ipairs(candidates) do
                -- Resolve POSIX symlink/.. traversal as the native linker does,
                -- rather than folding it into a different existing directory.
                local filename = (platform.windows and paths.join or platform.join)(directory, candidate)
                local stat, err = context.io:stat(filename)
                if err then error(err, 0) end
                if stat and stat.kind == "file" and context.io:readable(filename) then selected = filename; break end
            end
            if selected then break end
        end
        if not selected then
            local implicit_directory
            for _, candidate in ipairs(candidates) do
                local command = { table.unpack(request.compiler_argv) }
                for _, flag in ipairs(request.argv or {}) do command[#command + 1] = flag end
                command[#command + 1] = "-print-file-name=" .. candidate
                local result = context.io:run(command)
                if result.started and result.ok then
                    local filename = (result.output or ""):match("^%s*(.-)%s*$")
                    if filename ~= "" and filename ~= candidate and not filename:find("[\r\n]") then
                        local stat, err = context.io:stat(filename)
                        if err then error(err, 0) end
                        if stat and stat.kind == "file" then
                            -- Separate print-file-name queries do not expose
                            -- directory order. Different candidate directories
                            -- cannot safely be ranked by filename preference.
                            local directory = canonical(context, paths.dirname(filename))
                            if implicit_directory and implicit_directory ~= directory then
                                return nil, "ambiguous compiler library search order: " .. library
                            end
                            implicit_directory = directory
                            selected = selected or filename
                        end
                    end
                end
            end
        end
        if not selected then return nil, "cannot resolve native library: " .. library end
        local kind, kind_error = incremental.native_input_kind(context, selected)
        if not kind then return nil, selected .. ": " .. tostring(kind_error) end
        files[#files + 1] = selected
        end
    end
    return files
end

-- Browser trace identity needs user-selected archives before the synthetic entry
-- is compiled. Reuse the existing resolver and its diagnostics; other trailing
-- options remain in the full ordered identity recipe, not a second flag parser.
function certificate.browser_trace_libraries(context, compiler_argv, flags)
    local argv, filtered = link_arguments(flags), {}
    local index = 1
    while index <= #argv do
        local flag = argv[index]
        if flag == "-L" or flag == "-l" then
            filtered[#filtered + 1] = flag
            index = index + 1
            filtered[#filtered + 1] = argv[index]
        elseif flag:sub(1, 2) == "-L" or flag:sub(1, 2) == "-l" then
            filtered[#filtered + 1] = flag
        end
        index = index + 1
    end
    if #filtered == 0 then return {} end
    return compiler_libraries(context, {
        compiler_argv = compiler_argv, argv = filtered, static = true,
    })
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
    for _, flag in ipairs(link_arguments(request.argv)) do
        if flag:sub(1, 1) == "@" or flag:match("^%-fplugin") or
            flag:match("^%-%-?plugin") or flag == "-Xlinker" or
            flag:match("^%-%-?specs") or flag == "-wrapper" or
            flag == "-filelist" or flag:match("^%-filelist=") or flag == "--filelist" then
            return { cacheable = false, backend = backend or "none", argv = {},
                reason = "opaque linker input mechanism: " .. flag }
        end
    end
    if browser_descriptor(context) and backend == "archive" then
        return { cacheable = true, backend = "archive", files = {}, argv = {} }
    end
    if backend == "wasm" then
        need(type(filename) == "string", "link dependency output path is required")
        return { cacheable = true, backend = backend, dependency_file = filename,
            capture_trace = true, argv = { "-Wl,--trace" } }
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
    local bytes = incremental.file_contents(context, policy.dependency_file)
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
    elseif policy.backend == "wasm" then
        files = {}
        need(not bytes:find("\0", 1, true), "NUL in Wasm linker input trace")
        for line in (bytes .. "\n"):gmatch("([^\r\n]+)[\r\n]+") do
            local filename = line
            local stat = context.io:stat(filename)
            if not stat and line:sub(-1) == ")" then
                local candidates, offset = {}, 1
                while true do
                    local boundary = line:find("(", offset, true)
                    if not boundary or boundary >= #line - 1 then break end
                    candidates[#candidates + 1] = absolute(context, line:sub(1, boundary - 1))
                    offset = boundary + 1
                end
                filename = nil
                -- The archive path is a literal recipe input, not the first
                -- or last parenthesis: both it and the member may contain '('.
                for _, candidate in ipairs(candidates) do
                    if policy.trace_inputs[candidate] and
                       context.io:read_file(candidate, 7) == "!<arch>\n" then
                        need(not filename, "ambiguous Wasm linker input trace: " .. line)
                        filename = candidate
                    end
                end
                if not filename then
                    -- Implicit toolchain libraries are not recipe argv inputs.
                    -- Accept only one regular archive at a literal boundary.
                    for _, candidate in ipairs(candidates) do
                        local info = context.io:stat(candidate)
                        if info and info.kind == "file" and
                           context.io:read_file(candidate, 7) == "!<arch>\n" then
                            need(not filename, "ambiguous Wasm linker input trace: " .. line)
                            filename = candidate
                        end
                    end
                end
                stat = filename and context.io:stat(filename)
            end
            need(stat and stat.kind == "file", "invalid Wasm linker input trace: " .. line)
            files[#files + 1] = filename
        end
        need(#files > 0, "empty Wasm linker input trace")
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
        local filename = output_path(context, need(output.path))
        local key = canonical(context, filename)
        need(not seen[key], "duplicate final output: " .. filename)
        seen[key] = true
        outputs[#outputs + 1] = { path = filename, executable = output.executable or false,
            kind = output.kind or "file" }
        keys[#keys + 1] = key
    end
    table.sort(keys, util.bytewise_less)
    local key = incremental.digest(context, "final-output-set", keys)
    local directory = paths.join(canonical(context, spec.output_root), ".titan-links", key)
    local input = { outputs = outputs }
    for _, field in ipairs(RECIPE_FIELDS) do input[field] = spec[field] end
    local browser = browser_descriptor(context)
    if browser then
        input.policy = {}
        for name, value in pairs(spec.policy or {}) do input.policy[name] = value end
        input.policy.target = browser.identity
    end
    for _, field in ipairs(FILE_FIELDS) do input[field] = certificate.files(context, spec[field]) end
    need(data_only(input), "link recipe must contain only acyclic data")
    local native_request = {}
    for name, value in pairs(spec.native_libraries or {}) do native_request[name] = value end
    native_request.argv = native_request.argv or spec.argv
    native_request.dependency_file = native_request.dependency_file or paths.join(directory, "link.d")
    local output_tools = type(spec.toolchain) == "table" and spec.toolchain.output_tools
    if type(output_tools) == "table" and output_tools.uncertified then
        native_request.uncacheable = output_tools.uncertified
    end
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
    if policy.backend == "wasm" then
        policy.trace_inputs = {}
        for _, field in ipairs(FILE_FIELDS) do
            for _, file in ipairs(input[field]) do policy.trace_inputs[file.path] = true end
        end
    end
    input.native_policy = { backend = policy.backend, cacheable = policy.cacheable,
        files = policy.files and certificate.files(context, policy.files) or nil }
    return { key = key, directory = directory, synthetic_directory = paths.join(directory, "synthetic"),
        record = paths.join(directory, "record"), input = incremental.digest(context, "final-link", input),
        recipe = input, outputs = outputs, native_policy = policy, cacheable = policy.cacheable,
        dependency_argv = policy.argv,
        dependency_output = policy.capture_trace and policy.dependency_file or nil }
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
    local removed, remove_error = context.io:unlink(ticket.record)
    if removed then incremental.invalidate_file(context, ticket.record) end
    return removed, remove_error
end

function certificate.commit(context, ticket)
    -- Call only after the complete validated output set has been published.
    -- Re-observe every input rather than trusting the pre-link memo: only an
    -- input whose precise observation changed is reread and rehashed, and the
    -- freshly published outputs are hashed once to record them.
    local current = incremental.fresh_context(context)
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
