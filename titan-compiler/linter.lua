-- The `titanc --lint` style linter: a read-only pass over the typed ASTs of
-- successfully checked, analysis-only source modules. Only
-- `driver.lint_modules` loads this module, so ordinary compilation and
-- semantic clients never pay for it.
-- Implementation notes: doc/implementation/driver.md#lint-analysis-driverlint_modules
local lpeg = require "lpeglabel"
local lexer = require "titan-compiler.lexer"
local parser = require "titan-compiler.parser"
local types = require "titan-compiler.types"
local test_runner = require "titan-compiler.test_runner"

local linter = {}

-- The `--lint-format=json` document version.
linter.FORMAT_VERSION = 1

-- Every rule has a fixed base severity. A default rule is a `warning` that
-- starts enabled; an opt-in rule is a `hint` that starts off. The four
-- `candidate` rules may become defaults only with adjudicated corpus
-- evidence (doc/implementation/driver.md#lint-rules); an unpromoted
-- candidate ships opt-in like every other rule. Rules that failed the opt-in
-- corpus gate (boolean-option-condition, loop-string-concat,
-- unobserved-spawned-task, ipairs-unwrapped-hole-binder,
-- discarded-transfer-payload) are deferred, not shipped.
local RULES = {
    { id = "unused-local-binding", candidate = true, promoted = true },
    { id = "unused-lambda-param", candidate = true, promoted = true },
    { id = "prefer-record-call-shorthand", candidate = true, promoted = true },
    -- No adjudicated corpus diagnostics: unpromoted, so it ships opt-in.
    { id = "unmatched-public-test-signature", candidate = true, promoted = false },
    { id = "union-identity-equality" },
    { id = "stdlib-import-spelling" },
    { id = "prefer-const-local-field" },
    { id = "prefer-const-local" },
    { id = "boolean-option-silent-truthiness-local" },
    { id = "ephemeral-interface-map-key" },
    { id = "catch-reraise-resets-trace" },
    { id = "extra-do-block-around-try" },
    { id = "duplicate-record-literal-field" },
    { id = "gc-finalizable-non-collectable-arg" },
    { id = "gc-finalizable-captures-target" },
    { id = "race-any-unmanaged-losers" },
    { id = "header-dependent-public-c-export" },
    { id = "dso-imported-record-literal" },
    { id = "dso-closed-union-case" },
}

local RULE_BY_ID = {}
for _, rule in ipairs(RULES) do
    rule.default = rule.promoted == true
    rule.severity = rule.default and "warning" or "hint"
    RULE_BY_ID[rule.id] = rule
end

-- Ordered `{ id, severity, candidate }` descriptions for documentation and
-- tests.
function linter.rules()
    local list = {}
    for index, rule in ipairs(RULES) do
        list[index] = { id = rule.id, severity = rule.severity, candidate = rule.candidate == true }
    end
    return list
end

local DIRECTIVE_FLAGS = { enable = "--lint-enable", allow = "--lint-allow", deny = "--lint-deny" }

-- Apply ordered `{ op = "enable"|"allow"|"deny", value = ... }` directives,
-- strictly left to right, to the default rule modes. Returns a configuration
-- or `nil, message` for an unknown rule or directive.
function linter.configure(directives)
    if directives ~= nil and type(directives) ~= "table" then
        return nil, "lint rule directives must be a list"
    end
    local mode = {}
    for _, rule in ipairs(RULES) do
        mode[rule.id] = rule.default and "emit" or "off"
    end
    for _, directive in ipairs(directives or {}) do
        local op = type(directive) == "table" and directive.op
        local value = type(directive) == "table" and directive.value
        local flag = DIRECTIVE_FLAGS[op]
        if not flag or type(value) ~= "string" then
            return nil, "invalid lint rule directive"
        end
        local known = RULE_BY_ID[value] ~= nil
        if op == "enable" and value == "all" then
            for id, current in pairs(mode) do
                if current == "off" then mode[id] = "emit" end
            end
        elseif op == "deny" and (value == "warnings" or value == "hints") then
            local severity = value == "warnings" and "warning" or "hint"
            for _, rule in ipairs(RULES) do
                if rule.severity == severity and mode[rule.id] == "emit" then
                    mode[rule.id] = "deny"
                end
            end
        elseif not known then
            return nil, "unknown lint rule '" .. value .. "' (" .. flag .. "=" .. value .. ")"
        elseif op == "enable" then
            if mode[value] ~= "deny" then mode[value] = "emit" end
        elseif op == "allow" then
            mode[value] = "off"
        else
            mode[value] = "deny"
        end
    end
    return { mode = mode }
end

---------------------------------------------------------------------------
-- Shared AST and type helpers
---------------------------------------------------------------------------

-- Look through checker-inserted coercions and one-value adjustments.
local function unwrap(exp)
    while type(exp) == "table" do
        local tag = exp._tag
        if tag == "Ast.ExpCast" and exp._implicit_coercion then
            exp = exp.exp
        elseif tag == "Ast.ExpAdjust" then
            exp = exp.exp
        else
            break
        end
    end
    return exp
end

local function option_base(t)
    if type(t) == "table" and t._tag == "Type.Option" then return t.base end
    return t
end

local function registry_owner(t)
    t = option_base(t)
    if type(t) ~= "table" or t._tag ~= "Type.Nominal" then return nil end
    return types.registry[t.fqtn]
end

local function owner_module(fqtn)
    return type(fqtn) == "string" and fqtn:match("^(.*)%.[^.]+$") or nil
end

local function is_ast(node)
    return type(node) == "table" and type(node._tag) == "string" and node._tag:sub(1, 4) == "Ast."
end

-- The resolved module member `mod.name` that a callee expression names.
local function callee_member(call)
    if type(call) ~= "table" or call._tag ~= "Ast.ExpCall" or
       type(call.args) ~= "table" or call.args._tag ~= "Ast.ArgsFunc" then
        return nil
    end
    local callee = unwrap(call.exp)
    if not callee or callee._tag ~= "Ast.ExpVar" then return nil end
    local decl = callee.var and callee.var._decl
    if type(decl) == "table" and decl._tag == "Type.ModuleMember" then return decl end
    return nil
end

local function set_of(list)
    local set = {}
    for _, item in ipairs(list) do set[item] = true end
    return set
end

local SPAWN_FUNCTIONS = {
    ["titan.async"] = set_of({ "run", "run_with_cleanup" }),
    ["titan.thread"] = set_of({ "spawn", "spawn_one", "spawn_two", "spawn_three",
        "spawn_four", "spawn_five" }),
}
local RACE_FUNCTIONS = set_of({ "race_two", "race_three", "race_four", "race_five",
    "any_two", "any_three", "any_four", "any_five" })
-- Unions whose `==` is identity: every union of these two modules, the HTTP
-- mode unions, `reflect.Type`, and `websocket.MessageType`.
local IDENTITY_UNION_MODULES = set_of({ "titan.async", "titan.uv" })
local IDENTITY_UNIONS = set_of({ "titan.http.RedirectMode", "titan.http.CacheMode",
    "titan.http.CredentialsMode", "titan.http.RequestMode", "titan.reflect.Type",
    "titan.websocket.MessageType" })
local NON_COLLECTABLE = set_of({ "Type.Nil", "Type.Boolean", "Type.Integer", "Type.Float",
    "Type.String", "Type.CPointer", "Type.CInteger", "Type.CFloat" })
-- Checker decorations that own written expressions: the generic-for tuple
-- keeps written surplus expressions only in `_tuple_adjustment.exps`.
local ADJUSTMENT_FIELDS = { "_tuple_adjustment", "_result_adjustment", "_arg_adjustment",
    "_positional_adjustment" }
-- Syntax fields of type annotations that can hold further annotations.
local TYPE_FIELDS = { "subtype", "base", "basetype", "keystype", "valuestype", "argtypes",
    "rettypes", "varargtype", "flexrettype", "typeargs", "constraint" }

local function spawn_member(call)
    local decl = callee_member(call)
    if decl and SPAWN_FUNCTIONS[decl.modname] and SPAWN_FUNCTIONS[decl.modname][decl.name] then
        return decl
    end
    return nil
end

---------------------------------------------------------------------------
-- The walker
---------------------------------------------------------------------------

local function emit(w, rule, node, message, loc)
    local mode = w.mode[rule]
    if mode == "off" then return end
    loc = loc or node.loc
    -- An in-source `-- titan-lint: allow(...)` exception suppresses the
    -- diagnostic before it is reported, counted or denied.
    local allowed = w.allowed[loc.filename]
    local rules = allowed and allowed[loc.line]
    if rules and rules[rule] then return end
    local emitted = w.emitted[rule]
    if not emitted then
        emitted = {}
        w.emitted[rule] = emitted
    end
    if emitted[node] then return end
    emitted[node] = true
    w.sink[#w.sink + 1] = {
        file = loc.filename, line = loc.line, col = loc.col,
        severity = RULE_BY_ID[rule].severity, rule = rule, message = message,
        denied = mode == "deny",
    }
end

-- Each visited node advances `seq`; `prefix[seq]` counts the hazards seen so
-- far: every written `_` reference (an `Ast.VarName`, including assignment
-- targets and closure captures, and a type annotation naming `_` or `_.T`)
-- and every name read in a statement the checker left unchecked. A rename candidate records
-- the `seq` at which its binding becomes visible and the `seq` at which its
-- lexical scope closes; the difference of the two prefix counts tells, in
-- constant time, whether its interval holds any hazard. One traversal builds
-- the index for the whole module.
local function tick(w)
    local seq = w.seq + 1
    w.seq = seq
    w.prefix[seq] = w.hazards
end

local function note_hazard(w)
    w.hazards = w.hazards + 1
    w.prefix[w.seq] = w.hazards
end

local function open_scope(w)
    w.scopes[#w.scopes + 1] = {}
end

local function close_scope(w)
    local scope = table.remove(w.scopes)
    local exit_count = w.prefix[w.seq]
    for _, candidate in ipairs(scope) do
        if exit_count - w.prefix[candidate.ready] == 0 then
            emit(w, candidate.rule, candidate.decl, candidate.message)
        end
    end
end

-- A checked binding nothing reads or writes. `_used` covers reads and
-- captures and `_assigned` covers writes (a write-only scalar has no
-- `_used`); a binding without `_type` was never checked, so its use flags
-- are no evidence.
local function unused_binding(decl)
    return type(decl) == "table" and decl._tag == "Ast.Decl" and decl._type ~= nil and
        decl._used == nil and not decl._assigned and type(decl.name) == "string" and
        decl.name ~= "_" and not decl._catch_implicit and not decl._ignore
end

-- A local renamed to `_` would shadow a module-level `_` in its scope, and
-- the checker keeps no syntax for some type references to it (cast and test
-- targets), so a module declaring `_` gets no rename hints at all.
local function rename_candidate(w, rule, decl, message)
    if w.module_underscore then return end
    local scope = w.scopes[#w.scopes]
    scope[#scope + 1] = { rule = rule, decl = decl, ready = w.seq, message = message }
end

local visit

-- Written type annotations: `_.T` and a type named `_` are lexical uses of
-- `_`. Annotation nodes may be shared, so each is visited once.
local function visit_type(w, node)
    if type(node) ~= "table" then return end
    if node._tag == nil then
        for _, item in ipairs(node) do visit_type(w, item) end
        return
    end
    if node._tag:sub(1, 8) ~= "Ast.Type" or w.seen[node] then return end
    w.seen[node] = true
    tick(w)
    if (node._tag == "Ast.TypeQualName" and node.module == "_") or
       (node._tag == "Ast.TypeName" and node.name == "_") then
        note_hazard(w)
    end
    for _, field in ipairs(TYPE_FIELDS) do visit_type(w, node[field]) end
end

local function visit_ast_list(w, list)
    if type(list) ~= "table" then return end
    for _, item in ipairs(list) do
        if is_ast(item) then visit(w, item) end
    end
end

local function visit_decl(w, decl)
    if type(decl) ~= "table" or w.seen[decl] then return end
    w.seen[decl] = true
    tick(w)
    visit_type(w, decl.type)
end

-- The checker never reaches a statement after one that always returns: such
-- a statement has no `_always_returns`, and the names it reads set no use
-- flags. Every name read inside one is therefore a hazard.
local function visit_stats(w, block)
    for _, stat in ipairs(block.stats) do
        local unchecked = stat._always_returns == nil
        if unchecked then w.unchecked = w.unchecked + 1 end
        visit(w, stat)
        if unchecked then w.unchecked = w.unchecked - 1 end
    end
end

-- A `do ... catch ... end` that is the only statement of a block whose owner
-- could carry the `catch` itself.
local function check_owner_block(w, block)
    if type(block) == "table" and block._tag == "Ast.StatBlock" and not block._defer_tail and
       #block.stats == 1 then
        local stat = block.stats[1]
        if stat._tag == "Ast.StatTry" and not stat._defer_tail and stat.catchblock and
           stat._structure_loc then
            emit(w, "extra-do-block-around-try", stat,
                "unnecessary 'do ... end' around 'catch'; attach the 'catch' directly to " ..
                "the enclosing block (keep the 'do' only if it deliberately narrows the protected region)",
                stat._structure_loc)
        end
    end
end

local function record_field_write(w, var)
    local decl = type(var) == "table" and var._decl
    if var and var._tag == "Ast.VarDot" and type(decl) == "table" and decl._tag == "Type.Field" then
        w.field_writes[tostring(decl.fqtn) .. "\0" .. tostring(decl.name)] = true
    end
end

local function check_decl_rules(w, node)
    local decls, exps = node.decls, node.exps
    if #decls == 1 and #exps > 0 then
        local decl = decls[1]
        -- The checker supplies `nil` for an omitted initializer at the
        -- declaration's own location; there is no written value to keep.
        local initializer = unwrap(exps[1])
        local written = not (#exps == 1 and initializer and initializer._tag == "Ast.ExpNil" and
            initializer.loc == decl.loc)
        if written and not decl.isconst and decl._type ~= nil and decl._assigned == nil and
           not decl._forcontrol and decl._used == true and decl.name ~= "_" and not decl._ignore and
           not types.is_c_aggregate(decl._type) then
            emit(w, "prefer-const-local", decl,
                "local '" .. decl.name .. "' is never reassigned; consider 'const " .. decl.name ..
                " = ...' (optional: constant locals are a style choice, not a requirement)")
        end
    end
    local adjusted = node._result_adjustment and node._result_adjustment.fixed
    for index, decl in ipairs(decls) do
        local init = adjusted and adjusted[index]
        if decl.type == nil and not decl.option and type(init) == "table" and
           init._tag == "Ast.ExpCast" and init._implicit_coercion and
           init._adjustment and init._adjustment.coercion and
           init._adjustment.coercion.op == "truthiness" then
            local source = init.exp and init.exp._type
            if source and source._tag == "Type.Option" and source.base and
               source.base._tag == "Type.Boolean" and init._type and
               init._type._tag == "Type.Boolean" then
                emit(w, "boolean-option-silent-truthiness-local", decl,
                    "unannotated local '" .. decl.name .. "' turns 'boolean?' into 'boolean' by " ..
                    "truthiness, so nil silently becomes false; write 'local " .. decl.name ..
                    "? = ...' to keep nil, or annotate ': boolean' if that is intended")
            end
        end
    end
end

-- A call that allocates a fresh variant of a union whose `==` is identity:
-- comparing it with anything is always false (`~=` always true).
local function fresh_identity_variant(exp)
    if type(exp) ~= "table" or exp._tag ~= "Ast.ExpCall" then return nil end
    local constructor = exp._nominal_constructor
    local owner = type(constructor) == "table" and constructor.kind == "union" and
        constructor.owner
    if not owner or owner._tag ~= "Type.Union" or type(owner.name) ~= "string" then return nil end
    if IDENTITY_UNION_MODULES[owner_module(owner.name)] or IDENTITY_UNIONS[owner.name] then
        return owner.name
    end
    return nil
end

local function check_binop(w, node)
    if node.op ~= "==" and node.op ~= "~=" then return end
    local lhs, rhs = unwrap(node.lhs), unwrap(node.rhs)
    if type(lhs) ~= "table" or type(rhs) ~= "table" then return end
    local fqtn = fresh_identity_variant(lhs) or fresh_identity_variant(rhs)
    if fqtn then
        emit(w, "union-identity-equality", node,
            "'" .. node.op .. "' compares a freshly constructed '" .. fqtn .. "' variant by " ..
            "identity, so it is always " .. (node.op == "==" and "false" or "true") ..
            "; inspect the union with 'case' (or compare with a stored constant such as websocket.TEXT)")
    end
end

local function check_call(w, node)
    -- prefer-record-call-shorthand
    local callee = node.exp
    if #(node.typeargs or {}) == 0 and not node._shorthand_record_call and
       type(callee) == "table" and callee._tag == "Ast.ExpVar" and
       callee.var._tag == "Ast.VarDot" and callee.var.name == "new" then
        local namespace = callee.var.exp
        local decl = callee.var._decl
        if namespace and namespace._type and namespace._type._tag == "Type.Record" and
           type(decl) == "table" and decl._tag == "Type.StaticMethod" then
            emit(w, "prefer-record-call-shorthand", node,
                "call the record directly: delete '.new' and keep the rest of the call, including " ..
                "any owner type arguments (the record-call shorthand selects the same 'new')")
        end
    end

    local member = callee_member(node)
    if not member then return end
    local args = node.args.args
    if member.modname == "titan.gc" and member.name == "finalizable" then
        local target = unwrap(args[1])
        local t = target and target._type
        if t and NON_COLLECTABLE[t._tag] then
            emit(w, "gc-finalizable-non-collectable-arg", node,
                "gc.finalizable needs a Map or full userdata at run time; a '" .. types.tostring(t) ..
                "' value always raises (tests asserting that rejection are the exception)")
        end
        local callback = unwrap(args[2])
        local decl = target and target._tag == "Ast.ExpVar" and target.var._tag == "Ast.VarName" and
            target.var._decl
        if decl and decl._tag == "Ast.Decl" and callback and callback._tag == "Ast.ExpFunction" then
            for _, captured in ipairs(callback._captures or {}) do
                if captured == decl then
                    emit(w, "gc-finalizable-captures-target", node,
                        "the finalizer captures its own target '" .. decl.name .. "', which can keep " ..
                        "it reachable through the registered callback; use the callback parameter instead")
                    break
                end
            end
        end
    elseif member.modname == "titan.async" and RACE_FUNCTIONS[member.name] then
        for _, arg in ipairs(args) do
            local inner = spawn_member(unwrap(arg))
            if inner and inner.modname == "titan.async" then
                emit(w, "race-any-unmanaged-losers", node,
                    "inline '" .. inner.modname .. "." .. inner.name .. "' inside 'async." .. member.name ..
                    "' drops the Task handle, so a losing Task can never be cancelled or joined; " ..
                    "bind each Task to a local first (a self-terminating arm may be intentional)")
                break
            end
        end
    end
end

local function check_bracket(w, node)
    local map = option_base(node.exp1 and node.exp1._type)
    local key = node.exp2
    if not map or map._tag ~= "Type.Map" or type(key) ~= "table" or key._tag ~= "Ast.ExpCast" or
       not key._implicit_coercion then
        return
    end
    local interface = registry_owner(map.keys)
    local adjustment = key._adjustment
    if interface and interface._tag == "Type.Interface" and adjustment and adjustment.coercion and
       adjustment.coercion.op == "interface_wrapper" then
        local source = key.exp and key.exp._type
        emit(w, "ephemeral-interface-map-key", node,
            "Map keyed by Interface '" .. interface.name .. "' is indexed with a '" ..
            (source and types.tostring(source) or "concrete") .. "' value, which builds a fresh " ..
            "wrapper (a new key) on every evaluation; bind 'local key: " .. interface.name ..
            " = ...' once and reuse it")
    end
end

-- The owner of a nominal is a separately compiled provider when this analysis
-- selected it from a compiled module (not source) and the current module does
-- not import it as `.titan` source. A test module (one with discovered
-- tests) is rebuilt from source by every `titanc --test` run, so no provider
-- is replaced underneath it.
local function binary_owner(w, fqtn)
    if w.test_module then return nil end
    local owner_mod = owner_module(fqtn)
    if not owner_mod or owner_mod == w.modname or w.source_imports[owner_mod] then return nil end
    local kind = w.provider_kind(owner_mod)
    if kind == nil or kind == "source" then return nil end
    return owner_mod
end

local function check_initlist(w, node)
    local owner = registry_owner(node._type)
    if not owner or owner._tag ~= "Type.Record" then return end
    local names = {}
    for _, field in ipairs(node.fields) do
        local name = field.name
        if type(name) == "string" then
            if names[name] then
                emit(w, "duplicate-record-literal-field", field,
                    "duplicate field '" .. name .. "' in a record literal: every entry is evaluated " ..
                    "and the last one wins; remove the earlier entry if its expression has no needed effect")
            end
            names[name] = true
        end
    end
    local owner_mod = binary_owner(w, owner.name)
    if owner_mod then
        emit(w, "dso-imported-record-literal", node,
            "raw record literal for '" .. owner.name .. "' from the compiled provider '" .. owner_mod ..
            "' fixes that record's field layout at this use site; if the provider is replaced " ..
            "independently, prefer its constructor call")
    end
end

local CHILD_FIELDS = {
    ["Ast.StatCall"] = { "callexp" },
    ["Ast.StatReturn"] = { "exps" },
    ["Ast.VarBracket"] = { "exp1", "exp2" },
    ["Ast.VarDot"] = { "exp" },
    ["Ast.ExpInitList"] = { "fields" },
    ["Ast.Field"] = { "name", "exp" },
    ["Ast.ExpCall"] = { "exp", "args" },
    ["Ast.ArgsFunc"] = { "args" },
    ["Ast.ArgsMethod"] = { "args" },
    ["Ast.ArgsNamedFunc"] = { "fields" },
    ["Ast.ArgsNamedMethod"] = { "fields" },
    ["Ast.ExpVar"] = { "var" },
    ["Ast.ExpUnop"] = { "exp" },
    ["Ast.ExpConcat"] = { "exps" },
    ["Ast.ExpBinop"] = { "lhs", "rhs" },
    ["Ast.ExpCast"] = { "exp", "length" },
    ["Ast.ExpIs"] = { "exp", "length" },
    -- A parenthesized spread keeps its evaluated-once carrier on the adjust.
    ["Ast.ExpAdjust"] = { "exp", "_adjusted_spread" },
    ["Ast.ExpMethodRef"] = { "exp" },
    ["Ast.ExpUnionInit"] = { "values" },
    ["Ast.ExpDotsIndex"] = { "exp" },
    ["Ast.ExpSubset"] = { "exp", "first", "last" },
    ["Ast.ExpSpread"] = { "exp", "first", "last" },
    -- Shared carriers: visited where they first occur (the `seen` set
    -- makes a later occurrence free).
    ["Ast.ExpExtra"] = { "exp" },
    ["Ast.ExpSpreadIndex"] = { "spread" },
}

local function visit_children(w, node)
    local fields = CHILD_FIELDS[node._tag]
    if fields then
        for _, field in ipairs(fields) do
            local child = node[field]
            if type(child) == "table" and (child._tag == nil or is_ast(child)) then
                visit(w, child)
            end
        end
        return
    end
    -- Any other node: its syntax children, never decorations or annotations.
    for key, child in pairs(node) do
        if type(key) == "string" and key:sub(1, 1) ~= "_" and key ~= "loc" and key ~= "type" and
           key ~= "target" and key ~= "rettypes" and key ~= "typeparams" and type(child) == "table" then
            visit(w, child)
        end
    end
end

-- Enter a function body: active catch handlers do not cross it.
local function visit_function(w, node, lambda)
    local saved_catch = w.catch_error
    w.catch_error = nil
    open_scope(w)
    local fixed = {}
    for _, param in ipairs(node.params or {}) do
        visit_decl(w, param)
        if param.name ~= nil then fixed[#fixed + 1] = param end
    end
    if lambda and #fixed == 1 and unused_binding(fixed[1]) then
        rename_candidate(w, "unused-lambda-param", fixed[1],
            "lambda parameter '" .. fixed[1].name .. "' is never used; rename it to '_'")
    end
    -- Result annotations are resolved where the parameters are visible.
    visit_type(w, node.rettypes)
    visit_type(w, node.flexrettype)
    check_owner_block(w, node.block)
    visit(w, node.block)
    close_scope(w)
    w.catch_error = saved_catch
end

local function visit_loop_body(w, block)
    check_owner_block(w, block)
    visit(w, block)
end

local HANDLERS = {
    ["Ast.VarName"] = function(w, node)
        if node.name == "_" or w.unchecked > 0 then note_hazard(w) end
    end,

    ["Ast.StatBlock"] = function(w, node)
        -- A `defer` tail keeps the enclosing statement-list scope.
        if node._defer_tail then return visit_stats(w, node) end
        open_scope(w)
        visit_stats(w, node)
        close_scope(w)
    end,

    ["Ast.StatDecl"] = function(w, node)
        -- A local enters scope only after its whole declaration.
        visit(w, node.exps)
        check_decl_rules(w, node)
        for _, decl in ipairs(node.decls) do
            visit_decl(w, decl)
            if unused_binding(decl) then
                rename_candidate(w, "unused-local-binding", decl,
                    "local '" .. decl.name .. "' is never used; rename it to '_' to discard it " ..
                    "intentionally (its initializer still runs)")
            end
        end
    end,

    ["Ast.StatAssign"] = function(w, node)
        visit(w, node.exps)
        visit(w, node.vars)
        for _, var in ipairs(node.vars) do record_field_write(w, var) end
    end,

    ["Ast.StatWhile"] = function(w, node)
        visit(w, node.condition)
        visit_loop_body(w, node.block)
    end,

    ["Ast.StatRepeat"] = function(w, node)
        -- The `until` condition shares the body's scope.
        local block = node.block
        check_owner_block(w, block)
        open_scope(w)
        if not w.seen[block] then
            w.seen[block] = true
            tick(w)
            visit_stats(w, block)
        end
        visit(w, node.condition)
        close_scope(w)
    end,

    ["Ast.StatFor"] = function(w, node)
        visit(w, node.start)
        visit(w, node.finish)
        visit(w, node.inc)
        open_scope(w)
        visit_decl(w, node.decl)
        if unused_binding(node.decl) then
            rename_candidate(w, "unused-local-binding", node.decl,
                "loop variable '" .. node.decl.name .. "' is never used; rename it to '_'")
        end
        visit_loop_body(w, node.block)
        close_scope(w)
    end,

    ["Ast.StatForIn"] = function(w, node)
        visit(w, node.exps)
        open_scope(w)
        for _, decl in ipairs(node.decls) do
            visit_decl(w, decl)
            if unused_binding(decl) then
                rename_candidate(w, "unused-local-binding", decl,
                    "loop variable '" .. decl.name .. "' is never used; rename it to '_'")
            end
        end
        visit_loop_body(w, node.block)
        close_scope(w)
    end,

    ["Ast.StatIf"] = function(w, node)
        for _, branch in ipairs(node.thens) do
            if not w.seen[branch] then
                w.seen[branch] = true
                tick(w)
                visit(w, branch.condition)
                check_owner_block(w, branch.block)
                visit(w, branch.block)
            end
        end
        if node.elsestat then
            check_owner_block(w, node.elsestat)
            visit(w, node.elsestat)
        end
    end,

    ["Ast.StatCase"] = function(w, node)
        visit(w, node.exp)
        local closed = node._binary_closed_union
        local owner_mod = closed and binary_owner(w, closed)
        if owner_mod then
            emit(w, "dso-closed-union-case", node,
                "exhaustive 'case' on '" .. closed .. "' from the compiled provider '" .. owner_mod ..
                "' without an 'else' fixes its variant count at this use site; if the provider is " ..
                "replaced independently and may add variants, add an 'else' arm")
        end
        for _, arm in ipairs(node.arms) do
            if not w.seen[arm] then
                w.seen[arm] = true
                tick(w)
                open_scope(w)
                for _, binding in ipairs(arm.bindings or {}) do visit_decl(w, binding) end
                check_owner_block(w, arm.block)
                visit(w, arm.block)
                close_scope(w)
            end
        end
        if node.elseblock then
            check_owner_block(w, node.elseblock)
            visit(w, node.elseblock)
        end
    end,

    ["Ast.StatTry"] = function(w, node)
        visit(w, node.block)
        if node.catchblock then
            -- Only the innermost handler's `error` is in scope by that name.
            local saved = w.catch_error
            w.catch_error = node._error_decl
            visit(w, node.catchblock)
            w.catch_error = saved
        end
        if node.finallyblock then
            local saved = w.catch_error
            w.catch_error = nil
            visit(w, node.finallyblock)
            w.catch_error = saved
        end
    end,

    ["Ast.StatRaise"] = function(w, node)
        visit(w, node.exp)
        visit(w, node.trace)
        local raised = unwrap(node.exp)
        if node.trace == nil and w.catch_error ~= nil and raised and raised._tag == "Ast.ExpVar" and
           raised.var._tag == "Ast.VarName" and raised.var._decl == w.catch_error then
            emit(w, "catch-reraise-resets-trace", node,
                "'raise " .. raised.var.name .. "' starts a new traceback; use a bare 'raise' " ..
                "(or 'raise " .. raised.var.name .. ", traceback') to keep the original one, " ..
                "unless this handler deliberately resets it")
        end
    end,

    ["Ast.ExpFunction"] = function(w, node)
        visit_function(w, node, true)
    end,

    ["Ast.ExpBinop"] = function(w, node)
        visit(w, node.lhs)
        visit(w, node.rhs)
        check_binop(w, node)
    end,

    ["Ast.ExpCall"] = function(w, node)
        visit_type(w, node.typeargs)
        visit_children(w, node)
        check_call(w, node)
    end,

    ["Ast.VarBracket"] = function(w, node)
        visit_children(w, node)
        check_bracket(w, node)
    end,

    ["Ast.ExpInitList"] = function(w, node)
        visit_children(w, node)
        check_initlist(w, node)
    end,

    ["Ast.ExpIs"] = function(w, node)
        visit_children(w, node)
        visit_type(w, node.target)
    end,

    ["Ast.ExpCast"] = function(w, node)
        visit_children(w, node)
        visit_type(w, node.target)
        -- A mutable C address of a field, implicit or written, counts as a
        -- write to that field (the checker's `mutable_c_call_argument_decl`).
        local adjustment = node._adjustment
        local written = node._written_cast
        local plan = type(written) == "table" and written.tag == "just" and written.value
        if (adjustment and adjustment.kind == "direct_coercion" and adjustment.coercion and
            adjustment.coercion.op == "mutable_c_address") or
           (plan and plan.op == "coercion" and plan.coercion and
            plan.coercion.op == "mutable_c_address") then
            record_field_write(w, node.exp and node.exp.var)
        end
    end,
}

visit = function(w, node)
    if type(node) ~= "table" then return end
    if node._tag == nil then
        for _, item in ipairs(node) do visit(w, item) end
        return
    end
    if w.seen[node] then return end
    w.seen[node] = true
    tick(w)
    -- Written owner type arguments the checker keeps on a namespace.
    if node._nominal_typeargs then visit_type(w, node._nominal_typeargs) end
    local handler = HANDLERS[node._tag]
    if handler then handler(w, node) else visit_children(w, node) end
    for _, field in ipairs(ADJUSTMENT_FIELDS) do
        local adjustment = node[field]
        if type(adjustment) == "table" then
            visit_ast_list(w, adjustment.exps)
            visit_ast_list(w, adjustment.fixed)
        end
    end
end

---------------------------------------------------------------------------
-- Top-level rules
---------------------------------------------------------------------------

-- The first header-dependent C declaration (a typedef, struct or union with
-- a declaration origin) in a type's own structure. Nominal types are not
-- expanded here: their fqtns are appended to `edges` for the closed-graph
-- search below.
local function first_header_dependent(t, visited, edges)
    if type(t) ~= "table" or visited[t] then return nil end
    visited[t] = true
    local tag = t._tag
    if tag == "Type.CTypedef" or tag == "Type.CStruct" or tag == "Type.CUnion" then
        if types.c_declaration_origin(t) ~= nil then return t end
        if tag == "Type.CTypedef" then return first_header_dependent(t.target, visited, edges) end
        for _, field in ipairs(t.fields or {}) do
            local found = first_header_dependent(field.type, visited, edges)
            if found then return found end
        end
        return nil
    end
    local function each(list)
        for _, item in ipairs(list or {}) do
            local found = first_header_dependent(item, visited, edges)
            if found then return found end
        end
        return nil
    end
    if tag == "Type.CPointer" then return first_header_dependent(t.pointee, visited, edges)
    elseif tag == "Type.CArray" then return first_header_dependent(t.elem, visited, edges)
    elseif tag == "Type.COwned" then return first_header_dependent(t.pointee, visited, edges)
    elseif tag == "Type.CFunction" then
        return each(t.params) or first_header_dependent(t.ret, visited, edges)
    elseif tag == "Type.Option" then return first_header_dependent(t.base, visited, edges)
    elseif tag == "Type.Array" then return first_header_dependent(t.elem, visited, edges)
    elseif tag == "Type.Map" then
        return first_header_dependent(t.keys, visited, edges) or
            first_header_dependent(t.values, visited, edges)
    elseif tag == "Type.Function" or tag == "Type.Method" or tag == "Type.StaticMethod" then
        if t.islocal then return nil end
        return each(t.params) or each(t.rettypes) or
            first_header_dependent(t.varargtype, visited, edges) or
            first_header_dependent(t.flexrettype, visited, edges)
    elseif tag == "Type.FunctionScheme" then
        return each(t.typeparams) or first_header_dependent(t.signature, visited, edges)
    elseif tag == "Type.TypeParameter" then return first_header_dependent(t.constraint, visited, edges)
    elseif tag == "Type.Parameter" then
        return first_header_dependent(t.erased_constraint, visited, edges)
    elseif tag == "Type.Nominal" then
        if type(t.fqtn) == "string" then edges[#edges + 1] = t.fqtn end
        return each(t.args)
    elseif tag == "Type.Field" then
        if t.islocal then return nil end
        return first_header_dependent(t.type, visited, edges)
    elseif tag == "Type.Interface" then
        return each(t.typeparams) or each(t.fields) or each(t.methods)
    elseif tag == "Type.ModuleMember" or tag == "Type.ModuleVariable" then
        return first_header_dependent(t.type, visited, edges)
    end
    return nil
end

-- The public type graph of a nominal owner: public record fields, the parts
-- of public union variants, and an Interface's fields and methods.
local function nominal_public_types(owner)
    local list = {}
    if type(owner) ~= "table" then return list end
    if owner._tag == "Type.Record" then
        for _, field in ipairs(owner.fields or {}) do
            if not field.islocal then list[#list + 1] = field.type end
        end
    elseif owner._tag == "Type.Union" then
        for _, variant in ipairs(owner.variants or {}) do
            if not variant.islocal then
                for _, part in ipairs(variant.parts or {}) do list[#list + 1] = part.type end
            end
        end
    elseif owner._tag == "Type.Interface" then
        list[#list + 1] = owner
    end
    return list
end

-- Closed-graph reachability over nominal owners (Tarjan's strongly connected
-- components): each owner's result is the first header-dependent type
-- reachable through its public graph, or `false`. A component's members
-- share one result, assigned only when the whole component is complete, so
-- a back edge never caches a premature miss. Each owner is expanded once per
-- module.
local function nominal_header(state, fqtn)
    local result = state.result[fqtn]
    if result ~= nil then return result or nil end
    local function connect(v)
        state.next = state.next + 1
        state.index[v], state.low[v] = state.next, state.next
        state.stack[#state.stack + 1] = v
        state.on[v] = true
        local edges, direct = {}, nil
        for _, t in ipairs(nominal_public_types(types.registry[v])) do
            direct = direct or first_header_dependent(t, {}, edges)
        end
        state.direct[v], state.edges[v] = direct, edges
        for _, s in ipairs(edges) do
            if state.result[s] == nil then
                if state.index[s] == nil then
                    connect(s)
                    state.low[v] = math.min(state.low[v], state.low[s])
                elseif state.on[s] then
                    state.low[v] = math.min(state.low[v], state.index[s])
                end
            end
        end
        if state.low[v] == state.index[v] then
            local members = {}
            repeat
                local member = table.remove(state.stack)
                state.on[member] = false
                members[#members + 1] = member
            until member == v
            local found
            for _, member in ipairs(members) do
                found = found or state.direct[member]
            end
            if not found then
                for _, member in ipairs(members) do
                    for _, s in ipairs(state.edges[member]) do
                        found = found or state.result[s] or nil
                    end
                end
            end
            for _, member in ipairs(members) do state.result[member] = found or false end
        end
    end
    connect(fqtn)
    return state.result[fqtn] or nil
end

local function header_dependent(w, t)
    local edges = {}
    local found = first_header_dependent(t, {}, edges)
    for _, fqtn in ipairs(edges) do
        found = found or nominal_header(w.header_state, fqtn)
    end
    return found
end

-- A test module has no independently built importers.
local function check_public_c_type(w, node, name, t, loc)
    if w.test_module then return end
    local found = header_dependent(w, t)
    if found then
        emit(w, "header-dependent-public-c-export", node,
            "public '" .. name .. "' exposes header-dependent C type '" .. types.tostring(found) ..
            "', so every importer must 'foreign import' compatible headers; keep the C type in a " ..
            "'local' field or behind a portable Titan type unless this is a deliberate C-binding API",
            loc)
    end
end

-- Mirrors the checker's exported-declaration walk. Synthesized constructors
-- repeat their fields' or variant parts' types, which are reported at their
-- own declarations.
local function check_public_c_exports(w, node)
    local tag = node._tag
    if (tag == "Ast.TopLevelVar" or tag == "Ast.TopLevelFunc" or tag == "Ast.TopLevelForeignFunc" or
        tag == "Ast.TopLevelTypeAlias" or tag == "Ast.TopLevelMethod" or tag == "Ast.TopLevelStatic") and
       not node.islocal and not node._record_constructor and not node._union_constructor then
        local name = tag == "Ast.TopLevelVar" and node.decl and node.decl.name or node.name
        if tag == "Ast.TopLevelMethod" or tag == "Ast.TopLevelStatic" then
            name = tostring(node.class) .. (tag == "Ast.TopLevelMethod" and ":" or ".") .. tostring(name)
        end
        check_public_c_type(w, node, tostring(name), node._type)
    elseif tag == "Ast.TopLevelInterface" then
        check_public_c_type(w, node, node.name, node._type)
    elseif tag == "Ast.TopLevelRecord" and not node.islocal and node._type then
        for index, field in ipairs(node._type.fields or {}) do
            if not field.islocal then
                local syntax = node.fields[index] or node
                check_public_c_type(w, syntax, node.name .. "." .. field.name, field.type, syntax.loc)
            end
        end
    elseif tag == "Ast.TopLevelUnion" and not node.islocal then
        for _, variant in ipairs(node.variants) do
            if variant._type and not variant._type.islocal then
                for index, part in ipairs(variant._type.parts or {}) do
                    local syntax = variant.parts[index] or variant
                    check_public_c_type(w, syntax, node.name .. "." .. variant.name, part.type, syntax.loc)
                end
            end
        end
    end
end

local function check_import(w, node)
    local written = node._written_modname
    if node.source_required or type(written) ~= "string" then return end
    local short = written:match("^titan%.(.+)$")
    if not short or short == node.modname then return end
    local normalized, source_required = parser.normalize_import(short)
    if not source_required and normalized == node.modname then
        emit(w, "stdlib-import-spelling", node,
            "use the short standard-library import \"" .. short .. "\" instead of \"" .. written .. "\"")
    end
end

-- `test_runner.is_test_function` expects a monomorphic function type.
local function discovered_test(node)
    return node._tag == "Ast.TopLevelFunc" and type(node._type) == "table" and
        node._type._tag == "Type.Function" and test_runner.is_test_function(node)
end

local function check_test_signature(w, node)
    if node._tag ~= "Ast.TopLevelFunc" or node._ignore or node.islocal or
       type(node.name) ~= "string" or not node.name:match("^test_") or discovered_test(node) then
        return
    end
    emit(w, "unmatched-public-test-signature", node,
        "public function '" .. node.name .. "' starts with 'test_' but does not take exactly one " ..
        "'test.Context' parameter, so 'titanc --test' does not discover it as a test")
end

local function lint_module(unit, mode, sink, allowed)
    local w = {
        modname = unit.modname, mode = mode, sink = sink, allowed = allowed, emitted = {}, seen = {},
        seq = 0, hazards = 0, prefix = { [0] = 0 }, scopes = {},
        catch_error = nil, unchecked = 0,
        source_imports = {}, field_writes = {}, local_fields = {},
        provider_kind = unit.provider_kind or function() return nil end,
        header_state = { next = 0, index = {}, low = {}, stack = {}, on = {}, direct = {},
            edges = {}, result = {} },
    }
    local ast = unit.ast
    local imports_test = false
    for _, node in ipairs(ast) do
        local tag = node._tag
        if tag == "Ast.TopLevelImport" and not node._ignore then
            if node.source_required then w.source_imports[node.modname] = true end
            if node.modname == "titan.test" then imports_test = true end
        end
        local name = tag == "Ast.TopLevelImport" and node.localname or
            tag == "Ast.TopLevelVar" and node.decl and node.decl.name or
            tag ~= "Ast.TopLevelMethod" and tag ~= "Ast.TopLevelStatic" and node.name
        if name == "_" then w.module_underscore = true end
        if discovered_test(node) then w.test_module = true end
    end
    open_scope(w)
    for _, node in ipairs(ast) do
        local tag = node._tag
        if not node._ignore then
            check_public_c_exports(w, node)
            if tag == "Ast.TopLevelImport" then
                check_import(w, node)
            elseif tag == "Ast.TopLevelFunc" or tag == "Ast.TopLevelMethod" or
                   tag == "Ast.TopLevelStatic" then
                if imports_test then check_test_signature(w, node) end
                -- Synthesized constructors have no written body.
                if not node._record_constructor and not node._union_constructor then
                    tick(w)
                    visit_function(w, node, false)
                end
            elseif tag == "Ast.TopLevelVar" then
                tick(w)
                visit_decl(w, node.decl)
                visit(w, node.value)
            elseif tag == "Ast.TopLevelRecord" then
                -- Only this module and its '.titan' source importers assign a
                -- 'local' field; Lua code may also assign a public field of a
                -- 'local record'.
                for _, field in ipairs(node.fields) do
                    local descriptor = field._decl
                    if (node.islocal or field.islocal) and not field.isconst and
                       type(descriptor) == "table" and descriptor._tag == "Type.Field" and
                       not types.is_c_aggregate(descriptor.type) then
                        w.local_fields[#w.local_fields + 1] = { node = field, record = node.name,
                            key = tostring(descriptor.fqtn) .. "\0" .. tostring(descriptor.name) }
                    end
                end
            elseif tag == "Ast.StatBlock" then
                -- The module's root initializer: a function body of its own.
                local saved_catch = w.catch_error
                w.catch_error = nil
                visit(w, node)
                w.catch_error = saved_catch
            end
        end
    end
    close_scope(w)
    for _, field in ipairs(w.local_fields) do
        if not w.field_writes[field.key] then
            local name = field.record .. "." .. field.node.name
            emit(w, "prefer-const-local-field", field.node, field.node.islocal and
                ("local field '" .. name .. "' is never assigned in this module; consider " ..
                    "'local const' (unless a '.titan' source importer assigns it)") or
                ("field '" .. name .. "' of local record '" .. field.record .. "' is never " ..
                    "assigned in this module; consider 'const' (unless a '.titan' source " ..
                    "importer or Lua code assigns it)"),
                field.node._name_loc)
        end
    end
end

---------------------------------------------------------------------------
-- In-source exceptions: `-- titan-lint: allow(<rule-id>[, ...])`
---------------------------------------------------------------------------

-- The parser's own comment and string tokens, so a directive spelled inside
-- a string literal or a long comment is never one.
local COMMENT_END = (lexer.COMMENT / 0) * lpeg.Cp()
local STRING_END = (lexer.STRINGLIT / 0) * lpeg.Cp()
-- Every exception names its rules: no severity group or wildcard.
local RULE_GROUPS = set_of({ "all", "warnings", "hints" })
-- Tokens that close a block, so no statement of that block follows them.
local BLOCK_CLOSERS = set_of({ "end", "else", "elseif", "until", "catch", "finally", "when" })

-- The rule IDs of a directive comment body (the comment text after `--`,
-- starting at `titan-lint`), or `nil, message`.
local function parse_directive(body)
    local rest = body:match("^titan%-lint%s*:(.*)$")
    if not rest then return nil, "expected ':' after 'titan-lint'" end
    local verb, after = rest:match("^%s*([%a_][%w_%-]*)(.*)$")
    if verb ~= "allow" then
        return nil, verb and "unknown directive '" .. verb .. "' (expected 'allow')" or
            "expected 'allow(<rule-id>, ...)' after 'titan-lint:'"
    end
    if not after:match("^%s*%(") then return nil, "expected '(' after 'allow'" end
    local list, tail = after:match("^%s*%(([^)]*)%)(.*)$")
    if not list then return nil, "unclosed '(' in 'allow(...)'" end
    if not list:find("%S") then return nil, "empty 'allow()': name each rule it allows" end
    local rules, seen = {}, {}
    for item in (list .. ","):gmatch("([^,]*),") do
        local id = item:match("^%s*(.-)%s*$")
        if id == "" then return nil, "empty rule ID in 'allow(...)'" end
        if RULE_GROUPS[id] then
            return nil, "'allow(" .. id .. ")' is not supported: name each rule it allows"
        end
        if not RULE_BY_ID[id] then return nil, "unknown lint rule '" .. id .. "'" end
        if seen[id] then return nil, "duplicate lint rule '" .. id .. "'" end
        seen[id] = true
        rules[#rules + 1] = id
    end
    if tail:find("%S") then
        local separator, reason = tail:match("^%s*([:%-]%-?)%s*(.-)%s*$")
        if separator ~= ":" and separator ~= "--" then
            return nil, "unexpected text after 'allow(...)' (write ': <reason>')"
        end
        if reason == "" then return nil, "expected a reason after '" .. separator .. "'" end
    end
    return rules
end

-- Scan one contributing file's directives, appending `{ file, line, col,
-- message }` problems. Returns `{ [line] = { [rule-id] = directive line } }`,
-- or nil for a file without directives. A directive after code on its line
-- covers that line; a directive alone on its line covers the line of the
-- next code token, past blank, comment and `---` documentation lines, and
-- stacked directives combine. Only the parser counts lines: '\n' ends one,
-- and '\r' is whitespace.
local function scan_directives(filename, text, problems)
    if not text:find("titan-lint", 1, true) then return nil end
    local allowed, pending = nil, {}
    local pos, size, line, line_start = 1, #text, 1, 1
    -- The line on which the latest code token ended.
    local code_line = 0
    -- Inside a `---` comment run that `documentation.attach` collects: a
    -- directive there would become documentation text.
    local in_documentation = false

    local function problem(directive, message)
        problems[#problems + 1] = { file = filename, line = directive.line, col = directive.col,
            message = message }
    end

    local function allow(target, directive)
        allowed = allowed or {}
        local rules = allowed[target]
        if not rules then
            rules = {}
            allowed[target] = rules
        end
        for _, id in ipairs(directive.rules) do
            if rules[id] then
                problem(directive, "lint rule '" .. id .. "' is already allowed for line " .. target ..
                    " by the directive on line " .. rules[id])
            else
                rules[id] = directive.line
            end
        end
    end

    -- Move to `stop`, counting the line breaks passed over.
    local function advance(stop)
        local at = text:find("\n", pos, true)
        while at and at < stop do
            line, line_start = line + 1, at + 1
            at = text:find("\n", at + 1, true)
        end
        pos = stop
    end

    -- A code token spanning `pos` up to `stop`.
    local function code(stop)
        if #pending > 0 then
            local word = text:match("^[%a_][%w_]*", pos)
            for _, directive in ipairs(pending) do
                if BLOCK_CLOSERS[word] then
                    problem(directive, "no declaration or statement follows it before '" .. word .. "'")
                else
                    allow(line, directive)
                end
            end
            pending = {}
        end
        in_documentation = false
        advance(stop)
        code_line = line
    end

    while pos <= size do
        local byte = text:byte(pos)
        if byte == 10 or byte == 13 then
            -- A line break outside a comment ends any `---` comment run.
            in_documentation = false
            advance(pos + 1)
        elseif byte == 32 or byte == 9 or byte == 11 or byte == 12 then
            pos = pos + 1
        elseif byte == 45 and text:byte(pos + 1) == 45 then
            local stop = lpeg.match(COMMENT_END, text, pos) or size + 1
            local raw = text:sub(pos, stop - 1)
            if raw:match("^%-%-%[=*%[") then
                in_documentation = false
            elseif raw:byte(3) == 45 then
                in_documentation = true
            else
                local body = raw:sub(3):gsub("[\r\n]+$", ""):match("^%s*(.*)$")
                if body:match("^titan%-lint%f[^%w_%-]") then
                    local directive = { line = line, col = pos - line_start + 1 }
                    local rules, message = parse_directive(body)
                    if in_documentation then
                        problem(directive, "it is inside a '---' documentation comment; " ..
                            "place it above the documentation")
                    elseif not rules then
                        problem(directive, message)
                    else
                        directive.rules = rules
                        if code_line == line then
                            allow(line, directive)
                        else
                            pending[#pending + 1] = directive
                        end
                    end
                end
            end
            advance(stop)
        elseif byte == 34 or byte == 39 or byte == 91 then
            code(lpeg.match(STRING_END, text, pos) or pos + 1)
        else
            code(text:find("[%s\"'%[%-]", pos + 1) or size + 1)
        end
    end
    for _, directive in ipairs(pending) do
        problem(directive, "no declaration or statement follows it")
    end
    return allowed
end

local function problem_less(a, b)
    if a.file ~= b.file then return a.file < b.file end
    if a.line ~= b.line then return a.line < b.line end
    if a.col ~= b.col then return a.col < b.col end
    return a.message < b.message
end

local function diagnostic_less(a, b)
    if a.file ~= b.file then return a.file < b.file end
    if a.line ~= b.line then return a.line < b.line end
    if a.col ~= b.col then return a.col < b.col end
    if a.rule ~= b.rule then return a.rule < b.rule end
    return a.message < b.message
end

-- Lint checked analysis ASTs. `units` is a list of `{ modname, ast, sources }`
-- where `sources` lists the `{ filename, text }` of the module's contributing
-- files, whose `-- titan-lint:` directives are validated first: any invalid
-- one fails the run with `nil, errors`. `config` comes from
-- `linter.configure`. Diagnostics are attributed to the contributing file of
-- each node and sorted by file, line, column and rule.
function linter.lint(units, config)
    local allowed, problems = {}, {}
    for _, unit in ipairs(units) do
        for _, source in ipairs(unit.sources or {}) do
            if allowed[source.filename] == nil then
                allowed[source.filename] = scan_directives(source.filename, source.text, problems) or false
            end
        end
    end
    if #problems > 0 then
        table.sort(problems, problem_less)
        local errors = {}
        for index, p in ipairs(problems) do
            errors[index] = string.format("%s:%d:%d: invalid titan-lint directive: %s",
                p.file, p.line, p.col, p.message)
        end
        return nil, errors
    end
    local diagnostics = {}
    for _, unit in ipairs(units) do lint_module(unit, config.mode, diagnostics, allowed) end
    table.sort(diagnostics, diagnostic_less)
    local result = { diagnostics = diagnostics, warning_count = 0, hint_count = 0, denied_count = 0 }
    for _, diagnostic in ipairs(diagnostics) do
        if diagnostic.severity == "warning" then
            result.warning_count = result.warning_count + 1
        else
            result.hint_count = result.hint_count + 1
        end
        if diagnostic.denied then result.denied_count = result.denied_count + 1 end
    end
    return result
end

---------------------------------------------------------------------------
-- Output formats
---------------------------------------------------------------------------

function linter.format_human(result)
    local lines = {}
    for index, d in ipairs(result.diagnostics) do
        lines[index] = string.format("%s:%d:%d: %s[%s]: %s", d.file, d.line, d.col,
            d.severity, d.rule, d.message)
    end
    return table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
end

local JSON_ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function json_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return JSON_ESCAPES[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

function linter.format_json(result)
    local items = {}
    for index, d in ipairs(result.diagnostics) do
        items[index] = string.format(
            '{"file":%s,"line":%d,"col":%d,"severity":%s,"rule":%s,"message":%s,"denied":%s}',
            json_string(d.file), d.line, d.col, json_string(d.severity), json_string(d.rule),
            json_string(d.message), d.denied and "true" or "false")
    end
    return '{"version":' .. linter.FORMAT_VERSION .. ',"diagnostics":[' ..
        table.concat(items, ",") .. "]}\n"
end

return linter
