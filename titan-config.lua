extra_ffi_include_dirs = {
  "lua-5.5.1/src",
  "vendor/lpeglabel",
  "llhttp-release-v9.4.3/include",
  "sqlite-autoconf-3530400",
  "openssl-build/include",
  "openssl-3.5.7/include",
  "libuv-v1.52.1/include",
  "spec/fixtures/stdlib/native"
}

extra_ffi_cppflags =
"-D_GNU_SOURCE -DOPENSSL_API_COMPAT=30000"

include = { "./titan", "./spec/stdlib/titan" }

source_module_roots = { ".", "./spec/stdlib/titan" }
