local os_support = require "spec.support.os_test_support"

local HELPER_CASES = [====[
-- Synchronous public os behavior against the canonical production modules.
local os = import "os"
local async = import "async"

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function long_environment_value(): string
  local contents = "0123456789abcdef"
  while #contents < 8192 do contents = contents .. contents end
  return contents
end

local function restore_environment(name: string, original: string?)
  if original then
    os.setenv(name, original as string)
  else
    os.unsetenv(name)
  end
end

function exercise_environment(name: string): string
  local original: string? = os.getenv(name)
  local long_value = long_environment_value()
  do
    os.unsetenv(name)
    local missing: string? = os.getenv(name)
    check(not missing,
          "missing environment variable did not return nil")

    os.setenv(name, "")
    local empty: string? = os.getenv(name)
    check(empty and (empty as string) == "",
          "empty environment value was confused with a missing variable")

    os.setenv(name, long_value)
    local copied: string? = os.getenv(name)
    check(copied and (copied as string) == long_value,
          "long environment value was truncated during resize")
  finally
    restore_environment(name, original)
  end

  local restored: string? = os.getenv(name)
  if original then
    check(restored and
          (restored as string) == (original as string),
          "existing environment value was not restored")
  else
    check(not restored,
          "previously missing environment variable leaked globally")
  end
  return "environment-helpers-ok"
end

function exercise_nul_rejections(name: string, path: string): string
  local rejections = 0
  do
    os.getenv(name .. "\0get")
  catch
    local failure = error as async.Error
    check(failure.operation == "os.getenv",
          "NUL getenv reported the wrong operation")
    rejections = rejections + 1
  end
  do
    os.setenv(name .. "\0set", "value")
  catch
    local failure = error as async.Error
    check(failure.operation == "os.setenv",
          "NUL setenv name reported the wrong operation")
    rejections = rejections + 1
  end
  do
    os.setenv(name, "value\0suffix")
  catch
    local failure = error as async.Error
    check(failure.operation == "os.setenv" and failure.subject == name,
          "NUL environment value leaked into the Error subject")
    rejections = rejections + 1
  end
  do
    os.unsetenv(name .. "\0unset")
  catch
    local failure = error as async.Error
    check(failure.operation == "os.unsetenv",
          "NUL unsetenv reported the wrong operation")
    rejections = rejections + 1
  end
  do
    os.chdir(path .. "\0suffix")
  catch
    local failure = error as async.Error
    check(failure.operation == "os.chdir",
          "NUL chdir reported the wrong operation")
    rejections = rejections + 1
  end
  check(rejections == 5,
        "an embedded-NUL OS text argument reached libuv")
  return "os-nul-rejections-ok"
end

function exercise_paths_and_identity(temp: string): string
  local original = os.cwd()
  do
    os.chdir(temp)
    check(os.cwd() ~= original, "chdir did not update cwd")
  finally
    os.chdir(original)
  end
  check(os.cwd() == original, "cwd was not restored after chdir")

  check(#os.homedir() > 0, "homedir returned an empty path")
  check(#os.tmpdir() > 0, "tmpdir returned an empty path")
  check(#os.hostname() > 0, "hostname returned an empty name")
  local exepath_rejected = false
  do
    os.exepath()
  catch
    check((error as string) ==
          "os.exepath is only available in a compiled Titan program",
          "Lua-hosted exepath reported the wrong error")
    exepath_rejected = true
  end
  check(exepath_rejected, "Lua-hosted exepath unexpectedly succeeded")
  check(os.pid() > 0, "pid was not positive")
  check(os.ppid() >= 0, "ppid was negative")
  return "path-and-identity-helpers-ok"
end
]====]

local EXEPATH_APP = [====[
local system = import "os"

function main(args: {string}): integer
  if system.pid() <= 0 or system.ppid() <= 0 or #system.cwd() == 0 or
      #system.exepath() == 0 then
    return 1
  end
  return 0
end
]====]

describe("os synchronous helpers", function()
    local workspace
    local envname

    setup(function()
        workspace = os_support.workspace("helpers")
        envname = ("TITAN_OS_HELPERS_" .. workspace):
            gsub("[^A-Za-z0-9_]", "_")
        os_support.write_source(workspace, "os_helper_cases", HELPER_CASES)
        os_support.compile(workspace, "os_helper_cases")
        os_support.write_source(workspace, "os_exepath_app", EXEPATH_APP)
        os_support.compile(workspace, "os_exepath_app")
    end)

    teardown(function()
        os_support.cleanup(workspace)
    end)

    it("preserves environment and cwd while resizing real values",
    function()
        local source = "local temp = " .. string.format("%q", workspace) ..
            "\nlocal envname = " .. string.format("%q", envname) .. [[

local lfs = require "lfs"
local lua_os = os
local cases = require "os_helper_cases"

local original_cwd = lfs.currentdir()
local original_env = lua_os.getenv(envname)
local alternate_cwd = temp .. "/cwd"
assert(lfs.mkdir(alternate_cwd))

assert(cases.exercise_environment(envname) == "environment-helpers-ok")
assert(cases.exercise_nul_rejections(envname, temp) ==
    "os-nul-rejections-ok")
assert(cases.exercise_paths_and_identity(alternate_cwd) ==
    "path-and-identity-helpers-ok")
assert(lfs.currentdir() == original_cwd)
assert(lua_os.getenv(envname) == original_env)
]]
        local ok, status, output =
            os_support.run_lua_source(workspace, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)

    it("reports the executable path from a compiled Titan program", function()
        local ok, status, output =
            os_support.run_app(workspace, "os_exepath_app")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)
end)
