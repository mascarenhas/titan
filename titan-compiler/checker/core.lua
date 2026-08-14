-- Shared lexical environment for the checker implementation slices.
-- Feature modules install private declarations here in facade-controlled order;
-- global language and library names remain available through __index lookups.
local core = setmetatable({}, { __index = _G })
local _ENV = core

checker = {}

location = require "titan-compiler.location"

symtab = require "titan-compiler.symtab"

types = require "titan-compiler.types"

ast = require "titan-compiler.ast"

util = require "titan-compiler.util"

foreigntypes = require "titan-compiler.foreigntypes"

cdriver = require("c-parser.cdriver")

cdefines = require("c-parser.cdefines")

cprobe = require "titan-compiler.cprobe"

csemantics = require "titan-compiler.csemantics"

cdeclarator = require "titan-compiler.cdeclarator"

return core
