# LuaRocks supplies its private staging directories. Standalone Make installs
# use the selected tree directly; LuaRocks deploys and inventories staged files.
INST_BINDIR ?= $(TITAN_INSTALL_TREE)/bin
INST_LUADIR ?= $(TITAN_INSTALL_TREE)/share/lua/5.5
INST_LIBDIR ?= $(TITAN_INSTALL_TREE)/lib/lua/5.5
INST_CONFDIR ?= $(TITAN_INSTALL_TREE)/etc
TITAN_COMPILER_LUA := $(wildcard titan-compiler/*.lua \
	titan-compiler/checker/*.lua titan-compiler/coder/*.lua c-parser/*.lua)

# The including Makefile names the built `titan` Lua support module
# (TITAN_SUPPORT_MODULE). It is an ordinary native Lua module: LuaRocks
# deploys it to lib/lua/5.5 and owns it like any other rock file. Its build
# directory may contain spaces, so take only the last path component.
TITAN_SUPPORT_MODULE_NAME = $(lastword $(subst /, ,$(TITAN_SUPPORT_MODULE)))
.PHONY: install-compiler
install-compiler:
	@set -e; \
	for source in $(TITAN_COMPILER_LUA); do \
	  destination="$(INST_LUADIR)/$$source"; \
	  mkdir -p "$${destination%/*}"; \
	  install -p -m 0644 "$$source" "$$destination"; \
	done; \
	mkdir -p "$(INST_BINDIR)" "$(INST_CONFDIR)" "$(INST_LIBDIR)"; \
	install -p -m 0755 "$(TITAN_SUPPORT_MODULE)" \
	  "$(INST_LIBDIR)/$(TITAN_SUPPORT_MODULE_NAME)"; \
	install -p -m 0755 titanc "$(INST_BINDIR)/titanc"; \
	install -p -m 0644 THIRD_PARTY_NOTICES.md "$(INST_CONFDIR)/"

# Files outside LuaRocks' lua/lib/bin deployment stay in the version directory
# so `luarocks pack` includes them in binary rocks. The hook always copies from
# this retained payload, without depending on the build directory.
.PHONY: install-rock-tools binary-rock
install-rock-tools:
	mkdir -p "$(INST_PREFIX)/installer" "$(INST_BINDIR)"
	install -p -m 0644 scripts/titan_install.lua "$(INST_PREFIX)/installer/titan_install.lua"
	install -p -m 0755 scripts/titan-uninstall "$(INST_BINDIR)/titan-uninstall"
	printf '%s\n' '$(OPENSSL_MODE)' > "$(INST_PREFIX)/installer/openssl-mode"

TITAN_LUAROCKS ?= $(PREFIX)/bin/luarocks$(if $(filter Windows_NT,$(OS)),.exe)
TITAN_ROCK_VERSION ?= $(TITAN_VERSION)-1
binary-rock:
	@set -e; \
	arch=$$("$(TITAN_LUAROCKS)" --lua-version 5.5 --lua-dir "$(PREFIX)" --tree "$(TITAN_INSTALL_TREE)" config arch); \
	case "$$arch" in ''|*[!A-Za-z0-9_-]*) echo "Invalid LuaRocks architecture: $$arch" >&2; exit 1;; esac; \
	"$(TITAN_LUAROCKS)" --lua-version 5.5 --lua-dir "$(PREFIX)" --tree "$(TITAN_INSTALL_TREE)" pack titan "$(TITAN_ROCK_VERSION)"; \
	if test -f "titan-$(TITAN_ROCK_VERSION).all.rock"; then \
	  mv -f "titan-$(TITAN_ROCK_VERSION).all.rock" "titan-$(TITAN_ROCK_VERSION).$$arch.rock"; \
	fi; \
	test -f "titan-$(TITAN_ROCK_VERSION).$$arch.rock"; \
	echo "Packed: titan-$(TITAN_ROCK_VERSION).$$arch.rock"
