# Titan compiler — developer tooling.
#
# The compiler generates C that includes Lua 5.5's *internal* headers and links
# against its static library, so the test suite needs a Lua source tree built
# next to this checkout. This Makefile downloads and builds that tree, runs the
# suite through `luarocks test`, and cleans up generated artifacts.
#
# Run `make help` to list the available targets.

# Must match the hardcoded "lua-5.5.0" in titan-compiler/driver.lua
# (driver.LUA_SOURCE_PATH) and spec/support/helpers.lua, so don't override this
# unless you also update those — it only exists to keep the URL/paths below DRY.
LUA_VERSION ?= 5.5.0
LUA_DIR     := lua-$(LUA_VERSION)
LUA_TARBALL := $(LUA_DIR).tar.gz
LUA_URL     := https://www.lua.org/ftp/$(LUA_TARBALL)
LUA_LIB     := $(LUA_DIR)/src/liblua.a

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
# In bundled mode the archive is passed through titanc's extra-object channel;
# in system mode pkg-config's ordered linker output must stay intact.
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
else ifeq ($(LIBUV_MODE),system)
  LIBUV_LIB           :=
  LIBUV_INCLUDE_DIR   :=
  LIBUV_CPPFLAGS       = $(strip $(shell $(LIBUV_PKG_CONFIG) --cflags libuv 2>/dev/null))
  LIBUV_CFLAGS        := -fno-strict-aliasing
  LIBUV_EXTRA_OBJECTS :=
  LIBUV_LINK_LIBS     :=
  LIBUV_LDFLAGS        = $(strip $(shell $(LIBUV_PKG_CONFIG) --libs libuv 2>/dev/null))
else
  LIBUV_LIB           :=
  LIBUV_INCLUDE_DIR   :=
  LIBUV_CPPFLAGS      :=
  LIBUV_CFLAGS        :=
  LIBUV_EXTRA_OBJECTS :=
  LIBUV_LINK_LIBS     :=
  LIBUV_LDFLAGS       :=
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
COROUTINE_SO := coroutine.so
UV_SO        := uv.so
TIMER_SO     := timer.so
FS_SO        := fs.so
NET_SO       := net.so
OS_SO        := os.so
UV_CONFIG_STAMP := $(LIBUV_BUILD_DIR)/.titan-uv-config
STDLIB_MODULES := coroutine uv timer fs net os
STDLIB_SOS     := $(addsuffix .so,$(STDLIB_MODULES))
STDLIB_ALIASES := $(addprefix titan/,$(STDLIB_SOS))
ROCK_RUNTIME_SO := titan.so
ROCK_LUA_INCDIR ?= .lua/include
ROCK_CFLAGS     ?= -O2 -fPIC
ROCK_LD         ?= $(CC)
ROCK_LIBFLAG    ?= -shared
TITAN_LUA ?= $(if $(wildcard ./lua),./lua,.lua/bin/lua)
# Project Lua launchers put the installed rock before the checkout. Prepend the
# checkout so stdlib rebuilds always use the compiler sources that triggered
# them, while retaining the launcher's paths for third-party dependencies.
TITANC    ?= $(TITAN_LUA) -e 'package.path="./?.lua;./?/init.lua;" .. package.path' ./titanc
TITAN_COMPILER_LUA := $(wildcard titan-compiler/*.lua c-parser/*.lua) typed.lua

# Manual/prefix installs place the canonical Titan binary once and let Lua's
# qualified module path reach that same mapped DSO through a relative symlink.
# Custom layouts may override each destination and the relative alias target.
PREFIX                     ?= /usr/local
TITAN_ABI_VERSION          := 0.11
LUA_ABI_VERSION            ?= 5.5
TITAN_STDLIB_DIR           ?= $(PREFIX)/lib/titan/$(TITAN_ABI_VERSION)
LUA_LIBDIR                 ?= $(PREFIX)/lib/lua/$(LUA_ABI_VERSION)
TITAN_STDLIB_ALIAS_PREFIX  ?= ../../../titan/$(TITAN_ABI_VERSION)
TITAN_SHARE_DIR            ?= $(PREFIX)/share/titan

# libbacktrace is cloned + built into ./libbacktrace (gitignored), mirroring the
# ./lua-5.5.0 tree. The generated C and the runtime include its backtrace.h and
# link its static archive (driver.lua references ./libbacktrace/.libs/...).
LIBBT_DIR := libbacktrace
LIBBT_URL := https://github.com/ianlancetaylor/libbacktrace.git
LIBBT_LIB := $(LIBBT_DIR)/.libs/libbacktrace.a

.PHONY: all help lua libbacktrace libuv libuv-config check-libuv-tools \
	check-system-libuv invalid-libuv-mode runtime stdlib install-stdlib test \
	rock-build examples clean clean-lua clean-libbacktrace clean-libuv distclean \
	FORCE

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
	@echo "For a custom install prefix, run 'make install-stdlib PREFIX=/path'"
	@echo "and set TITAN_STDLIB_PATH=/path/lib/titan/$(TITAN_ABI_VERSION)."

libuv: ## Build/validate libuv (bundled by default; LIBUV_MODE=system is optional)

lua: $(LUA_LIB) .lua/bin/lua ## Download and build the bundled Lua source tree

$(LUA_LIB):
	@if [ ! -d "$(LUA_DIR)" ]; then \
	  echo "==> Downloading $(LUA_URL)"; \
	  if command -v curl >/dev/null 2>&1; then \
	    curl -fL -o "$(LUA_TARBALL)" "$(LUA_URL)"; \
	  elif command -v wget >/dev/null 2>&1; then \
	    wget -O "$(LUA_TARBALL)" "$(LUA_URL)"; \
	  else \
	    echo "ERROR: need 'curl' or 'wget' to download Lua" >&2; exit 1; \
	  fi; \
	  echo "==> Extracting $(LUA_TARBALL)"; \
	  tar zxf "$(LUA_TARBALL)"; \
	fi
	rm "$(LUA_TARBALL)"
	@echo "==> Building Lua ($(LUA_PLATFORM), MYCFLAGS=$(LUA_MYCFLAGS))"
	$(MAKE) -C "$(LUA_DIR)" $(LUA_PLATFORM) \
		MYCFLAGS=$(call make_shell_quote,$(LUA_MYCFLAGS)) \
		MYLDFLAGS=$(call make_shell_quote,$(LUA_MYLDFLAGS)) \
		MYLIBS=$(call make_shell_quote,$(LUA_MYLIBS))

.lua/bin/lua: $(LUA_LIB)
	$(MAKE) -C "$(LUA_DIR)" install INSTALL_TOP="$(CURDIR)/.lua"	

libbacktrace: $(LIBBT_LIB) ## Clone and build the bundled libbacktrace source tree

$(LIBBT_LIB):
	@if [ ! -d "$(LIBBT_DIR)" ]; then \
	  echo "==> Cloning $(LIBBT_URL)"; \
	  git clone "$(LIBBT_URL)" "$(LIBBT_DIR)"; \
	fi
	@echo "==> Building libbacktrace (configure + make, $(LIBBT_CFLAGS))"
	cd "$(LIBBT_DIR)" && \
		./configure CFLAGS=$(call make_shell_quote,$(LIBBT_CFLAGS)) && \
		$(MAKE)

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
# Preserve this stamp's mtime when every effective native-build input is
# unchanged; CI uses the same profile string as its cross-run cache key.
$(LIBUV_BUILD_CONFIG): FORCE
	@mkdir -p "$(@D)"
	@tmp="$@.tmp"; \
	{ printf '%s\n' \
		$(call make_shell_quote,HOST_OS=$(HOST_OS)) \
		$(call make_shell_quote,HOST_ARCH=$(HOST_ARCH)) \
		$(call make_shell_quote,CC=$(CC)) \
		$(call make_shell_quote,AR=$(AR)) \
		$(call make_shell_quote,RANLIB=$(RANLIB)) \
		$(call make_shell_quote,CMAKE_GENERATOR=$(CMAKE_GENERATOR)) \
		$(call make_shell_quote,LIBUV_VERSION=$(LIBUV_VERSION)) \
		$(call make_shell_quote,LIBUV_BUILD_PROFILE=$(LIBUV_BUILD_PROFILE)) \
		$(call make_shell_quote,LIBUV_BUILD_TYPE=$(LIBUV_BUILD_TYPE)) \
		$(call make_shell_quote,LIBUV_CMAKE_FLAGS=$(LIBUV_CMAKE_FLAGS)) \
		$(call make_shell_quote,LIBUV_BUILD_CFLAGS=$(LIBUV_BUILD_CFLAGS)); } > "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then \
		rm -f "$$tmp"; \
	else \
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

runtime: libuv $(RUNTIME_O) $(CORO_O) $(UV_O) ## Build the Titan C runtime objects (also built lazily by the compiler)

# Make does not otherwise notice command-line variable changes.  Recompute a
# small stamp on every invocation, but update its mtime only when an effective
# uv compile/link input changes.  Switching bundled/system mode, compiler, or
# flags then rebuilds titan_uv.o and consequently relinks uv.so without asking
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
		$(call make_shell_quote,LIBUV_LDFLAGS=$(LIBUV_LDFLAGS)); } > "$$tmp"; \
	if test -r "$@" && cmp -s "$$tmp" "$@"; then \
		rm -f "$$tmp"; \
	else \
		mv -f "$$tmp" "$@"; \
	fi

$(RUNTIME_O): titan-runtime/titan.c titan-runtime/titan.h | $(LUA_LIB) $(LIBBT_LIB)
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(CFLAGS) $(TITAN_EXTRA_CFLAGS) \
		-c titan-runtime/titan.c -I titan-runtime -I $(LUA_DIR)/src \
		-I $(LIBBT_DIR) -o $@

$(CORO_O): titan-runtime/titan_coro.c titan-runtime/titan/coro.h titan-runtime/minicoro.h titan-runtime/titan/ffi.h | $(LUA_LIB) $(LIBBT_LIB)
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(CFLAGS) $(TITAN_EXTRA_CFLAGS) \
		-c titan-runtime/titan_coro.c -I titan-runtime -I $(LUA_DIR)/src \
		-I $(LIBBT_DIR) -o $@

$(UV_O): titan-runtime/titan_uv.c titan-runtime/titan/uv.h \
		titan-runtime/titan.h $(UV_CONFIG_STAMP) | $(LUA_LIB) $(LIBBT_LIB) libuv
	$(CC) $(TITAN_EXTRA_CPPFLAGS) $(LIBUV_CPPFLAGS) $(CFLAGS) \
		$(TITAN_EXTRA_CFLAGS) $(LIBUV_CFLAGS) -c titan-runtime/titan_uv.c \
		-I titan-runtime -I $(LUA_DIR)/src -I $(LIBBT_DIR) -o $@

stdlib: libuv $(STDLIB_ALIASES) ## Build standard modules and their bundled dependencies

# Build the reserved canonical module only through the explicit standard-source
# mode.  Empty ordinary paths prevent an installed or application module from
# capturing this root while it is being built.
$(COROUTINE_SO): stdlib/coroutine.titan $(CORO_O) $(RUNTIME_O) titanc \
		$(TITAN_COMPILER_LUA) Makefile | .lua/bin/lua $(LIBBT_LIB)
	CC=$(call make_shell_quote,$(CC)) TITAN_PATH_0_11= TITAN_PATH= \
		TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CPPFLAGS)) \
		TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CFLAGS)) \
		TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_LDFLAGS)) \
		$(TITANC) --stdlib-build --tree stdlib \
		--lua-name titan.coroutine coroutine -X $(CORO_O)

# uv imports the already-built canonical coroutine image.  Its shim object is
# always an extra object; bundled mode appends the one static libuv archive,
# while system mode leaves that slot empty and supplies pkg-config's ordered
# output only through the final-link flags.
$(UV_SO): stdlib/uv.titan $(COROUTINE_SO) $(UV_O) $(RUNTIME_O) titanc \
		$(TITAN_COMPILER_LUA) Makefile $(LIBUV_EXTRA_OBJECTS) | \
		.lua/bin/lua $(LIBBT_LIB) libuv
	CC=$(call make_shell_quote,$(CC)) TITAN_PATH_0_11= TITAN_PATH= \
		TITAN_STDLIB_PATH=$(call make_shell_quote,$(CURDIR)) \
		TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CPPFLAGS) $(LIBUV_CPPFLAGS))) \
		TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_CFLAGS) $(LIBUV_CFLAGS))) \
		TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(strip $(TITAN_EXTRA_LDFLAGS) $(LIBUV_LDFLAGS))) \
		$(TITANC) --stdlib-build --tree stdlib --lua-name titan.uv uv \
		-X $(UV_O) $(LIBUV_EXTRA_OBJECTS)

# Higher-level standard modules import the already-built canonical uv image.
# They neither compile the uv source again nor link a second copy of libuv.
$(TIMER_SO): stdlib/timer.titan $(UV_SO) $(RUNTIME_O) titanc \
		$(TITAN_COMPILER_LUA) Makefile | .lua/bin/lua $(LIBBT_LIB)
	CC=$(call make_shell_quote,$(CC)) TITAN_PATH_0_11= TITAN_PATH= \
		TITAN_STDLIB_PATH=$(call make_shell_quote,$(CURDIR)) \
		TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CPPFLAGS)) \
		TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CFLAGS)) \
		TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_LDFLAGS)) \
		$(TITANC) --stdlib-build --tree stdlib \
		--lua-name titan.timer timer

# The filesystem facade imports the canonical uv image and keeps all native
# libuv types, shim symbols, and link inputs confined to uv.so.
$(FS_SO): stdlib/fs.titan $(UV_SO) $(RUNTIME_O) titanc \
		$(TITAN_COMPILER_LUA) Makefile | .lua/bin/lua $(LIBBT_LIB)
	CC=$(call make_shell_quote,$(CC)) TITAN_PATH_0_11= TITAN_PATH= \
		TITAN_STDLIB_PATH=$(call make_shell_quote,$(CURDIR)) \
		TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CPPFLAGS)) \
		TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CFLAGS)) \
		TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_LDFLAGS)) \
		$(TITANC) --stdlib-build --tree stdlib \
		--lua-name titan.fs fs

# The networking facade has the same binary-only boundary as fs: native TCP,
# DNS, and libuv ownership remain implemented by the canonical uv image.
$(NET_SO): stdlib/net.titan $(UV_SO) $(RUNTIME_O) titanc \
		$(TITAN_COMPILER_LUA) Makefile | .lua/bin/lua $(LIBBT_LIB)
	CC=$(call make_shell_quote,$(CC)) TITAN_PATH_0_11= TITAN_PATH= \
		TITAN_STDLIB_PATH=$(call make_shell_quote,$(CURDIR)) \
		TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CPPFLAGS)) \
		TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CFLAGS)) \
		TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_LDFLAGS)) \
		$(TITANC) --stdlib-build --tree stdlib \
		--lua-name titan.net net

# The portable OS facade also imports only the canonical uv image. All native
# libuv implementation details stay in uv.so.
$(OS_SO): stdlib/os.titan $(UV_SO) $(RUNTIME_O) titanc \
		$(TITAN_COMPILER_LUA) Makefile | .lua/bin/lua $(LIBBT_LIB)
	CC=$(call make_shell_quote,$(CC)) TITAN_PATH_0_11= TITAN_PATH= \
		TITAN_STDLIB_PATH=$(call make_shell_quote,$(CURDIR)) \
		TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CPPFLAGS)) \
		TITAN_EXTRA_CFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_CFLAGS)) \
		TITAN_EXTRA_LDFLAGS=$(call make_shell_quote,$(TITAN_EXTRA_LDFLAGS)) \
		$(TITANC) --stdlib-build --tree stdlib \
		--lua-name titan.os os

titan/%.so: %.so
	mkdir -p "$(@D)"
	rm -f "$@"
	ln -s ../$*.so "$@"

install-stdlib: stdlib ## Install canonical standard modules and relative Lua aliases
	mkdir -p "$(TITAN_STDLIB_DIR)" "$(LUA_LIBDIR)/titan" \
		"$(TITAN_SHARE_DIR)/LICENSES"
	@set -e; for module in $(STDLIB_MODULES); do \
		cp "$$module.so" "$(TITAN_STDLIB_DIR)/$$module.so"; \
		rm -f "$(LUA_LIBDIR)/titan/$$module.so"; \
		ln -s "$(TITAN_STDLIB_ALIAS_PREFIX)/$$module.so" \
			"$(LUA_LIBDIR)/titan/$$module.so"; \
	done
	cp THIRD_PARTY_NOTICES.md "$(TITAN_SHARE_DIR)/THIRD_PARTY_NOTICES.md"
	cp LICENSES/libuv-LICENSE "$(TITAN_SHARE_DIR)/LICENSES/libuv-LICENSE"

# LuaRocks' builtin backend cannot run the Titan compiler before it collects
# install files. Its make backend calls this target first, then copies every
# declared Lua/C artifact into the per-rock tree so the rock manifest, binary
# rocks, upgrades, and uninstall all own them. The deployed Lua alias is changed
# to a relative symlink by the rockspec's portable post-install hook.
rock-build: stdlib $(ROCK_RUNTIME_SO) ## Build all artifacts consumed by the LuaRocks manifest

$(ROCK_RUNTIME_SO): titan-runtime/titanlib.c
	$(CC) $(ROCK_CFLAGS) $(TITAN_EXTRA_CFLAGS) \
		-I"$(ROCK_LUA_INCDIR)" \
		-c titan-runtime/titanlib.c -o titan-runtime/titanlib.o
	$(ROCK_LD) $(ROCK_LIBFLAG) -o $@ titan-runtime/titanlib.o \
		$(TITAN_EXTRA_LDFLAGS)

test: lua libbacktrace libuv ## Build/install the rock and run the suite via `luarocks test`
	luarocks make
	luarocks test

examples: lua ## Compile the example Titan modules (SDL examples need SDL2 headers)
	$(MAKE) -C examples all

clean: ## Remove generated build/test artifacts (keeps the Lua tree)
	rm -f $(RUNTIME_O) titan-runtime/*.o
	rm -f stdlib/*.c stdlib/*.o
	rm -f titan/*.so
	-rmdir titan
	rm -f examples/*.c examples/*.o examples/*.so examples/sdl_demo
	rm -f testfiles/*.c testfiles/*.o testfiles/*.so
	rm -f *.c *.o *.so test
	rm -f luacov.stats.out luacov.report.out

clean-lua: ## Remove the downloaded Lua source tree(s) and tarball
	rm -rf $(LUA_DIR) lua-5.*/
	rm -f $(LUA_TARBALL) lua-5.*.tar.gz
	rm -rf .lua

clean-libbacktrace: ## Remove the cloned libbacktrace source tree
	rm -rf $(LIBBT_DIR)

clean-libuv: ## Remove the bundled libuv source, build tree, and release tarball
	rm -rf $(LIBUV_SRC_DIR) $(LIBUV_BUILD_DIR)
	rm -f $(LIBUV_TARBALL)

distclean: clean clean-lua clean-libbacktrace clean-libuv ## Remove all downloaded trees and artifacts
