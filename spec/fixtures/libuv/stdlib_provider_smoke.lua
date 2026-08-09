local mode = assert(arg[1], "missing stdlib provider mode")
assert(mode == "bundled" or mode == "system", mode)

local builtin_io = require "io"
local builtin_math = require "math"
local builtin_string = require "string"

local uv = require "titan.uv"
local async = require "titan.async"
local timer = require "titan.timer"
local titan_io = require "titan.io"
local fs = require "titan.fs"
local net = require "titan.net"
local ssl = require "titan.ssl"
local url = require "titan.url"
local http = require "titan.http"
local system = require "titan.os"
local peg = require "titan.peg"
local strings = require "titan.string"
local math = require "titan.math"
local lua = require "titan.lua"
local iter = require "titan.iter"
local gc = require "titan.gc"
local testing = require "titan.test"

local path = os.tmpname()
os.remove(path)
local parsed_url, parse_error = url.parse(
    "https://localhost:8443/provider?q=1")
assert(parse_error == nil)
assert(parsed_url.scheme == "https")
assert(parsed_url.host == "localhost")
assert(parsed_url.port == 8443)
assert(parsed_url.target == "/provider?q=1")
local task_finished = false
local task = async.run(function()
    timer.sleep(0)
    async.yield()
    fs.write_file(path, mode .. "\0uv")
    assert(fs.read_file(path) == mode .. "\0uv")
    fs.unlink(path)

    local reader = strings.reader("reader\0payload")
    assert(reader:read() == "reader\0payload")
    assert(reader:read() == nil)
    local writer = strings.writer()
    writer:write("writer")
    writer:write("\0payload")
    assert(writer:drain() == "writer\0payload")
    assert(writer:drain() == "")
    task_finished = true
end)
async.loop()
assert(task:status():as_string() == "succeeded")
assert(task_finished)

assert(peg.literal("peg"):match("peg") == 4)
assert(strings.len("a\0b") == 3)
local found = strings.match("regex42", "([0-9]+)")
assert(found and found:whole() == "42" and found:group(1) == "42")
assert(strings.find("a\0b", "\0b") == 2)

assert(math.sqrt(81.0) == 9.0)
assert(math.tonumber("0xff") == 255)
local chunk = lua.load("return ...", "=provider-smoke", nil)
local values = table.pack(chunk(1, nil, 3))
assert(values.n == 3 and values[1] == 1 and
       values[2] == nil and values[3] == 3)

local count = 0
local sum = 0
for _key, value in iter.pairs({ left = 20, right = 22 }) do
    count = count + 1
    sum = sum + value
end
assert(count == 2 and sum == 42)

local epoch = system.date("!*t", 0)
assert(epoch.year == 1970 and epoch.month == 1 and epoch.day == 1)

assert(require "io" == builtin_io)
assert(require "math" == builtin_math)
assert(require "string" == builtin_string)
assert(type(titan_io) == "userdata")
assert(type(async.version()) == "string")
assert(type(uv) == "userdata")
assert(type(net) == "userdata")
assert(type(ssl) == "userdata")
assert(type(http) == "userdata")
assert(type(testing) == "userdata")
assert(not testing.testing())
assert(not testing.verbose())

local initially_paused = gc.paused()
gc.pause()
assert(gc.paused())
if not initially_paused then gc.resume() end
assert(gc.paused() == initially_paused)
