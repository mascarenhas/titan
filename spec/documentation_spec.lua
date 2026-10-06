local documentation = require "titan-compiler.documentation"
local parser = require "titan-compiler.parser"
local types = require "titan-compiler.types"
local driver = require "titan-compiler.driver"
local completion = require "titan-compiler.completion"
local binarycompat = require "titan-compiler.binarycompat"

describe("LDoc documentation metadata", function()
    local previous_imported, previous_registry
    before_each(function()
        previous_imported, previous_registry = driver.imported, types.registry
        driver.imported, types.registry = {}, {}
    end)
    after_each(function()
        driver.imported, types.registry = previous_imported, previous_registry
    end)
    local function check(source, modules, request)
        driver.imported, types.registry = {}, {}
        local sources, entries = {sample = source}, {}
        for name, text in pairs(modules or {}) do sources[name] = text end
        local overrides = {}
        for name, text in pairs(sources) do
            local filename = name == "sample" and "/tmp/titan-ldoc-sample.titan" or "/tmp/titan-ldoc-" .. name .. ".titan"
            overrides[name] = {kind="generated", main=filename, files={filename}, contents={[filename]=text}}
        end
        local loader = driver.defaultloader({}, {
            analysis_only = true, interface = "source", transient_caches = true,
            source_roots = {sample = true}, source_overrides = overrides, completion = request,
        })
        local ok, result, errors = loader("sample")
        assert.is_true(ok, tostring(result))
        if not request then assert.equal(0, #errors, table.concat(errors, "\n")) end
        assert.is_true(driver.close_loader(loader))
        return driver.imported.sample, driver.imported
    end
    local source = [[
--- A documented module. Module details.
-- @module sample

--- An alias with its own meaning.
type Count = integer
--- A private alias.
local type Hidden = integer
--- A constant value.
const count: Count = 1
--- A generic box.
-- @usage containers.md#box
-- @see Container guide.
-- @field item The stored value.
record Box<|T|> item: T end
--- Create a box.
-- @param item Initial value.
-- @return New box.
-- @usage containers.md#box
function Box.new(item: T): Box<|T|> return {item = item} end
--- Read a box.
function Box:get(): T return self.item end
--- An interface view.
interface View
    --- The visible item.
    item: integer
    --- Read through the view.
    function get(): integer
end
--- A choice.
union Choice
    --- A successful choice.
    Some(item: integer)
    None()
end
--- A top-level function.
-- @param value A count.
-- @return The same value.
-- @return An extra value.
function echo(value: Count): integer return value end
]]
    it("parses summaries, paragraphs, repeated tags and multiline examples", function()
        local doc = documentation.parse("Summary? More detail.\n\nAnother paragraph.\n@param[opt] input first\n  continued\n@return one\n@return two\n@usage\n    echo(1)\n@custom unknown")
        assert.equal("Summary?", doc.summary)
        assert.equal("More detail.\n\nAnother paragraph.", doc.description)
        assert.same({name = "param", value = "[opt] input first\n  continued"}, doc.tags[1])
        assert.same({name = "return", value = "one"}, doc.tags[2])
        assert.same({name = "return", value = "two"}, doc.tags[3])
        assert.equal("\n    echo(1)", doc.tags[4].value)
        assert.equal("custom", doc.tags[5].name)
    end)
    it("attaches only lexical comment tokens to declarations and interface methods", function()
        local tree = assert(parser.parse("sample.titan", source))
        assert.equal("A documented module.", tree._documentation.summary)
        local names = {}
        for _, node in ipairs(tree) do if node.name then names[node.name] = node end end
        assert.equal("An alias with its own meaning.", names.Count._documentation.summary)
        assert.equal("Read through the view.", names.View.methods[1]._documentation.summary)
        local standalone = assert(parser.parse("standalone.titan", "--- First declaration.\nx=1\nlocal s=[=[--- False doc.]=]\n-- ordinary\ny=2\n"))
        local copyright = assert(parser.parse("copyright.titan", "--- A module.\n-- @module copyright\n-- @usage guide.md\n\n-- Copyright notice.\nx=1\n"))
        assert.equal("guide.md", copyright._documentation.tags[2].value)
        assert.is_nil(standalone._documentation)
        assert.equal("First declaration.", standalone[1].decl._documentation.summary)
        assert.is_nil(standalone[3]._documentation)
        local body = assert(parser.parse("body.titan", "--[=[-- Block summary. Block details.\n@param x input\n]=]\nfunction f(x:integer)\n--- Body annotation.\nlocal y=1\nend\nfunction g() end"))
        assert.equal("Block summary.", body[1]._documentation.summary)
        assert.equal("Block details.", body[1]._documentation.description)
        assert.is_nil(body[2]._documentation)
    end)
    it("scans large comment and doc-looking string runs without false attachment", function()
        local text = ("-- ordinary @param text.\n"):rep(8192) ..
            "local literal=[=[" .. ("--- False documentation.\n"):rep(8192) ..
            "]=]\n--- The final declaration.\nfunction final() end\n"
        local tree = assert(parser.parse("large-comments.titan", text))
        assert.is_nil(tree[1]._documentation)
        assert.equal("The final declaration.", tree[2]._documentation.summary)
        assert.is_nil(tree._documentation)
    end)
    it("resolves declaration identities including imported aliases, methods and fields", function()
        local entry = check(source .. [[
function use(box: Box<|integer|>, view: View): integer
  local a = box:get()
  local b = view:get()
  return a + b + box.item
end
]])
        local mod = entry.type
        assert.equal("A constant value.", mod.members.count._documentation.summary)
        assert.equal("The stored value.", mod.members.Box.type.fields[1]._documentation.summary)
        assert.same({name="usage",value="containers.md#box"},mod.members.Box.type.fields[1]._documentation.tags[1])
        assert.same({name="see",value="Container guide."},mod.members.Box.type.fields[1]._documentation.tags[2])
        assert.equal("Read a box.", mod.members.Box.type.methods.get._documentation.summary)
        assert.equal("Read through the view.", mod.type_members.View.methods.get._documentation.summary)
        local seen = {}
        local function visit(node)
            if type(node) ~= "table" or seen[node] then return end
            seen[node] = true
            if node._method then
                assert.truthy(documentation.for_node(node))
                assert.matches("Read", documentation.for_node(node).summary)
            end
            for key, value in pairs(node) do
                if type(value) == "table" and (type(key) ~= "string" or key:sub(1,1) ~= "_") then visit(value) end
            end
        end
        visit(entry.ast)
        local consumer = check([[local lib=import "lib"
function use(value:lib.Count):integer return lib.echo(value) end]], {lib=source:gsub("@module sample", "@module lib")})
        local use, imported
        for _, node in ipairs(consumer.ast) do
            if node.name == "use" then use = node end
            if node.modname == "lib" then imported = node end
        end
        local arg = use.params[1].type
        assert.equal("An alias with its own meaning.", documentation.for_node(arg).summary)
        assert.equal("A documented module.", documentation.for_node(imported).summary)
    end)
    it("retains detached docs in compact and encoded source manifests and binary metadata", function()
        local entry = check(source)
        local compact = assert(driver.compact_project_entry(entry))
        local decoded = assert(driver.decode_project_entry(assert(driver.encode_project_entry(entry))))
        assert.same(entry.type._documentation, compact.type._documentation)
        assert.same(entry.type._type_documentation, decoded.type._type_documentation)
        assert.same(entry.type.members.Box.type.methods.get._documentation, decoded.type.members.Box.type.methods.get._documentation)
        local binary = assert(driver.decode_module_interface(types.serialize(entry.type), "sample"))
        assert.same(entry.type._documentation, binary._documentation)
        assert.is_nil(binary._type_documentation.Hidden)
        assert.same(entry.type._type_documentation.Count, binary._type_documentation.Count)
        assert.same(entry.type.type_members.View.methods.get._documentation, binary.type_members.View.methods.get._documentation)
        local facts = completion.describe(decoded).candidates
        local docs = {}
        for _, row in ipairs(facts) do docs[row.owner_key .. "/" .. row.access_mode .. "/" .. row.name] = row.documentation end
        assert.equal("An alias with its own meaning.", docs["module:sample/type/Count"].summary)
        assert.equal("Read a box.", docs["nominal:sample.Box/colon/get"].summary)
        assert.equal("The stored value.", docs["nominal:sample.Box/dot/item"].summary)
        facts[1].documentation = {summary="changed",description="",tags={}}
        assert.not_equal("changed", completion.describe(decoded).candidates[1].documentation.summary)
    end)
    it("retains docs through generic specialization and unsaved member completion", function()
        local text = source .. '\nfunction use(box:Box<|integer|>) box:HOLE end'
        local caret = assert(text:find("HOLE", 1, true)) - 1
        local prepared = assert(completion.prepare("/tmp/titan-ldoc-sample.titan", text, caret))
        local entry = check(prepared.text, nil, prepared.request)
        local method
        for _, row in ipairs(entry.completion.candidates) do if row.name == "get" then method = row end end
        assert.equal("Read a box.", method.documentation.summary)
        assert.matches("integer", method.detail)
        local copied = documentation.copy(method.documentation)
        copied.tags[1] = {name="return",value="changed"}
        assert.same({}, method.documentation.tags)
    end)
    it("resolves source-free imported docs and captures provider sibling module docs", function()
        local saved = check(source)
        local binary = types.serialize(saved.type)
        driver.imported, types.registry = {}, {}
        local text = [[local lib=import "lib"
function use(value:lib.Count, box:lib.Box<|integer|>):integer
  local fn = lib.Box.new
  local bound = box:get
  return lib.echo(value) + bound()
end]]
        local filename = "/tmp/titan-ldoc-consumer.titan"
        -- Rebase a provider's module identity by checking it under that name.
        local files = {["/tmp/titan-ldoc-lib.titan"] = source}
        local provider_loader = driver.defaultloader({}, {analysis_only=true,
            source_overrides={lib={kind="generated",main="/tmp/titan-ldoc-lib.titan",files={"/tmp/titan-ldoc-lib.titan"},contents=files}}})
        assert.is_true(provider_loader("lib"))
        binary = types.serialize(driver.imported.lib.type)
        assert.is_true(driver.close_loader(provider_loader))
        driver.imported, types.registry = {}, {}
        local loader = driver.defaultloader({}, {analysis_only=true,completion_closed_world=true,
            source_roots={consumer=true}, source_overrides={consumer={kind="generated",main=filename,files={filename},contents={[filename]=text}}},
            cached_binary_interfaces={lib={serialized=binary,kind="static",filename="/tmp/lib.a"}}})
        local ok, _, errors = loader("consumer")
        assert.is_true(ok)
        assert.equal(0,#errors,table.concat(errors,"\n"))
        local entry = driver.imported.consumer
        local function find(name)
            for _, node in ipairs(entry.ast) do if node.name==name then return node end end
        end
        local use=find("use")
        assert.equal("An alias with its own meaning.",documentation.for_node(use.params[1].type).summary)
        assert.equal("A generic box.",documentation.for_node(use.params[2].type).summary)
        local names, seen = {}, {}
        local function visit(node)
            if type(node)~="table" or seen[node] then return end
            seen[node]=true
            if node.name or node.method then
                local doc=documentation.for_node(node)
                if doc then names[node.name or node.method]=doc.summary end
            end
            for key,value in pairs(node) do
                if type(value)=="table" and (type(key)~="string" or key:sub(1,1)~="_") then visit(value) end
            end
        end
        visit(use)
        assert.equal("Create a box.",names.new)
        assert.equal("Read a box.",names.get)
        assert.equal("A top-level function.",names.echo)
        assert.is_true(driver.close_loader(loader))
        local sibling=assert(driver.decode_module_interface(binary,"lib"))
        driver.imported={}
        local catalog=driver.completion_binary_catalog({selected_static_providers={{archive="/tmp/lib.a",entries={lib={type=sibling}}}},source_modules={}})
        assert.equal("A documented module.",catalog.lib.documentation.summary)
        catalog.lib.documentation.summary="changed"
        assert.equal("A documented module.",sibling._documentation.summary)
    end)
    it("documents synthesized public constructors from owners and variants", function()
        local entry = check("--- A record.\n-- @field item Stored count.\n-- @usage records.md\nrecord Item item:integer end\n--- A choice.\n-- @usage choices.md\nunion Choice\n--- A populated choice.\nSome(item:integer)\nNone()\nend")
        local item = entry.type.members.Item.type.functions.new._documentation
        assert.equal("Create a new Item.", item.summary)
        assert.same({name="param",value="item Stored count."},item.tags[1])
        assert.same({name="usage",value="records.md"},item.tags[3])
        local some = entry.type.members.Choice.type.functions.Some._documentation
        assert.equal("A populated choice.", some.summary)
        assert.same({name="usage",value="choices.md"},some.tags[3])
        assert.truthy(entry.type.members.Choice.type.functions.None._documentation)
    end)
    it("invalidates source-import fingerprints when private documentation changes", function()
        local entry = check([[--- A private alias.
local type Hidden=integer
--- A private function.
local function hidden(value:integer):integer return value end
--- A public function.
function public(value:integer):integer return value end
]])
        local before = assert(driver.serialize_source_interface(entry))
        local semantic = types.serialize_semantic(entry.type)
        entry.type._type_documentation.Hidden.summary = "Changed private alias docs."
        local alias_changed = assert(driver.serialize_source_interface(entry))
        assert.not_equal(before, alias_changed)
        entry.type.source_members.hidden._documentation.summary = "Changed private function docs."
        assert.not_equal(alias_changed, assert(driver.serialize_source_interface(entry)))
        assert.equal(semantic, types.serialize_semantic(entry.type))
        local compact = assert(driver.compact_project_entry(entry))
        assert.equal(assert(driver.serialize_source_interface(entry)),
            assert(driver.serialize_source_interface(compact)))
    end)
    it("keeps documentation outside runtime ABI and semantic compatibility", function()
        local entry = check(source)
        local before = binarycompat.module(entry.type, entry.declared_registry)
        local semantic = types.serialize_semantic(entry.type)
        entry.type._documentation.summary = "Changed module docs."
        entry.type.members.echo._documentation.summary = "Changed function docs."
        assert.same(before, binarycompat.module(entry.type, entry.declared_registry))
        assert.equal(semantic, types.serialize_semantic(entry.type))
        assert.not_equal(types.serialize(entry.type), semantic)
        assert.is_true(types.equals(entry.type.members.count.type, types.Integer()))
    end)
    it("rejects malformed and sparse documentation without retaining mutable input", function()
        local doc = documentation.parse("Summary.\n@return result")
        local typ = types.Documented(types.Module("sample", {}), doc)
        doc.tags[1].value = "changed"
        assert.equal("result", typ._documentation.tags[1].value)
        for _, broken in ipairs({
            {summary="s",description="d",tags={[2]={name="return",value="x"}}},
            {summary="s",description="d",tags={{name="return",value="x",extra=true}}},
            {summary="s",description="d",tags={},extra=true},
        }) do assert.has_error(function() documentation.copy(broken) end) end
        local legacy = assert(driver.decode_module_interface("Module('sample',{}, {})", "sample"))
        assert.is_nil(legacy._documentation)
        assert.is_nil(documentation.for_node({_tag="Ast.Decl",name="plain"}))
    end)
end)
