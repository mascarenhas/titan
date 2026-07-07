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

# The Lua build target ("linux", "macosx", ...) is taken from `uname` but can be
# overridden on the command line: `make lua LUA_PLATFORM=bsd`.
ifndef LUA_PLATFORM
  UNAME_S := $(shell uname -s)
  ifeq ($(UNAME_S),Darwin)
    LUA_PLATFORM := macosx
  else
    LUA_PLATFORM := linux
  endif
endif

# Kept in sync with titan-compiler/driver.lua (driver.CC / driver.CFLAGS).
CC        ?= cc
CFLAGS    ?= --std=c99 -O2 -Wall -fPIC -g -fno-optimize-sibling-calls
RUNTIME_O := titan-runtime/titan.o
CORO_O    := titan-runtime/titan_coro.o
CORO_SO   := coro.so

# libbacktrace is cloned + built into ./libbacktrace (gitignored), mirroring the
# ./lua-5.5.0 tree. The generated C and the runtime include its backtrace.h and
# link its static archive (driver.lua references ./libbacktrace/.libs/...).
LIBBT_DIR := libbacktrace
LIBBT_URL := https://github.com/ianlancetaylor/libbacktrace.git
LIBBT_LIB := $(LIBBT_DIR)/.libs/libbacktrace.a

.PHONY: all help lua libbacktrace runtime stdlib test examples clean clean-lua clean-libbacktrace distclean

all: lua libbacktrace stdlib ## Build everything needed to run the test suite (default)

help: ## Show this help
	@echo "Titan developer tasks:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

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
	@echo "==> Building Lua ($(LUA_PLATFORM), MYCFLAGS=-fPIC)"
	$(MAKE) -C "$(LUA_DIR)" $(LUA_PLATFORM) MYCFLAGS=-fPIC

.lua/bin/lua: $(LUA_LIB)
	$(MAKE) -C "$(LUA_DIR)" install INSTALL_TOP="$(CURDIR)/.lua"	

libbacktrace: $(LIBBT_LIB) ## Clone and build the bundled libbacktrace source tree

$(LIBBT_LIB):
	@if [ ! -d "$(LIBBT_DIR)" ]; then \
	  echo "==> Cloning $(LIBBT_URL)"; \
	  git clone "$(LIBBT_URL)" "$(LIBBT_DIR)"; \
	fi
	@echo "==> Building libbacktrace (configure + make, -fPIC)"
	cd "$(LIBBT_DIR)" && ./configure CFLAGS="-fPIC -g -O2" && $(MAKE)

runtime: $(RUNTIME_O) $(CORO_O) ## Build the Titan C runtime objects (also built lazily by the compiler)

$(RUNTIME_O): titan-runtime/titan.c titan-runtime/titan.h | $(LUA_LIB) $(LIBBT_LIB)
	$(CC) $(CFLAGS) -c titan-runtime/titan.c -I titan-runtime -I $(LUA_DIR)/src -I $(LIBBT_DIR) -o $@

$(CORO_O): titan-runtime/titan_coro.c titan-runtime/titan/coro.h titan-runtime/minicoro.h titan-runtime/titan/ffi.h | $(LUA_LIB) $(LIBBT_LIB)
	$(CC) $(CFLAGS) -c titan-runtime/titan_coro.c -I titan-runtime -I $(LUA_DIR)/src -I $(LIBBT_DIR) -o $@

stdlib: $(CORO_SO) ## Build the Titan standard library modules

$(CORO_SO): coro.titan $(CORO_O) $(RUNTIME_O) titanc | $(LUA_LIB) $(LIBBT_LIB)
	TITAN_PATH_0_11=/tmp TITAN_PATH=/tmp ./titanc coro -X $(CORO_O)

test: lua libbacktrace stdlib ## Build/install the rock and run the suite via `luarocks test`
	luarocks make
	luarocks test

examples: lua ## Compile the example Titan modules (SDL examples need SDL2 headers)
	$(MAKE) -C examples all

clean: ## Remove generated build/test artifacts (keeps the Lua tree)
	rm -f $(RUNTIME_O) titan-runtime/*.o
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

distclean: clean clean-lua clean-libbacktrace ## Remove everything: artifacts, the Lua tree, and libbacktrace
