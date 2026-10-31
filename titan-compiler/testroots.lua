-- Automatic test-root discovery for `titanc --test --test-dir`.
--
-- Discovery is a filesystem inventory: it lists the requested directories,
-- asks the ordinary tagged source resolver which module a candidate name
-- selects, and returns the ordered logical roots with those selected source
-- descriptors. It never reads source bytes, checks, generates, or publishes
-- anything, so a warm build pays only for listings and resolution.
--
-- Target variants (`foo_test.<label>.titan`) name the root `foo_test` when the
-- label applies to the selected target; the resolver, not the spelling that
-- found it, decides which file runs. A variant for another target is skipped
-- silently, and a reserved variant spelling is diagnosed like the folder sweep
-- diagnoses it.
--
-- Implementation notes: doc/implementation/test-runner.md#automatic-test-root-discovery

local path = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local staticmetadata = require "titan-compiler.staticmetadata"
local util = require "titan-compiler.util"

local testroots = {}

local ROOT_NAMES = { test = true, tests = true, spec = true, specs = true }

local function is_root_name(component)
    return ROOT_NAMES[component] == true or component:match("_tests?$") ~= nil or
        component:match("_specs?$") ~= nil
end

local function is_component(name)
    return type(name) == "string" and not name:find(".", 1, true) and
        staticmetadata.valid_module_name(name)
end

-- The logical component an immediate `*.titan` entry contributes, or nil when
-- the entry is not a root candidate. A variant contributes its base name only
-- when its label applies to the target; a reserved spelling is a diagnostic.
-- Other dotted stems keep no meaning here.
local function source_candidate(driver, target, name)
    local logical, label, err = driver.classify_source_filename(name)
    if err then return nil, err end
    if not logical then return nil end
    local stem = logical:sub(1, -7)
    if logical ~= name then
        if not is_component(stem) then return nil end
        if not driver.target_label_applies(target, label) then return nil end
        return stem
    end
    if is_component(stem) then return stem end
    return nil
end

-- The spelling before one trailing `.<word>` label. Discovery uses it only to
-- decide whether a symbolic link could name a root without following every
-- unrelated link; the driver owns the actual grammar.
local function spelled_stem(name)
    local stem = name:sub(1, -7)
    return stem:match("^(.*)%.%a+$") or stem
end

local function append_path(directory, name)
    return platform.join(directory, name)
end

local function normalized(value)
    return path.normalize(value)
end

local function folded(value)
    if platform.windows then return value:lower() end
    return value
end

local function same_path(left, right)
    if type(left) ~= "string" or type(right) ~= "string" then return false end
    return folded(normalized(left)) == folded(normalized(right))
end

-- Return whether `value` is `directory` or lies inside it, plus the lexical
-- remainder. Both spellings are normalized lexically; no filesystem access.
local function relative_within(value, directory)
    if type(value) ~= "string" or type(directory) ~= "string" then
        return false
    end
    local candidate, prefix = normalized(value), normalized(directory)
    if folded(candidate) == folded(prefix) then return true, "" end
    local separator = path.separator
    local boundary = prefix:sub(-1) == separator and prefix or
        prefix .. separator
    if folded(candidate:sub(1, #boundary)) ~= folded(boundary) then
        return false
    end
    return true, candidate:sub(#boundary + 1)
end

local function components_of(relative)
    local components = {}
    if relative == "" then return components end
    local separator = path.separator
    local pattern = separator == "\\" and "[^\\]+" or "[^/]+"
    for component in relative:gmatch(pattern) do
        components[#components + 1] = component
    end
    return components
end

local function push_component(components, name)
    local result = {}
    for index, component in ipairs(components) do result[index] = component end
    result[#result + 1] = name
    return result
end

local function join_components(components, name)
    if #components == 0 then return name end
    return table.concat(components, ".") .. "." .. name
end

-- `io`'s normalized stat omits LuaFileSystem's message for a missing path.
local function describe_error(err)
    if err == nil or err == "" then return "path does not exist" end
    return tostring(err)
end

-- A discovery candidate is identified by its logical name and the source the
-- ordinary resolver selects for it, never by the spelling that found it. Two
-- overlapping areas, or a repeated directory, therefore describe one module.
local function same_source_descriptor(left, right)
    if left.kind ~= right.kind then return false end
    if not same_path(left.main, right.main) then return false end
    local left_files, right_files = left.files or {}, right.files or {}
    if #left_files ~= #right_files then return false end
    for index = 1, #left_files do
        if not same_path(left_files[index], right_files[index]) then
            return false
        end
    end
    return true
end

-- The ordinary tagged resolver and its configured source root list. The driver
-- owns both; loading it lazily keeps `require "titan-compiler.testroots"`
-- usable from driver.lua itself. The variant helpers belong to the same
-- owner, so discovery never keeps a second copy of the spelling rule.
local function resolver_access(source_path)
    local loaded, driver = pcall(require, "titan-compiler.driver")
    if not loaded or type(driver) ~= "table" then
        error("test-root discovery requires the Titan driver: " ..
            tostring(driver), 3)
    end
    local resolve = driver.resolve_source
    if type(resolve) ~= "function" then
        error("test-root discovery requires " ..
            "driver.resolve_source(context, modname, source_path?)", 3)
    end
    for _, name in ipairs({ "classify_source_filename", "context_target",
            "target_label_applies" }) do
        if type(driver[name]) ~= "function" then
            error("test-root discovery requires driver." .. name, 3)
        end
    end
    local roots_text = source_path
    if roots_text == nil then roots_text = driver.TITAN_SOURCE_PATH end
    if type(roots_text) ~= "string" then roots_text = nil end
    return driver, resolve, roots_text
end

-- Discover automatic test roots.
--
-- `context` supplies `io` (list/stat/lstat/realpath/yield) and the selected
-- source target; a bare context detects the host once. `dirs` is the
-- ordered `--test-dir` list; each directory must lie inside a configured
-- `--tree` source root. `excludes` holds exact logical module names that are
-- removed from the automatic selection only. `explicit_roots` keeps positional
-- command-line order and wins over an exclusion. `source_path` overrides the
-- driver's `;`-separated source roots.
--
-- Returns the ordered logical roots (explicit first, then bytewise-sorted
-- automatic roots) and a map from logical name to the selected source
-- descriptor, or `nil, message` for a discovery or I/O error.
function testroots.discover(context, dirs, excludes, explicit_roots,
        source_path)
    if type(context) ~= "table" or not context.io then
        error("testroots.discover requires an I/O context", 2)
    end
    if type(dirs) ~= "table" or #dirs == 0 then
        return nil, "test-root discovery requires at least one " ..
            "--test-dir directory"
    end

    local driver, resolve, roots_text = resolver_access(source_path)
    -- The caller's platform initialization has already selected the target;
    -- the accessor returns it without repeating host detection.
    local target, target_err = driver.context_target(context)
    if not target then
        return nil, "cannot determine the source selection target: " ..
            tostring(target_err)
    end
    local configured = {}
    if roots_text then
        for root in roots_text:gmatch("[^;]+") do
            configured[#configured + 1] = root
        end
    end
    local cwd, cwd_err = context.io:cwd()
    if not cwd then return nil, "cannot locate test directories: " .. tostring(cwd_err) end
    local function absolute(value)
        return normalized(path.is_absolute(value) and value or append_path(cwd, value))
    end
    local source_roots = {}
    for _, spelling in ipairs(configured) do
        context.io:yield()
        source_roots[#source_roots + 1] = {
            spelling = spelling,
            absolute = absolute(spelling),
            physical = context.io:realpath(spelling),
        }
    end

    local excluded = {}
    for _, name in ipairs(excludes or {}) do
        if type(name) ~= "string" or
           not staticmetadata.valid_module_name(name) then
            return nil, "invalid --test-exclude module name '" ..
                tostring(name) .. "'"
        end
        excluded[name] = true
    end

    local roots, explicit = {}, {}
    for _, name in ipairs(explicit_roots or {}) do
        if not staticmetadata.valid_module_name(name) then
            return nil, "invalid logical Titan module name " ..
                string.format("%q", tostring(name))
        end
        if type(name) == "string" and not explicit[name] then
            explicit[name] = true
            roots[#roots + 1] = name
        end
    end

    -- Preserve the first containing tree's namespace, including an explicitly
    -- supplied directory symlink. Physical containment also accepts another
    -- spelling of the configured source root.
    local areas, area_keys = {}, {}
    for _, dir in ipairs(dirs) do
        if type(dir) ~= "string" or dir == "" or dir:find("\0", 1, true) then
            return nil, "invalid --test-dir directory path"
        end
        local attributes, attribute_err = context.io:stat(dir)
        if not attributes then
            return nil, "cannot resolve test directory '" .. dir .. "': " ..
                tostring(attribute_err or "path does not exist")
        end
        if attributes.kind ~= "directory" then
            return nil, "test directory '" .. dir .. "' is not a directory"
        end
        local physical, real_err = context.io:realpath(dir)
        if not physical then
            return nil, "cannot resolve test directory '" .. dir .. "': " ..
                tostring(real_err)
        end
        local matched
        for _, root in ipairs(source_roots) do
            local contained, relative = relative_within(absolute(dir), root.absolute)
            if not contained and root.physical then
                contained, relative = relative_within(physical, root.physical)
            end
            if contained then
                matched = { spelling = root.spelling, relative = relative }
                break
            end
        end
        if not matched then
            return nil, "--test-dir '" .. dir ..
                "' is outside every --tree source root"
        end
        local base, components = matched.spelling, {}
        for _, component in ipairs(components_of(matched.relative)) do
            base = append_path(base, component)
            components[#components + 1] = component
        end
        local key = folded(normalized(base))
        if not area_keys[key] then
            area_keys[key] = true
            areas[#areas + 1] = {
                base = base, components = components, source_root = matched.spelling,
            }
        end
    end

    local candidates = {}

    local function inside_discovery_area(value)
        for _, area in ipairs(areas) do
            if relative_within(value, area.base) then return true end
        end
        return false
    end

    local function consider(logical, physical, kind, source_root)
        local last = logical:match("[^.]+$")
        if not last or not is_root_name(last) then return true end
        if not staticmetadata.valid_module_name(logical) then return true end

        context.io:yield(logical)
        if excluded[logical] and not explicit[logical] then return true end
        local local_source, local_err = resolve(context, logical, source_root)
        if local_err then return nil, local_err end
        if not local_source then
            if kind == "directory" then return true end
            return nil, "cannot resolve test module '" .. logical .. "' at '" ..
                physical .. "': source disappeared during discovery"
        end
        -- Immediate folder contributors are not independent roots.
        if local_source.kind == "blocked" then return true end
        if kind == "directory" and
           (local_source.kind ~= "folder" or
            not same_path(path.dirname(local_source.main), physical)) then
            return true
        end

        local source, resolve_err = resolve(context, logical, roots_text)
        if not source then
            return nil, "cannot resolve test module '" .. logical .. "': " ..
                tostring(resolve_err or "source disappeared during discovery")
        end
        if source.kind == "blocked" then
            return nil, "test module '" .. logical .. "' at '" .. local_source.main ..
                "' is shadowed by folder module '" .. source.owner ..
                "' at '" .. source.main ..
                "'; reorder --tree roots or narrow --test-dir"
        end
        if type(source.main) ~= "string" then
            return nil, "cannot resolve test module '" .. logical ..
                "': the source resolver returned no main source"
        end
        -- The ordinary resolver, never the enumeration spelling, decides the
        -- selected source. A root must be reachable inside a selected
        -- discovery area; when an earlier source root wins instead, running it
        -- would execute another subtree's tests.
        if not inside_discovery_area(source.main) then
            return nil, "test module '" .. logical .. "' at '" .. local_source.main ..
                "' is shadowed by '" .. source.main ..
                "'; reorder --tree roots or narrow --test-dir"
        end

        local existing = candidates[logical]
        if existing then
            if same_source_descriptor(existing, source) then return true end
            -- One logical name cannot select two sources; never silently run
            -- another subtree's tests.
            return nil, "ambiguous test module '" .. logical .. "': '" ..
                existing.main .. "' and '" .. source.main ..
                "'; reorder --tree roots or narrow --test-dir"
        end
        candidates[logical] = source
        return true
    end

    local function walk(directory, components, source_root)
        local entries, list_err = context.io:list(directory)
        if not entries then
            return nil, "cannot enumerate test directory '" .. directory ..
                "': " .. tostring(list_err)
        end
        table.sort(entries, util.bytewise_less)
        for _, name in ipairs(entries) do
            context.io:yield(directory)
            local physical = append_path(directory, name)
            local attributes, attribute_err = context.io:lstat(physical)
            if not attributes then
                return nil, "cannot inspect '" .. physical .. "': " ..
                    tostring(attribute_err)
            end
            local kind = attributes.kind
            local linked = kind == "symlink"
            local candidate, shaped
            if kind ~= "directory" and name:sub(1, 1) ~= "." and
               name:sub(-6) == ".titan" then
                shaped = is_root_name(name) or is_root_name(spelled_stem(name))
                -- A regular file is always classified: an unreadable reserved
                -- spelling is diagnosed wherever the inventory sees it, while a
                -- link is followed only when it could name a root.
                if kind == "file" or shaped then
                    local candidate_err
                    candidate, candidate_err = source_candidate(
                        driver, target, name)
                    if candidate_err then
                        return nil, "invalid test source '" .. physical ..
                            "': " .. candidate_err
                    end
                end
            end
            if linked and name:sub(1, 1) ~= "." and
               (is_root_name(name) or shaped or candidate) then
                local target_attributes, target_err = context.io:stat(physical)
                if not target_attributes then
                    return nil, "cannot inspect symbolic link '" .. physical ..
                        "': " .. describe_error(target_err)
                end
                kind = target_attributes.kind
            end
            if kind == "directory" then
                if name:sub(1, 1) ~= "." and is_component(name) then
                    local ok, err = consider(
                        join_components(components, name), physical, "directory", source_root)
                    if not ok then return nil, err end
                    -- A directory symlink is one module candidate at most; its
                    -- subtree is not traversed, which keeps cycles impossible.
                    if not linked then
                        ok, err = walk(physical,
                            push_component(components, name), source_root)
                        if not ok then return nil, err end
                    end
                end
            elseif kind == "file" and candidate then
                local ok, err = consider(
                    join_components(components, candidate), physical, "file", source_root)
                if not ok then return nil, err end
            end
        end
        context.io:yield(directory)
        return true
    end

    for _, area in ipairs(areas) do
        if #area.components > 0 then
            local ok, err = consider(table.concat(area.components, "."),
                area.base, "directory", area.source_root)
            if not ok then return nil, err end
        end
        local ok, err = walk(area.base, area.components, area.source_root)
        if not ok then return nil, err end
    end

    local automatic = {}
    for logical in pairs(candidates) do
        if not explicit[logical] and not excluded[logical] then
            automatic[#automatic + 1] = logical
        end
    end
    table.sort(automatic, util.bytewise_less)
    for _, logical in ipairs(automatic) do
        roots[#roots + 1] = logical
    end
    if #roots == 0 then return nil, "no test modules found" end

    local sources = {}
    for _, logical in ipairs(roots) do
        local source = candidates[logical]
        if source then sources[logical] = source end
    end
    return roots, sources
end

return testroots
