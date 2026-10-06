-- Disposable, caret-specific source transformation and scalar declaration facts.
-- This module never checks source or installs the process-wide type registry.
local lpeg = require 'lpeglabel'
local lexer = require 'titan-compiler.lexer'
local location = require 'titan-compiler.location'
local types = require 'titan-compiler.types'
local util = require 'titan-compiler.util'
local documentation = require 'titan-compiler.documentation'
local completion = { VERSION = 1, TRANSFORM_VERSION = 1 }
local hole_name = '__titan_completion_hole'
local token_patterns = {}
for _, name in ipairs({'SPACE', 'COMMENT', 'STRINGLIT', 'NUMBER', 'ANYNAME'}) do
    token_patterns[#token_patterns + 1] = {name, (lexer[name] / 0) * lpeg.Cp()}
end
local symbols = {}
for name, pattern in pairs(lexer) do
    if name ~= 'SPACE' and name ~= 'COMMENT' and name ~= 'STRINGLIT'
       and name ~= 'NUMBER' and name ~= 'NAME' and name ~= 'ANYNAME' then
        symbols[#symbols + 1] = {name, (pattern / 0) * lpeg.Cp()}
    end
end
table.sort(symbols, function(a,b) return a[1] < b[1] end)
for _, item in ipairs(symbols) do token_patterns[#token_patterns + 1] = item end

local function tokens(text)
    local result, pos = {}, 1
    while pos <= #text do
        local matched
        for _, item in ipairs(token_patterns) do
            local finish = lpeg.match(item[2], text, pos)
            if finish then
                matched = {kind=item[1], text=text:sub(pos,finish-1), first=pos-1, last=finish-1}
                break
            end
        end
        if not matched then
            local char = text:sub(pos,pos)
            if char == '"' or char == "'" or text:sub(pos,pos+1) == '--'
                or text:sub(pos):match('^%[=*%[') then
                result[#result+1] = {kind='INCOMPLETE',text=text:sub(pos),first=pos-1,last=#text}
                break
            end
            matched = {kind='UNKNOWN',text=char,first=pos-1,last=pos}
        end
        result[#result+1] = matched
        pos = matched.last + 1
    end
    return result
end

local function import_transform(filename, text, caret, token, previous)
    if not previous or previous.text ~= 'import' then return nil end
    local quote = token.text:sub(1,1)
    if quote ~= '"' and quote ~= "'" then return nil end
    local first, last = token.first+1, token.last
    if token.text:sub(-1) == quote and #token.text > 1 then last = last-1 end
    if caret < first or caret > last then return nil end
    local prefix = text:sub(first+1,caret)
    if prefix:find('\\',1,true) or prefix:find('[\r\n]') then return nil end
    return {text=text,kind='import',prefix=prefix,replacement_start=first,replacement_end=last,
        request={filename=filename,kind='import',prefix=prefix,caret_byte=caret,
            start_byte=first,end_byte=last,analysis_start_byte=first,analysis_end_byte=last,
            transform_version=completion.TRANSFORM_VERSION}}
end

-- All offsets are zero-based UTF-8 byte boundaries; the host owns UTF-16 conversion.
-- Multiword C primitive replacement covers the complete written primitive leaf.
function completion.prepare(filename, text, caret)
    if type(filename)~='string' or type(text)~='string' or math.type(caret)~='integer'
       or caret<0 or caret>#text then return nil,'invalid completion input' end
    if caret<#text then
        local byte=text:byte(caret+1)
        if byte>=128 and byte<192 then return nil,'caret splits UTF-8' end
    end
    local all, significant = tokens(text), {}
    local first,last,active = caret,caret,nil
    local keyword_boundary
    for _, token in ipairs(all) do
        local inside = caret>=token.first and caret<token.last
        local at_unclosed_end = (token.kind=='INCOMPLETE' or token.kind=='COMMENT'
            and token.text:sub(-1)~='\n') and caret==token.last
        if inside or at_unclosed_end then
            if token.kind=='STRINGLIT' or token.kind=='INCOMPLETE' then
                local imported=import_transform(filename,text,caret,token,significant[#significant])
                if imported then return imported end
                return nil,'string or incomplete token'
            elseif token.kind=='COMMENT' then return nil,'comment'
            elseif token.kind=='NUMBER' then return nil,'number' end
        end
        if token.kind=='ANYNAME' and caret>=token.first and caret<=token.last then
            if caret==token.first and not completion.is_identifier(token.text) then
                keyword_boundary=token
            else
                first,last,active=token.first,token.last,token
            end
        end
        if token.last<=first and token.kind~='SPACE' and token.kind~='COMMENT' then
            significant[#significant+1]=token
        end
    end
    -- Recompute the prefix stream after identifying a mid-token replacement.
    significant={}
    for _,token in ipairs(all) do
        if token.last<=first and token.kind~='SPACE' and token.kind~='COMMENT' then
            significant[#significant+1]=token
        end
    end
    local previous=significant[#significant]
    if previous and previous.kind=='NUMBER' and previous.last==caret then
        return nil,'number'
    end
    local kind=previous and (previous.text=='.' and 'dot' or previous.text==':' and 'colon') or 'lexical'
    local index=#significant
    -- Primitive words form one grammar leaf, unlike pointer/qualifier syntax.
    local primitives={signed=true,unsigned=true,char=true,short=true,int=true,long=true,float=true,double=true,bool=true,void=true,lua_State=true}
    local leaf_first=first
    while index>0 and primitives[significant[index].text] do
        leaf_first=significant[index].first
        index=index-1
    end
    while index>0 and (significant[index].text=='*' or significant[index].text=='const'
            or significant[index].text=='(') do index=index-1 end
    local marker=significant[index]
    local raw_alias=marker and marker.text=='=' and significant[index-2]
        and significant[index-2].text=='type' and significant[index-3]
        and significant[index-3].text=='foreign'
    if marker and (marker.text=='foreign' or marker.text=='owned' or raw_alias) then
        kind='foreign'
        first=leaf_first
        -- Include words following the caret in an already written primitive.
        if active and primitives[active.text] then
            local found=false
            for _,token in ipairs(all) do
                if token==active then found=true
                elseif found and token.kind~='SPACE' then
                    if token.kind=='ANYNAME' and primitives[token.text] then last=token.last
                    else break end
                end
            end
        end
    end
    local declaration_token=active or keyword_boundary
    if previous and previous.text=='foreign' and declaration_token
       and (declaration_token.text=='import' or declaration_token.text=='type' or declaration_token.text=='function') then
        return nil,'foreign declaration keyword'
    end
    local dummy_name=hole_name
    while text:find(dummy_name,1,true) do dummy_name=dummy_name..'_' end
    -- A structural keyword starting at the caret belongs to the surrounding
    -- syntax. Keep it, with one analysis-only delimiter after the inserted name.
    local inserted=dummy_name..(keyword_boundary and ' ' or '')
    local transformed=text:sub(1,first)..inserted..text:sub(last+1)
    local line,col=location.get_line_number(transformed,first+1)
    local prefix=text:sub(first+1,caret)
    local line_starts={0}
    for offset in transformed:gmatch('()\n') do line_starts[#line_starts+1]=offset end
    local request={filename=filename,kind=kind,prefix=prefix,caret_byte=caret,
        line_starts=line_starts,source_length=#text,
        start_byte=first,end_byte=last,analysis_start_byte=first,analysis_end_byte=first+#inserted,
        line=line,col=col, name=dummy_name,transform_version=completion.TRANSFORM_VERSION}
    return {text=transformed,request=request,kind=kind,prefix=prefix,replacement_start=first,replacement_end=last}
end

-- Direct imports of the complete captured logical module, using the ordinary
-- parser's canonical shorthand and explicit-source interpretation. The host
-- calls this under its compiler permit and expands saved dependency closure.
function completion.dependencies(files)
    local parser = require 'titan-compiler.parser'
    local found = {}
    for _, file in ipairs(files) do
        local ast, parse_error = parser.parse(file.filename, file.contents)
        if not ast then return nil, parser.error_to_string(parse_error, file.filename) end
        for _, node in ipairs(ast) do
            if node._tag == 'Ast.TopLevelImport' then
                local item = found[node.modname]
                if not item then
                    item = { module_name = node.modname, source_required = false }
                    found[node.modname] = item
                end
                item.source_required = item.source_required or node.source_required == true
                    or node._source_import == true
            end
        end
    end
    local result = {}
    for _, item in pairs(found) do result[#result + 1] = item end
    table.sort(result, function(a, b) return util.bytewise_less(a.module_name, b.module_name) end)
    return result
end

function completion.original_byte(request, offset)
    if offset<=request.analysis_start_byte then return offset end
    if offset<request.analysis_end_byte then return request.start_byte end
    return offset-(request.analysis_end_byte-request.analysis_start_byte)+(request.end_byte-request.start_byte)
end

function completion.kind(typ, declaration)
    local tag=typ and typ._tag
    if declaration and (declaration._tag=='Type.Field' or declaration._tag=='Type.CField') then return 5 end
    if declaration and declaration._tag=='Type.Method' then return 2 end
    if tag=='Type.Module' or tag=='Type.CModule' then return 9 end
    if tag=='Type.Function' or tag=='Type.FunctionScheme' or tag=='Type.CFunction' then return 3 end
    if tag=='Type.Record' then return 22 end
    if tag=='Type.Union' then return 13 end
    if tag=='Type.Interface' then return 8 end
    if tag=='Type.Parameter' then return 25 end
    return 6
end

function completion.is_identifier(name)
    return lpeg.match(lexer.NAME * -lpeg.P(1), name) ~= nil
end

-- Mirror the ordinary checker's enum-use boundary, without native probes.
-- A pointer needs only a usable spelling; by-value enums require an existing
-- compiler validation or a target-int enumerator proof from exact C tokens.
function completion.foreign_available(typ, spelling_only, seen)
    if type(typ) ~= 'table' then return true end
    seen = seen or { full = {}, spelling = {} }
    local visited = spelling_only and seen.spelling or seen.full
    if visited[typ] then return true end
    visited[typ] = true
    local tag = typ._tag
    if spelling_only and tag == 'Type.CTypedef' then return true end
    local resolved = types.resolve_c_typedef(typ)
    if resolved and resolved._tag == 'Type.CInteger' and resolved._c_enum_identity then
        if resolved._c_enum_unspellable and tag ~= 'Type.CTypedef' then return false end
        return spelling_only or resolved._c_completion_int_enum == true or resolved._c_enum_validated == true
    elseif tag == 'Type.CTypedef' then
        return completion.foreign_available(typ.target, spelling_only, seen)
    elseif tag == 'Type.CPointer' then
        return completion.foreign_available(typ.pointee, true, seen)
    elseif tag == 'Type.CArray' then
        return completion.foreign_available(typ.elem, true, seen)
    elseif tag == 'Type.CFunction' then
        for _, param in ipairs(typ.params or {}) do
            if not completion.foreign_available(param, spelling_only, seen) then return false end
        end
        return completion.foreign_available(typ.ret, spelling_only, seen)
    end
    return true
end

function completion.fact(name, typ, declaration, domain, owner, mode, depth, local_override, spelling_only)
    if type(name)~='string' or (name~='...' and not name:match('^[%a_][%w_ ]*$'))
       or not typ or typ._tag=='Type.Invalid' then return nil end
    local rendered,detail=pcall(types.tostring,typ)
    if not rendered then return nil end
    local private=local_override
    if private==nil then private=declaration and declaration.islocal or false end
    domain,owner,mode=domain or 'value',owner or '',mode or ''
    return {name=name,kind=completion.kind(typ,declaration),detail=detail,
        lookup_domain=domain,lookup_key=domain..':'..name,type_key=owner..':'..domain..':'..name..':'..detail,
        scope_id=depth or 0,scope_depth=depth or 0,declaration_order=declaration and declaration._toplevel_order or 0,
        available=(domain~='foreign-value' and domain~='foreign-type') or completion.foreign_available(typ,spelling_only),islocal=private and true or false,visibility=private and 'private' or 'exported',
        owner_key=owner,access_mode=mode,
        documentation=(declaration and documentation.for_node(declaration) or typ and typ._documentation)
            and documentation.copy(declaration and documentation.for_node(declaration) or typ._documentation)}
end

local function callable(member,bound)
    local signature=bound and types.method_function_type(member)
        or types.Function(member.params,member.rettypes,false,member.varargtype,member.flexrettype)
    if member.scope and member.scope~=false then
        return types.FunctionScheme(member.scope,member.typeparams,signature)
    end
    return signature
end
completion.callable=callable

-- Saved indexing calls this while it owns a compatible declared interface.
-- Results contain no AST edges, type tables, or process-registry dependencies.
function completion.describe(entry)
    local module=entry.source_type or entry.type
    local result={version=completion.VERSION,module_name=module.name,candidates={},
        documentation=module._documentation and documentation.copy(module._documentation)}
    if entry.completion_facts then
        for _, row in ipairs(entry.completion_facts) do
            local copied={}
            for key,value in pairs(row) do copied[key]=key=="documentation" and documentation.copy(value) or value end
            result.candidates[#result.candidates+1]=copied
        end
        return result
    end
    local seen={}
    local function add(name,typ,decl,domain,owner,mode,private)
        local row=completion.fact(name,typ,decl,domain,owner,mode,0,private)
        if not row then return end
        local key=row.owner_key..'\0'..mode..'\0'..domain..'\0'..name
        if not seen[key] then result.candidates[#result.candidates+1]=row; seen[key]=true end
    end
    for _,members in ipairs({module.members or {},module.source_members or {}}) do
        for _,member in ipairs(members) do add(member.name,member.type,member,'value','module:'..module.name,'dot') end
    end
    for index,members in ipairs({module.type_members or {},module.source_type_members or {}}) do
        for name,typ in pairs(members) do
            add(name,typ,{_documentation=module._type_documentation and module._type_documentation[name]},'type','module:'..module.name,'type',index==2)
        end
    end
    local owners={}
    for name,owner in pairs(entry.declared_registry or entry.ast and entry.ast._declared_registry or {}) do owners[name]=owner end
    for _,members in ipairs({module.members or {},module.source_members or {}}) do
        for _,member in ipairs(members) do
            local owner=member.type
            if owner and (owner._tag=='Type.Record' or owner._tag=='Type.Union') then
                owners[owner.name]=owners[owner.name] or owner
            end
        end
    end
    for _,members in ipairs({module.type_members or {},module.source_type_members or {}}) do
        for _,owner in pairs(members) do
            if owner._tag=='Type.Interface' then owners[owner.name]=owners[owner.name] or owner end
        end
    end
    for name,owner in pairs(owners) do
        if name:match('^(.*)%.')==module.name then
            local key='nominal:'..name
            for _,field in ipairs(owner.fields or {}) do add(field.name,field.type,field,'value',key,'dot') end
            for method,member in pairs(owner.functions or {}) do
                if type(method)=='string' then add(method,callable(member),member,'value',key,'static') end
            end
            for method,member in pairs(owner.methods or {}) do
                if type(method)=='string' then add(method,callable(member,true),member,'value',key,'colon') end
            end
        end
    end
    local namespace=entry.ast and entry.ast._ffi_namespace
    if namespace then
        for name,member in pairs(namespace._type.members) do add(name,member.type,member,'foreign-value','ffi:'..module.name,'dot',true) end
        for name,typ in pairs(namespace._type.type_members) do add(name,typ,nil,'foreign-type','ffi:'..module.name,'type',true) end
    end
    table.sort(result.candidates,function(a,b)
        return util.bytewise_less(a.owner_key..'\0'..a.access_mode..'\0'..a.lookup_key,b.owner_key..'\0'..b.access_mode..'\0'..b.lookup_key)
    end)
    return result
end
return completion
