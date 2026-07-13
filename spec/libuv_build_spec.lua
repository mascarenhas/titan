local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"

local PKG_CONFIG = "sh spec/fixtures/libuv/fake-pkg-config.sh"

local function quote(word)
    local quoted = assert(cdriver.shell_quote(word))
    return quoted
end

local function run_argv(argv)
    local words = {}
    for _, word in ipairs(argv) do table.insert(words, quote(word)) end
    local pipe = assert(io.popen(table.concat(words, " ") .. " 2>&1"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    return ok == true, output, why, code
end

local function compiler_argv(...)
    local argv = assert(cdriver.split_shell_words(os.getenv("CC") or "cc"))
    for _, word in ipairs({ ... }) do argv[#argv + 1] = word end
    return argv
end

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    assert.truthy(file:write(contents))
    assert.truthy(file:close())
end

local function compile_archive_objects(source, objects)
    write_file(source, "int titan_archive_fixture(void) { return 0; }\n")
    for _, object in ipairs(objects) do
        local ok, output, why, code = run_argv(compiler_argv(
            "-c", source, "-o", object))
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    assert.truthy(file:close())
    return contents
end

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local function archive_object_members(output)
    local members = {}
    for member in output:gmatch("[^\r\n]+") do
        if member ~= "__.SYMDEF" and
           member ~= "__.SYMDEF SORTED" and
           member ~= "__.SYMDEF_64" and
           member ~= "__.SYMDEF_64 SORTED" then
            table.insert(members, member)
        end
    end
    return members
end

local function make_temp_dir()
    local path = assert(os.tmpname())
    os.remove(path)
    assert.truthy(lfs.mkdir(path))
    return path
end

-- GNU Make executes recipe lines containing $(MAKE) even under -n. Keep these
-- command-contract tests independent of the checkout's prepared state by
-- replacing every stdlib build prerequisite class with one isolated file.
-- MAKE=false is a second guard: a newly introduced recursive dependency makes
-- the spec fail instead of installing or rebuilding anything.
local function run_stdlib_dry_make(argv)
    local root = make_temp_dir()
    local prepared = root .. "/prepared"
    write_file(prepared, "prepared for a read-only Make dry run\n")

    table.insert(argv, "PREFIX=" .. root)
    table.insert(argv, "MAKE=false")
    for _, variable in ipairs({
        "STDLIB_TOOL_PREREQS",
        "STDLIB_PLATFORM_PREREQS",
        "STDLIB_COMMON_RUNTIME_PREREQS",
        "STDLIB_CORO_RUNTIME_PREREQS",
        "STDLIB_UV_RUNTIME_PREREQS",
        "STDLIB_RUNTIME_ARCHIVE_PREREQ",
    }) do
        table.insert(argv, variable .. "=" .. prepared)
    end

    local ok, output, why, code
    local ran, run_error = pcall(function()
        ok, output, why, code = run_argv(argv)
    end)
    os.remove(prepared)
    assert.truthy(lfs.rmdir(root))
    if not ran then error(run_error, 0) end
    return ok, output, why, code
end

local function run_make(host, environment)
    local argv = {
        "make", "--no-print-directory", "-s", "LIBUV_MODE=system",
        "HOST_OS=" .. host, "LIBUV_PKG_CONFIG=" .. PKG_CONFIG,
        "libuv-config",
    }
    local words = {}
    for _, word in ipairs(argv) do table.insert(words, quote(word)) end
    local command = table.concat(words, " ")
    if environment then command = environment .. " " .. command end
    local pipe = assert(io.popen(command .. " 2>&1"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    return ok == true, output, why, code
end

local function run_uv_dry_run(mode, host)
    local argv = {
        "make", "--no-print-directory", "-n",
        "-W", "titan/uv.titan",
        "LIBUV_MODE=" .. mode,
        "HOST_OS=" .. (host or "Linux"),
        "LIBUV_PKG_CONFIG=" .. PKG_CONFIG,
        "CC=ccache cc",
        "TITAN_EXTRA_CPPFLAGS=-DUSER_CPP=1",
        "TITAN_EXTRA_CFLAGS=-DUSER_C=1",
        "TITAN_EXTRA_LDFLAGS=-Wl,user-link",
        "titan/uv.so",
    }
    return run_stdlib_dry_make(argv)
end

local function run_facade_dry_run(mode, module)
    local argv = {
        "make", "--no-print-directory", "-n",
        "-W", "titan/" .. module .. ".titan",
        "LIBUV_MODE=" .. mode,
        "HOST_OS=Linux",
        "LIBUV_PKG_CONFIG=" .. PKG_CONFIG,
        "CC=ccache cc",
        "TITAN_EXTRA_CPPFLAGS=-DUSER_CPP=1",
        "TITAN_EXTRA_CFLAGS=-DUSER_C=1",
        "TITAN_EXTRA_LDFLAGS=-Wl,user-link",
        "titan/" .. module .. ".so",
    }
    return run_stdlib_dry_make(argv)
end

describe("libuv Makefile configuration", function()
    it("keeps LuaRocks on the native toolchain that prepared its prefix",
       function()
        local file = assert(io.open("Makefile", "rb"))
        local makefile = file:read("*a")
        file:close()
        for _, contract in ipairs({
            "LUAROCKS_CONFIG_POLICY := titan-system-tree-toolchain-v2",
            "TITAN_CONFIG_CC=$(call make_shell_quote,$(CC))",
            "TITAN_CONFIG_AR=$(call make_shell_quote,$(AR))",
            "TITAN_CONFIG_RANLIB=$(call make_shell_quote,$(RANLIB))",
            "unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5",
        }) do
            assert.truthy(makefile:find(contract, 1, true), contract)
        end

        file = assert(io.open("titan-dev-1.rockspec", "rb"))
        local rockspec = file:read("*a")
        file:close()
        for _, contract in ipairs({
            'AR = "$(AR)"',
            'RANLIB = "$(RANLIB)"',
            "unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5",
        }) do
            assert.truthy(rockspec:find(contract, 1, true), contract)
        end
    end)

    it("keys every runtime object and archive member to the selected Lua SDK",
       function()
        local file = assert(io.open("Makefile", "rb"))
        local makefile = file:read("*a")
        file:close()
        for _, contract in ipairs({
            "TITAN_RUNTIME_LUA_SOURCE_PATH ?= $(LUA_DIR)/src",
            "TITAN_RUNTIME_LUA_LIB = " ..
                "$(TITAN_RUNTIME_LUA_SOURCE_PATH)/liblua.a",
            "TITAN_RUNTIME_LUA_SOURCE_PATH=" ..
                "$(TITAN_RUNTIME_LUA_SOURCE_PATH)",
            "LUA_AR=$(LUA_AR)",
            "LUA_RANLIB=$(LUA_RANLIB)",
            "luaopen_titan_uv%c) == 0",
            "$(UV_CONFIG_STAMP) $(RUNTIME_BUILD_CONFIG)",
            "LIBUV_PROVIDER_LDFLAGS=$(LIBUV_PROVIDER_LDFLAGS)",
            "MEMBERS=$(notdir $(TITAN_RUNTIME_OBJECTS))",
            "UV_CONFIG_STAMP := titan-runtime/.titan-uv-build-config",
            "STDLIB_CORO_RUNTIME_PREREQS := $(RUNTIME_O) $(CORO_O)",
            "STDLIB_UV_RUNTIME_PREREQS := " ..
                "$(RUNTIME_O) $(UV_O) $(LIBUV_EXTRA_OBJECTS)",
            "STDLIB_COMMON_RUNTIME_PREREQS := $(RUNTIME_O)",
            "STDLIB_RUNTIME_ARCHIVE_PREREQ := $(TITAN_RUNTIME_LIB)",
            "rm -f $(STDLIB_SOS) coro.so",
            "rm -rf $(addsuffix .dSYM,$(STDLIB_SOS)) coro.so.dSYM",
        }) do
            assert.truthy(makefile:find(contract, 1, true), contract)
        end
        assert.falsy(makefile:find(
            "UV_CONFIG_STAMP := $(LIBUV_BUILD_DIR)/", 1, true), makefile)
        local _, prepared_count = makefile:gsub(
            "TITAN_RUNTIME_PREBUILT=1", "")
        assert.equal(6, prepared_count, makefile)

        file = assert(io.open("titan-compiler/driver.lua", "rb"))
        local driver_source = file:read("*a")
        file:close()
        assert.truthy(driver_source:find(
            'os.getenv("TITAN_RUNTIME_PREBUILT") ~= "1"', 1, true),
            driver_source)
        local _, include_count = makefile:gsub(
            "%-I %$%(TITAN_RUNTIME_LUA_SOURCE_PATH%)", "")
        assert.is_true(include_count >= 3, tostring(include_count))
    end)

    it("keeps the Lua titan module separate from the Titan runtime archive",
       function()
        local file = assert(io.open("Makefile", "rb"))
        local makefile = file:read("*a")
        file:close()
        local first = assert(makefile:find(
            "$(ROCK_RUNTIME_SO): $(TITANLIB_O)", 1, true))
        local last = assert(makefile:find("\n\n# LuaRocks", first, true))
        local rule = makefile:sub(first, last - 1)
        assert.truthy(rule:find(
            '$(ROCK_LD) $(ROCK_LIBFLAG) -o "$@" "$<" ' ..
            '$(TITAN_EXTRA_LDFLAGS)', 1, true), rule)
        for _, forbidden in ipairs({
            "$(TITAN_RUNTIME_LIB)", "$(LIBBT_LIB)", "$(RUNTIME_O)",
            "$(CORO_O)", "$(UV_O)",
        }) do
            assert.falsy(rule:find(forbidden, 1, true),
                forbidden .. " in:\n" .. rule)
        end
    end)

    it("uses a loadable Lua bundle for the direct macOS titan target",
       function()
        local ok, output, why, code = run_argv({
            "make", "--no-print-directory", "-Bn",
            "HOST_OS=Darwin", "titan.so",
        })
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local normalized = output:gsub("%s+", " ")
        assert.truthy(normalized:find(
            'cc -bundle -undefined dynamic_lookup -o "titan.so" ' ..
            '"titan-runtime/titanlib.o"', 1, true), normalized)
        assert.falsy(normalized:find(
            'cc -shared -o "titan.so"', 1, true), normalized)
    end)

    it("repairs a newer runtime archive with an extra member", function()
        local root = make_temp_dir()
        local archive = root .. "/libtitan.a"
        local config = root .. "/archive-build-config"
        local source = root .. "/archive-fixture.c"
        local objects = {
            root .. "/titan.o",
            root .. "/titan_coro.o",
            root .. "/titan_uv.o",
        }
        local make_archive = {
            "make", "--no-print-directory", "-s",
            "TITAN_RUNTIME_OBJECTS=" .. table.concat(objects, " "),
            "TITAN_RUNTIME_LIB=" .. archive,
            "RUNTIME_ARCHIVE_CONFIG=" .. config,
            archive,
        }
        local stale = root .. "/stale.o"
        local ran, run_error = pcall(function()
            compile_archive_objects(source, objects)

            local ok, output, why, code = run_argv(make_archive)
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")

            write_file(stale, "stale archive member\n")
            ok, output, why, code = run_argv({ "ar", "q", archive, stale })
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")

            local repaired, repair_output, repair_why, repair_code =
                run_argv(make_archive)
            assert.truthy(repaired, repair_output .. "\n(" ..
                tostring(repair_why) .. ", " ..
                tostring(repair_code) .. ")")
            ok, output, why, code = run_argv({ "ar", "t", archive })
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            assert.same({ "titan.o", "titan_coro.o", "titan_uv.o" },
                archive_object_members(output))
        end)
        for _, path in ipairs({
            stale, archive, config, config .. ".tmp", source,
            objects[1], objects[2], objects[3],
        }) do
            os.remove(path)
        end
        assert.truthy(lfs.rmdir(root))
        if not ran then error(run_error, 0) end
    end)

    it("ignores the BSD ranlib index when validating archive objects",
       function()
        local root = make_temp_dir()
        local archive = root .. "/libtitan.a"
        local config = root .. "/archive-build-config"
        local fake_ar = root .. "/ar-with-bsd-index"
        local build_log = root .. "/archive-builds"
        local objects = {
            root .. "/titan.o",
            root .. "/titan_coro.o",
            root .. "/titan_uv.o",
        }
        for _, object in ipairs(objects) do
            write_file(object, "isolated fake-archive fixture\n")
        end
        write_file(fake_ar, string.format([[#!/bin/sh
if test "$1" = t; then
  printf '%%s\n' '__.SYMDEF SORTED' titan.o titan_coro.o titan_uv.o
  exit 0
fi
if test "$1" = rcs; then
  printf 'build\n' >> %s
  : > "$2"
  exit 0
fi
exit 64
]], quote(build_log)))
        local ok, output, why, code = run_argv({ "chmod", "+x", fake_ar })
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local make_archive = {
            "make", "--no-print-directory", "-s",
            "AR=" .. fake_ar,
            "RANLIB=true",
            "TITAN_RUNTIME_OBJECTS=" .. table.concat(objects, " "),
            "TITAN_RUNTIME_LIB=" .. archive,
            "RUNTIME_ARCHIVE_CONFIG=" .. config,
            archive,
        }
        local ran, run_error = pcall(function()
            ok, output, why, code = run_argv(make_archive)
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            assert.equal("build\n", read_file(build_log))

            local aged = { "touch", "-t", "200001010000" }
            for _, path in ipairs(objects) do aged[#aged + 1] = path end
            aged[#aged + 1] = config
            ok, output, why, code = run_argv(aged)
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            ok, output, why, code = run_argv({
                "touch", "-t", "200101010000", archive,
            })
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")

            write_file(build_log, "")
            ok, output, why, code = run_argv(make_archive)
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            assert.equal("", read_file(build_log))
        end)
        for _, path in ipairs({
            archive, config, config .. ".tmp", fake_ar, build_log,
            objects[1], objects[2], objects[3],
        }) do
            os.remove(path)
        end
        assert.truthy(lfs.rmdir(root))
        if not ran then error(run_error, 0) end
    end)

    it("keys the bundled archive on effective build inputs", function()
        local file = assert(io.open("Makefile", "rb"))
        local makefile = file:read("*a")
        file:close()
        assert.truthy(makefile:find(
            "$(LIBUV_LIB): $(LIBUV_EXTRACTED) $(LIBUV_BUILD_CONFIG)",
            1, true), makefile)
        assert.falsy(makefile:find(
            "$(LIBUV_LIB): $(LIBUV_EXTRACTED) Makefile", 1, true),
            makefile)
        for _, input in ipairs({
            "LIBUV_VERSION=$(LIBUV_VERSION)",
            "LIBUV_BUILD_PROFILE=$(LIBUV_BUILD_PROFILE)",
            "LIBUV_BUILD_TYPE=$(LIBUV_BUILD_TYPE)",
            "LIBUV_CMAKE_FLAGS=$(LIBUV_CMAKE_FLAGS)",
            "LIBUV_BUILD_CFLAGS=$(LIBUV_BUILD_CFLAGS)",
        }) do
            assert.truthy(makefile:find(input, 1, true), input)
        end
    end)

    it("recreates the CMake build tree only when its configuration changes",
       function()
        local build_dir = make_temp_dir()
        local config = build_dir .. "/.titan-libuv-build-config"
        local sentinel = build_dir .. "/configured-output"

        local function configure(cc, generator)
            return run_argv({
                "make", "--no-print-directory", "-s",
                "LIBUV_BUILD_DIR=" .. build_dir,
                "CC=" .. cc,
                "AR=review-ar",
                "RANLIB=review-ranlib",
                "CMAKE_GENERATOR=" .. generator,
                config,
            })
        end

        local tested, test_error = pcall(function()
            write_file(sentinel, "stale configured output\n")

            local ok, output, why, code =
                configure("review-cc-a", "Review A")
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            assert.falsy(file_exists(sentinel))
            assert.truthy(file_exists(config))

            write_file(sentinel, "current configured output\n")
            ok, output, why, code = configure("review-cc-a", "Review A")
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            assert.truthy(file_exists(sentinel),
                "an unchanged configuration must preserve the CMake tree")

            ok, output, why, code = configure("review-cc-b", "Review A")
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            assert.falsy(file_exists(sentinel),
                "a compiler change must discard the cached CMake tree")

            write_file(sentinel, "old generator output\n")
            ok, output, why, code = configure("review-cc-b", "Review B")
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            assert.falsy(file_exists(sentinel),
                "a generator change must discard the cached CMake tree")
        end)

        os.remove(sentinel)
        os.remove(config)
        assert.truthy(lfs.rmdir(build_dir))
        if not tested then error(test_error, 0) end
    end)

    it("preserves complete pkg-config flags and Linux feature macros",
       function()
        local ok, output, why, code = run_make("Linux")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.truthy(output:find(
            "LIBUV_CPPFLAGS=-I/opt/libuv/include -DUV_FAKE_PKG=1 " ..
            "-D_GNU_SOURCE", 1, true), output)
        assert.truthy(output:find(
            "LIBUV_LDFLAGS=-L/opt/libuv/lib -luv -pthread -ldl -lrt",
            1, true), output)
    end)

    it("does not add the Linux-only macro on macOS", function()
        local ok, output, why, code = run_make("Darwin")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.truthy(output:find(
            "LIBUV_CPPFLAGS=-I/opt/libuv/include -DUV_FAKE_PKG=1",
            1, true), output)
        assert.falsy(output:find("-D_GNU_SOURCE", 1, true), output)
    end)

    it("fails early with platform package instructions when libuv is absent",
       function()
        local ok, output = run_make("Linux", "env FAKE_LIBUV_MISSING=1")
        assert.falsy(ok, output)
        assert.truthy(output:find("cannot find the libuv development package",
            1, true), output)
        assert.truthy(output:find("libuv1-dev", 1, true), output)
        assert.truthy(output:find("libuv-devel", 1, true), output)
        assert.truthy(output:find("brew install libuv pkgconf", 1, true),
            output)
    end)

    it("builds uv with the runtime archive, one libuv input, and merged flags",
       function()
        local ok, output, why, code = run_uv_dry_run("bundled")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local normalized = output:gsub("%s+", " ")
        assert.truthy(normalized:find("titanc titan.uv", 1, true), normalized)
        assert.falsy(normalized:find("-X", 1, true), normalized)
        assert.falsy(normalized:find("titan_uv.o", 1, true), normalized)
        assert.truthy(normalized:find([[CC='ccache cc']], 1, true), normalized)
        assert.truthy(normalized:find(
            [[TITAN_EXTRA_CPPFLAGS='-DUSER_CPP=1 -Ilibuv-v1.52.1/include -D_GNU_SOURCE']],
            1, true), normalized)
        assert.truthy(normalized:find(
            [[TITAN_EXTRA_CFLAGS='-DUSER_C=1 -fno-strict-aliasing']],
            1, true), normalized)
        assert.truthy(normalized:find(
            [[TITAN_EXTRA_LDFLAGS='-Wl,user-link -Wl,--whole-archive libuv-build/libuv.a -Wl,--no-whole-archive -lpthread -ldl -lrt']],
            1, true), normalized)

        ok, output, why, code = run_uv_dry_run("system")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        normalized = output:gsub("%s+", " ")
        assert.truthy(normalized:find("titanc titan.uv", 1, true), normalized)
        command_tail = normalized
        assert.falsy(command_tail:find("-X", 1, true), command_tail)
        assert.falsy(command_tail:find("titan_uv.o", 1, true), command_tail)
        assert.falsy(command_tail:find("libuv-build/libuv.a", 1, true),
            command_tail)
        assert.truthy(normalized:find(
            [[TITAN_EXTRA_CPPFLAGS='-DUSER_CPP=1 -I/opt/libuv/include -DUV_FAKE_PKG=1 -D_GNU_SOURCE']],
            1, true), normalized)
        assert.truthy(normalized:find(
            [[TITAN_EXTRA_LDFLAGS='-Wl,user-link -L/opt/libuv/lib -luv -pthread -ldl -lrt']],
            1, true), normalized)

        ok, output, why, code = run_uv_dry_run("bundled", "Darwin")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        normalized = output:gsub("%s+", " ")
        assert.truthy(normalized:find(
            [[TITAN_EXTRA_LDFLAGS='-Wl,user-link -Wl,-force_load,libuv-build/libuv.a -lpthread']],
            1, true), normalized)
    end)

    it("builds facade modules from binary uv without another libuv input",
       function()
        for _, module in ipairs({ "timer", "fs", "net", "os" }) do
            for _, mode in ipairs({ "bundled", "system" }) do
                local ok, output, why, code =
                    run_facade_dry_run(mode, module)
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                local normalized = output:gsub("%s+", " ")
                local marker = "titanc titan." .. module
                local marker_start = assert(normalized:find(marker, 1, true),
                    normalized)
                local prefix = normalized:sub(1, marker_start)
                local command_start = assert(prefix:match(".*()CC="),
                    normalized)
                local command = normalized:sub(command_start,
                    marker_start + #marker - 1)

                assert.truthy(command:find([[CC='ccache cc']], 1, true),
                    command)
                assert.truthy(command:find(
                    [[TITAN_EXTRA_CPPFLAGS='-DUSER_CPP=1']], 1, true),
                    command)
                assert.truthy(command:find(
                    [[TITAN_EXTRA_CFLAGS='-DUSER_C=1']], 1, true), command)
                assert.truthy(command:find(
                    [[TITAN_EXTRA_LDFLAGS='-Wl,user-link']], 1, true),
                    command)
                assert.falsy(command:find("titan_uv.o", 1, true), command)
                assert.falsy(command:find("libuv-build/libuv.a", 1, true),
                    command)
                assert.falsy(command:find("-luv", 1, true), command)
                assert.falsy(command:find("-D_GNU_SOURCE", 1, true),
                    command)
                assert.falsy(command:find("-fno-strict-aliasing", 1, true),
                    command)
            end
        end
    end)
end)
