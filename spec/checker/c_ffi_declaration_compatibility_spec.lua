local h = require "spec.support.helpers"
local checker = require "titan-compiler.checker"
local checker_core = require "titan-compiler.checker.core"
local cprobe = require "titan-compiler.cprobe"
local driver = require "titan-compiler.driver"
local lfs = require "lfs"
local types = require "titan-compiler.types"

local function with_header(contents, fn)
    local header = os.tmpname() .. ".h"
    local file = assert(io.open(header, "w"))
    assert(file:write(contents))
    assert(file:close())

    local results = { pcall(fn, header) }
    os.remove(header)
    if not results[1] then error(results[2], 0) end
    table.remove(results, 1)
    return table.unpack(results)
end

local function with_headers(contents, fn)
    local headers = {}
    local function open_header(index)
        if index > #contents then
            return fn(table.unpack(headers))
        end
        return with_header(contents[index], function(header)
            headers[index] = header
            return open_header(index + 1)
        end)
    end
    return open_header(1)
end

local function with_hard_link(source, fn)
    local alias = os.tmpname() .. ".h"
    os.remove(alias)
    assert(lfs.link(source, alias))

    local results = { pcall(fn, alias) }
    os.remove(alias)
    if not results[1] then error(results[2], 0) end
    table.remove(results, 1)
    return table.unpack(results)
end

local function new_context_configured_probe_service(options)
    local context = driver.new_resolver_context()
    local configured, configure_error =
        driver.configure_foreign_c(context)
    assert.truthy(configured, configure_error)

    local service_options = {}
    for key, value in pairs(options or {}) do
        service_options[key] = value
    end
    service_options.toolchain =
        assert(driver.toolchain_descriptor(context))
    local service, service_error = cprobe.new_service(service_options)
    assert.truthy(service, service_error)
    return context, service
end

local function close_context_configured_probe_service(context, service)
    local service_closed, service_close_error = service:close()
    local context_closed, context_close_error =
        driver.close_resolver_context(context)
    assert.truthy(service_closed, service_close_error)
    assert.truthy(context_closed, context_close_error)
end

local function nested_array_bound(typ)
    typ = types.resolve_c_typedef(typ)
    if typ._tag == "Type.CArray" then
        return typ.len
    elseif typ._tag == "Type.CPointer" then
        return nested_array_bound(typ.pointee)
    end
end

describe("compatible C declarations across foreign imports", function()
    it("retains one consistent complete parameter-name list", function()
        with_headers({
            "extern int ffi_named(int value);",
            "extern int ffi_named(int value);",
        }, function(first_header, second_header)
            local ok, err, ast = h.run_checker(
                'local first = foreign import "' .. first_header .. '"\n' ..
                'local second = foreign import "' .. second_header .. '"\n' ..
                [[
                    function run(): integer
                        return first.ffi_named { value = 1 }
                            + second.ffi_named { value = 2 }
                    end
                ]])
            assert.truthy(ok, err)
            for i = 1, 2 do
                assert.same({ "value" },
                    ast[i]._type.members.ffi_named.paramnames)
            end
        end)
    end)

    it("upgrades every occurrence from unknown to complete parameter names",
    function()
        with_headers({
            "extern int ffi_named(int);",
            "extern int ffi_named(int value);",
            "extern int ffi_named(int);",
        }, function(first_header, second_header, third_header)
            local ok, err, ast = h.run_checker(
                'local first = foreign import "' .. first_header .. '"\n' ..
                'local second = foreign import "' .. second_header .. '"\n' ..
                'local third = foreign import "' .. third_header .. '"\n' ..
                [[
                    function run(): integer
                        return first.ffi_named { value = 1 }
                            + second.ffi_named { value = 2 }
                            + third.ffi_named { value = 3 }
                    end
                ]])
            assert.truthy(ok, err)
            for i = 1, 3 do
                assert.same({ "value" },
                    ast[i]._type.members.ffi_named.paramnames)
            end
        end)
    end)

    it("permanently poisons differing complete parameter-name lists",
    function()
        with_headers({
            [[
                extern int ffi_forward(int first);
                extern int ffi_reverse(int second);
            ]],
            [[
                extern int ffi_forward(int second);
                extern int ffi_reverse(int first);
            ]],
            [[
                extern int ffi_forward(int first);
                extern int ffi_reverse(int first);
            ]],
        }, function(first_header, second_header, third_header)
            local imports =
                'local first = foreign import "' .. first_header .. '"\n' ..
                'local second = foreign import "' .. second_header .. '"\n' ..
                'local third = foreign import "' .. third_header .. '"\n'
            local ok, err, ast = h.run_checker(imports .. [[
                function run(): integer
                    return first.ffi_forward(1)
                        + second.ffi_forward(2)
                        + third.ffi_forward(3)
                        + first.ffi_reverse(4)
                        + second.ffi_reverse(5)
                        + third.ffi_reverse(6)
                end
            ]])
            assert.truthy(ok, err)
            for i = 1, 3 do
                assert.is_false(
                    ast[i]._type.members.ffi_forward.paramnames)
                assert.is_false(
                    ast[i]._type.members.ffi_reverse.paramnames)
            end

            local named_ok, named_err = h.run_checker(imports .. [[
                local function run()
                    first.ffi_forward { first = 1 }
                    second.ffi_forward { second = 2 }
                    third.ffi_forward { first = 3 }
                    first.ffi_reverse { second = 4 }
                    second.ffi_reverse { first = 5 }
                    third.ffi_reverse { first = 6 }
                end
            ]])
            assert.falsy(named_ok)
            local _, unavailable = named_err:gsub(
                "parameter names are unavailable for foreign function", "")
            assert.equal(6, unavailable)
            for _, alias in ipairs({ "first", "second", "third" }) do
                for _, name in ipairs({ "ffi_forward", "ffi_reverse" }) do
                    assert.match(
                        "foreign function '" .. alias .. "%." .. name .. "'",
                        named_err)
                end
            end
        end)
    end)

    it("accepts named and unnamed parameter declarator equivalents",
    function()
        with_header([[
            extern int ffi_abstract_array(int values[7]);
            extern int ffi_abstract_callback(
                int (*callback)(double));
            extern int ffi_abstract_array_pointer(
                int (*values)[7]);
        ]], function(named_header)
            with_header([[
                extern int ffi_abstract_array(int [7]);
                extern int ffi_abstract_callback(int (*)(double));
                extern int ffi_abstract_array_pointer(int (*)[7]);
            ]], function(unnamed_header)
                local ok, err, ast = h.run_checker(
                    'local named = foreign import "' ..
                        named_header .. '"\n' ..
                    'local unnamed = foreign import "' ..
                        unnamed_header .. '"\n')
                assert.truthy(ok, err)

                for _, name in ipairs({
                    "ffi_abstract_array",
                    "ffi_abstract_callback",
                    "ffi_abstract_array_pointer",
                }) do
                    assert.equal(
                        ast[1]._type.members[name].type,
                        ast[2]._type.members[name].type)
                end
            end)
        end)
    end)

    it("accepts function and object redeclarations through typedef aliases",
    function()
        with_header([[
            typedef long ffi_public_offset_t;
            extern int ffi_shared_lock(
                int fd, int command, ffi_public_offset_t offset);
            extern ffi_public_offset_t ffi_shared_cursor;
        ]], function(public_header)
            with_header([[
                typedef long ffi_internal_offset_t;
                extern int ffi_shared_lock(
                    int fd, int command, ffi_internal_offset_t offset);
                extern ffi_internal_offset_t ffi_shared_cursor;
            ]], function(internal_header)
                local ok, err, ast = h.run_checker(
                    'local public = foreign import "' ..
                        public_header .. '"\n' ..
                    'local internal = foreign import "' ..
                        internal_header .. '"\n')
                assert.truthy(ok, err)

                local public = ast[1]._type.members
                local internal = ast[2]._type.members
                assert.equal(public.ffi_shared_lock.type,
                    internal.ffi_shared_lock.type)
                assert.equal(public.ffi_shared_cursor.type,
                    internal.ffi_shared_cursor.type)
                assert.equal("ffi_public_offset_t",
                    public.ffi_shared_lock.type.params[3].name)
            end)
        end)
    end)

    it("preserves compatible redeclarations through an active type macro",
    function()
        with_headers({
            [[
                typedef signed char ffi_internal_byte;
                typedef ffi_internal_byte ffi_shared_byte;
                #define ffi_shared_byte ffi_internal_byte
            ]],
            [[
                #undef ffi_shared_byte
                typedef signed char ffi_shared_byte;
            ]],
        }, function(macro_header, direct_header)
            local ok, err, ast = h.run_checker(
                'local macro = foreign import "' ..
                    macro_header .. '"\n' ..
                'local direct = foreign import "' ..
                    direct_header .. '"\n')
            assert.truthy(ok, err)

            local macro_type =
                ast[1]._type.type_members.ffi_shared_byte
            local direct_type =
                ast[2]._type.type_members.ffi_shared_byte
            assert.equal(macro_type, direct_type)
            assert.is_nil(ast[1]._type.members.ffi_shared_byte)
            assert.is_nil(ast[2]._type.members.ffi_shared_byte)
        end)
    end)

    it("forms stable old-style and prototype composites in either order",
    function()
        with_header([[
            extern int ffi_oldstyle_composite();
        ]], function(oldstyle_header)
            with_header([[
                extern int ffi_oldstyle_composite(int value);
            ]], function(prototype_header)
                for _, headers in ipairs({
                    {oldstyle_header, prototype_header},
                    {prototype_header, oldstyle_header},
                }) do
                    local ok, err, ast = h.run_checker(
                        'local first = foreign import "' ..
                            headers[1] .. '"\n' ..
                        'local second = foreign import "' ..
                            headers[2] .. '"\n')
                    assert.truthy(ok, err)

                    local first = ast[1]._type.members
                        .ffi_oldstyle_composite
                    local second = ast[2]._type.members
                        .ffi_oldstyle_composite
                    assert.equal(first.type, second.type)
                    assert.equal(1, #first.type.params)
                    assert.equal("Type.CFunction", first.type._tag)
                    assert.equal("prototype",
                        first.type._paramstyle)
                    assert.same({"value"}, first.paramnames)
                    assert.same({"value"}, second.paramnames)
                end
            end)
        end)
    end)

    it("rejects prototypes changed by default argument promotions",
    function()
        with_header([[
            extern int ffi_unstable_oldstyle();
        ]], function(oldstyle_header)
            with_header([[
                extern int ffi_unstable_oldstyle(char value);
            ]], function(prototype_header)
                local ok, err = h.run_checker(
                    'local oldstyle = foreign import "' ..
                        oldstyle_header .. '"\n' ..
                    'local prototype = foreign import "' ..
                        prototype_header .. '"\n')
                assert.falsy(ok)
                assert.matches(
                    "conflicting C declaration for "
                        .. "'ffi_unstable_oldstyle'",
                    err, 1, true)
                assert.matches(
                    "configured C compiler rejected",
                    err, 1, true)
            end)
        end)
    end)

    it("rejects one-header old-style promotion conflicts at baseline",
    function()
        with_header([[
            extern int ffi_one_header_oldstyle();
            extern int ffi_one_header_oldstyle(char value);
        ]], function(header)
            local ok, err = h.run_checker(
                'local c = foreign import "' .. header .. '"\n')
            assert.falsy(ok)
            assert.matches(
                "final ordered C header context is invalid",
                err, 1, true)
            assert.matches(
                "configured C compiler rejected",
                err, 1, true)
        end)
    end)

    it("normalizes typedef and direct pointee qualifiers", function()
        with_header([[
            typedef const int ffi_const_int;
            extern ffi_const_int *ffi_qualified_pointer;
            extern ffi_const_int ffi_qualified_scalar_alias;
            extern ffi_const_int ffi_qualified_array[3];
        ]], function(typedef_header)
            with_header([[
                extern const int *ffi_qualified_pointer;
                extern const int ffi_qualified_scalar_alias;
                extern const int ffi_qualified_array[3];
            ]], function(direct_header)
                local ok, err, ast = h.run_checker(
                    'local aliases = foreign import "' ..
                        typedef_header .. '"\n' ..
                    'local direct = foreign import "' ..
                        direct_header .. '"\n')
                assert.truthy(ok, err)
                assert.equal(
                    ast[1]._type.members.ffi_qualified_pointer.type,
                    ast[2]._type.members.ffi_qualified_pointer.type)
                assert.equal(
                    ast[1]._type.members.ffi_qualified_scalar_alias.type,
                    ast[2]._type.members.ffi_qualified_scalar_alias.type)
                assert.equal(
                    ast[1]._type.members.ffi_qualified_array.type,
                    ast[2]._type.members.ffi_qualified_array.type)
            end)
        end)
    end)

    it("rejects different top-level object qualifiers", function()
        with_header([[
            extern const int ffi_qualified_scalar;
            extern int * const ffi_qualified_pointer_object;
        ]], function(qualified_header)
            with_header([[
                extern int ffi_qualified_scalar;
                extern int *ffi_qualified_pointer_object;
            ]], function(unqualified_header)
                local ok, err = h.run_checker(
                    'local qualified = foreign import "' ..
                        qualified_header .. '"\n' ..
                    'local unqualified = foreign import "' ..
                        unqualified_header .. '"\n')
                assert.falsy(ok)
                assert.matches(
                    "conflicting C declaration for 'ffi_qualified_scalar'",
                    err, 1, true)
                assert.matches(
                    "conflicting C declaration for "
                        .. "'ffi_qualified_pointer_object'",
                    err, 1, true)
            end)
        end)
    end)

    it("forms the known-bound composite array type in either order", function()
        with_header([[
            extern int ffi_composite_values[];
        ]], function(unknown_header)
            with_header([[
                extern int ffi_composite_values[7];
            ]], function(known_header)
                for _, headers in ipairs({
                    { unknown_header, known_header },
                    { known_header, unknown_header },
                }) do
                    local ok, err, ast = h.run_checker(
                        'local first = foreign import "' ..
                            headers[1] .. '"\n' ..
                        'local second = foreign import "' ..
                            headers[2] .. '"\n')
                    assert.truthy(ok, err)
                    local first =
                        ast[1]._type.members.ffi_composite_values.type
                    local second =
                        ast[2]._type.members.ffi_composite_values.type
                    assert.equal(first, second)
                    assert.equal("Type.CArray", first._tag)
                    assert.equal(7, first.len)
                end
            end)
        end)
    end)

    it("forms each array composite before probing its next redeclaration",
    function()
        with_headers({
            [[
                extern int ffi_wave_values[];
                #define TITAN_FFI_HIDE_WAVE_BOUNDS 1
            ]],
            [[
                #ifndef TITAN_FFI_HIDE_WAVE_BOUNDS
                extern int ffi_wave_values[3];
                #endif
            ]],
            [[
                #ifndef TITAN_FFI_HIDE_WAVE_BOUNDS
                extern int ffi_wave_values[4];
                #endif
            ]],
        }, function(first_header, second_header, third_header)
            local calls = {}
            local context, service =
                new_context_configured_probe_service({
                    runner = function(argv, metadata)
                        if metadata.stage == "baseline" or
                           metadata.source:find("titan_probe_d%[") then
                            calls[#calls + 1] = metadata
                        end
                        return require("c-parser.cdriver")
                            .capture_command(argv)
                    end,
                })
            local code =
                'local first = foreign import "' .. first_header .. '"\n' ..
                'local second = foreign import "' .. second_header .. '"\n' ..
                'local third = foreign import "' .. third_header .. '"\n'
            h.reset(true)
            local ast = assert(h.parse(code))
            local _, errors = checker.check(
                "test", ast, code, "test.titan", nil, {
                    probe_service_provider = function() return service end,
                })
            local err = table.concat(errors, "\n")
            assert.not_equal("", err)
            assert.matches(
                "conflicting C declaration for 'ffi_wave_values'",
                err, 1, true)
            assert.matches(
                "rejected the declaration compatibility candidate",
                err, 1, true)
            assert.equal(3, #calls)
            assert.equal("baseline", calls[1].stage)
            assert.matches("%[%]", calls[2].source)
            assert.matches("%[3%]", calls[2].source)
            assert.not_matches("%[4%]", calls[2].source)
            assert.matches("%[3%]", calls[3].source)
            assert.matches("%[4%]", calls[3].source)
            assert.not_matches("%[%]", calls[3].source)
            close_context_configured_probe_service(context, service)
        end)
    end)

    it("expands a completed declaration-owned array alias in the next probe",
    function()
        with_headers({
            [[
                typedef int ffi_wave_array_alias[];
                extern ffi_wave_array_alias ffi_wave_alias_values;
                #define TITAN_FFI_HIDE_ALIAS_BOUNDS 1
            ]],
            [[
                #ifndef TITAN_FFI_HIDE_ALIAS_BOUNDS
                extern int ffi_wave_alias_values[3];
                #endif
            ]],
            [[
                #ifndef TITAN_FFI_HIDE_ALIAS_BOUNDS
                extern int ffi_wave_alias_values[4];
                #endif
            ]],
        }, function(first_header, second_header, third_header)
            local calls = {}
            local context, service =
                new_context_configured_probe_service({
                    runner = function(argv, metadata)
                        if metadata.stage == "baseline" or
                           metadata.source:find("titan_probe_d%[") then
                            calls[#calls + 1] = metadata
                        end
                        return require("c-parser.cdriver")
                            .capture_command(argv)
                    end,
                })
            local code =
                'local first = foreign import "' .. first_header .. '"\n' ..
                'local second = foreign import "' .. second_header .. '"\n' ..
                'local third = foreign import "' .. third_header .. '"\n'
            h.reset(true)
            local ast = assert(h.parse(code))
            local _, errors = checker.check(
                "test", ast, code, "test.titan", nil, {
                    probe_service_provider = function() return service end,
                })
            local err = table.concat(errors, "\n")
            assert.matches(
                "conflicting C declaration for 'ffi_wave_alias_values'",
                err, 1, true)
            assert.equal(3, #calls)
            assert.matches("%[%]", calls[2].source)
            assert.matches("%[3%]", calls[2].source)
            assert.matches("%[3%]", calls[3].source)
            assert.matches("%[4%]", calls[3].source)
            assert.not_matches(
                "extern ffi_wave_array_alias titan_probe_d",
                calls[3].source)
            close_context_configured_probe_service(context, service)
        end)
    end)

    it("redirects a typedef before checking the next distinct name",
    function()
        local guarded = [[
            #ifndef TITAN_FFI_SHARED_WAVE_ALIAS
            #define TITAN_FFI_SHARED_WAVE_ALIAS
            typedef struct { int value; } ffi_shared_wave_alias;
            extern ffi_shared_wave_alias *ffi_shared_wave_object;
            #endif
        ]]
        with_headers({ guarded, guarded },
        function(first_header, second_header)
            local calls = {}
            local context, service =
                new_context_configured_probe_service({
                    runner = function(argv, metadata)
                        if metadata.stage == "baseline" or
                           metadata.source:find("extern ffi_shared_wave_alias ") then
                            calls[#calls + 1] = metadata
                        end
                        return require("c-parser.cdriver")
                            .capture_command(argv)
                    end,
                })
            local code =
                'local first = foreign import "' .. first_header .. '"\n' ..
                'local second = foreign import "' .. second_header .. '"\n'
            h.reset(true)
            local ast = assert(h.parse(code))
            local _, errors = checker.check(
                "test", ast, code, "test.titan", nil, {
                    probe_service_provider = function() return service end,
                })
            assert.equal(0, #errors, table.concat(errors, "\n"))
            assert.equal(3, #calls)
            assert.equal("baseline", calls[1].stage)
            assert.matches(
                "extern ffi_shared_wave_alias titan_probe_d",
                calls[2].source)
            assert.matches(
                "extern ffi_shared_wave_alias %*titan_probe_d",
                calls[3].source)

            local first_alias = ast[1]._type.type_members
                .ffi_shared_wave_alias
            local second_alias = ast[2]._type.type_members
                .ffi_shared_wave_alias
            assert.equal(first_alias, second_alias)
            assert.equal(first_alias.target, second_alias.target)
            assert.equal(
                ast[1]._type.members.ffi_shared_wave_object.type,
                ast[2]._type.members.ffi_shared_wave_object.type)
            close_context_configured_probe_service(context, service)
        end)
    end)

    it("accepts target-C-equivalent symbolic array bounds", function()
        with_headers({
            [[
                enum { FFI_SYMBOLIC_BOUND = 3 };
                extern int ffi_symbolic_values[FFI_SYMBOLIC_BOUND];
                extern int ffi_sizeof_values[sizeof(int)];
            ]],
            [[
                extern int ffi_symbolic_values[3];
                extern int ffi_sizeof_values[sizeof(int)];
            ]],
        }, function(symbolic_header, numeric_header)
            local ok, err, ast = h.run_checker(
                'local symbolic = foreign import "' ..
                    symbolic_header .. '"\n' ..
                'local numeric = foreign import "' ..
                    numeric_header .. '"\n')
            assert.truthy(ok, err)
            for _, name in ipairs({
                "ffi_symbolic_values",
                "ffi_sizeof_values",
            }) do
                assert.equal(
                    ast[1]._type.members[name].type,
                    ast[2]._type.members[name].type)
            end
        end)
    end)

    it("preserves pointer-to-array precedence in symbolic bounds", function()
        with_headers({
            [[
                extern int
                    ffi_pointer_sized_values[sizeof(int (*)[3])];
            ]],
            [[
                extern int
                    ffi_pointer_sized_values[sizeof(void *)];
            ]],
        }, function(array_pointer_header, void_pointer_header)
            local ok, err, ast = h.run_checker(
                'local array_pointer = foreign import "' ..
                    array_pointer_header .. '"\n' ..
                'local void_pointer = foreign import "' ..
                    void_pointer_header .. '"\n')
            assert.truthy(ok, err)
            assert.equal(
                ast[1]._type.members.ffi_pointer_sized_values.type,
                ast[2]._type.members.ffi_pointer_sized_values.type)
        end)
    end)

    it("renders repeated pointer-to-function symbolic bounds", function()
        with_headers({
            [[
                extern int
                    ffi_callback_sized_values[sizeof(int (*)(double))];
            ]],
            [[
                extern int
                    ffi_callback_sized_values[sizeof(int (*)(double))];
            ]],
        }, function(first_header, second_header)
            local ok, err, ast = h.run_checker(
                'local first = foreign import "' ..
                    first_header .. '"\n' ..
                'local second = foreign import "' ..
                    second_header .. '"\n')
            assert.truthy(ok, err)
            assert.equal(
                ast[1]._type.members.ffi_callback_sized_values.type,
                ast[2]._type.members.ffi_callback_sized_values.type)
        end)
    end)

    it("renders static array parameters in repeated symbolic bounds",
    function()
        with_headers({
            [[
                extern int ffi_static_parameter_extent[
                    sizeof(int (*)(int [static 3]))];
            ]],
            [[
                extern int ffi_static_parameter_extent[
                    sizeof(int (*)(int [static 3]))];
            ]],
        }, function(first_header, second_header)
            local ok, err, ast = h.run_checker(
                'local first = foreign import "' ..
                    first_header .. '"\n' ..
                'local second = foreign import "' ..
                    second_header .. '"\n')
            assert.truthy(ok, err)
            assert.equal(
                ast[1]._type.members.ffi_static_parameter_extent.type,
                ast[2]._type.members.ffi_static_parameter_extent.type)
        end)
    end)

    it("lets target C reject unequal symbolic array bounds", function()
        with_headers({
            [[
                enum { FFI_HIDDEN_BOUND = 3 };
                extern int ffi_hidden_values[FFI_HIDDEN_BOUND];
                #define TITAN_FFI_HIDE_UNEQUAL_BOUND 1
            ]],
            [[
                #ifndef TITAN_FFI_HIDE_UNEQUAL_BOUND
                extern int ffi_hidden_values[4];
                #endif
            ]],
        }, function(symbolic_header, unequal_header)
            local ok, err = h.run_checker(
                'local symbolic = foreign import "' ..
                    symbolic_header .. '"\n' ..
                'local unequal = foreign import "' ..
                    unequal_header .. '"\n')
            assert.falsy(ok)
            assert.matches(
                "conflicting C declaration for 'ffi_hidden_values'",
                err, 1, true)
            assert.matches(
                "rejected the declaration compatibility candidate",
                err, 1, true)
        end)
    end)

    it("keeps typedef array composites declaration-owned in either order",
    function()
        with_header([[
            typedef int ffi_incomplete_array[];
            extern ffi_incomplete_array ffi_typedef_values;
            extern ffi_incomplete_array ffi_typedef_untouched;
        ]], function(unknown_header)
            with_header([[
                extern int ffi_typedef_values[7];
            ]], function(known_header)
                for order, headers in ipairs({
                    { unknown_header, known_header },
                    { known_header, unknown_header },
                }) do
                    local ok, err, ast = h.run_checker(
                        'local first = foreign import "' ..
                            headers[1] .. '"\n' ..
                        'local second = foreign import "' ..
                            headers[2] .. '"\n')
                    assert.truthy(ok, err)
                    local first =
                        ast[1]._type.members.ffi_typedef_values.type
                    local second =
                        ast[2]._type.members.ffi_typedef_values.type
                    assert.equal(first, second)
                    assert.equal(7, nested_array_bound(first))
                    if order == 1 then
                        assert.equal("Type.CTypedef", first._tag)
                        assert.equal("ffi_incomplete_array", first.name)
                    end

                    local aliases = order == 1
                        and ast[1]._type or ast[2]._type
                    local alias = aliases.type_members
                        .ffi_incomplete_array
                    local untouched = aliases.members
                        .ffi_typedef_untouched.type
                    assert.equal("", nested_array_bound(alias))
                    assert.equal("", nested_array_bound(untouched))
                end
            end)
        end)
    end)

    it("completes nested pointer and function array paths independently",
    function()
        with_header([[
            typedef int ffi_unknown_array[];
            typedef ffi_unknown_array *ffi_unknown_pointer;
            extern ffi_unknown_array *ffi_nested_pointer;
            extern ffi_unknown_array *ffi_nested_untouched;
            extern int ffi_nested_function(ffi_unknown_pointer value);
            extern int ffi_function_untouched(ffi_unknown_pointer value);
        ]], function(unknown_header)
            with_header([[
                typedef int ffi_known_array[7];
                typedef ffi_known_array *ffi_known_pointer;
                extern ffi_known_array *ffi_nested_pointer;
                extern int ffi_nested_function(ffi_known_pointer value);
            ]], function(known_header)
                local ok, err, ast = h.run_checker(
                    'local unknown = foreign import "' ..
                        unknown_header .. '"\n' ..
                    'local known = foreign import "' ..
                        known_header .. '"\n')
                assert.truthy(ok, err)

                local unknown = ast[1]._type
                local known = ast[2]._type
                local pointer =
                    unknown.members.ffi_nested_pointer.type
                assert.equal(pointer,
                    known.members.ffi_nested_pointer.type)
                assert.equal(7, nested_array_bound(pointer))
                assert.equal("", nested_array_bound(
                    unknown.members.ffi_nested_untouched.type))
                assert.equal("", nested_array_bound(
                    unknown.type_members.ffi_unknown_array))

                local fn =
                    unknown.members.ffi_nested_function.type
                assert.equal(fn,
                    known.members.ffi_nested_function.type)
                assert.equal(7,
                    nested_array_bound(fn.params[1]))
                assert.equal("", nested_array_bound(
                    unknown.members
                        .ffi_function_untouched.type.params[1]))
            end)
        end)
    end)

    it("imports exact ordered pointer, array, and function declarators",
    function()
        with_header([[
            extern int *ffi_pointer_array[3];
            extern int (*ffi_array_pointer)[3];
            extern int (*ffi_callbacks[2])(int);
            extern int (*ffi_row_factory(void))[3];
        ]], function(header)
            local ok, err, ast = h.run_checker(
                'local c = foreign import "' .. header .. '"\n')
            assert.truthy(ok, err)
            local members = ast[1]._type.members

            local pointer_array =
                members.ffi_pointer_array.type
            assert.equal("Type.CArray", pointer_array._tag)
            assert.equal(3, pointer_array.len)
            assert.equal("Type.CPointer",
                pointer_array.elem._tag)

            local array_pointer =
                members.ffi_array_pointer.type
            assert.equal("Type.CPointer", array_pointer._tag)
            assert.equal("Type.CArray",
                array_pointer.pointee._tag)
            assert.equal(3, array_pointer.pointee.len)

            local callbacks = members.ffi_callbacks.type
            assert.equal("Type.CArray", callbacks._tag)
            assert.equal(2, callbacks.len)
            assert.equal("Type.CPointer", callbacks.elem._tag)
            assert.equal("Type.CFunction",
                callbacks.elem.pointee._tag)

            local factory =
                members.ffi_row_factory.type
            assert.equal("Type.CFunction", factory._tag)
            assert.equal("Type.CPointer", factory.ret._tag)
            assert.equal("Type.CArray",
                factory.ret.pointee._tag)
            assert.equal(3, factory.ret.pointee.len)
        end)
    end)

    it("matches matrix array parameters with pointer-to-array parameters",
    function()
        with_header([[
            extern int ffi_matrix_parameter(int values[][3]);
        ]], function(array_header)
            with_header([[
                extern int ffi_matrix_parameter(int (*values)[3]);
            ]], function(pointer_header)
                local ok, err, ast = h.run_checker(
                    'local arrays = foreign import "' ..
                        array_header .. '"\n' ..
                    'local pointers = foreign import "' ..
                        pointer_header .. '"\n')
                assert.truthy(ok, err)
                local first = ast[1]._type.members
                    .ffi_matrix_parameter.type
                local second = ast[2]._type.members
                    .ffi_matrix_parameter.type
                assert.equal(first, second)
                assert.equal("Type.CPointer",
                    first.params[1]._tag)
                assert.equal("Type.CArray",
                    first.params[1].pointee._tag)
                assert.equal(3, first.params[1].pointee.len)
            end)
        end)
    end)

    it("preserves qualified nonvoid and void function returns", function()
        with_header([[
            typedef const int ffi_const_int;
            typedef const void ffi_const_void;
            extern ffi_const_int ffi_qualified_return(void);
            extern ffi_const_void ffi_qualified_void_return(void);
        ]], function(alias_header)
            with_header([[
                extern const int ffi_qualified_return(void);
                extern const void ffi_qualified_void_return(void);
            ]], function(direct_header)
                local ok, err, ast = h.run_checker(
                    'local aliases = foreign import "' ..
                        alias_header .. '"\n' ..
                    'local direct = foreign import "' ..
                        direct_header .. '"\n')
                assert.truthy(ok, err)
                assert.equal(
                    ast[1]._type.members.ffi_qualified_return.type,
                    ast[2]._type.members.ffi_qualified_return.type)
                assert.equal(
                    ast[1]._type.members
                        .ffi_qualified_void_return.type,
                    ast[2]._type.members
                        .ffi_qualified_void_return.type)
                assert.equal("Type.CVoid",
                    types.resolve_c_typedef(ast[1]._type.members
                        .ffi_qualified_void_return.type.ret)._tag)
            end)
        end)

        with_header([[
            extern const int ffi_return_conflict(void);
            extern const void ffi_void_return_conflict(void);
        ]], function(qualified_header)
            with_header([[
                extern int ffi_return_conflict(void);
                extern void ffi_void_return_conflict(void);
            ]], function(plain_header)
                local ok, err = h.run_checker(
                    'local qualified = foreign import "' ..
                        qualified_header .. '"\n' ..
                    'local plain = foreign import "' ..
                        plain_header .. '"\n')
                assert.falsy(ok)
                assert.matches(
                    "conflicting C declaration for "
                        .. "'ffi_return_conflict'",
                    err, 1, true)
                assert.matches(
                    "conflicting C declaration for "
                        .. "'ffi_void_return_conflict'",
                    err, 1, true)
            end)
        end)
    end)

    it("matches nested aliased C callback signatures in every value path",
    function()
        with_header([[
            typedef int ffi_first_int;
            typedef int ffi_second_int;
            typedef ffi_first_int
                (*ffi_first_callback)(ffi_first_int);
            typedef ffi_second_int
                (*ffi_second_callback)(ffi_second_int);
            typedef ffi_first_callback
                (*ffi_first_factory)(void);
            typedef ffi_second_callback
                (*ffi_second_factory)(void);
            typedef ffi_first_callback *ffi_first_callback_pointer;
            typedef ffi_second_callback *ffi_second_callback_pointer;

            extern ffi_first_callback ffi_get_callback(void);
            extern void ffi_take_callback(ffi_second_callback callback);
            extern ffi_first_callback ffi_callbacks[4];
            extern ffi_first_int ffi_direct(ffi_first_int value);
            extern ffi_first_factory ffi_get_factory(void);
            extern void ffi_take_factory(ffi_second_factory factory);
            extern ffi_first_callback_pointer
                ffi_get_callback_pointer(void);
            extern void ffi_take_callback_pointer(
                ffi_second_callback_pointer pointer);
        ]], function(header)
            local ok, err, ast = h.run_checker([[
                local c = foreign import "]] .. header .. [["

                local function use(): nil
                    c.ffi_take_callback(c.ffi_get_callback())
                    c.ffi_take_callback(c.ffi_callbacks[0])
                    c.ffi_take_callback(c.ffi_direct)
                    c.ffi_take_factory(c.ffi_get_factory())
                    c.ffi_take_callback_pointer(
                        c.ffi_get_callback_pointer())
                    return nil
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("keeps callback identity strict before nested unsafe pointer fallback",
    function()
        with_header([[
            typedef int (*ffi_plain_callback)(int);
            typedef const int (*ffi_const_callback)(int);
            extern ffi_plain_callback ffi_get_plain(void);
            extern void ffi_take_const(ffi_const_callback callback);
            extern int ffi_direct_plain(int value);

            typedef void (*ffi_mutable_callback)(int *);
            typedef void (*ffi_const_pointee_callback)(const int *);
            extern ffi_mutable_callback ffi_get_mutable(void);
            extern void ffi_take_const_pointee(
                ffi_const_pointee_callback callback);
            extern ffi_mutable_callback ffi_mutable_callbacks[1];
            typedef ffi_mutable_callback *ffi_mutable_callback_pointer;
            typedef ffi_const_pointee_callback
                *ffi_const_callback_pointer;
            extern ffi_mutable_callback_pointer
                ffi_get_mutable_pointer(void);
            extern void ffi_take_const_pointer(
                ffi_const_callback_pointer pointer);
        ]], function(header)
            local ok, err, ast = h.run_checker([[
                local c = foreign import "]] .. header .. [["

                local function bad(): nil
                    c.ffi_take_const(c.ffi_get_plain())
                    c.ffi_take_const(c.ffi_direct_plain)
                    c.ffi_take_const_pointee(
                        c.ffi_get_mutable())
                    c.ffi_take_const_pointee(
                        c.ffi_mutable_callbacks[0])
                    c.ffi_take_const_pointer(
                        c.ffi_get_mutable_pointer())
                    return nil
                end
            ]])
            assert.falsy(ok)
            assert.is_false(types.consistent(
                ast[1]._type.type_members
                    .ffi_const_callback_pointer,
                ast[1]._type.type_members
                    .ffi_mutable_callback_pointer))
            assert.matches("types in argument 1", err)
            assert.matches("foreign %(C%) function", err)
            assert.matches("ffi_take_const_pointee", err, 1, true)
            assert.not_matches(
                "ffi_take_const_pointer", err, 1, true)
        end)
    end)

    it("accepts top-level callback parameter qualification and array composites",
    function()
        with_header([[
            typedef void (*ffi_plain_parameter)(int *);
            typedef void (*ffi_const_parameter)(int * const);
            extern ffi_plain_parameter ffi_get_parameter(void);
            extern void ffi_take_parameter(ffi_const_parameter callback);

            typedef int ffi_unknown_callback_array[];
            typedef int ffi_known_callback_array[7];
            typedef void (*ffi_unknown_array_callback)(
                ffi_unknown_callback_array *);
            typedef void (*ffi_known_array_callback)(
                ffi_known_callback_array *);
            extern ffi_unknown_array_callback
                ffi_get_array_callback(void);
            extern void ffi_take_array_callback(
                ffi_known_array_callback callback);
        ]], function(header)
            local ok, err = h.run_checker([[
                local c = foreign import "]] .. header .. [["

                local function good(): nil
                    c.ffi_take_parameter(c.ffi_get_parameter())
                    c.ffi_take_array_callback(
                        c.ffi_get_array_callback())
                    return nil
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("adjusts function parameters to compatible function pointers",
    function()
        with_header([[
            extern int ffi_callback_user(int callback(void));
        ]], function(function_header)
            with_header([[
                extern int ffi_callback_user(int (*callback)(void));
            ]], function(pointer_header)
                local ok, err, ast = h.run_checker(
                    'local function_form = foreign import "' ..
                        function_header .. '"\n' ..
                    'local pointer_form = foreign import "' ..
                        pointer_header .. '"\n')
                assert.truthy(ok, err)
                local callback = ast[1]._type.members
                    .ffi_callback_user.type.params[1]
                assert.equal("Type.CPointer", callback._tag)
                assert.equal("Type.CFunction", callback.pointee._tag)
                assert.equal(
                    ast[1]._type.members.ffi_callback_user.type,
                    ast[2]._type.members.ffi_callback_user.type)
            end)
        end)
    end)

    it("adjusts away top-level function parameter qualifiers", function()
        with_header([[
            extern int ffi_parameter_qualifiers(
                const int value, int * const pointer);
        ]], function(qualified_header)
            with_header([[
                extern int ffi_parameter_qualifiers(
                    int value, int *pointer);
            ]], function(unqualified_header)
                local ok, err = h.run_checker(
                    'local qualified = foreign import "' ..
                        qualified_header .. '"\n' ..
                    'local unqualified = foreign import "' ..
                        unqualified_header .. '"\n')
                assert.truthy(ok, err)
            end)
        end)
    end)

    it("still rejects declarations with different resolved C types",
    function()
        with_header([[
            typedef long ffi_wide_value_t;
            extern int ffi_conflict(ffi_wide_value_t value);
        ]], function(wide_header)
            with_header([[
                typedef int ffi_narrow_value_t;
                extern int ffi_conflict(ffi_narrow_value_t value);
            ]], function(narrow_header)
                local ok, err = h.run_checker(
                    'local wide = foreign import "' ..
                        wide_header .. '"\n' ..
                    'local narrow = foreign import "' ..
                        narrow_header .. '"\n')
                assert.falsy(ok)
                assert.matches(
                    "conflicting C declaration for 'ffi_conflict'",
                    err, 1, true)
                assert.matches("ffi_wide_value_t", err, 1, true)
                assert.matches("ffi_narrow_value_t", err, 1, true)
            end)
        end)
    end)

    it("rejects one typedef name with conflicting resolved types", function()
        with_header([[
            typedef int ffi_conflicting_type;
        ]], function(integer_header)
            with_header([[
                typedef double ffi_conflicting_type;
            ]], function(double_header)
                local ok, err = h.run_checker(
                    'local integers = foreign import "' ..
                        integer_header .. '"\n' ..
                    'local doubles = foreign import "' ..
                        double_header .. '"\n')
                assert.falsy(ok)
                assert.matches(
                    "conflicting C declaration for 'ffi_conflicting_type'",
                    err, 1, true)
            end)
        end)
    end)

    it("uses the active type macro that shadows an earlier typedef",
    function()
        with_header([[
            typedef int ffi_public_number;
            typedef double ffi_replacement_number;
            #define ffi_public_number ffi_replacement_number
        ]], function(header)
            local ok, err, ast = h.run_checker(
                'local c = foreign import "' .. header .. '"\n' ..
                [[
                    function identity(x: float): float
                        local converted =
                            x as c.ffi_public_number
                        return converted as float
                    end
                ]])
            assert.truthy(ok, err)

            local alias =
                ast[1]._type.type_members.ffi_public_number
            assert.equal("Type.CTypedef", alias._tag)
            assert.equal("ffi_public_number", alias.name)
            local resolved = types.resolve_c_typedef(alias)
            assert.equal("Type.CFloat", resolved._tag)
            assert.equal("double", resolved.spelling)
            assert.is_nil(
                ast[1]._type.members.ffi_public_number)
        end)
    end)

    it("keeps named aggregate targets nominal through a shared typedef",
    function()
        with_header([[
            struct ffi_first_record { int value; };
            typedef struct ffi_first_record ffi_shared_record;
        ]], function(first_header)
            with_header([[
                struct ffi_second_record { int value; };
                typedef struct ffi_second_record ffi_shared_record;
            ]], function(second_header)
                local ok, err = h.run_checker(
                    'local first = foreign import "' ..
                        first_header .. '"\n' ..
                    'local second = foreign import "' ..
                        second_header .. '"\n')
                assert.falsy(ok)
                assert.matches(
                    "conflicting C declaration for 'ffi_shared_record'",
                    err, 1, true)
            end)
        end)
    end)

    it("rejects independently declared same-shaped anonymous typedefs",
    function()
        with_header([[
            typedef struct { int value; } ffi_same_shape;
        ]], function(first_header)
            with_header([[
                typedef struct { int value; } ffi_same_shape;
            ]], function(second_header)
                local ok, err = h.run_checker(
                    'local first = foreign import "' ..
                        first_header .. '"\n' ..
                    'local second = foreign import "' ..
                        second_header .. '"\n')
                assert.falsy(ok)
                assert.matches(
                    "conflicting C declaration for 'ffi_same_shape'",
                    err, 1, true)
            end)
        end)
    end)

    it("recognizes one guarded anonymous typedef through outer aliases",
    function()
        with_header([[
            #ifndef TITAN_FFI_GUARDED_COMMON
            #define TITAN_FFI_GUARDED_COMMON
            typedef struct {
                int values[4 * sizeof(int)];
            } ffi_guarded_common, ffi_guarded_common_second;
            #endif
        ]], function(common_header)
            local common_name =
                assert(common_header:match("([^/]+)$"))
            with_header(
                '#include "' .. common_name .. '"\n'
                .. 'typedef ffi_guarded_common ffi_outer_a;\n'
                .. 'extern ffi_outer_a ffi_guarded_object;\n',
                function(first_header)
                    with_header(
                        '#include "' .. common_name .. '"\n'
                        .. 'typedef ffi_guarded_common_second ffi_outer_b;\n'
                        .. 'extern ffi_outer_b ffi_guarded_object;\n',
                        function(second_header)
                            local ok, err = h.run_checker(
                                'local first = foreign import "' ..
                                    first_header .. '"\n' ..
                                'local second = foreign import "' ..
                                    second_header .. '"\n')
                            assert.truthy(ok, err)
                        end)
                end)
        end)
    end)

    it("recognizes one guarded prototype-tag declaration through path aliases",
    function()
        with_header([[
            #ifndef TITAN_FFI_GUARDED_PROTOTYPE_TAG
            #define TITAN_FFI_GUARDED_PROTOTYPE_TAG
            extern int ffi_guarded_prototype_tag(
                struct ffi_guarded_local *value);
            #endif
        ]], function(common_header)
            local common_name =
                assert(common_header:match("([^/]+)$"))
            with_header(
                '#include "' .. common_name .. '"\n',
                function(first_header)
                    with_header(
                        '#include "./' .. common_name .. '"\n',
                        function(second_header)
                            local ok, err, ast = h.run_checker(
                                'local first = foreign import "' ..
                                    first_header .. '"\n' ..
                                'local second = foreign import "' ..
                                    second_header .. '"\n')
                            assert.truthy(ok, err)

                            local first = ast[1]._type.members
                                .ffi_guarded_prototype_tag.type
                            local second = ast[2]._type.members
                                .ffi_guarded_prototype_tag.type
                            assert.equal(first, second)
                            assert.equal(first.params[1].pointee,
                                second.params[1].pointee)
                            assert.is_nil(ast[1]._type.type_members
                                .ffi_guarded_local)
                            assert.is_nil(ast[2]._type.type_members
                                .ffi_guarded_local)
                        end)
                end)
        end)
    end)

    it("recognizes one pragma-once prototype tag through hard-link aliases",
    function()
        with_header([[
            #pragma once
            extern int ffi_hard_linked_prototype_tag(
                struct ffi_hard_linked_local *value);
        ]], function(common_header)
            with_hard_link(common_header, function(alias_header)
                local ok, err, ast = h.run_checker(
                    'local first = foreign import "' ..
                        common_header .. '"\n' ..
                    'local second = foreign import "' ..
                        alias_header .. '"\n')
                assert.truthy(ok, err)

                local first = ast[1]._type.members
                    .ffi_hard_linked_prototype_tag.type
                local second = ast[2]._type.members
                    .ffi_hard_linked_prototype_tag.type
                assert.equal(first, second)
                assert.equal(first.params[1].pointee,
                    second.params[1].pointee)
            end)
        end)
    end)

    it("does not excuse same-source macro-dependent type changes", function()
        with_header([[
            #ifndef TITAN_FFI_SOURCE_REPEAT_MACRO
            #define TITAN_FFI_SOURCE_REPEAT_MACRO
            extern TITAN_FFI_SHARED_TYPE ffi_source_repeat_macro(void);
            #endif
        ]], function(common_header)
            local common_name =
                assert(common_header:match("([^/]+)$"))
            with_headers({
                "#define TITAN_FFI_SUPPRESS_FIRST 1\n",
                [[
                    #ifndef TITAN_FFI_SUPPRESS_FIRST
                    #define TITAN_FFI_SHARED_TYPE int
                    #include "]] .. common_name .. [["
                    #undef TITAN_FFI_SHARED_TYPE
                    #endif
                ]],
                [[
                    #define TITAN_FFI_SHARED_TYPE double
                    #include "]] .. common_name .. [["
                    #undef TITAN_FFI_SHARED_TYPE
                ]],
            }, function(prelude_header, first_header, second_header)
                local ok, err, ast = h.run_checker(
                    'local prelude = foreign import "' ..
                        prelude_header .. '"\n' ..
                    'local first = foreign import "' ..
                        first_header .. '"\n' ..
                    'local second = foreign import "' ..
                        second_header .. '"\n')
                assert.falsy(ok)
                assert.matches(
                    "conflicting C declaration for " ..
                        "'ffi_source_repeat_macro'",
                    err, 1, true)
                assert.not_equal(
                    ast[2]._type.members.ffi_source_repeat_macro.type,
                    ast[3]._type.members.ffi_source_repeat_macro.type)
            end)
        end)
    end)

    it("preserves prototype-tag alias topology in source repeats", function()
        with_header([[
            #ifndef TITAN_FFI_SOURCE_REPEAT_TOPOLOGY
            #define TITAN_FFI_SOURCE_REPEAT_TOPOLOGY
            extern int ffi_source_repeat_topology(
                struct ffi_topology_local { int value; } *outer,
                void (*callback)(TITAN_FFI_CALLBACK_TAG *inner));
            #endif
        ]], function(common_header)
            local common_name =
                assert(common_header:match("([^/]+)$"))
            with_headers({
                "#define TITAN_FFI_SUPPRESS_TOPOLOGY_FIRST 1\n",
                [[
                    #ifndef TITAN_FFI_SUPPRESS_TOPOLOGY_FIRST
                    #define TITAN_FFI_CALLBACK_TAG struct ffi_topology_local
                    #include "]] .. common_name .. [["
                    #undef TITAN_FFI_CALLBACK_TAG
                    #endif
                ]],
                [[
                    #define TITAN_FFI_CALLBACK_TAG \
                        struct ffi_topology_local { int value; }
                    #include "]] .. common_name .. [["
                    #undef TITAN_FFI_CALLBACK_TAG
                ]],
            }, function(prelude_header, first_header, second_header)
                local ok, err = h.run_checker(
                    'local prelude = foreign import "' ..
                        prelude_header .. '"\n' ..
                    'local first = foreign import "' ..
                        first_header .. '"\n' ..
                    'local second = foreign import "' ..
                        second_header .. '"\n')
                assert.falsy(ok)
                assert.matches(
                    "conflicting C declaration for " ..
                        "'ffi_source_repeat_topology'",
                    err, 1, true)
            end)
        end)
    end)

    it("keeps separately sourced prototype tags nominal", function()
        with_headers({
            [[
                extern int ffi_distinct_prototype_tag(
                    struct ffi_distinct_local *value);
            ]],
            [[
                extern int ffi_distinct_prototype_tag(
                    struct ffi_distinct_local *value);
            ]],
        }, function(first_header, second_header)
            local ok, err = h.run_checker(
                'local first = foreign import "' .. first_header .. '"\n' ..
                'local second = foreign import "' .. second_header .. '"\n')
            assert.falsy(ok)
            assert.matches(
                "conflicting C declaration for " ..
                    "'ffi_distinct_prototype_tag'",
                err, 1, true)
        end)
    end)

    it("rejects an unguarded physical prototype-tag declaration twice",
    function()
        with_header([[
            extern int ffi_unguarded_prototype_tag(
                struct ffi_unguarded_local *value);
        ]], function(common_header)
            local common_name =
                assert(common_header:match("([^/]+)$"))
            with_header(
                '#include "' .. common_name .. '"\n',
                function(first_header)
                    with_header(
                        '#include "' .. common_name .. '"\n',
                        function(second_header)
                            local ok, err = h.run_checker(
                                'local first = foreign import "' ..
                                    first_header .. '"\n' ..
                                'local second = foreign import "' ..
                                    second_header .. '"\n')
                            assert.falsy(ok)
                            assert.matches(
                                "final ordered C header context is invalid",
                                err, 1, true)
                        end)
                end)
        end)
    end)

    it("uses the final header context across path aliases and three imports",
    function()
        with_header([[
            #ifndef TITAN_FFI_ALIASED_COMMON
            #define TITAN_FFI_ALIASED_COMMON
            typedef struct {
                int value;
            } ffi_aliased_common;
            #endif
        ]], function(common_header)
            local common_name =
                assert(common_header:match("([^/]+)$"))
            with_header(
                '#include "' .. common_name .. '"\n'
                .. 'extern ffi_aliased_common ffi_aliased_object;\n',
                function(first_header)
                    with_header(
                        '#include "./' .. common_name .. '"\n'
                        .. 'extern ffi_aliased_common '
                        .. 'ffi_aliased_object;\n',
                        function(second_header)
                            with_header(
                                '#include "' .. common_name .. '"\n'
                                .. 'extern ffi_aliased_common '
                                .. 'ffi_aliased_object;\n',
                                function(third_header)
                                    local ok, err, ast = h.run_checker(
                                        'local first = foreign import "' ..
                                            first_header .. '"\n' ..
                                        'local second = foreign import "' ..
                                            second_header .. '"\n' ..
                                        'local third = foreign import "' ..
                                            third_header .. '"\n')
                                    assert.truthy(ok, err)
                                    local first =
                                        ast[1]._type.type_members
                                            .ffi_aliased_common
                                    assert.equal(first,
                                        ast[2]._type.type_members
                                            .ffi_aliased_common)
                                    assert.equal(first,
                                        ast[3]._type.type_members
                                            .ffi_aliased_common)
                                    assert.equal(
                                        ast[1]._type.members
                                            .ffi_aliased_object.type,
                                        ast[3]._type.members
                                            .ffi_aliased_object.type)
                                end)
                        end)
                end)
        end)
    end)

    it("recognizes one pragma-once anonymous typedef", function()
        with_header([[
            #pragma once
            typedef struct {
                int value;
            } ffi_pragma_common;
        ]], function(common_header)
            local common_name =
                assert(common_header:match("([^/]+)$"))
            with_header(
                '#include "' .. common_name .. '"\n'
                .. 'extern ffi_pragma_common ffi_pragma_object;\n',
                function(first_header)
                    with_header(
                        '#include "' .. common_name .. '"\n'
                        .. 'extern ffi_pragma_common ffi_pragma_object;\n',
                        function(second_header)
                            local ok, err, ast = h.run_checker(
                                'local first = foreign import "' ..
                                    first_header .. '"\n' ..
                                'local second = foreign import "' ..
                                    second_header .. '"\n')
                            assert.truthy(ok, err)
                            assert.equal(
                                ast[1]._type.type_members.ffi_pragma_common,
                                ast[2]._type.type_members.ffi_pragma_common)
                        end)
                end)
        end)
    end)

    it("rejects a syntactic guard invalidated between wrappers", function()
        with_header([[
            #ifndef TITAN_FFI_UNDEF_COMMON
            #define TITAN_FFI_UNDEF_COMMON
            typedef struct {
                int value;
            } ffi_undef_common;
            #endif
        ]], function(common_header)
            local common_name =
                assert(common_header:match("([^/]+)$"))
            with_header(
                '#include "' .. common_name .. '"\n',
                function(first_header)
                    with_header(
                        '#undef TITAN_FFI_UNDEF_COMMON\n'
                        .. '#include "' .. common_name .. '"\n',
                        function(second_header)
                            local ok, err = h.run_checker(
                                'local first = foreign import "' ..
                                    first_header .. '"\n' ..
                                'local second = foreign import "' ..
                                    second_header .. '"\n')
                            assert.falsy(ok)
                            assert.matches(
                                "conflicting C declaration for "
                                    .. "'ffi_undef_common'",
                                err, 1, true)
                            assert.matches(
                                "rejected the final ordered foreign "
                                    .. "header context",
                                err, 1, true)
                        end)
                end)
        end)
    end)

    it("checks distinct redeclarations in source order",
    function()
        with_headers({
            [[
                extern int ffi_order_integer(int value);
                extern long ffi_order_long(long value);
            ]],
            [[
                extern int ffi_order_integer(int value);
                extern long ffi_order_long(long value);
            ]],
        }, function(first_header, second_header)
            local calls = {}
            local context, service =
                new_context_configured_probe_service({
                    runner = function(_, metadata)
                        if metadata.stage == "baseline" or
                           metadata.source:find("titan_probe_d%(") then
                            calls[#calls + 1] = metadata
                        end
                        return {
                            started = true,
                            ok = true,
                            status = 0,
                            diagnostic = "",
                        }
                    end,
                })
            local code =
                'local first = foreign import "' .. first_header .. '"\n' ..
                'local second = foreign import "' .. second_header .. '"\n'
            h.reset(true)
            local ast = assert(h.parse(code))
            local _, errors = checker.check(
                "test", ast, code, "test.titan", nil, {
                    probe_service_provider =
                        function() return service end,
                })
            assert.equal(0, #errors)
            assert.equal(3, #calls)
            assert.equal("baseline", calls[1].stage)
            assert.equal("candidate", calls[2].stage)
            assert.equal("candidate", calls[3].stage)
            assert.not_equal(calls[2].source, calls[3].source)
            assert.matches("extern int titan_probe_d%(int%)",
                calls[2].source)
            assert.matches("extern long titan_probe_d%(long%)",
                calls[3].source)
            for _, name in ipairs({
                "ffi_order_integer", "ffi_order_long",
            }) do
                assert.equal(
                    ast[1]._type.members[name].type,
                    ast[2]._type.members[name].type)
            end
            close_context_configured_probe_service(context, service)
        end)
    end)

    it("propagates production baseline exceptions through the checker",
    function()
        with_header(
            "extern int ffi_production_baseline_exception(int value);",
            function(header)
                local context = driver.new_resolver_context()
                local service, service_error =
                    driver.get_probe_service(context)
                assert.truthy(service, service_error)
                local original_module_context = service.module_context
                local cancellation = {}
                service.module_context = function(self, options)
                    local module_probe, err =
                        original_module_context(self, options)
                    assert.truthy(module_probe, err)
                    assert.equal(cprobe.ModuleContext,
                        getmetatable(module_probe))
                    module_probe.validate_baseline = function()
                        error(cancellation, 0)
                    end
                    return module_probe
                end

                local code =
                    'local ffi = foreign import "' .. header .. '"\n'
                h.reset(true)
                local ast = assert(h.parse(code))
                local result = table.pack(pcall(
                    checker.check,
                    "test", ast, code, "test.titan", nil, {
                        probe_service_provider =
                            function() return service end,
                    }))
                local closed, close_error =
                    driver.close_resolver_context(context)

                assert.is_false(result[1],
                    result[3] and table.concat(result[3], "\n"))
                assert.is_true(result[2] == cancellation)
                assert.truthy(closed, close_error)
            end)
    end)

    it("propagates production compatibility exceptions through the checker",
    function()
        with_headers({
            "extern int ffi_production_pair_exception(int value);",
            "extern int ffi_production_pair_exception(int value);",
        }, function(first_header, second_header)
            local context = driver.new_resolver_context()
            local service, service_error =
                driver.get_probe_service(context)
            assert.truthy(service, service_error)
            local original_module_context = service.module_context
            local cancellation = {}
            service.module_context = function(self, options)
                local module_probe, err =
                    original_module_context(self, options)
                assert.truthy(module_probe, err)
                assert.equal(cprobe.ModuleContext,
                    getmetatable(module_probe))
                module_probe.validate_baseline = function()
                    return { status = "success" }
                end
                module_probe.validate_declaration_compatibility =
                    function()
                        error(cancellation, 0)
                    end
                return module_probe
            end

            local code =
                'local first = foreign import "' .. first_header .. '"\n' ..
                'local second = foreign import "' .. second_header .. '"\n'
            h.reset(true)
            local ast = assert(h.parse(code))
            local result = table.pack(pcall(
                checker.check,
                "test", ast, code, "test.titan", nil, {
                    probe_service_provider =
                        function() return service end,
                }))
            local closed, close_error =
                driver.close_resolver_context(context)

            assert.is_false(result[1],
                result[3] and table.concat(result[3], "\n"))
            assert.is_true(result[2] == cancellation)
            assert.truthy(closed, close_error)
        end)
    end)

    it("normalizes an injected baseline exception as infrastructure",
    function()
        with_header(
            "extern int ffi_injected_baseline_exception(int value);",
            function(header)
                local context = driver.new_resolver_context()
                local profile_service, service_error =
                    driver.get_probe_service(context)
                assert.truthy(profile_service, service_error)
                local module_probe = {
                    validate_baseline = function()
                        error("injected baseline", 0)
                    end,
                }
                local service = {
                    profile = profile_service.profile,
                    cdriver_process_options = function()
                        return profile_service:cdriver_process_options()
                    end,
                    module_context = function()
                        return module_probe
                    end,
                }

                local code =
                    'local ffi = foreign import "' .. header .. '"\n'
                h.reset(true)
                local ast = assert(h.parse(code))
                local result = table.pack(pcall(
                    checker.check,
                    "test", ast, code, "test.titan", nil, {
                        probe_service_provider =
                            function() return service end,
                    }))
                local closed, close_error =
                    driver.close_resolver_context(context)

                assert.is_true(result[1])
                assert.matches(
                    "ordered header baseline validation failed: " ..
                        "injected baseline",
                    table.concat(result[3], "\n"), 1, true)
                assert.truthy(closed, close_error)
            end)
    end)

    it("normalizes injected declaration probe failures", function()
        with_headers({
            "extern int ffi_injected_probe(int value);",
            "extern int ffi_injected_probe(int value);",
        }, function(first_header, second_header)
            local context, profile_service =
                new_context_configured_probe_service()
            local profile = profile_service.profile

            local scenarios = {
                {
                    expected = "cannot validate a declaration pair",
                },
                {
                    probe = function()
                        return { status = "success" }
                    end,
                },
                {
                    expected = "probe returned no result",
                    probe = function() return nil end,
                },
                {
                    expected = "validation failed: injected probe",
                    probe = function()
                        error("injected probe", 0)
                    end,
                },
            }

            local candidate = {
                left_type = {},
                right_type = {},
                left_declaration = "left",
                right_declaration = "right",
            }
            for _, scenario in ipairs(scenarios) do
                local module_probe = {
                    validate_declaration_compatibility = scenario.probe,
                }
                local result =
                    checker_core.validate_foreign_declaration_compatibility(
                        module_probe, candidate.left_type, candidate.right_type,
                        candidate.left_declaration, candidate.right_declaration)
                if scenario.expected then
                    assert.equal("infrastructure_failure", result.status)
                    assert.matches(
                        scenario.expected, result.message, 1, true)
                else
                    assert.equal("success", result.status)
                end
            end

            local code =
                'local first = foreign import "' .. first_header .. '"\n' ..
                'local second = foreign import "' .. second_header .. '"\n'
            local service = {
                profile = profile,
                cdriver_process_options = function()
                    return profile_service:cdriver_process_options()
                end,
                module_context = function()
                    return {
                        validate_baseline = function()
                            return { status = "success" }
                        end,
                        validate_declaration_compatibility =
                            function() return nil end,
                    }
                end,
            }
            h.reset(true)
            local ast = assert(h.parse(code))
            local _, errors = checker.check(
                "test", ast, code, "test.titan", nil, {
                    probe_service_provider = function() return service end,
                })
            assert.matches(
                "probe returned no result",
                table.concat(errors, "\n"), 1, true)
            close_context_configured_probe_service(
                context, profile_service)
        end)
    end)

    it("reports baseline infrastructure failure without a conflict verdict",
    function()
        with_header([[
            #ifndef TITAN_FFI_INFRA_COMMON
            #define TITAN_FFI_INFRA_COMMON
            typedef struct {
                int value;
            } ffi_infra_common;
            #endif
        ]], function(common_header)
            local common_name =
                assert(common_header:match("([^/]+)$"))
            with_header(
                '#include "' .. common_name .. '"\n',
                function(first_header)
                    with_header(
                        '#include "' .. common_name .. '"\n',
                        function(second_header)
                            local calls = 0
                            local context, service =
                                new_context_configured_probe_service({
                                    runner = function()
                                        calls = calls + 1
                                        return nil,
                                            "test compiler could not be started"
                                    end,
                                })
                            local code =
                                'local first = foreign import "' ..
                                    first_header .. '"\n' ..
                                'local second = foreign import "' ..
                                    second_header .. '"\n'
                            h.reset(true)
                            local ast = assert(h.parse(code))
                            local _, errors = checker.check(
                                "test", ast, code, "test.titan", nil, {
                                    probe_service_provider =
                                        function() return service end,
                                })
                            assert.equal(1, calls)
                            local err = table.concat(errors, "\n")
                            assert.matches(
                                "cannot validate the final ordered "
                                    .. "C header context",
                                err, 1, true)
                            assert.not_matches(
                                "conflicting C declaration for "
                                    .. "'ffi_infra_common'",
                                err, 1, true)
                            close_context_configured_probe_service(
                                context, service)
                        end)
                end)
        end)
    end)

    it("rejects exact isolated repeats changed by cumulative macro state",
    function()
        with_header([[
            #ifndef TITAN_FFI_SELF_CHANGING_HEADER
            #define TITAN_FFI_SELF_CHANGING_HEADER
            extern int ffi_self_changing_object;
            #else
            extern long ffi_self_changing_object;
            #endif
        ]], function(header)
            local ok, err = h.run_checker(
                'local first = foreign import "' .. header .. '"\n' ..
                'local second = foreign import "' .. header .. '"\n')
            assert.falsy(ok)
            assert.matches(
                "final ordered C header context is invalid",
                err, 1, true)
            assert.not_matches(
                "conflicting C declaration for "
                    .. "'ffi_self_changing_object'",
                err, 1, true)
        end)
    end)

    it("does not collapse distinct macro-suppressed anonymous aliases",
    function()
        with_header([[
            typedef struct { int value; } ffi_macro_first_alias;
            extern ffi_macro_first_alias ffi_macro_shared_object;
            #define TITAN_FFI_SUPPRESS_SECOND_OBJECT 1
        ]], function(first_header)
            with_header([[
                typedef struct { int value; } ffi_macro_second_alias;
                #ifndef TITAN_FFI_SUPPRESS_SECOND_OBJECT
                extern ffi_macro_second_alias ffi_macro_shared_object;
                #endif
            ]], function(second_header)
                local ok, err, ast = h.run_checker(
                    'local first = foreign import "' ..
                        first_header .. '"\n' ..
                    'local second = foreign import "' ..
                        second_header .. '"\n')
                assert.falsy(ok)
                assert.matches(
                    "conflicting C declaration for "
                        .. "'ffi_macro_shared_object'",
                    err, 1, true)
                assert.matches(
                    "rejected the declaration compatibility candidate",
                    err, 1, true)

                local first = ast[1]._type.type_members
                    .ffi_macro_first_alias
                local second = ast[2]._type.type_members
                    .ffi_macro_second_alias
                assert.not_equal(first.target, second.target)
            end)
        end)
    end)

    it("rejects repeated named tag definitions in the final context",
    function()
        with_header([[
            struct ffi_repeated_tag {
                int first;
            };
        ]], function(first_header)
            with_header([[
                struct ffi_repeated_tag {
                    int second;
                };
            ]], function(second_header)
                local ok, err = h.run_checker(
                    'local first = foreign import "' ..
                        first_header .. '"\n' ..
                    'local second = foreign import "' ..
                        second_header .. '"\n')
                assert.falsy(ok)
                assert.matches(
                    "final ordered C header context is invalid",
                    err, 1, true)
            end)
        end)
    end)

    it("rejects one unguarded anonymous typedef emitted twice", function()
        with_header([[
            typedef struct {
                int value;
            } ffi_unguarded_common;
        ]], function(common_header)
            local common_name =
                assert(common_header:match("([^/]+)$"))
            with_header(
                '#include "' .. common_name .. '"\n'
                .. 'extern ffi_unguarded_common ffi_unguarded_object;\n',
                function(first_header)
                    with_header(
                        '#include "' .. common_name .. '"\n'
                        .. 'extern ffi_unguarded_common '
                        .. 'ffi_unguarded_object;\n',
                        function(second_header)
                            local ok, err = h.run_checker(
                                'local first = foreign import "' ..
                                    first_header .. '"\n' ..
                                'local second = foreign import "' ..
                                    second_header .. '"\n')
                            assert.falsy(ok)
                            assert.matches(
                                "conflicting C declaration for "
                                    .. "'ffi_unguarded_common'",
                                err, 1, true)
            end)
        end)
    end)
    end)

    it("rejects repeated anonymous declarations within one import", function()
        for _, case in ipairs({
            {
                name = "ffi_repeated_anonymous_typedef",
                source = [[
                    typedef struct { int value; }
                        ffi_repeated_anonymous_typedef;
                    typedef struct { int value; }
                        ffi_repeated_anonymous_typedef;
                ]],
            },
            {
                name = "ffi_repeated_anonymous_object",
                source = [[
                    extern struct { int value; }
                        ffi_repeated_anonymous_object;
                    extern struct { int value; }
                        ffi_repeated_anonymous_object;
                ]],
            },
        }) do
            with_header(case.source, function(header)
                local ok, err = h.run_checker(
                    'local c = foreign import "' .. header .. '"\n')
                assert.falsy(ok)
                assert.matches(
                    "final ordered C header context is invalid",
                    err, 1, true)
            end)
        end
    end)

    it("rejects repeated same-kind tag definitions within one import",
    function()
        for _, source in ipairs({
            [[
                struct ffi_repeated_tag_one_header { int value; };
                struct ffi_repeated_tag_one_header { int value; };
            ]],
            [[
                union ffi_repeated_union_one_header { int value; };
                union ffi_repeated_union_one_header { int value; };
            ]],
            [[
                enum ffi_repeated_enum_one_header { FFI_REPEAT_VALUE = 1 };
                enum ffi_repeated_enum_one_header { FFI_REPEAT_VALUE = 1 };
            ]],
        }) do
            with_header(source, function(header)
                local ok, err = h.run_checker(
                    'local c = foreign import "' .. header .. '"\n')
                assert.falsy(ok)
                assert.matches(
                    "final ordered C header context is invalid",
                    err, 1, true)
            end)
        end
    end)
end)
