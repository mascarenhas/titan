# Titan compiler — developer tooling.
#
# The compiler generates C that includes Lua 5.5's *internal* headers and links
# against its static library, so the test suite needs a Lua source tree built
# next to this checkout. This Makefile downloads and builds that tree, runs the
# suite through `luarocks test`, and cleans up generated artifacts.
#
# Run `make help` to list the available targets.

# Titan owns the Lua installation it runs on.  Keep PREFIX absolute because it
# is compiled into Lua's default module paths and copied into the installed
# luaconf.h used by later Lua libraries and Titan packages.
PREFIX ?= /usr/local
override PREFIX := $(abspath $(PREFIX))

# Must match the Lua source layout resolved by titan-compiler/driver.lua and
# spec/support/helpers.lua, so don't override this unless those consumers move
# with it — the variable primarily keeps the download/install paths below DRY.
LUA_VERSION      ?= 5.5.1
LUA_ABI_VERSION  ?= 5.5
LUA_DIR          := lua-$(LUA_VERSION)
LUA_TARBALL      := $(LUA_DIR).tar.gz
LUA_URL          := https://drive.google.com/uc?export=download&id=15oUbOJpvI7JGPK9CEYD38p06ahPywPpQ
# Version the extraction stamp when Titan's policy for the downloaded source
# tree changes. v2 deliberately restores upstream loadlib.c: global provider
# visibility now comes from generated logical-module shims and Titan's native
# lazy/global helper, not a Lua patch.
LUA_EXTRACTED    := $(LUA_DIR)/.titan-extracted-v2
LUA_BUILD_CONFIG := $(LUA_DIR)/src/.titan-build-config
LUA_LIB          := $(LUA_DIR)/src/liblua.a
# A source-checkout compiler can target another built Lua source tree through
# `titanc --lua`. Its runtime archive must use the same headers and library.
TITAN_RUNTIME_LUA_SOURCE_PATH ?= $(LUA_DIR)/src
TITAN_RUNTIME_LUA_LIB = $(TITAN_RUNTIME_LUA_SOURCE_PATH)/liblua.a
LUA_BIN          := $(PREFIX)/bin/lua
LUA_SOURCE_INSTALL_DIR := $(PREFIX)/src/$(LUA_DIR)
LUA_INSTALL_STAMP := $(PREFIX)/etc/titan/lua-$(LUA_VERSION).installed

# Lua 5.5.1's interactive Linux and macOS targets use GNU Readline. Prefer a
# usable host installation, but do not require a development package: an
# immutable/minimal host can build this pinned static fallback into PREFIX.
# The archive lives in a private library directory so an unrelated readline
# already installed in PREFIX cannot change which library Lua links.
READLINE_MODE        ?= auto
READLINE_VERSION     := 8.3
READLINE_PATCHLEVEL  := 3
READLINE_RELEASE     := $(READLINE_VERSION)-p$(READLINE_PATCHLEVEL)
READLINE_DIR         := readline-$(READLINE_VERSION)
READLINE_BUILD_DIR   := readline-build
READLINE_TARBALL     := $(READLINE_DIR).tar.gz
READLINE_URL         := https://ftp.gnu.org/gnu/readline/$(READLINE_TARBALL)
READLINE_SHA256      := fe5383204467828cd495ee8d1d3c037a7eba1389c22bc6a041f627976f9061cc
READLINE_PATCH_URL   := https://ftp.gnu.org/gnu/readline/readline-$(READLINE_VERSION)-patches
READLINE_PATCH_001   := readline83-001
READLINE_PATCH_002   := readline83-002
READLINE_PATCH_003   := readline83-003
READLINE_PATCHES     := $(READLINE_PATCH_001) $(READLINE_PATCH_002) $(READLINE_PATCH_003)
READLINE_PATCH_FILE  := vendor/readline/readline-8.3-p1-p3.patch
READLINE_COMBINED_PATCH_SHA256 := 70cbc596c0a7b3a35fabb8a05711a60e2695bd2d06a4e2f46f6f168f84403f96
READLINE_PATCH_001_SHA256 := 21f0a03106dbe697337cd25c70eb0edbaa2bdb6d595b45f83285cdd35bac84de
READLINE_PATCH_002_SHA256 := e27364396ba9f6debf7cbaaf1a669e2b2854241ae07f7eca74ca8a8ba0c97472
READLINE_PATCH_003_SHA256 := 72dee13601ce38f6746eb15239999a7c56f8e1ff5eb1ec8153a1f213e4acdb29
READLINE_EXTRACTED   := $(READLINE_DIR)/.titan-extracted-p$(READLINE_PATCHLEVEL)
READLINE_PRIVATE_ROOT := $(READLINE_BUILD_DIR)/.titan-readline-$(READLINE_RELEASE)
READLINE_PRIVATE_INCLUDEDIR := $(READLINE_PRIVATE_ROOT)/include
READLINE_PRIVATE_LIBDIR := $(READLINE_PRIVATE_ROOT)/lib
READLINE_PRIVATE_DATADIR := $(READLINE_PRIVATE_ROOT)/share
READLINE_STATIC_LIB  := $(READLINE_PRIVATE_LIBDIR)/libreadline.a
READLINE_HEADER      := $(READLINE_PRIVATE_INCLUDEDIR)/readline/readline.h
READLINE_HISTORY_HEADER := $(READLINE_PRIVATE_INCLUDEDIR)/readline/history.h
READLINE_LICENSE     := $(READLINE_PRIVATE_DATADIR)/licenses/COPYING
READLINE_LICENSE_SOURCE := LICENSES/readline-LICENSE
READLINE_LICENSE_SHA256 := 8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903
READLINE_INSTALL_STAMP := $(LUA_DIR)/.titan-readline-$(READLINE_RELEASE).installed
READLINE_SELECTION_CONFIG := $(LUA_DIR)/.titan-readline-$(READLINE_RELEASE).config
READLINE_BUILD_PROFILE := static-pic-private-staged-prefix-p3-v4
READLINE_CFLAGS      ?= $(LUA_MYCFLAGS)
READLINE_CPPFLAGS    ?=
READLINE_LDFLAGS     ?= $(LUA_MYLDFLAGS)
READLINE_ARFLAGS     ?= cr
READLINE_HOST        ?=
READLINE_PKG_CONFIG  ?= pkg-config
READLINE_PKG_CPPFLAGS := $(strip $(shell $(READLINE_PKG_CONFIG) --cflags-only-I readline 2>/dev/null))
READLINE_PKG_LDFLAGS := $(strip $(shell $(READLINE_PKG_CONFIG) --libs-only-L readline 2>/dev/null))
READLINE_PKG_LIBS    := $(filter-out -lreadline,$(strip $(shell $(READLINE_PKG_CONFIG) --libs-only-l --libs-only-other readline 2>/dev/null)))
READLINE_SYSTEM_CPPFLAGS ?= $(READLINE_PKG_CPPFLAGS)
READLINE_SYSTEM_LDFLAGS ?= $(READLINE_PKG_LDFLAGS)
# Lua's interactive targets already add -lreadline. This variable carries any
# additional system-provider libraries discovered through pkg-config (or an
# explicit override), and the probe adds the primary archive itself.
READLINE_SYSTEM_LIBS ?= $(READLINE_PKG_LIBS)
# Set this to explicit terminal-capability linker flags only when auto
# detection cannot find a usable curses, tinfo, or termcap library.
READLINE_TERMCAP_LIB ?= auto

# LuaRocks is part of the standalone Titan installation. Pin it just like Lua
# and bundled libuv so the complete toolchain lives under the same PREFIX.
LUAROCKS_VERSION   := 3.13.0
LUAROCKS_DIR       := luarocks-$(LUAROCKS_VERSION)
LUAROCKS_TARBALL   := $(LUAROCKS_DIR).tar.gz
LUAROCKS_URL       := https://luarocks.github.io/luarocks/releases/$(LUAROCKS_TARBALL)
LUAROCKS_EXTRACTED := $(LUAROCKS_DIR)/.titan-extracted
LUAROCKS_INSTALL_STAMP := $(PREFIX)/etc/titan/luarocks-$(LUAROCKS_VERSION).installed
LUAROCKS_CONFIG_FILE := $(PREFIX)/etc/luarocks/config-$(LUA_ABI_VERSION).lua
# Bump this when the generated embedded-LuaRocks policy changes.  The install
# target compares both this content stamp and the actual config, so an existing
# prefix is migrated instead of being left behind by an old touched stamp.
LUAROCKS_CONFIG_POLICY := titan-system-tree-toolchain-v2

# The standard library is released against one audited libuv version.  The
# bundled PIC archive is the default so a clean Linux/macOS checkout does not
# silently pick up whichever libuv happens to be installed on the host.
LIBUV_MODE        ?= bundled
LIBUV_VERSION     := 1.52.1
LIBUV_MIN_VERSION := 1.43.0
LIBUV_SRC_DIR     := libuv-v$(LIBUV_VERSION)
LIBUV_BUILD_DIR   := libuv-build
LIBUV_BUILD_CONFIG := $(LIBUV_BUILD_DIR)/.titan-libuv-build-config
LIBUV_TARBALL     := $(LIBUV_SRC_DIR).tar.gz
LIBUV_URL         := https://dist.libuv.org/dist/v$(LIBUV_VERSION)/$(LIBUV_TARBALL)
LIBUV_SHA256      := 66d511b9e6e334c0e62279eb234fbfb2b3110b1479c09b95b44c7afca8cff9e7
LIBUV_BUNDLED_LIB := $(LIBUV_BUILD_DIR)/libuv.a
LIBUV_EXTRACTED   := $(LIBUV_SRC_DIR)/.titan-extracted
LIBUV_PKG_CONFIG  ?= pkg-config
LIBUV_BUILD_TYPE  ?= Release
LIBUV_BUILD_PROFILE ?= static-pic-release-tests-off-v1
LIBUV_CMAKE_FLAGS := -DLIBUV_BUILD_SHARED=OFF -DBUILD_TESTING=OFF \
	-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
	-DCMAKE_BUILD_TYPE=$(LIBUV_BUILD_TYPE)
LIBUV_BUILD_CFLAGS ?=

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
LLHTTP_BUILD_CONFIG  := $(LLHTTP_BUILD_DIR)/.titan-llhttp-build-config
LLHTTP_ARCHIVE_CONFIG := $(LLHTTP_BUILD_DIR)/.titan-llhttp-archive-config
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
SQLITE3_BUILD_CONFIG  := $(SQLITE3_BUILD_DIR)/.titan-sqlite3-build-config
SQLITE3_ARCHIVE_CONFIG := $(SQLITE3_BUILD_DIR)/.titan-sqlite3-archive-config
SQLITE3_CPPFLAGS      := -I$(abspath $(SQLITE3_SRC_DIR))
SQLITE3_CFLAGS        := -std=c99 -fPIC -fvisibility=hidden -DSQLITE_THREADSAFE=1
SQLITE3_BUILD_CFLAGS  ?=

# The bundled OpenSSL release is the reproducible default.  System mode uses
# pkg-config only for compilation/final linking and deliberately carries no
# host OpenSSL archive into Titan's static provider.
OPENSSL_MODE          ?= bundled
OPENSSL_VERSION       := 3.5.7
OPENSSL_MIN_VERSION   := 3.0.0
OPENSSL_SRC_DIR       := openssl-$(OPENSSL_VERSION)
OPENSSL_SRC_ABS       := $(abspath $(OPENSSL_SRC_DIR))
OPENSSL_TARBALL       := $(OPENSSL_SRC_DIR).tar.gz
OPENSSL_URL           := https://github.com/openssl/openssl/releases/download/openssl-$(OPENSSL_VERSION)/$(OPENSSL_TARBALL)
OPENSSL_SHA256        := a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8
OPENSSL_EXTRACTED     := $(OPENSSL_SRC_DIR)/.titan-extracted
OPENSSL_BUILD_DIR     := openssl-build
OPENSSL_BUILD_CONFIG  := $(OPENSSL_BUILD_DIR)/.titan-openssl-build-config
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
OPENSSL_REQUIRED_CFLAGS := -O2 -g -fPIC -fvisibility=hidden

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

# These are the complete libuv inputs consumed by the later standard-library
# rule. In bundled mode libuv's archive joins the compiler's ordered -X
# payload so both canonical provider forms carry the same native closure. In
# system mode pkg-config's ordered linker output stays a final-link input and
# no system archive is copied into Titan's static provider.
ifeq ($(LIBUV_MODE),bundled)
  LIBUV_LIB           := $(LIBUV_BUNDLED_LIB)
  LIBUV_INCLUDE_DIR   := $(LIBUV_SRC_DIR)/include
  LIBUV_CPPFLAGS      := -I$(LIBUV_INCLUDE_DIR)
  LIBUV_CFLAGS        := -fno-strict-aliasing
  LIBUV_EXTRA_OBJECTS := $(LIBUV_LIB)
  ifeq ($(HOST_OS),Darwin)
    LIBUV_LINK_LIBS := pthread
  else ifeq ($(HOST_OS),Linux)
    LIBUV_CPPFLAGS  += -D_GNU_SOURCE
    # The compiler's ordinary runtime baseline already supplies -ldl and -lm.
    LIBUV_LINK_LIBS := pthread rt
  else
    LIBUV_LINK_LIBS :=
  endif
  LIBUV_LDFLAGS := $(addprefix -l,$(LIBUV_LINK_LIBS))
  LIBUV_PROVIDER_LDFLAGS := $(LIBUV_LDFLAGS)
else ifeq ($(LIBUV_MODE),system)
  LIBUV_LIB           :=
  LIBUV_INCLUDE_DIR   :=
  LIBUV_CPPFLAGS       = $(strip $(shell $(LIBUV_PKG_CONFIG) --cflags libuv 2>/dev/null))
  LIBUV_CFLAGS        := -fno-strict-aliasing
  LIBUV_EXTRA_OBJECTS :=
  LIBUV_LINK_LIBS     :=
  LIBUV_LDFLAGS        = $(strip $(shell $(LIBUV_PKG_CONFIG) --libs libuv 2>/dev/null))
  LIBUV_PROVIDER_LDFLAGS = $(LIBUV_LDFLAGS)
else
  LIBUV_LIB           :=
  LIBUV_INCLUDE_DIR   :=
  LIBUV_CPPFLAGS      :=
  LIBUV_CFLAGS        :=
  LIBUV_EXTRA_OBJECTS :=
  LIBUV_LINK_LIBS     :=
  LIBUV_LDFLAGS       :=
  LIBUV_PROVIDER_LDFLAGS :=
endif

# uv.h needs the feature-test macro before every header under Titan's strict
# C99 mode on Linux, independent of whether libuv itself is bundled or found by
# pkg-config. (The bundled branch already adds it above.)
ifeq ($(HOST_OS),Linux)
  ifeq ($(LIBUV_MODE),system)
    LIBUV_CPPFLAGS += -D_GNU_SOURCE
  endif
endif

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
CFLAGS    ?= --std=c99 -O2 -Wall -Wno-unused-but-set-variable -Wno-unused-function -fPIC -g
LUA_MYCFLAGS  ?= -fPIC
LUA_MYLDFLAGS ?=
LUA_MYLIBS    ?=
LIBBT_CFLAGS  ?= -fPIC -g -O2
TITAN_EXTRA_CPPFLAGS ?=
TITAN_EXTRA_CFLAGS   ?=
TITAN_EXTRA_LDFLAGS  ?=
TITAN_NO_LINE_DIRECTIVES ?=
export CLANG_FORMAT TITAN_EXTRA_CPPFLAGS TITAN_EXTRA_CFLAGS \
	TITAN_EXTRA_LDFLAGS TITAN_NO_LINE_DIRECTIVES
# Quote one complete environment value for the recipe shell.  This preserves
# embedded quotes in user flag strings so Titan's own argv parser sees them.
make_shell_quote = '$(subst ','"'"',$(1))'
make_shell_quote_value = '$(subst ','"'"',$(value $(1)))'
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
LPEGLABEL_BUILD_CONFIG := $(LPEGLABEL_BUILD_DIR)/.titan-lpeglabel-build-config
LPEGLABEL_ARCHIVE_CONFIG := $(LPEGLABEL_BUILD_DIR)/.titan-lpeglabel-archive-config
LPEGLABEL_CPPFLAGS := -I$(abspath $(LPEGLABEL_VENDOR_DIR))
LPEGLABEL_CFLAGS := -std=c99 -fPIC -fvisibility=hidden
LPEGLABEL_LUA_HEADERS = $(ROCK_LUA_INCDIR)/lua.h \
	$(ROCK_LUA_INCDIR)/luaconf.h $(ROCK_LUA_INCDIR)/lauxlib.h

UV_TITAN_SOURCES := \
	titan/uv/uv.titan \
	titan/uv/file.titan \
	titan/uv/os.titan \
	titan/uv/process.titan \
	titan/uv/runtime.titan \
	titan/uv/task.titan \
	titan/uv/tcp.titan \
	titan/uv/work.titan
STDLIB_HTTP_SOURCES := titan/http/http.titan titan/http/client.titan \
	titan/http/headers.titan titan/http/native.titan \
	titan/http/server.titan
SQLITE3_TITAN_SOURCES := titan/sqlite3/sqlite3.titan titan/sqlite3/bindings.titan \
	titan/sqlite3/row.titan titan/sqlite3/worker.titan
SQLITE3_TITAN_HEADERS := titan/sqlite3/native.h
JSON_TITAN_SOURCES := titan/json/json.titan titan/json/parser.titan \
	titan/json/decoder.titan titan/json/writer.titan titan/json/numbers.titan
STDLIB_MODULES := coroutine uv async timer io fs net ssl url http os peg string \
	math lua iteration gc test reflect sqlite3 json
STDLIB_SOS     := $(addsuffix .so,$(STDLIB_MODULES))
STDLIB_QUALIFIED_SOS := $(addprefix titan/,$(STDLIB_SOS))
STDLIB_ROOTS := titan.coroutine titan.uv titan.async titan.timer \
	titan.io titan.fs titan.net titan.ssl titan.url titan.http titan.os \
	titan.peg titan.string \
	titan.math titan.lua titan.iteration titan.gc titan.test titan.reflect titan.sqlite3 titan.json
STDLIB_TITAN_SOURCES := titan/coroutine.titan $(UV_TITAN_SOURCES) \
	titan/async.titan titan/timer.titan titan/io.titan titan/fs.titan \
	titan/net.titan titan/ssl.titan titan/url.titan \
	$(STDLIB_HTTP_SOURCES) titan/os.titan \
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
STDLIB_GENERATED_FFI_HEADERS := $(addsuffix .ffi.h, \
	$(addprefix titan/,$(filter-out uv http peg string sqlite3 json,$(STDLIB_MODULES))) \
	titan/uv/uv titan/http/http titan/peg/peg titan/string/string \
	titan/sqlite3/sqlite3 titan/json/json)
STDLIB_GENERATED_FOREIGN_HEADERS := $(STDLIB_GENERATED_FFI_HEADERS) \
	titan/coroutine.titan.h \
	titan/fs.titan.h titan/uv/uv.titan.h titan/http/http.titan.h \
	titan/sqlite3/sqlite3.titan.h titan/json/json.titan.h
STDLIB_SHIMS := titan/coroutine.lua titan/uv.lua titan/async.lua \
	titan/timer.lua titan/io.lua titan/fs.lua titan/net.lua titan/ssl.lua \
	titan/url.lua titan/http.lua titan/os.lua \
	titan/peg.lua titan/string.lua titan/math.lua titan/lua.lua \
	titan/iteration.lua titan/gc.lua titan/test.lua titan/reflect.lua titan/sqlite3.lua titan/json.lua
STDLIB_CONTAINER := titan.so
STDLIB_STATIC_ARCHIVE := titan.a
STDLIB_PROVIDER_OUTPUTS := $(STDLIB_CONTAINER) $(STDLIB_STATIC_ARCHIVE)
STDLIB_EXTRA_OBJECTS := $(LTITANLIB_O) $(LPEGLABEL_ARCHIVE) \
	$(LIBUV_EXTRA_OBJECTS) $(LLHTTP_ARCHIVE) $(SQLITE3_ARCHIVE) $(OPENSSL_EXTRA_OBJECTS)
STDLIB_NATIVE_IDENTITY_PREREQS := $(LPEGLABEL_ARCHIVE) \
	$(LLHTTP_ARCHIVE) $(SQLITE3_ARCHIVE) $(OPENSSL_EXTRA_OBJECTS)
STDLIB_LPEGLABEL_CPPFLAGS := $(LPEGLABEL_CPPFLAGS)
STDLIB_HTTP_CPPFLAGS := $(LLHTTP_CPPFLAGS)
STDLIB_SQLITE3_CPPFLAGS := $(SQLITE3_CPPFLAGS)
STDLIB_OPENSSL_CPPFLAGS := $(OPENSSL_CPPFLAGS)
STDLIB_OPENSSL_LDFLAGS := $(OPENSSL_PROVIDER_LDFLAGS)
STDLIB_LICENSES := LICENSES/libuv-LICENSE \
	LICENSES/lpeglabel-LICENSE LICENSES/lpeg-LICENSE \
	LICENSES/lpeg-patterns-LICENSE \
	LICENSES/ta-regex-LICENSE LICENSES/lua-LICENSE \
	LICENSES/llhttp-LICENSE LICENSES/sqlite3-LICENSE LICENSES/openssl-LICENSE
STDLIB_EMBEDDED_FORMAT_INPUTS := titan-compiler/staticmetadata.lua \
	titan-compiler/coder.lua $(wildcard titan-compiler/coder/*.lua)
TITAN_BOOTSTRAP_SO := titan-runtime/bootstrap/titan.so
STDLIB_BOOTSTRAP_PREREQ := $(TITAN_BOOTSTRAP_SO)
ROCK_LUA_INCDIR ?= $(PREFIX)/include
ROCK_CFLAGS     ?= -O2 -fPIC
ROCK_LD         ?= $(CC)
ifeq ($(HOST_OS),Darwin)
  ROCK_LIBFLAG  ?= -bundle -undefined dynamic_lookup
else
  ROCK_LIBFLAG  ?= -shared
endif
ROCKS_TREE      ?=
ROCK_TITANC     ?=
ROCK_LUA        ?= $(LUA_BIN)
STDLIB_USE_INSTALLED_RUNTIME ?= 0
TITAN_ROCKS_ROOT ?=
export TITAN_ROCKS_ROOT
TITAN_LUA ?= $(ROCK_LUA)
# Run the checkout's compiler sources with PREFIX's Lua. Prepending the checkout
# keeps developer stdlib rebuilds on the edits that triggered them, while Lua's
# configured default paths still find third-party dependencies under PREFIX.
TITANC    ?= $(TITAN_LUA) -E -e 'package.path="./?.lua;./?/init.lua;" .. package.path; package.cpath="./titan-runtime/bootstrap/?.so;" .. package.cpath' ./titanc
TITAN_COMPILER_LUA := $(wildcard titan-compiler/*.lua \
	titan-compiler/checker/*.lua titan-compiler/coder/*.lua c-parser/*.lua)

# Standard modules have one installed pathname. PREFIX owns Lua; ROCKS_TREE
# owns these Titan artifacts when it is supplied. The source-tree
# install-stdlib target can publish to PREFIX when ROCKS_TREE is omitted;
# it is not part of an installed Titan tree.
TITAN_INSTALL_TREE         := $(if $(strip $(ROCKS_TREE)),$(ROCKS_TREE),$(PREFIX))
STDLIB_INSTALL_STAGE       ?= $(CURDIR)
# CI may preserve the exact private-stage provider and its generated C/object
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
LIBBT_BUILD_CONFIG := $(LIBBT_DIR)/.titan-build-config
RUNTIME_BUILD_CONFIG := titan-runtime/.titan-runtime-build-config
RUNTIME_ARCHIVE_CONFIG := titan-runtime/.titan-runtime-archive-build-config
LTITANLIB_BUILD_CONFIG := titan-runtime/.titan-ltitanlib-build-config
STDLIB_CONFIG_STAMP := titan-runtime/.titan-stdlib-build-config
STDLIB_COMPLETION_STAMP := titan-runtime/.titan-stdlib-complete

# These wrappers indirectly launch recursive Make processes. The `+` recipe
# marker preserves the parent jobserver; this guard keeps that marker from
# turning Make's dry-run, query, or touch modes into real wrapper execution.
RECURSIVE_WRAPPER_GUARD = flags=$${MAKEFLAGS%% *}; case "$$flags" in -*) ;; *q*) exit 1 ;; *n*|*t*) exit 0 ;; esac;

.PHONY: all help lua readline readline-bundled-install \
	check-readline-tools luarocks libbacktrace libuv libuv-config llhttp \
	check-llhttp-tools sqlite3 check-sqlite3-tools openssl openssl-config check-openssl-tools \
	check-system-openssl invalid-openssl-mode lpeglabel \
	check-libuv-tools check-system-libuv invalid-libuv-mode runtime titan \
	stage-titan-bootstrap install-titan-sdk stdlib install-stdlib \
	publish-stdlib \
	rock-post-install rock-test test rock-build \
	examples clean clean-lua clean-readline clean-luarocks clean-libbacktrace clean-libuv \
	clean-llhttp clean-sqlite3 clean-openssl \
	distclean FORCE

FORCE:

all: lua libbacktrace libuv stdlib ## Build everything needed to run the test suite (default)

help: ## Show this help
	@echo "Titan developer tasks:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "make all and make stdlib use bundled libuv $(LIBUV_VERSION), OpenSSL"
	@echo "$(OPENSSL_VERSION), and llhttp $(LLHTTP_VERSION) by default. Use"
	@echo "LIBUV_MODE=system and/or OPENSSL_MODE=system to select pkg-config"
	@echo "libraries (libuv >= $(LIBUV_MIN_VERSION), OpenSSL >= $(OPENSSL_MIN_VERSION))."
	@echo "All builds require a C compiler. titanc --pretty-print additionally needs"
	@echo "clang-format. Bundled dependencies need CMake, Perl, git, tar, curl/wget,"
	@echo "and sha256sum/shasum (macOS: xcode-select --install; brew install cmake)."
	@echo "A usable system Readline is preferred; otherwise make lua builds pinned"
	@echo "GNU Readline $(READLINE_RELEASE) into PREFIX automatically; that fallback also"
	@echo "needs a linkable curses, tinfo, or termcap provider. Optional system packages:"
	@echo "Ubuntu/Debian libreadline-dev libuv1-dev libssl-dev pkg-config; Fedora"
	@echo "readline-devel libuv-devel openssl-devel pkgconf-pkg-config; macOS brew"
	@echo "install libuv openssl@3 pkgconf. Add clang-format only for --pretty-print."
	@echo "llhttp and SQLite $(SQLITE3_VERSION) are always bundled."
	@echo "For a standalone installation, choose one writable PREFIX and run:"
	@echo "  make lua PREFIX=/path && make luarocks PREFIX=/path && make libuv"
	@echo "  PATH=/path/bin:\$$PATH /path/bin/luarocks make"

libuv: ## Build/validate libuv (bundled by default; LIBUV_MODE=system is optional)

readline: $(READLINE_SELECTION_CONFIG) ## Select system Readline or provision the prefix-local fallback

lua: $(LUA_INSTALL_STAMP) ## Build and install Titan's prefix-configured Lua

# Re-run the real compile/link probe on every invocation, but preserve the
# configuration mtime when its result and inputs are unchanged. This keeps a
# warm `make lua` quiet while noticing a host development package appearing or
# disappearing. The system probe deliberately omits PREFIX: a previously
# provisioned fallback is not misclassified as a host installation. The
# selection file lives inside the generated Lua tree, so extraction must finish
# before a parallel build may create it.
$(READLINE_SELECTION_CONFIG): $(LUA_EXTRACTED) FORCE
	@set -e; \
	mkdir -p "$(@D)"; \
	base="$@.base"; probe="$@.probe"; probe_source="$@.probe.c"; \
	probe_log="$@.probe.log"; \
	tmp="$@.tmp"; stamp_tmp="$(READLINE_INSTALL_STAMP).tmp"; \
	trap 'rm -f "$$base" "$$probe" "$$probe_source" "$$probe_log" "$$tmp" "$$stamp_tmp"' \
		EXIT HUP INT TERM; \
	case "$(READLINE_MODE)" in \
	  auto|system|bundled) ;; \
	  *) echo "ERROR: READLINE_MODE must be auto, system, or bundled (got '$(READLINE_MODE)')." >&2; \
	     exit 1 ;; \
	esac; \
	case "$(LUA_PLATFORM)" in \
	  linux-readline|macosx) needs_readline=yes ;; \
	  *) needs_readline=no ;; \
	esac; \
	provider=disabled; \
	if test "$$needs_readline" = yes; then \
	  printf '%s\n' 'int main(void) { return 0; }' > "$$probe_source"; \
	  if ! $(LUA_CC) $(LUA_MYCFLAGS) $(LUA_MYLDFLAGS) \
	       "$$probe_source" -o "$$probe" $(LUA_MYLIBS) \
	       >"$$probe_log" 2>&1; then \
	    echo "ERROR: Lua compiler/linker sanity probe failed before Readline selection." >&2; \
	    cat "$$probe_log" >&2; \
	    exit 1; \
	  fi; \
	  printf '%s\n' \
	    '#include <stdio.h>' \
	    '#include <readline/readline.h>' \
	    '#include <readline/history.h>' \
	    'int main(int argc, char **argv) {' \
	    '  if (argc == 12345) add_history(readline(argv[0]));' \
	    '  return rl_readline_name == NULL;' \
	    '}' \
	    > "$$probe_source"; \
	  system_readline=no; \
	  if test "$(READLINE_MODE)" != bundled && \
	     $(LUA_CC) $(LUA_MYCFLAGS) $(READLINE_SYSTEM_CPPFLAGS) \
	       $(LUA_MYLDFLAGS) $(READLINE_SYSTEM_LDFLAGS) "$$probe_source" \
	       -o "$$probe" -lreadline $(LUA_MYLIBS) $(READLINE_SYSTEM_LIBS) \
	       >"$$probe_log" 2>&1; then \
	    system_readline=yes; \
	  fi; \
	  if test "$$system_readline" = yes; then \
	    provider=system; \
	  elif test "$(READLINE_MODE)" = system; then \
	    echo "ERROR: READLINE_MODE=system, but the readline header/library probe failed." >&2; \
	    cat "$$probe_log" >&2; \
	    echo "  Use READLINE_MODE=auto (the default) to build the prefix-local fallback." >&2; \
	    exit 1; \
	  else \
	    provider=bundled; \
	  fi; \
	fi; \
	if test "$$provider" = bundled; then \
	  source_inputs_ok=no; \
	  if command -v sha256sum >/dev/null 2>&1; then \
	    if printf '%s  %s\n' "$(READLINE_COMBINED_PATCH_SHA256)" \
	         "$(READLINE_PATCH_FILE)" | sha256sum -c - >/dev/null 2>&1 && \
	       printf '%s  %s\n' "$(READLINE_LICENSE_SHA256)" \
	         "$(READLINE_LICENSE_SOURCE)" | sha256sum -c - >/dev/null 2>&1; then \
	      source_inputs_ok=yes; \
	    fi; \
	  elif command -v shasum >/dev/null 2>&1; then \
	    if printf '%s  %s\n' "$(READLINE_COMBINED_PATCH_SHA256)" \
	         "$(READLINE_PATCH_FILE)" | shasum -a 256 -c - >/dev/null 2>&1 && \
	       printf '%s  %s\n' "$(READLINE_LICENSE_SHA256)" \
	         "$(READLINE_LICENSE_SOURCE)" | shasum -a 256 -c - >/dev/null 2>&1; then \
	      source_inputs_ok=yes; \
	    fi; \
	  else \
	    echo "ERROR: need sha256sum or shasum to verify $(READLINE_PATCH_FILE)." >&2; \
	    exit 1; \
	  fi; \
	  if test "$$source_inputs_ok" != yes; then \
	    echo "ERROR: checksum mismatch in vendored Readline patch or license input." >&2; \
	    exit 1; \
	  fi; \
	fi; \
	if test "$$provider" = bundled; then \
	  printf '%s\n' 'int main(void) { return 0; }' > "$$probe_source"; \
	  if ! $(LUA_CC) $(READLINE_CFLAGS) $(READLINE_CPPFLAGS) \
	       $(READLINE_LDFLAGS) "$$probe_source" -o "$$probe" $(LUA_MYLIBS) \
	       >"$$probe_log" 2>&1; then \
	    echo "ERROR: Readline fallback compiler/linker sanity probe failed before terminal-library selection." >&2; \
	    cat "$$probe_log" >&2; \
	    exit 1; \
	  fi; \
	fi; \
	termcap=; \
	if test "$$provider" = bundled; then \
	  printf '%s\n' \
	    'extern int tgetent(char *, const char *);' \
	    'int main(void) { return tgetent((char *)0, (const char *)0); }' \
	    > "$$probe_source"; \
	  termcap_found=no; \
	  if test "$(READLINE_TERMCAP_LIB)" != auto; then \
	    termcap=$(call make_shell_quote,$(READLINE_TERMCAP_LIB)); \
	    if $(LUA_CC) $(READLINE_CFLAGS) $(READLINE_CPPFLAGS) \
	       $(READLINE_LDFLAGS) "$$probe_source" -o "$$probe" \
	       $(LUA_MYLIBS) $$termcap \
	       >/dev/null 2>&1; then \
	      termcap_found=yes; \
	    fi; \
	  else \
	    candidates='none -ltinfo -lncursesw -lncurses -lcurses -ltermcap'; \
	    if test "$(HOST_OS)" = Linux; then \
	      candidates="$$candidates -Wl,-l:libtinfo.so.6 -Wl,-l:libtinfo.so.5 -Wl,-l:libncursesw.so.6 -Wl,-l:libncurses.so.6"; \
	    fi; \
	    for candidate in $$candidates; do \
	      candidate_flags=$$candidate; \
	      if test "$$candidate" = none; then candidate_flags=; fi; \
	      if $(LUA_CC) $(READLINE_CFLAGS) $(READLINE_CPPFLAGS) \
	         $(READLINE_LDFLAGS) "$$probe_source" -o "$$probe" \
	         $(LUA_MYLIBS) $$candidate_flags >/dev/null 2>&1; then \
	        termcap="$$candidate_flags"; termcap_found=yes; break; \
	      fi; \
	    done; \
	  fi; \
	  if test "$$termcap_found" != yes; then \
	    echo "ERROR: local Readline needs a usable curses, tinfo, or termcap library." >&2; \
	    echo "  Install the platform terminal-library development package or set READLINE_TERMCAP_LIB." >&2; \
	    exit 1; \
	  fi; \
	fi; \
	{ printf 'provider=%s\n' "$$provider"; \
	  printf 'termcap=%s\n' "$$termcap"; \
	  printf '%s\n' \
	    $(call make_shell_quote,LUA_PLATFORM=$(LUA_PLATFORM)) \
	    $(call make_shell_quote,READLINE_MODE=$(READLINE_MODE)) \
	    $(call make_shell_quote,READLINE_VERSION=$(READLINE_VERSION)) \
	    $(call make_shell_quote,READLINE_PATCHLEVEL=$(READLINE_PATCHLEVEL)) \
	    $(call make_shell_quote,READLINE_SHA256=$(READLINE_SHA256)) \
	    $(call make_shell_quote,READLINE_PATCH_001_SHA256=$(READLINE_PATCH_001_SHA256)) \
	    $(call make_shell_quote,READLINE_PATCH_002_SHA256=$(READLINE_PATCH_002_SHA256)) \
	    $(call make_shell_quote,READLINE_PATCH_003_SHA256=$(READLINE_PATCH_003_SHA256)) \
	    $(call make_shell_quote,READLINE_COMBINED_PATCH_SHA256=$(READLINE_COMBINED_PATCH_SHA256)) \
	    $(call make_shell_quote,READLINE_LICENSE_SHA256=$(READLINE_LICENSE_SHA256)) \
	    $(call make_shell_quote,READLINE_BUILD_PROFILE=$(READLINE_BUILD_PROFILE)) \
	    $(call make_shell_quote,READLINE_PRIVATE_ROOT=$(READLINE_PRIVATE_ROOT)) \
	    $(call make_shell_quote,READLINE_PRIVATE_INCLUDEDIR=$(READLINE_PRIVATE_INCLUDEDIR)) \
	    $(call make_shell_quote,READLINE_PRIVATE_LIBDIR=$(READLINE_PRIVATE_LIBDIR)) \
	    $(call make_shell_quote,LUA_CC=$(LUA_CC)) \
	    $(call make_shell_quote,AR=$(AR)) \
	    $(call make_shell_quote,RANLIB=$(RANLIB)) \
	    $(call make_shell_quote,READLINE_CFLAGS=$(READLINE_CFLAGS)) \
	    $(call make_shell_quote,READLINE_CPPFLAGS=$(READLINE_CPPFLAGS)) \
	    $(call make_shell_quote,READLINE_LDFLAGS=$(READLINE_LDFLAGS)) \
	    $(call make_shell_quote,READLINE_ARFLAGS=$(READLINE_ARFLAGS)) \
	    $(call make_shell_quote,READLINE_HOST=$(READLINE_HOST)) \
	    $(call make_shell_quote,READLINE_SYSTEM_CPPFLAGS=$(READLINE_SYSTEM_CPPFLAGS)) \
	    $(call make_shell_quote,READLINE_SYSTEM_LDFLAGS=$(READLINE_SYSTEM_LDFLAGS)) \
	    $(call make_shell_quote,READLINE_SYSTEM_LIBS=$(READLINE_SYSTEM_LIBS)) \
	    $(call make_shell_quote,READLINE_TERMCAP_LIB=$(READLINE_TERMCAP_LIB)); \
	} > "$$base"; \
	if test "$$provider" = bundled; then \
	  printf '%s\n' \
	    '#include <stdio.h>' \
	    '#include <readline/readline.h>' \
	    '#include <readline/history.h>' \
	    'int main(int argc, char **argv) {' \
	    '  if (argc == 12345) add_history(readline(argv[0]));' \
	    '  return rl_readline_name == NULL;' \
	    '}' \
	    > "$$probe_source"; \
	  fallback_current=no; \
	  if test -f "$(READLINE_INSTALL_STAMP)" && \
	     cmp -s "$$base" "$(READLINE_INSTALL_STAMP)" && \
	     test -f "$(READLINE_HEADER)" && test -f "$(READLINE_HISTORY_HEADER)" && \
	     test -f "$(READLINE_STATIC_LIB)" && \
	     cmp -s "$(READLINE_LICENSE_SOURCE)" "$(READLINE_LICENSE)" && \
	     $(LUA_CC) -I"$(READLINE_PRIVATE_INCLUDEDIR)" \
	       $(READLINE_CFLAGS) $(READLINE_CPPFLAGS) $(READLINE_LDFLAGS) \
	       "$$probe_source" -o "$$probe" "$(READLINE_STATIC_LIB)" \
	       $(LUA_MYLIBS) $$termcap >/dev/null 2>&1; then \
	    fallback_current=yes; \
	  fi; \
	  if test "$$fallback_current" != yes; then \
	    echo "==> System Readline development files unavailable; provisioning $(READLINE_RELEASE)"; \
	    $(MAKE) --no-print-directory readline-bundled-install \
	      LUA_CC=$(call make_shell_quote,$(LUA_CC)) \
	      AR=$(call make_shell_quote,$(AR)) \
	      RANLIB=$(call make_shell_quote,$(RANLIB)) \
	      READLINE_CFLAGS=$(call make_shell_quote,$(READLINE_CFLAGS)) \
	      READLINE_CPPFLAGS=$(call make_shell_quote,$(READLINE_CPPFLAGS)) \
	      READLINE_LDFLAGS=$(call make_shell_quote,$(READLINE_LDFLAGS)) \
	      READLINE_ARFLAGS=$(call make_shell_quote,$(READLINE_ARFLAGS)) \
	      READLINE_HOST=$(call make_shell_quote,$(READLINE_HOST)) \
	      READLINE_SELECTED_TERMCAP_LIB="$$termcap"; \
	    if ! test -f "$(READLINE_HEADER)" || \
	       ! test -f "$(READLINE_HISTORY_HEADER)" || \
	       ! test -f "$(READLINE_STATIC_LIB)" || \
	       ! cmp -s "$(READLINE_LICENSE_SOURCE)" "$(READLINE_LICENSE)" || \
	       ! $(LUA_CC) -I"$(READLINE_PRIVATE_INCLUDEDIR)" \
	         $(READLINE_CFLAGS) $(READLINE_CPPFLAGS) $(READLINE_LDFLAGS) \
	         "$$probe_source" -o "$$probe" "$(READLINE_STATIC_LIB)" \
	         $(LUA_MYLIBS) $$termcap >/dev/null 2>&1; then \
	      echo "ERROR: prefix-local Readline failed its exact post-install link validation." >&2; \
	      exit 1; \
	    fi; \
	    cp "$$base" "$$stamp_tmp"; \
	    mv -f "$$stamp_tmp" "$(READLINE_INSTALL_STAMP)"; \
	  fi; \
	fi; \
	cp "$$base" "$$tmp"; \
	if test -f "$@" && cmp -s "$$tmp" "$@"; then \
	  :; \
	else \
	  echo "==> Lua Readline provider: $$provider"; \
	  mv -f "$$tmp" "$@"; \
	fi

check-readline-tools:
	@missing=0; \
	if ! command -v "$(firstword $(LUA_CC))" >/dev/null 2>&1; then \
	  echo "ERROR: Lua C compiler '$(firstword $(LUA_CC))' was not found." >&2; missing=1; \
	fi; \
	if ! command -v "$(firstword $(AR))" >/dev/null 2>&1; then \
	  echo "ERROR: archiver '$(firstword $(AR))' was not found." >&2; missing=1; \
	fi; \
	if ! command -v "$(firstword $(RANLIB))" >/dev/null 2>&1; then \
	  echo "ERROR: ranlib '$(firstword $(RANLIB))' was not found." >&2; missing=1; \
	fi; \
	if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then \
	  echo "ERROR: need curl or wget to download $(READLINE_TARBALL)." >&2; missing=1; \
	fi; \
	if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then \
	  echo "ERROR: need sha256sum or shasum to verify $(READLINE_TARBALL)." >&2; missing=1; \
	fi; \
	if ! command -v tar >/dev/null 2>&1; then \
	  echo "ERROR: tar is required to extract $(READLINE_TARBALL)." >&2; missing=1; \
	fi; \
	if ! command -v git >/dev/null 2>&1; then \
	  echo "ERROR: git is required to apply GNU Readline's vendored official fixes." >&2; missing=1; \
	fi; \
	test "$$missing" -eq 0

$(READLINE_TARBALL):
	@$(MAKE) --no-print-directory check-readline-tools
	@echo "==> Downloading $(READLINE_URL)"
	@set -e; tmp="$@.tmp"; trap 'rm -f "$$tmp"' EXIT HUP INT TERM; \
	if command -v curl >/dev/null 2>&1; then \
	  curl -fL -o "$$tmp" "$(READLINE_URL)"; \
	else \
	  wget -O "$$tmp" "$(READLINE_URL)"; \
	fi; \
	if command -v sha256sum >/dev/null 2>&1; then \
	  printf '%s  %s\n' "$(READLINE_SHA256)" "$$tmp" | sha256sum -c -; \
	else \
	  printf '%s  %s\n' "$(READLINE_SHA256)" "$$tmp" | shasum -a 256 -c -; \
	fi; \
	mv -f "$$tmp" "$@"

$(READLINE_EXTRACTED): $(READLINE_TARBALL) $(READLINE_PATCH_FILE)
	@$(MAKE) --no-print-directory check-readline-tools
	@echo "==> Verifying GNU Readline $(READLINE_VERSION) release archive and patch"
	@set -e; check_sha256() { \
	  expected="$$1"; path="$$2"; \
	  if command -v sha256sum >/dev/null 2>&1; then \
	    printf '%s  %s\n' "$$expected" "$$path" | sha256sum -c -; \
	  else \
	    printf '%s  %s\n' "$$expected" "$$path" | shasum -a 256 -c -; \
	  fi; \
	}; \
	if ! check_sha256 "$(READLINE_SHA256)" "$(READLINE_TARBALL)"; then \
	  echo "ERROR: checksum mismatch for $(READLINE_TARBALL); removing it." >&2; \
	  rm -f "$(READLINE_TARBALL)"; exit 1; \
	fi; \
	if ! check_sha256 "$(READLINE_COMBINED_PATCH_SHA256)" \
	     "$(READLINE_PATCH_FILE)"; then \
	  echo "ERROR: checksum mismatch for applied Readline patch $(READLINE_PATCH_FILE)." >&2; \
	  exit 1; \
	fi
	@echo "==> Extracting and patching GNU Readline $(READLINE_RELEASE)"
	rm -rf "$(READLINE_DIR)"
	tar zxf "$(READLINE_TARBALL)"
	@test -x "$(READLINE_DIR)/configure" || { \
	  echo "ERROR: $(READLINE_TARBALL) did not contain $(READLINE_DIR)." >&2; exit 1; \
	}
	git apply --directory="$(READLINE_DIR)" "$(READLINE_PATCH_FILE)"
	@test "$$(sed -n '$$p' "$(READLINE_DIR)/patchlevel")" = "3"
	@touch "$@"

# The fallback is a private Lua build input, not a discoverable SDK. Upstream's
# pkg-config files capture the temporary stage paths, so discard them before
# atomically publishing the validated include/library tree. Its ordinary build
# is parallel-safe, but its install targets race while replacing libhistory.a;
# keep only that staging pass serial.
readline-bundled-install: check-readline-tools $(READLINE_EXTRACTED)
	@set -e; \
	echo "==> Building staged static GNU Readline $(READLINE_RELEASE) for $(PREFIX)"; \
	mkdir -p "$(dir $(READLINE_PRIVATE_ROOT))"; \
	stage="$$(mktemp -d \
	  "$(dir $(READLINE_PRIVATE_ROOT)).readline-$(READLINE_RELEASE).stage.XXXXXX")"; \
	backup=; \
	cleanup() { \
	  if test -n "$$backup" && test -e "$$backup" && \
	     ! test -e "$(READLINE_PRIVATE_ROOT)"; then \
	    mv "$$backup" "$(READLINE_PRIVATE_ROOT)"; \
	  fi; \
	  if test -n "$$stage" && test -e "$$stage"; then rm -rf "$$stage"; fi; \
	}; \
	trap cleanup EXIT HUP INT TERM; \
	rm -rf "$(READLINE_BUILD_DIR)"; \
	mkdir -p "$(READLINE_BUILD_DIR)"; \
	( cd "$(READLINE_BUILD_DIR)" && \
	  "$(abspath $(READLINE_DIR))/configure" \
	    --prefix="$(abspath $$stage)" \
	    --includedir="$(abspath $$stage)/include" \
	    --libdir="$(abspath $$stage)/lib" \
	    --datarootdir="$(abspath $$stage)/share" \
	    --disable-shared --enable-static \
	    $(if $(strip $(READLINE_HOST)),--host=$(call make_shell_quote,$(READLINE_HOST)),) \
	    CC=$(call make_shell_quote,$(LUA_CC)) \
	    AR=$(call make_shell_quote,$(AR)) \
	    ARFLAGS=$(call make_shell_quote,$(READLINE_ARFLAGS)) \
	    RANLIB=$(call make_shell_quote,$(RANLIB)) \
	    CFLAGS=$(call make_shell_quote,$(READLINE_CFLAGS)) \
	    CPPFLAGS=$(call make_shell_quote,$(READLINE_CPPFLAGS)) \
	    LDFLAGS=$(call make_shell_quote,$(READLINE_LDFLAGS)) \
	    LIBS=$(call make_shell_quote,$(READLINE_SELECTED_TERMCAP_LIB)) ); \
	$(MAKE) -C "$(READLINE_BUILD_DIR)"; \
	$(MAKE) -j1 -C "$(READLINE_BUILD_DIR)" install; \
	rm -rf "$$stage/lib/pkgconfig"; \
	mkdir -p "$$stage/share/licenses"; \
	cmp -s "$(READLINE_DIR)/COPYING" "$(READLINE_LICENSE_SOURCE)" || { \
	  echo "ERROR: checked-in GNU Readline license does not match the pinned source." >&2; \
	  exit 1; \
	}; \
	install -m 0644 "$(READLINE_LICENSE_SOURCE)" \
	  "$$stage/share/licenses/COPYING"; \
	test -f "$$stage/include/readline/readline.h" && \
	test -f "$$stage/include/readline/history.h" && \
	test -f "$$stage/lib/libreadline.a" && \
	cmp -s "$(READLINE_LICENSE_SOURCE)" "$$stage/share/licenses/COPYING" || { \
	  echo "ERROR: staged GNU Readline install is incomplete." >&2; exit 1; \
	}; \
	probe_source="$(READLINE_BUILD_DIR)/.titan-link-probe.c"; \
	probe="$(READLINE_BUILD_DIR)/.titan-link-probe"; \
	printf '%s\n' \
	  '#include <stdio.h>' \
	  '#include <readline/readline.h>' \
	  '#include <readline/history.h>' \
	  'int main(int argc, char **argv) {' \
	  '  if (argc == 12345) add_history(readline(argv[0]));' \
	  '  return rl_readline_name == NULL;' \
	  '}' > "$$probe_source"; \
	$(LUA_CC) -I"$$stage/include" $(READLINE_CFLAGS) $(READLINE_CPPFLAGS) \
	  $(READLINE_LDFLAGS) "$$probe_source" -o "$$probe" \
	  "$$stage/lib/libreadline.a" $(LUA_MYLIBS) \
	  $(READLINE_SELECTED_TERMCAP_LIB) || { \
	  echo "ERROR: staged GNU Readline failed its exact link validation." >&2; \
	  exit 1; \
	}; \
	rm -f "$$probe" "$$probe_source"; \
	if test -e "$(READLINE_PRIVATE_ROOT)"; then \
	  backup="$(READLINE_PRIVATE_ROOT).backup.$$$$"; \
	  test ! -e "$$backup"; \
	  mv "$(READLINE_PRIVATE_ROOT)" "$$backup"; \
	fi; \
	mv "$$stage" "$(READLINE_PRIVATE_ROOT)"; \
	stage=; \
	if test -n "$$backup"; then rm -rf "$$backup"; backup=; fi; \
	trap - EXIT HUP INT TERM

$(LUA_INSTALL_STAMP): $(LUA_LIB) $(LUA_BUILD_CONFIG)
	@echo "==> Installing Lua $(LUA_VERSION) into $(PREFIX)"
	$(MAKE) -C "$(LUA_DIR)" install INSTALL_TOP="$(PREFIX)"
	mkdir -p "$(LUA_SOURCE_INSTALL_DIR)"
	install -m 0644 $(LUA_DIR)/src/*.c $(LUA_DIR)/src/*.h \
		"$(LUA_SOURCE_INSTALL_DIR)/"
	mkdir -p "$(@D)"
	touch "$@"

$(LUA_TARBALL):
	@echo "==> Downloading $(LUA_URL)"
	@if command -v curl >/dev/null 2>&1; then \
	  curl -fL -o "$@" "$(LUA_URL)"; \
	elif command -v wget >/dev/null 2>&1; then \
	  wget -O "$@" "$(LUA_URL)"; \
	else \
	  echo "ERROR: need 'curl' or 'wget' to download Lua" >&2; exit 1; \
	fi

$(LUA_EXTRACTED): $(LUA_TARBALL)
	@echo "==> Replacing generated Lua source tree from $(LUA_TARBALL)"
	rm -rf "$(LUA_DIR)"
	tar zxf "$(LUA_TARBALL)"
	@touch "$@"

# Lua's own Makefile does not track source/header dependencies.  This content
# stamp configures luaconf.h with Titan's installation paths and cleans Lua
# objects whenever that configuration or any effective native-build input
# changes. An unchanged invocation preserves the stamp mtime and leaves the
# already-built interpreter warm. loadlib.c remains the pristine upstream file.
$(LUA_BUILD_CONFIG): $(LUA_EXTRACTED) $(READLINE_SELECTION_CONFIG) FORCE
	@tmp="$@.tmp"; header="$(LUA_DIR)/src/luaconf.h"; \
	tmp_header="$$header.titan.tmp"; \
	changed="$@.changed"; \
	rm -f "$$changed"; \
	{ printf '%s\n' \
		$(call make_shell_quote,PREFIX=$(PREFIX)) \
		$(call make_shell_quote,LUA_PLATFORM=$(LUA_PLATFORM)) \
		$(call make_shell_quote,LUA_CC=$(LUA_CC)) \
		$(call make_shell_quote,LUA_AR=$(LUA_AR)) \
		$(call make_shell_quote,LUA_RANLIB=$(LUA_RANLIB)) \
		$(call make_shell_quote,LUA_MYCFLAGS=$(LUA_MYCFLAGS)) \
		$(call make_shell_quote,LUA_MYLDFLAGS=$(LUA_MYLDFLAGS)) \
		$(call make_shell_quote,LUA_MYLIBS=$(LUA_MYLIBS)) \
		$(call make_shell_quote,TITAN_LIBRARY_VERSION=$(TITAN_LIBRARY_VERSION)); } \
		> "$$tmp"; \
	cat "$(READLINE_SELECTION_CONFIG)" >> "$$tmp"; \
	awk -v root=$(call make_shell_quote,$(PREFIX)) \
	    -v titan_library=$(call make_shell_quote,$(TITAN_LIBRARY_VERSION)) \
	  '$$1 == "#define" && $$2 == "LUA_TITAN_CDIR" { next } \
	   { if ($$1 == "#define" && index($$2, "LUA_ROOT") == 1) { \
	       printf("#define LUA_ROOT %c%s/%c\n", 34, root, 34); next; \
	     } \
	     if ($$1 == "#define" && $$2 == "LUA_CDIR" && \
	         index($$0, "LUA_ROOT") != 0) { \
	       print; \
	       printf("#define LUA_TITAN_CDIR%cLUA_ROOT %clib/titan/%s/%c\n", \
	              9, 34, titan_library, 34); \
	       next; \
	     } \
	     line = $$0; \
	     gsub(/LUA_TITAN_CDIR[ \t]*"[?][.]so;"[ \t]*/, "", line); \
	     if (line ~ /LUA_CDIR[ \t]*"[?][.]so;"/) { \
	       sub(/LUA_CDIR[ \t]*"[?][.]so;"/, \
	           "LUA_TITAN_CDIR \"?.so;\" LUA_CDIR \"?.so;\"", line); \
	     } \
	     print line; }' "$$header" > "$$tmp_header"; \
	grep -q '^#define LUA_ROOT' "$$tmp_header"; \
	grep -q '^#define LUA_TITAN_CDIR' "$$tmp_header"; \
	test "$$(grep -Ec 'LUA_TITAN_CDIR[[:space:]]*"[?][.]so;"' \
	              "$$tmp_header")" -eq 1; \
	if test -r "$@" && cmp -s "$$tmp" "$@" && \
	   cmp -s "$$tmp_header" "$$header"; then \
	  rm -f "$$tmp" "$$tmp_header"; \
	else \
	  echo "==> Configuring Lua for Titan paths"; \
	  mv -f "$$tmp_header" "$$header"; \
	  mv -f "$$tmp" "$$changed"; \
	fi
	@if test -r "$@.changed"; then \
	  $(MAKE) -C "$(LUA_DIR)/src" clean; \
	fi
	@if test -r "$@.changed"; then mv -f "$@.changed" "$@"; fi

$(LUA_LIB): $(LUA_BUILD_CONFIG)
	@set -e; \
	readline_provider="$$(sed -n 's/^provider=//p' "$(READLINE_SELECTION_CONFIG)")"; \
	readline_termcap="$$(sed -n 's/^termcap=//p' "$(READLINE_SELECTION_CONFIG)")"; \
	lua_mycflags=$(call make_shell_quote,$(LUA_MYCFLAGS)); \
	lua_myldflags=$(call make_shell_quote,$(LUA_MYLDFLAGS)); \
	lua_mylibs=$(call make_shell_quote,$(LUA_MYLIBS)); \
	if test "$$readline_provider" = bundled; then \
	  lua_mycflags="-I$(abspath $(READLINE_PRIVATE_INCLUDEDIR)) $$lua_mycflags"; \
	  lua_myldflags="-L$(abspath $(READLINE_PRIVATE_LIBDIR)) $$lua_myldflags"; \
	  lua_mylibs="$$lua_mylibs $$readline_termcap"; \
	elif test "$$readline_provider" = system; then \
	  lua_mycflags="$$lua_mycflags $(READLINE_SYSTEM_CPPFLAGS)"; \
	  lua_myldflags="$$lua_myldflags $(READLINE_SYSTEM_LDFLAGS)"; \
	  lua_mylibs="$$lua_mylibs $(READLINE_SYSTEM_LIBS)"; \
	fi; \
	echo "==> Building Lua ($(LUA_PLATFORM), Readline=$$readline_provider, MYCFLAGS=$$lua_mycflags)"; \
	$(MAKE) -C "$(LUA_DIR)" $(LUA_PLATFORM) \
		CC=$(call make_shell_quote,$(LUA_CC)) \
		AR=$(call make_shell_quote,$(LUA_AR)) \
		RANLIB=$(call make_shell_quote,$(LUA_RANLIB)) \
		MYCFLAGS="$$lua_mycflags" \
		MYLDFLAGS="$$lua_myldflags" \
		MYLIBS="$$lua_mylibs"

luarocks: $(LUAROCKS_INSTALL_STAMP) ## Install pinned LuaRocks into PREFIX

# This is a content/config migration target, not a one-time touched stamp.
# LuaRocks' generated config includes a user tree even with --rocks-tree; Titan
# owns one standalone prefix, so emit the complete force-config file ourselves
# with Lua's %q quoting and keep only that prefix's named system tree.  FORCE
# makes old prefixes self-migrate, while cmp preserves a completely quiet warm
# invocation and does not perturb dependency mtimes.
$(LUAROCKS_INSTALL_STAMP): $(LUA_INSTALL_STAMP) FORCE
	@set -e; \
	mkdir -p "$(@D)" "$(dir $(LUAROCKS_CONFIG_FILE))"; \
	stamp_tmp="$@.tmp"; config_tmp="$@.config.tmp"; \
	changed="$@.changed"; config_changed="$@.config.changed"; \
	rm -f "$$changed" "$$config_changed"; \
	{ printf '%s\n' \
		$(call make_shell_quote,LUAROCKS_VERSION=$(LUAROCKS_VERSION)) \
		$(call make_shell_quote,PREFIX=$(PREFIX)) \
		$(call make_shell_quote,LUA_ABI_VERSION=$(LUA_ABI_VERSION)) \
		$(call make_shell_quote,LUA_BIN=$(LUA_BIN)) \
		$(call make_shell_quote,CC=$(CC)) \
		$(call make_shell_quote,AR=$(AR)) \
		$(call make_shell_quote,RANLIB=$(RANLIB)) \
		$(call make_shell_quote,CONFIGURE=--prefix=$(PREFIX) --rocks-tree=$(PREFIX) --with-lua=$(PREFIX) --force-config) \
		$(call make_shell_quote,CONFIG_POLICY=$(LUAROCKS_CONFIG_POLICY)); } \
		> "$$stamp_tmp"; \
	TITAN_CONFIG_PREFIX=$(call make_shell_quote,$(PREFIX)) \
	TITAN_CONFIG_LUA_VERSION=$(call make_shell_quote,$(LUA_ABI_VERSION)) \
	TITAN_CONFIG_CC=$(call make_shell_quote,$(CC)) \
	TITAN_CONFIG_AR=$(call make_shell_quote,$(AR)) \
	TITAN_CONFIG_RANLIB=$(call make_shell_quote,$(RANLIB)) \
		"$(LUA_BIN)" -e 'local p = assert(os.getenv("TITAN_CONFIG_PREFIX")); local v = assert(os.getenv("TITAN_CONFIG_LUA_VERSION")); local cc = assert(os.getenv("TITAN_CONFIG_CC")); local ar = assert(os.getenv("TITAN_CONFIG_AR")); local ranlib = assert(os.getenv("TITAN_CONFIG_RANLIB")); local function q(s) return string.format("%q", s) end; local function join(s) return p == "/" and ("/" .. s) or (p .. "/" .. s) end; io.write("-- LuaRocks configuration for Titan (system tree and native toolchain)\n\n"); io.write("rocks_trees = {\n   { name = \"system\", root = ", q(p), " };\n}\n"); io.write("variables = {\n   LUA_DIR = ", q(p), ";\n   LUA_BINDIR = ", q(join("bin")), ";\n   LUA_VERSION = ", q(v), ";\n   LUA = ", q(join("bin/lua")), ";\n   CC = ", q(cc), ";\n   LD = ", q(cc), ";\n   AR = ", q(ar), ";\n   RANLIB = ", q(ranlib), ";\n}\n")' \
		> "$$config_tmp"; \
	if test -x "$(PREFIX)/bin/luarocks" && \
	   test -r "$@" && cmp -s "$$stamp_tmp" "$@" && \
	   test -r "$(LUAROCKS_CONFIG_FILE)" && \
	   cmp -s "$$config_tmp" "$(LUAROCKS_CONFIG_FILE)"; then \
		rm -f "$$stamp_tmp" "$$config_tmp"; \
	else \
		mv -f "$$stamp_tmp" "$$changed"; \
		mv -f "$$config_tmp" "$$config_changed"; \
	fi
	@if test -r "$@.changed"; then \
		$(MAKE) --no-print-directory "$(LUAROCKS_EXTRACTED)"; \
	fi
	@if test -r "$@.changed"; then \
		echo "==> Configuring LuaRocks $(LUAROCKS_VERSION) for $(PREFIX)"; \
		(cd "$(LUAROCKS_DIR)" && \
			./configure --prefix="$(PREFIX)" --rocks-tree="$(PREFIX)" \
				--with-lua="$(PREFIX)" --force-config); \
	fi
	@if test -r "$@.changed"; then $(MAKE) -C "$(LUAROCKS_DIR)"; fi
	@if test -r "$@.changed"; then $(MAKE) -C "$(LUAROCKS_DIR)" install; fi
	@if test -r "$@.changed"; then \
		mv -f "$@.config.changed" "$(LUAROCKS_CONFIG_FILE)"; \
		mv -f "$@.changed" "$@"; \
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

$(LUAROCKS_EXTRACTED):
	@if [ ! -d "$(LUAROCKS_DIR)" ]; then \
	  mkdir -p "$(LUAROCKS_DIR)"; \
	  touch "$(LUAROCKS_DIR)/.titan-needs-extract"; \
	fi
	@if test -r "$(LUAROCKS_DIR)/.titan-needs-extract"; then \
	  $(MAKE) --no-print-directory "$(LUAROCKS_TARBALL)"; \
	fi
	@if test -r "$(LUAROCKS_DIR)/.titan-needs-extract"; then \
	  echo "==> Extracting $(LUAROCKS_TARBALL)"; \
	  tar zxf "$(LUAROCKS_TARBALL)"; \
	  rm -f "$(LUAROCKS_DIR)/.titan-needs-extract"; \
	fi
	@touch "$@"

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

# Autoconf Makefiles do not know that a changed command-line compiler/CFLAGS
# invalidates existing objects.  Preserve the stamp mtime on a warm build; when
# an effective input changes (notably sanitizer flags), clean before rebuilding.
$(LIBBT_BUILD_CONFIG): $(LIBBT_CLONE_STAMP) FORCE
	@tmp="$@.tmp"; changed="$@.changed"; rm -f "$$changed"; \
	{ printf '%s\n' \
		$(call make_shell_quote,HOST_OS=$(HOST_OS)) \
		$(call make_shell_quote,HOST_ARCH=$(HOST_ARCH)) \
		$(call make_shell_quote,CC=$(CC)) \
		$(call make_shell_quote,AR=$(AR)) \
		$(call make_shell_quote,RANLIB=$(RANLIB)) \
		$(call make_shell_quote,LIBBT_CFLAGS=$(LIBBT_CFLAGS)); } > "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then \
		rm -f "$$tmp"; \
	else \
		mv -f "$$tmp" "$$changed"; \
	fi
	@if test -r "$@.changed" && test -f "$(LIBBT_DIR)/Makefile"; then \
		$(MAKE) -C "$(LIBBT_DIR)" clean; \
	fi
	@if test -r "$@.changed"; then mv -f "$@.changed" "$@"; fi

$(LIBBT_LIB): $(LIBBT_BUILD_CONFIG)
	@echo "==> Building libbacktrace (configure + make, $(LIBBT_CFLAGS))"
	cd "$(LIBBT_DIR)" && \
		./configure CC=$(call make_shell_quote,$(CC)) \
			AR=$(call make_shell_quote,$(AR)) \
			RANLIB=$(call make_shell_quote,$(RANLIB)) \
			CFLAGS=$(call make_shell_quote,$(LIBBT_CFLAGS))
	@if test -f "$(LIBBT_DIR)/Makefile"; then $(MAKE) -C "$(LIBBT_DIR)"; fi

ifeq ($(LIBUV_MODE),bundled)
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

$(LIBUV_EXTRACTED): $(LIBUV_TARBALL)
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
	@touch "$@"

# Make does not otherwise notice changes to command-line CMake variables, while
# depending on the complete Makefile rebuilds libuv after unrelated edits.
# Preserve this stamp and the configured build tree when every effective input
# is unchanged.  On a change, recreate only libuv's generated build directory:
# CMake caches its compiler and generator, so an in-place reconfigure could
# silently retain an old toolchain or reject a new generator. CMake owns the
# archive tools associated with that compiler; explicit alternatives belong in
# LIBUV_CMAKE_FLAGS. CI uses the same profile string as its cross-run cache key.
$(LIBUV_BUILD_CONFIG): FORCE
	@set -e; \
	tmp="$${TMPDIR:-/tmp}/titan-libuv-build-config.$$$$.tmp"; \
	trap 'rm -f "$$tmp"' 0 1 2 15; \
	{ printf '%s\n' \
		$(call make_shell_quote,HOST_OS=$(HOST_OS)) \
		$(call make_shell_quote,HOST_ARCH=$(HOST_ARCH)) \
		$(call make_shell_quote,CC=$(CC)) \
		$(call make_shell_quote,CMAKE_GENERATOR=$(CMAKE_GENERATOR)) \
		$(call make_shell_quote,LIBUV_VERSION=$(LIBUV_VERSION)) \
		$(call make_shell_quote,LIBUV_BUILD_PROFILE=$(LIBUV_BUILD_PROFILE)) \
		$(call make_shell_quote,LIBUV_BUILD_TYPE=$(LIBUV_BUILD_TYPE)) \
		$(call make_shell_quote,LIBUV_CMAKE_FLAGS=$(LIBUV_CMAKE_FLAGS)) \
		$(call make_shell_quote,LIBUV_BUILD_CFLAGS=$(LIBUV_BUILD_CFLAGS)); } > "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then \
		rm -f "$$tmp"; \
	else \
		rm -rf "$(LIBUV_BUILD_DIR)"; \
		mkdir -p "$(@D)"; \
		mv -f "$$tmp" "$@"; \
	fi

$(LIBUV_LIB): $(LIBUV_EXTRACTED) $(LIBUV_BUILD_CONFIG)
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

else ifeq ($(LIBUV_MODE),system)
libuv: check-system-libuv

check-system-libuv:
	@if ! command -v "$(firstword $(LIBUV_PKG_CONFIG))" >/dev/null 2>&1; then \
	  echo "ERROR: pkg-config is required for LIBUV_MODE=system." >&2; \
	  echo "  Ubuntu/Debian: sudo apt-get install libuv1-dev pkg-config" >&2; \
	  echo "  Fedora: sudo dnf install libuv-devel pkgconf-pkg-config" >&2; \
	  echo "  macOS: brew install libuv pkgconf" >&2; exit 1; \
	fi
	@if ! $(LIBUV_PKG_CONFIG) --exists libuv; then \
	  echo "ERROR: pkg-config cannot find the libuv development package." >&2; \
	  echo "  Ubuntu/Debian: sudo apt-get install libuv1-dev pkg-config" >&2; \
	  echo "  Fedora: sudo dnf install libuv-devel pkgconf-pkg-config" >&2; \
	  echo "  macOS: brew install libuv pkgconf" >&2; \
	  echo "Homebrew may install libuv outside default compiler paths; its pkg-config output is required." >&2; exit 1; \
	fi
	@if ! $(LIBUV_PKG_CONFIG) --atleast-version="$(LIBUV_MIN_VERSION)" libuv; then \
	  found=`$(LIBUV_PKG_CONFIG) --modversion libuv 2>/dev/null || echo unknown`; \
	  echo "ERROR: system libuv $$found is too old; need >= $(LIBUV_MIN_VERSION)." >&2; exit 1; \
	fi
	@echo "==> Using system libuv `$(LIBUV_PKG_CONFIG) --modversion libuv`"
	@echo "    LIBUV_CPPFLAGS=$(LIBUV_CPPFLAGS)"
	@echo "    LIBUV_LDFLAGS=$(LIBUV_LDFLAGS)"

else
libuv: invalid-libuv-mode

invalid-libuv-mode:
	@echo "ERROR: unsupported LIBUV_MODE='$(LIBUV_MODE)'; choose 'bundled' or 'system'." >&2
	@exit 1
endif

libuv-config: libuv ## Print the effective libuv compiler and linker inputs
	@echo "LIBUV_MODE=$(LIBUV_MODE)"
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

llhttp: $(LLHTTP_ARCHIVE) ## Build/validate private llhttp support

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

$(LLHTTP_BUILD_CONFIG): FORCE $(LLHTTP_EXTRACTED) $(LLHTTP_SOURCES) \
		$(LLHTTP_HEADER)
	@mkdir -p "$(@D)"
	@tmp="$@.tmp"; \
	{ printf '%s\n' \
		$(call make_shell_quote,LLHTTP_VERSION=$(LLHTTP_VERSION)) \
		$(call make_shell_quote,LLHTTP_SHA256=$(LLHTTP_SHA256)) \
		$(call make_shell_quote,HOST_OS=$(HOST_OS)) \
		$(call make_shell_quote,HOST_ARCH=$(HOST_ARCH)) \
		$(call make_shell_quote,CC=$(CC)) \
		$(call make_shell_quote,AR=$(AR)) \
		$(call make_shell_quote,RANLIB=$(RANLIB)) \
		$(call make_shell_quote,ROCK_CFLAGS=$(ROCK_CFLAGS)) \
		$(call make_shell_quote,TITAN_EXTRA_CPPFLAGS=$(TITAN_EXTRA_CPPFLAGS)) \
		$(call make_shell_quote,TITAN_EXTRA_CFLAGS=$(TITAN_EXTRA_CFLAGS)) \
		$(call make_shell_quote,LLHTTP_CPPFLAGS=$(LLHTTP_CPPFLAGS)) \
		$(call make_shell_quote,LLHTTP_CFLAGS=$(LLHTTP_CFLAGS)) \
		$(call make_shell_quote,LLHTTP_BUILD_CFLAGS=$(LLHTTP_BUILD_CFLAGS)) \
		$(call make_shell_quote,SOURCES=$(LLHTTP_SOURCES)); \
	  for input in $(LLHTTP_SOURCES) $(LLHTTP_HEADER); do \
	    cksum "$$input"; \
	  done; } > "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then \
	  rm -f "$$tmp"; \
	else \
	  mv -f "$$tmp" "$@"; \
	fi

$(LLHTTP_BUILD_DIR)/%.o: $(LLHTTP_SRC_DIR)/src/%.c \
		$(LLHTTP_BUILD_CONFIG)
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(LLHTTP_CPPFLAGS) $(ROCK_CFLAGS) \
		$(LLHTTP_CFLAGS) $(TITAN_EXTRA_CFLAGS) $(LLHTTP_BUILD_CFLAGS) \
		-c "$<" -o "$@"

$(LLHTTP_ARCHIVE_CONFIG): FORCE $(firstword $(LLHTTP_OBJECTS))
	@mkdir -p "$(@D)"
	@set -e; \
	probe="$(@D)/.titan-llhttp-tool-probe.a"; tmp="$@.tmp"; \
	rm -f "$$probe" "$$tmp"; \
	if $(AR) qDc "$$probe" "$(firstword $(LLHTTP_OBJECTS))" \
			>/dev/null 2>&1 && \
	   $(RANLIB) -D "$$probe" >/dev/null 2>&1; then \
	  ar_mode=qDc; ranlib_mode=-D; deterministic=yes; \
	else \
	  rm -f "$$probe"; \
	  $(AR) qc "$$probe" "$(firstword $(LLHTTP_OBJECTS))" \
			>/dev/null 2>&1 || { \
	    echo "ERROR: configured AR supports neither qDc nor qc" >&2; exit 1; \
	  }; \
	  $(RANLIB) "$$probe" >/dev/null 2>&1 || { \
	    echo "ERROR: configured RANLIB is unusable" >&2; exit 1; \
	  }; \
	  ar_mode=qc; ranlib_mode=ordinary; deterministic=no; \
	fi; \
	rm -f "$$probe"; \
	{ printf '%s\n' \
		$(call make_shell_quote,AR=$(AR)) \
		$(call make_shell_quote,RANLIB=$(RANLIB)) \
		$(call make_shell_quote,MEMBERS=$(notdir $(LLHTTP_OBJECTS))) \
		"AR_MODE=$$ar_mode" "RANLIB_MODE=$$ranlib_mode" \
		"DETERMINISTIC=$$deterministic"; } > "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then \
	  rm -f "$$tmp"; \
	else \
	  mv -f "$$tmp" "$@"; \
	fi

$(LLHTTP_ARCHIVE): FORCE $(LLHTTP_OBJECTS) $(LLHTTP_ARCHIVE_CONFIG)
	@set -e; \
	expected="$$(printf '%s\n' $(notdir $(LLHTTP_OBJECTS)))"; actual=""; \
	if test -f "$@" && test ! -L "$@"; then \
	  actual="$$( $(AR) t "$@" 2>/dev/null | \
	    awk '$$0 !~ /^__[.]SYMDEF(_64)?( SORTED)?$$/' )"; \
	fi; \
	newer=$(call make_shell_quote,$(filter-out FORCE,$?)); \
	if test -n "$$newer" || test "$$actual" != "$$expected"; then \
	  tmp="$@.tmp"; rm -f "$$tmp"; \
	  ar_mode="$$(sed -n 's/^AR_MODE=//p' "$(LLHTTP_ARCHIVE_CONFIG)")"; \
	  ranlib_mode="$$(sed -n 's/^RANLIB_MODE=//p' \
	    "$(LLHTTP_ARCHIVE_CONFIG)")"; \
	  $(AR) "$$ar_mode" "$$tmp" $(LLHTTP_OBJECTS); \
	  if test "$$ranlib_mode" = -D; then \
	    $(RANLIB) -D "$$tmp"; \
	  else \
	    $(RANLIB) "$$tmp"; \
	  fi; \
	  actual="$$( $(AR) t "$$tmp" 2>/dev/null | \
	    awk '$$0 !~ /^__[.]SYMDEF(_64)?( SORTED)?$$/' )"; \
	  test "$$actual" = "$$expected" || { \
	    rm -f "$$tmp"; \
	    echo "ERROR: private llhttp archive has wrong member order" >&2; \
	    exit 1; \
	  }; \
	  mv -f "$$tmp" "$@"; \
	fi

sqlite3: $(SQLITE3_ARCHIVE) ## Build/validate private sqlite3 support

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

$(SQLITE3_BUILD_CONFIG): FORCE $(SQLITE3_EXTRACTED) $(SQLITE3_SOURCES) \
		$(SQLITE3_HEADER)
	@mkdir -p "$(@D)"
	@tmp="$@.tmp"; \
	{ printf '%s\n' \
		$(call make_shell_quote,SQLITE3_VERSION=$(SQLITE3_VERSION)) \
		$(call make_shell_quote,SQLITE3_SHA256=$(SQLITE3_SHA256)) \
		$(call make_shell_quote,HOST_OS=$(HOST_OS)) \
		$(call make_shell_quote,HOST_ARCH=$(HOST_ARCH)) \
		$(call make_shell_quote,CC=$(CC)) \
		$(call make_shell_quote,AR=$(AR)) \
		$(call make_shell_quote,RANLIB=$(RANLIB)) \
		$(call make_shell_quote,ROCK_CFLAGS=$(ROCK_CFLAGS)) \
		$(call make_shell_quote,TITAN_EXTRA_CPPFLAGS=$(TITAN_EXTRA_CPPFLAGS)) \
		$(call make_shell_quote,TITAN_EXTRA_CFLAGS=$(TITAN_EXTRA_CFLAGS)) \
		$(call make_shell_quote,SQLITE3_CPPFLAGS=$(SQLITE3_CPPFLAGS)) \
		$(call make_shell_quote,SQLITE3_CFLAGS=$(SQLITE3_CFLAGS)) \
		$(call make_shell_quote,SQLITE3_BUILD_CFLAGS=$(SQLITE3_BUILD_CFLAGS)) \
		$(call make_shell_quote,SOURCES=$(SQLITE3_SOURCES)); \
	  for input in $(SQLITE3_SOURCES) $(SQLITE3_HEADER); do \
	    cksum "$$input"; \
	  done; } > "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then \
	  rm -f "$$tmp"; \
	else \
	  mv -f "$$tmp" "$@"; \
	fi

$(SQLITE3_BUILD_DIR)/%.o: $(SQLITE3_SRC_DIR)/%.c \
		$(SQLITE3_BUILD_CONFIG)
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(SQLITE3_CPPFLAGS) $(ROCK_CFLAGS) \
		$(SQLITE3_CFLAGS) $(TITAN_EXTRA_CFLAGS) $(SQLITE3_BUILD_CFLAGS) \
		-c "$<" -o "$@"

$(SQLITE3_ARCHIVE_CONFIG): FORCE $(firstword $(SQLITE3_OBJECTS))
	@mkdir -p "$(@D)"
	@set -e; \
	probe="$(@D)/.titan-sqlite3-tool-probe.a"; tmp="$@.tmp"; \
	rm -f "$$probe" "$$tmp"; \
	if $(AR) qDc "$$probe" "$(firstword $(SQLITE3_OBJECTS))" \
			>/dev/null 2>&1 && \
	   $(RANLIB) -D "$$probe" >/dev/null 2>&1; then \
	  ar_mode=qDc; ranlib_mode=-D; deterministic=yes; \
	else \
	  rm -f "$$probe"; \
	  $(AR) qc "$$probe" "$(firstword $(SQLITE3_OBJECTS))" \
			>/dev/null 2>&1 || { \
	    echo "ERROR: configured AR supports neither qDc nor qc" >&2; exit 1; \
	  }; \
	  $(RANLIB) "$$probe" >/dev/null 2>&1 || { \
	    echo "ERROR: configured RANLIB is unusable" >&2; exit 1; \
	  }; \
	  ar_mode=qc; ranlib_mode=ordinary; deterministic=no; \
	fi; \
	rm -f "$$probe"; \
	{ printf '%s\n' \
		$(call make_shell_quote,AR=$(AR)) \
		$(call make_shell_quote,RANLIB=$(RANLIB)) \
		$(call make_shell_quote,MEMBERS=$(notdir $(SQLITE3_OBJECTS))) \
		"AR_MODE=$$ar_mode" "RANLIB_MODE=$$ranlib_mode" \
		"DETERMINISTIC=$$deterministic"; } > "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then \
	  rm -f "$$tmp"; \
	else \
	  mv -f "$$tmp" "$@"; \
	fi

$(SQLITE3_ARCHIVE): FORCE $(SQLITE3_OBJECTS) $(SQLITE3_ARCHIVE_CONFIG)
	@set -e; \
	expected="$$(printf '%s\n' $(notdir $(SQLITE3_OBJECTS)))"; actual=""; \
	if test -f "$@" && test ! -L "$@"; then \
	  actual="$$( $(AR) t "$@" 2>/dev/null | \
	    awk '$$0 !~ /^__[.]SYMDEF(_64)?( SORTED)?$$/' )"; \
	fi; \
	newer=$(call make_shell_quote,$(filter-out FORCE,$?)); \
	if test -n "$$newer" || test "$$actual" != "$$expected"; then \
	  tmp="$@.tmp"; rm -f "$$tmp"; \
	  ar_mode="$$(sed -n 's/^AR_MODE=//p' "$(SQLITE3_ARCHIVE_CONFIG)")"; \
	  ranlib_mode="$$(sed -n 's/^RANLIB_MODE=//p' \
	    "$(SQLITE3_ARCHIVE_CONFIG)")"; \
	  $(AR) "$$ar_mode" "$$tmp" $(SQLITE3_OBJECTS); \
	  if test "$$ranlib_mode" = -D; then \
	    $(RANLIB) -D "$$tmp"; \
	  else \
	    $(RANLIB) "$$tmp"; \
	  fi; \
	  actual="$$( $(AR) t "$$tmp" 2>/dev/null | \
	    awk '$$0 !~ /^__[.]SYMDEF(_64)?( SORTED)?$$/' )"; \
	  test "$$actual" = "$$expected" || { \
	    rm -f "$$tmp"; \
	    echo "ERROR: private sqlite3 archive has wrong member order" >&2; \
	    exit 1; \
	  }; \
	  mv -f "$$tmp" "$@"; \
	fi

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

$(OPENSSL_BUILD_CONFIG): FORCE $(OPENSSL_EXTRACTED)
	@set -e; \
	tmp="$${TMPDIR:-/tmp}/titan-openssl-build-config.$$$$.tmp"; \
	trap 'rm -f "$$tmp"' 0 1 2 15; \
	{ printf '%s\n' \
		$(call make_shell_quote,OPENSSL_VERSION=$(OPENSSL_VERSION)) \
		$(call make_shell_quote,OPENSSL_SHA256=$(OPENSSL_SHA256)) \
		$(call make_shell_quote,HOST_OS=$(HOST_OS)) \
		$(call make_shell_quote,HOST_ARCH=$(HOST_ARCH)) \
		$(call make_shell_quote,CC=$(CC)) \
		$(call make_shell_quote,AR=$(AR)) \
		$(call make_shell_quote,RANLIB=$(RANLIB)) \
		$(call make_shell_quote,OPENSSL_PERL=$(OPENSSL_PERL)) \
		$(call make_shell_quote,OPENSSL_CONFIGURE_FLAGS=$(OPENSSL_CONFIGURE_FLAGS)) \
		$(call make_shell_quote,OPENSSL_REQUIRED_CFLAGS=$(OPENSSL_REQUIRED_CFLAGS)) \
		$(call make_shell_quote,OPENSSL_BUILD_CFLAGS=$(OPENSSL_BUILD_CFLAGS)) \
		$(call make_shell_quote,TITAN_EXTRA_CPPFLAGS=$(TITAN_EXTRA_CPPFLAGS)); } \
	  > "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then \
	  rm -f "$$tmp"; \
	else \
	  rm -rf "$(OPENSSL_BUILD_DIR)"; \
	  mkdir -p "$(@D)"; \
	  mv -f "$$tmp" "$@"; \
	fi

$(OPENSSL_BUILD_COMPLETE): $(OPENSSL_EXTRACTED) $(OPENSSL_BUILD_CONFIG)
	@$(MAKE) --no-print-directory check-openssl-tools
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

lpeglabel: $(LPEGLABEL_ARCHIVE) ## Build/validate the private LPegLabel archive

# Hash every source/header and the exact public Lua configuration on every
# invocation. The stamp's mtime changes only when content or a target-affecting
# input changes, so warm builds remain true no-ops while same-mtime source
# rewrites still invalidate every private object.
$(LPEGLABEL_BUILD_CONFIG): FORCE $(LPEGLABEL_SOURCES) $(LPEGLABEL_HEADERS) \
		$(LUA_INSTALL_STAMP)
	@mkdir -p "$(@D)"
	@tmp="$@.tmp"; \
	{ printf '%s\n' \
		$(call make_shell_quote,LPEGLABEL_VERSION=$(LPEGLABEL_VERSION)) \
		$(call make_shell_quote,LPEGLABEL_COMMIT=$(LPEGLABEL_COMMIT)) \
		$(call make_shell_quote,HOST_OS=$(HOST_OS)) \
		$(call make_shell_quote,HOST_ARCH=$(HOST_ARCH)) \
		$(call make_shell_quote,CC=$(CC)) \
		$(call make_shell_quote,AR=$(AR)) \
		$(call make_shell_quote,RANLIB=$(RANLIB)) \
		$(call make_shell_quote,ROCK_LUA_INCDIR=$(ROCK_LUA_INCDIR)) \
		$(call make_shell_quote,ROCK_CFLAGS=$(ROCK_CFLAGS)) \
		$(call make_shell_quote,TITAN_EXTRA_CPPFLAGS=$(TITAN_EXTRA_CPPFLAGS)) \
		$(call make_shell_quote,TITAN_EXTRA_CFLAGS=$(TITAN_EXTRA_CFLAGS)) \
		$(call make_shell_quote,LPEGLABEL_CPPFLAGS=$(LPEGLABEL_CPPFLAGS)) \
		$(call make_shell_quote,LPEGLABEL_CFLAGS=$(LPEGLABEL_CFLAGS)) \
		$(call make_shell_quote,SOURCES=$(LPEGLABEL_SOURCES)) \
		$(call make_shell_quote,HEADERS=$(LPEGLABEL_HEADERS)) \
		$(call make_shell_quote,LUA_HEADERS=$(LPEGLABEL_LUA_HEADERS)); \
	  for input in $(LPEGLABEL_SOURCES) $(LPEGLABEL_HEADERS) \
			$(LPEGLABEL_LUA_HEADERS); do \
	    cksum "$$input"; \
	  done; } > "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then \
	  rm -f "$$tmp"; \
	else \
	  mv -f "$$tmp" "$@"; \
	fi

$(LPEGLABEL_BUILD_DIR)/%.o: $(LPEGLABEL_VENDOR_DIR)/%.c \
		$(LPEGLABEL_BUILD_CONFIG)
	@mkdir -p "$(@D)"
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(LPEGLABEL_CPPFLAGS) \
		-I"$(ROCK_LUA_INCDIR)" $(ROCK_CFLAGS) $(LPEGLABEL_CFLAGS) \
		$(TITAN_EXTRA_CFLAGS) -c "$<" -o "$@"

# Probe the configured archive commands rather than assuming GNU flags. Use
# deterministic qDc/-D only when both tools support that pair; otherwise verify
# the portable q/ordinary-ranlib pair. The selected mode is a stamped input to
# archive construction.
$(LPEGLABEL_ARCHIVE_CONFIG): FORCE $(firstword $(LPEGLABEL_OBJECTS))
	@mkdir -p "$(@D)"
	@set -e; \
	probe="$(@D)/.titan-lpeglabel-tool-probe.a"; \
	tmp="$@.tmp"; \
	rm -f "$$probe" "$$tmp"; \
	if $(AR) qDc "$$probe" "$(firstword $(LPEGLABEL_OBJECTS))" \
			>/dev/null 2>&1 && \
	   $(RANLIB) -D "$$probe" >/dev/null 2>&1; then \
	  ar_mode=qDc; ranlib_mode=-D; deterministic=yes; \
	else \
	  rm -f "$$probe"; \
	  if ! $(AR) qc "$$probe" "$(firstword $(LPEGLABEL_OBJECTS))" \
			>/dev/null 2>&1; then \
	    echo "ERROR: configured AR supports neither qDc nor qc" >&2; \
	    exit 1; \
	  fi; \
	  if ! $(RANLIB) "$$probe" >/dev/null 2>&1; then \
	    echo "ERROR: configured RANLIB supports neither -D nor ordinary mode" >&2; \
	    exit 1; \
	  fi; \
	  ar_mode=qc; ranlib_mode=ordinary; deterministic=no; \
	fi; \
	rm -f "$$probe"; \
	{ printf '%s\n' \
		$(call make_shell_quote,AR=$(AR)) \
		$(call make_shell_quote,RANLIB=$(RANLIB)) \
		$(call make_shell_quote,MEMBERS=$(notdir $(LPEGLABEL_OBJECTS))) \
		"AR_MODE=$$ar_mode" "RANLIB_MODE=$$ranlib_mode" \
		"DETERMINISTIC=$$deterministic"; } > "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then \
	  rm -f "$$tmp"; \
	else \
	  mv -f "$$tmp" "$@"; \
	fi

# FORCE makes exact ordered membership a warm-build invariant. Rebuild only
# when an input/configuration is newer or the regular archive's manifest is
# missing or wrong; successful validation leaves the archive mtime untouched.
$(LPEGLABEL_ARCHIVE): FORCE $(LPEGLABEL_OBJECTS) \
		$(LPEGLABEL_ARCHIVE_CONFIG)
	@set -e; \
	expected="$$(printf '%s\n' $(notdir $(LPEGLABEL_OBJECTS)))"; \
	actual=""; \
	if test -f "$@" && test ! -L "$@"; then \
	  actual="$$( $(AR) t "$@" 2>/dev/null | \
	    awk '$$0 !~ /^__[.]SYMDEF(_64)?( SORTED)?$$/' )"; \
	fi; \
	newer=$(call make_shell_quote,$(filter-out FORCE,$?)); \
	if test -n "$$newer" || test "$$actual" != "$$expected"; then \
	  tmp="$@.tmp"; \
	  rm -f "$$tmp"; \
	  ar_mode="$$(sed -n 's/^AR_MODE=//p' \
	    "$(LPEGLABEL_ARCHIVE_CONFIG)")"; \
	  ranlib_mode="$$(sed -n 's/^RANLIB_MODE=//p' \
	    "$(LPEGLABEL_ARCHIVE_CONFIG)")"; \
	  $(AR) "$$ar_mode" "$$tmp" $(LPEGLABEL_OBJECTS); \
	  if test "$$ranlib_mode" = -D; then \
	    $(RANLIB) -D "$$tmp"; \
	  else \
	    $(RANLIB) "$$tmp"; \
	  fi; \
	  actual="$$( $(AR) t "$$tmp" 2>/dev/null | \
	    awk '$$0 !~ /^__[.]SYMDEF(_64)?( SORTED)?$$/' )"; \
	  if test "$$actual" != "$$expected"; then \
	    rm -f "$$tmp"; \
	    echo "ERROR: private LPegLabel archive has wrong member order" >&2; \
	    exit 1; \
	  fi; \
	  mv -f "$$tmp" "$@"; \
	fi

runtime: $(TITAN_RUNTIME_LIB) ## Build the Titan C runtime archive used by every compiler mode

# titan.o and minicoro.o share one compile configuration. Recompute its
# contents without changing mtime on a warm build so switching compilers,
# include roots, or sanitizer flags cannot reuse stale native objects or the
# archive made from them.
$(RUNTIME_BUILD_CONFIG): FORCE
	@tmp="$@.tmp"; \
	{ printf '%s\n' \
		$(call make_shell_quote,HOST_OS=$(HOST_OS)) \
		$(call make_shell_quote,HOST_ARCH=$(HOST_ARCH)) \
		$(call make_shell_quote,PREFIX=$(PREFIX)) \
		$(call make_shell_quote,CC=$(CC)) \
		$(call make_shell_quote,CFLAGS=$(CFLAGS)) \
		$(call make_shell_quote,TITAN_EXTRA_CPPFLAGS=$(TITAN_EXTRA_CPPFLAGS)) \
		$(call make_shell_quote,TITAN_EXTRA_CFLAGS=$(TITAN_EXTRA_CFLAGS)) \
		$(call make_shell_quote,LUA_DIR=$(LUA_DIR)) \
		$(call make_shell_quote,TITAN_RUNTIME_LUA_SOURCE_PATH=$(TITAN_RUNTIME_LUA_SOURCE_PATH)) \
		$(call make_shell_quote,LUA_PLATFORM=$(LUA_PLATFORM)) \
		$(call make_shell_quote,LUA_MYCFLAGS=$(LUA_MYCFLAGS)) \
		$(call make_shell_quote,LUA_MYLDFLAGS=$(LUA_MYLDFLAGS)) \
		$(call make_shell_quote,LUA_MYLIBS=$(LUA_MYLIBS)) \
		$(call make_shell_quote,INCLUDES=titan-runtime $(TITAN_RUNTIME_LUA_SOURCE_PATH) $(LIBBT_DIR)); } \
		> "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then \
		rm -f "$$tmp"; \
	else \
		mv -f "$$tmp" "$@"; \
	fi

# ltitanlib.o has a distinct public-Lua compile and shared-module link surface.
# Keep link inputs in the same stamp: a changed sanitizer LDFLAG must relink
# titan.so even when its small C source and compile flags are otherwise stable.
$(LTITANLIB_BUILD_CONFIG): FORCE
	@tmp="$@.tmp"; \
	{ printf '%s\n' \
		$(call make_shell_quote,HOST_OS=$(HOST_OS)) \
		$(call make_shell_quote,HOST_ARCH=$(HOST_ARCH)) \
		$(call make_shell_quote,PREFIX=$(PREFIX)) \
		$(call make_shell_quote,CC=$(CC)) \
		$(call make_shell_quote,ROCK_LUA_INCDIR=$(ROCK_LUA_INCDIR)) \
		$(call make_shell_quote,ROCK_CFLAGS=$(ROCK_CFLAGS)) \
		$(call make_shell_quote,TITAN_EXTRA_CFLAGS=$(TITAN_EXTRA_CFLAGS)) \
		$(call make_shell_quote,ROCK_LD=$(ROCK_LD)) \
		$(call make_shell_quote,ROCK_LIBFLAG=$(ROCK_LIBFLAG)) \
		$(call make_shell_quote,TITAN_EXTRA_LDFLAGS=$(TITAN_EXTRA_LDFLAGS)); } \
		> "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then \
		rm -f "$$tmp"; \
	else \
		mv -f "$$tmp" "$@"; \
	fi

$(RUNTIME_O): titan-runtime/titan.c titan-runtime/titan.h \
		$(RUNTIME_BUILD_CONFIG) | $(TITAN_RUNTIME_LUA_LIB) $(LIBBT_LIB)
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(CFLAGS) $(TITAN_EXTRA_CFLAGS) \
		-c titan-runtime/titan.c -I titan-runtime -I $(TITAN_RUNTIME_LUA_SOURCE_PATH) \
		-I $(LIBBT_DIR) -o $@

$(MINICORO_O): titan-runtime/minicoro.c \
		titan-runtime/minicoro.h titan-runtime/titan/ffi.h \
		$(RUNTIME_BUILD_CONFIG) | $(TITAN_RUNTIME_LUA_LIB) $(LIBBT_LIB)
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(CFLAGS) $(TITAN_EXTRA_CFLAGS) \
		-c titan-runtime/minicoro.c -I titan-runtime -I $(TITAN_RUNTIME_LUA_SOURCE_PATH) \
		-I $(LIBBT_DIR) -o $@

$(RUNTIME_ARCHIVE_CONFIG): FORCE
	@tmp="$@.tmp"; \
	{ printf '%s\n' \
		$(call make_shell_quote,AR=$(AR)) \
		$(call make_shell_quote,RANLIB=$(RANLIB)) \
		$(call make_shell_quote,MEMBERS=$(notdir $(TITAN_RUNTIME_OBJECTS))); } \
		> "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then \
		rm -f "$$tmp"; \
	else \
		mv -f "$$tmp" "$@"; \
	fi

$(TITAN_RUNTIME_LIB): $(TITAN_RUNTIME_OBJECTS) $(RUNTIME_ARCHIVE_CONFIG)
	rm -f "$@"
	$(AR) rcs "$@" $(TITAN_RUNTIME_OBJECTS)
	$(RANLIB) "$@"

$(LTITANLIB_O): titan-runtime/ltitanlib.c $(LTITANLIB_BUILD_CONFIG) $(LUA_INSTALL_STAMP)
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

# The active library path initially needs only Titan's bare Lua support entry. A
# valid support/full image already at that path is deliberately preserved: a
# repeated source build must never shrink a complete stdlib back to bootstrap.
stage-titan-bootstrap: $(TITAN_BOOTSTRAP_SO)
	@test -n "$(strip $(ROCKS_TREE))" || { \
	  echo "ERROR: stage-titan-bootstrap requires ROCKS_TREE" >&2; exit 1; \
	}
	@set -e; \
	canonical="$(TITAN_CANONICAL_SUPPORT_SO)"; \
	validate_support() { \
	  TITAN_SUPPORT_IMAGE="$$1" "$(TITAN_LUA)" -E -e \
	    'local image = assert(os.getenv("TITAN_SUPPORT_IMAGE")); local open, err = package.loadlib(image, "luaopen_titan"); if not open then io.stderr:write(tostring(err), "\n"); os.exit(1) end; local values = table.pack(pcall(open)); if not values[1] or values.n ~= 2 or type(values[2]) ~= "table" or type(values[2]._loadlib) ~= "function" or type(values[2]._loadlibglobal) ~= "function" then io.stderr:write("luaopen_titan did not return the required support table\n"); os.exit(1) end'; \
	}; \
	mkdir -p "$$(dirname "$$canonical")"; \
	if test -e "$$canonical" || test -L "$$canonical"; then \
	  if ! validate_support "$$canonical"; then \
	    echo "ERROR: existing Titan library image is not a usable support provider: $$canonical" >&2; \
	    exit 1; \
	  fi; \
	else \
	  tmp="$$canonical.tmp.$$$$"; \
	  trap 'rm -f "$$tmp"' EXIT HUP INT TERM; \
	  install -m 0755 "$(TITAN_BOOTSTRAP_SO)" "$$tmp"; \
	  validate_support "$$tmp" || { \
	    echo "ERROR: private Titan bootstrap is not a usable support provider" >&2; \
	    exit 1; \
	  }; \
	  if test -e "$$canonical" || test -L "$$canonical"; then \
	    validate_support "$$canonical" || { \
	      echo "ERROR: concurrently staged Titan image is incompatible: $$canonical" >&2; \
	      exit 1; \
	    }; \
	  else \
	    mv -f "$$tmp" "$$canonical"; \
	  fi; \
	  trap - EXIT HUP INT TERM; \
	  rm -f "$$tmp"; \
	fi

# LuaRocks passes ROCKS_TREE only for its source build. A direct `make titan`
# therefore stops after producing the runtime archive and the private support
# bootstrap, while the rock build also stages the SDK inputs needed by the
# just-installed compiler. No Titan stdlib source is compiled before LuaRocks
# deploys titanc, and the private bootstrap never shares a timestamp with the
# final paired standard-library provider.
titan: lpeglabel libbacktrace libuv openssl llhttp sqlite3 $(TITAN_RUNTIME_LIB) $(TITAN_BOOTSTRAP_SO) ## Build Titan's native runtime and Lua bootstrap
	@if test -n "$(strip $(ROCKS_TREE))"; then \
	  $(MAKE) --no-print-directory install-titan-sdk \
		ROCKS_TREE=$(call make_shell_quote,$(ROCKS_TREE)) \
		LIBUV_MODE=$(call make_shell_quote,$(LIBUV_MODE)); \
	fi

install-titan-sdk: $(TITAN_RUNTIME_LIB) $(TITAN_BOOTSTRAP_SO) $(LUA_LIB) \
		$(LIBBT_LIB) $(LIBUV_LIB) $(OPENSSL_LIBS) $(LLHTTP_HEADER) \
		$(SQLITE3_HEADER) $(TITAN_SDK_ROOT_HEADERS) \
		$(TITAN_SDK_NAMESPACED_HEADERS) stage-titan-bootstrap
	@test -n "$(strip $(ROCKS_TREE))" || { \
	  echo "ERROR: install-titan-sdk requires ROCKS_TREE" >&2; exit 1; \
	}
	@set -e; \
	mkdir -p "$(ROCKS_TREE)"; \
	rocks_tree=$$(CDPATH= cd "$(ROCKS_TREE)" && pwd -P); \
	version_dir="$$rocks_tree/lib/titan/$(TITAN_LIBRARY_VERSION)"; \
	echo "==> Installing Titan SDK into $$rocks_tree"; \
	rm -f "$$rocks_tree/include/titan_longjmp.h"; \
	mkdir -p "$$rocks_tree/src/$(LUA_DIR)" \
		"$$rocks_tree/include/titan" "$$rocks_tree/lib" \
		"$$version_dir"; \
	install -m 0644 $(LUA_DIR)/src/*.c $(LUA_DIR)/src/*.h \
		"$$rocks_tree/src/$(LUA_DIR)/"; \
	install -m 0644 "$(LUA_LIB)" "$$rocks_tree/lib/liblua.a"; \
	rm -f "$$rocks_tree/lib/libtitan.a"; \
	install -m 0644 "$(TITAN_RUNTIME_LIB)" "$$version_dir/libtitan.a"; \
	install -m 0644 "$(LIBBT_LIB)" "$$rocks_tree/lib/libbacktrace.a"; \
	install -m 0644 $(TITAN_SDK_ROOT_HEADERS) "$$rocks_tree/include/"; \
	install -m 0644 $(TITAN_SDK_NAMESPACED_HEADERS) \
		"$$rocks_tree/include/titan/"; \
	if test "$(LIBUV_MODE)" != system; then \
	  cp -R "$(LIBUV_SRC_DIR)/include/." "$$rocks_tree/include/"; \
	else \
	  rm -f "$$rocks_tree/include/uv.h"; \
	  rm -rf "$$rocks_tree/include/uv"; \
	fi; \
	if test "$(OPENSSL_MODE)" != system; then \
	  mkdir -p "$$rocks_tree/include/openssl"; \
	  install -m 0644 $(OPENSSL_SRC_DIR)/include/openssl/*.h \
	    $(OPENSSL_BUILD_DIR)/include/openssl/*.h "$$rocks_tree/include/openssl/"; \
	else \
	  rm -rf "$$rocks_tree/include/openssl"; \
	fi; \
	install -m 0644 "$(LLHTTP_HEADER)" "$$rocks_tree/include/"; \
	install -m 0644 "$(SQLITE3_HEADER)" "$$rocks_tree/include/"; \
	rm -f "$$rocks_tree/lib/libuv.a"

# The real bundled libuv archive is private input to the paired titan.so/titan.a
# provider. The install recipe above removes copies left by older SDKs so
# extensions cannot create a second native instance. The post-install build
# consumes the installed Titan runtime archive rather than smuggling source-tree
# runtime objects into standard modules. System libuv remains an ordered final
# link input; bundled mode gets headers from the staged SDK and gives the private
# archive to titanc through the same -X payload as ltitanlib.o and the private
# LPegLabel archive.
ifeq ($(STDLIB_USE_INSTALLED_RUNTIME),1)
  STDLIB_PLATFORM_PREREQS :=
  STDLIB_NATIVE_PREREQS := $(STDLIB_EXTRA_OBJECTS)
  STDLIB_RUNTIME_ARCHIVE_PREREQ :=
  STDLIB_TOOL_PREREQS :=
  ifeq ($(LIBUV_MODE),system)
    STDLIB_UV_CPPFLAGS := $(LIBUV_CPPFLAGS)
    STDLIB_UV_LDFLAGS := $(LIBUV_PROVIDER_LDFLAGS)
  else
    STDLIB_UV_CPPFLAGS := $(filter-out -I$(LIBUV_INCLUDE_DIR),$(LIBUV_CPPFLAGS))
    STDLIB_UV_LDFLAGS := $(LIBUV_PROVIDER_LDFLAGS)
  endif
  STDLIB_UV_CFLAGS := $(LIBUV_CFLAGS)
else
  STDLIB_PLATFORM_PREREQS := libuv openssl
  # The provider pair may extract every runtime member. Keep the runtime archive
  # itself order-only so its exact-membership repair runs before the compiler
  # without turning a no-op archive validation into a relink.
  STDLIB_NATIVE_PREREQS := $(TITAN_RUNTIME_OBJECTS) \
	$(STDLIB_EXTRA_OBJECTS)
  STDLIB_RUNTIME_ARCHIVE_PREREQ := $(TITAN_RUNTIME_LIB)
  # A standalone PREFIX is prepared with `make lua` before stdlib. Depending
  # on its prefix-local stamp keeps native source builds ordered without
  # rerunning Lua's installation for every module (or during Make dry runs).
  STDLIB_TOOL_PREREQS := $(LUA_INSTALL_STAMP) $(LIBBT_LIB)
  STDLIB_UV_CPPFLAGS := $(LIBUV_CPPFLAGS)
  STDLIB_UV_CFLAGS := $(LIBUV_CFLAGS)
  # Only platform/system final libraries belong here. Bundled libuv is in
  # STDLIB_EXTRA_OBJECTS so the compiler force-loads it into titan.so and
  # flattens it into titan.a.
  STDLIB_UV_LDFLAGS := $(strip $(LIBUV_PROVIDER_LDFLAGS))
endif

stdlib: $(STDLIB_PROVIDER_OUTPUTS) $(STDLIB_SHIMS) ## Build the paired standard-library provider

$(STDLIB_PROVIDER_OUTPUTS) $(STDLIB_SHIMS): $(STDLIB_COMPLETION_STAMP)
	@test -f "$@" && test ! -L "$@" || { \
	  echo "ERROR: completed stdlib provider is missing or nonregular: $@" >&2; exit 1; \
	}

# Record every effective native and compiler input that can change the
# standard-library provider pair. Preserve mtimes when the configuration is
# unchanged so a valid warm pair does not oscillate between bootstrap and full
# forms. When content changes, explicitly invalidate the completion stamp so
# rebuild correctness does not depend on filesystem timestamp granularity or
# Make's prerequisite re-stat behavior.
$(STDLIB_CONFIG_STAMP): FORCE $(STDLIB_NATIVE_IDENTITY_PREREQS)
	@set -e; \
	tmp="$@.tmp"; \
	{ printf '%s\n' \
		$(call make_shell_quote,HOST_OS=$(HOST_OS)) \
		$(call make_shell_quote,HOST_ARCH=$(HOST_ARCH)) \
		$(call make_shell_quote,TITAN_ABI_VERSION=$(TITAN_ABI_VERSION)) \
		$(call make_shell_quote,TITAN_VERSION=$(TITAN_VERSION)) \
		$(call make_shell_quote,TITAN_LIBRARY_VERSION=$(TITAN_LIBRARY_VERSION)) \
		$(call make_shell_quote,CC=$(CC)) \
		$(call make_shell_quote,AR=$(AR)) \
		$(call make_shell_quote,RANLIB=$(RANLIB)) \
		$(call make_shell_quote,TITANC=$(TITANC)) \
		$(call make_shell_quote,TITAN_LUA=$(TITAN_LUA)) \
		$(call make_shell_quote,STDLIB_USE_INSTALLED_RUNTIME=$(STDLIB_USE_INSTALLED_RUNTIME)) \
		$(call make_shell_quote,STDLIB_ROOTS=$(STDLIB_ROOTS)) \
		$(call make_shell_quote,STDLIB_TITAN_SOURCES=$(STDLIB_TITAN_SOURCES)) \
		$(call make_shell_quote,STDLIB_SHIMS=$(STDLIB_SHIMS)) \
		$(call make_shell_quote,STDLIB_CONTAINER=$(STDLIB_CONTAINER)) \
		$(call make_shell_quote,STDLIB_STATIC_ARCHIVE=$(STDLIB_STATIC_ARCHIVE)) \
		$(call make_shell_quote,STDLIB_PROVIDER_OUTPUTS=$(STDLIB_PROVIDER_OUTPUTS)) \
		$(call make_shell_quote,STDLIB_EXTRA_OBJECTS=$(STDLIB_EXTRA_OBJECTS)) \
		$(call make_shell_quote,STDLIB_LPEGLABEL_CPPFLAGS=$(STDLIB_LPEGLABEL_CPPFLAGS)) \
		$(call make_shell_quote,STDLIB_HTTP_CPPFLAGS=$(STDLIB_HTTP_CPPFLAGS)) \
		$(call make_shell_quote,STDLIB_SQLITE3_CPPFLAGS=$(STDLIB_SQLITE3_CPPFLAGS)) \
		$(call make_shell_quote,SQLITE3_TITAN_HEADERS=$(SQLITE3_TITAN_HEADERS)) \
		$(call make_shell_quote,STDLIB_OPENSSL_CPPFLAGS=$(STDLIB_OPENSSL_CPPFLAGS)) \
		$(call make_shell_quote,STDLIB_OPENSSL_LDFLAGS=$(STDLIB_OPENSSL_LDFLAGS)) \
		$(call make_shell_quote,STDLIB_EMBEDDED_FORMAT_INPUTS=$(STDLIB_EMBEDDED_FORMAT_INPUTS)) \
		$(call make_shell_quote,LPEGLABEL_VERSION=$(LPEGLABEL_VERSION)) \
		$(call make_shell_quote,LPEGLABEL_COMMIT=$(LPEGLABEL_COMMIT)) \
		$(call make_shell_quote,LPEGLABEL_SOURCES=$(LPEGLABEL_SOURCES)) \
		$(call make_shell_quote,LPEGLABEL_HEADERS=$(LPEGLABEL_HEADERS)) \
		$(call make_shell_quote,LPEGLABEL_ARCHIVE=$(LPEGLABEL_ARCHIVE)) \
		$(call make_shell_quote,LPEGLABEL_BUILD_CONFIG=$(LPEGLABEL_BUILD_CONFIG)) \
		$(call make_shell_quote,LPEGLABEL_ARCHIVE_CONFIG=$(LPEGLABEL_ARCHIVE_CONFIG)) \
		$(call make_shell_quote,TITAN_EXTRA_CPPFLAGS=$(TITAN_EXTRA_CPPFLAGS)) \
		$(call make_shell_quote,TITAN_EXTRA_CFLAGS=$(TITAN_EXTRA_CFLAGS)) \
		$(call make_shell_quote,TITAN_EXTRA_LDFLAGS=$(TITAN_EXTRA_LDFLAGS)) \
		$(call make_shell_quote,TITAN_NO_LINE_DIRECTIVES=$(TITAN_NO_LINE_DIRECTIVES)) \
		$(call make_shell_quote,LIBUV_MODE=$(LIBUV_MODE)) \
		$(call make_shell_quote,LIBUV_VERSION=$(LIBUV_VERSION)) \
		$(call make_shell_quote,STDLIB_UV_CPPFLAGS=$(STDLIB_UV_CPPFLAGS)) \
		$(call make_shell_quote,STDLIB_UV_CFLAGS=$(STDLIB_UV_CFLAGS)) \
		$(call make_shell_quote,STDLIB_UV_LDFLAGS=$(STDLIB_UV_LDFLAGS)) \
		$(call make_shell_quote,LLHTTP_VERSION=$(LLHTTP_VERSION)) \
		$(call make_shell_quote,SQLITE3_VERSION=$(SQLITE3_VERSION)) \
		$(call make_shell_quote,SQLITE3_SHA256=$(SQLITE3_SHA256)) \
		$(call make_shell_quote,SQLITE3_CFLAGS=$(SQLITE3_CFLAGS)) \
		$(call make_shell_quote,SQLITE3_BUILD_CFLAGS=$(SQLITE3_BUILD_CFLAGS)) \
		$(call make_shell_quote,LLHTTP_SHA256=$(LLHTTP_SHA256)) \
		$(call make_shell_quote,LLHTTP_SOURCE_NAMES=$(LLHTTP_SOURCE_NAMES)) \
		$(call make_shell_quote,LLHTTP_BUILD_CFLAGS=$(LLHTTP_BUILD_CFLAGS)) \
		$(call make_shell_quote,OPENSSL_MODE=$(OPENSSL_MODE)) \
		$(call make_shell_quote,OPENSSL_VERSION=$(OPENSSL_VERSION)) \
		$(call make_shell_quote,OPENSSL_SHA256=$(OPENSSL_SHA256)) \
		$(call make_shell_quote,OPENSSL_CONFIGURE_FLAGS=$(OPENSSL_CONFIGURE_FLAGS)) \
		$(call make_shell_quote,OPENSSL_BUILD_CFLAGS=$(OPENSSL_BUILD_CFLAGS)); \
	  for input in $(LPEGLABEL_SOURCES) $(LPEGLABEL_HEADERS) \
			$(LPEGLABEL_BUILD_CONFIG) \
			$(LPEGLABEL_ARCHIVE_CONFIG) $(LPEGLABEL_ARCHIVE) \
			$(LLHTTP_BUILD_CONFIG) $(LLHTTP_ARCHIVE_CONFIG) \
			$(SQLITE3_BUILD_CONFIG) $(SQLITE3_ARCHIVE_CONFIG) \
			$(LLHTTP_ARCHIVE) $(SQLITE3_ARCHIVE) $(OPENSSL_EXTRA_OBJECTS); do \
	    cksum "$$input"; \
	  done; } \
		> "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then \
		rm -f "$$tmp"; \
	else \
		rm -f "$(STDLIB_COMPLETION_STAMP)" && \
		mv -f "$$tmp" "$@"; \
	fi

# FORCE runs the inexpensive completeness check on every invocation. The
# compiler itself runs only when an input is newer, configuration changed, or
# one public output is absent. All twenty-one roots are explicit source roots in one
# process, so their internal imports are linked into the paired titan.so/titan.a
# provider. The warm check rescans the archive without rewriting either output.
$(STDLIB_COMPLETION_STAMP): FORCE $(STDLIB_TITAN_SOURCES) $(SQLITE3_TITAN_HEADERS) titanc \
		$(TITAN_COMPILER_LUA) Makefile $(STDLIB_CONFIG_STAMP) \
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
	validate_archive() { \
	  env -u LUA_PATH -u LUA_CPATH -u LUA_PATH_5_5 -u LUA_CPATH_5_5 \
	    TITAN_STDLIB_ARCHIVE=$(call make_shell_quote,$(STDLIB_STATIC_ARCHIVE)) \
	    TITAN_STDLIB_ABI=$(call make_shell_quote,$(TITAN_ABI_VERSION)) \
	    TITAN_STDLIB_ROOTS=$(call make_shell_quote,$(STDLIB_ROOTS)) \
	    "$(TITAN_LUA)" -E -e \
	      'package.path="./?.lua;./?/init.lua;" .. package.path; local metadata = require "titan-compiler.staticmetadata"; local archive = assert(os.getenv("TITAN_STDLIB_ARCHIVE")); local provider, scan_error = metadata.scan_archive(archive, { expected_abi = assert(os.getenv("TITAN_STDLIB_ABI")) }); if not provider then error(scan_error, 0) end; local expected = {}; for name in assert(os.getenv("TITAN_STDLIB_ROOTS")):gmatch("%S+") do expected[name] = true end; for name in pairs(provider.entries) do if not expected[name] then error("unexpected stdlib archive metadata key " .. name, 0) end; expected[name] = nil end; local missing = next(expected); if missing then error("missing stdlib archive metadata key " .. missing, 0) end'; \
	}; \
	if test "$$stale" = 0 && ! validate_archive; then stale=1; fi; \
	if test "$$stale" = 1; then \
	  rm -f "$@"; \
	  rm -f $(STDLIB_SOS) $(STDLIB_QUALIFIED_SOS); \
	  rm -rf $(addsuffix .dSYM,$(STDLIB_SOS)) \
		$(addsuffix .dSYM,$(STDLIB_QUALIFIED_SOS)); \
	  unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5; \
	  CC=$(call make_shell_quote,$(CC)) \
	    AR=$(call make_shell_quote,$(AR)) \
	    RANLIB=$(call make_shell_quote,$(RANLIB)) \
	    TITAN_PATH$(TITAN_LIBRARY_VERSION_SUFFIX)=$(call make_shell_quote,$(CURDIR)) TITAN_PATH= \
	    TITAN_ROCKS_ROOT=$(call make_shell_quote,$(TITAN_ROCKS_ROOT)) \
	    TITAN_RUNTIME_PREBUILT=1 \
	    TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CPPFLAGS) $(STDLIB_LPEGLABEL_CPPFLAGS) $(STDLIB_HTTP_CPPFLAGS) $(STDLIB_SQLITE3_CPPFLAGS) $(STDLIB_OPENSSL_CPPFLAGS) $(STDLIB_UV_CPPFLAGS))) \
	    TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CFLAGS) $(STDLIB_UV_CFLAGS))) \
	    TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_LDFLAGS) $(STDLIB_UV_LDFLAGS) $(STDLIB_OPENSSL_LDFLAGS))) \
	    $(TITANC) $(STDLIB_ROOTS) -X $(STDLIB_EXTRA_OBJECTS); \
	  for output in $(STDLIB_PROVIDER_OUTPUTS) $(STDLIB_SHIMS); do \
	    test -f "$$output" && test ! -L "$$output" || { \
	      echo "ERROR: stdlib build did not produce $$output" >&2; exit 1; \
	    }; \
	  done; \
	  validate_archive || { \
	    echo "ERROR: stdlib build produced an invalid $(STDLIB_STATIC_ARCHIVE)" >&2; \
	    exit 1; \
	  }; \
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
install-stdlib publish-stdlib: scripts/stdlib_installer.lua
	@set -e; \
	mkdir -p "$(TITAN_INSTALL_TREE)" "$(TITAN_SHARE_DIR)/LICENSES"; \
	install -m 0644 THIRD_PARTY_NOTICES.md \
	  "$(TITAN_SHARE_DIR)/THIRD_PARTY_NOTICES.md"; \
	install -m 0644 $(STDLIB_LICENSES) \
	  "$(TITAN_SHARE_DIR)/LICENSES/"; \
	root=$$(CDPATH= cd "$(TITAN_INSTALL_TREE)" && pwd -P); \
	stage=$(call make_shell_quote,$(STDLIB_INSTALL_STAGE)); \
	( unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5; \
	  export CC=$(call make_shell_quote,$(CC)); \
	  export AR=$(call make_shell_quote,$(AR)); \
	  export RANLIB=$(call make_shell_quote,$(RANLIB)); \
	  export TITAN_PATH$(TITAN_LIBRARY_VERSION_SUFFIX)=$(call make_shell_quote,$(CURDIR)); \
	  export TITAN_PATH=; \
	  export TITAN_ROCKS_ROOT=$(call make_shell_quote,$(TITAN_ROCKS_ROOT)); \
	  export TITAN_RUNTIME_PREBUILT=1; \
	  export TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CPPFLAGS) $(STDLIB_HTTP_CPPFLAGS) $(STDLIB_SQLITE3_CPPFLAGS) $(STDLIB_OPENSSL_CPPFLAGS) $(STDLIB_UV_CPPFLAGS))); \
	  export TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CFLAGS) $(STDLIB_UV_CFLAGS))); \
	  export TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_LDFLAGS) $(STDLIB_UV_LDFLAGS) $(STDLIB_OPENSSL_LDFLAGS))); \
	  "$(TITAN_LUA)" -E "$(CURDIR)/scripts/stdlib_installer.lua" \
	    "$$stage" "$$root" )

# The post-install compiler runs in a private destination-filesystem directory,
# so every -X input is absolute. Both modes carry ltitanlib.o, private LPegLabel,
# private llhttp, and private SQLite. Bundled mode additionally
# carries the pinned libuv and OpenSSL archives; system dependencies remain
# final-link inputs instead.
STDLIB_STAGED_EXTRA_OBJECTS = $(foreach object,$(STDLIB_EXTRA_OBJECTS),$(abspath $(object)))

# LuaRocks invokes this only after deploying titanc and its Lua compiler
# modules. Build all twenty-one source roots once in a private directory on the
# destination filesystem. The Lua publisher validates the complete protocol
# and exact staged titan.test compiler source, commits twenty-one shims, that
# source, the archive, and the one macOS dSYM before renaming titan.so last;
# any caught failure restores the prior pair or first-install bootstrap.
rock-post-install: scripts/stdlib_installer.lua $(STDLIB_EXTRA_OBJECTS) openssl
	@test -n "$(strip $(ROCKS_TREE))" || { \
	  echo "ERROR: rock-post-install requires ROCKS_TREE" >&2; exit 1; \
	}
	@test -n "$(strip $(ROCK_TITANC))" && test -x "$(ROCK_TITANC)" || { \
	  echo "ERROR: rock-post-install requires deployed ROCK_TITANC" >&2; exit 1; \
	}
	@test -n "$(strip $(ROCK_LUA))" && test -x "$(ROCK_LUA)" || { \
	  echo "ERROR: rock-post-install requires ROCK_LUA" >&2; exit 1; \
	}
	@set -e; \
	mkdir -p "$(ROCKS_TREE)/lib/titan/$(TITAN_LIBRARY_VERSION)"; \
	rocks_tree=$$(CDPATH= cd "$(ROCKS_TREE)" && pwd -P); \
	version_dir="$$rocks_tree/lib/titan/$(TITAN_LIBRARY_VERSION)"; \
	share_dir="$$rocks_tree/share/titan"; \
	mkdir -p "$$share_dir/LICENSES"; \
	install -m 0644 THIRD_PARTY_NOTICES.md \
	  "$$share_dir/THIRD_PARTY_NOTICES.md"; \
	install -m 0644 $(STDLIB_LICENSES) "$$share_dir/LICENSES/"; \
	stage=$$(mktemp -d "$$version_dir/.titan-stdlib-stage.XXXXXX"); \
	trap 'rm -rf "$$stage"' EXIT HUP INT TERM; \
	echo "==> Building paired Titan stdlib providers with $(ROCK_TITANC)"; \
	( cd "$$stage"; \
	  unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5; \
	  mkdir -p titan; \
	  install -m 0644 "$(CURDIR)/titan/test.titan" titan/test.titan; \
	  export TITAN_ROCKS_ROOT="$$rocks_tree"; \
	  export TITAN_PATH$(TITAN_LIBRARY_VERSION_SUFFIX)="$$version_dir"; \
	  export TITAN_PATH=; \
	  export TITAN_RUNTIME_PREBUILT=1; \
	  export CC=$(call make_shell_quote,$(CC)); \
	  export AR=$(call make_shell_quote,$(AR)); \
	  export RANLIB=$(call make_shell_quote,$(RANLIB)); \
	  export TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CPPFLAGS) $(STDLIB_LPEGLABEL_CPPFLAGS) $(STDLIB_HTTP_CPPFLAGS) $(STDLIB_SQLITE3_CPPFLAGS) $(STDLIB_OPENSSL_CPPFLAGS) $(STDLIB_UV_CPPFLAGS))); \
	  export TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CFLAGS) $(STDLIB_UV_CFLAGS))); \
	  export TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_LDFLAGS) $(STDLIB_UV_LDFLAGS) $(STDLIB_OPENSSL_LDFLAGS))); \
	  $(call make_shell_quote,$(ROCK_TITANC)) --tree \
	    $(call make_shell_quote,$(CURDIR)) $(STDLIB_ROOTS) \
	    -X $(STDLIB_STAGED_EXTRA_OBJECTS); \
	  if test -n $(call make_shell_quote,$(strip $(TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT))); then \
	    "$(ROCK_LUA)" -E \
	      "$(CURDIR)/spec/support/ci_asan_generated_c_context.lua" \
	      snapshot \
	      $(call make_shell_quote,$(strip $(TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT))) \
	      "$$stage/titan.so" "$(CURDIR)/titan" "$$version_dir/titan.so" \
	      "$(CURDIR)/titan"; \
	  fi; \
	  "$(ROCK_LUA)" -E "$(CURDIR)/scripts/stdlib_installer.lua" \
	    "$$stage" "$$rocks_tree" ); \
	trap - EXIT HUP INT TERM; \
	rm -rf "$$stage"

# Compatibility name for callers of the former rockspec build target.  It no
# longer builds stdlib before LuaRocks has deployed the compiler.
rock-build: titan

# --test gives its first root ownership of the aggregate executable path. Keep
# that role explicit and assign it to titan.test's tests, not an unrelated module.
TITAN_STDLIB_TEST_PROGRAM_ROOT := test.tests
TITAN_STDLIB_TEST_PROGRAM_OUTPUT := test/tests
TITAN_STDLIB_TEST_ROOTS := $(TITAN_STDLIB_TEST_PROGRAM_ROOT) \
	coroutine.tests iteration.tests gc.tests lua.tests math.tests peg.tests \
	string.core_test string.format_pack_test string.regex_test async.tests \
	uv.task_tests io.tests fs.tests timer.tests net.tests ssl.tests http.tests \
	url.tests os.tests os.process_tests uv.runtime_tests reflect.tests sqlite3.tests json.tests
TITAN_TEST_BUILD_DIR ?= .titan-tests
TITAN_TEST_EXECUTABLE := $(TITAN_TEST_BUILD_DIR)/$(TITAN_STDLIB_TEST_PROGRAM_OUTPUT)
TITAN_TEST_TIMEOUT ?= 120
TEST_TITANC ?= titanc
TEST_LUA ?= lua
BUSTED ?= busted
BUSTED_FILTER ?=
TITAN_FILTER ?=
TITAN_TEST_CPPFLAGS = $(if $(strip $(TITAN_EXTRA_CPPFLAGS)),$(TITAN_EXTRA_CPPFLAGS),$(TITAN_TEST_EXTRA_CPPFLAGS))
TITAN_TEST_CFLAGS = $(if $(strip $(TITAN_EXTRA_CFLAGS)),$(TITAN_EXTRA_CFLAGS),$(TITAN_TEST_EXTRA_CFLAGS))
TITAN_TEST_LDFLAGS = $(if $(strip $(TITAN_EXTRA_LDFLAGS)),$(TITAN_EXTRA_LDFLAGS),$(TITAN_TEST_EXTRA_LDFLAGS))
STDLIB_BUSTED_TESTS := \
	spec/asan_generated_c_context_spec.lua spec/dense_array_runtime_spec.lua \
	spec/libuv_build_spec.lua spec/lpeglabel_build_spec.lua \
	spec/minicoro_spec.lua spec/readline_build_spec.lua \
	spec/rockspec_spec.lua spec/stdlib_installer_spec.lua

.PHONY: busted-test stdlib-busted-test stdlib-test \
	titan-stdlib-test-build titan-stdlib-test-run titan-stdlib-test

busted-test: ## Run retained Busted specs, optionally with BUSTED_FILTER
	BUSTED=$(call make_shell_quote_value,BUSTED) \
		BUSTED_FILTER=$(call make_shell_quote_value,BUSTED_FILTER) \
		TITAN_ROCK_TEST_STDLIB_SPECS=$(call make_shell_quote_value,STDLIB_BUSTED_TESTS) \
		TITAN_ROCK_TEST_INTERNAL=1 \
		bash spec/support/run_rock_tests.sh $(EXTRA_TEST_FLAGS)

stdlib-busted-test: ## Run retained stdlib/runtime Busted specs without coverage
	BUSTED=$(call make_shell_quote_value,BUSTED) \
		BUSTED_FILTER=$(call make_shell_quote_value,BUSTED_FILTER) \
		TITAN_ROCK_TEST_INTERNAL=1 \
		bash spec/support/run_rock_tests.sh \
		$(STDLIB_BUSTED_TESTS) $(EXTRA_TEST_FLAGS)

titan-stdlib-test-build: $(SQLITE3_HEADER) ## Build every native Titan stdlib test into one executable
	@bash spec/support/clean_generated_test_artifacts.sh
	@mkdir -p $(call make_shell_quote,$(TITAN_TEST_BUILD_DIR))
	@set +e; \
	fixture_lua_include="$$( $(TEST_LUA) -E -e \
	  'io.write(assert(require("titan-compiler.driver").LUA_SOURCE_PATH))' )" || exit $$?; \
	test -n "$$fixture_lua_include" && test -f "$$fixture_lua_include/lua.h" || { \
	  echo "ERROR: native test fixture cannot locate matching Lua headers" >&2; exit 1; \
	}; \
	fixture_lua_include="$$(CDPATH= cd "$$fixture_lua_include" && pwd -P)" || exit $$?; \
	( cd $(call make_shell_quote,$(TITAN_TEST_BUILD_DIR)); \
	  cp $(call make_shell_quote,$(abspath spec/fixtures/stdlib/native/async_foreign_work.h)) \
	    async_foreign_work.h && \
	  $(CC) -std=c99 -Wall -Wextra -Werror -fPIC \
	    $(TITAN_TEST_CPPFLAGS) $(TITAN_TEST_CFLAGS) \
	    -I$(call make_shell_quote,$(abspath spec/fixtures/stdlib/native)) \
	    -c $(call make_shell_quote,$(abspath spec/fixtures/stdlib/native/async_foreign_work.c)) \
	    -o async_foreign_work.o && \
	  cp $(call make_shell_quote,$(abspath spec/fixtures/stdlib/native/uv_stdio_probe.h)) \
	    uv_stdio_probe.h && \
	  $(CC) -std=c99 -Wall -Wextra -Werror -fPIC \
	    $(TITAN_TEST_CPPFLAGS) $(TITAN_TEST_CFLAGS) \
	    -I$(call make_shell_quote,$(abspath spec/fixtures/stdlib/native)) \
	    -c $(call make_shell_quote,$(abspath spec/fixtures/stdlib/native/uv_stdio_probe.c)) \
	    -o uv_stdio_probe.o && \
	  cp $(call make_shell_quote,$(abspath spec/fixtures/stdlib/native/sqlite3_worker_fixture.h)) \
	    sqlite3_worker_fixture.h && \
	  $(CC) -std=c99 -Wall -Wextra -Werror -fPIC -pthread \
	    $(TITAN_TEST_CPPFLAGS) $(TITAN_TEST_CFLAGS) $(SQLITE3_CPPFLAGS) \
	    -I"$$fixture_lua_include" \
	    -I$(call make_shell_quote,$(abspath spec/fixtures/stdlib/native)) \
	    -c $(call make_shell_quote,$(abspath spec/fixtures/stdlib/native/sqlite3_worker_fixture.c)) \
	    -o sqlite3_worker_fixture.o && \
	  $(CC) -std=c99 -Wall -Wextra -Werror \
	    $(TITAN_TEST_CPPFLAGS) $(TITAN_TEST_CFLAGS) \
	    $(call make_shell_quote,$(abspath spec/fixtures/stdlib/native/os_process_host_child.c)) \
	    $(TITAN_TEST_LDFLAGS) -o os_process_host_child && \
	  TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(strip $(TITAN_TEST_CPPFLAGS) -I.)) \
	  TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(strip $(TITAN_TEST_CFLAGS))) \
	  TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(strip $(TITAN_TEST_LDFLAGS))) \
	    $(TEST_TITANC) --test --no-uv-bootstrap --tree \
	      $(call make_shell_quote,$(abspath spec/stdlib/titan)) \
	      $(TITAN_STDLIB_TEST_ROOTS) \
	      -X async_foreign_work.o uv_stdio_probe.o ); \
	status=$$?; \
	bash spec/support/clean_generated_test_artifacts.sh --keep-output; \
	if test $$status -ne 0; then rm -rf -- $(call make_shell_quote,$(TITAN_TEST_BUILD_DIR)); fi; \
	exit $$status

titan-stdlib-test-run: ## Run the built native suite, optionally with TITAN_FILTER
	@test -x $(call make_shell_quote,$(TITAN_TEST_EXECUTABLE)) || { \
	  echo "ERROR: run 'make titan-stdlib-test-build' first" >&2; exit 1; \
	}
	@TITAN_FILTER=$(call make_shell_quote_value,TITAN_FILTER) \
	bash -o pipefail -c ' \
	  if [[ -n $${TITAN_FILTER:-} ]]; then \
	    set -- "$$@" "--filter=$$TITAN_FILTER"; \
	  fi; \
	  bash spec/support/run_with_timeout.sh "$$@" 2>&1 | cat' -- \
	  $(call make_shell_quote,$(TITAN_TEST_TIMEOUT)) \
	  $(call make_shell_quote,$(TITAN_TEST_EXECUTABLE))

titan-stdlib-test: titan-stdlib-test-build ## Build and run all native Titan stdlib tests
	$(MAKE) titan-stdlib-test-run

stdlib-test: stdlib-busted-test ## Run all stdlib/runtime tests without coverage
	$(MAKE) titan-stdlib-test

rock-test: busted-test ## Run retained Busted specs, then native Titan stdlib tests
	$(MAKE) titan-stdlib-test

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

clean: ## Remove generated build/test artifacts (keeps the Lua tree)
	bash spec/support/clean_generated_test_artifacts.sh
	rm -f $(RUNTIME_O) titan-runtime/*.o $(TITAN_RUNTIME_LIB)
	rm -f $(LPEGLABEL_OBJECTS) $(LPEGLABEL_ARCHIVE) \
		$(LPEGLABEL_BUILD_CONFIG) $(LPEGLABEL_ARCHIVE_CONFIG)
	rmdir "$(LPEGLABEL_BUILD_DIR)" 2>/dev/null || true
	rm -rf "$(LLHTTP_BUILD_DIR)"
	rm -f $(RUNTIME_BUILD_CONFIG) $(RUNTIME_ARCHIVE_CONFIG) \
		$(LTITANLIB_BUILD_CONFIG) \
		titan-runtime/.titan-titanlib-build-config \
		$(STDLIB_CONFIG_STAMP) $(STDLIB_COMPLETION_STAMP)
	rm -f $(TITAN_BOOTSTRAP_SO)
	rm -rf $(TITAN_BOOTSTRAP_SO).dSYM
	rmdir titan-runtime/bootstrap 2>/dev/null || true
	rm -f titan/*.c titan/*.o
	rm -f titan/uv/*.c titan/uv/*.o
	rm -f titan/http/http.c titan/http/http.o
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

clean-lua: ## Remove the downloaded Lua source tree(s) and tarball
	rm -rf $(LUA_DIR) lua-5.*/
	rm -f $(LUA_TARBALL) lua-5.*.tar.gz
	rm -rf .lua

clean-readline: ## Remove the bundled Readline source/build trees and release archive
	rm -rf $(READLINE_DIR) $(READLINE_BUILD_DIR)
	rm -f $(READLINE_TARBALL) $(READLINE_PATCHES)

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

distclean: clean clean-lua clean-readline clean-luarocks clean-libbacktrace clean-libuv clean-llhttp clean-sqlite3 clean-openssl ## Remove all downloaded trees and artifacts
