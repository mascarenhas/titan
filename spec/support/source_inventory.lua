local assert = require "luassert"
local lfs = require "lfs"

local source_inventory = {}

local function collect_lua_files(path, files)
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            local child = path .. "/" .. name
            local mode = assert(lfs.attributes(child, "mode"))
            if mode == "directory" then
                collect_lua_files(child, files)
            elseif mode == "file" and name:match("%.lua$") then
                files[#files + 1] = child
            end
        end
    end
end

function source_inventory.lua_files(path)
    local files = {}
    collect_lua_files(path, files)
    table.sort(files)
    return files
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    assert.truthy(file:close())
    return contents
end

-- A literal Lua-pattern spelling of a Makefile variable or target name, which
-- may contain `-` (a quantifier outside a set).
local function pattern_literal(text)
    return (text:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- Collect the words of the first assignment whose left-hand side matches
-- `pattern`, joining continuation lines.
local function makefile_assignment_words(label, filename, pattern)
    local values = {}
    local collecting = false
    local found = false
    for line in (read_file(filename) .. "\n"):gmatch("(.-)\n") do
        local value
        if collecting then
            value = line
        else
            value = line:match(pattern)
            if value then found = true end
        end
        if value then
            local continued = value:match("\\%s*$") ~= nil
            value = value:gsub("\\%s*$", "")
            for word in value:gmatch("%S+") do values[#values + 1] = word end
            collecting = continued
            if not collecting then break end
        end
    end
    assert.truthy(found, "missing Makefile variable " .. label)
    assert.falsy(collecting, "unterminated Makefile variable " .. label)
    local result = {}
    local prefixing = false
    for _, word in ipairs(values) do
        if word == "$(addprefix" then
            prefixing = true
        elseif prefixing then
            word = word:gsub("^%$%(TITAN_OUTPUT_DIR%)/,", ""):gsub("%)$", "")
            result[#result + 1] = "out/" .. word
        else
            result[#result + 1] = word:gsub("%$%(TITAN_OUTPUT_DIR%)", "out")
        end
    end
    return result
end

-- The words of the `NAME := ...` assignment in `filename` (default `Makefile`).
function source_inventory.makefile_words(name, filename)
    return makefile_assignment_words(name, filename or "Makefile",
        "^" .. pattern_literal(name) .. "%s*:=%s*(.*)$")
end

-- Target-specific `export NAME = ...` assignments, which Makefile.win uses for
-- the per-target Busted spec lists no ordinary variable declares.
function source_inventory.makefile_target_export_words(filename, target, name)
    return makefile_assignment_words(name, filename,
        "^" .. pattern_literal(target) .. "%s*:%s*export%s+"
        .. pattern_literal(name) .. "%s*[:+%?]?=%s*(.*)$")
end

-- The native standard-library sources, expanding the per-module lists
-- `STDLIB_TITAN_SOURCES` names.
function source_inventory.stdlib_source_files(filename)
    local sources = {}
    local source_ensembles = {
        ["$(UV_TITAN_SOURCES)"] = "UV_TITAN_SOURCES",
        ["$(ASYNC_TITAN_SOURCES)"] = "ASYNC_TITAN_SOURCES",
        ["$(OS_TITAN_SOURCES)"] = "OS_TITAN_SOURCES",
        ["$(STDLIB_HTTP_SOURCES)"] = "STDLIB_HTTP_SOURCES",
        ["$(WEBSOCKET_TITAN_SOURCES)"] = "WEBSOCKET_TITAN_SOURCES",
        ["$(SQLITE3_TITAN_SOURCES)"] = "SQLITE3_TITAN_SOURCES",
        ["$(JSON_TITAN_SOURCES)"] = "JSON_TITAN_SOURCES",
        ["$(PROTOBUF_TITAN_SOURCES)"] = "PROTOBUF_TITAN_SOURCES",
        ["$(LUA_TITAN_SOURCES)"] = "LUA_TITAN_SOURCES",
        ["$(THREAD_TITAN_SOURCES)"] = "THREAD_TITAN_SOURCES",
    }
    for _, source in ipairs(source_inventory.makefile_words("STDLIB_TITAN_SOURCES", filename)) do
        local ensemble = source_ensembles[source]
        if ensemble then
            for _, constituent in ipairs(source_inventory.makefile_words(ensemble, filename)) do
                sources[#sources + 1] = constituent
            end
        else
            sources[#sources + 1] = source
        end
    end
    return sources
end

-- The declared native inventory plus the browser-only standard-library
-- sources, which no native Make list names: the compiler's browser selection
-- of the standard tree supplies them, and each must belong to a module that
-- the browser status inventory marks browser-only. Run from the checkout root.
function source_inventory.audited_stdlib_sources()
    local sources = source_inventory.stdlib_source_files()
    local driver = require "titan-compiler.driver"
    local browser_fixtures = require "spec.support.browser_fixtures"
    local paths = require "titan-compiler.path"
    local browser_checks = dofile("scripts/browser_stdlib.lua")
    local declared, browser_only = {}, {}
    for _, source in ipairs(sources) do declared[source] = true end
    for _, row in ipairs(browser_checks.status_inventory.modules) do
        if row[2] == "browser-only" then browser_only[row[1]] = true end
    end
    local descriptor = assert(driver._browser_target.import(browser_fixtures.descriptor()))
    local context = driver._new_resolver_context({ target = "browser" }, descriptor)
    local called, selected, err = pcall(browser_checks.check_sources, context, ".")
    local closed, close_error = driver.close_resolver_context(context)
    assert.is_true(called, selected)
    assert.is_true(closed, close_error)
    assert.is_table(selected, err)
    local covered = {}
    for _, file in ipairs(selected) do
        local source = paths.to_slash(file):gsub("^%./", "")
        if not declared[source] then
            local modname = "titan." .. assert(source:match("^titan/([^/.]+)"), source)
            assert.truthy(browser_only[modname], source .. " is a browser-only source outside a browser-only module")
            covered[modname] = true
            sources[#sources + 1] = source
        end
    end
    -- Every browser-only module is audited through at least one source.
    assert.same(browser_only, covered)
    return sources
end

return source_inventory
