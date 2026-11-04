-- Build-owned core-stdlib checks; deliberately not part of titanc's user link path.
local staticmetadata = require "titan-compiler.staticmetadata"
local objectmetadata = require "titan-compiler.objectmetadata"
local linkcertificate = require "titan-compiler.linkcertificate"
local depfile = require "titan-compiler.depfile"
local driver = require "titan-compiler.driver"
local types = require "titan-compiler.types"
local util = require "titan-compiler.util"
local M = {}

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
        for _, group in ipairs({ typ.methods or {}, typ.functions or {} }) do
            for _, method in pairs(group) do
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
            typ._tag == "Type.Union" and "union" or
            typ._tag == "Type.Interface" and "interface" or "function"
        add(member.name, kind, typ, member.isconst and " (const)" or nil, member)
        nominal_members(member.name, typ)
    end
    for name, typ in pairs(modtype.type_members or {}) do
        add(name, "type alias", typ)
        nominal_members(name, typ)
    end
    return result
end

-- No member omissions or semantic signature differences are recorded. Machine
-- layouts live in separate provider metadata and are deliberately not compared.
function M.inventory(native, browser)
    local rows, differences = {}, {}
    for _, modname in ipairs(browser.key_order) do
        local browser_entry, native_entry = browser.entries[modname], native.entries[modname]
        if not native_entry then return nil, "missing native module " .. modname end
        local b = M.members(assert(driver.decode_module_interface(browser_entry.types, modname, "browser interface")))
        local n = M.members(assert(driver.decode_module_interface(native_entry.types, modname, "native interface")))
        local names, seen = {}, {}
        for name in pairs(b) do names[#names + 1], seen[name] = name, true end
        for name in pairs(n) do if not seen[name] then names[#names + 1] = name end end
        table.sort(names, util.bytewise_less)
        for _, name in ipairs(names) do
            local bm, nm = b[name], n[name]
            if not bm or not nm or bm.kind ~= nm.kind or bm.signature ~= nm.signature or bm.semantic ~= nm.semantic then
                differences[#differences + 1] = modname .. "." .. name .. ": native=" ..
                    (nm and nm.signature or "<absent>") .. "; browser=" .. (bm and bm.signature or "<absent>") ..
                    (bm and nm and bm.semantic ~= nm.semantic and " (semantic declaration differs)" or "")
            else
                rows[#rows + 1] = { module = modname, name = name, kind = bm.kind, signature = bm.signature }
            end
        end
    end
    if #differences > 0 then return nil, "unrecorded public interface differences:\n" .. table.concat(differences, "\n") end
    return rows
end

function M.member_table(rows)
    local out = {
        "# Browser core stdlib public-member inventory (generated)", "",
        "Derived from native and browser provider interfaces. No member omissions or signature differences.",
        "Semantic interface types are compared with documentation excluded; machine layouts are separate metadata.", "",
        "| Module | Member | Kind | Native and browser signature |", "| --- | --- | --- | --- |",
    }
    local function escape(text) return text:gsub("|", "&#124;"):gsub("`", "&#96;") end
    for _, row in ipairs(rows) do
        out[#out + 1] = "| `" .. row.module .. "` | `" .. row.name .. "` | " .. row.kind .. " | `" .. escape(row.signature) .. "` |"
    end
    return table.concat(out, "\n") .. "\n"
end
return M
