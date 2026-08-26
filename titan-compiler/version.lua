-- Canonical compiler/package version identities shared by modules which cannot
-- depend on driver.lua without creating an initialization cycle.
local version = {
    TITAN_ABI_VERSION = "2",
    TITAN_VERSION = "0.6.0",
    LUA_VERSION = "5.5",
}

version.TITAN_LIBRARY_VERSION =
    assert(version.TITAN_VERSION:match("^(%d+%.%d+)%.[0-9]+$"))
version.TITAN_LIBRARY_VERSION_SUFFIX =
    "_" .. version.TITAN_LIBRARY_VERSION:gsub("%.", "_")

return version
