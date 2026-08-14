# Titan compiler checker/coder refactor

The two main Titan compiler modules, titan-compiler/checker.lua and titan-compiler/coder.lua, have gotten
unwieldy, at over 15Kloc each.

They should be refactored so they are broken up into smaller modules, organized under new `titan-compiler/checker/`
and `titan-compiler/coder/` folders.

The refactor should use this approach (replicated for both checker.lua and coder.lua):

Use a script to extract the list of top-level declarations, classifying them in six buckets:

0. other modules imported with `require`
1. local variables
2. local functions (some variable declarations are actually forward declarations for mutually recursive sets of functions)
3. module variables (directly under the `checker`/`coder` tables)
4. module functions directly under `checker`/`coder` tables
5. module functions under subtables of `checker` (line the `checker._generic` subtable, not sure there are others)

For each function declaration, the script should extract the line span of the function text.

A second analysis pass analyses each function in isolation to enrich this metadata with the the list of symbols it references
from this top-level scope.

A separate analysis goes through the rest of the compiler code, looking for modules that import these two main modules, and yielding a
list of symbols accessed by clients. Ignore tests for this analysis.

This will give for each module a graph of declarations and their dependencies. Use this information to be able to break up the modules. A possible structure is a top `{checker/coder}.core` module with shared variables and leaf functions, with a middle layer of modules that implement slices of functionality (possible examples for `checker`: generic type checking, generic type inference, coercion insertion,
overall type checking, but this should be informed by the analysis, do not take this as an imposed structure). The bottom layer
has a façade module with the minimum public API the clients of the module actually use. This façade remain as `titan-compiler/checker.lua`
and `titan-compiler/coder.lua`, respectively, so changes in non-test clients are minimal. This is not an issue with the Lua module system,
as you can have `require "titan-compiler.checker" loading the `titan-compiler/checker.lua` façade and `require "titan-compiler.checker.core"`
loading `titan-compiler/checker/core.lua`, for example.

Tests were ignored in the use analysis because they can always import modules from the other layers.

It is fine for the outcome of the process to be 0 local declarations in each module, apart from the references to other imported modules.

When implementing the actual breaking up of the modules, do not move whole chunks of the module at once. Do it in small chunks, carefully verifying the code in its new home versus the previous code looking for unintended semantic changes. Use a staging area where each file is a snippet of a new module, with a separate file recording the order the snippets should be assembled, then create the module by running a script that assembles the snippets with blank lines between each snippet, writing the module to its final source location.
