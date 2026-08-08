-- Public synchronous titan.os time/date/locale behavior is a standard-library
-- integration suite and runs outside LuaCov. It compiles an exact private os
-- provider against the prepared canonical dependencies, without rebuilding or
-- modifying the shared standard image.
local assert = require "luassert"
local async_stdlib = require "spec.support.async_stdlib"

local function quote(word)
    return "'" .. tostring(word):gsub("'", "'\\''") .. "'"
end

local function exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local prefix = os.getenv("PREFIX")
local LUA = prefix and exists(prefix .. "/bin/lua")
    and prefix .. "/bin/lua" or "lua"

-- This focused suite needs only the small titan.string surface referenced by
-- titan.os. Its complete implementation and dependency graph have separate
-- exact-provider suites; keeping this support module literal and binary-safe
-- avoids rebuilding PEG/regex solely to test the synchronous time slice.
local STRING_SUPPORT = [[
local ffi = foreign import "titan/ffi.h"
local cstring = foreign import "string.h"

record StringWriter
  local contents: string
end

local function initial_position(position: integer,
                                length: integer): integer
  if position > 0 then
    return position
  elseif position == 0 or position < -length then
    return 1
  else
    return length + position + 1
  end
end

local function ending_position(position: integer,
                               length: integer): integer
  if position > length then
    return length
  elseif position >= 0 then
    return position
  elseif position < -length then
    return 0
  else
    return length + position + 1
  end
end

function sub(subject: string, first: integer,
             last: integer?): string
  local actual_last = -1
  if last then actual_last = last end
  local initial = initial_position(first, #subject)
  local ending = ending_position(actual_last, #subject)
  if initial > ending then return "" end
  local count = ending - initial + 1
  local storage = ffi.titan_ffi_char.new_array(count)
  cstring.memcpy(
    storage as *ffi.titan_ffi_char,
    (subject as const *ffi.titan_ffi_char) + initial - 1,
    count as cstring.size_t)
  return storage as string
end

function find(subject: string, needle: string,
              init: integer?): (integer?, integer?)
  local raw_init = 1
  if init then raw_init = init end
  local first = initial_position(raw_init, #subject)
  if first > #subject + 1 then return nil, nil end
  if #needle == 0 then return first, first - 1 end
  if first > #subject or #needle > #subject - first + 1 then
    return nil, nil
  end
  local subject_bytes = subject as const *ffi.titan_ffi_char
  local needle_bytes = needle as const *ffi.titan_ffi_char
  local offset = first - 1
  local limit = #subject - #needle
  while offset <= limit do
    if cstring.memcmp(
        subject_bytes + offset, needle_bytes,
        #needle as cstring.size_t) == 0 then
      return offset + 1, offset + #needle
    end
    offset = offset + 1
  end
  return nil, nil
end

function writer(): StringWriter
  return StringWriter.new("")
end

function StringWriter:write(data: string)
  self.contents = self.contents .. data
end

function StringWriter:drain(): string
  local result = self.contents
  self.contents = ""
  return result
end
]]

local TYPED_PROBE = [[
local system = import "os"

function utc(timestamp: integer): system.Date
  local result = system.date("!*t", timestamp)
  if result is system.Date then return result as system.Date end
  raise "os.date did not return Date for *t"
end

function formatted_utc(timestamp: integer): string
  local result = system.date("!%Y-%m-%d %H:%M:%S", timestamp)
  if result is string then return result as string end
  raise "os.date did not return string for a format"
end

function default_noon(): integer
  return system.time { year = 2001, month = 2, day = 3 }
end

function positional_omitted_isdst(): integer
  return system.time()
end

function positional_nil_isdst(): integer
  return system.time(nil, nil, nil, nil, nil, nil, nil)
end

function positional_false_isdst(): integer
  return system.time(nil, nil, nil, nil, nil, nil, false)
end

function named_omitted_isdst(): integer
  return system.time {}
end

function named_nil_isdst(): integer
  return system.time { isdst = nil }
end

function named_false_isdst(): integer
  return system.time { isdst = false }
end

function mapped_isdst(isdst: boolean?): integer
  return system.time(2020, 7, 1, 12, 0, 0, isdst)
end

function clock_and_difference(): (float, float)
  return system.clock(), system.difftime(27, 9)
end
]]

describe("titan.os synchronous time and locale", function()
    local workspace
    local layout

    setup(function()
        workspace = async_stdlib.workspace("os-time")
        async_stdlib.refresh_private_runtime(workspace)
        layout = async_stdlib.exact_layout(workspace)
        async_stdlib.write_source(
            workspace, "titan.string", STRING_SUPPORT)
        async_stdlib.compile(workspace, "titan.string", {
            layout = layout,
            cppflags = "",
        })
        async_stdlib.register_exact_provider(layout, "titan.string")
        async_stdlib.prepare_async_core(workspace, layout)

        async_stdlib.write_source(
            workspace, "titan.os", async_stdlib.read("titan/os.titan"))
        async_stdlib.compile(workspace, "titan.os", {
            layout = layout,
            cppflags = "",
        })
        async_stdlib.register_exact_provider(layout, "titan.os")
        async_stdlib.write_source(
            workspace, "os_time_typed_probe", TYPED_PROBE)
        async_stdlib.compile(workspace, "os_time_typed_probe", {
            layout = layout,
            cppflags = "",
        })
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    local function run(source)
        local lua_path = workspace .. "/?.lua;;"
        local cpath = workspace .. "/?.so;" ..
            workspace .. "/titan-runtime/bootstrap/?.so;;"
        local command = table.concat({
            "env -u LUA_PATH -u LUA_CPATH" ..
                " -u LUA_PATH_5_5 -u LUA_CPATH_5_5",
            "TITAN_PATH_0_22=" .. quote(workspace),
            "TITAN_PATH=",
            "TZ=" .. quote("EST5EDT,M3.2.0/2,M11.1.0/2"),
            "LUA_PATH=" .. quote(lua_path),
            "LUA_PATH_5_5=" .. quote(lua_path),
            "LUA_CPATH=" .. quote(cpath),
            "LUA_CPATH_5_5=" .. quote(cpath),
            quote(LUA) .. " -e " .. quote(source),
        }, " ")
        local ok, status, output = async_stdlib.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    it("exposes typed clocks and string-or-Date calendar results", function()
        run([[
            local system = require "titan.os"
            local probe = require "os_time_typed_probe"

            local before = system.clock()
            local total = 0
            for index = 1, 200000 do total = total + index end
            local after = system.clock()
            assert(total > 0 and before >= 0 and after >= before)
            assert(math.type(before) == "float")
            local probed, difference = probe.clock_and_difference()
            assert(math.type(probed) == "float" and difference == 18.0)
            assert(system.difftime(25, 10) == 15.0)

            local formatted = probe.formatted_utc(0)
            assert(formatted == "1970-01-01 00:00:00", formatted)
            local detailed = system.date(
                "!%Y-%m-%d %H:%M:%S %w %j", 0)
            assert(detailed == "1970-01-01 00:00:00 4 001", detailed)
            local local_formatted = system.date(
                "%Y-%m-%d %H:%M:%S", 0)
            assert(local_formatted == "1969-12-31 19:00:00",
                local_formatted)
            assert(type(system.date(nil, 0)) == "string")

            local date = probe.utc(0)
            assert(date.year == 1970 and date.month == 1 and date.day == 1)
            assert(date.hour == 0 and date.min == 0 and date.sec == 0)
            assert(date.wday == 5 and date.yday == 1)
            assert(date.isdst == false or date.isdst == nil)
        ]])
    end)

    it("normalizes named date fields with Lua's noon defaults", function()
        run([[
            local system = require "titan.os"
            local probe = require "os_time_typed_probe"

            local current_ok, now = pcall(system.time)
            assert(current_ok, now)
            assert(math.type(now) == "integer")
            assert(math.abs(now - os.time()) <= 2)

            -- boolean? must preserve nil and false across direct positional,
            -- direct named, and Lua-entry calls. Nil/omission selects current
            -- time; an explicit false without date fields is a supplied field
            -- and therefore raises the field-completeness diagnostic.
            local direct_now = probe.positional_omitted_isdst()
            assert(math.abs(direct_now - now) <= 2)
            direct_now = probe.positional_nil_isdst()
            assert(math.abs(direct_now - now) <= 2)
            local ok, message = pcall(probe.positional_false_isdst)
            assert(not ok and message:find(
                "time requires year, month, and day together", 1, true))

            direct_now = probe.named_omitted_isdst()
            assert(math.abs(direct_now - now) <= 2)
            direct_now = probe.named_nil_isdst()
            assert(math.abs(direct_now - now) <= 2)
            ok, message = pcall(probe.named_false_isdst)
            assert(not ok and message:find(
                "time requires year, month, and day together", 1, true))

            local lua_nil_ok, lua_nil = pcall(
                system.time, nil, nil, nil, nil, nil, nil, nil)
            assert(lua_nil_ok and math.abs(lua_nil - now) <= 2, lua_nil)
            ok, message = pcall(
                system.time, nil, nil, nil, nil, nil, nil, false)
            assert(not ok and message:find(
                "time requires year, month, and day together", 1, true))

            -- Under this suite's deterministic POSIX timezone, July is
            -- daylight time. Compare all three tm_isdst inputs with Lua's
            -- table API so this proves the native -1/0/1 mapping, not merely
            -- that boolean? preserves false.
            local fields = {
                year = 2020, month = 7, day = 1,
                hour = 12, min = 0, sec = 0,
            }
            local inferred_expected = os.time(fields)
            fields = {
                year = 2020, month = 7, day = 1,
                hour = 12, min = 0, sec = 0, isdst = false,
            }
            local standard_expected = os.time(fields)
            fields = {
                year = 2020, month = 7, day = 1,
                hour = 12, min = 0, sec = 0, isdst = true,
            }
            local daylight_expected = os.time(fields)

            local inferred = probe.mapped_isdst(nil)
            local standard = probe.mapped_isdst(false)
            local daylight = probe.mapped_isdst(true)
            assert(inferred == inferred_expected)
            assert(standard == standard_expected)
            assert(daylight == daylight_expected)
            assert(inferred == daylight)
            assert(standard - daylight == 60 * 60)

            local expected = os.time { year = 2001, month = 2, day = 3 }
            local noon_ok, noon = pcall(probe.default_noon)
            assert(noon_ok, noon)
            assert(noon == expected, tostring(noon) .. " ~= " .. expected)

            local normalized_ok, normalized = pcall(
                system.time, 2020, 2, 30, 4, 5, 6)
            assert(normalized_ok, normalized)
            local lua_fields = {
                year = 2020, month = 2, day = 30,
                hour = 4, min = 5, sec = 6,
            }
            assert(normalized == os.time(lua_fields))
            local actual = system.date("*t", normalized)
            local expected_fields = os.date("*t", normalized)
            for _, name in ipairs{
                "year", "month", "day", "hour", "min", "sec",
                "wday", "yday",
            } do
                assert(actual[name] == expected_fields[name])
            end
            assert(actual.isdst == expected_fields.isdst)
        ]])
    end)

    it("grows formatted output and validates formats and date fields", function()
        run([[
            local system = require "titan.os"
            local format = ("%Y"):rep(1024)
            local rendered = system.date("!" .. format, 0)
            assert(rendered == ("1970"):rep(1024))
            assert(system.date("!", 0) == "")

            local ok, message = pcall(system.date, "%Q", 0)
            assert(not ok and message:find(
                "invalid conversion specifier '%Q'", 1, true))
            ok, message = pcall(system.date, "%", 0)
            assert(not ok and message:find(
                "invalid conversion specifier '%'", 1, true))
            ok, message = pcall(system.date, "%Y\0suffix", 0)
            assert(not ok and message:find(
                "date format contains an embedded NUL", 1, true))

            ok, message = pcall(system.time, 2020)
            assert(not ok and message:find(
                "time requires year, month, and day together", 1, true))
            ok, message = pcall(system.time, nil, nil, nil, 12)
            assert(not ok and message:find(
                "time requires year, month, and day together", 1, true))
            ok, message = pcall(system.time,
                math.maxinteger, 1, 1)
            assert(not ok and message:find(
                "time field 'year' is out of range", 1, true))
        ]])
    end)

    it("queries, changes, and restores ISO C locale categories", function()
        run([[
            local system = require "titan.os"
            local previous = assert(system.setlocale(nil, "time"))
            local ok, failure = pcall(function()
                assert(system.setlocale("C", "time"))
                assert(system.setlocale(nil, "time") == "C")
                assert(system.date("!%c", 0) == os.date("!%c", 0))
                assert(system.setlocale(
                    "titan-locale-that-does-not-exist", "time") == nil)
            end)
            local restored = system.setlocale(previous, "time")
            assert(restored, "could not restore LC_TIME")
            if not ok then error(failure, 0) end

            ok, failure = pcall(system.setlocale, "C", "unknown")
            assert(not ok and failure:find(
                "invalid locale category 'unknown'", 1, true))
            ok, failure = pcall(system.setlocale, "C\0suffix", "time")
            assert(not ok and failure:find(
                "locale name contains an embedded NUL", 1, true))
            ok, failure = pcall(system.setlocale, "C", "time\0suffix")
            assert(not ok and failure:find(
                "locale category contains an embedded NUL", 1, true))
        ]])
    end)
end)
