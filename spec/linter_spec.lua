local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local installed_prefix = require "spec.support.installed_prefix"
local lfs = require "lfs"
local linter = require "titan-compiler.linter"
local platform = require "titan-compiler.platform"
local temporary = require "spec.support.temporary"
local types = require "titan-compiler.types"

-- Fixture sources mark every expected diagnostic with a trailing
-- `--! <rule-id> ...` comment on the reported line. Each module lists the
-- rules whose complete hit set it pins: a marked line is a positive and every
-- unmarked construct in the module is a near miss for those rules.

local function write_file(filename, text)
    local handle = assert(io.open(filename, "wb"))
    assert(handle:write(text))
    assert(handle:close())
end

local function make_tree(files)
    local root = temporary.name("-lint")
    assert(lfs.mkdir(root))
    for relative, text in pairs(files) do
        local directory = root
        for component in relative:gmatch("([^/]+)/") do
            directory = directory .. "/" .. component
            if not lfs.attributes(directory) then assert(lfs.mkdir(directory)) end
        end
        write_file(root .. "/" .. relative, text)
    end
    return root
end

local function remove_tree(target)
    local mode = lfs.symlinkattributes(target, "mode")
    if not mode then return end
    if mode == "directory" then
        for entry in lfs.dir(target) do
            if entry ~= "." and entry ~= ".." then remove_tree(target .. "/" .. entry) end
        end
        assert(lfs.rmdir(target))
    else
        assert(os.remove(target))
    end
end

-- Lint through the public driver entry point; it analyzes in fresh semantic
-- caches and restores the caller's.
local function lint(root, modules, options)
    local request = { modules = modules, tree = root,
        rule_directives = { { op = "enable", value = "all" } } }
    for key, value in pairs(options or {}) do request[key] = value end
    return driver.lint_modules(request)
end

local function basename(filename)
    return filename:match("([^/\\]+)$")
end

local function marked_hits(text, rules)
    local hits, line = {}, 0
    for source_line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line + 1
        local marks = source_line:match("%-%-!%s*(.-)%s*$")
        for rule in (marks or ""):gmatch("%S+") do
            if rules[rule] then hits[#hits + 1] = line .. " " .. rule end
        end
    end
    table.sort(hits)
    return hits
end

local function reported_hits(result, file, rules)
    local hits = {}
    for _, diagnostic in ipairs(result.diagnostics) do
        if basename(diagnostic.file) == file and (rules == nil or rules[diagnostic.rule]) then
            hits[#hits + 1] = diagnostic.line .. " " .. diagnostic.rule
        end
    end
    table.sort(hits)
    return hits
end

local function set_of(list)
    local set = {}
    for _, item in ipairs(list) do set[item] = true end
    return set
end

local FIXTURES = {}
-- `negative` fixtures pin rules that must stay silent on every line. A dotted
-- module name lives at the matching slash path.
local function fixture(name, rules, text, negative)
    FIXTURES[#FIXTURES + 1] = { name = name, rules = rules, text = text, negative = negative,
        file = name:gsub("%.", "/") .. ".titan" }
end

fixture("unused", { "unused-local-binding", "unused-lambda-param" }, [==[
local iteration = import "iteration"

local function consume(n: integer): integer
  return n + 1
end

function plain(xs: {integer}): integer
  local ignored = #xs --! unused-local-binding
  local _ = consume(1)
  local written = 0
  written = #xs
  for index = 1, 3 do consume(1) end --! unused-local-binding
  for _, item in iteration.ipairs(xs) do consume(item) end
  for position, _ in iteration.ipairs(xs) do end --! unused-local-binding
  local f = function (unused: integer): integer return 42 end --! unused-lambda-param
  local g = function (_: integer): integer return 1 end
  local h = function (a: integer, b: integer): integer return 1 end
  local k = function (...: integer): integer return 1 end
  return f(1) + g(1) + h(1, 2) + k()
end

function shadow_read(): integer
  local _ = 1
  local unused = 2
  return _
end

function shadow_write(): integer
  local _ = 1
  local unused = 2
  _ = 3
  return 0
end

function shadow_closure(): function (): integer
  local _ = 1
  local unused = 2
  return function (): integer return _ end
end

function before_and_after(): integer
  local _ = 1
  local unused = 2
  local total = _
  do
    local _ = 3
    total = total + _
  end
  return total + _
end

function inner_shadow_only(): integer
  local unused = 2
  do
    local _ = 3
    return _
  end
end

function in_repeat(): integer
  local count = 0
  repeat
    local _ = count
    local unused = 1
    count = count + 1
  until _ > 3
  return count
end

function in_defer(): integer
  local _ = 1
  local unused = 2
  defer consume(_)
  return 0
end

function lambda_shadow(): function (integer): integer
  local _ = 1
  return function (unused: integer): integer return _ end
end

function after_scope(): integer
  do
    local unused = 1 --! unused-local-binding
  end
  local _ = 2
  return _
end
]==])

-- Written `_` uses that are not plain names, and code the checker never
-- reached: renaming would capture or break them, so nothing is reported.
fixture("unused_hidden", { "unused-local-binding", "unused-lambda-param" }, [==[
local function iter(): integer?
  return nil
end

function parenthesized(_: {integer}): integer?
  local unused = 1
  return (..._)
end

function result_annotation(_: integer): function (value): (integer?)
  return function (unused: value): integer?
    return _
  end
end

function surplus(_: string): integer
  local unused = 1
  for _ in iter, nil, nil, nil, #_ do end
  return 1
end

function unreachable(): integer
  do return 0 end
  local x = 1
  return x
end

function read_unreachable(): integer
  local y = 1
  do return 0 end
  return y
end

function visible(xs: {integer}): integer?
  local dropped = 1 --! unused-local-binding
  return (...xs)
end
]==])

-- A module-level `_` can be named by types whose written syntax the checker
-- does not keep (cast and test targets); no local of such a module is
-- offered the rename.
fixture("unused_module_underscore", { "unused-local-binding", "unused-lambda-param" }, [==[
local _ = import "test"

function qualified(v: value): boolean
  local unused = 1
  return v is _.Context
end

function qualified_cast(v: value): _.Context
  local unused = 1
  return v as _.Context
end

function qualified_lambda(): function (value): boolean
  return function (unused: value): boolean
    local check = function (v: value): boolean return v is _.Context end
    return check(1)
  end
end

function annotated(): function (value): (_.Context?)
  return function (unused: value): _.Context?
    return nil
  end
end
]==], true)

fixture("shorthand", { "prefer-record-call-shorthand" }, [==[
local geo = import "geo"

record Point
  x: integer
  y: integer
end

record Box<|T|>
  item: T
end

function Box.new<|U|>(src: U, f: function (U): (T)): Box<|T|>
  return { item = f(src) }
end

union Shape
  circle()
end

function Shape.new(): Shape
  return Shape.circle()
end

function make(): (Point, Point, Point, Box<|integer|>, function (integer, integer): (Point), geo.Point, Shape)
  local a = Point.new(1, 2) --! prefer-record-call-shorthand
  local b = Point(3, 4)
  local c = Point.new { x = 1, y = 2 } --! prefer-record-call-shorthand
  local d = Box<|integer|>.new<|string|>("ok", function (s: string): integer return #s end)
  local ctor: function (integer, integer): (Point) = Point.new
  local e = geo.Point.new(5, 6) --! prefer-record-call-shorthand
  local s = Shape.new()
  return a, b, c, d, ctor, e, s
end

record Holder<|T|>
  item: T?
end

local function create(): value
  return Holder<|integer|>.new(nil) --! prefer-record-call-shorthand
end

function created(): value
  return create()
end
]==])

fixture("testsig", { "unmatched-public-test-signature" }, [==[
local test = import "test"

type Ctx = test.Context

function test_ok(t: test.Context)
  test.assert(t:name() ~= "")
end

function test_alias(t: Ctx)
  test.assert(t:name() ~= "")
end

function test_missing() --! unmatched-public-test-signature
end

function test_wrong(n: integer) --! unmatched-public-test-signature
  test.assert(n > 0)
end

function test_two(t: test.Context, n: integer) --! unmatched-public-test-signature
  test.assert(n > 0)
end

local function test_helper(n: integer): integer
  return n
end

function helper_test(n: integer): integer
  return test_helper(n)
end

function test_generic<|T|>(x: T): T --! unmatched-public-test-signature
  return x
end
]==])

fixture("notest", { "unmatched-public-test-signature" }, [==[
function test_wrong(n: integer): integer
  return n
end
]==], true)

fixture("unions", { "union-identity-equality" }, [==[
local async = import "async"
local http = import "http"
local reflect = import "reflect"
local uv = import "uv"
local websocket = import "websocket"

union Mode
  fast()
  slow()
end

local cached_mode = Mode.fast()

function Mode.cached(): Mode
  return cached_mode
end

function async_rows(a: async.Result<|integer, string|>, b: async.Result<|integer, string|>): boolean
  if a == async.Result<|integer, string|>.success(1) then return true end --! union-identity-equality
  return a == b
end

function async_nil(a: async.Result<|integer, string|>?): boolean
  return a == nil
end

function uv_rows(m: uv.run_mode): boolean
  if m == uv.run_mode.default() then return true end --! union-identity-equality
  return m == uv.RUN_DEFAULT
end

function http_rows(r: http.RedirectMode, c: http.CacheMode, cr: http.CredentialsMode, q: http.RequestMode): boolean
  if r == http.RedirectMode.follow() then return true end --! union-identity-equality
  if c ~= http.CacheMode.reload() then return true end --! union-identity-equality
  if cr == http.CredentialsMode.omit() then return true end --! union-identity-equality
  return q == http.RequestMode.cors() --! union-identity-equality
end

function reflect_rows(a: reflect.Type, b: reflect.Type): boolean
  if reflect.Type.is_integer() == a then return true end --! union-identity-equality
  return a ~= b
end

function websocket_rows(k: websocket.MessageType): boolean
  if k == websocket.MessageType.text() then return true end --! union-identity-equality
  if websocket.MessageType.binary() ~= k then return true end --! union-identity-equality
  return k == websocket.TEXT or k ~= websocket.BINARY
end

function user_rows(u1: Mode, u2: Mode): boolean
  return u1 == u2 or u1 == Mode.cached() or u1 == Mode.fast()
end
]==])

-- A user module below the `titan.async` prefix is not the async module.
fixture("titan.async.user", { "union-identity-equality" }, [==[
union U
  a()
  b()
end

function eq(x: U, y: U): boolean
  return x == y or x == U.a()
end
]==], true)

fixture("imports", { "stdlib-import-spelling" }, [==[
local strings = import "titan.string" --! stdlib-import-spelling
local filesystem = import "titan.fs" --! stdlib-import-spelling
local math = import "math"
local collab = import "collab.titan"

function use(): integer
  return #strings.upper("x") + math.floor(1.5) + #filesystem.read_file("x") + collab.Item(1).id
end
]==])

fixture("consts", { "prefer-const-local-field", "prefer-const-local" }, [==[
foreign import "time.h"

local record Session
  local token: string --! prefer-const-local-field
  local uses: integer
  label: string
  local const fixed: integer
  local stamp: foreign tm
end

local function Session:bump(): integer
  self.uses = self.uses + 1
  return self.uses + #self.token + #self.label + self.fixed
end

function locals(n: integer): integer
  local limit = 10 --! prefer-const-local
  local total = 0
  total = total + n
  const fixed = 1
  local a, b = 1, 2
  local t = foreign tm.new()
  t.tm_year = 1
  local unused = 5
  local omitted: value
  return limit + total + fixed + a + b + (t.tm_year as integer) + (omitted == nil and 0 or 1)
end
]==])

fixture("booleans", { "boolean-option-silent-truthiness-local" }, [==[
function conditions(flag: boolean?, other: boolean): integer
  if flag then return 1 end
  if not flag then return 2 end
  while flag do flag = false end
  repeat flag = nil until flag
  if flag == nil then return 3 end
  if other then return 4 end
  return 0
end

function truthiness(flags: {boolean}, i: integer): boolean
  local active = flags[i] --! boolean-option-silent-truthiness-local
  local kept? = flags[i]
  local typed: boolean = flags[i]
  return active and (kept or typed)
end
]==])

fixture("iface", { "ephemeral-interface-map-key" }, [==[
interface Keyed
  function id(): integer
end

record Item
  const code: integer
end

function Item:id(): integer
  return self.code
end

function lookup(cache: {Keyed: string}, item: Item): string?
  return cache[item] --! ephemeral-interface-map-key
end

function store(cache: {Keyed: string}, item: Item)
  cache[item] = "x" --! ephemeral-interface-map-key
end

function reuse(cache: {Keyed: string}, item: Item): string?
  local key: Keyed = item
  cache[key] = "ok"
  return cache[key]
end
]==])

fixture("errors", { "catch-reraise-resets-trace", "extra-do-block-around-try" }, [==[
local function risky()
end

function reraise()
  risky()
catch
  raise error --! catch-reraise-resets-trace
end

function bare()
  risky()
catch
  raise
end

function with_trace()
  risky()
catch
  raise error, traceback
end

function in_lambda()
  risky()
catch
  local again = function () raise error end
  again()
end

function nested()
  risky()
catch
  local outer = error
  do
    risky()
  catch
    raise error --! catch-reraise-resets-trace
  end
  raise outer
end

function in_finally()
  do --! extra-do-block-around-try
    risky()
  catch
    defer raise error
    risky()
  end
end

function wrapped(): integer?
  do --! extra-do-block-around-try
    return 1
  catch
    return nil
  end
end

function direct(): integer?
  return 1
catch
  return nil
end

function narrowed(): integer
  local n = 1
  do
    n = 2
  catch
    return 0
  end
  return n
end

function loop_body(count: integer)
  for _ = 1, count do
    do --! extra-do-block-around-try
      risky()
    catch
      risky()
    end
  end
end

do
  do
    risky()
  catch
    risky()
  end
end
]==])

fixture("records", { "duplicate-record-literal-field", "dso-imported-record-literal",
    "dso-closed-union-case" }, [==[
local geo = import "geo"
local collab = import "collab.titan"
local http = import "http"
local uv = import "uv"

record Pair
  x: integer
  y: integer
end

union Local
  a()
  b()
end

function dup(): Pair
  return { x = 1, y = 2, x = 3 } --! duplicate-record-literal-field
end

function clean(): Pair
  return { x = 1, y = 2 }
end

function container(): uv.stdio_container_t
  return { flags = 0, data = uv.stdio_data_t.fd(-1) } --! dso-imported-record-literal
end

function via_ctor(): uv.stdio_container_t
  return uv.stdio_container_t(0, uv.stdio_data_t.fd(-1))
end

function source_owner(): geo.Point
  return { x = 0, y = 0 }
end

function collab_literal(): collab.Item
  return { id = 1 }
end

function describe(mode: http.RedirectMode): integer
  case mode --! dso-closed-union-case
  when follow() then return 1
  when error() then return 2
  when manual() then return 3
  end
end

function describe_else(mode: http.RedirectMode): integer
  case mode
  when follow() then return 1
  else return 0
  end
end

function source_union(s: geo.Status): string
  case s
  when ok() then return "ok"
  when failed(msg) then return msg
  end
end

function local_case(l: Local): integer
  case l
  when a() then return 1
  when b() then return 2
  end
end

function collab_case(k: collab.Kind): integer
  case k
  when one() then return 1
  when two() then return 2
  end
end
]==])

fixture("gcs", { "gc-finalizable-non-collectable-arg", "gc-finalizable-captures-target" }, [==[
local gc = import "gc"

record Handle
  closed: boolean
end

function bad()
  gc.finalizable(42, function (_: integer) end) --! gc-finalizable-non-collectable-arg
  gc.finalizable("text", function (_: string) end) --! gc-finalizable-non-collectable-arg
end

function captures(): (Handle, Handle)
  local h = Handle(false)
  gc.finalizable(h, function (_: Handle) h.closed = true end) --! gc-finalizable-captures-target
  local k = Handle(false)
  gc.finalizable(k, function (target: Handle) target.closed = true end)
  return h, k
end

function ok_value(x: value)
  gc.finalizable<|value|>(x, function (_: value) end)
end
]==])

fixture("races", { "race-any-unmanaged-losers" }, [==[
local async = import "async"
local timer = import "timer"

function race_inline(): integer
  local work = async.run(function (): integer
    timer.sleep(5)
    return 1
  end)
  case async.any_two(work, async.run(function (): nil --! race-any-unmanaged-losers
    timer.sleep(20)
    return nil
  end))
  when first(v) then return v
  when second() then work:cancel(); async.join(work); return 0
  when none() then return -1
  end
end

function race_managed(): integer
  local work = async.run(function (): integer
    timer.sleep(5)
    return 1
  end)
  local deadline = async.run(function (): nil
    timer.sleep(20)
    return nil
  end)
  case async.any_two(work, deadline)
  when first(v) then deadline:cancel(); async.join(deadline); return v
  when second() then work:cancel(); async.join(work); return 0
  when none() then return -1
  end
end
]==])

fixture("cexports", { "header-dependent-public-c-export" }, [==[
foreign import "time.h"

function make_tm(): foreign tm --! header-dependent-public-c-export
  local t = foreign tm.new()
  t.tm_year = 1
  return t
end

local function hidden(): foreign tm
  local t = foreign tm.new()
  t.tm_year = 2
  return t
end

record Stamp
  year: integer
  local raw: foreign tm
end

record Exposed
  raw: foreign tm --! header-dependent-public-c-export
end

union Holder
  held(stamp: foreign tm) --! header-dependent-public-c-export
  empty()
end

function portable(n: foreign int): foreign int
  return n
end

function use_hidden(): integer
  return hidden().tm_year as integer
end
]==])

-- Closed-graph reachability through public nominal fields and variants,
-- including a cycle whose header type hangs off a different edge; both
-- declaration orders must report every exporting declaration.
fixture("cgraph_a", { "header-dependent-public-c-export" }, [==[
foreign import "time.h"

record Inner
  raw: foreign tm --! header-dependent-public-c-export
end

record Outer
  inner: Inner --! header-dependent-public-c-export
end

function public(outer: Outer): Outer --! header-dependent-public-c-export
  return outer
end

record A
  b: B? --! header-dependent-public-c-export
  raw: foreign tm --! header-dependent-public-c-export
end

record B
  a: A? --! header-dependent-public-c-export
end

union Either
  left(b: B) --! header-dependent-public-c-export
  none()
end

function take_b(b: B): integer --! header-dependent-public-c-export
  return b.a == nil and 0 or 1
end

record Hidden
  local raw: foreign tm
end

record Wraps
  hidden: Hidden
end

function wraps(w: Wraps): Wraps
  return w
end
]==])

fixture("cgraph_b", { "header-dependent-public-c-export" }, [==[
foreign import "time.h"

function take_b(b: B): integer --! header-dependent-public-c-export
  return b.a == nil and 0 or 1
end

record B
  a: A? --! header-dependent-public-c-export
end

record A
  raw: foreign tm --! header-dependent-public-c-export
  b: B? --! header-dependent-public-c-export
end
]==])

-- A module with discovered tests is rebuilt from source by `titanc --test`
-- and has no independently built importers: no packaging hints.
fixture("packaging_tests", { "header-dependent-public-c-export", "dso-imported-record-literal",
    "dso-closed-union-case" }, [==[
foreign import "time.h"
local http = import "http"
local test = import "test"
local uv = import "uv"

record Fixture
  raw: foreign tm
end

function test_modes(t: test.Context)
  local mode = http.RedirectMode.follow()
  local container: uv.stdio_container_t = { flags = 0, data = uv.stdio_data_t.fd(-1) }
  case mode
  when follow() then test.assert(container.flags == 0, t:name())
  when error() then test.assert(false)
  when manual() then test.assert(false)
  end
end
]==], true)

-- Same-name user declarations: semantic resolution, not spelling, selects
-- every library-specific rule. Every rule is enabled and none may fire.
fixture("clean", {}, [==[
record Runner
  count: integer
end

function Runner.new(count: integer): Runner
  return { count = count }
end

function Runner:run(): integer
  return self.count
end

function Runner:spawn(): integer
  return self.count
end

function Runner:to_transfer_payload(): string
  return "payload"
end

union Shape
  circle()
end

function Shape.new(): Shape
  return Shape.circle()
end

local function run(n: integer): integer
  return n
end

local function spawn(n: integer): integer
  return n
end

local function finalizable(n: integer): integer
  return n
end

local function ipairs(n: integer): integer
  return n
end

function use(async: Runner, gc: Runner, json: Runner, thread: Runner): integer
  async:run()
  gc:spawn()
  json:to_transfer_payload()
  Shape.new()
  return run(1) + spawn(2) + finalizable(3) + ipairs(4) + thread:run() + Runner(5).count
end
]==])

local PROVIDERS = {
    ["geo.titan"] = [==[
record Point
  x: integer
  y: integer
end

union Status
  ok(code: integer)
  failed(msg: string)
end
]==],
    ["collab.titan"] = [==[
record Item
  id: integer
end

union Kind
  one()
  two()
end
]==],
}

describe("titanc --lint rule configuration", function()
    local function modes(directives)
        local config = assert(linter.configure(directives))
        return config.mode
    end

    it("keeps the documented rule inventory and default severities", function()
        local rules = linter.rules()
        assert.equal(19, #rules)
        local candidates = 0
        for _, rule in ipairs(rules) do
            if rule.candidate then candidates = candidates + 1 end
            assert.equal(rule.severity == "warning" and "emit" or "off", modes({})[rule.id])
        end
        assert.equal(4, candidates)
        -- Adjudicated promotions (doc/implementation/driver.md#lint-rules).
        local defaults = {}
        for _, rule in ipairs(rules) do
            if rule.severity == "warning" then defaults[#defaults + 1] = rule.id end
        end
        assert.same({ "unused-local-binding", "unused-lambda-param", "prefer-record-call-shorthand" }, defaults)
    end)

    it("applies enable, allow and deny strictly left to right", function()
        local rule = "duplicate-record-literal-field"
        assert.equal("off", modes({})[rule])
        assert.equal("emit", modes({ { op = "enable", value = rule } })[rule])
        assert.equal("off", modes({ { op = "enable", value = rule }, { op = "allow", value = rule } })[rule])
        assert.equal("emit", modes({ { op = "allow", value = rule }, { op = "enable", value = rule } })[rule])
        -- deny implies enable; a later allow still wins; enable keeps deny.
        assert.equal("deny", modes({ { op = "deny", value = rule } })[rule])
        assert.equal("off", modes({ { op = "deny", value = rule }, { op = "allow", value = rule } })[rule])
        assert.equal("deny", modes({ { op = "deny", value = rule }, { op = "enable", value = rule } })[rule])
        assert.equal("deny", modes({ { op = "deny", value = rule }, { op = "enable", value = "all" } })[rule])
        -- Severity groups promote only rules that are already emitting.
        local hints = modes({ { op = "deny", value = "hints" } })
        assert.equal("off", hints[rule])
        local enabled = modes({ { op = "enable", value = rule }, { op = "deny", value = "hints" } })
        assert.equal("deny", enabled[rule])
        assert.equal("off", enabled["prefer-const-local"])
        local all = modes({ { op = "enable", value = "all" }, { op = "allow", value = rule },
            { op = "deny", value = "hints" } })
        assert.equal("off", all[rule])
        assert.equal("deny", all["prefer-const-local"])
        for _, item in ipairs(linter.rules()) do
            local denied = modes({ { op = "deny", value = "warnings" } })[item.id]
            assert.equal(item.severity == "warning" and "deny" or "off", denied)
        end
    end)

    it("rejects unknown rules, including rules deferred from v1", function()
        for _, deferred in ipairs({ "boolean-option-condition", "loop-string-concat",
                "unobserved-spawned-task", "ipairs-unwrapped-hole-binder",
                "discarded-transfer-payload" }) do
            local config, err = linter.configure({ { op = "enable", value = deferred } })
            assert.is_nil(config)
            assert.matches("unknown lint rule '" .. deferred .. "'", err, 1, true)
        end
    end)

    it("rejects unknown rules and malformed directives", function()
        local config, err = linter.configure({ { op = "enable", value = "no-such-rule" } })
        assert.is_nil(config)
        assert.matches("unknown lint rule 'no-such-rule' (--lint-enable=no-such-rule)", err, 1, true)
        config, err = linter.configure({ { op = "allow", value = "all" } })
        assert.is_nil(config)
        assert.matches("--lint-allow=all", err, 1, true)
        config, err = linter.configure({ { op = "deny", value = "all" } })
        assert.is_nil(config)
        assert.matches("--lint-deny=all", err, 1, true)
        assert.is_nil((linter.configure({ { op = "silence", value = "x" } })))
    end)

    it("formats human and versioned JSON diagnostics", function()
        local result = { diagnostics = { { file = "a\"b.titan", line = 3, col = 7,
            severity = "hint", rule = "prefer-const-local", message = "x\n'y'", denied = true } } }
        assert.equal("a\"b.titan:3:7: hint[prefer-const-local]: x\n'y'\n", linter.format_human(result))
        assert.equal('{"version":1,"diagnostics":[{"file":"a\\"b.titan","line":3,"col":7,' ..
            '"severity":"hint","rule":"prefer-const-local","message":"x\\n\'y\'","denied":true}]}\n',
            linter.format_json(result))
        assert.equal('{"version":1,"diagnostics":[]}\n', linter.format_json({ diagnostics = {} }))
        assert.equal("", linter.format_human({ diagnostics = {} }))
    end)
end)

-- Apply each advertised fix of the default rules to its fixture text.
local function apply_fixes(text, diagnostics)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    table.sort(diagnostics, function(a, b)
        if a.line ~= b.line then return a.line < b.line end
        return a.col > b.col
    end)
    for _, d in ipairs(diagnostics) do
        local line = lines[d.line]
        if d.rule == "prefer-record-call-shorthand" then
            local prefix = line:sub(1, d.col - 1)
            local stripped = prefix:gsub("%s+$", "")
            assert(stripped:sub(-4) == ".new", line)
            lines[d.line] = stripped:sub(1, -5) .. prefix:sub(#stripped + 1) .. line:sub(d.col)
        else
            local name = assert(d.message:match("'([^']+)'"))
            assert(line:sub(d.col, d.col + #name - 1) == name, line)
            lines[d.line] = line:sub(1, d.col - 1) .. "_" .. line:sub(d.col + #name)
        end
    end
    return table.concat(lines, "\n")
end

describe("driver.lint_modules", function()
    local root, result, errors
    lazy_setup(function()
        local files = {}
        for name, text in pairs(PROVIDERS) do files[name] = text end
        local modules = {}
        for _, item in ipairs(FIXTURES) do
            files[item.file] = item.text
            modules[#modules + 1] = item.name
        end
        root = make_tree(files)
        result, errors = lint(root, modules)
    end)
    lazy_teardown(function()
        if root then remove_tree(root) end
    end)

    it("checks every fixture cleanly", function()
        assert.is_nil(errors, errors and table.concat(errors, "\n"))
        assert.truthy(result)
    end)

    for _, item in ipairs(FIXTURES) do
        local rules = set_of(item.rules)
        local label = #item.rules > 0 and table.concat(item.rules, ", ") or "every rule (no diagnostics)"
        it("reports exactly the marked " .. item.name .. " diagnostics: " .. label, function()
            assert.truthy(result, errors and table.concat(errors, "\n"))
            local expected = marked_hits(item.text, rules)
            if #item.rules > 0 then
                assert.is_true(item.negative or #expected > 0, "fixture lacks a positive")
                assert.same(expected, reported_hits(result, basename(item.file), rules))
            else
                assert.same({}, reported_hits(result, basename(item.file)))
            end
        end)
    end

    it("covers every rule with a positive fixture", function()
        local covered = {}
        for _, item in ipairs(FIXTURES) do
            for rule in item.text:gmatch("%-%-!%s*([%w%-]+)") do covered[rule] = true end
        end
        for _, rule in ipairs(linter.rules()) do
            assert.is_true(covered[rule.id] == true, rule.id)
        end
    end)

    it("sorts diagnostics by file, line, column and rule, and counts severities", function()
        local previous
        local hints, warnings = 0, 0
        for _, d in ipairs(result.diagnostics) do
            if previous then
                local key = { d.file, d.line, d.col, d.rule }
                local before = { previous.file, previous.line, previous.col, previous.rule }
                local ordered = before[1] < key[1] or before[1] == key[1] and (before[2] < key[2] or
                    before[2] == key[2] and (before[3] < key[3] or before[3] == key[3] and before[4] <= key[4]))
                assert.is_true(ordered)
            end
            if d.severity == "hint" then hints = hints + 1 else warnings = warnings + 1 end
            assert.is_false(d.denied)
            previous = d
        end
        assert.equal(hints, result.hint_count)
        assert.equal(warnings, result.warning_count)
        assert.equal(0, result.denied_count)
    end)

    it("re-checks every advertised rename and shorthand fix", function()
        local defaults = { "unused-local-binding", "unused-lambda-param", "prefer-record-call-shorthand" }
        local fixed_files, modules = {}, {}
        for name, text in pairs(PROVIDERS) do fixed_files[name] = text end
        for _, item in ipairs(FIXTURES) do
            if item.name == "unused" or item.name == "unused_hidden" or item.name == "shorthand" then
                local diagnostics = {}
                for _, d in ipairs(result.diagnostics) do
                    if basename(d.file) == basename(item.file) and set_of(defaults)[d.rule] then
                        diagnostics[#diagnostics + 1] = d
                    end
                end
                assert.is_true(#diagnostics > 0)
                fixed_files[item.file] = apply_fixes(item.text, diagnostics)
                modules[#modules + 1] = item.name
            end
        end
        local fixed_root = make_tree(fixed_files)
        local directives = {}
        for _, rule in ipairs(defaults) do directives[#directives + 1] = { op = "enable", value = rule } end
        local fixed, fixed_errors = lint(fixed_root, modules, { rule_directives = directives })
        remove_tree(fixed_root)
        assert.is_nil(fixed_errors, fixed_errors and table.concat(fixed_errors, "\n"))
        assert.same({}, fixed.diagnostics)
    end)

    it("words diagnostics without claims the checked program does not support", function()
        local seen = {}
        for _, d in ipairs(result.diagnostics) do
            seen[d.rule] = true
            if d.rule == "prefer-record-call-shorthand" then
                assert.matches("delete '.new' and keep the rest of the call, including any owner type arguments",
                    d.message, 1, true)
            elseif d.rule == "unmatched-public-test-signature" then
                local suffix = "so 'titanc --test' does not discover it as a test"
                assert.equal(suffix, d.message:sub(-#suffix))
            elseif d.rule == "union-identity-equality" then
                assert.matches("so it is always (%a+);", d.message)
            end
        end
        for _, rule in ipairs({ "prefer-record-call-shorthand", "unmatched-public-test-signature",
                "union-identity-equality" }) do
            assert.is_true(seen[rule] == true, rule)
        end
    end)

    it("reports denied diagnostics and lints only the requested roots", function()
        local denied = assert(lint(root, { "records" },
            { rule_directives = { { op = "deny", value = "dso-closed-union-case" } } }))
        assert.equal(1, #denied.diagnostics)
        assert.equal(1, denied.denied_count)
        assert.equal("dso-closed-union-case", denied.diagnostics[1].rule)
        assert.equal("records.titan", basename(denied.diagnostics[1].file))
        assert.is_true(denied.diagnostics[1].denied)
    end)
end)

describe("driver.lint_modules analysis boundary", function()
    local roots = {}
    local function tree(files)
        local path = make_tree(files)
        roots[#roots + 1] = path
        return path
    end
    after_each(function()
        for _, path in ipairs(roots) do remove_tree(path) end
        roots = {}
    end)

    local function count_closes(body)
        local close = driver.close_resolver_context
        local opened, closed = {}, {}
        local construct = driver.new_resolver_context
        driver.new_resolver_context = function(...)
            local context = construct(...)
            opened[#opened + 1] = context
            return context
        end
        driver.close_resolver_context = function(context, ...)
            closed[#closed + 1] = context
            return close(context, ...)
        end
        local outcome = table.pack(pcall(body))
        driver.close_resolver_context, driver.new_resolver_context = close, construct
        return opened, closed, table.unpack(outcome, 1, outcome.n)
    end

    -- Compare by identity: contexts are large cyclic tables.
    local function assert_all_closed(opened, closed)
        assert.is_true(#opened > 0)
        assert.equal(#opened, #closed)
        local seen = {}
        for _, context in ipairs(closed) do seen[context] = true end
        for _, context in ipairs(opened) do assert.is_true(seen[context] == true) end
    end

    it("never lints a partial tree and closes the resolver on every exit path", function()
        local path = tree({
            ["good.titan"] = "function f(): integer\n  local unused = 1\n  return 2\nend\n",
            ["typed.titan"] = "function f(): integer\n  return \"no\"\nend\n",
            ["broken.titan"] = "function f(\n",
            ["pkg/pkg.titan"] = "function main_part(): integer\n  return 1\nend\n",
            ["pkg/extra.titan"] = "function extra_part(): integer\n  local unused = 1\n  return 2\nend\n",
        })
        for _, case in ipairs({
            { { "good", "typed" }, "type error" },
            { { "broken" }, "syntax error" },
            { { "missing" }, "source module 'missing' not found" },
            { { "titan.json" }, "source module 'titan.json' not found" },
            { { "pkg.extra" }, "belongs to folder module 'pkg'" },
        }) do
            local opened, closed, ok, lint_result, lint_errors = count_closes(function()
                return lint(path, case[1])
            end)
            assert.is_true(ok, lint_result)
            assert.is_nil(lint_result)
            assert.matches(case[2], table.concat(lint_errors, "\n"), 1, true)
            assert_all_closed(opened, closed)
        end

        local opened, closed, ok, lint_result = count_closes(function()
            return lint(path, { "good", "pkg" })
        end)
        assert.is_true(ok)
        assert_all_closed(opened, closed)
        local files = {}
        for _, d in ipairs(lint_result.diagnostics) do files[#files + 1] = basename(d.file) .. ":" .. d.line end
        assert.same({ "good.titan:2", "extra.titan:2" }, files)

        -- An unexpected error inside the linter still closes the resolver.
        local real_lint = linter.lint
        linter.lint = function() error("linter exploded", 0) end
        opened, closed, ok, lint_result = count_closes(function() return lint(path, { "good" }) end)
        linter.lint = real_lint
        assert.is_false(ok)
        assert.equal("linter exploded", lint_result)
        assert_all_closed(opened, closed)
    end)

    it("analyzes afresh on every call and restores the caller's caches", function()
        local unused = "function f(): integer\n  local unused = 1\n  return 2\nend\n"
        local path = tree({ ["fresh.titan"] = unused })
        local other = tree({ ["fresh.titan"] = "function g(): integer\n  return 1\nend\n" })
        local imported, registry = driver.imported, types.registry
        local request = { modules = { "fresh" }, tree = path }
        local first = assert(driver.lint_modules(request))
        local second = assert(driver.lint_modules(request))
        assert.equal(1, #first.diagnostics)
        assert.same(first.diagnostics, second.diagnostics)
        assert.equal(imported, driver.imported)
        assert.equal(registry, types.registry)

        write_file(path .. "/fresh.titan", "function f(\n")
        local broken, broken_errors = driver.lint_modules(request)
        assert.is_nil(broken)
        assert.matches("syntax error", table.concat(broken_errors, "\n"), 1, true)
        assert.equal(imported, driver.imported)
        assert.equal(registry, types.registry)

        write_file(path .. "/fresh.titan",
            "function f(): integer\n  local unused = 1\n  local again = 2\n  return 2\nend\n")
        assert.equal(2, #assert(driver.lint_modules(request)).diagnostics)
        assert.same({}, assert(driver.lint_modules({ modules = { "fresh" }, tree = other })).diagnostics)

        -- Another compiler consumer leaves its own checked `fresh` behind.
        local context = driver.new_resolver_context({ analysis_only = true })
        local loader = driver.defaultloader({}, { context = context, source_roots = { fresh = true },
            source_overrides = { fresh = assert(driver.resolve_source(context, "fresh", path)) } })
        assert.is_true((loader("fresh")))
        assert.is_true(driver.close_loader(loader))
        assert.is_true(driver.close_resolver_context(context))
        local consumer = driver.imported
        assert.truthy(consumer.fresh)
        assert.same({}, assert(driver.lint_modules({ modules = { "fresh" }, tree = other })).diagnostics)
        assert.equal(consumer, driver.imported)
        driver.imported, types.registry = imported, registry
    end)

    it("keeps a live native consumer's caches across browser lints", function()
        local handle = driver.browser_analysis_target(nil)
        if not handle then
            pending("the selected installation has no browser SDK")
            return
        end
        local path = tree({
            ["page.titan"] = "function f(): integer\n  return 1\nend\n",
            ["broken.titan"] = "function f(): integer\n  return \"no\"\nend\n",
        })
        local imported, registry = driver.imported, types.registry
        local native = driver.new_resolver_context({ analysis_only = true })
        local loader = driver.defaultloader({}, { context = native })
        assert.is_true((loader("titan.sqlite3")))
        local consumer, entry = driver.imported, driver.imported["titan.sqlite3"]
        assert.truthy(entry)
        for _, case in ipairs({ { "page", true }, { "broken", false } }) do
            local lint_result, lint_errors = lint(path, { case[1] }, { target = "browser" })
            assert.equal(case[2], lint_result ~= nil, lint_errors and table.concat(lint_errors, "\n"))
            assert.is_true(pcall(driver.assert_target_context, native))
            assert.equal(consumer, driver.imported)
            assert.equal(entry, driver.imported["titan.sqlite3"])
        end
        assert.is_true(driver.close_loader(loader))
        assert.is_true(driver.close_resolver_context(native))

        -- A later browser consumer starts from fresh caches and rejects the
        -- native-only module instead of adopting the native entry.
        local browser = driver.new_resolver_context({ target = "browser", analysis_only = true,
            browser_analysis_target = handle })
        local browser_loader = driver.defaultloader({}, { context = browser })
        assert.is_false((browser_loader("titan.sqlite3")))
        assert.are_not.equal(entry, driver.imported["titan.sqlite3"])
        assert.is_true(driver.close_loader(browser_loader))
        assert.is_true(driver.close_resolver_context(browser))
        driver.imported, types.registry = imported, registry
    end)

    it("validates options and directives before analysis", function()
        local path = tree({ ["good.titan"] = "function f(): integer\n  return 2\nend\n" })
        for _, case in ipairs({
            { { modules = {} }, "at least one module name or test directory is required" },
            { { modules = { "good" }, rule_directives = { { op = "enable", value = "bogus" } } },
                "unknown lint rule 'bogus'" },
            { { modules = { "bad..name" } }, "invalid logical module name 'bad..name'" },
            { { modules = { "good" }, test_excludes = { "x" } }, "test_excludes requires test_dirs" },
            { { modules = { "good" }, native_cli = { { kind = "cflag", value = "-O2" } } },
                "include and define switches" },
            { { modules = { "good" }, target = "native" }, "not a compilation target" },
            { { modules = { "good" }, target = "plan9" }, "unknown target 'plan9'" },
        }) do
            local request = { tree = path }
            for key, value in pairs(case[1]) do request[key] = value end
            local lint_result, lint_errors = driver.lint_modules(request)
            assert.is_nil(lint_result)
            assert.matches(case[2], table.concat(lint_errors, "\n"), 1, true)
        end
    end)

    it("forwards -I and -D switches to C header analysis", function()
        local path = tree({
            ["include/lint_fixture.h"] = "#ifdef LINT_FIXTURE\ntypedef int lint_fixture_t;\n#endif\n",
            ["app.titan"] = 'foreign import "lint_fixture.h"\n\n' ..
                "function width(): integer\n  return foreign lint_fixture_t.sizeof as integer\nend\n",
        })
        local include = path .. "/include"
        local lint_result, lint_errors = lint(path, { "app" },
            { native_cli = { { kind = "include", value = include } } })
        assert.is_nil(lint_result)
        assert.matches("lint_fixture_t", table.concat(lint_errors, "\n"), 1, true)
        lint_result, lint_errors = lint(path, { "app" }, { native_cli = {
            { kind = "include", value = include }, { kind = "define", value = "LINT_FIXTURE" } } })
        assert.is_nil(lint_errors, lint_errors and table.concat(lint_errors, "\n"))
        assert.same({}, lint_result.diagnostics)
    end)

    it("discovers --test-dir roots and honors --test-exclude", function()
        local path = tree({
            ["app/main.titan"] = "function f(): integer\n  local unused = 1\n  return 2\nend\n",
            ["app/tests/foo_test.titan"] = "function g(): integer\n  local unused = 1\n  return 2\nend\n",
            ["app/tests/bar_test.titan"] = "function h(): integer\n  local unused = 1\n  return 2\nend\n",
        })
        local lint_result, lint_errors = lint(path, {}, { test_dirs = { path .. "/app" },
            test_excludes = { "app.tests.bar_test" } })
        assert.is_nil(lint_errors, lint_errors and table.concat(lint_errors, "\n"))
        local files = {}
        for _, d in ipairs(lint_result.diagnostics) do files[#files + 1] = basename(d.file) end
        assert.same({ "foo_test.titan" }, files)
        lint_result, lint_errors = lint(path, { "app.main" }, { test_dirs = { path .. "/app" },
            test_excludes = { "app.tests.bar_test", "app.tests.foo_test" } })
        assert.is_nil(lint_errors, lint_errors and table.concat(lint_errors, "\n"))
        assert.equal("main.titan", basename(lint_result.diagnostics[1].file))
        lint_result, lint_errors = lint(path, {}, { test_dirs = { path .. "/app" },
            test_excludes = { "app.tests.bar_test", "app.tests.foo_test" } })
        assert.is_nil(lint_result)
        assert.matches("no test modules found", table.concat(lint_errors, "\n"), 1, true)
    end)

    it("bails out cleanly when the browser SDK is absent", function()
        local path = tree({ ["good.titan"] = "function f(): integer\n  return 2\nend\n" })
        local empty = tree({ ["placeholder"] = "" })
        local opened, closed, ok, lint_result, lint_errors = count_closes(function()
            return lint(path, { "good" }, { target = "browser", browser_prefix = empty })
        end)
        assert.is_true(ok, lint_result)
        assert.is_nil(lint_result)
        assert.truthy(lint_errors[1])
        assert_all_closed(opened, closed)
    end)

    it("lints for --target browser with the browser analysis SDK", function()
        if not driver.browser_analysis_target(nil) then
            pending("the selected installation has no browser SDK")
            return
        end
        local path = tree({
            ["page.titan"] = "local strings = import \"titan.string\"\n\n" ..
                "function f(): integer\n  local unused = 1\n  return #strings.upper(\"x\")\nend\n",
            ["page.browser.titan"] = "local strings = import \"titan.string\"\n\n" ..
                "function f(): integer\n  local unused_on_browser = 1\n  return #strings.upper(\"x\")\nend\n",
        })
        local lint_result, lint_errors = lint(path, { "page" }, { target = "browser" })
        assert.is_nil(lint_errors, lint_errors and table.concat(lint_errors, "\n"))
        local found = {}
        for _, d in ipairs(lint_result.diagnostics) do
            found[#found + 1] = basename(d.file) .. ":" .. d.line .. ":" .. d.rule
        end
        assert.same({ "page.browser.titan:1:stdlib-import-spelling",
            "page.browser.titan:4:unused-local-binding" }, found)
    end)

    it("checks the '_' rename interval in constant time per binding", function()
        -- `depth` nested blocks holding `per_level` bindings each. When the
        -- innermost block writes '_', every binding's interval contains it.
        local function nested(depth, per_level, use_inside)
            local lines, count = { "function deep(): integer", "  local _ = 0" }, 0
            for _ = 1, depth do
                lines[#lines + 1] = "do"
                for _ = 1, per_level do
                    count = count + 1
                    lines[#lines + 1] = "local unused" .. count .. " = " .. count
                end
            end
            lines[#lines + 1] = use_inside and "_ = _ + 1" or "local x = 1"
            for _ = 1, depth do lines[#lines + 1] = "end" end
            lines[#lines + 1] = "  return _"
            lines[#lines + 1] = "end"
            return table.concat(lines, "\n") .. "\n"
        end
        local path = tree({
            ["hidden.titan"] = nested(32, 32, true),
            ["deep.titan"] = nested(32, 32, false),
            ["shallow.titan"] = nested(4, 256, false),
            ["small.titan"] = nested(4, 32, false),
        })
        local directives = { { op = "enable", value = "unused-local-binding" } }
        local config = assert(linter.configure(directives))
        -- Keep the checked units the driver hands to the linter.
        local real_lint, units_by_name = linter.lint, {}
        linter.lint = function(units, ...)
            for _, unit in ipairs(units) do units_by_name[unit.modname] = unit end
            return real_lint(units, ...)
        end
        local ok, lint_result, lint_errors = pcall(lint, path, { "hidden", "deep", "shallow", "small" },
            { rule_directives = directives })
        linter.lint = real_lint
        assert.is_true(ok, lint_result)
        assert.is_nil(lint_errors, lint_errors and table.concat(lint_errors, "\n"))
        local per_file = {}
        for _, d in ipairs(lint_result.diagnostics) do
            per_file[basename(d.file)] = (per_file[basename(d.file)] or 0) + 1
        end
        assert.is_nil(per_file["hidden.titan"])
        assert.equal(1025, per_file["deep.titan"])
        assert.equal(1025, per_file["shallow.titan"])
        assert.equal(129, per_file["small.titan"])
        local function cost(name)
            local units = { units_by_name[name] }
            local best = math.huge
            for _ = 1, 3 do
                local start = os.clock()
                for _ = 1, 10 do linter.lint(units, config) end
                best = math.min(best, os.clock() - start)
            end
            return math.max(best, 1e-6)
        end
        cost("small")
        -- Equal binding counts at depths 32 and 4: an ancestor walk per
        -- binding or per '_' would cost about eight times as much.
        local depth_ratio = cost("deep") / cost("shallow")
        assert.is_true(depth_ratio < 3, "depth cost ratio " .. depth_ratio)
        -- Eight times the bindings: a rescan of each binding's tail would
        -- cost about 64 times as much.
        local size_ratio = cost("shallow") / cost("small")
        assert.is_true(size_ratio < 24, "size cost ratio " .. size_ratio)
    end)
end)

describe("titanc --lint command line", function()
    local LUA = installed_prefix.active() .. "/bin/lua" .. (platform.windows and ".exe" or "")
    local roots = {}
    after_each(function()
        for _, path in ipairs(roots) do remove_tree(path) end
        roots = {}
    end)

    local function run(arguments, merge, prelude)
        local settings = { LUA_PATH_5_5 = package.path, LUA_CPATH_5_5 = package.cpath,
            TITAN_PROBE_CACHE_DISABLE = "1" }
        local argv, options = {}, { stderr_to_stdout = merge ~= false }
        if platform.windows then
            options.env = settings
            argv[1] = LUA
        else
            argv[1] = "env"
            for name, value in pairs(settings) do argv[#argv + 1] = name .. "=" .. value end
            argv[#argv + 1] = LUA
        end
        if prelude then
            argv[#argv + 1] = "-e"
            argv[#argv + 1] = prelude
        end
        argv[#argv + 1] = "titanc"
        for _, argument in ipairs(arguments) do argv[#argv + 1] = argument end
        local outcome = compiler_io.new_sync():run(argv, options)
        assert.is_true(outcome.started, outcome.diagnostic)
        return outcome.status, (outcome.output or ""):gsub("\r\n", "\n")
    end

    it("rejects build, link and output switches", function()
        for _, case in ipairs({
            { { "-o", "out" }, "-o/--output" }, { { "--exe", "app" }, "--exe" },
            { { "-c" }, "-c/--compile-only" }, { { "--static" }, "--static" },
            { { "--source-first" }, "--source-first" }, { { "--incremental" }, "--incremental" },
            { { "--no-source-records" }, "--no-source-records" }, { { "--coverage" }, "--coverage" },
            { { "--coverage-module", "x" }, "--coverage" }, { { "--c-source", "x.c" }, "--c-source" },
            { { "-X", "x.o" }, "-X/--extra-object" }, { { "-l", "m" }, "-l/--link" },
            { { "-L", "lib" }, "-L/--library-dir" }, { { "--cflag=-O2" }, "--cflag" },
            { { "--ldflag=-s" }, "--ldflag" }, { { "--c-parts", "2" }, "--c-parts" },
            { { "-j", "2" }, "-j/--jobs" }, { { "--pretty-print" }, "--pretty-print" },
            { { "--no-line-directives" }, "--no-line-directives" },
            { { "--no-uv-bootstrap" }, "--no-uv-bootstrap" }, { { "--print-ast" }, "--print-ast" },
            { { "--print-root" }, "--print-root" },
        }) do
            local arguments = { "--lint", "m" }
            for _, argument in ipairs(case[1]) do arguments[#arguments + 1] = argument end
            local status, output = run(arguments)
            assert.equal(1, status, output)
            assert.matches("--lint cannot be combined with " .. case[2], output, 1, true)
        end
        for _, case in ipairs({
            { { "--lint-enable=all", "m" }, "require --lint" },
            { { "--lint", "--lint-format=xml", "m" }, "--lint-format must be human or json" },
            { { "--lint", "--test-dir", "t", "m" }, "--test-dir and --test-exclude require --test" },
            { { "--lint", "--test", "--test-exclude", "x", "m" }, "--test-exclude requires --test-dir" },
            { { "--lint", "--lint-deny=bogus", "m" }, "unknown lint rule 'bogus'" },
            { { "--lint" }, "at least one module name or test directory is required" },
        }) do
            local status, output = run(case[1])
            assert.equal(1, status, output)
            assert.matches(case[2], output, 1, true)
        end
    end)

    it("prints diagnostics, exits 0 unless a rule is denied, and emits JSON", function()
        local path = make_tree({
            ["app.titan"] = "function f(): integer\n  local unused = 1\n  return 2\nend\n",
            ["typed.titan"] = "function f(): integer\n  return \"no\"\nend\n",
        })
        roots[#roots + 1] = path
        local status, output = run({ "--lint", "-t", path, "app" })
        assert.equal(0, status, output)
        assert.matches("app.titan:2:9: warning[unused-local-binding]: local 'unused' is never used", output, 1, true)

        status, output = run({ "--lint", "-t", path, "--lint-deny=unused-local-binding",
            "--lint-format=json", "app" }, false)
        assert.equal(1, status, output)
        assert.matches('^{"version":1,"diagnostics":%[{"file":"[^"]*app%.titan","line":2,"col":9,' ..
            '"severity":"warning","rule":"unused%-local%-binding","message":"[^"]*","denied":true}%]}\n$', output)

        status, output = run({ "--lint", "-t", path, "--lint-deny=warnings",
            "--lint-allow=unused-local-binding", "app" })
        assert.equal(0, status, output)
        assert.equal("", output)

        status, output = run({ "--lint", "-t", path, "app", "typed" })
        assert.equal(1, status, output)
        assert.matches("type error", output, 1, true)
        assert.is_nil(output:find("[unused-local-binding]", 1, true))
    end)

    it("forwards -I and -D and discovers --test --test-dir roots", function()
        local path = make_tree({
            ["include/lint_fixture.h"] = "#ifdef LINT_FIXTURE\ntypedef int lint_fixture_t;\n#endif\n",
            ["app/app.titan"] = 'foreign import "lint_fixture.h"\n\n' ..
                "function width(): integer\n  return foreign lint_fixture_t.sizeof as integer\nend\n",
            ["app/tests/one_test.titan"] = "function g(): integer\n  local unused = 1\n  return 2\nend\n",
            ["app/tests/two_test.titan"] = "function h(): integer\n  local unused = 1\n  return 2\nend\n",
        })
        roots[#roots + 1] = path
        local status, output = run({ "--lint", "-t", path, "-I", path .. "/include",
            "-D", "LINT_FIXTURE", "--lint-enable=all", "--test", "--test-dir", path .. "/app",
            "--test-exclude", "app.tests.two_test", "app" })
        assert.equal(0, status, output)
        assert.matches("one_test.titan:2:9: warning[unused-local-binding]", output, 1, true)
        assert.is_nil(output:find("two_test", 1, true))
        status, output = run({ "--lint", "-t", path, "-I", path .. "/include", "app" })
        assert.equal(1, status, output)
        assert.matches("lint_fixture_t", output, 1, true)
    end)

    it("loads the linter only for --lint", function()
        local trap = 'package.preload["titan-compiler.linter"] = function() error("linter loaded", 0) end'
        local status, output = run({}, true, trap)
        assert.equal(1, status, output)
        assert.matches("at least one module name is required", output, 1, true)
        assert.is_nil(output:find("linter loaded", 1, true))
        status, output = run({ "--lint", "m" }, true, trap)
        assert.equal(1, status, output)
        assert.matches("linter loaded", output, 1, true)
    end)
end)
