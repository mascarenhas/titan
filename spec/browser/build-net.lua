-- Build native peers and the browser HTTP/WebSocket behavior images.
local lfs = require "lfs"
local process = require "titan-compiler.process"
local path = require "titan-compiler.path"
local suffix = require("titan-compiler.platform").windows and ".exe" or ""
local repository = assert(lfs.currentdir())
local output = assert(arg[1], "usage: lua -E spec/browser/build-net.lua OUTPUT")
assert(not arg[2], "build-net.lua accepts exactly one output directory")
if not path.is_absolute(output) then output = path.join(repository, output) end
local prefix = assert(os.getenv("TITAN_ROOT") or os.getenv("PREFIX"), "TITAN_ROOT or PREFIX is required")
local fixture = path.join(repository, "spec/fixtures/browser_net")
local images = path.join(output, "images")
local function mkdir(directory)
    if lfs.attributes(directory, "mode") == "directory" then return end
    local parent = path.dirname(directory)
    if parent ~= directory then mkdir(parent) end
    assert(lfs.mkdir(directory))
end
local function copy(name, directory)
    local input = assert(io.open(path.join(directory or fixture, name), "rb"))
    local bytes = assert(input:read("a")); assert(input:close())
    local file = assert(io.open(path.join(images, name), "wb"))
    assert(file:write(bytes)); assert(file:close())
end
local function compile(arguments, browser)
    local argv = {path.join(prefix, "bin/titanc" .. suffix), "-q", "--incremental"}
    for _, argument in ipairs(arguments) do argv[#argv + 1] = argument end
    local result = process.capture(argv, {cwd = repository, env = {
        TITAN_ROOT = prefix, TITAN_TARGET = "", TITAN_PATH_0_6 = browser and "" or nil,
        TITAN_EXTRA_CPPFLAGS = "", TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "",
    }})
    assert(result.ok, result.output or result.diagnostic)
end
mkdir(output)
mkdir(images)
compile({"--tree", fixture, "--output", path.join(output, "native"),
    "--exe", path.join(output, "native/server" .. suffix), "server"})
compile({"--target", "browser", "--no-uv-bootstrap", "--test", "--tree", path.join(repository, "spec/stdlib/titan"),
    "--output", path.join(output, "objects/http"), "--exe", path.join(images, "http.mjs"), "http.browser_tests"}, true)
compile({"--target", "browser", "--no-uv-bootstrap", "--test", "--tree", path.join(repository, "spec/stdlib/titan"),
    "--output", path.join(output, "objects/websocket"), "--exe", path.join(images, "websocket.mjs"),
    "websocket.browser_tests"}, true)
copy("net.test.mjs")
copy("same-origin.mjs")
copy("websocket.test.mjs")
-- The WebSocket image's host controls (titan_net_test_publish).
copy("fixture-imports.mjs", path.join(repository, "spec/fixtures/browser_runtime"))
-- Each image uses only reviewed imports (scripts/browser_imports.lua).
local checks = dofile(path.join(repository, "scripts/browser_stdlib.lua"))
local strategy = require("titan-compiler.io").new_sync()
-- The HTTP owner imports titan.lua, which links the filesystem runtime (D14).
assert(checks.check_file_imports(strategy, path.join(images, "http.mjs"), {"entry", "vfs"}))
assert(checks.check_file_imports(strategy, path.join(images, "websocket.mjs"), {"entry", "fixture:net"}))
io.stdout:write("BROWSER-NET " .. output .. " profile=" .. (os.getenv("TITAN_BUILD_PROFILE") or "production") .. "\n")
