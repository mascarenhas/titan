-- LDoc-style source comments and detached documentation metadata. No AST,
-- registry, HTML rendering or executable tag configuration enters this contract.
local lpeg = require "lpeglabel"
local lexer = require "titan-compiler.lexer"
local documentation = {}
local comment = (lexer.COMMENT / 0) * lpeg.Cp()
local string_literal = (lexer.STRINGLIT / 0) * lpeg.Cp()

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function documentation.parse(text)
    local prose, tags, current = {}, {}, nil
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local name, value = line:match("^%s*@([%w_]+)(.*)$")
        if name then
            current = {name = name, value = trim(value)}
            tags[#tags + 1] = current
        elseif current then
            -- Keep multiline examples, indentation and paragraph breaks.
            current.value = current.value .. "\n" .. line
        else
            prose[#prose + 1] = line
        end
    end
    local description = trim(table.concat(prose, "\n"))
    local summary, rest = description:match("^(.-[%.%?])%s+(.*)$")
    if not summary then summary, rest = description:match("^([^\n]+)\n(.*)$") end
    summary, rest = summary or description, rest or ""
    for _, tag in ipairs(tags) do tag.value = (tag.value:gsub("%s+$", "")) end
    return {summary = summary, description = trim(rest), tags = tags}
end

function documentation.copy(doc)
    if type(doc) ~= "table" or getmetatable(doc) ~= nil
       or type(doc.summary) ~= "string" or type(doc.description) ~= "string"
       or type(doc.tags) ~= "table" or getmetatable(doc.tags) ~= nil then
        error("invalid documentation metadata", 2)
    end
    for key in pairs(doc) do
        if key ~= "summary" and key ~= "description" and key ~= "tags" then
            error("unexpected documentation field " .. tostring(key), 2)
        end
    end
    local count = 0
    for key in pairs(doc.tags) do
        if math.type(key) ~= "integer" or key < 1 then
            error("invalid documentation tag index", 2)
        end
        count = count + 1
    end
    local result = {summary = doc.summary, description = doc.description, tags = {}}
    for index = 1, count do
        local tag = doc.tags[index]
        if type(tag) ~= "table" or getmetatable(tag) ~= nil
           or type(tag.name) ~= "string" or not tag.name:match("^[%w_]+$")
           or type(tag.value) ~= "string" then
            error("invalid documentation tag", 2)
        end
        for key in pairs(tag) do
            if key ~= "name" and key ~= "value" then
                error("unexpected documentation tag field " .. tostring(key), 2)
            end
        end
        result.tags[index] = {name = tag.name, value = tag.value}
    end
    return result
end

function documentation.copy_map(map)
    if type(map) ~= "table" or getmetatable(map) ~= nil then
        error("invalid type documentation map", 2)
    end
    local result = {}
    for name, doc in pairs(map) do
        if type(name) ~= "string" then error("invalid type documentation name", 2) end
        result[name] = documentation.copy(doc)
    end
    return result
end

local function has_tag(doc, name)
    for _, tag in ipairs(doc.tags) do if tag.name == name then return true end end
    return false
end

-- Only lexical comment tokens count. Quoted/long strings are skipped by the
-- ordinary lexer, so a doc-looking string can never attach to a declaration.
function documentation.attach(tree, source)
    local groups, active, pos, significant = {}, nil, 1, false
    local function finish()
        if active then
            active.doc = documentation.parse(table.concat(active.lines, "\n"))
            groups[#groups + 1] = active
            active = nil
        end
    end
    while pos <= #source do
        local byte = source:sub(pos, pos)
        if source:sub(pos, pos + 1) == "--" then
            local last = assert(lpeg.match(comment, source, pos))
            local raw = source:sub(pos, last - 1)
            local equals, body = raw:match("^%-%-%[(=*)%[(.*)$")
            if equals then
                finish()
                body = body:sub(1, -(#equals + 3))
                if body:match("^%-%-") then
                    active = {first = pos, last = last, prefix = not significant,
                        lines = {body:gsub("^%-%-", "", 1)}}
                    finish()
                end
            else
                local starts = raw:match("^%-%-%-+")
                if starts then finish() end
                if starts or active then
                    if not active then active = {first = pos, prefix = not significant, lines = {}} end
                    local line = raw:gsub("[\r\n]+$", ""):gsub(starts and "^%-+ ?" or "^%-%- ?", "", 1)
                    active.lines[#active.lines + 1], active.last = line, last
                end
            end
            pos = last
        elseif byte:match("%s") then
            -- A physical blank line closes a line-comment block; an explicit
            -- `--` line remains part of it and carries a prose/tag paragraph.
            if byte == "\n" or byte == "\r" then finish() end
            pos = pos + 1
        else
            finish()
            significant = true
            local last = (byte == '"' or byte == "'" or byte == "[")
                and lpeg.match(string_literal, source, pos)
            pos = last or pos + 1
        end
    end
    finish()
    local by_position, lines = {}, {1}
    for offset in source:gmatch("()\n") do lines[#lines + 1] = offset + 1 end
    for _, group in ipairs(groups) do
        if group.prefix and has_tag(group.doc, "module") then
            tree._documentation = tree._documentation or group.doc
        else
            local next_pos = group.last
            while source:sub(next_pos, next_pos):match("%s") do next_pos = next_pos + 1 end
            by_position[next_pos] = group.doc
        end
    end
    local function attach(node)
        if not node.loc then return end
        local position = lines[node.loc.line] + node.loc.col - 1
        node._documentation = by_position[position]
        if node.decl then node.decl._documentation = node._documentation end
    end
    for _, node in ipairs(tree) do
        if not node._record_constructor and not node._union_constructor then
            attach(node)
            for _, member in ipairs(node.members or node.fields or node.variants or {}) do attach(member) end
        end
    end
    return tree
end

-- Copy documentation onto declaration identities before checking bodies. Types
-- of variables/functions and transparent alias targets are never decorated:
-- they may be shared by unrelated declarations.
local function inherit_links(target, parent)
    if not parent then return end
    local seen = {}
    for _, tag in ipairs(target.tags) do seen[tag.name .. "\0" .. tag.value] = true end
    for _, tag in ipairs(parent.tags) do
        local key = tag.name .. "\0" .. tag.value
        if (tag.name == "usage" or tag.name == "see") and not seen[key] then
            target.tags[#target.tags + 1] = {name=tag.name,value=tag.value}
            seen[key] = true
        end
    end
end

local function constructor_documentation(node)
    local owner = node._nominal_owner or node._owner_decl
    local owning = owner and owner._documentation
    local variant = node._union_variant
    local specific = variant and variant._documentation
    if not owning and not specific then return nil end
    local doc = {summary = specific and specific.summary or
        ("Create a new " .. node.class .. (variant and "." .. node.name or "") .. "."),
        description = specific and specific.description or owning and
            (owning.summary .. (owning.description ~= "" and "\n\n" .. owning.description or "")) or "",
        tags = {}}
    local fields = {}
    for _, field in ipairs(owner and owner._type and owner._type.fields or {}) do fields[field.name] = field end
    for _, parameter in ipairs(node.params or {}) do
        if parameter.name then
            local field = fields[parameter.name]
            local detail = field and field._documentation
            doc.tags[#doc.tags + 1] = {name="param", value=parameter.name .. " " ..
                (detail and detail.summary or "Initial value.")}
        end
    end
    doc.tags[#doc.tags + 1] = {name="return", value="A new " .. node.class .. " value."}
    inherit_links(doc, specific)
    inherit_links(doc, owning)
    return doc
end

function documentation.bind_declaration(node)
    if not node._documentation and (node._record_constructor or node._union_constructor) then
        node._documentation = constructor_documentation(node)
    end
    local tag, typ = node._tag, node._type
    if typ and (tag == "Ast.TopLevelRecord" or tag == "Ast.TopLevelUnion"
            or tag == "Ast.TopLevelInterface" or tag == "Ast.TopLevelMethod"
            or tag == "Ast.TopLevelStatic") then
        typ._documentation = node._documentation
    end
    local field_docs = {}
    if node._documentation then
        for _, tag in ipairs(node._documentation.tags) do
            if tag.name == "field" then
                local name, value = tag.value:match("^(%S+)%s+(.*)$")
                if name and not field_docs[name] then
                    field_docs[name] = documentation.parse(value)
                    inherit_links(field_docs[name], node._documentation)
                end
            end
        end
    end
    for _, member in ipairs(node.members or node.fields or node.variants or {}) do
        local doc = member._documentation or field_docs[member.name]
        local identity = member._decl or member._field
        if identity then identity._documentation = doc end
        member._documentation = doc
    end
end

function documentation.for_node(node)
    if type(node) ~= "table" then return nil end
    if node._documentation then return node._documentation end
    local decl = node._decl or node._method or node._field
    if decl then
        if decl._documentation then return decl._documentation end
        if decl._tag == "Ast.TopLevelImport" then return decl._type and decl._type._documentation end
        if decl._tag == "Checker.TypeMember" then
            local module = node._module_decl and node._module_decl._type
                or node.exp and node.exp._type
            local named = module and module._type_documentation
            return named and named[decl.name] or decl.type and decl.type._documentation
        end
    end
    if node._tag == "Ast.TopLevelImport" then return node._type and node._type._documentation end
    return nil
end

local function doc_literal(doc)
    local tags = {}
    for index, tag in ipairs(doc.tags) do
        tags[index] = "{name=" .. string.format("%q", tag.name) .. ",value=" .. string.format("%q", tag.value) .. "}"
    end
    return "{summary=" .. string.format("%q", doc.summary) .. ",description=" ..
        string.format("%q", doc.description) .. ",tags={" .. table.concat(tags, ",") .. "}}"
end
function documentation.serialize(doc)
    return doc_literal(documentation.copy(doc))
end
function documentation.serialize_map(map)
    map = documentation.copy_map(map)
    local names, result = {}, {}
    for name in pairs(map) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do result[#result + 1] = "[" .. string.format("%q", name) .. "]=" .. doc_literal(map[name]) end
    return "{" .. table.concat(result, ",") .. "}"
end
return documentation
