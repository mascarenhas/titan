-- Experimental object certification. Persisted format versions deliberately
-- remain unchanged on the private issue-incr-proto measurement branch.
local lfs = require "lfs"
local sha256 = require "titan-compiler.sha256"
local types = require "titan-compiler.types"
local util = require "titan-compiler.util"
local incremental = {}

local function hash(context, bytes)
    return sha256.hex_via(context and context.cache_adapter and
        context.cache_adapter.sha256_binary, bytes)
end

local function inventory(directory, suffix, result)
    if lfs.attributes(directory, "mode") ~= "directory" then return end
    local names = {}
    for name in lfs.dir(directory) do
        if name ~= "." and name ~= ".." then names[#names + 1] = name end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local path = directory .. "/" .. name
        if lfs.attributes(path, "mode") == "directory" then
            inventory(path, suffix, result)
        elseif name:sub(-#suffix) == suffix then
            local bytes = assert(util.get_file_contents(path))
            result[#result + 1] = name .. ":" .. #bytes .. ":" .. bytes
        end
    end
end

function incremental.configuration(driver, context)
    if context and context.incremental_configuration then
        return context.incremental_configuration
    end
    local started = os.clock()
    local compiler = assert(package.searchpath("titan-compiler.driver", package.path))
    local root = assert(compiler:match("^(.*)[/\\]titan%-compiler[/\\]driver[.]lua$"))
    local pieces = {}
    inventory(root .. "/titan-compiler", ".lua", pieces)
    inventory(root .. "/c-parser", ".lua", pieces)
    local frontend = util.get_file_contents(root .. "/titanc")
        or util.get_file_contents(driver.TITAN_ROOT .. "/bin/titanc")
    if frontend then pieces[#pieces + 1] = frontend end
    -- Generated C consumes runtime/Lua headers even without a foreign import.
    inventory(driver.TITAN_ROOT .. "/include/titan", ".h", pieces)
    local installed = driver.INSTALL_PATHS or {}
    inventory(installed.lua_source or "", ".h", pieces)
    local identity = hash(context, table.concat(pieces, "\0"))
    pieces = { identity, driver.CC, driver.CFLAGS,
        tostring(driver.EMIT_LINE_DIRECTIVES), driver.BUILD_PROFILE,
        driver.TITAN_ROOT, driver.TITAN_RUNTIME_PATH }
    for _, flags in ipairs({ driver.EXTRA_CPPFLAGS or {}, driver.EXTRA_CFLAGS or {},
                            driver.foreign_include_dirs(),
                            context and context.extra_ffi_include_dirs or {} }) do
        pieces[#pieces + 1] = "[" .. table.concat(flags, "\0") .. "]"
    end
    identity = hash(context, table.concat(pieces, "\0"))
    if context then context.incremental_configuration = identity end
    if context and context.probe_verbose then
        io.stderr:write(string.format("Titan object configuration: %.3fs CPU\n", os.clock() - started))
    end
    return identity
end

function incremental.interface(entry, source_required, context)
    local pieces = { types.serialize_semantic(entry.type) }
    local layouts = entry.layouts or entry.object_metadata and entry.object_metadata.layouts
    if not layouts and entry.ast then
        local layout = require "titan-compiler.nominallayout"
        local plans = {}
        for _, node in ipairs(entry.ast) do
            if not node._ignore and node._tag == "Ast.TopLevelRecord" then
                plans[node._type.name] = assert(layout.record(node._type))
            elseif not node._ignore and node._tag == "Ast.TopLevelUnion" then
                for _, variant in ipairs(node._type.variants) do
                    plans[node._type.name .. "." .. variant.name] =
                        assert(layout.variant(node._type, variant))
                end
            end
        end
        layouts = assert(layout.encode(entry.type.name, plans))
    end
    if layouts then pieces[#pieces + 1] = layouts end
    if entry.kind == "source" then
        if source_required then
            pieces[#pieces + 1] = assert(require("titan-compiler.sourceinterface").serialize(entry))
        end
        local recipe = entry.object_metadata and entry.object_metadata.foreign_header
            or entry.ast and entry.ast._foreign_header_recipe
        if not recipe and entry.ast then
            local _, generated = require("titan-compiler.coder").generate_foreign_header(
                entry.type.name, entry.ast, { module = entry.type.name })
            recipe = generated
        end
        if recipe then
            pieces[#pieces + 1] = require("titan-compiler.ffiheaders").foreign_contents(
                recipe, "module.ffi.h", function(name) return name .. ".titan.h" end)
        end
    end
    return hash(context, table.concat(pieces, "\0"))
end

return incremental
