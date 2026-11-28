-- The browser playground's compiler: one browser semantic target rehydrated
-- from a published catalog, and per-request resolver contexts over an owned
-- in-memory filesystem holding only the project. No host file, process,
-- C compiler or optimizer is reachable from here; the page compiles and
-- links the emitted C with its own toolchain and hands the optimized image
-- back for its trace table and loader module.
-- Implementation notes: doc/implementation/playground-bundle.md
local driver = require "titan-compiler.driver"
local checker = require "titan-compiler.checker"
local compiler_io = require "titan-compiler.io"
local completion = require "titan-compiler.completion"
local documentation = require "titan-compiler.documentation"
local parser = require "titan-compiler.parser"
local types = require "titan-compiler.types"
local browsertrace = require "titan-compiler.browsertrace"
local browserlink = require "titan-compiler.browserlink"
local staticmetadata = require "titan-compiler.staticmetadata"
local sha256 = require "titan-compiler.sha256"
local util = require "titan-compiler.util"

local playground = {}

-- The project is the filesystem root; the SDK lives under the reserved
-- `titan/` mount no project path may name.
local SDK_ROOT = "/titan"
local IMAGE = "app.wasm"
-- The image entry lives where titanc puts a program's synthetic entry, in a
-- `.titan-links` directory: a dot-led component no module stem can have.
local ENTRY = ".titan-links/main/synthetic/main__entrypoint.c"

local Service = {}
Service.__index = Service

-- Open the compiler over the semantic assets of one browser SDK publication.
function playground.open(assets)
    if type(assets) ~= "table" then error("playground assets are required", 2) end
    local directory = driver.installed_paths(SDK_ROOT, "browser").titan_bin
    local sdk = {}
    for name, field in pairs({ ["analysis-target"] = "analysis_target", ["absent-modules"] = "absent_modules" }) do
        if type(assets[field]) ~= "string" then error("playground asset " .. field .. " must be bytes", 2) end
        sdk[directory .. "/" .. name] = assets[field]
    end
    local handle, err = driver.browser_analysis_target(SDK_ROOT, {
        io = compiler_io.new_memory({ files = sdk }), catalog = assets.catalog,
    })
    if not handle then return nil, err end
    return setmetatable({ handle = handle, sdk = sdk, sdk_modules = driver.browser_analysis_modules(handle) },
        Service)
end

-- Project paths are relative POSIX paths naming real files; `titan/` is the
-- SDK's. Only `.titan` files reach the compiler.
local function project_io(self, files)
    local tree = {}
    for name, contents in pairs(self.sdk) do tree[name] = contents end
    for name, contents in pairs(files) do
        if type(name) ~= "string" or type(contents) ~= "string" or name == "" or name:find("\0", 1, true) or
            name:find("\\", 1, true) or name:sub(1, 1) == "/" or name:find("//", 1, true) or
            name:sub(-1) == "/" then
            error("invalid project path " .. string.format("%q", tostring(name)), 0)
        end
        for segment in name:gmatch("[^/]+") do
            if segment == "." or segment == ".." then
                error("invalid project path " .. string.format("%q", name), 0)
            end
        end
        if name == "titan" or name:sub(1, 6) == "titan/" then
            error("project path " .. string.format("%q", name) .. " names the reserved titan/ mount", 0)
        end
        if name:match("%.titan$") then tree["/" .. name] = contents end
    end
    return compiler_io.new_memory({ files = tree })
end

-- The snapshot's logical modules exactly as the ordinary tagged resolver
-- selects them for the browser target: a `.titan` file belongs to the module
-- whose selected sources list it. Each file proposes its own dotted stem
-- (target label removed by the driver's spelling rule) and its folder's; the
-- resolver decides. Inactive target variants, shadowed flat files and folder
-- contributors are therefore never modules of their own. Returns the sorted
-- module names, each selected file's owner, and spelling or lookup errors.
local function project_modules(context, files)
    local candidates, problems = {}, {}
    for name in pairs(files) do
        local directory, basename = name:match("^(.-)([^/]+)$")
        if basename:match("%.titan$") then
            local logical, _, spelling_error = driver.classify_source_filename(basename)
            if spelling_error then
                problems[#problems + 1] = { message = spelling_error, severity = "error", path = name,
                    line = 1, col = 1 }
            else
                candidates[(directory .. logical:sub(1, -7)):gsub("/", ".")] = true
                if directory ~= "" then candidates[directory:sub(1, -2):gsub("/", ".")] = true end
            end
        end
    end
    local names = {}
    for modname in pairs(candidates) do
        if staticmetadata.valid_module_name(modname) then names[#names + 1] = modname end
    end
    table.sort(names, util.bytewise_less)
    local modules, owners = {}, {}
    for _, modname in ipairs(names) do
        local source, lookup_error = driver.resolve_source(context, modname)
        if lookup_error then
            problems[#problems + 1] = { message = lookup_error, severity = "error" }
        elseif source and source.kind ~= "blocked" then
            for _, file in ipairs(source.files) do
                local relative = file:gsub("^%./", "")
                if files[relative] and not owners[relative] then
                    owners[relative] = modname
                    if modules[#modules] ~= modname then modules[#modules + 1] = modname end
                end
            end
        end
    end
    table.sort(problems, function(left, right)
        return util.bytewise_less(left.path or "", right.path or "") or
            (left.path or "") == (right.path or "") and util.bytewise_less(left.message, right.message)
    end)
    return modules, owners, problems
end

-- One compiler diagnostic: `file:line:col: message`, with the project path
-- the editor knows. Lines and columns are 1-based UTF-8 byte positions.
local function diagnostic(text)
    local file, line, col, message = text:match("^%./([^:\n]+):(%d+):(%d+): (.*)$")
    if not file then file, line, col, message = text:match("^/([^:\n]+):(%d+):(%d+): (.*)$") end
    if file then
        return { message = message, severity = "error", path = file, line = tonumber(line), col = tonumber(col) }
    end
    return { message = text, severity = "error" }
end

local function add_diagnostics(list, seen, errors)
    if type(errors) == "string" then errors = { errors } end
    for _, text in ipairs(errors or {}) do
        for item in tostring(text):gmatch("[^\n]+") do
            if not seen[item] then
                seen[item] = true
                list[#list + 1] = diagnostic(item)
            end
        end
    end
end

-- Each request checks one complete snapshot from scratch: the process-wide
-- module and nominal registries start empty, so no module, edit or removal
-- of an earlier snapshot survives into this one.
local function with_context(self, files, options, run)
    local io = project_io(self, files)
    driver.imported, types.registry = {}, {}
    options.target, options.browser_analysis_target = "browser", self.handle
    options.io, options.transient_caches = io, true
    local context = driver.new_resolver_context(options)
    local results = table.pack(pcall(run, context))
    assert(driver.close_resolver_context(context))
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

-- Every project module, checked as a root with the analysis ABI.
function Service:check(files)
    return with_context(self, files, { analysis_only = true }, function(context)
        local modules, _, problems = project_modules(context, files)
        local roots = {}
        for _, modname in ipairs(modules) do roots[modname] = true end
        local loader = driver.defaultloader({}, { context = context, source_roots = roots })
        local diagnostics, seen = problems, {}
        for _, modname in ipairs(modules) do
            local ok, failure, errors = loader(modname)
            add_diagnostics(diagnostics, seen, ok and errors or failure)
            if not ok then add_diagnostics(diagnostics, seen, errors) end
        end
        return diagnostics
    end)
end

-- Zero-based byte offsets of a 1-based line/column location in `text`.
local function byte_offset(text, loc)
    local start = 0
    for _ = 2, loc.line do
        local newline = text:find("\n", start + 1, true)
        if not newline then return nil end
        start = newline
    end
    return start + loc.col - 1
end

local function project_span(files, loc, length)
    local path = type(loc) == "table" and type(loc.filename) == "string" and loc.filename:match("^%./(.+)$")
    local text = path and files[path]
    local from = text and byte_offset(text, loc)
    return from and { path = path, from = from, to = from + length } or nil
end

local function check_cursor(files, cursor)
    if type(cursor) ~= "table" or type(cursor.path) ~= "string" or type(files[cursor.path]) ~= "string" or
        math.type(cursor.offset) ~= "integer" or cursor.offset < 0 or cursor.offset > #files[cursor.path] then
        error("invalid cursor", 0)
    end
end

-- The module that owns the cursor's file, loaded as the only root; nil for a
-- file the target does not select.
local function load_cursor_module(context, files, cursor)
    local _, owners = project_modules(context, files)
    local modname = owners[cursor.path]
    if not modname then return nil end
    driver.defaultloader({}, { context = context, source_roots = { [modname] = true } })(modname)
    local mod = driver.imported[modname]
    return type(mod) == "table" and mod or nil
end

-- The declared type and documentation of the name under the cursor: the
-- innermost checked node whose written name covers it.
function Service:hover(files, cursor)
    check_cursor(files, cursor)
    return with_context(self, files, { analysis_only = true }, function(context)
        local mod = load_cursor_module(context, files, cursor)
        if not mod or not mod.ast then return nil end
        local best, best_span
        local visited = {}
        local function visit(node)
            if type(node) ~= "table" or visited[node] then return end
            visited[node] = true
            local name = type(node.name) == "string" and node.name or type(node.method) == "string" and node.method
            local span = name and node._name_loc and project_span(files, node._name_loc, #name)
            if span and span.path == cursor.path and span.from <= cursor.offset and cursor.offset <= span.to and
                (node._type or node._decl) and (not best_span or span.to - span.from <= best_span.to - best_span.from) then
                best, best_span = node, span
            end
            for key, child in pairs(node) do
                if type(key) ~= "string" or key:sub(1, 1) ~= "_" then visit(child) end
            end
        end
        visit(mod.ast)
        if not best then return nil end
        local decl = best._decl or best._method or best._field
        local typ = best._type or (type(decl) == "table" and decl.type)
        if not typ and type(decl) == "table" and (decl._tag == "Type.Method" or decl._tag == "Type.StaticMethod") then
            typ = completion.callable(decl, false)
        end
        local rendered, signature = pcall(types.tostring, typ)
        if not rendered then return nil end
        local name = best.name or best.method
        local result = { at = best_span, signature = name .. ": " .. signature }
        local doc = documentation.for_node(best) or (type(decl) == "table" and documentation.for_node(decl))
        if doc and doc.summary ~= "" then result.summary = doc.summary end
        if type(decl) == "table" and decl ~= best and type(decl.name) == "string" and decl._name_loc then
            result.declaration = project_span(files, decl._name_loc, #decl.name)
        end
        return result
    end)
end

local COMPLETION_KINDS = { [2] = "method", [3] = "function", [5] = "field", [6] = "variable",
    [8] = "interface", [9] = "module", [13] = "union", [22] = "record", [25] = "type" }

-- The import strings that name a module this snapshot can load, spelled as
-- the parser normalizes them: each standard-library module by its canonical
-- name and its shorthand, and every other project module both as a module
-- and, for private collaboration, as an explicit `.titan` source import. A
-- spelling the parser would normalize to another module is not offered.
local function import_candidates(self, modules, own)
    local items = {}
    local function offer(label, modname, detail)
        if parser.normalize_import(label) == modname then
            items[#items + 1] = { label = label, kind = "module", detail = detail }
        end
    end
    for _, modname in ipairs(modules) do
        if modname ~= own then
            offer(modname, modname, "project module")
            offer(modname .. ".titan", modname, "project module source")
        end
    end
    for _, modname in ipairs(self.sdk_modules) do
        offer(modname, modname, "standard library")
        local short = modname:match("^titan%.(.+)$")
        if short then offer(short, modname, "standard library") end
    end
    table.sort(items, function(left, right) return util.bytewise_less(left.label, right.label) end)
    return items
end

-- Candidates at the cursor: module names inside an import string, otherwise
-- the checker's candidates from a private transformed snapshot. The caller's
-- files are never changed.
function Service:complete(files, cursor)
    check_cursor(files, cursor)
    local prepared = completion.prepare("./" .. cursor.path, files[cursor.path], cursor.offset)
    if not prepared then return nil end
    local replace = { path = cursor.path, from = prepared.replacement_start, to = prepared.replacement_end }
    if prepared.kind == "import" then
        return with_context(self, files, { analysis_only = true }, function(context)
            local modules, owners = project_modules(context, files)
            if not owners[cursor.path] then return nil end
            return { replace = replace, items = import_candidates(self, modules, owners[cursor.path]) }
        end)
    end
    local snapshot = {}
    for name, contents in pairs(files) do snapshot[name] = contents end
    snapshot[cursor.path] = prepared.text
    local rows = with_context(self, snapshot, { analysis_only = true, completion = prepared.request },
        function(context)
            local mod = load_cursor_module(context, snapshot, cursor)
            return mod and mod.completion and mod.completion.candidates
        end)
    if not rows then return nil end
    local items = {}
    for _, row in ipairs(rows) do
        if row.available ~= false then
            local doc = row.documentation
            items[#items + 1] = { label = row.name, kind = COMPLETION_KINDS[row.kind] or "value",
                detail = row.detail, summary = doc and doc.summary ~= "" and doc.summary or nil }
        end
    end
    return { replace = replace, items = items }
end

-- The generated C of the `main` program: every project source module's
-- translation unit and headers, and the image entry declaring `identity`.
-- Language errors are diagnostics with no units.
function Service:emit_c(files, identity)
    if type(identity) ~= "string" or not identity:match("^" .. string.rep("[0-9a-f]", 64) .. "$") then
        error("image identity must be 64 lowercase hexadecimal digits", 0)
    end
    return with_context(self, files, { emit_c_only = true }, function(context)
        context.link_kind = "program"
        local loader = driver.defaultloader({}, { context = context, source_roots = { main = true } })
        local result = { files = {}, units = {}, entry = "", diagnostics = {} }
        local seen = {}
        local _, errors = checker.checkimport("main", loader)
        add_diagnostics(result.diagnostics, seen, errors)
        if #result.diagnostics > 0 then return result end
        if not checker.has_main(driver.imported.main.ast) then
            local _, owners = project_modules(context, files)
            local main_file
            for path, owner in pairs(owners) do
                if owner == "main" and (not main_file or util.bytewise_less(path, main_file)) then main_file = path end
            end
            result.diagnostics[1] = { message = "the main module must declare function main(args: {string}): integer",
                severity = "error", path = main_file, line = main_file and 1, col = main_file and 1 }
            return result
        end
        local finalized, finalize_errors = driver.finalize_resolver_context(context)
        if not finalized then
            add_diagnostics(result.diagnostics, seen, finalize_errors)
            return result
        end
        local sources = {}
        for name in pairs(context.source_names) do sources[#sources + 1] = name end
        table.sort(sources, util.bytewise_less)
        for _, name in ipairs(sources) do
            local emitted, emit_error = driver.emit_module_c(context, name)
            if not emitted then error(emit_error, 0) end
            result.files[emitted.unit.filename] = emitted.unit.code
            result.units[#result.units + 1] = emitted.unit.filename
            for _, header in ipairs(emitted.headers) do
                result.files[header.filename] = header.contents
            end
        end
        result.entry = ENTRY
        result.files[ENTRY] = driver.browser_entrypoint_contents("main", nil, { context = context }) ..
            browsertrace.declaration(identity)
        return result
    end)
end

-- The published image of an optimized link: the stripped Wasm, its source
-- map and trace table, the loader module embedding factory and loader, and,
-- for an image that links the storage runtime, that runtime's JavaScript
-- and its companions. `storage` holds the bundle's `vfs`, `sql` and
-- `worker` sources and its `sqlite` service bytes; `companions` lists each
-- `{ name, bytes }` to publish beside `app.wasm` (`app.worker.mjs`, then
-- `app.sqlite3.wasm`).
function playground.build_trace(linked, identity, factory, loader, storage)
    local image, map = browsertrace.dwarf_map(linked, IMAGE .. ".map", IMAGE)
    if not image then return nil, map end
    local inventory, err, oversized = browserlink.image_inventory(image)
    if not inventory then
        if oversized then
            local location, source_error = browsertrace.function_source(map, oversized)
            err = err .. (location and ("; first mapped source " .. location) or
                ("; source unavailable (" .. tostring(source_error) .. ")"))
        end
        return nil, err
    end
    local trace
    map, trace = browsertrace.rewrite(image, map, identity, IMAGE .. ".map")
    if not map then return nil, trace end
    local linked_storage, embedded, companions = browserlink.storage(inventory.imports), nil, {}
    if linked_storage then
        if type(storage) ~= "table" then
            return nil, "this image links the browser storage runtime; pass the bundle's storage sources"
        end
        for _, key in ipairs(linked_storage == "sql" and { "vfs", "worker", "sql", "sqlite" } or { "vfs", "worker" }) do
            if type(storage[key]) ~= "string" then
                return nil, "the bundle's storage source '" .. key .. "' must be a string"
            end
        end
        local worker, sqlite = browserlink.companion_names(IMAGE)
        embedded = { vfs = storage.vfs }
        companions[1] = { name = worker, bytes = browserlink.worker_module(storage.worker, identity) }
        if linked_storage == "sql" then
            embedded.sql = storage.sql
            embedded.sqlite_sha256 = sha256.hex_via(require("titan")._sha256_binary, storage.sqlite)
            companions[2] = { name = sqlite, bytes = storage.sqlite }
        end
    end
    local module
    module, err = browserlink.embed(factory, loader, IMAGE, identity, embedded)
    if not module then return nil, err end
    return { mjs = module, wasm = image, trace = trace, map = map, companions = companions }
end

-- The titanc.wasm protocol, private to that host and its titanc.mjs adapter.
-- A message is a little-endian u32 count of u32-length-prefixed byte
-- strings. Requests name an operation then its arguments (file maps as
-- path/contents pairs, byte offsets in decimal); replies are `ok` and a JSON
-- result, or `error` and a message. Image bytes travel as further strings.
local ARRAY = {}

local function array(list)
    return setmetatable(list or {}, ARRAY)
end

local ESCAPES = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function encode_json(value, out)
    local kind = type(value)
    if value == nil then
        out[#out + 1] = "null"
    elseif kind == "boolean" then
        out[#out + 1] = tostring(value)
    elseif math.type(value) == "integer" then
        out[#out + 1] = string.format("%d", value)
    elseif kind == "string" then
        out[#out + 1] = '"' .. value:gsub('[%c"\\]', function(char)
            return ESCAPES[char] or string.format("\\u%04x", char:byte())
        end) .. '"'
    elseif kind == "table" and (getmetatable(value) == ARRAY or value[1] ~= nil) then
        out[#out + 1] = "["
        for index, item in ipairs(value) do
            if index > 1 then out[#out + 1] = "," end
            encode_json(item, out)
        end
        out[#out + 1] = "]"
    elseif kind == "table" then
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, util.bytewise_less)
        out[#out + 1] = "{"
        for index, key in ipairs(keys) do
            if index > 1 then out[#out + 1] = "," end
            encode_json(key, out)
            out[#out + 1] = ":"
            encode_json(value[key], out)
        end
        out[#out + 1] = "}"
    else
        error("cannot encode " .. kind .. " as JSON", 0)
    end
    return out
end

local function decode_message(bytes)
    local count, position = string.unpack("<I4", bytes)
    local strings = {}
    for index = 1, count do strings[index], position = string.unpack("<s4", bytes, position) end
    if position ~= #bytes + 1 then error("malformed titanc request", 0) end
    return strings
end

local function encode_message(...)
    local strings = table.pack(...)
    local parts = { string.pack("<I4", strings.n) }
    for index = 1, strings.n do parts[index + 1] = string.pack("<s4", strings[index]) end
    return table.concat(parts)
end

local function file_map(strings, first)
    local files = {}
    for index = first, #strings, 2 do
        if strings[index + 1] == nil or files[strings[index]] ~= nil then error("malformed project files", 0) end
        files[strings[index]] = strings[index + 1]
    end
    return files
end

local function cursor(strings)
    return { path = strings[2], offset = math.tointeger(tonumber(strings[3])) }
end

local function ok(value)
    return encode_message("ok", table.concat(encode_json(value, {})))
end

local operations = {}

function operations.check(service, strings)
    return ok(array(service:check(file_map(strings, 2))))
end

function operations.hover(service, strings)
    return ok(service:hover(file_map(strings, 4), cursor(strings)))
end

function operations.complete(service, strings)
    local result = service:complete(file_map(strings, 4), cursor(strings))
    if result then array(result.items) end
    return ok(result)
end

function operations.emit_c(service, strings)
    local result = service:emit_c(file_map(strings, 3), strings[2])
    array(result.units)
    array(result.diagnostics)
    return ok(result)
end

-- The bundle's storage sources follow the loader, all four or none.
function operations.build_trace(_, strings)
    if strings[6] ~= nil and strings[9] == nil then error("incomplete browser storage sources", 0) end
    local image, err = playground.build_trace(strings[2], strings[3], strings[4], strings[5], strings[6] and
        { vfs = strings[6], sql = strings[7], worker = strings[8], sqlite = strings[9] })
    if not image then error(err, 0) end
    local names, files = array(), {}
    for index, companion in ipairs(image.companions) do
        names[index], files[index] = companion.name, companion.bytes
    end
    return encode_message("ok", table.concat(encode_json(names, {})), image.mjs, image.wasm, image.trace, image.map,
        table.unpack(files))
end

-- The request handler titanc.wasm keeps: `open` first, with the catalog,
-- analysis-target and absent-modules bytes; then any operation.
function playground.host()
    local service
    return function(request)
        local called, reply = xpcall(function()
            local strings = decode_message(request)
            local operation = strings[1]
            if operation == "open" then
                local opened, err = playground.open({ catalog = strings[2], analysis_target = strings[3],
                    absent_modules = strings[4] })
                if not opened then error(err, 0) end
                service = opened
                return ok(true)
            end
            if not service then error("the playground compiler is not open", 0) end
            local handler = operations[operation]
            if not handler then error("unknown playground operation " .. tostring(operation), 0) end
            return handler(service, strings)
        end, function(err)
            return type(err) == "string" and err or debug.traceback(tostring(err))
        end)
        if called then return reply end
        return encode_message("error", reply)
    end
end

return playground
