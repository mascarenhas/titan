local version = require "titan-compiler.version"

local major, minor = version.TITAN_LIBRARY_VERSION:match("^([0-9]+)%.([0-9]+)$")
major, minor = tonumber(major), tonumber(minor)

local series = {
    ("%d.%d"):format(major, minor + 1),
    ("%d.%d"):format(major + 1, minor),
}
if minor > 0 then
    series[#series + 1] = ("%d.%d"):format(major, minor - 1)
end
return series
