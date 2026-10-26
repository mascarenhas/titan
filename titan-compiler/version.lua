-- Canonical compiler/package version identities shared by modules which cannot
-- depend on driver.lua without creating an initialization cycle.
local version = {
    TITAN_ABI_VERSION = "2",
    TITAN_VERSION = "0.6.0",
    LUA_VERSION = "5.5",
    OBJECT_RECORD_SCHEMA = "1",
    TITAN_LINK_RECORD_SCHEMA = "1",
    TITAN_NATIVE_RECORD_SCHEMA = "1",
    CERTIFICATE_DIGEST = "sha256",
    CERTIFICATE_CANONICALIZATION = "titan-certificate-v1",
    BUILD_WORKER_PROTOCOL = "titan-build-worker-v1",
    C_HEADER_FILE_PROTOCOL = "c-header-file-v3",
    C_HEADER_SEARCH_PROTOCOL = "c-header-search-v2",
    C_HEADER_ORIGIN_PROTOCOL = "c-header-origin-v1",
    C_HEADER_CACHE_VERSION = 8,
    PROJECT_CACHE_VERSION = 6,
    SOURCE_INTERFACE_FORMAT = "titan-source-interface-v2",
}

version.TITAN_LIBRARY_VERSION =
    assert(version.TITAN_VERSION:match("^(%d+%.%d+)%.[0-9]+$"))
version.TITAN_LIBRARY_VERSION_SUFFIX =
    "_" .. version.TITAN_LIBRARY_VERSION:gsub("%.", "_")

return version
