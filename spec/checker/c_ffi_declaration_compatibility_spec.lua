local h = require "spec.support.helpers"
local checker = require "titan-compiler.checker"
local cdriver = require "c-parser.cdriver"
local cprobe = require "titan-compiler.cprobe"
local driver = require "titan-compiler.driver"
local lfs = require "lfs"
local types = require "titan-compiler.types"

-- Authored headers share a real directory so ordinary relative #includes use
-- the same search rules as a project. No aliases or reconstructed declarations
-- are needed to establish one module-wide C environment.
local function with_headers(contents, fn)
    local directory = os.tmpname()
    assert(os.remove(directory))
    assert(lfs.mkdir(directory))
    local headers = {}
    local result = table.pack(pcall(function()
        for index, source in ipairs(contents) do
            local filename = directory .. "/header" .. index .. ".h"
            headers[#headers + 1] = filename
            local file = assert(io.open(filename, "w"))
            assert(file:write(source))
            assert(file:close())
        end
        return fn(headers)
    end))
    for _, filename in ipairs(headers) do os.remove(filename) end
    assert(lfs.rmdir(directory))
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
end

local function imports(headers)
    local source = {}
    for _, header in ipairs(headers) do
        source[#source + 1] = 'foreign import "' .. header .. '"\n'
    end
    return table.concat(source)
end

local function checked(contents, body)
    return with_headers(contents, function(headers)
        local ok, err, ast = h.run_checker(imports(headers) .. (body or ""))
        assert.truthy(ok, err)
        return ast._ffi_namespace._type, ast
    end)
end

local function rejected(contents)
    with_headers(contents, function(headers)
        local ok, err = h.run_checker(imports(headers))
        assert.falsy(ok)
        assert.matches("final ordered C header context is invalid", err, 1, true)
        assert.matches("configured C compiler rejected", err, 1, true)
        assert.not_matches("declaration compatibility candidate", err, 1, true)
    end)
end

local function bound(typ)
    typ = types.resolve_c_typedef(typ)
    if typ._tag == "Type.CArray" then return typ.len end
    if typ._tag == "Type.CPointer" then return bound(typ.pointee) end
end

local function with_service(options, fn)
    local context = driver.new_resolver_context()
    local result = table.pack(pcall(function()
        local configured, err = driver.configure_foreign_c(context)
        assert.truthy(configured, err)
        options.toolchain = assert(driver.toolchain_descriptor(context))
        local service = assert(cprobe.new_service(options))
        local outcome = table.pack(pcall(fn, service))
        local closed, close_error = service:close()
        assert.truthy(closed, close_error)
        if not outcome[1] then error(outcome[2], 0) end
        return table.unpack(outcome, 2, outcome.n)
    end))
    local closed, close_error = driver.close_resolver_context(context)
    assert.truthy(closed, close_error)
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
end

local function check_with_service(code, service)
    h.reset(true)
    local ast = assert(h.parse(code))
    local _, errors = checker.check("test", ast, code, "test.titan", nil, {
        probe_service_provider = function() return service end,
    })
    return errors, ast
end

describe("C declarations in one module-wide ffi environment", function()
    it("retains consistent complete parameter names", function()
        local ffi = checked({
            "extern int ffi_named(int value);",
            "extern int ffi_named(int value);",
        }, [[
            function run(): integer
                return ffi.ffi_named { value = 1 }
            end
        ]])
        assert.same({ "value" }, ffi.members.ffi_named.paramnames)
    end)

    it("retains complete names across unnamed declarations in either order", function()
        for _, sources in ipairs({
            { "extern int ffi_named(int);", "extern int ffi_named(int value);",
              "extern int ffi_named(int);" },
            { "extern int ffi_named(int value);", "extern int ffi_named(int);" },
        }) do
            local ffi = checked(sources, [[
                function run(): integer
                    return ffi.ffi_named { value = 1 }
                end
            ]])
            assert.same({ "value" }, ffi.members.ffi_named.paramnames)
        end
    end)

    it("permanently disables named calls after differing complete lists", function()
        with_headers({
            "extern int ffi_named(int first);",
            "extern int ffi_named(int second);",
            "extern int ffi_named(int first);",
        }, function(headers)
            local source = imports(headers)
            local ok, err, ast = h.run_checker(source .. [[
                function positional(): integer return ffi.ffi_named(1) end
            ]])
            assert.truthy(ok, err)
            assert.is_false(ast._ffi_namespace._type.members.ffi_named.paramnames)
            ok, err = h.run_checker(source .. [[
                function named(): integer
                    return ffi.ffi_named { first = 1 }
                end
            ]])
            assert.falsy(ok)
            assert.matches("parameter names are unavailable for foreign function 'ffi.ffi_named'",
                err, 1, true)
        end)
    end)

    it("retains names in array and callback abstract-declarator repeats", function()
        local ffi = checked({ [[
            extern int ffi_array(int values[7]);
            extern int ffi_callback(int (*callback)(double));
            extern int ffi_array_pointer(int (*values)[7]);
        ]], [[
            extern int ffi_array(int [7]);
            extern int ffi_callback(int (*)(double));
            extern int ffi_array_pointer(int (*)[7]);
        ]] })
        assert.same({ "values" }, ffi.members.ffi_array.paramnames)
        assert.same({ "callback" }, ffi.members.ffi_callback.paramnames)
        assert.same({ "values" }, ffi.members.ffi_array_pointer.paramnames)
        assert.equal("Type.CPointer", ffi.members.ffi_array.type.params[1]._tag)
        assert.equal("Type.CFunction", ffi.members.ffi_callback.type.params[1].pointee._tag)
        assert.equal(7, bound(ffi.members.ffi_array_pointer.type.params[1]))
    end)

    it("accepts function and object redeclarations through equivalent typedefs", function()
        local ffi = checked({ [[
            typedef long ffi_public_offset_t;
            extern int ffi_lock(int fd, ffi_public_offset_t offset);
            extern ffi_public_offset_t ffi_cursor;
        ]], [[
            typedef long ffi_internal_offset_t;
            extern int ffi_lock(int fd, ffi_internal_offset_t offset);
            extern ffi_internal_offset_t ffi_cursor;
        ]] }, [[
            function run(): integer return ffi.ffi_lock(1, ffi.ffi_cursor) end
        ]])
        assert.same({ "fd", "offset" }, ffi.members.ffi_lock.paramnames)
        assert.equal("long", types.resolve_c_typedef(ffi.members.ffi_cursor.type).spelling)
    end)

    it("merges named-call metadata through equivalent typedef spellings", function()
        local ffi = checked({ [[
            typedef long ffi_first;
            extern int ffi_named(ffi_first);
        ]], [[
            typedef long ffi_second;
            extern int ffi_named(ffi_second value);
        ]] }, [[
            function run(): integer return ffi.ffi_named { value = 1 } end
        ]])
        assert.same({ "value" }, ffi.members.ffi_named.paramnames)
    end)

    it("forms a prototype composite from an old-style declaration in either order", function()
        for _, sources in ipairs({
            { "extern int ffi_composite();", "extern int ffi_composite(int value);" },
            { "extern int ffi_composite(int value);", "extern int ffi_composite();" },
        }) do
            local ffi = checked(sources, [[
                function run(): integer return ffi.ffi_composite { value = 1 } end
            ]])
            local member = ffi.members.ffi_composite
            assert.equal("prototype", member.type._paramstyle)
            assert.equal(1, #member.type.params)
            assert.same({ "value" }, member.paramnames)
        end
    end)

    it("normalizes typedef and direct pointee qualifiers", function()
        local ffi = checked({ [[
            typedef const int ffi_const_int;
            extern ffi_const_int *ffi_pointer;
            extern ffi_const_int ffi_scalar;
            extern ffi_const_int ffi_values[3];
        ]], [[
            extern const int *ffi_pointer;
            extern const int ffi_scalar;
            extern const int ffi_values[3];
        ]] })
        assert.equal("Type.CPointer", ffi.members.ffi_pointer.type._tag)
        assert.equal(3, bound(ffi.members.ffi_values.type))
        assert.truthy(ffi.members.ffi_scalar)
    end)

    it("forms a known-bound array composite in either order", function()
        for _, sources in ipairs({
            { "extern int ffi_values[];", "extern int ffi_values[7];" },
            { "extern int ffi_values[7];", "extern int ffi_values[];" },
        }) do
            local ffi = checked(sources)
            assert.equal("Type.CArray", ffi.members.ffi_values.type._tag)
            assert.equal(7, bound(ffi.members.ffi_values.type))
        end
    end)

    it("completes only the redeclared object without mutating its array typedef", function()
        for _, sources in ipairs({
            { [[typedef int ffi_array[];
                extern ffi_array ffi_values;
                extern ffi_array ffi_untouched;]],
              "extern int ffi_values[7];" },
            { "extern int ffi_values[7];",
              [[typedef int ffi_array[];
                extern ffi_array ffi_values;
                extern ffi_array ffi_untouched;]] },
        }) do
            local ffi = checked(sources)
            assert.equal(7, bound(ffi.members.ffi_values.type))
            assert.equal("", bound(ffi.type_members.ffi_array))
            assert.equal("", bound(ffi.members.ffi_untouched.type))
        end
    end)

    it("completes nested pointer and function arrays without mutating other uses", function()
        local ffi = checked({ [[
            typedef int ffi_unknown_array[];
            typedef ffi_unknown_array *ffi_unknown_pointer;
            extern ffi_unknown_array *ffi_pointer;
            extern ffi_unknown_array *ffi_untouched;
            extern int ffi_function(ffi_unknown_pointer value);
            extern int ffi_function_untouched(ffi_unknown_pointer value);
        ]], [[
            typedef int ffi_known_array[7];
            typedef ffi_known_array *ffi_known_pointer;
            extern ffi_known_array *ffi_pointer;
            extern int ffi_function(ffi_known_pointer value);
        ]] })
        assert.equal(7, bound(ffi.members.ffi_pointer.type))
        assert.equal(7, bound(ffi.members.ffi_function.type.params[1]))
        assert.equal("", bound(ffi.members.ffi_untouched.type))
        assert.equal("", bound(ffi.members.ffi_function_untouched.type.params[1]))
        assert.equal("", bound(ffi.type_members.ffi_unknown_array))
    end)

    it("retains exact pointer, array, and function declarator ordering", function()
        local ffi = checked({ [[
            extern int *ffi_pointer_array[3];
            extern int (*ffi_array_pointer)[3];
            extern int (*ffi_callbacks[2])(int);
            extern int (*ffi_row_factory(void))[3];
        ]] })
        local members = ffi.members
        local array = members.ffi_pointer_array.type
        assert.equal("Type.CArray", array._tag)
        assert.equal(3, array.len)
        assert.equal("Type.CPointer", array.elem._tag)
        local pointer = members.ffi_array_pointer.type
        assert.equal("Type.CPointer", pointer._tag)
        assert.equal("Type.CArray", pointer.pointee._tag)
        assert.equal(3, pointer.pointee.len)
        local callbacks = members.ffi_callbacks.type
        assert.equal("Type.CArray", callbacks._tag)
        assert.equal(2, callbacks.len)
        assert.equal("Type.CFunction", callbacks.elem.pointee._tag)
        local factory = members.ffi_row_factory.type
        assert.equal("Type.CFunction", factory._tag)
        assert.equal("Type.CPointer", factory.ret._tag)
        assert.equal("Type.CArray", factory.ret.pointee._tag)
        assert.equal(3, factory.ret.pointee.len)
    end)

    it("adjusts matrix and bare callback parameters to their pointer forms", function()
        local ffi = checked({ [[
            extern int ffi_matrix(int values[][3]);
            extern int ffi_callback(int callback(void));
            extern int ffi_qualifiers(const int value, int * const pointer);
        ]], [[
            extern int ffi_matrix(int (*values)[3]);
            extern int ffi_callback(int (*callback)(void));
            extern int ffi_qualifiers(int value, int *pointer);
        ]] })
        local matrix = ffi.members.ffi_matrix.type.params[1]
        assert.equal("Type.CPointer", matrix._tag)
        assert.equal("Type.CArray", matrix.pointee._tag)
        assert.equal(3, matrix.pointee.len)
        local callback = ffi.members.ffi_callback.type.params[1]
        assert.equal("Type.CPointer", callback._tag)
        assert.equal("Type.CFunction", callback.pointee._tag)
        assert.same({ "value", "pointer" }, ffi.members.ffi_qualifiers.paramnames)
    end)

    it("preserves qualified nonvoid and void returns through typedefs", function()
        local ffi = checked({ [[
            typedef const int ffi_const_int;
            typedef const void ffi_const_void;
            extern ffi_const_int ffi_number(void);
            extern ffi_const_void ffi_nothing(void);
        ]], [[
            extern const int ffi_number(void);
            extern const void ffi_nothing(void);
        ]] })
        assert.equal("Type.CInteger", types.resolve_c_typedef(ffi.members.ffi_number.type.ret)._tag)
        assert.equal("Type.CVoid", types.resolve_c_typedef(ffi.members.ffi_nothing.type.ret)._tag)
    end)

    it("accepts nested aliased callbacks in direct, array, and returned value paths", function()
        checked({ [[
            typedef int ffi_first_int;
            typedef int ffi_second_int;
            typedef ffi_first_int (*ffi_first_callback)(ffi_first_int);
            typedef ffi_second_int (*ffi_second_callback)(ffi_second_int);
            typedef ffi_first_callback (*ffi_first_factory)(void);
            typedef ffi_second_callback (*ffi_second_factory)(void);
            typedef ffi_first_callback *ffi_first_pointer;
            typedef ffi_second_callback *ffi_second_pointer;
            extern ffi_first_callback ffi_get_callback(void);
            extern void ffi_take_callback(ffi_second_callback callback);
            extern ffi_first_callback ffi_callbacks[4];
            extern ffi_first_int ffi_direct(ffi_first_int value);
            extern ffi_first_factory ffi_get_factory(void);
            extern void ffi_take_factory(ffi_second_factory factory);
            extern ffi_first_pointer ffi_get_pointer(void);
            extern void ffi_take_pointer(ffi_second_pointer pointer);
        ]] }, [[
            local function use()
                ffi.ffi_take_callback(ffi.ffi_get_callback())
                ffi.ffi_take_callback(ffi.ffi_callbacks[0])
                ffi.ffi_take_callback(ffi.ffi_direct)
                ffi.ffi_take_factory(ffi.ffi_get_factory())
                ffi.ffi_take_pointer(ffi.ffi_get_pointer())
            end
        ]])
    end)

    it("accepts callback parameter qualification and incomplete array compatibility", function()
        checked({ [[
            typedef void (*ffi_plain)(int *);
            typedef void (*ffi_qualified)(int * const);
            extern ffi_plain ffi_get(void);
            extern void ffi_take(ffi_qualified callback);
            typedef int ffi_unknown_array[];
            typedef int ffi_known_array[7];
            typedef void (*ffi_unknown)(ffi_unknown_array *);
            typedef void (*ffi_known)(ffi_known_array *);
            extern ffi_unknown ffi_get_array(void);
            extern void ffi_take_array(ffi_known callback);
        ]] }, [[
            local function use()
                ffi.ffi_take(ffi.ffi_get())
                ffi.ffi_take_array(ffi.ffi_get_array())
            end
        ]])
    end)

    for _, case in ipairs({
        { "enum and numeric bounds", "enum { FFI_BOUND = 3 }; extern int ffi_values[FFI_BOUND];",
          "extern int ffi_values[3];" },
        { "repeated sizeof bounds", "extern int ffi_values[sizeof(int)];",
          "extern int ffi_values[sizeof(int)];" },
        { "pointer-to-array sizeof bounds", "extern int ffi_values[sizeof(int (*)[3])];",
          "extern int ffi_values[sizeof(void *)];" },
        { "callback sizeof bounds", "extern int ffi_values[sizeof(int (*)(double))];",
          "extern int ffi_values[sizeof(int (*)(double))];" },
        { "static callback array sizeof bounds", "extern int ffi_values[sizeof(int (*)(int [static 3]))];",
          "extern int ffi_values[sizeof(int (*)(int [static 3]))];" },
    }) do
        it("accepts C-equivalent " .. case[1], function()
            local ffi = checked({ case[2], case[3] })
            assert.equal("Type.CArray", ffi.members.ffi_values.type._tag)
        end)
    end

    it("lets earlier macros suppress later declarations before type conversion", function()
        local ffi = checked({ [[
            extern int ffi_values[];
            #define FFI_SUPPRESS_BOUND 1
        ]], [[
            #ifndef FFI_SUPPRESS_BOUND
            extern int ffi_values[3];
            #endif
        ]], [[
            #ifndef FFI_SUPPRESS_BOUND
            extern int ffi_values[4];
            #endif
        ]] })
        assert.equal("", bound(ffi.members.ffi_values.type))
    end)

    it("uses final redefinition and undef state for macro members", function()
        local ffi = checked({ [[
            #define FFI_REDEFINED 1
            #define FFI_REMOVED 3
        ]], [[
            #undef FFI_REDEFINED
            #define FFI_REDEFINED 2.5
            #undef FFI_REMOVED
        ]] }, [[
            function number(): float return ffi.FFI_REDEFINED end
        ]])
        assert.equal("Type.CFloat", ffi.members.FFI_REDEFINED.type._tag)
        assert.is_nil(ffi.members.FFI_REMOVED)
    end)

    it("uses an active type macro that shadows an earlier typedef", function()
        local ffi = checked({ [[
            typedef int ffi_number;
            typedef double ffi_replacement;
            #define ffi_number ffi_replacement
        ]] }, [[
            function identity(x: float): float
                local converted = x as ffi.ffi_number
                return converted as float
            end
        ]])
        local alias = ffi.type_members.ffi_number
        assert.equal("ffi_number", alias.name)
        assert.equal("Type.CFloat", types.resolve_c_typedef(alias)._tag)
        assert.equal("double", types.resolve_c_typedef(alias).spelling)
        assert.is_nil(ffi.members.ffi_number)
    end)

    it("uses only the active conditional declaration of a shared C name", function()
        local ffi = checked({ "#define FFI_SUPPRESS_FIRST 1", [[
            #ifndef FFI_SUPPRESS_FIRST
            extern int ffi_conditional(void);
            #endif
        ]], "extern double ffi_conditional(void);" })
        assert.equal("Type.CFloat", ffi.members.ffi_conditional.type.ret._tag)
    end)

    it("keeps distinct anonymous aliases when one conflicting object is suppressed", function()
        local ffi = checked({ [[
            typedef struct { int value; } ffi_first;
            extern ffi_first ffi_object;
            #define FFI_SUPPRESS_SECOND 1
        ]], [[
            typedef struct { int value; } ffi_second;
            #ifndef FFI_SUPPRESS_SECOND
            extern ffi_second ffi_object;
            #endif
        ]] })
        assert.not_equal(ffi.type_members.ffi_first.target, ffi.type_members.ffi_second.target)
        assert.equal(ffi.type_members.ffi_first,
            ffi.members.ffi_object.type)
    end)

    it("parses one guarded anonymous definition through repeated real includes", function()
        local ffi = checked({ [[
            #ifndef FFI_COMMON
            #define FFI_COMMON
            typedef struct { int values[4]; } ffi_common, ffi_second;
            #endif
        ]], [[
            #include "header1.h"
            typedef ffi_common ffi_outer_a;
            extern ffi_outer_a ffi_object;
        ]], [[
            #include "./header1.h"
            typedef ffi_second ffi_outer_b;
            extern ffi_outer_b ffi_object;
        ]] })
        assert.equal(types.resolve_c_typedef(ffi.type_members.ffi_outer_a),
            types.resolve_c_typedef(ffi.type_members.ffi_outer_b))
        assert.equal(types.resolve_c_typedef(ffi.type_members.ffi_common),
            types.resolve_c_typedef(ffi.members.ffi_object.type))
    end)

    it("honors pragma once for repeated inclusion of the same authored header", function()
        local ffi = checked({ [[
            #pragma once
            typedef struct { int value; } ffi_common;
        ]], [[
            #include "header1.h"
            extern ffi_common ffi_object;
        ]], [[
            #include "header1.h"
            extern ffi_common ffi_object;
        ]] })
        assert.equal(ffi.type_members.ffi_common, ffi.members.ffi_object.type)
    end)

    it("shares an anonymous union only among declarators of that definition", function()
        local ffi = checked({ [[
            typedef union { int number; double fraction; } ffi_first, ffi_second;
            typedef union { int number; double fraction; } ffi_distinct;
        ]] })
        local first = types.resolve_c_typedef(ffi.type_members.ffi_first)
        local second = types.resolve_c_typedef(ffi.type_members.ffi_second)
        local distinct = types.resolve_c_typedef(ffi.type_members.ffi_distinct)
        assert.equal("Type.CUnion", first._tag)
        assert.equal(first, second)
        assert.not_equal(first, distinct)
    end)

    it("keeps incompatible callback signatures strict at direct argument boundaries", function()
        with_headers({ [[
            typedef void (*ffi_mutable_callback)(int *);
            typedef void (*ffi_const_callback)(const int *);
            extern ffi_mutable_callback ffi_get_callback(void);
            extern void ffi_take_callback(ffi_const_callback callback);
        ]] }, function(headers)
            local ok, err = h.run_checker(imports(headers) .. [[
                local function use()
                    ffi.ffi_take_callback(ffi.ffi_get_callback())
                end
            ]])
            assert.falsy(ok)
            assert.matches("types in argument 1", err, 1, true)
            assert.matches("ffi_take_callback", err, 1, true)
        end)
    end)

    it("keeps a guarded prototype-local tag out of the file-scope namespace", function()
        local ffi = checked({ [[
            #ifndef FFI_LOCAL_TAG
            #define FFI_LOCAL_TAG
            extern int ffi_function(struct ffi_local *value);
            #endif
        ]], '#include "header1.h"', '#include "./header1.h"' })
        assert.is_nil(ffi.type_members.ffi_local)
        assert.equal("Type.CStruct", ffi.members.ffi_function.type.params[1].pointee._tag)
    end)

    for _, case in ipairs({
        { "old-style promotion conflicts", "extern int ffi_conflict();",
          "extern int ffi_conflict(char value);" },
        { "top-level object qualifier conflicts", "extern const int ffi_conflict;",
          "extern int ffi_conflict;" },
        { "resolved function parameter conflicts", "extern int ffi_conflict(long value);",
          "extern int ffi_conflict(int value);" },
        { "one typedef with different resolved types", "typedef int ffi_conflict;",
          "typedef double ffi_conflict;" },
        { "distinct named aggregate aliases", "struct ffi_first { int value; }; typedef struct ffi_first ffi_conflict;",
          "struct ffi_second { int value; }; typedef struct ffi_second ffi_conflict;" },
        { "distinct anonymous aggregate aliases", "typedef struct { int value; } ffi_conflict;",
          "typedef struct { int value; } ffi_conflict;" },
        { "unguarded prototype-local tag repeats", "extern int ffi_conflict(struct ffi_local *value);",
          "extern int ffi_conflict(struct ffi_local *value);" },
        { "unequal symbolic array bounds", "enum { FFI_BOUND = 3 }; extern int ffi_conflict[FFI_BOUND];",
          "extern int ffi_conflict[4];" },
        { "repeated named struct definitions", "struct ffi_conflict { int first; };",
          "struct ffi_conflict { int second; };" },
        { "repeated named union definitions", "union ffi_conflict { int first; };",
          "union ffi_conflict { int second; };" },
        { "repeated named enum definitions", "enum ffi_conflict { FFI_VALUE = 1 };",
          "enum ffi_conflict { FFI_VALUE = 1 };" },
    }) do
        it("rejects " .. case[1] .. " in the combined context", function()
            rejected({ case[2], case[3] })
        end)
    end

    it("rejects a header guard explicitly invalidated before another include", function()
        rejected({ [[
            #ifndef FFI_GUARDED
            #define FFI_GUARDED
            typedef struct { int value; } ffi_conflict;
            #endif
        ]], [[
            #undef FFI_GUARDED
            #include "header1.h"
        ]] })
    end)

    it("preserves repeated directives so a state-changing header can conflict", function()
        with_headers({ [[
            #ifndef FFI_REPEAT
            #define FFI_REPEAT
            extern int ffi_conflict;
            #else
            extern long ffi_conflict;
            #endif
        ]] }, function(headers)
            local ok, err = h.run_checker(imports({ headers[1], headers[1] }))
            assert.falsy(ok)
            assert.matches("final ordered C header context is invalid", err, 1, true)
        end)
    end)

    it("validates one module baseline without per-name reconciliation probes", function()
        with_headers({ [[
            extern int ffi_first(int value);
            extern long ffi_second(long value);
        ]], [[
            extern int ffi_first(int value);
            extern long ffi_second(long value);
        ]] }, function(headers)
            local calls, contexts = {}, 0
            with_service({ runner = function(argv, metadata)
                calls[#calls + 1] = metadata
                return cdriver.capture_command(argv)
            end }, function(service)
                local module_context = service.module_context
                service.module_context = function(self, options)
                    contexts = contexts + 1
                    local context = assert(module_context(self, options))
                    context.validate_declaration_compatibility = function()
                        error("obsolete declaration-pair validation was called")
                    end
                    return context
                end
                local errors, ast = check_with_service(imports(headers), service)
                assert.equal(0, #errors, table.concat(errors, "\n"))
                assert.equal(1, contexts)
                assert.equal(1, #calls)
                assert.equal("baseline", calls[1].stage)
                assert.not_matches("titan_probe_d", calls[1].source, 1, true)
                assert.truthy(ast._ffi_namespace._type.members.ffi_first)
                assert.truthy(ast._ffi_namespace._type.members.ffi_second)
                assert.is_nil(ast[1]._type)
                assert.is_nil(ast[2]._type)
            end)
        end)
    end)

    it("propagates cancellation from the production baseline unchanged", function()
        with_headers({ "extern int ffi_value;" }, function(headers)
            with_service({}, function(service)
                local module_context = service.module_context
                local cancellation = {}
                service.module_context = function(self, options)
                    local context = assert(module_context(self, options))
                    assert.equal(cprobe.ModuleContext, getmetatable(context))
                    context.validate_baseline = function() error(cancellation, 0) end
                    return context
                end
                local ok, err = pcall(check_with_service, imports(headers), service)
                assert.is_false(ok)
                assert.is_true(err == cancellation)
            end)
        end)
    end)

    it("reports an injected baseline exception as infrastructure failure", function()
        with_headers({ "extern int ffi_value;" }, function(headers)
            with_service({}, function(service)
                local adapter = {
                    profile = service.profile,
                    cdriver_process_options = function()
                        return service:cdriver_process_options()
                    end,
                    module_context = function()
                        return { validate_baseline = function()
                            error("injected baseline", 0)
                        end }
                    end,
                }
                local errors = check_with_service(imports(headers), adapter)
                assert.matches("ordered header baseline validation failed: injected baseline",
                    table.concat(errors, "\n"), 1, true)
            end)
        end)
    end)

    it("reports an unavailable baseline compiler without a declaration conflict", function()
        with_headers({ "extern int ffi_value;" }, function(headers)
            local calls = 0
            with_service({ runner = function()
                calls = calls + 1
                return nil, "test compiler could not be started"
            end }, function(service)
                local errors = check_with_service(imports(headers), service)
                local err = table.concat(errors, "\n")
                assert.equal(1, calls)
                assert.matches("cannot validate the final ordered C header context", err, 1, true)
                assert.not_matches("conflicting C declaration", err, 1, true)
            end)
        end)
    end)

    for _, case in ipairs({
        {
            name = "the enum query is rejected",
            result = { status = "rejected", accepted = false,
                message = "injected enum query rejection" },
            diagnostic = "cannot validate C enum type",
            detail = "injected enum query rejection",
        },
        {
            name = "the enum query infrastructure fails",
            result = { status = "infrastructure_failure",
                message = "injected enum compiler startup failure" },
            diagnostic = "cannot validate C enum type",
            detail = "injected enum compiler startup failure",
        },
        {
            name = "the enum query reports multiple carriers",
            result = { status = "success", accepted = true,
                selection = { kind = "enum_carrier", match_count = 2,
                    carrier_id = 3 } },
            diagnostic = "configured C compiler reported multiple carriers",
        },
    }) do
        it("rejects enum values when " .. case.name, function()
            with_headers({ [[
                typedef enum ffi_probe_enum {
                    FFI_PROBE_NEGATIVE = -1, FFI_PROBE_POSITIVE = 1
                } ffi_probe_enum;
                extern ffi_probe_enum ffi_enum_value;
            ]] }, function(headers)
                with_service({}, function(service)
                    local queries = 0
                    local module_context = service.module_context
                    service.module_context = function(self, options)
                        local context = assert(module_context(self, options))
                        context.select_enum_carrier = function(_, typ, eligible_ids)
                            queries = queries + 1
                            assert.truthy(types.resolve_c_typedef(typ)._c_enum_identity)
                            assert.is_true(#eligible_ids >= 2)
                            return case.result
                        end
                        return context
                    end
                    local source = imports(headers)
                    local unused_errors = check_with_service(source, service)
                    assert.equal(0, #unused_errors, table.concat(unused_errors, "\n"))
                    assert.equal(0, queries)

                    local errors = check_with_service(source .. [[
                        function run(): integer
                            return ffi.ffi_enum_value as integer
                        end
                    ]], service)
                    local err = table.concat(errors, "\n")
                    assert.is_true(queries > 0)
                    assert.is_true(#errors > 0)
                    assert.matches(case.diagnostic, err, 1, true)
                    if case.detail then assert.matches(case.detail, err, 1, true) end
                    assert.not_matches("full range fits in lua_Integer", err, 1, true)
                    assert.not_matches("conflicting C declaration", err, 1, true)
                end)
            end)
        end)
    end
end)
