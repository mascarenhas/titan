
local cpp = {}

local typed = require("c-parser.typed")
local c99 = require("c-parser.c99")
local sha256 = require("titan-compiler.sha256")
local compiler_io = require("titan-compiler.io")

-- Standalone c-parser callers retain the ordinary synchronous behavior. The
-- compiler driver passes its resolver-context strategy explicitly, so every
-- language-server path uses the same Titan-backed object instead.
local default_io = compiler_io.new_sync()

local SEP = package.config:sub(1,1)

local function path_join(directory, name)
    if directory:sub(-1) == SEP then return directory .. name end
    return directory .. SEP .. name
end

function cpp.absolute_lookup_path(path, cwd)
    if path:sub(1, 1) ~= SEP then path = path_join(cwd, path) end
    -- Remove only standalone '.' components. Preserve separator runs and,
    -- critically, every '..' and symbolic-link component: in
    -- link/../header.h the kernel follows link before applying '..', and a
    -- later restat must traverse that same link again so retargeting it
    -- invalidates the recorded header world.
    local output = {}
    local pending_separators = ""
    local index = 1
    while index <= #path do
        if path:sub(index, index) == SEP then
            local finish = index + 1
            while finish <= #path and path:sub(finish, finish) == SEP do
                finish = finish + 1
            end
            pending_separators = path:sub(index, finish - 1)
            index = finish
        else
            local finish = index + 1
            while finish <= #path and path:sub(finish, finish) ~= SEP do
                finish = finish + 1
            end
            local component = path:sub(index, finish - 1)
            if component == "." then
                local separator_finish = finish
                while separator_finish <= #path and
                      path:sub(separator_finish, separator_finish) == SEP do
                    separator_finish = separator_finish + 1
                end
                local following = path:sub(finish, separator_finish - 1)
                -- Exactly two leading separators may name an
                -- implementation-defined namespace on POSIX. A leading dot
                -- must neither promote '/' to '//' nor demote '//' to a
                -- longer run.
                if #output > 0 and #following > #pending_separators then
                    pending_separators = following
                end
                index = separator_finish
            else
                output[#output + 1] = pending_separators
                output[#output + 1] = component
                pending_separators = ""
                index = finish
            end
        end
    end
    output[#output + 1] = pending_separators
    return table.concat(output)
end

local function io_for(options)
    return options and options.io or default_io
end

local function read_file_contents(filename, strategy)
    return strategy:read_file(filename)
end

local function attribute_identity(attributes)
    if not attributes then return "missing" end
    local kind = attributes.kind == "symlink" and "link" or attributes.kind
    return table.concat({
        tostring(kind), tostring(attributes.mode),
        tostring(attributes.device), tostring(attributes.inode),
    }, ":")
end

local function search_candidate_openable(path, strategy)
    return strategy:readable(path)
end

function cpp.header_search_identity(path, openable, strategy)
    strategy = strategy or default_io
    if openable == nil then
        openable = search_candidate_openable(path, strategy)
    end
    local link = strategy:lstat(path)
    local followed = strategy:stat(path)
    return table.concat({
        "c-header-search-v1", "lstat=" .. attribute_identity(link),
        "stat=" .. attribute_identity(followed),
        "open=" .. (openable and "readable" or "unreadable"),
    }, ";")
end

function cpp.header_file_identity(contents, path, strategy)
    strategy = strategy or default_io
    local followed = strategy:stat(path)
    return "c-header-file-v1:sha256:" .. sha256.hex(contents) ..
        ";stat=" .. attribute_identity(followed)
end

function cpp.header_input_identity(kind, path, strategy)
    strategy = strategy or default_io
    if kind == "file" then
        local contents, err = read_file_contents(path, strategy)
        if not contents then
            return "c-header-file-v1:unreadable:" ..
                cpp.header_search_identity(path, nil, strategy), err
        end
        return cpp.header_file_identity(contents, path, strategy)
    elseif kind == "search" then
        return cpp.header_search_identity(path, nil, strategy)
    end
    return nil, "C header input kind must be 'file' or 'search'"
end

local function debug() end
--[[
local inspect = require("inspect")
local function debug(...)
    local args = { ... }
    for i, arg in ipairs(args) do
        if type(arg) == "table" then
            args[i] = inspect(arg)
        end
    end
    print(table.unpack(args))
end

local function is_sequence(xs)
   if type(xs) ~= "table" then
      return false
   end
   local l = #xs
   for k, _ in pairs(xs) do
      if type(k) ~= "number" or k < 1 or k > l or math.floor(k) ~= k then
         return false
      end
   end
   return true
end
--]]

-- The real C compiler is the authority for both include search and predefined
-- macros. Keep all shell handling here: callers pass parsed flag arrays, while
-- CC may be either an argv array or the conventional shell-word string.

function cpp.split_shell_words(input)
    if type(input) ~= "string" then
        return nil, "shell words must be a string"
    end
    if input:find("\0", 1, true) then
        return nil, "shell words contain a NUL byte"
    end

    local words = {}
    local word = {}
    local started = false
    local mode = "plain"
    local i = 1
    while i <= #input do
        local ch = input:sub(i, i)
        if mode == "plain" then
            if ch:match("%s") then
                if started then
                    table.insert(words, table.concat(word))
                    word = {}
                    started = false
                end
            elseif ch == "'" then
                mode = "single"
                started = true
            elseif ch == '"' then
                mode = "double"
                started = true
            elseif ch == "\\" then
                i = i + 1
                if i > #input then
                    return nil, "trailing backslash in shell words"
                end
                table.insert(word, input:sub(i, i))
                started = true
            else
                table.insert(word, ch)
                started = true
            end
        elseif mode == "single" then
            if ch == "'" then
                mode = "plain"
            else
                table.insert(word, ch)
            end
        else
            if ch == '"' then
                mode = "plain"
            elseif ch == "\\" then
                local nextch = input:sub(i + 1, i + 1)
                if nextch == "" then
                    return nil, "trailing backslash in double-quoted shell word"
                end
                if nextch == "$" or nextch == "`" or nextch == '"'
                or nextch == "\\" or nextch == "\n" then
                    i = i + 1
                    if nextch ~= "\n" then
                        table.insert(word, nextch)
                    end
                else
                    table.insert(word, ch)
                end
            else
                table.insert(word, ch)
            end
        end
        i = i + 1
    end

    if mode == "single" then
        return nil, "unterminated single quote in shell words"
    elseif mode == "double" then
        return nil, "unterminated double quote in shell words"
    end
    if started then
        table.insert(words, table.concat(word))
    end
    return words
end

function cpp.shell_quote(word)
    if type(word) ~= "string" then
        return nil, "shell argument must be a string"
    end
    if word:find("\0", 1, true) then
        return nil, "shell argument contains a NUL byte"
    end
    return "'" .. word:gsub("'", "'\\''") .. "'"
end

local function copy_map(t)
    local u = {}
    for k, v in pairs(t) do
        u[k] = v
    end
    return u
end

-- Preprocessing token arrays carry spacing and raw-spelling provenance in
-- weak side tables. Define them before context construction so any graph
-- copied out of the probe cache can preserve that metadata as well as the
-- ordinary Lua table contents.
local pp_spacing = setmetatable({}, { __mode = "k" })
local pp_raw_spelling = setmetatable({}, { __mode = "k" })

local function clone_graph(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end

    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[clone_graph(key, seen)] = clone_graph(item, seen)
    end
    local metatable = getmetatable(value)
    if type(metatable) == "table" then
        setmetatable(copy, clone_graph(metatable, seen))
    end
    local spacing = pp_spacing[value]
    if spacing then pp_spacing[copy] = clone_graph(spacing, seen) end
    local raw_spelling = pp_raw_spelling[value]
    if raw_spelling then
        pp_raw_spelling[copy] = clone_graph(raw_spelling, seen)
    end
    return copy
end


function cpp.clone_graph(value)
    return clone_graph(value)
end


local function graph_weight(value, seen)
    local kind = type(value)
    if kind ~= "table" and kind ~= "string" then return 0 end
    if kind == "string" then
        -- Long Lua strings are not interned, so equal spellings may still be
        -- distinct retained allocations. Charge every occurrence to keep the
        -- budget conservative; repeated interned short strings merely make
        -- the estimate safer.
        return 25 + #value
    end
    seen = seen or {}
    if seen[value] then return 0 end
    seen[value] = true

    local weight = 56
    for key, item in pairs(value) do
        weight = weight + 32
            + graph_weight(key, seen)
            + graph_weight(item, seen)
    end
    local metatable = getmetatable(value)
    if type(metatable) == "table" then
        weight = weight + graph_weight(metatable, seen)
    end
    local spacing = pp_spacing[value]
    if spacing then weight = weight + graph_weight(spacing, seen) end
    local raw_spelling = pp_raw_spelling[value]
    if raw_spelling then
        weight = weight + graph_weight(raw_spelling, seen)
    end
    return weight
end


function cpp.graph_weight(value)
    return graph_weight(value)
end

local function copy_incdirs(incdirs)
    local copy = { quote = {}, system = {} }
    for _, mode in ipairs({ "quote", "system" }) do
        for _, dir in ipairs(incdirs[mode] or {}) do
            table.insert(copy[mode], dir)
        end
    end
    return copy
end

local function normalize_argv(value, name, string_is_shell_words)
    if value == nil then
        return {}
    end
    if type(value) == "string" then
        if not string_is_shell_words then
            return nil, name .. " must be a parsed argument array"
        end
        local argv, err = cpp.split_shell_words(value)
        if not argv then
            return nil, "invalid " .. name .. ": " .. err
        end
        value = argv
    end
    if type(value) ~= "table" then
        return nil, name .. " must be an argument array"
    end

    local argv = {}
    for i = 1, #value do
        local arg = value[i]
        if type(arg) ~= "string" then
            return nil, name .. " argument " .. i .. " must be a string"
        end
        if arg:find("\0", 1, true) then
            return nil, name .. " argument " .. i .. " contains a NUL byte"
        end
        argv[i] = arg
    end
    for k in pairs(value) do
        if type(k) ~= "number" or k < 1 or k > #value
        or k % 1 ~= 0 then
            return nil, name .. " must be a dense argument array"
        end
    end
    return argv
end

local function normalize_toolchain(options)
    options = options or {}
    if type(options) ~= "table" then
        return nil, "preprocessor options must be a table"
    end

    local compiler, err = normalize_argv(
        options.compiler or os.getenv("CC") or "cc", "compiler", true)
    if not compiler then
        return nil, err
    elseif #compiler == 0 then
        return nil, "compiler command is empty"
    end

    local cppflags
    cppflags, err = normalize_argv(options.cppflags, "cppflags", false)
    if not cppflags then
        return nil, err
    end
    local compile_flags
    compile_flags, err =
        normalize_argv(options.compile_flags, "compile flags", false)
    if not compile_flags then
        return nil, err
    end

    local fixed_include_dirs
    fixed_include_dirs, err = normalize_argv(
        options.fixed_include_dirs, "fixed include dirs", false)
    if not fixed_include_dirs then
        return nil, err
    end

    local language_mode = options.language_mode or "c99"
    if type(language_mode) ~= "string"
    or not language_mode:match("^[%w%+_.-]+$") then
        return nil, "invalid C language mode"
    end
    local language_flag = options.language_flag
    if language_flag == nil then
        language_flag = "-std=" .. language_mode
    elseif language_flag ~= false and
           (type(language_flag) ~= "string" or language_flag == "" or
            language_flag:find("[\r\n%z]")) then
        return nil, "language flag must be false or a nonempty single-line string"
    end

    return {
        io = io_for(options),
        compiler = compiler,
        language_mode = language_mode,
        language_flag = language_flag,
        compile_flags = compile_flags,
        cppflags = cppflags,
        fixed_include_dirs = fixed_include_dirs,
    }
end

local function append_argv(dst, src)
    for _, arg in ipairs(src) do
        table.insert(dst, arg)
    end
end

local function shell_command(argv)
    local quoted = {}
    for i, arg in ipairs(argv) do
        local q, err = cpp.shell_quote(arg)
        if not q then
            return nil, err
        end
        quoted[i] = q
    end
    return table.concat(quoted, " ")
end

-- Execute an already parsed argv through the one POSIX captured-command path
-- used by both preprocessing discovery and checker-side compile probes.
-- Callers receive process state rather than having an expected nonzero status
-- collapsed into a transport error.
function cpp.capture_command(argv, options)
    options = options or {}
    local normalized, normalize_err =
        normalize_argv(argv, "command", false)
    if not normalized then
        return {
            started = false,
            ok = false,
            diagnostic = normalize_err,
        }
    elseif #normalized == 0 then
        return {
            started = false,
            ok = false,
            diagnostic = "command is empty",
        }
    end

    return io_for(options):run(normalized, {
        stderr_to_stdout = options.stderr_to_stdout ~= false,
    })
end

local function run_command(argv, stderr_to_stdout, strategy)
    local result = cpp.capture_command(argv, {
        stderr_to_stdout = stderr_to_stdout,
        io = strategy,
    })
    if not result.started or not result.ok then
        return nil, ("command failed (%s %s): %s"):format(
            tostring(result.why or "spawn"),
            tostring(result.status or "?"),
            result.diagnostic or "")
    end
    return result.output
end

local function config_argv(config)
    local argv = {}
    append_argv(argv, config.compiler)
    append_argv(argv, config.compile_flags)
    append_argv(argv, config.cppflags)
    -- Match generated/runtime compilation: user CPP flags precede Titan's
    -- fixed language/default flags, so the fixed C99 mode wins if a caller
    -- accidentally supplies another -std option in the CPP channel.
    if config.language_flag then
        table.insert(argv, config.language_flag)
    end
    for _, dir in ipairs(config.fixed_include_dirs) do
        append_argv(argv, { "-I", dir })
    end
    return argv
end

local function key_argv(argv)
    local parts = {}
    for _, arg in ipairs(argv) do
        table.insert(parts, #arg .. ":" .. arg)
    end
    return table.concat(parts, "|")
end

local function append_canonical(parts, value, active)
    local kind = type(value)
    parts[#parts + 1] = kind
    if kind ~= "table" then
        parts[#parts + 1] = tostring(value)
        return
    end
    if active[value] then
        error("cyclic configured preprocessor context", 2)
    end
    active[value] = true
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(left, right)
        local left_kind, right_kind = type(left), type(right)
        if left_kind ~= right_kind then return left_kind < right_kind end
        if left_kind == "number" then return left < right end
        return tostring(left) < tostring(right)
    end)
    parts[#parts + 1] = tostring(#keys)
    for _, key in ipairs(keys) do
        append_canonical(parts, key, active)
        append_canonical(parts, value[key], active)
    end
    local spacing = pp_spacing[value]
    parts[#parts + 1] = spacing and "spacing" or "no-spacing"
    if spacing then append_canonical(parts, spacing, active) end
    local raw_spelling = pp_raw_spelling[value]
    parts[#parts + 1] = raw_spelling and "raw-spelling" or "no-raw-spelling"
    if raw_spelling then
        append_canonical(parts, raw_spelling, active)
    end
    active[value] = nil
end

-- Include both what the configured compiler was asked and the authoritative
-- include/macro world it reported. The latter makes cdriver's higher-level
-- cache key describe C interpretation inputs, not merely an argv spelling.
local function preprocessor_semantic_digest(incdirs, defines)
    local parts = { "titan-cpp-semantic-context-v1" }
    append_canonical(parts, incdirs, {})
    append_canonical(parts, defines, {})
    return "sha256:" .. sha256.hex(key_argv(parts))
end

-- A process may host more than one compiler context (the language server does
-- so across project reloads). Probe results are valid only for the strategy
-- which observed the command and forced-header inputs.
local probe_caches = setmetatable({}, { __mode = "k" })

local function probe_cache_for(strategy)
    local cache = probe_caches[strategy]
    if not cache then
        cache = {}
        probe_caches[strategy] = cache
    end
    return cache
end

local function copy_config(config)
    return {
        io = config.io,
        compiler = { table.unpack(config.compiler) },
        language_mode = config.language_mode,
        language_flag = config.language_flag,
        compile_flags = { table.unpack(config.compile_flags) },
        cppflags = { table.unpack(config.cppflags) },
        fixed_include_dirs = { table.unpack(config.fixed_include_dirs) },
    }
end

local function opaque_preprocessor_argument(argument)
    if argument:sub(1, 1) == "@" then
        return "response-file argument '" .. argument .. "'"
    elseif argument:sub(1, 4) == "-Wp," then
        return "preprocessor pass-through argument '" .. argument .. "'"
    elseif argument == "-Xpreprocessor" then
        return "preprocessor pass-through argument '-Xpreprocessor'"
    elseif argument == "-include-pch" or argument == "-include-pth" then
        return "opaque forced-header argument '" .. argument .. "'"
    end
end

local function scan_forced_arguments(arguments, first, channel,
                                     imacros, includes)
    local stripped = {}
    for index = 1, first - 1 do stripped[index] = arguments[index] end
    local index = first
    while index <= #arguments do
        local argument = arguments[index]
        local opaque = opaque_preprocessor_argument(argument)
        if opaque then
            return nil, "cannot track forced C headers hidden by " .. opaque ..
                " in " .. channel
        end

        local kind
        local operand
        if argument == "-include" or argument == "-imacros" then
            kind = argument == "-include" and "include" or "imacros"
            index = index + 1
            operand = arguments[index]
            if operand == nil then
                return nil, argument .. " in " .. channel ..
                    " requires a header operand"
            end
        elseif argument:sub(1, 8) == "-include" and #argument > 8 then
            kind = "include"
            operand = argument:sub(9)
        elseif argument:sub(1, 8) == "-imacros" and #argument > 8 then
            kind = "imacros"
            operand = argument:sub(9)
        else
            stripped[#stripped + 1] = argument
        end

        if kind then
            if operand == "" then
                return nil, "-" .. kind .. " in " .. channel ..
                    " requires a nonempty header operand"
            end
            local item = {
                kind = kind,
                operand = operand,
                channel = channel,
            }
            if kind == "imacros" then
                imacros[#imacros + 1] = item
            else
                includes[#includes + 1] = item
            end
        end
        index = index + 1
    end
    return stripped
end

local function forced_configuration(config)
    local stripped = copy_config(config)
    local imacros = {}
    local includes = {}
    local value, err = scan_forced_arguments(
        config.compiler, 2, "compiler command", imacros, includes)
    if not value then return nil, err end
    stripped.compiler = value
    value, err = scan_forced_arguments(
        config.compile_flags, 1, "compile flags", imacros, includes)
    if not value then return nil, err end
    stripped.compile_flags = value
    value, err = scan_forced_arguments(
        config.cppflags, 1, "CPP flags", imacros, includes)
    if not value then return nil, err end
    stripped.cppflags = value

    local forced = {}
    -- GCC and Clang process every -imacros occurrence before every -include
    -- occurrence, while preserving order within each class.
    append_argv(forced, imacros)
    append_argv(forced, includes)
    return {
        original = config,
        stripped = stripped,
        forced = forced,
    }
end

local function probe_include_paths(config)
    local argv = config_argv(config)
    append_argv(argv, { "-E", "-v", "-x", "c", "/dev/null", "-o", "/dev/null" })
    local output, err = run_command(argv, true, config.io)
    if not output then
        return nil, "failed probing C include search: " .. err
    end

    local paths = { quote = {}, system = {} }
    local mode
    for line in (output .. "\n"):gmatch("(.-)\n") do
        if line:find([[#include "..." search starts here]], 1, true) then
            mode = "quote"
        elseif line:find([[#include <...> search starts here]], 1, true) then
            mode = "system"
        elseif line:find([[End of search list]], 1, true) then
            mode = nil
        elseif mode then
            local path = line:gsub("^%s+", "")
                :gsub("%s+%(framework directory%)$", "")
            if path ~= "" then
                table.insert(paths[mode], path)
            end
        end
    end
    return paths
end

local function parse_macro_dump(output, strategy)
    local blank_ctx = {
        io = strategy,
        incdirs = {},
        defines = {},
        macro_changes = {},
        ifmode = { true },
        output = {},
        output_origins = {},
        current_dir = {},
    }
    typed.set_type(blank_ctx, "Ctx")
    local ctx, err
    ctx, err = cpp.parse_contents("-", output, blank_ctx)
    if not ctx then
        return nil, "failed parsing compiler macro output: " .. err
    end

    ctx.defines["__builtin_va_list"] = { "char", "*" }
    ctx.defines["__extension__"] = {}
    ctx.defines["__attribute__"] = { args = { "arg" }, repl = {} }
    ctx.defines["__restrict__"] = { "restrict" }
    ctx.defines["__restrict"] = { "restrict" }
    ctx.defines["__inline__"] = { "inline" }
    ctx.defines["__inline"] = { "inline" }
    return ctx.defines
end

local function probe_macro_definitions(config, source)
    local argv = config_argv(config)
    append_argv(argv, { "-dM", "-E", "-x", "c", source })
    local output, err = run_command(argv, false, config.io)
    if not output then
        return nil, "failed probing C macros for '" .. source .. "': " .. err
    end
    return parse_macro_dump(output, config.io)
end

local function probe_default_defines(config)
    return probe_macro_definitions(config, "/dev/null")
end

local function base_probe(config)
    local key = "base|" .. key_argv(config_argv(config))
    local probe_cache = probe_cache_for(config.io)
    local probed = probe_cache[key]
    if probed then return probed end
    local incdirs, err = probe_include_paths(config)
    if not incdirs then return nil, err end
    local defines
    defines, err = probe_default_defines(config)
    if not defines then return nil, err end
    probed = { incdirs = incdirs, defines = defines }
    probe_cache[key] = probed
    return probed
end

local function append_manifest(parts, label, ...)
    parts[#parts + 1] = label
    for index = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(index, ...))
    end
end

local function truncate_array(values, length)
    for index = #values, length + 1, -1 do values[index] = nil end
end

local function forced_header_candidates(operand, cwd, incdirs)
    if operand:sub(1, 1) == SEP then
        return { cpp.absolute_lookup_path(operand, cwd) }
    end
    local candidates = {
        cpp.absolute_lookup_path(operand, cwd),
    }
    for _, directory in ipairs(incdirs.quote or {}) do
        candidates[#candidates + 1] =
            cpp.absolute_lookup_path(path_join(directory, operand), cwd)
    end
    for _, directory in ipairs(incdirs.system or {}) do
        candidates[#candidates + 1] =
            cpp.absolute_lookup_path(path_join(directory, operand), cwd)
    end
    return candidates
end

local function scan_forced_headers(forced, incdirs, base_defines, cwd,
                                   strategy)
    local dependencies = {}
    local dependency_identities = {}
    local search_inputs = {}
    local search_identities = {}
    local manifest = { "titan-forced-c-headers-v1" }
    local ctx = {
        io = strategy,
        incdirs = copy_incdirs(incdirs),
        defines = copy_map(base_defines),
        macro_changes = {},
        ifmode = { true },
        output = {},
        output_origins = {},
        current_dir = {},
    }
    typed.set_type(ctx, "Ctx")

    ctx.header_dependency_observer = function(path, contents)
        path = cpp.absolute_lookup_path(path, cwd)
        local identity = cpp.header_file_identity(contents, path, strategy)
        append_manifest(manifest, "file", path, identity)
        local previous = dependency_identities[path]
        if previous and previous ~= identity then
            return nil, "forced C header changed while it was parsed: " .. path
        elseif not previous then
            dependency_identities[path] = identity
            dependencies[#dependencies + 1] = {
                kind = "file", path = path, identity = identity,
            }
        end
        return true
    end
    ctx.include_search_observer = function(path, openable)
        path = cpp.absolute_lookup_path(path, cwd)
        local identity = cpp.header_search_identity(path, openable, strategy)
        append_manifest(manifest, "search", path, identity)
        local previous = search_identities[path]
        if previous and previous ~= identity then
            return nil, "forced C include candidate changed while it " ..
                "was searched: " .. path
        elseif not previous then
            search_identities[path] = identity
            search_inputs[#search_inputs + 1] = {
                kind = "search", path = path, identity = identity,
            }
        end
        return true
    end

    for _, item in ipairs(forced) do
        append_manifest(manifest, "option", item.kind, item.operand)
        local selected
        local selected_contents
        local open_error
        for _, candidate in ipairs(
                forced_header_candidates(item.operand, cwd, incdirs)) do
            local contents, err = strategy:read_file(candidate)
            local observed, observe_err =
                ctx.include_search_observer(candidate, contents ~= nil)
            if not observed then
                return nil, observe_err
            end
            if contents then
                selected = candidate
                selected_contents = contents
                break
            end
            open_error = err
        end
        if not selected then
            return nil, "forced C header '" .. item.operand ..
                "' is missing or unreadable" ..
                (open_error and ": " .. tostring(open_error) or "")
        end

        local output_length = #ctx.output
        local origins_length = #ctx.output_origins
        local parsed, parse_error =
            cpp.parse_contents(selected, selected_contents, ctx)
        if not parsed then
            return nil, "failed preprocessing forced C header '" ..
                item.operand .. "': " .. tostring(parse_error)
        end
        if item.kind == "imacros" then
            truncate_array(ctx.output, output_length)
            truncate_array(ctx.output_origins, origins_length)
        end
    end

    ctx.header_dependency_observer = nil
    ctx.include_search_observer = nil
    return {
        dependencies = dependencies,
        search_inputs = search_inputs,
        manifest = key_argv(manifest),
        output = ctx.output,
        output_origins = ctx.output_origins,
        macro_changes = ctx.macro_changes,
        scanned_defines = ctx.defines,
    }
end

local function inspect_forced_configuration(configuration)
    if #configuration.forced == 0 then
        return {
            dependencies = {},
            search_inputs = {},
            manifest = key_argv({ "titan-forced-c-headers-v1", "none" }),
            output = {},
            output_origins = {},
            macro_changes = {},
        }
    end

    local cwd, cwd_error = configuration.original.io:cwd()
    if not cwd then
        return nil, "failed determining cwd for forced C headers: " ..
            tostring(cwd_error)
    end
    local base, err = base_probe(configuration.stripped)
    if not base then return nil, err end
    local scanned
    scanned, err = scan_forced_headers(
        configuration.forced, base.incdirs, base.defines, cwd,
        configuration.original.io)
    if not scanned then return nil, err end
    scanned.incdirs = copy_incdirs(base.incdirs)
    scanned.base_defines = copy_map(base.defines)
    return scanned
end

function cpp.inspect_forced_headers(options)
    local config, err = normalize_toolchain(options)
    if not config then return nil, err end
    local configuration
    configuration, err = forced_configuration(config)
    if not configuration then return nil, err end
    local inspected
    inspected, err = inspect_forced_configuration(configuration)
    if not inspected then return nil, err end
    return inspected
end

function cpp.new_context(options)
    local config, err = normalize_toolchain(options)
    if not config then
        return nil, err
    end

    local configuration
    configuration, err = forced_configuration(config)
    if not configuration then return nil, err end
    local forced
    forced, err = inspect_forced_configuration(configuration)
    if not forced then return nil, err end

    local key = "final|" .. key_argv(config_argv(config)) ..
        "|forced=" .. forced.manifest
    local probe_cache = probe_cache_for(config.io)
    local probed = probe_cache[key]
    if not probed then
        local incdirs
        if #configuration.forced == 0 then
            incdirs, err = probe_include_paths(config)
            if not incdirs then return nil, err end
        else
            incdirs = forced.incdirs
        end
        local defines
        defines, err = probe_default_defines(config)
        if not defines then return nil, err end

        if #configuration.forced > 0 then
            local stable
            stable, err = inspect_forced_configuration(configuration)
            if not stable then return nil, err end
            if stable.manifest ~= forced.manifest then
                return nil, "forced C headers changed while probing the " ..
                    "configured preprocessor"
            end
            forced = stable
        end
        probed = {
            incdirs = incdirs,
            defines = defines,
            semantic_digest =
                preprocessor_semantic_digest(incdirs, defines),
        }
        probe_cache[key] = probed
    end

    local ctx = {
        io = config.io,
        incdirs = copy_incdirs(probed.incdirs),
        defines = clone_graph(probed.defines),
        macro_changes = copy_map(forced.macro_changes),
        ifmode = { true },
        output = { table.unpack(forced.output) },
        output_origins = { table.unpack(forced.output_origins) },
        current_dir = {},
        -- cdriver caches completed header interpretation across resolver
        -- contexts owned by the same I/O provider. Publish the exact ordered
        -- compiler argv plus the forced-header world used to construct this
        -- context, and retain language_mode even when a caller deliberately
        -- suppresses the synthesized -std flag.
        preprocessor_configuration_key = key_argv({
            "titan-cpp-context-v1", config.language_mode, key,
            probed.semantic_digest,
        }),
        forced_header_dependencies = forced.dependencies,
        forced_header_search_inputs = forced.search_inputs,
        forced_header_manifest = forced.manifest,
    }
    typed.set_type(ctx, "Ctx")
    return ctx
end

-- Test and embedding hook: cached probe results are otherwise process-lifetime.
function cpp.clear_probe_cache()
    probe_caches = setmetatable({}, { __mode = "k" })
end

-- Not supported:
-- * character set conversion
-- * trigraphs

local states = {
    any = {
        ['"'] = { next = "dquote" },
        ["'"] = { next = "squote" },
        ["/"] = { silent = true, next = "slash" },
    },
    dquote = {
        ['"'] = { next = "any" },
        ["\\"] = { next = "dquote_backslash" },
    },
    dquote_backslash = {
        single_char = true,
        default = { next = "dquote" },
    },
    squote = {
        ["'"] = { next = "any" },
        ["\\"] = { next = "squote_backslash" },
    },
    squote_backslash = {
        single_char = true,
        default = { next = "squote" },
    },
    slash = {
        single_char = true,
        ["/"] = { add = " ", silent = true, next = "line_comment" },
        ["*"] = { add = " ", silent = true, next = "block_comment" },
        default = { add = "/", next = "any" },
    },
    line_comment = {
        silent = true,
    },
    block_comment = {
        silent = true,
        ["*"] = { silent = true, next = "try_end_block_comment" },
        continue_line = "block_comment",
    },
    try_end_block_comment = {
        single_char = true,
        silent = true,
        ["/"] = { silent = true, next = "any" },
        ["*"] = { silent = true, next = "try_end_block_comment" },
        default = { silent = true, next = "block_comment" },
        continue_line = "block_comment",
    },
}

for _, rules in pairs(states) do
    local out = "["
    for k, _ in pairs(rules) do
        if #k == 1 then
            out = out .. k
        end
    end
    out = out .. "]"
    rules.pattern = out ~= "[]" and out
end

local function add(buf, txt)
    if not buf then
        buf = {}
    end
    table.insert(buf, txt)
    return buf
end

local function initial_processing_contents(contents)
    local backslash_buf
    local buf
    local state = "any"
    local output = {}
    local linenr = 0

    -- Run the comment/string state machine over one complete logical line
    -- (backslash-continuations already merged) and append the result to
    -- `output`. `buf` and `state` persist across calls so a block comment can
    -- span several logical lines (states[state].continue_line).
    local function flush_logical_line(line, nr)
        local len = #line
        local i = 1
        local out = ""
        -- Go through the line
        while i <= len do
            -- Current state in the state machine
            local st = states[state]

            -- Look for next character matching a state transition
            local n = nil
            if st.pattern then
                if st.single_char then
                    if line:sub(i,i):find(st.pattern) then
                        n = i
                    end
                else
                    n = line:find(st.pattern, i)
                end
            end

            local transition, ch
            if n then
                ch = line:sub(n, n)
                transition = st[ch]
            else
                n = i
                ch = line:sub(n, n)
                transition = st.default
            end

            if not transition then
                -- output the rest of the string if we should
                if not st.silent then
                    out = i == 1 and line or line:sub(i)
                end
                break
            end

            -- output everything up to the transition if we should
            if n > i and not st.silent then
                buf = add(buf, line:sub(i, n - 1))
            end

            -- Some transitions output an explicit character
            if transition.add then
                buf = add(buf, transition.add)
            end

            if not transition.silent then
                buf = add(buf, ch)
            end

            -- and move to the next state
            state = transition.next
            i = n + 1
        end

        -- A '/' at the very end of a logical line was consumed into the 'slash'
        -- lookahead but never emitted; it cannot begin a comment (the next char
        -- is on a different logical line), so it is a division operator. Emit it
        -- rather than dropping it.
        if state == "slash" then
            out = out .. "/"
            state = "any"
        end

        -- If we ended in a non-line-terminating state
        if states[state].continue_line then
            -- buffer the output and keep going
            buf = add(buf, out)
            state = states[state].continue_line
        else
            -- otherwise, flush the buffer
            if buf then
                table.insert(buf, out)
                out = table.concat(buf)
                buf = nil
            end
            -- output the string and reset the state.
            table.insert(output, { nr = nr, line = out})
            state = "any"
        end
    end

    local input_offset = 1
    while input_offset <= #contents do
        local newline = contents:find("\n", input_offset, true)
        local input_line
        if newline then
            input_line = contents:sub(input_offset, newline - 1)
            input_offset = newline + 1
        else
            input_line = contents:sub(input_offset)
            input_offset = #contents + 1
        end
        -- for-loop control variables are read-only in Lua 5.5
        local line = input_line
        linenr = linenr + 1
        -- Normalize CRLF: a physical line read in binary mode keeps its trailing
        -- '\r', which would both hide a backslash-continuation (the '\' is no
        -- longer the last character) and leak a stray '\r' into the tokens.
        if line:sub(-1) == "\r" then
            line = line:sub(1, -2)
        end
        local len = #line
        if line:find("\\", len, true) then
            -- If backslash-terminated, buffer it
            backslash_buf = add(backslash_buf, line:sub(1, len - 1))
        else
            -- Merge backslash-terminated line
            if backslash_buf then
                table.insert(backslash_buf, line)
                line = table.concat(backslash_buf)
            end
            backslash_buf = nil
            flush_logical_line(line, linenr)
        end
    end

    -- EOF housekeeping so trailing code is never silently dropped: a file ending
    -- with a backslash-continuation leaves text in backslash_buf, and a file
    -- ending inside a block comment (or any continue_line state) leaves text in
    -- buf. Flush both.
    if backslash_buf then
        flush_logical_line(table.concat(backslash_buf), linenr)
    end
    if buf then
        table.insert(output, { nr = linenr, line = table.concat(buf) })
        buf = nil
    end

    typed.set_type(output, "LineList")
    return output
end

cpp.initial_processing = typed("FILE* -> LineList", function(fd)
    local contents, err = fd:read("a")
    fd:close()
    if not contents then error(err) end
    return initial_processing_contents(contents)
end)

-- Stringification needs the spelling relationship between adjacent
-- preprocessing tokens, not merely the tokens themselves: `a+b` must become
-- `"a+b"`, while `a /* comment */ + b` must become `"a + b"`. Keep that
-- small amount of provenance out-of-band so the parser and the rest of the
-- preprocessor can continue to use ordinary string arrays. Raw spelling is
-- separate because C digraphs behave canonically during expansion but retain
-- their original spelling under `#`.
local pp_token_spellings = {
    ["##"] = { "##", "%:%:" },
    ["#"] = { "#", "%:" },
    ["["] = { "[", "<:" },
    ["]"] = { "]", ":>" },
    ["{"] = { "{", "<%" },
    ["}"] = { "}", "%>" },
}

local function token_spellings(token)
    return pp_token_spellings[token] or { token }
end

local function match_token_forward(line, pos, token)
    for _, spelling in ipairs(token_spellings(token)) do
        if line:sub(pos, pos + #spelling - 1) == spelling then
            return pos + #spelling, spelling
        end
    end
    return nil
end

local function match_token_backward(line, last, token)
    for _, spelling in ipairs(token_spellings(token)) do
        local first = last - #spelling + 1
        if first >= 1 and line:sub(first, last) == spelling then
            return first, spelling
        end
    end
    return nil
end

local function record_full_spacing(tokens, line)
    local spacing = {}
    local raw = {}
    local pos = 1
    for i, token in ipairs(tokens) do
        local whitespace_start = pos
        while pos <= #line and line:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
        spacing[i] = pos > whitespace_start
        local nextpos, spelling = match_token_forward(line, pos, token)
        if not nextpos then
            return
        end
        pos = nextpos
        raw[i] = spelling
    end
    if line:sub(pos):find("%S") then
        return
    end
    pp_spacing[tokens] = spacing
    pp_raw_spelling[tokens] = raw
end

-- Directive replacement/expression lists are suffixes of their logical line.
-- Match from the end so repeated identifiers in the macro header cannot be
-- mistaken for replacement-list tokens.
local function record_suffix_spacing(tokens, line)
    local first, last = {}, {}
    local raw = {}
    local pos = #line
    while pos >= 1 and line:sub(pos, pos):match("%s") do
        pos = pos - 1
    end
    for i = #tokens, 1, -1 do
        last[i] = pos
        first[i], raw[i] = match_token_backward(line, pos, tokens[i])
        if not first[i] then
            return
        end
        pos = first[i] - 1
        while pos >= 1 and line:sub(pos, pos):match("%s") do
            pos = pos - 1
        end
    end

    local spacing = {}
    spacing[1] = false
    for i = 2, #tokens do
        local gap = line:sub(last[i - 1] + 1, first[i] - 1)
        if gap:find("%S") then
            return
        end
        spacing[i] = #gap > 0
    end
    pp_spacing[tokens] = spacing
    pp_raw_spelling[tokens] = raw
end

local function token_has_space_before(tokens, i)
    local spacing = pp_spacing[tokens]
    return spacing and spacing[i] or false
end

local function set_token_spacing(tokens, spacing)
    pp_spacing[tokens] = spacing
end

local function token_raw_spelling(tokens, i)
    local raw = pp_raw_spelling[tokens]
    return raw and raw[i] or tokens[i]
end

local function append_token(tokens, token, has_space_before, raw_spelling)
    table.insert(tokens, token)
    local spacing = pp_spacing[tokens]
    if not spacing then
        spacing = {}
        pp_spacing[tokens] = spacing
    end
    spacing[#tokens] = has_space_before == true
    local raw = pp_raw_spelling[tokens]
    if not raw then
        raw = {}
        pp_raw_spelling[tokens] = raw
    end
    raw[#tokens] = raw_spelling or token
end

local function append_tokens(tokens, values, first_has_space_before)
    local value_spacing = pp_spacing[values]
    local value_raw = pp_raw_spelling[values]
    for i, token in ipairs(values) do
        local before
        if i == 1 then
            before = first_has_space_before
        elseif value_spacing then
            before = value_spacing[i]
        else
            -- A caller-created string array has lost its raw spelling. Keep
            -- its tokens separate rather than inventing adjacency.
            before = true
        end
        append_token(tokens, token, before,
            value_raw and value_raw[i] or token)
    end
end

cpp.tokenize = typed("string -> table", function(line)
    local tokens = c99.match_preprocessing_grammar(line)
    if not tokens then
        return tokens
    end

    if not tokens.directive then
        record_full_spacing(tokens, line)
    elseif tokens.directive == "define" and tokens.repl then
        record_suffix_spacing(tokens.repl, line)
    elseif (tokens.directive == "if" or tokens.directive == "elif")
    and tokens.exp then
        record_suffix_spacing(tokens.exp, line)
    end
    return tokens
end)

local function find_file(ctx, filename, mode, is_next)
    if filename:sub(1, 1) == SEP then
        local contents = ctx.io:read_file(filename)
        if contents then return filename, contents end
        return nil, nil, "file not found"
    end
    local paths = {}
    local current_dir = ctx.current_dir[#ctx.current_dir]
    if mode == "quote" or is_next then
        if not is_next then
            table.insert(paths, current_dir)
        end
        for _, incdir in ipairs(ctx.incdirs.quote or {}) do
            table.insert(paths, incdir)
        end
    end
    if mode == "system" or is_next then
        for _, incdir in ipairs(ctx.incdirs.system or {}) do
            table.insert(paths, incdir)
        end
    end
    if is_next then
        while paths[1] and paths[1] ~= current_dir do
            table.remove(paths, 1)
        end
        table.remove(paths, 1)
    end
    for _, path in ipairs(paths) do
        local pathname = path..SEP..filename
        local contents = ctx.io:read_file(pathname)
        if ctx.include_search_observer then
            local ok, observe_err =
                ctx.include_search_observer(pathname, contents ~= nil)
            if not ok then
                return nil, nil, observe_err, true
            end
        end
        if contents then
            return pathname, contents
        end
    end
    return nil, nil, "file not found"
end

local parse_expression = typed("{string} -> Exp?", function(tokens)
    local text = table.concat(tokens, " ")
    local exp = c99.match_preprocessing_expression_grammar(text)
    -- The caller reports a structured preprocessor syntax error. Never write
    -- parser failures directly: embeddings such as an LSP server reserve
    -- stdout for their transport framing.
    return exp
end)

-- C99 6.10.1 evaluates preprocessing integer expressions in the widest
-- signed/unsigned integer types (intmax_t/uintmax_t).  A Lua integer has the
-- right 64-bit representation for both, but needs an explicit signedness bit:
-- values in the upper half of uintmax_t otherwise become negative and break
-- comparisons, division, and right shifts.  Keep that distinction local to
-- the conditional-expression evaluator.
local function pp_integer(bits, unsigned)
    assert(math.type(bits) == "integer")
    return { bits = bits, unsigned = unsigned == true }
end

local function digit_value(byte)
    if byte >= 48 and byte <= 57 then return byte - 48 end
    if byte >= 65 and byte <= 70 then return byte - 65 + 10 end
    if byte >= 97 and byte <= 102 then return byte - 97 + 10 end
    return nil
end

-- Parse without routing through a Lua float.  Lua's integer arithmetic wraps
-- modulo 2^64, which gives us the exact uintmax_t bit pattern even for
-- UINT64_MAX.  Unsuffixed hexadecimal/octal constants whose high bit is set
-- select uintmax_t after the preprocessing integer-type mapping.
local function parse_integer_constant(spelling)
    local suffix = spelling:match("([uUlL]+)$") or ""
    local digits = spelling:sub(1, #spelling - #suffix)
    local base = 10
    local first = 1
    if digits:match("^0[xX]") then
        base = 16
        first = 3
    elseif #digits > 1 and digits:sub(1, 1) == "0" then
        base = 8
        first = 2
    end
    if first > #digits and digits ~= "0" then return nil end

    local bits = 0
    for index = first, #digits do
        local digit = digit_value(digits:byte(index))
        if digit == nil or digit >= base then return nil end
        bits = bits * base + digit
    end
    local unsigned = suffix:find("[uU]") ~= nil
    if not unsigned and bits < 0 then
        -- This is the uintmax_t candidate for a non-decimal constant.  Treat a
        -- too-large decimal constant the same way as the host compilers we
        -- support do as an extension, instead of losing precision in a float.
        unsigned = true
    end
    return pp_integer(bits, unsigned)
end

local simple_character_escapes = {
    a = 7, b = 8, f = 12, n = 10, r = 13, t = 9, v = 11,
    ["\\"] = 92, ["'"] = 39, ['"'] = 34, ["?"] = 63,
}

-- Character constants are permitted in #if expressions.  Their exact value
-- is implementation-defined for wide and multi-character spellings; use the
-- conventional execution-character-set/GCC packing used by Titan's supported
-- hosts, while handling the standard escapes exactly for ordinary ASCII.
local function parse_character_constant(spelling)
    local quote = spelling:find("'", 1, true)
    if not quote or spelling:sub(-1) ~= "'" then return nil end
    local body = spelling:sub(quote + 1, -2)
    local values = {}
    local index = 1
    while index <= #body do
        local byte = body:byte(index)
        if byte ~= 92 then
            values[#values + 1] = byte
            index = index + 1
        else
            index = index + 1
            local escape = body:sub(index, index)
            if escape == "" then return nil end
            local simple = simple_character_escapes[escape]
            if simple then
                values[#values + 1] = simple
                index = index + 1
            elseif escape == "x" then
                local value = 0
                local start = index + 1
                index = start
                while index <= #body do
                    local digit = digit_value(body:byte(index))
                    if digit == nil then break end
                    value = value * 16 + digit
                    index = index + 1
                end
                if index == start then return nil end
                values[#values + 1] = value
            elseif escape:match("[0-7]") then
                local value = 0
                local count = 0
                while index <= #body and count < 3 do
                    local digit = digit_value(body:byte(index))
                    if digit == nil or digit >= 8 then break end
                    value = value * 8 + digit
                    index = index + 1
                    count = count + 1
                end
                values[#values + 1] = value
            elseif escape == "u" or escape == "U" then
                local count = escape == "u" and 4 or 8
                local value = 0
                index = index + 1
                for _ = 1, count do
                    local digit = index <= #body and
                        digit_value(body:byte(index)) or nil
                    if digit == nil then return nil end
                    value = value * 16 + digit
                    index = index + 1
                end
                values[#values + 1] = value
            else
                -- C accepts implementation-defined escaped characters with a
                -- diagnostic.  Preserve their ordinary character value.
                values[#values + 1] = escape:byte()
                index = index + 1
            end
        end
    end
    if #values == 0 then return nil end

    local bits = 0
    for _, value in ipairs(values) do
        bits = (bits << 8) | value
    end
    return pp_integer(bits, false)
end

local function unsigned_less(left, right)
    return math.ult(left, right)
end

local function unsigned_less_equal(left, right)
    return left == right or unsigned_less(left, right)
end

-- Divide uintmax_t bit patterns exactly, without converting either operand to
-- double.  Each subtraction chooses the largest non-overflowing shifted
-- divisor no greater than the remaining dividend, so this is bounded by 64
-- outer and 64 inner iterations.
local function unsigned_divmod(numerator, denominator)
    if denominator == 0 then
        error("division by zero in preprocessor expression", 0)
    end
    local quotient = 0
    local remainder = numerator
    while not unsigned_less(remainder, denominator) do
        local divisor = denominator
        local quotient_bit = 1
        while unsigned_less_equal(divisor, remainder >> 1) do
            divisor = divisor << 1
            quotient_bit = quotient_bit << 1
        end
        remainder = remainder - divisor
        quotient = quotient | quotient_bit
    end
    return quotient, remainder
end

-- Lua's // rounds toward minus infinity; C integer division truncates toward
-- zero, and the remainder has the sign of the dividend.
local function signed_divmod(numerator, denominator)
    if denominator == 0 then
        error("division by zero in preprocessor expression", 0)
    end
    local quotient = numerator // denominator
    local remainder = numerator % denominator
    if remainder ~= 0 and ((numerator < 0) ~= (denominator < 0)) then
        quotient = quotient + 1
        remainder = numerator - quotient * denominator
    end
    return quotient, remainder
end

local function common_unsigned(left, right)
    return left.unsigned or right.unsigned
end

local function compare_less(left, right)
    if common_unsigned(left, right) then
        return unsigned_less(left.bits, right.bits)
    end
    return left.bits < right.bits
end

local function shift_count(value)
    if value.bits < 0 or value.bits >= 64 then
        error("invalid shift count in preprocessor expression", 0)
    end
    return value.bits
end

local function signed_right_shift(bits, count)
    if bits >= 0 or count == 0 then return bits >> count end
    -- Lua's >> is logical.  Complementing before and after it supplies the
    -- sign bits and matches the arithmetic right shift of supported hosts.
    return ~((~bits) >> count)
end

-- Determine only the intmax_t/uintmax_t result type of an expression.  This is
-- separate from evaluation because ?: applies the usual arithmetic conversion
-- to both operands while evaluating only the selected one; walking the type of
-- an unselected `1 / 0` must not perform that division.
local expression_is_unsigned
expression_is_unsigned = function(exp)
    if not exp.op then
        local spelling = exp[1]
        if spelling:match("^L?'") then return false end
        local integer = parse_integer_constant(spelling)
        return integer and integer.unsigned or false
    elseif exp.op == "+" or exp.op == "-" then
        if exp[2] then
            for _, operand in ipairs(exp) do
                if expression_is_unsigned(operand) then return true end
            end
            return false
        end
        return expression_is_unsigned(exp[1])
    elseif exp.op == "*" or exp.op == "/" or exp.op == "%" or
           exp.op == "&" or exp.op == "|" or exp.op == "^" then
        for _, operand in ipairs(exp) do
            if expression_is_unsigned(operand) then return true end
        end
        return false
    elseif exp.op == "<<" or exp.op == ">>" or exp.op == "~" then
        return expression_is_unsigned(exp[1])
    elseif exp.op == "?" then
        return expression_is_unsigned(exp[2]) or
            expression_is_unsigned(exp[3])
    end
    -- Relational, equality, logical, !, and defined all produce signed int.
    return false
end

local eval_exp
eval_exp = typed("Ctx, Exp -> table", function(ctx, exp)
    debug(exp)

    if not exp.op then
        local val = exp[1]
        typed.check(val, "string")
        if val:match("^L?'") then
            local character = parse_character_constant(val)
            if not character then
                error("invalid character constant in preprocessor expression", 0)
            end
            return character
        end
        local integer = parse_integer_constant(val)
        if integer then return integer end
        if val:match("^[A-Za-z_][_A-Za-z0-9]*$") then
            -- Macro replacement has already run.  C99 6.10.1p4 replaces every
            -- remaining identifier (including a self-recursive macro name)
            -- with the pp-number 0.
            return pp_integer(0, false)
        end
        error("non-integer constant in preprocessor expression", 0)
    elseif exp.op == "+"  then
        if exp[2] then
            local result = eval_exp(ctx, exp[1])
            for index = 2, #exp do
                local right = eval_exp(ctx, exp[index])
                result = pp_integer(result.bits + right.bits,
                    common_unsigned(result, right))
            end
            return result
        else
            return eval_exp(ctx, exp[1])
        end
    elseif exp.op == "-"  then
        if exp[2] then
            local result = eval_exp(ctx, exp[1])
            for index = 2, #exp do
                local right = eval_exp(ctx, exp[index])
                result = pp_integer(result.bits - right.bits,
                    common_unsigned(result, right))
            end
            return result
        else
            local value = eval_exp(ctx, exp[1])
            return pp_integer(-value.bits, value.unsigned)
        end
    elseif exp.op == "*" then
        local result = eval_exp(ctx, exp[1])
        for index = 2, #exp do
            local right = eval_exp(ctx, exp[index])
            result = pp_integer(result.bits * right.bits,
                common_unsigned(result, right))
        end
        return result
    elseif exp.op == "/" or exp.op == "%" then
        local result = eval_exp(ctx, exp[1])
        for index = 2, #exp do
            local right = eval_exp(ctx, exp[index])
            local quotient, remainder, unsigned
            if common_unsigned(result, right) then
                quotient, remainder =
                    unsigned_divmod(result.bits, right.bits)
                unsigned = true
            else
                quotient, remainder = signed_divmod(result.bits, right.bits)
                unsigned = false
            end
            result = pp_integer(
                exp.op == "/" and quotient or remainder, unsigned)
        end
        return result
    elseif exp.op == ">>" or exp.op == "<<" then
        local result = eval_exp(ctx, exp[1])
        for index = 2, #exp do
            local count = shift_count(eval_exp(ctx, exp[index]))
            local bits
            if exp.op == "<<" then
                bits = result.bits << count
            elseif result.unsigned then
                bits = result.bits >> count
            else
                bits = signed_right_shift(result.bits, count)
            end
            result = pp_integer(bits, result.unsigned)
        end
        return result
    elseif exp.op == "&" or exp.op == "|" or exp.op == "^" then
        local result = eval_exp(ctx, exp[1])
        for index = 2, #exp do
            local right = eval_exp(ctx, exp[index])
            local bits
            if exp.op == "&" then
                bits = result.bits & right.bits
            elseif exp.op == "|" then
                bits = result.bits | right.bits
            else
                bits = result.bits ~ right.bits
            end
            result = pp_integer(bits, common_unsigned(result, right))
        end
        return result
    elseif exp.op == "~" then
        local value = eval_exp(ctx, exp[1])
        return pp_integer(~value.bits, value.unsigned)
    elseif exp.op == "==" or exp.op == "!=" then
        local result = eval_exp(ctx, exp[1])
        for index = 2, #exp do
            local right = eval_exp(ctx, exp[index])
            local equal = result.bits == right.bits
            if exp.op == "!=" then equal = not equal end
            result = pp_integer(equal and 1 or 0, false)
        end
        return result
    elseif exp.op == ">=" or exp.op == "<=" or
           exp.op == ">" or exp.op == "<" then
        local result = eval_exp(ctx, exp[1])
        for index = 2, #exp do
            local right = eval_exp(ctx, exp[index])
            local comparison
            if exp.op == "<" then
                comparison = compare_less(result, right)
            elseif exp.op == ">" then
                comparison = compare_less(right, result)
            elseif exp.op == "<=" then
                comparison = not compare_less(right, result)
            else
                comparison = not compare_less(result, right)
            end
            result = pp_integer(comparison and 1 or 0, false)
        end
        return result
    elseif exp.op == "!" then
        return pp_integer(eval_exp(ctx, exp[1]).bits ~= 0 and 0 or 1, false)
    elseif exp.op == "&&" then
        for _, e in ipairs(exp) do
            if eval_exp(ctx, e).bits == 0 then
                return pp_integer(0, false)
            end
        end
        return pp_integer(1, false)
    elseif exp.op == "||" then
        for _, e in ipairs(exp) do
            if eval_exp(ctx, e).bits ~= 0 then
                return pp_integer(1, false)
            end
        end
        return pp_integer(0, false)
    elseif exp.op == "?" then
        local selected
        if eval_exp(ctx, exp[1]).bits ~= 0 then
            selected = eval_exp(ctx, exp[2])
        else
            selected = eval_exp(ctx, exp[3])
        end
        return pp_integer(selected.bits,
            expression_is_unsigned(exp[2]) or
                expression_is_unsigned(exp[3]))
    elseif exp.op == "defined" then
        return pp_integer((ctx.defines[exp[1][1]] ~= nil) and 1 or 0, false)
    else
        error("unimplemented operator " .. tostring(exp.op))
    end
end)

local consume_parentheses = typed("{string}, number, LineList, number -> {{string}}, number", function(tokens, start, linelist, cur)
    local args = {}
    local i = start + 1
    local arg = {}
    set_token_spacing(arg, {})
    local stack = 0
    while true do
        local token = tokens[i]
        if token == nil then
            repeat
                cur = cur + 1
                if not linelist[cur] then
                    error("unterminated function-like macro")
                end
                local nextline = linelist[cur].tk
                linelist[cur].tk = {}
                set_token_spacing(linelist[cur].tk, {})
                -- A physical newline separating two logical preprocessing
                -- lines is whitespace for stringification.
                append_tokens(tokens, nextline, true)
                token = tokens[i]
            until token
        end
        if token == "(" then
            stack = stack + 1
            append_token(arg, token, token_has_space_before(tokens, i),
                token_raw_spelling(tokens, i))
        elseif token == ")" then
            if stack == 0 then
                if #arg > 0 then
                    table.insert(args, arg)
                end
                break
            end
            stack = stack - 1
            append_token(arg, token, token_has_space_before(tokens, i),
                token_raw_spelling(tokens, i))
        elseif token == "," then
            if stack == 0 then
                table.insert(args, arg)
                arg = {}
                set_token_spacing(arg, {})
            else
                append_token(arg, token, token_has_space_before(tokens, i),
                    token_raw_spelling(tokens, i))
            end
        else
            append_token(arg, token, token_has_space_before(tokens, i),
                token_raw_spelling(tokens, i))
        end
        i = i + 1
    end
    return args, i
end)

local function array_copy(t)
    local t2 = {}
    for i,v in ipairs(t) do
        t2[i] = v
    end
    local spacing = pp_spacing[t]
    if spacing then
        local spacing2 = {}
        for i = 1, #t do
            spacing2[i] = spacing[i]
        end
        pp_spacing[t2] = spacing2
    end
    local raw = pp_raw_spelling[t]
    if raw then
        local raw2 = {}
        for i = 1, #t do
            raw2[i] = raw[i]
        end
        pp_raw_spelling[t2] = raw2
    end
    return t2
end

local function table_replace_n_with(list, at, n, values)
    local old = #list
    local old_tokens = {}
    for i = 1, old do
        old_tokens[i] = list[i]
    end
    local old_spacing = pp_spacing[list]
    local value_spacing = pp_spacing[values]
    local old_raw = pp_raw_spelling[list]
    local value_raw = pp_raw_spelling[values]
    debug("TRNW?", list, "AT", at, "N", n, "VALUES", values)
    --assert(is_sequence(list))
    local nvalues = #values
    local nils = n >= nvalues and (n - nvalues + 1) or 0
    if n ~= nvalues then
        table.move(list, at + n, #list + nils, at + nvalues)
    end
    debug("....", list)
    table.move(values, 1, nvalues, at, list)
    --assert(is_sequence(list))
    debug("TRNW!", list)
    assert(#list == old - n + #values)

    if old_spacing or value_spacing then
        local spacing = {}
        for i = 1, at - 1 do
            spacing[i] = old_spacing and old_spacing[i] or false
        end
        for i = 1, nvalues do
            if i == 1 then
                spacing[at] = at > 1 and old_spacing
                    and old_spacing[at] or false
            elseif value_spacing then
                spacing[at + i - 1] = value_spacing[i] == true
            else
                spacing[at + i - 1] = true
            end
        end
        local newat = at + nvalues
        for oldi = at + n, old do
            local before = old_spacing and old_spacing[oldi] or false
            if nvalues == 0 and oldi == at + n and at > 1
            and old_spacing then
                -- Whitespace before an empty macro invocation remains between
                -- the surviving tokens (`a E+b`, where E expands to nothing,
                -- becomes the token spelling `a +b`). Whitespace *inside* an
                -- empty function-like invocation is consumed with it.
                before = before or old_spacing[at] == true
            end
            spacing[newat] = before
            newat = newat + 1
        end
        pp_spacing[list] = spacing
    end

    if old_raw or value_raw then
        local raw = {}
        for i = 1, at - 1 do
            raw[i] = old_raw and old_raw[i] or old_tokens[i]
        end
        for i = 1, nvalues do
            raw[at + i - 1] = value_raw and value_raw[i] or values[i]
        end
        local newat = at + nvalues
        for oldi = at + n, old do
            raw[newat] = old_raw and old_raw[oldi] or old_tokens[oldi]
            newat = newat + 1
        end
        pp_raw_spelling[list] = raw
    end
end

local function table_remove(list, pos, n)
    table_replace_n_with(list, pos, n, {})
end

local stringify = typed("{string} -> string", function(tokens)
    local pieces = {}
    local spacing = pp_spacing[tokens]
    for i in ipairs(tokens) do
        if i > 1 and (not spacing or spacing[i]) then
            table.insert(pieces, " ")
        end
        table.insert(pieces, token_raw_spelling(tokens, i))
    end
    local text = table.concat(pieces)
    text = text:gsub("\\", "\\\\"):gsub('"', '\\"')
    return '"' .. text .. '"'
end)

local macro_expand

local mark_noloop = typed("table, string, number -> ()", function(noloop, token, n)
    noloop[token] = math.max(noloop[token] or 0, n)
end)

-- Shift recorded "blue paint" positions by `n` after the token stream changed
-- length at position `from`. Only entries at or past `from` move; entries before
-- it are already behind the cursor (their paint has expired -- see valid_noloop)
-- and must NOT be bumped forward, or a subsequent, unrelated use of the same
-- macro would be wrongly suppressed. This happens with glibc's <math.h>, where
-- __CONCAT is reused across sibling expansions of __MATHCALL_VEC: painting it
-- once (via __SIMD_DECL) used to block the later __CONCAT(name,) in the actual
-- declaration, dropping the function name.
local shift_noloop = typed("table, number, number -> ()", function(noloop, n, from)
    for token, v in pairs(noloop) do
        if v >= from then
            noloop[token] = v + n
        end
    end
end)

local valid_noloop = typed("table, string, number -> boolean", function(noloop, token, n)
    return noloop[token] == nil or noloop[token] < n
end)

local PLACEMARKER = {}

local function paste_error(linelist, cur, lhs, rhs)
    local line = linelist and linelist[cur]
    local where = line and line.nr and (" at line %d"):format(line.nr) or ""
    error(("invalid preprocessing token paste%s: '%s' ## '%s'")
        :format(where, lhs, rhs), 0)
end

local function paste_token(linelist, cur, lhs, rhs)
    local joined = lhs .. rhs
    local parsed = cpp.tokenize(joined)
    if not parsed or #parsed ~= 1 then
        paste_error(linelist, cur, lhs, rhs)
    end
    return parsed[1], token_raw_spelling(parsed, 1)
end

local replace_args = typed("Ctx, {string}, table, LineList, number -> ()", function(ctx, tokens, args, linelist, cur)
    -- C macro arguments have two simultaneous representations. `#` and `##`
    -- consume the raw preprocessing tokens, while an ordinary occurrence
    -- consumes an independently prescanned copy. Never expand the shared raw
    -- argument in place: one parameter can occur in both contexts.
    local expanded_args = {}
    local function expanded_argument(name)
        local expanded = expanded_args[name]
        if not expanded then
            expanded = array_copy(args[name])
            macro_expand(ctx, expanded, linelist, cur, false)
            expanded_args[name] = expanded
        end
        return expanded
    end

    local substituted = {}
    set_token_spacing(substituted, {})
    local i = 1
    while i <= #tokens do
        local token = tokens[i]
        if token == "#" and args[tokens[i + 1]] then
            append_token(substituted, stringify(args[tokens[i + 1]]),
                token_has_space_before(tokens, i))
            i = i + 2
        elseif args[token] then
            local paste_operand = tokens[i - 1] == "##" or tokens[i + 1] == "##"
            local replacement = paste_operand and args[token]
                or expanded_argument(token)
            if paste_operand and #replacement == 0 then
                append_token(substituted, PLACEMARKER,
                    token_has_space_before(tokens, i))
            else
                append_tokens(substituted, replacement,
                    token_has_space_before(tokens, i))
            end
            i = i + 1
        else
            append_token(substituted, token,
                token_has_space_before(tokens, i),
                token_raw_spelling(tokens, i))
            i = i + 1
        end
    end

    -- Complete every paste left-to-right. When a raw argument has multiple
    -- tokens only its boundary token participates, because the substitution
    -- above inserted the complete raw sequence around the `##` marker.
    i = 1
    while i <= #substituted do
        if substituted[i] == "##" then
            local lhs = substituted[i - 1]
            local rhs = substituted[i + 1]
            if lhs == nil or rhs == nil then
                paste_error(linelist, cur, tostring(lhs), tostring(rhs))
            end
            local pasted
            local pasted_raw
            if lhs == PLACEMARKER and rhs == PLACEMARKER then
                pasted = PLACEMARKER
            elseif lhs == PLACEMARKER then
                pasted = rhs
                pasted_raw = token_raw_spelling(substituted, i + 1)
            elseif rhs == PLACEMARKER then
                pasted = lhs
                pasted_raw = token_raw_spelling(substituted, i - 1)
            else
                pasted, pasted_raw = paste_token(linelist, cur,
                    token_raw_spelling(substituted, i - 1),
                    token_raw_spelling(substituted, i + 1))
            end
            local pasted_values = {}
            append_token(pasted_values, pasted, false, pasted_raw)
            table_replace_n_with(substituted, i - 1, 3, pasted_values)
            i = math.max(i - 1, 1)
        else
            i = i + 1
        end
    end

    local replacement = {}
    set_token_spacing(replacement, {})
    for i, token in ipairs(substituted) do
        if token ~= PLACEMARKER then
            append_token(replacement, token,
                token_has_space_before(substituted, i),
                token_raw_spelling(substituted, i))
        end
    end
    table_replace_n_with(tokens, 1, #tokens, replacement)
end)

macro_expand = typed("Ctx, {string}, LineList, number, boolean -> ()", function(ctx, tokens, linelist, cur, expr_mode)
    local i = 1
    -- TODO propagate noloop into replace_args. recurse into macro_expand storing a proper offset internally.
    local noloop = {}
    while true do
        ::continue::
        debug(i, tokens)
        local token = tokens[i]
        if not token then
            break
        end
        if expr_mode then
            if token == "defined" then
                if tokens[i + 1] == "(" then
                    i = i + 2
                end
                i = i + 2
                goto continue
            end
        end
        local define = ctx.defines[token]
        if define and valid_noloop(noloop, token, i) then
            debug(token, define)
            local repl = define.repl
            if define.args then
                if tokens[i + 1] == "(" then
                    local args, j = consume_parentheses(tokens, i + 1, linelist, cur)
                    debug("args:", #args, args)
                    local named_args = {}
                    local variadic = define.args[#define.args] == "..."
                    local fixed_count = #define.args - (variadic and 1 or 0)
                    for argi = 1, fixed_count do
                        named_args[define.args[argi]] = args[argi] or {}
                    end
                    if variadic then
                        local varargs = {}
                        set_token_spacing(varargs, {})
                        for argi = fixed_count + 1, #args do
                            if argi > fixed_count + 1 then
                                append_token(varargs, ",", false, ",")
                            end
                            append_tokens(varargs, args[argi],
                                token_has_space_before(args[argi], 1))
                        end
                        -- The grammar records C's unnamed variadic parameter
                        -- as `...`; replacement lists name it `__VA_ARGS__`.
                        -- A literal `...` in the replacement is an ordinary
                        -- ellipsis and must remain unchanged.
                        named_args["__VA_ARGS__"] = varargs
                    end
                    local expansion = array_copy(repl)
                    replace_args(ctx, expansion, named_args, linelist, cur)
                    local nexpansion = #expansion
                    local n = j - i + 1
                    if nexpansion == 0 then
                        table_remove(tokens, i, n)
                    else
                        table_replace_n_with(tokens, i, n, expansion)
                    end
                    shift_noloop(noloop, nexpansion - n, i)
                    mark_noloop(noloop, token, i + nexpansion - 1)
                else
                    i = i + 1
                end
            else
                local ndefine = #define
                if ndefine == 0 then
                    table_remove(tokens, i, 1)
                    shift_noloop(noloop, -1, i)
                elseif ndefine == 1 then
                    table_replace_n_with(tokens, i, 1, define)
                    mark_noloop(noloop, token, i)
                    noloop[token] = math.max(noloop[token] or 0, i)
                else
                    table_replace_n_with(tokens, i, 1, define)
                    mark_noloop(noloop, token, i + ndefine - 1)
                end
            end
        else
            i = i + 1
        end
    end
end)

local run_expression = typed("Ctx, {string} -> boolean", function(ctx, tks)
    local exp = parse_expression(tks)
    if not exp then
        error("syntax error in preprocessor expression", 0)
    end
    return eval_exp(ctx, exp).bits ~= 0
end)

local function parse_contents(filename, contents, ctx)
    ctx.io = ctx.io or default_io
    ctx.output_origins = ctx.output_origins or {}
    -- Record the names whose active macro definition this header closure
    -- changes. Foreign imports are parsed independently, but generated C
    -- includes every header in source order; checker-side field projections
    -- therefore need later definitions, redefinitions, and undefinitions to
    -- replace the earlier state rather than accumulate forever.
    ctx.macro_changes = ctx.macro_changes or {}

    local current_dir = filename:gsub("/[^/]*$", "")
    if current_dir == filename then current_dir = "." end
    table.insert(ctx.current_dir, current_dir)

    if ctx.header_dependency_observer then
        local observed, observe_err =
            ctx.header_dependency_observer(filename, contents)
        if not observed then
            table.remove(ctx.current_dir)
            return nil, observe_err
        end
    end
    local linelist = initial_processing_contents(contents)

    for _, lineitem in ipairs(linelist) do
        lineitem.tk = cpp.tokenize(lineitem.line)
    end

    -- ifmode is a tri-state stack: true (emitting), false (skipping this
    -- branch), or "skip" (a previous branch already matched).
    ---@type (boolean|string)[]
    local ifmode = ctx.ifmode
    for cur, lineitem in ipairs(linelist) do
        local line = lineitem.line
        local tk = lineitem.tk
        debug(filename, cur, ifmode[#ifmode], #ifmode, line)

        if #ifmode == 1 and (tk.directive == "elif" or tk.directive == "else" or tk.directive == "endif") then
            table.remove(ctx.current_dir)
            return nil, "unexpected directive " .. tk.directive
        end

        if tk.exp then
            macro_expand(ctx, tk.exp, linelist, cur, true)
        end

        if ifmode[#ifmode] == true then
            if tk.directive then
                debug(tk)
            end
            if tk.directive == "define" then
                local k = tk.id
                local v = tk.args and tk or tk.repl
                ctx.defines[k] = v
                ctx.macro_changes[k] = true
            elseif tk.directive == "undef" then
                ctx.defines[tk.id] = nil
                ctx.macro_changes[tk.id] = true
            elseif tk.directive == "ifdef" then
                table.insert(ifmode, (ctx.defines[tk.id] ~= nil))
            elseif tk.directive == "ifndef" then
                table.insert(ifmode, (ctx.defines[tk.id] == nil))
            elseif tk.directive == "if" then
                table.insert(ifmode, run_expression(ctx, tk.exp))
            elseif tk.directive == "elif" then
                ifmode[#ifmode] = "skip"
            elseif tk.directive == "else" then
                ifmode[#ifmode] = not ifmode[#ifmode]
            elseif tk.directive == "endif" then
                table.remove(ifmode, #ifmode)
            elseif tk.directive == "error" or tk.directive == "pragma" then
                -- ignore
            elseif tk.directive == "include" or tk.directive == "include_next" then
                local name = tk.exp[1]
                local mode = tk.exp.mode
                local is_next = (tk.directive == "include_next")
                local inc_filename, inc_contents, err, observer_failed =
                    find_file(ctx, name, mode, is_next)
                if observer_failed then
                    table.remove(ctx.current_dir)
                    return nil, name .. ":" .. err
                elseif not inc_filename then
                    -- fall back to trying to load an #include "..." as #include <...>;
                    -- this is necessary for Mac system headers
                    inc_filename, inc_contents, err, observer_failed =
                        find_file(ctx, name, "system", is_next)
                    if observer_failed then
                        table.remove(ctx.current_dir)
                        return nil, name .. ":" .. err
                    end
                end
                if not inc_filename then
                    table.remove(ctx.current_dir)
                    return nil, name..":"..err
                end
                local ok, include_err =
                    parse_contents(inc_filename, inc_contents, ctx)
                if not ok then
                    table.remove(ctx.current_dir)
                    return nil, name .. ":" .. include_err
                end
            else
                macro_expand(ctx, tk, linelist, cur, false)
                table.insert(ctx.output, table.concat(tk, " "))
                ctx.output_origins[#ctx.output] = {
                    file = filename,
                    line = lineitem.nr,
                }
            end
        elseif ifmode[#ifmode] == false then
            if tk.directive == "ifdef"
            or tk.directive == "ifndef"
            or tk.directive == "if" then
                table.insert(ifmode, "skip")
            elseif tk.directive == "else" then
                ifmode[#ifmode] = not ifmode[#ifmode]
            elseif tk.directive == "elif" then
                ifmode[#ifmode] = run_expression(ctx, tk.exp)
            elseif tk.directive == "endif" then
                table.remove(ifmode, #ifmode)
            end
        elseif ifmode[#ifmode] == "skip" then
            if tk.directive == "ifdef"
            or tk.directive == "ifndef"
            or tk.directive == "if" then
                table.insert(ifmode, "skip")
            elseif tk.directive == "else"
                or tk.directive == "elif" then
                -- do nothing
            elseif tk.directive == "endif" then
                table.remove(ifmode, #ifmode)
            end
        end
    end

    table.remove(ctx.current_dir)

    return ctx, nil
end

cpp.parse_contents = typed(
    "string, string, Ctx -> Ctx?, string?", parse_contents)

-- Preserve the historical optional FILE* entry point for standalone parser
-- callers, while compiler-owned paths pass only names and consume bytes via
-- the context strategy. Include recursion uses parse_contents so a selected
-- header is never opened a second time merely to test its existence.
cpp.parse_file = typed(
    "string, FILE*?, Ctx? -> Ctx?, string?",
    function(filename, fd, ctx)
        if not ctx then
            local context_error
            ctx, context_error = cpp.new_context()
            if not ctx then return nil, context_error end
        end
        ctx.io = ctx.io or default_io

        local contents
        if not fd and not filename:match("^/") then
            local found_name, found_contents, find_error, observer_failed =
                find_file(ctx, filename, "system")
            if observer_failed then return nil, find_error end
            if found_contents then
                filename, contents = found_name, found_contents
            end
        end

        if fd then
            local read_error
            contents, read_error = fd:read("a")
            fd:close()
            if not contents then return nil, read_error end
        elseif not contents then
            local read_error
            contents, read_error = ctx.io:read_file(filename)
            if not contents then return nil, read_error end
        end
        return parse_contents(filename, contents, ctx)
    end)

cpp.expand_macro = typed("string, table -> string", function(macro, define_set)
    local ctx = typed.table("Ctx", setmetatable({
        defines = define_set,
    }, { __index = error, __newindex = error }))
    local tokens = { macro }
    local linelist = typed.table("LineList", { { nr = 1, line = macro } })
    macro_expand(ctx, tokens, linelist, 1, false)
    return table.concat(tokens, " ")
end)

return cpp
