-- Session-scoped, compile-only C probes.
--
-- This module deliberately knows nothing about Titan compatibility. Callers
-- first decide that a C construct is a permitted candidate, then ask this
-- service whether the configured C compiler accepts the exact lowering.
local cprobe = {}

local cdeclarator = require "titan-compiler.cdeclarator"
local csemantics = require "titan-compiler.csemantics"
local cpreamble = require "titan-compiler.cpreamble"
local types = require "titan-compiler.types"
local sha256 = require "titan-compiler.sha256"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"

local default_io = compiler_io.new_sync()

local Service = {}
Service.__index = Service

local ModuleContext = {}
ModuleContext.__index = ModuleContext

local probe_function_type = {
    _tag = "Type.CFunction",
    params = {},
    ret = { _tag = "Type.CVoid" },
    vararg = false,
    abi = "cdecl",
}

local function copy_array(values)
    local copy = {}
    for index, value in ipairs(values or {}) do
        copy[index] = value
    end
    return copy
end

local function deep_copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[deep_copy(key, seen)] = deep_copy(item, seen)
    end
    return copy
end

local function dense_string_array(value, name, string_is_shell_words)
    if value == nil then return {} end
    if type(value) == "string" and string_is_shell_words then
        local words, err = cdriver.split_shell_words(value)
        if not words then
            return nil, "invalid " .. name .. ": " .. err
        end
        value = words
    end
    if type(value) ~= "table" then
        return nil, name .. " must be a parsed argument array"
    end

    local copy = {}
    for index = 1, #value do
        local argument = value[index]
        if type(argument) ~= "string" then
            return nil, name .. " argument " .. index .. " must be a string"
        elseif argument:find("\0", 1, true) then
            return nil, name .. " argument " .. index .. " contains a NUL byte"
        end
        copy[index] = argument
    end
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key > #value
        or key % 1 ~= 0 then
            return nil, name .. " must be a dense argument array"
        end
    end
    return copy
end

local function append_all(destination, source)
    for _, value in ipairs(source or {}) do
        destination[#destination + 1] = value
    end
end

-- Length-prefix every component. Unlike delimiter-only concatenation this is
-- collision-free even when a compiler argument or pathname contains the
-- delimiter, a newline, or an empty string.
local function encode_sequence(values)
    local encoded = {}
    for index, value in ipairs(values) do
        value = tostring(value)
        encoded[index] = #value .. ":" .. value
    end
    return table.concat(encoded)
end

local function keyed_fields(fields)
    local flattened = { "titan-cprobe-key-v1" }
    for _, field in ipairs(fields) do
        flattened[#flattened + 1] = field[1]
        flattened[#flattened + 1] = field[2] or ""
    end
    return encode_sequence(flattened)
end

-- Probe declarations need an identifier, but ordinary fixed names can be
-- captured by an imported macro or collide with a header declaration. Use a
-- short context-derived spelling instead. The role keeps names distinct inside
-- one probe source, and avoiding C's reserved-identifier namespace keeps
-- `-Wreserved-identifier` configurations usable.
local function probe_identifier(role, context_key)
    local hash = 0
    local text = tostring(context_key)
    for index = 1, #text do
        hash = (hash * 131 + text:byte(index)) % 2147483629
    end
    return ("titan_probe_%s_%08x"):format(role, hash)
end

local function path_join(directory, name)
    if directory:sub(-1) == "/" then return directory .. name end
    return directory .. "/" .. name
end

local function absolute_path(path, base)
    if path:sub(1, 1) == "/" then return path end
    return path_join(base, path)
end

local function ensure_directory(path, strategy)
    local attributes = strategy:stat(path)
    if attributes and attributes.kind == "directory" then return true end
    if attributes ~= nil then return nil end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path then
        if not ensure_directory(parent, strategy) then return nil end
    end
    local made = strategy:mkdir(path)
    if made then return true end
    attributes = strategy:stat(path)
    return attributes and attributes.kind == "directory" or nil
end

local function first_diagnostic_line(diagnostic)
    diagnostic = diagnostic or ""
    for line in (diagnostic .. "\n"):gmatch("(.-)\r?\n") do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then return trimmed end
    end
    return ""
end

local function quote_header_name(name)
    if name:find("[\r\n%z]") then
        return nil, "quoted C header name contains a newline or NUL byte"
    end
    return '"' .. name:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function angle_header_name(name)
    if name:find("[<>\r\n%z]") then
        return nil, "angle C header name contains a delimiter, newline, or NUL byte"
    end
    return "<" .. name .. ">"
end

local function normalize_header_inputs(value, expected_kind, source_dir, cwd,
                                       subject)
    if value == nil then return {} end
    if type(value) ~= "table" then
        return nil, subject .. " must be an ordered array"
    end
    local result = {}
    for index = 1, #value do
        local input = value[index]
        if type(input) ~= "table" then
            return nil, subject .. " entry " .. index .. " must be a table"
        end
        local kind = input.kind
        local path = input.path
        local identity = input.identity
        local restat = input.restat
        if kind ~= expected_kind then
            return nil, subject .. " entry " .. index .. " must have kind '" ..
                expected_kind .. "'"
        elseif type(path) ~= "string" or path == "" or
               path:find("\0", 1, true) then
            return nil, subject .. " entry " .. index ..
                " must have a nonempty NUL-free path"
        elseif type(identity) ~= "string" or identity == "" then
            return nil, subject .. " entry " .. index ..
                " must have a nonempty identity"
        elseif restat ~= nil and type(restat) ~= "boolean" then
            return nil, subject .. " entry " .. index ..
                " restat flag must be boolean"
        end
        result[index] = {
            kind = kind,
            path = absolute_path(path, cwd or source_dir),
            identity = identity,
            restat = restat ~= false,
        }
    end
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key > #value
        or key % 1 ~= 0 then
            return nil, subject .. " must be a dense ordered array"
        end
    end
    return result
end

local function normalize_include_descriptor(descriptor, source_dir, cwd)
    if type(descriptor) == "string" then
        descriptor = {
            original = descriptor,
            resolved = descriptor,
            include_kind = "angle",
            include_name = descriptor,
        }
    elseif type(descriptor) ~= "table" then
        return nil, "C include descriptor must be a string or table"
    end

    local kind = descriptor.include_kind or descriptor.kind
    local name = descriptor.include_name or descriptor.name
        or descriptor.original
    local original = descriptor.original or name
    local resolved = descriptor.resolved
    local probe_wrapper = descriptor.probe_wrapper
    local header_dependencies, dependency_error = normalize_header_inputs(
        descriptor.c_header_dependencies, "file", source_dir, cwd,
        "C header dependencies")
    if not header_dependencies then return nil, dependency_error end
    local header_search_inputs, search_error = normalize_header_inputs(
        descriptor.c_header_search_inputs, "search", source_dir, cwd,
        "C header search inputs")
    if not header_search_inputs then return nil, search_error end
    if kind ~= "angle" and kind ~= "quote" then
        return nil, "C include descriptor kind must be 'angle' or 'quote'"
    elseif type(name) ~= "string" or name == "" then
        return nil, "C include descriptor name must be a nonempty string"
    elseif type(original) ~= "string" then
        return nil, "C include descriptor original spelling must be a string"
    elseif resolved ~= nil and type(resolved) ~= "string" then
        return nil, "C include descriptor resolved path must be a string"
    end

    local rendered
    local effective_resolved = resolved or ""
    if probe_wrapper ~= nil then
        local wrapper_digest = type(name) == "string" and name:match(
            "^titan%-source%-foreign%-([0-9a-f]+)%.h$")
        if kind ~= "quote" or type(probe_wrapper) ~= "table" or
           type(probe_wrapper.name) ~= "string" or
           probe_wrapper.name ~= name or not wrapper_digest or
           #wrapper_digest ~= 64 or
           type(probe_wrapper.contents) ~= "string" or
           type(resolved) ~= "string" or resolved == "" then
            return nil, "invalid private probe-header wrapper descriptor"
        end
        local err
        rendered, err = quote_header_name(name)
        if not rendered then return nil, err end
        return {
            original = original,
            resolved = resolved,
            include_kind = kind,
            include_name = name,
            rendered = rendered,
            probe_wrapper = {
                name = probe_wrapper.name,
                contents = probe_wrapper.contents,
            },
            c_header_dependencies = header_dependencies,
            c_header_search_inputs = header_search_inputs,
        }
    elseif kind == "quote" then
        -- cdriver descriptors are resolved relative to the importing process,
        -- not relative to a future probe directory. Make that interpretation
        -- explicit before the source moves under /tmp. When no resolved path
        -- was supplied, the original quote import belongs to source_dir.
        if resolved then
            effective_resolved = absolute_path(resolved, cwd)
        else
            effective_resolved = absolute_path(name, source_dir)
        end
        local err
        rendered, err = quote_header_name(effective_resolved)
        if not rendered then return nil, err end
    else
        local err
        rendered, err = angle_header_name(name)
        if not rendered then return nil, err end
    end

    return {
        original = original,
        resolved = effective_resolved,
        include_kind = kind,
        include_name = name,
        rendered = rendered,
        c_header_dependencies = header_dependencies,
        c_header_search_inputs = header_search_inputs,
    }
end

local function source_foreign_include_alias(
        descriptor, modname, public_header)
    if type(descriptor) ~= "table" or
       type(descriptor.rendered) ~= "string" or
       descriptor.rendered == "" then
        return nil, "source-foreign probe alias requires a normalized include"
    elseif descriptor.include_kind ~= "quote" or
           type(descriptor.resolved) ~= "string" or
           descriptor.resolved:sub(1, 1) ~= "/" or
           descriptor.rendered ~= quote_header_name(descriptor.resolved) then
        return nil, "source-foreign probe alias requires an absolute quoted physical include"
    elseif type(modname) ~= "string" or modname == "" then
        return nil, "source-foreign probe alias requires a module name"
    elseif type(public_header) ~= "string" or
           public_header:sub(1, 1) ~= "/" then
        return nil, "source-foreign probe alias requires an absolute public header path"
    end
    local identity = keyed_fields({
        { "alias_version", "source-foreign-v1" },
        { "module", modname },
        { "public_header", public_header },
    })
    local name = "titan-source-foreign-" .. sha256.hex(identity) .. ".h"
    local rendered, rendered_error = quote_header_name(name)
    if not rendered then return nil, rendered_error end
    local function stable_generated_identity(value)
        local digest, kind, mode, device, inode = value:match(
            "^c%-header%-file%-v1:sha256:([0-9a-f]+);" ..
            "stat=([^:;]+):([^:;]+):([^:;]+):([^:;]+)$")
        if digest and #digest == 64 and kind == "file" and
           mode:match("^%d+$") and device:match("^%-?%d+$") and
           inode:match("^%-?%d+$") then
            return "c-header-file-v1:sha256:" .. digest
        end
        return value
    end
    local header_dependencies = {}
    for index, dependency in ipairs(
            descriptor.c_header_dependencies or {}) do
        local copy = deep_copy(dependency)
        if copy.kind == "file" and copy.path == descriptor.resolved then
            -- The resolver-owned sibling contains the exact generated bytes
            -- included by the authoritative C probe compiler. Give those
            -- bytes the stable public-header logical path for probe-cache
            -- identity, but do not ask a language-server client to stat a
            -- file which this analysis did not publish. Titan source stamps
            -- cover regeneration; physical nested C headers remain
            -- independently restattable.
            copy.path = public_header
            copy.identity = stable_generated_identity(copy.identity)
            copy.restat = false
        end
        header_dependencies[index] = copy
    end
    return {
        original = modname,
        resolved = public_header,
        include_kind = "quote",
        include_name = name,
        rendered = rendered,
        probe_wrapper = {
            name = name,
            contents = "#include " .. descriptor.rendered .. "\n",
        },
        c_header_dependencies = header_dependencies,
        c_header_search_inputs =
            deep_copy(descriptor.c_header_search_inputs or {}),
    }
end

local generated_c_escape_bytes = {
    ["a"] = 7,
    ["b"] = 8,
    ["f"] = 12,
    ["n"] = 10,
    ["r"] = 13,
    ["t"] = 9,
    ["v"] = 11,
    ["\\"] = 92,
    ['"'] = 34,
}

-- Generated source-foreign headers spell source dependencies with the
-- compiler's C string-literal encoder. Decode only that closed spelling so a
-- resolver-random physical sibling can be replaced in the identity stream by
-- its public path and the already established identity of its generated
-- contents. The canonicalized bytes are hashed only; they are never compiled.
local function decode_generated_include(line)
    local encoded = line:match('^#include%s+"(.*)"%s*$')
    if not encoded then return nil end
    local decoded = {}
    local index = 1
    while index <= #encoded do
        local byte = encoded:byte(index)
        if byte ~= 92 then
            decoded[#decoded + 1] = string.char(byte)
            index = index + 1
        else
            local escaped = encoded:sub(index + 1, index + 1)
            if escaped:match("^[0-7]$") then
                local octal = encoded:sub(index + 1, index + 3)
                if #octal ~= 3 or not octal:match("^[0-7][0-7][0-7]$") then
                    return nil
                end
                decoded[#decoded + 1] = string.char(tonumber(octal, 8))
                index = index + 4
            else
                local escaped_byte = generated_c_escape_bytes[escaped]
                if not escaped_byte then return nil end
                decoded[#decoded + 1] = string.char(escaped_byte)
                index = index + 2
            end
        end
    end
    return table.concat(decoded)
end

local function canonicalize_generated_header(contents, aliases)
    local normalized = {}
    for index, alias in ipairs(aliases or {}) do
        if type(alias) ~= "table"
           or type(alias.public_header) ~= "string"
           or alias.public_header:sub(1, 1) ~= "/"
           or type(alias.identity) ~= "string"
           or alias.identity == "" then
            return nil, "generated source header alias " .. index ..
                " is invalid"
        end
        normalized[index] = {
            prefix = alias.public_header .. ".check.tmp.",
            canonical = "#titan-source-foreign-include-v1:" .. sha256.hex(
                keyed_fields({
                    { "public_header", alias.public_header },
                    { "generated_identity", alias.identity },
                })),
        }
    end
    for key in pairs(aliases or {}) do
        if type(key) ~= "number" or key < 1 or key > #(aliases or {})
           or key % 1 ~= 0 then
            return nil, "generated source header aliases must be a dense array"
        end
    end

    local output = {}
    local offset = 1
    while offset <= #contents do
        local newline = contents:find("\n", offset, true)
        local line = newline and contents:sub(offset, newline - 1)
            or contents:sub(offset)
        local include = decode_generated_include(line)
        if include then
            for _, alias in ipairs(normalized) do
                if include:sub(1, #alias.prefix) == alias.prefix then
                    local suffix = include:sub(#alias.prefix + 1)
                    if suffix ~= "" and not suffix:find("/", 1, true) then
                        line = alias.canonical
                        break
                    end
                end
            end
        end
        output[#output + 1] = line
        if not newline then break end
        output[#output + 1] = "\n"
        offset = newline + 1
    end
    if #contents == 0 then return "" end
    return table.concat(output)
end

-- Hash the exact generated companion after replacing only compiler-owned
-- nested checking-header spellings with stable transitive identities. This
-- keeps ordinary byte changes authoritative while ensuring that a fresh
-- resolver's random temporary basenames cannot poison persistent probe keys.
function cprobe.source_foreign_generated_identity(
        filename, aliases, strategy)
    strategy = strategy or default_io
    if type(filename) ~= "string" or filename == "" then
        return nil, "generated source header filename must be nonempty"
    elseif type(aliases) ~= "table" then
        return nil, "generated source header aliases must be a table"
    end
    local contents, read_error = strategy:read_file(filename)
    if not contents then return nil, read_error end
    local canonical, canonical_error =
        canonicalize_generated_header(contents, aliases)
    if not canonical then return nil, canonical_error end
    return "c-header-generated-v1:sha256:" .. sha256.hex(canonical)
end

local function normalize_include_dirs(value)
    if value == nil then return {} end
    if type(value) ~= "table" then
        return nil, "include_dirs must be an ordered array"
    end

    local result = {}
    for index = 1, #value do
        local item = value[index]
        if type(item) == "string" then
            if item:find("\0", 1, true) then
                return nil, "include_dirs entry " .. index .. " contains a NUL byte"
            end
            result[index] = { flag = "-I", path = item }
        elseif type(item) == "table" then
            local flag = item.flag
            if not flag then
                local kind = item.kind or item.include_kind
                if kind == "quote" then
                    flag = "-iquote"
                elseif kind == "system" then
                    flag = "-isystem"
                else
                    flag = "-I"
                end
            end
            local path = item.path or item.dir or item[1]
            if flag ~= "-I" and flag ~= "-iquote" and flag ~= "-isystem" then
                return nil, "include_dirs entry " .. index ..
                    " has an unsupported flag"
            elseif type(path) ~= "string" or path == "" then
                return nil, "include_dirs entry " .. index ..
                    " must have a nonempty path"
            elseif path:find("\0", 1, true) then
                return nil, "include_dirs entry " .. index ..
                    " contains a NUL byte"
            end
            result[index] = { flag = flag, path = path }
        else
            return nil, "include_dirs entry " .. index ..
                " must be a string or table"
        end
    end
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key > #value
        or key % 1 ~= 0 then
            return nil, "include_dirs must be a dense ordered array"
        end
    end
    return result
end

local function include_dirs_key(include_dirs)
    local fields = {}
    for index, include in ipairs(include_dirs) do
        fields[#fields + 1] = { "include_flag_" .. index, include.flag }
        fields[#fields + 1] = { "include_path_" .. index, include.path }
    end
    return keyed_fields(fields)
end

local function header_context_key(
        source_dir, includes, forced_header_manifest)
    local fields = {
        { "header_context_version", "2" },
        { "source_dir", source_dir },
        { "forced_headers", forced_header_manifest or "" },
    }
    for index, include in ipairs(includes) do
        local prefix = "header_" .. index .. "_"
        fields[#fields + 1] = { prefix .. "original", include.original }
        fields[#fields + 1] = { prefix .. "resolved", include.resolved }
        fields[#fields + 1] = { prefix .. "kind", include.include_kind }
        fields[#fields + 1] = { prefix .. "name", include.include_name }
        fields[#fields + 1] = { prefix .. "rendered", include.rendered }
        for dependency_index, dependency in ipairs(
                include.c_header_dependencies or {}) do
            local dependency_prefix = prefix .. "dependency_" ..
                dependency_index .. "_"
            fields[#fields + 1] = {
                dependency_prefix .. "kind", dependency.kind }
            fields[#fields + 1] = {
                dependency_prefix .. "path", dependency.path }
            fields[#fields + 1] = {
                dependency_prefix .. "identity", dependency.identity }
            fields[#fields + 1] = {
                dependency_prefix .. "restat",
                dependency.restat and "true" or "false" }
        end
        for search_index, search in ipairs(
                include.c_header_search_inputs or {}) do
            local search_prefix = prefix .. "search_" .. search_index .. "_"
            fields[#fields + 1] = {
                search_prefix .. "kind", search.kind }
            fields[#fields + 1] = {
                search_prefix .. "path", search.path }
            fields[#fields + 1] = {
                search_prefix .. "identity", search.identity }
            fields[#fields + 1] = {
                search_prefix .. "restat",
                search.restat and "true" or "false" }
        end
    end
    -- Header closures can contain thousands of files and failed include-search
    -- candidates. Keep the exact ordered manifest as the hash input, but never
    -- embed that unbounded string in every baseline/candidate cache key. Those
    -- keys are retained for the lifetime of a compiler service, so carrying
    -- the manifest directly makes memory and hashing work multiplicative in
    -- (header inputs x semantic probes).
    return "titan-cprobe-header-context-v2:sha256:" ..
        sha256.hex(keyed_fields(fields))
end

local function collect_header_inputs(includes, additional_inputs)
    local result = {}
    local seen = {}
    local function append(input)
        if input.restat == false then return true end
        local key = input.kind .. "\0" .. input.path
        local previous = seen[key]
        if previous and previous ~= input.identity then
            return nil, "conflicting C header input identity for '" ..
                input.path .. "'"
        elseif not previous then
            seen[key] = input.identity
            result[#result + 1] = {
                kind = input.kind,
                path = input.path,
                identity = input.identity,
            }
        end
        return true
    end
    for _, input in ipairs(additional_inputs or {}) do
        local ok, err = append(input)
        if not ok then return nil, err end
    end
    for _, include in ipairs(includes or {}) do
        for _, dependency in ipairs(
                include.c_header_dependencies or {}) do
            local ok, err = append(dependency)
            if not ok then return nil, err end
        end
        for _, search in ipairs(
                include.c_header_search_inputs or {}) do
            local ok, err = append(search)
            if not ok then return nil, err end
        end
    end
    return result
end

local function render_header_preamble(includes)
    local lines = { cpreamble.fixed_prefix }
    if #includes > 0 then lines[#lines + 1] = "" end
    for _, include in ipairs(includes) do
        lines[#lines + 1] = "#include " .. include.rendered
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = cpreamble.after_foreign_imports
    return table.concat(lines, "\n")
end

local function append_preamble(lines, preamble)
    if preamble ~= "" then
        lines[#lines + 1] = preamble
        lines[#lines + 1] = ""
    end
end

local function render_baseline_source(module_context)
    local lines = {}
    local name = probe_identifier("b", module_context.header_key)
    local probe_declaration =
        cdeclarator.render_declaration(probe_function_type, name)
    append_preamble(lines, module_context.header_preamble)
    lines[#lines + 1] = probe_declaration .. ";"
    lines[#lines + 1] = probe_declaration .. " {"
    lines[#lines + 1] = "    (void)0;"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

local function declaration_qualifiers(declaration)
    if type(declaration) ~= "table" then return nil end
    return declaration.qualifiers
end

local function expand_probe_declaration_typedef(typ)
    -- A declaration-owned array view can acquire a composite bound after an
    -- earlier accepted redeclaration. Its source typedef still has the old
    -- incomplete definition in the header preamble, so probe the private view
    -- structurally instead of hiding that mutation behind the typedef name.
    return typ._tag == "Type.CTypedef"
       and typ._declaration_array_view == true
end

local function render_declaration_compatibility_pair(
        left_type, right_type, left_declaration, right_declaration, name)
    if not left_type or not right_type then
        error("C declaration compatibility probe requires two types", 2)
    end

    -- Two declarations of one otherwise-unused identifier ask the configured
    -- compiler the exact C question: are these declaration types compatible in
    -- the final ordered header context? This is stronger than compiling the
    -- preamble alone, which does not compare independently extracted types.
    -- It still cannot prove that a macro-suppressed source declaration occurred.
    local left = cdeclarator.render_declaration(
        left_type, name, declaration_qualifiers(left_declaration),
        expand_probe_declaration_typedef)
    local right = cdeclarator.render_declaration(
        right_type, name, declaration_qualifiers(right_declaration),
        expand_probe_declaration_typedef)
    return {
        left_declaration = left,
        right_declaration = right,
    }
end

local function render_declaration_compatibility_source(
        module_context, left_type, right_type,
        left_declaration, right_declaration)
    local rendered = render_declaration_compatibility_pair(
        left_type, right_type, left_declaration, right_declaration,
        probe_identifier("d", module_context.header_key))
    local lines = {}
    append_preamble(lines, module_context.header_preamble)
    lines[#lines + 1] =
        "extern " .. rendered.left_declaration .. ";"
    lines[#lines + 1] =
        "extern " .. rendered.right_declaration .. ";"
    lines[#lines + 1] = ""
    return table.concat(lines, "\n"), rendered
end

local function render_declaration_compatibility_batch_source(
        module_context, entries)
    local lines = {}
    append_preamble(lines, module_context.header_preamble)

    if #entries == 1 then
        local entry = entries[1]
        local rendered = render_declaration_compatibility_pair(
            entry.left_type, entry.right_type,
            entry.left_declaration, entry.right_declaration,
            probe_identifier("d", module_context.header_key))
        lines[#lines + 1] = "#if defined(__clang__)"
        lines[#lines + 1] = "# pragma clang diagnostic push"
        lines[#lines + 1] =
            "# pragma clang diagnostic ignored \"-Wunused-variable\""
        lines[#lines + 1] = "#elif defined(__GNUC__)"
        lines[#lines + 1] = "# pragma GCC diagnostic push"
        lines[#lines + 1] =
            "# pragma GCC diagnostic ignored \"-Wunused-variable\""
        lines[#lines + 1] = "# if __GNUC__ >= 13"
        lines[#lines + 1] =
            "#  pragma GCC diagnostic ignored \"-Wenum-int-mismatch\""
        lines[#lines + 1] = "# endif"
        lines[#lines + 1] = "#endif"
        lines[#lines + 1] =
            "extern " .. rendered.left_declaration .. ";"
        lines[#lines + 1] =
            "extern " .. rendered.right_declaration .. ";"
        lines[#lines + 1] = "#if defined(__clang__)"
        lines[#lines + 1] = "# pragma clang diagnostic pop"
        lines[#lines + 1] = "#elif defined(__GNUC__)"
        lines[#lines + 1] = "# pragma GCC diagnostic pop"
        lines[#lines + 1] = "#endif"
        lines[#lines + 1] = ""
        return table.concat(lines, "\n")
    end

    -- Ordinary identifiers have separate block scopes below, but every
    -- block-scope extern still denotes an external-linkage C identifier. Keep
    -- the pair spellings distinct just as the former flat batch did.
    local wrapper = probe_identifier("db", module_context.header_key)
    lines[#lines + 1] = "void " .. wrapper .. "(void);"
    lines[#lines + 1] = "void " .. wrapper .. "(void)"
    lines[#lines + 1] = "{"

    -- The block-scope extern declarations are intentional probe machinery.
    -- Do not let an opt-in warning about nested externs turn otherwise valid
    -- pairs into compiler rejections; preserve other configured diagnostics
    -- and remain ordinary C99 on non-GNU-compatible compilers.
    lines[#lines + 1] = "#if defined(__clang__)"
    lines[#lines + 1] = "# pragma clang diagnostic push"
    lines[#lines + 1] =
        "# pragma clang diagnostic ignored \"-Wnested-externs\""
    lines[#lines + 1] =
        "# pragma clang diagnostic ignored \"-Wunused-variable\""
    lines[#lines + 1] = "#elif defined(__GNUC__)"
    lines[#lines + 1] = "# pragma GCC diagnostic push"
    lines[#lines + 1] =
        "# pragma GCC diagnostic ignored \"-Wnested-externs\""
    lines[#lines + 1] =
        "# pragma GCC diagnostic ignored \"-Wunused-variable\""
    lines[#lines + 1] = "# if __GNUC__ >= 13"
    lines[#lines + 1] =
        "#  pragma GCC diagnostic ignored \"-Wenum-int-mismatch\""
    lines[#lines + 1] = "# endif"
    lines[#lines + 1] = "#endif"

    for index, entry in ipairs(entries) do
        -- A C tag introduced by a file-scope object declaration remains
        -- visible to every later declaration in that translation unit. Give
        -- each pair its own nested block so one candidate cannot seed a tag
        -- that changes another candidate's prototype-scope identity.
        local role = "d" .. tostring(index)
        local rendered = render_declaration_compatibility_pair(
            entry.left_type, entry.right_type,
            entry.left_declaration, entry.right_declaration,
            probe_identifier(role, module_context.header_key))
        lines[#lines + 1] = "    {"
        lines[#lines + 1] =
            "        extern " .. rendered.left_declaration .. ";"
        lines[#lines + 1] =
            "        extern " .. rendered.right_declaration .. ";"
        lines[#lines + 1] = "    }"
    end
    lines[#lines + 1] = "#if defined(__clang__)"
    lines[#lines + 1] = "# pragma clang diagnostic pop"
    lines[#lines + 1] = "#elif defined(__GNUC__)"
    lines[#lines + 1] = "# pragma GCC diagnostic pop"
    lines[#lines + 1] = "#endif"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

local function render_pointer_source(module_context, source_type, target_type)
    local source_name =
        probe_identifier("s", module_context.header_key)
    local target_name =
        probe_identifier("t", module_context.header_key)
    local function_name =
        probe_identifier("f", module_context.header_key)
    local source_declaration =
        cdeclarator.render_declaration(source_type, source_name)
    local target_declaration =
        cdeclarator.render_declaration(target_type, target_name)
    local source_type_name = cdeclarator.render_type_name(source_type)
    local target_type_name = cdeclarator.render_type_name(target_type)
    local probe_declaration =
        cdeclarator.render_declaration(probe_function_type, function_name)

    local lines = {}
    append_preamble(lines, module_context.header_preamble)
    lines[#lines + 1] = "extern " .. source_declaration .. ";"
    lines[#lines + 1] = probe_declaration .. ";"
    lines[#lines + 1] = probe_declaration .. " {"
    lines[#lines + 1] = "    " .. target_declaration .. " ="
    lines[#lines + 1] =
        "        (" .. target_type_name .. ")" .. source_name .. ";"
    lines[#lines + 1] = "    (void)" .. target_name .. ";"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""

    return table.concat(lines, "\n"), {
        source_declaration = source_declaration,
        target_declaration = target_declaration,
        source_type = source_type_name,
        target_type = target_type_name,
    }
end

local operator_spellings = {
    ["-"] = true,
    ["~"] = true,
    ["+"] = true,
    ["*"] = true,
    ["/"] = true,
    ["%"] = true,
    ["<"] = true,
    ["<="] = true,
    [">"] = true,
    [">="] = true,
    ["=="] = true,
    ["!="] = true,
    ["&"] = true,
    ["|"] = true,
    ["^"] = true,
    ["<<"] = true,
    [">>"] = true,
}

local function render_operator_operand(name, variable, source_type,
                                       target_type, is_null)
    if not target_type then
        error("C operator operand '" .. name .. "' has no target type", 3)
    end
    local target_name = cdeclarator.render_type_name(target_type)
    if is_null then
        return nil, "((" .. target_name .. ")(0))", {
            source_type = "<null>",
            source_declaration = "",
            target_type = target_name,
            null = true,
        }
    elseif not source_type then
        error("C operator operand '" .. name .. "' has no source type", 3)
    end

    local declaration =
        cdeclarator.render_declaration(source_type, variable)
    local expression =
        "((" .. target_name .. ")(" .. variable .. "))"
    return "extern " .. declaration .. ";", expression, {
        source_type = cdeclarator.render_declaration(source_type, ""),
        source_declaration = declaration,
        target_type = target_name,
        null = false,
    }
end

local function render_operator_source(module_context, trait)
    if type(trait) ~= "table"
       or (trait.kind ~= "unary" and trait.kind ~= "binary") then
        error("C operator probe requires a unary or binary trait", 2)
    elseif not operator_spellings[trait.cop] then
        error("unsupported C operator probe spelling '"
            .. tostring(trait.cop) .. "'", 2)
    end

    local lhs_name = probe_identifier("l", module_context.header_key)
    local rhs_name = probe_identifier("r", module_context.header_key)
    local function_name = probe_identifier("o", module_context.header_key)
    local lhs_decl, lhs_exp, lhs = render_operator_operand(
        "lhs", lhs_name,
        trait.lhs_source, trait.lhs_target, trait.lhs_null)
    local rhs_decl, rhs_exp, rhs
    if trait.kind == "binary" then
        rhs_decl, rhs_exp, rhs = render_operator_operand(
            "rhs", rhs_name,
            trait.rhs_source, trait.rhs_target, trait.rhs_null)
    end

    local expression
    if trait.kind == "unary" then
        expression = trait.cop .. lhs_exp
    else
        expression = lhs_exp .. " " .. trait.cop .. " " .. rhs_exp
    end

    local probe_declaration =
        cdeclarator.render_declaration(probe_function_type, function_name)
    local lines = {}
    append_preamble(lines, module_context.header_preamble)
    if lhs_decl then lines[#lines + 1] = lhs_decl end
    if rhs_decl then lines[#lines + 1] = rhs_decl end
    lines[#lines + 1] = probe_declaration .. ";"
    lines[#lines + 1] = probe_declaration .. " {"
    lines[#lines + 1] = "    (void)(" .. expression .. ");"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""

    return table.concat(lines, "\n"), {
        kind = trait.kind,
        cop = trait.cop,
        expression = expression,
        lhs = lhs,
        rhs = rhs,
        lhs_decay = trait.lhs_decay == true,
        rhs_decay = trait.rhs_decay == true,
        result_type = trait.result
            and types.tostring(trait.result) or "",
    }
end

local function command_string(argv)
    local quoted = {}
    for index, argument in ipairs(argv) do
        local word, err = cdriver.shell_quote(argument)
        if not word then return nil, err end
        quoted[index] = word
    end
    return "env LANG=C LC_ALL=C " .. table.concat(quoted, " ")
end

local function default_runner(strategy, argv)
    return strategy:run(argv, {
        stderr_to_stdout = true,
    })
end

local function default_temp_provider(strategy)
    local root, temp_error = strategy:tmpname()
    if not root then
        return nil, "could not reserve private probe directory: " ..
            tostring(temp_error)
    end
    -- The optional ownership flag lets the async Titan strategy finish
    -- releasing this caller-owned tmpname reservation even when Task
    -- cancellation is delivered with the unlink completion.
    local removed, remove_error = strategy:unlink(root, true)
    if not removed then
        return nil, "could not release probe directory reservation: " ..
            tostring(remove_error)
    end
    -- The optional ownership flag lets the async Titan strategy roll back this
    -- unique, previously absent directory if its mkdir completes concurrently
    -- with Task cancellation. Ordinary Lua strategies ignore the extra value.
    local made, mkdir_error = strategy:mkdir(root, true)
    if not made then
        return nil, "could not create private probe directory: " ..
            tostring(mkdir_error)
    end

    local tracked = {}
    local workspace = {
        root = root,
        _compiler_io_strategy_owned = true,
    }

    function workspace:write(name, contents)
        local path = path_join(self.root, name)
        local ok, write_error = strategy:write_file(path, contents)
        if not ok then return nil, write_error end
        tracked[name] = true
        return true
    end

    function workspace:remove(name)
        local path = path_join(self.root, name)
        local current = strategy:lstat(path)
        if not current then
            tracked[name] = nil
            return true
        end
        local removed, err = strategy:unlink(path)
        if not removed then return nil, err end
        tracked[name] = nil
        return true
    end

    function workspace:cleanup()
        local errors = {}
        for name in pairs(tracked) do
            local removed, err = self:remove(name)
            if not removed then errors[#errors + 1] = tostring(err) end
        end
        -- Account for an object emitted by the compiler between a failed
        -- runner return and normal per-probe cleanup.
        local entries, list_error = strategy:list(self.root)
        if entries then
            for _, entry in ipairs(entries) do
                local removed, err =
                    strategy:unlink(path_join(self.root, entry))
                if not removed then
                    errors[#errors + 1] = entry .. ": " .. tostring(err)
                end
            end
        elseif list_error then
            errors[#errors + 1] = tostring(list_error)
        end
        local removed, err = strategy:rmdir(self.root)
        if not removed then errors[#errors + 1] = tostring(err) end
        if #errors > 0 then return nil, table.concat(errors, "; ") end
        return true
    end

    return workspace
end

local function result_diagnostic(result)
    if result.diagnostic ~= nil then return tostring(result.diagnostic) end
    if result.output ~= nil then return tostring(result.output) end
    local parts = {}
    if result.stdout ~= nil and result.stdout ~= "" then
        parts[#parts + 1] = tostring(result.stdout)
    end
    if result.stderr ~= nil and result.stderr ~= "" then
        parts[#parts + 1] = tostring(result.stderr)
    end
    return table.concat(parts, "\n")
end

local function normalize_runner_result(result, secondary)
    if result == nil then
        return {
            started = false,
            ok = false,
            diagnostic = tostring(secondary or "command runner did not start"),
        }
    elseif type(result) == "boolean" then
        return {
            started = true,
            ok = result,
            status = result and 0 or 1,
            diagnostic = tostring(secondary or ""),
        }
    elseif type(result) ~= "table" then
        return {
            started = false,
            ok = false,
            diagnostic = "command runner returned unsupported result type " ..
                type(result),
        }
    end

    local status = result.status or result.exit_status or result.code
    local shell_signal = result.why == "exit"
        and type(status) == "number"
        and status >= 129 and status <= 192
        and (status - 128) or nil
    local normalized = {
        started = result.started ~= false and result.spawned ~= false,
        interrupted = result.interrupted == true
            or result.why == "signal" or shell_signal ~= nil,
        status = shell_signal or status,
        diagnostic = result_diagnostic(result),
    }
    if result.ok ~= nil then
        normalized.ok = result.ok == true
    elseif result.success ~= nil then
        normalized.ok = result.success == true
    else
        normalized.ok = normalized.status == nil or normalized.status == 0
    end
    if not normalized.started or normalized.interrupted then
        normalized.ok = false
    end
    return normalized
end

local function event_text(event)
    if event.kind == "cache" then
        return ("[cprobe] %s cache %s: %s"):format(
            event.cache, event.hit and "hit" or "miss", event.key)
    elseif event.kind == "source" then
        return ("[cprobe] %s source %s:\n%s"):format(
            event.stage, event.path, event.source)
    elseif event.kind == "command" then
        return ("[cprobe] %s command: %s"):format(
            event.stage, event.command)
    elseif event.kind == "result" then
        local status = event.started == false and "not started"
            or event.interrupted and "interrupted"
            or event.ok and "exit 0"
            or "exit " .. tostring(event.status)
        local text = ("[cprobe] %s result: %s"):format(event.stage, status)
        if event.diagnostic ~= "" then
            text = text .. "\n" .. event.diagnostic
        end
        return text
    elseif event.kind == "cleanup" then
        local text = ("[cprobe] cleanup %s: %s"):format(
            event.scope, event.ok and "ok" or "failed")
        if event.error then text = text .. ": " .. event.error end
        return text
    end
    return "[cprobe] " .. tostring(event.kind)
end

function Service:_emit(event)
    if not self.verbose then return end
    local copy = deep_copy(event)
    self.evidence[#self.evidence + 1] = copy
    if self.verbose_sink then
        self.verbose_sink(copy)
    else
        print(event_text(copy))
    end
end

function Service:_persistent_success_location(source, key)
    if not self.cache_directory then return nil end
    -- v1 named markers by source alone. v2 accepted a caller-supplied semantic
    -- key, but did not independently bind the service's forced-header state.
    -- v3 includes the authoritative toolchain and forced-header manifest, so
    -- old markers are guaranteed misses even for internal callers that reuse
    -- an otherwise identical semantic key.
    local digest = sha256.hex(keyed_fields({
        { "persistent_success_version", "3" },
        { "toolchain", self.toolchain_key },
        { "forced_headers", self.forced_header_manifest },
        { "semantic_key", key or "" },
        { "source", source },
    }))
    return path_join(self.cache_directory, digest .. ".success"), digest
end

function Service:_forced_header_inputs_stable()
    for _, input in ipairs(self.forced_header_inputs or {}) do
        local identity, err =
            cdriver.header_input_identity(input.kind, input.path, self.io)
        if not identity then
            return nil, "could not restat forced C header input '" ..
                input.path .. "': " .. tostring(err)
        elseif identity ~= input.identity then
            return nil, "forced C header input changed: " .. input.path
        end
    end
    return true
end

function Service:_persistent_success(source, key)
    local path, digest = self:_persistent_success_location(source, key)
    if not path then return nil end
    local attributes = self.io:stat(path)
    if attributes and attributes.kind == "file" then
        return true, path, digest
    end
    return false, path, digest
end

-- Optional structured telemetry for compiler clients. Keep this separate from
-- verbose evidence: a cache-only observer must not retain probe sources or
-- commands, and it must never fall back to printing on stdout. The sink is
-- best-effort because observability cannot change a compiler verdict.
function Service:_trace_persistent_cache(stage, hit, digest, path)
    local sink = self.persistent_cache_trace
    if not sink then return end
    pcall(sink, tostring(stage), hit == true, tostring(digest), tostring(path))
end

function Service:_publish_persistent_success(path)
    if not path or not self.cache_directory then return nil end
    if not ensure_directory(self.cache_directory, self.io) then return nil end
    -- write_file is the strategy's atomic publication primitive. Writing the
    -- final marker directly leaves no second, unowned temporary file if an
    -- async strategy commits the rename and then delivers Task cancellation.
    local written = self.io:write_file(path, "")
    if not written then
        local attributes = self.io:stat(path)
        return attributes and attributes.kind == "file" or nil
    end
    return true
end

function Service:_ensure_workspace()
    if self.workspace then return self.workspace end
    if self.closed then return nil, "probe service is closed" end

    local provider = self.temp_provider
    local ok, workspace, err
    if self.temp_provider_is_strategy then
        workspace, err = provider(self)
        ok = true
    elseif type(provider) == "function" then
        ok, workspace, err = pcall(provider, self)
    elseif type(provider) == "table" and type(provider.create) == "function" then
        ok, workspace, err = pcall(provider.create, provider, self)
    else
        return nil, "temporary workspace provider is not callable"
    end
    if not ok then
        return nil, "temporary workspace provider raised an error: " ..
            tostring(workspace)
    elseif not workspace then
        return nil, tostring(err or "temporary workspace provider failed")
    elseif type(workspace) ~= "table" then
        return nil, "temporary workspace provider did not return a table"
    elseif type(workspace.root) ~= "string" or workspace.root == "" then
        return nil, "temporary workspace has no root path"
    end
    self.workspace = workspace
    return workspace
end

local function call_workspace(workspace, method, ...)
    local fn = workspace[method]
    if type(fn) ~= "function" then
        return nil, "temporary workspace has no " .. method .. " method"
    end
    local ok, first, second
    if workspace._compiler_io_strategy_owned then
        -- Strategy methods normalize ordinary backend failures themselves.
        -- Call them directly so a Titan Task cancellation is not converted
        -- into an ordinary probe infrastructure diagnostic by Lua pcall.
        first, second = fn(workspace, ...)
        ok = true
    else
        ok, first, second = pcall(fn, workspace, ...)
    end
    if not ok then
        return nil, method .. " raised an error: " .. tostring(first)
    elseif first == false or (first == nil and second ~= nil) then
        return nil, tostring(second or (method .. " failed"))
    end
    return true
end

function Service:_materialize_probe_wrappers(workspace, wrappers)
    if not wrappers then return true end
    local names = {}
    for name in pairs(wrappers) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        if not self.materialized_probe_wrappers[name] then
            local wrote, err = call_workspace(
                workspace, "write", name, wrappers[name])
            if not wrote then return nil, err end
            self.materialized_probe_wrappers[name] = true
        end
    end
    return true
end

function Service:_compile_argv(source_path, object_path)
    local argv = copy_array(self.compiler_argv)
    append_all(argv, self.compile_flags)
    append_all(argv, self.cppflags)
    if self.language_flag then
        argv[#argv + 1] = self.language_flag
    end
    append_all(argv, self.cflags)
    for _, include in ipairs(self.include_dirs) do
        argv[#argv + 1] = include.flag
        argv[#argv + 1] = include.path
    end
    if self.syntax_only then
        argv[#argv + 1] = "-fsyntax-only"
        argv[#argv + 1] = source_path
    else
        argv[#argv + 1] = "-c"
        argv[#argv + 1] = source_path
        argv[#argv + 1] = "-o"
        argv[#argv + 1] = object_path
    end
    return argv
end

local function infrastructure_run(stage, reason, run)
    return {
        status = "infrastructure_failure",
        ok = false,
        accepted = nil,
        stage = stage,
        reason = reason,
        diagnostic = run and run.diagnostic or tostring(reason),
        summary = first_diagnostic_line(
            run and run.diagnostic or tostring(reason)),
        command = run and run.command,
        argv = run and run.argv,
        source = run and run.source,
        source_path = run and run.source_path,
        object_path = run and run.object_path,
        exit_status = run and run.status,
        started = run and run.started,
        interrupted = run and run.interrupted == true,
        cleanup_error = run and run.cleanup_error == true,
        run_reason = run and run.reason,
    }
end

function Service:_run_source(stage, source, key, probe_label, wrappers)
    if self.closed then
        return infrastructure_run(stage, "workspace", {
            diagnostic = "probe service is closed",
            source = source,
        })
    end
    local stable, stability_error = self:_forced_header_inputs_stable()
    if not stable then
        return {
            started = false,
            ok = false,
            interrupted = false,
            reason = "header_inputs",
            diagnostic = stability_error,
            source = source,
        }
    end
    local persistent_hit, persistent_path, persistent_digest =
        self:_persistent_success(source, key)
    if persistent_path then
        self:_trace_persistent_cache(
            stage, persistent_hit, persistent_digest, persistent_path)
        self:_emit({
            kind = "cache",
            cache = "persistent success",
            hit = persistent_hit == true,
            key = persistent_digest,
            path = persistent_path,
        })
    end
    if persistent_hit then
        stable, stability_error = self:_forced_header_inputs_stable()
        if not stable then
            return {
                started = false,
                ok = false,
                interrupted = false,
                reason = "header_inputs",
                diagnostic = stability_error,
                source = source,
            }
        end
        return {
            started = true,
            ok = true,
            interrupted = false,
            status = 0,
            diagnostic = "",
            source = source,
            persistent_cached = true,
            cache_path = persistent_path,
        }
    end

    local workspace, workspace_error = self:_ensure_workspace()
    if not workspace then
        return infrastructure_run(stage, "workspace",
            { diagnostic = workspace_error, source = source })
    end
    local wrappers_ok, wrappers_error =
        self:_materialize_probe_wrappers(workspace, wrappers)
    if not wrappers_ok then
        return infrastructure_run(stage, "workspace", {
            diagnostic = "could not prepare private probe-header wrapper: " ..
                tostring(wrappers_error),
            source = source,
        })
    end

    self.sequence = self.sequence + 1
    local label = stage == "baseline" and "baseline"
        or probe_label or "unsafe-object-pointer"
    local stem = ("%06d-%s"):format(self.sequence, label)
    local source_name = stem .. ".c"
    local object_name = stem .. ".o"
    local source_path = path_join(workspace.root, source_name)
    local object_path = path_join(workspace.root, object_name)

    local wrote, write_error =
        call_workspace(workspace, "write", source_name, source)
    if not wrote then
        -- A provider may have created a partial file before reporting failure.
        -- Best-effort removal here keeps per-probe cleanup independent of the
        -- later session close.
        call_workspace(workspace, "remove", source_name)
        return infrastructure_run(stage, "workspace", {
            diagnostic = "could not write probe source: " .. write_error,
            source = source,
            source_path = source_path,
            object_path = self.syntax_only and nil or object_path,
        })
    end

    local argv = self:_compile_argv(source_path, object_path)
    local command, command_error = command_string(argv)
    if not command then
        call_workspace(workspace, "remove", source_name)
        return infrastructure_run(stage, "command", {
            diagnostic = "could not construct probe command: " .. command_error,
            argv = argv,
            source = source,
            source_path = source_path,
            object_path = self.syntax_only and nil or object_path,
        })
    end

    self:_emit({
        kind = "source",
        stage = stage,
        key = key,
        path = source_path,
        source = source,
    })
    self:_emit({
        kind = "command",
        stage = stage,
        key = key,
        argv = copy_array(argv),
        command = command,
    })

    local metadata = {
        stage = stage,
        key = key,
        argv = copy_array(argv),
        command = command,
        source = source,
        source_path = source_path,
        object_path = self.syntax_only and nil or object_path,
    }
    local call_ok, raw_result, secondary
    if self.runner_is_strategy then
        raw_result, secondary = self.runner(copy_array(argv), metadata)
        call_ok = true
    else
        call_ok, raw_result, secondary =
            pcall(self.runner, copy_array(argv), metadata)
    end
    local run
    if not call_ok then
        run = {
            started = false,
            ok = false,
            diagnostic = "command runner raised an error: " ..
                tostring(raw_result),
        }
    else
        run = normalize_runner_result(raw_result, secondary)
    end
    stable, stability_error = self:_forced_header_inputs_stable()
    if not stable then
        run.started = false
        run.ok = false
        run.interrupted = false
        run.reason = "header_inputs"
        run.diagnostic = stability_error
    end
    run.argv = copy_array(argv)
    run.command = command
    run.source = source
    run.source_path = source_path
    run.object_path = self.syntax_only and nil or object_path

    self:_emit({
        kind = "result",
        stage = stage,
        key = key,
        started = run.started,
        ok = run.ok,
        interrupted = run.interrupted,
        status = run.status,
        diagnostic = run.diagnostic,
    })

    local cleanup_errors = {}
    local source_removed, source_remove_error =
        call_workspace(workspace, "remove", source_name)
    if not source_removed then
        cleanup_errors[#cleanup_errors + 1] =
            source_name .. ": " .. source_remove_error
    end
    if not self.syntax_only then
        local object_removed, object_remove_error =
            call_workspace(workspace, "remove", object_name)
        if not object_removed then
            cleanup_errors[#cleanup_errors + 1] =
                object_name .. ": " .. object_remove_error
        end
    end
    self:_emit({
        kind = "cleanup",
        scope = stage .. " artifacts",
        ok = #cleanup_errors == 0,
        error = #cleanup_errors > 0 and table.concat(cleanup_errors, "; ")
            or nil,
    })
    if #cleanup_errors > 0 then
        run.started = false
        run.ok = false
        run.diagnostic = "could not clean probe artifacts: " ..
            table.concat(cleanup_errors, "; ")
        run.cleanup_error = true
    elseif run.started and run.ok and not run.interrupted and persistent_path then
        self:_publish_persistent_success(persistent_path)
        run.cache_path = persistent_path
    end
    return run
end

local function infrastructure_message(stage, run)
    local summary = first_diagnostic_line(run.diagnostic)
    local message
    if run.cleanup_error or run.reason == "workspace"
    or run.reason == "command" then
        message =
            "cannot validate C conversion because the probe infrastructure failed"
    elseif stage == "baseline" and run.started ~= false
    and not run.interrupted and not run.cleanup_error then
        message =
            "cannot validate C conversion because the foreign header baseline failed"
    elseif run.interrupted then
        message =
            "cannot validate C conversion because the configured compiler was interrupted"
    elseif run.started == false and run.source_path then
        message =
            "cannot validate C conversion because the configured compiler/toolchain could not be started"
    else
        message =
            "cannot validate C conversion because the probe infrastructure failed"
    end
    if summary ~= "" then message = message .. ": " .. summary end
    return message
end

function Service:_ensure_baseline(module_context)
    local stable, stability_error = self:_forced_header_inputs_stable()
    if not stable then
        return infrastructure_run("baseline", "header_inputs", {
            started = false,
            ok = false,
            interrupted = false,
            reason = "header_inputs",
            diagnostic = stability_error,
        })
    end
    local key = module_context.baseline_key
    local cached = self.baseline_cache[key]
    self:_emit({
        kind = "cache",
        cache = "baseline",
        hit = cached ~= nil,
        key = key,
    })
    if cached then
        local copy = deep_copy(cached)
        copy.cached = true
        return copy
    end

    local source = render_baseline_source(module_context)
    local run = self:_run_source(
        "baseline", source, key, nil, module_context.probe_wrappers)
    local result
    if run.started and not run.interrupted and run.ok then
        result = {
            status = "success",
            ok = true,
            accepted = true,
            stage = "baseline",
            key = key,
            cached = run.persistent_cached == true,
            persistent_cached = run.persistent_cached == true,
            diagnostic = run.diagnostic,
            summary = first_diagnostic_line(run.diagnostic),
            command = run.command,
            argv = run.argv,
            source = source,
            source_path = run.source_path,
            exit_status = run.status,
            started = true,
            interrupted = false,
            cleanup_error = false,
        }
    else
        result = infrastructure_run("baseline", "baseline", run)
        result.key = key
        result.cached = false
        result.message = infrastructure_message("baseline", run)
    end
    -- Only a completed compiler invocation supplies semantic header evidence.
    -- Workspace, spawn, interruption, and cleanup failures remain retryable.
    if run.started and not run.interrupted and not run.cleanup_error then
        self.baseline_cache[key] = deep_copy(result)
    end
    return result
end

function ModuleContext:validate_baseline()
    local service = self.service
    if service.closed then
        return {
            status = "infrastructure_failure",
            ok = false,
            accepted = nil,
            stage = "service",
            reason = "closed",
            diagnostic = "probe service is closed",
            summary = "probe service is closed",
            message =
                "cannot validate the final ordered C headers because "
                .. "the probe service is closed",
        }
    end

    local result = service:_ensure_baseline(self)
    if result.status == "success" then return result end

    -- `_ensure_baseline` deliberately presents a broken header preamble as
    -- infrastructure to candidate conversion/operator probes: those probes
    -- cannot interpret a candidate rejection unless the baseline compiles.
    -- The checker asks a different question here. A completed, uninterrupted
    -- compiler rejection is the authoritative semantic answer for the final
    -- ordered foreign-header context.
    if result.started and not result.interrupted
       and not result.cleanup_error then
        result.status = "rejected"
        result.ok = false
        result.accepted = false
        result.stage = "baseline"
        result.reason = "compiler_rejection"
        result.message =
            "configured C compiler rejected the final ordered foreign "
            .. "header context"
        if result.summary and result.summary ~= "" then
            result.message = result.message .. ": " .. result.summary
        end
    else
        result.message =
            "cannot validate the final ordered C headers because "
            .. "the probe infrastructure failed"
        if result.summary and result.summary ~= "" then
            result.message = result.message .. ": " .. result.summary
        end
    end
    return result
end

local function declaration_compatibility_result_key(
        service, module_context, rendered)
    return keyed_fields({
        { "toolchain", service.toolchain_key },
        { "headers", module_context.header_key },
        { "probe_kind", "declaration_compatibility" },
        { "left_declaration", rendered.left_declaration },
        { "right_declaration", rendered.right_declaration },
    })
end

local function closed_declaration_compatibility_result()
    return {
        status = "infrastructure_failure",
        ok = false,
        accepted = nil,
        stage = "service",
        reason = "closed",
        diagnostic = "probe service is closed",
        summary = "probe service is closed",
        message =
            "cannot validate C declaration compatibility because "
            .. "the probe service is closed",
    }
end

local function changed_forced_header_result(diagnostic)
    diagnostic = tostring(diagnostic)
    return {
        status = "infrastructure_failure",
        ok = false,
        accepted = nil,
        stage = "service",
        reason = "header_inputs",
        diagnostic = diagnostic,
        summary = first_diagnostic_line(diagnostic),
        message = "cannot validate C semantics because the configured " ..
            "forced header inputs changed: " ..
            first_diagnostic_line(diagnostic),
    }
end

local function unrenderable_declaration_compatibility_result(diagnostic)
    diagnostic = tostring(diagnostic)
    return {
        status = "rejected",
        ok = false,
        accepted = false,
        stage = "source",
        reason = "unrenderable_declaration",
        diagnostic = diagnostic,
        summary = first_diagnostic_line(diagnostic),
        message =
            "cannot prove C declaration compatibility because the "
            .. "exact declaration pair cannot be rendered: "
            .. first_diagnostic_line(diagnostic),
    }
end

local function baseline_declaration_compatibility_result(
        module_context, entry, baseline)
    return {
        status = "infrastructure_failure",
        ok = false,
        accepted = nil,
        stage = "baseline",
        kind = "declaration_compatibility",
        key = entry.key,
        baseline_key = module_context.baseline_key,
        cached = false,
        baseline_cached = baseline.cached,
        left_declaration = entry.rendered.left_declaration,
        right_declaration = entry.rendered.right_declaration,
        diagnostic = baseline.diagnostic,
        summary = baseline.summary,
        message = baseline.message
            and baseline.message:gsub(
                "cannot validate C conversion",
                "cannot validate C declaration compatibility", 1)
            or "cannot validate C declaration compatibility because "
                .. "the foreign header baseline failed",
        command = baseline.command,
        argv = baseline.argv,
        source = baseline.source,
        source_path = baseline.source_path,
        exit_status = baseline.exit_status,
        interrupted = baseline.interrupted,
    }
end

local function declaration_compatibility_candidate_result(
        module_context, entry, run, baseline_cached)
    local result = {
        kind = "declaration_compatibility",
        key = entry.key,
        baseline_key = module_context.baseline_key,
        cached = run.persistent_cached == true,
        persistent_cached = run.persistent_cached == true,
        baseline_cached = baseline_cached,
        left_declaration = entry.rendered.left_declaration,
        right_declaration = entry.rendered.right_declaration,
        diagnostic = run.diagnostic,
        summary = first_diagnostic_line(run.diagnostic),
        command = run.command,
        argv = run.argv,
        -- Keep the exact program compiled for this verdict aligned with its
        -- diagnostic, command, and temporary pathname. Lua strings are shared
        -- immutable values, so caching this one batch source under each pair
        -- key does not copy its bytes per result.
        source = run.source,
        source_path = run.source_path,
        object_path = run.object_path,
        exit_status = run.status,
        interrupted = run.interrupted == true,
    }

    if not run.started or run.interrupted or run.cleanup_error then
        result.status = "infrastructure_failure"
        result.ok = false
        result.accepted = nil
        result.stage = "candidate"
        result.reason = run.cleanup_error and "cleanup"
            or run.interrupted and "interrupted"
            or run.reason or "spawn"
        result.message = infrastructure_message("candidate", run):gsub(
            "cannot validate C conversion",
            "cannot validate C declaration compatibility", 1)
    elseif not run.ok then
        result.status = "rejected"
        result.ok = false
        result.accepted = false
        result.stage = "candidate"
        result.reason = "compiler_rejection"
        result.message =
            "configured C compiler rejected the declaration compatibility "
            .. "candidate"
        if result.summary ~= "" then
            result.message = result.message .. ": " .. result.summary
        end
    else
        result.status = "success"
        result.ok = true
        result.accepted = true
        result.stage = "candidate"
    end
    return result
end

local function declaration_compatibility_batch_key(
        service, module_context, entries)
    local fields = {
        { "toolchain", service.toolchain_key },
        { "headers", module_context.header_key },
        { "probe_kind", "declaration_compatibility_batch" },
    }
    for index, entry in ipairs(entries) do
        fields[#fields + 1] = {
            "candidate_" .. tostring(index), entry.key,
        }
    end
    return keyed_fields(fields)
end

local function copy_entry_slice(entries, first, last)
    local out = {}
    for index = first, last do
        out[#out + 1] = entries[index]
    end
    return out
end

-- Compile a group once on the ordinary success path. A compiler rejection says
-- only that at least one pair in the group failed, so recursively bisect until
-- every rejected leaf has the same singleton evidence the historical API
-- produced. Spawn/interruption/workspace failures are not semantic evidence and
-- therefore apply to the whole group without bisection or caching.
local function validate_declaration_compatibility_batch(
        module_context, entries, baseline, resolved)
    local service = module_context.service
    local source = render_declaration_compatibility_batch_source(
        module_context, entries)
    local key = declaration_compatibility_batch_key(
        service, module_context, entries)
    local run = service:_run_source(
        "candidate", source, key, "declaration-compatibility-batch",
        module_context.probe_wrappers)

    if not run.started or run.interrupted or run.cleanup_error then
        for _, entry in ipairs(entries) do
            resolved[entry.key] =
                declaration_compatibility_candidate_result(
                    module_context, entry, run, baseline.cached)
        end
        return
    elseif run.ok or #entries == 1 then
        for _, entry in ipairs(entries) do
            local result = declaration_compatibility_candidate_result(
                module_context, entry, run, baseline.cached)
            resolved[entry.key] = result
            service.result_cache[entry.key] = deep_copy(result)
        end
        return
    end

    local middle = math.floor(#entries / 2)
    validate_declaration_compatibility_batch(
        module_context, copy_entry_slice(entries, 1, middle),
        baseline, resolved)
    validate_declaration_compatibility_batch(
        module_context, copy_entry_slice(entries, middle + 1, #entries),
        baseline, resolved)
end

function ModuleContext:validate_declaration_compatibilities(candidates)
    if type(candidates) ~= "table" then
        error("C declaration compatibility candidates must be an array", 2)
    end
    local service = self.service
    local results = {}
    if service.closed then
        for index = 1, #candidates do
            results[index] = closed_declaration_compatibility_result()
        end
        return results
    end
    local stable, stability_error = service:_forced_header_inputs_stable()
    if not stable then
        for index = 1, #candidates do
            results[index] = changed_forced_header_result(stability_error)
        end
        return results
    end

    local entries = {}
    local pending_by_key = {}
    for index, candidate in ipairs(candidates) do
        local left_type = candidate.left_type or candidate[1]
        local right_type = candidate.right_type or candidate[2]
        local left_declaration = candidate.left_declaration or candidate[3]
        local right_declaration = candidate.right_declaration or candidate[4]
        local rendered_ok, rendered = pcall(
            render_declaration_compatibility_pair,
            left_type, right_type, left_declaration, right_declaration,
            probe_identifier("d", self.header_key))
        if not rendered_ok then
            results[index] =
                unrenderable_declaration_compatibility_result(rendered)
        else
            local key = declaration_compatibility_result_key(
                service, self, rendered)
            local cached = service.result_cache[key]
            local pending = pending_by_key[key]
            service:_emit({
                kind = "cache",
                cache = "candidate",
                hit = cached ~= nil or pending ~= nil,
                pending = cached == nil and pending ~= nil or nil,
                key = key,
            })
            if cached then
                local result = deep_copy(cached)
                result.cached = true
                results[index] = result
            elseif pending then
                pending.indexes[#pending.indexes + 1] = index
            else
                local entry = {
                    key = key,
                    rendered = rendered,
                    left_type = left_type,
                    right_type = right_type,
                    left_declaration = left_declaration,
                    right_declaration = right_declaration,
                    indexes = { index },
                }
                entries[#entries + 1] = entry
                pending_by_key[key] = entry
            end
        end
    end

    if #entries == 0 then return results end

    local baseline = service:_ensure_baseline(self)
    local resolved = {}
    if baseline.status ~= "success" then
        for _, entry in ipairs(entries) do
            resolved[entry.key] = baseline_declaration_compatibility_result(
                self, entry, baseline)
        end
    else
        validate_declaration_compatibility_batch(
            self, entries, baseline, resolved)
    end

    for _, entry in ipairs(entries) do
        local result = resolved[entry.key]
        for occurrence, index in ipairs(entry.indexes) do
            results[index] = deep_copy(result)
            if occurrence > 1 and result.status ~= "infrastructure_failure" then
                results[index].cached = true
            end
        end
    end
    return results
end

function ModuleContext:validate_declaration_compatibility(
        left_type, right_type, left_declaration, right_declaration)
    return self:validate_declaration_compatibilities({ {
        left_type = left_type,
        right_type = right_type,
        left_declaration = left_declaration,
        right_declaration = right_declaration,
    } })[1]
end

local function pointer_result_key(service, module_context, rendered)
    return keyed_fields({
        { "toolchain", service.toolchain_key },
        { "headers", module_context.header_key },
        { "probe_kind", "unsafe_object_pointer" },
        { "direction", "source_to_target" },
        { "source_type", rendered.source_type },
        { "source_declaration", rendered.source_declaration },
        { "target_type", rendered.target_type },
        { "target_declaration", rendered.target_declaration },
    })
end

function ModuleContext:probe_unsafe_object_pointer(source_type, target_type)
    local service = self.service
    if service.closed then
        return {
            status = "infrastructure_failure",
            ok = false,
            accepted = nil,
            stage = "service",
            reason = "closed",
            diagnostic = "probe service is closed",
            summary = "probe service is closed",
            message =
                "cannot validate C conversion because the probe service is closed",
        }
    end
    local stable, stability_error = service:_forced_header_inputs_stable()
    if not stable then
        return changed_forced_header_result(stability_error)
    end

    local rendered_ok, source, rendered = pcall(
        render_pointer_source, self, source_type, target_type)
    if not rendered_ok then
        return {
            status = "infrastructure_failure",
            ok = false,
            accepted = nil,
            stage = "source",
            reason = "render",
            diagnostic = tostring(source),
            summary = first_diagnostic_line(tostring(source)),
            message =
                "cannot validate C conversion because probe source generation failed: " ..
                first_diagnostic_line(tostring(source)),
        }
    end

    local key = pointer_result_key(service, self, rendered)
    local cached = service.result_cache[key]
    service:_emit({
        kind = "cache",
        cache = "candidate",
        hit = cached ~= nil,
        key = key,
    })
    if cached then
        local result = deep_copy(cached)
        result.cached = true
        return result
    end

    local baseline = service:_ensure_baseline(self)
    if baseline.status ~= "success" then
        return {
            status = "infrastructure_failure",
            ok = false,
            accepted = nil,
            stage = "baseline",
            kind = "unsafe_object_pointer",
            key = key,
            baseline_key = self.baseline_key,
            cached = false,
            baseline_cached = baseline.cached,
            source_type = rendered.source_type,
            target_type = rendered.target_type,
            diagnostic = baseline.diagnostic,
            summary = baseline.summary,
            message = baseline.message,
            command = baseline.command,
            argv = baseline.argv,
            source = baseline.source,
            source_path = baseline.source_path,
            exit_status = baseline.exit_status,
            interrupted = baseline.interrupted,
        }
    end

    local run = service:_run_source(
        "candidate", source, key, nil, self.probe_wrappers)
    local result = {
        kind = "unsafe_object_pointer",
        key = key,
        baseline_key = self.baseline_key,
        cached = run.persistent_cached == true,
        persistent_cached = run.persistent_cached == true,
        baseline_cached = baseline.cached,
        source_type = rendered.source_type,
        target_type = rendered.target_type,
        source_declaration = rendered.source_declaration,
        target_declaration = rendered.target_declaration,
        diagnostic = run.diagnostic,
        summary = first_diagnostic_line(run.diagnostic),
        command = run.command,
        argv = run.argv,
        source = source,
        source_path = run.source_path,
        object_path = run.object_path,
        exit_status = run.status,
        interrupted = run.interrupted == true,
    }

    if not run.started or run.interrupted or run.cleanup_error then
        result.status = "infrastructure_failure"
        result.ok = false
        result.accepted = nil
        result.stage = "candidate"
        result.reason = run.cleanup_error and "cleanup"
            or run.interrupted and "interrupted"
            or run.reason or "spawn"
        result.message = infrastructure_message("candidate", run)
        return result
    elseif not run.ok then
        result.status = "rejected"
        result.ok = false
        result.accepted = false
        result.stage = "candidate"
        result.reason = "compiler_rejection"
        result.message =
            "configured C compiler rejected conversion from '" ..
            rendered.source_type .. "' to '" .. rendered.target_type .. "'"
        if result.summary ~= "" then
            result.message = result.message .. ": " .. result.summary
        end
    else
        result.status = "success"
        result.ok = true
        result.accepted = true
        result.stage = "candidate"
    end

    -- Only an actual compiler answer is semantic probe cache material. A
    -- spawn/interruption/cleanup failure remains infrastructure, never a
    -- negative conversion result.
    service.result_cache[key] = deep_copy(result)
    return result
end

ModuleContext.unsafe_object_pointer =
    ModuleContext.probe_unsafe_object_pointer

local function operator_result_key(service, module_context, rendered)
    local lhs = rendered.lhs
    local rhs = rendered.rhs or {
        source_type = "",
        source_declaration = "",
        target_type = "",
        null = false,
    }
    return keyed_fields({
        { "toolchain", service.toolchain_key },
        { "headers", module_context.header_key },
        { "probe_kind", "c_operator" },
        { "operator_kind", rendered.kind },
        { "operator_spelling", rendered.cop },
        { "operator_expression", rendered.expression },
        { "lhs_source_type", lhs.source_type },
        { "lhs_source_declaration", lhs.source_declaration },
        { "lhs_target_type", lhs.target_type },
        { "lhs_null", tostring(lhs.null) },
        { "lhs_decay", tostring(rendered.lhs_decay) },
        { "rhs_source_type", rhs.source_type },
        { "rhs_source_declaration", rhs.source_declaration },
        { "rhs_target_type", rhs.target_type },
        { "rhs_null", tostring(rhs.null) },
        { "rhs_decay", tostring(rendered.rhs_decay) },
        { "result_type", rendered.result_type },
    })
end

function ModuleContext:probe_operator(trait)
    local service = self.service
    if service.closed then
        return {
            status = "infrastructure_failure",
            ok = false,
            accepted = nil,
            stage = "service",
            reason = "closed",
            diagnostic = "probe service is closed",
            summary = "probe service is closed",
            message =
                "cannot validate C operator because the probe service is closed",
        }
    end
    local stable, stability_error = service:_forced_header_inputs_stable()
    if not stable then
        return changed_forced_header_result(stability_error)
    end

    local rendered_ok, source, rendered = pcall(
        render_operator_source, self, trait)
    if not rendered_ok then
        return {
            status = "infrastructure_failure",
            ok = false,
            accepted = nil,
            stage = "source",
            reason = "render",
            diagnostic = tostring(source),
            summary = first_diagnostic_line(tostring(source)),
            message =
                "cannot validate C operator because probe source generation failed: "
                .. first_diagnostic_line(tostring(source)),
        }
    end

    local key = operator_result_key(service, self, rendered)
    local cached = service.result_cache[key]
    service:_emit({
        kind = "cache",
        cache = "candidate",
        hit = cached ~= nil,
        key = key,
    })
    if cached then
        local result = deep_copy(cached)
        result.cached = true
        return result
    end

    local baseline = service:_ensure_baseline(self)
    if baseline.status ~= "success" then
        return {
            status = "infrastructure_failure",
            ok = false,
            accepted = nil,
            stage = "baseline",
            kind = "c_operator",
            key = key,
            baseline_key = self.baseline_key,
            cached = false,
            baseline_cached = baseline.cached,
            operator_kind = rendered.kind,
            operator = rendered.cop,
            expression = rendered.expression,
            diagnostic = baseline.diagnostic,
            summary = baseline.summary,
            message = baseline.message
                and baseline.message:gsub(
                    "cannot validate C conversion",
                    "cannot validate C operator", 1)
                or "cannot validate C operator because the foreign "
                    .. "header baseline failed",
            command = baseline.command,
            argv = baseline.argv,
            source = baseline.source,
            source_path = baseline.source_path,
            exit_status = baseline.exit_status,
            interrupted = baseline.interrupted,
        }
    end

    local run = service:_run_source(
        "candidate", source, key, "c-operator", self.probe_wrappers)
    local result = {
        kind = "c_operator",
        key = key,
        baseline_key = self.baseline_key,
        cached = run.persistent_cached == true,
        persistent_cached = run.persistent_cached == true,
        baseline_cached = baseline.cached,
        operator_kind = rendered.kind,
        operator = rendered.cop,
        expression = rendered.expression,
        rendered = rendered,
        diagnostic = run.diagnostic,
        summary = first_diagnostic_line(run.diagnostic),
        command = run.command,
        argv = run.argv,
        source = source,
        source_path = run.source_path,
        object_path = run.object_path,
        exit_status = run.status,
        interrupted = run.interrupted == true,
    }

    if not run.started or run.interrupted or run.cleanup_error then
        result.status = "infrastructure_failure"
        result.ok = false
        result.accepted = nil
        result.stage = "candidate"
        result.reason = run.cleanup_error and "cleanup"
            or run.interrupted and "interrupted"
            or run.reason or "spawn"
        result.message =
            infrastructure_message("candidate", run):gsub(
                "cannot validate C conversion",
                "cannot validate C operator", 1)
        return result
    elseif not run.ok then
        result.status = "rejected"
        result.ok = false
        result.accepted = false
        result.stage = "candidate"
        result.reason = "compiler_rejection"
        result.message =
            "configured C compiler rejected "
            .. rendered.kind .. " operator expression '"
            .. rendered.expression .. "'"
        if result.summary ~= "" then
            result.message = result.message .. ": " .. result.summary
        end
    else
        result.status = "success"
        result.ok = true
        result.accepted = true
        result.stage = "candidate"
    end

    -- Compiler rejection is a semantic answer; execution and cleanup
    -- failures are infrastructure and deliberately remain retryable.
    service.result_cache[key] = deep_copy(result)
    return result
end

ModuleContext.c_operator = ModuleContext.probe_operator

function Service:module_context(options)
    if self.closed then return nil, "probe service is closed" end
    local stable, stability_error = self:_forced_header_inputs_stable()
    if not stable then return nil, stability_error end
    options = options or {}
    if type(options) ~= "table" then
        return nil, "module probe context options must be a table"
    end

    local process_cwd, cwd_error = self.io:cwd()
    if not process_cwd then
        return nil, "cannot determine module probe cwd: " ..
            tostring(cwd_error)
    end
    local cwd = options.cwd or process_cwd
    if type(cwd) ~= "string" or cwd == "" then
        return nil, "module probe context cwd must be a nonempty string"
    end
    cwd = absolute_path(cwd, process_cwd)
    local source_dir = options.source_dir or cwd
    if type(source_dir) ~= "string" or source_dir == "" then
        return nil, "module probe source_dir must be a nonempty string"
    end
    source_dir = absolute_path(source_dir, cwd)

    local raw_includes = options.includes or options.include_descriptors
        or options.headers or {}
    if type(raw_includes) ~= "table" then
        return nil, "module probe includes must be an ordered array"
    end
    local includes = {}
    for index = 1, #raw_includes do
        local include, err = normalize_include_descriptor(
            raw_includes[index], source_dir, cwd)
        if not include then
            return nil, "invalid C include descriptor " .. index .. ": " .. err
        end
        includes[index] = include
    end
    for key in pairs(raw_includes) do
        if type(key) ~= "number" or key < 1 or key > #raw_includes
        or key % 1 ~= 0 then
            return nil, "module probe includes must be a dense ordered array"
        end
    end

    local probe_wrappers = {}
    for _, include in ipairs(includes) do
        local wrapper = include.probe_wrapper
        if wrapper then
            local existing = probe_wrappers[wrapper.name] or
                self.probe_wrapper_bindings[wrapper.name]
            if existing and existing ~= wrapper.contents then
                return nil, "conflicting private probe-header wrapper '" ..
                    wrapper.name .. "'"
            end
            probe_wrappers[wrapper.name] = wrapper.contents
        end
    end
    for name, contents in pairs(probe_wrappers) do
        self.probe_wrapper_bindings[name] = contents
    end

    local header_key = header_context_key(
        source_dir, includes, self.forced_header_manifest)
    local header_inputs, inputs_error = collect_header_inputs(
        includes, self.forced_header_inputs)
    if not header_inputs then return nil, inputs_error end
    local context = setmetatable({
        service = self,
        source_dir = source_dir,
        includes = includes,
        header_preamble = render_header_preamble(includes),
        probe_wrappers = probe_wrappers,
        header_inputs = header_inputs,
        header_key = header_key,
        baseline_key = keyed_fields({
            { "toolchain", self.toolchain_key },
            { "headers", header_key },
            { "probe_kind", "baseline" },
        }),
    }, ModuleContext)
    return context
end

Service.new_module_context = Service.module_context

function Service:probe_unsafe_object_pointer(
        module_context, source_type, target_type)
    if getmetatable(module_context) ~= ModuleContext
    or module_context.service ~= self then
        return nil, "module context does not belong to this probe service"
    end
    return module_context:probe_unsafe_object_pointer(source_type, target_type)
end

function Service:validate_declaration_compatibility(
        module_context, left_type, right_type,
        left_declaration, right_declaration)
    if getmetatable(module_context) ~= ModuleContext
    or module_context.service ~= self then
        return nil, "module context does not belong to this probe service"
    end
    return module_context:validate_declaration_compatibility(
        left_type, right_type, left_declaration, right_declaration)
end

function Service:validate_declaration_compatibilities(
        module_context, candidates)
    if getmetatable(module_context) ~= ModuleContext
    or module_context.service ~= self then
        return nil, "module context does not belong to this probe service"
    end
    return module_context:validate_declaration_compatibilities(candidates)
end

function Service:probe_operator(module_context, trait)
    if getmetatable(module_context) ~= ModuleContext
    or module_context.service ~= self then
        return nil, "module context does not belong to this probe service"
    end
    return module_context:probe_operator(trait)
end

function Service:close()
    if self.closed and not self.workspace then
        if self.close_error then return nil, self.close_error end
        return true
    end
    self.closed = true
    if not self.workspace then return true end

    local workspace = self.workspace
    local wrapper_names = {}
    for name in pairs(self.materialized_probe_wrappers) do
        wrapper_names[#wrapper_names + 1] = name
    end
    table.sort(wrapper_names)
    local wrapper_error
    for _, name in ipairs(wrapper_names) do
        local removed, remove_error =
            call_workspace(workspace, "remove", name)
        if not removed and not wrapper_error then
            wrapper_error = remove_error
        end
    end
    local cleaned, cleanup_error =
        call_workspace(workspace, "cleanup")
    -- A strategy-owned cancellation raises out of call_workspace before these
    -- ownership fields are cleared. An uncancelled resolver cleanup can then
    -- retry the exact workspace. Ordinary custom-provider failures retain the
    -- historical terminal close_error behavior.
    self.workspace = nil
    self.materialized_probe_wrappers = {}
    local close_error = wrapper_error
    if not cleaned and not close_error then close_error = cleanup_error end
    self:_emit({
        kind = "cleanup",
        scope = "session workspace",
        ok = close_error == nil,
        error = close_error,
    })
    if close_error then
        self.close_error = close_error
        return nil, close_error
    end
    return true
end

Service.__close = function(self)
    self:close()
end

-- Return the exact compiler context with which cdriver must preprocess and
-- parse this service's headers. Fold the service's separated flag channels
-- into cdriver's compile-prefix channel so their relative order remains
-- identical; fixed `-I` roots stay explicit so cdriver's own header resolver
-- sees the same ordered SDK roots without rediscovery.
function Service:cdriver_process_options()
    local compile_flags = copy_array(self.compile_flags)
    append_all(compile_flags, self.cppflags)
    if self.language_flag then
        compile_flags[#compile_flags + 1] = self.language_flag
    end
    append_all(compile_flags, self.cflags)

    local fixed_include_dirs = {}
    local plain_fixed_roots = true
    for _, include in ipairs(self.include_dirs) do
        if include.flag ~= "-I" then
            plain_fixed_roots = false
            break
        end
    end
    if plain_fixed_roots then
        for index, include in ipairs(self.include_dirs) do
            fixed_include_dirs[index] = include.path
        end
    else
        -- cdriver's fixed-root channel spells only `-I`. Preserve a mixed
        -- `-I`/`-iquote`/`-isystem` service exactly by folding the complete
        -- ordered suffix into the already-authoritative compile prefix.
        for _, include in ipairs(self.include_dirs) do
            compile_flags[#compile_flags + 1] = include.flag
            compile_flags[#compile_flags + 1] = include.path
        end
    end

    return {
        io = self.io,
        process_trace = self.process_trace,
        process_analysis = self.process_analysis,
        compiler = copy_array(self.compiler_argv),
        language_mode = self.language_mode,
        language_flag = false,
        compile_flags = compile_flags,
        cppflags = {},
        compiler_include_dirs = fixed_include_dirs,
        fixed_include_dirs = copy_array(fixed_include_dirs),
        profile = self.profile and deep_copy(self.profile) or nil,
        profile_identity = self.profile_identity,
    }
end

Service.process_file_options = Service.cdriver_process_options

local function option(options, toolchain, name, default)
    if options[name] ~= nil then return options[name] end
    if toolchain[name] ~= nil then return toolchain[name] end
    return default
end

function cprobe.new_service(options)
    options = options or {}
    if type(options) ~= "table" then
        return nil, "C probe service options must be a table"
    end
    local toolchain = options.toolchain or {}
    if type(toolchain) ~= "table" then
        return nil, "C probe toolchain must be a table"
    end

    local strategy = options.io or toolchain.io or default_io
    local valid, validation_error = pcall(compiler_io.validate, strategy, 3)
    if not valid then
        return nil, "invalid compiler I/O strategy: " ..
            tostring(validation_error)
    end

    local compiler_argv, err = dense_string_array(
        option(options, toolchain, "compiler_argv",
            option(options, toolchain, "compiler", "cc")),
        "compiler_argv", true)
    if not compiler_argv then return nil, err end
    if #compiler_argv == 0 then return nil, "compiler_argv is empty" end

    local compile_flags
    compile_flags, err = dense_string_array(
        option(options, toolchain, "compile_flags", {}),
        "compile_flags", false)
    if not compile_flags then return nil, err end
    local cppflags
    cppflags, err = dense_string_array(
        option(options, toolchain, "cppflags", {}),
        "cppflags", false)
    if not cppflags then return nil, err end
    local cflags
    cflags, err = dense_string_array(
        option(options, toolchain, "cflags", {}),
        "cflags", false)
    if not cflags then return nil, err end

    local language_mode =
        option(options, toolchain, "language_mode", "c99")
    if type(language_mode) ~= "string" or language_mode == ""
    or language_mode:find("[\r\n%z]") then
        return nil, "language_mode must be a nonempty single-line string"
    end
    local language_flag = option(
        options, toolchain, "language_flag", "-std=" .. language_mode)
    if language_flag == false then
        language_flag = nil
    elseif type(language_flag) ~= "string" or language_flag == ""
    or language_flag:find("[\r\n%z]") then
        return nil, "language_flag must be false or a nonempty single-line string"
    end

    local raw_include_dirs =
        option(options, toolchain, "include_dirs", nil)
    if raw_include_dirs == nil then
        raw_include_dirs, err =
            cdriver.resolve_compiler_include_dirs(nil, strategy)
        if not raw_include_dirs then return nil, err end
    end
    local include_dirs
    include_dirs, err = normalize_include_dirs(
        raw_include_dirs)
    if not include_dirs then return nil, err end

    local profile = option(options, toolchain, "profile", nil)
    if profile ~= nil and type(profile) ~= "table" then
        return nil, "profile must be a target-profile table"
    end
    local profile_identity =
        option(options, toolchain, "profile_identity",
            option(options, toolchain, "arithmetic_profile_identity", ""))
    if type(profile_identity) ~= "string" then
        return nil, "profile_identity must be a string"
    end
    if profile then
        local derived_identity
        derived_identity, err =
            csemantics.profile_identity(profile)
        if not derived_identity then
            return nil, "invalid target profile: " .. tostring(err)
        elseif profile_identity ~= ""
           and profile_identity ~= derived_identity then
            return nil, "profile_identity disagrees with the target profile"
        end
        profile_identity = derived_identity
        profile = deep_copy(profile)
        profile.identity = derived_identity
    end

    local process_trace = option(
        options, toolchain, "process_trace", nil)
    if process_trace ~= nil and type(process_trace) ~= "function" then
        return nil, "process_trace must be a function"
    end
    local process_analysis = option(
        options, toolchain, "process_analysis", nil)
    local persistent_cache_trace = option(
        options, toolchain, "persistent_cache_trace", nil)
    if persistent_cache_trace ~= nil and
       type(persistent_cache_trace) ~= "function" then
        return nil, "persistent_cache_trace must be a function"
    end

    -- `-c ... -o private.o` is the portable non-linking baseline. A caller may
    -- opt into `-fsyntax-only` only after establishing that its configured
    -- compiler supports that extension.
    local syntax_only = option(options, toolchain, "syntax_only", false)
    if type(syntax_only) ~= "boolean" then
        return nil, "syntax_only must be a boolean"
    end

    local fields = {
        { "compiler_argv", encode_sequence(compiler_argv) },
        { "compile_flags", encode_sequence(compile_flags) },
        { "language_mode", language_mode },
        { "language_flag", language_flag or "" },
        { "cppflags", encode_sequence(cppflags) },
        { "cflags", encode_sequence(cflags) },
        { "include_dirs", include_dirs_key(include_dirs) },
        { "profile_identity", profile_identity },
        { "compile_mode", syntax_only and "syntax-only" or "object" },
    }

    local effective_preprocessor_flags = copy_array(compile_flags)
    append_all(effective_preprocessor_flags, cppflags)
    if language_flag then
        effective_preprocessor_flags[#effective_preprocessor_flags + 1] =
            language_flag
    end
    append_all(effective_preprocessor_flags, cflags)
    for _, include in ipairs(include_dirs) do
        effective_preprocessor_flags[#effective_preprocessor_flags + 1] =
            include.flag
        effective_preprocessor_flags[#effective_preprocessor_flags + 1] =
            include.path
    end
    local forced_headers
    forced_headers, err = cdriver.forced_header_inputs({
        io = strategy,
        compiler = compiler_argv,
        language_mode = language_mode,
        language_flag = false,
        compile_flags = effective_preprocessor_flags,
        cppflags = {},
        compiler_include_dirs = {},
    })
    if not forced_headers then
        return nil, "invalid forced C header configuration: " .. tostring(err)
    end
    local forced_header_inputs = {}
    append_all(forced_header_inputs,
        forced_headers.c_header_dependencies)
    append_all(forced_header_inputs,
        forced_headers.c_header_search_inputs)
    -- cpp's manifest is intentionally exact and ordered, but it can grow with
    -- every forced header and include-search candidate. Toolchain and probe
    -- keys are retained and nested repeatedly, so publish only one
    -- domain-separated digest here; the exact restattable inputs remain in the
    -- separate arrays above.
    local forced_header_manifest =
        "titan-cprobe-forced-header-context-v2:sha256:" .. sha256.hex(
            keyed_fields({
                { "forced_header_context_version", "2" },
                { "manifest", forced_headers.manifest },
            }))
    fields[#fields + 1] = {
        "forced_header_manifest", forced_header_manifest,
    }

    local verbose = options.verbose
    local verbose_sink = options.verbose_sink
    if type(verbose) == "function" and verbose_sink == nil then
        verbose_sink = verbose
        verbose = true
    end
    if verbose == nil then verbose = false end
    if type(verbose) ~= "boolean" then
        return nil, "verbose must be a boolean or event sink function"
    elseif verbose_sink ~= nil and type(verbose_sink) ~= "function" then
        return nil, "verbose_sink must be a function"
    end

    local runner = options.runner
    local runner_is_strategy = runner == nil
    if runner == nil then
        runner = function(argv)
            return default_runner(strategy, argv)
        end
    end
    if type(runner) ~= "function" then
        return nil, "runner must be a function"
    end
    local temp_provider = options.temp_provider
    local temp_provider_is_strategy = temp_provider == nil
    if temp_provider == nil then
        temp_provider = function()
            return default_temp_provider(strategy)
        end
    end
    if type(temp_provider) ~= "function"
    and not (type(temp_provider) == "table"
        and type(temp_provider.create) == "function") then
        return nil, "temp_provider must be callable"
    end

    local cache_directory = option(
        options, toolchain, "cache_directory", nil)
    if cache_directory == "" then cache_directory = nil end
    if cache_directory ~= nil then
        if type(cache_directory) ~= "string"
           or cache_directory:find("%z") then
            return nil, "cache_directory must be a pathname string"
        end
        local cwd, cwd_error = strategy:cwd()
        if not cwd then
            return nil, "cannot determine cache cwd: " .. tostring(cwd_error)
        end
        cache_directory = absolute_path(cache_directory, cwd)
        if cache_directory ~= "/" then
            cache_directory = cache_directory:gsub("/+$", "")
        end
        local cache_identity = option(
            options, toolchain, "cache_identity", nil)
        if cache_identity == "" then cache_identity = nil end
        if cache_identity ~= nil then
            if type(cache_identity) ~= "string" then
                return nil, "cache_identity must be a string"
            end
            cache_directory = path_join(cache_directory,
                "namespace-" .. sha256.hex(cache_identity))
        end
    end

    return setmetatable({
        io = strategy,
        process_trace = process_trace,
        process_analysis = process_analysis,
        persistent_cache_trace = persistent_cache_trace,
        compiler_argv = compiler_argv,
        compile_flags = compile_flags,
        language_mode = language_mode,
        language_flag = language_flag,
        cppflags = cppflags,
        cflags = cflags,
        include_dirs = include_dirs,
        forced_header_dependencies =
            forced_headers.c_header_dependencies,
        forced_header_search_inputs =
            forced_headers.c_header_search_inputs,
        forced_header_inputs = forced_header_inputs,
        forced_header_manifest = forced_header_manifest,
        profile = profile,
        profile_identity = profile_identity,
        syntax_only = syntax_only,
        toolchain_key = keyed_fields(fields),
        runner = runner,
        runner_is_strategy = runner_is_strategy,
        temp_provider = temp_provider,
        temp_provider_is_strategy = temp_provider_is_strategy,
        cache_directory = cache_directory,
        verbose = verbose,
        verbose_sink = verbose_sink,
        evidence = {},
        baseline_cache = {},
        result_cache = {},
        probe_wrapper_bindings = {},
        materialized_probe_wrappers = {},
        sequence = 0,
        workspace = nil,
        closed = false,
    }, Service)
end

cprobe.source_foreign_include_alias = source_foreign_include_alias
cprobe.collect_header_inputs = collect_header_inputs

function cprobe.normalize_include_descriptor(descriptor, options)
    options = options or {}
    local strategy = options.io or default_io
    local process_cwd, cwd_error = strategy:cwd()
    if not process_cwd then
        return nil, "cannot determine include cwd: " .. tostring(cwd_error)
    end
    local cwd = absolute_path(options.cwd or process_cwd, process_cwd)
    local source_dir = absolute_path(options.source_dir or cwd, cwd)
    return normalize_include_descriptor(descriptor, source_dir, cwd)
end

cprobe.new = cprobe.new_service
Service.new = cprobe.new_service
cprobe.Service = Service
cprobe.ModuleContext = ModuleContext
cprobe.render_baseline_source = render_baseline_source
cprobe.render_declaration_compatibility_source =
    render_declaration_compatibility_source
cprobe.render_unsafe_object_pointer_source = render_pointer_source
cprobe.render_operator_source = render_operator_source

return cprobe
