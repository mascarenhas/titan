local path = require "titan-compiler.path"
local M = {}

function M.sdk_assets(paths)
    local root = paths.titan_bin
    return {
        runtime = paths.libtitan,
        js_library = path.join(root, "titan-browser-library.js"),
        loader = path.join(root, "titan-browser.mjs"),
        runner = path.join(root, "titan-browser-run"),
        runner_module = path.join(root, "titan-browser-run.mjs"),
        node_worker = path.join(root, "titan-browser-node-worker.mjs"),
        page = path.join(root, "titan-browser-page.mjs"),
        lpeglabel = path.join(root, "libtitan-lpeglabel.a"),
        provider = path.join(root, "titan.a"),
        sdk_digests = paths.sdk_digests,
    }
end

function M.require_sdk(context, descriptor, install)
    local assets = M.sdk_assets(descriptor.paths)
    for _, key in ipairs({ "runtime", "js_library", "loader", "runner",
            "runner_module", "node_worker", "page" }) do
        local filename = assets[key]
        local stat = context.io:stat(filename)
        local readable = stat and stat.kind == "file" and context.io:read_file(filename)
        if not readable then
            local command = "make browser-sdk PREFIX=" .. install.prefix
            if install.rocks_tree then command = command .. " ROCKS_TREE=" .. install.rocks_tree end
            return nil, "browser SDK is incomplete: missing " .. string.format("%q", filename) ..
                "; run '" .. command .. "'"
        end
    end
    return assets
end

local purposes = { program = true, protocol = true, gate = true,
    minicoro = true, budget = true, baseline = true }
local option_keys = { purpose = true, assertions = true, optimization = true,
    asyncify = true, budgets = true, entry = true }
local defaults = { stack_size = 1048576, asyncify_stack_size = 65536,
    initial_memory = 16777216, maximum_memory = 2147483648 }

function M.profile(descriptor, options)
    if type(options) ~= "table" then return nil, "browser link profile options are required" end
    for key in pairs(options) do
        if not option_keys[key] then return nil, "unknown browser link profile option " .. tostring(key) end
    end
    local purpose = options.purpose
    if not purposes[purpose] then return nil, "invalid browser link profile purpose" end
    local assertions = options.assertions
    if assertions ~= 0 and assertions ~= 2 then return nil, "browser assertions must be 0 or 2" end
    local asyncify = options.asyncify
    if asyncify == nil then asyncify = true end
    if type(asyncify) ~= "boolean" or not asyncify and purpose ~= "minicoro" and purpose ~= "baseline" then
        return nil, "this browser link profile requires Asyncify"
    end
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
            local alignment = (key == "initial_memory" or key == "maximum_memory") and 65536 or 16
            if defaults[key] == nil or math.type(value) ~= "integer" or value <= 0 or value % alignment ~= 0 then
                return nil, "invalid browser budget override " .. tostring(key)
            end
            budgets[key] = value
        end
        if budgets.initial_memory > budgets.maximum_memory or budgets.maximum_memory > 2147483648 then
            return nil, "invalid browser memory budgets"
        end
    end
    local flags, compile = {}, {}
    local effective_opt
    if optimization then
        effective_opt = "-" .. optimization
        flags[#flags + 1] = effective_opt
        compile[1] = effective_opt
    else
        for _, flag in ipairs(descriptor.compile_flags) do
            if flag:match("^%-O") then effective_opt = flag end
        end
    end
    local function add(flag) flags[#flags + 1] = flag end
    add("-sASYNCIFY=" .. (asyncify and "1" or "0"))
    add("-sSUPPORT_LONGJMP=" .. descriptor.lua.record.sjlj)
    add("-sSTACK_SIZE=" .. budgets.stack_size)
    if asyncify then add("-sASYNCIFY_STACK_SIZE=" .. budgets.asyncify_stack_size) end
    add("-sINITIAL_MEMORY=" .. budgets.initial_memory)
    add("-sALLOW_MEMORY_GROWTH=1")
    add("-sMAXIMUM_MEMORY=" .. budgets.maximum_memory)
    add("-sABORTING_MALLOC=0")
    add("-sEXIT_RUNTIME=0")
    add("-sINVOKE_RUN=0")
    if entry == "titan" then add("--no-entry") end
    add("-sMODULARIZE=1")
    add("-sEXPORT_ES6=1")
    add("-sENVIRONMENT=web,node")
    local exports = entry == "titan" and '"_titan_browser_entry","_malloc","_free"' or
        '"_main","_malloc","_free"'
    if purpose == "gate" then
        exports = exports .. ',"_titan_browser_gate_guarded","_titan_browser_gate_observe"'
    end
    add("-sEXPORTED_FUNCTIONS=[" .. exports .. "]")
    add('-sEXPORTED_RUNTIME_METHODS=["ccall","HEAPU8"]')
    add('-sINCOMING_MODULE_JS_API=["stdin","stdout","stderr","locateFile","onAbort"]')
    if entry == "titan" then
        add("--js-library")
        add(M.sdk_assets(descriptor.paths).js_library)
    end
    add("-sASSERTIONS=" .. assertions)
    add("-sSTACK_OVERFLOW_CHECK=2")
    return { link_flags = flags, compile_flags = compile,
        identity_inputs = { target_identity = descriptor.identity, purpose = purpose,
            entry = entry, assertions = assertions, optimization = effective_opt,
            asyncify = asyncify, budgets = budgets, link_flags = flags, compile_flags = compile } }
end

-- Target-owned settings cannot be weakened by trailing user flags. Accept
-- unrelated Emscripten settings, but reject every spelling of an owned one.
local owned = { SUPPORT_LONGJMP = true, ASYNCIFY = true, STACK_SIZE = true,
    INITIAL_MEMORY = true, ALLOW_MEMORY_GROWTH = true, MAXIMUM_MEMORY = true,
    ABORTING_MALLOC = true, EXIT_RUNTIME = true, INVOKE_RUN = true,
    MODULARIZE = true, EXPORT_ES6 = true, ENVIRONMENT = true,
    EXPORTED_FUNCTIONS = true, EXPORTED_RUNTIME_METHODS = true,
    INCOMING_MODULE_JS_API = true, ASSERTIONS = true, STACK_OVERFLOW_CHECK = true,
    TITAN_TARGET_BROWSER = true, TITAN_COROUTINE_STACK_SIZE = true,
    MCO_ASYNCFY_STACK_SIZE = true }
function M.validate_extras(flags)
    for index, flag in ipairs(flags or {}) do
        local setting = flag:match("^%-[sD](.+)") or
            (flag == "-s" or flag == "-D") and flags[index + 1]
        local key = setting and setting:match("^([%w_]+)")
        if key and (owned[key] or key:match("^ASYNCIFY_")) or
            flag == "--no-entry" or flag == "--js-library" or flag:match("^%-%-js%-library=") then
            return nil, "browser link profile owns option " .. flag
        end
    end
    return true
end

return M
