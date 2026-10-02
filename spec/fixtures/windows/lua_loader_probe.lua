assert(require("relocation_é") == "relocated UTF-8 Lua source")
assert(require("titan_lua_sdk_probe") == 5)
assert(not pcall(package.loadlib, arg[1] .. "\0suffix", "luaopen_titan_loader_canary"))
assert(not pcall(package.loadlib, arg[1], "luaopen_titan_loader_canary\0suffix"))
local invalid, message = package.loadlib("\255.dll", "luaopen_titan_loader_canary")
assert(invalid == nil and type(message) == "string")
local open, err = package.loadlib(arg[1], "luaopen_titan_loader_canary")
if arg[2] == "reject" then
    assert(open == nil and type(err) == "string", "loaded dependency outside app bin/System32")
else
    assert(assert(open, err)() == 67)
end
print("relocated UTF-8 Lua and controlled DLL search passed: " .. arg[2])
