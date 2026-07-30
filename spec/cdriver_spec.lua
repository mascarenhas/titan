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

    it("retains suffixes on unnamed parameter declarators", function()
        local header = tmp_header([[
            extern int named_array(int value[7]);
            extern int unnamed_array(int [7]);
            extern int named_callback(int (*callback)(double));
            extern int unnamed_callback(int (*)(double));
            extern int named_array_pointer(int (*values)[7]);
            extern int unnamed_array_pointer(int (*)[7]);
        ]])

        local ffi_types = assert_process_file(header)
        os.remove(header)

        for _, pair in ipairs({
            {"named_array", "unnamed_array"},
            {"named_callback", "unnamed_callback"},
            {"named_array_pointer", "unnamed_array_pointer"},
        }) do
            local named = ffi_types[pair[1]].params[1]
            local unnamed = ffi_types[pair[2]].params[1]
            assert.same(named._declarator_ops, unnamed._declarator_ops)
            assert.same(named.type, unnamed.type)
        end
        assert.equal(
            "functionptr",
            ffi_types.unnamed_callback.params[1].type)
        assert.same(
            {{idx = 7}, "*"},
            ffi_types.unnamed_array_pointer.params[1]._declarator_ops)
    end)

    it("publishes completed typedef-array declarators in either order",
    function()
        local header = tmp_header([[
            typedef int cdriver_array[];

            extern cdriver_array cdriver_alias_first;
            extern int cdriver_alias_first[7];
            extern int cdriver_direct_first[7];
            extern cdriver_array cdriver_direct_first;

            extern cdriver_array *cdriver_nested_alias_first;
            extern int (*cdriver_nested_alias_first)[7];
            extern int (*cdriver_nested_direct_first)[7];
            extern cdriver_array *cdriver_nested_direct_first;

            extern void cdriver_function_alias_first(
                cdriver_array *values);
            extern void cdriver_function_alias_first(
                int (*values)[7]);
            extern void cdriver_function_direct_first(
                int (*values)[7]);
            extern void cdriver_function_direct_first(
                cdriver_array *values);
        ]])

        local ffi_types = assert_process_file(header)
        os.remove(header)

        for _, name in ipairs({
            "cdriver_alias_first",
            "cdriver_direct_first",
        }) do
            assert.same(
                {{idx = 7}},
                ffi_types[name]._declarator_ops)
        end
        for _, name in ipairs({
            "cdriver_nested_alias_first",
            "cdriver_nested_direct_first",
        }) do
            assert.same(
                {{idx = 7}, "*"},
                ffi_types[name]._declarator_ops)
        end
        for _, name in ipairs({
            "cdriver_function_alias_first",
            "cdriver_function_direct_first",
        }) do
            assert.same(
                {{idx = 7}, "*"},
                ffi_types[name].params[1]._declarator_ops)
        end
    end)

    it("uses active same-name type macros but suppresses macro-only aliases",
    function()
        local header = tmp_header([[
            typedef double cdriver_replacement_type;
            typedef int cdriver_public_type;
            typedef signed char cdriver_self_type;
            #define cdriver_public_type cdriver_replacement_type
            #define cdriver_macro_only_type cdriver_replacement_type
            #define cdriver_self_type cdriver_self_type
        ]])

        local ffi_types = assert_process_file(header)
        os.remove(header)

        assert.equal("typedef", ffi_types.cdriver_replacement_type.type)
        assert.equal("typedef", ffi_types.cdriver_public_type.type)
        assert.same({"double"}, ffi_types.cdriver_public_type.def)
        assert.equal("typedef", ffi_types.cdriver_self_type.type)
        assert.same(
            {"signed", "char"}, ffi_types.cdriver_self_type.def)
        assert.is_nil(ffi_types.cdriver_macro_only_type)
        local occurrences = {}
        for _, item in ipairs(ffi_types) do
            occurrences[item.name] = (occurrences[item.name] or 0) + 1
        end
        assert.equal(1, occurrences.cdriver_replacement_type)
        assert.equal(2, occurrences.cdriver_public_type)
        assert.equal(1, occurrences.cdriver_self_type)
        assert.is_nil(occurrences.cdriver_macro_only_type)
    end)

    it("records final field projections and every touched macro name",
    function()
        local header = tmp_header([[
            #define cdriver_projection implementation.member
            #define cdriver_removed implementation.member
            #undef cdriver_removed
            #define cdriver_replaced implementation.member
            #undef cdriver_replaced
            #define cdriver_replaced 17
        ]])

        local ffi_types = assert_process_file(header)
        os.remove(header)

        assert.same(
            { "implementation", "member" },
            ffi_types.field_macro_paths.cdriver_projection.path)
        assert.is_nil(ffi_types.field_macro_paths.cdriver_removed)
        assert.is_nil(ffi_types.field_macro_paths.cdriver_replaced)
        assert.is_true(ffi_types.macro_changes.cdriver_projection)
        assert.is_true(ffi_types.macro_changes.cdriver_removed)
        assert.is_true(ffi_types.macro_changes.cdriver_replaced)
        assert.same(
            { "implementation", ".", "member" },
            ffi_types.macro_definitions.cdriver_projection)
        assert.is_nil(ffi_types.macro_definitions.cdriver_removed)
        assert.same({ "17" },
            ffi_types.macro_definitions.cdriver_replaced)
    end)


    describe("configured preprocessor toolchain", function()
        setup(function()
            require("c-parser.cpp").clear_probe_cache()
        end)

        it("imports libuv X-macro error enumerators under production flags", function()
            local types = assert_process_file("uv.h", {
                compiler = { os.getenv("CC") or "cc" },
                language_mode = "c99",
                cppflags = {
                    "-Ilibuv-v1.52.1/include",
                    "-D_GNU_SOURCE",
                },
                compiler_include_dirs = {
                    "titan-runtime",
                    "lua-5.5.0/src",
                },
            })

            local function enum_value(name)
                for _, item in ipairs(assert(types[name]).values) do
                    if item.name == name then
                        return item.value
                    end
                end
            end

            assert.equal("enum", assert(types.UV_EIO).type)
            local eio = assert(enum_value("UV_EIO"))
            local canceled = assert(enum_value("UV_ECANCELED"))
            -- POSIX errno numbers are target-specific; libuv's portable
            -- contract is that every error value is negative.
            assert.is_true(eio < 0)
            assert.is_true(canceled < 0)
            assert.equal(-4095, enum_value("UV_EOF"))
            assert.equal("typedef", assert(types.uv_errno_t).type)
        end)

        it("publishes compile-flag aliases to renamed C functions", function()
            local types = assert_process_file("lua.h", {
                compiler = { os.getenv("CC") or "cc" },
                language_mode = "c99",
                language_flag = false,
                compile_flags = {
                    "--std=c99",
                    "-Dlua_newuserdatauv=titan_uv_test_newuserdatauv",
                },
                cppflags = {},
                compiler_include_dirs = {
                    "titan-runtime",
                    "lua-5.5.0/src",
                },
            })

            local alias = assert(types.lua_newuserdatauv)
            local target = assert(types.titan_uv_test_newuserdatauv)
            assert.equal("function", target.type)
            assert.equal("function", alias.type)
            assert.equal("lua_newuserdatauv", alias.name)
            assert.equal(target.ret, alias.ret)
            assert.equal(target.params, alias.params)
            assert.equal(target.paramnames, alias.paramnames)
            assert.equal(target.paramnames_state, alias.paramnames_state)
            assert.equal(target.vararg, alias.vararg)
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
            local original_lua_path = old_lua_path
            if original_lua_path:sub(1, 1) ~= "/" then
                original_lua_path =
                    assert(lfs.currentdir()) .. "/" .. original_lua_path
            end
            local files = { header, root .. "/lua.h" }
            write_file(header, "typedef int alternate_lua_path_marker;\n")
            write_file(root .. "/lua.h", [[
typedef long long lua_Integer;
typedef double lua_Number;
]])
            -- The checker baseline now compiles the exact fixed generated-C
            -- prefix. Keep this target-profile fixture's alternate `lua.h`
            -- while making the remaining real internal headers available
            -- through the same selected Lua source directory.
            for _, name in ipairs({
                "luaconf.h", "lauxlib.h", "llimits.h",
                "lstate.h", "lgc.h",
                "ltable.h", "ltm.h", "lfunc.h", "lstring.h",
                "lvm.h", "lobject.h", "ldo.h",
            }) do
                local wrapper = root .. "/" .. name
                files[#files + 1] = wrapper
                write_file(wrapper,
                    '#include "' .. original_lua_path
                        .. "/" .. name .. '"\n')
            end

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
            remove_tree(files, { root })
            assert.truthy(ok, err)
        end)

        it("acquires Lua numeric spellings and target macros under exact flags",
           function()
            local inputs = assert(cdriver.target_profile_inputs({
                compiler = { os.getenv("CC") or "cc" },
                language_mode = "c99",
                language_flag = false,
                compile_flags = {
                    "--std=c99",
                    "-funsigned-char",
                    "-DTITAN_PROFILE_FLAG=23",
                },
                cppflags = {},
                compiler_include_dirs = {
                    "titan-runtime",
                    "lua-5.5.0/src",
                },
            }))

            assert.equal("long long", inputs.lua_integer)
            assert.equal("double", inputs.lua_number)
            assert.is_string(inputs.size_t)
            assert.is_string(inputs.ptrdiff_t)
            assert.is_table(inputs.signed_minima)
            for _, spelling in ipairs({
                "signed char", "short", "int", "long", "long long",
            }) do
                assert.is_table(inputs.signed_minima[spelling])
            end
            assert.same({ "1" }, inputs.macros.__CHAR_UNSIGNED__)
            assert.same({ "23" }, inputs.macros.TITAN_PROFILE_FLAG)
            assert.same({
                "titan-runtime",
                "lua-5.5.0/src",
            }, inputs.fixed_include_dirs)
            assert.equal("lua.h", inputs.lua_header.original)
            assert.matches("/lua%.h$", inputs.lua_header.resolved)

            local profile = assert(
                require("titan-compiler.csemantics").build_profile(inputs))
            assert.is_false(
                profile.integers[profile.size_t].type.signed)
            assert.is_true(
                profile.integers[profile.ptrdiff_t].type.signed)
        end)

        it("rebuilds profiles and resolver probe services after reconfiguration",
           function()
            local driver = require "titan-compiler.driver"
            local old_cflags = driver.CFLAGS
            local context = driver.new_resolver_context()
            local first = assert(driver.get_probe_service(context))
            local first_configuration =
                driver.FOREIGN_C_CONFIGURATION_ID

            local ok, err = pcall(function()
                driver.CFLAGS = old_cflags .. " -funsigned-char"
                driver.configure_foreign_c()
                assert.is_true(
                    driver.FOREIGN_C_CONFIGURATION_ID >
                    first_configuration)
                assert.is_false(driver.TARGET_PROFILE.char_signed)

                local second = assert(driver.get_probe_service(context))
                assert.not_equal(first, second)
                assert.is_true(first.closed)
                assert.equal(driver.TARGET_PROFILE.identity,
                    second.profile_identity)
            end)
            driver.close_resolver_context(context)
            driver.CFLAGS = old_cflags
            driver.configure_foreign_c()
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
