local platform = require "titan-compiler.platform"

local function with_overrides(target, replacements, body)
    local originals = {}
    for name, replacement in pairs(replacements) do
        originals[#originals + 1] = { name, target[name] }
        target[name] = replacement
    end
    local ok, failure = xpcall(body, debug.traceback)
    for _, original in ipairs(originals) do
        target[original[1]] = original[2]
    end
    assert.truthy(ok, failure)
end

describe("compiler process environment", function()
    it("keeps platform import lexical on both hosts", function()
        local original_require = require
        local original_module = package.loaded["titan-compiler.platform"]
        local original_config = package.config
        local ok, failure = xpcall(function()
            for _, windows in ipairs({ false, true }) do
                package.loaded["titan-compiler.platform"] = nil
                package.config = (windows and "\\" or "/") .. "\n;\n?\n!\n-\n"
                with_overrides(_G, { require = function(name)
                    if name == "luv" then
                        error("platform import loaded native process code")
                    end
                    return original_require(name)
                end }, function()
                    assert.equal(windows,
                        require("titan-compiler.platform").windows)
                end)
            end
        end, debug.traceback)
        package.config = original_config
        package.loaded["titan-compiler.platform"] = original_module
        assert.truthy(ok, failure)
    end)

    it("uses the ordinary POSIX getter without loading native code", function()
        local values = { empty = "", unicode = "env 雪 Ω" }
        local original_require = require
        with_overrides(platform, { windows = false }, function()
            with_overrides(os, { getenv = function(name) return values[name] end }, function()
                with_overrides(_G, { require = function(name)
                    if name == "luv" then
                        error("POSIX getter loaded native process code")
                    end
                    return original_require(name)
                end }, function()
                    assert.is_nil(platform.getenv("absent"))
                    assert.equal("", platform.getenv("empty"))
                    assert.equal(values.unicode, platform.getenv("unicode"))
                    assert.equal(1, select("#", platform.getenv("absent")))
                end)
            end)
        end)
    end)

    it("reads Windows values lazily from the native process environment", function()
        local values = { empty = "", unicode = "env 雪 Ω" }
        local calls = {}
        with_overrides(platform, { windows = true }, function()
            with_overrides(os, { getenv = function()
                error("Windows compiler consulted the CRT snapshot")
            end }, function()
                with_overrides(package.loaded, { luv = {
                    os_getenv = function(name)
                        calls[#calls + 1] = name
                        if values[name] == nil then return nil, "ENOENT", "ENOENT" end
                        return values[name]
                    end,
                } }, function()
                    assert.is_nil(platform.getenv("absent"))
                    assert.equal("", platform.getenv("empty"))
                    assert.equal(values.unicode, platform.getenv("unicode"))
                    values.unicode = "updated 雪 Ω"
                    assert.equal(values.unicode, platform.getenv("unicode"))
                    values.unicode = nil
                    assert.is_nil(platform.getenv("unicode"))
                    assert.equal(1, select("#", platform.getenv("absent")))
                end)
            end)
        end)
        assert.same({ "absent", "empty", "unicode", "unicode", "unicode", "absent" }, calls)
    end)

    it("uses live Windows CC in the preprocessor and direct checker", function()
        local cpp = require "c-parser.cpp"
        require "titan-compiler.checker"
        local core = require "titan-compiler.checker.core"
        local cc = "'unterminated"
        with_overrides(platform, { windows = true }, function()
            with_overrides(os, { getenv = function()
                error("compiler fallback consulted the CRT snapshot")
            end }, function()
                with_overrides(package.loaded, { luv = {
                    os_getenv = function(name)
                        if name == "CC" then return cc end
                    end,
                } }, function()
                    local configuration, err = cpp.inspect_forced_headers({})
                    assert.is_nil(configuration)
                    assert.equal("invalid compiler: unterminated single quote in shell words", err)
                    assert.is_table(cpp.inspect_forced_headers({ compiler = "explicit-cc" }))

                    cc = "live-native-cc"
                    with_overrides(core, { foreign_c_options = {} }, function()
                        with_overrides(core.cdriver, { target_profile_inputs = function(options)
                            assert.equal(cc, options.compiler)
                            return nil, "selected native compiler"
                        end }, function()
                            local service, failure = core.new_direct_probe_service()
                            assert.is_nil(service)
                            assert.equal("selected native compiler", failure)
                        end)
                    end)
                end)
            end)
        end)
    end)

    it("reserves Windows temporary files under the live TEMP directory", function()
        local compiler_io = require "titan-compiler.io"
        local paths = require "titan-compiler.path"
        local reserved
        with_overrides(platform, { windows = true }, function()
            with_overrides(os, {
                getenv = function() error("temporary reservation consulted the CRT snapshot") end,
                tmpname = function() return "/crt-reservation.tmp" end,
            }, function()
                with_overrides(package.loaded, { luv = {
                    os_getenv = function(name)
                        if name == "TEMP" then return "C:/live temp 雪" end
                    end,
                } }, function()
                    with_overrides(io, { open = function(filename, mode)
                        reserved = filename
                        assert.equal("wb", mode)
                        return { close = function() return true end }
                    end }, function()
                        local temporary = assert(compiler_io.new_sync():tmpname())
                        assert.equal("C:/live temp 雪/crt-reservation.tmp", paths.to_slash(temporary))
                        assert.equal(temporary, reserved)
                    end)
                end)
            end)
        end)
    end)

    it("observes live Windows updates while the CRT snapshot stays unchanged", function()
        if not platform.windows then pending("native Windows environment boundary") end
        local uv = require "luv"
        local name = "TITAN_COMPILER_ENV_SPEC_" .. uv.os_getpid() .. "_" .. os.time()
        local original = platform.getenv(name)
        local original_crt = os.getenv(name)
        local ok, failure = xpcall(function()
            assert(uv.os_setenv(name, "initial"))
            assert.equal("initial", platform.getenv(name))
            assert(uv.os_setenv(name, "updated 雪 Ω"))
            assert.equal("updated 雪 Ω", platform.getenv(name))
            assert.equal(original_crt, os.getenv(name))
            assert(uv.os_setenv(name, ""))
            assert.equal("", platform.getenv(name))
            assert(uv.os_unsetenv(name))
            assert.is_nil(platform.getenv(name))
        end, debug.traceback)
        if original == nil then assert(uv.os_unsetenv(name))
        else assert(uv.os_setenv(name, original)) end
        assert.equal(original, platform.getenv(name))
        assert.truthy(ok, failure)
    end)
end)
