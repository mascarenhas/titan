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
LUA_VERSION      ?= 5.5.0
LUA_ABI_VERSION  ?= 5.5
LUA_DIR          := lua-$(LUA_VERSION)
LUA_TARBALL      := $(LUA_DIR).tar.gz
LUA_URL          := https://www.lua.org/ftp/$(LUA_TARBALL)
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

HOST_OS   := $(shell uname -s)
HOST_ARCH := $(shell uname -m)

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

# The Lua build target ("linux", "macosx", ...) is taken from `uname` but can be
# overridden on the command line: `make lua LUA_PLATFORM=bsd`.
ifndef LUA_PLATFORM
  ifeq ($(HOST_OS),Darwin)
    LUA_PLATFORM := macosx
  else
    LUA_PLATFORM := linux
  endif
endif

# Kept in sync with titan-compiler/driver.lua (driver.CC / driver.CFLAGS).
CC        ?= cc
AR        ?= ar
RANLIB    ?= ranlib
LUA_CC    ?= $(CC)
LUA_AR    ?= $(AR) rcu
LUA_RANLIB ?= $(RANLIB)
CFLAGS    ?= --std=c99 -O2 -Wall -fPIC -g -fno-optimize-sibling-calls
LUA_MYCFLAGS  ?= -fPIC
LUA_MYLDFLAGS ?=
LUA_MYLIBS    ?=
LIBBT_CFLAGS  ?= -fPIC -g -O2
TITAN_EXTRA_CPPFLAGS ?=
TITAN_EXTRA_CFLAGS   ?=
TITAN_EXTRA_LDFLAGS  ?=
TITAN_NO_LINE_DIRECTIVES ?=
export TITAN_EXTRA_CPPFLAGS TITAN_EXTRA_CFLAGS TITAN_EXTRA_LDFLAGS \
	TITAN_NO_LINE_DIRECTIVES
# Quote one complete environment value for the recipe shell.  This preserves
# embedded quotes in user flag strings so Titan's own argv parser sees them.
make_shell_quote = '$(subst ','"'"',$(1))'
RUNTIME_O := titan-runtime/titan.o
CORO_O    := titan-runtime/titan_coro.o
UV_O      := titan-runtime/titan_uv.o
TITANLIB_O := titan-runtime/titanlib.o
TITAN_RUNTIME_OBJECTS := $(RUNTIME_O) $(CORO_O) $(UV_O)
TITAN_RUNTIME_LIB := titan-runtime/libtitan.a
TITAN_SDK_ROOT_HEADERS := titan-runtime/minicoro.h titan-runtime/titan.h \
	titan-runtime/titan_longjmp.h
TITAN_SDK_NAMESPACED_HEADERS := titan-runtime/titan/ffi.h \
	titan-runtime/titan/coro.h titan-runtime/titan/uv.h

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
	titan/uv/tcp.titan
UV_CONFIG_STAMP := titan-runtime/.titan-uv-build-config
STDLIB_MODULES := coroutine uv async timer io fs net os peg string \
	math lua iter gc
STDLIB_SOS     := $(addsuffix .so,$(STDLIB_MODULES))
STDLIB_QUALIFIED_SOS := $(addprefix titan/,$(STDLIB_SOS))
STDLIB_ROOTS := titan.coroutine titan.uv titan.async titan.timer \
	titan.io titan.fs titan.net titan.os titan.peg titan.string \
	titan.math titan.lua titan.iter titan.gc
STDLIB_TITAN_SOURCES := titan/coroutine.titan $(UV_TITAN_SOURCES) \
	titan/async.titan titan/timer.titan titan/io.titan titan/fs.titan \
	titan/net.titan titan/os.titan \
	titan/peg/peg.titan titan/peg/combinators.titan \
	titan/peg/native.titan \
	titan/peg/relabel.titan titan/peg/relabel_parser.titan \
	titan/string/string.titan titan/string/bytes.titan \
	titan/string/format.titan titan/string/pack.titan \
	titan/string/regex_api.titan titan/string/regex_compile.titan \
	titan/string/regex_parser.titan \
	titan/math.titan titan/lua.titan titan/iter.titan titan/gc.titan
STDLIB_SHIMS := titan/coroutine.lua titan/uv.lua titan/async.lua \
	titan/timer.lua titan/io.lua titan/fs.lua titan/net.lua titan/os.lua \
	titan/peg.lua titan/string.lua titan/math.lua titan/lua.lua \
	titan/iter.lua titan/gc.lua
STDLIB_CONTAINER := titan.so
STDLIB_STATIC_ARCHIVE := titan.a
STDLIB_PROVIDER_OUTPUTS := $(STDLIB_CONTAINER) $(STDLIB_STATIC_ARCHIVE)
STDLIB_EXTRA_OBJECTS := $(TITANLIB_O) $(LPEGLABEL_ARCHIVE) \
	$(LIBUV_EXTRA_OBJECTS)
STDLIB_NATIVE_IDENTITY_PREREQS := $(LPEGLABEL_ARCHIVE)
STDLIB_LPEGLABEL_CPPFLAGS := $(LPEGLABEL_CPPFLAGS)
STDLIB_LICENSES := LICENSES/libuv-LICENSE \
	LICENSES/lpeglabel-LICENSE LICENSES/lpeg-LICENSE \
	LICENSES/ta-regex-LICENSE LICENSES/lua-LICENSE
STDLIB_EMBEDDED_FORMAT_INPUTS := titan-compiler/staticmetadata.lua \
	titan-compiler/coder.lua
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
TITAN_COMPILER_LUA := $(wildcard titan-compiler/*.lua c-parser/*.lua)

# Standard modules have one installed pathname. PREFIX owns Lua; ROCKS_TREE
# owns these Titan artifacts when it is supplied. The source-tree
# install-stdlib target can publish to PREFIX when ROCKS_TREE is omitted;
# it is not part of an installed Titan tree.
TITAN_INSTALL_TREE         := $(if $(strip $(ROCKS_TREE)),$(ROCKS_TREE),$(PREFIX))
STDLIB_INSTALL_STAGE       ?= $(CURDIR)
TITAN_ABI_VERSION          := 0.20
TITAN_STDLIB_ABI_DIR       ?= $(TITAN_INSTALL_TREE)/lib/titan/$(TITAN_ABI_VERSION)
TITAN_CANONICAL_SUPPORT_SO ?= $(TITAN_STDLIB_ABI_DIR)/titan.so
TITAN_CANONICAL_STATIC_ARCHIVE ?= $(TITAN_STDLIB_ABI_DIR)/titan.a
TITAN_STDLIB_DIR           ?= $(TITAN_INSTALL_TREE)/lib/titan/$(TITAN_ABI_VERSION)/titan
TITAN_STDLIB_LUA_DIR       ?= $(TITAN_INSTALL_TREE)/share/lua/$(LUA_ABI_VERSION)/titan
LUA_LIBDIR                 ?= $(TITAN_INSTALL_TREE)/lib/lua/$(LUA_ABI_VERSION)
TITAN_STDLIB_LEGACY_DIR    ?= $(LUA_LIBDIR)/titan/stdlib_$(subst .,_,$(TITAN_ABI_VERSION))
TITAN_SHARE_DIR            ?= $(TITAN_INSTALL_TREE)/share/titan

# libbacktrace is cloned + built into ./libbacktrace (gitignored), mirroring the
# ./lua-5.5.0 tree. The generated C and the runtime include its backtrace.h and
# link its static archive (driver.lua references ./libbacktrace/.libs/...).
LIBBT_DIR := libbacktrace
LIBBT_URL := https://github.com/ianlancetaylor/libbacktrace.git
LIBBT_LIB := $(LIBBT_DIR)/.libs/libbacktrace.a
LIBBT_CLONE_STAMP := $(LIBBT_DIR)/.titan-cloned
LIBBT_BUILD_CONFIG := $(LIBBT_DIR)/.titan-build-config
RUNTIME_BUILD_CONFIG := titan-runtime/.titan-runtime-build-config
RUNTIME_ARCHIVE_CONFIG := titan-runtime/.titan-runtime-archive-build-config
TITANLIB_BUILD_CONFIG := titan-runtime/.titan-titanlib-build-config
STDLIB_CONFIG_STAMP := titan-runtime/.titan-stdlib-build-config
STDLIB_COMPLETION_STAMP := titan-runtime/.titan-stdlib-complete

.PHONY: all help lua luarocks libbacktrace libuv libuv-config lpeglabel \
	check-libuv-tools check-system-libuv invalid-libuv-mode runtime titan \
	stage-titan-bootstrap install-titan-sdk stdlib install-stdlib \
	publish-stdlib \
	rock-post-install test rock-build \
	examples clean clean-lua clean-luarocks clean-libbacktrace clean-libuv \
	distclean FORCE

FORCE:

all: lua libbacktrace libuv stdlib ## Build everything needed to run the test suite (default)

help: ## Show this help
	@echo "Titan developer tasks:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "make all and make stdlib use bundled libuv $(LIBUV_VERSION) by default."
	@echo "Use 'make libuv' for only that dependency, or LIBUV_MODE=system"
	@echo "to use pkg-config with libuv >= $(LIBUV_MIN_VERSION)."
	@echo "Bundled prerequisites: a C compiler, CMake, tar, curl/wget, and"
	@echo "sha256sum/shasum (macOS: xcode-select --install; brew install cmake)."
	@echo "System mode packages: Ubuntu/Debian libuv1-dev pkg-config; Fedora"
	@echo "libuv-devel pkgconf-pkg-config; macOS brew install libuv pkgconf."
	@echo "For a standalone installation, choose one writable PREFIX and run:"
	@echo "  make lua PREFIX=/path && make luarocks PREFIX=/path && make libuv"
	@echo "  PATH=/path/bin:\$$PATH /path/bin/luarocks make"

libuv: ## Build/validate libuv (bundled by default; LIBUV_MODE=system is optional)

lua: $(LUA_INSTALL_STAMP) ## Build and install Titan's prefix-configured Lua

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
$(LUA_BUILD_CONFIG): $(LUA_EXTRACTED) FORCE
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
		$(call make_shell_quote,TITAN_ABI_VERSION=$(TITAN_ABI_VERSION)); } \
		> "$$tmp"; \
	awk -v root=$(call make_shell_quote,$(PREFIX)) \
	    -v titan_abi=$(call make_shell_quote,$(TITAN_ABI_VERSION)) \
	  '$$1 == "#define" && $$2 == "LUA_TITAN_CDIR" { next } \
	   { if ($$1 == "#define" && index($$2, "LUA_ROOT") == 1) { \
	       printf("#define LUA_ROOT %c%s/%c\n", 34, root, 34); next; \
	     } \
	     if ($$1 == "#define" && $$2 == "LUA_CDIR" && \
	         index($$0, "LUA_ROOT") != 0) { \
	       print; \
	       printf("#define LUA_TITAN_CDIR%cLUA_ROOT %clib/titan/%s/%c\n", \
	              9, 34, titan_abi, 34); \
	       next; \
	     } \
	     line = $$0; \
	     gsub(/LUA_TITAN_CDIR"[?][.]so;"[ \t]*/, "", line); \
	     if (line ~ /LUA_CDIR"[?][.]so;"/) { \
	       sub(/LUA_CDIR"[?][.]so;"/, \
	           "LUA_TITAN_CDIR\"?.so;\" LUA_CDIR\"?.so;\"", line); \
	     } \
	     print line; }' "$$header" > "$$tmp_header"; \
	grep -q '^#define LUA_ROOT' "$$tmp_header"; \
	grep -q '^#define LUA_TITAN_CDIR' "$$tmp_header"; \
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
	@echo "==> Building Lua ($(LUA_PLATFORM), MYCFLAGS=$(LUA_MYCFLAGS))"
	$(MAKE) -C "$(LUA_DIR)" $(LUA_PLATFORM) \
		CC=$(call make_shell_quote,$(LUA_CC)) \
		AR=$(call make_shell_quote,$(LUA_AR)) \
		RANLIB=$(call make_shell_quote,$(LUA_RANLIB)) \
		MYCFLAGS=$(call make_shell_quote,$(LUA_MYCFLAGS)) \
		MYLDFLAGS=$(call make_shell_quote,$(LUA_MYLDFLAGS)) \
		MYLIBS=$(call make_shell_quote,$(LUA_MYLIBS))

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
	cmake --build "$(LIBUV_BUILD_DIR)" --target uv_a
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
# deterministic qD/-D only when both tools support that pair; otherwise verify
# the portable q/ordinary-ranlib pair. The selected mode is a stamped input to
# archive construction.
$(LPEGLABEL_ARCHIVE_CONFIG): FORCE $(firstword $(LPEGLABEL_OBJECTS))
	@mkdir -p "$(@D)"
	@set -e; \
	probe="$(@D)/.titan-lpeglabel-tool-probe.a"; \
	tmp="$@.tmp"; \
	rm -f "$$probe" "$$tmp"; \
	if $(AR) qD "$$probe" "$(firstword $(LPEGLABEL_OBJECTS))" \
			>/dev/null 2>&1 && \
	   $(RANLIB) -D "$$probe" >/dev/null 2>&1; then \
	  ar_mode=qD; ranlib_mode=-D; deterministic=yes; \
	else \
	  rm -f "$$probe"; \
	  if ! $(AR) q "$$probe" "$(firstword $(LPEGLABEL_OBJECTS))" \
			>/dev/null 2>&1; then \
	    echo "ERROR: configured AR supports neither qD nor q" >&2; \
	    exit 1; \
	  fi; \
	  if ! $(RANLIB) "$$probe" >/dev/null 2>&1; then \
	    echo "ERROR: configured RANLIB supports neither -D nor ordinary mode" >&2; \
	    exit 1; \
	  fi; \
	  ar_mode=q; ranlib_mode=ordinary; deterministic=no; \
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

runtime: libuv $(TITAN_RUNTIME_LIB) ## Build the Titan C runtime archive used by every compiler mode

# titan.o and titan_coro.o share one compile configuration.  As with the libuv
# stamp below, recompute its contents without changing mtime on a warm build so
# switching compilers, include roots, or sanitizer flags cannot reuse stale
# native objects or the archive made from them.
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

# titanlib.o has a distinct public-Lua compile and shared-module link surface.
# Keep link inputs in the same stamp: a changed sanitizer LDFLAG must relink
# titan.so even when its small C source and compile flags are otherwise stable.
$(TITANLIB_BUILD_CONFIG): FORCE
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

# Make does not otherwise notice command-line variable changes.  Recompute a
# small stamp on every invocation, but update its mtime only when an effective
# uv compile/link input changes. Switching bundled/system mode, compiler, or
# flags rebuilds titan_uv.o and consequently relinks the combined
# titan.so/titan.a provider pair without asking the user to clean first.
$(UV_CONFIG_STAMP): FORCE
	@mkdir -p "$(@D)"
	@tmp="$@.tmp"; \
	{ printf '%s\n' \
		$(call make_shell_quote,HOST_OS=$(HOST_OS)) \
		$(call make_shell_quote,HOST_ARCH=$(HOST_ARCH)) \
		$(call make_shell_quote,CC=$(CC)) \
		$(call make_shell_quote,CFLAGS=$(CFLAGS)) \
		$(call make_shell_quote,TITAN_EXTRA_CPPFLAGS=$(TITAN_EXTRA_CPPFLAGS)) \
		$(call make_shell_quote,TITAN_EXTRA_CFLAGS=$(TITAN_EXTRA_CFLAGS)) \
		$(call make_shell_quote,TITAN_EXTRA_LDFLAGS=$(TITAN_EXTRA_LDFLAGS)) \
		$(call make_shell_quote,LIBUV_MODE=$(LIBUV_MODE)) \
		$(call make_shell_quote,LIBUV_VERSION=$(LIBUV_VERSION)) \
		$(call make_shell_quote,LIBUV_CPPFLAGS=$(LIBUV_CPPFLAGS)) \
		$(call make_shell_quote,LIBUV_CFLAGS=$(LIBUV_CFLAGS)) \
		$(call make_shell_quote,LIBUV_EXTRA_OBJECTS=$(LIBUV_EXTRA_OBJECTS)) \
		$(call make_shell_quote,LIBUV_LDFLAGS=$(LIBUV_LDFLAGS)) \
		$(call make_shell_quote,LIBUV_PROVIDER_LDFLAGS=$(LIBUV_PROVIDER_LDFLAGS)); } > "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then \
		rm -f "$$tmp"; \
	else \
		mv -f "$$tmp" "$@"; \
	fi

$(RUNTIME_O): titan-runtime/titan.c titan-runtime/titan.h \
		titan-runtime/titan_longjmp.h \
		$(RUNTIME_BUILD_CONFIG) | $(TITAN_RUNTIME_LUA_LIB) $(LIBBT_LIB)
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(CFLAGS) $(TITAN_EXTRA_CFLAGS) \
		-c titan-runtime/titan.c -I titan-runtime -I $(TITAN_RUNTIME_LUA_SOURCE_PATH) \
		-I $(LIBBT_DIR) -o $@

$(CORO_O): titan-runtime/titan_coro.c titan-runtime/titan/coro.h \
		titan-runtime/minicoro.h titan-runtime/titan/ffi.h \
		$(RUNTIME_BUILD_CONFIG) | $(TITAN_RUNTIME_LUA_LIB) $(LIBBT_LIB)
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(CFLAGS) $(TITAN_EXTRA_CFLAGS) \
		-c titan-runtime/titan_coro.c -I titan-runtime -I $(TITAN_RUNTIME_LUA_SOURCE_PATH) \
		-I $(LIBBT_DIR) -o $@

$(UV_O): titan-runtime/titan_uv.c titan-runtime/titan/uv.h \
		titan-runtime/titan.h titan-runtime/titan_longjmp.h \
		$(UV_CONFIG_STAMP) $(RUNTIME_BUILD_CONFIG) | \
		$(TITAN_RUNTIME_LUA_LIB) $(LIBBT_LIB) libuv
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(LIBUV_CPPFLAGS) $(CFLAGS) \
		$(TITAN_EXTRA_CFLAGS) $(LIBUV_CFLAGS) -c titan-runtime/titan_uv.c \
		-I titan-runtime -I $(TITAN_RUNTIME_LUA_SOURCE_PATH) \
		-I $(LIBBT_DIR) -o $@

# Record the archive tools and exact member contract on every Make invocation,
# while preserving this stamp's mtime on a warm build. Archive membership is
# validated by the archive target itself below, independently of filesystem
# timestamp granularity.
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

$(TITAN_RUNTIME_LIB):: $(TITAN_RUNTIME_OBJECTS) $(RUNTIME_ARCHIVE_CONFIG)
	rm -f "$@"
	$(AR) rcs "$@" $(TITAN_RUNTIME_OBJECTS)
	$(RANLIB) "$@"

# A second, forced rule makes exact membership a content invariant instead of
# relying on a refreshed prerequisite being observably newer than the archive.
# GNU Make runs double-colon recipes for one target serially, so this remains
# safe under `make -j` and becomes a no-op for a valid warm archive.
$(TITAN_RUNTIME_LIB):: FORCE
	@set -e; \
	expected="$$(printf '%s\n' $(notdir $(TITAN_RUNTIME_OBJECTS)))"; \
	actual=""; \
	if test -r "$@"; then \
		actual="$$( $(AR) t "$@" 2>/dev/null | \
			awk '$$0 !~ /^__[.]SYMDEF(_64)?( SORTED)?$$/' )"; \
	fi; \
	if test "$$actual" != "$$expected"; then \
		rm -f "$@"; \
		$(AR) rcs "$@" $(TITAN_RUNTIME_OBJECTS); \
		$(RANLIB) "$@"; \
	fi

$(TITANLIB_O): titan-runtime/titanlib.c $(TITANLIB_BUILD_CONFIG)
	$(CC) $(ROCK_CFLAGS) $(TITAN_EXTRA_CFLAGS) \
		-I"$(ROCK_LUA_INCDIR)" -c "$<" -o "$@"

$(TITAN_BOOTSTRAP_SO): $(TITANLIB_O)
	@mkdir -p "$(@D)"
	@set -e; tmp="$@.tmp"; rm -f "$$tmp"; \
	if $(ROCK_LD) $(ROCK_LIBFLAG) -o "$$tmp" "$<" \
		$(TITAN_EXTRA_LDFLAGS); then \
		mv -f "$$tmp" "$@"; \
	else \
		status=$$?; rm -f "$$tmp"; exit $$status; \
	fi

# The active ABI path initially needs only Titan's bare Lua support entry. A
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
	    echo "ERROR: existing Titan $(TITAN_ABI_VERSION) image is not a usable support provider: $$canonical" >&2; \
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
titan: libbacktrace libuv $(TITAN_RUNTIME_LIB) $(TITAN_BOOTSTRAP_SO) ## Build Titan's native runtime and Lua bootstrap
	@if test -n "$(strip $(ROCKS_TREE))"; then \
	  $(MAKE) --no-print-directory install-titan-sdk \
		ROCKS_TREE=$(call make_shell_quote,$(ROCKS_TREE)) \
		LIBUV_MODE=$(call make_shell_quote,$(LIBUV_MODE)); \
	fi

install-titan-sdk: $(TITAN_RUNTIME_LIB) $(TITAN_BOOTSTRAP_SO) $(LUA_LIB) \
		$(LIBBT_LIB) $(LIBUV_LIB) $(TITAN_SDK_ROOT_HEADERS) \
		$(TITAN_SDK_NAMESPACED_HEADERS) stage-titan-bootstrap
	@test -n "$(strip $(ROCKS_TREE))" || { \
	  echo "ERROR: install-titan-sdk requires ROCKS_TREE" >&2; exit 1; \
	}
	@set -e; \
	mkdir -p "$(ROCKS_TREE)"; \
	rocks_tree=$$(CDPATH= cd "$(ROCKS_TREE)" && pwd -P); \
	echo "==> Installing Titan SDK into $$rocks_tree"; \
	mkdir -p "$$rocks_tree/src/$(LUA_DIR)" \
		"$$rocks_tree/include/titan" "$$rocks_tree/lib"; \
	install -m 0644 $(LUA_DIR)/src/*.c $(LUA_DIR)/src/*.h \
		"$$rocks_tree/src/$(LUA_DIR)/"; \
	install -m 0644 "$(LUA_LIB)" "$$rocks_tree/lib/liblua.a"; \
	install -m 0644 "$(TITAN_RUNTIME_LIB)" \
		"$$rocks_tree/lib/libtitan.a"; \
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
	rm -f "$$rocks_tree/lib/libuv.a"

# The real bundled libuv archive is private input to the paired titan.so/titan.a
# provider. The install recipe above removes copies left by older SDKs so
# extensions cannot create a second native instance. The post-install build
# consumes the installed Titan runtime archive rather than smuggling source-tree
# runtime objects into standard modules. System libuv remains an ordered final
# link input; bundled mode gets headers from the staged SDK and gives the private
# archive to titanc through the same -X payload as titanlib.o and the private
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
  STDLIB_PLATFORM_PREREQS := libuv
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
		$(call make_shell_quote,STDLIB_UV_LDFLAGS=$(STDLIB_UV_LDFLAGS)); \
	  for input in $(LPEGLABEL_SOURCES) $(LPEGLABEL_HEADERS) \
			$(LPEGLABEL_BUILD_CONFIG) \
			$(LPEGLABEL_ARCHIVE_CONFIG) $(LPEGLABEL_ARCHIVE); do \
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
# one public output is absent. All fourteen roots are explicit source roots in one
# process, so their internal imports are linked into the paired titan.so/titan.a
# provider. The warm check rescans the archive without rewriting either output.
$(STDLIB_COMPLETION_STAMP): FORCE $(STDLIB_TITAN_SOURCES) titanc \
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
	    TITAN_PATH_0_20=$(call make_shell_quote,$(CURDIR)) TITAN_PATH= \
	    TITAN_ROCKS_ROOT=$(call make_shell_quote,$(TITAN_ROCKS_ROOT)) \
	    TITAN_RUNTIME_PREBUILT=1 \
	    TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CPPFLAGS) $(STDLIB_LPEGLABEL_CPPFLAGS) $(STDLIB_UV_CPPFLAGS))) \
	    TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CFLAGS) $(STDLIB_UV_CFLAGS))) \
	    TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_LDFLAGS) $(STDLIB_UV_LDFLAGS))) \
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
	  export TITAN_PATH_0_20=$(call make_shell_quote,$(CURDIR)); \
	  export TITAN_PATH=; \
	  export TITAN_ROCKS_ROOT=$(call make_shell_quote,$(TITAN_ROCKS_ROOT)); \
	  export TITAN_RUNTIME_PREBUILT=1; \
	  export TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CPPFLAGS) $(STDLIB_UV_CPPFLAGS))); \
	  export TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CFLAGS) $(STDLIB_UV_CFLAGS))); \
	  export TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_LDFLAGS) $(STDLIB_UV_LDFLAGS))); \
	  "$(TITAN_LUA)" -E "$(CURDIR)/scripts/stdlib_installer.lua" \
	    "$$stage" "$$root" )

# The post-install compiler runs in a private destination-filesystem directory,
# so every -X input is absolute. System mode carries titanlib.o followed by the
# private LPegLabel archive; bundled mode appends the pinned libuv archive.
STDLIB_STAGED_EXTRA_OBJECTS = $(foreach object,$(STDLIB_EXTRA_OBJECTS),$(abspath $(object)))

# LuaRocks invokes this only after deploying titanc and its Lua compiler
# modules. Build all fourteen source roots once in a private directory on the
# destination filesystem. The Lua publisher validates the complete protocol,
# commits fourteen shims, the archive, and the one macOS dSYM before renaming
# titan.so last; any caught failure restores the prior pair, the legacy
# DSO-only installation, or the first-install bootstrap.
rock-post-install: scripts/stdlib_installer.lua $(STDLIB_EXTRA_OBJECTS)
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
	mkdir -p "$(ROCKS_TREE)/lib/titan/$(TITAN_ABI_VERSION)"; \
	rocks_tree=$$(CDPATH= cd "$(ROCKS_TREE)" && pwd -P); \
	abi_dir="$$rocks_tree/lib/titan/$(TITAN_ABI_VERSION)"; \
	share_dir="$$rocks_tree/share/titan"; \
	mkdir -p "$$share_dir/LICENSES"; \
	install -m 0644 THIRD_PARTY_NOTICES.md \
	  "$$share_dir/THIRD_PARTY_NOTICES.md"; \
	install -m 0644 $(STDLIB_LICENSES) "$$share_dir/LICENSES/"; \
	stage=$$(mktemp -d "$$abi_dir/.titan-stdlib-stage.XXXXXX"); \
	trap 'rm -rf "$$stage"' EXIT HUP INT TERM; \
	echo "==> Building paired Titan stdlib providers with $(ROCK_TITANC)"; \
	( cd "$$stage"; \
	  unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5; \
	  export TITAN_ROCKS_ROOT="$$rocks_tree"; \
	  export TITAN_PATH_0_20="$$abi_dir"; \
	  export TITAN_PATH=; \
	  export TITAN_RUNTIME_PREBUILT=1; \
	  export CC=$(call make_shell_quote,$(CC)); \
	  export AR=$(call make_shell_quote,$(AR)); \
	  export RANLIB=$(call make_shell_quote,$(RANLIB)); \
	  export TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CPPFLAGS) $(STDLIB_LPEGLABEL_CPPFLAGS) $(STDLIB_UV_CPPFLAGS))); \
	  export TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CFLAGS) $(STDLIB_UV_CFLAGS))); \
	  export TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_LDFLAGS) $(STDLIB_UV_LDFLAGS))); \
	  $(call make_shell_quote,$(ROCK_TITANC)) --tree \
	    $(call make_shell_quote,$(CURDIR)) $(STDLIB_ROOTS) \
	    -X $(STDLIB_STAGED_EXTRA_OBJECTS); \
	  "$(ROCK_LUA)" -E "$(CURDIR)/scripts/stdlib_installer.lua" \
	    "$$stage" "$$rocks_tree" ); \
	trap - EXIT HUP INT TERM; \
	rm -rf "$$stage"

# Compatibility name for callers of the former rockspec build target.  It no
# longer builds stdlib before LuaRocks has deployed the compiler.
rock-build: titan

test: luarocks libbacktrace libuv ## Build/install the rock and run the suite via `luarocks test`
	unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5; \
	  PREFIX="$(PREFIX)" PATH="$(PREFIX)/bin:$$PATH" \
	  "$(PREFIX)/bin/luarocks" make --force
	unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5; \
	  PREFIX="$(PREFIX)" PATH="$(PREFIX)/bin:$$PATH" \
	  "$(PREFIX)/bin/luarocks" test

examples: lua ## Compile the example Titan modules (SDL examples need SDL2 headers)
	$(MAKE) -C examples all

clean: ## Remove generated build/test artifacts (keeps the Lua tree)
	rm -f $(RUNTIME_O) titan-runtime/*.o $(TITAN_RUNTIME_LIB)
	rm -f $(LPEGLABEL_OBJECTS) $(LPEGLABEL_ARCHIVE) \
		$(LPEGLABEL_BUILD_CONFIG) $(LPEGLABEL_ARCHIVE_CONFIG)
	rmdir "$(LPEGLABEL_BUILD_DIR)" 2>/dev/null || true
	rm -f $(RUNTIME_BUILD_CONFIG) $(RUNTIME_ARCHIVE_CONFIG) \
		$(TITANLIB_BUILD_CONFIG) $(UV_CONFIG_STAMP) \
		$(STDLIB_CONFIG_STAMP) $(STDLIB_COMPLETION_STAMP)
	rm -f $(TITAN_BOOTSTRAP_SO)
	rm -rf $(TITAN_BOOTSTRAP_SO).dSYM
	rmdir titan-runtime/bootstrap 2>/dev/null || true
	rm -f titan/*.c titan/*.o
	rm -f titan/uv/*.c titan/uv/*.o
	rm -f titan/peg/peg.c titan/peg/peg.o
	rm -f titan/string/string.c titan/string/string.o
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

clean-luarocks: ## Remove the downloaded LuaRocks source tree and tarball
	rm -rf $(LUAROCKS_DIR)
	rm -f $(LUAROCKS_TARBALL)

clean-libbacktrace: ## Remove the cloned libbacktrace source tree
	rm -rf $(LIBBT_DIR)

clean-libuv: ## Remove the bundled libuv source, build tree, and release tarball
	rm -rf $(LIBUV_SRC_DIR) $(LIBUV_BUILD_DIR)
	rm -f $(LIBUV_TARBALL)

distclean: clean clean-lua clean-luarocks clean-libbacktrace clean-libuv ## Remove all downloaded trees and artifacts
