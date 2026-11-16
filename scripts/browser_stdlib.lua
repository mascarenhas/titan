-- Build-owned core-stdlib checks; deliberately not part of titanc's user link path.
local staticmetadata = require "titan-compiler.staticmetadata"
local objectmetadata = require "titan-compiler.objectmetadata"
local linkcertificate = require "titan-compiler.linkcertificate"
local depfile = require "titan-compiler.depfile"
local driver = require "titan-compiler.driver"
local types = require "titan-compiler.types"
local util = require "titan-compiler.util"
local build = require "titan-compiler.build"
local M = {}

-- The reviewed operation-status inventory: every native module, and every
-- public callable, type and variable of a present one, with its browser
-- status and the test that proves it. The other checks read their module
-- lists from it.
local directory = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
M.status_inventory = dofile(directory .. "browser_stdlib_inventory.lua")
M.absent_modules = {}
local absent_modules, browser_only_modules = {}, {}
for _, row in ipairs(M.status_inventory.modules) do
    if row[2] == "absent" then
        M.absent_modules[#M.absent_modules + 1] = row[1]
        absent_modules[row[1]] = true
    elseif row[2] == "browser-only" then
        browser_only_modules[row[1]] = true
    end
end

-- The Make inventory is literal, with the same continuation convention as the
-- native source audits. Gates consume it instead of keeping another root list.
function M.browser_roots(strategy, filename)
    local contents, err = strategy:read_file(filename or "Makefile")
    if not contents then return nil, err end
    local roots, collecting, found = {}, false, false
    for line in (contents .. "\n"):gmatch("(.-)\n") do
        local value = collecting and line or
            line:match("^BROWSER_STDLIB_ROOTS%s*:=%s*(.*)$")
        if value then
            found = true
            collecting = value:match("\\%s*$") ~= nil
            for root in value:gsub("\\%s*$", ""):gmatch("%S+") do
                roots[#roots + 1] = root
            end
            if not collecting then break end
        end
    end
    if not found or collecting or #roots == 0 then
        return nil, "missing, empty or unterminated BROWSER_STDLIB_ROOTS"
    end
    return roots
end

-- Discover logical candidates, but let the compiler choose their actual files:
-- defaults shadowed by variants and constituents of absent folders stay unread.
-- The caller owns an activated browser resolver context. Returns the selected
-- files, sorted, so source audits can cover the browser-only ones.
function M.check_sources(context, tree)
    local strategy, modules, sources = context.io, {}, {}
    local function inspect(name)
        if modules[name] or not staticmetadata.valid_module_name(name) then return true end
        modules[name] = true
        local source, err = driver.resolve_source(context, name, tree)
        if err then return nil, err end
        if not source or source.kind == "blocked" then return true end
        for _, file in ipairs(source.files or { source.main }) do
            if not sources[file] then
                sources[file] = true
                local imports
                imports, err = build.imports_for(strategy, { main = file })
                if not imports then return nil, err end
                for _, import in ipairs(imports) do
                    if absent_modules[import.name] then
                        return nil, file .. ": forbidden browser stdlib import " .. import.name
                    end
                end
            end
        end
        return true
    end
    local function visit(directory, prefix)
        local entries, err = strategy:list(directory)
        if not entries then return nil, err end
        table.sort(entries, util.bytewise_less)
        if prefix ~= "titan" then
            local ok
            ok, err = inspect(prefix)
            if not ok then return nil, err end
        end
        for _, name in ipairs(entries) do
            local filename = directory .. "/" .. name
            local info
            info, err = strategy:stat(filename)
            if not info then return nil, err end
            local ok = true
            if info.kind == "directory" then
                ok, err = visit(filename, prefix .. "." .. name)
            elseif info.kind == "file" then
                local logical = driver.classify_source_filename(name)
                if logical then
                    ok, err = inspect(prefix .. "." .. logical:gsub("%.titan$", ""))
                end
            end
            if not ok then return nil, err end
        end
        return true
    end
    local ok, err = visit(tree .. "/titan", "titan")
    if not ok then return nil, err end
    local selected = {}
    for file in pairs(sources) do selected[#selected + 1] = file end
    table.sort(selected, util.bytewise_less)
    return selected
end

function M.check_path(path)
    local normalized = "/" .. path:gsub("\\", "/"):lower()
    local name = normalized:match("([^/]+)$") or normalized
    local header = name:match("%.h$") and (
        name == "uv.h" or normalized:find("/uv/", 1, true) or
        normalized:find("/libuv/", 1, true) or normalized:find("/openssl/", 1, true) or
        name == "llhttp.h" or normalized:find("/llhttp/", 1, true) or
        name == "sqlite3.h" or name == "sqlite3ext.h" or normalized:find("/sqlite3/", 1, true))
    local archive = name:match("%.a$") and (
        name:match("^libuv[%._-]") or name:match("^libssl[%._-]") or
        name:match("^libcrypto[%._-]") or name:match("^libopenssl[%._-]") or
        name:match("^libllhttp[%._-]") or name:match("^libsqlite3[%._-]") or
        name:match("^libtitan%-llhttp[%._-]") or name:match("^libtitan%-sqlite3[%._-]"))
    if header or archive then return nil, "forbidden browser stdlib dependency: " .. path end
    return true
end

function M.check_symbol(name, origin)
    if type(name) == "string" and (name:match("^uv_") or name:match("^SSL_") or
        name:match("^OPENSSL_") or name:match("^llhttp_") or name:match("^sqlite3_")) then
        return nil, origin .. ": forbidden browser stdlib symbol " .. name
    end
    return true
end

function M.check_headers(record)
    for _, dependency in ipairs(record.c_header_dependencies or {}) do
        local ok, err = M.check_path(dependency.path)
        if not ok then return nil, err end
    end
    return true
end

local function check_object(object, bytes, origin)
    local module = object.metadata and object.metadata.module
    if absent_modules[module] then
        return nil, origin .. ": forbidden browser stdlib module " .. module
    end
    for _, symbol in ipairs(object.symbols or {}) do
        local ok, err = M.check_symbol(symbol.name, origin)
        if not ok then return nil, err end
    end
    for _, import in ipairs(object.imports or {}) do
        local ok, err = M.check_symbol(import.name, origin)
        if not ok then return nil, err end
    end
    for _, section in ipairs(object.sections or {}) do
        if section.name == ".titan.source" then
            local record, err = objectmetadata.read(bytes, origin)
            if not record then return nil, err end
            return M.check_headers(record)
        end
    end
    return true
end

function M.check_archive(filename, scanned)
    local ok, err = M.check_path(filename)
    if not ok then return nil, err end
    if not scanned then
        scanned, err = staticmetadata.scan_archive(filename)
        if not scanned then return nil, err end
    end
    for _, member in ipairs(scanned.members or {}) do
        local origin = filename .. "(" .. member.display_name .. ")"
        ok, err = M.check_path(member.display_name)
        if not ok then return nil, err end
        ok, err = check_object(member.object, member.bytes, origin)
        if not ok then return nil, err end
    end
    return true
end

-- Inspect the image's imports, exports and internal function names, not just
-- its public exports: dead-stripping must not conceal a linked host dependency.
function M.check_image(bytes, origin)
    local image, err = staticmetadata.browser_trace_image(bytes, origin)
    if not image then return nil, err end
    for _, import in ipairs(image.imports) do
        if import.kind == 0 and (import.name:match("^__syscall_") or
            import.name:match("^fd_") or import.name == "_emscripten_system") then
            return nil, origin .. ": forbidden browser filesystem import " .. import.name
        end
    end
    for _, inventory in ipairs({ image.imports, image.exports }) do
        for _, symbol in ipairs(inventory) do
            local ok
            ok, err = M.check_symbol(symbol.name, origin)
            if not ok then return nil, err end
        end
    end
    if next(image.function_names) == nil then return nil, origin .. ": missing function name inventory" end
    for _, name in pairs(image.function_names) do
        local ok
        ok, err = M.check_symbol(name, origin)
        if not ok then return nil, err end
    end
    return true
end

function M.check_output(strategy, directory)
    local root, err = strategy:realpath(directory)
    if not root then return nil, err end
    local seen = {}
    local context = { io = strategy, cache_adapter = { sha256_binary = require("titan")._sha256_binary } }

    local function check_dependencies(filename, required)
        local dependencies = filename:gsub("%.o$", ".d")
        local info, dependency_error = strategy:stat(dependencies)
        if not info then
            if required or dependency_error then
                return nil, dependency_error or ("missing authored-C header provenance: " .. dependencies)
            end
            return true
        end
        local bytes
        bytes, dependency_error = strategy:read_file(dependencies)
        if not bytes then return nil, dependency_error end
        local inputs
        inputs, dependency_error = depfile.parse(bytes)
        if not inputs or #inputs == 0 then
            return nil, dependency_error or ("invalid authored-C header provenance: " .. dependencies)
        end
        for _, input in ipairs(inputs) do
            local ok
            ok, dependency_error = M.check_path(input)
            if not ok then return nil, dependency_error end
        end
        return true
    end

    local function check_native(filename, required_headers)
        local ok, native_error = M.check_path(filename)
        if not ok then return nil, native_error end
        local physical
        physical, native_error = strategy:realpath(filename)
        if not physical then return nil, native_error end
        local normalized = physical:gsub("\\", "/")
        if normalized:match("/%.native/[^/]+%.o$") then
            ok, native_error = check_dependencies(physical, required_headers)
            if not ok then return nil, native_error end
        elseif required_headers then
            return nil, "invalid authored-C input path: " .. filename
        end
        local info
        info, native_error = strategy:stat(filename)
        if not info then return nil, native_error end
        local key = info.device ~= nil and info.inode ~= nil and
            ("inode:" .. tostring(info.device) .. ":" .. tostring(info.inode)) or ("path:" .. physical)
        local observation = table.concat({
            tostring(info.size), tostring(info.mode),
            tostring(info.modified_seconds), tostring(info.modified_nanoseconds),
            tostring(info.changed_seconds), tostring(info.changed_nanoseconds), tostring(info.time_precision),
        }, ":")
        if seen[key] == observation then return true end
        if filename:match("%.a$") then
            -- libclang_rt.builtins.a includes __c_longjmp.o with a different
            -- feature vector. This is a content audit, not provider ABI selection.
            local scanned
            scanned, native_error = staticmetadata.scan_archive(filename, { io = strategy, independent_members = true })
            if not scanned then return nil, native_error end
            ok, native_error = M.check_archive(filename, scanned)
        else
            local bytes
            bytes, native_error = strategy:read_file(filename)
            if not bytes then return nil, native_error end
            local object
            object, native_error = staticmetadata.classify_object(bytes, filename)
            if not object then return nil, native_error end
            ok, native_error = check_object(object, bytes, filename)
        end
        if not ok then return nil, native_error end
        seen[key] = observation
        return true
    end

    local function visit(current)
        local entries, visit_error = strategy:list(current)
        if not entries then return nil, visit_error end
        if current:gsub("\\", "/"):match("/%.native$") then
            local inventory
            inventory, visit_error = linkcertificate.read_record(context, current .. "/inputs")
            if not inventory or type(inventory.inputs) ~= "table" then
                return nil, visit_error or ("missing authored-C input inventory: " .. current)
            end
            local count = 0
            for index, input in pairs(inventory.inputs) do
                if math.type(index) ~= "integer" or index < 1 or index > #inventory.inputs or
                        type(input) ~= "string" then
                    return nil, "invalid authored-C input inventory: " .. current
                end
                count = count + 1
            end
            if count ~= #inventory.inputs then return nil, "invalid authored-C input inventory: " .. current end
            for _, input in ipairs(inventory.inputs) do
                local ok
                ok, visit_error = check_native(input, true)
                if not ok then return nil, visit_error end
            end
        end
        for _, name in ipairs(entries) do
            local filename = current .. "/" .. name
            local info
            info, visit_error = strategy:lstat(filename)
            if not info then return nil, visit_error end
            local ok
            if info.kind == "directory" then
                ok, visit_error = visit(filename)
            elseif info.kind == "file" and name:match("%.o$") then
                ok, visit_error = check_native(filename, false)
            elseif info.kind == "file" and name == "record" and current:find("/.titan-links/", 1, true) then
                local record
                record, visit_error = linkcertificate.read_record(context, filename)
                if not record then return nil, visit_error end
                for _, input in ipairs(record.native or {}) do
                    ok, visit_error = M.check_path(input.path)
                    if not ok then return nil, visit_error end
                    if input.path:match("%.o$") or input.path:match("%.a$") then
                        local physical
                        physical, visit_error = strategy:realpath(input.path)
                        if not physical then return nil, visit_error end
                        local authored = physical:sub(1, #root + 1) == root .. "/" and
                            physical:gsub("\\", "/"):match("/%.native/[^/]+%.o$") ~= nil
                        ok, visit_error = check_native(input.path, authored)
                        if not ok then return nil, visit_error end
                    end
                end
                ok = true
            else
                ok = true
            end
            if not ok then return nil, visit_error end
        end
        return true
    end
    return visit(directory)
end

-- Inventory public declarations, nominal fields, variants, methods and statics.
-- CFunction members are raw foreign exports, not Lua-facing function slots.
function M.members(modtype)
    local result = {}
    local function add(name, kind, typ, suffix, declaration)
        if result[name] then error("duplicate public member " .. name) end
        result[name] = { kind = kind, signature = types.tostring(typ) .. (suffix or ""),
            semantic = types.serialize_semantic(declaration or typ) }
    end
    local function nominal_members(name, typ)
        for _, field in ipairs(typ.fields or {}) do
            if not field.islocal then
                add(name .. "." .. field.name, "field", field.type,
                    field.isconst and " (readonly)" or nil)
            end
        end
        for _, variant in ipairs(typ.variants or {}) do
            if not variant.islocal then
                local parts = {}
                for _, part in ipairs(variant.parts) do
                    parts[#parts + 1] = part.name .. ": " .. types.tostring(part.type)
                end
                add(name .. "." .. variant.name, "variant", variant, "(" .. table.concat(parts, ", ") .. ")")
            end
        end
        -- Interface methods have both ordered and named views; use their
        -- declaration order once, while record and union methods are maps.
        local each = typ._tag == "Type.Interface" and ipairs or pairs
        for _, group in ipairs({ typ.methods or {}, typ.functions or {} }) do
            for _, method in each(group) do
                if not method.islocal then
                    local key = name .. (method._tag == "Type.Method" and ":" or ".") .. method.name
                    -- A union variant's generated static constructor is the
                    -- same public member; its full type is also in the union.
                    if not (result[key] and result[key].kind == "variant") then
                        add(key, method._tag == "Type.Method" and "method" or "static function", method)
                    end
                end
            end
        end
    end
    for _, member in ipairs(modtype.members) do
        local typ = member.type
        local kind = member._tag == "Type.ModuleVariable" and "variable" or
            typ._tag == "Type.CFunction" and "raw foreign function" or
            typ._tag == "Type.Record" and "record" or
            typ._tag == "Type.Union" and "union" or "function"
        add(member.name, kind, typ, member.isconst and " (const)" or nil, member)
        nominal_members(member.name, typ)
    end
    for name, typ in pairs(modtype.type_members or {}) do
        add(name, typ._tag == "Type.Interface" and "interface" or "type alias", typ)
        nominal_members(name, typ)
    end
    return result
end

-- A canonical copy of a decoded interface for comparison across targets.
-- Serialization records a record's total field count and each public field's
-- physical index, and likewise for union variants, so private layout would
-- otherwise leak into the comparison. The copy keeps only what private
-- members change for importers: a record keeps one hidden field when the
-- checker rejects its literals outside its module (a private field and no
-- custom constructor), and a union keeps one hidden variant when `case`
-- cannot cover it. Public fields and variants are renumbered by position,
-- from 0 as serialized indices are.
-- `absent` names owner members (`Owner:method`, `Owner.static`) to drop, and
-- module members are sorted by name.
function M.normalize(modtype, absent)
    absent = absent or {}
    local function present(owner, group, separator)
        local result = {}
        for name, member in pairs(group) do
            if not absent[owner .. separator .. name] then result[name] = member end
        end
        return result
    end
    local function declaration(owner, typ)
        if typ._tag == "Type.Record" then
            local fields = {}
            for index, field in ipairs(typ.fields) do
                fields[index] = types.Field(field.fqtn, field.name, field.type, index - 1, field.isconst)
            end
            local hidden = (typ.nfields or #typ.fields) > #typ.fields and not typ.custom_constructor
            return types.Record(typ.name, fields, present(owner, typ.functions, "."),
                present(owner, typ.methods, ":"), #fields + (hidden and 1 or 0),
                typ.scope, typ.typeparams, typ.custom_constructor)
        elseif typ._tag == "Type.Union" then
            local variants = {}
            for index, variant in ipairs(typ.variants) do
                variants[index] = types.Variant(variant.fqtn, variant.name, variant.parts, index - 1)
            end
            local hidden = (typ.nvariants or #typ.variants) > #typ.variants
            return types.Union(typ.name, variants, present(owner, typ.functions, "."),
                present(owner, typ.methods, ":"), #variants + (hidden and 1 or 0),
                typ.scope, typ.typeparams)
        end
        return typ
    end
    local members = {}
    for index, member in ipairs(modtype.members) do
        if member._tag == "Type.ModuleMember" then
            members[index] = types.ModuleMember(member.modname, member.name,
                declaration(member.name, member.type), member.paramnames)
        else
            members[index] = member
        end
    end
    table.sort(members, function(a, b) return util.bytewise_less(a.name, b.name) end)
    local type_members = {}
    for name, typ in pairs(modtype.type_members or {}) do type_members[name] = declaration(name, typ) end
    return types.Module(modtype.name, members, type_members)
end

-- The omissions the comparison accepts, by module: the inventory's absent
-- members. A browser-only module (`titan.browser`) has no native interface
-- to compare, so the comparison skips it.
function M.omissions(inventory)
    local result = {}
    for modname, rows in pairs(inventory.members) do
        local omitted = {}
        for _, row in ipairs(rows) do
            if row[2]:match("^absent:") then omitted[#omitted + 1] = row[1] end
        end
        result[modname] = { omitted = omitted }
    end
    return result
end

-- Every other member must keep its native kind, rendered signature and
-- normalized semantic declaration; the native owners of omitted methods and
-- statics drop them first, while omissions themselves are checked against
-- the native interface as declared. Machine layouts live in separate provider
-- metadata and are deliberately not compared. Returns the shared member rows,
-- the number of compared shared modules and the recorded difference rows.
function M.inventory(native, browser, recorded_differences)
    recorded_differences = recorded_differences or M.omissions(M.status_inventory)
    local rows, recorded_rows, differences, modules = {}, {}, {}, 0
    for _, modname in ipairs(browser.key_order) do
        if not browser_only_modules[modname] then
            local browser_entry, native_entry = browser.entries[modname], native.entries[modname]
            if not native_entry then return nil, "missing native module " .. modname end
            modules = modules + 1
            local native_type = assert(driver.decode_module_interface(native_entry.types, modname, "native interface"))
            local declared = M.members(native_type)
            local recorded = recorded_differences[modname] or {}
            local omitted = {}
            for _, name in ipairs(recorded.omitted or {}) do omitted[name] = true end
            local b = M.members(M.normalize(assert(driver.decode_module_interface(
                browser_entry.types, modname, "browser interface"))))
            local n = M.members(M.normalize(native_type, omitted))
            for _, name in ipairs(recorded.omitted or {}) do
                if not declared[name] then
                    differences[#differences + 1] = modname .. "." .. name .. ": recorded omission is not a native member"
                elseif b[name] then
                    differences[#differences + 1] = modname .. "." .. name .. ": recorded omission is in the browser interface"
                else
                    recorded_rows[#recorded_rows + 1] = { module = modname, name = name, difference = "omitted",
                        kind = declared[name].kind, signature = declared[name].signature }
                end
            end
            local names, seen = {}, {}
            for name in pairs(b) do names[#names + 1], seen[name] = name, true end
            for name in pairs(n) do if not seen[name] then names[#names + 1] = name end end
            table.sort(names, util.bytewise_less)
            for _, name in ipairs(names) do
                local bm, nm = b[name], n[name]
                local owner = name:match("^([^.:]+)[.:]")
                if nm and not bm and (omitted[name] or (owner and omitted[owner] and not b[owner])) then
                    -- Recorded above, or a member of an omitted record.
                elseif not bm or not nm or bm.kind ~= nm.kind or bm.signature ~= nm.signature or bm.semantic ~= nm.semantic then
                    differences[#differences + 1] = modname .. "." .. name .. ": native=" ..
                        (nm and nm.signature or "<absent>") .. "; browser=" .. (bm and bm.signature or "<absent>") ..
                        (bm and nm and bm.semantic ~= nm.semantic and " (semantic declaration differs)" or "")
                else
                    rows[#rows + 1] = { module = modname, name = name, kind = bm.kind, signature = bm.signature }
                end
            end
        end
    end
    if #differences > 0 then return nil, "unrecorded public interface differences:\n" .. table.concat(differences, "\n") end
    return rows, modules, recorded_rows
end

local member_statuses = { implemented = true, raise = true, ["type-only"] = true,
    ["absent:typed"] = true, ["absent:native-only"] = true }
local module_statuses = { present = true, absent = true, ["browser-only"] = true }

-- Inventory rows cover callables, types and variables. Fields, union variants
-- (with their constructors) and Interface methods belong to their owner's
-- declaration, which the comparison checks whole.
function M.status_scope(members)
    local scope = {}
    for name, row in pairs(members) do
        local owner = name:match("^([^.:]+)[.:]")
        if row.kind ~= "field" and row.kind ~= "variant" and
            not (owner and members[owner] and members[owner].kind == "interface") then
            scope[name] = row
        end
    end
    return scope
end

-- How a row names its test: `<owner>.<case>` as the runner reports it, with
-- subtests joined by `.`; `os.browser_tests:<name>` for a case of the
-- program-mode OS stream harness; or a whole `<owner>`.
function M.test_reference(test)
    if type(test) ~= "string" then return nil end
    if test:match("^os%.browser_tests:[^%s]+$") then return "harness" end
    if not test:match("^[%w_]+%.[%w_.]*[%w_]$") or test:find("..", 1, true) then return nil end
    return select(2, test:gsub("%.", "")) == 1 and "owner" or "case"
end

-- Test owners outside the browser stdlib image, with the real-toolchain gate
-- that runs them under Node and Chromium and checks their evidence.
M.harness_owners = {
    ["async.browser_tests"] = "spec/coder/browser_scheduler_spec.lua",
    ["os.browser_tests"] = "spec/coder/browser_scheduler_spec.lua",
    ["http.browser_tests"] = "spec/coder/browser_net_spec.lua",
    ["websocket.browser_tests"] = "spec/coder/browser_net_spec.lua",
}

-- Every test the inventory names, with its owner and the row naming it.
function M.test_references(inventory)
    local result = {}
    local function add(test, label)
        local kind = M.test_reference(test)
        if kind then
            result[#result + 1] = { test = test, kind = kind, label = label,
                owner = kind == "harness" and "os.browser_tests" or test:match("^[%w_]+%.[%w_]+") }
        end
    end
    for _, row in ipairs(inventory.modules) do add(row.test, row[1]) end
    for modname, rows in pairs(inventory.members) do
        for _, row in ipairs(rows) do add(row[3], modname .. "." .. row[1]) end
    end
    for _, row in ipairs(inventory.stock_lua or {}) do add(row[3], "stock Lua " .. row[1]) end
    return result
end

-- The cases a run reports as passed: runner lines `[       OK ] <case>
-- (<ms> ms)`, and the case names of a passing OS stream harness summary. A
-- parent reports OK after its subtests whatever their outcome, so it counts
-- only when none of them was skipped or failed.
function M.passed_cases(output)
    local passed, unfinished = {}, {}
    for raw in (output .. "\n"):gmatch("([^\n]*)\n") do
        local line = raw:gsub("\r$", "")
        local name = line:match("^%[       OK %] (.-) %(%d+%.%d%d ms%)$")
        if name then passed[name] = true end
        local other = line:match("^%[  SKIPPED %] (.*)$") or line:match("^%[  FAILED  %] (.*)$")
        if other then unfinished[#unfinished + 1] = other end
    end
    for name in pairs(passed) do
        local prefix = name .. "."
        for _, text in ipairs(unfinished) do
            if text:sub(1, #prefix) == prefix then passed[name] = nil; break end
        end
    end
    local summary = output:match("OS%-STREAMS (%b{})")
    if summary and summary:find('"verdict":"PASS"', 1, true) then
        for name in (summary:match('"names":(%b[])') or ""):gmatch('"([^"]*)"') do
            passed["os.browser_tests:" .. name] = true
        end
    end
    return passed
end

-- Every inventory test whose owner the run covers must have passed in it: a
-- named case exactly, a whole owner through at least one passed case.
-- Skipped cases never count.
function M.require_evidence(inventory, output, owners)
    local passed, missing = M.passed_cases(output), {}
    for _, reference in ipairs(M.test_references(inventory)) do
        if owners[reference.owner] then
            local found = passed[reference.test]
            if reference.kind == "owner" then
                local prefix = reference.test .. "."
                for name in pairs(passed) do
                    if name:sub(1, #prefix) == prefix then found = true; break end
                end
            end
            if not found then missing[#missing + 1] = reference.label .. ": " .. reference.test end
        end
    end
    if #missing > 0 then
        table.sort(missing, util.bytewise_less)
        return nil, "inventory tests that did not pass:\n" .. table.concat(missing, "\n")
    end
    return true
end

-- The declaration that classifies an absent owner: its own fields, variant
-- payloads and generic scope, without the methods and statics that have rows
-- of their own.
local function owner_declaration(modtype, name)
    local member = modtype.members[name]
    local typ = member and member._tag == "Type.ModuleMember" and member.type or (modtype.type_members or {})[name]
    if typ and typ._tag == "Type.Record" then
        return types.Record(typ.name, typ.fields, {}, {}, typ.nfields, typ.scope, typ.typeparams,
            typ.custom_constructor)
    elseif typ and typ._tag == "Type.Union" then
        return types.Union(typ.name, typ.variants, {}, {}, typ.nvariants, typ.scope, typ.typeparams)
    end
    return nil
end

-- Whether some browser declaration other than an exempt one can hand out a
-- value of `fqtn`. Results, readable fields, variant payloads and the
-- parameters of function-typed parameters are positive positions; mutable
-- Arrays, Maps, generic arguments and mutable variables are both.
local function reaches(typ, fqtn, polarity)
    local tag = typ and typ._tag
    local function each(list, sign)
        for _, item in ipairs(list or {}) do
            if reaches(item, fqtn, sign) then return true end
        end
        return false
    end
    local flipped = polarity == "+" and "-" or polarity == "-" and "+" or "both"
    if tag == "Type.Nominal" then
        return (typ.fqtn == fqtn and polarity ~= "-") or each(typ.args, "both")
    elseif tag == "Type.Option" then
        return reaches(typ.base, fqtn, polarity)
    elseif tag == "Type.Array" then
        return reaches(typ.elem, fqtn, typ.isconst.tag == "yes" and polarity or "both")
    elseif tag == "Type.Map" then
        return reaches(typ.keys, fqtn, "both") or reaches(typ.values, fqtn, "both")
    elseif tag == "Type.Function" or tag == "Type.Method" or tag == "Type.StaticMethod" then
        return each(typ.rettypes, polarity) or reaches(typ.flexrettype, fqtn, polarity) or
            each(typ.params, flipped) or reaches(typ.varargtype, fqtn, flipped) or each(typ.typeparams, "both")
    elseif tag == "Type.FunctionScheme" then
        return reaches(typ.signature, fqtn, polarity) or each(typ.typeparams, "both")
    elseif tag == "Type.TypeParameter" then
        return reaches(typ.constraint, fqtn, "both")
    elseif tag == "Type.Parameter" then
        return reaches(typ.erased_constraint, fqtn, "both")
    elseif tag == "Type.GenericAlias" then
        return typ.target_owner_fqtn == fqtn or each(typ.typeparams, "both")
    elseif tag == "Type.Record" or tag == "Type.Interface" then
        for _, field in ipairs(typ.fields) do
            if reaches(field.type, fqtn, polarity) then return true end
        end
        for _, group in ipairs({ typ.methods or {}, typ.functions or {} }) do
            for _, method in pairs(group) do
                if type(method) == "table" and reaches(method, fqtn, polarity) then return true end
            end
        end
        return each(typ.typeparams, "both")
    elseif tag == "Type.Union" then
        for _, variant in ipairs(typ.variants) do
            for _, part in ipairs(variant.parts) do
                if reaches(part.type, fqtn, polarity) then return true end
            end
        end
        for _, group in ipairs({ typ.methods, typ.functions }) do
            for _, method in pairs(group) do
                if reaches(method, fqtn, polarity) then return true end
            end
        end
        return each(typ.typeparams, "both")
    end
    return false
end

-- A type-only owner cannot be built without a callable, and nothing in any
-- browser module except a `raise` member or the owner's own instance methods
-- and fields can produce one. `modules` lists every decoded browser module
-- with its module name and the names of its `raise` members. Returns nil or
-- the reason the owner is reachable.
local function type_only_violation(modtype, name, modules)
    local member = modtype.members[name]
    local owner = member and member._tag == "Type.ModuleMember" and member.type
    if not owner or (owner._tag ~= "Type.Record" and owner._tag ~= "Type.Union") then
        return "is not a record or union"
    end
    if owner._tag == "Type.Record" and not owner.custom_constructor and (owner.nfields or #owner.fields) == #owner.fields then
        return "can be built from a record literal"
    elseif owner._tag == "Type.Union" and #owner.variants > 0 then
        return "has public variants"
    end
    local fqtn = owner.name
    for _, scanned in ipairs(modules) do
        local raising, prefix = scanned.raising, scanned.modname .. "."
        local function check(label, typ, polarity)
            if not raising[label] and reaches(typ, fqtn, polarity) then return "is reachable through " .. prefix .. label end
            return nil
        end
        for _, other in ipairs(scanned.type.members) do
            local typ, err = other.type, nil
            if other == member then
                for static_name, static in pairs(owner.functions) do
                    err = err or check(name .. "." .. static_name, static, "+")
                end
            elseif other._tag == "Type.ModuleVariable" then
                err = check(other.name, typ, other.isconst and "+" or "both")
            elseif typ._tag == "Type.Record" or typ._tag == "Type.Union" then
                for _, group in ipairs({ typ.methods, typ.functions }) do
                    for method_name, method in pairs(group) do
                        local key = other.name .. (method._tag == "Type.Method" and ":" or ".") .. method_name
                        err = err or check(key, method, "+")
                    end
                end
                err = err or check(other.name, owner_declaration(scanned.type, other.name), "+")
            else
                err = check(other.name, typ, "+")
            end
            if err then return err end
        end
        for alias, typ in pairs(scanned.type.type_members or {}) do
            if typ._tag == "Type.Interface" and reaches(typ, fqtn, "+") then
                return "is reachable through " .. prefix .. alias
            end
        end
    end
    return nil
end

-- Checks the status inventory against both interfaces: every native module
-- has a module row and every native member of a present module a member row
-- (B, C); absences are classified by whether their own declaration names an
-- absent module; present statuses exist in the browser, name their tests,
-- and type-only owners stay unreachable (D); browser-only modules have no
-- native counterpart (E). Returns true, or nil and every violation.
function M.check_status(native, browser, inventory)
    inventory = inventory or M.status_inventory
    local errors, absent, present, core = {}, {}, {}, {}
    local function fail(text) errors[#errors + 1] = text end
    local module_rows = {}
    for _, row in ipairs(inventory.modules) do
        local modname, status = row[1], row[2]
        if module_rows[modname] then fail(modname .. ": duplicate module row") end
        module_rows[modname] = row
        local in_native, in_browser = native.entries[modname] ~= nil, browser.entries[modname] ~= nil
        if not module_statuses[status] then
            fail(modname .. ": unknown module status " .. tostring(status))
        elseif status == "present" then
            core[modname] = row.core == true
            if in_native and in_browser then
                present[modname] = true
            else
                fail(modname .. ": present module is missing from a provider")
            end
            if M.test_reference(row.test) ~= "owner" then fail(modname .. ": present module names no test owner") end
        elseif status == "absent" then
            absent[modname] = true
            if not in_native or in_browser then fail(modname .. ": absent module is not native-only") end
            if type(row.reason) ~= "string" or row.reason == "" then fail(modname .. ": absent module has no reason") end
        elseif in_native or not in_browser then
            fail(modname .. ": browser-only module is not browser-only")
        end
    end
    for _, provider in ipairs({ native, browser }) do
        for _, modname in ipairs(provider.key_order) do
            if not module_rows[modname] then fail(modname .. ": module has no status row") end
        end
    end
    local function names_absent_module(text)
        for modname in pairs(absent) do
            if text:find(modname .. ".", 1, true) then return true end
        end
        return false
    end
    for modname in pairs(inventory.members) do
        if not present[modname] then fail(modname .. ": member rows for a module that is not present") end
    end
    -- Every browser module, decoded once with its raise members: a type-only
    -- owner must stay unreachable from all of them.
    local browser_types, scanned = {}, {}
    for _, modname in ipairs(browser.key_order) do
        local raising = {}
        for _, row in ipairs(inventory.members[modname] or {}) do
            if row[2] == "raise" then raising[row[1]] = true end
        end
        browser_types[modname] = assert(driver.decode_module_interface(browser.entries[modname].types, modname,
            "browser interface"))
        scanned[#scanned + 1] = { modname = modname, type = browser_types[modname], raising = raising }
    end
    for modname in pairs(present) do
        local native_type = assert(driver.decode_module_interface(native.entries[modname].types, modname,
            "native interface"))
        local browser_type = browser_types[modname]
        local declared, offered = M.members(native_type), M.members(browser_type)
        local scope, rows = M.status_scope(declared), {}
        for _, row in ipairs(inventory.members[modname] or {}) do
            if rows[row[1]] then fail(modname .. "." .. row[1] .. ": duplicate status row") end
            rows[row[1]] = row
        end
        -- A member of an absent owner typed by an absent module is typed too;
        -- otherwise its own declaration decides.
        local function class(name)
            local owner = name:match("^([^.:]+)[.:]")
            if owner and rows[owner] and rows[owner][2]:match("^absent:") and class(owner) == "absent:typed" then
                return "absent:typed"
            end
            local declaration = owner_declaration(native_type, name)
            local text = declaration and types.serialize_semantic(declaration) or declared[name].semantic
            return names_absent_module(text) and "absent:typed" or "absent:native-only"
        end
        for name in pairs(scope) do
            if not rows[name] then fail(modname .. "." .. name .. ": native member has no status row") end
        end
        for name, row in pairs(rows) do
            local status, test, label = row[2], row[3], modname .. "." .. name
            local kind = declared[name] and declared[name].kind
            local reference = M.test_reference(test)
            if not scope[name] then
                fail(label .. ": status row is not a native callable, type or variable")
            elseif not member_statuses[status] then
                fail(label .. ": unknown status " .. tostring(status))
            elseif status:match("^absent:") then
                if offered[name] then fail(label .. ": absent member is in the browser interface") end
                if status ~= class(name) then fail(label .. ": absence is " .. class(name) .. ", not " .. status) end
                if test ~= nil then fail(label .. ": absent member names a test") end
            else
                if not offered[name] then fail(label .. ": " .. status .. " member is missing from the browser") end
                if kind == "raw foreign function" and status ~= "implemented" then
                    fail(label .. ": a raw foreign function is implemented or absent")
                end
                if status == "type-only" then
                    if test ~= nil then fail(label .. ": type-only member names a test") end
                    local owner = name:match("^([^.:]+)[.:]")
                    if owner and not (rows[owner] and rows[owner][2] == "type-only") then
                        fail(label .. ": type-only member of an owner that is not type-only")
                    elseif owner and kind ~= "method" then
                        fail(label .. ": only instance methods of a type-only owner are type-only")
                    elseif not owner then
                        local violation = type_only_violation(browser_type, name, scanned)
                        if violation then fail(label .. ": type-only owner " .. violation) end
                    end
                elseif reference == nil then
                    fail(label .. ": " .. status .. " member names no test")
                elseif reference == "owner" and not (status == "implemented" and core[modname]) then
                    fail(label .. ": only implemented members of a core module may name a whole test owner")
                end
            end
        end
    end
    for _, row in ipairs(inventory.stock_lua or {}) do
        local reference = M.test_reference(row[3])
        if row[2] ~= "implemented" and row[2] ~= "raise" then
            fail("stock Lua " .. row[1] .. ": unknown status " .. tostring(row[2]))
        elseif reference ~= "case" and reference ~= "harness" then
            fail("stock Lua " .. row[1] .. ": names no exact test case")
        end
    end
    if #errors > 0 then
        table.sort(errors, util.bytewise_less)
        return nil, "status inventory violations:\n" .. table.concat(errors, "\n")
    end
    return true
end

-- The generated member table. Each row shows its inventory status and test;
-- fields, variants and Interface methods show their owner's.
function M.member_table(rows, recorded_rows, inventory)
    inventory = inventory or M.status_inventory
    local statuses = {}
    for modname, list in pairs(inventory.members) do
        for _, row in ipairs(list) do statuses[modname .. " " .. row[1]] = row end
    end
    local function status(row)
        local found = statuses[row.module .. " " .. row.name] or
            statuses[row.module .. " " .. (row.name:match("^([^.:]+)[.:]") or "")]
        return found and found[2] or "", found and found[3] or ""
    end
    local out = {
        "# Browser core stdlib public-member inventory (generated)", "",
        "Derived from native and browser provider interfaces. Shared members keep their native signatures; " ..
            "the browser differs only in the absent members listed last.",
        "Semantic interface types are compared with documentation excluded; machine layouts are separate metadata.", "",
        "| Module | Member | Kind | Status | Test | Native and browser signature |",
        "| --- | --- | --- | --- | --- | --- |",
    }
    local function escape(text) return text:gsub("|", "&#124;"):gsub("`", "&#96;") end
    for _, row in ipairs(rows) do
        local state, test = status(row)
        out[#out + 1] = "| `" .. row.module .. "` | `" .. row.name .. "` | " .. row.kind .. " | " .. state ..
            " | " .. (test ~= "" and "`" .. test .. "`" or "") .. " | `" .. escape(row.signature) .. "` |"
    end
    if recorded_rows and #recorded_rows > 0 then
        out[#out + 1] = ""
        out[#out + 1] = "## Absent browser members"
        out[#out + 1] = ""
        out[#out + 1] = "| Module | Member | Status | Kind | Native signature |"
        out[#out + 1] = "| --- | --- | --- | --- | --- |"
        for _, row in ipairs(recorded_rows) do
            local state = status(row)
            out[#out + 1] = "| `" .. row.module .. "` | `" .. row.name .. "` | " .. (state ~= "" and state or row.difference) ..
                " | " .. row.kind .. " | `" .. escape(row.signature) .. "` |"
        end
    end
    return table.concat(out, "\n") .. "\n"
end

-- The browser type fixture: each module's serialized interface from the
-- browser provider's metadata, keyed by its short name, as the native fixture
-- pins the native provider. Each value takes the lowest long-bracket level
-- (from one) whose closing bracket does not occur in its text.
function M.type_fixture(scanned)
    local out = {
        "-- Exact current serialized interfaces of the browser standard provider",
        "-- (lib/titan-browser/<version>/titan.a). Regenerate with",
        "-- `lua scripts/check_browser_stdlib.lua fixture <browser titan.a> <this file>`.",
        "return {",
    }
    for _, modname in ipairs(scanned.key_order) do
        local text, level = scanned.entries[modname].types, "="
        while text:find("]" .. level .. "]", 1, true) do level = level .. "=" end
        out[#out + 1] = "    " .. modname:gsub("^titan%.", "") .. " = [" .. level .. "[" .. text .. "]" .. level .. "],"
    end
    out[#out + 1] = "}"
    return table.concat(out, "\n") .. "\n"
end

return M
