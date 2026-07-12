local assert = require "luassert"
local lfs = require "lfs"
local checker = require "titan-compiler.checker"
local driver = require "titan-compiler.driver"
local parser = require "titan-compiler.parser"
local types = require "titan-compiler.types"

local M = {}
local registry = debug.getregistry()
local cache_key = "titan.spec.support.stdlib-checker.uv:" .. lfs.currentdir()

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    file:close()
    return contents
end

local function build_uv_interface()
    local saved_registry = types.registry
    local saved_imported = driver.imported
    types.registry = {}
    driver.imported = {}
    local modules = {
        coroutine = read_file("stdlib/coroutine.titan"),
        uv = read_file("stdlib/uv.titan"),
    }
    local source = modules.uv
    local ast, parse_errors = parser.parse("stdlib/uv.titan", source)
    assert.truthy(ast, parse_errors and
        parser.error_to_string(parse_errors, "stdlib/uv.titan"))
    local modtype, errors = checker.check("uv", ast, source,
        "stdlib/uv.titan", driver.tableloader(modules, {}, {}))
    assert.truthy(modtype)
    assert.equals(0, #errors, table.concat(errors, "\n"))
    local source_registry = {}
    for name, typ in pairs(types.registry) do source_registry[name] = typ end
    local result = {
        source_type = modtype,
        source_registry = source_registry,
        serialized = types.serialize(modtype),
    }
    types.registry = saved_registry
    driver.imported = saved_imported
    return result
end

local function cached_uv()
    local cached = registry[cache_key]
    if not cached then
        cached = build_uv_interface()
        registry[cache_key] = cached
    end
    return cached
end

-- Return the source-checked type, including local fields needed by uv's own
-- interface assertions. Restore its complete nominal registry after test
-- isolation replaces types.registry; uv's own checks intentionally inspect a
-- few private owner records in addition to the exported surface.
function M.source_uv()
    local cached = cached_uv()
    for name, typ in pairs(cached.source_registry) do
        types.registry[name] = typ
    end
    return cached.source_type
end

-- Rehydrate a fresh binary-boundary view for each facade/consumer check. This
-- is the same serialization boundary tableloader applies after a source import,
-- while the expensive uv source check above still occurs once per process.
function M.uv_imported()
    local chunk, err = load("return " .. cached_uv().serialized,
        "cached uv interface", "t", types)
    assert.truthy(chunk, err)
    local ok, modtype = pcall(chunk)
    assert.truthy(ok, modtype)
    return { uv = { type = modtype } }
end

return M
