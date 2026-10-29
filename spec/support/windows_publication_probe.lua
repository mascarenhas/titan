local root = assert(arg[1])
local publication = assert(loadfile(root .. "/windows_publication.lua"))()
local support = assert(package.loadlib(root .. "/support.dll", "luaopen_titan"))()
assert(package.loaded.titan == nil)
local filesystem = require("titan-compiler.io").new_sync()
local fs = {
  stat = function(path)
    local metadata, err = filesystem:lstat(path)
    return metadata, err, metadata == nil and err == nil and 2 or nil
  end,
  reserve = function(path) return filesystem:reserve_sibling(path) end,
  replace = function(from, to) return filesystem:rename(from, to) end,
  remove = os.remove,
}
local function read(path)
  local f = assert(io.open(path, "rb")); local bytes = assert(f:read("a")); assert(f:close()); return bytes
end
local function write(path, bytes)
  local f = assert(io.open(path, "wb")); assert(f:write(bytes)); assert(f:close())
end
local old = read(root .. "/support.dll")
local function fail_at(second)
  return { after_commit = function(index, _)
    if index == second then return nil, "injected final failure" end
    return true
  end }
end
for _, mode in ipairs({ "provider", "program", "rollback", "new-launcher", "mapped",
    "mapped-unchanged", "alias" }) do
  local prefix = root .. "/" .. mode
  local image, launcher = prefix .. "-provider.dll", prefix .. ".exe"
  local source, executable_source = prefix .. "-source.dll", prefix .. "-source.exe"
  write(image, old)
  write(source, mode == "mapped-unchanged" and old or old .. "new overlay")
  write(executable_source, "new executable")
  local launcher_existed = mode == "program" or mode == "rollback"
  if launcher_existed then write(launcher, "old executable") end
  local held
  if mode == "mapped" or mode == "mapped-unchanged" then
    held = assert(package.loadlib(image, "luaopen_titan"))
  end
  local request, options
  if mode == "provider" or mode == "alias" then
    request = { destination = image,
      source = mode == "alias" and image:upper() or source }
  else
    request = { provider = { destination = image, source = source },
      executable = { destination = launcher, source = executable_source } }
    if mode == "rollback" or mode == "new-launcher" then options = fail_at(2) end
  end
  local ok, err
  if request.provider then
    ok, err = publication.publish_program(request, fs, options)
  else
    ok, err = publication.publish({ request }, fs, options)
  end
  print(mode .. ": " .. tostring(ok) .. " " .. tostring(err))
  if mode == "provider" or mode == "program" then
    assert(ok, err)
    assert(read(image) == old .. "new overlay", "provider bytes were not published")
    if mode == "program" then
      assert(read(launcher) == "new executable", "launcher bytes were not published")
    else
      assert(not filesystem:lstat(launcher), "single-provider publication created a launcher")
    end
  elseif mode == "mapped-unchanged" then
    assert(ok, err); assert(read(image) == old, "unchanged mapped image was rewritten")
  else
    assert(not ok, "expected protected failure")
    assert(read(image) == old, "previous image bytes changed")
    if mode == "new-launcher" then
      assert(filesystem:lstat(launcher) == nil, "new launcher survived rollback")
    elseif launcher_existed then
      assert(read(launcher) == "old executable", "previous launcher bytes changed")
    end
  end
  if held then assert(type(held()) == "table") end
end
print("native publication transaction passed")
