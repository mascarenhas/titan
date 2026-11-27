-- Session-scoped, compile-only C probes.
--
-- This module deliberately knows nothing about Titan compatibility. Callers
-- first decide that a C construct is a permitted candidate, then ask this
-- service whether the configured C compiler accepts the exact lowering.
local cprobe = {}

local cdeclarator = require "titan-compiler.cdeclarator"
local cprobe_cache = require "titan-compiler.cprobe_cache"
local csemantics = require "titan-compiler.csemantics"
local cpreamble = require "titan-compiler.cpreamble"
local types = require "titan-compiler.types"
local sha256 = require "titan-compiler.sha256"
local staticmetadata = require "titan-compiler.staticmetadata"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local ffiheaders = require "titan-compiler.ffiheaders"
local jobs = require "titan-compiler.jobs"

local default_io = compiler_io.new_sync()

-- Keep disk reads bounded even if a file changes between stat and read.
local MAX_PERSISTENT_RECORD_BYTES = cprobe_cache.MAX_RECORD_BYTES
local MAX_SELECTION_OBJECT_BYTES = 16 * 1024 * 1024
local ENUM_PAYLOAD_PREFIX = "TITENUM\0\1\12"
local ENUM_PAYLOAD_BYTES = 12
local ENUM_SECTION = { elf = ".titan.cprobe", coff = ".titan.cprobe", wasm = ".titan.cprobe",
    macho_segment = "__DATA", macho_section = "__titancprobe" }

-- IDs are a persistent query protocol, not positions in an eligibility list.
cprobe.enum_carrier_names = {
    "char", "signed char", "unsigned char", "short", "unsigned short",
    "int", "unsigned int", "long", "unsigned long", "long long",
    "unsigned long long",
}

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

-- Each source is an independent translation unit. Role names are fixed so
-- neither toolchain nor header metadata is hidden in the source cache key.
local function probe_identifier(role)
    return "titan_probe_" .. role
end

-- Observers receive a bounded label of the ordered include spellings.
-- Labels are for diagnostics only and never affect source or cache lookup.
local TRACE_HEADER_SPELLING_BYTES = 48
local TRACE_HEADER_LABEL_INCLUDES = 3
local TRACE_HEADER_LABEL_BYTES = 192

local function bounded_trace_spelling(value)
    value = tostring(value or "")
    local parts = {}
    local length = 0
    local truncated = false
    for index = 1, #value do
        local byte = value:byte(index)
        local piece
        if byte >= 32 and byte <= 126 then
            local character = string.char(byte)
            piece = (character == "\\" or character == '"')
                and "\\" .. character or character
        else
            piece = ("\\x%02x"):format(byte)
        end
        if length + #piece > TRACE_HEADER_SPELLING_BYTES - 3 then
            truncated = true
            break
        end
        parts[#parts + 1] = piece
        length = length + #piece
    end
    if truncated then parts[#parts + 1] = "..." end
    return table.concat(parts)
end

local function trace_header_label(includes)
    local labels = {}
    local shown = math.min(#includes, TRACE_HEADER_LABEL_INCLUDES)
    for index = 1, shown do
        local include = includes[index]
        local spelling = bounded_trace_spelling(
            include.original ~= "" and include.original
                or include.include_name)
        labels[index] = include.include_kind == "angle"
            and "<" .. spelling .. ">" or '"' .. spelling .. '"'
    end
    if #includes > shown then
        labels[#labels + 1] =
            ("+%d more"):format(#includes - shown)
    end
    local label = table.concat(labels, ", ")
    if #label > TRACE_HEADER_LABEL_BYTES then
        label = label:sub(1, TRACE_HEADER_LABEL_BYTES - 3) .. "..."
    end
    return label
end

local platform = require "titan-compiler.platform"

local function path_join(directory, name)
    if platform.windows then return assert(platform.join(directory, name)) end
    if directory:sub(-1) == "/" then return directory .. name end
    return directory .. "/" .. name
end

local function absolute_path(path, base, strategy)
    if platform.windows then return assert(platform.absolute(path, base, strategy or default_io)) end
    if path:sub(1, 1) == "/" then return path end
    return path_join(base, path)
end

local function ensure_directory(path, strategy)
    local attributes = strategy:stat(path)
    if attributes and attributes.kind == "directory" then return true end
    if attributes ~= nil then return nil end
    local parent = platform.windows and platform.parent(path) or path:match("^(.*)/[^/]+$")
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

local quote_header_name = ffiheaders.quote_header

local function angle_header_name(name)
    if name:find("[<>\r\n%z]") then
        return nil, "angle C header name contains a delimiter, newline, or NUL byte"
    end
    return "<" .. name .. ">"
end

local function normalize_include_descriptor(descriptor, source_dir, cwd, strategy)
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
    local generated_header = descriptor.generated_header
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
    if generated_header ~= nil then
        -- Generated plans are immutable compiler-owned data. Normalization
        -- changes the include spelling, not the plan or its existing digest.
        local err
        rendered, err = quote_header_name(generated_header.logical_name)
        if not rendered then return nil, err end
        return {
            original = generated_header.logical_name,
            resolved = generated_header.identity, include_kind = "quote",
            include_name = generated_header.logical_name,
            rendered = rendered, generated_header = generated_header,
            c_header_dependencies = descriptor.c_header_dependencies,
            c_header_search_inputs = descriptor.c_header_search_inputs,
            c_header_graph_key = descriptor.c_header_graph_key,
        }
    elseif kind == "quote" then
        -- cdriver descriptors are resolved relative to the importing process,
        -- not relative to a future probe directory. Make that interpretation
        -- explicit before the source moves under /tmp. When no resolved path
        -- was supplied, the original quote import belongs to source_dir.
        if resolved then
            effective_resolved = absolute_path(resolved, cwd, strategy)
        else
            effective_resolved = absolute_path(name, source_dir, strategy)
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
        c_header_dependencies = descriptor.c_header_dependencies,
        c_header_search_inputs = descriptor.c_header_search_inputs,
        c_header_graph_key = descriptor.c_header_graph_key,
    }
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

local function render_header_preamble(includes)
    local lines = { cpreamble.fixed_prefix }
    if #includes > 0 then lines[#lines + 1] = "" end
    for _, include in ipairs(includes) do
        if include.generated_header then
            -- The generated bundle is program input. Bind its exact ordered
            -- contents/origins in the raw source, independently of its private
            -- location. External authored header changes retain manual clearing.
            lines[#lines + 1] = "/* Titan C environment: " .. include.generated_header.digest .. " */"
        end
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
    local name = probe_identifier("b")
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
        probe_identifier("d"))
    local lines = {}
    append_preamble(lines, module_context.header_preamble)
    -- These are synthetic declarations. Enum/carrier compatibility is a C
    -- type question, even when GCC warns about spelling the compatible pair.
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
    return table.concat(lines, "\n"), rendered
end

local function enum_selection_question(eligible_ids)
    if type(eligible_ids) ~= "table" then
        error("enum carrier IDs must be a dense ordered array", 2)
    end
    local ids, seen = {}, {}
    for index, id in ipairs(eligible_ids) do
        if math.type(id) ~= "integer" or not cprobe.enum_carrier_names[id]
           or seen[id] then
            error("enum carrier IDs must be distinct stable IDs in 1..11", 2)
        end
        ids[index], seen[id] = id, true
    end
    for key in pairs(eligible_ids) do
        if math.type(key) ~= "integer" or key < 1 or key > #ids then
            error("enum carrier IDs must be a dense ordered array", 2)
        end
    end
    -- Validate a returned count/sum against this exact eligibility question,
    -- including multiple matches. No target arithmetic is evaluated in Lua.
    local sums = { [0] = { [0] = true } }
    for index, id in ipairs(ids) do
        for count = index, 1, -1 do
            sums[count] = sums[count] or {}
            for sum in pairs(sums[count - 1]) do
                sums[count][sum + id] = true
            end
        end
    end
    local function valid_result(result)
        if result.outcome == "compiler_rejection" then
            return result.selection == nil
        end
        local selection = result.selection
        return cprobe_cache.valid_selection(selection) and
            sums[selection.match_count] ~= nil and
            sums[selection.match_count][selection.carrier_id] == true
    end
    return { ids = ids, valid_result = valid_result }
end

-- Implementation notes: doc/implementation/c-ffi-expressions.md#enum-carrier-selection
local function render_enum_selection_source(context, declaration_type, question)
    local name = probe_identifier("d")
    local declaration = cdeclarator.render_declaration(
        declaration_type, name, {}, expand_probe_declaration_typedef)
    local lines = {}
    append_preamble(lines, context.header_preamble)
    lines[#lines + 1] = "extern " .. declaration .. ";"
    local matches, selected = { "0" }, { "0" }
    for _, id in ipairs(question.ids) do
        local match = "__builtin_types_compatible_p(__typeof__(&" .. name ..
            "), " .. cprobe.enum_carrier_names[id] .. " *)"
        matches[#matches + 1] = match
        selected[#selected + 1] = "(" .. id .. " * " .. match .. ")"
    end
    lines[#lines + 1] = "#if defined(__APPLE__)"
    lines[#lines + 1] =
        "__attribute__((used, aligned(1), section(\"__DATA,__titancprobe\")))"
    lines[#lines + 1] = "#else"
    lines[#lines + 1] =
        "__attribute__((used, aligned(1), section(\".titan.cprobe\")))"
    lines[#lines + 1] = "#endif"
    -- This array is a serialized object-section answer, never runtime storage.
    -- Clang ASan redzones would otherwise pad its exact twelve-byte payload,
    -- just as they would the public/source metadata sections.
    lines[#lines + 1] = "#if defined(__clang__)"
    lines[#lines + 1] = "__attribute__((no_sanitize(\"address\")))"
    lines[#lines + 1] = "#endif"
    lines[#lines + 1] = "static const unsigned char " ..
        probe_identifier("enum_result") .. "[] = {"
    lines[#lines + 1] = "    84, 73, 84, 69, 78, 85, 77, 0, 1, 12,"
    lines[#lines + 1] = "    " .. table.concat(matches, " + ") .. ","
    lines[#lines + 1] = "    " .. table.concat(selected, " + ")
    lines[#lines + 1] = "};"
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

local function decode_enum_selection_object(bytes, origin, question)
    local payload, err = staticmetadata.read_object_section(
        bytes, origin, ENUM_SECTION, ENUM_PAYLOAD_BYTES)
    if not payload then return nil, err end
    if #payload ~= ENUM_PAYLOAD_BYTES or
       payload:sub(1, #ENUM_PAYLOAD_PREFIX) ~= ENUM_PAYLOAD_PREFIX then
        return nil, "invalid enum selection payload magic, version or length"
    end
    local selection = { kind = "enum_carrier",
        match_count = payload:byte(11), carrier_id = payload:byte(12) }
    if not question.valid_result({ outcome = "success", selection = selection }) then
        return nil, "enum selection payload does not answer its eligible carrier question"
    end
    return selection
end

local function prepare_pointer_probe(module_context, source_type, target_type)
    local source_name =
        probe_identifier("s")
    local target_name =
        probe_identifier("t")
    local source_declaration =
        cdeclarator.render_declaration(source_type, source_name)
    local target_declaration =
        cdeclarator.render_declaration(target_type, target_name)
    local source_type_name = cdeclarator.render_type_name(source_type)
    local target_type_name = cdeclarator.render_type_name(target_type)
    return {
        source_name = source_name,
        target_name = target_name,
        rendered = {
            source_declaration = source_declaration,
            target_declaration = target_declaration,
            source_type = source_type_name,
            target_type = target_type_name,
        },
    }
end

local function render_prepared_pointer_source(module_context, prepared)
    local rendered = prepared.rendered
    local function_name =
        probe_identifier("f")
    local probe_declaration =
        cdeclarator.render_declaration(probe_function_type, function_name)

    local lines = {}
    append_preamble(lines, module_context.header_preamble)
    lines[#lines + 1] =
        "extern " .. rendered.source_declaration .. ";"
    lines[#lines + 1] = probe_declaration .. ";"
    lines[#lines + 1] = probe_declaration .. " {"
    lines[#lines + 1] = "    " .. rendered.target_declaration .. " ="
    lines[#lines + 1] =
        "        (" .. rendered.target_type .. ")" ..
        prepared.source_name .. ";"
    lines[#lines + 1] = "    (void)" .. prepared.target_name .. ";"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""

    return table.concat(lines, "\n")
end

local function render_pointer_source(module_context, source_type, target_type)
    local prepared = prepare_pointer_probe(
        module_context, source_type, target_type)
    return render_prepared_pointer_source(module_context, prepared),
        prepared.rendered
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
                                       target_type, is_null, literal)
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
    if literal then
        return nil, "((" .. target_name .. ")(" .. literal .. "))", {
            source_type = cdeclarator.render_type_name(source_type),
            source_declaration = "",
            target_type = target_name,
            null = false,
            literal = literal,
        }
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

local function prepare_operator_probe(module_context, trait)
    if type(trait) ~= "table"
       or (trait.kind ~= "unary" and trait.kind ~= "binary") then
        error("C operator probe requires a unary or binary trait", 2)
    elseif not operator_spellings[trait.cop] then
        error("unsupported C operator probe spelling '"
            .. tostring(trait.cop) .. "'", 2)
    end

    local lhs_name = probe_identifier("l")
    local rhs_name = probe_identifier("r")
    local lhs_decl, lhs_exp, lhs = render_operator_operand(
        "lhs", lhs_name,
        trait.lhs_source, trait.lhs_target, trait.lhs_null, trait.lhs_literal)
    local rhs_decl, rhs_exp, rhs
    if trait.kind == "binary" then
        rhs_decl, rhs_exp, rhs = render_operator_operand(
            "rhs", rhs_name,
            trait.rhs_source, trait.rhs_target, trait.rhs_null, trait.rhs_literal)
    end

    local expression
    if trait.kind == "unary" then
        expression = trait.cop .. lhs_exp
    else
        expression = lhs_exp .. " " .. trait.cop .. " " .. rhs_exp
    end

    return {
        lhs_declaration = lhs_decl,
        rhs_declaration = rhs_decl,
        rendered = {
            kind = trait.kind,
            cop = trait.cop,
            expression = expression,
            lhs = lhs,
            rhs = rhs,
            lhs_decay = trait.lhs_decay == true,
            rhs_decay = trait.rhs_decay == true,
            result_type = trait.result
                and types.tostring(trait.result) or "",
        },
    }
end

local function render_prepared_operator_source(module_context, prepared)
    local rendered = prepared.rendered
    local function_name = probe_identifier("o")
    local probe_declaration =
        cdeclarator.render_declaration(probe_function_type, function_name)
    local lines = {}
    append_preamble(lines, module_context.header_preamble)
    if prepared.lhs_declaration then
        lines[#lines + 1] = prepared.lhs_declaration
    end
    if prepared.rhs_declaration then
        lines[#lines + 1] = prepared.rhs_declaration
    end
    lines[#lines + 1] = probe_declaration .. ";"
    lines[#lines + 1] = probe_declaration .. " {"
    lines[#lines + 1] = "    (void)(" .. rendered.expression .. ");"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""

    return table.concat(lines, "\n")
end

local function render_operator_source(module_context, trait)
    local prepared = prepare_operator_probe(module_context, trait)
    return render_prepared_operator_source(module_context, prepared),
        prepared.rendered
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
        local function root_is_absent()
            local current, inspection_error = strategy:lstat(self.root)
            return current == nil and inspection_error == nil
        end
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
            -- Cancellation can arrive after an accepted rmdir removed the
            -- directory. A later uncancelled close retries this same owner.
            -- Confirm absence rather than classifying platform error text.
            if root_is_absent() then
                if #errors > 0 then return nil, table.concat(errors, "; ") end
                return true
            end
            errors[#errors + 1] = tostring(list_error)
        end
        local removed, err = strategy:rmdir(self.root)
        if not removed and not root_is_absent() then
            errors[#errors + 1] = tostring(err)
        end
        if #errors > 0 then return nil, table.concat(errors, "; ") end
        return true
    end

    return workspace
end

local function protected_tostring(value, fallback)
    local ok, rendered = pcall(tostring, value)
    if ok then return rendered end
    return fallback or "unprintable value"
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

local function finite_nonnegative_number(value)
    return type(value) == "number" and value == value and
        value >= 0 and value < math.huge
end

local function integral_exit_status(value)
    return type(value) == "number" and value == value and
        value >= 0 and value <= 255 and value % 1 == 0
end

local function malformed_runner_result(result, diagnostic, started)
    return {
        -- A validated started=true is useful process telemetry even when a
        -- later field makes the result unusable as semantic evidence. Verdict
        -- selection must use classification, never this lifecycle bit.
        started = started == true,
        ok = false,
        interrupted = false,
        classification = "infrastructure_failure",
        reason = "malformed_runner_result",
        diagnostic = diagnostic or result_diagnostic(result),
    }
end

local function consistent_alias(result, names, expected_type, subject)
    local value
    local present = false
    for _, name in ipairs(names) do
        local candidate = result[name]
        if candidate ~= nil then
            if type(candidate) ~= expected_type then
                return nil, false,
                    "command runner returned a non-" .. expected_type ..
                    " " .. name .. " field"
            elseif present and candidate ~= value then
                return nil, false,
                    "command runner returned contradictory " ..
                    subject .. " aliases"
            end
            value = candidate
            present = true
        end
    end
    return value, present
end

-- A compiler rejection is useful semantic evidence, but only when the runner
-- describes an ordinary completed child exit consistently. Be deliberately
-- strict here: permissive truthiness can turn a signal, missing executable, or
-- malformed bridge value into a persistent negative verdict.
local function normalize_runner_result(result, secondary)
    if result == nil then
        return {
            started = false,
            ok = false,
            interrupted = false,
            classification = "infrastructure_failure",
            reason = "spawn",
            diagnostic = tostring(
                secondary or "command runner did not start"),
        }
    elseif type(result) ~= "table" then
        return malformed_runner_result({},
            "command runner returned unsupported result type " .. type(result))
    end

    local started, has_started, alias_error = consistent_alias(
        result, { "started", "spawned" }, "boolean", "spawn")
    if alias_error then
        return malformed_runner_result(result, alias_error)
    end
    local ok, has_ok
    ok, has_ok, alias_error = consistent_alias(
        result, { "ok", "success" }, "boolean", "success")
    if alias_error then
        return malformed_runner_result(result, alias_error, started)
    end
    local status, has_status
    status, has_status, alias_error = consistent_alias(
        result, { "status", "exit_status", "code" },
        "number", "exit status")
    if alias_error then
        return malformed_runner_result(result, alias_error, started)
    end
    local interrupted = result.interrupted == true or
        result.why == "signal" or result.signal ~= nil
    local wall_ms = result.wall_ms

    if not has_started or not has_ok then
        return malformed_runner_result(result,
            "command runner omitted boolean started/ok fields", started)
    elseif result.interrupted ~= nil and
           type(result.interrupted) ~= "boolean" then
        return malformed_runner_result(result,
            "command runner returned a non-boolean interrupted field", started)
    elseif result.why ~= nil and result.why ~= "exit" and
           result.why ~= "signal" then
        return malformed_runner_result(result,
            "command runner returned an unknown termination reason", started)
    elseif result.signal ~= nil and
           (not integral_exit_status(result.signal) or
            result.signal == 0) then
        return malformed_runner_result(result,
            "command runner returned an invalid signal field", started)
    elseif result.signal ~= nil and result.why == "exit" then
        return malformed_runner_result(result,
            "command runner returned contradictory signal/why fields", started)
    elseif result.signal ~= nil and has_status and status ~= result.signal then
        return malformed_runner_result(result,
            "command runner returned contradictory signal/status fields", started)
    elseif result.interrupted == false and
           (result.signal ~= nil or result.why == "signal") then
        return malformed_runner_result(result,
            "command runner returned contradictory interruption fields", started)
    elseif result.interrupted == true and result.why == "exit" then
        return malformed_runner_result(result,
            "command runner returned contradictory interruption/why fields",
            started)
    elseif wall_ms ~= nil and not finite_nonnegative_number(wall_ms) then
        return malformed_runner_result(result,
            "command runner returned an invalid wall_ms value", started)
    elseif started == false then
        if ok or interrupted or (status ~= nil and status ~= 126 and
                                 status ~= 127) then
            return malformed_runner_result(result,
                "command runner returned contradictory spawn fields", started)
        end
        return {
            started = false,
            ok = false,
            interrupted = false,
            status = status,
            wall_ms = wall_ms,
            classification = "infrastructure_failure",
            reason = "spawn",
            diagnostic = result_diagnostic(result),
        }
    elseif interrupted then
        if ok then
            return malformed_runner_result(result,
                "command runner marked an interrupted child successful", started)
        end
        return {
            started = true,
            ok = false,
            interrupted = true,
            status = status,
            wall_ms = wall_ms,
            classification = "infrastructure_failure",
            reason = "interrupted",
            diagnostic = result_diagnostic(result),
        }
    elseif not has_status and started and not ok then
        -- A launched child without a completed status (the stock runner's
        -- capture, wait or batch-transport failure) is nonsemantic evidence;
        -- keep the runner's own explanation visible.
        local diagnostic = result_diagnostic(result)
        return malformed_runner_result(result, diagnostic ~= "" and diagnostic
            or "command runner returned no exit status for a started command",
            started)
    elseif not has_status or not integral_exit_status(status) then
        local malformed = malformed_runner_result(result,
            "command runner returned an invalid exit status", started)
        return malformed
    elseif status == 126 or status == 127 then
        if ok then
            return malformed_runner_result(result,
                "command runner marked an unavailable command successful",
                started)
        end
        return {
            started = false,
            ok = false,
            interrupted = false,
            status = status,
            wall_ms = wall_ms,
            classification = "infrastructure_failure",
            reason = "spawn",
            diagnostic = result_diagnostic(result),
        }
    elseif ok ~= (status == 0) then
        return malformed_runner_result(result,
            "command runner returned contradictory ok/status fields", started)
    end

    return {
        started = true,
        ok = ok,
        interrupted = false,
        status = status,
        wall_ms = wall_ms,
        classification = ok and "success" or "compiler_rejection",
        diagnostic = result_diagnostic(result),
    }
end

-- Custom runners are an embedding boundary and may return proxy tables with
-- arbitrary __index/__tostring behavior. Keep every normalization access under
-- protection so a malformed result remains retryable infrastructure rather
-- than escaping into the checker or becoming semantic evidence.
local function normalize_custom_runner_result(result, secondary)
    local ok, normalized = pcall(
        normalize_runner_result, result, secondary)
    if ok then return normalized end
    return malformed_runner_result({},
        "command runner result normalization raised an error: " ..
        protected_tostring(normalized, "unprintable normalization error"))
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

function Service:_create_workspace()
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
    elseif not platform.is_absolute(workspace.root) then
        return nil, "temporary workspace root path must be absolute"
    elseif workspace.root:find("\0", 1, true) then
        return nil, "temporary workspace root path contains a NUL byte"
    end
    return workspace
end

function Service:_ensure_workspace()
    if self.workspace then return self.workspace end
    local workspace, err = self:_create_workspace()
    if workspace then self.workspace = workspace end
    return workspace, err
end

function Service:_ensure_generated_workspace(header)
    self.generated_workspaces = self.generated_workspaces or {}
    local entry = self.generated_workspaces[header.digest]
    if not entry then
        local workspace, err = self:_create_workspace()
        if not workspace then return nil, err end
        entry = {
            workspace = workspace,
            owner = { io = self.io, source_ffi_header_bundle = workspace.root,
                source_ffi_header_directories = {} },
        }
        -- Own the directory before staging any dependency can suspend.
        self.generated_workspaces[header.digest] = entry
    end
    if not entry.header then
        local current, err = ffiheaders.materialize(entry.owner, header)
        if not current then return nil, err end
        entry.header = current
    end
    return entry.workspace, nil, entry.header
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

function Service:_compile_argv(source_path, object_path, object_result)
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
    if self.syntax_only and not object_result then
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
        compiler_classification = run and run.classification,
        classification = "infrastructure_failure",
        wall_ms = run and run.wall_ms,
        execution_digest = run and run.execution_digest,
    }
end

local function diagnostic_line_bounds(text, first, last)
    local line_start = first
    while line_start > 1 and text:byte(line_start - 1) ~= 10 do
        line_start = line_start - 1
    end
    local newline_after = text:find("\n", last + 1, true)
    local line_end = newline_after and newline_after - 1 or #text
    if text:byte(line_end) == 13 then line_end = line_end - 1 end
    return line_start, line_end
end

local function diagnostic_location_suffix(text, last, line_end)
    local cursor = last + 1
    if cursor > line_end or text:byte(cursor) ~= 58 then return false end
    cursor = cursor + 1
    local first_digit = cursor
    while cursor <= line_end do
        local byte = text:byte(cursor)
        if byte < 48 or byte > 57 then break end
        cursor = cursor + 1
    end
    if cursor == first_digit then return false end
    if cursor > line_end then return true end
    local terminator = text:byte(cursor)
    return terminator == 58 or terminator == 44
end

local function structured_diagnostic_path(text, first, last)
    local line_start, line_end = diagnostic_line_bounds(text, first, last)
    if first == line_start then
        if last == line_end or
           diagnostic_location_suffix(text, last, line_end) then
            return true
        end
        -- GCC emits a location-free context line immediately before ordinary
        -- function/body diagnostics. It is still a structured reference to
        -- the source file, and the exact phrases sharply constrain the POSIX
        -- prefix ambiguity instead of accepting arbitrary text after a colon.
        local suffix = text:sub(last + 1, line_end)
        return suffix == ": At top level:" or
            suffix:match("^: In function .+:$") ~= nil
    end
    local prefix = text:sub(line_start, first - 1)
    if not prefix:match("^%s*In file included from $") and
       not prefix:match("^%s+from $") then
        return false
    end
    return diagnostic_location_suffix(text, last, line_end)
end

-- Compiler diagnostics are semantic payload. Normalize only exact private
-- workspace paths plus structured source-foreign redirects; keep every other
-- byte, including coincidental basenames and real header paths, unchanged.
local function normalize_private_diagnostic(
        diagnostic, source_path, object_path, workspace_root, aliases)
    if type(diagnostic) ~= "string" then
        diagnostic = protected_tostring(
            diagnostic, "unprintable command runner diagnostic")
    end
    if diagnostic == "" then return "", true end
    local original = diagnostic
    local persistent_safe = true
    local mappings = {}
    local mapping_by_path = {}
    local function add_mapping(physical_path, public_path)
        if type(physical_path) ~= "string" or physical_path == "" or
           type(public_path) ~= "string" then
            return
        end
        local existing = mapping_by_path[physical_path]
        if existing then
            if existing.public_path ~= public_path then
                -- Two meanings for one exact byte span cannot be normalized
                -- deterministically. Mark it so any occurrence stays live;
                -- the uncovered-leaf scan below refuses publication only when
                -- that ambiguous private spelling is actually present.
                existing.conflicted = true
            end
            return
        end
        local mapping = {
            physical_path = physical_path,
            public_path = public_path,
            leaf = physical_path:match("([^/]+)$"),
        }
        mapping_by_path[physical_path] = mapping
        mappings[#mappings + 1] = mapping
    end
    add_mapping(source_path, "<titan-cprobe-source>")
    add_mapping(object_path, "<titan-cprobe-object>")
    for _, alias in ipairs(aliases or {}) do
        add_mapping(alias.physical_path, alias.public_path)
    end

    -- Classify every candidate against the original diagnostic, then splice
    -- once. Sequential replacement could otherwise make one public alias look
    -- like another private path and cascade into a different spelling.
    local candidates = {}
    for _, mapping in ipairs(mappings) do
        local cursor = 1
        while not mapping.conflicted do
            local first, last = original:find(
                mapping.physical_path, cursor, true)
            if not first then break end
            if structured_diagnostic_path(original, first, last) then
                candidates[#candidates + 1] = {
                    first = first,
                    last = last,
                    replacement = mapping.public_path,
                }
            else
                -- Whitespace and punctuation are valid POSIX pathname bytes;
                -- an unstructured occurrence may be a suffix of a different
                -- real path. Preserve it and keep the result memory-only.
                persistent_safe = false
            end
            cursor = first + 1
        end
    end
    table.sort(candidates, function(left, right)
        if left.first ~= right.first then return left.first < right.first end
        if left.last ~= right.last then return left.last > right.last end
        return left.replacement < right.replacement
    end)

    -- A physical path can be a prefix of another configured private path.
    -- Accept duplicate descriptions of one identical replacement, but do not
    -- guess between overlapping or differently mapped spans.
    local replacements = {}
    local index = 1
    while index <= #candidates do
        local group_end = candidates[index].last
        local next_index = index + 1
        while next_index <= #candidates and
              candidates[next_index].first <= group_end do
            if candidates[next_index].last > group_end then
                group_end = candidates[next_index].last
            end
            next_index = next_index + 1
        end
        local representative = candidates[index]
        local identical = true
        for candidate_index = index + 1, next_index - 1 do
            local candidate = candidates[candidate_index]
            if candidate.first ~= representative.first or
               candidate.last ~= representative.last or
               candidate.replacement ~= representative.replacement then
                identical = false
                break
            end
        end
        if identical then
            replacements[#replacements + 1] = representative
        else
            persistent_safe = false
        end
        index = next_index
    end

    local function covered_by_replacement(first, last)
        for _, replacement in ipairs(replacements) do
            if first >= replacement.first and last <= replacement.last then
                return true
            end
            if replacement.first > first then break end
        end
        return false
    end

    -- Some compiler wrappers report only basenames. Replacing those globally
    -- would corrupt unrelated diagnostic text, while retaining them in a
    -- persistent payload would leave a stale temporary filename. Inspect the
    -- original bytes so a stable public
    -- replacement which happens to share that basename is not rejected.
    for _, mapping in ipairs(mappings) do
        local leaf = mapping.leaf
        local cursor = 1
        while leaf and leaf ~= "" do
            local first, last = original:find(leaf, cursor, true)
            if not first then break end
            if not covered_by_replacement(first, last) then
                persistent_safe = false
                break
            end
            cursor = first + 1
        end
    end

    -- A wrapper can mention only the private workspace directory (for
    -- example, as a command context) without naming the generated source or
    -- object leaf. Do not rewrite such arbitrary prose, but never persist the
    -- invocation-specific root unless the occurrence is already inside an
    -- exact structured-path replacement above.
    local workspace_cursor = 1
    while type(workspace_root) == "string" and workspace_root ~= "" do
        local first, last = original:find(
            workspace_root, workspace_cursor, true)
        if not first then break end
        if not covered_by_replacement(first, last) then
            persistent_safe = false
            break
        end
        workspace_cursor = first + 1
    end

    if #replacements > 0 then
        local pieces = {}
        local cursor = 1
        for _, replacement in ipairs(replacements) do
            pieces[#pieces + 1] = original:sub(
                cursor, replacement.first - 1)
            pieces[#pieces + 1] = replacement.replacement
            cursor = replacement.last + 1
        end
        pieces[#pieces + 1] = original:sub(cursor)
        diagnostic = table.concat(pieces)
    end
    return diagnostic, persistent_safe
end

-- Prepare one compiler invocation: workspace (or staged generated-header
-- workspace), numbered source/object names, the written source, argv, the
-- command and verbose evidence. Returns the job, or nil and a completed
-- infrastructure run when preparation failed.
function Service:_prepare_execution(
        stage, source, key, probe_label, question, generated_header)
    if self.closed then
        return nil, infrastructure_run(stage, "closed", {
            diagnostic = "probe service is closed",
            source = source,
        })
    end
    local workspace, workspace_error, staged_header
    if generated_header then
        workspace, workspace_error, staged_header = self:_ensure_generated_workspace(generated_header)
    else
        workspace, workspace_error = self:_ensure_workspace()
    end
    if not workspace then
        return nil, infrastructure_run(stage, "workspace",
            { diagnostic = workspace_error, source = source })
    end
    local diagnostic_aliases
    if staged_header then
        local aliases = {}
        local seen = {}
        local function add(header)
            if seen[header] then return end
            seen[header] = true
            aliases[#aliases + 1] = { physical_path = header.filename, public_path = header.identity }
            for _, dependency in ipairs(header.dependencies) do add(dependency) end
        end
        add(staged_header)
        diagnostic_aliases = aliases
    end
    self.sequence = self.sequence + 1
    local label = stage == "baseline" and "baseline"
        or probe_label or "unsafe-object-pointer"
    local stem = ("%06d-%s"):format(self.sequence, label)
    local source_name = stem .. ".c"
    local object_name = stem .. ".o"
    local source_path = path_join(workspace.root, source_name)
    local object_path = path_join(workspace.root, object_name)
    local syntax_only = self.syntax_only and not question
    local reported_object_path = not syntax_only and object_path or nil

    local wrote, write_error =
        call_workspace(workspace, "write", source_name, source)
    if not wrote then
        -- A provider may have created a partial file before reporting failure.
        -- Best-effort removal here keeps per-probe cleanup independent of the
        -- later session close.
        call_workspace(workspace, "remove", source_name)
        return nil, infrastructure_run(stage, "workspace", {
            diagnostic = normalize_private_diagnostic(
                "could not write probe source: " .. write_error,
                source_path, object_path, workspace.root,
                diagnostic_aliases),
            source = source,
            source_path = source_path,
            object_path = reported_object_path,
        })
    end

    local argv = self:_compile_argv(source_path, object_path, question ~= nil)
    local command, command_error = command_string(argv)
    if not command then
        call_workspace(workspace, "remove", source_name)
        return nil, infrastructure_run(stage, "command", {
            diagnostic = normalize_private_diagnostic(
                "could not construct probe command: " .. command_error,
                source_path, object_path, workspace.root,
                diagnostic_aliases),
            argv = argv,
            source = source,
            source_path = source_path,
            object_path = reported_object_path,
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

    return {
        stage = stage,
        key = key,
        source = source,
        question = question,
        workspace = workspace,
        source_name = source_name,
        object_name = object_name,
        source_path = source_path,
        object_path = object_path,
        reported_object_path = reported_object_path,
        syntax_only = syntax_only,
        diagnostic_aliases = diagnostic_aliases,
        argv = argv,
        command = command,
        metadata = {
            stage = stage,
            key = key,
            argv = copy_array(argv),
            command = command,
            source = source,
            source_path = source_path,
            object_path = reported_object_path,
        },
    }
end

-- Normalize one prepared invocation's runner result, extract an enum
-- selection, normalize private diagnostic paths and remove its artifacts.
-- `call_ok` is false when a custom runner raised `raw_result`.
function Service:_finish_execution(job, call_ok, raw_result, secondary)
    local question, workspace = job.question, job.workspace
    local source_path, object_path = job.source_path, job.object_path
    local diagnostic_aliases = job.diagnostic_aliases
    local run
    if not call_ok then
        run = {
            started = false,
            ok = false,
            interrupted = false,
            classification = "infrastructure_failure",
            reason = "spawn",
            diagnostic = "command runner raised an error: " ..
                protected_tostring(
                    raw_result, "unprintable command runner error"),
        }
    elseif self.runner_is_strategy then
        run = normalize_runner_result(raw_result, secondary)
    else
        run = normalize_custom_runner_result(raw_result, secondary)
    end
    if question and run.classification == "success" then
        local attributes, read_error = self.io:stat(object_path)
        local bytes
        if attributes and attributes.kind == "file" and
           type(attributes.size) == "number" and attributes.size >= 0 and
           attributes.size <= MAX_SELECTION_OBJECT_BYTES then
            bytes, read_error = self.io:read_file(
                object_path, MAX_SELECTION_OBJECT_BYTES)
        else
            read_error = read_error or "missing, non-file or oversized enum query object"
        end
        local selection
        if type(bytes) == "string" and #bytes <= MAX_SELECTION_OBJECT_BYTES then
            selection, read_error = decode_enum_selection_object(
                bytes, object_path, question)
        end
        if selection then
            run.selection = selection
        else
            run.ok = false
            run.classification = "infrastructure_failure"
            run.reason = "result_extraction"
            run.diagnostic = "could not extract enum selection result: " ..
                tostring(read_error or "invalid or oversized object bytes")
        end
    end
    local diagnostic_persistent_safe
    run.diagnostic, diagnostic_persistent_safe = normalize_private_diagnostic(
        run.diagnostic, source_path, object_path, workspace.root,
        diagnostic_aliases)
    run.diagnostic_persistent_safe = diagnostic_persistent_safe
    run.execution_digest = job.key
    run.argv = copy_array(job.argv)
    run.command = job.command
    run.source = job.source
    run.source_path = source_path
    run.object_path = job.reported_object_path

    self:_emit({
        kind = "result",
        stage = job.stage,
        key = job.key,
        started = run.started,
        ok = run.ok,
        interrupted = run.interrupted,
        status = run.status,
        diagnostic = run.diagnostic,
    })

    local cleanup_errors = {}
    local source_removed, source_remove_error =
        call_workspace(workspace, "remove", job.source_name)
    if not source_removed then
        cleanup_errors[#cleanup_errors + 1] =
            job.source_name .. ": " .. source_remove_error
    end
    if not job.syntax_only then
        local object_removed, object_remove_error =
            call_workspace(workspace, "remove", job.object_name)
        if not object_removed then
            cleanup_errors[#cleanup_errors + 1] =
                job.object_name .. ": " .. object_remove_error
        end
    end
    self:_emit({
        kind = "cleanup",
        scope = job.stage .. " artifacts",
        ok = #cleanup_errors == 0,
        error = #cleanup_errors > 0 and table.concat(cleanup_errors, "; ")
            or nil,
    })
    if #cleanup_errors > 0 then
        run.ok = false
        run.selection = nil
        run.reason = "cleanup"
        run.classification = "infrastructure_failure"
        run.diagnostic = "could not clean probe artifacts: " ..
            table.concat(cleanup_errors, "; ")
        run.cleanup_error = true
        local normalized_diagnostic, cleanup_diagnostic_safe =
            normalize_private_diagnostic(
            run.diagnostic, source_path, object_path, workspace.root,
            diagnostic_aliases)
        run.diagnostic = normalized_diagnostic
        run.diagnostic_persistent_safe =
            run.diagnostic_persistent_safe ~= false and
            cleanup_diagnostic_safe
    end
    return run
end

function Service:_execute_source(
        stage, source, key, probe_label, question, generated_header)
    local job, failed = self:_prepare_execution(
        stage, source, key, probe_label, question, generated_header)
    if not job then return failed end
    local call_ok, raw_result, secondary
    if self.runner_is_strategy then
        raw_result, secondary = self.runner(copy_array(job.argv), job.metadata)
        call_ok = true
    else
        call_ok, raw_result, secondary =
            pcall(self.runner, copy_array(job.argv), job.metadata)
    end
    return self:_finish_execution(job, call_ok, raw_result, secondary)
end

-- All memory and disk reuse answers the same question: has this exact raw C
-- source already completed? Environment changes deliberately do not invalidate
-- either outcome. Removing the cache is the programmer's refresh mechanism.
-- A rejected header baseline is the exception on disk: it usually reflects one
-- invocation's missing -D/-I flags, so only this service process reuses it.
-- An adapter digest yields the same hexadecimal key as the Lua fallback.
function Service:_digest(source)
    local adapter = self.cache_adapter
    return sha256.hex_via(adapter and adapter.sha256_binary, source)
end

function Service:_cache_location(source)
    local key = self:_digest(source)
    return self.cache_directory and
        path_join(self.cache_directory, key .. ".result") or nil, key
end

function Service:_memory_result(key, question)
    local result = self.result_cache[key]
    if result and question and not question.valid_result(result) then
        self.result_cache[key], result = nil, nil
    end
    if result then return result, "service" end
    result = self.analysis_result_cache and self.analysis_result_cache[key]
    if result and question and not question.valid_result(result) then
        self.analysis_result_cache[key], result = nil, nil
    end
    if result then
        self.result_cache[key] = result
        return result, "analysis"
    end
end

function Service:_lookup_result(key, path, stage, module_name, question)
    local result, tier = self:_memory_result(key, question)
    if result then return result, tier, "memory" end
    if not path then return nil, nil, "disabled" end
    local attributes, stat_error = self.io:stat(path)
    local lookup = stat_error and "io_error" or "miss"
    if attributes then
        lookup = "invalid"
        if attributes.kind == "file" and
           type(attributes.size) == "number" and attributes.size >= 0 and
           attributes.size <= MAX_PERSISTENT_RECORD_BYTES then
            local encoded, read_error = self.io:read_file(
                path, MAX_PERSISTENT_RECORD_BYTES)
            result = encoded and cprobe_cache.decode(encoded) or nil
            if result and question and not question.valid_result(result) then
                result = nil
            end
            lookup = result and "hit" or read_error and "io_error" or "invalid"
        end
    end
    if self.persistent_cache_trace then
        pcall(self.persistent_cache_trace, stage, result ~= nil,
            key, path, module_name or "")
    end
    -- I/O can suspend while another request completes. Reuse that completed
    -- in-analysis result before installing what this disk read observed.
    local remembered, remembered_tier = self:_memory_result(key, question)
    if remembered then return remembered, remembered_tier, lookup end
    if result then
        self.result_cache[key] = result
        if self.analysis_result_cache then
            self.analysis_result_cache[key] = result
        end
        return result, "persistent", lookup
    end
    return nil, nil, lookup
end

local function semantic_run(result, source, tier, path)
    return {
        started = true,
        ok = result.outcome == "success",
        interrupted = false,
        status = result.exit_status,
        diagnostic = result.diagnostic,
        source = source,
        cached = true,
        cache_tier = tier,
        persistent_cached = tier == "persistent",
        cache_path = path,
        classification = result.outcome,
        selection = deep_copy(result.selection),
    }
end

function Service:_publish_result(key, path, run, question, stage)
    run.cache_path = path
    if run.classification ~= "success" and
       run.classification ~= "compiler_rejection" then
        return run, "not_applicable"
    end
    local remembered, tier = self:_memory_result(key, question)
    if remembered then
        return semantic_run(remembered, run.source, tier, path), "existing"
    end
    local result = {
        outcome = run.classification,
        exit_status = run.status,
        diagnostic = run.diagnostic or "",
        selection = deep_copy(run.selection),
    }
    self.result_cache[key] = result
    if self.analysis_result_cache then
        self.analysis_result_cache[key] = result
    end
    if not path then return run, "disabled" end
    if stage == "baseline" and run.classification == "compiler_rejection" then
        return run, "process_only"
    end
    if run.diagnostic_persistent_safe == false then
        return run, "unstable_diagnostic"
    end
    local encoded = cprobe_cache.encode(result)
    if not encoded then return run, "too_large" end
    if not ensure_directory(self.cache_directory, self.io) then
        return run, "failed"
    end
    -- The I/O strategy replaces through a private sibling and atomic rename.
    -- A failed cache write never changes the completed compiler result.
    local written = self.io:write_file(path, encoded)
    return run, written and "published" or "failed"
end

function Service:_trace_semantic(key, kind, context, run, publication)
    if not self.semantic_trace then return end
    local count = 1
    if key ~= "" then
        count = (self.semantic_requests[key] or 0) + 1
        self.semantic_requests[key] = count
    end
    pcall(self.semantic_trace, {
        event = "semantic_result",
        key = key,
        probe_kind = kind,
        header_identity = context and context.baseline_key or "",
        header_label = context and context.header_label or "",
        module = context and context.module_name or "",
        outcome = run.classification,
        cache_tier = run.cache_tier or "compiler",
        repeated = count > 1,
        publication = publication or "not_applicable",
    })
end

-- `batch_kind` is "single" for a synchronous launch and "speculative" for a
-- launch from a flushed speculative acceptance batch.
function Service:_trace_execution(key, kind, context, run, lookup, publication,
                                  batch_kind)
    if not self.execution_trace or not run.execution_digest then return end
    pcall(self.execution_trace, {
        event = "compiler_execution",
        key = key,
        probe_kind = kind,
        batch_kind = batch_kind or "single",
        header_identity = context and context.baseline_key or "",
        header_label = context and context.header_label or "",
        module = context and context.module_name or "",
        outcome = run.classification,
        started = run.started == true,
        persistent_lookup = lookup,
        publication = publication,
        wall_ms = run.wall_ms,
    })
end

-- One source, one lookup, one compiler invocation, one result. Candidate
-- misses first establish whether the shared header preamble itself compiles.
-- A `deferrable` acceptance candidate whose context batch is deferring is
-- recorded there after its lookup and baseline instead of being compiled. An
-- authoritative recheck first replays each occurrence's nonpublishable result,
-- including a failed nested baseline owned by that candidate, before lookup.
function Service:_run_source(stage, source, kind, context, question, deferrable,
                             nested_baseline)
    kind = kind or "raw_source"
    local path, key = self:_cache_location(source)
    if self.closed then
        local run = infrastructure_run(stage, "closed", {
            diagnostic = "probe service is closed", source = source,
        })
        run.key = key
        self:_trace_semantic(key, kind, context, run)
        return run
    end
    local batch = context and context.batch
    local pending = batch and not question and batch.pending_by_key[key]
    if pending then
        -- The synchronous path's repeated request is a memory hit.
        self:_emit({ kind = "cache", cache = stage, hit = true, key = key })
        return batch:_defer_duplicate(pending, kind, context)
    end
    -- A candidate owns its failed baseline gate as one replay outcome. Nested
    -- baseline calls neither consume nor record the independent history of
    -- explicit validate_baseline calls. Replaying the candidate therefore
    -- consumes its dependency too, before a later same-source cached verdict.
    -- Exhausted histories allow the synchronous path's ordinary lookup/retry.
    local answer = batch and not nested_baseline and batch:_answer(key)
    if answer then
        answer.key, answer.cache_path = key, path
        self:_trace_semantic(key, kind, context, answer, "not_applicable")
        return answer
    end
    local semantic, tier, lookup = self:_lookup_result(
        key, path, stage, context and context.module_name, question)
    self:_emit({ kind = "cache", cache = stage,
        hit = semantic ~= nil, key = key })
    if semantic then
        local run = semantic_run(semantic, source, tier, path)
        run.baseline_cached = true
        run.key = key
        self:_trace_semantic(key, kind, context, run)
        return run
    end
    local baseline
    if context and stage == "candidate" then
        baseline = context:validate_baseline(true)
        if baseline.status ~= "success" then
            local run = {
                classification = "infrastructure_failure",
                ok = false, stage = "baseline",
                reason = baseline.status == "rejected" and "baseline" or baseline.reason,
                status = baseline.exit_status,
                source = baseline.source,
                diagnostic = baseline.diagnostic,
                source_path = baseline.source_path,
                object_path = baseline.object_path,
                argv = baseline.argv, command = baseline.command,
                cleanup_error = baseline.cleanup_error,
                baseline_cached = baseline.cached,
                interrupted = baseline.interrupted,
                started = baseline.started,
            }
            run.key = key
            if batch then batch:_observe(key, run) end
            self:_trace_semantic(key, kind, context, run)
            return run
        end
    end
    if deferrable and batch and batch.deferring and not question then
        return batch:_defer(stage, source, key, path, kind, context, lookup,
            baseline and baseline.cached)
    end
    local execution = self:_execute_source(stage, source, key,
        kind:gsub("_", "-"), question, context and context.generated_header)
    if batch and not nested_baseline then batch:_observe(key, execution) end
    local run, publication = self:_publish_result(
        key, path, execution, question, stage)
    run.key = key
    if baseline then run.baseline_cached = baseline.cached end
    self:_trace_execution(key, kind, context, execution, lookup, publication)
    self:_trace_semantic(key, kind, context, run, publication)
    return run
end

-- A checker invocation's speculative acceptance batch. While `deferring`,
-- an eligible cache miss whose baseline passed is recorded with its already
-- rendered source, digest, cache path and immutable module context, and the
-- call receives an assumed success carrying the real key. `flush` compiles
-- the unique requests through the I/O strategy's `run_batch`, publishes only
-- real verdicts, and reports whether every request was accepted. Every
-- nonpublishable occurrence is kept in `outcomes`: a candidate's failed
-- baseline gate belongs to the candidate, while explicit baseline calls keep
-- their own history. An authoritative recheck receives these as `answers`
-- and consumes each once, in order, before any later cache entry can answer
-- that source. Completed verdicts never recompile; failed runs retry only
-- where the synchronous path would retry them.
-- Implementation notes: doc/implementation/c-ffi-expressions.md#speculative-batched-acceptance-probes
local ProbeBatch = {}
ProbeBatch.__index = ProbeBatch

local function publishable(run)
    return run.classification == "success" or
        run.classification == "compiler_rejection"
end

local function assumed_run(request)
    return {
        started = true, ok = true, interrupted = false, status = 0,
        classification = "success", diagnostic = "", deferred = true,
        source = request.source, key = request.key,
        cache_path = request.path, baseline_cached = request.baseline_cached,
    }
end

function ProbeBatch:_defer(stage, source, key, path, kind, context, lookup,
                           baseline_cached)
    local request = {
        stage = stage, source = source, key = key, path = path, kind = kind,
        context = context, lookup = lookup, baseline_cached = baseline_cached,
    }
    self.pending[#self.pending + 1] = request
    self.pending_by_key[key] = request
    self.requests[#self.requests + 1] = {
        request = request, kind = kind, context = context,
    }
    return assumed_run(request)
end

function ProbeBatch:_defer_duplicate(request, kind, context)
    self.requests[#self.requests + 1] = {
        request = request, kind = kind, context = context, duplicate = true,
    }
    return assumed_run(request)
end

function ProbeBatch:_observe(key, execution)
    if publishable(execution) then return end
    local outcomes = self.outcomes[key]
    if not outcomes then
        outcomes = {}
        self.outcomes[key] = outcomes
    end
    outcomes[#outcomes + 1] = execution
end

-- The next nonpublishable outcome owned by `key` (including its failed
-- baseline gate), in occurrence order, or nil once they are all consumed.
function ProbeBatch:_answer(key)
    local answers = self.answers and self.answers[key]
    local position = (self.answer_positions[key] or 0) + 1
    if not answers or position > #answers then return nil end
    self.answer_positions[key] = position
    return answers[position]
end

-- One cleanup boundary owns preparation, dispatch, finishing and
-- publication. A caught INT/TERM/HUP returned by `run_batch` is recorded on
-- the service at once, so `Service:close` delivers it once the workspaces
-- are gone (a resolver closes its header bundle before its service) even if
-- a later step raises. Every prepared probe is finished, removing its
-- artifacts, before any verdict is published. A raised error (a strategy
-- cancellation) first retries the finishing of every unfinished prepared
-- probe; a probe whose cleanup raises again stays in the service workspace
-- for its close. The original error object is then rethrown. A result
-- container that is not a table, or whose entry cannot be read, answers no
-- command, so that probe finishes as an infrastructure failure.
function ProbeBatch:flush()
    self.deferring = false
    local pending, requests = self.pending, self.requests
    self.pending, self.pending_by_key, self.requests = {}, {}, {}
    if #pending == 0 then return true end
    local service = self.service
    local prepared = {}
    local called, accepted, cancelled = pcall(function()
        local commands = {}
        for index, request in ipairs(pending) do
            local job, failed = service:_prepare_execution(request.stage,
                request.source, request.key, (request.kind:gsub("_", "-")), nil,
                request.context.generated_header)
            if job then
                commands[#commands + 1] = copy_array(job.argv)
                job.command_index = #commands
            end
            prepared[index] = job or { failed = failed }
        end
        local results, signal = {}, nil
        if #commands > 0 then
            -- A strategy method, called directly like the synchronous runner.
            results, signal = service.io:run_batch(commands, { jobs = service.jobs })
        end
        -- Never continue checking under a returning signal handler: the
        -- service's owner delivers this after closing it.
        if signal then service.cancelled_signal = signal end
        local malformed = type(results) ~= "table" and
            ("C probe batch runner returned a " .. type(results) ..
                " instead of a result table") or nil
        local executions = {}
        for index, job in ipairs(prepared) do
            local execution = job.failed
            if not execution then
                local result, unreadable = nil, malformed
                if not malformed then
                    local readable, value = pcall(function()
                        return results[job.command_index]
                    end)
                    if readable then result = value else
                        unreadable = "C probe batch result could not be read: " ..
                            protected_tostring(value, "unprintable error")
                    end
                end
                execution = service:_finish_execution(job, true, result, unreadable)
                job.finished = true
            end
            executions[index] = execution
        end
        local all_accepted = true
        for index, request in ipairs(pending) do
            local execution = executions[index]
            self:_observe(request.key, execution)
            local run, publication = service:_publish_result(
                request.key, request.path, execution)
            request.run, request.publication = run, publication
            service:_trace_execution(request.key, request.kind, request.context,
                execution, request.lookup, publication, "speculative")
            if execution.classification ~= "success" then all_accepted = false end
        end
        for _, entry in ipairs(requests) do
            local request = entry.request
            if entry.duplicate then
                service:_trace_semantic(request.key, entry.kind, entry.context, {
                    classification = request.run.classification,
                    cache_tier = publishable(request.run) and "service" or nil,
                })
            else
                service:_trace_semantic(request.key, entry.kind, entry.context,
                    request.run, request.publication)
            end
        end
        return all_accepted, signal
    end)
    if not called then
        for _, job in ipairs(prepared) do
            if not job.failed and not job.finished then
                local finished = pcall(service._finish_execution, service, job,
                    false, accepted)
                job.finished = finished
            end
        end
        error(accepted, 0)
    end
    if cancelled then
        error("C probe batch interrupted by signal " .. tostring(cancelled), 0)
    end
    return accepted
end

-- The stock native `run_batch` launches its own processes, so it stands in
-- for the strategy only while the strategy's resolved `run` is the stock one
-- too. A strategy that overrides `run`, directly or through its metatable,
-- keeps its synchronous runner calls unless it supplies its own `run_batch`.
function Service:batching()
    if not self.runner_is_strategy or self.jobs <= 1 then return false end
    local readable, run_batch, run = pcall(function()
        return self.io.run_batch, self.io.run
    end)
    if not readable or type(run_batch) ~= "function" then return false end
    return run_batch ~= default_io.run_batch or run == default_io.run
end

-- `answers` are a speculative pass's `outcomes`, for its authoritative recheck.
function Service:new_probe_batch(answers)
    return setmetatable({
        service = self,
        deferring = false,
        pending = {},
        pending_by_key = {},
        requests = {},
        outcomes = {},
        answers = answers,
        answer_positions = {},
    }, ProbeBatch)
end

local function probe_result(context, kind, stage, source, run, rejection)
    local status = run.classification == "success" and "success"
        or run.classification == "compiler_rejection" and "rejected"
        or "infrastructure_failure"
    local diagnostic = run.diagnostic or ""
    if diagnostic ~= "" and context.generated_header then
        local aliases, seen = {}, {}
        local resolve = require("titan-compiler.relocation").resolve
        local display_context = { relocation_roots = context.service.relocation_roots }
        local function add(header)
            if seen[header] then return end
            seen[header] = true
            local display = resolve(display_context, header.identity)
            if display ~= header.identity then
                aliases[#aliases + 1] = { physical_path = header.identity, public_path = display }
            end
            for _, dependency in ipairs(header.dependencies) do add(dependency) end
        end
        add(context.generated_header)
        if #aliases > 0 then
            -- Cache diagnostics retain stable identities. Render a public
            -- view for both fresh and replayed runs without mutating them.
            diagnostic = normalize_private_diagnostic(diagnostic, nil, nil, nil, aliases)
        end
    end
    local result = {
        kind = kind, status = status,
        ok = status == "success",
        accepted = status == "success",
        stage = run.stage or stage,
        reason = run.reason or (status == "rejected" and "compiler_rejection" or nil),
        key = run.key or "", baseline_key = context.baseline_key,
        cached = run.cached == true,
        persistent_cached = run.persistent_cached == true,
        cache_tier = run.cache_tier or "compiler",
        cache_path = run.cache_path,
        baseline_cached = run.baseline_cached,
        diagnostic = diagnostic,
        summary = first_diagnostic_line(diagnostic),
        source = run.source or source,
        command = run.command, argv = run.argv,
        source_path = run.source_path, object_path = run.object_path,
        exit_status = type(run.status) == "number" and run.status or nil,
        started = run.started == true,
        interrupted = run.interrupted == true,
        cleanup_error = run.cleanup_error == true,
        run_reason = run.reason,
        compiler_classification = run.classification,
        classification = run.classification,
        selection = deep_copy(run.selection),
    }
    if status == "infrastructure_failure" then result.accepted = nil end
    if status == "rejected" then
        result.message = "configured C compiler rejected " .. rejection
    elseif status == "infrastructure_failure" then
        if run.cleanup_error or run.reason == "workspace" or run.reason == "command" then
            result.message = "cannot validate C semantics because the probe infrastructure failed"
        elseif run.interrupted then
            result.message = "cannot validate C semantics because the configured compiler was interrupted"
        elseif run.started == false and run.source_path then
            result.message = "cannot validate C semantics because the configured compiler/toolchain could not be started"
        elseif run.stage == "baseline" and run.reason == "baseline" then
            result.message = "cannot validate C semantics because the foreign header baseline failed"
        else
            result.message = "cannot validate C semantics because the probe infrastructure failed"
        end
    end
    if result.message and result.summary ~= "" then
        result.message = result.message .. ": " .. result.summary
    end
    return result
end

-- Nested gates belong to the requesting candidate's replay outcome, not the
-- ordered history of direct baseline validations.
function ModuleContext:validate_baseline(nested)
    local source = self.baseline_source
    local run = self.service:_run_source(
        "baseline", source, "header_baseline", self, nil, nil, nested)
    return probe_result(self, "header_baseline", "baseline", source, run,
        "the final ordered foreign header context")
end

-- Acceptance-only kinds whose success the checker consumes only as
-- acceptance plus the source key. A declaration-compatibility caller opts in
-- per call (`{ deferrable = true }`); enum-range and enum-carrier questions
-- choose checker state and are never deferred.
local DEFERRABLE_KINDS = { c_operator = true, unsafe_object_pointer = true }

function ModuleContext:_candidate(kind, render_source, ...)
    return self:_run_candidate(kind, DEFERRABLE_KINDS[kind] == true,
        render_source, ...)
end

function ModuleContext:_run_candidate(kind, deferrable, render_source, ...)
    if self.service.closed then
        local run = { classification = "infrastructure_failure", stage = "service",
            reason = "closed", diagnostic = "probe service is closed" }
        self.service:_trace_semantic("", kind, self, run)
        return probe_result(self, kind, "service", "", run, "")
    end
    local ok, source, rendered = pcall(render_source, self, ...)
    if not ok then
        local diagnostic = tostring(source)
        local result = probe_result(self, kind, "source", "", {
            classification = "infrastructure_failure", reason = "render",
            diagnostic = diagnostic,
        }, "")
        if kind == "declaration_compatibility" then
            result.status, result.accepted = "rejected", false
            result.reason = "unrenderable_declaration"
            result.message = "cannot prove C declaration compatibility because "
                .. "the exact declaration pair cannot be rendered: "
                .. result.summary
        end
        self.service:_trace_semantic("", kind, self, {
            classification = "infrastructure_failure",
        })
        return result
    end
    local rejection = kind == "declaration_compatibility"
        and "the declaration compatibility candidate"
        or kind == "unsafe_object_pointer"
        and "conversion from '" .. rendered.source_type .. "' to '"
            .. rendered.target_type .. "'"
        or rendered.kind .. " operator expression '" .. rendered.expression .. "'"
    local run = self.service:_run_source(
        "candidate", source, kind, self, nil, deferrable)
    local result = probe_result(self, kind, "candidate", source, run, rejection)
    for name, value in pairs(rendered) do result[name] = value end
    if kind == "c_operator" then
        result.operator_kind = rendered.kind
        result.operator = rendered.cop
        result.rendered = rendered
        result.kind = kind
    end
    return result
end

function ModuleContext:validate_declaration_compatibility(
        left_type, right_type, left_declaration, right_declaration, options)
    return self:_run_candidate("declaration_compatibility",
        type(options) == "table" and options.deferrable == true,
        render_declaration_compatibility_source,
        left_type, right_type, left_declaration, right_declaration)
end

function ModuleContext:validate_declaration_compatibilities(candidates, options)
    local results = {}
    for index, candidate in ipairs(candidates) do
        results[index] = self:validate_declaration_compatibility(
            candidate.left_type, candidate.right_type,
            candidate.left_declaration, candidate.right_declaration, options)
    end
    return results
end

function ModuleContext:select_enum_carrier(declaration_type, eligible_ids)
    local ok, question = pcall(enum_selection_question, eligible_ids)
    local source
    if ok then
        ok, source = pcall(render_enum_selection_source,
            self, declaration_type, question)
    end
    if not ok then
        return probe_result(self, "enum_carrier", "source", "", {
            classification = "infrastructure_failure", reason = "render",
            diagnostic = tostring(source or question),
        }, "the enum carrier query")
    end
    local run = self.service:_run_source(
        "candidate", source, "enum_carrier", self, question)
    return probe_result(self, "enum_carrier", "candidate", source, run,
        "the enum carrier query")
end

function ModuleContext:probe_unsafe_object_pointer(source_type, target_type)
    return self:_candidate("unsafe_object_pointer", render_pointer_source,
        source_type, target_type)
end

function ModuleContext:probe_operator(trait)
    return self:_candidate("c_operator", render_operator_source, trait)
end

ModuleContext.unsafe_object_pointer = ModuleContext.probe_unsafe_object_pointer
ModuleContext.c_operator = ModuleContext.probe_operator

function Service:module_context(options)
    if self.closed then return nil, "probe service is closed" end
    options = options or {}
    if type(options) ~= "table" then
        return nil, "module probe context options must be a table"
    end
    local module_name = options.module or ""
    if type(module_name) ~= "string" or
       module_name:find("\0", 1, true) then
        return nil, "module probe context module must be a NUL-free string"
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
    cwd = absolute_path(cwd, process_cwd, self.io)
    local source_dir = options.source_dir or cwd
    if type(source_dir) ~= "string" or source_dir == "" then
        return nil, "module probe source_dir must be a nonempty string"
    end
    source_dir = absolute_path(source_dir, cwd, self.io)

    local raw_includes = options.includes or options.include_descriptors
        or options.headers or {}
    if type(raw_includes) ~= "table" then
        return nil, "module probe includes must be an ordered array"
    end
    local includes = {}
    for index = 1, #raw_includes do
        local include, err = normalize_include_descriptor(
            raw_includes[index], source_dir, cwd, self.io)
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

    local generated_header
    for _, include in ipairs(includes) do
        if include.generated_header then
            if generated_header and generated_header.digest ~= include.generated_header.digest then
                return nil, "a C probe context requires one generated module environment"
            end
            generated_header = include.generated_header
        end
    end
    -- One checker invocation shares its batch across every context it builds
    -- as foreign includes grow.
    local batch = options.batch
    if batch ~= nil and (getmetatable(batch) ~= ProbeBatch or batch.service ~= self) then
        return nil, "module probe batch must belong to this probe service"
    end
    local context = setmetatable({
        service = self,
        module_name = module_name,
        source_dir = source_dir,
        includes = includes,
        header_preamble = render_header_preamble(includes),
        generated_header = generated_header,
        header_label = trace_header_label(includes),
        batch = batch,
    }, ModuleContext)
    context.baseline_source = render_baseline_source(context)
    context.baseline_key = self:_digest(context.baseline_source)
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

function Service:_close_workspaces()
    if self.closed and not self.workspace and not next(self.generated_workspaces or {}) then
        if self.close_error then return nil, self.close_error end
        return true
    end
    self.closed = true
    local bundle_error
    for digest, entry in pairs(self.generated_workspaces or {}) do
        local closed, err = ffiheaders.close(entry.owner)
        if closed then closed, err = call_workspace(entry.workspace, "cleanup") end
        if closed then self.generated_workspaces[digest] = nil
        elseif not bundle_error then bundle_error = err end
    end
    if not self.workspace then
        if bundle_error then return nil, bundle_error end
        return true
    end

    local workspace = self.workspace
    local cleaned, cleanup_error =
        call_workspace(workspace, "cleanup")
    -- A strategy-owned cancellation raises out of call_workspace before these
    -- ownership fields are cleared. An uncancelled resolver cleanup can then
    -- retry the exact workspace. Ordinary custom-provider failures retain the
    -- historical terminal close_error behavior.
    self.workspace = nil
    local close_error = bundle_error
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

-- A probe batch that caught INT/TERM/HUP unwound its check to this service's
-- owner. Deliver that signal under the restored action only now, after the
-- workspaces and staged headers are removed. The driver closes a resolver's
-- C header bundle before its probe service.
function Service:close()
    local closed, close_error = self:_close_workspaces()
    local signal = self.cancelled_signal
    self.cancelled_signal = nil
    jobs.propagate(signal)
    return closed, close_error
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
        cache_adapter = self.cache_adapter,
        relocation_roots = self.relocation_roots,
        header_observations = self.header_observations,
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
        return nil, "include_dirs must be an explicit ordered array"
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
    local semantic_trace = option(
        options, toolchain, "semantic_trace", nil)
    if semantic_trace ~= nil and type(semantic_trace) ~= "function" then
        return nil, "semantic_trace must be a function"
    end
    local execution_trace = option(
        options, toolchain, "execution_trace", nil)
    if execution_trace ~= nil and type(execution_trace) ~= "function" then
        return nil, "execution_trace must be a function"
    end
    -- `-c ... -o private.o` is the portable non-linking baseline. A caller may
    -- opt into `-fsyntax-only` only after establishing that its configured
    -- compiler supports that extension.
    local syntax_only = option(options, toolchain, "syntax_only", false)
    if type(syntax_only) ~= "boolean" then
        return nil, "syntax_only must be a boolean"
    end
    -- The resolver's local native job cap. Greater than one lets a checker
    -- defer acceptance candidates into a batch run through the strategy's
    -- optional `run_batch`; the default keeps every probe synchronous.
    local jobs_cap = options.jobs
    if jobs_cap == nil then jobs_cap = 1 end
    if math.type(jobs_cap) ~= "integer" or jobs_cap < 1 then
        return nil, "jobs must be a positive integer"
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
        cache_directory = absolute_path(cache_directory, cwd, strategy)
        if cache_directory ~= "/" then
            cache_directory = cache_directory:gsub("/+$", "")
        end
    end

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

    local analysis_result_cache
    if process_analysis ~= nil then
        analysis_result_cache, err = cdriver.process_analysis_probe_cache(
            process_analysis, strategy)
        if not analysis_result_cache then return nil, err end
    end

    local service = setmetatable({
        io = strategy,
        cache_adapter = options.cache_adapter,
        relocation_roots = options.relocation_roots,
        header_observations = options.header_observations or cdriver.header_observation_index(options.header_inputs),
        process_trace = process_trace,
        process_analysis = process_analysis,
        persistent_cache_trace = persistent_cache_trace,
        semantic_trace = semantic_trace,
        execution_trace = execution_trace,
        compiler_argv = compiler_argv,
        compile_flags = compile_flags,
        language_mode = language_mode,
        language_flag = language_flag,
        cppflags = cppflags,
        cflags = cflags,
        include_dirs = include_dirs,
        profile = profile,
        profile_identity = profile_identity,
        syntax_only = syntax_only,
        jobs = jobs_cap,
        runner = runner,
        runner_is_strategy = runner_is_strategy,
        temp_provider = temp_provider,
        temp_provider_is_strategy = temp_provider_is_strategy,
        cache_directory = cache_directory,
        verbose = verbose,
        verbose_sink = verbose_sink,
        evidence = {},
        result_cache = {},
        analysis_result_cache = analysis_result_cache,
        semantic_requests = {},
        sequence = 0,
        workspace = nil,
        closed = false,
    }, Service)
    return service
end

function cprobe.normalize_include_descriptor(descriptor, options)
    options = options or {}
    local strategy = options.io or default_io
    local process_cwd, cwd_error = strategy:cwd()
    if not process_cwd then
        return nil, "cannot determine include cwd: " .. tostring(cwd_error)
    end
    local cwd = absolute_path(options.cwd or process_cwd, process_cwd, strategy)
    local source_dir = absolute_path(options.source_dir or cwd, cwd, strategy)
    return normalize_include_descriptor(descriptor, source_dir, cwd, strategy)
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
