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
CFLAGS    ?= --std=c99 -O2 -Wall -fPIC
RUNTIME_O := titan-runtime/titan.o

.PHONY: all help lua runtime test examples clean clean-lua distclean

all: lua ## Build everything needed to run the test suite (default)

help: ## Show this help
	@echo "Titan developer tasks:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

lua: $(LUA_LIB) ## Download and build the bundled Lua source tree

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
	@echo "==> Building Lua ($(LUA_PLATFORM), MYCFLAGS=-fPIC)"
	$(MAKE) -C "$(LUA_DIR)" $(LUA_PLATFORM) MYCFLAGS=-fPIC

runtime: $(RUNTIME_O) ## Build the Titan C runtime object (also built lazily by the compiler)

$(RUNTIME_O): titan-runtime/titan.c titan-runtime/titan.h | $(LUA_LIB)
	$(CC) $(CFLAGS) -c titan-runtime/titan.c -I titan-runtime -I $(LUA_DIR)/src -o $@

test: lua ## Build/install the rock and run the suite via `luarocks test`
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

distclean: clean clean-lua ## Remove everything: artifacts and the Lua tree
