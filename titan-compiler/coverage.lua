-- Opt-in coverage build ownership. Normal compilation never calls this module.
local lfs = require "lfs"
local path = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local sha256 = require "titan-compiler.sha256"
local util = require "titan-compiler.util"
local staticmetadata = require "titan-compiler.staticmetadata"

local coverage = {}

local function absolute(filename)
    return path.normalize(path.is_absolute(filename) and filename or
        path.join(lfs.currentdir(), filename))
end

local function mkdir(filename)
    if lfs.attributes(filename, "mode") == "directory" then return true end
    local parent = path.dirname(filename)
    if parent ~= filename then
        local ok, err = mkdir(parent)
        if not ok then return nil, err end
    end
    return lfs.mkdir(filename)
end

local function hash_file(filename)
    local contents, err = util.get_file_contents(filename)
    if not contents then return nil, err end
    return sha256.hex(contents)
end

-- A deliberately small JSON writer for the compiler's own plain manifest.
-- The report tool owns schema validation and reading external JSON.
local function json(value)
    if type(value) == "string" then
        return '"' .. value:gsub('[%z\1-\31\\"]', function(byte)
            if byte == '"' then return '\\"' end
            if byte == '\\' then return '\\\\' end
            return string.format('\\u%04x', byte:byte())
        end) .. '"'
    elseif type(value) == "number" or type(value) == "boolean" then
        return tostring(value)
    end
    assert(type(value) == "table", "invalid coverage manifest value")
    local entries = {}
    if #value > 0 or next(value) == nil then
        for _, item in ipairs(value) do entries[#entries + 1] = json(item) end
        return '[' .. table.concat(entries, ',') .. ']'
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        entries[#entries + 1] = json(key) .. ':' .. json(value[key])
    end
    return '{' .. table.concat(entries, ',') .. '}'
end
coverage.json = json

local function compiler_identity(frontend)
    local driver_file = assert(package.searchpath("titan-compiler.driver", package.path))
    local compiler_dir = path.dirname(absolute(driver_file))
    local files = {}
    local function visit(directory)
        for entry in lfs.dir(directory) do
            if entry ~= "." and entry ~= ".." then
                local filename = path.join(directory, entry)
                if lfs.attributes(filename, "mode") == "directory" then
                    visit(filename)
                elseif entry:match("[.]lua$") then files[#files + 1] = filename end
            end
        end
    end
    visit(compiler_dir)
    local parser_dir = path.join(path.dirname(compiler_dir), "c-parser")
    if lfs.attributes(parser_dir, "mode") == "directory" then visit(parser_dir) end
    files[#files + 1] = frontend
    table.sort(files)
    local hashes = {}
    for _, filename in ipairs(files) do
        hashes[#hashes + 1] = filename .. "\0" .. assert(hash_file(filename))
    end
    return sha256.hex(table.concat(hashes, "\n"))
end

function coverage.prepare(driver, args, strategy)
    if not driver.EMIT_LINE_DIRECTIVES then
        return nil, "Titan source coverage requires source #line directives"
    end
    if args.print_ast then return nil, "--coverage cannot be combined with --print-ast" end
    if platform.windows then
        return nil, "native Titan coverage backend gcc-gcov is unsupported by the Windows CLANG64 SDK"
    end
    local selected, names = {}, {}
    for _, name in ipairs(args.coverage_module or {}) do
        if not staticmetadata.valid_module_name(name) then
            return nil, "invalid --coverage-module name " .. string.format("%q", name)
        end
        if name == "titan.test" or name == "titan.test.runner" then
            return nil, "test support cannot be a coverage module: " .. name
        end
        if not selected[name] then selected[name] = true; names[#names + 1] = name end
    end
    if #names == 0 then return nil, "--coverage requires an explicit --coverage-module production inventory" end
    table.sort(names)
    local mappings = {}
    for _, mapping in ipairs(args.coverage_source_map or {}) do
        local from, to = mapping:match("^([^=]+)=(.+)$")
        if not from then return nil, "--coverage-source-map requires STAGED_DIRECTORY=TRACKED_DIRECTORY" end
        local resolved, resolution_error = strategy:realpath(absolute(from))
        if not resolved then return nil, resolution_error end
        mappings[#mappings + 1] = { from = resolved, to = absolute(to) }
    end
    table.sort(mappings, function(a, b) return #a.from > #b.from end)
    local gcov = args.coverage_gcov or platform.getenv("GCOV") or "gcov"
    local gcov_argv, parse_err = driver.split_shell_words(gcov)
    if not gcov_argv then return nil, parse_err end
    local cc_argv, cc_err = driver.split_shell_words(driver.CC)
    if not cc_argv then return nil, cc_err end
    local function run(command, suffix)
        local argv = { table.unpack(command) }
        for _, arg in ipairs(suffix) do argv[#argv + 1] = arg end
        local result = strategy:run(argv)
        if not result.ok then return nil, result.output or result.diagnostic end
        return result.output
    end
    local cc_version, cc_version_err = run(cc_argv, { "-dumpfullversion" })
    if not cc_version then return nil, "coverage requires GCC 14 or newer: " .. tostring(cc_version_err) end
    cc_version = cc_version:match("^%s*(%d+%.%d+%.?%d*)")
    local cc_banner = run(cc_argv, { "--version" })
    if not cc_version or tonumber(cc_version:match("^%d+")) < 14 or
       not cc_banner or cc_banner:lower():find("clang", 1, true) then
        return nil, "coverage requires GCC 14 or newer; Clang is not a supported backend"
    end
    local gcov_version, gcov_err = run(gcov_argv, { "--version" })
    if not gcov_version or not gcov_version:match("gcov") or
       not gcov_version:find(cc_version, 1, true) then
        return nil, "coverage requires gcov matching GCC " .. cc_version .. ": " .. tostring(gcov_err or gcov_version)
    end
    local frontend = absolute(args._coverage_frontend or "titanc")
    local tool = path.join(path.dirname(frontend), "titan-coverage")
    local probe = strategy:run({ "python3", tool, "probe", "--cc", driver.CC, "--gcov", gcov })
    if not probe.ok then
        return nil, "native coverage capability probe failed: " .. tostring(probe.output or probe.diagnostic)
    end
    local directory = absolute(args.coverage)
    local source_directories = { absolute(".") }
    for tree in (args.tree or "."):gmatch("[^;]+") do
        source_directories[#source_directories + 1] = absolute(tree)
    end
    local output_identity
    if lfs.attributes(directory, "mode") == "directory" then
        local identity_error
        output_identity, identity_error = strategy:realpath(directory)
        if not output_identity then return nil, identity_error end
    end
    for _, source_directory in ipairs(source_directories) do
        local source_identity
        if output_identity and lfs.attributes(source_directory, "mode") == "directory" then
            local identity_error
            source_identity, identity_error = strategy:realpath(source_directory)
            if not source_identity then return nil, identity_error end
        end
        if directory == source_directory or
           output_identity and output_identity == source_identity then
            return nil, "coverage output must be a separate build directory"
        end
    end
    local ok, err = mkdir(directory)
    if not ok then return nil, err end
    local compile_prefix, flags_err = driver.generated_compile_prefix()
    if not compile_prefix then return nil, flags_err end
    for _, flag in ipairs(compile_prefix) do
        if flag == "--coverage" or flag:match("^%-fprofile") or
           flag == "-ftest-coverage" then
            return nil, "coverage flags must be owned by --coverage, not ambient compiler flags"
        end
    end
    local root = absolute(args.coverage_root or ".")
    local root_identity, root_error = strategy:realpath(root)
    if not root_identity then return nil, root_error end
    local settings = {
        metric = "titan-executable-lines", line_mapping = "titan-coverage-markers-v1",
        modules = names, compile_prefix = compile_prefix,
        link_flags = driver.EXTRA_LDFLAGS, compiler_identity = compiler_identity(frontend),
        cc = driver.CC, cc_version = cc_version, gcov = gcov,
        backend_probe = probe.output,
        pretty_print = args.pretty_print == true, test = args.test == true,
        source_tree = args.tree or ".", working_directory = lfs.currentdir(),
        source_mappings = mappings,
        root_identity = root_identity,
    }
    local configuration = json(settings)
    local config_path = path.join(directory, "build.config")
    local old = util.get_file_contents(config_path)
    if old and old ~= configuration then
        return nil, "coverage build configuration changed; use a fresh --coverage directory"
    end
    if not old then
        ok, err = util.set_file_contents(config_path, configuration)
        if not ok then return nil, err end
    end
    return {
        directory = directory, selected = selected, modules = names,
        root = root, root_identity = root_identity, strategy = strategy, settings = settings,
        mappings = mappings,
        sources = {}, source_entries = {}, receipts = {}, source_hashes = {},
    }
end

function coverage.source(build, name, source, forced)
    local stem = path.join(build.directory, "objects", (name:gsub("[.]", "/")))
    source.native_output = stem .. ".titan"
    source.program_output = path.join(build.directory, "bin", (name:gsub("[.]", "/")))
    local hashes = {}
    local source_hashes = {}
    for _, filename in ipairs(source.files) do
        local bytes = source.contents and source.contents[filename] or util.get_file_contents(filename)
        if not bytes then return nil, "cannot read coverage source " .. filename end
        local digest = sha256.hex(bytes)
        hashes[#hashes + 1] = absolute(filename) .. "\0" .. digest
        source_hashes[absolute(filename)] = digest
    end
    local identity = table.concat(hashes, "\n")
    local receipt = path.join(build.directory, "objects", name:gsub("[.]", "/") .. ".coverage-receipt")
    local object_hash = hash_file(stem .. ".o")
    local notes_hash = build.selected[name] and hash_file(stem .. ".gcno") or "uninstrumented"
    local anchors_hash = build.selected[name] and hash_file(stem .. ".coverage-anchors") or "uninstrumented"
    local expected = identity .. "\n" .. tostring(object_hash) .. "\n" .. tostring(notes_hash)
        .. "\n" .. tostring(anchors_hash)
    if not object_hash or not notes_hash or not anchors_hash or util.get_file_contents(receipt) ~= expected then
        forced[name] = true
    end
    build.receipts[name] = { path = receipt, identity = identity, stem = stem }
    build.source_entries[name] = source
    build.source_hashes[name] = source_hashes
    return true
end

function coverage.compile_flags(build, name)
    if not build.selected[name] then return { "-O0", "-fno-lto" } end
    return { "-O0", "-fno-lto", "--coverage", "-fprofile-update=atomic",
        "-fkeep-static-functions", "-dumpbase", path.basename(name:gsub("[.]", "/")) .. ".c",
        "-dumpbase-ext", ".c" }
end

function coverage.write_manifest(build, imported, objects, providers, extra_inputs)
    local sources, inventory, unmeasured = {}, {}, {}
    for _, name in ipairs(build.modules) do
        local mod = imported[name]
        if not mod or mod.kind ~= "source" then
            return nil, "coverage module must be compiled from source: " .. name
        end
        local object = assert(objects[name])
        local anchors, anchors_error = util.get_file_contents(object:gsub("[.]o$", ".coverage-anchors"))
        if not anchors then return nil, anchors_error end
        local source_names = {}
        for _, filename in ipairs(mod.source_files or { mod.filename }) do
            local filename_absolute = absolute(filename)
            local source_hash = build.source_hashes[name][filename_absolute]
            if hash_file(filename_absolute) ~= source_hash then
                return nil, "source changed during coverage build: " .. filename_absolute
            end
            local tracked = filename_absolute
            local source_identity, source_error = build.strategy:realpath(filename_absolute)
            if not source_identity then return nil, source_error end
            for _, mapping in ipairs(build.mappings) do
                if source_identity:sub(1, #mapping.from + 1) == mapping.from .. "/" then
                    tracked = mapping.to .. source_identity:sub(#mapping.from + 1)
                    break
                end
            end
            local tracked_identity, tracked_error = build.strategy:realpath(tracked)
            if not tracked_identity then return nil, tracked_error end
            local relative = tracked_identity:sub(#build.root_identity + 2)
            if tracked_identity:sub(1, #build.root_identity + 1) ~= build.root_identity .. "/" then
                return nil, "coverage source is outside --coverage-root: " .. filename_absolute
            end
            sources[#sources + 1] = { path = filename_absolute, report_path = relative, module = name,
                tracked_path = path.join(build.root, relative),
                sha256 = source_hash,
                allow_empty = not anchors:find(filename .. "\0", 1, true) }
            source_names[#source_names + 1] = relative
        end
        inventory[#inventory + 1] = {
            path = absolute(object), notes = absolute(object:gsub("[.]o$", ".gcno")),
            data = absolute(object:gsub("[.]o$", ".gcda")), sources = source_names,
            expect_data = #providers > 0,
            sha256 = assert(hash_file(object)),
            notes_sha256 = assert(hash_file(object:gsub("[.]o$", ".gcno"))),
        }
    end
    for name, mod in pairs(imported) do
        if mod.kind == "dynamic" or mod.kind == "static" then
            unmeasured[#unmeasured + 1] = { module = name, path = mod.filename or mod.static_archive }
        end
    end
    table.sort(unmeasured, function(a, b) return a.module < b.module end)
    for name, receipt in pairs(build.receipts) do
        local object_hash, err = hash_file(receipt.stem .. ".o")
        if not object_hash then return nil, err end
        local notes_hash = build.selected[name] and hash_file(receipt.stem .. ".gcno") or "uninstrumented"
        if not notes_hash then return nil, "missing coverage notes for " .. name end
        local anchors_hash = build.selected[name] and hash_file(receipt.stem .. ".coverage-anchors") or "uninstrumented"
        if not anchors_hash then return nil, "missing coverage anchors for " .. name end
        local ok, write_err = util.set_file_contents(receipt.path,
            receipt.identity .. "\n" .. object_hash .. "\n" .. notes_hash .. "\n" .. anchors_hash)
        if not ok then return nil, write_err end
    end
    local link_inventory, seen_inputs = {}, {}
    local function linked(filename, role, module)
        local resolved = absolute(filename)
        if seen_inputs[resolved] then return true end
        local hash, hash_error = hash_file(resolved)
        if not hash then return nil, hash_error end
        seen_inputs[resolved] = true
        link_inventory[#link_inventory + 1] = { path = resolved, role = role,
            module = module, sha256 = hash }
        return true
    end
    for name, filename in pairs(objects) do
        local ok, link_error = linked(filename, build.selected[name] and "measured" or "support", name)
        if not ok then return nil, link_error end
    end
    for _, entry in ipairs(unmeasured) do
        if entry.path then
            local ok, link_error = linked(entry.path, "unmeasured-provider", entry.module)
            if not ok then return nil, link_error end
        end
    end
    for _, filename in ipairs(extra_inputs or {}) do
        if filename:sub(1, 1) ~= "-" then
            local ok, link_error = linked(filename, "native-payload")
            if not ok then return nil, link_error end
        end
    end
    table.sort(link_inventory, function(a, b) return a.path < b.path end)
    local manifest = { version = 1, backend = "gcc-gcov", root = build.root,
        sources = sources, objects = inventory, providers = providers,
        unmeasured = unmeasured, link_inventory = link_inventory, settings = build.settings }
    for _, provider in ipairs(providers) do provider.sha256 = assert(hash_file(provider.path)) end
    return util.set_file_contents(path.join(build.directory, "build.json"), json(manifest) .. "\n")
end

return coverage
