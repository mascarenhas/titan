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

function cdriver.process_file(filename, options)
    options = normalize_options(options)
    local own_dirs = options.compiler_include_dirs
        or default_compiler_include_dirs()
    local ctx, err = cpp.new_context({
        compiler = options.compiler,
        language_mode = options.language_mode,
        cppflags = options.cppflags,
        fixed_include_dirs = own_dirs,
    })
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

    local ffi_types, err = ctypes.register_types(res)
    if not ffi_types then
        return nil, err
    end

    cdefines.register_defines(ffi_types, ctx.defines)

    return ffi_types, nil, include
end

-- Shared argument handling for driver/checker integration. CPPFLAGS must be
-- split once and passed to process_file as an array; never reconstruct words
-- by splitting on whitespace at the call site.
cdriver.split_shell_words = cpp.split_shell_words
cdriver.shell_quote = cpp.shell_quote

return cdriver
