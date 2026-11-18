local path = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local M = {}
-- WebAssembly JavaScript Interface implementation-defined byte limits.
local MAX_IMAGE_BYTES, MAX_BODY_BYTES = 1073741824, 7654321

function M.sdk_assets(paths)
    local root = paths.titan_bin
    return {
        runtime = paths.libtitan,
        js_library = path.join(root, "titan-browser-library.js"),
        bridge_library = path.join(root, "titan-browser-bridge.js"),
        trace_library = path.join(root, "titan-browser-trace.js"),
        loader = path.join(root, "titan-browser.mjs"),
        runner = path.join(root, "titan-browser-run"),
        runner_module = path.join(root, "titan-browser-run.mjs"),
        node_worker = path.join(root, "titan-browser-node-worker.mjs"),
        page = path.join(root, "titan-browser-page.mjs"),
        module_check = path.join(root, "titan-browser-module-check.mjs"),
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

-- The native pair stays in the ordinary Windows executable/provider layout.
function M.windows_runner_files(release)
    return { "bin/titan-browser-job.exe", "lib/titan/" .. release .. "/windows_browser_job.dll" }
end

function M.require_sdk(context, descriptor, install)
    local assets = M.sdk_assets(descriptor.paths)
    local make = platform.windows and "make -f Makefile.win browser-sdk" or "make browser-sdk"
    local command = make .. " PREFIX=" .. install.prefix
    if install.rocks_tree and install.rocks_tree ~= "" then
        command = command .. " ROCKS_TREE=" .. install.rocks_tree
    end
    for _, key in ipairs({ "runtime", "js_library", "bridge_library", "trace_library",
            "loader", "runner", "runner_module", "node_worker", "page", "module_check", "build_profile" }) do
        local filename = assets[key]
        local stat = context.io:stat(filename)
        local readable = stat and stat.kind == "file" and context.io:read_file(filename, 0)
        if not readable then
            return nil, "browser SDK is incomplete: missing " .. string.format("%q", filename) ..
                "; run '" .. command .. "'"
        end
    end
    -- The SDK's archives were compiled for one build profile, and a link must
    -- use the same one.
    local recorded = context.io:read_file(assets.build_profile, 32)
    local profile = recorded and recorded:match("^(%l+)\n$")
    if not profile or not require("titan-compiler.browsertarget").valid_profile(profile) then
        return nil, "browser SDK build profile " .. string.format("%q", assets.build_profile) ..
            " is invalid; run '" .. command .. "'"
    end
    if profile ~= descriptor.build_profile then
        local rocks = install.rocks_tree and install.rocks_tree ~= "" and " ROCKS_TREE=<tree>" or ""
        return nil, string.format("browser SDK %q was built with the %s profile, but this build uses %s; " ..
            "set TITAN_BUILD_PROFILE=%s, or build a %s browser SDK in another prefix with " ..
            "'%s PREFIX=<prefix>%s TITAN_BUILD_PROFILE=%s'", descriptor.paths.titan_bin,
            profile, descriptor.build_profile, profile, descriptor.build_profile, make, rocks, descriptor.build_profile)
    end
    if platform.windows then
        for _, relative in ipairs(M.windows_runner_files(require("titan-compiler.version").TITAN_LIBRARY_VERSION)) do
            local filename = path.join(descriptor.paths.root, relative)
            local stat = context.io:stat(filename)
            if not stat or stat.kind ~= "file" then
                return nil, "browser SDK is incomplete: missing " .. string.format("%q", filename) ..
                    "; run '" .. command .. "'"
            end
        end
    end
    return assets
end

local purposes = { program = true, test = true, protocol = true, gate = true,
    minicoro = true, budget = true, baseline = true }
local option_keys = { purpose = true, assertions = true, optimization = true,
    budgets = true, entry = true }
-- Initial memory is the image's static data and stack plus `initial_heap`;
-- 15 MiB is the heap a data-free image had under a fixed 16 MiB.
local defaults = { stack_size = 1048576,
    initial_heap = 15728640, maximum_memory = 2147483648 }

function M.profile(descriptor, options)
    if type(options) ~= "table" then return nil, "browser link profile options are required" end
    for key in pairs(options) do
        if not option_keys[key] then return nil, "unknown browser link profile option " .. tostring(key) end
    end
    local purpose = options.purpose
    if not purposes[purpose] then return nil, "invalid browser link profile purpose" end
    local assertions = options.assertions
    if assertions ~= 0 and assertions ~= 2 then return nil, "browser assertions must be 0 or 2" end
    local optimization = options.optimization
    if optimization ~= nil and (optimization ~= "O1" and optimization ~= "O2" or
            purpose ~= "minicoro" and purpose ~= "budget" and purpose ~= "baseline") then
        return nil, "invalid browser link optimization override"
    end
    local entry = options.entry or "titan"
    if entry ~= "titan" and (entry ~= "lua-main" or purpose ~= "baseline") then
        return nil, "invalid browser link entry"
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
    local flags, compile = {}, {}
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
    -- A production program link optimizes like its objects and accepts the
    -- frames that costs. Test images, the validation profile and the fixed
    -- harness purposes keep the frame flags.
    local frames = profile ~= "production" or purpose ~= "program"
    local function add(flag) flags[#flags + 1] = flag end
    add(effective_opt or "-O1")
    if frames then
        add("-fno-inline")
        add("-fno-optimize-sibling-calls")
    end
    add("-gsource-map")
    add("-g2")
    -- Preserve distinct function identities in production test traces.
    -- Object-level -fno-inline alone does not prevent Binaryen folding.
    local passes = ""
    if profile == "production" and purpose == "test" then
        passes = "--skip-pass=inlining-optimizing" ..
            ",--skip-pass=duplicate-function-elimination"
    end
    if entry == "titan" and passes ~= "" then
        add("-sBINARYEN_EXTRA_PASSES=" .. passes)
    end
    add("-sJSPI=1")
    -- The bridge library's driver relinquish is the only other suspending
    -- import; images without the bridge library keep the coroutine pair.
    local imports = entry == "titan" and
        '"titan_mco_transfer","titan_mco_destroy","titan_browser_relinquish"' or
        '"titan_mco_transfer","titan_mco_destroy"'
    local promised = entry == "titan" and
        '"titan_browser_initialize","titan_browser_entry","titan_browser_invoke",' ..
        '"titan_browser_close","titan_mco_entry"' or '"main"'
    if purpose == "gate" then
        imports = imports .. ',"emscripten_sleep"'
        promised = promised .. ',"titan_browser_gate_guarded"'
    end
    add("-sJSPI_IMPORTS=[" .. imports .. "]")
    add("-sJSPI_EXPORTS=[" .. promised .. "]")
    add("-sSUPPORT_LONGJMP=" .. descriptor.lua.record.sjlj)
    add("-sWASM_LEGACY_EXCEPTIONS=1")
    add("-sSTACK_SIZE=" .. budgets.stack_size)
    add("-sINITIAL_HEAP=" .. budgets.initial_heap)
    add("-sALLOW_MEMORY_GROWTH=1")
    add("-sMAXIMUM_MEMORY=" .. budgets.maximum_memory)
    add("-sABORTING_MALLOC=0")
    add("-sEXIT_RUNTIME=0")
    add("-sINVOKE_RUN=0")
    if entry == "titan" then add("--no-entry") end
    add("-sMODULARIZE=1")
    add("-sEXPORT_ES6=1")
    add("-sENVIRONMENT=web,node")
    -- Node 26 is the only supported Node; below 19, Emscripten's WASI
    -- `random_get` would `require('node:crypto')`.
    add("-sMIN_NODE_VERSION=260000")
    add(entry == "titan" and "-sFILESYSTEM=0" or "-sFORCE_FILESYSTEM=1")
    add("-sPRINTF_LONG_DOUBLE=1")
    local exports = entry == "titan" and
        '"_titan_browser_initialize","_titan_browser_entry","_titan_browser_invoke",' ..
        '"_titan_browser_release_callable","_titan_browser_close",' ..
        '"_malloc","_free","_titan_browser_trace_identity"' or
        '"_main","_malloc","_free"'
    if purpose == "gate" then
        exports = exports .. ',"_titan_browser_gate_guarded","_titan_browser_gate_observe"'
    end
    add("-sEXPORTED_FUNCTIONS=[" .. exports .. "]")
    add('-sEXPORTED_RUNTIME_METHODS=["HEAPU8"]')
    add(entry == "titan" and '-sINCOMING_MODULE_JS_API=["locateFile","onAbort"]' or
        '-sINCOMING_MODULE_JS_API=["stdin","stdout","stderr","locateFile","onAbort"]')
    if entry == "titan" then
        add("--js-library")
        add(M.sdk_assets(descriptor.paths).js_library)
        add("--js-library")
        add(M.sdk_assets(descriptor.paths).bridge_library)
        add("--js-library")
        add(M.sdk_assets(descriptor.paths).trace_library)
    end
    add("-sASSERTIONS=" .. assertions)
    add("-sSTACK_OVERFLOW_CHECK=2")
    return { link_flags = flags, compile_flags = compile,
        identity_inputs = { target_identity = descriptor.identity, profile = profile,
            purpose = purpose, entry = entry, assertions = assertions,
            optimization = effective_opt, backend = "jspi", budgets = budgets,
            link_flags = flags, compile_flags = compile } }
end

-- Target-owned settings cannot be weakened by trailing user flags. Accept
-- unrelated Emscripten settings, but reject every spelling of an owned one.
local owned = { SUPPORT_LONGJMP = true, WASM_LEGACY_EXCEPTIONS = true,
    JSPI = true, STACK_SIZE = true,
    INITIAL_MEMORY = true, INITIAL_HEAP = true, ALLOW_MEMORY_GROWTH = true, MAXIMUM_MEMORY = true,
    ABORTING_MALLOC = true, EXIT_RUNTIME = true, INVOKE_RUN = true,
    MODULARIZE = true, EXPORT_ES6 = true, ENVIRONMENT = true, MIN_NODE_VERSION = true,
    FORCE_FILESYSTEM = true, FILESYSTEM = true, MINIMAL_RUNTIME = true, PRINTF_LONG_DOUBLE = true,
    EXPORTED_FUNCTIONS = true, EXPORTED_RUNTIME_METHODS = true,
    INCOMING_MODULE_JS_API = true, ASSERTIONS = true, STACK_OVERFLOW_CHECK = true,
    TITAN_TARGET_BROWSER = true, TITAN_COROUTINE_STACK_SIZE = true,
    TITAN_CODEC_DEPTH_LIMIT = true,
    BINARYEN_EXTRA_PASSES = true }
-- Options that put a file's contents into the generated module or its data.
-- The image identity and the warm-link certificate record only owned inputs,
-- so a module built with one would match no recorded input; each names the
-- supported route instead.
local CONTENT_OPTIONS = {
    ["--pre-js"] = "add JavaScript with EM_JS or EM_ASM in a --c-source helper",
    ["--post-js"] = "add JavaScript with EM_JS or EM_ASM in a --c-source helper",
    ["--extern-pre-js"] = "add JavaScript with EM_JS or EM_ASM in a --c-source helper",
    ["--extern-post-js"] = "add JavaScript with EM_JS or EM_ASM in a --c-source helper",
    ["--js-transform"] = "the generated module is Titan's",
    ["--embed-file"] = "browser images have no filesystem",
    ["--preload-file"] = "browser images have no filesystem",
    ["--exclude-file"] = "browser images have no filesystem",
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
    for index, flag in ipairs(flags or {}) do
        local content = flag:match("^(%-%-[%w-]+)=") or flag
        if CONTENT_OPTIONS[content] then
            return nil, (origin == "compile" and compile_label or label) .. " does not accept " ..
                content .. "; " .. CONTENT_OPTIONS[content]
        end
        local purpose = options and options.purpose
        if purpose ~= "baseline" and purpose ~= "minicoro" and purpose ~= "budget" and
            require("titan-compiler.browsertarget").trace_option(flag) then
            if origin == "compile" then
                return nil, compile_label .. " owns compile option " .. string.format("%q", flag)
            end
            return nil, label .. " owns option " .. flag
        end
        local setting = flag:match("^%-[sDU](.+)") or
            (flag == "-s" or flag == "-D" or flag == "-U") and flags[index + 1]
        local key = setting and setting:match("^([%w_]+)")
        local positive = key and key:gsub("^NO_", "")
        if key and (owned[positive] or positive == "ASYNCIFY" or
                positive:match("^ASYNCIFY_") or positive:match("^JSPI_")) or
            flag == "--no-entry" or flag == "--js-library" or flag:match("^%-%-js%-library=") then
            if origin == "compile" then
                return nil, compile_label .. " owns compile option " .. string.format("%q", flag)
            end
            return nil, label .. " owns option " .. flag
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

-- Emscripten's `ENVIRONMENT=web,node` shell reaches Node's built-ins inside
-- `if (ENVIRONMENT_IS_NODE)` through `createRequire` and three `require`
-- calls; an optimizing link prints them again with either quote style, extra
-- parentheses and less whitespace. Node 26 provides the same modules
-- through `process.getBuiltinModule`, which needs no import, so one image
-- serves pages, bundlers and Node. Only these pinned statements change, all
-- of them or none; the module check refuses anything else.
local NODE_SHELL = {
    { "const%s*{%s*createRequire%s*}%s*=%s*await%s*%(*%s*import%(%s*(['\"])node:module%1%s*%)%s*%)*%s*;?", "" },
    { "var%s+require%s*=%s*createRequire%(%s*import%.meta%.url%s*%)%s*;?", "" },
    { "var%s+fs%s*=%s*require%(%s*(['\"])node:fs%1%s*%)%s*;?", "var fs = process.getBuiltinModule(%1fs%1);" },
    { "require%(%s*(['\"])node:path%1%s*%)%s*%.%s*dirname%s*%(%s*require%(%s*(['\"])node:url%2%s*%)%s*" ..
        "%.%s*fileURLToPath%s*%(%s*_scriptName%s*%)%s*%)",
        "process.getBuiltinModule(%1path%1).dirname(process.getBuiltinModule(%2url%2).fileURLToPath(_scriptName))" },
}

-- Emscripten's pinned ES-module output has one trailing default factory export.
-- Keep the factory lexical and its bundler-visible new URL expressions intact;
-- only the embedded owner is an application entrypoint. The owner receives the
-- image identity that the linked Wasm exports, so it refuses a `.wasm` from
-- another link before any entry. The Node shell is rewritten here; the module
-- check then refuses any module the embedded module would load.
function M.embed(image, loader, wasm_name, identity)
    if type(identity) ~= "string" or not identity:match("^" .. string.rep("[0-9a-f]", 64) .. "$") then
        return nil, "browser image identity must be 64 lowercase hexadecimal digits"
    end
    local factory
    local _, count = image:gsub("\n%s*export%s+default%s", "")
    if count ~= 1 then return nil, "browser image has no unique default factory export" end
    image, count = image:gsub("\nexport default ([%a_$][%w_$]*);%s*$", function(name)
        factory = name
        return "\n"
    end)
    if count ~= 1 then return nil, "browser image has no unique default factory export" end
    loader, count = loader:gsub("export function create%(", "function create(", 1)
    if count ~= 1 or loader:match("\n%s*export%s") or loader:match("^%s*export%s") or
            loader:match("\n%s*import%s") or loader:match("^%s*import%s") then
        return nil, "browser loader has an unsupported module surface"
    end
    local function quote(name)
        return '"' .. name:gsub('[%z\1-\31\\"]', function(char)
            return string.format("\\u%04x", char:byte())
        end) .. '"'
    end
    local wasm, trace = quote(wasm_name), quote(wasm_name .. ".trace")
    local rewritten = 0
    for _, rule in ipairs(NODE_SHELL) do
        image, count = image:gsub(rule[1], rule[2], 1)
        rewritten = rewritten + count
    end
    -- A shell printed in another form would keep part of its `require`.
    if rewritten ~= 0 and rewritten ~= #NODE_SHELL then
        return nil, "browser image has an unrecognized Emscripten Node shell"
    end
    return image .. "\nconst titanCreate = (() => {\n" .. loader ..
        "\nreturn create;\n})();\n" ..
        "export default function create(options = {}) {\n" ..
        "  const locateFile = options.locateFile ?? ((name, prefix) => {\n" ..
        "    if (name.endsWith('.wasm.trace')) return new URL(" .. trace .. ", import.meta.url).href;\n" ..
        "    if (name.endsWith('.wasm')) return new URL(" .. wasm .. ", import.meta.url).href;\n" ..
        "    return prefix + name;\n  });\n" ..
        "  return titanCreate(" .. factory .. ", {...options, locateFile}, {identity: \"" .. identity ..
        "\", wasm: " .. wasm .. "});\n}\n"
end

-- emcc's configured Node, as `em-config NODE_JS` prints it: a Python list of
-- the executable and its arguments, each quoted with either quote style.
local function node_argv(listing)
    local body = listing:match("^%s*%[(.*)%]%s*$")
    if not body then return nil end
    local argv, pos = {}, 1
    while true do
        local quote, index = body:match("^%s*(['\"])()", pos)
        if not quote then break end
        local value = {}
        while body:sub(index, index) ~= quote do
            local char = body:sub(index, index)
            if char == "\\" then
                index = index + 1
                char = body:sub(index, index)
                if not char:match("^[\\'\"]$") then return nil end
            elseif char == "" then
                return nil
            end
            value[#value + 1] = char
            index = index + 1
        end
        argv[#argv + 1] = table.concat(value)
        pos = select(2, body:find("^%s*,?", index + 1)) + 1
    end
    if #argv == 0 or body:find("%S", pos) then return nil end
    return argv
end

-- Runs the SDK's module check over a module file under emcc's configured
-- Node, with the acorn parser of emcc's installation, once per link.
-- Implementation notes: doc/implementation/browser-target.md#the-module-check
function M.check_module(context, tools, checker, module)
    local function setting(name)
        local em_config = platform.windows and "em-config.exe" or "em-config"
        local result = context.io:run({ path.join(tools.location, em_config), name },
            { stderr_to_stdout = true })
        local output = type(result) == "table" and (result.output or result.diagnostic) or tostring(result)
        -- Python prints the value last, after any configuration warning.
        local value = type(result) == "table" and result.ok and output:match("([^\r\n]*)\r?\n?$")
        if value and value ~= "" then return value end
        return nil, "cannot read emcc's " .. name .. " setting: " .. output
    end
    local listing, err = setting("NODE_JS")
    if not listing then return nil, err end
    local root
    root, err = setting("EMSCRIPTEN_ROOT")
    if not root then return nil, err end
    local argv = node_argv(listing)
    if not argv then return nil, "cannot read emcc's NODE_JS setting: " .. listing end
    argv[#argv + 1] = checker
    argv[#argv + 1] = path.join(root, "node_modules/acorn/dist/acorn.mjs")
    argv[#argv + 1] = module
    local result = context.io:run(argv, { stderr_to_stdout = true })
    if type(result) == "table" and result.ok then return true end
    local output = type(result) == "table" and (result.output or result.diagnostic) or tostring(result)
    if type(result) == "table" and result.status == 2 then return nil, (output:gsub("%s+$", "")) end
    return nil, "browser image module check did not run: " .. output
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
