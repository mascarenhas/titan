extra_ffi_include_dirs = {
  "vendor/lpeglabel",
  "spec/fixtures/stdlib/native"
}

extra_ffi_cppflags =
"-D_GNU_SOURCE -DOPENSSL_API_COMPAT=30000"

include = { "./titan", "./spec/stdlib/titan" }

source_module_roots = { ".", "./spec/stdlib/titan" }
