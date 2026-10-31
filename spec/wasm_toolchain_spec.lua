local temporary = require "spec.support.temporary"
local toolchain = require "spec.support.browser_toolchain"
local fixtures = require "spec.support.browser_fixtures"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local cprobe = require "titan-compiler.cprobe"
local driver = require "titan-compiler.driver"
local incremental = require "titan-compiler.incremental"
local compiler_io = require "titan-compiler.io"
local nominallayout = require "titan-compiler.nominallayout"
local objectmetadata = require "titan-compiler.objectmetadata"
local parser = require "titan-compiler.parser"
local staticmetadata = require "titan-compiler.staticmetadata"
local types = require "titan-compiler.types"
local util = require "titan-compiler.util"
local version = require "titan-compiler.version"

local function run_tool(strategy, base_argv, extra_args)
    local argv = {}
    for _, arg in ipairs(base_argv) do argv[#argv + 1] = arg end
    for _, arg in ipairs(extra_args) do argv[#argv + 1] = arg end
    local res = strategy:run(argv, { stderr_to_stdout = true })
    assert.is_true(res.ok, res.output or res.diagnostic or "command failed")
    return res
end

local function generate_titan_c(modname, root, stem, source)
    local saved_registry = types.registry
    local saved_imported = driver.imported
    local filename = root .. "/" .. stem .. ".titan"
    local ffi_header = root .. "/" .. stem .. ".ffi.h"
    local ok, code_or_err, entry, layouts, ffi_path = xpcall(function()
        types.registry = {}
        driver.imported = {}
        local ast, parse_err = parser.parse(filename, source)
        assert.truthy(ast, parse_err)
        local modtype, errors = checker.check(modname, ast, source, filename)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        local header_plan = assert(driver.plan_foreign_header(modname, ast, filename))
        assert(driver.validate_foreign_header_plan(header_plan))
        assert(util.set_file_contents(ffi_header, header_plan.ffi_contents or "/* empty */\n"))
        local generated = assert(coder.generate(
            modname, ast, {}, version.TITAN_ABI_VERSION, true, {
                nominal_layouts = {},
                foreign_header_plan = header_plan,
            }))
        local source_entry = {
            kind = "source",
            type = ast._declared_type or modtype,
            filename = filename,
            source_files = { filename },
            deps = {},
            declared_registry = ast._declared_registry,
        }
        local source_payload = assert(objectmetadata.encode(source_entry, {
            layouts = generated.encoded_layouts,
        }))
        local source_decl = assert(objectmetadata.render(
            source_payload,
            "titan_object_source_" .. driver.mangle_module_name(modname)))
        return generated.parts[1].code .. "\n" .. source_decl,
            source_entry, generated.encoded_layouts, ffi_header
    end, debug.traceback)
    types.registry = saved_registry
    driver.imported = saved_imported
    assert.is_true(ok, code_or_err)
    return code_or_err, entry, layouts, ffi_path
end

describe("Wasm real-toolchain object and archive metadata", function()
    local strategy = compiler_io.new_sync()
    local cleanup_files, cleanup_dirs

    before_each(function()
        cleanup_files = {}
        cleanup_dirs = {}
    end)

    after_each(function()
        for index = #cleanup_files, 1, -1 do
            os.remove(cleanup_files[index])
        end
        for index = #cleanup_dirs, 1, -1 do
            strategy:rmdir(cleanup_dirs[index])
        end
    end)

    local function temp_workspace()
        local root = temporary.name("-wasm-tc")
        assert(strategy:mkdir(root))
        cleanup_dirs[#cleanup_dirs + 1] = root
        return root
    end

    local function track_file(path)
        cleanup_files[#cleanup_files + 1] = path
        return path
    end

    it("reads untouched generated .titan.meta, .titan.source and .titan.cprobe from emcc 6.0.13 and upstream clang", function()
        local info, why = toolchain.require()
        if not info then pending(why) return end

        local root = temp_workspace()
        local alpha_source = [[
record Counter
    value: integer
end

union Choice
    None()
    Some(integer)
end

function add(a: integer, b: integer): integer
    local c = Counter.new(a + b)
    return c.value
end
]]
        local c_code, source_entry, expected_layouts, alpha_ffi = generate_titan_c(
            "wasm_alpha", root, "wasm_alpha", alpha_source)
        track_file(alpha_ffi)
        assert.matches("#elif defined(__ELF__) || defined(_WIN32) || defined(__wasm__)", c_code, 1, true)
        assert.matches("TITAN_META_SECTION TITAN_META_NO_ADDRESS_SANITIZE", c_code, 1, true)
        assert.matches("TITAN_SOURCE_META_SECTION TITAN_SOURCE_META_NO_ADDRESS_SANITIZE", c_code, 1, true)

        local probe_tail = [[
enum probe_check { NEG = -1, POS = 1 };
extern enum probe_check probe_val;
__attribute__((used, aligned(1), section(".titan.cprobe")))
__attribute__((no_sanitize("address")))
static const unsigned char wasm_probe_bytes[] = {
    84, 73, 84, 69, 78, 85, 77, 0, 1, 12,
    __builtin_types_compatible_p(__typeof__(&probe_val), int *), 6
};
]]
        local c_path = track_file(root .. "/wasm_alpha.c")
        assert(util.set_file_contents(c_path, c_code .. "\n" .. probe_tail))

        local core = require "titan-compiler.coder.core"
        require "titan-compiler.coder.module"
        local expected_types = types.serialize(source_entry.type)
        local public_payload = assert(staticmetadata.render(
            "wasm_alpha", version.TITAN_ABI_VERSION,
            expected_types, expected_layouts))
        local source_payload = assert(objectmetadata.encode(source_entry, {
            layouts = expected_layouts,
        }))
        local clang_fixture_code = util.render(core.coder.modmetadata, {
            METADATANAME = "wasm_alpha_metadata",
            METADATA = assert(staticmetadata.c_initializer(public_payload)),
        }) .. assert(objectmetadata.render(
            source_payload, "titan_object_source_wasm_alpha")) .. "\n" .. probe_tail
        local clang_c_path = track_file(root .. "/wasm_alpha_clang_fixture.c")
        assert(util.set_file_contents(clang_c_path, clang_fixture_code))

        local include_root = "-I" .. root
        local include_runtime = "-I" .. info.prefix .. "/include"
        local include_lua = "-I" .. info.prefix .. "/lib/browser/include"
        local emcc_obj = track_file(root .. "/wasm_alpha.emcc.o")
        local clang_obj = track_file(root .. "/wasm_alpha.clang.o")

        run_tool(strategy, info.tools.cc, {
            "--std=c99", "-O2", "-DLUA_USE_POSIX", "-DLUA_USE_BROWSER",
            "-sSUPPORT_LONGJMP=emscripten",
            include_root, include_runtime, include_lua,
            "-c", c_path, "-o", emcc_obj,
        })
        run_tool(strategy, info.tools.clang, {
            "--target=wasm32-unknown-emscripten", "--std=c99", "-O2",
            "-c", clang_c_path, "-o", clang_obj,
        })

        local expected_fp = fixtures.fingerprint()

        for _, object_path in ipairs({ emcc_obj, clang_obj }) do
            local bytes = assert(util.get_file_contents(object_path, "rb"))
            local object = assert(staticmetadata.classify_object(
                bytes, object_path, expected_fp, {
                    expected_abi = version.TITAN_ABI_VERSION,
                    require_layouts = true,
                    validate_layouts = function(modname, layout_bytes)
                        return nominallayout.decode(layout_bytes, modname)
                    end,
                }))
            assert.equal("object", object.kind)
            assert.equal("wasm", object.format)
            assert.same(expected_fp, object.fingerprint)
            assert.equal("wasm_alpha", object.metadata.module)
            assert.equal(version.TITAN_ABI_VERSION, object.metadata.abi)
            assert.equal(expected_types, object.metadata.types)
            assert.equal(expected_layouts, object.metadata.layouts)
            assert.is_table(object.metadata.decoded_layouts)

            local restored = assert(objectmetadata.read(
                bytes, object_path, version.TITAN_ABI_VERSION))
            assert.equal("wasm_alpha", restored.type.name)
            assert.equal(expected_layouts, restored.object_metadata.layouts)

            local probe = assert(staticmetadata.read_object_section(
                bytes, object_path, {
                    elf = ".titan.cprobe", coff = ".titan.cprobe",
                    wasm = ".titan.cprobe",
                    macho_segment = "__DATA", macho_section = "__titancprobe",
                }, 12))
            assert.equal("TITENUM\0\1\12\1\6", probe)

            if object_path == emcc_obj then
                local defined_funcs = {}
                for _, sym in ipairs(object.symbols) do
                    if sym.kind == "function" and sym.defined and
                       sym.binding == "global" and sym.name then
                        defined_funcs[sym.name] = true
                    end
                end
                for _, required in ipairs({
                    "wasm_alpha_abi",
                    "wasm_alpha_types",
                    "wasm_alpha_layouts",
                    "wasm_alpha_init",
                    "luaopen_wasm_alpha",
                }) do
                    assert.is_true(defined_funcs[required],
                        "missing protocol symbol " .. required .. " in " .. object_path)
                end
            end
        end

        local asm_source = [[
.text
.globl x
.type x,@object
.section .data.x,"",@
x:
.int64 foo+4294967296
.int64 foo-4294967296
.size x, 16
]]
        local asm_path = track_file(root .. "/reloc64.s")
        local asm_obj = track_file(root .. "/reloc64.o")
        assert(util.set_file_contents(asm_path, asm_source))
        run_tool(strategy, info.tools.clang, {
            "--target=wasm32-unknown-emscripten", "-x", "assembler",
            "-c", asm_path, "-o", asm_obj,
        })
        local asm_bytes = assert(util.get_file_contents(asm_obj, "rb"))
        local parsed_asm = assert(staticmetadata.classify_object(
            asm_bytes, asm_obj))
        assert.equal("wasm", parsed_asm.format)
        assert.same({
            format = "wasm",
            word_size = 32,
            linking_version = 2,
            features = "",
        }, parsed_asm.fingerprint)
        assert.equal(".data.x", parsed_asm.sections[1].name)
        assert.equal(16, parsed_asm.sections[1].size)
    end)

    it("scans emar archives, verifies manifests, and rejects bitcode and mixed archives", function()
        local info, why = toolchain.require()
        if not info then pending(why) return end

        local root = temp_workspace()
        local include_root = "-I" .. root
        local include_runtime = "-I" .. info.prefix .. "/include"
        local include_lua = "-I" .. info.prefix .. "/lib/browser/include"
        local common_flags = {
            "--std=c99", "-O2", "-DLUA_USE_POSIX", "-DLUA_USE_BROWSER",
            "-sSUPPORT_LONGJMP=emscripten",
            include_root, include_runtime, include_lua,
        }

        local alpha_c = track_file(root .. "/wasm_alpha.c")
        local beta_c = track_file(root .. "/wasm_beta.c")
        local helper_c = track_file(root .. "/helper.c")
        local alpha_code, _, _, alpha_ffi = generate_titan_c(
            "wasm_alpha", root, "wasm_alpha",
            "function alpha(): integer return 1 end\n")
        local beta_code, _, _, beta_ffi = generate_titan_c(
            "wasm_beta", root, "wasm_beta",
            "function beta(): integer return 2 end\n")
        track_file(alpha_ffi)
        track_file(beta_ffi)
        assert(util.set_file_contents(alpha_c, alpha_code))
        assert(util.set_file_contents(beta_c, beta_code))
        assert(util.set_file_contents(helper_c,
            "int wasm_helper_value(void) { return 42; }\n"))

        local alpha_o = track_file(root .. "/wasm_alpha.o")
        local beta_o = track_file(root .. "/wasm_beta.o")
        local helper_o = track_file(root .. "/helper.o")
        for _, pair in ipairs({
            { alpha_c, alpha_o },
            { beta_c, beta_o },
            { helper_c, helper_o },
        }) do
            local args = {}
            for _, flag in ipairs(common_flags) do args[#args + 1] = flag end
            args[#args + 1] = "-c"
            args[#args + 1] = pair[1]
            args[#args + 1] = "-o"
            args[#args + 1] = pair[2]
            run_tool(strategy, info.tools.cc, args)
        end

        local provider_a = track_file(root .. "/libprovider.a")
        run_tool(strategy, info.tools.ar, {
            "rcu", provider_a, alpha_o, beta_o, helper_o,
        })
        run_tool(strategy, info.tools.ranlib, { provider_a })

        local expected_fp = fixtures.fingerprint()
        local scanned = assert(staticmetadata.scan_archive(provider_a, {
            target = expected_fp,
            expected_abi = version.TITAN_ABI_VERSION,
            require_layouts = true,
        }))
        assert.equal("archive", scanned.kind)
        assert.equal(3, #scanned.members)
        assert.same({ "wasm_alpha", "wasm_beta" }, scanned.key_order)

        local manifest_verified = assert(staticmetadata.verify_regular_archive_manifest(
            provider_a, {
                { staged_file = alpha_o, byte_length = #assert(util.get_file_contents(alpha_o, "rb")), origin = alpha_o },
                { staged_file = beta_o, byte_length = #assert(util.get_file_contents(beta_o, "rb")), origin = beta_o },
                { staged_file = helper_o, byte_length = #assert(util.get_file_contents(helper_o, "rb")), origin = helper_o },
            }))
        assert.equal(3, manifest_verified.member_count)

        local ctx = { io = strategy }
        local kind, err, lto = incremental.native_input_kind(ctx, helper_o)
        assert.equal("object", kind, err)
        assert.is_false(lto)
        kind, err, lto = incremental.native_input_kind(ctx, provider_a)
        assert.equal("archive", kind, err)
        assert.is_false(lto)
        assert.same(expected_fp, assert(incremental.part_fingerprint(ctx, helper_o)))

        local lto_o = track_file(root .. "/lto.o")
        run_tool(strategy, info.tools.cc, {
            "--std=c99", "-O2", "-flto", "-c", helper_c, "-o", lto_o,
        })
        local lto_bytes = assert(util.get_file_contents(lto_o, "rb"))
        local classified_lto, lto_err = staticmetadata.classify_object(lto_bytes, lto_o)
        assert.is_nil(classified_lto)
        assert.matches("LLVM bitcode (LTO) object is not supported", lto_err, 1, true)

        kind, err, lto = incremental.native_input_kind(ctx, lto_o)
        assert.equal("object", kind, err)
        assert.is_true(lto)

        local lto_a = track_file(root .. "/liblto.a")
        run_tool(strategy, info.tools.ar, { "rcu", lto_a, alpha_o, lto_o })
        local scanned_lto, scanned_lto_err = staticmetadata.scan_archive(lto_a, {
            expected_abi = version.TITAN_ABI_VERSION,
        })
        assert.is_nil(scanned_lto)
        assert.matches('archive member #%d+ .* name "lto.o": LLVM bitcode %(LTO%) object is not supported', scanned_lto_err)

        local simd_o = track_file(root .. "/simd.o")
        run_tool(strategy, info.tools.cc, {
            "--std=c99", "-O2", "-msimd128", "-c", helper_c, "-o", simd_o,
        })
        local mixed_feat_a = track_file(root .. "/libmixed_feat.a")
        run_tool(strategy, info.tools.ar, { "rcu", mixed_feat_a, alpha_o, simd_o })
        local scanned_feat, scanned_feat_err = staticmetadata.scan_archive(mixed_feat_a, {
            expected_abi = version.TITAN_ABI_VERSION,
        })
        assert.is_nil(scanned_feat)
        assert.matches('archive member #%d+ .* name "simd.o": target mismatch: Wasm features .* does not match target', scanned_feat_err)

        local cdriver = require "c-parser.cdriver"
        local native_cc = assert(cdriver.split_shell_words(os.getenv("CC") or "cc"))
        local native_o = track_file(root .. "/native_helper.o")
        run_tool(strategy, native_cc, { "-std=c99", "-O2", "-c", helper_c, "-o", native_o })
        local mixed_fmt_a = track_file(root .. "/libmixed_fmt.a")
        run_tool(strategy, info.tools.ar, { "rcu", mixed_fmt_a, alpha_o, native_o })
        local scanned_fmt, scanned_fmt_err = staticmetadata.scan_archive(mixed_fmt_a, {
            expected_abi = version.TITAN_ABI_VERSION,
        })
        assert.is_nil(scanned_fmt)
        assert.matches('archive member #%d+ .* name "native_helper.o": target mismatch: object format %w+ does not match target format wasm', scanned_fmt_err)
    end)

    it("extracts wasm32 enum-carrier answers through cprobe without target execution", function()
        local info, why = toolchain.require()
        if not info then pending(why) return end

        local root = temp_workspace()
        local header = track_file(root .. "/wasm_enums.h")
        assert(util.set_file_contents(header, [[
enum wasm_signed_enum { WASM_NEG = -1, WASM_POS = 1 };
enum wasm_u32_enum { WASM_U32 = 4294967295U };
enum wasm_u64_enum { WASM_U64 = 18446744073709551615ULL };
]]))

        local all_ids = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }
        for _, short_enums in ipairs({ false, true }) do
            local cflags = { "--std=c99", "-O2", "-Wall", "-Werror" }
            if short_enums then cflags[#cflags + 1] = "-fshort-enums" end
            local service = assert(cprobe.new_service({
                compiler_argv = info.tools.cc,
                include_dirs = {
                    info.prefix .. "/include",
                    info.prefix .. "/lib/browser/include",
                },
                cflags = cflags,
                syntax_only = true,
            }))
            local mod = assert(service:module_context({
                includes = { { include_kind = "quote", include_name = header } },
            }))

            local signed_type = types.CInteger("enum wasm_signed_enum", true, 3, 32)
            local signed_res = mod:select_enum_carrier(signed_type, all_ids)
            assert.equal("success", signed_res.status, signed_res.message)
            assert.equal(1, signed_res.selection.match_count)
            assert.equal(short_enums and 2 or 6, signed_res.selection.carrier_id)

            local u32_type = types.CInteger("enum wasm_u32_enum", false, 3, 32)
            local u32_res = mod:select_enum_carrier(u32_type, all_ids)
            assert.equal("success", u32_res.status, u32_res.message)
            assert.equal(1, u32_res.selection.match_count)
            assert.equal(7, u32_res.selection.carrier_id)

            local u64_type = types.CInteger("enum wasm_u64_enum", false, 4, 64)
            local u64_res = mod:select_enum_carrier(u64_type, all_ids)
            assert.equal("success", u64_res.status, u64_res.message)
            assert.equal(1, u64_res.selection.match_count)
            -- On wasm32 (ILP32), unsigned long (id 9) is 32-bit, so a 64-bit
            -- unsigned enum must select unsigned long long (id 11).
            assert.equal(11, u64_res.selection.carrier_id)

            local without_ull = mod:select_enum_carrier(
                u64_type, { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 })
            assert.equal("success", without_ull.status, without_ull.message)
            assert.equal(0, without_ull.selection.match_count)

            assert.is_true(service:close())
        end
    end)
end)
