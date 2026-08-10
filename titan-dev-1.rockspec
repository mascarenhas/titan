rockspec_format = "3.0"
package = "titan"
version = "dev-1"
source = {
   url = "git+https://github.com/titan-lang/titan"
}
description = {
   summary = "Initial prototype of the Titan compiler",
   detailed = [[
      Initial prototype of the Titan compiler.
      This is a proof-of-concept, implementing a subset of
      the Titan language.
   ]],
   homepage = "http://github.com/titan-lang/titan",
   issues_url = "https://github.com/titan-lang/titan/issues",
   labels = { "compiler", "lua", "language" },
   license = "MIT"
}
dependencies = {
   "lua ~> 5.5",
   -- The compiler's parser still uses the separately installed Lua module.
   -- titan.peg embeds its own private, namespaced LPegLabel engine in the
   -- combined standard-library provider and does not load this C module.
   "lpeglabel >= 1.5.0",
   "inspect >= 3.1.0",
   "argparse >= 0.5.0",
   "luafilesystem >= 1.7.0"
}
test_dependencies = {
   "busted >= 2.0",
   "cluacov >= 0.1"
}
test = {
   type = "command",
   command = "bash spec/support/run_rock_tests.sh"
}
hooks = {
   post_install = [[set -e
      unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5
      rocks_tree="$(SCRIPTS_DIR)/.."
      rocks_tree="$(CDPATH= cd "$rocks_tree" && pwd -P)"
      $(MAKE) rock-post-install \
         PREFIX="$(LUA_DIR)" \
         ROCKS_TREE="$rocks_tree" \
         ROCK_TITANC="$(SCRIPTS_DIR)/titanc" \
         ROCK_LUA="$(LUA_DIR)/bin/lua" \
         ROCK_LUA_INCDIR="$(LUA_INCDIR)" \
         ROCK_CFLAGS="$(CFLAGS)" \
         ROCK_LD="$(LD)" \
         ROCK_LIBFLAG="$(LIBFLAG)" \
         STDLIB_USE_INSTALLED_RUNTIME=1 \
         CC="$(CC)" AR="$(AR)" RANLIB="$(RANLIB)"]]
}
build = {
   type = "make",
   -- This remains a source-only installation flow. The target builds the C
   -- runtime and, because ROCKS_TREE is set here, stages the compiler SDK
   -- before LuaRocks deploys the compiler modules. The paired stdlib provider
   -- is deliberately deferred to post_install so it is compiled by the
   -- deployed titanc.
   build_target = "titan",
   install_pass = false,
   build_variables = {
      PREFIX = "$(LUA_DIR)",
      ROCKS_TREE = "$(SCRIPTS_DIR)/..",
      AR = "$(AR)",
      RANLIB = "$(RANLIB)",
      ROCK_LUA_INCDIR = "$(LUA_INCDIR)",
      ROCK_CFLAGS = "$(CFLAGS)",
      ROCK_LD = "$(LD)",
      ROCK_LIBFLAG = "$(LIBFLAG)"
   },
   copy_directories = {
      "doc",
      "LICENSES"
   },
   install = {
      lua = {
      ["titan-compiler.ast"] = "titan-compiler/ast.lua",
      ["titan-compiler.cdeclarator"] = "titan-compiler/cdeclarator.lua",
      ["titan-compiler.cpreamble"] = "titan-compiler/cpreamble.lua",
      ["titan-compiler.cprobe"] = "titan-compiler/cprobe.lua",
      ["titan-compiler.csemantics"] = "titan-compiler/csemantics.lua",
      ["titan-compiler.checker"] = "titan-compiler/checker.lua",
      ["titan-compiler.coder"] = "titan-compiler/coder.lua",
      ["titan-compiler.driver"] = "titan-compiler/driver.lua",
      ["titan-compiler.foreigntypes"] = "titan-compiler/foreigntypes.lua",
      ["titan-compiler.test_runner"] = "titan-compiler/test_runner.lua",
      ["titan-compiler.lexer"] = "titan-compiler/lexer.lua",
      ["titan-compiler.location"] = "titan-compiler/location.lua",
      ["titan-compiler.typedecl"] = "titan-compiler/typedecl.lua",
      ["titan-compiler.parser"] = "titan-compiler/parser.lua",
      ["titan-compiler.pretty"] = "titan-compiler/pretty.lua",
      ["titan-compiler.staticmetadata"] = "titan-compiler/staticmetadata.lua",
      ["titan-compiler.symtab"] = "titan-compiler/symtab.lua",
      ["titan-compiler.syntax_errors"] = "titan-compiler/syntax_errors.lua",
      ["titan-compiler.types"] = "titan-compiler/types.lua",
      ["titan-compiler.util"] = "titan-compiler/util.lua",
      ["c-parser.typed"] = "c-parser/typed.lua",
      ["c-parser.c99"] = "c-parser/c99.lua",
      ["c-parser.cdriver"] = "c-parser/cdriver.lua",
      ["c-parser.cpp"] = "c-parser/cpp.lua",
      ["c-parser.ctypes"] = "c-parser/ctypes.lua",
      ["c-parser.cdefines"] = "c-parser/cdefines.lua"
      },
      bin = {
         "titanc"
      },
      conf = {
         "THIRD_PARTY_NOTICES.md"
      }
   }
}
