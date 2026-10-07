rockspec_format = "3.0"
package = "titan"
version = "0.6.0-1"
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
   command = "bash spec/support/run_rock_tests.sh",
   flags = { "--prefix=$(LUA_DIR)", "--make=$(MAKE)" }
}
hooks = {
   platforms = {
      windows = {
         post_install = [["$(MAKE)" -f Makefile.win rock-post-install PREFIX="$(LUA_DIR)" ROCKS_TREE="$(SCRIPTS_DIR)/.." ROCK_TITANC="$(BINDIR)/titanc" ROCK_LUA="$(LUA)" ROCK_CFLAGS="$(CFLAGS)" CC="$(CC)" AR="$(AR)" RANLIB="$(RANLIB)"]]
      }
   },
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
   platforms = {
      windows = {
         makefile = "Makefile.win"
      }
   },
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
      ["titan-compiler.maybe3"] = "titan-compiler/maybe3.lua",
      ["titan-compiler.cdeclarator"] = "titan-compiler/cdeclarator.lua",
      ["titan-compiler.cpreamble"] = "titan-compiler/cpreamble.lua",
      ["titan-compiler.cprobe"] = "titan-compiler/cprobe.lua",
      ["titan-compiler.cprobe_cache"] = "titan-compiler/cprobe_cache.lua",
      ["titan-compiler.csemantics"] = "titan-compiler/csemantics.lua",
      ["titan-compiler.sha256"] = "titan-compiler/sha256.lua",
      ["titan-compiler.graphcodec"] = "titan-compiler/graphcodec.lua",
      ["titan-compiler.declarationschemas"] = "titan-compiler/declarationschemas.lua",
      ["titan-compiler.documentation"] = "titan-compiler/documentation.lua",
      ["titan-compiler.completion"] = "titan-compiler/completion.lua",
      ["titan-compiler.checker.completion"] = "titan-compiler/checker/completion.lua",
      ["titan-compiler.projectcache"] = "titan-compiler/projectcache.lua",
      ["titan-compiler.objectmetadata"] = "titan-compiler/objectmetadata.lua",
      ["titan-compiler.cacheadapter"] = "titan-compiler/cacheadapter.lua",
      ["titan-compiler.foreigncache"] = "titan-compiler/foreigncache.lua",
      ["titan-compiler.cdefinitioncache"] = "titan-compiler/cdefinitioncache.lua",
      ["titan-compiler.ffiheaders"] = "titan-compiler/ffiheaders.lua",
      ["titan-compiler.checker"] = "titan-compiler/checker.lua",
      ["titan-compiler.binarycompat"] = "titan-compiler/binarycompat.lua",
      ["titan-compiler.checker.binary_usage"] = "titan-compiler/checker/binary_usage.lua",
      ["titan-compiler.checker.calls"] = "titan-compiler/checker/calls.lua",
      ["titan-compiler.checker.common"] = "titan-compiler/checker/common.lua",
      ["titan-compiler.checker.core"] = "titan-compiler/checker/core.lua",
      ["titan-compiler.checker.c_types"] = "titan-compiler/checker/c_types.lua",
      ["titan-compiler.checker.declarations"] = "titan-compiler/checker/declarations.lua",
      ["titan-compiler.checker.entry"] = "titan-compiler/checker/entry.lua",
      ["titan-compiler.checker.expression_lists"] = "titan-compiler/checker/expression_lists.lua",
      ["titan-compiler.checker.expressions"] = "titan-compiler/checker/expressions.lua",
      ["titan-compiler.checker.imports"] = "titan-compiler/checker/imports.lua",
      ["titan-compiler.checker.interfaces"] = "titan-compiler/checker/interfaces.lua",
      ["titan-compiler.checker.linear"] = "titan-compiler/checker/linear.lua",
      ["titan-compiler.checker.lowering"] = "titan-compiler/checker/lowering.lua",
      ["titan-compiler.checker.statements"] = "titan-compiler/checker/statements.lua",
      ["titan-compiler.checker.type_syntax"] = "titan-compiler/checker/type_syntax.lua",
      ["titan-compiler.checker.variables"] = "titan-compiler/checker/variables.lua",
      ["titan-compiler.coder"] = "titan-compiler/coder.lua",
      ["titan-compiler.coder.binary"] = "titan-compiler/coder/binary.lua",
      ["titan-compiler.coder.calls"] = "titan-compiler/coder/calls.lua",
      ["titan-compiler.coder.immediate"] = "titan-compiler/coder/immediate.lua",
      ["titan-compiler.coder.core"] = "titan-compiler/coder/core.lua",
      ["titan-compiler.coder.declarations"] = "titan-compiler/coder/declarations.lua",
      ["titan-compiler.coder.expressions"] = "titan-compiler/coder/expressions.lua",
      ["titan-compiler.coder.flow"] = "titan-compiler/coder/flow.lua",
      ["titan-compiler.coder.generate"] = "titan-compiler/coder/generate.lua",
      ["titan-compiler.coder.interfaces"] = "titan-compiler/coder/interfaces.lua",
      ["titan-compiler.coder.module"] = "titan-compiler/coder/module.lua",
      ["titan-compiler.coder.names"] = "titan-compiler/coder/names.lua",
      ["titan-compiler.coder.numerics"] = "titan-compiler/coder/numerics.lua",
      ["titan-compiler.coder.statements"] = "titan-compiler/coder/statements.lua",
      ["titan-compiler.coder.values"] = "titan-compiler/coder/values.lua",
      ["titan-compiler.coder.nominal"] = "titan-compiler/coder/nominal.lua",
      ["titan-compiler.coder.nativeoption"] = "titan-compiler/coder/nativeoption.lua",
      ["titan-compiler.coder.nominalcalls"] = "titan-compiler/coder/nominalcalls.lua",
      ["titan-compiler.coder.native_record_fields"] = "titan-compiler/coder/native_record_fields.lua",
      ["titan-compiler.checker.native_record_fields"] = "titan-compiler/checker/native_record_fields.lua",
      ["titan-compiler.nominallayout"] = "titan-compiler/nominallayout.lua",
      ["titan-compiler.driver"] = "titan-compiler/driver.lua",
      ["titan-compiler.foreigntypes"] = "titan-compiler/foreigntypes.lua",
      ["titan-compiler.io"] = "titan-compiler/io.lua",
      ["titan-compiler.platform"] = "titan-compiler/platform.lua",
      ["titan-compiler.path"] = "titan-compiler/path.lua",
            ["titan-compiler.windows_path"] = "titan-compiler/windows_path.lua",
      ["titan-compiler.windows_publication"] = "titan-compiler/windows_publication.lua",
      ["titan-compiler.test_runner"] = "titan-compiler/test_runner.lua",
      ["titan-compiler.lexer"] = "titan-compiler/lexer.lua",
      ["titan-compiler.location"] = "titan-compiler/location.lua",
      ["titan-compiler.typedecl"] = "titan-compiler/typedecl.lua",
      ["titan-compiler.parser"] = "titan-compiler/parser.lua",
      ["titan-compiler.sourceinterface"] = "titan-compiler/sourceinterface.lua",
      ["titan-compiler.staticmetadata"] = "titan-compiler/staticmetadata.lua",
      ["titan-compiler.symtab"] = "titan-compiler/symtab.lua",
      ["titan-compiler.syntax_errors"] = "titan-compiler/syntax_errors.lua",
      ["titan-compiler.types"] = "titan-compiler/types.lua",
      ["titan-compiler.util"] = "titan-compiler/util.lua",
      ["titan-compiler.version"] = "titan-compiler/version.lua",
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
