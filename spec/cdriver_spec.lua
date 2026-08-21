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
    local ffi_types, err, include, context =
        cdriver.process_file(filename, options)
    assert(ffi_types, err)
    assert.is_nil(err)
    assert.is_table(include)
    return ffi_types, include, context
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

    describe("header dependency identity", function()
        it("reports exact direct and transitive bytes parsed", function()
            local root = tmp_dir()
            local outer = root .. "/outer.h"
            local nested = root .. "/nested.h"
            local outer_contents =
                '#include "nested.h"\nextern int titan_outer(void);\n'
            local first_nested = "typedef int titan_nested_value;\n"
            write_file(outer, outer_contents)
            write_file(nested, first_nested)

            local _, include, context = assert_process_file(
                "outer.h", { source_dir = root })
            assert.same({
                { kind = "file", path = outer,
                  identity = assert(cdriver.header_input_identity(
                      "file", outer)) },
                { kind = "file", path = nested,
                  identity = assert(cdriver.header_input_identity(
                      "file", nested)) },
            }, include.c_header_dependencies)
            assert.equal(
                include.c_header_dependencies,
                context.c_header_dependencies)
            assert.same({
                { kind = "search", path = outer,
                  identity = assert(cdriver.header_input_identity(
                      "search", outer)) },
                { kind = "search", path = nested,
                  identity = assert(cdriver.header_input_identity(
                      "search", nested)) },
            }, include.c_header_search_inputs)

            local second_nested = "typedef long titan_nested_value;\n"
            write_file(nested, second_nested)
            local _, changed = assert_process_file(
                "outer.h", { source_dir = root })
            assert.equal(
                include.c_header_dependencies[1].identity,
                changed.c_header_dependencies[1].identity)
            assert.equal(
                assert(cdriver.header_input_identity("file", nested)),
                changed.c_header_dependencies[2].identity)
            assert.not_equal(
                include.c_header_dependencies[2].identity,
                changed.c_header_dependencies[2].identity)

            remove_tree({ outer, nested }, { root })
        end)

        it("records missing earlier candidates so additions shadow safely",
        function()
            local root = tmp_dir()
            local source = mkdir(root, "source")
            local early = mkdir(root, "early")
            local late = mkdir(root, "late")
            local outer = source .. "/outer.h"
            local early_header = early .. "/selected.h"
            local late_header = late .. "/selected.h"
            write_file(outer, "#include <selected.h>\n")
            write_file(late_header,
                "typedef int titan_selected_header_value;\n")
            local options = {
                source_dir = source,
                compiler_include_dirs = {},
                cppflags = { "-I", early, "-I", late },
            }

            local _, first = assert_process_file("outer.h", options)
            assert.same({
                { kind = "search", path = outer,
                  identity = assert(cdriver.header_input_identity(
                      "search", outer)) },
                { kind = "search", path = early_header,
                  identity = assert(cdriver.header_input_identity(
                      "search", early_header)) },
                { kind = "search", path = late_header,
                  identity = assert(cdriver.header_input_identity(
                      "search", late_header)) },
            }, first.c_header_search_inputs)
            assert.equal(late_header,
                first.c_header_dependencies[2].path)

            write_file(early_header,
                "typedef long titan_selected_header_value;\n")
            local _, shadowed = assert_process_file("outer.h", options)
            assert.equal(early_header,
                shadowed.c_header_dependencies[2].path)
            assert.equal(2, #shadowed.c_header_search_inputs)
            assert.not_equal(
                first.c_header_search_inputs[2].identity,
                shadowed.c_header_search_inputs[2].identity)

            remove_tree(
                { outer, early_header, late_header },
                { source, early, late, root })
        end)

        it("preserves symlink traversal when absolutizing include paths",
        function()
            local root = tmp_dir()
            local source = mkdir(root, "source")
            local first = mkdir(root, "first")
            local first_nested = mkdir(first, "nested")
            local first_include = mkdir(first, "include")
            local second = mkdir(root, "second")
            local second_nested = mkdir(second, "nested")
            local second_include = mkdir(second, "include")
            local lexical_dir = mkdir(root, "include")
            local link = root .. "/sdk-link"
            assert(lfs.link("first/nested", link, true))

            local outer = source .. "/outer.h"
            local first_selected = first_include .. "/selected.h"
            local second_selected = second_include .. "/selected.h"
            local lexical = lexical_dir .. "/selected.h"
            local lookup = link .. "/../include/selected.h"
            local selected_contents =
                "typedef int titan_symlink_parent_value;\n"
            write_file(outer, "#include <selected.h>\n")
            write_file(first_selected, selected_contents)
            write_file(second_selected, selected_contents)
            write_file(lexical,
                "typedef double titan_symlink_parent_value;\n")

            local types, include = assert_process_file("outer.h", {
                source_dir = source,
                compiler_include_dirs = {},
                cppflags = { "-I", link .. "/../include" },
            })
            assert.same({ "int" },
                types.titan_symlink_parent_value.def)
            assert.equal(lookup,
                include.c_header_dependencies[2].path)
            assert.equal(lookup,
                include.c_header_search_inputs[2].path)
            local first_file_identity =
                include.c_header_dependencies[2].identity
            local first_search_identity =
                include.c_header_search_inputs[2].identity
            assert.equal(assert(cdriver.header_input_identity("file", lookup)),
                first_file_identity)
            assert.equal(assert(cdriver.header_input_identity(
                "search", lookup)), first_search_identity)

            local direct_types, direct_include = assert_process_file(lookup, {
                compiler_include_dirs = {},
            })
            assert.same({ "int" },
                direct_types.titan_symlink_parent_value.def)
            assert.equal(lookup, direct_include.resolved)
            assert.equal(lookup,
                direct_include.c_header_dependencies[1].path)

            assert(os.remove(link))
            assert(lfs.link("second/nested", link, true))
            assert.not_equal(first_file_identity,
                assert(cdriver.header_input_identity("file", lookup)))
            assert.not_equal(first_search_identity,
                assert(cdriver.header_input_identity("search", lookup)))

            remove_tree(
                { outer, first_selected, second_selected, lexical, link },
                { root, first, first_nested, first_include,
                  second, second_nested, second_include,
                  lexical_dir, source })
        end)

        it("preserves a symlinked header's quoted-include origin", function()
            local root = tmp_dir()
            local alias = mkdir(root, "alias")
            local vendor = mkdir(root, "vendor")
            local alias_header = alias .. "/api.h"
            local alias_nested = alias .. "/nested.h"
            local vendor_header = vendor .. "/api.h"
            local vendor_nested = vendor .. "/nested.h"
            write_file(vendor_header, '#include "nested.h"\n')
            write_file(alias_nested,
                "typedef int titan_symlink_origin_value;\n")
            write_file(vendor_nested,
                "typedef double titan_symlink_origin_value;\n")
            assert(lfs.link("../vendor/api.h", alias_header, true))

            local types, include = assert_process_file(alias_header, {
                compiler_include_dirs = {},
            })
            assert.same({ "int" }, types.titan_symlink_origin_value.def)
            assert.equal(alias_header, include.resolved)
            assert.same({ alias_header, alias_nested }, {
                include.c_header_dependencies[1].path,
                include.c_header_dependencies[2].path,
            })

            remove_tree(
                { alias_header, alias_nested, vendor_header, vendor_nested },
                { alias, vendor, root })
        end)

        it("distinguishes a same-byte replacement from a hard link",
        function()
            local root = tmp_dir()
            local original = root .. "/original.h"
            local linked = root .. "/linked.h"
            local replacement = root .. "/replacement.h"
            local contents = "typedef int titan_physical_header_value;\n"
            write_file(original, contents)
            assert(lfs.link(original, linked))

            local original_file = assert(cdriver.header_input_identity(
                "file", original))
            local original_search = assert(cdriver.header_input_identity(
                "search", original))
            assert.equal(original_file,
                assert(cdriver.header_input_identity("file", linked)))
            assert.equal(original_search,
                assert(cdriver.header_input_identity("search", linked)))

            write_file(replacement, contents)
            assert(os.rename(replacement, linked))
            assert.not_equal(original_file,
                assert(cdriver.header_input_identity("file", linked)))
            assert.not_equal(original_search,
                assert(cdriver.header_input_identity("search", linked)))

            remove_tree({ original, linked, replacement }, { root })
        end)

        it("records the exact include lookup access result", function()
            local root = tmp_dir()
            local source = mkdir(root, "source")
            local early = mkdir(root, "early")
            local late = mkdir(root, "late")
            local outer = source .. "/outer.h"
            local early_header = early .. "/selected.h"
            local late_header = late .. "/selected.h"
            write_file(outer, "#include <selected.h>\n")
            write_file(early_header,
                "typedef long titan_access_selected;\n")
            write_file(late_header,
                "typedef int titan_access_selected;\n")

            local original_open = io.open
            io.open = function(filename, mode)
                if filename == early_header and mode == "rb" then
                    return nil, "simulated access denial"
                end
                return original_open(filename, mode)
            end
            local include
            local ok, err = pcall(function()
                local _types
                _types, include = assert_process_file("outer.h", {
                    source_dir = source,
                    compiler_include_dirs = {},
                    cppflags = { "-I", early, "-I", late },
                })
            end)
            io.open = original_open
            assert.truthy(ok, err)
            assert.equal(late_header,
                include.c_header_dependencies[2].path)
            assert.matches("lstat=file",
                include.c_header_search_inputs[2].identity, 1, true)
            assert.matches("stat=file",
                include.c_header_search_inputs[2].identity, 1, true)
            assert.matches("open=unreadable",
                include.c_header_search_inputs[2].identity, 1, true)
            local now_readable = assert(cdriver.header_input_identity(
                "search", early_header))
            assert.matches("open=readable", now_readable, 1, true)
            assert.not_equal(
                include.c_header_search_inputs[2].identity, now_readable)

            remove_tree(
                { outer, early_header, late_header },
                { source, early, late, root })
        end)

        it("distinguishes broken and followed include symlinks", function()
            local root = tmp_dir()
            local target = root .. "/future.h"
            local link = root .. "/candidate.h"
            assert(lfs.link(target, link, true))
            local broken = assert(cdriver.header_input_identity(
                "search", link))
            assert.matches("lstat=link", broken, 1, true)
            assert.matches("stat=missing", broken, 1, true)

            write_file(target, "typedef int titan_future_header;\n")
            local followed = assert(cdriver.header_input_identity(
                "search", link))
            assert.matches("lstat=link", followed, 1, true)
            assert.matches("stat=file", followed, 1, true)
            assert.not_equal(broken, followed)

            assert(os.remove(link))
            assert(os.remove(target))
            assert(lfs.rmdir(root))
        end)

        it("includes the actual lookup open predicate", function()
            local header = tmp_header(
                "typedef int titan_openable_header;\n")
            local readable = assert(cdriver.header_input_identity(
                "search", header))
            assert.matches("open=readable", readable, 1, true)

            -- Keep lstat/stat metadata unchanged while simulating an
            -- effective-access denial. The identity must follow the same
            -- io.open predicate that ordered include selection uses, not only
            -- ownership/mode bits (which do not describe ACL decisions).
            local original_open = io.open
            local unreadable
            io.open = function(filename, mode)
                if filename == header and mode == "rb" then
                    return nil, "simulated access denial"
                end
                return original_open(filename, mode)
            end
            local ok, err = pcall(function()
                unreadable = assert(cdriver.header_input_identity(
                    "search", header))
            end)
            io.open = original_open
            assert.truthy(ok, err)
            assert.matches("open=unreadable", unreadable, 1, true)
            assert.not_equal(readable, unreadable)

            assert(os.remove(header))
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
                    "lua-5.5.1/src",
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
                    "lua-5.5.1/src",
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

        it("reparses forced macro headers and publishes their exact bytes",
        function()
            local root = tmp_dir()
            local forced = root .. "/forced-macros.h"
            local imported = root .. "/imported.h"
            write_file(imported,
                "typedef TITAN_FORCED_TYPE titan_forced_value;\n")
            write_file(forced, "#define TITAN_FORCED_TYPE int\n")
            local options = {
                compiler = { "cc" },
                language_mode = "c99",
                cppflags = { "-include", forced },
                source_dir = root,
            }

            local first, first_include =
                assert_process_file("imported.h", options)
            assert.same({ "int" }, first.titan_forced_value.def)
            assert.same({
                {
                    kind = "file",
                    path = forced,
                    identity = assert(cdriver.header_input_identity(
                        "file", forced)),
                },
                {
                    kind = "file",
                    path = imported,
                    identity = assert(cdriver.header_input_identity(
                        "file", imported)),
                },
            }, first_include.c_header_dependencies)

            write_file(forced, "#define TITAN_FORCED_TYPE long\n")
            local second, second_include =
                assert_process_file("imported.h", options)
            assert.same({ "long" }, second.titan_forced_value.def)
            assert.not_equal(
                first_include.c_header_dependencies[1].identity,
                second_include.c_header_dependencies[1].identity)

            remove_tree({ forced, imported }, { root })
        end)

        it("honors forced-header spellings and compiler ordering", function()
            local root = tmp_dir()
            local imacros_one = root .. "/imacros-one.h"
            local imacros_two = root .. "/imacros-two.h"
            local include_one = root .. "/include-one.h"
            local include_two = root .. "/include-two.h"
            local imported = root .. "/imported.h"
            write_file(imacros_one, [[
#define TITAN_FORCED_STEP 1
typedef int titan_imacros_output_must_be_hidden;
]])
            write_file(imacros_two, [[
#if TITAN_FORCED_STEP == 1
#define TITAN_FORCED_STEP 2
#else
#define TITAN_FORCED_STEP 99
#endif
]])
            write_file(include_one, [[
#if TITAN_FORCED_STEP == 2
#define TITAN_FORCED_STEP 3
#endif
]])
            write_file(include_two, [[
#if TITAN_FORCED_STEP == 3
typedef long titan_forced_order_value;
#else
typedef double titan_forced_order_value;
#endif
]])
            write_file(imported, "extern int titan_forced_order_marker;\n")

            local types, include = assert_process_file("imported.h", {
                compiler = { "cc" },
                language_mode = "c99",
                source_dir = root,
                -- Deliberately interleave both classes. GCC and Clang apply
                -- all imacros first, then all includes, stably within class.
                cppflags = {
                    "-include", include_one,
                    "-imacros" .. imacros_one,
                    "-include" .. include_two,
                    "-imacros", imacros_two,
                },
            })
            assert.same({ "long" }, types.titan_forced_order_value.def)
            assert.is_nil(types.titan_imacros_output_must_be_hidden)
            assert.same({
                imacros_one, imacros_two, include_one, include_two, imported,
            }, (function()
                local paths = {}
                for _, dependency in ipairs(
                        include.c_header_dependencies) do
                    paths[#paths + 1] = dependency.path
                end
                return paths
            end)())

            remove_tree({
                imacros_one, imacros_two, include_one, include_two, imported,
            }, { root })
        end)

        it("invalidates nested forced-header search shadowing", function()
            local root = tmp_dir()
            local early = mkdir(root, "early")
            local late = mkdir(root, "late")
            local forced = root .. "/forced.h"
            local imported = root .. "/imported.h"
            local early_nested = early .. "/forced-nested.h"
            local late_nested = late .. "/forced-nested.h"
            write_file(forced, "#include <forced-nested.h>\n")
            write_file(late_nested,
                "typedef int titan_forced_nested_value;\n")
            write_file(imported, "extern int titan_forced_nested_marker;\n")
            local options = {
                compiler = { "cc" },
                language_mode = "c99",
                source_dir = root,
                compile_flags = {
                    "-I", early, "-I", late, "-include", forced,
                },
                compiler_include_dirs = {},
            }

            local first, first_include =
                assert_process_file("imported.h", options)
            assert.same({ "int" }, first.titan_forced_nested_value.def)
            assert.equal(late_nested,
                first_include.c_header_dependencies[2].path)
            local saw_missing_early = false
            for _, input in ipairs(first_include.c_header_search_inputs) do
                if input.path == early_nested then
                    saw_missing_early = true
                    assert.matches("open=unreadable", input.identity, 1, true)
                end
            end
            assert.is_true(saw_missing_early)

            write_file(early_nested,
                "typedef long titan_forced_nested_value;\n")
            local changed, changed_include =
                assert_process_file("imported.h", options)
            assert.same({ "long" }, changed.titan_forced_nested_value.def)
            assert.equal(early_nested,
                changed_include.c_header_dependencies[2].path)

            remove_tree({
                forced, imported, early_nested, late_nested,
            }, { early, late, root })
        end)

        it("retains exact forced and ordinary lookup paths",
        function()
            local root = tmp_dir()
            local child = mkdir(root, "child")
            local forced = root .. "/forced.h"
            local imported = root .. "/imported.h"
            write_file(forced, "#define TITAN_NORMALIZED_TYPE int\n")
            write_file(imported,
                "typedef TITAN_NORMALIZED_TYPE titan_normalized_value;\n")
            local forced_lookup = child .. "/../forced.h"
            local imported_lookup = child .. "/../imported.h"
            local types, include = assert_process_file("imported.h", {
                compiler = { "cc" },
                language_mode = "c99",
                source_dir = child .. "/..",
                compile_flags = {
                    "-I", child .. "/..",
                    "-include" .. forced_lookup,
                },
                compiler_include_dirs = {},
            })
            assert.same({ "int" }, types.titan_normalized_value.def)
            assert.equal(imported_lookup, include.resolved)
            assert.same({ forced_lookup, imported_lookup }, {
                include.c_header_dependencies[1].path,
                include.c_header_dependencies[2].path,
            })
            assert.equal(forced_lookup,
                include.c_header_search_inputs[1].path)
            assert.equal(imported_lookup,
                include.c_header_search_inputs[2].path)

            remove_tree({ forced, imported }, { child, root })
        end)

        it("rejects an unreadable forced header before parsing a module",
        function()
            local root = tmp_dir()
            local forced = root .. "/forced.h"
            local imported = root .. "/imported.h"
            write_file(forced, "#define TITAN_UNREADABLE_FORCED 1\n")
            write_file(imported, "extern int titan_unreadable_marker;\n")
            local original_open = io.open
            io.open = function(path, mode)
                if path == forced and mode == "rb" then
                    return nil, "simulated forced-header access denial"
                end
                return original_open(path, mode)
            end
            local ok, types, err = pcall(cdriver.process_file,
                "imported.h", {
                    compiler = { "cc" },
                    source_dir = root,
                    cppflags = { "-include", forced },
                })
            io.open = original_open
            assert.is_true(ok, types)
            assert.is_nil(types)
            assert.matches("missing or unreadable", err, 1, true)
            assert.matches("simulated forced%-header access denial", err)

            remove_tree({ forced, imported }, { root })
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
                    "lua-5.5.1/src",
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
                "lua-5.5.1/src",
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
