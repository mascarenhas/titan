local cdriver = {}

local cpp = require("c-parser.cpp")
local c99 = require("c-parser.c99")
local ctypes = require("c-parser.ctypes")
local cdefines = require("c-parser.cdefines")
local lfs = require("lfs")

local SEP = package.config:sub(1, 1)
local LOAD_CWD = lfs.currentdir()

local compiler_include_dirs

local function is_absolute_path(filename)
    return filename:match("^/") ~= nil
end

local function join_path(dir, filename)
    if dir:sub(-1) == SEP then
        return dir .. filename
    end
    return dir .. SEP .. filename
end

local function file_exists(filename)
    local fd = io.open(filename, "rb")
    if fd then
        fd:close()
        return true
    end
    return false
end

local function parent_dir(dir)
    local parent = dir:match("^(.*)[/\\][^/\\]+$")
    if parent == "" or parent == dir then
        return nil
    end
    return parent
end

local function find_runtime_dir(start_dir)
    local dir = start_dir
    while dir do
        local runtime = join_path(dir, "titan-runtime")
        if file_exists(join_path(runtime, "titan/ffi.h")) then
            return runtime
        end
        dir = parent_dir(dir)
    end
end

local function find_sdk_include_dir(start_dir)
    local dir = start_dir
    while dir do
        local include = join_path(dir, "include")
        if file_exists(join_path(include, "titan/ffi.h")) then
            return include
        end
        dir = parent_dir(dir)
    end
end

local function find_lua_source_dir(start_dir)
    local dir = start_dir
    while dir do
        local lua_source = join_path(join_path(dir, "lua-5.5.0"), "src")
        if file_exists(join_path(lua_source, "lua.h")) then
            return lua_source
        end
        lua_source = join_path(join_path(dir, "src"), "lua-5.5.0")
        if file_exists(join_path(lua_source, "lua.h")) then
            return lua_source
        end
        dir = parent_dir(dir)
    end
end

local function default_compiler_include_dirs()
    if compiler_include_dirs then
        return compiler_include_dirs
    end

    local source = debug.getinfo(1, "S").source
    local this_dir = source:sub(1, 1) == "@"
        and source:sub(2):match("^(.*)[/\\][^/\\]+$")
        or "."
    if not is_absolute_path(this_dir) then
        this_dir = join_path(LOAD_CWD, this_dir)
    end
    compiler_include_dirs = {
        find_runtime_dir(this_dir) or find_sdk_include_dir(this_dir)
            or "titan-runtime",
    }
    local lua_source = find_lua_source_dir(this_dir)
    if lua_source then
        table.insert(compiler_include_dirs, lua_source)
    end
    return compiler_include_dirs
end

-- Resolve the fixed Titan/Lua SDK roots once and return an owned ordered copy.
-- Passing nil requests checkout/installed-module discovery; an explicit empty
-- array remains empty. This distinction lets direct checker embeddings share
-- the exact roots later installed in their probe service instead of
-- accidentally converting "discover" into "no fixed headers".
function cdriver.resolve_compiler_include_dirs(value)
    if value == nil then value = default_compiler_include_dirs() end
    if type(value) ~= "table" then
        return nil, "compiler include dirs must be an ordered array"
    end
    local copy = {}
    for index = 1, #value do
        local directory = value[index]
        if type(directory) ~= "string" or directory == "" then
            return nil, "compiler include dir " .. index ..
                " must be a nonempty string"
        elseif directory:find("\0", 1, true) then
            return nil, "compiler include dir " .. index ..
                " contains a NUL byte"
        end
        copy[index] = directory
    end
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key > #value
        or key % 1 ~= 0 then
            return nil, "compiler include dirs must be a dense ordered array"
        end
    end
    return copy
end

local function find_header(filename, incdirs)
    for _, incdir in ipairs(incdirs or {}) do
        local candidate = join_path(incdir, filename)
        if file_exists(candidate) then
            return candidate
        end
    end
end

local function normalize_options(options)
    if type(options) == "string" then
        return { source_dir = options }
    end
    if type(options) == "table" then
        return options
    end
    return {}
end

local function resolve_include(filename, options, incdirs)
    options = normalize_options(options)

    if is_absolute_path(filename) then
        return {
            original = filename,
            resolved = filename,
            include_kind = "quote",
            include_name = filename,
        }
    end

    if options.source_dir then
        local source_relative = join_path(options.source_dir, filename)
        if file_exists(source_relative) then
            return {
                original = filename,
                resolved = source_relative,
                include_kind = "quote",
                include_name = filename,
            }
        end
    end

    local quote_header = find_header(filename, incdirs.quote)
    if quote_header then
        return {
            original = filename,
            resolved = quote_header,
            include_kind = "quote",
            include_name = filename,
        }
    end

    return {
        original = filename,
        resolved = find_header(filename, incdirs.system) or filename,
        include_kind = "angle",
        include_name = filename,
    }
end

local function new_cpp_context(options)
    local own_dirs, dirs_error =
        cdriver.resolve_compiler_include_dirs(
            options.compiler_include_dirs)
    if not own_dirs then return nil, dirs_error end
    return cpp.new_context({
        compiler = options.compiler,
        language_mode = options.language_mode,
        language_flag = options.language_flag,
        compile_flags = options.compile_flags,
        cppflags = options.cppflags,
        fixed_include_dirs = own_dirs,
    })
end

function cdriver.process_file(filename, options)
    options = normalize_options(options)
    local ctx, err = new_cpp_context(options)
    if not ctx then
        return nil, "failed configuring C preprocessor: " .. err
    end

    local include = resolve_include(filename, options, ctx.incdirs)
    local parse_filename = file_exists(include.resolved) and include.resolved or filename

    ctx, err = cpp.parse_file(parse_filename, nil, ctx)
    if not ctx then
        return nil, "failed preprocessing '"..filename.."': " .. err
    end

    local srccode = table.concat(ctx.output, "\n").." $EOF$"

    local res, err, line, col, fragment = c99.match_language_grammar(srccode)
    if not res then
        return nil, ("failed parsing: %s:%d:%d: %s\n%s"):format(filename, line, col, err, fragment)
    end

    -- Preserve source positions through the flattened preprocessor stream for
    -- declaration diagnostics. Compatibility never treats path/line/column as
    -- proof of C type identity; the final ordered-header compiler baseline is
    -- authoritative for independently parsed anonymous declarations.
    local line_starts = {}
    local next_start = 1
    for index, output_line in ipairs(ctx.output) do
        line_starts[index] = next_start
        next_start = next_start + #output_line + 1
    end
    local function source_origin(position)
        local low, high = 1, #line_starts
        local found = 1
        while low <= high do
            local middle = math.floor((low + high) / 2)
            if line_starts[middle] <= position then
                found = middle
                low = middle + 1
            else
                high = middle - 1
            end
        end
        local origin = ctx.output_origins
            and ctx.output_origins[found]
        if not origin then return nil end
        return {
            file = origin.file,
            line = origin.line,
            column = position - line_starts[found] + 1,
        }
    end
    for _, declaration in ipairs(res) do
        declaration._declaration_provenance =
            source_origin(declaration._source_position)
        declaration._source_position = nil
    end

    local ffi_types, err = ctypes.register_types(res, {
        header = filename,
        resolved_header = include.resolved,
    })
    if not ffi_types then
        return nil, err
    end

    cdefines.register_defines(ffi_types, ctx.defines)

    -- The fourth result is deliberately contextual rather than process-global:
    -- target-profile acquisition needs the exact macro context that parsed the
    -- configured Lua headers, while ordinary callers retain the historical
    -- first three results.
    return ffi_types, nil, include, ctx
end

local function primitive_typedef_spelling(ffi_types, name)
    local item = ffi_types[name]
    local declaration = item and item.type == "typedef" and item
        or item and item.type
    local definition = declaration and declaration.def
    if type(definition) ~= "table" or definition.type ~= nil then
        return nil, "configured '" .. name ..
            "' is not a primitive C typedef"
    end

    local tokens = {}
    for index = 1, #definition do
        if type(definition[index]) ~= "string" then
            return nil, "configured '" .. name ..
                "' has a non-primitive C spelling"
        end
        tokens[#tokens + 1] = definition[index]
    end
    if #tokens == 0 then
        return nil, "configured '" .. name .. "' has an empty C spelling"
    end
    return table.concat(tokens, " ")
end

-- Acquire the pure target-profile inputs under the same compiler argv,
-- target-selecting flags, and installed luaconf.h used for generated code.
-- csemantics owns interpretation; this layer only exposes parser facts.
function cdriver.target_profile_inputs(options)
    options = normalize_options(options)
    local fixed_include_dirs, dirs_error =
        cdriver.resolve_compiler_include_dirs(
            options.compiler_include_dirs)
    if not fixed_include_dirs then return nil, dirs_error end
    local ffi_types, err, include, ctx =
        cdriver.process_file("lua.h", options)
    if not ffi_types then
        return nil, "failed acquiring configured Lua numeric types: " .. err
    end

    local lua_integer
    lua_integer, err = primitive_typedef_spelling(ffi_types, "lua_Integer")
    if not lua_integer then return nil, err end
    local lua_number
    lua_number, err = primitive_typedef_spelling(ffi_types, "lua_Number")
    if not lua_number then return nil, err end

    return {
        macros = ctx.defines,
        lua_integer = lua_integer,
        lua_number = lua_number,
        lua_header = include,
        fixed_include_dirs = fixed_include_dirs,
    }
end

-- Shared argument handling for driver/checker integration. CPPFLAGS must be
-- split once and passed to process_file as an array; never reconstruct words
-- by splitting on whitespace at the call site.
cdriver.split_shell_words = cpp.split_shell_words
cdriver.shell_quote = cpp.shell_quote
cdriver.capture_command = cpp.capture_command

return cdriver
