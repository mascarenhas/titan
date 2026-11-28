local path = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local M = {}
-- WebAssembly JavaScript Interface implementation-defined byte limits.
local MAX_IMAGE_BYTES, MAX_BODY_BYTES = 1073741824, 7654321

function M.sdk_assets(paths)
    local root = paths.titan_bin
    return {
        runtime = paths.libtitan,
        factory = path.join(root, "titan-wasm-factory.mjs"),
        loader = path.join(root, "titan-browser.mjs"),
        runner = path.join(root, "titan-browser-run"),
        runner_module = path.join(root, "titan-browser-run.mjs"),
        node_worker = path.join(root, "titan-browser-node-worker.mjs"),
        page = path.join(root, "titan-browser-page.mjs"),
        -- The storage runtime: embedded or published only for an image that
        -- links it (see `M.storage`).
        vfs = path.join(root, "titan-browser-vfs.mjs"),
        sql = path.join(root, "titan-browser-sql.mjs"),
        storage_worker = path.join(root, "titan-storage-worker.mjs"),
        sqlite_service = path.join(root, "titan-sqlite3-service.wasm"),
        build_profile = path.join(root, "build-profile"),
        lpeglabel = path.join(root, "libtitan-lpeglabel.a"),
        provider = path.join(root, "titan.a"),
        sdk_digests = paths.sdk_digests,
    }
end

function M.runner_argv(launcher, ...)
    if platform.windows then return { "sh.exe", path.to_slash(launcher), ... } end
    return { launcher, ... }
end

-- Keep the normal Windows launcher/provider layout with a private module name.
function M.windows_runner_files(release)
    return { "bin/titan-browser-job.exe",
        "lib/titan/" .. release .. "/_titan_browser/windows_job.dll" }
end

-- Keep diagnostics usable from the same host shell as the failed build.
-- The caller supplies the user's root spelling, never the certified path.
function M.install_command(goal, prefix, rocks_tree, profile)
    local make = platform.windows and "mingw32-make -f Makefile.win " or "make "
    if goal == "compiler" then
        return make .. (platform.windows and "compiler" or "install-compiler-sdk")
    end
    local target = goal == "lua" and (platform.windows and "lua-browser" or "install-browser") or "browser-sdk"
    local command = make .. target .. " PREFIX=" .. prefix
    if rocks_tree and rocks_tree ~= "" then command = command .. " ROCKS_TREE=" .. rocks_tree end
    if profile then command = command .. " TITAN_BUILD_PROFILE=" .. profile end
    return command
end

function M.compiler_remedy()
    return (platform.windows and "run '" or "run 'luarocks make' or '") ..
        M.install_command("compiler") .. "' first"
end

function M.require_sdk(context, descriptor, install)
    local assets = M.sdk_assets(descriptor.paths)
    local function command()
        return M.install_command("sdk", install.prefix, install.rocks_tree)
    end
    for _, key in ipairs({ "runtime", "factory", "loader", "runner", "runner_module", "node_worker",
            "page", "vfs", "sql", "storage_worker", "sqlite_service", "build_profile" }) do
        local filename = assets[key]
        local stat = context.io:stat(filename)
        local readable = stat and stat.kind == "file" and context.io:read_file(filename, 0)
        if not readable then
            return nil, "browser SDK is incomplete: missing " .. string.format("%q", filename) ..
                "; run '" .. command() .. "'"
        end
    end
    -- The SDK's archives were compiled for one build profile, and a link must
    -- use the same one.
    local recorded = context.io:read_file(assets.build_profile, 32)
    local profile = recorded and recorded:match("^(%l+)\n$")
    if not profile or not require("titan-compiler.browsertarget").valid_profile(profile) then
        return nil, "browser SDK build profile " .. string.format("%q", assets.build_profile) ..
            " is invalid; run '" .. command() .. "'"
    end
    if profile ~= descriptor.build_profile then
        local rocks = install.rocks_tree and install.rocks_tree ~= "" and "<tree>" or nil
        return nil, string.format("browser SDK %q was built with the %s profile, but this build uses %s; " ..
            "set TITAN_BUILD_PROFILE=%s, or build a %s browser SDK in another prefix with '%s'",
            descriptor.paths.titan_bin, profile, descriptor.build_profile, profile, descriptor.build_profile,
            M.install_command("sdk", "<prefix>", rocks, descriptor.build_profile))
    end
    if platform.windows then
        for _, relative in ipairs(M.windows_runner_files(require("titan-compiler.version").TITAN_LIBRARY_VERSION)) do
            local filename = path.join(descriptor.paths.root, relative)
            local stat = context.io:stat(filename)
            if not stat or stat.kind ~= "file" then
                return nil, "browser SDK is incomplete: missing " .. string.format("%q", filename) ..
                    "; run '" .. command() .. "'"
            end
        end
    end
    return assets
end

local purposes = { program = true, test = true, protocol = true, gate = true,
    minicoro = true, budget = true, baseline = true }
local option_keys = { purpose = true, optimization = true, budgets = true }
-- Initial memory is the image's static data and stack plus `initial_heap`;
-- 15 MiB is the heap a data-free image had under a fixed 16 MiB.
local defaults = { stack_size = 1048576,
    initial_heap = 15728640, maximum_memory = 2147483648 }
-- The post-link optimizer reads exactly the features the objects use; it
-- would otherwise encode instructions the engines refuse.
local OPTIMIZER_FEATURES = { "--enable-exception-handling", "--enable-multivalue", "--enable-bulk-memory",
    "--enable-mutable-globals", "--enable-sign-ext", "--enable-nontrapping-float-to-int",
    "--enable-reference-types" }

-- The image's link (`link_flags`, to clang as the reactor driver) and post-link
-- (`optimizer_flags`, to wasm-opt) of one purpose. Every image exports its
-- memory, function table and stack bounds to the factory; the entrypoint
-- carries the entry points' and the allocator's own export names.
function M.profile(descriptor, options)
    if type(options) ~= "table" then return nil, "browser link profile options are required" end
    for key in pairs(options) do
        if not option_keys[key] then return nil, "unknown browser link profile option " .. tostring(key) end
    end
    local purpose = options.purpose
    if not purposes[purpose] then return nil, "invalid browser link profile purpose" end
    local optimization = options.optimization
    if optimization ~= nil and (optimization ~= "O1" and optimization ~= "O2" or
            purpose ~= "minicoro" and purpose ~= "budget" and purpose ~= "baseline") then
        return nil, "invalid browser link optimization override"
    end
    local budgets = {}
    for key, value in pairs(defaults) do budgets[key] = value end
    if options.budgets ~= nil then
        if purpose ~= "budget" or type(options.budgets) ~= "table" then
            return nil, "browser budget overrides require the budget profile"
        end
        for key, value in pairs(options.budgets) do
            local alignment = (key == "initial_heap" or key == "maximum_memory") and 65536 or 16
            if defaults[key] == nil or math.type(value) ~= "integer" or value <= 0 or value % alignment ~= 0 then
                return nil, "invalid browser budget override " .. tostring(key)
            end
            budgets[key] = value
        end
        -- Compare before subtracting: an aligned override can be any positive
        -- integer, and their sum could wrap.
        if budgets.maximum_memory > 2147483648 or budgets.stack_size > budgets.maximum_memory or
                budgets.initial_heap > budgets.maximum_memory - budgets.stack_size then
            return nil, "invalid browser memory budgets"
        end
    end
    local compile = {}
    local effective_opt
    if optimization then
        effective_opt = "-" .. optimization
        compile[1] = effective_opt
    else
        for _, flag in ipairs(descriptor.compile_flags) do
            if flag:match("^%-O") then effective_opt = flag end
        end
    end
    local profile = descriptor.build_profile
    if not require("titan-compiler.browsertarget").valid_profile(profile) then
        return nil, "invalid browser build profile"
    end
    local flags = { "-mexec-model=reactor", "-Wl,--stack-first",
        "-Wl,-z,stack-size=" .. budgets.stack_size, "-Wl,--initial-heap=" .. budgets.initial_heap,
        "-Wl,--max-memory=" .. budgets.maximum_memory, "-Wl,--gc-sections", "-Wl,--export-table",
        "-Wl,--export=__stack_pointer", "-Wl,--export=__stack_low", "-Wl,--export=__stack_high" }
    if purpose == "gate" then
        flags[#flags + 1] = "-Wl,--export=titan_browser_gate_guarded"
        flags[#flags + 1] = "-Wl,--export=titan_browser_gate_observe"
    end
    for _, library in ipairs({ "-lc-printscan-long-double", "-lsetjmp", "-lwasi-emulated-process-clocks" }) do
        flags[#flags + 1] = library
    end
    -- `--stack-check` traps a function whose frame would cross the active
    -- stack's low bound (the factory programs it through
    -- `__set_stack_limits`). A production program optimizes like its
    -- objects; production test images keep distinct function identities for
    -- their exact traces, which object-level -fno-inline alone does not do.
    local optimizer = { effective_opt or "-O1", "--debuginfo", "--stack-check" }
    if profile == "production" and purpose == "test" then
        optimizer[#optimizer + 1] = "--skip-pass=inlining-optimizing"
        optimizer[#optimizer + 1] = "--skip-pass=duplicate-function-elimination"
    end
    for _, feature in ipairs(OPTIMIZER_FEATURES) do optimizer[#optimizer + 1] = feature end
    return { link_flags = flags, optimizer_flags = optimizer, compile_flags = compile,
        identity_inputs = { target_identity = descriptor.identity, profile = profile,
            purpose = purpose, optimization = effective_opt, backend = "jspi", budgets = budgets,
            link_flags = flags, optimizer_flags = optimizer, compile_flags = compile } }
end

-- Target-owned settings cannot be weakened by trailing user flags: the
-- linker options that place the stack, size and grow memory, choose the
-- exports, imports and entry, or drop the names and line tables traces need.
-- An option's `--no-` spelling is the same option; a linker response file
-- could carry any of them.
local OWNED_LINKER = { ["stack-first"] = true, z = true, ["stack-size"] = true, ["initial-heap"] = true,
    ["initial-memory"] = true, ["max-memory"] = true, ["growable-memory"] = true, export = true,
    ["export-all"] = true, ["export-dynamic"] = true, ["export-if-defined"] = true, ["export-memory"] = true,
    ["export-table"] = true, ["import-memory"] = true, ["import-table"] = true, ["import-undefined"] = true,
    ["allow-undefined"] = true, ["allow-undefined-file"] = true, ["unresolved-symbols"] = true,
    e = true, entry = true, ["shared-memory"] = true, ["gc-sections"] = true,
    s = true, S = true, ["strip-all"] = true, ["strip-debug"] = true,
    ["global-base"] = true, ["table-base"] = true, ["growable-table"] = true, ["experimental-pic"] = true }
local OWNED_DRIVER = { ["-s"] = true, ["-z"] = true, ["-e"] = true, ["-nostartfiles"] = true,
    ["-nostdlib"] = true, ["-nodefaultlibs"] = true }
-- Driver options that select another linker than the SDK's certified wasm-ld.
local function selects_linker(flag)
    return flag:match("^%-fuse%-ld=") or flag:match("^%-%-ld%-path=") or flag:match("^%-B") or
        flag:match("^%-%-prefix")
end
local OWNED_DEFINES = { TITAN_TARGET_BROWSER = true, TITAN_COROUTINE_STACK_SIZE = true,
    TITAN_CODEC_DEPTH_LIMIT = true, _WASI_EMULATED_PROCESS_CLOCKS = true }
-- Emscripten options that put JavaScript or files into the generated module
-- have no wasi-sdk spelling; each names the supported route instead.
local JAVASCRIPT = "add JavaScript through titan.browser bindings or create({ imports })"
local CONTENT_OPTIONS = {
    ["--pre-js"] = JAVASCRIPT, ["--post-js"] = JAVASCRIPT, ["--extern-pre-js"] = JAVASCRIPT,
    ["--extern-post-js"] = JAVASCRIPT, ["--js-library"] = JAVASCRIPT,
    ["--embed-file"] = "browser images have no filesystem",
    ["--preload-file"] = "browser images have no filesystem",
}
-- `origin` is "compile" for a caller's compile extras and "link" otherwise, so
-- one owned option is reported by the diagnostic that owns it: the compile
-- message matches `browsertarget.build`'s, the link message names the link
-- profile.
function M.validate_extras(flags, options, build_profile, origin)
    local label = build_profile and ("browser " .. build_profile .. " link profile") or
        "browser link profile"
    local compile_label = "browser profile"
    if build_profile then compile_label = "browser " .. build_profile .. " profile" end
    local function owns(flag)
        if origin == "compile" then
            return nil, compile_label .. " owns compile option " .. string.format("%q", flag)
        end
        return nil, label .. " owns option " .. flag
    end
    for index, flag in ipairs(flags or {}) do
        local content = flag:match("^(%-%-[%w-]+)=") or flag
        if CONTENT_OPTIONS[content] then
            return nil, (origin == "compile" and compile_label or label) .. " does not accept " ..
                content .. "; " .. CONTENT_OPTIONS[content]
        end
        local purpose = options and options.purpose
        if purpose ~= "baseline" and purpose ~= "minicoro" and purpose ~= "budget" and
            require("titan-compiler.browsertarget").trace_option(flag) then
            return owns(flag)
        end
        local define = flag:match("^%-[DU](.+)") or (flag == "-D" or flag == "-U") and flags[index + 1]
        if OWNED_DRIVER[flag] or selects_linker(flag) or define and OWNED_DEFINES[define:match("^([%w_]+)")] then
            return owns(flag)
        end
        local linker = flag:match("^%-Wl,(.*)$") or flags[index - 1] == "-Xlinker" and flag
        for argument in ((linker or "") .. ","):gmatch("([^,]*),") do
            if argument:sub(1, 1) == "@" then
                return nil, (origin == "compile" and compile_label or label) ..
                    " does not accept linker response file " .. flag
            end
            local name = argument:match("^%-%-?([%w-]+)") or ""
            if OWNED_LINKER[name] or OWNED_LINKER[(name:gsub("^no%-", ""))] then return owns(flag) end
        end
    end
    return true
end

function M.check_image_size(size)
    if size > MAX_IMAGE_BYTES then
        return nil, string.format("browser image is %d bytes, exceeds maximum of %d bytes",
            size, MAX_IMAGE_BYTES)
    end
    return true
end

local function js_string(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
        return string.format("\\u%04x", char:byte())
    end) .. '"'
end

local HEX64 = "^" .. string.rep("[0-9a-f]", 64) .. "$"

-- The storage runtime an image links, read from its import section: units
-- that use titan.fs, os.cwd, os.chdir or titan.lua call
-- `env.titan_browser_vfs_*` from their module initialization, and
-- titan.sqlite3 `env.titan_browser_sql_retire_sync`. Returns nil, "vfs" or
-- "sql" (the filesystem and SQLite). An image that links neither embeds no
-- storage JavaScript and publishes no worker or SQLite service.
local STORAGE_IMPORTS = { titan_browser_vfs_linked = "vfs", titan_browser_vfs_retire_sync = "vfs",
    titan_browser_sql_retire_sync = "sql" }
function M.storage(imports)
    local linked
    for _, import in ipairs(imports) do
        local kind = import.kind == 0 and import.module == "env" and STORAGE_IMPORTS[import.name]
        if kind == "sql" then return "sql" end
        linked = linked or kind or nil
    end
    return linked
end

-- The image-scoped companions beside `<stem>.wasm`: the storage worker and
-- the SQLite service.
function M.companion_names(wasm_name)
    local stem = wasm_name:gsub("%.wasm$", "")
    return stem .. ".worker.mjs", stem .. ".sqlite3.wasm"
end

-- A published worker starts with this line naming its image's identity, so
-- a later link removes a worker only when Titan wrote it.
local WORKER_SENTINEL = "// Titan-Generated-Browser-Worker: "
function M.worker_module(worker, identity)
    return WORKER_SENTINEL .. identity .. "\n" .. worker
end

function M.generated_worker(bytes)
    local line = bytes:match("^([^\n]*)\n")
    return line ~= nil and line:sub(1, #WORKER_SENTINEL) == WORKER_SENTINEL and
        line:sub(#WORKER_SENTINEL + 1):match(HEX64) ~= nil
end

-- The SHA-256 of the SQLite service a published image module names, or nil.
function M.embedded_sqlite_digest(module_bytes)
    return module_bytes:match("\nexport default function create%(.-sqlite: {wasm: \"[^\"\n]*\", sha256: \"(" ..
        string.rep("[0-9a-f]", 64) .. ")\"}")
end

-- A storage source has the factory's surface: its one exported function
-- becomes a module-level declaration.
local function companion_source(text, name)
    local count
    text, count = ("\n" .. text):gsub("\nexport function " .. name .. "%(", "\nfunction " .. name .. "(")
    if count ~= 1 or text:match("\n%s*export%s") or text:match("\n%s*import%s") then return nil end
    return text:sub(2)
end

-- One image module: the SDK's static factory, the storage runtime the image
-- links, the loader, then the image's `create`. The factory's named seams
-- become plain declarations, so an image exports only `create`, and its
-- trailing default export is the instantiate function the loader receives.
-- The image binding names the `.wasm`, the identity the linked Wasm exports,
-- so the loader refuses a `.wasm` from another link before any entry, and
-- the module's own directory. `storage`, when the image links it, holds the
-- `vfs` source and, for SQLite, the `sql` source and the published service's
-- `sqlite_sha256`; the binding then names the storage, the worker and the
-- service. The default `locateFile` keeps every `new URL` literal visible to
-- bundlers. A module evaluated from an opaque URL (`blob:` or `data:`) has no
-- directory: with a caller `locateFile` the binding names an empty one
-- instead of throwing.
function M.embed(factory, loader, wasm_name, identity, storage)
    if type(identity) ~= "string" or not identity:match(HEX64) then
        return nil, "browser image identity must be 64 lowercase hexadecimal digits"
    end
    local instantiate, count
    factory, count = ("\n" .. factory):gsub("\nexport default ([%a_$][%w_$]*);%s*$", function(name)
        instantiate = name
        return "\n"
    end)
    factory = factory:gsub("\nexport function ", "\nfunction ")
    if count ~= 1 or factory:match("\n%s*export%s") or factory:match("\n%s*import%s") then
        return nil, "browser factory has an unsupported module surface"
    end
    loader, count = loader:gsub("export function create%(", "function create(", 1)
    if count ~= 1 or loader:match("\n%s*export%s") or loader:match("^%s*export%s") or
            loader:match("\n%s*import%s") or loader:match("^%s*import%s") then
        return nil, "browser loader has an unsupported module surface"
    end
    local wasm, trace = js_string(wasm_name), js_string(wasm_name .. ".trace")
    local runtime, binding, located = { factory:sub(2) }, "", ""
    if storage then
        local vfs = companion_source(storage.vfs, "titanBrowserStorage")
        if not vfs then return nil, "browser filesystem runtime has an unsupported module surface" end
        runtime[#runtime + 1] = vfs
        local worker_name, sqlite_name = M.companion_names(wasm_name)
        local worker, sqlite = js_string(worker_name), js_string(sqlite_name)
        binding = ",\n    storage: titanBrowserStorage, worker: " .. worker
        located = "name === " .. worker .. " ? new URL(" .. worker .. ", import.meta.url).href :\n    "
        if storage.sql then
            local sql = companion_source(storage.sql, "titanBrowserSql")
            if not sql then return nil, "browser SQLite runtime has an unsupported module surface" end
            if type(storage.sqlite_sha256) ~= "string" or not storage.sqlite_sha256:match(HEX64) then
                return nil, "browser SQLite service digest must be 64 lowercase hexadecimal digits"
            end
            runtime[#runtime + 1] = sql
            binding = binding .. ",\n    sql: titanBrowserSql, sqlite: {wasm: " .. sqlite .. ", sha256: \"" ..
                storage.sqlite_sha256 .. "\"}"
            located = located .. "name === " .. sqlite .. " ? new URL(" .. sqlite .. ", import.meta.url).href :\n    "
        end
    end
    return table.concat(runtime, "\n") .. "\nconst titanCreate = (() => {\n" .. loader ..
        "\nreturn create;\n})();\n" ..
        "export default function create(options = {}) {\n" ..
        "  const locateFile = options.locateFile ?? (name => name.endsWith('.wasm.trace') ?\n" ..
        "    new URL(" .. trace .. ", import.meta.url).href : " .. located ..
        "new URL(" .. wasm .. ", import.meta.url).href);\n" ..
        "  const directory = options.locateFile != null && !URL.canParse('.', import.meta.url) ? '' :\n" ..
        "    new URL('.', import.meta.url).href;\n" ..
        "  return titanCreate(" .. instantiate .. ", {...options, locateFile}, {identity: \"" .. identity ..
        "\", wasm: " .. wasm .. ", directory" .. binding .. "});\n}\n"
end

-- The protocol probe image links the program's own C, so it may import host
-- functions that only the program's `create({ imports })` supplies. The
-- probe runs no provider code, only its metadata functions, so a stand-in
-- that returns zero values lets the image instantiate even when a C
-- constructor calls one. Imports the runtime owns are left to it, and any
-- other kind of import still fails instantiation. `imports` are
-- `image_inventory`'s. Returns nil when there is nothing to add.
local ZERO = { i64 = "0n", funcref = "null", externref = "null", exnref = "null" }
function M.protocol_imports(imports)
    local modules, order = {}, {}
    for _, import in ipairs(imports) do
        local module, name = import.module, import.name
        if import.kind == 0 and module ~= "wasi_snapshot_preview1" and not (module == "env" and
                (name:sub(1, 14) == "titan_browser_" or name:sub(1, 10) == "titan_mco_")) then
            if not modules[module] then
                modules[module] = {}
                order[#order + 1] = module
            end
            local values = {}
            for value in import.signature:match("%->%((.*)%)$"):gmatch("[^,]+") do
                values[#values + 1] = ZERO[value] or "0"
            end
            local result = #values == 0 and "undefined" or #values == 1 and values[1] or
                "[" .. table.concat(values, ", ") .. "]"
            -- Computed keys, so that even a `__proto__` name is an own property.
            table.insert(modules[module], "[" .. js_string(name) .. "]: () => " .. result)
        end
    end
    if #order == 0 then return nil end
    local entries = {}
    for index, module in ipairs(order) do
        entries[index] = "  [" .. js_string(module) .. "]: {" .. table.concat(modules[module], ", ") .. "}"
    end
    return "export default {\n" .. table.concat(entries, ",\n") .. "\n};\n"
end

-- Inventory shares the bounded final-image walk with the map rewriter.
function M.image_inventory(bytes)
    local valid, err = M.check_image_size(#bytes)
    if not valid then return nil, err end
    local image
    image, err = require("titan-compiler.staticmetadata").browser_trace_image(bytes)
    if not image then return nil, err end
    for index, range in ipairs(image.function_ranges) do
        local size = range[2] - range[1]
        if size > MAX_BODY_BYTES then
            local wasm_index = image.function_imports + index - 1
            local name = image.function_names[wasm_index + 1]
            local label = name and name ~= "" and
                string.format("function %q (Wasm index %d)", name, wasm_index) or
                ("function at Wasm index " .. wasm_index)
            -- The existing range lets the driver enrich only this error with
            -- mapped source, without reparsing the Wasm or copying its body.
            return nil, string.format("browser image %s body is %d bytes, exceeds maximum of %d bytes",
                label, size, MAX_BODY_BYTES), range
        end
    end
    for _, import in ipairs(image.imports) do
        local name = import.name
        if name:match("^_?dlopen") or name:match("^_?dlsym") or
            name:match("^_?dlerror") or name:match("^_*backtrace") then
            return nil, "browser image imports forbidden symbol " .. string.format("%q", name)
        end
    end
    return { imports = image.imports, exports = image.exports }
end

return M
