local assert = require "luassert"
local lfs = require "lfs"
local driver = require "titan-compiler.driver"
local platform = require "titan-compiler.platform"
local paths = require "titan-compiler.path"
local process = require "titan-compiler.process"
local temporary = require "spec.support.temporary"
local children = require "spec.support.luacov_children"
local M = {}
local repository = assert(lfs.currentdir())
if platform.windows then repository = assert(platform.path.normalize(repository)) end
local prefix = require("spec.support.installed_prefix").active()
local suffix = platform.windows and ".exe" or ""

function M.mkdir(path)
    if lfs.attributes(path, "mode") == "directory" then return end
    local parent = paths.dirname(path)
    if parent ~= path and parent ~= "." then M.mkdir(parent) end
    assert(lfs.mkdir(path))
end
function M.write(path, bytes)
    M.mkdir(paths.dirname(path))
    local file = assert(io.open(path, "wb"))
    assert(file:write(bytes)); assert(file:close())
end
function M.read(path)
    local file = assert(io.open(path, "rb"))
    local bytes = assert(file:read("a")); assert(file:close()); return bytes
end
-- A false result means an explicitly loaded Windows DLL remains mapped until
-- this process exits. Its ancestors stay for the worker's later temp cleanup.
function M.remove(path, loaded_images)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        local empty = true
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                if M.remove(path .. "/" .. name, loaded_images) == false then
                    empty = false
                end
            end
        end
        if not empty then return false end
        assert(lfs.rmdir(path))
    elseif mode then
        local removed, message, code = os.remove(path)
        if not removed and platform.windows and mode == "file" and code == 13
           and path:lower():match("[.]dll$") and loaded_images
           and loaded_images[paths.normalize(path)] then
            return false
        end
        assert(removed, message)
    end
    return true
end
function M.copy(from, to)
    if lfs.attributes(from, "mode") ~= "directory" then M.write(to, M.read(from)); return end
    M.mkdir(to)
    for name in lfs.dir(from) do
        if name ~= "." and name ~= ".." then M.copy(from .. "/" .. name, to .. "/" .. name) end
    end
end
function M.host()
    local context = driver.new_resolver_context()
    local target = assert(driver.context_target(context))
    assert(driver.close_resolver_context(context))
    return target
end
function M.new()
    local root = temporary.name(); assert(os.remove(root)); M.mkdir(root)
    local self = { root = root, source = root .. "/source", output = root .. "/out",
        frontend = root .. "/compiler", host = M.host(), prefix = prefix }
    M.mkdir(self.source)
    M.copy(repository .. "/titan-compiler", self.frontend .. "/titan-compiler")
    M.copy(repository .. "/c-parser", self.frontend .. "/c-parser")
    M.copy(repository .. "/titanc", self.frontend .. "/titanc")
    M.copy(repository .. "/titan-config.lua", self.frontend .. "/titan-config.lua")
    self.collector = children.new(repository, self.frontend, root .. "/luacov")
    function self:run(argv, env, provider_root)
        provider_root = provider_root or self.output
        local environment = { TITAN_ROOT = prefix, TITAN_TARGET = "", TERM = "dumb",
            TITAN_PATH_0_6 = provider_root .. ";" .. prefix .. "/lib/titan/0.6",
            TITAN_PROBE_CACHE_DISABLE = "1", TITAN_EXTRA_CPPFLAGS = "",
            TITAN_EXTRA_CFLAGS = "-O0 -fno-lto", TITAN_EXTRA_LDFLAGS = "-fno-lto",
            PATH = prefix .. "/bin" .. (platform.windows and ";" or ":") .. (os.getenv("PATH") or "") }
        for name, value in pairs(env or {}) do environment[name] = value end
        local result = process.capture(argv, { cwd = self.root, env = environment })
        result.output = (result.output or result.diagnostic or ""):gsub("\r\n", "\n")
        return result
    end
    function self:compile(arguments, env, adjacent)
        local init = string.format("package.path=%q..package.path; ",
            self.frontend .. "/?.lua;" .. self.frontend .. "/?/init.lua;") .. self.collector:init_code()
        local argv = { prefix .. "/bin/lua" .. suffix, "-E", "-e", init,
            self.frontend .. "/titanc", "--tree", self.source }
        if not adjacent then argv[#argv + 1] = "--output"; argv[#argv + 1] = self.output end
        for _, value in ipairs(arguments) do argv[#argv + 1] = value end
        local result = self:run(argv, env, adjacent and self.root or self.output)
        self.collector:collect()
        return result
    end
    function self:compiled(arguments, env, adjacent)
        local result = self:compile(arguments, env, adjacent)
        assert.is_true(result.ok, result.output)
        return result.output
    end
    function self:program(name, relative, adjacent)
        local output = adjacent and self.root or self.output
        local executable = platform.windows and
            assert(driver.windows_program_paths(name, nil, nil, output)).executable or
            output .. "/" .. (relative or name:gsub("%.", "/"))
        local provider_root = platform.windows and output .. "/lib/titan/0.6" or output
        return self:run({ executable }, nil, provider_root)
    end
    function self:close(loaded_images)
        self.collector:collect()
        local retained
        if platform.windows and loaded_images then
            retained = {}
            for _, image in ipairs(loaded_images) do retained[paths.normalize(image)] = true end
        end
        M.remove(self.root, retained)
    end
    return self
end
return M
