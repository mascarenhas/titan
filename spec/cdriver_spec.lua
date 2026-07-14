local lfs = require "lfs"

local cdriver = require "c-parser.cdriver"

local function write_file(filename, contents)
    local fd = assert(io.open(filename, "wb"))
    fd:write(contents)
    fd:close()
end

local function tmp_header(contents)
    local filename = os.tmpname() .. ".h"
    write_file(filename, contents)
    return filename
end

local function tmp_dir()
    local dirname = os.tmpname()
    os.remove(dirname)
    assert(lfs.mkdir(dirname))
    return dirname
end

local function mkdir(parent, name)
    local dirname = parent .. "/" .. name
    assert(lfs.mkdir(dirname))
    return dirname
end

local function remove_tree(files, dirs)
    for _, filename in ipairs(files or {}) do
        os.remove(filename)
    end
    for i = #(dirs or {}), 1, -1 do
        lfs.rmdir(dirs[i])
    end
end

local function assert_process_file(filename, options)
    local ffi_types, err, include = cdriver.process_file(filename, options)
    assert(ffi_types, err)
    assert.is_nil(err)
    assert.is_table(include)
    return ffi_types, include
end

describe("C FFI cdriver", function()
    describe("top-level include descriptor", function()
        it("treats absolute paths as quoted includes", function()
            local header = tmp_header("extern int titan_cdriver_absolute(void);\n")

            local _, include = assert_process_file(header)

            assert.equal(header, include.original)
            assert.equal(header, include.resolved)
            assert.equal("quote", include.include_kind)
            assert.equal(header, include.include_name)

            os.remove(header)
        end)

        it("resolves relative headers under source_dir as quoted includes", function()
            local dir = tmp_dir()
            local header = "titan_cdriver_local.h"
            local resolved = dir .. "/" .. header
            write_file(resolved, "extern int titan_cdriver_local(void);\n")

            local _, include = assert_process_file(header, { source_dir = dir })

            assert.equal(header, include.original)
            assert.equal(resolved, include.resolved)
            assert.equal("quote", include.include_kind)
            assert.equal(header, include.include_name)

            os.remove(resolved)
            lfs.rmdir(dir)
        end)

        it("uses angle descriptors for system headers", function()
            local _, include = assert_process_file("stdio.h")

            assert.equal("stdio.h", include.original)
            assert.is_string(include.resolved)
            assert.equal("angle", include.include_kind)
            assert.equal("stdio.h", include.include_name)
        end)

        it("uses angle descriptors for compiler-provided headers", function()
            local _, include = assert_process_file("titan/ffi.h")

            assert.equal("titan/ffi.h", include.original)
            assert.matches("/titan/ffi%.h$", include.resolved)
            assert.equal("angle", include.include_kind)
            assert.equal("titan/ffi.h", include.include_name)
        end)

        it("resolves compiler-provided headers independently of cwd", function()
            local olddir = assert(lfs.currentdir())
            assert(lfs.chdir("/tmp"))
            local ok, err = pcall(function()
                local _, include = assert_process_file("titan/ffi.h")
                assert.matches("/titan/ffi%.h$", include.resolved)
                assert.equal("angle", include.include_kind)
            end)
            assert(lfs.chdir(olddir))
            assert.truthy(ok, err)
        end)
    end)


    describe("configured preprocessor toolchain", function()
        setup(function()
            require("c-parser.cpp").clear_probe_cache()
        end)

        it("uses -I and -D flags for top-level and recursive header parsing", function()
            local root = tmp_dir()
            local incdir = mkdir(root, "include path with spaces")
            local outer = incdir .. "/flags_only.h"
            local inner = incdir .. "/flags_nested.h"
            write_file(inner, "typedef int nested_from_flag_path;\n")
            write_file(outer, [[
#include <flags_nested.h>
#ifdef TITAN_FLAG_BRANCH
typedef int selected_by_flag;
#else
typedef double selected_by_flag;
#endif
]])

            local types, include = assert_process_file("flags_only.h", {
                compiler = { "cc" },
                language_mode = "c99",
                cppflags = { "-I", incdir, "-DTITAN_FLAG_BRANCH=1" },
            })
            assert.same({ "int" }, types.selected_by_flag.def)
            assert.same({ "int" }, types.nested_from_flag_path.def)
            assert.equal(outer, include.resolved)
            assert.equal("angle", include.include_kind)

            remove_tree({ outer, inner }, { incdir, root })
        end)

        it("resolves -iquote headers as quoted includes", function()
            local root = tmp_dir()
            local incdir = mkdir(root, "quote includes")
            local header = incdir .. "/quote_only.h"
            write_file(header, "typedef int titan_quote_only;\n")

            local types, include = assert_process_file("quote_only.h", {
                compiler = { "cc" },
                language_mode = "c99",
                cppflags = { "-iquote", incdir },
            })
            assert.same({ "int" }, types.titan_quote_only.def)
            assert.equal(header, include.resolved)
            assert.equal("quote", include.include_kind)
            assert.equal("quote_only.h", include.include_name)

            remove_tree({ header }, { incdir, root })
        end)

        it("searches user -I directories before Titan's fixed include dirs",
           function()
            local root = tmp_dir()
            local incdir = mkdir(root, "colliding includes")
            local titandir = mkdir(incdir, "titan")
            local header = titandir .. "/ffi.h"
            write_file(header, "typedef int titan_user_header_won;\n")

            local types, include = assert_process_file("titan/ffi.h", {
                compiler = { "cc" },
                language_mode = "c99",
                cppflags = { "-I", incdir },
            })
            assert.same({ "int" }, types.titan_user_header_won.def)
            assert.equal(header, include.resolved)
            assert.equal("angle", include.include_kind)

            remove_tree({ header }, { titandir, incdir, root })
        end)

        it("separates include and macro probes by the complete flag array", function()
            local root = tmp_dir()
            local first = mkdir(root, "first flags")
            local second = mkdir(root, "second flags")
            local first_header = first .. "/cached_config.h"
            local second_header = second .. "/cached_config.h"
            write_file(first_header, [[
#ifdef FIRST_CONFIG
typedef int cached_selection;
#else
typedef float cached_selection;
#endif
]])
            write_file(second_header, [[
#ifdef SECOND_CONFIG
typedef double cached_selection;
#else
typedef float cached_selection;
#endif
]])

            local first_types = assert_process_file("cached_config.h", {
                compiler = "cc",
                language_mode = "c99",
                cppflags = { "-I", first, "-DFIRST_CONFIG=1" },
            })
            assert.same({ "int" }, first_types.cached_selection.def)

            local second_types, include = assert_process_file("cached_config.h", {
                compiler = { "cc" },
                language_mode = "c99",
                cppflags = { "-I", second, "-DSECOND_CONFIG=1" },
            })
            assert.same({ "double" }, second_types.cached_selection.def)
            assert.equal(second_header, include.resolved)

            remove_tree({ first_header, second_header }, { first, second, root })
        end)

        it("separates predefined macro probes by C language mode", function()
            local header = tmp_header([[
#if __STDC_VERSION__ >= 201112L
typedef int language_selection;
#else
typedef double language_selection;
#endif
]])

            local c99_types = assert_process_file(header, {
                compiler = "cc",
                language_mode = "c99",
                cppflags = {},
            })
            assert.same({ "double" }, c99_types.language_selection.def)

            local c11_types = assert_process_file(header, {
                compiler = "cc",
                language_mode = "c11",
                cppflags = {},
            })
            assert.same({ "int" }, c11_types.language_selection.def)

            os.remove(header)
        end)

        it("orders CPP flags before Titan's fixed language mode", function()
            local header = tmp_header([[
#if __STDC_VERSION__ >= 201112L
typedef int wrong_order_selection;
#else
typedef double fixed_mode_selection;
#endif
]])

            local types = assert_process_file(header, {
                compiler = "cc",
                language_mode = "c99",
                cppflags = { "-std=c11" },
            })
            assert.same({ "double" }, types.fixed_mode_selection.def)
            assert.is_nil(types.wrong_order_selection)

            os.remove(header)
        end)

        it("separates probes by compiler command and quotes compiler paths", function()
            local root = tmp_dir()
            local bindir = mkdir(root, "compiler path")
            local compiler = bindir .. "/titan test cc"
            local header = bindir .. "/compiler_config.h"
            local quoted_bindir = assert(cdriver.shell_quote(bindir))
            write_file(compiler, "#!/bin/sh\nexec cc -I" .. quoted_bindir
                .. " -DTITAN_WRAPPER_CC=1 \"$@\"\n")
            local quoted_compiler = assert(cdriver.shell_quote(compiler))
            local chmod_ok = os.execute("chmod +x " .. quoted_compiler)
            assert.truthy(chmod_ok)
            write_file(header, [[
#ifdef TITAN_WRAPPER_CC
typedef int compiler_selection;
#else
typedef double compiler_selection;
#endif
]])

            local wrapped, include = assert_process_file("compiler_config.h", {
                compiler = quoted_compiler,
                language_mode = "c99",
                cppflags = {},
            })
            assert.same({ "int" }, wrapped.compiler_selection.def)
            assert.equal(header, include.resolved)

            local plain = assert_process_file(header, {
                compiler = { "cc" },
                language_mode = "c99",
                cppflags = {},
            })
            assert.same({ "double" }, plain.compiler_selection.def)

            remove_tree({ header, compiler }, { bindir, root })
        end)

        it("preserves the compiler's CPATH include search", function()
            local root = tmp_dir()
            local incdir = mkdir(root, "cpath includes")
            local header = incdir .. "/cpath_only.h"
            write_file(header, "typedef int found_through_cpath;\n")

            local types, include = assert_process_file("cpath_only.h", {
                compiler = { "env", "CPATH=" .. incdir, "cc" },
                language_mode = "c99",
                cppflags = {},
            })
            assert.same({ "int" }, types.found_through_cpath.def)
            assert.equal(header, include.resolved)

            remove_tree({ header }, { incdir, root })
        end)

        it("refreshes fixed FFI includes after the driver Lua path changes",
           function()
            local driver = require "titan-compiler.driver"
            local checker = require "titan-compiler.checker"
            local parser = require "titan-compiler.parser"
            local root = tmp_dir()
            local header = root .. "/alternate_lua_path.h"
            local old_lua_path = driver.LUA_SOURCE_PATH
            write_file(header, "typedef int alternate_lua_path_marker;\n")

            local ok, err = pcall(function()
                driver.LUA_SOURCE_PATH = root
                driver.configure_foreign_c()
                local code = [[
                    local alt = foreign import "alternate_lua_path.h"
                    function size(): integer
                        return alt.alternate_lua_path_marker.sizeof
                            as integer
                    end
                ]]
                local ast = assert(parser.parse("alternate.titan", code))
                local _, errors = checker.check(
                    "alternate", ast, code, "alternate.titan")
                assert.equal(0, #errors, table.concat(errors, "\n"))
            end)
            driver.LUA_SOURCE_PATH = old_lua_path
            driver.configure_foreign_c()
            remove_tree({ header }, { root })
            assert.truthy(ok, err)
        end)

        it("rejects unparsed or malformed configuration", function()
            local header = tmp_header("typedef int never_reached;\n")

            local types, err = cdriver.process_file(header, {
                cppflags = "-I/tmp/include",
            })
            assert.is_nil(types)
            assert.matches("cppflags must be a parsed argument array", err)

            types, err = cdriver.process_file(header, {
                compiler = "cc 'unfinished",
                cppflags = {},
            })
            assert.is_nil(types)
            assert.matches("unterminated single quote", err)

            types, err = cdriver.process_file(header, {
                compiler = "cc",
                language_mode = "c99; touch /tmp/nope",
                cppflags = {},
            })
            assert.is_nil(types)
            assert.matches("invalid C language mode", err)

            os.remove(header)
        end)
    end)
end)
