assert(require("relocation_é") == "relocated UTF-8 Lua source")
assert(require("titan_lua_sdk_probe") == 5)
local filename, mode = assert(arg[1]), assert(arg[2])
assert(mode == "reject" or mode == "accept")
local directory = assert(filename:match("^(.*)[/\\][^/\\]+$"))
package.cpath = directory .. "/?.dll;" .. package.cpath
assert(package.searchpath("titan_loader_canary", package.cpath))
local open, err, stage = package.loadlib(filename, "luaopen_titan_loader_canary")
if mode == "reject" then
    assert(open == nil and type(err) == "string" and stage == "open",
        "loaded a module with an absent native dependency")
    local ok, message = pcall(require, "titan_loader_canary")
    assert(not ok and type(message) == "string")
else
    assert(assert(open, err)() == 67)
    assert(require("titan_loader_canary") == 67)
end
print("relocated Lua and ordinary Windows DLL search passed: " .. mode)
