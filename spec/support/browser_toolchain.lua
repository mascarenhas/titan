-- Shared real-toolchain gate. Pure/synthesized browser specs do not use this.
--
-- `detect()`/`require()` keep #328's compile-only contract: a verified
-- Emscripten 6.0.13 and the fork's installed browser Lua. An explicit
-- requirement table adds capabilities on top of it:
--
--   { node = true }                                  -- Node 26+ through the runner
--   { node = true, chrome = true }                   -- plus headless Chromium
--   { node = true, chrome = true, sdk = true }       -- plus the installed browser SDK
--
-- Absence is reported as `nil, reason` so a body can pend; the strict
-- `TITAN_REQUIRE_BROWSER_TOOLCHAIN=1` variable turns the same reason into an
-- error. A capability that is present but malformed is never downgraded to an
-- absence: the third result is true and `require` always raises.
local compiler_io = require "titan-compiler.io"
local paths = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local installed_prefix = require "spec.support.installed_prefix"
local M = {}

-- Successful capabilities are cached separately, and absence is never cached:
-- established capability records stay cheap while a fake environment unit case
-- cannot poison a later installed-toolchain case.
local cache = {}

local requirements_schema = { node = true, chrome = true, sdk = true }

local function check_requirements(requirements)
    if requirements == nil then return {} end
    if type(requirements) ~= "table" then
        return nil, "browser toolchain requirements must be a table"
    end
    for key, value in pairs(requirements) do
        if not requirements_schema[key] then
            return nil, "unknown browser toolchain requirement " ..
                string.format("%q", tostring(key))
        elseif value ~= true then
            return nil, "browser toolchain requirement " ..
                string.format("%q", key) .. " must be true"
        end
    end
    return requirements
end

local function absolute(strategy, filename)
    return platform.is_absolute(filename) and filename or
        paths.join(assert(strategy:cwd()), filename)
end

local function executable(strategy, filename)
    local attributes = strategy:stat(filename)
    return attributes and attributes.kind == "file" and
        strategy:executable(filename) == true
end

local function discover()
    if platform.windows then
        return nil, "browser builds are supported from Linux and macOS hosts"
    end
    local strategy = compiler_io.new_sync()
    local emsdk = os.getenv("EMSDK")
    local cc
    if emsdk and emsdk ~= "" then
        cc = absolute(strategy, paths.join(emsdk, "upstream/emscripten/emcc"))
        if not executable(strategy, cc) then
            return nil, "emcc not found at " .. string.format("%q", cc)
        end
    else
        for directory in ((os.getenv("PATH") or "") .. ":"):gmatch("(.-):") do
            local candidate = absolute(strategy, paths.join(directory == "" and "." or directory, "emcc"))
            if executable(strategy, candidate) then cc = candidate; break end
        end
        if not cc then return nil, "emcc not found (EMSDK unset; not on PATH)" end
    end
    local result = strategy:run({ cc, "--version" }, { stderr_to_stdout = true })
    local found = result and result.output and
        result.output:match("emcc[^\n]- (%d+%.%d+%.%d+)")
    if not result or not result.ok or found ~= "6.0.13" then
        return nil, string.format("%q reports Emscripten %s, expected 6.0.13", cc, found or "unknown")
    end
    local directory = paths.dirname(cc)
    local tools = { cc = { cc }, ar = { paths.join(directory, "emar") },
        ranlib = { paths.join(directory, "emranlib") },
        clang = { paths.join(paths.dirname(directory), "bin/clang") } }
    for name, argv in pairs(tools) do
        if not executable(strategy, argv[1]) then
            return nil, name .. " not found at " .. string.format("%q", argv[1])
        end
    end
    local prefix = installed_prefix.active()
    local base = paths.join(prefix, "lib/browser")
    for _, relative in ipairs({ "liblua.a", "liblua-config.txt", "include/lua.h",
            "include/luaconf.h", "include/lstate.h" }) do
        local filename = paths.join(base, relative)
        if not strategy:readable(filename) then
            return nil, "browser Lua prerequisite not readable: " .. string.format("%q", filename) ..
                "; run 'make install-browser PREFIX=" .. prefix .. "' in the Lua fork"
        end
    end
    return { prefix = prefix, tools = tools,
        record_path = paths.join(base, "liblua-config.txt") }
end

-- Browser Lua compilation macros, from the installed record. Harnesses that
-- compile C against the archive must use exactly these: the fork changes them
-- (for example LUAI_MAXCCALLS), and an object built with a local list is a
-- different configuration than the archive it links against.
function M.lua_defines(info)
    local record_path = type(info) == "table" and info.record_path
    assert(type(record_path) == "string",
        "browser toolchain info with a record path is required", 2)
    local file, open_error = io.open(record_path, "rb")
    assert(file, "cannot read browser Lua record " .. string.format("%q", record_path) ..
        ": " .. tostring(open_error), 2)
    local text = assert(file:read("a")); assert(file:close())
    local recorded
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local value = line:match("^lua_defines=(.*)$")
        if value then recorded = value end
    end
    assert(type(recorded) == "string" and recorded ~= "",
        "browser Lua record " .. string.format("%q", record_path) ..
        " lacks lua_defines; reinstall the browser Lua fork", 2)
    local defines = {}
    for define in recorded:gmatch("%S+") do defines[#defines + 1] = define end
    assert(#defines > 0, "browser Lua record " .. string.format("%q", record_path) ..
        " has an empty lua_defines; reinstall the browser Lua fork", 2)
    return defines
end

-- A compile command that names the record's browser Lua macros. They are
-- spliced in by appending, never by `table.unpack` in a non-final position: a
-- table constructor keeps only the first result of a non-final `table.unpack`,
-- which silently drops all but one define. Every caller gets the same
-- self-check, so a recurrence fails instead of compiling a different
-- configuration than the archive it links against.
function M.with_lua_defines(info, before, after)
    local argv = {}
    for _, flag in ipairs(before or {}) do argv[#argv + 1] = flag end
    local defines = M.lua_defines(info)
    for _, define in ipairs(defines) do argv[#argv + 1] = define end
    for _, flag in ipairs(after or {}) do argv[#argv + 1] = flag end
    for _, define in ipairs(defines) do
        local seen = 0
        for _, flag in ipairs(argv) do
            if flag == define then seen = seen + 1 end
        end
        assert(seen == 1, "browser compile command must carry record define " ..
            define .. " exactly once: " .. table.concat(argv, " "))
    end
    return argv
end

-- ROOT is the installed Titan tree: `ROCKS_TREE` when it is set, else PREFIX.
local function install_root(prefix)
    local rocks_tree = os.getenv("ROCKS_TREE")
    if rocks_tree == "" then rocks_tree = nil end
    return rocks_tree or prefix, rocks_tree
end

local function repository_root()
    local module = package.searchpath("spec.support.browser_toolchain", package.path)
    return module and module:match("^(.*)[/\\]spec[/\\]support[/\\]browser_toolchain%.lua$")
end

-- E owns Node and Chrome discovery. The helper asks the installed runner for
-- its closed --probe result and falls back to the source launcher before the
-- SDK exists; it never re-implements either probe.
local function runner_candidates()
    local candidates = {}
    local driver = require "titan-compiler.driver"
    local browserlink = require "titan-compiler.browserlink"
    local installed = driver.installed_paths(install_root(installed_prefix.active()), "browser")
    if installed then
        candidates[#candidates + 1] = browserlink.sdk_assets(installed).runner
    end
    local repository = repository_root()
    if repository then
        candidates[#candidates + 1] =
            paths.join(repository, "titan-runtime/browser/titan-browser-run")
    end
    return candidates
end

-- The probe's stdout is one closed JSON object of strings, booleans and nulls.
-- Decoding exactly that shape keeps the helper independent of a JSON library
-- that is not a declared compiler dependency.
local NULL = {}

local function decode_probe(bytes)
    local position = 1
    local function fail(message) error({ probe = message }, 0) end
    local function skip_space()
        while true do
            local char = bytes:sub(position, position)
            if char == " " or char == "\t" or char == "\r" or char == "\n" then
                position = position + 1
            else
                return
            end
        end
    end
    local escapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
        b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
    local function parse_string()
        position = position + 1
        local parts = {}
        while true do
            local char = bytes:sub(position, position)
            if char == "" then fail("unterminated string") end
            if char == '"' then
                position = position + 1
                return table.concat(parts)
            elseif char == "\\" then
                local code = bytes:sub(position + 1, position + 1)
                if code == "u" then
                    local hex = bytes:sub(position + 2, position + 5)
                    local point = hex:match("^%x%x%x%x$") and tonumber(hex, 16)
                    if not point or point >= 0xD800 and point <= 0xDFFF then
                        fail("invalid unicode escape")
                    end
                    parts[#parts + 1] = utf8.char(point)
                    position = position + 6
                else
                    local replacement = escapes[code]
                    if not replacement then fail("invalid string escape") end
                    parts[#parts + 1] = replacement
                    position = position + 2
                end
            else
                if char:byte() < 32 or char:byte() == 127 then
                    fail("raw control byte in string")
                end
                parts[#parts + 1] = char
                position = position + 1
            end
        end
    end
    local parse_value
    function parse_value()
        skip_space()
        local char = bytes:sub(position, position)
        if char == "{" then
            position = position + 1
            local object = {}
            skip_space()
            if bytes:sub(position, position) == "}" then
                position = position + 1
                return object
            end
            while true do
                skip_space()
                if bytes:sub(position, position) ~= '"' then
                    fail("expected an object key")
                end
                local key = parse_string()
                if object[key] ~= nil then fail("duplicate object key") end
                skip_space()
                if bytes:sub(position, position) ~= ":" then fail("expected ':'") end
                position = position + 1
                object[key] = parse_value()
                skip_space()
                local separator = bytes:sub(position, position)
                position = position + 1
                if separator == "}" then return object end
                if separator ~= "," then fail("expected ',' or '}'") end
            end
        elseif char == '"' then
            return parse_string()
        elseif bytes:sub(position, position + 3) == "true" then
            position = position + 4
            return true
        elseif bytes:sub(position, position + 4) == "false" then
            position = position + 5
            return false
        elseif bytes:sub(position, position + 3) == "null" then
            position = position + 4
            return NULL
        end
        fail("unsupported probe value")
    end
    local ok, value = pcall(function()
        local parsed = parse_value()
        if bytes:sub(position, position) ~= "\n" then
            fail("probe result is not LF-terminated")
        end
        position = position + 1
        if position <= #bytes then fail("probe result has trailing bytes") end
        return parsed
    end)
    if not ok then
        return nil, type(value) == "table" and value.probe or tostring(value)
    end
    return value
end

local record_keys = { path = true, version = true, ok = true, reason = true }

-- A capability value must be real, nonempty text. Escaped control characters
-- are legitimate JSON (a multi-line Chrome diagnostic is the common case), so
-- only the raw-byte form is rejected, at the decoder.
local function usable(value)
    return type(value) == "string" and value ~= ""
end

local function probe_record(records, name)
    local record = records[name]
    if type(record) ~= "table" then
        return nil, name .. " record is not an object"
    end
    for key in pairs(record) do
        if not record_keys[key] then
            return nil, name .. " record has unknown key " .. string.format("%q", key)
        end
    end
    if type(record.ok) ~= "boolean" or record.path == nil or
            record.version == nil or record.reason == nil then
        return nil, name .. " record is missing a required key"
    end
    for _, key in ipairs({ "path", "version", "reason" }) do
        if record[key] ~= NULL and type(record[key]) ~= "string" then
            return nil, name .. " record has a wrongly typed " .. key
        end
    end
    -- The runner's frozen contract: a success names both tools and carries no
    -- reason; a refusal always explains itself. Anything else is corruption.
    if record.ok then
        if record.reason ~= NULL then
            return nil, name .. " record reports success with a reason"
        end
        if not usable(record.path) then
            return nil, name .. " record reports success without a usable path"
        end
        if not usable(record.version) then
            return nil, name .. " record reports success without a usable version"
        end
    else
        if not usable(record.reason) then
            return nil, name .. " record reports failure without a usable reason"
        end
        for _, key in ipairs({ "path", "version" }) do
            if record[key] ~= NULL and not usable(record[key]) then
                return nil, name .. " record reports failure with an unusable " .. key
            end
        end
    end
    return record
end

local function decode_records(bytes)
    local records, message = decode_probe(bytes)
    if not records then return nil, message end
    if type(records) ~= "table" then return nil, "probe result is not an object" end
    for key in pairs(records) do
        if key ~= "node" and key ~= "chrome" then
            return nil, "probe result has unknown key " .. string.format("%q", key)
        end
    end
    local node, node_error = probe_record(records, "node")
    if not node then return nil, node_error end
    local chrome, chrome_error = probe_record(records, "chrome")
    if not chrome then return nil, chrome_error end
    return { node = node, chrome = chrome }
end

local function capability(record)
    if record.ok then
        return { path = record.path, version = record.version }
    end
    return nil, record.reason
end

local function run_probe(strategy)
    local found = {}
    for _, launcher in ipairs(runner_candidates()) do
        found[#found + 1] = string.format("%q", launcher)
        if executable(strategy, launcher) then
            local result = strategy:run({ launcher, "--probe" },
                { stderr_to_stdout = true })
            if not result or not result.started then
                return nil, "browser runner probe could not start: " .. tostring(
                    result and result.diagnostic or "no captured result")
            end
            local output = result.output or ""
            if not result.ok then
                local reason = output:gsub("%s+$", "")
                if reason == "" then
                    reason = "browser runner probe exited with status " ..
                        tostring(result.status)
                end
                return nil, reason
            end
            local records, message = decode_records(output)
            if not records then
                return nil, "malformed browser runner probe result: " .. message, true
            end
            return records
        end
    end
    return nil, "browser runner launcher not found (" ..
        table.concat(found, ", ") .. ")"
end

local function extended(requirements)
    if not (requirements.node or requirements.chrome) then return end
    if (not requirements.node or cache.node) and
            (not requirements.chrome or cache.chrome) then
        return
    end
    local records, reason, malformed = run_probe(compiler_io.new_sync())
    if not records then return reason, malformed end
    local node, node_error = capability(records.node)
    local chrome, chrome_error = capability(records.chrome)
    cache.node, cache.chrome = node, chrome
    if requirements.node and not node then return node_error end
    if requirements.chrome and not chrome then return chrome_error end
end

local function extended_sdk()
    if cache.sdk then return end
    local strategy = compiler_io.new_sync()
    local prefix = installed_prefix.active()
    local root, rocks_tree = install_root(prefix)
    local driver = require "titan-compiler.driver"
    local browserlink = require "titan-compiler.browserlink"
    local installed = driver.installed_paths(root, "browser")
    if not installed then
        return "cannot resolve the browser SDK root from " ..
            string.format("%q", root)
    end
    -- An absent SDK is a pendable capability; a present but incomplete one is a
    -- production failure, so the readiness answer carries that distinction.
    local present = strategy:stat(installed.titan_bin) ~= nil
    local assets, diagnostic = browserlink.require_sdk({ io = strategy },
        { paths = installed }, { prefix = prefix, rocks_tree = rocks_tree })
    if not assets then return diagnostic, present end
    cache.sdk = installed.titan_bin
end

function M.detect(requirements)
    local wanted, invalid = check_requirements(requirements)
    if not wanted then error(invalid, 2) end
    local info = cache.base
    if not info then
        local reason
        info, reason = discover()
        if not info then return nil, reason end
        cache.base = info
    end
    local extended_reason, malformed = extended(wanted)
    if extended_reason then return nil, extended_reason, malformed end
    if wanted.sdk then
        extended_reason, malformed = extended_sdk()
        if extended_reason then return nil, extended_reason, malformed end
    end
    if not (wanted.node or wanted.chrome or wanted.sdk) then return info end
    local result = {}
    for key, value in pairs(info) do result[key] = value end
    if wanted.node then result.node = cache.node end
    if wanted.chrome then result.chrome = cache.chrome end
    if wanted.sdk then result.sdk_root = cache.sdk end
    return result
end

function M.require(requirements)
    local info, reason, malformed = M.detect(requirements)
    if info then return info end
    reason = "browser toolchain unavailable: " .. tostring(reason)
    if malformed or os.getenv("TITAN_REQUIRE_BROWSER_TOOLCHAIN") == "1" then
        error(reason, 2)
    end
    return nil, reason
end

-- A test image uses only reviewed imports (scripts/browser_imports.lua): the
-- entry imports plus the classes of the test fixtures it links. `image` names
-- the `.mjs` or its `.wasm`.
local stdlib_checks
function M.check_imports(image, classes)
    stdlib_checks = stdlib_checks or dofile(repository_root() .. "/scripts/browser_stdlib.lua")
    local ok, err = stdlib_checks.check_file_imports(compiler_io.new_sync(), image, classes)
    if not ok then error(err, 2) end
end

return M
