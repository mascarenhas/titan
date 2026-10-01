local root = assert(arg[1])
local publication = assert(loadfile(root .. "/windows_publication.lua"))()
local support = assert(package.loadlib(root .. "/support.dll", "luaopen_titan"))()
assert(package.loaded.titan == nil)
local fs = {
  stat = function(path) return support._win_stat(path, false) end,
  reserve = support._win_reserve_sibling,
  replace = support._win_replace,
  remove = os.remove,
}
local function read(path)
  local f = assert(io.open(path, "rb")); local bytes = assert(f:read("a")); assert(f:close()); return bytes
end
local function write(path, bytes)
  local f = assert(io.open(path, "wb")); assert(f:write(bytes)); assert(f:close())
end
local old = read(root .. "/support.dll")
for _, mode in ipairs({ "normal", "rollback", "mapped", "alias" }) do
  local prefix = root .. "/" .. mode
  local image, shim, source = prefix .. "-provider.dll", prefix .. ".lua", prefix .. "-source.dll"
  write(image, old); write(shim, "old shim"); write(source, old .. "new overlay")
  local held
  if mode == "mapped" then held = assert(package.loadlib(image, "luaopen_titan")) end
  local options
  if mode == "rollback" then options = { after_commit = function(i)
    if i == 2 then return nil, "injected final failure" end
    return true
  end } end
  local ok, err = publication.publish({ { destination = shim, contents = "new shim" },
    { destination = image, source = mode == "alias" and image:upper() or source } }, fs, options)
  print(mode .. ": " .. tostring(ok) .. " " .. tostring(err))
  if mode == "normal" then
    assert(ok, err); assert(read(image) == old .. "new overlay"); assert(read(shim) == "new shim")
  else
    assert(not ok, "expected protected failure")
    assert(read(image) == old, "previous image bytes changed")
    assert(read(shim) == "old shim", "previous shim bytes changed")
  end
  if held then assert(type(held()) == "table") end
end
print("native publication transaction passed")
