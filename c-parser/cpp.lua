
local cpp = {}

local typed = require("c-parser.typed")
local c99 = require("c-parser.c99")

local SEP = package.config:sub(1,1)

local shl, shr
if jit then
    shl = function(a, b)
        return bit.lshift(a, b)
    end
    shr = function(a, b)
        return bit.rshift(a, b)
    end
else
    shl, shr = load([[
        local function shl(a, b)
            return a << b
        end
        local function shr(a, b)
            return a >> b
        end
        return shl, shr
    ]])()
end

local function debug() end
--[[
local inspect = require("inspect")
local function debug(...)
    local args = { ... }
    for i, arg in ipairs(args) do
        if type(arg) == "table" then
            args[i] = inspect(arg)
        end
    end
    print(table.unpack(args))
end

local function is_sequence(xs)
   if type(xs) ~= "table" then
      return false
   end
   local l = #xs
   for k, _ in pairs(xs) do
      if type(k) ~= "number" or k < 1 or k > l or math.floor(k) ~= k then
         return false
      end
   end
   return true
end
--]]

-- The real C compiler is the authority for both include search and predefined
-- macros. Keep all shell handling here: callers pass parsed flag arrays, while
-- CC may be either an argv array or the conventional shell-word string.

function cpp.split_shell_words(input)
    if type(input) ~= "string" then
        return nil, "shell words must be a string"
    end
    if input:find("\0", 1, true) then
        return nil, "shell words contain a NUL byte"
    end

    local words = {}
    local word = {}
    local started = false
    local mode = "plain"
    local i = 1
    while i <= #input do
        local ch = input:sub(i, i)
        if mode == "plain" then
            if ch:match("%s") then
                if started then
                    table.insert(words, table.concat(word))
                    word = {}
                    started = false
                end
            elseif ch == "'" then
                mode = "single"
                started = true
            elseif ch == '"' then
                mode = "double"
                started = true
            elseif ch == "\\" then
                i = i + 1
                if i > #input then
                    return nil, "trailing backslash in shell words"
                end
                table.insert(word, input:sub(i, i))
                started = true
            else
                table.insert(word, ch)
                started = true
            end
        elseif mode == "single" then
            if ch == "'" then
                mode = "plain"
            else
                table.insert(word, ch)
            end
        else
            if ch == '"' then
                mode = "plain"
            elseif ch == "\\" then
                local nextch = input:sub(i + 1, i + 1)
                if nextch == "" then
                    return nil, "trailing backslash in double-quoted shell word"
                end
                if nextch == "$" or nextch == "`" or nextch == '"'
                or nextch == "\\" or nextch == "\n" then
                    i = i + 1
                    if nextch ~= "\n" then
                        table.insert(word, nextch)
                    end
                else
                    table.insert(word, ch)
                end
            else
                table.insert(word, ch)
            end
        end
        i = i + 1
    end

    if mode == "single" then
        return nil, "unterminated single quote in shell words"
    elseif mode == "double" then
        return nil, "unterminated double quote in shell words"
    end
    if started then
        table.insert(words, table.concat(word))
    end
    return words
end

function cpp.shell_quote(word)
    if type(word) ~= "string" then
        return nil, "shell argument must be a string"
    end
    if word:find("\0", 1, true) then
        return nil, "shell argument contains a NUL byte"
    end
    return "'" .. word:gsub("'", "'\\''") .. "'"
end

local function copy_map(t)
    local u = {}
    for k, v in pairs(t) do
        u[k] = v
    end
    return u
end

local function copy_incdirs(incdirs)
    local copy = { quote = {}, system = {} }
    for _, mode in ipairs({ "quote", "system" }) do
        for _, dir in ipairs(incdirs[mode] or {}) do
            table.insert(copy[mode], dir)
        end
    end
    return copy
end

local function normalize_argv(value, name, string_is_shell_words)
    if value == nil then
        return {}
    end
    if type(value) == "string" then
        if not string_is_shell_words then
            return nil, name .. " must be a parsed argument array"
        end
        local argv, err = cpp.split_shell_words(value)
        if not argv then
            return nil, "invalid " .. name .. ": " .. err
        end
        value = argv
    end
    if type(value) ~= "table" then
        return nil, name .. " must be an argument array"
    end

    local argv = {}
    for i = 1, #value do
        local arg = value[i]
        if type(arg) ~= "string" then
            return nil, name .. " argument " .. i .. " must be a string"
        end
        if arg:find("\0", 1, true) then
            return nil, name .. " argument " .. i .. " contains a NUL byte"
        end
        argv[i] = arg
    end
    for k in pairs(value) do
        if type(k) ~= "number" or k < 1 or k > #value
        or k % 1 ~= 0 then
            return nil, name .. " must be a dense argument array"
        end
    end
    return argv
end

local function normalize_toolchain(options)
    options = options or {}
    if type(options) ~= "table" then
        return nil, "preprocessor options must be a table"
    end

    local compiler, err = normalize_argv(
        options.compiler or os.getenv("CC") or "cc", "compiler", true)
    if not compiler then
        return nil, err
    elseif #compiler == 0 then
        return nil, "compiler command is empty"
    end

    local cppflags
    cppflags, err = normalize_argv(options.cppflags, "cppflags", false)
    if not cppflags then
        return nil, err
    end

    local fixed_include_dirs
    fixed_include_dirs, err = normalize_argv(
        options.fixed_include_dirs, "fixed include dirs", false)
    if not fixed_include_dirs then
        return nil, err
    end

    local language_mode = options.language_mode or "c99"
    if type(language_mode) ~= "string"
    or not language_mode:match("^[%w%+_.-]+$") then
        return nil, "invalid C language mode"
    end

    return {
        compiler = compiler,
        language_mode = language_mode,
        cppflags = cppflags,
        fixed_include_dirs = fixed_include_dirs,
    }
end

local function append_argv(dst, src)
    for _, arg in ipairs(src) do
        table.insert(dst, arg)
    end
end

local function shell_command(argv)
    local quoted = {}
    for i, arg in ipairs(argv) do
        local q, err = cpp.shell_quote(arg)
        if not q then
            return nil, err
        end
        quoted[i] = q
    end
    return table.concat(quoted, " ")
end

local function run_command(argv, stderr_to_stdout)
    local command, err = shell_command(argv)
    if not command then
        return nil, err
    end
    command = "env LANG=C LC_ALL=C " .. command
    if stderr_to_stdout then
        command = command .. " 2>&1"
    end
    local pipe
    pipe, err = io.popen(command, "r")
    if not pipe then
        return nil, err
    end
    local output = pipe:read("*a")
    local ok, why, status = pipe:close()
    if not ok then
        return nil, ("command failed (%s %s): %s"):format(
            tostring(why), tostring(status), output)
    end
    return output
end

local function config_argv(config)
    local argv = {}
    append_argv(argv, config.compiler)
    append_argv(argv, config.cppflags)
    -- Match generated/runtime compilation: user CPP flags precede Titan's
    -- fixed language/default flags, so the fixed C99 mode wins if a caller
    -- accidentally supplies another -std option in the CPP channel.
    table.insert(argv, "-std=" .. config.language_mode)
    for _, dir in ipairs(config.fixed_include_dirs) do
        append_argv(argv, { "-I", dir })
    end
    return argv
end

local function key_argv(argv)
    local parts = {}
    for _, arg in ipairs(argv) do
        table.insert(parts, #arg .. ":" .. arg)
    end
    return table.concat(parts, "|")
end

local probe_cache = {}

local function probe_include_paths(config)
    local argv = config_argv(config)
    append_argv(argv, { "-E", "-v", "-x", "c", "/dev/null", "-o", "/dev/null" })
    local output, err = run_command(argv, true)
    if not output then
        return nil, "failed probing C include search: " .. err
    end

    local paths = { quote = {}, system = {} }
    local mode
    for line in (output .. "\n"):gmatch("(.-)\n") do
        if line:find([[#include "..." search starts here]], 1, true) then
            mode = "quote"
        elseif line:find([[#include <...> search starts here]], 1, true) then
            mode = "system"
        elseif line:find([[End of search list]], 1, true) then
            mode = nil
        elseif mode then
            local path = line:gsub("^%s+", "")
                :gsub("%s+%(framework directory%)$", "")
            if path ~= "" then
                table.insert(paths[mode], path)
            end
        end
    end
    return paths
end

local function probe_default_defines(config)
    local argv = config_argv(config)
    append_argv(argv, { "-dM", "-E", "-x", "c", "/dev/null" })
    local output, err = run_command(argv, false)
    if not output then
        return nil, "failed probing predefined C macros: " .. err
    end

    local fd
    fd, err = io.tmpfile()
    if not fd then
        return nil, "failed creating temporary macro probe file: " .. err
    end
    fd:write(output)
    fd:seek("set", 0)
    local blank_ctx = {
        incdirs = {},
        defines = {},
        ifmode = { true },
        output = {},
        current_dir = {},
    }
    typed.set_type(blank_ctx, "Ctx")
    local ctx
    ctx, err = cpp.parse_file("-", fd, blank_ctx)
    if not ctx then
        return nil, "failed parsing predefined C macros: " .. err
    end

    ctx.defines["__builtin_va_list"] = { "char", "*" }
    ctx.defines["__extension__"] = {}
    ctx.defines["__attribute__"] = { args = { "arg" }, repl = {} }
    ctx.defines["__restrict__"] = { "restrict" }
    ctx.defines["__restrict"] = { "restrict" }
    ctx.defines["__inline__"] = { "inline" }
    ctx.defines["__inline"] = { "inline" }
    return ctx.defines
end

function cpp.new_context(options)
    local config, err = normalize_toolchain(options)
    if not config then
        return nil, err
    end

    local key = key_argv(config_argv(config))
    local probed = probe_cache[key]
    if not probed then
        local incdirs
        incdirs, err = probe_include_paths(config)
        if not incdirs then
            return nil, err
        end
        local defines
        defines, err = probe_default_defines(config)
        if not defines then
            return nil, err
        end
        probed = { incdirs = incdirs, defines = defines }
        probe_cache[key] = probed
    end

    local ctx = {
        incdirs = copy_incdirs(probed.incdirs),
        defines = copy_map(probed.defines),
        ifmode = { true },
        output = {},
        current_dir = {},
    }
    typed.set_type(ctx, "Ctx")
    return ctx
end

-- Test and embedding hook: cached probe results are otherwise process-lifetime.
function cpp.clear_probe_cache()
    probe_cache = {}
end

-- Not supported:
-- * character set conversion
-- * trigraphs

local states = {
    any = {
        ['"'] = { next = "dquote" },
        ["'"] = { next = "squote" },
        ["/"] = { silent = true, next = "slash" },
    },
    dquote = {
        ['"'] = { next = "any" },
        ["\\"] = { next = "dquote_backslash" },
    },
    dquote_backslash = {
        single_char = true,
        default = { next = "dquote" },
    },
    squote = {
        ["'"] = { next = "any" },
        ["\\"] = { next = "squote_backslash" },
    },
    squote_backslash = {
        single_char = true,
        default = { next = "squote" },
    },
    slash = {
        single_char = true,
        ["/"] = { add = " ", silent = true, next = "line_comment" },
        ["*"] = { add = " ", silent = true, next = "block_comment" },
        default = { add = "/", next = "any" },
    },
    line_comment = {
        silent = true,
    },
    block_comment = {
        silent = true,
        ["*"] = { silent = true, next = "try_end_block_comment" },
        continue_line = "block_comment",
    },
    try_end_block_comment = {
        single_char = true,
        silent = true,
        ["/"] = { silent = true, next = "any" },
        ["*"] = { silent = true, next = "try_end_block_comment" },
        default = { silent = true, next = "block_comment" },
        continue_line = "block_comment",
    },
}

for _, rules in pairs(states) do
    local out = "["
    for k, _ in pairs(rules) do
        if #k == 1 then
            out = out .. k
        end
    end
    out = out .. "]"
    rules.pattern = out ~= "[]" and out
end

local function add(buf, txt)
    if not buf then
        buf = {}
    end
    table.insert(buf, txt)
    return buf
end

cpp.initial_processing = typed("FILE* -> LineList", function(fd)
    local backslash_buf
    local buf
    local state = "any"
    local output = {}
    local linenr = 0

    -- Run the comment/string state machine over one complete logical line
    -- (backslash-continuations already merged) and append the result to
    -- `output`. `buf` and `state` persist across calls so a block comment can
    -- span several logical lines (states[state].continue_line).
    local function flush_logical_line(line, nr)
        local len = #line
        local i = 1
        local out = ""
        -- Go through the line
        while i <= len do
            -- Current state in the state machine
            local st = states[state]

            -- Look for next character matching a state transition
            local n = nil
            if st.pattern then
                if st.single_char then
                    if line:sub(i,i):find(st.pattern) then
                        n = i
                    end
                else
                    n = line:find(st.pattern, i)
                end
            end

            local transition, ch
            if n then
                ch = line:sub(n, n)
                transition = st[ch]
            else
                n = i
                ch = line:sub(n, n)
                transition = st.default
            end

            if not transition then
                -- output the rest of the string if we should
                if not st.silent then
                    out = i == 1 and line or line:sub(i)
                end
                break
            end

            -- output everything up to the transition if we should
            if n > i and not st.silent then
                buf = add(buf, line:sub(i, n - 1))
            end

            -- Some transitions output an explicit character
            if transition.add then
                buf = add(buf, transition.add)
            end

            if not transition.silent then
                buf = add(buf, ch)
            end

            -- and move to the next state
            state = transition.next
            i = n + 1
        end

        -- A '/' at the very end of a logical line was consumed into the 'slash'
        -- lookahead but never emitted; it cannot begin a comment (the next char
        -- is on a different logical line), so it is a division operator. Emit it
        -- rather than dropping it.
        if state == "slash" then
            out = out .. "/"
            state = "any"
        end

        -- If we ended in a non-line-terminating state
        if states[state].continue_line then
            -- buffer the output and keep going
            buf = add(buf, out)
            state = states[state].continue_line
        else
            -- otherwise, flush the buffer
            if buf then
                table.insert(buf, out)
                out = table.concat(buf)
                buf = nil
            end
            -- output the string and reset the state.
            table.insert(output, { nr = nr, line = out})
            state = "any"
        end
    end

    for input_line in fd:lines() do
        -- for-loop control variables are read-only in Lua 5.5
        local line = input_line
        linenr = linenr + 1
        -- Normalize CRLF: a physical line read in binary mode keeps its trailing
        -- '\r', which would both hide a backslash-continuation (the '\' is no
        -- longer the last character) and leak a stray '\r' into the tokens.
        if line:sub(-1) == "\r" then
            line = line:sub(1, -2)
        end
        local len = #line
        if line:find("\\", len, true) then
            -- If backslash-terminated, buffer it
            backslash_buf = add(backslash_buf, line:sub(1, len - 1))
        else
            -- Merge backslash-terminated line
            if backslash_buf then
                table.insert(backslash_buf, line)
                line = table.concat(backslash_buf)
            end
            backslash_buf = nil
            flush_logical_line(line, linenr)
        end
    end

    -- EOF housekeeping so trailing code is never silently dropped: a file ending
    -- with a backslash-continuation leaves text in backslash_buf, and a file
    -- ending inside a block comment (or any continue_line state) leaves text in
    -- buf. Flush both.
    if backslash_buf then
        flush_logical_line(table.concat(backslash_buf), linenr)
    end
    if buf then
        table.insert(output, { nr = linenr, line = table.concat(buf) })
        buf = nil
    end

    fd:close()
    typed.set_type(output, "LineList")
    return output
end)

cpp.tokenize = typed("string -> table", function(line)
    return c99.match_preprocessing_grammar(line)
end)

local function find_file(ctx, filename, mode, is_next)
    local paths = {}
    local current_dir = ctx.current_dir[#ctx.current_dir]
    if mode == "quote" or is_next then
        if not is_next then
            table.insert(paths, current_dir)
        end
        for _, incdir in ipairs(ctx.incdirs.quote or {}) do
            table.insert(paths, incdir)
        end
    end
    if mode == "system" or is_next then
        for _, incdir in ipairs(ctx.incdirs.system or {}) do
            table.insert(paths, incdir)
        end
    end
    if is_next then
        while paths[1] and paths[1] ~= current_dir do
            table.remove(paths, 1)
        end
        table.remove(paths, 1)
    end
    for _, path in ipairs(paths) do
        local pathname = path..SEP..filename
        local fd = io.open(pathname, "r")
        if fd then
            return pathname, fd
        end
    end
    return nil, nil, "file not found"
end

local parse_expression = typed("{string} -> Exp?", function(tokens)
    local text = table.concat(tokens, " ")
    local exp, err, _, _, fragment = c99.match_preprocessing_expression_grammar(text)
    if not exp then
        print("Error parsing expression: " .. tostring(err) .. ": " .. text .. " AT " .. fragment)
    end
    return exp
end)

local eval_exp
eval_exp = typed("Ctx, Exp -> number", function(ctx, exp)
    debug(exp)

    if not exp.op then
        local val = exp[1]
        typed.check(val, "string")
        local defined = ctx.defines[val]
        if defined then
            assert(type(defined) == "table")
            local subexp = parse_expression(defined)
            if not subexp then
                return 0 -- FIXME
            end
            return eval_exp(ctx, subexp)
        end
        val = val:gsub("U*L*$", "")
        if val:match("^0[xX]") then
            return tonumber(val) or 0
        elseif val:sub(1,1) == "0" then
            return tonumber(val, 8) or 0
        else
            return tonumber(val) or 0
        end
    elseif exp.op == "+"  then
        if exp[2] then
            return eval_exp(ctx, exp[1]) + eval_exp(ctx, exp[2])
        else
            return eval_exp(ctx, exp[1])
        end
    elseif exp.op == "-"  then
        if exp[2] then
            return eval_exp(ctx, exp[1]) - eval_exp(ctx, exp[2])
        else
            return -(eval_exp(ctx, exp[1]))
        end
    elseif exp.op == "*"  then return eval_exp(ctx, exp[1]) * eval_exp(ctx, exp[2])
    elseif exp.op == "/"  then return eval_exp(ctx, exp[1]) / eval_exp(ctx, exp[2])
    elseif exp.op == ">>" then return shr(eval_exp(ctx, exp[1]), eval_exp(ctx, exp[2])) -- FIXME C semantics
    elseif exp.op == "<<" then return shl(eval_exp(ctx, exp[1]), eval_exp(ctx, exp[2])) -- FIXME C semantics
    elseif exp.op == "==" then return (eval_exp(ctx, exp[1]) == eval_exp(ctx, exp[2])) and 1 or 0
    elseif exp.op == "!=" then return (eval_exp(ctx, exp[1]) ~= eval_exp(ctx, exp[2])) and 1 or 0
    elseif exp.op == ">=" then return (eval_exp(ctx, exp[1]) >= eval_exp(ctx, exp[2])) and 1 or 0
    elseif exp.op == "<=" then return (eval_exp(ctx, exp[1]) <= eval_exp(ctx, exp[2])) and 1 or 0
    elseif exp.op == ">"  then return (eval_exp(ctx, exp[1]) > eval_exp(ctx, exp[2])) and 1 or 0
    elseif exp.op == "<"  then return (eval_exp(ctx, exp[1]) < eval_exp(ctx, exp[2])) and 1 or 0
    elseif exp.op == "!"  then return (eval_exp(ctx, exp[1]) == 1) and 0 or 1
    elseif exp.op == "&&" then
        for _, e in ipairs(exp) do
            if eval_exp(ctx, e) == 0 then
                return 0
            end
        end
        return 1
    elseif exp.op == "||" then
        for _, e in ipairs(exp) do
            if eval_exp(ctx, e) ~= 0 then
                return 1
            end
        end
        return 0
    elseif exp.op == "?" then
        if eval_exp(ctx, exp[1]) ~= 0 then
            return eval_exp(ctx, exp[2])
        else
            return eval_exp(ctx, exp[3])
        end
    elseif exp.op == "defined" then
        return (ctx.defines[exp[1][1]] ~= nil) and 1 or 0
    else
        error("unimplemented operator " .. tostring(exp.op))
    end
end)

local consume_parentheses = typed("{string}, number, LineList, number -> {{string}}, number", function(tokens, start, linelist, cur)
    local args = {}
    local i = start + 1
    local arg = {}
    local stack = 0
    while true do
        local token = tokens[i]
        if token == nil then
            repeat
                cur = cur + 1
                if not linelist[cur] then
                    error("unterminated function-like macro")
                end
                local nextline = linelist[cur].tk
                linelist[cur].tk = {}
                table.move(nextline, 1, #nextline, i, tokens)
                token = tokens[i]
            until token
        end
        if token == "(" then
            stack = stack + 1
            table.insert(arg, token)
        elseif token == ")" then
            if stack == 0 then
                if #arg > 0 then
                    table.insert(args, arg)
                end
                break
            end
            stack = stack - 1
            table.insert(arg, token)
        elseif token == "," then
            if stack == 0 then
                table.insert(args, arg)
                arg = {}
            else
                table.insert(arg, token)
            end
        else
            table.insert(arg, token)
        end
        i = i + 1
    end
    return args, i
end)

local function array_copy(t)
    local t2 = {}
    for i,v in ipairs(t) do
        t2[i] = v
    end
    return t2
end

local function table_remove(list, pos, n)
    table.move(list, pos + n, #list + n, pos)
end

local function table_replace_n_with(list, at, n, values)
    local old = #list
    debug("TRNW?", list, "AT", at, "N", n, "VALUES", values)
    --assert(is_sequence(list))
    local nvalues = #values
    local nils = n >= nvalues and (n - nvalues + 1) or 0
    if n ~= nvalues then
        table.move(list, at + n, #list + nils, at + nvalues)
    end
    debug("....", list)
    table.move(values, 1, nvalues, at, list)
    --assert(is_sequence(list))
    debug("TRNW!", list)
    assert(#list == old - n + #values)
end

local stringify = typed("{string} -> string", function(tokens)
    return '"'..table.concat(tokens, " "):gsub("\"", "\\")..'"'
end)

local macro_expand

local mark_noloop = typed("table, string, number -> ()", function(noloop, token, n)
    noloop[token] = math.max(noloop[token] or 0, n)
end)

-- Shift recorded "blue paint" positions by `n` after the token stream changed
-- length at position `from`. Only entries at or past `from` move; entries before
-- it are already behind the cursor (their paint has expired -- see valid_noloop)
-- and must NOT be bumped forward, or a subsequent, unrelated use of the same
-- macro would be wrongly suppressed. This happens with glibc's <math.h>, where
-- __CONCAT is reused across sibling expansions of __MATHCALL_VEC: painting it
-- once (via __SIMD_DECL) used to block the later __CONCAT(name,) in the actual
-- declaration, dropping the function name.
local shift_noloop = typed("table, number, number -> ()", function(noloop, n, from)
    for token, v in pairs(noloop) do
        if v >= from then
            noloop[token] = v + n
        end
    end
end)

local valid_noloop = typed("table, string, number -> boolean", function(noloop, token, n)
    return noloop[token] == nil or noloop[token] < n
end)

local replace_args = typed("Ctx, {string}, table, LineList, number -> ()", function(ctx, tokens, args, linelist, cur)
    local i = 1
    local hash_next = false
    local join_next = false
    while true do
        local token = tokens[i]
        if not token then
            break
        end
        if token == "#" then
            hash_next = true
            table.remove(tokens, i)
        elseif token == "##" then
            join_next = true
            table.remove(tokens, i)
        elseif args[token] then
            macro_expand(ctx, args[token], linelist, cur, false)
            if hash_next then
                tokens[i] = stringify(args[token])
                hash_next = false
            elseif join_next then
                tokens[i - 1] = tokens[i - 1] .. table.concat(args[token], " ")
                table.remove(tokens, i)
                join_next = false
            else
                table_replace_n_with(tokens, i, 1, args[token])
                debug(token, args[token], tokens)
                i = i + #args[token]
            end
        elseif join_next then
            tokens[i - 1] = tokens[i - 1] .. tokens[i]
            table.remove(tokens, i)
            join_next = false
        else
            hash_next = false
            join_next = false
            i = i + 1
        end
    end
end)

macro_expand = typed("Ctx, {string}, LineList, number, boolean -> ()", function(ctx, tokens, linelist, cur, expr_mode)
    local i = 1
    -- TODO propagate noloop into replace_args. recurse into macro_expand storing a proper offset internally.
    local noloop = {}
    while true do
        ::continue::
        debug(i, tokens)
        local token = tokens[i]
        if not token then
            break
        end
        if expr_mode then
            if token == "defined" then
                if tokens[i + 1] == "(" then
                    i = i + 2
                end
                i = i + 2
                goto continue
            end
        end
        local define = ctx.defines[token]
        if define and valid_noloop(noloop, token, i) then
            debug(token, define)
            local repl = define.repl
            if define.args then
                if tokens[i + 1] == "(" then
                    local args, j = consume_parentheses(tokens, i + 1, linelist, cur)
                    debug("args:", #args, args)
                    local named_args = {}
                    for i = 1, #define.args do
                        named_args[define.args[i]] = args[i] or {}
                    end
                    local expansion = array_copy(repl)
                    replace_args(ctx, expansion, named_args, linelist, cur)
                    local nexpansion = #expansion
                    local n = j - i + 1
                    if nexpansion == 0 then
                        table_remove(tokens, i, n)
                    else
                        table_replace_n_with(tokens, i, n, expansion)
                    end
                    shift_noloop(noloop, nexpansion - n, i)
                    mark_noloop(noloop, token, i + nexpansion - 1)
                else
                    i = i + 1
                end
            else
                local ndefine = #define
                if ndefine == 0 then
                    table.remove(tokens, i)
                    shift_noloop(noloop, -1, i)
                elseif ndefine == 1 then
                    tokens[i] = define[1]
                    mark_noloop(noloop, token, i)
                    noloop[token] = math.max(noloop[token] or 0, i)
                else
                    table_replace_n_with(tokens, i, 1, define)
                    mark_noloop(noloop, token, i + ndefine - 1)
                end
            end
        else
            i = i + 1
        end
    end
end)

local run_expression = typed("Ctx, {string} -> boolean", function(ctx, tks)
    local exp = parse_expression(tks)
    return eval_exp(ctx, exp) ~= 0
end)

cpp.parse_file = typed("string, FILE*?, Ctx? -> Ctx?, string?", function(filename, fd, ctx)
    if not ctx then
        local err
        ctx, err = cpp.new_context()
        if not ctx then
            return nil, err
        end
        -- if not absolute path
        if not filename:match("^/") then
            local found_name, found_fd = find_file(ctx, filename, "system")
            if found_fd then
                filename, fd = found_name, found_fd
            end
        end
    end

    local current_dir = filename:gsub("/[^/]*$", "")
    if current_dir == filename then
        current_dir = "."
        local found_name, found_fd = find_file(ctx, filename, "system")
        if found_fd then
            filename, fd = found_name, found_fd
        end
    end
    table.insert(ctx.current_dir, current_dir)

    local err
    if not fd then
        fd, err = io.open(filename, "rb")
        if not fd then
            table.remove(ctx.current_dir)
            return nil, err
        end
    end
    local linelist = cpp.initial_processing(fd)

    for _, lineitem in ipairs(linelist) do
        lineitem.tk = cpp.tokenize(lineitem.line)
    end

    -- ifmode is a tri-state stack: true (emitting), false (skipping this
    -- branch), or "skip" (a previous branch already matched).
    ---@type (boolean|string)[]
    local ifmode = ctx.ifmode
    for cur, lineitem in ipairs(linelist) do
        local line = lineitem.line
        local tk = lineitem.tk
        debug(filename, cur, ifmode[#ifmode], #ifmode, line)

        if #ifmode == 1 and (tk.directive == "elif" or tk.directive == "else" or tk.directive == "endif") then
            table.remove(ctx.current_dir)
            return nil, "unexpected directive " .. tk.directive
        end

        if tk.exp then
            macro_expand(ctx, tk.exp, linelist, cur, true)
        end

        if ifmode[#ifmode] == true then
            if tk.directive then
                debug(tk)
            end
            if tk.directive == "define" then
                local k = tk.id
                local v = tk.args and tk or tk.repl
                ctx.defines[k] = v
            elseif tk.directive == "undef" then
                ctx.defines[tk.id] = nil
            elseif tk.directive == "ifdef" then
                table.insert(ifmode, (ctx.defines[tk.id] ~= nil))
            elseif tk.directive == "ifndef" then
                table.insert(ifmode, (ctx.defines[tk.id] == nil))
            elseif tk.directive == "if" then
                table.insert(ifmode, run_expression(ctx, tk.exp))
            elseif tk.directive == "elif" then
                ifmode[#ifmode] = "skip"
            elseif tk.directive == "else" then
                ifmode[#ifmode] = not ifmode[#ifmode]
            elseif tk.directive == "endif" then
                table.remove(ifmode, #ifmode)
            elseif tk.directive == "error" or tk.directive == "pragma" then
                -- ignore
            elseif tk.directive == "include" or tk.directive == "include_next" then
                local name = tk.exp[1]
                local mode = tk.exp.mode
                local is_next = (tk.directive == "include_next")
                local inc_filename, inc_fd, err = find_file(ctx, name, mode, is_next)
                if not inc_filename then
                    -- fall back to trying to load an #include "..." as #include <...>;
                    -- this is necessary for Mac system headers
                    inc_filename, inc_fd, err = find_file(ctx, name, "system", is_next)
                end
                if not inc_filename then
                    table.remove(ctx.current_dir)
                    return nil, name..":"..err
                end
                local ok, include_err = cpp.parse_file(inc_filename, inc_fd, ctx)
                if not ok then
                    table.remove(ctx.current_dir)
                    return nil, name .. ":" .. include_err
                end
            else
                macro_expand(ctx, tk, linelist, cur, false)
                table.insert(ctx.output, table.concat(tk, " "))
            end
        elseif ifmode[#ifmode] == false then
            if tk.directive == "ifdef"
            or tk.directive == "ifndef"
            or tk.directive == "if" then
                table.insert(ifmode, "skip")
            elseif tk.directive == "else" then
                ifmode[#ifmode] = not ifmode[#ifmode]
            elseif tk.directive == "elif" then
                ifmode[#ifmode] = run_expression(ctx, tk.exp)
            elseif tk.directive == "endif" then
                table.remove(ifmode, #ifmode)
            end
        elseif ifmode[#ifmode] == "skip" then
            if tk.directive == "ifdef"
            or tk.directive == "ifndef"
            or tk.directive == "if" then
                table.insert(ifmode, "skip")
            elseif tk.directive == "else"
                or tk.directive == "elif" then
                -- do nothing
            elseif tk.directive == "endif" then
                table.remove(ifmode, #ifmode)
            end
        end
    end

    table.remove(ctx.current_dir)

    return ctx, nil
end)

cpp.expand_macro = typed("string, table -> string", function(macro, define_set)
    local ctx = typed.table("Ctx", setmetatable({
        defines = define_set,
    }, { __index = error, __newindex = error }))
    local tokens = { macro }
    local linelist = typed.table("LineList", { { nr = 1, line = macro } })
    macro_expand(ctx, tokens, linelist, 1, false)
    return table.concat(tokens, " ")
end)

return cpp
