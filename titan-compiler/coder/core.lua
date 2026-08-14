-- Shared lexical environment for the implementation slices.
-- Feature modules install declarations here in facade-controlled order.
-- These names were genuine _ENV globals in the monolith; proxy them to _G
-- so this mechanical split preserves their binding and mutation semantics.
local global_bindings = {
    array_metatable = true,
    setboxed = true,
    copyboxed = true,
    checkandgetmixed = true,
    checkandsetmixed = true,
}
local core = setmetatable({}, {
    __index = _G,
    __newindex = function(self, name, value)
        if global_bindings[name] then
            rawset(_G, name, value)
        else
            rawset(self, name, value)
        end
    end,
})
local _ENV = core

types = require "titan-compiler.types"

util  = require "titan-compiler.util"

cdeclarator = require "titan-compiler.cdeclarator"

coder = {
    _csemantics = require "titan-compiler.csemantics",
    -- Every slice reads this generation-local policy from the one shared
    -- implementation table. coder.generate resets it before emitline runs.
    _emit_line_directives = true,
}

-- Lua 5.5's CallInfo encodes finite result requests only through MAXRESULTS.
-- The checker rejects wider finite generic function-value calls; keep the same
-- value here as an internal assertion so hand-built or stale ASTs cannot emit
-- an invalid finite luaD_callnoyield request. Statically open generic calls use
-- LUA_MULTRET.
LUA_VM_MAX_RESULTS = 250

codeexp, codestat, codeforeignexp, codelambda, codelambdadec, codemethodref =
    nil, nil, nil, nil, nil, nil

codedotsindex = nil   -- forward: codecall (case-2 borrow) calls it; defined below

render = util.render

return core
