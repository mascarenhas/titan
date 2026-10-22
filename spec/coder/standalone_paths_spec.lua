-- Exercise the generated launcher and runtime loader in relocated processes.
local driver = require "titan-compiler.driver"
local compiler_io = require "titan-compiler.io"
local platform = require "titan-compiler.platform"
local core = require "titan-compiler.coder.core"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"
local repository = assert(lfs.currentdir())
local prefix = require("spec.support.installed_prefix").active()

local function run(argv)
    local result = compiler_io.new_sync():run(argv)
    assert.is_true(result.started and result.ok, result.output or result.diagnostic)
    return result.output or ""
end
local function write(filename, contents)
    local file = assert(io.open(filename, "wb"))
    assert(file:write(contents))
    assert(file:close())
end
local function mkdir(directory)
    run({ "mkdir", "-p", directory })
end

-- These shell stubs exercise Unix PATH lookup and physical symlink
-- resolution. Windows path policy is covered in spec/standalone_paths_spec.lua.
local unix_it = platform.windows and pending or it

describe("standalone launcher path discovery", function()
    local workspace, executable, tree, tools, cwd
    setup(function()
        if platform.windows then return end
        workspace = assert(compiler_io.new_sync():tmpname())
        assert(os.remove(workspace))
        mkdir(workspace)
        workspace = assert(compiler_io.new_sync():realpath(workspace))
        tree, tools, cwd = workspace .. "/SDK é with spaces", workspace .. "/tools", workspace .. "/cwd"
        for _, dir in ipairs({ tree .. "/share/lua/5.5", tree .. "/lib/titan/0.6", tools, cwd,
                               workspace .. "/application" }) do mkdir(dir) end
        executable = workspace .. "/application/probe"
        local paths = assert(driver.installed_paths(prefix))
        local native = workspace .. "/native.c"
        write(native, "int standalone_answer(void) { return 42; }\n")
        local cc = assert(cdriver.split_shell_words(driver.CC))
        local shared = { table.unpack(cc) }
        for _, arg in ipairs({ "-shared", "-fPIC", native, "-o", tree .. "/lib/titan/0.6/discoverable.so" }) do
            shared[#shared + 1] = arg
        end
        run(shared)
        write(tree .. "/share/lua/5.5/discoverable.lua", "return 42\n")
        local source = driver.entrypoint_contents("standalone_probe") .. [[
static int probe_main(lua_State *L) {
    typedef int (*answer_fn)(void);
    void *provider = loadlib(L, "discoverable.so");
    answer_fn answer = titan_cast_func(answer_fn,
        loadsym(L, provider, "standalone_answer"));
    if (answer() != 42) return luaL_error(L, "wrong native provider");
    if (luaL_dostring(L, "assert(require('discoverable') == 42)") != LUA_OK)
        return lua_error(L);
    lua_pushinteger(L, 0);
    return 1;
}
int luaopen_standalone_probe(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, probe_main);
    lua_setfield(L, -2, "main");
    return 1;
}
]]
        write(workspace .. "/launcher.c", source)
        local argv = { table.unpack(cc) }
        for _, arg in ipairs({ "-std=c99", "-O0", "-Wall", "-Wextra",
            "-I" .. paths.include, "-I" .. paths.lua_source, workspace .. "/launcher.c" }) do
            argv[#argv + 1] = arg
        end
        for _, arg in ipairs(driver.installed_link_inputs(paths, driver.IS_DARWIN)) do
            argv[#argv + 1] = arg
        end
        argv[#argv + 1], argv[#argv + 2] = "-o", executable
        run(argv)
    end)
    teardown(function()
        if workspace then run({ "rm", "-rf", workspace }) end
    end)
    before_each(function()
        if tools then
            os.remove(tools .. "/titanc")
            os.remove(tools .. "/lua")
        end
    end)
    local function stub(name, body)
        write(tools .. "/" .. name, "#!/bin/sh\n" .. body .. "\n")
        run({ "chmod", "+x", tools .. "/" .. name })
    end
    local function launch(program, overrides)
        local argv = { "env", "-u", "LUA_PATH", "-u", "LUA_PATH_5_5",
            "-u", "LUA_CPATH", "-u", "LUA_CPATH_5_5", "-u", "TITAN_PATH",
            "-u", "TITAN_PATH_0_6", "PATH=" .. tools }
        for _, value in ipairs(overrides or {}) do argv[#argv + 1] = value end
        argv[#argv + 1] = program or executable
        -- Change CWD explicitly: the synchronous strategy's portable run API
        -- does not own a per-command working directory.
        local previous = assert(lfs.currentdir())
        assert(lfs.chdir(cwd))
        local ok, err = pcall(run, argv)
        assert(lfs.chdir(previous))
        assert.is_true(ok, err)
    end
    unix_it("loads native and Lua dependencies from titanc's discovered tree", function()
        stub("titanc", '[ "$1" = --print-root ] || exit 1\nprintf "%s\\n" ' .. assert(cdriver.shell_quote(tree)))
        stub("lua", "exit 99")
        launch()
    end)
    unix_it("loads from Lua's tree when titanc is missing or fails", function()
        stub("lua", 'printf "%s" ' .. assert(cdriver.shell_quote(tree .. "/lib/titan/0.6/?.so")))
        launch()
        stub("titanc", "echo /invalid; exit 1")
        launch()
    end)
    unix_it("uses the physical executable directory from another CWD and through a symlink", function()
        local app = workspace .. "/application"
        mkdir(app .. "/lib/titan/0.6")
        mkdir(app .. "/share/lua/5.5")
        run({ "cp", tree .. "/lib/titan/0.6/discoverable.so", app .. "/lib/titan/0.6/discoverable.so" })
        run({ "cp", tree .. "/share/lua/5.5/discoverable.lua", app .. "/share/lua/5.5/discoverable.lua" })
        launch()
        run({ "ln", "-s", executable, tools .. "/probe" })
        launch("probe")
    end)
    unix_it("runs a Titan program with a separately compiled dynamic dependency", function()
        local sources = workspace .. "/source"
        mkdir(sources)
        write(sources .. "/path_dependency.titan", [[
function answer(): integer
    return 42
end
]])
        write(sources .. "/path_consumer.titan", [[
local dependency = import "path_dependency"
function main(args: {string}): integer
    if dependency.answer() == 42 then return 0 end
    return 1
end
]])
        local function compile(output, module)
            run({ "env", "-u", "LUA_PATH", "-u", "LUA_PATH_5_5",
                "-u", "LUA_CPATH", "-u", "LUA_CPATH_5_5", "CCACHE_DISABLE=1",
                "TITAN_ROCKS_ROOT=" .. prefix,
                "TITAN_PATH_0_6=" .. tree .. "/lib/titan/0.6", "TITAN_PATH=",
                prefix .. "/bin/lua", "-e", "package.path=" ..
                    string.format("%q", repository .. "/?.lua;" .. repository .. "/?/init.lua;") ..
                    "..package.path", repository .. "/titanc",
                "--tree", sources, "--output", output, module })
        end
        compile(tree .. "/lib/titan/0.6", "path_dependency")
        -- Exclude source and archive fallback from the consumer build.
        assert(os.remove(sources .. "/path_dependency.titan"))
        assert(os.remove(tree .. "/lib/titan/0.6/path_dependency.a"))
        compile(workspace .. "/application", "path_consumer")
        stub("titanc", 'printf "%s\\n" ' .. assert(cdriver.shell_quote(tree)))
        launch(workspace .. "/application/path_consumer")
    end)
    unix_it("preserves explicit versioned and unversioned paths", function()
        stub("titanc", "echo /wrong")
        for _, suffix in ipairs({ "", "_5_5" }) do
            launch(nil, { "LUA_PATH" .. suffix .. "=" .. tree .. "/share/lua/5.5/?.lua",
                "LUA_CPATH" .. suffix .. "=" .. tree .. "/lib/titan/0.6/?.so",
                "TITAN_PATH" .. (suffix == "" and "" or "_0_6") .. "=" .. tree .. "/lib/titan/0.6" })
        end
    end)
    unix_it("inserts the discovered default for ;; in an explicit Titan path", function()
        stub("titanc", 'printf "%s\\n" ' .. assert(cdriver.shell_quote(tree)))
        for _, name in ipairs({ "TITAN_PATH", "TITAN_PATH_0_6" }) do
            launch(nil, { name .. "=" .. workspace .. "/missing;;" })
        end
    end)
end)
