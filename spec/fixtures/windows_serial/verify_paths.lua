local path = require "titan-compiler.windows_path"
local checks = 0
local function equal(expected, actual)
    checks = checks + 1
    assert(expected == actual, string.format("expected %q, got %q", tostring(expected), tostring(actual)))
end
local function failure(fn, reason, ...)
    local value, message, actual_reason = fn(...)
    equal(nil, value)
    assert(type(message) == "string" and #message > 0)
    equal(reason, actual_reason)
end
local function split(value, parent, leaf)
    local actual_parent, actual_leaf, message = path.split(value)
    equal(nil, message)
    equal(parent, actual_parent)
    equal(leaf, actual_leaf)
end

local kinds = {
    { [[C:\folder\file]], "drive_absolute", true },
    { "c:/folder/file", "drive_absolute", true },
    { [[\\server\share\folder]], "unc_absolute", true },
    { "//Server/Share", "unc_absolute", true },
    { [[\\?\C:\folder\..\file]], "extended_drive", true },
    { [[\\?\UNC\server\share\folder]], "extended_unc", true },
    { [[\\?\unc\Server\Share]], "extended_unc", true },
    { [[\\?\Volume{d0ac8cd8-bd4b-11f1-af3e-fa5e484244a2}\folder]], "extended_volume", true },
    { [[C:folder\file]], "drive_relative", false },
    { "C:", "drive_relative", false },
    { [[\folder\file]], "root_relative", false },
    { "/folder/file", "root_relative", false },
    { [[folder\file]], "relative", false },
    { ".", "relative", false },
}
for _, case in ipairs(kinds) do
    equal(case[2], path.kind(case[1]))
    equal(case[3], path.is_absolute(case[1]))
end

equal("C:/Hello World/é/雪/file", path.separators([[C:\Hello World\é/雪\file]]))
equal("//Server/Share/folder", path.separators([[\\Server\Share\folder]]))
local extended = [[\\?\c:\Hello World\é\雪\.\..\trailing. ]]
equal(extended, path.separators(extended))
equal(extended, path.normalize(extended))
equal(extended, path.absolute(extended, nil))
equal([[\\?\UNC\Server\Share\..\X]], path.normalize([[\\?\UNC\Server\Share\..\X]]))
equal("C:/b", path.normalize([[C:\a\.\..\b]]))
equal("C:/b", path.normalize("C:/../../b"))
equal("C:/", path.normalize("C:/a/../../.."))
equal("//Server/Share/b", path.normalize([[\\Server\Share\a\..\..\b]]))
equal("//Server/Share/", path.normalize("//Server/Share/../../"))
equal("/b", path.normalize("/a/../../b"))
equal("../../b", path.normalize("a/../../../b"))
equal("C:../b", path.normalize("C:a/../../b"))
equal("C:", path.normalize("C:a/.."))
equal(".", path.normalize("./a/.."))
equal("a/b", path.normalize([[a\\b//]]))
equal("C:/Case/é/雪/space . ", path.normalize([[C:\Case\é\雪\space . ]]))

equal("C:/root/link/../file", path.absolute([[link\..\file]], [[C:\root]]))
equal("D:/file", path.absolute("/file", [[D:\root\child]]))
equal("//Server/Share/file", path.absolute([[\file]], [[\\Server\Share\child]]))
equal("//Server/Share/child/../file", path.absolute("../file", "//Server/Share/child"))
equal("c:/Existing/../file", path.absolute([[c:\Existing\..\file]], nil))
failure(path.absolute, "native_resolution_required", "C:foo", "C:/cwd")
failure(path.absolute, "native_resolution_required", "D:foo", "C:/cwd")
failure(path.absolute, "native_resolution_required", "../foo", [[\\?\C:\cwd]])
failure(path.absolute, "native_resolution_required", "/foo", [[\\?\UNC\s\share\cwd]])
failure(path.absolute, "invalid_path", "foo", "relative-cwd")

equal("C:/root/lib/titan/0.6", path.join([[C:\root]], "lib/titan/0.6"))
equal("C:/file", path.join("C:/", "file"))
equal("C:file", path.join("C:", "file"))
equal("relative/base/file", path.join("relative/base", "file"))
equal([[\\?\C:\root\lib\titan\0.6]], path.join([[\\?\C:\root]], "lib/titan/0.6"))
equal([[\\?\UNC\s\share\file]], path.join([[\\?\UNC\s\share]], "file"))
equal([[\\?\C:\root\a\..\b]], path.join([[\\?\C:\root]], "a/../b"))
equal([[\\?\C:\root\file. ]], path.join([[\\?\C:\root]], "file. "))
failure(path.join, "invalid_path", "C:/base", "D:/absolute")
failure(path.join, "invalid_path", "C:/base", "/rooted")
failure(path.join, "invalid_path", "C:/base", "D:relative")

split("C:/", nil, nil)
split("C:////", nil, nil)
split("//Server/Share", nil, nil)
split("//Server/Share/", nil, nil)
split("//Server/Share/file", "//Server/Share/", "file")
split([[\\?\C:\]], nil, nil)
split([[\\?\UNC\s\share]], nil, nil)
split([[\\?\UNC\s\share\]], nil, nil)
split([[\\?\UNC\s\share\child]], [[\\?\UNC\s\share\]], "child")
split([[\\?\C:\root\..\file]], [[\\?\C:\root\..]], "file")
split("C:/root/../file", "C:/root/..", "file")
split("C:/root/", "C:/root", "")
split("C:foo", "C:", "foo")
split("C:", nil, nil)
split("/file", "/", "file")
split("a/b", "a", "b")
split("file", nil, "file")
split(".", nil, ".")

for _, value in ipairs({
    "", "bad\0path", "//server", "//server/", "//server//share", "///server/share",
    "//?/C:/file", [[\\.\PhysicalDrive0]], [[\\?\C:relative]],
    [[\\?\C:\bad/slash]], [[\\?\UNC\server]], [[\\?\GLOBALROOT\Device\X]],
    [[\\?\Volume{not-a-guid}\file]],
    [[\\?\Volume{g0ac8cd8-bd4b-11f1-af3e-fa5e484244a2}\file]],
}) do
    failure(path.normalize, "invalid_path", value)
end
failure(path.separators, "invalid_path", {})
local parent, leaf, message, reason = path.split("")
equal(nil, parent)
equal(nil, leaf)
assert(type(message) == "string")
equal("invalid_path", reason)
print(string.format("Windows lexical path tests passed (%d assertions)", checks))
