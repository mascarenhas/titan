-- Browser playground bundle for `make playground-sdk`: the compiler Wasm and
-- its adapter, the semantic catalog, and the link-only SDK the page compiles
-- user C against. Inputs are this checkout and the installed validation
-- browser SDK; nothing installed is modified.
-- Implementation notes: doc/implementation/playground-bundle.md
local build_dir, out_dir, repository = ...
assert(build_dir and out_dir and repository, "usage: playground_sdk.lua BUILD_DIR OUT_DIR REPOSITORY " ..
    "[--runtime-source FILE]... [--lpeglabel-source FILE]... ROOT...")
-- The SDK's runtime and LPegLabel C sources (Make's lists), then the browser
-- standard library roots.
local runtime_sources, lpeglabel_sources, roots = {}, {}, {}
do
    local arguments = { select(4, ...) }
    local index = 1
    while index <= #arguments do
        local argument = arguments[index]
        if argument == "--runtime-source" or argument == "--lpeglabel-source" then
            local list = argument == "--runtime-source" and runtime_sources or lpeglabel_sources
            list[#list + 1] = assert(arguments[index + 1], argument .. " needs a file")
            index = index + 2
        else
            roots[#roots + 1] = argument
            index = index + 1
        end
    end
    assert(#runtime_sources > 0 and #lpeglabel_sources > 0 and #roots > 0, "runtime sources and roots are required")
end

local function getenv(name)
    local value = os.getenv(name)
    if value == nil or value == "" then return nil end
    return value
end

local prefix = assert(getenv("PREFIX"), "PREFIX is required")
local install_tree = getenv("TITAN_INSTALL_TREE") or prefix

do
    local roots_list = install_tree ~= prefix and { install_tree, prefix } or { install_tree }
    local lua_paths, c_paths = {}, {}
    for _, root in ipairs(roots_list) do
        lua_paths[#lua_paths + 1] = root .. "/share/lua/5.5/?.lua"
        lua_paths[#lua_paths + 1] = root .. "/share/lua/5.5/?/init.lua"
        c_paths[#c_paths + 1] = root .. "/lib/lua/5.5/?.so"
    end
    lua_paths[#lua_paths + 1] = package.path
    c_paths[#c_paths + 1] = package.cpath
    package.path = table.concat(lua_paths, ";")
    package.cpath = table.concat(c_paths, ";")
end

local lfs = require "lfs"
local support = require "titan"
local driver = require "titan-compiler.driver"
local browser_target = require "titan-compiler.browsertarget"
local compiler_io = require "titan-compiler.io"
local graphcodec = require "titan-compiler.graphcodec"
local paths = require "titan-compiler.path"
local sha256 = require "titan-compiler.sha256"
local staticmetadata = require "titan-compiler.staticmetadata"
local util = require "titan-compiler.util"
local cdriver = require "c-parser.cdriver"

local strategy = compiler_io.new_sync()
-- titan.a is a public asset; the page's static host refuses larger files.
local MAX_PROVIDER_BYTES = 25 * 1024 * 1024

local function fail(message)
    io.stderr:write("playground-sdk: ", tostring(message), "\n")
    os.exit(1)
end

local function ensure_dir(dir)
    if lfs.attributes(dir, "mode") == "directory" then return end
    local parent = paths.dirname(dir)
    if parent and parent ~= dir then ensure_dir(parent) end
    local made, err = lfs.mkdir(dir)
    if not made and lfs.attributes(dir, "mode") ~= "directory" then
        fail("cannot create directory '" .. dir .. "': " .. tostring(err))
    end
end

local function read(filename)
    local bytes, err = strategy:read_file(filename)
    if not bytes then fail("cannot read '" .. filename .. "': " .. tostring(err)) end
    return bytes
end

local function write(filename, bytes)
    ensure_dir(assert(paths.dirname(filename)))
    local written, err = strategy:write_file(filename, bytes)
    if not written then fail("cannot write '" .. filename .. "': " .. tostring(err)) end
end

local function run(argv, what)
    local result = strategy:run(argv, { stderr_to_stdout = true })
    if not result.ok then
        fail(what .. " failed: " .. tostring(result.output or result.diagnostic))
    end
    return result.output or ""
end

local function sorted_keys(map)
    local keys = {}
    for key in pairs(map) do keys[#keys + 1] = key end
    table.sort(keys, util.bytewise_less)
    return keys
end

-- Deterministic JSON: sorted object keys, arrays as written.
local function json(value, out)
    out = out or {}
    if type(value) == "string" then
        out[#out + 1] = '"' .. value:gsub('[%c"\\]', function(char)
            local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\t'] = '\\t', ['\r'] = '\\r' }
            return escapes[char] or string.format("\\u%04x", char:byte())
        end) .. '"'
    elseif value[1] ~= nil then
        out[#out + 1] = "["
        for index, item in ipairs(value) do
            if index > 1 then out[#out + 1] = "," end
            json(item, out)
        end
        out[#out + 1] = "]"
    else
        out[#out + 1] = "{"
        for index, key in ipairs(sorted_keys(value)) do
            if index > 1 then out[#out + 1] = "," end
            json(key, out)
            out[#out + 1] = ":"
            json(value[key], out)
        end
        out[#out + 1] = "}"
    end
    return out
end

local function write_json(filename, value)
    write(filename, table.concat(json(value)) .. "\n")
end

-- A deterministic ustar archive of regular files and directories: relative
-- names of at most 100 bytes, directory names without a trailing slash,
-- parents before children, zero owner and time.
local function ustar(entries)
    local blocks = {}
    local function octal(value, width)
        return string.format("%0" .. (width - 1) .. "o", value) .. "\0"
    end
    for _, entry in ipairs(entries) do
        assert(#entry.name <= 100 and entry.name:sub(1, 1) ~= "/" and entry.name:sub(-1) ~= "/",
            "invalid archive member name " .. entry.name)
        local contents = entry.contents or ""
        local header = entry.name .. string.rep("\0", 100 - #entry.name) ..
            octal(entry.contents and 420 or 493, 8) .. octal(0, 8) .. octal(0, 8) ..
            octal(#contents, 12) .. octal(0, 12) .. "        " ..
            (entry.contents and "0" or "5") .. string.rep("\0", 100) .. "ustar\0" .. "00" ..
            string.rep("\0", 32) .. string.rep("\0", 32) .. octal(0, 8) .. octal(0, 8) ..
            string.rep("\0", 155) .. string.rep("\0", 12)
        local sum = 0
        for index = 1, #header do sum = sum + header:byte(index) end
        header = header:sub(1, 148) .. string.format("%06o", sum) .. "\0 " .. header:sub(157)
        blocks[#blocks + 1] = header
        blocks[#blocks + 1] = contents .. string.rep("\0", (512 - #contents % 512) % 512)
    end
    blocks[#blocks + 1] = string.rep("\0", 1024)
    return table.concat(blocks)
end

-- A Lua long string holding `text` verbatim.
local function long_string(text)
    local level = 0
    while text:find("]" .. string.rep("=", level) .. "]", 1, true) do level = level + 1 end
    local equals = string.rep("=", level)
    return "[" .. equals .. "[\n" .. text .. "]" .. equals .. "]"
end

-- The run's own directories, checked before anything is written or removed.
-- Neither the build directory nor the output may overlap the checkout's
-- library sources, the installation, the toolchain or each other. Each must
-- be missing, empty or marked as an earlier run's: the build directory with
-- `.playground-build`, the output with `.playground-bundle` (which the
-- packager, reading named files, never publishes). The output may not be a
-- symbolic link, and a marked one may hold only bundle files, which the run
-- replaces; only the build directory's own contents are ever removed.
local BUILD_MARKER = ".playground-build"
local OUT_MARKER = ".playground-bundle"
local BUNDLE = { ["titanc.wasm"] = "file", ["titanc.mjs"] = "file", ["stdlib_catalog.bin"] = "file",
    ["analysis-target"] = "file", ["absent-modules"] = "file", ["stdlib-sources.json"] = "file",
    ["titan.a"] = "file", ["libtitan.a"] = "file", ["libtitan-lpeglabel.a"] = "file", ["liblua.a"] = "file",
    ["headers.tar"] = "file", ["link-plan.json"] = "file", ["titan-browser.mjs"] = "file",
    ["titan-wasm-factory.mjs"] = "file", ["LICENSE"] = "file", ["THIRD_PARTY_NOTICES.md"] = "file",
    ["LICENSES"] = "directory" }
local NOTICES = {}
for name in lfs.dir(paths.join(repository, "LICENSES")) do
    if name:sub(1, 1) ~= "." then NOTICES[#NOTICES + 1] = name end
end
table.sort(NOTICES, util.bytewise_less)

-- The physical spelling of `path`: its deepest existing ancestor resolved,
-- then the missing remainder.
local function physical(path)
    if not paths.is_absolute(path) then path = paths.join(assert(lfs.currentdir()), path) end
    path = paths.normalize(path)
    local missing = {}
    while not lfs.symlinkattributes(path, "mode") do
        local parent = paths.dirname(path)
        if not parent or parent == path then break end
        table.insert(missing, 1, paths.basename(path))
        path = parent
    end
    local real, err = strategy:realpath(path)
    if not real then fail("cannot resolve '" .. path .. "': " .. tostring(err)) end
    for _, name in ipairs(missing) do real = paths.join(real, name) end
    return real
end

local function within(path, directory)
    return path == directory or path:sub(1, #directory + 1) == directory .. "/"
end

local physical_build, physical_out = physical(build_dir), physical(out_dir)
local function refuse_overlaps(protected)
    for _, owned in ipairs({ { "the build directory", physical_build }, { "the output directory", physical_out } }) do
        for _, input in ipairs(protected) do
            if within(owned[2], input[2]) or within(input[2], owned[2]) then
                fail(owned[1] .. " '" .. owned[2] .. "' overlaps " .. input[1] .. " '" .. input[2] .. "'")
            end
        end
    end
end
refuse_overlaps({ { "the library sources", physical(paths.join(repository, "titan")) },
    { "the installation", physical(install_tree) }, { "the prefix", physical(prefix) } })
if within(physical_build, physical_out) or within(physical_out, physical_build) then
    fail("the build directory '" .. physical_build .. "' and the output directory '" .. physical_out .. "' overlap")
end

local function entries(directory)
    local names = {}
    for name in lfs.dir(directory) do
        if name ~= "." and name ~= ".." then names[#names + 1] = name end
    end
    table.sort(names, util.bytewise_less)
    return names
end

for _, directory in ipairs({ build_dir, out_dir }) do
    local mode = lfs.attributes(directory, "mode")
    if mode and mode ~= "directory" then fail("'" .. directory .. "' is not a directory") end
end
if lfs.symlinkattributes(out_dir, "mode") == "link" then
    fail("the output directory '" .. out_dir .. "' is a symbolic link; name the directory itself")
end
-- Whether `directory` exists with entries but without its run's marker.
local function unowned(directory, marker)
    return lfs.attributes(directory, "mode") and #entries(directory) > 0 and
        lfs.symlinkattributes(paths.join(directory, marker), "mode") ~= "file"
end
if unowned(build_dir, BUILD_MARKER) then
    fail("the build directory '" .. build_dir .. "' holds files playground-sdk did not create; " ..
        "choose another TITAN_PLAYGROUND_BUILD_DIR")
end
if unowned(out_dir, OUT_MARKER) then
    fail("the output directory '" .. out_dir .. "' is not empty and is not an earlier playground bundle; " ..
        "choose an empty or missing PLAYGROUND_OUT")
end
if lfs.attributes(out_dir, "mode") then
    local notices = {}
    for _, name in ipairs(NOTICES) do notices[name] = "file" end
    local expected = { [OUT_MARKER] = "file" }
    for name, kind in pairs(BUNDLE) do expected[name] = kind end
    for _, listing in ipairs({ { out_dir, expected }, { paths.join(out_dir, "LICENSES"), notices } }) do
        if lfs.symlinkattributes(listing[1], "mode") then
            for _, name in ipairs(entries(listing[1])) do
                if lfs.symlinkattributes(paths.join(listing[1], name), "mode") ~= listing[2][name] then
                    fail("the output directory '" .. out_dir .. "' holds '" .. name .. "', which is not a " ..
                        "bundle file")
                end
            end
        end
    end
end

-- A bundle file's path in the output directory.
local function output(name)
    assert(BUNDLE[name:match("^[^/]+")], name)
    return paths.join(out_dir, name)
end

local sdk = driver.installed_paths(install_tree, "browser")
local profile = read(paths.join(sdk.titan_bin, "build-profile"))
if profile ~= "validation\n" then
    fail("the playground needs a validation browser SDK; " .. sdk.titan_bin .. " is " .. profile:gsub("\n", ""))
end
local jobs = getenv("TITAN_JOBS") or "4"

-- The real validated descriptor of this SDK, without this script's own
-- build flags: it names the toolchain and the compile and link recipe of a
-- playground program.
driver.EXTRA_CPPFLAGS, driver.EXTRA_CFLAGS, driver.EXTRA_LDFLAGS = {}, {}, {}
driver.TITAN_ROOT = install_tree
driver.INSTALL_PATHS = driver.installed_paths(install_tree)
local build_context = driver.new_resolver_context({ io = strategy, target = "browser" })
local descriptor, descriptor_error = driver.context_target_descriptor(build_context)
if not descriptor then fail(descriptor_error) end
if #descriptor.include_dirs ~= 2 or descriptor.include_dirs[1] ~= sdk.lua_source or
    descriptor.include_dirs[2] ~= sdk.include then
    fail("unexpected browser include roots")
end
local wasi_sdk = descriptor.tools.location
refuse_overlaps({ { "wasi-sdk", physical(wasi_sdk) } })
ensure_dir(build_dir)
write(paths.join(build_dir, BUILD_MARKER), "")
ensure_dir(out_dir)
write(paths.join(out_dir, OUT_MARKER), "")

-- Every C object the bundle ships is compiled by the same titanc browser
-- recipe as the SDK's, plus prefix maps: line tables and `__FILE__` name the
-- checkout, SDK and wasi-sdk logically, so the bytes do not depend on where
-- those trees are. Clang applies the last matching map, so the most specific
-- (longest) prefix comes last.
local lean_dir = paths.join(build_dir, "provider")
local provider_sources = paths.join(lean_dir, "src")
local titanc_environment
do
    local maps = { { repository, "." }, { install_tree, "titan-sdk" }, { wasi_sdk, "wasi-sdk" },
        { provider_sources, "." } }
    table.sort(maps, function(left, right) return #left[1] < #right[1] end)
    local flags = {}
    for index, map in ipairs(maps) do
        flags[index] = cdriver.shell_quote("-ffile-prefix-map=" .. map[1] .. "=" .. map[2])
    end
    titanc_environment = { "env", "TITAN_ROOT=" .. install_tree, "TITAN_PATH_0_6=.", "TITAN_PATH=",
        "CPPFLAGS=", "TITAN_EXTRA_CPPFLAGS=" .. cdriver.shell_quote("-I" .. paths.join(repository, "vendor/lpeglabel")),
        "TITAN_EXTRA_CFLAGS=" .. table.concat(flags, " "), "TITAN_EXTRA_LDFLAGS=",
        paths.join(install_tree, "bin/titanc"), "--target", "browser" }
end

-- Run titanc in `directory` (default: the checkout).
local function titanc(arguments, what, directory)
    local argv = { table.unpack(titanc_environment) }
    for _, argument in ipairs(arguments) do argv[#argv + 1] = argument end
    if directory then assert(lfs.chdir(directory)) end
    local output = run(argv, what)
    if directory then assert(lfs.chdir(repository)) end
    return output
end

local function copy_tree(source, destination)
    for name in lfs.dir(source) do
        if name ~= "." and name ~= ".." then
            local from, to = paths.join(source, name), paths.join(destination, name)
            if lfs.attributes(from, "mode") == "directory" then
                copy_tree(from, to)
            else
                write(to, read(from))
            end
        end
    end
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then remove_tree(paths.join(path, name)) end
        end
        assert(lfs.rmdir(path))
    elseif mode then
        assert(os.remove(path))
    end
end

-- 1. The runtime and LPegLabel archives, from the SDK's own sources.
local runtime_archive = paths.join(build_dir, "runtime/libtitan.a")
local lpeglabel_archive = paths.join(build_dir, "runtime/libtitan-lpeglabel.a")
do
    local arguments = { "--output", paths.join(build_dir, "runtime"), "-c", "-q", "--print-c-objects" }
    local sources = {}
    for _, list in ipairs({ runtime_sources, lpeglabel_sources }) do
        for _, source in ipairs(list) do
            sources[#sources + 1] = source
            arguments[#arguments + 1] = "--c-source"
            arguments[#arguments + 1] = source
        end
    end
    local objects = {}
    for line in titanc(arguments, "compiling the runtime"):gmatch("[^\n]+") do objects[#objects + 1] = line end
    if #objects ~= #sources then fail("unexpected runtime object list") end
    -- Members are named after their sources, not the certified object paths.
    local function archive(output, first, last)
        local inputs = {}
        for index = first, last do
            local classified, err = staticmetadata.classify_object(read(objects[index]), objects[index],
                descriptor.fingerprint)
            if not classified then fail(err) end
            local member = paths.basename(sources[index]):gsub("%.c$", ".o")
            inputs[#inputs + 1] = { path = member, object = classified }
        end
        local built, err = driver.build_static_archive(output, inputs, nil, descriptor.fingerprint, false, nil,
            build_context)
        if not built then fail(err) end
    end
    archive(runtime_archive, 1, #runtime_sources)
    archive(lpeglabel_archive, #runtime_sources + 1, #objects)
end

-- The fork owns the browser Lua build. Its line tables name the builder's
-- checkout and wasi-sdk and never reach a trace table, which keeps only
-- `.titan` rows, so the bundle's copy drops its debug sections.
local lua_archive = paths.join(build_dir, "runtime/liblua.a")
run({ paths.join(wasi_sdk, "bin/llvm-objcopy"), "--strip-debug", sdk.liblua, lua_archive }, "stripping liblua.a")

-- 2. The link-only provider: the browser standard library rebuilt without
-- source records. It compiles a copy of the library's sources inside its
-- output root, which the compiler relocates, so the identities of the C
-- headers beside those sources (and with them the provider's metadata) do not
-- name the checkout. The root is claimed for the browser target, as titanc
-- claims an empty one, before the copy makes it nonempty.
do
    -- Inside the marked build directory: never anything else.
    assert(within(physical(provider_sources), physical_build))
    remove_tree(provider_sources)
    ensure_dir(lean_dir)
    local claimed, claim_error = driver.validate_output_target(build_context, lean_dir, true)
    if not claimed then fail(claim_error) end
    copy_tree(paths.join(repository, "titan"), paths.join(provider_sources, "titan"))
    local arguments = { "--output", lean_dir, "--source-first", "--no-source-records", "-j" .. jobs,
        "-X", lpeglabel_archive, "-q" }
    for _, root in ipairs(roots) do arguments[#arguments + 1] = root end
    titanc(arguments, "building the link-only provider", provider_sources)
end
local provider = read(paths.join(lean_dir, "titan.a"))
if #provider >= MAX_PROVIDER_BYTES then
    fail("the link-only provider is " .. #provider .. " bytes; the limit is " .. MAX_PROVIDER_BYTES)
end
write(output("titan.a"), provider)

-- 3. The semantic assets: analysis-target rebound to this provider, and the
-- catalog captured from one validated scan of it.
local digest_context = { cache_adapter = { sha256_binary = support._sha256_binary } }
local analysis = assert(browser_target.decode_analysis(digest_context, read(paths.join(sdk.titan_bin, "analysis-target"))))
analysis.provider_sha256 = sha256.hex_via(support._sha256_binary, provider)
local analysis_bytes = assert(browser_target.encode_analysis_data(digest_context, analysis))
local absent = read(paths.join(sdk.titan_bin, "absent-modules"))
local semantic_root = paths.join(build_dir, "semantic")
local semantic = driver.installed_paths(semantic_root, "browser").titan_bin
write(paths.join(semantic, "titan.a"), provider)
write(paths.join(semantic, "analysis-target"), analysis_bytes)
write(paths.join(semantic, "absent-modules"), absent)
local handle, handle_error = driver.browser_analysis_target(semantic_root)
if not handle then fail(handle_error) end
local catalog = assert(driver.browser_analysis_catalog(handle))
write(output("analysis-target"), analysis_bytes)
write(output("absent-modules"), absent)
write(output("stdlib_catalog.bin"), catalog)

-- 4. The selected browser sources of every provider module, keyed by their
-- checkout-relative paths (the paths the provider's line tables name).
do
    local context = driver.new_resolver_context({ target = "browser", analysis_only = true,
        browser_analysis_target = handle })
    local sources = {}
    local checkout = repository .. "/"
    for _, name in ipairs(sorted_keys(assert(graphcodec.decode(catalog)).modules)) do
        local source, err = driver.resolve_source(context, name, repository)
        if not source then fail("cannot resolve the source of " .. name .. ": " .. tostring(err)) end
        for _, filename in ipairs(source.files) do
            if filename:sub(1, #checkout) ~= checkout then fail(filename .. " is outside " .. repository) end
            sources[filename:sub(#checkout + 1)] = read(filename)
        end
    end
    assert(driver.close_resolver_context(context))
    write_json(output("stdlib-sources.json"), sources)
end

-- 5. The compile and link recipe of a playground program.
do
    local plan, err = driver.browserlink.profile(descriptor, { purpose = "program" })
    if not plan then fail(err) end
    local compile_flags = {}
    for index, flag in ipairs(descriptor.compile_flags) do compile_flags[index] = flag end
    write_json(output("link-plan.json"), {
        compile_flags = compile_flags, include_roots = { "lua", "sdk" },
        link_flags = plan.link_flags, optimizer_flags = plan.optimizer_flags,
    })
end

-- 6. The include roots those flags name: verified browser Lua headers and
-- the Titan SDK headers.
do
    local entries = { { name = "lua" } }
    local lua_headers = {}
    for name in lfs.dir(sdk.lua_source) do
        if name:match("%.h$") then lua_headers[#lua_headers + 1] = name end
    end
    table.sort(lua_headers, util.bytewise_less)
    for _, name in ipairs(lua_headers) do
        entries[#entries + 1] = { name = "lua/" .. name, contents = read(paths.join(sdk.lua_source, name)) }
    end
    local sdk_entries, directories = {}, { sdk = true }
    for _, relative in ipairs(browser_target.SDK_HEADERS) do
        local directory = relative:match("^(.*)/[^/]+$")
        if directory then directories["sdk/" .. directory] = true end
        sdk_entries["sdk/" .. relative] = read(paths.join(sdk.include, relative))
    end
    for directory in pairs(directories) do sdk_entries[directory] = false end
    for _, name in ipairs(sorted_keys(sdk_entries)) do
        entries[#entries + 1] = { name = name, contents = sdk_entries[name] or nil }
    end
    write(output("headers.tar"), ustar(entries))
end

-- 7. The compiler Wasm: this installation's compiler Lua, its pure Lua
-- dependencies and the playground entry, over the bundle's browser Lua,
-- LPegLabel and Titan support archives.
do
    local share = paths.join(install_tree, "share/lua/5.5")
    local modules = {}
    local excluded = { ["titan-compiler.build"] = true, ["titan-compiler.build_worker"] = true,
        ["titan-compiler.process"] = true, ["titan-compiler.titanc"] = true }
    local function collect(directory, relative)
        for name in lfs.dir(directory) do
            local full, child = paths.join(directory, name), relative .. "/" .. name
            local mode = name:sub(1, 1) ~= "." and lfs.attributes(full, "mode")
            if mode == "directory" then
                collect(full, child)
            elseif mode == "file" and name:match("%.lua$") then
                local modname = child:gsub("%.lua$", ""):gsub("/", ".")
                if not excluded[modname] then modules[modname] = { file = child, source = read(full) } end
            end
        end
    end
    collect(paths.join(share, "titan-compiler"), "titan-compiler")
    collect(paths.join(share, "c-parser"), "c-parser")
    modules.relabel = { file = "relabel.lua", source = read(paths.join(repository, "vendor/lpeglabel/relabel.lua")) }
    modules.inspect = { file = "inspect.lua", source = read(paths.join(share, "inspect.lua")) }
    modules.lfs = { file = "lfs.lua", source = read(paths.join(repository, "titan-runtime/playground/lfs.lua")) }
    local chunks = { "-- Generated by scripts/playground_sdk.lua: the playground compiler's Lua modules.\n",
        "local preload, load = package.preload, load\n",
        "local function module(name, chunkname, source)\n",
        "    preload[name] = function(...) return assert(load(source, chunkname, \"t\"))(...) end\n",
        "end\n" }
    for _, modname in ipairs(sorted_keys(modules)) do
        local item = modules[modname]
        chunks[#chunks + 1] = string.format("module(%q, %q, ", modname, "@" .. item.file) ..
            long_string(item.source) .. ")\n"
    end
    chunks[#chunks + 1] = 'return require("titan-compiler.playground").host()\n'
    local wasm_dir = paths.join(build_dir, "titanc")
    write(paths.join(wasm_dir, "titanc-bundle.lua"), table.concat(chunks))
    local compile = browser_target.compiler_argv(descriptor.tools)
    for _, flag in ipairs(descriptor.compile_flags) do compile[#compile + 1] = flag end
    for _, argument in ipairs({ "-std=c23", "-I", sdk.lua_source, "--embed-dir=" .. wasm_dir, "-c",
            paths.join(repository, "titan-runtime/playground/titanc.c"), "-o", paths.join(wasm_dir, "titanc.o") }) do
        compile[#compile + 1] = argument
    end
    run(compile, "compiling titanc.c")
    local link = browser_target.compiler_argv(descriptor.tools)
    for _, argument in ipairs({ "-mexec-model=reactor", "-Wl,--stack-first", "-Wl,-z,stack-size=8388608",
            "-Wl,--strip-debug", "-o", output("titanc.wasm"), paths.join(wasm_dir, "titanc.o"),
            lua_archive, runtime_archive, lpeglabel_archive,
            "-lsetjmp", "-lwasi-emulated-process-clocks", "-lc-printscan-long-double" }) do
        link[#link + 1] = argument
    end
    run(link, "linking titanc.wasm")
end

-- 8. The remaining inputs of a playground link and its loader, the adapter,
-- and the notices covering every redistributed file.
write(output("liblua.a"), read(lua_archive))
write(output("libtitan.a"), read(runtime_archive))
write(output("libtitan-lpeglabel.a"), read(lpeglabel_archive))
for _, name in ipairs({ "titan-browser.mjs", "titan-wasm-factory.mjs" }) do
    write(output(name), read(paths.join(sdk.titan_bin, name)))
end
write(output("titanc.mjs"), read(paths.join(repository, "titan-runtime/playground/titanc.mjs")))
for _, name in ipairs({ "LICENSE", "THIRD_PARTY_NOTICES.md" }) do
    write(output(name), read(paths.join(repository, name)))
end
for _, name in ipairs(NOTICES) do
    write(output("LICENSES/" .. name), read(paths.join(repository, "LICENSES/" .. name)))
end

-- 9. The compiler must open over its own catalog and emit a program.
run({ getenv("TITAN_NODE") or "node", paths.join(repository, "scripts/playground_smoke.mjs"), out_dir },
    "checking titanc.wasm")
print("playground-sdk: wrote " .. out_dir)
