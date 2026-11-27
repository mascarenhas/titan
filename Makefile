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

# Implementation notes: doc/implementation/repository-workflow.md#choose-the-matching-profile-and-command
# Validation is an explicit native-toolchain profile, including runtime and
# provider dependencies. Choose it before Make expands the test graph.
TITAN_TEST_GOALS := test rock-test busted-test stdlib-test stdlib-busted-test \
	titan-stdlib-test titan-stdlib-test-build titan-stdlib-test-objects titan-stdlib-test-run \
	titan-stdlib-test-run-parallel titan-stdlib-browser-test \
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
# The offline pack delegates path normalization to Python, including spaces.
BROWSER_PACK_PREFIX := $(PREFIX)
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
LIBUV_BUILD_CONFIG := $(LIBUV_BUILD_DIR)/.titan-build.config
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
LUA_MYCFLAGS  ?= $(TITAN_PROFILE_HOST_FLAGS)
LUA_MYLDFLAGS ?= $(TITAN_PROFILE_HOST_FLAGS)
LUA_MYLIBS    ?=
LIBBT_CFLAGS  ?= -fPIC -g $(if $(filter validation,$(TITAN_BUILD_PROFILE)),$(TITAN_VALIDATION_FLAGS),-O2)
TITAN_EXTRA_CPPFLAGS ?=
TITAN_EXTRA_CFLAGS   ?=
TITAN_EXTRA_LDFLAGS  ?=
TITAN_NO_LINE_DIRECTIVES ?=
TITAN_JOBS ?= 4
# Implementation notes: doc/implementation/build-script-audit.md#make-job-pool-and-titanc-recipes
# GNU Make before 4.2 (macOS /usr/bin/make is 3.81) never shows -jN in
# MAKEFLAGS, so `make -j1` looks exactly like `make`. There a TITAN_JOBS taken
# only from this default keeps the serial build. An explicit TITAN_JOBS
# enables the compiler's local pool; a supported inherited jobserver still
# imposes the caller's global limit.
TITAN_MAKE_HIDES_JOBS := $(filter 3.% 4.0 4.1,$(MAKE_VERSION))
TITAN_JOBS_SERIAL_DEFAULT := $(if $(TITAN_MAKE_HIDES_JOBS),$(filter file,$(origin TITAN_JOBS)))
ifneq ($(TITAN_JOBS_SERIAL_DEFAULT),)
TITAN_JOBS := 1
endif
export CLANG_FORMAT TITAN_EXTRA_CPPFLAGS TITAN_EXTRA_CFLAGS \
	TITAN_EXTRA_LDFLAGS TITAN_NO_LINE_DIRECTIVES
# Keep every Titan compiler output in a separate, removable tree. Native
# runtime and dependency builds retain their existing build directories.
TITAN_OUTPUT_DIR ?= out
TITAN_VERBOSE ?=
TITAN_VERBOSE_FLAG = $(if $(filter 1,$(TITAN_VERBOSE)),-v)

RUNTIME_O := titan-runtime/titan.o
MINICORO_O := titan-runtime/minicoro.o
TITAN_PATH_O := titan-runtime/titan_path.o
LTITANLIB_O := titan-runtime/ltitanlib.o
# ltitanlib.o is archived too, so static hosts can link and preload the
# `titan` support module; ordinary links pull it only when referenced.
TITAN_RUNTIME_OBJECTS := $(RUNTIME_O) $(MINICORO_O) $(TITAN_PATH_O) $(LTITANLIB_O)
TITAN_RUNTIME_LIB := titan-runtime/libtitan.a
TITAN_RUNTIME_SOURCES := titan-runtime/titan.c titan-runtime/minicoro.c \
	titan-runtime/titan_path.c titan-runtime/ltitanlib.c
TITAN_SDK_ROOT_HEADERS := titan-runtime/minicoro.h titan-runtime/titan.h titan-runtime/transfer.h
TITAN_SDK_NAMESPACED_HEADERS := titan-runtime/titan/ffi.h titan-runtime/titan/browser.h

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

# Every standard-library Titan source is listed here explicitly. A target
# variant (`name.<label>.titan`, labels windows/darwin/linux/browser and the
# umbrella native) follows its default (`name.titan`) when one exists; a
# variant-only family lists just its variants. There are no wildcards. Only
# the selected variant of a family compiles, so the Busted source-policy audits
# read this inventory family by family and fail on a folder file no entry declares.
# Implementation notes: doc/implementation/target-source-selection.md#make-inventories-and-audits
UV_TITAN_SOURCES := \
	titan/uv/uv.native.titan \
	titan/uv/address.titan \
	titan/uv/callbacks.titan \
	titan/uv/capabilities.titan \
	titan/uv/constants.titan \
	titan/uv/data.titan \
	titan/uv/dll.titan \
	titan/uv/dns.titan \
	titan/uv/external_wake.titan \
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
	titan/uv/transfer.titan \
	titan/uv/udp.titan \
	titan/uv/utilities.titan
UV_TITAN_HEADERS := \
	titan/uv/address-native.h \
	titan/uv/callback.h \
	titan/uv/data_native.h \
	titan/uv/external-wake-native.h \
	titan/uv/fd-native.h \
	titan/uv/network-native.h \
	titan/uv/platform-constants.h \
	titan/uv/sync_storage.h \
	titan/uv/thread-native.h \
	titan/uv/transfer-native.h \
	titan/uv/utility_bits.h \
	titan/uv/version-native.h \
	titan/uv/work-data.h
ASYNC_TITAN_SOURCES := titan/async/async.titan \
	titan/async/external.native.titan titan/async/external.browser.titan \
	titan/async/foreign.native.titan titan/async/receiver.native.titan \
	titan/async/runtime.native.titan titan/async/runtime.browser.titan
ASYNC_TITAN_HEADERS := titan/async/async_receiver_native.h titan/async/async_signal_platform.h
OS_TITAN_SOURCES := titan/os/os.titan \
	titan/os/clock.native.titan titan/os/clock.browser.titan \
	titan/os/environment.native.titan titan/os/environment.browser.titan \
	titan/os/process.native.titan titan/os/process.browser.titan \
	titan/os/stdio.native.titan titan/os/stdio.browser.titan
OS_TITAN_HEADERS := titan/os/os_platform.h titan/os/os_environment.h \
	titan/os/environment.browser.h
STDLIB_HTTP_SOURCES := titan/http/http.titan titan/http/client.native.titan \
	titan/http/client.browser.titan titan/http/native_imports.native.titan \
	titan/http/headers.titan titan/http/options.titan titan/http/parser.native.titan \
	titan/http/pool.native.titan titan/http/server.native.titan \
	titan/http/transfer.native.titan titan/http/upgrade.native.titan
SQLITE3_TITAN_SOURCES := titan/sqlite3/sqlite3.native.titan titan/sqlite3/bindings.titan \
	titan/sqlite3/row.titan titan/sqlite3/worker.titan
SQLITE3_TITAN_HEADERS := titan/sqlite3/native.h
LUA_TITAN_SOURCES := titan/lua/lua.titan titan/lua/background.native.titan \
	titan/lua/loading.browser.titan titan/lua/loading.native.titan titan/lua/worker.titan
LUA_TITAN_HEADERS := titan/lua/native.h
STRING_TITAN_HEADERS := titan/string/format_native.h
WEBSOCKET_TITAN_SOURCES := titan/websocket/websocket.native.titan titan/websocket/handshake.native.titan \
	titan/websocket/connection.native.titan titan/websocket/frames.native.titan \
	titan/websocket/types.titan titan/websocket/utf8.titan titan/websocket/crypto.native.titan \
	titan/websocket/websocket.browser.titan titan/websocket/client.browser.titan
JSON_TITAN_SOURCES := titan/json/json.titan titan/json/parser.titan \
	titan/json/decoder.titan titan/json/writer.titan titan/json/numbers.titan
PROTOBUF_TITAN_SOURCES := titan/protobuf/protobuf.titan titan/protobuf/encoder.titan \
	titan/protobuf/decoder.titan titan/protobuf/portable.titan titan/protobuf/schema.titan \
	titan/protobuf/trace.titan
THREAD_TITAN_SOURCES := titan/thread/thread.native.titan titan/thread/channel.titan \
	titan/thread/group.titan titan/thread/spawn.titan
THREAD_TITAN_HEADERS := titan/thread/native.h
STDLIB_MODULES := coroutine uv async timer io fs net ssl url http websocket os path peg string \
	math lua iteration gc test reflect sqlite3 json protobuf transfer thread
STDLIB_SOS     := $(addsuffix .so,$(STDLIB_MODULES))
STDLIB_QUALIFIED_SOS := $(addprefix titan/,$(STDLIB_SOS))
STDLIB_ROOTS := titan.coroutine titan.uv titan.async titan.timer \
	titan.io titan.fs titan.net titan.ssl titan.url titan.http titan.websocket titan.os titan.path \
	titan.peg titan.string \
	titan.math titan.lua titan.iteration titan.gc titan.test titan.reflect titan.sqlite3 titan.json titan.protobuf titan.transfer titan.thread
STDLIB_TITAN_SOURCES := titan/coroutine.titan $(UV_TITAN_SOURCES) \
	$(ASYNC_TITAN_SOURCES) titan/timer.native.titan titan/timer.browser.titan titan/io.titan titan/fs.native.titan \
	titan/net.native.titan titan/ssl.native.titan titan/url.titan \
	$(STDLIB_HTTP_SOURCES) $(WEBSOCKET_TITAN_SOURCES) $(OS_TITAN_SOURCES) titan/path.titan \
	titan/peg/peg.titan titan/peg/combinators.titan \
	titan/peg/native.titan \
	titan/peg/relabel.titan titan/peg/relabel_parser.titan \
	titan/string/string.titan titan/string/bytes.titan \
	titan/string/format.titan titan/string/pack.titan \
	titan/string/regex_api.titan titan/string/regex_compile.titan \
	titan/string/regex_parser.titan \
	titan/math.titan $(LUA_TITAN_SOURCES) titan/iteration.titan titan/gc.titan \
	titan/test.titan titan/reflect.titan $(SQLITE3_TITAN_SOURCES) \
	$(JSON_TITAN_SOURCES) $(PROTOBUF_TITAN_SOURCES) titan/transfer.titan $(THREAD_TITAN_SOURCES)
STDLIB_GENERATED_FFI_HEADERS := $(addprefix $(TITAN_OUTPUT_DIR)/,$(addsuffix .ffi.h, \
	$(addprefix titan/,$(filter-out uv async os http websocket peg string sqlite3 json lua protobuf thread,$(STDLIB_MODULES))) \
	titan/uv/uv titan/async/async titan/os/os titan/http/http titan/websocket/websocket titan/peg/peg titan/string/string \
	titan/sqlite3/sqlite3 titan/json/json titan/lua/lua titan/protobuf/protobuf titan/thread/thread))
STDLIB_GENERATED_FOREIGN_HEADERS := $(STDLIB_GENERATED_FFI_HEADERS) \
	$(addprefix $(TITAN_OUTPUT_DIR)/,titan/coroutine.titan.h \
	titan/uv/uv.titan.h titan/async/async.titan.h titan/http/http.titan.h \
	titan/sqlite3/sqlite3.titan.h titan/lua/lua.titan.h titan/protobuf/protobuf.titan.h \
	titan/transfer.titan.h titan/thread/thread.titan.h)
STDLIB_CONTAINER := $(TITAN_OUTPUT_DIR)/titan.so
STDLIB_STATIC_ARCHIVE := $(TITAN_OUTPUT_DIR)/titan.a
STDLIB_PROVIDER_OUTPUTS := $(STDLIB_CONTAINER) $(STDLIB_STATIC_ARCHIVE)
STDLIB_EXTRA_OBJECTS := $(LPEGLABEL_ARCHIVE) \
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
# The `titan` Lua support module: ltitanlib plus the shared path code. The
# checkout compiler loads it from here; installs deploy it to lib/lua/5.5.
TITAN_SUPPORT_MODULE := titan-runtime/bootstrap/titan.so
STDLIB_BOOTSTRAP_PREREQ := $(TITAN_SUPPORT_MODULE)
# The support module is an ordinary Lua C module exporting only luaopen_titan;
# titan_path.o's globals stay local to this image so a process that also
# preloads libtitan.a (the language server) cannot interpose them.
TITAN_SUPPORT_EXPORTS := scripts/titan_support_exports.map
ifeq ($(HOST_OS),Darwin)
  TITAN_SUPPORT_EXPORT_FLAGS ?= -Wl,-exported_symbol,_luaopen_titan
else
  TITAN_SUPPORT_EXPORT_FLAGS ?= -Wl,--version-script=$(TITAN_SUPPORT_EXPORTS)
endif
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
TITAN_ROOT ?=
export TITAN_ROOT
ifeq ($(origin TITAN_LUA),undefined)
  BROWSER_PACK_LUA = $(BROWSER_PACK_PREFIX)/bin/lua
endif
TITAN_LUA ?= $(or $(realpath $(ROCK_LUA)),$(ROCK_LUA))
# Stdlib development uses the deployed compiler and its matching SDK once
# installed. The checkout compiler remains the bootstrap path and an explicit
# option through STDLIB_USE_INSTALLED_RUNTIME=0. Canonicalize only these build
# inputs, so a LuaRocks /var/home root and a PATH /home alias select one SDK.
STDLIB_INSTALLED_ROOT = $(or $(realpath $(TITAN_INSTALL_TREE)),$(abspath $(TITAN_INSTALL_TREE)))
STDLIB_ROCKS_ROOT = $(if $(strip $(TITAN_ROOT)),$(or $(realpath $(TITAN_ROOT)),$(abspath $(TITAN_ROOT))),$(if $(filter 1,$(STDLIB_USE_INSTALLED_RUNTIME)),$(STDLIB_INSTALLED_ROOT)))
# Dependencies may live in a separate LuaRocks tree. The source compiler and
# its private native support must still take precedence over any installed Titan.
SOURCE_COMPILER_SETUP = local root=os.getenv("ROCKS_TREE"); \
	if root and root~="" then \
	package.path=root .. "/share/lua/5.5/?.lua;" .. root .. "/share/lua/5.5/?/init.lua;" .. package.path; \
	package.cpath=root .. "/lib/lua/5.5/?.so;" .. package.cpath end; \
	package.path="./?.lua;./?/init.lua;" .. package.path; \
	package.cpath="./titan-runtime/bootstrap/?.so;" .. package.cpath
# Distinct from the runtime `TITANC` command that the SDK fallback spawns:
# a command-line Make variable is exported into every recipe environment.
STDLIB_TITANC ?= $(if $(filter 1,$(STDLIB_USE_INSTALLED_RUNTIME)),$(call make_shell_quote,$(STDLIB_INSTALLED_ROOT)/bin/titanc),$(call make_shell_quote,$(TITAN_LUA)) -E -e $(call make_shell_quote,$(SOURCE_COMPILER_SETUP)) ./titanc --lua $(call make_shell_quote,$(abspath $(TITAN_RUNTIME_LUA_SOURCE_PATH))))

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
TITAN_VERSION              := 0.6.2
TITAN_VERSION_COMPONENTS   := $(subst ., ,$(TITAN_VERSION))
TITAN_LIBRARY_VERSION      := $(word 1,$(TITAN_VERSION_COMPONENTS)).$(word 2,$(TITAN_VERSION_COMPONENTS))
TITAN_LIBRARY_VERSION_SUFFIX := _$(subst .,_,$(TITAN_LIBRARY_VERSION))
TITAN_STDLIB_VERSION_DIR   ?= $(TITAN_INSTALL_TREE)/lib/titan/$(TITAN_LIBRARY_VERSION)
TITAN_CANONICAL_PROVIDER_SO ?= $(TITAN_STDLIB_VERSION_DIR)/titan.so
TITAN_CANONICAL_STATIC_ARCHIVE ?= $(TITAN_STDLIB_VERSION_DIR)/titan.a
TITAN_SHARE_DIR            ?= $(TITAN_INSTALL_TREE)/share/titan

# libbacktrace is cloned + built into ./libbacktrace (gitignored), mirroring the
# ./lua-5.5.1 tree. The generated C and the runtime include its backtrace.h and
# link its static archive (driver.lua references ./libbacktrace/.libs/...).
LIBBT_DIR := libbacktrace
LIBBT_URL ?= https://github.com/ianlancetaylor/libbacktrace.git
LIBBT_LIB := $(LIBBT_DIR)/.libs/libbacktrace.a
LIBBT_CLONE_STAMP := $(LIBBT_DIR)/.titan-cloned
LIBBT_CONFIG_STAMP := $(LIBBT_DIR)/.titan-build.config

# These wrappers indirectly launch recursive Make processes or titanc. The `+`
# recipe marker preserves the parent jobserver; this guard keeps that marker
# from turning Make's dry-run, query, or touch modes into real wrapper
# execution. Mode letters appear as GNU Make 4's leading flag word (`kn`) or,
# in GNU Make 3.81 when a long option is present, as a dash word (`-nk`).
# Only words made of no-argument flag letters count: 3.81 passes `NAME=value`
# overrides without `--` when no flag is present, and option arguments such
# as `-Onone` or `-I/tmp/include` may contain n, q, or t.
RECURSIVE_WRAPPER_GUARD = titan_mode=; set -f; set -- $$MAKEFLAGS; set +f; \
	for titan_word do case "$$titan_word" in --) break ;; --*) ;; \
	  *[!-BLRSdeijknpqrstvw]*) ;; *) titan_mode=$$titan_mode$$titan_word ;; esac; done; \
	case "$$titan_mode" in *q*) exit 1 ;; *n*|*t*) exit 0 ;; esac;


.PHONY: all help lua luarocks libbacktrace libuv libuv-config llhttp \
	check-llhttp-tools sqlite3 check-sqlite3-tools openssl openssl-config check-openssl-tools \
	check-system-openssl invalid-openssl-mode lpeglabel \
	check-libuv-tools runtime \
	install-compiler-sdk install-titan-sdk publish-titan-sdk \
	stdlib stdlib-objects install-stdlib \
	install publish-stdlib \
	rock-test test rock-build \
	clean clean-stdlib clean-lua clean-luarocks clean-libbacktrace clean-libuv \
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
	  $(MAKE) -C "$(LUA_DIR)" $(LUA_PLATFORM) PREFIX="$(PREFIX)" \
	    CC=$(call make_shell_quote,$(LUA_CC)) \
	    AR=$(call make_shell_quote,$(LUA_AR)) \
	    RANLIB=$(call make_shell_quote,$(LUA_RANLIB)) \
	    MYCFLAGS=$(call make_shell_quote,$(LUA_MYCFLAGS)) \
	    MYLDFLAGS=$(call make_shell_quote,$(LUA_MYLDFLAGS)) \
	    MYLIBS=$(call make_shell_quote,$(LUA_MYLIBS)); \
	  $(MAKE) -C "$(LUA_DIR)" install PREFIX="$(PREFIX)"; \
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

# Implementation notes: doc/implementation/build-script-audit.md#native-dependency-configuration-stamps
# FORCE recomputes the recorded configuration on every run, but the stamp is
# replaced only when its content changes, so an unchanged build keeps its
# timestamp and nothing rebuilds. Only the archive below depends on it.
$(LIBBT_CONFIG_STAMP): FORCE | $(LIBBT_CLONE_STAMP)
	@set -e; tmp="$@.tmp"; \
	printf '%s\n' $(call make_shell_quote,TITAN_BUILD_PROFILE=$(TITAN_BUILD_PROFILE)) \
	  $(call make_shell_quote,CC=$(CC)) $(call make_shell_quote,AR=$(AR)) \
	  $(call make_shell_quote,RANLIB=$(RANLIB)) \
	  $(call make_shell_quote,LIBBT_CFLAGS=$(LIBBT_CFLAGS)) > "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then rm -f "$$tmp"; else mv -f "$$tmp" "$@"; fi

# Configure does not rebuild existing objects for new flags, so a rebuild
# starts from a clean tree.
$(LIBBT_LIB): $(LIBBT_CLONE_STAMP) $(LIBBT_CONFIG_STAMP)
	@echo "==> Building libbacktrace (configure + make, $(LIBBT_CFLAGS))"
	@if test -f "$(LIBBT_DIR)/Makefile"; then $(MAKE) -C "$(LIBBT_DIR)" clean; fi
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

# Implementation notes: doc/implementation/build-script-audit.md#native-dependency-configuration-stamps
# As for libbacktrace: rewritten only when the configuration changes, and
# only the archive depends on it.
$(LIBUV_BUILD_CONFIG): FORCE
	@set -e; mkdir -p "$(LIBUV_BUILD_DIR)"; tmp="$@.tmp"; \
	printf '%s\n' $(call make_shell_quote,CC=$(CC)) \
	  $(call make_shell_quote,LIBUV_CMAKE_FLAGS=$(LIBUV_CMAKE_FLAGS)) \
	  $(call make_shell_quote,LIBUV_BUILD_CFLAGS=$(LIBUV_BUILD_CFLAGS)) > "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then rm -f "$$tmp"; else mv -f "$$tmp" "$@"; fi

# A rebuild discards the CMake cache: it would keep an earlier compiler and,
# when LIBUV_BUILD_CFLAGS becomes empty, earlier C flags.
$(LIBUV_LIB): $(LIBUV_EXTRACTED) $(LIBUV_BUILD_CONFIG)
	@$(MAKE) --no-print-directory check-libuv-tools
	@echo "==> Configuring libuv $(LIBUV_VERSION) (static, PIC, $(LIBUV_BUILD_TYPE))"
	rm -rf "$(LIBUV_BUILD_DIR)/CMakeCache.txt" "$(LIBUV_BUILD_DIR)/CMakeFiles"
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

$(RUNTIME_O): titan-runtime/titan.c titan-runtime/titan.h titan-runtime/transfer.h \
		titan-runtime/titan/ffi.h $(LIBBT_DIR)/backtrace.h \
		$(TITAN_RUNTIME_LUA_HEADERS) | $(TITAN_RUNTIME_LUA_LIB) $(LIBBT_LIB)
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(CFLAGS) $(TITAN_EXTRA_CFLAGS) \
		-c titan-runtime/titan.c -I titan-runtime -I $(TITAN_RUNTIME_LUA_SOURCE_PATH) \
		-I $(LIBBT_DIR) -o $@

$(MINICORO_O): titan-runtime/minicoro.c \
		titan-runtime/minicoro.h titan-runtime/titan.h titan-runtime/transfer.h \
		titan-runtime/titan/ffi.h \
		$(TITAN_RUNTIME_LUA_HEADERS) | $(TITAN_RUNTIME_LUA_LIB) $(LIBBT_LIB)
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(CFLAGS) $(TITAN_EXTRA_CFLAGS) \
		-c titan-runtime/minicoro.c -I titan-runtime -I $(TITAN_RUNTIME_LUA_SOURCE_PATH) \
		-I $(LIBBT_DIR) -o $@

# titan_path.c includes only the Lua SDK and titan.h (plus titan_winloader.h
# for _WIN32), and the support module links nothing else. Ordering it behind
# the runtime archive and libbacktrace would make a direct `make
# install-compiler` rebuild unrelated native dependencies.
$(TITAN_PATH_O): titan-runtime/titan_path.c titan-runtime/titan.h \
		titan-runtime/transfer.h titan-runtime/titan/ffi.h \
		$(TITAN_RUNTIME_LUA_HEADERS)
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(CFLAGS) $(TITAN_EXTRA_CFLAGS) \
		-c titan-runtime/titan_path.c -I titan-runtime -I $(TITAN_RUNTIME_LUA_SOURCE_PATH) \
		-o $@

# ltitanlib.c includes titan.h and titan_winloader.h only for _WIN32, where
# scripts/build_windows_runtime.sh tracks every titan-runtime/*.h header.
$(LTITANLIB_O): titan-runtime/ltitanlib.c \
		$(wildcard $(ROCK_LUA_HEADERS)) $(LUA_SDK_PREREQ)
	$(CC) $(ROCK_CFLAGS) $(TITAN_EXTRA_CFLAGS) \
		-I"$(ROCK_LUA_INCDIR)" -c "$<" -o "$@"

$(TITAN_RUNTIME_LIB): $(TITAN_RUNTIME_OBJECTS)
	rm -f "$@"
	$(AR) rcs "$@" $(TITAN_RUNTIME_OBJECTS)
	$(RANLIB) "$@"

# An ordinary Lua C module exporting only luaopen_titan; it needs neither the
# standard library nor the rest of the runtime.
$(TITAN_SUPPORT_MODULE): $(LTITANLIB_O) $(TITAN_PATH_O) $(TITAN_SUPPORT_EXPORTS)
	@mkdir -p "$(@D)"
	@set -e; tmp="$@.tmp"; rm -f "$$tmp"; \
	if $(ROCK_LD) $(ROCK_LIBFLAG) $(TITAN_SUPPORT_EXPORT_FLAGS) -o "$$tmp" \
		$(LTITANLIB_O) $(TITAN_PATH_O) $(TITAN_EXTRA_LDFLAGS); then \
		mv -f "$$tmp" "$@"; \
	else \
		status=$$?; rm -f "$$tmp"; exit $$status; \
	fi

# The installed compiler loads the support module from lib/lua/5.5. Direct
# installs build it first; the LuaRocks install pass (INST_PREFIX) only copies
# what its build pass produced.
ifeq ($(strip $(INST_PREFIX)),)
install-compiler: $(TITAN_SUPPORT_MODULE)
endif

# Build with this source rock's compiler, even when another Titan is installed.
# The checkout support module supplies native compiler support without
# publishing anything into the destination tree.
all: lpeglabel libbacktrace libuv openssl llhttp sqlite3 $(TITAN_RUNTIME_LIB) $(TITAN_SUPPORT_MODULE) ## Build the runtime and paired standard library (default)
	$(MAKE) --no-print-directory stdlib STDLIB_USE_INSTALLED_RUNTIME=0 TITAN_ROOT=

# Implementation notes: doc/implementation/build-script-audit.md#installation-and-publication
# LuaRocks runs this in the same source directory as the build pass. Compiler
# files and the support module enter its ordinary staging directories. The
# retained payload is published by post_install for both source and binary rocks.
ifneq ($(strip $(INST_PREFIX)),)
install: install-compiler install-rock-tools stage-rock-payload ## Stage the built compiler, SDK and standard library
.PHONY: stage-rock-payload
stage-rock-payload:
	+$(MAKE) --no-print-directory publish-titan-sdk publish-stdlib \
	  TITAN_INSTALL_TREE="$(INST_PREFIX)/titan-sdk"
else
install: install-compiler publish-titan-sdk publish-stdlib ## Copy the built compiler, SDK and standard library
endif

# PREFIX owns installed Lua. Stage that SDK into a separate ROCKS_TREE, while
# leaving Lua-owned files in place when both installation roots are the same.
TITAN_RUNTIME_SDK_PREREQS := $(TITAN_RUNTIME_LIB) \
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

# The compiler SDK carries no standard-module metadata or archive provider.
install-compiler-sdk: install-compiler $(TITAN_RUNTIME_SDK_PREREQS) ## Build and install the compiler/runtime SDK without the standard library
	@set -e; \
	$(TITAN_RUNTIME_SDK_COPY); \
	mkdir -p "$$rocks_tree/etc/titan"; \
	printf '%s\n' $(call make_shell_quote,$(TITAN_BUILD_PROFILE)) > "$$rocks_tree/etc/titan/build-profile"

install-titan-sdk: $(TITAN_RUNTIME_SDK_PREREQS) $(LIBUV_LIB) $(OPENSSL_LIBS) \
	$(LLHTTP_HEADER) $(SQLITE3_HEADER)
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
# and its private archive goes to titanc through the same -X payload as the
# private LPegLabel archive.
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


# Both entry points select the complete graph; only the final link receives
# the native payload. titanc certifies all objects and final artifacts.
STDLIB_COMPILER_ENV = CC=$(call make_shell_quote,$(CC)) \
	AR=$(call make_shell_quote,$(AR)) RANLIB=$(call make_shell_quote,$(RANLIB)) \
	ROCKS_TREE=$(call make_shell_quote,$(TITAN_INSTALL_TREE)) \
	TITAN_PATH$(TITAN_LIBRARY_VERSION_SUFFIX)=$(call make_shell_quote,$(CURDIR)) TITAN_PATH= \
	TITAN_ROOT=$(call make_shell_quote,$(STDLIB_ROCKS_ROOT)) TITAN_RUNTIME_PREBUILT=1 \
	TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CPPFLAGS) $(STDLIB_LPEGLABEL_CPPFLAGS) $(STDLIB_HTTP_CPPFLAGS) $(STDLIB_SQLITE3_CPPFLAGS) $(STDLIB_OPENSSL_CPPFLAGS) $(STDLIB_UV_CPPFLAGS))) \
	TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CFLAGS) $(STDLIB_UV_CFLAGS))) \
	TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_LDFLAGS) $(STDLIB_UV_LDFLAGS) $(STDLIB_OPENSSL_LDFLAGS)))

stdlib-objects: $(STDLIB_NATIVE_PREREQS) $(STDLIB_TOOL_PREREQS) $(STDLIB_BOOTSTRAP_PREREQ) $(STDLIB_RUNTIME_ARCHIVE_PREREQ) $(STDLIB_PLATFORM_PREREQS) ## Compile standard-library objects without linking a provider
	+@$(RECURSIVE_WRAPPER_GUARD) $(TITAN_JOBS_CHECK) \
	unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 TITAN_TARGET; \
	$(STDLIB_COMPILER_ENV) $(STDLIB_TITANC) --output $(call make_shell_quote,$(TITAN_OUTPUT_DIR)) --source-first --incremental -j$(TITAN_JOBS) $(TITAN_VERBOSE_FLAG) -c $(STDLIB_ROOTS)

stdlib: $(STDLIB_NATIVE_PREREQS) $(STDLIB_TOOL_PREREQS) $(STDLIB_BOOTSTRAP_PREREQ) $(STDLIB_RUNTIME_ARCHIVE_PREREQ) $(STDLIB_PLATFORM_PREREQS) ## Build the paired standard-library provider
	+@$(RECURSIVE_WRAPPER_GUARD) $(TITAN_JOBS_CHECK) \
	unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 TITAN_TARGET; \
	$(STDLIB_COMPILER_ENV) $(STDLIB_TITANC) --output $(call make_shell_quote,$(TITAN_OUTPUT_DIR)) --source-first --incremental -j$(TITAN_JOBS) $(TITAN_VERBOSE_FLAG) \
	  $(STDLIB_ROOTS) -X $(STDLIB_EXTRA_OBJECTS)

install-stdlib: stdlib ## Install the paired standard library from this source tree
publish-stdlib: ## Copy an already built standard library from STDLIB_INSTALL_STAGE
install-stdlib publish-stdlib:
	@set -e; \
	stage=$(call make_shell_quote,$(STDLIB_INSTALL_STAGE)); \
	mkdir -p "$(TITAN_STDLIB_VERSION_DIR)" "$(TITAN_SHARE_DIR)/LICENSES"; \
	if test -n $(call make_shell_quote,$(strip $(TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT))); then \
	  $(STDLIB_COMPILER_ENV) "$(TITAN_LUA)" -E \
	    "$(CURDIR)/spec/support/ci_asan_generated_c_context.lua" snapshot \
	    $(call make_shell_quote,$(strip $(TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT))) \
	    "$$stage/titan.so" "$$stage/titan" \
	    "$(TITAN_CANONICAL_PROVIDER_SO)" "$(CURDIR)/titan"; \
	fi; \
	install -p -m 0755 "$$stage/titan.so" "$(TITAN_CANONICAL_PROVIDER_SO)"; \
	install -p -m 0644 "$$stage/titan.a" "$(TITAN_CANONICAL_STATIC_ARCHIVE)"; \
	rm -f "$(TITAN_SHARE_DIR)/$(TITAN_LIBRARY_VERSION)/src/titan/test.titan"; \
	if test -d "$$stage/titan.so.dSYM"; then \
	  rm -rf "$(TITAN_CANONICAL_PROVIDER_SO).dSYM"; \
	  cp -pR "$$stage/titan.so.dSYM" "$(TITAN_CANONICAL_PROVIDER_SO).dSYM"; \
	fi; \
	install -p -m 0644 THIRD_PARTY_NOTICES.md "$(TITAN_SHARE_DIR)/THIRD_PARTY_NOTICES.md"; \
	install -p -m 0644 $(STDLIB_LICENSES) "$(TITAN_SHARE_DIR)/LICENSES/"

BROWSER_COMPILER_REMEDY := run 'luarocks make' or 'make install-compiler-sdk' first
include $(TITAN_MAKEFILE_DIR)scripts/browser.mk

# Compatibility name for callers of the former rockspec build target.
rock-build: all

TITAN_TEST_MODULE_MANIFEST := $(TITAN_MAKEFILE_DIR)spec/support/stdlib_test_modules.mk
include $(TITAN_TEST_MODULE_MANIFEST)
TITAN_TEST_BUILD_DIR ?= $(TITAN_OUTPUT_DIR)/tests
TITAN_TEST_EXECUTABLE := $(TITAN_TEST_BUILD_DIR)/$(TITAN_STDLIB_TEST_PROGRAM_OUTPUT)
# The suite deadline includes fresh child-fixture compilation at the selected
# native profile across all audited test owners, including fresh child compilers.
# Focused gates may set a lower bound.
TITAN_TEST_TIMEOUT ?= 600
TITAN_TEST_JOBS ?= 4
# One run's merged output, audited afterwards against the root inventory
# written beside it. Concurrent filtered runs of one built executable need
# distinct logs (and their own TMPDIR); the defaults are the shared
# out/tests/stdout.log and out/tests/roots.txt.
TITAN_TEST_RUN_LOG ?= $(TITAN_TEST_BUILD_DIR)/stdout.log
ifeq ($(origin TITAN_TEST_RUN_LOG),file)
TITAN_TEST_RUN_ROOTS := $(TITAN_TEST_BUILD_DIR)/roots.txt
else
TITAN_TEST_RUN_ROOTS = $(TITAN_TEST_RUN_LOG).roots
endif
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
TITAN_TEST_C_SOURCES := spec/fixtures/stdlib/native/async_foreign_work.c \
	spec/fixtures/stdlib/native/fs_fixture.c spec/fixtures/stdlib/native/uv_stdio_probe.c
TITAN_TEST_FIXTURE_OUTPUTS := $(addprefix $(TITAN_TEST_BUILD_DIR)/,async_foreign_work.h uv_stdio_probe.h uv_stdio_probe.o uv_coverage_threads.h uv_coverage_pty.h sqlite3_worker_fixture.h sqlite3_worker_fixture.o ssl_allocator_fixture.h ssl_allocator_fixture.o ssl_error_strings.h ssl_error_strings.o os_descriptor_limit.h os_descriptor_limit.o os_process_host_child)
# GNU ld fault wrappers belong only to fresh Linux child processes.
# Keep their owned outputs separate from every aggregate -X payload.
TITAN_TEST_LINUX_FAULT_OBJECTS := $(addprefix $(TITAN_TEST_BUILD_DIR)/,transfer_alloc_fault.o uv_sync_alloc_fault.o thread_retirement_fault.o)
TITAN_TEST_LINUX_FAULT_HEADERS := $(addprefix $(TITAN_TEST_BUILD_DIR)/,transfer_alloc_fault_api.h uv_sync_alloc_fault_api.h thread_retirement_fault_api.h)
TITAN_TEST_LINUX_FAULT_OUTPUTS := $(TITAN_TEST_LINUX_FAULT_OBJECTS) $(TITAN_TEST_LINUX_FAULT_HEADERS)
ifeq ($(HOST_OS),Linux)
TITAN_TEST_FIXTURE_OUTPUTS += $(TITAN_TEST_LINUX_FAULT_OUTPUTS)
endif
# Only the pure-C child uses a Make flags stamp; compiler inputs are certified
# by titanc instead of compiler/provider publication timestamps.
TITAN_TEST_CONFIG_STAMP := $(TITAN_TEST_BUILD_DIR)/native-flags.config
# TEST_LUA selects the installed SDK, just as it does for the compiler and the
# native fixtures. A cold non-test Make invocation need not have one installed.
TITAN_TEST_INSTALL_ROOT := $(shell $(TEST_LUA) -E -e 'io.write(assert(require("titan-compiler.driver").TITAN_ROOT))' 2>/dev/null)
# POSIX terminal fixtures need the same Linux feature declarations as libuv.
# Keep this separate from its source header search path in installed-SDK tests.
TITAN_TEST_FEATURE_CPPFLAGS = $(filter -D_GNU_SOURCE,$(LIBUV_CPPFLAGS))
TITAN_TEST_COMPILER_ENV = TITAN_BUILD_PROFILE=$(call make_shell_quote,$(TITAN_BUILD_PROFILE)) \
	TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(strip $(TITAN_TEST_CPPFLAGS) $(TITAN_TEST_FEATURE_CPPFLAGS) -I.)) \
	TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(strip $(TITAN_TEST_CFLAGS))) \
	TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(strip $(TITAN_TEST_LDFLAGS)))
# Native launches additionally set TITAN_ROOT to TITAN_TEST_INSTALL_ROOT (the
# installation selected by TEST_LUA), so the runtime's SDK fallback cannot
# consult a titanc on PATH or a user root. TITAN_TEST_COMPILER_ENV stays
# Busted-compatible: its specs choose their own provider paths.
STDLIB_BUSTED_TESTS := \
	spec/asan_generated_c_context_spec.lua spec/dense_array_runtime_spec.lua \
	spec/libuv_build_spec.lua spec/lpeglabel_build_spec.lua \
	spec/minicoro_spec.lua \
	spec/rockspec_spec.lua spec/titan_install_spec.lua

# Implementation notes: doc/implementation/test-runner.md#busted-partitions
# The unfiltered invocation schedules every retained, stdlib-compiler, and
# compiler spec per file across isolated checkout workers that share one Make
# job pool. rock-test also asks it to build the native aggregate inside that
# pool and record the build status for the native phase. Make before 4.2 with
# the serial TITAN_JOBS default passes no TITAN_JOBS: the runner then sizes a
# private pool with one slot per Busted worker and one for the native build,
# whose titanc recipes stay at one job.
ROCK_TEST_BUSTED = $(TITAN_TEST_COMPILER_ENV) BUSTED=$(call make_shell_quote_value,BUSTED) \
	BUSTED_FILTER=$(call make_shell_quote_value,BUSTED_FILTER) \
	TITAN_ROCK_TEST_STDLIB_SPECS=$(call make_shell_quote_value,STDLIB_BUSTED_TESTS) \
	MAKE=$(call make_shell_quote,$(MAKE)) \
	$(if $(TITAN_JOBS_SERIAL_DEFAULT),,TITAN_JOBS=$(call make_shell_quote,$(TITAN_JOBS))) \
	TITAN_ROCK_TEST_INTERNAL=1 \
	bash spec/support/run_rock_tests.sh $(EXTRA_TEST_FLAGS)
TITAN_ROCK_TEST_NATIVE_STATUS = $(abspath $(TITAN_TEST_BUILD_DIR))/.rock-test-native-build.status

.PHONY: busted-test stdlib-busted-test stdlib-test \
	titan-stdlib-test-build titan-stdlib-test-objects check-titan-test-sdk \
	titan-stdlib-test-run titan-stdlib-test-run-parallel titan-stdlib-test titan-stdlib-lint

busted-test: ## Run retained Busted specs, optionally with BUSTED_FILTER
	+@$(RECURSIVE_WRAPPER_GUARD) $(TITAN_JOBS_CHECK) $(ROCK_TEST_BUSTED)

stdlib-busted-test: ## Run retained stdlib/runtime Busted specs without coverage
	$(TITAN_TEST_COMPILER_ENV) BUSTED=$(call make_shell_quote_value,BUSTED) \
		BUSTED_FILTER=$(call make_shell_quote_value,BUSTED_FILTER) \
		TITAN_ROCK_TEST_INTERNAL=1 \
		bash spec/support/run_rock_tests.sh \
		$(STDLIB_BUSTED_TESTS) $(EXTRA_TEST_FLAGS)

check-titan-test-sdk:
	@test -n $(call make_shell_quote,$(TITAN_TEST_INSTALL_ROOT)) && \
	  test -f $(call make_shell_quote,$(TITAN_TEST_INSTALL_ROOT)/lib/titan/$(TITAN_LIBRARY_VERSION)/titan.so) || { \
	  echo "ERROR: native tests require TEST_LUA from an installed Titan SDK" >&2; exit 1; \
	}
	@mkdir -p $(call make_shell_quote,$(TITAN_TEST_BUILD_DIR))

$(TITAN_TEST_CONFIG_STAMP): FORCE | check-titan-test-sdk
	@set -e; tmp="$@.tmp"; \
	printf '%s\n' $(call make_shell_quote,CC=$(CC)) \
	  $(call make_shell_quote,CPPFLAGS=$(TITAN_TEST_CPPFLAGS)) \
	  $(call make_shell_quote,CFLAGS=$(TITAN_TEST_CFLAGS)) \
	  $(call make_shell_quote,LDFLAGS=$(TITAN_TEST_LDFLAGS)) > "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then rm -f "$$tmp"; else mv -f "$$tmp" "$@"; fi

titan-stdlib-test-objects: $(filter %.h,$(TITAN_TEST_FIXTURE_OUTPUTS)) | check-titan-test-sdk ## Compile native test modules and aggregate helpers without linking
	+@$(RECURSIVE_WRAPPER_GUARD) $(TITAN_JOBS_CHECK) set -e; \
	unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 TITAN_TARGET; \
	cd $(call make_shell_quote,$(TITAN_TEST_BUILD_DIR)); \
	TITAN_ROOT=$(call make_shell_quote,$(TITAN_TEST_INSTALL_ROOT)) \
	$(TITAN_TEST_COMPILER_ENV) $(TEST_TITANC) --output . --test --incremental -j$(TITAN_JOBS) $(TITAN_VERBOSE_FLAG) -c \
	  --tree $(call make_shell_quote,$(abspath spec/stdlib/titan)) \
	  --test-dir $(call make_shell_quote,$(abspath spec/stdlib/titan)) $(TITAN_STDLIB_TEST_PROGRAM_ROOT) \
	  $(foreach source,$(TITAN_TEST_C_SOURCES),--c-source $(call make_shell_quote,$(abspath $(source))))

# Implementation notes: doc/implementation/driver.md#lint-analysis-driverlint_modules
# The stdlib lints in its own build environment. Its tests lint as
# titan-stdlib-test-objects compiles them: from the test output directory, with
# the staged fixture headers and canonical test namespaces, plus the native
# helpers that test-root discovery never names. titan-stdlib-browser-lint
# proves that these roots cover the whole test tree.
titan-stdlib-lint: $(LUA_SDK_PREREQ) $(STDLIB_BOOTSTRAP_PREREQ) $(STDLIB_PLATFORM_PREREQS) $(SQLITE3_HEADER) $(LLHTTP_HEADER) $(LPEGLABEL_HEADERS) $(filter %.h,$(TITAN_TEST_FIXTURE_OUTPUTS)) | check-titan-test-sdk ## Lint the native stdlib and its tests under every rule
	@unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 TITAN_TARGET; \
	status=0; \
	$(STDLIB_COMPILER_ENV) $(STDLIB_TITANC) -q --lint $(TITAN_LINT_FLAGS) $(STDLIB_ROOTS) || status=1; \
	cd $(call make_shell_quote,$(TITAN_TEST_BUILD_DIR)) && \
	TITAN_ROOT=$(call make_shell_quote,$(TITAN_TEST_INSTALL_ROOT)) \
	$(TITAN_TEST_COMPILER_ENV) $(TEST_TITANC) -q --lint $(TITAN_LINT_FLAGS) --test \
	  --tree $(call make_shell_quote,$(abspath spec/stdlib/titan)) \
	  --test-dir $(call make_shell_quote,$(abspath spec/stdlib/titan)) \
	  $(TITAN_STDLIB_TEST_PROGRAM_ROOT) $(TITAN_STDLIB_NATIVE_HELPER_ROOTS) || status=1; \
	test "$$status" = 0

# Staged headers support child compiler invocations from the test output CWD.
TITAN_TEST_FIXTURE_HEADERS := async_foreign_work.h uv_stdio_probe.h \
	uv_coverage_threads.h uv_coverage_pty.h sqlite3_worker_fixture.h \
	ssl_allocator_fixture.h ssl_error_strings.h os_descriptor_limit.h
ifeq ($(HOST_OS),Linux)
TITAN_TEST_FIXTURE_HEADERS += $(notdir $(TITAN_TEST_LINUX_FAULT_HEADERS))
endif
$(addprefix $(TITAN_TEST_BUILD_DIR)/,$(TITAN_TEST_FIXTURE_HEADERS)): $(TITAN_TEST_BUILD_DIR)/%: spec/fixtures/stdlib/native/% | check-titan-test-sdk
	cp "$<" "$@"

# Child-program helpers, including the dual-use stdio input, are certified
# separately with their exact native policy.
# The compiler reports the current source's object path; old canonical-path
# nodes retained after a checkout move never select the fixed fixture copy.
define titan_test_native_rule
$(TITAN_TEST_BUILD_DIR)/$(1).o: spec/fixtures/stdlib/native/$(1).c FORCE | check-titan-test-sdk
	+@$$(RECURSIVE_WRAPPER_GUARD) $$(TITAN_JOBS_CHECK) set -e; \
	unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 TITAN_TARGET; \
	native_output=$$(call make_shell_quote,$$(TITAN_TEST_BUILD_DIR)/native/$(1).o); \
	native_object=$$$$(CC=$$(call make_shell_quote,$$(CC)) \
	TITAN_ROOT=$$(call make_shell_quote,$$(TITAN_TEST_INSTALL_ROOT)) \
	TITAN_BUILD_PROFILE=$$(call make_shell_quote,$$(TITAN_BUILD_PROFILE)) \
	TITAN_EXTRA_CPPFLAGS=$$(call make_shell_quote,$$(strip $$(TITAN_TEST_CPPFLAGS) $(3))) \
	TITAN_EXTRA_CFLAGS=$$(call make_shell_quote,$$(TITAN_TEST_CFLAGS)) \
	TITAN_EXTRA_LDFLAGS=$$(call make_shell_quote,$$(TITAN_TEST_LDFLAGS)) \
	$$(TEST_TITANC) -c --incremental --output "$$$$native_output" -j$$(TITAN_JOBS) $$(TITAN_VERBOSE_FLAG) --print-c-objects \
	  --cflag=-std=c99 --cflag=-Wall --cflag=-Wextra --cflag=-Werror --cflag=-fPIC \
	  -I spec/fixtures/stdlib/native $(2) --c-source "$$<"); \
	case "$$$$native_object" in /*) ;; *) echo 'ERROR: expected one absolute certified native fixture object' >&2; exit 1 ;; esac; \
	test -f "$$$$native_object" || { echo 'ERROR: missing reported native fixture object' >&2; exit 1; }; \
	if ! cmp -s "$$$$native_object" "$$@"; then cp -p "$$$$native_object" "$$@"; fi
endef
$(eval $(call titan_test_native_rule,uv_stdio_probe))
$(eval $(call titan_test_native_rule,sqlite3_worker_fixture,--cflag=-pthread,$(SQLITE3_CPPFLAGS)))
$(eval $(call titan_test_native_rule,ssl_allocator_fixture,--cflag=-pthread,$(STDLIB_OPENSSL_CPPFLAGS)))
$(eval $(call titan_test_native_rule,ssl_error_strings,,$(STDLIB_OPENSSL_CPPFLAGS)))
$(eval $(call titan_test_native_rule,os_descriptor_limit))
ifeq ($(HOST_OS),Linux)
$(eval $(call titan_test_native_rule,transfer_alloc_fault,--cflag=-pthread -I titan))
$(eval $(call titan_test_native_rule,uv_sync_alloc_fault,--cflag=-pthread))
$(eval $(call titan_test_native_rule,thread_retirement_fault,--cflag=-pthread,$(TITAN_TEST_FEATURE_CPPFLAGS)))
endif

$(TITAN_TEST_BUILD_DIR)/os_process_host_child: spec/fixtures/stdlib/native/os_process_host_child.c $(TITAN_TEST_CONFIG_STAMP)
	$(CC) -std=c99 -Wall -Wextra -Werror $(TITAN_TEST_CPPFLAGS) $(TITAN_TEST_CFLAGS) \
	  "$<" $(TITAN_TEST_LDFLAGS) -o "$@"

titan-stdlib-test-build: $(TITAN_TEST_FIXTURE_OUTPUTS) | check-titan-test-sdk ## Build every native Titan stdlib test into one incremental executable
	+@$(RECURSIVE_WRAPPER_GUARD) $(TITAN_JOBS_CHECK) set -e; \
	unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 TITAN_TARGET; \
	cd $(call make_shell_quote,$(TITAN_TEST_BUILD_DIR)); \
	TITAN_ROOT=$(call make_shell_quote,$(TITAN_TEST_INSTALL_ROOT)) \
	$(TITAN_TEST_COMPILER_ENV) $(TEST_TITANC) --output . --test --incremental --no-uv-bootstrap -j$(TITAN_JOBS) $(TITAN_VERBOSE_FLAG) \
	  --tree $(call make_shell_quote,$(abspath spec/stdlib/titan)) \
	  --test-dir $(call make_shell_quote,$(abspath spec/stdlib/titan)) \
	  --exe $(call make_shell_quote,$(abspath $(TITAN_TEST_EXECUTABLE))) $(TITAN_STDLIB_TEST_PROGRAM_ROOT) \
	  $(foreach source,$(TITAN_TEST_C_SOURCES),--c-source $(call make_shell_quote,$(abspath $(source))))

# The aggregate and its children run outside <prefix>/bin. Give them the
# selected installation's Lua paths instead of their executable-relative defaults.
titan-stdlib-test-run: ## Run the built native suite, optionally with TITAN_FILTER and a private TITAN_TEST_RUN_LOG
	@test -x $(call make_shell_quote,$(TITAN_TEST_EXECUTABLE)) || { \
	  echo "ERROR: run 'make titan-stdlib-test-build' first" >&2; exit 1; \
	}
	@mkdir -p "$$(dirname $(call make_shell_quote,$(TITAN_TEST_RUN_LOG)))" \
	  "$$(dirname $(call make_shell_quote,$(TITAN_TEST_RUN_ROOTS)))"
	@printf '%s\n' $(TITAN_STDLIB_TEST_ROOTS) > $(call make_shell_quote,$(TITAN_TEST_RUN_ROOTS))
	@status=0; \
	$(TITAN_TEST_COMPILER_ENV) \
	LUA_PATH_5_5="$$( $(TEST_LUA) -E -e 'io.write(package.path)' )" \
	LUA_CPATH_5_5="$$( $(TEST_LUA) -E -e 'io.write(package.cpath)' )" \
	TITAN_TEST_BUILD_DIR=$(call make_shell_quote,$(abspath $(TITAN_TEST_BUILD_DIR))) \
	TITAN_TEST_SOURCE_ROOT=$(call make_shell_quote,$(CURDIR)) \
	TITAN_TEST_SDK_ROOT=$(call make_shell_quote,$(TITAN_TEST_INSTALL_ROOT)) \
	TITAN_ROOT=$(call make_shell_quote,$(TITAN_TEST_INSTALL_ROOT)) \
	TITAN_PROCESS_CHILD=$(call make_shell_quote,$(abspath $(TITAN_TEST_BUILD_DIR)/os_process_host_child)) \
	TITAN_FILTER=$(call make_shell_quote_value,TITAN_FILTER) \
	bash -o pipefail -c ' \
	  log=$$1; shift; \
	  if [[ -n $${TITAN_FILTER:-} ]]; then \
	    set -- "$$@" "--filter=$$TITAN_FILTER"; \
	  fi; \
	  bash spec/support/run_with_timeout.sh "$$@" 2>&1 | tee "$$log"' -- \
	  $(call make_shell_quote,$(TITAN_TEST_RUN_LOG)) \
	  $(call make_shell_quote,$(TITAN_TEST_TIMEOUT)) \
	  $(call make_shell_quote,$(TITAN_TEST_EXECUTABLE)) || status=$$?; \
	$(TEST_LUA) -E spec/support/check_stdlib_test_output.lua \
	  $(call make_shell_quote,$(TITAN_TEST_RUN_LOG)) \
	  $(call make_shell_quote,$(TITAN_TEST_RUN_ROOTS)) \
	  $(call make_shell_quote_value,TITAN_FILTER); \
	audit=$$?; test "$$status" = 0 || exit "$$status"; exit "$$audit"

# The unfiltered composition runs the complete inventory through the parallel
# owner-group runner; TITAN_FILTER keeps one focused leaf invocation.
titan-stdlib-test: titan-stdlib-test-build ## Build and run all native Titan stdlib tests
	@if test -n $(call make_shell_quote_value,TITAN_FILTER); then \
	  $(MAKE) --no-print-directory titan-stdlib-test-run; \
	else \
	  $(MAKE) --no-print-directory titan-stdlib-test-run-parallel; \
	fi

# Implementation notes: doc/implementation/test-runner.md#parallel-native-aggregate-runs
# One complete prebuilt aggregate runs as TITAN_TEST_JOBS ordinary owner
# groups, then the timing-guarded owners alone; the union is audited.
titan-stdlib-test-run-parallel: ## Run the built native suite in parallel owner groups, then timing-guarded owners alone
	@if test -n $(call make_shell_quote_value,TITAN_FILTER); then \
	  echo 'ERROR: titan-stdlib-test-run-parallel runs the complete inventory; use titan-stdlib-test-run with TITAN_FILTER' >&2; \
	  exit 2; \
	fi
	@$(TITAN_TEST_COMPILER_ENV) \
	LUA_PATH_5_5="$$( $(TEST_LUA) -E -e 'io.write(package.path)' )" \
	LUA_CPATH_5_5="$$( $(TEST_LUA) -E -e 'io.write(package.cpath)' )" \
	TEST_LUA=$(call make_shell_quote,$(TEST_LUA)) \
	MAKE=$(call make_shell_quote,$(MAKE)) \
	TITAN_TEST_MODULE_MANIFEST=$(call make_shell_quote,$(TITAN_TEST_MODULE_MANIFEST)) \
	TITAN_TEST_EXECUTABLE=$(call make_shell_quote,$(TITAN_TEST_EXECUTABLE)) \
	TITAN_TEST_TIMEOUT=$(call make_shell_quote,$(TITAN_TEST_TIMEOUT)) \
	TITAN_TEST_JOBS=$(call make_shell_quote,$(TITAN_TEST_JOBS)) \
	TITAN_TEST_RUN_LOG=$(call make_shell_quote,$(TITAN_TEST_RUN_LOG)) \
	TITAN_TEST_RUN_ROOTS=$(call make_shell_quote,$(TITAN_TEST_RUN_ROOTS)) \
	TITAN_TEST_BUILD_DIR=$(call make_shell_quote,$(abspath $(TITAN_TEST_BUILD_DIR))) \
	TITAN_TEST_SOURCE_ROOT=$(call make_shell_quote,$(CURDIR)) \
	TITAN_TEST_SDK_ROOT=$(call make_shell_quote,$(TITAN_TEST_INSTALL_ROOT)) \
	TITAN_ROOT=$(call make_shell_quote,$(TITAN_TEST_INSTALL_ROOT)) \
	TITAN_PROCESS_CHILD=$(call make_shell_quote,$(abspath $(TITAN_TEST_BUILD_DIR)/os_process_host_child)) \
	bash spec/support/run_parallel_stdlib_tests.sh

stdlib-test: stdlib-busted-test ## Run all stdlib/runtime tests without coverage
	$(MAKE) titan-stdlib-test

# Implementation notes: doc/implementation/native-coverage.md#repository-integration-and-verification
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
titan-native-coverage-build: $(STDLIB_NATIVE_PREREQS) $(TITAN_TEST_FIXTURE_OUTPUTS) | check-titan-test-sdk ## Compile source-linked native tests with line coverage
	+@$(RECURSIVE_WRAPPER_GUARD) $(TITAN_JOBS_CHECK) set -e; \
	unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 TITAN_TARGET; \
	mkdir -p $(call make_shell_quote,$(TITAN_COVERAGE_BUILD_DIR)); cd $(call make_shell_quote,$(TITAN_COVERAGE_BUILD_DIR)); \
	CC=$(call make_shell_quote,$(CC)) TITAN_BUILD_PROFILE=validation \
	TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(TITAN_COVERAGE_CPPFLAGS)) \
	TITAN_EXTRA_CFLAGS='-O0 -fno-lto' \
	TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(strip -O0 -fno-lto $(if $(filter Linux,$(HOST_OS)),-rdynamic) $(STDLIB_UV_LDFLAGS) $(STDLIB_OPENSSL_LDFLAGS))) \
	$(TEST_TITANC) --output . --test --incremental --no-uv-bootstrap --coverage -j$(TITAN_JOBS) $(TITAN_VERBOSE_FLAG) \
	  --coverage-module 'titan.*' --coverage-root $(call make_shell_quote,$(CURDIR)) \
	  --coverage-gcov $(call make_shell_quote,$(TITAN_COVERAGE_GCOV)) \
	  --coverage-output $(call make_shell_quote,$(abspath $(TITAN_COVERAGE_REPORT_DIR))) \
	  --coverage-gcovr $(call make_shell_quote,$(TITAN_COVERAGE_GCOVR)) \
	  $(foreach format,$(TITAN_COVERAGE_FORMATS),--coverage-format $(format)) \
	  --tree $(call make_shell_quote,$(abspath spec/stdlib/titan);$(CURDIR)) \
	  --test-dir $(call make_shell_quote,$(abspath spec/stdlib/titan)) \
	  --exe $(call make_shell_quote,$(TITAN_COVERAGE_EXECUTABLE)) $(TITAN_STDLIB_TEST_PROGRAM_ROOT) \
	  $(foreach source,$(TITAN_TEST_C_SOURCES),--c-source $(call make_shell_quote,$(abspath $(source)))) \
	  -X $(foreach object,$(STDLIB_EXTRA_OBJECTS),$(call make_shell_quote,$(abspath $(object))))

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
# Implementation notes: doc/implementation/test-runner.md#busted-partitions
# The unfiltered Busted phase also builds the native aggregate inside its job
# pool. A Busted failure does not suppress the native phase; the native run
# starts only after every Busted worker and the native build have finished.
rock-test: ## Run retained Busted specs, then native Titan stdlib tests
	+@$(RECURSIVE_WRAPPER_GUARD) $(TITAN_JOBS_CHECK) \
	status_file=$(call make_shell_quote,$(TITAN_ROCK_TEST_NATIVE_STATUS)); \
	mkdir -p "$$(dirname "$$status_file")" && rm -f "$$status_file" || exit 1; \
	busted_status=0; \
	TITAN_ROCK_TEST_BUILD_NATIVE=1 TITAN_ROCK_TEST_NATIVE_STATUS="$$status_file" \
	  $(ROCK_TEST_BUSTED) || busted_status=$$?; \
	case "$$busted_status" in 129|130|143) rm -f "$$status_file"; exit "$$busted_status" ;; esac; \
	build_status=0; \
	if test -f "$$status_file"; then \
	  read -r build_status < "$$status_file" || build_status=1; \
	  rm -f "$$status_file"; \
	else \
	  $(MAKE) --no-print-directory titan-stdlib-test-build || build_status=$$?; \
	fi; \
	native_status=$$build_status; \
	if test "$$build_status" = 0; then \
	  if test -n $(call make_shell_quote_value,TITAN_FILTER); then \
	    $(MAKE) --no-print-directory titan-stdlib-test-run || native_status=$$?; \
	  else \
	    $(MAKE) --no-print-directory titan-stdlib-test-run-parallel || native_status=$$?; \
	  fi; \
	else \
	  echo "native stdlib test build failed (status $$build_status); the native run was skipped" >&2; \
	fi; \
	test "$$busted_status" = 0 || echo "Busted phase failed (status $$busted_status)" >&2; \
	test "$$native_status" = 0 || echo "native stdlib phase failed (status $$native_status)" >&2; \
	test "$$busted_status" = 0 && test "$$native_status" = 0
endif

test: lua luarocks ## Build/install the rock and run the suite via `luarocks test`
	+$(RECURSIVE_WRAPPER_GUARD) unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 TITAN_TARGET; \
	  PREFIX="$(PREFIX)" PATH="$(PREFIX)/bin:$$PATH" \
	  "$(PREFIX)/bin/luarocks" make --force
	+$(RECURSIVE_WRAPPER_GUARD) unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 TITAN_TARGET; \
		PREFIX="$(PREFIX)" PATH="$(PREFIX)/bin:$$PATH" \
		EXTRA_TEST_FLAGS=$(call make_shell_quote,$(strip $(EXTRA_TEST_FLAGS))) \
		BUSTED_FILTER=$(call make_shell_quote_value,BUSTED_FILTER) \
		TITAN_FILTER=$(call make_shell_quote_value,TITAN_FILTER) \
		TITAN_TEST_TIMEOUT=$(call make_shell_quote,$(TITAN_TEST_TIMEOUT)) \
		"$(PREFIX)/bin/luarocks" test

clean-stdlib: ## Remove standard-library compiler outputs
	rm -rf $(call make_shell_quote,$(TITAN_OUTPUT_DIR)/titan) $(call make_shell_quote,$(TITAN_OUTPUT_DIR)/.titan-links)
	rm -f $(STDLIB_PROVIDER_OUTPUTS)
	rm -rf $(STDLIB_CONTAINER).dSYM

clean: ## Remove generated build/test artifacts (keeps the Lua tree)
	rm -rf $(call make_shell_quote,$(TITAN_OUTPUT_DIR))
	bash spec/support/clean_generated_test_artifacts.sh
	rm -f $(RUNTIME_O) titan-runtime/*.o $(TITAN_RUNTIME_LIB)
	rm -f $(LPEGLABEL_OBJECTS) $(LPEGLABEL_ARCHIVE)
	rmdir "$(LPEGLABEL_BUILD_DIR)" 2>/dev/null || true
	rm -rf "$(LLHTTP_BUILD_DIR)"
	rm -f $(TITAN_SUPPORT_MODULE)
	rm -rf $(TITAN_SUPPORT_MODULE).dSYM
	rmdir titan-runtime/bootstrap 2>/dev/null || true
	rm -f $(STDLIB_GENERATED_FOREIGN_HEADERS)
	rm -f $(STDLIB_PROVIDER_OUTPUTS) $(STDLIB_QUALIFIED_SOS) $(STDLIB_SOS)
	rm -rf $(STDLIB_CONTAINER).dSYM
	rm -rf $(addsuffix .dSYM,$(STDLIB_SOS)) \
		$(addsuffix .dSYM,$(STDLIB_QUALIFIED_SOS))
	rm -f *.so test
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
