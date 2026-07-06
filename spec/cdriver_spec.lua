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
            assert.matches("titan%-runtime/titan/ffi%.h$", include.resolved)
            assert.equal("angle", include.include_kind)
            assert.equal("titan/ffi.h", include.include_name)
        end)

        it("resolves compiler-provided headers independently of cwd", function()
            local olddir = assert(lfs.currentdir())
            assert(lfs.chdir("/tmp"))
            local ok, err = pcall(function()
                local _, include = assert_process_file("titan/ffi.h")
                assert.matches("titan%-runtime/titan/ffi%.h$", include.resolved)
                assert.equal("angle", include.include_kind)
            end)
            assert(lfs.chdir(olddir))
            assert.truthy(ok, err)
        end)
    end)
end)
