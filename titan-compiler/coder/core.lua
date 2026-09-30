-- Shared lexical environment for the implementation slices.
-- Feature modules install private declarations here in facade-controlled order;
-- global language and library names remain available through __index lookups.
local core = setmetatable({}, { __index = _G })
local _ENV = core

types = require "titan-compiler.types"

maybe3 = require "titan-compiler.maybe3"

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
