-- Completion observes the ordinary checker while its exact lexical environment
-- and receiver specialization are alive. It never makes a dummy declaration.
local core=require 'titan-compiler.checker.core'
local completion=require 'titan-compiler.completion'
local _ENV=core

function completion_matches(node,st)
    local request=st.completion_request
    if not request then return false end
    local loc=node._name_loc or node._method_loc or node.loc
    return loc and loc.filename==request.filename and loc.line==request.line
        and loc.col==request.col and (node.name==request.name or node.method==request.name)
end

-- Non-call statements are normally rejected before expression checking. Only
-- the marked syntax subtree may bypass that early exit in completion mode.
function completion_contains(root, st)
    if not st.completion_request then return false end
    local pending, seen = { root }, {}
    while #pending > 0 do
        local node = table.remove(pending)
        if type(node) == 'table' and not seen[node] then
            seen[node] = true
            if completion_matches(node, st) then return true end
            for key, value in pairs(node) do
                if type(value) == 'table' and (type(key) ~= 'string' or key:sub(1, 1) ~= '_') then
                    pending[#pending + 1] = value
                end
            end
        end
    end
    return false
end

local function begin(st,kind)
    local result={version=completion.VERSION,quality='complete',kind=kind,candidates={},scopes={}}
    local request=st.completion_request
    local function byte(loc,fallback)
        if not loc or loc.filename~=request.filename then return fallback end
        local start=request.line_starts and request.line_starts[loc.line]
        if not start then return fallback end
        return completion.original_byte(request,start+loc.col-1)
    end
    for depth=1,#st.blocks+#st.generic_type_scopes do
        local node=st.completion_blocks and st.completion_blocks[depth]
        result.scopes[#result.scopes+1]={id=depth,parent_id=depth>1 and depth-1 or nil,
            kind=depth==1 and 'module' or depth>#st.blocks and 'generic' or 'lexical',
            filename=request.filename,byte_start=byte(node and node.loc,0),
            byte_finish=byte(node and node._end_loc,request.source_length),caret_byte=request.caret_byte}
    end
    st.completion_result=result
    return result
end

local function add(result,name,typ,decl,domain,owner,mode,depth,private,spelling_only)
    local row=completion.fact(name,typ,decl,domain,owner,mode,depth,private,spelling_only)
    if row then
        if row.available then result.candidates[#result.candidates+1]=row
        else result.quality='partial' end
    end
end

local function type_declarations(result,st,errors,depth,current_module)
    local seen={}
    for index=current_module and 0 or #st.generic_type_scopes,1,-1 do
        for name,typ in pairs(st.generic_type_scopes[index]) do
            if not seen[name] then add(result,name,typ,typ._decl,'type','','',depth+index); seen[name]=true end
        end
    end
    for name,decl in pairs(st.type_aliases) do
        if not seen[name] then
            add(result,name,resolve_type_alias(decl,st,errors),decl,'type','module:'..st.modname,'type',1)
            seen[name]=true
        end
    end
    for name,decl in pairs(st.interface_declarations or {}) do
        if not seen[name] then add(result,name,decl._type,decl,'type','module:'..st.modname,'type',1); seen[name]=true end
    end
    for name,decl in pairs(st.blocks[1]) do
        local typ=decl._type
        if typ and (typ._tag=='Type.Record' or typ._tag=='Type.Union') and not seen[name] then
            add(result,name,typ,decl,'type','module:'..st.modname,'type',1); seen[name]=true
        end
    end
    if not current_module then
        for name,ctor in pairs({integer=types.Integer,float=types.Float,string=types.String,
            boolean=types.Boolean,value=types.Value}) do
            if not seen[name] then add(result,name,ctor(),nil,'type','','type',0) end
        end
    end
end

function completion_lexical(node,st,errors,kind,current_module)
    if not completion_matches(node,st) then return false end
    local result=begin(st,kind)
    if kind=='type' then type_declarations(result,st,errors,#st.blocks,current_module) end
    local seen={}
    local first=current_module and 1 or #st.blocks
    for depth=first,1,-1 do
        for name,decl in pairs(st.blocks[depth]) do
            local typ=decl._type
            if not seen[name] and not st:hidden_from_initializer(decl)
                and not name:find('$',1,true) and (current_module or completion.is_identifier(name))
                and (not current_module or not decl._builtin) then
                seen[name]=true
                local permitted=not (checker._foreign_function_depth>0)
                    or decl._tag=='Ast.Decl' or decl._tag=='Ast.TopLevelForeignFunc'
                    or decl._tag=='Checker.ForeignNamespace'
                    or decl._tag=='Ast.TopLevelImport' and decl._source_import
                if kind=='type' then
                    permitted=permitted and typ and (typ._tag=='Type.Module' or decl._current_module)
                end
                if permitted then add(result,name,typ,decl,'value','module:'..st.modname,'',depth) end
            end
        end
    end
    local vararg=not current_module and st:find_symbol('$vararg')
    if kind=='lexical' and vararg and vararg.funcdepth==#func_stack then
        add(result,'...',vararg.elem,nil,'vararg','','',#st.blocks)
    end
    if kind~='type' and not current_module and not seen.ffi and st.ffi_namespace then
        add(result,'ffi',st.ffi_namespace._type,st.ffi_namespace,'value','','',0)
    end
    if kind~='type' and checker._foreign_function_depth==0 then
        -- Aliases to static namespaces are legal in expressions only when the
        -- ordinary lexical value lookup did not bind the spelling.
        for name,decl in pairs(st.type_aliases) do
            if not seen[name] and (current_module or completion.is_identifier(name)) then
                local typ=resolve_type_alias(decl,st,errors)
                local owner=alias_namespace_type(typ,st)
                if owner then add(result,name,owner,decl,'value','module:'..st.modname,'',1) end
            end
        end
    end
    return true
end

local function module_candidates(result,st,mod,include_source,type_only)
    local values={mod.members or {}}
    if include_source then values[#values+1]=mod.source_members or {} end
    local seen={}
    for _,members in ipairs(values) do
        for name,member in pairs(members) do
            if type(name)=='string' and not seen[name] then
                seen[name]=true
                local typ=member.type
                local foreign_ok=type_only or checker._foreign_function_depth==0
                    or checker._foreign_function_reference({_tag='Ast.VarDot',_decl=member,
                        exp={_type=mod},name=name})
                if foreign_ok and (not type_only or typ._tag=='Type.Record' or typ._tag=='Type.Union') then
                    add(result,name,typ,member,type_only and 'type' or 'value','module:'..mod.name,type_only and 'type' or 'dot',0)
                end
            end
        end
    end
    local maps={mod.type_members or {}}
    if include_source then maps[#maps+1]=mod.source_type_members or {} end
    for index,members in ipairs(maps) do
        for name,typ in pairs(members) do
            if not seen[name] and (type_only or checker._foreign_function_depth==0 and alias_namespace_type(typ,st)) then
                add(result,name,typ,{_documentation=mod._type_documentation and mod._type_documentation[name]},'type','module:'..mod.name,type_only and 'type' or 'dot',0,index==2)
                seen[name]=true
            end
        end
    end
end

function completion_qualified_type(node,st,errors)
    if not completion_matches(node,st) then return false end
    local binding=st:find_symbol(node.module)
    if binding and binding._current_module then return completion_lexical(node,st,errors,'type',true) end
    local result=begin(st,'type')
    if binding and binding._type and binding._type._tag=='Type.Module' then
        module_candidates(result,st,binding._type,binding._source_import,true)
    else result.quality='unresolved' end
    return true
end

function completion_members(node,receiver,typ,st,errors,mode)
    if not completion_matches(node,st) then return false end
    local result=begin(st,mode)
    if not typ or typ._tag=='Type.Invalid' then result.quality='unresolved'; return true end
    if typ._tag=='Type.Option' and typ.base._tag=='Type.Nominal' then typ=typ.base end
    if typ._tag=='Type.Parameter' and typ.erased_constraint~=nil then typ=typ.erased_constraint end
    if mode=='dot' and typ._tag=='Type.Module' then
        local decl=receiver and receiver._tag=='Ast.ExpVar' and receiver.var._decl
        module_candidates(result,st,typ,decl and decl._source_import,false)
    elseif mode=='dot' and typ._tag=='Type.CModule' then
        for name,member in pairs(typ.members) do
            add(result,name,member.type,member,'foreign-value','ffi:'..st.modname,'dot',0,true)
        end
    elseif mode=='dot' and (typ._tag=='Type.Record' or typ._tag=='Type.Union') then
        for name,member in pairs(typ.functions) do
            if is_nominal_member_visible_from(st,member) then
                add(result,name,completion.callable(member),member,'value','nominal:'..typ.name,'static',0)
            end
        end
    elseif typ._tag=='Type.Nominal' and is_nominal_visible_from(st,typ.fqtn) then
        local owner=generic_applied_owner_view(typ,errors,node.loc)
        if owner then
            if mode=='colon' then
                for name,member in pairs(owner.methods or {}) do
                    if type(name)=='string' and is_nominal_member_visible_from(st,member) then
                        add(result,name,completion.callable(member,true),member,'value','nominal:'..typ.fqtn,'colon',0)
                    end
                end
            elseif owner._tag=='Type.Record' or owner._tag=='Type.Interface' then
                for _,field in ipairs(owner.fields) do
                    if is_nominal_member_visible_from(st,field) then
                        add(result,field.name,field.type,field,'value','nominal:'..typ.fqtn,'dot',0)
                    end
                end
            end
        else result.quality='unresolved' end
    elseif mode=='dot' and types.is_direct_c(typ) then
        local aggregate=c_resolve(typ)
        if aggregate._tag=='Type.CPointer' or aggregate._tag=='Type.COwned' then aggregate=c_resolve(aggregate.pointee) end
        if aggregate._tag=='Type.CStruct' or aggregate._tag=='Type.CUnion' then
            if aggregate._c_tag_scope=='file' and aggregate.tagname then
                local record=st:find_c_file_tag(aggregate.tagname,aggregate._tag=='Type.CStruct' and 'struct' or 'union')
                if record and record.canonical and record.canonical.complete then aggregate=record.canonical end
            end
            local names={}
            for _,field in ipairs(aggregate.fields or {}) do names[field.name]=true end
            for name in pairs(st.foreign_field_macro_cache or {}) do names[name]=true end
            for name in pairs(st.foreign_macro_definitions or {}) do names[name]=true end
            for name in pairs(names) do
                local field=c_field_decl(typ,name,st)
                if field then add(result,name,field.type,field,'foreign-value','c:'..types.tostring(aggregate),'dot',0,true) end
            end
        end
    end
    return true
end

function completion_foreign(node,st,errors,spelling_only)
    if not completion_matches(node,st) then return false end
    local result=begin(st,'foreign')
    local names=foreigntypes.surface_primitive_names()
    local seen={}
    for _,name in ipairs(names) do
        local typ=resolve_surface_c_type(name,st,errors,node.loc)
        add(result,name,typ,nil,'foreign-type','ffi:'..st.modname,'type',0,true,spelling_only)
        seen[name]=true
    end
    local namespace=st.ffi_namespace and st.ffi_namespace._type
    for name,typ in pairs(namespace and namespace.type_members or {}) do
        if not seen[name] then add(result,name,typ,nil,'foreign-type','ffi:'..st.modname,'type',0,true,spelling_only) end
    end
    return true
end

function completion_finish(st,ast,errors)
    if not st.completion_request then return end
    local captured=st.completion_result
    local result=captured or begin(st,st.completion_request.kind)
    if not captured then result.quality='unresolved' end
    -- The dummy itself is deliberately rejected. Other checker errors retain
    -- useful resolved context but require an incomplete response.
    for _,err in ipairs(errors) do
        if not tostring(err):find(st.completion_request.name,1,true)
           and not (st.completion_statement_errors and st.completion_statement_errors[err]) then
            result.quality='partial'
            break
        end
    end
    table.sort(result.candidates,function(a,b)
        if a.scope_depth~=b.scope_depth then return a.scope_depth>b.scope_depth end
        return util.bytewise_less(a.lookup_key,b.lookup_key)
    end)
    ast._completion=result
end
return core
