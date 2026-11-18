# Browser Lua, SDK and stdlib recipes shared by the two host Makefiles.
BROWSER_STDLIB_ROOTS := titan.test titan.coroutine titan.gc titan.math titan.iteration \
	titan.reflect titan.json titan.protobuf titan.transfer titan.peg titan.string titan.url titan.path titan.browser \
	titan.async titan.timer titan.os titan.io titan.lua titan.http titan.websocket
BROWSER_LPEGLABEL_SOURCES ?= $(LPEGLABEL_SOURCES)
BROWSER_INSTALL_TREE ?= $(TITAN_INSTALL_TREE)
BROWSER_EXE_SUFFIX ?=
BROWSER_LUA_MODULE_SUFFIX ?= .so
BROWSER_NATIVE_PATH ?= $(abspath $(1))
BROWSER_RUNNER_SHELL ?=
BROWSER_LPEGLABEL_CPPFLAGS ?= $(LPEGLABEL_CPPFLAGS)
BROWSER_COMPILER_REMEDY ?= run 'luarocks make' or 'make install-compiler-sdk' first
TITAN_BROWSER_BUILD_DIR ?= $(TITAN_OUTPUT_DIR)/browser-sdk
LUA_BROWSER_CC ?=
LUA_BROWSER_AR ?=
LUA_BROWSER_RANLIB ?=
LUA_BROWSER_MYCFLAGS ?= $(MYCFLAGS)
LUA_BROWSER_MYLDFLAGS ?= $(MYLDFLAGS)

.PHONY: lua-browser browser-sdk uninstall-browser-sdk titan-stdlib-browser-test
lua-browser: ## Build and install the fork's WebAssembly Lua library with configuration + digest reuse
	+@$(RECURSIVE_WRAPPER_GUARD) \
	PREFIX=$(call make_shell_quote,$(PREFIX)) \
	LUA_DIR=$(call make_shell_quote,$(LUA_DIR)) \
	MAKE=$(call make_shell_quote,$(MAKE)) \
	FORK_REVISION=$(call make_shell_quote,$(FORK_REVISION)) \
	LUA_BROWSER_CC=$(call make_shell_quote,$(LUA_BROWSER_CC)) \
	LUA_BROWSER_AR=$(call make_shell_quote,$(LUA_BROWSER_AR)) \
	LUA_BROWSER_RANLIB=$(call make_shell_quote,$(LUA_BROWSER_RANLIB)) \
	LUA_BROWSER_MYCFLAGS=$(call make_shell_quote,$(LUA_BROWSER_MYCFLAGS)) \
	LUA_BROWSER_MYLDFLAGS=$(call make_shell_quote,$(LUA_BROWSER_MYLDFLAGS)) \
	sh scripts/lua_browser.sh

# Pool seeding belongs to the mixed Busted/native test launcher. Each build
# target invokes one compiler, which owns its module graph and local cap.
TITAN_JOBS_CHECK = case $(call make_shell_quote,$(TITAN_JOBS)) in ''|0*|*[!0-9]*|?????????*) \
	  echo 'TITAN_JOBS must be a positive integer' >&2; exit 2 ;; esac;

BROWSER_SDK_ENV = PREFIX=$(call make_shell_quote,$(call BROWSER_NATIVE_PATH,$(PREFIX))) \
	TITAN_INSTALL_TREE=$(call make_shell_quote,$(BROWSER_INSTALL_TREE)) \
	ROCKS_TREE=$(call make_shell_quote,$(strip $(ROCKS_TREE))) \
	TITAN_ROOT=$(call make_shell_quote,$(BROWSER_INSTALL_TREE)) \
	TITAN_PATH$(TITAN_LIBRARY_VERSION_SUFFIX)=$(call make_shell_quote,$(call BROWSER_NATIVE_PATH,.)) \
	TITAN_PATH= \
	CPPFLAGS= TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(BROWSER_LPEGLABEL_CPPFLAGS)) \
	TITAN_BUILD_PROFILE=$(call make_shell_quote,$(TITAN_BUILD_PROFILE)) \
	TITAN_VERBOSE=$(call make_shell_quote,$(TITAN_VERBOSE)) \
	$(if $(strip $(ROCKS_TREE)),LUA_PATH=$(call make_shell_quote,$(BROWSER_INSTALL_TREE)/share/lua/5.5/?.lua;$(BROWSER_INSTALL_TREE)/share/lua/5.5/?/init.lua;;)) \
	$(if $(strip $(ROCKS_TREE)),LUA_CPATH=$(call make_shell_quote,$(BROWSER_INSTALL_TREE)/lib/lua/5.5/?$(BROWSER_LUA_MODULE_SUFFIX);;))

browser-sdk: ## Build and install the browser target runtime, tools and core stdlib provider
	+@$(RECURSIVE_WRAPPER_GUARD) $(TITAN_JOBS_CHECK) set -e; \
	unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 TITAN_TARGET; \
	if test -z "$${TITAN_NODE:-}"; then \
	  unset TITAN_NODE; \
	fi; \
	titanc_bin=$(call make_shell_quote,$(BROWSER_INSTALL_TREE)/bin/titanc$(BROWSER_EXE_SUFFIX)); \
	if test ! -x "$$titanc_bin"; then titanc_bin=$(call make_shell_quote,$(PREFIX)/bin/titanc$(BROWSER_EXE_SUFFIX)); fi; \
	if test ! -x "$$titanc_bin"; then \
	  echo "browser-sdk: installed titanc not found; $(BROWSER_COMPILER_REMEDY)" >&2; \
	  exit 1; \
	fi; \
	build_dir=$(call make_shell_quote,$(call BROWSER_NATIVE_PATH,$(TITAN_BROWSER_BUILD_DIR))); \
	$(BROWSER_BUILD_HOST_TOOLS) \
	$(BROWSER_SDK_ENV) $(call make_shell_quote,$(TITAN_LUA)) -E scripts/browser_sdk.lua prepare "$$build_dir" $(call make_shell_quote,$(call BROWSER_NATIVE_PATH,.)); \
	c_objects=$$($(BROWSER_SDK_ENV) "$$titanc_bin" --target browser \
	  --output "$$build_dir" -c --incremental -j$(TITAN_JOBS) \
	  $(if $(filter 1,$(TITAN_VERBOSE)),-v,-q) --print-c-objects \
	  $(foreach source,$(TITAN_RUNTIME_SOURCES) $(BROWSER_LPEGLABEL_SOURCES),--c-source $(call make_shell_quote,$(call BROWSER_NATIVE_PATH,$(source))))); \
	if test -n "$(BROWSER_EXE_SUFFIX)"; then c_objects=$$(printf '%s' "$$c_objects" | tr -d '\r'); fi; \
	nl="$$(printf '\nX')"; nl="$${nl%X}"; \
	set -f; IFS="$$nl"; set -- $$c_objects; set +f; unset IFS; \
	$(BROWSER_SDK_ENV) $(call make_shell_quote,$(TITAN_LUA)) -E scripts/browser_sdk.lua stage-runtime \
	  "$$build_dir" $(call make_shell_quote,$(call BROWSER_NATIVE_PATH,.)) "$$@"; \
	$(BROWSER_SDK_ENV) "$$titanc_bin" --target browser \
	  --output "$$build_dir" --source-first --incremental -j$(TITAN_JOBS) \
	  -X $(call make_shell_quote,$(BROWSER_INSTALL_TREE)/lib/titan-browser/$(TITAN_LIBRARY_VERSION)/libtitan-lpeglabel.a) \
	  $(if $(filter 1,$(TITAN_VERBOSE)),-v,-q) $(BROWSER_STDLIB_ROOTS); \
	$(BROWSER_SDK_ENV) $(call make_shell_quote,$(TITAN_LUA)) -E scripts/browser_sdk.lua finalize "$$build_dir"

# Implementation notes: doc/implementation/build-script-audit.md#installation-and-publication
uninstall-browser-sdk: ## Remove the files browser-sdk installed, keeping other files in their directory
	$(call make_shell_quote,$(TITAN_LUA)) -E scripts/titan_install.lua uninstall-browser-sdk \
	  $(call make_shell_quote,$(BROWSER_INSTALL_TREE)) $(TITAN_LIBRARY_VERSION)

TITAN_BROWSER_TEST_BUILD_DIR ?= $(TITAN_OUTPUT_DIR)/browser-stdlib
TITAN_BROWSER_TEST_SDK := $(BROWSER_INSTALL_TREE)/lib/titan-browser/$(TITAN_LIBRARY_VERSION)
# The engines that run the image, and the shell command that runs it there.
# The Playwright CI cells pass their own engine and spec/browser/playwright-run.mjs --image.
TITAN_BROWSER_TEST_ENGINES ?= node chromium
TITAN_BROWSER_TEST_RUNNER ?= $(BROWSER_RUNNER_SHELL) $(call make_shell_quote,$(TITAN_BROWSER_TEST_SDK)/titan-browser-run)
BROWSER_NATIVE_PARITY ?= $(BROWSER_SDK_ENV) $(call make_shell_quote,$(TITAN_LUA)) -E scripts/check_browser_stdlib.lua inventory \
	  $(call make_shell_quote,$(BROWSER_INSTALL_TREE)/lib/titan/$(TITAN_LIBRARY_VERSION)/titan.a) \
	  $(call make_shell_quote,$(TITAN_BROWSER_TEST_SDK)/titan.a) "$$build_dir/members.md"

# Keep compiler-owned output separate from the image and logs: a cold suite
# leaves browser output initialization and its marker to titanc.
titan-stdlib-browser-test: ## Build one complete browser stdlib image, audit all owners, and run it on each test engine
	+@$(strip $(TITAN_STDLIB_BROWSER_TEST_ROOTS_CHECK)) $(RECURSIVE_WRAPPER_GUARD) $(TITAN_JOBS_CHECK) set -e; \
	unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 TITAN_TARGET; \
	build_dir=$(call make_shell_quote,$(call BROWSER_NATIVE_PATH,$(TITAN_BROWSER_TEST_BUILD_DIR))); \
	compiler_dir="$$build_dir/objects"; \
	mkdir -p "$$build_dir/images"; \
	printf '%s\n' $(TITAN_STDLIB_BROWSER_TEST_ROOTS) > "$$build_dir/roots.txt"; \
	set --; \
	while IFS= read -r owner; do set -- "$$@" "$$owner"; done < "$$build_dir/roots.txt"; \
	echo "Browser stdlib building image: stdlib"; \
	started=$$(date +%s); \
	$(BROWSER_SDK_ENV) TITAN_PATH$(TITAN_LIBRARY_VERSION_SUFFIX)=$(call make_shell_quote,$(TITAN_BROWSER_TEST_SDK)) \
	  $(call make_shell_quote,$(BROWSER_INSTALL_TREE)/bin/titanc$(BROWSER_EXE_SUFFIX)) \
	  $(if $(filter 1,$(TITAN_VERBOSE)),-v,-q) --target browser --test --incremental --no-uv-bootstrap \
	  --tree $(call make_shell_quote,$(call BROWSER_NATIVE_PATH,spec/stdlib/titan)) \
	  --output "$$compiler_dir" --exe "$$build_dir/images/stdlib.mjs" -j$(TITAN_JOBS) \
	  --c-source $(call make_shell_quote,$(call BROWSER_NATIVE_PATH,spec/fixtures/browser_runtime/close.c)) "$$@"; \
	elapsed=$$(($$(date +%s) - $$started)); \
	echo "Browser stdlib image stdlib build_seconds=$$elapsed"; \
	$(BROWSER_SDK_ENV) $(call make_shell_quote,$(TITAN_LUA)) -E scripts/check_browser_stdlib.lua closure \
	  "$$compiler_dir" $(call make_shell_quote,$(TITAN_BROWSER_TEST_SDK)/titan.a) "$$build_dir/images/stdlib.wasm"; \
	$(BROWSER_SDK_ENV) $(call make_shell_quote,$(TITAN_LUA)) -E scripts/check_browser_stdlib.lua imports \
	  entry "$$build_dir/images/stdlib.wasm"; \
	$(BROWSER_NATIVE_PARITY); \
	filter=$(call make_shell_quote_value,TITAN_FILTER); \
	overall=0; \
	for engine in $(TITAN_BROWSER_TEST_ENGINES); do \
	  echo "Browser stdlib engine: $$engine image: stdlib"; \
	  set --; \
	  if test -n "$$filter"; then set -- "--filter=$$filter"; fi; \
	  status=0; \
	  bash scripts/run_browser_stdlib.sh "$$build_dir/stdlib.$$engine.log" "$$build_dir/stdlib.$$engine.stderr.log" \
	    $(TITAN_BROWSER_TEST_RUNNER) \
	    --engine "$$engine" --timeout 300000 --grace 2000 --root "$$build_dir/images" \
	    "$$build_dir/images/stdlib.mjs" -- "$$@" || status=$$?; \
	  if test "$$status" != 0; then \
	    echo "Browser stdlib image stdlib failed under $$engine (status $$status)" >&2; \
	    overall=1; \
	  fi; \
	  $(BROWSER_SDK_ENV) $(call make_shell_quote,$(TITAN_LUA)) -E scripts/check_browser_stdlib.lua output \
	    "$$build_dir/roots.txt" "$$filter" "$$build_dir/stdlib.$$engine.log" || overall=1; \
	done; \
	test "$$overall" = 0
