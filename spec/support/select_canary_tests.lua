#!/usr/bin/env lua

-- Read `busted --list` output on stdin and write a deterministic canary
-- manifest on stdout. The input files must be the same explicit spec-file
-- arguments passed to Busted.

local canary = require "spec.support.canary"

local function usage()
    return [[usage: select_canary_tests.lua [--percent 5] [--seed SEED] SPEC...

Reads `busted --list SPEC...` output from stdin. If --seed is omitted,
GITHUB_SHA is used. Selection is reproducible and rounded up independently in
each input spec file, so every nonempty file contributes at least one test.]]
end

local function parse_args(arguments)
    local percent = 5
    local seed
    local files = {}
    local index = 1
    while index <= #arguments do
        local argument = arguments[index]
        if argument == "--help" or argument == "-h" then
            return nil, "help"
        elseif argument == "--" then
            for rest = index + 1, #arguments do
                table.insert(files, arguments[rest])
            end
            break
        elseif argument == "--percent" or argument == "--seed" then
            index = index + 1
            if index > #arguments then
                error("missing value for " .. argument, 0)
            end
            if argument == "--percent" then
                percent = arguments[index]
            else
                seed = arguments[index]
            end
        elseif argument:match("^%-%-percent=") then
            percent = argument:match("^%-%-percent=(.*)$")
        elseif argument:match("^%-%-seed=") then
            seed = argument:match("^%-%-seed=(.*)$")
        elseif argument:sub(1, 1) == "-" then
            error("unknown option: " .. argument, 0)
        else
            table.insert(files, argument)
        end
        index = index + 1
    end
    return {
        percent = percent,
        seed = seed or os.getenv("GITHUB_SHA"),
        files = files,
    }
end

local ok, options, reason = pcall(parse_args, arg)
if not ok then
    io.stderr:write("select_canary_tests: " .. options .. "\n")
    io.stderr:write(usage() .. "\n")
    os.exit(2)
end
if reason == "help" then
    io.write(usage() .. "\n")
    os.exit(0)
end

ok, reason = pcall(function()
    local parsed = canary.parse_busted_list(io.lines(), options.files)
    local selection = canary.select(parsed, options.percent, options.seed)
    io.write(canary.render_manifest(selection))
end)
if not ok then
    io.stderr:write("select_canary_tests: " .. reason .. "\n")
    os.exit(2)
end
