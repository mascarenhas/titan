local cdriver = {}

local cpp = require("c-parser.cpp")
local c99 = require("c-parser.c99")
local ctypes = require("c-parser.ctypes")
local cdefines = require("c-parser.cdefines")

local SEP = package.config:sub(1, 1)

local include_paths
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

local function find_lua_source_dir(start_dir)
    local dir = start_dir
    while dir do
        local lua_source = join_path(join_path(dir, "lua-5.5.0"), "src")
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
    compiler_include_dirs = { find_runtime_dir(this_dir) or "titan-runtime" }
    local lua_source = find_lua_source_dir(this_dir)
    if lua_source then
        table.insert(compiler_include_dirs, lua_source)
    end
    return compiler_include_dirs
end

local function cpp_include_paths()
    if include_paths then
        return include_paths
    end

    local pd = io.popen("LANG=C cpp -v /dev/null -o /dev/null 2>&1")
    if not pd then
        include_paths = { system = { "/usr/include" } }
        return include_paths
    end

    local paths = { system = {} }
    local in_system_paths = false
    for line in pd:lines() do
        if line:find([[#include <...> search starts here]], 1, true) then
            in_system_paths = true
        elseif line:find([[End of search list]], 1, true) then
            in_system_paths = false
        elseif in_system_paths then
            table.insert(paths.system, line:sub(2))
        end
    end
    pd:close()

    if #paths.system == 0 then
        paths.system = { "/usr/include" }
    end
    include_paths = paths
    return include_paths
end

local function find_system_header(filename)
    for _, incdir in ipairs(cpp_include_paths().system) do
        local candidate = join_path(incdir, filename)
        if file_exists(candidate) then
            return candidate
        end
    end
    return filename
end

local function find_compiler_header(filename, options)
    local dirs = options.compiler_include_dirs or default_compiler_include_dirs()
    for _, incdir in ipairs(dirs) do
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

local function resolve_include(filename, options)
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

    local compiler_header = find_compiler_header(filename, options)
    if compiler_header then
        return {
            original = filename,
            resolved = compiler_header,
            include_kind = "angle",
            include_name = filename,
        }
    end

    return {
        original = filename,
        resolved = find_system_header(filename),
        include_kind = "angle",
        include_name = filename,
    }
end

function cdriver.process_file(filename, options)
    local include = resolve_include(filename, options)
    local parse_filename = file_exists(include.resolved) and include.resolved or filename

    local ctx, err = cpp.parse_file(parse_filename, nil, nil)
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

return cdriver
