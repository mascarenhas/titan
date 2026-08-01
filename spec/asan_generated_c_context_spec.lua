local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local driver = require "titan-compiler.driver"
local lfs = require "lfs"
local mapper = require "spec.support.asan_generated_c_context"

local FIXTURE = "spec/fixtures/asan/generated_c_context.c"
local SYMBOL = "titan_test_generated_c_context"
local SECOND_SYMBOL = "titan_test_second_context"

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    assert.truthy(file:close())
    return contents
end

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    assert.truthy(file:write(contents))
    assert.truthy(file:close())
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                remove_tree(path .. "/" .. entry)
            end
        end
        assert.truthy(lfs.rmdir(path))
    elseif mode then
        assert.truthy(os.remove(path))
    end
end

local function temporary_directory()
    local path = assert(os.tmpname()) .. "-asan module + context"
    os.remove(path)
    assert.truthy(lfs.mkdir(path))
    return path
end

local function copy_argv(argv)
    local copy = {}
    for index, word in ipairs(argv) do copy[index] = word end
    return copy
end

local function capture_without_ccache(argv, options)
    local wrapped = { "env", "CCACHE_DISABLE=1" }
    for _, word in ipairs(argv) do wrapped[#wrapped + 1] = word end
    return cdriver.capture_command(wrapped, options)
end

local function run(argv)
    local result = capture_without_ccache(argv)
    assert.truthy(result.started, result.diagnostic)
    assert.truthy(result.ok, result.diagnostic)
    return result.output
end

local function compile_fixture(workspace)
    local generated = workspace .. "/generated"
    assert.truthy(lfs.mkdir(generated))
    local source = generated .. "/context.c"
    local object = generated .. "/context.o"
    local provider = workspace .. "/provider + exact.so"
    write_file(source, read_file(FIXTURE))

    local compile = copy_argv(assert(driver.generated_compile_prefix()))
    compile[#compile + 1] = "-c"
    compile[#compile + 1] = source
    compile[#compile + 1] = "-o"
    compile[#compile + 1] = object
    run(compile)

    local link = assert(cdriver.split_shell_words(driver.CC))
    link[#link + 1] = "-shared"
    link[#link + 1] = object
    link[#link + 1] = "-o"
    link[#link + 1] = provider
    for _, flag in ipairs(driver.EXTRA_LDFLAGS) do link[#link + 1] = flag end
    run(link)
    return generated, source, object, provider
end

local function named_symbol(path, name)
    local output = run({ "nm", "-anS", "--defined-only", path })
    local found
    for _, symbol in ipairs(mapper.parse_nm(output)) do
        if symbol.name == name then
            assert.falsy(found, "duplicate fixture symbol")
            found = symbol
        end
    end
    return assert(found, "missing fixture symbol")
end

local function build_id(path)
    local output = run({ "readelf", "-n", path })
    return assert(output:match("Build ID:%s*([%da-fA-F]+)"),
        "fixture provider has no BuildId")
end

local function asan_frame(provider, offset, id, symbol, line, number)
    return string.format("#%d 0x7fff12345678 in %s synthetic_input.titan:%d " ..
        "(%s+0x%x) (BuildId: %s)", number or 0, symbol, line,
        provider, offset, id)
end

local function asan_log(provider, offset, id, additional_frames)
    local lines = {
        "==123==ERROR: AddressSanitizer: synthetic failure",
        asan_frame(provider, offset, id, SYMBOL, 725),
    }
    for _, frame in ipairs(additional_frames or {}) do
        lines[#lines + 1] = frame
    end
    lines[#lines + 1] = "SUMMARY: AddressSanitizer: synthetic failure"
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

describe("ASan generated-C context diagnostics", function()
    it("parses only numbered relocation-safe frames and takes the final module pair",
    function()
        local frames = mapper.parse_frames(table.concat({
            "#0 0xabc in f input.titan:7 (/tmp/a + b.so+0x12F) " ..
                "(BuildId: A0b1)",
            "  #1 0xdef (/lib/libc.so+0X2a1c9) " ..
                "(/lib/libc.so+0x2a1c9) (BuildId: 99)",
            "#2 0x123 in absolute_only input.titan:8",
            "SUMMARY: AddressSanitizer: (/tmp/not-a-frame.so+0x44)",
            "",
        }, "\n"))
        assert.equal(2, #frames)
        assert.same({
            number = 0,
            module = "/tmp/a + b.so",
            offset = 0x12f,
            build_id = "a0b1",
            text = "#0 0xabc in f input.titan:7 " ..
                "(/tmp/a + b.so+0x12F) (BuildId: A0b1)",
        }, frames[1])
        assert.equal("/lib/libc.so", frames[2].module)
        assert.equal(0x2a1c9, frames[2].offset)
        assert.equal("99", frames[2].build_id)
    end)

    it("relabels a line-preserving shadow and clamps numbered context", function()
        local source = table.concat({
            "first",
            "  #line 90 \"input.titan\"",
            "target",
            "last",
        }, "\n")
        local shadow = mapper.strip_line_directives(source, "/tmp/output.c")
        assert.matches('^#line 1 "/tmp/output.c"\n', shadow)
        assert.falsy(shadow:find("input.titan", 1, true))
        assert.equal(5, select(2, shadow:gsub("\n", "")) + 1)
        assert.equal(table.concat({
            "        1 | first",
            "        2 |   #line 90 \"input.titan\"",
            ">       3 | target",
            "        4 | last",
        }, "\n"), assert(mapper.source_context(source, 3, 20)))
    end)

    if not driver.IS_DARWIN then
        local workspace

        before_each(function()
            workspace = temporary_directory()
        end)

        after_each(function()
            remove_tree(workspace)
        end)

        it("captures combined sanitizer output without masking command status",
        function()
            local log_dir = workspace .. "/captured logs"
            local result = cdriver.capture_command({
                "env", "TITAN_SANITIZER_LOG_DIR=" .. log_dir,
                "bash", "spec/support/ci_sanitizer_capture.sh", "status-7",
                "bash", "-c",
                'printf "captured stdout\\n"; ' ..
                    'printf "captured stderr\\n" >&2; exit 7',
            })
            assert.is_true(result.started)
            assert.is_false(result.ok)
            assert.equal("exit", result.why)
            assert.equal(7, result.status)
            assert.equal("captured stdout\ncaptured stderr\n",
                read_file(log_dir .. "/status-7.log"))
        end)

        it("maps a saved DSO offset to verified generated C without rerunning",
        function()
            local generated, _, _, provider = compile_fixture(workspace)
            local symbol = named_symbol(provider, SYMBOL)
            local second_symbol = named_symbol(provider, SECOND_SYMBOL)
            local id = build_id(provider)
            local snapshot = workspace .. "/snapshot"
            assert.equal(1, mapper.snapshot(snapshot, provider, generated))

            local log_dir = workspace .. "/logs"
            assert.truthy(lfs.mkdir(log_dir))
            write_file(log_dir .. "/synthetic.log",
                asan_log(provider, symbol.address, id, {
                    asan_frame(provider, second_symbol.address, id,
                        SECOND_SYMBOL, 950, 1),
                }))
            local report = assert(mapper.report_logs(log_dir, snapshot, {
                work_dir = workspace .. "/shadow",
                context_radius = 2,
                run_command = capture_without_ccache,
            }))
            assert.truthy(report:find("symbol: " .. SYMBOL .. "+0x0",
                1, true), report)
            assert.matches("normal DWARF attribution: .*synthetic_input%.titan:72[567]",
                report)
            local generated_line = report:match(
                "generated C context:.-/context%.c:(%d+)")
            assert.truthy(generated_line == "3" or generated_line == "4",
                report)
            assert.truthy(report:find("GENERATED_C_CONTEXT_TARGET", 1, true),
                report)
            assert.truthy(report:find("return *value + 7;", 1, true), report)
            assert.truthy(report:find(
                "symbol: " .. SECOND_SYMBOL .. "+0x0", 1, true), report)
            assert.truthy(report:find("SECOND_CONTEXT_TARGET", 1, true), report)
            assert.truthy(report:find("return *value - 3;", 1, true), report)
            assert.truthy(report:find("0x7fff12345678", 1, true))
        end)

        it("refuses mismatched BuildIds, module paths, and shadow text", function()
            local generated, _, _, provider = compile_fixture(workspace)
            local symbol = named_symbol(provider, SYMBOL)
            local id = build_id(provider)
            local snapshot = workspace .. "/snapshot"
            assert.equal(1, mapper.snapshot(snapshot, provider, generated))
            local saved = assert(mapper._read_snapshot(snapshot))

            local wrong_id = mapper.report_text(
                asan_log(provider, symbol.address, "deadbeef"), saved, {
                    work_dir = workspace .. "/wrong-id-shadow",
                    run_command = capture_without_ccache,
                })
            assert.matches("BuildId does not match", wrong_id)
            assert.falsy(wrong_id:find("generated C context:", 1, true))

            local wrong_path = mapper.report_text(
                asan_log(workspace .. "/else/provider + exact.so",
                    symbol.address, id), saved, {
                    work_dir = workspace .. "/wrong-path-shadow",
                    run_command = capture_without_ccache,
                })
            assert.matches("no relocation%-safe frames", wrong_path)

            local wrong_shadow_work = workspace .. "/wrong-shadow-path"
            local function wrong_shadow_path_runner(argv, options)
                if argv[1] == "fake-addr2line" then
                    local is_shadow, is_text = false, false
                    for index, word in ipairs(argv) do
                        is_shadow = is_shadow or
                            word:find(wrong_shadow_work, 1, true) ~= nil
                        is_text = is_text or
                            (word == "-j" and argv[index + 1] == ".text")
                    end
                    if is_shadow and is_text then
                        return {
                            started = true,
                            ok = true,
                            output = "/tmp/not-the-saved-source.c:3\n",
                        }
                    end
                end
                return capture_without_ccache(argv, options)
            end
            local wrong_shadow_path = mapper.report_text(
                asan_log(provider, symbol.address, id), saved, {
                    work_dir = wrong_shadow_work,
                    addr2line = "fake-addr2line",
                    run_command = wrong_shadow_path_runner,
                })
            assert.truthy(wrong_shadow_path:find(
                "shadow symbolization did not resolve to the saved generated C",
                1, true), wrong_shadow_path)
            assert.falsy(wrong_shadow_path:find(
                "generated C context:", 1, true))

            local snap_source = snapshot .. "/units/context.c"
            write_file(snap_source, read_file(snap_source):gsub(
                "return %*value %+ 7;", "return *value + 700000;"))
            local mismatch = mapper.report_text(
                asan_log(provider, symbol.address, id), saved, {
                    work_dir = workspace .. "/mismatch-shadow",
                    run_command = capture_without_ccache,
                })
            assert.truthy(mismatch:find(
                "normal and shadow function bytes differ", 1, true)
                or mismatch:find(
                    "normal and shadow function layouts differ", 1, true),
                mismatch)
            assert.falsy(mismatch:find("generated C context:", 1, true))

            assert.truthy(os.remove(snapshot .. "/units/context.o"))
            local incomplete, incomplete_err = mapper._read_snapshot(snapshot)
            assert.is_nil(incomplete)
            assert.matches("unit manifest does not match", incomplete_err)
        end)
    end
end)
