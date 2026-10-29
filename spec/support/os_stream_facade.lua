local async_stdlib = require "spec.support.async_stdlib"

local M = {}

local function quote(word)
    return "'" .. tostring(word):gsub("'", "'\\''") .. "'"
end

local function exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local function host_lua()
    local prefix = os.getenv("PREFIX")
    if prefix and exists(prefix .. "/bin/lua") then
        return prefix .. "/bin/lua"
    end
    return "lua"
end

-- titan.os and titan.io use only these string operations. The complete
-- string/PEG implementation has its own exact-provider suites; this focused
-- process fixture keeps its native build graph to coroutine/uv/async plus the
-- two facades under test.
local STRING_SUPPORT = [====[
foreign import "lua.h"
foreign import "lauxlib.h"
foreign import "titan/ffi.h"
foreign import "string.h"

record StringWriter
  local contents: string
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

function StringWriter:close()
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
  local storage = foreign char.new_array(count)
  ffi.memcpy(
    storage as foreign *char,
    (subject as foreign const *char) + initial - 1,
    count as foreign size_t)
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
  local subject_bytes = subject as foreign const *char
  local needle_bytes = needle as foreign const *char
  local offset = first - 1
  local limit = #subject - #needle
  while offset <= limit do
    if ffi.memcmp(
        subject_bytes + offset, needle_bytes,
        #needle as foreign size_t) == 0 then
      return offset + 1, offset + #needle
    end
    offset = offset + 1
  end
  return nil, nil
end

function tostring(candidate: value): string
  local top = ffi.lua_gettop(L)
  defer ffi.lua_settop(L, top)
  -- Candidate plus the two temporary slots used by luaL_getmetafield/callmeta.
  if ffi.lua_checkstack(L, 3) == 0 then
    raise "cannot reserve Lua stack for string conversion"
  end
  ffi.lua_pushtvalue(L, candidate)
  ffi.luaL_tolstring(L, -1, nil)
  return ffi.lua_totvalue(L, -1) as value
end
]====]

function M.prepare(workspace, include_io)
    local layout = async_stdlib.exact_layout(workspace)
    async_stdlib.refresh_private_runtime(workspace)

    async_stdlib.write_source(workspace, "titan.string", STRING_SUPPORT)
    async_stdlib.compile(workspace, "titan.string", {
        layout = layout,
        cppflags = "",
    })
    async_stdlib.register_exact_provider(layout, "titan.string")
    async_stdlib.prepare_async_core(workspace, layout, { "os" })

    if include_io then
        async_stdlib.write_source(
            workspace, "titan.io", async_stdlib.read("titan/io.titan"))
        async_stdlib.compile(workspace, "titan.io", {
            layout = layout,
            cppflags = "",
        })
        async_stdlib.register_exact_provider(layout, "titan.io")
    end
    return layout
end

-- The facade fixtures are deliberately self-contained exact-provider graphs.
-- Running them must not require (or fall back to) the shared combined standard
-- image, which may be absent or concurrently replaced by packaging tests. The
-- workspace's own support module installs the Titan searcher.
function M.run_lua_source(workspace, layout, source, options)
    options = options or {}
    local cpath = workspace .. "/titan-runtime/bootstrap/?.so;" ..
        workspace .. "/?.so"
    local lua_path = workspace .. "/?.lua"
    local command = {
        "env -u LUA_PATH -u LUA_CPATH" ..
            " -u LUA_PATH_5_5 -u LUA_CPATH_5_5",
        "TITAN_PATH_0_6=" .. quote(layout.library_root),
        "TITAN_PATH=",
        "LUA_PATH=" .. quote(lua_path),
        "LUA_PATH_5_5=" .. quote(lua_path),
        "LUA_CPATH=" .. quote(cpath),
        "LUA_CPATH_5_5=" .. quote(cpath),
    }
    for _, argument in ipairs(options.exec_prefix or {}) do
        command[#command + 1] = quote(argument)
    end
    command[#command + 1] = quote(host_lua())
    command[#command + 1] = "-e"
    command[#command + 1] = quote('require "titan"')
    command[#command + 1] = "-e"
    command[#command + 1] = quote(source)
    return async_stdlib.run(
        table.concat(command, " "), options.cwd or workspace)
end

return M
