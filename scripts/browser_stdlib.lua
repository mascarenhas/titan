-- Build-owned core-stdlib checks; deliberately not part of titanc's user link path.
local staticmetadata = require "titan-compiler.staticmetadata"
local objectmetadata = require "titan-compiler.objectmetadata"
local linkcertificate = require "titan-compiler.linkcertificate"
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
        name:match("^libuv[%.-]") or name:match("^libssl[%.-]") or
        name:match("^libcrypto[%.-]") or name:match("^libopenssl[%.-]") or
        name:match("^libllhttp[%.-]") or name:match("^libsqlite3[%.-]") or
        name:match("^libtitan%-llhttp[%.-]") or name:match("^libtitan%-sqlite3[%.-]"))
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
    local entries, err = strategy:list(directory)
    if not entries then return nil, err end
    for _, name in ipairs(entries) do
        local filename = directory .. "/" .. name
        local info
        info, err = strategy:lstat(filename)
        if not info then return nil, err end
        if info.kind == "directory" then
            local ok
            ok, err = M.check_output(strategy, filename)
            if not ok then return nil, err end
        elseif info.kind == "file" and name:match("%.o$") then
            local bytes
            bytes, err = strategy:read_file(filename)
            if not bytes then return nil, err end
            local object
            object, err = staticmetadata.classify_object(bytes, filename)
            if not object then return nil, err end
            local ok
            ok, err = check_object(object, bytes, filename)
            if not ok then return nil, err end
        elseif info.kind == "file" and name == "record" and directory:find("/.titan-links/", 1, true) then
            local record
            record, err = linkcertificate.read_record({
                io = strategy, cache_adapter = { sha256_binary = require("titan")._sha256_binary },
            }, filename)
            if not record then return nil, err end
            for _, input in ipairs(record.native or {}) do
                local ok
                ok, err = M.check_path(input.path)
                if not ok then return nil, err end
            end
        end
    end
    return true
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
