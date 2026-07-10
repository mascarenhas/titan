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
   type = "busted"
}
hooks = {
   post_install = [[set -e
      titan_libdir="$(PREFIX)/../../../../lua/$(LUA_VERSION)/titan"
      for module in coroutine uv timer; do
         test -f "$titan_libdir/stdlib_0_11/$module.so"
         rm -f "$titan_libdir/$module.so"
         ln -s "stdlib_0_11/$module.so" "$titan_libdir/$module.so"
      done]]
}
build = {
   type = "make",
   build_target = "rock-build",
   install_pass = false,
   build_variables = {
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
      ["titan-compiler.checker"] = "titan-compiler/checker.lua",
      ["titan-compiler.coder"] = "titan-compiler/coder.lua",
      ["titan-compiler.driver"] = "titan-compiler/driver.lua",
      ["titan-compiler.foreigntypes"] = "titan-compiler/foreigntypes.lua",
      ["titan-compiler.lexer"] = "titan-compiler/lexer.lua",
      ["titan-compiler.location"] = "titan-compiler/location.lua",
      ["titan-compiler.typedecl"] = "titan-compiler/typedecl.lua",
      ["titan-compiler.parser"] = "titan-compiler/parser.lua",
      ["titan-compiler.pretty"] = "titan-compiler/pretty.lua",
      ["titan-compiler.symtab"] = "titan-compiler/symtab.lua",
      ["titan-compiler.syntax_errors"] = "titan-compiler/syntax_errors.lua",
      ["titan-compiler.types"] = "titan-compiler/types.lua",
      ["titan-compiler.util"] = "titan-compiler/util.lua",
      ["typed"] = "typed.lua",
      ["c-parser.c99"] = "c-parser/c99.lua",
      ["c-parser.cdriver"] = "c-parser/cdriver.lua",
      ["c-parser.cpp"] = "c-parser/cpp.lua",
      ["c-parser.ctypes"] = "c-parser/ctypes.lua",
      ["c-parser.cdefines"] = "c-parser/cdefines.lua"
      },
      lib = {
         ["titan"] = "titan.so",
         ["titan.stdlib_0_11.coroutine"] = "coroutine.so",
         ["titan.coroutine"] = "coroutine.so",
         ["titan.stdlib_0_11.uv"] = "uv.so",
         ["titan.uv"] = "uv.so",
         ["titan.stdlib_0_11.timer"] = "timer.so",
         ["titan.timer"] = "timer.so"
      },
      bin = {
         "titanc"
      },
      conf = {
         "THIRD_PARTY_NOTICES.md"
      }
   }
}
