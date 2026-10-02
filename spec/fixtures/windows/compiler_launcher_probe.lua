-- Run both through the native entry and directly through its controlled Lua.
assert(_VERSION == "Lua 5.5")
local lfs = require "lfs"
assert(type(lfs.currentdir()) == "string")
assert(require("lpeglabel").match(require("lpeglabel").P("ok"), "ok") == 3)
assert(require("relabel").match("ok", "'ok'") == 3)
assert(type(require("inspect")({ok = true})) == "string")
assert(type(require("argparse")) == "table")
assert(type(require("titan-compiler.parser")) == "table")
local function hex(text)
    return (text:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
end
assert(arg[-2] == nil)
assert(arg[-1]:match("[\\/]titanc%.exe$") or arg[-1]:match("[\\/]lua%.exe$"))
assert(arg[0]:match("[\\/]titanc%.lua$"))
local args = table.pack(...)
assert(args.n == #arg)
for i = 1, args.n do assert(args[i] == arg[i]) end
if arg[1] == "error" then error("native launcher diagnostic", 0) end
if arg[1] == "exit" then os.exit(37) end
if arg[1] == "init" then assert(titan_launcher_init == "preserved") end
for i = 1, #arg do print(i .. ":" .. hex(arg[i])) end
