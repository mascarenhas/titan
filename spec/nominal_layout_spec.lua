local types = require "titan-compiler.types"
local layout = require "titan-compiler.nominallayout"
local graphcodec = require "titan-compiler.graphcodec"
local coder = require "titan-compiler.coder"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local paths = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local h = require "spec.support.helpers"
local files = require "spec.fixtures.target_selection.support"
local temporary = require "spec.support.temporary"
local lfs = require "lfs"

local function field(name, typ, index, private, isconst, owner)
    local result = types.Field(owner or "sample.Record", name, typ, index, isconst == true)
    result.islocal = private == true
    return result
end

local function record(fields, name)
    return types.Record(name or "sample.Record", fields, {}, {}, #fields)
end

local function cint()
    return types.CInteger("int", true, 3, 32)
end

local function cstruct(name, fields, fam)
    return types.CStruct(nil, name, nil, fields or {}, true, fam == true)
end

local function rejected(fn, fragment)
    local value, err = fn()
    assert.is_nil(value)
    assert.is_string(err)
    assert.truthy(err:find(fragment, 1, true), err)
end

describe("nominal physical layouts", function()
    it("compacts public and private GC slots without changing logical ordinals", function()
        local owner = record({
            field("hidden_number", types.Integer(), 0, true),
            field("title", types.String(), 1),
            field("hidden_child", types.Value(), 2, true),
            field("ready", types.Boolean(), 3),
            field("count", cint(), 4),
        })
        local before = types.serialize(owner)
        local plan = assert(layout.record(owner))
        assert.equal(2, plan.nuv)
        assert.equal(1, plan.npublicuv)
        assert.same({3, 4, 0}, {plan.members[1].index,
            plan.members[2].index, plan.members[3].index})
        assert.equal(0, plan.by_name.title.uv_index)
        assert.equal(1, plan.by_name.hidden_child.uv_index)
        assert.equal("_public.f3", plan.by_index[3].path)
        assert.equal("f0", plan.by_index[0].path)
        assert.is_true(plan.complete)
        assert.is_true(plan.has_private)
        assert.equal(before, types.serialize(owner))
        assert.is_nil(owner.fields[1].uv_index)
    end)

    it("represents all-raw, all-GC, and empty records without fake GC slots", function()
        local raw = assert(layout.record(record({
            field("i", types.Integer(), 0), field("b", types.Boolean(), 1),
            field("f", types.Float(), 2), field("nil_slot", types.Nil(), 3),
        })))
        assert.equal(0, raw.nuv)
        assert.equal(4, #raw.public_members)
        local gc = assert(layout.record(record({
            field("s", types.String(), 0),
            field("a", types.Array(types.Integer(), {tag="no"}), 1),
            field("f", types.Function({}, {}, false, nil, nil), 2),
        })))
        assert.equal(3, gc.nuv)
        assert.equal(0, #gc.members)
        local empty = assert(layout.record(record({})))
        assert.equal(0, empty.nuv)
        assert.equal(0, #empty.members)
    end)

    it("classifies the erased generic carrier rather than a concrete application", function()
        local scope = types.GenericScope("sample", "sample.Record", nil,
            "owner", "record")
        local parameter = types.Parameter(scope, 1, "T", nil)
        local plan = assert(layout.record(record({field("item", parameter, 0)})))
        assert.equal("uv", plan.slots[1].storage)
        assert.equal("Type.Value", plan.slots[1].type._tag)
        assert.equal("Type.Parameter", parameter._tag)
    end)

    it("keeps TValue, Udata pointers, owned values, and optional GC bases traced", function()
        local tvalue = cstruct("TValue")
        local udata = types.CPointer(cstruct("Udata"), {})
        for _, typ in ipairs({tvalue, udata, types.CTypedef("SavedValue", tvalue),
            types.COwned(cint(), false), types.Option(types.String()),
            types.Option(tvalue), types.Option(udata), types.Nominal("sample.Other")}) do
            assert.equal("uv", assert(layout.classify(typ)).storage)
        end
        assert.equal("payload", assert(layout.classify(
            types.CPointer(cstruct("TValue"), {}))).storage)
    end)

    it("retains native unsigned and extended floating types in optional payloads", function()
        local wide = types.CInteger("unsigned long long", false, 5, 64)
        for _, base in ipairs({wide, types.CFloat("long double"), types.Integer(),
            types.Boolean(), types.CPointer(cint(), {})}) do
            local result = assert(layout.classify(types.Option(base)))
            assert.equal("payload", result.storage)
            assert.equal("option", result.kind)
            assert.equal(base, result.base.type)
            assert.equal(base, result.type.base)
        end
    end)

    it("classifies fixed aggregates and typedef arrays while preserving their C declarations", function()
        local point = cstruct("point", {
            types.CField(nil, "x", cint(), nil, false),
            types.CField(nil, "y", cint(), nil, false),
        })
        local alias = types.CTypedef("int_four", types.CArray(cint(), 4))
        assert.equal("aggregate", assert(layout.classify(point)).kind)
        local array = assert(layout.classify(alias))
        assert.equal("array", array.kind)
        assert.equal(alias, array.type)
        local union = types.CUnion(nil, "choice", nil, {
            types.CField(nil, "point", point, nil, false),
            types.CField(nil, "bytes", alias, nil, false),
        }, true)
        assert.equal("aggregate", assert(layout.classify(union)).kind)
    end)

    it("normalizes uncounted array views without discarding C pointee constness", function()
        local view = types.CTypedef("const_view", types.CArray(cint(), nil, {"const"}))
        local result = assert(layout.classify(view))
        assert.equal("scalar", result.kind)
        assert.equal("Type.CPointer", result.type._tag)
        assert.same({"const"}, result.type.quals)
        assert.equal("Type.CArray", view.target._tag)
    end)

    it("rejects incomplete, FAM, and recursively GC-bearing by-value objects", function()
        local incomplete = types.CStruct(nil, "opaque", nil, {}, false, false)
        rejected(function() return layout.classify(incomplete) end, "incomplete")
        assert.equal("scalar", assert(layout.classify(types.CPointer(incomplete, {}))).kind)
        local fam = cstruct("packet", {
            types.CField(nil, "data", types.CArray(cint(), nil), nil, true),
        }, true)
        local nested = types.CUnion(nil, "nested", nil, {
            types.CField(nil, "packet", fam, nil, false),
        }, true)
        rejected(function() return layout.classify(nested) end, "FAM")
        local bearing = cstruct("bearing", {
            types.CField(nil, "values", types.CArray(cstruct("TValue"), 4), nil, false),
        })
        rejected(function() return layout.classify(bearing) end, "GC-bearing")
        rejected(function() return layout.classify(types.CArray(cint(), 0)) end, "extent")
    end)

    it("keeps an empty zero tag and sparse public union tags with one-based parts", function()
        local fqtn = "sample.Message"
        local empty = types.Variant(fqtn, "empty", {}, 0)
        local hidden = types.Variant(fqtn, "hidden", {
            field("private_value", cint(), 1, false, false, fqtn),
        }, 1)
        hidden.islocal = true
        local message = types.Variant(fqtn, "message", {
            field("count", types.Integer(), 1, false, false, fqtn),
            field("text", types.String(), 2, false, false, fqtn),
            field("enabled", types.Option(types.Boolean()), 3, false, false, fqtn),
        }, 2)
        local owner = types.Union(fqtn, {empty, hidden, message}, {}, {}, 3)
        local pempty = assert(layout.variant(owner, empty))
        local phidden = assert(layout.variant(owner, hidden))
        local pmessage = assert(layout.variant(owner, message))
        assert.equal(0, pempty.tag)
        assert.equal(0, pempty.nuv)
        assert.equal(0, pempty.arity)
        assert.equal("header", pmessage.header_member)
        assert.equal("tag", pmessage.tag_member)
        assert.equal(0, pmessage.by_index[2].uv_index)
        assert.equal("p1", pmessage.by_index[1].path)
        assert.is_false(pmessage.by_index[1].isconst)
        assert.is_nil(layout.public(phidden))
        local decoded = assert(layout.decode(assert(layout.encode("sample",
            {pempty, phidden, pmessage})), "sample"))
        assert.equal(0, decoded.variants[fqtn][0].arity)
        assert.is_nil(decoded.variants[fqtn][1])
        assert.equal(3, decoded.variants[fqtn][2].arity)
    end)

    it("publishes only the public prefix and UV map of a record with private C members", function()
        local hidden = cstruct("secret_native_type", {
            types.CField(nil, "native", cint(), nil, false),
        })
        local plan = assert(layout.record(record({
            field("secret_field", hidden, 0, true),
            field("public_count", cint(), 1),
            field("private_root", types.Value(), 2, true),
            field("public_text", types.String(), 3),
        })))
        local bytes = assert(layout.encode("sample", {[plan.name] = plan}))
        assert.is_nil(bytes:find("secret_native_type", 1, true))
        assert.is_nil(bytes:find("secret_field", 1, true))
        assert.is_nil(bytes:find("private_root", 1, true))
        local public = assert(layout.decode(bytes, "sample")).records[plan.name]
        assert.is_false(public.complete)
        assert.is_true(public.has_private)
        assert.equal(4, public.nfields)
        assert.equal(1, public.nuv)
        assert.is_nil(public.by_index[0])
        assert.is_nil(public.by_index[2])
        assert.equal("_public.f1", public.by_index[1].path)
        assert.equal("Type.CInteger", public.by_index[1].type._tag)
        assert.equal(0, public.by_index[3].uv_index)
        assert.is_nil(public.by_index[3].type)
    end)

    it("round-trips portable native declarations and complete constructor layouts", function()
        local callback = types.CPointer(types.CFunction({cint()},
            types.CVoid(), false, nil), {})
        local plan = assert(layout.record(record({
            field("pointer", types.CPointer(cint(), {"const"}), 0),
            field("callback", callback, 1),
            field("wide", types.Option(types.CInteger("unsigned long long", false, 5, 64)), 2),
            field("precise", types.Option(types.CFloat("long double")), 3),
        })))
        local public = assert(layout.decode(assert(layout.encode("sample", {plan})))).records[plan.name]
        assert.is_true(public.complete)
        assert.equal(0, public.nuv)
        for index, slot in ipairs(plan.slots) do
            assert.is_true(types.equals(slot.type, public.slots[index].type))
        end
        assert.equal("long double", public.by_index[3].base.type.spelling)
    end)

    it("omits source-local nominal owners and rejects public nonportable C layouts", function()
        local owner = record({field("pointer", types.CPointer(cstruct("private"), {}), 0)})
        local plan = assert(layout.record(owner))
        rejected(function() return layout.encode("sample", {plan}) end, "portable")
        owner.islocal = true
        plan = assert(layout.record(owner))
        local decoded = assert(layout.decode(assert(layout.encode("sample", {plan}))))
        assert.same({}, decoded.layouts)
    end)

    it("distinguishes generated names with underscores, dots, and dashes", function()
        local names = {"a.b_c", "a_b.c", "a-b.C", "a_b.C", "a._2eb"}
        local seen = {}
        for _, fqtn in ipairs(names) do
            local cname = assert(layout.record(record({}, fqtn))).cname
            assert.is_nil(seen[cname])
            assert.truthy(cname:match("^[A-Za-z_][A-Za-z0-9_]*$"))
            seen[cname] = true
        end
    end)

    it("encodes maps deterministically and rejects duplicate owners", function()
        local a = assert(layout.record(record({}, "sample.A")))
        local b = assert(layout.record(record({}, "sample.B")))
        assert.equal(assert(layout.encode("sample", {a, b})),
            assert(layout.encode("sample", {z = b, a = a})))
        rejected(function() return layout.encode("sample", {a, a}) end, "duplicate")
    end)

    it("rejects malformed closed metadata instead of fabricating layout facts", function()
        local plan = assert(layout.record(record({
            field("text", types.String(), 0), field("count", cint(), 1),
        })))
        local encoded = assert(layout.encode("sample", {plan}))
        local function changed(mutate, fragment)
            local wire = assert(graphcodec.decode(encoded))
            mutate(wire)
            rejected(function()
                return layout.decode(assert(graphcodec.encode(wire)), "sample")
            end, fragment)
        end
        changed(function(w) w.extra = true end, "index")
        changed(function(w) w[2] = 99 end, "incompatible")
        changed(function(w) w[4][1][6][1][5] = 1 end, "dense")
        changed(function(w) w[4][1][6][2][5] = "f999" end, "member name")
        changed(function(w) w[4][1][6][2][6] = {"Type.CStruct"} end, "aggregate declaration")
        changed(function(w) w[4][1][6][2][6][5] = 0 end, "exportable")
        changed(function(w) w[4][1][6][2][1] = 0 end, "ordered")
        changed(function(w) w[4][1][6][2] = nil end, "missing slots")
        changed(function(w) w[4][1][2] = "foreign.Record" end, "another module")
        rejected(function() return layout.decode(encoded, "other") end, "module name")
        rejected(function() return layout.decode(encoded:sub(1, -2)) end, "checksum")
    end)
end)

-- Issue #450: a module compiled from source in the same build contributes only
-- its public layout to ordinary importers. Its header-typed private fields
-- must never reach a translation unit that does not include its C headers.
describe("source-built nominal layout privacy", function()
    local ROOT = assert(lfs.currentdir())
    if platform.windows then ROOT = assert(platform.path.normalize(ROOT)) end
    local PREFIX = require("spec.support.installed_prefix").active()
    local LUA = paths.join(PREFIX, "bin/lua" .. (platform.windows and ".exe" or ""))
    local PUBLIC = "_titan_nominal_pkg_2ea_2eHandle_public_payload"
    local COMPLETE = "_titan_nominal_pkg_2ea_2eHandle_payload"
    local workspace, saved_imported, saved_registry

    before_each(function()
        saved_imported, saved_registry = driver.imported, types.registry
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.write(paths.join(workspace, "opaque.h"), "typedef struct my_handle my_handle;\n" ..
            "typedef struct priv_state { int x; } priv_state;\n")
    end)

    after_each(function()
        driver.imported, types.registry = saved_imported, saved_registry
        files.remove(workspace)
    end)

    -- `c` imports `a` as source and reads a private field; `d` and `e` reach
    -- `a.Handle` only through `c`, so neither gains `a`'s private layout.
    local function sources()
        return {
            ["pkg.a"] = string.format("foreign import %q\n", paths.join(workspace, "opaque.h")) .. [[
record Handle
  const width: integer
  local const raw: foreign *my_handle
  local const state: foreign priv_state
  local const tag: string
end

function make(width: integer): Handle
  local state = foreign priv_state.new()
  state.x = 3
  return Handle(width, nil, state, "private")
end
]],
            ["pkg.b"] = [[
local a = import "pkg.a"

function width_of(h: a.Handle): integer
  return h.width
end

function seven(): integer
  return width_of(a.make(7))
end
]],
            ["pkg.c"] = [[
local a = import "pkg.a.titan"

function pass_handle(): a.Handle
  return a.make(9)
end

function state_of(h: a.Handle): integer
  return h.state.x as integer
end
]],
            ["pkg.d"] = [[
local c = import "pkg.c"

function width(): integer
  return c.pass_handle().width
end
]],
            ["pkg.e"] = [[
local c = import "pkg.c.titan"

function width(): integer
  return c.pass_handle().width
end
]],
            ["pkg.app"] = [[
local b = import "pkg.b"
local c = import "pkg.c"
local d = import "pkg.d"
local e = import "pkg.e"

function main(args: {string}): integer
  return b.seven() + d.width() + e.width() + c.state_of(c.pass_handle()) - 28
end
]],
        }
    end

    local function write_sources()
        for name, source in pairs(sources()) do
            files.write(paths.join(workspace, name:gsub("[.]", "/") .. ".titan"), source)
        end
    end

    local function public_only(code, name)
        for _, private in ipairs({ COMPLETE, "my_handle", "priv_state" }) do
            assert.is_nil(code:find(private, 1, true), name .. " names " .. private)
        end
    end

    -- `code_of(name)` returns the generated C of module `pkg.<name>`.
    local function assert_layouts(code_of)
        for _, name in ipairs({ "b", "d", "e" }) do
            local code = code_of(name)
            assert.truthy(code:find("} " .. PUBLIC .. ";", 1, true), name)
            public_only(code, name)
        end
        assert.truthy(code_of("c"):find("} " .. COMPLETE .. ";", 1, true))
    end

    -- The CLI writes `pkg/b.c` below its output; in-process builds write `pkg.b.c`.
    local function generated_file(directory, stem)
        return function(name)
            return files.read(paths.join(directory, stem .. name .. ".c"))
        end
    end

    -- This checkout's CLI and compiler with the selected installation's SDK.
    local function titanc(...)
        local argv = { LUA, "-e", "package.path = " .. string.format("%q",
            ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;") .. " .. package.path",
            ROOT .. "/titanc", "--tree", workspace, ... }
        local environment = { TITAN_ROOT = PREFIX, TITAN_PROBE_CACHE_DISABLE = "1",
            TITAN_EXTRA_CPPFLAGS = "", TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "" }
        local options = { stderr_to_stdout = true }
        if platform.windows then
            options.env = environment
        else
            local command = { "env" }
            for name, value in pairs(environment) do command[#command + 1] = name .. "=" .. value end
            for _, word in ipairs(argv) do command[#command + 1] = word end
            argv = command
        end
        local result = compiler_io.new_sync():run(argv, options)
        local output = (result.output or result.diagnostic or ""):gsub("\r\n", "\n")
        assert.is_true(result.ok == true, output)
        return output
    end

    local function in_workspace(body)
        local previous = assert(lfs.currentdir())
        assert(lfs.chdir(workspace))
        local ok, err = pcall(body)
        assert(lfs.chdir(previous))
        assert(ok, err)
    end

    it("builds CLI libraries and compile-only objects with public importer layouts", function()
        write_sources()
        for _, mode in ipairs({ "library", "objects" }) do
            local out = paths.join(workspace, mode)
            if mode == "objects" then
                titanc("-q", "-c", "-o", out, "pkg.b", "pkg.d", "pkg.e")
            else
                titanc("-q", "-o", out, "pkg.b", "pkg.d", "pkg.e")
            end
            assert_layouts(generated_file(out, "pkg/"))
        end
    end)

    it("emits the same public importer layout in cold and warm incremental builds", function()
        write_sources()
        local out = paths.join(workspace, "out")
        local function declarations(name)
            local found = {}
            for block in files.read(paths.join(out, "pkg/" .. name .. ".c"))
                    :gmatch("typedef struct {[^{}]*} _titan_nominal_[%w_]+;") do
                found[#found + 1] = block
            end
            return table.concat(found, "\n")
        end
        titanc("-q", "--incremental", "-c", "-o", out, "pkg.b", "pkg.d", "pkg.e")
        assert_layouts(generated_file(out, "pkg/"))
        local cold = declarations("b")
        local b = paths.join(workspace, "pkg/b.titan")
        files.write(b, files.read(b) .. "\nfunction eight(): integer\n  return 8\nend\n")
        local output = titanc("-v", "--incremental", "-c", "-o", out, "pkg.b", "pkg.d", "pkg.e")
        assert.truthy(output:find("Titan object hit pkg.a:", 1, true), output)
        assert.truthy(output:find("Titan object miss pkg.b: source-content", 1, true), output)
        assert.equal(cold, declarations("b"))
        assert_layouts(generated_file(out, "pkg/"))
    end)

    it("keeps single-resolver in-process libraries and programs public", function()
        local code_of = generated_file(workspace, "pkg.")
        in_workspace(function()
            local ok, err = h.generate_modules(sources(), "pkg.app")
            assert.truthy(ok, err)
        end)
        assert_layouts(code_of)
        public_only(code_of("app"), "app")
        in_workspace(function()
            local ok, err = h.generate_modules(sources(), "pkg.app", true)
            assert.truthy(ok, err)
            local ran, why, status, output = h.call_app("./pkg/app")
            assert.is_true(ran, output)
            assert.equal("exit", why, output)
            assert.equal(0, status, output)
        end)
        assert_layouts(code_of)
    end)

    it("keeps direct coder.generate calls public without application layouts", function()
        local ok, err, imported = h.run_checker_modules(sources(), "pkg.app", { interface = "source" })
        assert.is_true(ok, err)
        assert_layouts(function(name)
            local generated = coder.generate("pkg." .. name, imported["pkg." .. name].ast, {},
                driver.TITAN_ABI_VERSION, false, {})
            local parts = {}
            for _, part in ipairs(generated.parts) do parts[#parts + 1] = part.code end
            return table.concat(parts, "\n")
        end)
    end)
end)
