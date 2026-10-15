.DELETE_ON_ERROR:
.DEFAULT_GOAL := all

# Titan compiler — developer tooling.
#
# The compiler generates C that includes Lua 5.5's *internal* headers and links
# against its matching static library. Native targets reuse the installed Lua
# SDK when available; `make lua` prepares it from a local source build. This
# Makefile also runs the suite through `luarocks test` and cleans artifacts.
#
# Run `make help` to list the available targets.

# Quote one shell argument, including configured paths and command strings.
make_shell_quote = '$(subst ','"'"',$(1))'
make_shell_quote_value = '$(subst ','"'"',$(value $(1)))'

# Validation is an explicit native-toolchain profile, including runtime and
# provider dependencies. Choose it before Make expands the test graph.
TITAN_TEST_GOALS := test rock-test busted-test stdlib-test stdlib-busted-test \
	titan-stdlib-test titan-stdlib-test-build titan-stdlib-test-objects titan-stdlib-test-run \
	titan-native-coverage titan-native-coverage-build titan-native-coverage-run
TITAN_BUILD_PROFILE ?= $(if $(filter $(TITAN_TEST_GOALS),$(MAKECMDGOALS)),validation,production)
ifneq ($(TITAN_BUILD_PROFILE),production)
  ifneq ($(TITAN_BUILD_PROFILE),validation)
    $(error TITAN_BUILD_PROFILE must be production or validation)
  endif
endif
export TITAN_BUILD_PROFILE
TITAN_VALIDATION_FLAGS := -O0 -fno-lto
TITAN_PROFILE_NATIVE_FLAGS = $(if $(filter validation,$(TITAN_BUILD_PROFILE)),$(TITAN_VALIDATION_FLAGS))
# The compiler and test harness execute through Lua and native Lua modules.
TITAN_PROFILE_HOST_FLAGS = $(if $(filter validation,$(TITAN_BUILD_PROFILE)),-O2 -fno-lto)

# An explicit PREFIX always wins. After the initial `make lua`, discover the
# Titan-owned Lua on PATH without loading ambient Lua init/module overrides.
# Keep the launch path's spelling when it names that same physical prefix.
ifeq ($(origin PREFIX),undefined)
  _TITAN_PATH_PREFIX := $(shell sh $(call make_shell_quote,$(dir $(lastword $(MAKEFILE_LIST)))scripts/detect_lua_prefix.sh) 2>/dev/null)
  PREFIX := $(if $(filter validation,$(TITAN_BUILD_PROFILE)),$(CURDIR)/.lua-validation,$(if $(strip $(_TITAN_PATH_PREFIX)),$(_TITAN_PATH_PREFIX),/usr/local))
endif
override PREFIX := $(abspath $(PREFIX))

# Must match the Lua source layout resolved by titan-compiler/driver.lua and
# spec/support/helpers.lua, so don't override this unless those consumers move
# with it — the variable keeps the source/install paths below consistent.
TITAN_MAKEFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
LUA_VERSION      := 5.5.1
LUA_ABI_VERSION  ?= 5.5
LUA_DIR          := lua-$(LUA_VERSION)
LUA_SOURCE_READY := $(LUA_DIR)/src/lua.h
LUA_BIN          := $(PREFIX)/bin/lua
LUA_SOURCE_INSTALL_DIR := $(PREFIX)/src/$(LUA_DIR)
# LuaRocks already runs against a prepared PREFIX. Its native build must not
# download or reconstruct Lua merely because this checkout has no local tree.
# An installed header set selects its matching archive even if that archive is
# missing, so an incomplete SDK fails instead of mixing it with checkout Lua.
LUA_INSTALLED_SDK := $(and $(wildcard $(LUA_SOURCE_INSTALL_DIR)/lua.h),$(wildcard $(LUA_SOURCE_INSTALL_DIR)/lobject.h))
LUA_SDK_SOURCE_PATH := $(if $(LUA_INSTALLED_SDK),$(LUA_SOURCE_INSTALL_DIR),$(LUA_DIR)/src)
LUA_SDK_PREREQ := $(if $(LUA_INSTALLED_SDK),,lua)
# `titanc --lua` can explicitly select another built source tree. Only the
# installed PREFIX layout keeps liblua.a outside that source directory.
TITAN_RUNTIME_LUA_SOURCE_PATH ?= $(LUA_SDK_SOURCE_PATH)
TITAN_RUNTIME_LUA_LIB = $(if $(filter $(abspath $(LUA_SOURCE_INSTALL_DIR)),$(abspath $(TITAN_RUNTIME_LUA_SOURCE_PATH))),$(PREFIX)/lib/liblua.a,$(TITAN_RUNTIME_LUA_SOURCE_PATH)/liblua.a)
TITAN_RUNTIME_LUA_HEADERS = $(wildcard $(TITAN_RUNTIME_LUA_SOURCE_PATH)/*.h)

# LuaRocks is part of the standalone Titan installation. Pin it just like Lua
# and bundled libuv so the complete toolchain lives under the same PREFIX.
LUAROCKS_VERSION   := 3.13.0
LUAROCKS_DIR       := luarocks-$(LUAROCKS_VERSION)
LUAROCKS_TARBALL   := $(LUAROCKS_DIR).tar.gz
LUAROCKS_URL       := https://luarocks.github.io/luarocks/releases/$(LUAROCKS_TARBALL)
LUAROCKS_BIN       := $(PREFIX)/bin/luarocks

# The standard library is released against one audited libuv version.  The
# bundled PIC archive is required so a clean Linux/macOS checkout does not
# silently pick up whichever libuv happens to be installed on the host.
ifneq ($(strip $(LIBUV_MODE)),)
  $(error LIBUV_MODE is no longer supported; Titan always bundles patched libuv)
endif
LIBUV_VERSION     := 1.53.0
LIBUV_SRC_DIR     := libuv-v$(LIBUV_VERSION)
LIBUV_BUILD_DIR   := libuv-build
LIBUV_TARBALL     := $(LIBUV_SRC_DIR).tar.gz
LIBUV_URL         := https://dist.libuv.org/dist/v$(LIBUV_VERSION)/$(LIBUV_TARBALL)
LIBUV_SHA256      := cb0d6dd2128d5a95bd242c6cc982a24fe608fa93da57b6b4ec763b0018c53e64
LIBUV_BUNDLED_LIB := $(LIBUV_BUILD_DIR)/libuv.a
LIBUV_PATCH_FILE  := vendor/libuv/libuv-1.53.0-spawn-close.patch
LIBUV_EXTRACTED   := $(LIBUV_SRC_DIR)/.titan-extracted-spawn-close-v1
LIBUV_BUILD_TYPE  ?= $(if $(filter validation,$(TITAN_BUILD_PROFILE)),Debug,Release)
LIBUV_BUILD_PROFILE ?= static-pic-release-tests-off-v2
LIBUV_CMAKE_FLAGS := -DLIBUV_BUILD_SHARED=OFF -DBUILD_TESTING=OFF \
	-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
	-DCMAKE_BUILD_TYPE=$(LIBUV_BUILD_TYPE)
LIBUV_BUILD_CFLAGS ?= $(TITAN_PROFILE_NATIVE_FLAGS)

# HTTP parsing is always a private, statically carried standard-library
# dependency.  Release archives contain the generated C parser, so the build
# needs neither Node.js nor npm and can preserve Titan's configured CC/AR/
# RANLIB identity directly.
LLHTTP_VERSION       := 9.4.3
LLHTTP_RELEASE_TAG   := release/v$(LLHTTP_VERSION)
LLHTTP_SRC_DIR       := llhttp-release-v$(LLHTTP_VERSION)
LLHTTP_TARBALL       := $(LLHTTP_SRC_DIR).tar.gz
LLHTTP_URL           := https://github.com/nodejs/llhttp/archive/refs/tags/$(LLHTTP_RELEASE_TAG).tar.gz
LLHTTP_SHA256        := 1eb813c7437b31a87496a1cd3ed79f00746720f5e7e29c79b42c02cb69f36c39
LLHTTP_EXTRACTED     := $(LLHTTP_SRC_DIR)/.titan-extracted
LLHTTP_BUILD_DIR     := llhttp-build
LLHTTP_SOURCE_NAMES  := llhttp.c http.c api.c
LLHTTP_SOURCES       := $(addprefix $(LLHTTP_SRC_DIR)/src/,$(LLHTTP_SOURCE_NAMES))
LLHTTP_OBJECTS       := $(addprefix $(LLHTTP_BUILD_DIR)/,$(LLHTTP_SOURCE_NAMES:.c=.o))
LLHTTP_HEADER        := $(LLHTTP_SRC_DIR)/include/llhttp.h
LLHTTP_ARCHIVE       := $(LLHTTP_BUILD_DIR)/libtitan-llhttp.a
LLHTTP_CPPFLAGS      := -I$(abspath $(LLHTTP_SRC_DIR)/include)
LLHTTP_CFLAGS        := -std=c99 -fPIC -fvisibility=hidden
LLHTTP_BUILD_CFLAGS  ?=

# SQLite is always private standard-provider payload. Use the official release
# tarball's amalgamation directly; no configure/Tcl generation or system mode.
# Its SHA-256 was checked against the official download page's SHA3-256:
# 454e45f61c6bd75b7420e7190732dea03ce6639c63ada47bbc592f67fc340338.
SQLITE3_VERSION       := 3.53.4
SQLITE3_RELEASE       := 3530400
SQLITE3_SRC_DIR       := sqlite-autoconf-$(SQLITE3_RELEASE)
SQLITE3_TARBALL       := $(SQLITE3_SRC_DIR).tar.gz
SQLITE3_URL           := https://sqlite.org/2026/$(SQLITE3_TARBALL)
SQLITE3_SHA256        := 0e9483900e92cd5de8fd48d16bf9200145a61f7fd5be542a5ac81d8a9516eb9c
SQLITE3_EXTRACTED     := $(SQLITE3_SRC_DIR)/.titan-extracted
SQLITE3_BUILD_DIR     := sqlite3-build
SQLITE3_SOURCES       := $(SQLITE3_SRC_DIR)/sqlite3.c
SQLITE3_OBJECTS       := $(SQLITE3_BUILD_DIR)/sqlite3.o
SQLITE3_HEADER        := $(SQLITE3_SRC_DIR)/sqlite3.h
SQLITE3_ARCHIVE       := $(SQLITE3_BUILD_DIR)/libtitan-sqlite3.a
SQLITE3_CPPFLAGS      := -I$(abspath $(SQLITE3_SRC_DIR))
SQLITE3_CFLAGS        := -std=c99 -fPIC -fvisibility=hidden -DSQLITE_THREADSAFE=1
SQLITE3_BUILD_CFLAGS  ?=

# Prefer the system OpenSSL package. The optional pinned bundled release gives
# reproducible and instrumented builds their own native payload. System mode
# uses pkg-config for compilation/final linking and carries no host archive.
OPENSSL_MODE          ?= system
OPENSSL_VERSION       := 3.5.7
OPENSSL_MIN_VERSION   := 3.0.0
OPENSSL_SRC_DIR       := openssl-$(OPENSSL_VERSION)
OPENSSL_SRC_ABS       := $(abspath $(OPENSSL_SRC_DIR))
OPENSSL_TARBALL       := $(OPENSSL_SRC_DIR).tar.gz
OPENSSL_URL           := https://github.com/openssl/openssl/releases/download/openssl-$(OPENSSL_VERSION)/$(OPENSSL_TARBALL)
OPENSSL_SHA256        := a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8
OPENSSL_EXTRACTED     := $(OPENSSL_SRC_DIR)/.titan-extracted
OPENSSL_BUILD_DIR     := openssl-build
OPENSSL_BUILD_COMPLETE := $(OPENSSL_BUILD_DIR)/.titan-openssl-build-complete
OPENSSL_BUNDLED_LIBSSL := $(OPENSSL_BUILD_DIR)/libssl.a
OPENSSL_BUNDLED_LIBCRYPTO := $(OPENSSL_BUILD_DIR)/libcrypto.a
OPENSSL_PKG_CONFIG    ?= pkg-config
OPENSSL_PERL          ?= perl
OPENSSL_BUILD_CFLAGS  ?=
OPENSSL_EXTRA_CONFIGURE_FLAGS ?=
# Keep the embedded library self-contained and deterministic.  In particular,
# no-pinshared is required when static libcrypto is embedded in titan.so.
OPENSSL_CONFIGURE_FLAGS := --api=3.0 no-shared no-pinshared no-atexit \
	no-apps no-tests no-docs no-legacy no-comp no-dso no-module no-quic \
	no-zlib no-zstd no-brotli no-autoload-config \
	$(OPENSSL_EXTRA_CONFIGURE_FLAGS)
OPENSSL_REQUIRED_CFLAGS := $(if $(filter validation,$(TITAN_BUILD_PROFILE)),$(TITAN_VALIDATION_FLAGS),-O2) -g -fPIC -fvisibility=hidden

HOST_OS   := $(shell uname -s)
HOST_ARCH := $(shell uname -m)

ifeq ($(OPENSSL_MODE),bundled)
  OPENSSL_LIBS := $(OPENSSL_BUNDLED_LIBSSL) $(OPENSSL_BUNDLED_LIBCRYPTO)
  OPENSSL_CPPFLAGS := -I$(abspath $(OPENSSL_BUILD_DIR)/include) \
	-I$(abspath $(OPENSSL_SRC_DIR)/include) -DOPENSSL_API_COMPAT=30000
  OPENSSL_EXTRA_OBJECTS := $(OPENSSL_LIBS)
  # no-dso and the explicitly disabled compression backends leave pthread as
  # the only platform library outside the two carried archives on supported
  # Linux/macOS builds.  The final validation link checks this assumption.
  OPENSSL_PROVIDER_LDFLAGS := -lpthread
else ifeq ($(OPENSSL_MODE),system)
  OPENSSL_LIBS :=
  OPENSSL_CPPFLAGS = $(strip $(shell $(OPENSSL_PKG_CONFIG) --cflags openssl 2>/dev/null)) \
	-DOPENSSL_API_COMPAT=30000
  OPENSSL_EXTRA_OBJECTS :=
  OPENSSL_PROVIDER_LDFLAGS = $(strip $(shell $(OPENSSL_PKG_CONFIG) --libs openssl 2>/dev/null))
else
  OPENSSL_LIBS :=
  OPENSSL_CPPFLAGS :=
  OPENSSL_EXTRA_OBJECTS :=
  OPENSSL_PROVIDER_LDFLAGS :=
endif

# Libuv always joins the compiler's ordered -X payload, so both canonical
# provider forms carry the same patched native implementation.
LIBUV_LIB           := $(LIBUV_BUNDLED_LIB)
LIBUV_INCLUDE_DIR   := $(LIBUV_SRC_DIR)/include
LIBUV_CPPFLAGS      := -I$(LIBUV_INCLUDE_DIR)
LIBUV_CFLAGS        := -fno-strict-aliasing
LIBUV_EXTRA_OBJECTS := $(LIBUV_LIB)
ifeq ($(HOST_OS),Darwin)
  LIBUV_LINK_LIBS := pthread
else ifeq ($(HOST_OS),Linux)
  LIBUV_CPPFLAGS  += -D_GNU_SOURCE
  # Linux libuv uses pthreads and clock APIs from librt on older glibc.
  LIBUV_LINK_LIBS := pthread rt
else
  LIBUV_LINK_LIBS :=
endif
LIBUV_LDFLAGS := $(addprefix -l,$(LIBUV_LINK_LIBS))
LIBUV_PROVIDER_LDFLAGS := $(LIBUV_LDFLAGS)

# The Lua build target ("linux-readline", "macosx", ...) is taken from `uname`
# but can be overridden on the command line: `make lua LUA_PLATFORM=bsd`.
ifndef LUA_PLATFORM
  ifeq ($(HOST_OS),Darwin)
    LUA_PLATFORM := macosx
  else ifeq ($(HOST_OS),Linux)
    LUA_PLATFORM := linux-readline
  else
    LUA_PLATFORM := linux
  endif
endif

# Kept in sync with titan-compiler/driver.lua (driver.CC, the opt-in
# driver.CLANG_FORMAT, and driver.CFLAGS).
CC           ?= cc
AR           ?= ar
RANLIB       ?= ranlib
CLANG_FORMAT ?= clang-format
LUA_CC    ?= $(CC)
LUA_AR    ?= $(AR) rcu
LUA_RANLIB ?= $(RANLIB)
TITAN_DEFAULT_OPTFLAGS := $(if $(filter validation,$(TITAN_BUILD_PROFILE)),$(TITAN_VALIDATION_FLAGS),-O3)
ifeq ($(TITAN_BUILD_PROFILE),production)
  ifeq ($(HOST_OS),Linux)
    TITAN_DEFAULT_OPTFLAGS += -flto=auto -ffat-lto-objects
  endif
endif
TITAN_DEFAULT_DEBUGFLAGS := -g
ifeq ($(TITAN_BUILD_PROFILE),production)
  ifeq ($(origin CFLAGS),undefined)
    # Probe the configured command, including wrappers; Clang also defines
    # __GNUC__, so its own identity takes precedence.
    TITAN_CC_MACROS := $(shell $(CC) -dM -E -x c /dev/null 2>/dev/null)
    ifneq ($(filter __clang__,$(TITAN_CC_MACROS)),)
      TITAN_DEFAULT_DEBUGFLAGS := -gline-tables-only -fdebug-info-for-profiling
    else ifneq ($(filter __GNUC__,$(TITAN_CC_MACROS)),)
      TITAN_DEFAULT_DEBUGFLAGS := -g1
    endif
  endif
endif
CFLAGS    ?= --std=c99 $(TITAN_DEFAULT_OPTFLAGS) -Wall -Wno-unused-but-set-variable -Wno-unused-function -fPIC $(TITAN_DEFAULT_DEBUGFLAGS)
LUA_MYCFLAGS  ?= -fPIC $(TITAN_PROFILE_HOST_FLAGS)
LUA_MYLDFLAGS ?= $(TITAN_PROFILE_HOST_FLAGS)
LUA_MYLIBS    ?=
LIBBT_CFLAGS  ?= -fPIC -g $(if $(filter validation,$(TITAN_BUILD_PROFILE)),$(TITAN_VALIDATION_FLAGS),-O2)
TITAN_EXTRA_CPPFLAGS ?=
TITAN_EXTRA_CFLAGS   ?=
TITAN_EXTRA_LDFLAGS  ?=
TITAN_NO_LINE_DIRECTIVES ?=
export CLANG_FORMAT TITAN_EXTRA_CPPFLAGS TITAN_EXTRA_CFLAGS \
	TITAN_EXTRA_LDFLAGS TITAN_NO_LINE_DIRECTIVES
# Keep every Titan compiler output in a separate, removable tree. Native
# runtime and dependency builds retain their existing build directories.
TITAN_OUTPUT_DIR ?= out

RUNTIME_O := titan-runtime/titan.o
MINICORO_O := titan-runtime/minicoro.o
LTITANLIB_O := titan-runtime/ltitanlib.o
TITAN_RUNTIME_OBJECTS := $(RUNTIME_O) $(MINICORO_O)
TITAN_RUNTIME_LIB := titan-runtime/libtitan.a
TITAN_SDK_ROOT_HEADERS := titan-runtime/minicoro.h titan-runtime/titan.h
TITAN_SDK_NAMESPACED_HEADERS := titan-runtime/titan/ffi.h

# Titan's public PEG module embeds one audited LPegLabel engine instead of
# depending on the compiler-owned lpeglabel.so at run time. Keep this native
# payload separate from libtitan.a and the installed SDK: it is a private
# standard-library -X input. These definitions precede STDLIB_EXTRA_OBJECTS so
# that its simply-expanded payload can place the archive explicitly.
LPEGLABEL_VERSION := 1.6.2-1
LPEGLABEL_COMMIT := 912b0b9e8641074408ffc2259e069b188e0c717b
LPEGLABEL_VENDOR_DIR ?= vendor/lpeglabel
LPEGLABEL_BUILD_DIR ?= lpeglabel-build
LPEGLABEL_SOURCE_NAMES := lplcap.c lplcode.c lplprint.c lpltree.c lplvm.c
LPEGLABEL_HEADER_NAMES := lplcap.h lplcode.h lplprint.h lpltree.h \
	lpltypes.h lplvm.h titan_lpeglabel_namespace.h titan_lpeglabel.h
LPEGLABEL_SOURCES := $(addprefix $(LPEGLABEL_VENDOR_DIR)/,$(LPEGLABEL_SOURCE_NAMES))
LPEGLABEL_HEADERS := $(addprefix $(LPEGLABEL_VENDOR_DIR)/,$(LPEGLABEL_HEADER_NAMES))
LPEGLABEL_OBJECTS := $(addprefix $(LPEGLABEL_BUILD_DIR)/,\
	$(LPEGLABEL_SOURCE_NAMES:.c=.o))
LPEGLABEL_ARCHIVE := $(LPEGLABEL_BUILD_DIR)/libtitan-lpeglabel.a
LPEGLABEL_CPPFLAGS := -I$(abspath $(LPEGLABEL_VENDOR_DIR))
LPEGLABEL_CFLAGS := -std=c99 -fPIC -fvisibility=hidden
LPEGLABEL_LUA_HEADERS = $(ROCK_LUA_HEADERS)
# Keep parser execution optimized even when generic Titan extras select O0.
LPEGLABEL_BUILD_CFLAGS ?= $(TITAN_PROFILE_HOST_FLAGS)

UV_TITAN_SOURCES := \
	titan/uv/uv.titan \
	titan/uv/address.titan \
	titan/uv/callbacks.titan \
	titan/uv/capabilities.titan \
	titan/uv/constants.titan \
	titan/uv/data.titan \
	titan/uv/dll.titan \
	titan/uv/dns.titan \
	titan/uv/fd.titan \
	titan/uv/identifiers.titan \
	titan/uv/pipe_tty.titan \
	titan/uv/platform_constants.titan \
	titan/uv/process.titan \
	titan/uv/startup.titan \
	titan/uv/stream_ops.titan \
	titan/uv/stream_owners.titan \
	titan/uv/sync.titan \
	titan/uv/tcp.titan \
	titan/uv/threading.titan \
	titan/uv/udp.titan \
	titan/uv/utilities.titan
UV_TITAN_HEADERS := \
	titan/uv/address-native.h \
	titan/uv/callback.h \
	titan/uv/data_native.h \
	titan/uv/fd-native.h \
	titan/uv/network-native.h \
	titan/uv/platform-constants.h \
	titan/uv/sync_storage.h \
	titan/uv/thread-native.h \
	titan/uv/utility_bits.h \
	titan/uv/version-native.h \
	titan/uv/work-data.h
STDLIB_HTTP_SOURCES := titan/http/http.titan titan/http/client.titan \
	titan/http/headers.titan titan/http/native.titan \
	titan/http/server.titan titan/http/upgrade.titan
SQLITE3_TITAN_SOURCES := titan/sqlite3/sqlite3.titan titan/sqlite3/bindings.titan \
	titan/sqlite3/row.titan titan/sqlite3/worker.titan
SQLITE3_TITAN_HEADERS := titan/sqlite3/native.h
STRING_TITAN_HEADERS := titan/string/format_native.h
WEBSOCKET_TITAN_SOURCES := titan/websocket/websocket.titan titan/websocket/handshake.titan \
	titan/websocket/connection.titan titan/websocket/frames.titan \
	titan/websocket/utf8.titan titan/websocket/native.titan
JSON_TITAN_SOURCES := titan/json/json.titan titan/json/parser.titan \
	titan/json/decoder.titan titan/json/writer.titan titan/json/numbers.titan
STDLIB_MODULES := coroutine uv async timer io fs net ssl url http websocket os path peg string \
	math lua iteration gc test reflect sqlite3 json
STDLIB_SOS     := $(addsuffix .so,$(STDLIB_MODULES))
STDLIB_QUALIFIED_SOS := $(addprefix titan/,$(STDLIB_SOS))
STDLIB_ROOTS := titan.coroutine titan.uv titan.async titan.timer \
	titan.io titan.fs titan.net titan.ssl titan.url titan.http titan.websocket titan.os titan.path \
	titan.peg titan.string \
	titan.math titan.lua titan.iteration titan.gc titan.test titan.reflect titan.sqlite3 titan.json
STDLIB_TITAN_SOURCES := titan/coroutine.titan $(UV_TITAN_SOURCES) \
	titan/async.titan titan/timer.titan titan/io.titan titan/fs.titan \
	titan/net.titan titan/ssl.titan titan/url.titan \
	$(STDLIB_HTTP_SOURCES) $(WEBSOCKET_TITAN_SOURCES) titan/os.titan titan/path.titan \
	titan/peg/peg.titan titan/peg/combinators.titan \
	titan/peg/native.titan \
	titan/peg/relabel.titan titan/peg/relabel_parser.titan \
	titan/string/string.titan titan/string/bytes.titan \
	titan/string/format.titan titan/string/pack.titan \
	titan/string/regex_api.titan titan/string/regex_compile.titan \
	titan/string/regex_parser.titan \
	titan/math.titan titan/lua.titan titan/iteration.titan titan/gc.titan \
	titan/test.titan titan/reflect.titan $(SQLITE3_TITAN_SOURCES) \
	$(JSON_TITAN_SOURCES)
STDLIB_GENERATED_FFI_HEADERS := $(addprefix $(TITAN_OUTPUT_DIR)/,$(addsuffix .ffi.h, \
	$(addprefix titan/,$(filter-out uv http websocket peg string sqlite3 json,$(STDLIB_MODULES))) \
	titan/uv/uv titan/http/http titan/websocket/websocket titan/peg/peg titan/string/string \
	titan/sqlite3/sqlite3 titan/json/json))
STDLIB_GENERATED_FOREIGN_HEADERS := $(STDLIB_GENERATED_FFI_HEADERS) \
	$(addprefix $(TITAN_OUTPUT_DIR)/,titan/coroutine.titan.h \
	titan/uv/uv.titan.h titan/http/http.titan.h \
	titan/sqlite3/sqlite3.titan.h)
# One native compilation unit per logical module, including folder ensembles.
# This reviewed import graph owns rebuild propagation and parallel ordering;
# titanc's object fast path deliberately does not track dependency freshness.
STDLIB_STEM_uv := titan/uv/uv
STDLIB_STEM_http := titan/http/http
STDLIB_STEM_websocket := titan/websocket/websocket
STDLIB_STEM_peg := titan/peg/peg
STDLIB_STEM_string := titan/string/string
STDLIB_STEM_sqlite3 := titan/sqlite3/sqlite3
STDLIB_STEM_json := titan/json/json
stdlib_stem = $(TITAN_OUTPUT_DIR)/$(if $(STDLIB_STEM_$(1)),$(STDLIB_STEM_$(1)),titan/$(1))
stdlib_outputs = $(call stdlib_stem,$(1)).o $(call stdlib_stem,$(1)).c $(filter $(call stdlib_stem,$(1)).%,$(STDLIB_GENERATED_FOREIGN_HEADERS))
STDLIB_MODULE_OBJECTS := $(foreach module,$(STDLIB_MODULES),$(call stdlib_stem,$(module)).o)
STDLIB_IMPORTS_coroutine :=
STDLIB_IMPORTS_uv := iteration
STDLIB_IMPORTS_async := uv coroutine string
STDLIB_IMPORTS_timer := async uv
STDLIB_IMPORTS_io := os string
STDLIB_IMPORTS_fs := async uv string
STDLIB_IMPORTS_net := async uv string
STDLIB_IMPORTS_ssl := async fs net string gc uv
STDLIB_IMPORTS_url := peg string
STDLIB_IMPORTS_http := async io math net ssl string timer url uv
STDLIB_IMPORTS_websocket := async gc http io iteration net ssl string timer url uv
STDLIB_IMPORTS_os := async uv iteration string
STDLIB_IMPORTS_path := string
STDLIB_IMPORTS_peg := gc
STDLIB_IMPORTS_string := peg gc
STDLIB_IMPORTS_math :=
STDLIB_IMPORTS_lua := async fs io string
STDLIB_IMPORTS_iteration :=
STDLIB_IMPORTS_gc :=
STDLIB_IMPORTS_test :=
STDLIB_IMPORTS_reflect := iteration lua string
STDLIB_IMPORTS_sqlite3 := async uv reflect string math
STDLIB_IMPORTS_json := reflect string math peg iteration
STDLIB_SHIMS := $(addprefix $(TITAN_OUTPUT_DIR)/,titan/coroutine.lua titan/uv.lua titan/async.lua \
	titan/timer.lua titan/io.lua titan/fs.lua titan/net.lua titan/ssl.lua \
	titan/url.lua titan/http.lua titan/websocket.lua titan/os.lua titan/path.lua \
	titan/peg.lua titan/string.lua titan/math.lua titan/lua.lua \
	titan/iteration.lua titan/gc.lua titan/test.lua titan/reflect.lua titan/sqlite3.lua titan/json.lua)
STDLIB_CONTAINER := $(TITAN_OUTPUT_DIR)/titan.so
STDLIB_STATIC_ARCHIVE := $(TITAN_OUTPUT_DIR)/titan.a
STDLIB_PROVIDER_OUTPUTS := $(STDLIB_CONTAINER) $(STDLIB_STATIC_ARCHIVE)
STDLIB_EXTRA_OBJECTS := $(LTITANLIB_O) $(LPEGLABEL_ARCHIVE) \
	$(LIBUV_EXTRA_OBJECTS) $(LLHTTP_ARCHIVE) $(SQLITE3_ARCHIVE) $(OPENSSL_EXTRA_OBJECTS)
STDLIB_LPEGLABEL_CPPFLAGS := $(LPEGLABEL_CPPFLAGS)
STDLIB_HTTP_CPPFLAGS := $(LLHTTP_CPPFLAGS)
STDLIB_SQLITE3_CPPFLAGS := $(SQLITE3_CPPFLAGS)
STDLIB_OPENSSL_CPPFLAGS := $(OPENSSL_CPPFLAGS)
STDLIB_OPENSSL_LDFLAGS := $(OPENSSL_PROVIDER_LDFLAGS)
STDLIB_LICENSES := LICENSES/libuv-LICENSE LICENSES/libuv-LICENSE-extra \
	LICENSES/libuv-tree-LICENSE LICENSES/libuv-inet-LICENSE \
	LICENSES/lpeglabel-LICENSE LICENSES/lpeg-LICENSE \
	LICENSES/lpeg-patterns-LICENSE \
	LICENSES/ta-regex-LICENSE LICENSES/lua-LICENSE \
	LICENSES/llhttp-LICENSE LICENSES/sqlite3-LICENSE LICENSES/openssl-LICENSE LICENSES/go-LICENSE LICENSES/libbacktrace-LICENSE
TITAN_BOOTSTRAP_SO := titan-runtime/bootstrap/titan.so
STDLIB_BOOTSTRAP_PREREQ := $(TITAN_BOOTSTRAP_SO)
ROCK_LUA_INCDIR ?= $(PREFIX)/include
ROCK_LUA_HEADERS = $(addprefix $(ROCK_LUA_INCDIR)/,lua.h luaconf.h lauxlib.h)
# Stock LuaRocks supplies optimized dependency flags. Apply the Titan payload
# profile here; explicit TITAN_EXTRA_CFLAGS still follow it at compile sites.
ROCK_CFLAGS     ?= -O2 -fPIC
override ROCK_CFLAGS := $(strip $(ROCK_CFLAGS) $(TITAN_PROFILE_NATIVE_FLAGS))
ROCK_LD         ?= $(CC)
ifeq ($(HOST_OS),Darwin)
  ROCK_LIBFLAG  ?= -bundle -undefined dynamic_lookup
else
  ROCK_LIBFLAG  ?= -shared
endif
ROCKS_TREE      ?=
ROCK_TITANC     ?=
ROCK_LUA        ?= $(LUA_BIN)
STDLIB_USE_INSTALLED_RUNTIME ?= $(if $(wildcard $(TITAN_INSTALL_TREE)/bin/titanc),1,0)
TITAN_ROCKS_ROOT ?=
export TITAN_ROCKS_ROOT
TITAN_LUA ?= $(or $(realpath $(ROCK_LUA)),$(ROCK_LUA))
# Stdlib development uses the deployed compiler and its matching SDK once
# installed. The checkout compiler remains the bootstrap path and an explicit
# option through STDLIB_USE_INSTALLED_RUNTIME=0. Canonicalize only these build
# inputs, so a LuaRocks /var/home root and a PATH /home alias select one SDK.
STDLIB_INSTALLED_ROOT = $(or $(realpath $(TITAN_INSTALL_TREE)),$(abspath $(TITAN_INSTALL_TREE)))
STDLIB_ROCKS_ROOT = $(if $(strip $(TITAN_ROCKS_ROOT)),$(or $(realpath $(TITAN_ROCKS_ROOT)),$(abspath $(TITAN_ROCKS_ROOT))),$(if $(filter 1,$(STDLIB_USE_INSTALLED_RUNTIME)),$(STDLIB_INSTALLED_ROOT)))
# Dependencies may live in a separate LuaRocks tree. The source compiler and
# its private native support must still take precedence over any installed Titan.
SOURCE_COMPILER_SETUP = local root=os.getenv("ROCKS_TREE"); \
	if root and root~="" then \
	package.path=root .. "/share/lua/5.5/?.lua;" .. root .. "/share/lua/5.5/?/init.lua;" .. package.path; \
	package.cpath=root .. "/lib/lua/5.5/?.so;" .. package.cpath end; \
	package.path="./?.lua;./?/init.lua;" .. package.path; \
	package.cpath="./titan-runtime/bootstrap/?.so;" .. package.cpath
TITANC ?= $(if $(filter 1,$(STDLIB_USE_INSTALLED_RUNTIME)),$(call make_shell_quote,$(STDLIB_INSTALLED_ROOT)/bin/titanc),$(call make_shell_quote,$(TITAN_LUA)) -E -e $(call make_shell_quote,$(SOURCE_COMPILER_SETUP)) ./titanc --lua $(call make_shell_quote,$(abspath $(TITAN_RUNTIME_LUA_SOURCE_PATH))))

# Standard modules have one installed pathname. PREFIX owns Lua; ROCKS_TREE
# owns these Titan artifacts when it is supplied. The source-tree
# install-stdlib target can publish to PREFIX when ROCKS_TREE is omitted;
# it is not part of an installed Titan tree.
TITAN_INSTALL_TREE         := $(if $(strip $(ROCKS_TREE)),$(ROCKS_TREE),$(PREFIX))
STDLIB_INSTALL_STAGE       ?= $(abspath $(TITAN_OUTPUT_DIR))
# CI may preserve the exact provider and its generated C/object
# pairs for failure-only sanitizer symbolization before later tests can replace
# those outputs. Ordinary builds leave this empty and pay no snapshot cost.
TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT ?=
# ABI compatibility is independent from the semantic compiler/stdlib release.
# Installed library paths use the release's derived major/minor component so
# patch releases share one provider namespace.
TITAN_ABI_VERSION          := 2
TITAN_VERSION              := 0.6.0
TITAN_VERSION_COMPONENTS   := $(subst ., ,$(TITAN_VERSION))
TITAN_LIBRARY_VERSION      := $(word 1,$(TITAN_VERSION_COMPONENTS)).$(word 2,$(TITAN_VERSION_COMPONENTS))
TITAN_LIBRARY_VERSION_SUFFIX := _$(subst .,_,$(TITAN_LIBRARY_VERSION))
TITAN_STDLIB_VERSION_DIR   ?= $(TITAN_INSTALL_TREE)/lib/titan/$(TITAN_LIBRARY_VERSION)
TITAN_CANONICAL_SUPPORT_SO ?= $(TITAN_STDLIB_VERSION_DIR)/titan.so
TITAN_CANONICAL_STATIC_ARCHIVE ?= $(TITAN_STDLIB_VERSION_DIR)/titan.a
TITAN_STDLIB_DIR           ?= $(TITAN_INSTALL_TREE)/lib/titan/$(TITAN_LIBRARY_VERSION)/titan
TITAN_STDLIB_LUA_DIR       ?= $(TITAN_INSTALL_TREE)/share/lua/$(LUA_ABI_VERSION)/titan
LUA_LIBDIR                 ?= $(TITAN_INSTALL_TREE)/lib/lua/$(LUA_ABI_VERSION)
TITAN_STDLIB_LEGACY_DIR    ?= $(LUA_LIBDIR)/titan/stdlib$(TITAN_LIBRARY_VERSION_SUFFIX)
TITAN_SHARE_DIR            ?= $(TITAN_INSTALL_TREE)/share/titan

# libbacktrace is cloned + built into ./libbacktrace (gitignored), mirroring the
# ./lua-5.5.1 tree. The generated C and the runtime include its backtrace.h and
# link its static archive (driver.lua references ./libbacktrace/.libs/...).
LIBBT_DIR := libbacktrace
LIBBT_URL ?= https://github.com/ianlancetaylor/libbacktrace.git
LIBBT_LIB := $(LIBBT_DIR)/.libs/libbacktrace.a
LIBBT_CLONE_STAMP := $(LIBBT_DIR)/.titan-cloned
STDLIB_COMPLETION_STAMP := $(TITAN_OUTPUT_DIR)/.titan-stdlib-complete

# These wrappers indirectly launch recursive Make processes. The `+` recipe
# marker preserves the parent jobserver; this guard keeps that marker from
# turning Make's dry-run, query, or touch modes into real wrapper execution.
RECURSIVE_WRAPPER_GUARD = flags=$${MAKEFLAGS%% *}; case "$$flags" in -*) ;; *q*) exit 1 ;; *n*|*t*) exit 0 ;; esac;

.PHONY: all help lua luarocks libbacktrace libuv libuv-config llhttp \
	check-llhttp-tools sqlite3 check-sqlite3-tools openssl openssl-config check-openssl-tools \
	check-system-openssl invalid-openssl-mode lpeglabel \
	check-libuv-tools runtime \
	stage-titan-bootstrap install-compiler-sdk install-titan-sdk publish-titan-sdk stdlib stdlib-objects install-stdlib \
	install publish-stdlib \
	rock-test test rock-build \
	examples clean clean-stdlib clean-lua clean-luarocks clean-libbacktrace clean-libuv \
	clean-llhttp clean-sqlite3 clean-openssl \
	distclean FORCE

FORCE:

help: ## Show this help
	@echo "Titan developer tasks:"
	@grep -h -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "make all and make stdlib bundle patched libuv $(LIBUV_VERSION) and llhttp"
	@echo "$(LLHTTP_VERSION). OpenSSL uses pkg-config's system package by default"
	@echo "(>= $(OPENSSL_MIN_VERSION)); OPENSSL_MODE=bundled builds $(OPENSSL_VERSION)."
	@echo "All builds require a C compiler. titanc --pretty-print additionally needs"
	@echo "clang-format. Bundled dependencies need CMake, Perl, git, tar, curl/wget,"
	@echo "and sha256sum/shasum (macOS: xcode-select --install; brew install cmake)."
	@echo "Lua's default Linux/macOS targets require system Readline development files."
	@echo "Ubuntu/Debian: libreadline-dev libssl-dev pkg-config; Fedora:"
	@echo "readline-devel openssl-devel pkgconf-pkg-config; macOS: brew install"
	@echo "readline openssl@3 pkgconf. Override LUA_PLATFORM to omit Readline."
	@echo "llhttp and SQLite $(SQLITE3_VERSION) are always bundled."
	@echo "For a standalone installation, choose one writable PREFIX and run:"
	@echo "  make lua PREFIX=/path"
	@echo "  export PATH=/path/bin:\$$PATH"
	@echo "  make luarocks && luarocks make"
	@echo "Later Make commands detect PREFIX from Titan's Lua on PATH."

include $(TITAN_MAKEFILE_DIR)scripts/install_compiler.mk

libuv: ## Build the pinned bundled libuv with Titan's Unix cleanup correction

# Lua and LuaRocks preparation deliberately checks only their installed programs.
# Clean the upstream source tree yourself before changing build inputs.
lua: ## Build and install Lua unless PREFIX/bin/lua already exists
	@set -e; if test ! -f "$(LUA_BIN)"; then \
	  test -f "$(LUA_SOURCE_READY)" || { \
	    echo "ERROR: Lua source is missing; initialize the Lua submodule." >&2; \
	    echo "Run: git submodule update --init --recursive" >&2; exit 1; \
	  }; \
	  $(MAKE) -C "$(LUA_DIR)" $(LUA_PLATFORM) \
	    TITAN_LIBRARY_VERSION="$(TITAN_LIBRARY_VERSION)" PREFIX="$(PREFIX)" \
	    CC=$(call make_shell_quote,$(LUA_CC)) \
	    AR=$(call make_shell_quote,$(LUA_AR)) \
	    RANLIB=$(call make_shell_quote,$(LUA_RANLIB)) \
	    MYCFLAGS=$(call make_shell_quote,$(LUA_MYCFLAGS)) \
	    MYLDFLAGS=$(call make_shell_quote,$(LUA_MYLDFLAGS)) \
	    MYLIBS=$(call make_shell_quote,$(LUA_MYLIBS)); \
	  $(MAKE) -C "$(LUA_DIR)" install \
	    TITAN_LIBRARY_VERSION="$(TITAN_LIBRARY_VERSION)" PREFIX="$(PREFIX)"; \
	fi

luarocks: lua ## Install LuaRocks unless PREFIX/bin/luarocks already exists
	@set -e; if test ! -f "$(LUAROCKS_BIN)"; then \
	  if test ! -f "$(LUAROCKS_DIR)/configure"; then \
	    $(MAKE) --no-print-directory -f $(call make_shell_quote,$(firstword $(MAKEFILE_LIST))) "$(LUAROCKS_TARBALL)"; \
	    tar zxf "$(LUAROCKS_TARBALL)"; \
	  fi; \
	  (cd "$(LUAROCKS_DIR)" && ./configure --prefix="$(PREFIX)" \
	    --rocks-tree="$(PREFIX)" --with-lua="$(PREFIX)" --force-config); \
	  $(MAKE) -C "$(LUAROCKS_DIR)" LUA_DIR="$(PREFIX)"; \
	  $(MAKE) -C "$(LUAROCKS_DIR)" install LUA_DIR="$(PREFIX)"; \
	fi

$(LUAROCKS_TARBALL):
	@echo "==> Downloading $(LUAROCKS_URL)"
	@if command -v curl >/dev/null 2>&1; then \
	  curl -fL -o "$@" "$(LUAROCKS_URL)"; \
	elif command -v wget >/dev/null 2>&1; then \
	  wget -O "$@" "$(LUAROCKS_URL)"; \
	else \
	  echo "ERROR: need 'curl' or 'wget' to download LuaRocks" >&2; exit 1; \
	fi

libbacktrace: $(LIBBT_LIB) ## Clone and build the bundled libbacktrace source tree

$(LIBBT_CLONE_STAMP):
	@if [ ! -d "$(LIBBT_DIR)" ]; then \
	  echo "==> Cloning $(LIBBT_URL)"; \
	  git clone "$(LIBBT_URL)" "$(LIBBT_DIR)"; \
	fi
	@test -x "$(LIBBT_DIR)/configure" || { \
	  echo "ERROR: $(LIBBT_DIR) is not a complete libbacktrace source tree" >&2; \
	  exit 1; \
	}
	@touch "$@"

$(LIBBT_LIB): $(LIBBT_CLONE_STAMP)
	@echo "==> Building libbacktrace (configure + make, $(LIBBT_CFLAGS))"
	cd "$(LIBBT_DIR)" && \
		./configure CC=$(call make_shell_quote,$(CC)) \
			AR=$(call make_shell_quote,$(AR)) \
			RANLIB=$(call make_shell_quote,$(RANLIB)) \
			CFLAGS=$(call make_shell_quote,$(LIBBT_CFLAGS))
	@if test -f "$(LIBBT_DIR)/Makefile"; then $(MAKE) -C "$(LIBBT_DIR)"; fi

libuv: $(LIBUV_LIB)

check-libuv-tools:
	@missing=0; \
	if ! command -v "$(firstword $(CC))" >/dev/null 2>&1; then \
	  echo "ERROR: C compiler '$(firstword $(CC))' was not found." >&2; \
	  echo "  Ubuntu/Debian: sudo apt-get install build-essential" >&2; \
	  echo "  Fedora: sudo dnf install gcc make" >&2; \
	  echo "  macOS: xcode-select --install" >&2; missing=1; \
	fi; \
	if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then \
	  echo "ERROR: need 'curl' or 'wget' to download $(LIBUV_TARBALL)." >&2; \
	  echo "  Ubuntu/Debian: sudo apt-get install curl" >&2; \
	  echo "  Fedora: sudo dnf install curl" >&2; \
	  echo "  macOS: curl is supplied by the operating system" >&2; missing=1; \
	fi; \
	if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then \
	  echo "ERROR: need 'sha256sum' or 'shasum' to verify $(LIBUV_TARBALL)." >&2; \
	  echo "  Linux: install the coreutils package" >&2; \
	  echo "  macOS: install Perl/shasum (normally supplied by macOS)" >&2; missing=1; \
	fi; \
	if ! command -v cmake >/dev/null 2>&1; then \
	  echo "ERROR: CMake is required to build bundled libuv." >&2; \
	  echo "  Ubuntu/Debian: sudo apt-get install cmake" >&2; \
	  echo "  Fedora: sudo dnf install cmake" >&2; \
	  echo "  macOS: brew install cmake" >&2; missing=1; \
	fi; \
	if ! command -v tar >/dev/null 2>&1; then \
	  echo "ERROR: 'tar' is required to extract $(LIBUV_TARBALL)." >&2; \
	  echo "  Linux: install the tar package" >&2; \
	  echo "  macOS: tar is supplied by the operating system" >&2; missing=1; \
	fi; \
	if ! command -v git >/dev/null 2>&1; then \
	  echo "ERROR: 'git' is required to apply the bundled libuv correction." >&2; missing=1; \
	fi; \
	if [ "$(HOST_OS)" != Linux ] && [ "$(HOST_OS)" != Darwin ]; then \
	  echo "ERROR: bundled libuv is currently supported only on Linux and macOS (host: $(HOST_OS)/$(HOST_ARCH))." >&2; \
	  missing=1; \
	fi; \
	test "$$missing" -eq 0

$(LIBUV_TARBALL):
	@$(MAKE) --no-print-directory check-libuv-tools
	@echo "==> Downloading $(LIBUV_URL)"
	@if command -v curl >/dev/null 2>&1; then \
	  curl -fL -o "$@" "$(LIBUV_URL)"; \
	elif command -v wget >/dev/null 2>&1; then \
	  wget -O "$@" "$(LIBUV_URL)"; \
	else \
	  echo "ERROR: need 'curl' or 'wget' to download libuv" >&2; exit 1; \
	fi

$(LIBUV_EXTRACTED): $(LIBUV_TARBALL) $(LIBUV_PATCH_FILE)
	@$(MAKE) --no-print-directory check-libuv-tools
	@echo "==> Verifying SHA-256 for $(LIBUV_TARBALL)"
	@if command -v sha256sum >/dev/null 2>&1; then \
	  printf '%s  %s\n' "$(LIBUV_SHA256)" "$(LIBUV_TARBALL)" | sha256sum -c -; \
	elif command -v shasum >/dev/null 2>&1; then \
	  printf '%s  %s\n' "$(LIBUV_SHA256)" "$(LIBUV_TARBALL)" | shasum -a 256 -c -; \
	else \
	  echo "ERROR: need 'sha256sum' or 'shasum' to verify libuv" >&2; exit 1; \
	fi || { \
	  echo "ERROR: checksum mismatch for $(LIBUV_TARBALL); removing the corrupt download." >&2; \
	  rm -f "$(LIBUV_TARBALL)"; exit 1; \
	}
	@echo "==> Extracting $(LIBUV_TARBALL)"
	rm -rf "$(LIBUV_SRC_DIR)"
	tar zxf "$(LIBUV_TARBALL)"
	@test -d "$(LIBUV_SRC_DIR)" || { \
	  echo "ERROR: $(LIBUV_TARBALL) did not contain $(LIBUV_SRC_DIR)." >&2; exit 1; \
	}
	git apply --directory="$(LIBUV_SRC_DIR)" "$(LIBUV_PATCH_FILE)"
	@touch "$@"

$(LIBUV_LIB): $(LIBUV_EXTRACTED)
	@$(MAKE) --no-print-directory check-libuv-tools
	@echo "==> Configuring libuv $(LIBUV_VERSION) (static, PIC, $(LIBUV_BUILD_TYPE))"
	cmake -S "$(LIBUV_SRC_DIR)" -B "$(LIBUV_BUILD_DIR)" \
		$(LIBUV_CMAKE_FLAGS) \
		$(if $(strip $(LIBUV_BUILD_CFLAGS)),-DCMAKE_C_FLAGS=$(call make_shell_quote,$(LIBUV_BUILD_CFLAGS)))
	@echo "==> Building libuv $(LIBUV_VERSION)"
	+$(RECURSIVE_WRAPPER_GUARD) cmake --build "$(LIBUV_BUILD_DIR)" --target uv_a
	@test -f "$(LIBUV_LIB)" || { \
	  echo "ERROR: libuv build completed without producing $(LIBUV_LIB)." >&2; exit 1; \
	}
	@touch "$@"

libuv-config: libuv ## Print the effective libuv compiler and linker inputs
	@echo "LIBUV_VERSION=$(LIBUV_VERSION)"
	@echo "LIBUV_BUILD_TYPE=$(LIBUV_BUILD_TYPE)"
	@echo "LIBUV_INCLUDE_DIR=$(LIBUV_INCLUDE_DIR)"
	@echo "LIBUV_CPPFLAGS=$(LIBUV_CPPFLAGS)"
	@echo "LIBUV_CFLAGS=$(LIBUV_CFLAGS)"
	@echo "LIBUV_BUILD_CFLAGS=$(LIBUV_BUILD_CFLAGS)"
	@echo "LIBUV_EXTRA_OBJECTS=$(LIBUV_EXTRA_OBJECTS)"
	@echo "LIBUV_LINK_LIBS=$(LIBUV_LINK_LIBS)"
	@echo "LIBUV_LDFLAGS=$(LIBUV_LDFLAGS)"
	@echo "LIBUV_PROVIDER_LDFLAGS=$(LIBUV_PROVIDER_LDFLAGS)"

llhttp: $(LLHTTP_ARCHIVE) ## Build private llhttp support

check-llhttp-tools:
	@missing=0; \
	for tool in "$(firstword $(CC))" "$(firstword $(AR))" \
		"$(firstword $(RANLIB))" tar; do \
	  if ! command -v "$$tool" >/dev/null 2>&1; then \
	    echo "ERROR: bundled llhttp requires '$$tool'." >&2; missing=1; \
	  fi; \
	done; \
	if ! command -v curl >/dev/null 2>&1 && \
	   ! command -v wget >/dev/null 2>&1; then \
	  echo "ERROR: need curl or wget to download $(LLHTTP_TARBALL)." >&2; \
	  missing=1; \
	fi; \
	if ! command -v sha256sum >/dev/null 2>&1 && \
	   ! command -v shasum >/dev/null 2>&1; then \
	  echo "ERROR: need sha256sum or shasum to verify llhttp." >&2; \
	  missing=1; \
	fi; \
	test "$$missing" -eq 0

$(LLHTTP_TARBALL):
	@$(MAKE) --no-print-directory check-llhttp-tools
	@echo "==> Downloading $(LLHTTP_URL)"
	@if command -v curl >/dev/null 2>&1; then \
	  curl -fL -o "$@" "$(LLHTTP_URL)"; \
	else \
	  wget -O "$@" "$(LLHTTP_URL)"; \
	fi

$(LLHTTP_EXTRACTED): $(LLHTTP_TARBALL)
	@$(MAKE) --no-print-directory check-llhttp-tools
	@echo "==> Verifying SHA-256 for $(LLHTTP_TARBALL)"
	@if command -v sha256sum >/dev/null 2>&1; then \
	  printf '%s  %s\n' "$(LLHTTP_SHA256)" "$(LLHTTP_TARBALL)" | \
	    sha256sum -c -; \
	else \
	  printf '%s  %s\n' "$(LLHTTP_SHA256)" "$(LLHTTP_TARBALL)" | \
	    shasum -a 256 -c -; \
	fi || { \
	  echo "ERROR: checksum mismatch for $(LLHTTP_TARBALL); removing it." >&2; \
	  rm -f "$(LLHTTP_TARBALL)"; exit 1; \
	}
	@echo "==> Extracting $(LLHTTP_TARBALL)"
	rm -rf "$(LLHTTP_SRC_DIR)"
	tar zxf "$(LLHTTP_TARBALL)"
	@test -f "$(LLHTTP_HEADER)" || { \
	  echo "ERROR: $(LLHTTP_TARBALL) omitted generated llhttp sources." >&2; \
	  exit 1; \
	}
	@touch "$@"

# These files arrive together from the verified release archive.  Giving Make
# their extraction stamp as the generating rule lets a clean parallel build
# resolve the header/source prerequisites before the source directory exists.
$(LLHTTP_SOURCES) $(LLHTTP_HEADER): $(LLHTTP_EXTRACTED)
	@test -f "$@" || { echo "ERROR: extracted llhttp omitted $@" >&2; exit 1; }

$(LLHTTP_BUILD_DIR)/%.o: $(LLHTTP_SRC_DIR)/src/%.c \
		$(LLHTTP_HEADER)
	@mkdir -p "$(@D)"
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(LLHTTP_CPPFLAGS) $(ROCK_CFLAGS) \
		$(LLHTTP_CFLAGS) $(TITAN_EXTRA_CFLAGS) $(LLHTTP_BUILD_CFLAGS) \
		-c "$<" -o "$@"

$(LLHTTP_ARCHIVE): $(LLHTTP_OBJECTS)
	rm -f "$@"
	$(AR) rcs "$@" $(LLHTTP_OBJECTS)
	$(RANLIB) "$@"

sqlite3: $(SQLITE3_ARCHIVE) ## Build private sqlite3 support

check-sqlite3-tools:
	@missing=0; \
	for tool in "$(firstword $(CC))" "$(firstword $(AR))" \
		"$(firstword $(RANLIB))" tar; do \
	  if ! command -v "$$tool" >/dev/null 2>&1; then \
	    echo "ERROR: bundled sqlite3 requires '$$tool'." >&2; missing=1; \
	  fi; \
	done; \
	if ! command -v curl >/dev/null 2>&1 && \
	   ! command -v wget >/dev/null 2>&1; then \
	  echo "ERROR: need curl or wget to download $(SQLITE3_TARBALL)." >&2; \
	  missing=1; \
	fi; \
	if ! command -v sha256sum >/dev/null 2>&1 && \
	   ! command -v shasum >/dev/null 2>&1; then \
	  echo "ERROR: need sha256sum or shasum to verify sqlite3." >&2; \
	  missing=1; \
	fi; \
	test "$$missing" -eq 0

$(SQLITE3_TARBALL):
	@$(MAKE) --no-print-directory check-sqlite3-tools
	@echo "==> Downloading $(SQLITE3_URL)"
	@if command -v curl >/dev/null 2>&1; then \
	  curl -fL -o "$@" "$(SQLITE3_URL)"; \
	else \
	  wget -O "$@" "$(SQLITE3_URL)"; \
	fi

$(SQLITE3_EXTRACTED): $(SQLITE3_TARBALL)
	@$(MAKE) --no-print-directory check-sqlite3-tools
	@echo "==> Verifying SHA-256 for $(SQLITE3_TARBALL)"
	@if command -v sha256sum >/dev/null 2>&1; then \
	  printf '%s  %s\n' "$(SQLITE3_SHA256)" "$(SQLITE3_TARBALL)" | \
	    sha256sum -c -; \
	else \
	  printf '%s  %s\n' "$(SQLITE3_SHA256)" "$(SQLITE3_TARBALL)" | \
	    shasum -a 256 -c -; \
	fi || { \
	  echo "ERROR: checksum mismatch for $(SQLITE3_TARBALL); removing it." >&2; \
	  rm -f "$(SQLITE3_TARBALL)"; exit 1; \
	}
	@echo "==> Extracting $(SQLITE3_TARBALL)"
	rm -rf "$(SQLITE3_SRC_DIR)"
	tar zxf "$(SQLITE3_TARBALL)"
	@test -f "$(SQLITE3_HEADER)" || { \
	  echo "ERROR: $(SQLITE3_TARBALL) omitted generated sqlite3 sources." >&2; \
	  exit 1; \
	}
	@touch "$@"

# These files arrive together from the verified release archive.  Giving Make
# their extraction stamp as the generating rule lets a clean parallel build
# resolve the header/source prerequisites before the source directory exists.
$(SQLITE3_SOURCES) $(SQLITE3_HEADER): $(SQLITE3_EXTRACTED)
	@test -f "$@" || { echo "ERROR: extracted sqlite3 omitted $@" >&2; exit 1; }

$(SQLITE3_BUILD_DIR)/%.o: $(SQLITE3_SRC_DIR)/%.c \
		$(SQLITE3_HEADER)
	@mkdir -p "$(@D)"
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(SQLITE3_CPPFLAGS) $(ROCK_CFLAGS) \
		$(SQLITE3_CFLAGS) $(TITAN_EXTRA_CFLAGS) $(SQLITE3_BUILD_CFLAGS) \
		-c "$<" -o "$@"

$(SQLITE3_ARCHIVE): $(SQLITE3_OBJECTS)
	rm -f "$@"
	$(AR) rcs "$@" $(SQLITE3_OBJECTS)
	$(RANLIB) "$@"

ifeq ($(OPENSSL_MODE),bundled)
openssl: $(OPENSSL_LIBS) ## Build bundled OpenSSL

check-openssl-tools:
	@missing=0; \
	for tool in "$(firstword $(CC))" "$(firstword $(AR))" \
		"$(firstword $(RANLIB))" "$(firstword $(OPENSSL_PERL))" tar; do \
	  if ! command -v "$$tool" >/dev/null 2>&1; then \
	    echo "ERROR: bundled OpenSSL requires '$$tool'." >&2; missing=1; \
	  fi; \
	done; \
	if ! command -v curl >/dev/null 2>&1 && \
	   ! command -v wget >/dev/null 2>&1; then \
	  echo "ERROR: need curl or wget to download $(OPENSSL_TARBALL)." >&2; \
	  missing=1; \
	fi; \
	if ! command -v sha256sum >/dev/null 2>&1 && \
	   ! command -v shasum >/dev/null 2>&1; then \
	  echo "ERROR: need sha256sum or shasum to verify OpenSSL." >&2; \
	  missing=1; \
	fi; \
	if test "$(HOST_OS)" != Linux && test "$(HOST_OS)" != Darwin; then \
	  echo "ERROR: bundled OpenSSL supports Linux and macOS, not $(HOST_OS)." >&2; \
	  missing=1; \
	fi; \
	test "$$missing" -eq 0

$(OPENSSL_TARBALL):
	@$(MAKE) --no-print-directory check-openssl-tools
	@echo "==> Downloading $(OPENSSL_URL)"
	@if command -v curl >/dev/null 2>&1; then \
	  curl -fL -o "$@" "$(OPENSSL_URL)"; \
	else \
	  wget -O "$@" "$(OPENSSL_URL)"; \
	fi

$(OPENSSL_EXTRACTED): $(OPENSSL_TARBALL)
	@$(MAKE) --no-print-directory check-openssl-tools
	@echo "==> Verifying SHA-256 for $(OPENSSL_TARBALL)"
	@if command -v sha256sum >/dev/null 2>&1; then \
	  printf '%s  %s\n' "$(OPENSSL_SHA256)" "$(OPENSSL_TARBALL)" | \
	    sha256sum -c -; \
	else \
	  printf '%s  %s\n' "$(OPENSSL_SHA256)" "$(OPENSSL_TARBALL)" | \
	    shasum -a 256 -c -; \
	fi || { \
	  echo "ERROR: checksum mismatch for $(OPENSSL_TARBALL); removing it." >&2; \
	  rm -f "$(OPENSSL_TARBALL)"; exit 1; \
	}
	rm -rf "$(OPENSSL_SRC_DIR)"
	tar zxf "$(OPENSSL_TARBALL)"
	@test -f "$(OPENSSL_SRC_DIR)/Configure" || { \
	  echo "ERROR: $(OPENSSL_TARBALL) omitted Configure." >&2; exit 1; \
	}
	@touch "$@"

$(OPENSSL_BUILD_COMPLETE): $(OPENSSL_EXTRACTED)
	@$(MAKE) --no-print-directory check-openssl-tools
	@mkdir -p "$(OPENSSL_BUILD_DIR)"
	@echo "==> Configuring OpenSSL $(OPENSSL_VERSION) (static, PIC, private)"
	cd "$(OPENSSL_BUILD_DIR)" && \
	  CC=$(call make_shell_quote,$(CC)) \
	  AR=$(call make_shell_quote,$(AR)) \
	  RANLIB=$(call make_shell_quote,$(RANLIB)) \
	  CPPFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CPPFLAGS)) \
	  CFLAGS=$(call make_shell_quote,$(OPENSSL_REQUIRED_CFLAGS) $(OPENSSL_BUILD_CFLAGS)) \
	  $(OPENSSL_PERL) "$(OPENSSL_SRC_ABS)/Configure" \
	    $(OPENSSL_CONFIGURE_FLAGS)
	@echo "==> Building OpenSSL $(OPENSSL_VERSION) libraries"
	$(MAKE) -C "$(OPENSSL_BUILD_DIR)" build_libs
	@test -f "$(OPENSSL_BUNDLED_LIBSSL)" && \
	  test ! -L "$(OPENSSL_BUNDLED_LIBSSL)" && \
	  test -f "$(OPENSSL_BUNDLED_LIBCRYPTO)" && \
	  test ! -L "$(OPENSSL_BUNDLED_LIBCRYPTO)" || { \
	    echo "ERROR: OpenSSL build omitted regular static libraries." >&2; \
	    exit 1; \
	  }
	@touch "$@"

$(OPENSSL_LIBS): $(OPENSSL_BUILD_COMPLETE)
	@test -f "$@" && test ! -L "$@"

else ifeq ($(OPENSSL_MODE),system)
openssl: check-system-openssl ## Validate system OpenSSL

check-system-openssl:
	@if ! command -v "$(firstword $(OPENSSL_PKG_CONFIG))" >/dev/null 2>&1; then \
	  echo "ERROR: pkg-config is required for OPENSSL_MODE=system." >&2; \
	  exit 1; \
	fi
	@if ! $(OPENSSL_PKG_CONFIG) --exists openssl; then \
	  echo "ERROR: pkg-config cannot find OpenSSL development files." >&2; \
	  echo "  Ubuntu/Debian: sudo apt-get install libssl-dev pkg-config" >&2; \
	  echo "  Fedora: sudo dnf install openssl-devel pkgconf-pkg-config" >&2; \
	  echo "  macOS: brew install openssl@3 pkgconf" >&2; exit 1; \
	fi
	@if ! $(OPENSSL_PKG_CONFIG) --atleast-version="$(OPENSSL_MIN_VERSION)" openssl; then \
	  found=`$(OPENSSL_PKG_CONFIG) --modversion openssl 2>/dev/null || echo unknown`; \
	  echo "ERROR: system OpenSSL $$found is too old; need >= $(OPENSSL_MIN_VERSION)." >&2; \
	  exit 1; \
	fi
	@echo "==> Using system OpenSSL `$(OPENSSL_PKG_CONFIG) --modversion openssl`"
	@echo "    OPENSSL_CPPFLAGS=$(OPENSSL_CPPFLAGS)"
	@echo "    OPENSSL_PROVIDER_LDFLAGS=$(OPENSSL_PROVIDER_LDFLAGS)"

else
openssl: invalid-openssl-mode

invalid-openssl-mode:
	@echo "ERROR: unsupported OPENSSL_MODE='$(OPENSSL_MODE)'; choose 'bundled' or 'system'." >&2
	@exit 1
endif

openssl-config: openssl ## Print effective OpenSSL compiler/linker inputs
	@echo "OPENSSL_MODE=$(OPENSSL_MODE)"
	@echo "OPENSSL_VERSION=$(OPENSSL_VERSION)"
	@echo "OPENSSL_MIN_VERSION=$(OPENSSL_MIN_VERSION)"
	@echo "OPENSSL_CPPFLAGS=$(OPENSSL_CPPFLAGS)"
	@echo "OPENSSL_EXTRA_OBJECTS=$(OPENSSL_EXTRA_OBJECTS)"
	@echo "OPENSSL_PROVIDER_LDFLAGS=$(OPENSSL_PROVIDER_LDFLAGS)"

lpeglabel: $(LPEGLABEL_ARCHIVE) ## Build the private LPegLabel archive

$(LPEGLABEL_BUILD_DIR)/%.o: $(LPEGLABEL_VENDOR_DIR)/%.c \
		$(LPEGLABEL_HEADERS) $(wildcard $(LPEGLABEL_LUA_HEADERS)) $(LUA_SDK_PREREQ)
	@mkdir -p "$(@D)"
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(LPEGLABEL_CPPFLAGS) \
		-I"$(ROCK_LUA_INCDIR)" $(ROCK_CFLAGS) $(LPEGLABEL_CFLAGS) \
		$(TITAN_EXTRA_CFLAGS) $(LPEGLABEL_BUILD_CFLAGS) -c "$<" -o "$@"

$(LPEGLABEL_ARCHIVE): $(LPEGLABEL_OBJECTS)
	rm -f "$@"
	$(AR) rcs "$@" $(LPEGLABEL_OBJECTS)
	$(RANLIB) "$@"

runtime: $(TITAN_RUNTIME_LIB) ## Build the Titan C runtime archive used by every compiler mode

$(LIBBT_DIR)/backtrace.h: | $(LIBBT_CLONE_STAMP)

$(RUNTIME_O): titan-runtime/titan.c titan-runtime/titan.h \
		titan-runtime/titan/ffi.h $(LIBBT_DIR)/backtrace.h \
		$(TITAN_RUNTIME_LUA_HEADERS) | $(TITAN_RUNTIME_LUA_LIB) $(LIBBT_LIB)
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(CFLAGS) $(TITAN_EXTRA_CFLAGS) \
		-c titan-runtime/titan.c -I titan-runtime -I $(TITAN_RUNTIME_LUA_SOURCE_PATH) \
		-I $(LIBBT_DIR) -o $@

$(MINICORO_O): titan-runtime/minicoro.c \
		titan-runtime/minicoro.h titan-runtime/titan/ffi.h \
		$(TITAN_RUNTIME_LUA_HEADERS) | $(TITAN_RUNTIME_LUA_LIB) $(LIBBT_LIB)
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(CFLAGS) $(TITAN_EXTRA_CFLAGS) \
		-c titan-runtime/minicoro.c -I titan-runtime -I $(TITAN_RUNTIME_LUA_SOURCE_PATH) \
		-I $(LIBBT_DIR) -o $@

$(TITAN_RUNTIME_LIB): $(TITAN_RUNTIME_OBJECTS)
	rm -f "$@"
	$(AR) rcs "$@" $(TITAN_RUNTIME_OBJECTS)
	$(RANLIB) "$@"

$(LTITANLIB_O): titan-runtime/ltitanlib.c \
		$(wildcard $(ROCK_LUA_HEADERS)) $(LUA_SDK_PREREQ)
	$(CC) $(ROCK_CFLAGS) $(TITAN_EXTRA_CFLAGS) \
		-I"$(ROCK_LUA_INCDIR)" -c "$<" -o "$@"

$(TITAN_BOOTSTRAP_SO): $(LTITANLIB_O)
	@mkdir -p "$(@D)"
	@set -e; tmp="$@.tmp"; rm -f "$$tmp"; \
	if $(ROCK_LD) $(ROCK_LIBFLAG) -o "$$tmp" "$<" \
		$(TITAN_EXTRA_LDFLAGS); then \
		mv -f "$$tmp" "$@"; \
	else \
		status=$$?; rm -f "$$tmp"; exit $$status; \
	fi

# Seed an absent canonical provider. Preserve an installed full standard library.
stage-titan-bootstrap: $(TITAN_BOOTSTRAP_SO)
	@mkdir -p "$(TITAN_STDLIB_VERSION_DIR)"
	@if test ! -e "$(TITAN_CANONICAL_SUPPORT_SO)"; then \
	  install -m 0755 "$(TITAN_BOOTSTRAP_SO)" "$(TITAN_CANONICAL_SUPPORT_SO)"; \
	fi

# Build with this source rock's compiler, even when another Titan is installed.
# The private bootstrap supplies native compiler support without publishing an
# incomplete provider into the destination tree.
all: lpeglabel libbacktrace libuv openssl llhttp sqlite3 $(TITAN_RUNTIME_LIB) $(TITAN_BOOTSTRAP_SO) ## Build the runtime and paired standard library (default)
	$(MAKE) --no-print-directory stdlib STDLIB_USE_INSTALLED_RUNTIME=0 TITAN_ROCKS_ROOT=

# LuaRocks runs this in the same source directory as the build pass. Compiler
# files and shims enter its ordinary staging directories. The retained payload
# is published by post_install for both source and binary rocks.
ifneq ($(strip $(INST_PREFIX)),)
install: install-compiler install-rock-tools stage-rock-payload ## Stage the built compiler, SDK and standard library
.PHONY: stage-rock-payload
stage-rock-payload:
	+$(MAKE) --no-print-directory publish-titan-sdk publish-stdlib \
	  TITAN_INSTALL_TREE="$(INST_PREFIX)/titan-sdk" \
	  TITAN_STDLIB_LUA_DIR="$(INST_LUADIR)/titan"
else
install: install-compiler publish-titan-sdk publish-stdlib ## Copy the built compiler, SDK and standard library
endif

# PREFIX owns installed Lua. Stage that SDK into a separate ROCKS_TREE, while
# leaving Lua-owned files in place when both installation roots are the same.
TITAN_RUNTIME_SDK_PREREQS := $(TITAN_RUNTIME_LIB) $(TITAN_BOOTSTRAP_SO) \
	$(TITAN_RUNTIME_LUA_LIB) $(LIBBT_LIB) $(TITAN_SDK_ROOT_HEADERS) \
	$(TITAN_SDK_NAMESPACED_HEADERS) LICENSE
TITAN_RUNTIME_SDK_COPY = \
	mkdir -p "$(TITAN_INSTALL_TREE)"; \
	rocks_tree=$$(CDPATH= cd "$(TITAN_INSTALL_TREE)" && pwd -P); \
	version_dir="$$rocks_tree/lib/titan/$(TITAN_LIBRARY_VERSION)"; \
	echo "==> Installing Titan SDK into $$rocks_tree"; \
	rm -f "$$rocks_tree/include/titan_longjmp.h"; \
	mkdir -p "$$rocks_tree/src/$(LUA_DIR)" \
		"$$rocks_tree/include/titan" "$$rocks_tree/lib" \
		"$$rocks_tree/share/titan" "$$version_dir"; \
	install -p -m 0644 LICENSE "$$rocks_tree/share/titan/LICENSE"; \
	lua_source="$(abspath $(TITAN_RUNTIME_LUA_SOURCE_PATH))"; \
	if test "$$lua_source" != "$(LUA_SOURCE_INSTALL_DIR)" || \
	   test "$$rocks_tree" != "$$(CDPATH= cd "$(PREFIX)" && pwd -P)"; then \
	  install -p -m 0644 "$$lua_source"/*.c "$$lua_source"/*.h \
		"$$rocks_tree/src/$(LUA_DIR)/"; \
	  install -p -m 0644 "$(TITAN_RUNTIME_LUA_LIB)" "$$rocks_tree/lib/liblua.a"; \
	fi; \
	rm -f "$$rocks_tree/lib/libtitan.a"; \
	install -p -m 0644 "$(TITAN_RUNTIME_LIB)" "$$version_dir/libtitan.a"; \
	install -p -m 0644 "$(LIBBT_LIB)" "$$rocks_tree/lib/libbacktrace.a"; \
	install -p -m 0644 $(TITAN_SDK_ROOT_HEADERS) "$$rocks_tree/include/"; \
	install -p -m 0644 $(TITAN_SDK_NAMESPACED_HEADERS) \
		"$$rocks_tree/include/titan/"

# The guarded bootstrap provides bare native compiler support without claiming
# standard-module metadata, an archive provider, or generated Lua shims.
install-compiler-sdk: install-compiler $(TITAN_RUNTIME_SDK_PREREQS) stage-titan-bootstrap ## Build and install the compiler/runtime SDK without the standard library
	@set -e; \
	$(TITAN_RUNTIME_SDK_COPY); \
	mkdir -p "$$rocks_tree/etc/titan"; \
	printf '%s\n' $(call make_shell_quote,$(TITAN_BUILD_PROFILE)) > "$$rocks_tree/etc/titan/build-profile"

install-titan-sdk: $(TITAN_RUNTIME_SDK_PREREQS) $(LIBUV_LIB) $(OPENSSL_LIBS) \
	$(LLHTTP_HEADER) $(SQLITE3_HEADER) stage-titan-bootstrap
publish-titan-sdk: ## Copy the already built native compiler SDK
install-titan-sdk publish-titan-sdk:
	@set -e; \
	$(TITAN_RUNTIME_SDK_COPY); \
	cp -pR "$(LIBUV_SRC_DIR)/include/." "$$rocks_tree/include/"; \
	if test "$(OPENSSL_MODE)" != system; then \
	  mkdir -p "$$rocks_tree/include/openssl"; \
	  install -p -m 0644 $(OPENSSL_SRC_DIR)/include/openssl/*.h \
	    $(OPENSSL_BUILD_DIR)/include/openssl/*.h "$$rocks_tree/include/openssl/"; \
	else \
	  rm -rf "$$rocks_tree/include/openssl"; \
	fi; \
	install -p -m 0644 "$(LLHTTP_HEADER)" "$$rocks_tree/include/"; \
	install -p -m 0644 "$(SQLITE3_HEADER)" "$$rocks_tree/include/"; \
	rm -f "$$rocks_tree/lib/libuv.a"; \
	mkdir -p "$$rocks_tree/etc/titan"; \
	printf '%s\n' $(call make_shell_quote,$(TITAN_BUILD_PROFILE)) > "$$rocks_tree/etc/titan/build-profile"

# The real bundled libuv archive is private input to the paired titan.so/titan.a
# provider. The install recipe above removes copies left by older SDKs so
# extensions cannot create a second native instance. Development stdlib builds
# can consume the installed Titan runtime archive. Libuv headers come from that SDK,
# and its private archive goes to titanc through the same -X payload as
# ltitanlib.o and the private
# LPegLabel archive.
ifeq ($(STDLIB_USE_INSTALLED_RUNTIME),1)
  STDLIB_PLATFORM_PREREQS := libuv openssl
  STDLIB_NATIVE_PREREQS := $(STDLIB_EXTRA_OBJECTS) \
	$(STDLIB_ROCKS_ROOT)/lib/titan/$(TITAN_LIBRARY_VERSION)/libtitan.a \
	$(STDLIB_ROCKS_ROOT)/lib/libbacktrace.a $(STDLIB_ROCKS_ROOT)/lib/liblua.a
  STDLIB_BOOTSTRAP_PREREQ :=
  STDLIB_RUNTIME_ARCHIVE_PREREQ :=
  STDLIB_TOOL_PREREQS :=
  STDLIB_UV_CPPFLAGS := $(filter-out -I$(LIBUV_INCLUDE_DIR),$(LIBUV_CPPFLAGS))
  STDLIB_UV_LDFLAGS := $(LIBUV_PROVIDER_LDFLAGS)
  STDLIB_UV_CFLAGS := $(LIBUV_CFLAGS)
else
  STDLIB_PLATFORM_PREREQS := libuv openssl
  # The provider pair may extract every runtime member. Keep the runtime archive
  # itself order-only because its object prerequisites already own relinking.
  STDLIB_NATIVE_PREREQS := $(TITAN_RUNTIME_OBJECTS) \
	$(STDLIB_EXTRA_OBJECTS)
  STDLIB_RUNTIME_ARCHIVE_PREREQ := $(TITAN_RUNTIME_LIB)
  # Only an unprepared PREFIX needs the Lua installation step. A prepared
  # SDK supplies real source headers and its matching archive directly.
  STDLIB_TOOL_PREREQS := $(LUA_SDK_PREREQ) $(TITAN_RUNTIME_LUA_LIB) $(LIBBT_LIB)
  STDLIB_UV_CPPFLAGS := $(LIBUV_CPPFLAGS)
  STDLIB_UV_CFLAGS := $(LIBUV_CFLAGS)
  # Only platform/system final libraries belong here. Bundled libuv is in
  # STDLIB_EXTRA_OBJECTS so the compiler force-loads it into titan.so and
  # flattens it into titan.a.
  STDLIB_UV_LDFLAGS := $(strip $(LIBUV_PROVIDER_LDFLAGS))
endif

# Compiler/SDK changes invalidate every module; native header changes enter at
# their owning modules and propagate through the explicit source import graph.
# Track the selected SDK's source headers, including installed-prefix updates.
# LuaRocks generates the CLI wrapper after our build; the retained script owns
# compiler invalidation when present, so deployment alone cannot force a rebuild.
ifeq ($(STDLIB_USE_INSTALLED_RUNTIME),1)
  STDLIB_COMPILER_PREREQS = Makefile $(or \
	$(wildcard $(STDLIB_ROCKS_ROOT)/lib/luarocks/rocks-$(LUA_ABI_VERSION)/titan/*/bin/titanc),\
	$(STDLIB_ROCKS_ROOT)/bin/titanc) \
	$(wildcard $(STDLIB_ROCKS_ROOT)/share/lua/$(LUA_ABI_VERSION)/titan-compiler/*.lua \
	$(STDLIB_ROCKS_ROOT)/share/lua/$(LUA_ABI_VERSION)/titan-compiler/checker/*.lua \
	$(STDLIB_ROCKS_ROOT)/share/lua/$(LUA_ABI_VERSION)/titan-compiler/coder/*.lua \
	$(STDLIB_ROCKS_ROOT)/share/lua/$(LUA_ABI_VERSION)/c-parser/*.lua) \
	$(STDLIB_ROCKS_ROOT)/include/minicoro.h $(STDLIB_ROCKS_ROOT)/include/titan.h \
	$(STDLIB_ROCKS_ROOT)/include/titan/ffi.h \
	$(wildcard $(STDLIB_ROCKS_ROOT)/src/$(LUA_DIR)/*.h)
else
  STDLIB_COMPILER_PREREQS = titanc $(TITAN_COMPILER_LUA) Makefile \
	$(TITAN_SDK_ROOT_HEADERS) $(TITAN_SDK_NAMESPACED_HEADERS) \
	$(TITAN_RUNTIME_LUA_HEADERS)
endif
STDLIB_UV_HEADER_DIRS = $(if $(filter 1,$(STDLIB_USE_INSTALLED_RUNTIME)),$(STDLIB_ROCKS_ROOT)/include,$(LIBUV_INCLUDE_DIR))
ifeq ($(OPENSSL_MODE),bundled)
  STDLIB_OPENSSL_HEADER_DIRS = $(OPENSSL_SRC_DIR)/include $(OPENSSL_BUILD_DIR)/include
else
  STDLIB_OPENSSL_HEADER_DIRS = $(shell $(OPENSSL_PKG_CONFIG) --variable=includedir openssl 2>/dev/null)
endif
STDLIB_C_INPUTS_uv = $(UV_TITAN_HEADERS) $(foreach dir,$(STDLIB_UV_HEADER_DIRS),$(wildcard $(dir)/uv.h $(dir)/uv/*.h))
STDLIB_C_INPUTS_async = titan/async_signal_platform.h
STDLIB_C_INPUTS_fs = titan/fs_platform.h
STDLIB_C_INPUTS_os = titan/os_platform.h titan/os_environment.h
STDLIB_C_INPUTS_path = titan/path_platform.h
STDLIB_C_INPUTS_peg = $(LPEGLABEL_HEADERS)
STDLIB_C_INPUTS_string = $(STRING_TITAN_HEADERS)
STDLIB_C_INPUTS_http = $(LLHTTP_HEADER)
STDLIB_C_INPUTS_ssl = $(foreach dir,$(STDLIB_OPENSSL_HEADER_DIRS),$(wildcard $(dir)/openssl/*.h))
STDLIB_C_INPUTS_websocket = $(foreach dir,$(STDLIB_OPENSSL_HEADER_DIRS),$(wildcard $(dir)/openssl/*.h))
STDLIB_C_INPUTS_sqlite3 = $(SQLITE3_HEADER) $(SQLITE3_TITAN_HEADERS)

# The command is identical for object builds and the final link. Only the
# latter receives native payload. Make schedules modules; each compiler gets
# one generated-C slot so nested parallelism stays within the jobserver bound.
STDLIB_COMPILER_ENV = CC=$(call make_shell_quote,$(CC)) \
	AR=$(call make_shell_quote,$(AR)) RANLIB=$(call make_shell_quote,$(RANLIB)) \
	ROCKS_TREE=$(call make_shell_quote,$(TITAN_INSTALL_TREE)) \
	TITAN_PATH$(TITAN_LIBRARY_VERSION_SUFFIX)=$(call make_shell_quote,$(CURDIR)) TITAN_PATH= \
	TITAN_ROCKS_ROOT=$(call make_shell_quote,$(STDLIB_ROCKS_ROOT)) TITAN_RUNTIME_PREBUILT=1 \
	TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CPPFLAGS) $(STDLIB_LPEGLABEL_CPPFLAGS) $(STDLIB_HTTP_CPPFLAGS) $(STDLIB_SQLITE3_CPPFLAGS) $(STDLIB_OPENSSL_CPPFLAGS) $(STDLIB_UV_CPPFLAGS))) \
	TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CFLAGS) $(STDLIB_UV_CFLAGS))) \
	TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_LDFLAGS) $(STDLIB_UV_LDFLAGS) $(STDLIB_OPENSSL_LDFLAGS)))

stdlib-objects: $(foreach module,$(STDLIB_MODULES),$(call stdlib_outputs,$(module))) ## Compile standard-library objects without linking a provider

# A real object target owns its generated C and headers, including the exact
# source/object pair needed by sanitizer diagnostic snapshots. FORCE runs an
# inexpensive completeness check; unchanged outputs keep their timestamps.
# This also works with the GNU Make shipped by macOS, without grouped targets.
define stdlib_object_rule
$(call stdlib_stem,$(1)).o: FORCE $(filter titan/$(1).titan titan/$(1)/%.titan,$(STDLIB_TITAN_SOURCES)) \
	$(foreach dependency,$(STDLIB_IMPORTS_$(1)),$(call stdlib_outputs,$(dependency))) \
	$(STDLIB_C_INPUTS_$(1)) $(STDLIB_COMPILER_PREREQS) \
	$(STDLIB_TOOL_PREREQS) | $(STDLIB_NATIVE_PREREQS) $(STDLIB_BOOTSTRAP_PREREQ) \
	$(STDLIB_RUNTIME_ARCHIVE_PREREQ) $(STDLIB_PLATFORM_PREREQS)
	@set -e; \
	stale=0; \
	newer=$$(call make_shell_quote,$$(filter-out FORCE,$$?)); \
	test -z "$$$$newer" || stale=1; \
	for output in $(call stdlib_outputs,$(1)); do \
	  test -f "$$$$output" && test ! -L "$$$$output" || stale=1; \
	done; \
	if test "$$$$stale" = 1; then \
	  echo "==> Compiling stdlib module titan.$(1)"; \
	  rm -f "$$@"; \
	  unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5; \
	  $$(STDLIB_COMPILER_ENV) $$(TITANC) --output $$(call make_shell_quote,$$(TITAN_OUTPUT_DIR)) --source-first --incremental -j1 -c titan.$(1); \
	  for output in $(call stdlib_outputs,$(1)); do \
	    test -f "$$$$output" && test ! -L "$$$$output" || { \
	      echo "ERROR: stdlib compilation did not produce $$$$output" >&2; exit 1; \
	    }; \
	  done; \
	fi
$(filter-out $(call stdlib_stem,$(1)).o,$(call stdlib_outputs,$(1))): $(call stdlib_stem,$(1)).o
	@test -f "$$@" && test ! -L "$$@"
endef
$(foreach module,$(STDLIB_MODULES),$(eval $(call stdlib_object_rule,$(module))))

stdlib: $(STDLIB_PROVIDER_OUTPUTS) $(STDLIB_SHIMS) ## Build the paired standard-library provider

$(STDLIB_PROVIDER_OUTPUTS) $(STDLIB_SHIMS): $(STDLIB_COMPLETION_STAMP)
	@test -f "$@" && test ! -L "$@" || { \
	  echo "ERROR: completed stdlib provider is missing or nonregular: $@" >&2; exit 1; \
	}

# FORCE runs the inexpensive completeness check on every invocation. The
# final link runs only when an object/input changed or a public output is
# absent. All standard-module objects feed the same paired provider.
$(STDLIB_COMPLETION_STAMP): FORCE $(STDLIB_MODULE_OBJECTS) \
		$(STDLIB_COMPILER_PREREQS) \
		$(STDLIB_NATIVE_PREREQS) $(STDLIB_BOOTSTRAP_PREREQ) \
		$(STDLIB_TOOL_PREREQS) | $(STDLIB_RUNTIME_ARCHIVE_PREREQ) \
		$(STDLIB_PLATFORM_PREREQS)
	@set -e; \
	stale=0; \
	newer=$(call make_shell_quote,$(filter-out FORCE,$?)); \
	test -z "$$newer" || stale=1; \
	test -f "$@" || stale=1; \
	for output in $(STDLIB_PROVIDER_OUTPUTS) $(STDLIB_SHIMS); do \
	  test -f "$$output" && test ! -L "$$output" || stale=1; \
	done; \
	if test "$(HOST_OS)" = Darwin; then \
	  test -d "$(STDLIB_CONTAINER).dSYM" || stale=1; \
	else \
	  rm -rf "$(STDLIB_CONTAINER).dSYM"; \
	fi; \
	if test "$$stale" = 1; then \
	  echo "==> Linking paired Titan stdlib providers"; \
	  rm -f "$@"; \
	  rm -f $(STDLIB_SOS) $(STDLIB_QUALIFIED_SOS); \
	  rm -rf $(addsuffix .dSYM,$(STDLIB_SOS)) \
		$(addsuffix .dSYM,$(STDLIB_QUALIFIED_SOS)); \
	  unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5; \
	  $(STDLIB_COMPILER_ENV) $(TITANC) --output $(call make_shell_quote,$(TITAN_OUTPUT_DIR)) --source-first --incremental \
	    $(STDLIB_ROOTS) -X $(STDLIB_EXTRA_OBJECTS); \
	  for output in $(STDLIB_PROVIDER_OUTPUTS) $(STDLIB_SHIMS); do \
	    test -f "$$output" && test ! -L "$$output" || { \
	      echo "ERROR: stdlib build did not produce $$output" >&2; exit 1; \
	    }; \
	  done; \
	  if test "$(HOST_OS)" = Darwin; then \
	    test -d "$(STDLIB_CONTAINER).dSYM" || { \
	      echo "ERROR: stdlib build did not produce $(STDLIB_CONTAINER).dSYM" >&2; exit 1; \
	    }; \
	  fi; \
	  tmp="$@.tmp"; : > "$$tmp"; mv -f "$$tmp" "$@"; \
	fi; \
	rm -f $(STDLIB_SOS) $(STDLIB_QUALIFIED_SOS); \
	rm -rf $(addsuffix .dSYM,$(STDLIB_SOS)) \
		$(addsuffix .dSYM,$(STDLIB_QUALIFIED_SOS))

install-stdlib: stdlib ## Install the paired standard library from this source tree
publish-stdlib: ## Copy an already built standard library from STDLIB_INSTALL_STAGE
install-stdlib publish-stdlib:
	@set -e; \
	stage=$(call make_shell_quote,$(STDLIB_INSTALL_STAGE)); \
	mkdir -p "$(TITAN_STDLIB_VERSION_DIR)" "$(TITAN_STDLIB_LUA_DIR)" \
	  "$(TITAN_SHARE_DIR)/LICENSES"; \
	if test -n $(call make_shell_quote,$(strip $(TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT))); then \
	  $(STDLIB_COMPILER_ENV) "$(TITAN_LUA)" -E \
	    "$(CURDIR)/spec/support/ci_asan_generated_c_context.lua" snapshot \
	    $(call make_shell_quote,$(strip $(TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT))) \
	    "$$stage/titan.so" "$$stage/titan" \
	    "$(TITAN_CANONICAL_SUPPORT_SO)" "$(CURDIR)/titan"; \
	fi; \
	install -p -m 0755 "$$stage/titan.so" "$(TITAN_CANONICAL_SUPPORT_SO)"; \
	install -p -m 0644 "$$stage/titan.a" "$(TITAN_CANONICAL_STATIC_ARCHIVE)"; \
	for shim in $(notdir $(STDLIB_SHIMS)); do \
	  install -p -m 0644 "$$stage/titan/$$shim" "$(TITAN_STDLIB_LUA_DIR)/"; \
	done; \
	rm -f "$(TITAN_SHARE_DIR)/$(TITAN_LIBRARY_VERSION)/src/titan/test.titan"; \
	if test -d "$$stage/titan.so.dSYM"; then \
	  rm -rf "$(TITAN_CANONICAL_SUPPORT_SO).dSYM"; \
	  cp -pR "$$stage/titan.so.dSYM" "$(TITAN_CANONICAL_SUPPORT_SO).dSYM"; \
	fi; \
	install -p -m 0644 THIRD_PARTY_NOTICES.md "$(TITAN_SHARE_DIR)/THIRD_PARTY_NOTICES.md"; \
	install -p -m 0644 $(STDLIB_LICENSES) "$(TITAN_SHARE_DIR)/LICENSES/"

# Compatibility name for callers of the former rockspec build target.
rock-build: all

TITAN_TEST_MODULE_MANIFEST := $(TITAN_MAKEFILE_DIR)spec/support/stdlib_test_modules.mk
include $(TITAN_TEST_MODULE_MANIFEST)
TITAN_TEST_BUILD_DIR ?= $(TITAN_OUTPUT_DIR)/tests
TITAN_TEST_EXECUTABLE := $(TITAN_TEST_BUILD_DIR)/$(TITAN_STDLIB_TEST_PROGRAM_OUTPUT)
# The suite deadline includes fresh child-fixture compilation at the selected
# native profile across all 28 test roots, including fresh child compilers.
# Focused gates may set a lower bound.
TITAN_TEST_TIMEOUT ?= 600
TEST_TITANC ?= $(if $(filter validation,$(TITAN_BUILD_PROFILE)),$(call make_shell_quote,$(PREFIX)/bin/titanc),titanc)
TEST_LUA ?= $(if $(filter validation,$(TITAN_BUILD_PROFILE)),$(PREFIX)/bin/lua,lua)
ifeq ($(origin BUSTED),undefined)
BUSTED := $(if $(filter validation,$(TITAN_BUILD_PROFILE)),$(PREFIX)/bin/busted,busted)
endif
BUSTED_FILTER ?=
TITAN_FILTER ?=
TITAN_TEST_CPPFLAGS = $(if $(strip $(TITAN_EXTRA_CPPFLAGS)),$(TITAN_EXTRA_CPPFLAGS),$(TITAN_TEST_EXTRA_CPPFLAGS))
TITAN_TEST_CFLAGS = $(strip $(TITAN_PROFILE_NATIVE_FLAGS) $(if $(strip $(TITAN_EXTRA_CFLAGS)),$(TITAN_EXTRA_CFLAGS),$(TITAN_TEST_EXTRA_CFLAGS)))
TITAN_TEST_LDFLAGS = $(strip $(TITAN_PROFILE_NATIVE_FLAGS) $(if $(strip $(TITAN_EXTRA_LDFLAGS)),$(TITAN_EXTRA_LDFLAGS),$(TITAN_TEST_EXTRA_LDFLAGS)))
titan_test_stem = $(TITAN_TEST_BUILD_DIR)/$(patsubst spec/stdlib/titan/%.titan,%,$(firstword $(TITAN_TEST_SOURCES_$(1))))
titan_test_outputs = $(call titan_test_stem,$(1)).o $(call titan_test_stem,$(1)).c $(call titan_test_stem,$(1)).ffi.h $(if $(TITAN_TEST_FOREIGN_$(1)),$(call titan_test_stem,$(1)).titan.h)
TITAN_TEST_MODULE_OBJECTS := $(foreach module,$(TITAN_TEST_MODULES),$(call titan_test_stem,$(module)).o)
TITAN_TEST_NATIVE_OBJECTS := $(addprefix $(TITAN_TEST_BUILD_DIR)/,async_foreign_work.o fs_fixture.o uv_stdio_probe.o sqlite3_worker_fixture.o)
TITAN_TEST_FIXTURE_OUTPUTS := $(TITAN_TEST_NATIVE_OBJECTS) $(addprefix $(TITAN_TEST_BUILD_DIR)/,async_foreign_work.h uv_stdio_probe.h uv_coverage_threads.h uv_coverage_pty.h sqlite3_worker_fixture.h ssl_allocator_fixture.h ssl_allocator_fixture.o ssl_error_strings.h ssl_error_strings.o os_descriptor_limit.h os_descriptor_limit.o os_process_host_child)
TITAN_TEST_CONFIG_STAMP := $(TITAN_TEST_BUILD_DIR)/build.config
# TEST_LUA selects the installed SDK, just as it does for the compiler and the
# native fixtures. A cold non-test Make invocation need not have one installed.
TITAN_TEST_INSTALL_ROOT := $(shell $(TEST_LUA) -E -e 'io.write(assert(require("titan-compiler.driver").TITAN_ROOT))' 2>/dev/null)
TITAN_TEST_PROVIDER_PREREQS := $(if $(TITAN_TEST_INSTALL_ROOT),$(TITAN_TEST_INSTALL_ROOT)/lib/titan/$(TITAN_LIBRARY_VERSION)/titan.so $(TITAN_TEST_INSTALL_ROOT)/lib/titan/$(TITAN_LIBRARY_VERSION)/titan.a)
TITAN_TEST_COMPILER_PREREQS := Makefile $(TITAN_TEST_MODULE_MANIFEST) \
	$(if $(TITAN_TEST_INSTALL_ROOT),$(TITAN_TEST_INSTALL_ROOT)/bin/titanc \
	$(wildcard $(TITAN_TEST_INSTALL_ROOT)/share/lua/5.5/titan-compiler/*.lua \
	$(TITAN_TEST_INSTALL_ROOT)/share/lua/5.5/titan-compiler/checker/*.lua \
	$(TITAN_TEST_INSTALL_ROOT)/share/lua/5.5/titan-compiler/coder/*.lua \
	$(TITAN_TEST_INSTALL_ROOT)/share/lua/5.5/c-parser/*.lua \
	$(TITAN_TEST_INSTALL_ROOT)/src/$(LUA_DIR)/*.h \
	$(TITAN_TEST_INSTALL_ROOT)/include/*.h $(TITAN_TEST_INSTALL_ROOT)/include/titan/*.h))
# POSIX terminal fixtures need the same Linux feature declarations as libuv.
# Keep this separate from its source header search path in installed-SDK tests.
TITAN_TEST_FEATURE_CPPFLAGS = $(filter -D_GNU_SOURCE,$(LIBUV_CPPFLAGS))
TITAN_TEST_COMPILER_ENV = TITAN_BUILD_PROFILE=$(call make_shell_quote,$(TITAN_BUILD_PROFILE)) \
	TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(strip $(TITAN_TEST_CPPFLAGS) $(TITAN_TEST_FEATURE_CPPFLAGS) -I.)) \
	TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(strip $(TITAN_TEST_CFLAGS))) \
	TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(strip $(TITAN_TEST_LDFLAGS)))
STDLIB_BUSTED_TESTS := \
	spec/asan_generated_c_context_spec.lua spec/dense_array_runtime_spec.lua \
	spec/libuv_build_spec.lua spec/lpeglabel_build_spec.lua \
	spec/minicoro_spec.lua \
	spec/rockspec_spec.lua spec/titan_install_spec.lua

.PHONY: busted-test stdlib-busted-test stdlib-test \
	titan-stdlib-test-build titan-stdlib-test-objects titan-stdlib-test-run titan-stdlib-test

busted-test: ## Run retained Busted specs, optionally with BUSTED_FILTER
	$(TITAN_TEST_COMPILER_ENV) BUSTED=$(call make_shell_quote_value,BUSTED) \
		BUSTED_FILTER=$(call make_shell_quote_value,BUSTED_FILTER) \
		TITAN_ROCK_TEST_STDLIB_SPECS=$(call make_shell_quote_value,STDLIB_BUSTED_TESTS) \
		TITAN_ROCK_TEST_INTERNAL=1 \
		bash spec/support/run_rock_tests.sh $(EXTRA_TEST_FLAGS)

stdlib-busted-test: ## Run retained stdlib/runtime Busted specs without coverage
	$(TITAN_TEST_COMPILER_ENV) BUSTED=$(call make_shell_quote_value,BUSTED) \
		BUSTED_FILTER=$(call make_shell_quote_value,BUSTED_FILTER) \
		TITAN_ROCK_TEST_INTERNAL=1 \
		bash spec/support/run_rock_tests.sh \
		$(STDLIB_BUSTED_TESTS) $(EXTRA_TEST_FLAGS)

$(TITAN_TEST_CONFIG_STAMP): FORCE
	@mkdir -p $(call make_shell_quote,$(TITAN_TEST_BUILD_DIR))
	@set -e; \
	test -n $(call make_shell_quote,$(TITAN_TEST_INSTALL_ROOT)) && \
	  test -f $(call make_shell_quote,$(firstword $(TITAN_TEST_PROVIDER_PREREQS))) || { \
	  echo "ERROR: native tests require TEST_LUA from an installed Titan SDK" >&2; exit 1; \
	}; \
	tmp="$@.tmp"; \
	printf '%s\n' $(call make_shell_quote,TITAN_BUILD_PROFILE=$(TITAN_BUILD_PROFILE)) \
	  $(call make_shell_quote,TEST_TITANC=$(TEST_TITANC)) \
	  $(call make_shell_quote,TEST_LUA=$(TEST_LUA)) \
	  $(call make_shell_quote,CC=$(CC)) $(call make_shell_quote,AR=$(AR)) \
	  $(call make_shell_quote,RANLIB=$(RANLIB)) \
	  $(call make_shell_quote,SDK=$(TITAN_TEST_INSTALL_ROOT)) \
	  $(call make_shell_quote,CPPFLAGS=$(TITAN_TEST_CPPFLAGS)) \
	  $(call make_shell_quote,CFLAGS=$(TITAN_TEST_CFLAGS)) \
	  $(call make_shell_quote,LDFLAGS=$(TITAN_TEST_LDFLAGS)) \
	  $(call make_shell_quote,LINE_DIRECTIVES=$(TITAN_NO_LINE_DIRECTIVES)) \
	  $(call make_shell_quote,ROOTS=$(TITAN_STDLIB_TEST_ROOTS)) > "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then rm -f "$$tmp"; \
	else \
	  rm -f $(TITAN_TEST_MODULE_OBJECTS) \
	    $(TITAN_TEST_NATIVE_OBJECTS) $(TITAN_TEST_BUILD_DIR)/ssl_allocator_fixture.o \
	    $(TITAN_TEST_BUILD_DIR)/ssl_error_strings.o $(TITAN_TEST_BUILD_DIR)/os_descriptor_limit.o \
	    $(TITAN_TEST_BUILD_DIR)/os_process_host_child \
	    $(TITAN_TEST_EXECUTABLE); \
	  mv -f "$$tmp" "$@"; \
	fi

define titan_test_object_rule
$(call titan_test_stem,$(1)).o: FORCE $(TITAN_TEST_SOURCES_$(1)) $(TITAN_TEST_C_INPUTS_$(1)) \
	$(foreach dependency,$(TITAN_TEST_IMPORTS_$(1)),$(call titan_test_outputs,$(dependency))) \
	$(TITAN_TEST_COMPILER_PREREQS) $(TITAN_TEST_PROVIDER_PREREQS) $(TITAN_TEST_CONFIG_STAMP)
	@set -e; stale=0; \
	newer=$$(call make_shell_quote,$$(filter-out FORCE,$$?)); \
	test -z "$$$$newer" || stale=1; \
	for output in $(call titan_test_outputs,$(1)); do test -f "$$$$output" || stale=1; done; \
	if test "$$$$stale" = 1; then \
	  rm -f "$$@"; \
	  ( cd $$(call make_shell_quote,$$(TITAN_TEST_BUILD_DIR)); \
	    $$(TITAN_TEST_COMPILER_ENV) $$(TEST_TITANC) --output . --test --incremental -j1 -c \
	      --tree $$(call make_shell_quote,$$(abspath spec/stdlib/titan)) $(1) ); \
	  for output in $(call titan_test_outputs,$(1)); do \
	    test -f "$$$$output" || { echo "ERROR: test compilation did not produce $$$$output" >&2; exit 1; }; \
	  done; \
	fi
$(filter-out $(call titan_test_stem,$(1)).o,$(call titan_test_outputs,$(1))): $(call titan_test_stem,$(1)).o
	@test -f "$$@"
endef
$(foreach module,$(TITAN_TEST_MODULES),$(eval $(call titan_test_object_rule,$(module))))

titan-stdlib-test-objects: $(TITAN_TEST_MODULE_OBJECTS) ## Compile native test modules without linking the runner

$(TITAN_TEST_BUILD_DIR)/async_foreign_work.h: spec/fixtures/stdlib/native/async_foreign_work.h $(TITAN_TEST_CONFIG_STAMP)
	cp "$<" "$@"
$(TITAN_TEST_BUILD_DIR)/uv_stdio_probe.h: spec/fixtures/stdlib/native/uv_stdio_probe.h $(TITAN_TEST_CONFIG_STAMP)
	cp "$<" "$@"
$(TITAN_TEST_BUILD_DIR)/uv_coverage_threads.h: spec/fixtures/stdlib/native/uv_coverage_threads.h $(TITAN_TEST_CONFIG_STAMP)
	cp "$<" "$@"
$(TITAN_TEST_BUILD_DIR)/uv_coverage_pty.h: spec/fixtures/stdlib/native/uv_coverage_pty.h $(TITAN_TEST_CONFIG_STAMP)
	cp "$<" "$@"
$(TITAN_TEST_BUILD_DIR)/sqlite3_worker_fixture.h: spec/fixtures/stdlib/native/sqlite3_worker_fixture.h $(TITAN_TEST_CONFIG_STAMP)
	cp "$<" "$@"

# This allocation hook belongs only to an archive-linked SSL child, never the
# aggregate's native payload. Both ordinary and covered fixtures share it.
$(TITAN_TEST_BUILD_DIR)/ssl_allocator_fixture.h: spec/fixtures/stdlib/native/ssl_allocator_fixture.h $(TITAN_TEST_CONFIG_STAMP)
	cp "$<" "$@"
$(TITAN_TEST_BUILD_DIR)/ssl_allocator_fixture.o: spec/fixtures/stdlib/native/ssl_allocator_fixture.c $(TITAN_TEST_BUILD_DIR)/ssl_allocator_fixture.h $(STDLIB_C_INPUTS_ssl) $(OPENSSL_LIBS) $(TITAN_TEST_CONFIG_STAMP)
	$(CC) -std=c99 -Wall -Wextra -Werror -fPIC -pthread \
	  $(TITAN_TEST_CPPFLAGS) $(TITAN_TEST_CFLAGS) $(STDLIB_OPENSSL_CPPFLAGS) \
	  -Ispec/fixtures/stdlib/native -c "$<" -o "$@"

# These objects belong only to their fresh child processes. In particular,
# OpenSSL's sticky no-error-strings setting must never reach the aggregate.
$(TITAN_TEST_BUILD_DIR)/ssl_error_strings.h: spec/fixtures/stdlib/native/ssl_error_strings.h $(TITAN_TEST_CONFIG_STAMP)
	cp "$<" "$@"
$(TITAN_TEST_BUILD_DIR)/ssl_error_strings.o: spec/fixtures/stdlib/native/ssl_error_strings.c $(TITAN_TEST_BUILD_DIR)/ssl_error_strings.h $(STDLIB_C_INPUTS_ssl) $(OPENSSL_LIBS) $(TITAN_TEST_CONFIG_STAMP)
	$(CC) -std=c99 -Wall -Wextra -Werror -fPIC \
	  $(TITAN_TEST_CPPFLAGS) $(TITAN_TEST_CFLAGS) $(STDLIB_OPENSSL_CPPFLAGS) \
	  -Ispec/fixtures/stdlib/native -c "$<" -o "$@"
$(TITAN_TEST_BUILD_DIR)/os_descriptor_limit.h: spec/fixtures/stdlib/native/os_descriptor_limit.h $(TITAN_TEST_CONFIG_STAMP)
	cp "$<" "$@"
$(TITAN_TEST_BUILD_DIR)/os_descriptor_limit.o: spec/fixtures/stdlib/native/os_descriptor_limit.c $(TITAN_TEST_BUILD_DIR)/os_descriptor_limit.h $(TITAN_TEST_CONFIG_STAMP)
	$(CC) -std=c99 -Wall -Wextra -Werror -fPIC $(TITAN_TEST_CPPFLAGS) $(TITAN_TEST_CFLAGS) \
	  -Ispec/fixtures/stdlib/native -c "$<" -o "$@"

$(TITAN_TEST_BUILD_DIR)/async_foreign_work.o: spec/fixtures/stdlib/native/async_foreign_work.c $(TITAN_TEST_BUILD_DIR)/async_foreign_work.h $(TITAN_TEST_CONFIG_STAMP)
	$(CC) -std=c99 -Wall -Wextra -Werror -fPIC $(TITAN_TEST_CPPFLAGS) $(TITAN_TEST_CFLAGS) \
	  -Ispec/fixtures/stdlib/native -c "$<" -o "$@"
$(TITAN_TEST_BUILD_DIR)/fs_fixture.o: spec/fixtures/stdlib/native/fs_fixture.c spec/stdlib/titan/fs/fixture_support.h $(TITAN_TEST_COMPILER_PREREQS) $(TITAN_TEST_CONFIG_STAMP)
	$(CC) -std=c99 -Wall -Wextra -Werror -fPIC $(TITAN_TEST_CPPFLAGS) $(TITAN_TEST_CFLAGS) \
	  -c "$<" -o "$@"
$(TITAN_TEST_BUILD_DIR)/uv_stdio_probe.o: spec/fixtures/stdlib/native/uv_stdio_probe.c $(TITAN_TEST_BUILD_DIR)/uv_stdio_probe.h $(TITAN_TEST_CONFIG_STAMP)
	$(CC) -std=c99 -Wall -Wextra -Werror -fPIC $(TITAN_TEST_CPPFLAGS) $(TITAN_TEST_CFLAGS) \
	  -Ispec/fixtures/stdlib/native -c "$<" -o "$@"
$(TITAN_TEST_BUILD_DIR)/sqlite3_worker_fixture.o: spec/fixtures/stdlib/native/sqlite3_worker_fixture.c $(TITAN_TEST_BUILD_DIR)/sqlite3_worker_fixture.h $(SQLITE3_HEADER) $(TITAN_TEST_COMPILER_PREREQS) $(TITAN_TEST_CONFIG_STAMP)
	@set -e; \
	fixture_lua_include="$$( $(TEST_LUA) -E -e 'io.write(assert(require("titan-compiler.driver").LUA_SOURCE_PATH))' )"; \
	test -n "$$fixture_lua_include" && test -f "$$fixture_lua_include/lua.h"; \
	$(CC) -std=c99 -Wall -Wextra -Werror -fPIC -pthread \
	  $(TITAN_TEST_CPPFLAGS) $(TITAN_TEST_CFLAGS) $(SQLITE3_CPPFLAGS) \
	  -I"$$fixture_lua_include" -Ispec/fixtures/stdlib/native -c "$<" -o "$@"
$(TITAN_TEST_BUILD_DIR)/os_process_host_child: spec/fixtures/stdlib/native/os_process_host_child.c $(TITAN_TEST_CONFIG_STAMP)
	$(CC) -std=c99 -Wall -Wextra -Werror $(TITAN_TEST_CPPFLAGS) $(TITAN_TEST_CFLAGS) \
	  "$<" $(TITAN_TEST_LDFLAGS) -o "$@"

# A changed configuration can remove the executable after Make has cached its
# timestamp. Recheck its existence even when fast rebuilds share that timestamp.
$(TITAN_TEST_EXECUTABLE): FORCE $(TITAN_TEST_MODULE_OBJECTS) \
		$(TITAN_TEST_FIXTURE_OUTPUTS) $(TITAN_TEST_COMPILER_PREREQS) \
		$(TITAN_TEST_PROVIDER_PREREQS) $(TITAN_TEST_CONFIG_STAMP)
	@set -e; \
	newer=$(call make_shell_quote,$(filter-out FORCE,$?)); \
	if test -n "$$newer" || test ! -f "$@"; then \
	  cd $(call make_shell_quote,$(TITAN_TEST_BUILD_DIR)); \
	  $(TITAN_TEST_COMPILER_ENV) $(TEST_TITANC) --output . --test --incremental --no-uv-bootstrap \
	    --tree $(call make_shell_quote,$(abspath spec/stdlib/titan)) \
	    $(TITAN_STDLIB_TEST_ROOTS) -X async_foreign_work.o fs_fixture.o uv_stdio_probe.o; \
	fi

titan-stdlib-test-build: $(TITAN_TEST_EXECUTABLE) ## Build every native Titan stdlib test into one incremental executable

# The aggregate and its children run outside <prefix>/bin. Give them the
# selected installation's Lua paths instead of their executable-relative defaults.
titan-stdlib-test-run: ## Run the built native suite, optionally with TITAN_FILTER
	@test -x $(call make_shell_quote,$(TITAN_TEST_EXECUTABLE)) || { \
	  echo "ERROR: run 'make titan-stdlib-test-build' first" >&2; exit 1; \
	}
	@printf '%s\n' $(TITAN_STDLIB_TEST_ROOTS) > $(call make_shell_quote,$(TITAN_TEST_BUILD_DIR)/roots.txt)
	@status=0; \
	$(TITAN_TEST_COMPILER_ENV) \
	LUA_PATH_5_5="$$( $(TEST_LUA) -E -e 'io.write(package.path)' )" \
	LUA_CPATH_5_5="$$( $(TEST_LUA) -E -e 'io.write(package.cpath)' )" \
	TITAN_TEST_BUILD_DIR=$(call make_shell_quote,$(abspath $(TITAN_TEST_BUILD_DIR))) \
	TITAN_TEST_SOURCE_ROOT=$(call make_shell_quote,$(CURDIR)) \
	TITAN_TEST_SDK_ROOT=$(call make_shell_quote,$(TITAN_TEST_INSTALL_ROOT)) \
	TITAN_PROCESS_CHILD=$(call make_shell_quote,$(abspath $(TITAN_TEST_BUILD_DIR)/os_process_host_child)) \
	TITAN_FILTER=$(call make_shell_quote_value,TITAN_FILTER) \
	bash -o pipefail -c ' \
	  log=$$1; shift; \
	  if [[ -n $${TITAN_FILTER:-} ]]; then \
	    set -- "$$@" "--filter=$$TITAN_FILTER"; \
	  fi; \
	  bash spec/support/run_with_timeout.sh "$$@" 2>&1 | tee "$$log"' -- \
	  $(call make_shell_quote,$(TITAN_TEST_BUILD_DIR)/stdout.log) \
	  $(call make_shell_quote,$(TITAN_TEST_TIMEOUT)) \
	  $(call make_shell_quote,$(TITAN_TEST_EXECUTABLE)) || status=$$?; \
	$(TEST_LUA) -E spec/support/check_stdlib_test_output.lua \
	  $(call make_shell_quote,$(TITAN_TEST_BUILD_DIR)/stdout.log) \
	  $(call make_shell_quote,$(TITAN_TEST_BUILD_DIR)/roots.txt) \
	  $(call make_shell_quote_value,TITAN_FILTER); \
	audit=$$?; test "$$status" = 0 || exit "$$status"; exit "$$audit"

titan-stdlib-test: titan-stdlib-test-build ## Build and run all native Titan stdlib tests
	$(MAKE) titan-stdlib-test-run

stdlib-test: stdlib-busted-test ## Run all stdlib/runtime tests without coverage
	$(MAKE) titan-stdlib-test

# Coverage is the same native suite with source dependencies selected from this
# checkout. C and objects stay in .coverage directories inside the output tree.
# Linux exports the executable's Lua API for the suite's ordinary Lua C helpers.
TITAN_COVERAGE_BUILD_DIR ?= $(TITAN_OUTPUT_DIR)/coverage
TITAN_COVERAGE_REPORT_DIR ?= $(TITAN_COVERAGE_BUILD_DIR)/report
TITAN_COVERAGE_GCOV ?= gcov
TITAN_COVERAGE_GCOVR ?= gcovr
TITAN_COVERAGE_FORMATS ?=
TITAN_COVERAGE_CPPFLAGS = $(strip $(TITAN_TEST_CPPFLAGS) $(STDLIB_LPEGLABEL_CPPFLAGS) $(STDLIB_HTTP_CPPFLAGS) $(STDLIB_SQLITE3_CPPFLAGS) $(STDLIB_OPENSSL_CPPFLAGS) $(STDLIB_UV_CPPFLAGS) -I$(abspath $(TITAN_TEST_BUILD_DIR)))
TITAN_COVERAGE_EXECUTABLE = $(abspath $(TITAN_COVERAGE_BUILD_DIR))/$(TITAN_STDLIB_TEST_PROGRAM_OUTPUT)
.PHONY: titan-native-coverage-build titan-native-coverage-run titan-native-coverage
titan-native-coverage-build: $(STDLIB_NATIVE_PREREQS) $(TITAN_TEST_FIXTURE_OUTPUTS) ## Compile source-linked native tests with line coverage
	@mkdir -p $(call make_shell_quote,$(TITAN_COVERAGE_BUILD_DIR))
	@cd $(call make_shell_quote,$(TITAN_COVERAGE_BUILD_DIR)); \
	CC=$(call make_shell_quote,$(CC)) TITAN_BUILD_PROFILE=validation \
	TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(TITAN_COVERAGE_CPPFLAGS)) \
	TITAN_EXTRA_CFLAGS='-O0 -fno-lto' \
	TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(strip -O0 -fno-lto $(if $(filter Linux,$(HOST_OS)),-rdynamic) $(STDLIB_UV_LDFLAGS) $(STDLIB_OPENSSL_LDFLAGS))) \
	$(TEST_TITANC) --output . --test --no-uv-bootstrap --coverage \
	  --coverage-module 'titan.*' --coverage-root $(call make_shell_quote,$(CURDIR)) \
	  --coverage-gcov $(call make_shell_quote,$(TITAN_COVERAGE_GCOV)) \
	  --coverage-output $(call make_shell_quote,$(abspath $(TITAN_COVERAGE_REPORT_DIR))) \
	  --coverage-gcovr $(call make_shell_quote,$(TITAN_COVERAGE_GCOVR)) \
	  $(foreach format,$(TITAN_COVERAGE_FORMATS),--coverage-format $(format)) \
	  --tree $(call make_shell_quote,$(abspath spec/stdlib/titan);$(CURDIR)) \
	  $(TITAN_STDLIB_TEST_ROOTS) -X $(foreach object,$(STDLIB_EXTRA_OBJECTS),$(call make_shell_quote,$(abspath $(object)))) \
	    $(foreach object,$(filter-out %/sqlite3_worker_fixture.o,$(TITAN_TEST_NATIVE_OBJECTS)),$(call make_shell_quote,$(abspath $(object))))

titan-native-coverage-run: ## Run native coverage tests; the executable resets and reports its own counters
	+$(MAKE) titan-stdlib-test-run TITAN_TEST_EXECUTABLE=$(call make_shell_quote,$(TITAN_COVERAGE_EXECUTABLE))

titan-native-coverage: titan-native-coverage-build ## Compile and directly run native coverage tests
	+$(MAKE) titan-native-coverage-run

# A fresh implicit validation prefix needs a complete current installation.
# Re-enter after preparation so installed-SDK paths are expanded in a fresh
# Make process, just as LuaRocks' ordinary test backend does.
ifeq ($(TITAN_BUILD_PROFILE),validation)
  ifeq ($(wildcard $(PREFIX)/bin/titanc),)
    TITAN_ROCK_TEST_PREPARE := 1
  endif
endif
ifeq ($(TITAN_ROCK_TEST_PREPARE),1)
rock-test: ## Prepare the isolated validation SDK, then run both test domains
	$(MAKE) test
else
rock-test: busted-test ## Run retained Busted specs, then native Titan stdlib tests
	$(MAKE) titan-stdlib-test
endif

test: lua luarocks ## Build/install the rock and run the suite via `luarocks test`
	+$(RECURSIVE_WRAPPER_GUARD) unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5; \
	  PREFIX="$(PREFIX)" PATH="$(PREFIX)/bin:$$PATH" \
	  "$(PREFIX)/bin/luarocks" make --force
	+$(RECURSIVE_WRAPPER_GUARD) unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5; \
		PREFIX="$(PREFIX)" PATH="$(PREFIX)/bin:$$PATH" \
		EXTRA_TEST_FLAGS=$(call make_shell_quote,$(strip $(EXTRA_TEST_FLAGS))) \
		BUSTED_FILTER=$(call make_shell_quote_value,BUSTED_FILTER) \
		TITAN_FILTER=$(call make_shell_quote_value,TITAN_FILTER) \
		TITAN_TEST_TIMEOUT=$(call make_shell_quote,$(TITAN_TEST_TIMEOUT)) \
		"$(PREFIX)/bin/luarocks" test

examples: lua ## Compile the example Titan modules (SDL examples need SDL2 headers)
	$(MAKE) -C examples all

clean-stdlib: ## Remove standard-library artifacts before changing build inputs
	rm -f $(STDLIB_MODULE_OBJECTS) $(STDLIB_SHIMS) $(STDLIB_PROVIDER_OUTPUTS) $(STDLIB_COMPLETION_STAMP)
	rm -f $(STDLIB_GENERATED_FOREIGN_HEADERS) $(foreach module,$(STDLIB_MODULES),$(call stdlib_stem,$(module)).c)
	rm -rf $(STDLIB_CONTAINER).dSYM

clean: ## Remove generated build/test artifacts (keeps the Lua tree)
	rm -rf $(call make_shell_quote,$(TITAN_OUTPUT_DIR))
	bash spec/support/clean_generated_test_artifacts.sh
	rm -f $(RUNTIME_O) titan-runtime/*.o $(TITAN_RUNTIME_LIB)
	rm -f $(LPEGLABEL_OBJECTS) $(LPEGLABEL_ARCHIVE)
	rmdir "$(LPEGLABEL_BUILD_DIR)" 2>/dev/null || true
	rm -rf "$(LLHTTP_BUILD_DIR)"
	rm -f $(STDLIB_COMPLETION_STAMP)
	rm -f $(TITAN_BOOTSTRAP_SO)
	rm -rf $(TITAN_BOOTSTRAP_SO).dSYM
	rmdir titan-runtime/bootstrap 2>/dev/null || true
	rm -f titan/*.c titan/*.o
	rm -f titan/uv/*.c titan/uv/*.o
	rm -f titan/http/http.c titan/http/http.o
	rm -f titan/websocket/websocket.c titan/websocket/websocket.o
	rm -f titan/peg/peg.c titan/peg/peg.o
	rm -f titan/string/string.c titan/string/string.o
	rm -f titan/json/json.c titan/json/json.o
	rm -f $(STDLIB_GENERATED_FOREIGN_HEADERS)
	rm -f $(STDLIB_PROVIDER_OUTPUTS) $(STDLIB_QUALIFIED_SOS) $(STDLIB_SOS)
	rm -f $(STDLIB_SHIMS)
	rm -rf $(STDLIB_CONTAINER).dSYM
	rm -rf $(addsuffix .dSYM,$(STDLIB_SOS)) \
		$(addsuffix .dSYM,$(STDLIB_QUALIFIED_SOS))
	rm -f examples/*.c examples/*.o examples/*.so \
		examples/utils.a examples/artisanal.a examples/sdl_quit.a \
		examples/sdl_demo
	rm -f testfiles/*.c testfiles/*.o testfiles/*.so \
		testfiles/selection_sort.a testfiles/sieve.a
	rm -f *.c *.o *.so test
	rm -f luacov.stats.out luacov.report.out

clean-lua: ## Remove Lua build artifacts and the checkout-local install; preserve the submodule
	@if test -f "$(LUA_DIR)/Makefile"; then $(MAKE) -C "$(LUA_DIR)" clean; fi
	rm -f lua-5.*.tar.gz
	rm -rf .lua

clean-luarocks: ## Remove the downloaded LuaRocks source tree and tarball
	rm -rf $(LUAROCKS_DIR)
	rm -f $(LUAROCKS_TARBALL)

clean-libbacktrace: ## Remove the cloned libbacktrace source tree
	rm -rf $(LIBBT_DIR)

clean-libuv: ## Remove the bundled libuv source, build tree, and release tarball
	rm -rf $(LIBUV_SRC_DIR) $(LIBUV_BUILD_DIR)
	rm -f $(LIBUV_TARBALL)

clean-llhttp: ## Remove the private llhttp source, build tree, and release tarball
	rm -rf $(LLHTTP_SRC_DIR) $(LLHTTP_BUILD_DIR)
	rm -f $(LLHTTP_TARBALL)

clean-sqlite3: ## Remove the private SQLite amalgamation, build tree, and release tarball
	rm -rf "$(SQLITE3_SRC_DIR)" "$(SQLITE3_BUILD_DIR)" "$(SQLITE3_TARBALL)"

clean-openssl: ## Remove the bundled OpenSSL source/build trees and release tarball
	rm -rf $(OPENSSL_SRC_DIR) $(OPENSSL_BUILD_DIR)
	rm -f $(OPENSSL_TARBALL)

distclean: clean clean-lua clean-luarocks clean-libbacktrace clean-libuv clean-llhttp clean-sqlite3 clean-openssl ## Remove all downloaded trees and artifacts
