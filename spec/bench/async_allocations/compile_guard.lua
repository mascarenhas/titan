local cli = assert(table.remove(arg, 1))
local allowed = assert(table.remove(arg, 1))
arg[0] = cli
local driver = require "titan-compiler.driver"
assert(driver.TITAN_ABI_VERSION == "2", "generated ABI changed")
assert(driver.TITAN_VERSION == "0.6.0", "package version changed")
assert(driver.TITAN_LIBRARY_VERSION == "0.6", "SDK namespace changed")
assert(driver.LANGUAGE_SERVER_API_VERSION == 1, "language-server API changed")
local parser = require "titan-compiler.parser"
local parse = parser.parse
local count = 0
parser.parse = function(filename, input)
  assert(filename == allowed, "unexpected source fallback: " .. tostring(filename))
  count = count + 1
  io.stdout:write("MEASUREMENT_SOURCE_PARSE:", filename, "\n")
  return parse(filename, input)
end
dofile(cli)
assert(count == 1, "measurement consumer must parse exactly one source module")
io.stdout:write("SOURCE_FREE_IMPORTS: ABI=2 SDK=0.6 LSP=1 consumer_sources=1\n")
