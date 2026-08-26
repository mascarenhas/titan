extra_ffi_include_dirs = {
  "vendor/lpeglabel",
  "llhttp-release-v9.4.3/include",
  "openssl-build/include",
  "openssl-3.5.7/include",
  "libuv-v1.52.1/include",
}

extra_ffi_cppflags =
  "-D_GNU_SOURCE -DOPENSSL_API_COMPAT=30000"
