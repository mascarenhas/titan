local cdriver = require "c-parser.cdriver"
local jobs = require "titan-compiler.jobs"
local process = require "titan-compiler.process"
local M = {}

local function same(left, right)
    if #left ~= #right then return false end
    for index, value in ipairs(left) do if value ~= right[index] then return false end end
    return true
end
local function shell_words(command)
    command = command:gsub("%s+2>&1$", "")
    local quote, escaped
    for index = 1, #command do
        local char = command:sub(index, index)
        if escaped then escaped = false
        elseif char == "\\" and quote ~= "'" then escaped = true
        elseif quote then
            if char == quote then quote = nil
            elseif quote == '"' and (char == "$" or char == "`") then
                error("browser process audit rejected shell expansion", 0)
            end
        elseif char == "'" or char == '"' then quote = char
        elseif char:find("[;&|<>()`$\n\r]") then
            error("browser process audit rejected shell control", 0)
        end
    end
    return assert(cdriver.split_shell_words(command))
end
local function render(argv)
    local words = {}
    for index, value in ipairs(argv) do words[index] = assert(cdriver.shell_quote(value)) end
    return table.concat(words, " ")
end

function M.install(options)
    local restore, shells, workers, batches = {}, {}, {}, {}
    local function patch(owner, key, replacement)
        local original = owner[key]
        restore[#restore + 1] = function() owner[key] = original end
        owner[key] = replacement(original)
    end
    local function normalize(argv)
        if type(argv) == "string" then
            if shells[argv] then return shells[argv] end
            argv = shell_words(argv)
        end
        if (argv[1] == "/bin/sh" or argv[1] == "sh") and argv[2] == "-c" then
            assert(#argv == 3, "browser process audit rejected shell argv")
            return normalize(argv[3])
        end
        if argv[1] == "sh.exe" and options.runner and
                argv[2] == options.runner:gsub("\\", "/") then
            return { options.runner, table.unpack(argv, 3) }
        end
        if argv[1] == "env" or argv[1] == "/usr/bin/env" then
            local index = 2
            while argv[index] and argv[index]:match("^[A-Za-z_][A-Za-z_0-9]*=") do index = index + 1 end
            return normalize({ table.unpack(argv, index) })
        end
        return argv
    end
    local function audit(argv, worker)
        if options.active and not options.active() then return nil end
        argv = normalize(argv)
        local operation, tool
        if worker or workers[argv[#argv]] then
            local expected = options.worker_argv and options.worker_argv()
            if expected and same(argv, expected) then operation, tool = "frontend", "compiler-worker"
            elseif workers[argv[#argv]] and same(argv, workers[argv[#argv]]) then
                operation, tool = "frontend", "compiler-worker"
            end
        else
            if options.runner and argv[1] == options.runner and
                (#argv == 2 and argv[2] == "--probe" or
                 #argv == 4 and argv[2] == "--engine" and argv[3] == "node" and argv[4]:match("[.]mjs$")) then
                operation, tool = "execute", "browser-runner"
            end
            -- The module check reads two emcc settings, then runs emcc's Node
            -- with emcc's acorn over the staged module.
            local emcc = options.tools.cc and options.tools.cc[#options.tools.cc]
            local em_config = emcc and emcc:gsub("emcc%.exe$", "em-config.exe"):gsub("emcc$", "em-config")
            if emcc and #argv == 2 and argv[1]:gsub("\\", "/") == em_config:gsub("\\", "/") and
                (argv[2] == "NODE_JS" or argv[2] == "EMSCRIPTEN_ROOT") then
                operation, tool = "query", "em-config"
            end
            if options.module_check and #argv >= 4 and argv[#argv - 2] == options.module_check and
                argv[#argv - 1]:gsub("\\", "/"):match("/node_modules/acorn/dist/acorn[.]mjs$") and
                argv[#argv]:match("[.]mjs$") then
                operation, tool = "check", "module-check"
            end
            for _, entry in ipairs({ { "cc", "emcc" }, { "ar", "emar" }, { "ranlib", "emranlib" } }) do
                local prefix = options.tools[entry[1]]
                local matches = prefix and #argv >= #prefix
                for index, value in ipairs(prefix or {}) do
                    if argv[index] ~= value then matches = false end
                end
                if matches then
                    tool = entry[2]
                    local args = { table.unpack(argv, #prefix + 1) }
                    if entry[1] == "cc" and #args == 1 and
                            (args[1]:match("^@.+[.]mjs[.]rsp$") or
                             args[1]:match("^@.+[.]mjs[.]link[.]rsp[.]tmp[.][^/\\]+$")) then
                        -- The compiler's GNU quoting only escapes backslashes
                        -- and double quotes, both supported by split_shell_words.
                        local file = assert(io.open(args[1]:sub(2), "rb"))
                        local bytes = assert(file:read("a"))
                        assert(file:close())
                        args = assert(cdriver.split_shell_words(bytes))
                    end
                    if #args == 1 and args[1] == "--version" then operation = "query"
                    elseif entry[1] == "cc" then
                        for index, flag in ipairs(args) do
                            if flag == "-c" then operation = "compile"
                            elseif flag == "-E" or flag == "-fsyntax-only" then operation = "preprocess" end
                            if options.images and flag == "-o" and args[index + 1] and args[index + 1]:match("[.]mjs$") then
                                operation = "link"
                            end
                        end
                    elseif entry[1] == "ar" and (args[1] == "qDc" or args[1] == "qc") and #args >= 2 then
                        operation = "archive"
                    elseif entry[1] == "ranlib" and
                        (#args == 1 and args[1]:sub(1, 1) ~= "-" or #args == 2 and args[1] == "-D") then
                        operation = "archive"
                    end
                    break
                end
            end
        end
        if options.record then options.record(tool or tostring(argv[1]), operation or "rejected", argv) end
        if not operation then error("browser process audit rejected operation: " .. render(argv), 0) end
        return argv, tool, operation
    end
    local function wrap(original, completed, argv, ...)
        local normalized, tool = audit(argv)
        local results = table.pack(original(argv, ...))
        if completed and options.after and normalized then options.after(normalized, tool) end
        return table.unpack(results, 1, results.n)
    end
    patch(os, "execute", function(original)
        return function(...) return wrap(original, true, ...) end
    end)
    patch(io, "popen", function(original)
        return function(...) return wrap(original, false, ...) end
    end)
    for _, field in ipairs({ "start", "run", "capture", "start_job" }) do
        patch(process, field, function(original)
            local completed = field == "run" or field == "capture"
            return function(...) return wrap(original, completed, ...) end
        end)
    end
    patch(process, "start_worker", function(original)
        return function(argv, ...)
            audit(argv, true)
            if options.worker_prefix then
                argv = { table.unpack(argv) }
                argv[#argv] = options.worker_prefix .. argv[#argv]
                workers[argv[#argv]] = argv
            end
            return original(argv, ...)
        end
    end)
    patch(process, "new_batch", function(original)
        return function(...)
            local batch = original(...)
            local spawn = batch.spawn
            batches[#batches + 1] = { batch, spawn }
            batch.spawn = function(self, argv, ...)
                audit(argv)
                return spawn(self, argv, ...)
            end
            return batch
        end
    end)
    patch(jobs, "launch", function(original)
        return function(channel, argv, command, stdout, stderr, index, ...)
            local normalized = audit(argv)
            if normalized and not channel.remote then
                assert(command == render(argv), "browser process audit rejected job command/argv disagreement")
                local redirection = stderr == stdout and "2>&1" or "2>" .. assert(cdriver.shell_quote(stderr))
                local transport = "(trap : INT TERM HUP; (trap : INT TERM HUP; " .. command .. ") >" ..
                    assert(cdriver.shell_quote(stdout)) .. " " .. redirection ..
                    "; _titan_compile_status=$?; printf '%s\\n' " .. assert(cdriver.shell_quote(tostring(index))) ..
                    "; exit $_titan_compile_status) 1<>" .. channel.quoted_path
                shells[transport] = normalized
            end
            return original(channel, argv, command, stdout, stderr, index, ...)
        end
    end)
    local uv = process.library()
    patch(uv, "spawn", function(original)
        return function(executable, settings, ...)
            audit({ executable, table.unpack(settings.args or {}) })
            return original(executable, settings, ...)
        end
    end)
    return {
        check = audit,
        restore = function()
            for _, saved in ipairs(batches) do saved[1].spawn = saved[2] end
            for index = #restore, 1, -1 do restore[index]() end
        end,
    }
end
return M
