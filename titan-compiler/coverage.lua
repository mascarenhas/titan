local source_selection = require "titan-compiler.source_selection"
-- Coverage is an ordinary source build in output-local .coverage directories.
local lfs = require "lfs"
local path = require "titan-compiler.path"
local platform = require "titan-compiler.platform"

local coverage = {}

local function absolute(filename)
    return path.to_slash(path.normalize(path.is_absolute(filename) and filename or
        path.join(lfs.currentdir(), filename)))
end
coverage.absolute = absolute

function coverage.output_path(filename)
    return path.join(path.dirname(filename), ".coverage", path.basename(filename))
end

local function mkdir(directory)
    if lfs.attributes(directory, "mode") == "directory" then return true end
    local parent = path.dirname(directory)
    if parent ~= directory then
        local ok, err = mkdir(parent)
        if not ok then return nil, err end
    end
    return lfs.mkdir(directory)
end

-- Globs match a complete logical module name; * and ? also match dots.
local function glob_pattern(glob)
    if type(glob) ~= "string" or glob == "" or glob:find("[^%w_.*?]") then
        return nil, "invalid --coverage-module glob " .. string.format("%q", tostring(glob)) ..
            "; use logical module names with * and ?"
    end
    local pattern = glob:gsub("[.]", "%%."):gsub("%*", ".*"):gsub("%?", ".")
    return "^" .. pattern .. "$"
end

function coverage.test_functions(ast)
    local names = {}
    for _, node in ipairs(ast) do
        if node._tag == "Ast.TopLevelFunc" and type(node.name) == "string"
            and node.name:match("^test_") then
            names[#names + 1] = node.name
        end
    end
    return names
end

function coverage.matches(build, name, test_functions)
    if test_functions and #test_functions > 0 then return false end
    if name == "titan.test.runner" or build.generated[name] then return false end
    if #build.patterns == 0 then return true end
    for _, pattern in ipairs(build.patterns) do
        if name:match(pattern) then return true end
    end
    return false
end

-- Implementation notes: doc/implementation/native-coverage.md#selection-and-object-ownership
function coverage.prepare(driver, args, strategy)
    if not driver.EMIT_LINE_DIRECTIVES then
        return nil, "Titan source coverage requires source #line directives"
    end
    if args.print_ast then return nil, "--coverage cannot be combined with --print-ast" end
    local backend = args.coverage_backend or (platform.windows and "llvm-gcov" or "gcc-gcov")
    if backend ~= "gcc-gcov" and backend ~= "llvm-gcov" then
        return nil, "unsupported native coverage backend " .. tostring(backend)
    end
    if platform.windows and backend == "gcc-gcov" then
        return nil, "native Titan coverage backend gcc-gcov is unsupported by the Windows CLANG64 SDK"
    end
    local patterns = {}
    for _, glob in ipairs(args.coverage_module or {}) do
        local pattern, err = glob_pattern(glob)
        if not pattern then return nil, err end
        patterns[#patterns + 1] = pattern
    end
    local gcov = args.coverage_gcov or platform.getenv("GCOV") or
        (backend == "llvm-gcov" and "llvm-cov gcov" or "gcov")
    local gcov_argv, err = driver.split_shell_words(gcov)
    if not gcov_argv or #gcov_argv == 0 then return nil, err or "coverage gcov command is empty" end
    local cc_argv, cc_error = driver.split_shell_words(driver.CC)
    if not cc_argv or #cc_argv == 0 then return nil, cc_error or "coverage C compiler command is empty" end
    local function run(command, suffix)
        local argv = { table.unpack(command) }
        for _, argument in ipairs(suffix) do argv[#argv + 1] = argument end
        local result = strategy:run(argv)
        if not result.ok then return nil, result.output or result.diagnostic end
        return result.output
    end
    if backend == "gcc-gcov" then
        local version = run(cc_argv, { "-dumpfullversion" })
        version = version and version:match("^%s*(%d+%.%d+%.?%d*)")
        local banner = run(cc_argv, { "--version" })
        if not version or tonumber(version:match("^%d+")) < 14 or
            not banner or banner:lower():find("clang", 1, true) then
            return nil, "coverage requires GCC 14 or newer; select --coverage-backend llvm-gcov for Clang"
        end
        local gcov_version, gcov_error = run(gcov_argv, { "--version" })
        if not gcov_version or not gcov_version:find(version, 1, true) then
            return nil, "coverage requires gcov matching GCC " .. version .. ": " .. tostring(gcov_error or gcov_version)
        end
    else
        local banner = run(cc_argv, { "--version" })
        local version = banner and banner:match("clang version (%d+%.%d+%.%d+)%f[%D]")
        if not version then return nil, "llvm-gcov coverage requires Clang" end
        local reader = run(gcov_argv, { "--version" })
        if not reader or reader:match("LLVM version (%d+%.%d+%.%d+)%f[%D]") ~= version then
            return nil, "llvm-gcov coverage requires llvm-cov gcov matching LLVM " .. version
        end
    end
    local formats = {}
    for _, format in ipairs(args.coverage_format or {}) do
        if format ~= "html" and format ~= "lcov" and format ~= "cobertura" then
            return nil, "unsupported coverage report format " .. tostring(format)
        end
        formats[#formats + 1] = format
    end
    local gcovr, gcovr_error = driver.split_shell_words(
        args.coverage_gcovr or platform.getenv("GCOVR") or "gcovr")
    if not gcovr or #gcovr == 0 then return nil, gcovr_error or "coverage gcovr command is empty" end
    return {
        selected = {}, modules = {}, patterns = patterns, generated = {}, outputs = {},
        backend = backend, gcov = gcov_argv, gcovr = gcovr,
        root = absolute(args.coverage_root or "."),
        output = absolute(args.coverage_output or
            path.join(args.output or ".", ".coverage", "report")),
        formats = formats, working_directory = absolute("."),
    }
end

function coverage.source(build, name, source)
    if not source._coverage_output then
        local native_output = source_selection.output_stem(
            source.native_output or source.main, name) .. ".titan"
        source.native_output = coverage.output_path(native_output)
        source._coverage_output = true
    end
    build.outputs[name] = source.native_output
    if source.kind == "generated" then build.generated[name] = true end
    return true
end

function coverage.select(build, imported)
    build.selected, build.modules = {}, {}
    for name, mod in pairs(imported) do
        if mod.kind == "source" then
            local tests = mod.ast and coverage.test_functions(mod.ast) or
                mod.object_metadata and mod.object_metadata.coverage_test_functions or mod.test_functions
            if coverage.matches(build, name, tests) then
                build.selected[name] = true
                build.modules[#build.modules + 1] = name
            end
        end
    end
    table.sort(build.modules)
    if #build.modules == 0 then
        return nil, "coverage selection is empty: no matching source modules without test_ functions"
    end
    return true
end

function coverage.compile_flags(build, name)
    if not build.selected[name] then return { "-O0", "-fno-lto" } end
    local flags = { "-O0", "-fno-lto", "--coverage", "-fprofile-update=atomic" }
    if build.backend == "llvm-gcov" then
        flags[#flags + 1] = "-dumpdir"
        flags[#flags + 1] = path.to_slash(path.dirname(absolute(build.outputs[name]))) .. "/"
    else
        flags[#flags + 1] = "-fkeep-static-functions"
        -- The compiler's temporary .o pathname must not rename its notes.
        flags[#flags + 1] = "-dumpbase"
        flags[#flags + 1] = path.basename(source_selection.output_stem(
            assert(build.outputs[name]), name)) .. ".c"
        flags[#flags + 1] = "-dumpbase-ext"
        flags[#flags + 1] = ".c"
    end
    return flags
end

function coverage.partial(parts, source_files, backend)
    local sources = {}
    for _, source in ipairs(source_files) do sources[#sources + 1] = absolute(source) end
    local files, anchors = {}, {}
    for _, part in ipairs(parts) do
        local generated = absolute(part.filename)
        files[#files + 1] = generated
        local mapped = {}
        for source, lines in pairs(part.anchors or {}) do
            local numbers = {}
            for line in pairs(lines) do numbers[#numbers + 1] = line end
            table.sort(numbers)
            mapped[absolute(source)] = numbers
        end
        anchors[generated] = mapped
    end
    return { enabled = true, backend = backend, files = files,
        sources = sources, anchors = anchors }
end

function coverage.inventory(build, imported)
    local files, sources, anchors, seen = {}, {}, {}, {}
    for _, name in ipairs(build.modules) do
        local mod = imported[name]
        local partial = mod.coverage or mod.object_metadata and mod.object_metadata.coverage
        if not partial or not partial.enabled then return nil, "missing coverage object inventory for " .. name end
        for _, filename in ipairs(partial.files) do files[#files + 1] = filename end
        for _, source in ipairs(partial.sources) do
            if not seen[source] then seen[source] = true; sources[#sources + 1] = source end
        end
        for filename, mapping in pairs(partial.anchors) do anchors[filename] = mapping end
    end
    table.sort(files)
    table.sort(sources)
    local made, err = mkdir(build.output)
    if not made then return nil, err end
    return { files = files, sources = sources, anchors = anchors, backend = build.backend,
        gcov = build.gcov, gcovr = build.gcovr, root = build.root, output = build.output, formats = build.formats,
        working_directory = build.working_directory }
end

-- The executable and object records are trusted compiler-owned Lua data.
function coverage.serialize(value)
    if type(value) == "string" then return string.format("%q", value) end
    if type(value) ~= "table" then return tostring(value) end
    local keys, fields = {}, {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(left, right)
        if type(left) ~= type(right) then return type(left) < type(right) end
        return left < right
    end)
    for _, key in ipairs(keys) do
        fields[#fields + 1] = "[" .. coverage.serialize(key) .. "]=" .. coverage.serialize(value[key])
    end
    return "{" .. table.concat(fields, ",") .. "}"
end

return coverage
