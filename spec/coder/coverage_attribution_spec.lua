local assert = require "luassert"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local driver = require "titan-compiler.driver"
local lines = require "titan-compiler.coverage_lines"
local h = require "spec.support.helpers"

local MODULE, FILENAME = "coverage_attribution", "coverage_attribution.titan"
local SOURCE = [[local initial = 11
function choose(flag: boolean): integer
  local text = "one" .. "two" .. "three"
  if flag then
    return initial + #text
  end
  return 30
end
function uncalled(): integer
  return 99
end
function make(): function(): integer
  return function(): integer
    return 17
  end
end
do
  initial = 12
end
]]

local function checked(source, filename)
    h.reset()
    filename = filename or FILENAME
    local ast, parse_err = h.parse(source, filename)
    assert.truthy(ast, parse_err)
    local _, errors = checker.check(MODULE, ast, source, filename)
    assert.equal(0, #errors, table.concat(errors, "\n"))
    return ast
end

local function generate(options, policy, source)
    local ast = checked(source or SOURCE)
    return coder.generate(MODULE, ast, {}, driver.TITAN_ABI_VERSION,
        policy, options)
end

local function locations(code)
    local result, filename, number = {}, nil, nil
    for line in (code .. "\n"):gmatch("([^\n]*)\n") do
        local anchor, owner = line:match('^#line (%d+) "([^"]+)"$')
        if anchor then
            number, filename = tonumber(anchor), owner
        else
            result[#result + 1] = { text = line, filename = filename, line = number }
            if number then number = number + 1 end
        end
    end
    return result
end

describe("coverage source ownership in generated C", function()
    it("preserves authored directive spacing until coverage conversion", function()
        local authored = '#line 40 "authored.h"\n\nint value = 7;\n'
        local strategy = {
            read_file = function() return authored end,
            write_file = function(_, _, contents) authored = contents; return true end,
        }
        assert.truthy(driver.format_generated_file("authored.c", false, false,
            strategy, true))
        assert.equal('#line 40 "authored.h"\n\nint value = 7;\n', authored)
        assert.truthy(driver.format_generated_file("authored.c", false, false,
            strategy, false))
        assert.equal('#line 40 "authored.h"\nint value = 7;\n', authored)
    end)

    it("leaves ordinary code generation unchanged and resets its policy", function()
        local before = generate()
        local covered = generate({ coverage = true })
        assert.truthy(covered:find("// TITAN_COVERAGE_BEGIN", 1, true))
        assert.is_nil(covered:find("#line ", 1, true))
        assert.equal(before, generate())
        assert.equal(before, generate({ coverage = false }))
    end)

    it("retains only selected LLVM coverage native lambda definitions", function()
        local before = generate()
        local llvm = generate({ coverage = true, coverage_backend = "llvm-gcov" })
        assert.matches("static __attribute__((used))", llvm, 1, true)
        assert.is_nil(generate({ coverage = true }):find("__attribute__((used))", 1, true))
        assert.is_nil(generate({ coverage = false, coverage_backend = "llvm-gcov" }):find("__attribute__((used))", 1, true))
        assert.equal(before, generate())
        -- Entry adapters and declaration prototypes are generated machinery;
        -- only the native body that owns Titan source regions is retained.
        local count = 0
        for signature in llvm:gmatch("static __attribute__%(%(used%)%)[^\n]+") do
            assert.matches("_lambda_", signature, 1, true)
            assert.is_nil(signature:find("_lua", 1, true))
            assert.is_nil(signature:find("_strict", 1, true))
            assert.is_nil(signature:find(";", 1, true))
            count = count + 1
        end
        assert.equal(1, count)
    end)

    it("retains nested lambda bodies created only in constant dead arms", function()
        local source = [[function never()
  if false then
    local first = function(): integer return 17 end
  end
  while false do
    local second = function(): function(): integer
      return function(): integer return 23 end
    end
  end
end
]]
        local llvm = generate({ coverage = true, coverage_backend = "llvm-gcov" }, nil, source)
        local retained = 0
        for _ in llvm:gmatch("static __attribute__%(%(used%)%)") do retained = retained + 1 end
        assert.equal(3, retained)
        local converted, err, anchors = lines.convert(llvm, "coverage_attribution.c")
        assert.truthy(converted, err)
        for _, number in ipairs({ 3, 6, 7 }) do
            assert.is_true(anchors[FILENAME][number], "missing authored lambda line " .. number)
        end
    end)

    it("rejects disabled line directives for Titan-source coverage", function()
        assert.has_error(function() generate({ coverage = true }, false) end,
            "Titan-source coverage requires line directives")
        assert.is_nil(generate(nil, false):find("#line ", 1, true))
    end)

    it("retains user initializers, uncalled functions and lambda bodies", function()
        local code, err, anchors = lines.convert(generate({ coverage = true }),
            "coverage_attribution.c")
        assert.truthy(code, err)
        local source_anchors = anchors[FILENAME]
        for _, line in ipairs({ 1, 3, 4, 5, 7, 10, 13, 14, 18 }) do
            assert.is_true(source_anchors[line], "missing source line " .. line)
        end
        assert.is_nil(source_anchors[2], "function declaration is generated setup")
        assert.is_nil(source_anchors[9], "uncalled declaration is generated setup")
        assert.is_nil(source_anchors[17], "initializer block braces are generated")
    end)

    it("attributes wrappers, signatures, prologues and epilogues to generated C", function()
        local code, err = lines.convert(generate({ coverage = true }),
            "coverage_attribution.c")
        assert.truthy(code, err)
        local prologues, wrappers, bodies = 0, 0, 0
        for _, location in ipairs(locations(code)) do
            if location.text:find("StkId _base = L->top.p;", 1, true) then
                assert.equal("coverage_attribution.c", location.filename)
                prologues = prologues + 1
            elseif location.text:find("static int", 1, true)
                and location.text:find("lua_State *L", 1, true) then
                assert.equal("coverage_attribution.c", location.filename)
                wrappers = wrappers + 1
            elseif location.text:match("= 99;") then
                assert.equal(FILENAME, location.filename)
                assert.equal(10, location.line)
                bodies = bodies + 1
            end
        end
        assert.is_true(prologues >= 4)
        assert.is_true(wrappers >= 4)
        assert.equal(1, bodies)
    end)

    it("keeps every multiline expansion on explicit source anchors", function()
        local code, err, anchors = lines.convert(generate({ coverage = true }),
            "coverage_attribution.c")
        assert.truthy(code, err)
        for _, location in ipairs(locations(code)) do
            if location.filename == FILENAME and location.text:find("[^ \t]") then
                assert.is_true(anchors[FILENAME][location.line],
                    "expansion drifted to line " .. location.line .. ": " .. location.text)
            end
        end
    end)

    it("excludes synthesized constructors while preserving custom constructors", function()
        local code, err, anchors = lines.convert(generate({ coverage = true }, nil,
            [[record Shape
  x: integer
end
record Custom
  x: integer
end
function Custom.new(x: integer): Custom
  return { x = x }
end
function shape(): Shape
  return Shape(4)
end
]]), "coverage_attribution.c")
        assert.truthy(code, err)
        assert.is_nil(anchors[FILENAME][1])
        assert.is_nil(anchors[FILENAME][4])
        assert.is_true(anchors[FILENAME][8])
        assert.is_true(anchors[FILENAME][11])
    end)

    it("outlines source foreign bodies for coverage and restores normal inlining", function()
        local ast = checked([[foreign function plus(input: int): int
  return input + 1
end
function use(input: integer): integer
  return plus(input)
end
]])
        local ordinary = coder.generate_foreign_header(MODULE, ast)
        assert.truthy(ordinary:find("static inline", 1, true))
        coder.prepare_coverage(ast, true)
        local header = coder.generate_foreign_header(MODULE, ast)
        assert.is_nil(header:find("static inline", 1, true))
        assert.is_nil(header:find("TITAN_COVERAGE_", 1, true))
        local generated = coder.generate(MODULE, ast, {}, driver.TITAN_ABI_VERSION,
            true, { coverage = true })
        local code, err, anchors = lines.convert(generated, "coverage_attribution.c")
        assert.truthy(code, err)
        assert.is_true(anchors[FILENAME][2])
        coder.prepare_coverage(ast, false)
        local restored = coder.generate_foreign_header(MODULE, ast)
        assert.equal(ordinary, restored)
        assert.is_nil(restored:find("TITAN_COVERAGE_", 1, true))
    end)

    it("anchors foreign elseif and until decisions independently of their bodies", function()
        local source = [[foreign function decisions(input: int): int
  if input == 1 then
    return 10
  elseif input == 2 then
    return 20
  end
  repeat
    input = input - 1
  until input == 0
  return input
end
]]
        local ordinary = generate(nil, nil, source)
        local code, err, anchors = lines.convert(generate({ coverage = true }, nil, source),
            "coverage_attribution.c")
        assert.truthy(code, err)
        for _, line in ipairs({ 2, 3, 4, 5, 8, 9, 10 }) do
            assert.is_true(anchors[FILENAME][line], "missing foreign decision/body line " .. line)
        end
        assert.is_nil(anchors[FILENAME][7], "constant C repeat backedge is generated scaffolding")
        assert.equal(ordinary, generate(nil, nil, source))
        assert.equal(ordinary, generate({ coverage = false }, nil, source))
    end)

    it("keeps catch and deferred user bodies while excluding protected setup", function()
        local code, err, anchors = lines.convert(generate({ coverage = true }, nil,
            [[local count = 0
local function update()
  count = count + 1
end
function exercise(fail: boolean): integer
  defer update()
  if fail then raise "failed" end
  return 1
catch
  return 2
end
]]), "coverage_attribution.c")
        assert.truthy(code, err)
        for _, line in ipairs({ 1, 3, 6, 7, 8, 10 }) do
            assert.is_true(anchors[FILENAME][line], "missing body line " .. line)
        end
        assert.is_nil(anchors[FILENAME][5])
        assert.is_nil(anchors[FILENAME][9])
        for _, location in ipairs(locations(code)) do
            if location.text:find("setjmp", 1, true) then
                assert.equal("coverage_attribution.c", location.filename)
            end
        end
    end)

    it("retains every contributor's independent filename and uncalled body", function()
        h.reset()
        local source = "function left(): integer\n  return 3\nend\n"
        local ast = assert(h.parse(source, "folder/folder.titan"))
        local extra = assert(h.parse("function right(): integer\n  return 7\nend\n",
            "folder/extra.titan"))
        for _, node in ipairs(extra) do ast[#ast + 1] = node end
        local _, errors = checker.check(MODULE, ast, source, "folder/folder.titan")
        assert.equal(0, #errors, table.concat(errors, "\n"))
        local generated = coder.generate(MODULE, ast, {}, driver.TITAN_ABI_VERSION,
            true, { coverage = true })
        local code, err, anchors = lines.convert(generated, "coverage_attribution.c")
        assert.truthy(code, err)
        assert.same({ [2] = true }, anchors["folder/folder.titan"])
        assert.same({ [2] = true }, anchors["folder/extra.titan"])
    end)
end)
