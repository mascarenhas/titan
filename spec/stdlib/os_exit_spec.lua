local os_support = require "spec.support.os_test_support"

local EXIT_APP = [====[
local async = import "async"
local system = import "os"
local timer = import "timer"
local stdio = foreign import "stdio.h"

local function append(path: string, text: string)
  local file = stdio.fopen(path, "ab")
  if not file then raise "could not open exit marker" end
  local written = stdio.fwrite(text, #text, 1, file)
  if (written as integer) ~= 1 then
    stdio.fclose(file)
    raise "could not write exit marker"
  end
  if stdio.fclose(file) ~= 0 then
    raise "could not close exit marker"
  end
end

local function default_exit(marker: string): integer
  defer append(marker, "defer;")
  do
    defer append(marker, "finally;")
    system.exit()
  end
  append(marker, "after;")
  return 99
end

local function explicit_exit(marker: string): integer
  defer append(marker, "defer;")
  system.exit(23)
  append(marker, "after;")
  return 99
end

local function child_exit(marker: string): integer
  async.run(function (): value
    defer append(marker, "child-defer;")
    timer.sleep(5)
    system.exit(29)
    append(marker, "child-after;")
    return nil
  end)
  defer append(marker, "main-defer;")
  return 7
end

local function caught_exit(marker: string): integer
  defer append(marker, "defer;")
  do
    system.exit(31)
  catch
    append(marker, "caught;")
  end
  append(marker, "after-catch;")
  timer.sleep(0)
  append(marker, "after-await;")
  return 99
end

local function competing_exit(marker: string): integer
  local child_ready = false
  async.run(function (): value
    defer append(marker, "child-defer;")
    child_ready = true
    do
      timer.sleep(1000)
    catch
      append(marker, "child-caught;")
      system.exit(47)
    end
    append(marker, "child-after;")
    return nil
  end)
  while not child_ready do async.yield() end
  defer append(marker, "main-defer;")
  system.exit(41)
  return 99
end

function main(args: {string}): integer
  if #args ~= 2 then return 98 end
  if args[1] == "default" then
    return default_exit(args[2])
  elseif args[1] == "explicit" then
    return explicit_exit(args[2])
  elseif args[1] == "child" then
    return child_exit(args[2])
  elseif args[1] == "caught" then
    return caught_exit(args[2])
  elseif args[1] == "competing" then
    return competing_exit(args[2])
  end
  return 97
end
]====]

describe("os.exit", function()
    local workspace

    setup(function()
        workspace = os_support.workspace("exit-direct")
        os_support.write_source(workspace, "os_exit_app", EXIT_APP)
        os_support.compile(workspace, "os_exit_app")
    end)

    teardown(function()
        os_support.cleanup(workspace)
    end)

    local function read(path)
        local file = assert(io.open(path, "rb"))
        local contents = assert(file:read("*a"))
        assert(file:close())
        return contents
    end

    local function run(mode)
        local marker = workspace .. "/" .. mode .. ".marker"
        local _, status, output =
            os_support.run_app(workspace, "os_exit_app", mode, marker)
        return marker, status, output
    end

    it("returns default and explicit codes after language cleanup", function()
        local marker, status, output = run("default")
        assert.equals(0, status, output)
        assert.equals("finally;defer;", read(marker))

        marker, status, output = run("explicit")
        assert.equals(23, status, output)
        assert.equals("defer;", read(marker))
    end)

    it("lets a child Task replace a completed main result", function()
        local marker, status, output = run("child")
        assert.equals(29, status, output)
        local contents = read(marker)
        assert.matches("main%-defer;", contents)
        assert.matches("child%-defer;", contents)
        assert.is_nil(contents:find("child-after;", 1, true))
    end)

    it("reinjects exit cancellation after a user catch", function()
        local marker, status, output = run("caught")
        assert.equals(31, status, output)
        assert.equals("caught;after-catch;defer;", read(marker))
    end)

    it("keeps the first code when a cancelled Task requests exit", function()
        local marker, status, output = run("competing")
        assert.equals(41, status, output)
        local contents = read(marker)
        assert.matches("main%-defer;", contents)
        assert.matches("child%-caught;", contents)
        assert.matches("child%-defer;", contents)
        assert.is_nil(contents:find("child-after;", 1, true))
    end)
end)
