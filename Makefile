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
LUA_EXTRACTED    := $(LUA_DIR)/.titan-extracted
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

# These are the complete inputs consumed by the later standard-module rules.
# In bundled mode libuv's archive is a private input used to construct the one
# canonical titan/uv.so provider; in system mode pkg-config's ordered linker output
# must stay intact.
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
    LIBUV_LINK_LIBS := pthread dl rt
  else
    LIBUV_LINK_LIBS :=
  endif
  LIBUV_LDFLAGS := $(addprefix -l,$(LIBUV_LINK_LIBS))
  ifeq ($(HOST_OS),Darwin)
    LIBUV_PROVIDER_LDFLAGS := -Wl,-force_load,$(LIBUV_LIB) $(LIBUV_LDFLAGS)
  else
    LIBUV_PROVIDER_LDFLAGS := -Wl,--whole-archive $(LIBUV_LIB) \
	-Wl,--no-whole-archive $(LIBUV_LDFLAGS)
  endif
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
export TITAN_EXTRA_CPPFLAGS TITAN_EXTRA_CFLAGS TITAN_EXTRA_LDFLAGS
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
COROUTINE_SO := coroutine.so
UV_SO        := uv.so
TIMER_SO     := timer.so
FS_SO        := fs.so
NET_SO       := net.so
OS_SO        := os.so
UV_CONFIG_STAMP := titan-runtime/.titan-uv-build-config
STDLIB_MODULES := coroutine uv timer fs net os
STDLIB_SOS     := $(addsuffix .so,$(STDLIB_MODULES))
STDLIB_QUALIFIED_SOS := $(addprefix titan/,$(STDLIB_SOS))
ROCK_RUNTIME_SO := titan.so
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
STDLIB_USE_INSTALLED_RUNTIME ?= 0
TITAN_ROCKS_ROOT ?=
export TITAN_ROCKS_ROOT
TITAN_LUA ?= $(LUA_BIN)
# Run the checkout's compiler sources with PREFIX's Lua. Prepending the checkout
# keeps developer stdlib rebuilds on the edits that triggered them, while Lua's
# patched default paths still find third-party dependencies under PREFIX.
TITANC    ?= $(TITAN_LUA) -e 'package.path="./?.lua;./?/init.lua;" .. package.path' ./titanc
TITAN_COMPILER_LUA := $(wildcard titan-compiler/*.lua c-parser/*.lua) typed.lua

# Standard modules have one installed pathname. PREFIX owns Lua; ROCKS_TREE
# owns these Titan artifacts when it is supplied. Today's supported setup
# makes them the same directory, while this fallback keeps
# `make install-stdlib PREFIX=...` useful on its own.
TITAN_INSTALL_TREE         := $(if $(strip $(ROCKS_TREE)),$(ROCKS_TREE),$(PREFIX))
TITAN_ABI_VERSION          := 0.11
TITAN_STDLIB_ABI_DIR       ?= $(TITAN_INSTALL_TREE)/lib/titan/$(TITAN_ABI_VERSION)
TITAN_STDLIB_DIR           ?= $(TITAN_INSTALL_TREE)/lib/titan/$(TITAN_ABI_VERSION)/titan
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

.PHONY: all help lua luarocks libbacktrace libuv libuv-config \
	check-libuv-tools check-system-libuv invalid-libuv-mode runtime titan \
	install-titan-sdk stdlib install-stdlib rock-post-install test rock-build \
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

lua: $(LUA_INSTALL_STAMP) ## Build and install Titan's patched Lua into PREFIX

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

$(LUA_EXTRACTED):
	@if [ ! -d "$(LUA_DIR)" ]; then \
	  mkdir -p "$(LUA_DIR)"; \
	  touch "$(LUA_DIR)/.titan-needs-extract"; \
	fi
	@if test -r "$(LUA_DIR)/.titan-needs-extract"; then \
	  $(MAKE) --no-print-directory "$(LUA_TARBALL)"; \
	fi
	@if test -r "$(LUA_DIR)/.titan-needs-extract"; then \
	  echo "==> Extracting $(LUA_TARBALL)"; \
	  tar zxf "$(LUA_TARBALL)"; \
	  rm -f "$(LUA_DIR)/.titan-needs-extract"; \
	fi
	@touch "$@"

# Lua's own Makefile does not track source/header dependencies.  This content
# stamp patches luaconf.h plus loadlib.c's narrow Titan-uv visibility rule, and
# cleans Lua objects whenever either patch or any effective native-build input
# changes.  An unchanged invocation preserves the stamp mtime and leaves the
# already-built interpreter warm.
$(LUA_BUILD_CONFIG): $(LUA_EXTRACTED) FORCE
	@tmp="$@.tmp"; header="$(LUA_DIR)/src/luaconf.h"; \
	loadlib="$(LUA_DIR)/src/loadlib.c"; \
	tmp_header="$$header.titan.tmp"; \
	tmp_loadlib="$$loadlib.titan.tmp"; changed="$@.changed"; \
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
	awk '{ \
	     if ($$0 ~ /reg = lsys_load[(]L, path, [*]sym ==/ && \
	         $$0 !~ /luaopen_titan_uv/) { \
	       print "    /* titan/uv.so provides libuv to later extension images. */"; \
	       printf("    reg = lsys_load(L, path, *sym == %c*%c || strcmp(sym, %cluaopen_titan_uv%c) == 0);\n", \
	              39, 39, 34, 34); \
	       next; \
	     } \
	     print; }' "$$loadlib" > "$$tmp_loadlib"; \
	grep -q '^#define LUA_ROOT' "$$tmp_header"; \
	grep -q '^#define LUA_TITAN_CDIR' "$$tmp_header"; \
	grep -q 'strcmp(sym, "luaopen_titan_uv") == 0' "$$tmp_loadlib"; \
	if test -r "$@" && cmp -s "$$tmp" "$@" && \
	   cmp -s "$$tmp_header" "$$header" && \
	   cmp -s "$$tmp_loadlib" "$$loadlib"; then \
	  rm -f "$$tmp" "$$tmp_header" "$$tmp_loadlib"; \
	else \
	  echo "==> Configuring Lua for Titan paths and uv visibility"; \
	  mv -f "$$tmp_header" "$$header"; \
	  mv -f "$$tmp_loadlib" "$$loadlib"; \
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
# uv compile/link input changes.  Switching bundled/system mode, compiler, or
# flags then rebuilds titan_uv.o and consequently relinks titan/uv.so without asking
# the user to clean first.
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

$(ROCK_RUNTIME_SO): $(TITANLIB_O)
	$(ROCK_LD) $(ROCK_LIBFLAG) -o "$@" "$<" $(TITAN_EXTRA_LDFLAGS)

# LuaRocks passes ROCKS_TREE only for its source build. A direct `make titan`
# therefore stops after producing the runtime archive and Lua module, while the
# rock build also stages the SDK inputs needed by the just-installed compiler.
# No Titan stdlib module is built before LuaRocks deploys titanc.
titan: libbacktrace libuv $(TITAN_RUNTIME_LIB) $(ROCK_RUNTIME_SO) ## Build Titan's native runtime and Lua module
	@if test -n "$(strip $(ROCKS_TREE))"; then \
	  $(MAKE) --no-print-directory install-titan-sdk \
		ROCKS_TREE=$(call make_shell_quote,$(ROCKS_TREE)) \
		LIBUV_MODE=$(call make_shell_quote,$(LIBUV_MODE)); \
	fi

install-titan-sdk: $(TITAN_RUNTIME_LIB) $(ROCK_RUNTIME_SO) $(LUA_LIB) \
		$(LIBBT_LIB) $(LIBUV_LIB) $(TITAN_SDK_ROOT_HEADERS) \
		$(TITAN_SDK_NAMESPACED_HEADERS)
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

# The real bundled libuv archive is private to uv.so. The install recipe above
# removes copies left by older SDKs so extensions cannot create a second native
# instance. The post-install build consumes the installed Titan runtime archive
# rather than smuggling source-tree runtime objects into standard modules. System
# libuv still needs pkg-config's flags; bundled mode gets headers from the
# staged SDK but consumes the source build's private archive only while linking
# the canonical titan/uv.so provider.
ifeq ($(STDLIB_USE_INSTALLED_RUNTIME),1)
  STDLIB_PLATFORM_PREREQS :=
  STDLIB_COMMON_RUNTIME_PREREQS :=
  STDLIB_CORO_RUNTIME_PREREQS :=
  STDLIB_UV_RUNTIME_PREREQS :=
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
  # Each image is stale only when an archive member it can actually extract is
  # stale. Keep the unified archive order-only so it is assembled and validated
  # before every link without making a libuv-only member update relink coroutine
  # or the facades.
  STDLIB_COMMON_RUNTIME_PREREQS := $(RUNTIME_O)
  STDLIB_CORO_RUNTIME_PREREQS := $(RUNTIME_O) $(CORO_O)
  STDLIB_UV_RUNTIME_PREREQS := $(RUNTIME_O) $(UV_O) $(LIBUV_EXTRA_OBJECTS)
  STDLIB_RUNTIME_ARCHIVE_PREREQ := $(TITAN_RUNTIME_LIB)
  # A standalone PREFIX is prepared with `make lua` before stdlib. Depending
  # on its prefix-local stamp keeps native source builds ordered without
  # rerunning Lua's installation for every module (or during Make dry runs).
  STDLIB_TOOL_PREREQS := $(LUA_INSTALL_STAMP) $(LIBBT_LIB)
  STDLIB_UV_CPPFLAGS := $(LIBUV_CPPFLAGS)
  STDLIB_UV_CFLAGS := $(LIBUV_CFLAGS)
  # Put bundled libuv in the final-link flags, after libtitan.a has extracted
  # titan_uv.o. Whole-archive/force-load makes uv.so a complete provider even
  # for public APIs the standard module itself does not call.
  STDLIB_UV_LDFLAGS := $(strip $(LIBUV_PROVIDER_LDFLAGS))
endif

stdlib: $(STDLIB_PLATFORM_PREREQS) $(STDLIB_QUALIFIED_SOS) ## Build standard modules and their bundled dependencies
	rm -f $(STDLIB_SOS) coro.so
	rm -rf $(addsuffix .dSYM,$(STDLIB_SOS)) coro.so.dSYM

# Standard-library sources use their ordinary qualified module names. Explicit
# titanc roots are built from source; their imports remain binary-first and find
# the already-built qualified modules through this checkout's Titan path.
titan/$(COROUTINE_SO): titan/coroutine.titan $(STDLIB_CORO_RUNTIME_PREREQS) titanc \
		$(TITAN_COMPILER_LUA) Makefile | $(STDLIB_RUNTIME_ARCHIVE_PREREQ) \
		$(STDLIB_TOOL_PREREQS)
	CC=$(call make_shell_quote,$(CC)) \
		TITAN_PATH_0_11=$(call make_shell_quote,$(CURDIR)) TITAN_PATH= \
		TITAN_RUNTIME_PREBUILT=1 \
		TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CPPFLAGS)) \
		TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CFLAGS)) \
		TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_LDFLAGS)) \
		$(TITANC) titan.coroutine

# uv imports the already-built canonical coroutine image. Both checkout and
# installed builds extract the uv shim from libtitan.a. Bundled mode force-loads
# one private static libuv archive into this provider image; system mode supplies
# pkg-config's ordered output only through the final-link flags.
titan/$(UV_SO): titan/uv.titan titan/$(COROUTINE_SO) $(STDLIB_UV_RUNTIME_PREREQS) titanc \
		$(TITAN_COMPILER_LUA) Makefile | $(STDLIB_TOOL_PREREQS) \
		$(STDLIB_PLATFORM_PREREQS) $(STDLIB_RUNTIME_ARCHIVE_PREREQ)
	CC=$(call make_shell_quote,$(CC)) \
		TITAN_PATH_0_11=$(call make_shell_quote,$(CURDIR)) TITAN_PATH= \
		TITAN_RUNTIME_PREBUILT=1 \
		TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CPPFLAGS) $(STDLIB_UV_CPPFLAGS))) \
		TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CFLAGS) $(STDLIB_UV_CFLAGS))) \
		TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_LDFLAGS) $(STDLIB_UV_LDFLAGS))) \
		$(TITANC) titan.uv

# Higher-level standard modules import the already-built canonical uv image.
# They neither compile the uv source again nor link a second copy of libuv.
titan/$(TIMER_SO): titan/timer.titan titan/$(UV_SO) $(STDLIB_COMMON_RUNTIME_PREREQS) titanc \
		$(TITAN_COMPILER_LUA) Makefile | $(STDLIB_RUNTIME_ARCHIVE_PREREQ) \
		$(STDLIB_TOOL_PREREQS)
	CC=$(call make_shell_quote,$(CC)) \
		TITAN_PATH_0_11=$(call make_shell_quote,$(CURDIR)) TITAN_PATH= \
		TITAN_RUNTIME_PREBUILT=1 \
		TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CPPFLAGS)) \
		TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CFLAGS)) \
		TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_LDFLAGS)) \
		$(TITANC) titan.timer

# The filesystem facade imports the canonical uv image and keeps all native
# libuv types, shim symbols, and link inputs confined to uv.so.
titan/$(FS_SO): titan/fs.titan titan/$(UV_SO) $(STDLIB_COMMON_RUNTIME_PREREQS) titanc \
		$(TITAN_COMPILER_LUA) Makefile | $(STDLIB_RUNTIME_ARCHIVE_PREREQ) \
		$(STDLIB_TOOL_PREREQS)
	CC=$(call make_shell_quote,$(CC)) \
		TITAN_PATH_0_11=$(call make_shell_quote,$(CURDIR)) TITAN_PATH= \
		TITAN_RUNTIME_PREBUILT=1 \
		TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CPPFLAGS)) \
		TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CFLAGS)) \
		TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_LDFLAGS)) \
		$(TITANC) titan.fs

# The networking facade has the same binary-only boundary as fs: native TCP,
# DNS, and libuv ownership remain implemented by the canonical uv image.
titan/$(NET_SO): titan/net.titan titan/$(UV_SO) $(STDLIB_COMMON_RUNTIME_PREREQS) titanc \
		$(TITAN_COMPILER_LUA) Makefile | $(STDLIB_RUNTIME_ARCHIVE_PREREQ) \
		$(STDLIB_TOOL_PREREQS)
	CC=$(call make_shell_quote,$(CC)) \
		TITAN_PATH_0_11=$(call make_shell_quote,$(CURDIR)) TITAN_PATH= \
		TITAN_RUNTIME_PREBUILT=1 \
		TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CPPFLAGS)) \
		TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CFLAGS)) \
		TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_LDFLAGS)) \
		$(TITANC) titan.net

# The portable OS facade also imports only the canonical uv image. All native
# libuv implementation details stay in uv.so.
titan/$(OS_SO): titan/os.titan titan/$(UV_SO) $(STDLIB_COMMON_RUNTIME_PREREQS) titanc \
		$(TITAN_COMPILER_LUA) Makefile | $(STDLIB_RUNTIME_ARCHIVE_PREREQ) \
		$(STDLIB_TOOL_PREREQS)
	CC=$(call make_shell_quote,$(CC)) \
		TITAN_PATH_0_11=$(call make_shell_quote,$(CURDIR)) TITAN_PATH= \
		TITAN_RUNTIME_PREBUILT=1 \
		TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CPPFLAGS)) \
		TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CFLAGS)) \
		TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_LDFLAGS)) \
		$(TITANC) titan.os

install-stdlib: stdlib ## Install the canonical qualified standard modules
	mkdir -p "$(TITAN_STDLIB_DIR)" "$(TITAN_SHARE_DIR)/LICENSES"
	@set -e; for module in $(STDLIB_MODULES); do \
		rm -f "$(TITAN_STDLIB_DIR)/$$module.so"; \
		install -m 0755 "titan/$$module.so" \
			"$(TITAN_STDLIB_DIR)/$$module.so"; \
		rm -rf "$(TITAN_STDLIB_DIR)/$$module.so.dSYM"; \
		if test -d "titan/$$module.so.dSYM"; then \
			cp -R "titan/$$module.so.dSYM" \
				"$(TITAN_STDLIB_DIR)/$$module.so.dSYM"; \
		fi; \
		rm -f "$(TITAN_STDLIB_ABI_DIR)/$$module.so"; \
		rm -rf "$(TITAN_STDLIB_ABI_DIR)/$$module.so.dSYM"; \
		rm -f "$(LUA_LIBDIR)/titan/$$module.so"; \
		rm -rf "$(LUA_LIBDIR)/titan/$$module.so.dSYM"; \
		rm -f "$(TITAN_STDLIB_LEGACY_DIR)/$$module.so"; \
		rm -rf "$(TITAN_STDLIB_LEGACY_DIR)/$$module.so.dSYM"; \
	done
	rm -f "$(LUA_LIBDIR)/coro.so"
	rm -rf "$(LUA_LIBDIR)/coro.so.dSYM"
	cp THIRD_PARTY_NOTICES.md "$(TITAN_SHARE_DIR)/THIRD_PARTY_NOTICES.md"
	cp LICENSES/libuv-LICENSE "$(TITAN_SHARE_DIR)/LICENSES/libuv-LICENSE"

# LuaRocks invokes this only after it has deployed titanc and its Lua compiler
# modules. Force all six standard modules through that installed compiler,
# then install each canonical qualified DSO at its one supported pathname.
rock-post-install:
	@test -n "$(strip $(ROCKS_TREE))" || { \
	  echo "ERROR: rock-post-install requires ROCKS_TREE" >&2; exit 1; \
	}
	@test -n "$(strip $(ROCK_TITANC))" && test -x "$(ROCK_TITANC)" || { \
	  echo "ERROR: rock-post-install requires deployed ROCK_TITANC" >&2; exit 1; \
	}
	@mkdir -p "$(ROCKS_TREE)"
	@echo "==> Building Titan stdlib with $(ROCK_TITANC)"
	@if test -d "$(ROCKS_TREE)"; then \
	  rocks_tree=$$(CDPATH= cd "$(ROCKS_TREE)" && pwd -P); \
	  TITAN_ROCKS_ROOT="$$rocks_tree" \
	    $(MAKE) --no-print-directory -B $(STDLIB_QUALIFIED_SOS) \
		  TITAN_ROCKS_ROOT="$$rocks_tree" \
		  STDLIB_USE_INSTALLED_RUNTIME=1 \
		  TITANC=$(call make_shell_quote,$(ROCK_TITANC)) \
		  LIBUV_MODE=$(call make_shell_quote,$(LIBUV_MODE)); \
	fi
	@set -e; \
	rocks_tree=$$(CDPATH= cd "$(ROCKS_TREE)" && pwd -P); \
	stdlib_abi_dir="$$rocks_tree/lib/titan/$(TITAN_ABI_VERSION)"; \
	stdlib_dir="$$stdlib_abi_dir/titan"; \
	lua_cdir="$$rocks_tree/lib/lua/$(LUA_ABI_VERSION)"; \
	lua_module_dir="$$lua_cdir/titan"; \
	legacy_stdlib_dir="$$lua_module_dir/stdlib_$(subst .,_,$(TITAN_ABI_VERSION))"; \
	mkdir -p "$$stdlib_dir"; \
	for module in $(STDLIB_MODULES); do \
	  rm -f "$$stdlib_dir/$$module.so"; \
	  install -m 0755 "titan/$$module.so" "$$stdlib_dir/$$module.so"; \
	  rm -rf "$$stdlib_dir/$$module.so.dSYM"; \
	  if test -d "titan/$$module.so.dSYM"; then \
	    cp -R "titan/$$module.so.dSYM" "$$stdlib_dir/$$module.so.dSYM"; \
	  fi; \
	  rm -f "$$stdlib_abi_dir/$$module.so"; \
	  rm -rf "$$stdlib_abi_dir/$$module.so.dSYM"; \
	  rm -f "$$lua_module_dir/$$module.so"; \
	  rm -rf "$$lua_module_dir/$$module.so.dSYM"; \
	  rm -f "$$legacy_stdlib_dir/$$module.so"; \
	  rm -rf "$$legacy_stdlib_dir/$$module.so.dSYM"; \
	done; \
	rm -f "$$lua_cdir/coro.so"; \
	rm -rf "$$lua_cdir/coro.so.dSYM"

# Compatibility name for callers of the former rockspec build target.  It no
# longer builds stdlib before LuaRocks has deployed the compiler.
rock-build: titan

test: luarocks libbacktrace libuv ## Build/install the rock and run the suite via `luarocks test`
	unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5; \
	  PATH="$(PREFIX)/bin:$$PATH" "$(PREFIX)/bin/luarocks" make --force
	unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5; \
	  PATH="$(PREFIX)/bin:$$PATH" "$(PREFIX)/bin/luarocks" test

examples: lua ## Compile the example Titan modules (SDL examples need SDL2 headers)
	$(MAKE) -C examples all

clean: ## Remove generated build/test artifacts (keeps the Lua tree)
	rm -f $(RUNTIME_O) titan-runtime/*.o $(TITAN_RUNTIME_LIB)
	rm -f $(RUNTIME_BUILD_CONFIG) $(RUNTIME_ARCHIVE_CONFIG) \
		$(TITANLIB_BUILD_CONFIG) $(UV_CONFIG_STAMP)
	rm -f titan/*.c titan/*.o
	rm -f titan/*.so
	rm -rf $(addsuffix .dSYM,$(STDLIB_SOS)) \
		$(addsuffix .dSYM,$(STDLIB_QUALIFIED_SOS))
	rm -f examples/*.c examples/*.o examples/*.so examples/sdl_demo
	rm -f testfiles/*.c testfiles/*.o testfiles/*.so
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
