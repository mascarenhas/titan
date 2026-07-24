local h = require "spec.support.helpers"

local probe_session

local function run_checker(code)
    return h.run_checker(code, probe_session)
end

local function with_header(contents, fn)
    local header = os.tmpname() .. ".h"
    local file = assert(io.open(header, "w"))
    file:write(contents)
    file:close()

    local results = { pcall(fn, header) }
    os.remove(header)
    if not results[1] then
        error(results[2], 0)
    end
    table.remove(results, 1)
    return table.unpack(results)
end

describe("named file-scope C tags", function()
    setup(function()
        probe_session = h.new_checker_probe_session()
    end)

    teardown(function()
        h.close_checker_probe_session(probe_session)
        probe_session = nil
    end)

    it("publishes complete struct and union tags as direct type aliases",
    function()
        with_header([[
            struct Item { int value; };
            union Cell { int count; double number; };
            static struct Item make_item(void) {
                struct Item item = { 7 };
                return item;
            }
        ]], function(header)
            local ok, err, ast = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function item(): c.Item
                    return c.make_item()
                end

                local function read_integer(cell: c.Cell): integer
                    return cell.count as integer
                end
            ]])
            assert.truthy(ok, err)

            local cmod = ast[1]._type
            assert.equal("Type.CStruct",
                cmod.type_members.Item._tag)
            assert.equal("Item",
                cmod.type_members.Item.tagname)
            assert.equal("Type.CUnion",
                cmod.type_members.Cell._tag)
            assert.equal("Cell",
                cmod.type_members.Cell.tagname)
        end)
    end)

    for _, source in ipairs({
        [[
            typedef long Item;
            struct Item { int value; };
        ]],
        [[
            struct Item { int value; };
            typedef long Item;
        ]],
        [[
            typedef double _Complex Item;
            struct Item { int value; };
        ]],
    }) do
        it("gives a syntactic same-name typedef precedence", function()
            with_header(source, function(header)
                local ok, err, ast = run_checker([[
                    local c = foreign import "]] .. header .. [["
                ]])
                assert.truthy(ok, err)

                local item = ast[1]._type.type_members.Item
                if source:match("_Complex", 1, true) then
                    assert.is_nil(item)
                else
                    assert.equal("Type.CTypedef", item._tag)
                end
            end)
        end)
    end

    it("publishes differently named forwards and file-scope pointer refs",
    function()
        with_header([[
            typedef struct Forward ForwardRef;
            struct PointerOnly *pointer_value;
        ]], function(header)
            local ok, err, ast = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function forward(p: *c.Forward): *c.ForwardRef
                    return p
                end

                local function pointer(): *c.PointerOnly
                    return c.pointer_value
                end
            ]])
            assert.truthy(ok, err)

            local aliases = ast[1]._type.type_members
            assert.equal("Type.CStruct", aliases.Forward._tag)
            assert.equal("Type.CTypedef", aliases.ForwardRef._tag)
            assert.equal(aliases.Forward,
                aliases.ForwardRef.target)
            assert.equal("Type.CStruct", aliases.PointerOnly._tag)
        end)
    end)

    it("excludes anonymous, enum, and prototype-only tags", function()
        with_header([[
            struct { int value; } anonymous_value;
            enum Choice { CHOICE_A };
            extern int consume(struct PrototypeOnly *value);
        ]], function(header)
            local ok, err, ast = run_checker([[
                local c = foreign import "]] .. header .. [["
            ]])
            assert.truthy(ok, err)

            local aliases = ast[1]._type.type_members
            assert.is_nil(aliases.Choice)
            assert.is_nil(aliases.PrototypeOnly)
        end)
    end)

    it("keeps ordinary values ahead of the separate tag namespace", function()
        with_header([[
            struct stat { int new; int value; };
            static int stat(void) { return 9; }
            static struct stat make_stat(void) {
                struct stat value = { 4, 5 };
                return value;
            }
        ]], function(header)
            local ok, err, ast = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function call_stat(): integer
                    return c.stat() as integer
                end

                local function read_field(): integer
                    local result: c.stat = c.make_stat()
                    return result.new as integer
                end
            ]])
            assert.truthy(ok, err)
            assert.equal("Type.CStruct",
                ast[1]._type.type_members.stat._tag)
            assert.equal("Type.ModuleMember",
                ast[1]._type.members.stat._tag)
        end)
    end)

    it("keeps an external function ahead of the separate tag namespace",
    function()
        with_header([[
            struct external_stat { int value; };
            extern int external_stat(void);
        ]], function(header)
            local ok, err, ast = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function call_external_stat(): integer
                    return c.external_stat() as integer
                end
            ]])
            assert.truthy(ok, err)
            assert.equal("Type.CStruct",
                ast[1]._type.type_members.external_stat._tag)
            assert.equal("Type.ModuleMember",
                ast[1]._type.members.external_stat._tag)
        end)
    end)

    it("diagnoses pseudo-members hidden by an ordinary collision", function()
        with_header([[
            struct stat { int value; };
            static int stat(void) { return 9; }
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function bad()
                    local result = c.stat.new()
                end
            ]])
            assert.falsy(ok)
            assert.matches(
                "C type pseudo%-member 'stat%.new' is unavailable",
                err)
        end)
    end)

    it("distinguishes collided scalar names from real aggregate fields",
    function()
        with_header([[
            struct object_name { int new; int new_array; int alignof; };
            static struct object_name object_name = { 3, 5, 7 };

            struct int_name { int value; };
            static int int_name = 7;

            struct enum_name { int value; };
            enum { enum_name = 11 };

            struct macro_name { int value; };
            #define macro_name 13
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function real_fields(): integer
                    return c.object_name.new as integer
                        + c.object_name.new_array as integer
                        + c.object_name.alignof as integer
                end
            ]])
            assert.truthy(ok, err)

            for _, collided in ipairs({
                { expression = "c.int_name.new()",
                  diagnostic = "int_name%.new" },
                { expression = "c.int_name.new_array(1)",
                  diagnostic = "int_name%.new_array" },
                { expression = "c.enum_name.sizeof",
                  diagnostic = "enum_name%.sizeof" },
                { expression = "c.macro_name.alignof",
                  diagnostic = "macro_name%.alignof" },
            }) do
                ok, err = run_checker([[
                    local c = foreign import "]] .. header .. [["
                    local function bad()
                        local result = ]] .. collided.expression
                    .. "\n                    end\n")
                assert.falsy(ok)
                assert.matches(
                    "C type pseudo%-member '"
                    .. collided.diagnostic
                    .. "' is unavailable",
                    err)
            end
        end)
    end)

    it("allows pointer-only use of an incomplete named tag", function()
        with_header([[
            struct Forward;
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function identity(
                    pointer: *c.Forward): *c.Forward
                    return pointer
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    for _, use in ipairs({
        {
            name = "parameter",
            code = [[
                local function bad(item: c.Forward)
                end
            ]],
            diagnostic = "parameter 'item'",
        },
        {
            name = "return",
            code = [[
                local function bad(): c.Forward
                    return c.impossible()
                end
            ]],
            diagnostic = "return type 1",
        },
        {
            name = "initialized local",
            code = [[
                local function bad()
                    local item: c.Forward = c.impossible()
                end
            ]],
            diagnostic = "declaration of local variable 'item'",
        },
        {
            name = "cast target",
            code = [[
                local function bad(pointer: *c.Forward)
                    local item = pointer as c.Forward
                end
            ]],
            diagnostic = "by%-value C cast target",
        },
        {
            name = "field access",
            code = [[
                local function bad(pointer: *c.Forward): integer
                    return pointer.count as integer
                end
            ]],
            diagnostic = "field 'count' not found in C type",
        },
        {
            name = "sizeof",
            code = [[
                local item_size = c.Forward.sizeof
            ]],
            diagnostic = "C pseudo%-member '%.sizeof'",
        },
        {
            name = "alignof",
            code = [[
                local item_alignment = c.Forward.alignof
            ]],
            diagnostic = "C pseudo%-member '%.alignof'",
        },
        {
            name = "allocation",
            code = [[
                local function bad()
                    local item = c.Forward.new()
                end
            ]],
            diagnostic = "cannot allocate incomplete C struct",
        },
    }) do
        it("rejects incomplete tag use in a " .. use.name .. " sink",
        function()
            with_header([[
                struct Forward;
                extern struct Forward impossible(void);
            ]], function(header)
                local ok, err = run_checker(
                    'local c = foreign import "' .. header .. '"\n'
                    .. use.code)
                assert.falsy(ok)
                assert.matches(use.diagnostic, err)
                assert.matches(
                    "incomplete or not yet visible", err, 1, true)
            end)
        end)
    end

    it("keeps later completion hidden from an earlier module variable",
    function()
        with_header([[
            struct Shared;
            extern struct Shared make_shared(void);
        ]], function(forward_header)
            with_header([[
                struct Shared { int count; };
            ]], function(definition_header)
                local ok, err = run_checker([[
                    local before = foreign import "]]
                    .. forward_header .. [["
                    local item: before.Shared = before.make_shared()
                    local after = foreign import "]]
                    .. definition_header .. [["
                ]])
                assert.falsy(ok)
                assert.matches(
                    "declaration of module variable 'item'", err)
                assert.matches(
                    "incomplete or not yet visible", err, 1, true)
            end)
        end)
    end)

    for _, member in ipairs({ "sizeof", "alignof" }) do
        it("keeps later completion hidden from an earlier ." .. member,
        function()
            with_header([[
                struct Shared;
            ]], function(forward_header)
                with_header([[
                    struct Shared { int count; };
                ]], function(definition_header)
                    local ok, err = run_checker(
                        'local before = foreign import "'
                        .. forward_header .. '"\n'
                        .. "local metric = before.Shared."
                        .. member .. "\n"
                        .. 'local after = foreign import "'
                        .. definition_header .. '"\n')
                    assert.falsy(ok)
                    assert.matches(
                        "C pseudo%-member '%." .. member .. "'", err)
                    assert.matches(
                        "incomplete or not yet visible", err, 1, true)
                end)
            end)
        end)
    end

    it("completes a prior imported tag in place", function()
        with_header([[
            struct Shared;
        ]], function(forward_header)
            with_header([[
                struct Shared { int count; };
                static struct Shared make_shared(void) {
                    struct Shared item = { 12 };
                    return item;
                }
            ]], function(definition_header)
                local ok, err, ast = run_checker([[
                    local before = foreign import "]] .. forward_header .. [["
                    local after = foreign import "]] .. definition_header .. [["

                    local function read(): integer
                        local item: before.Shared = after.make_shared()
                        return item.count as integer
                    end
                ]])
                assert.truthy(ok, err)
                assert.equal(ast[1]._type.type_members.Shared,
                    ast[2]._type.type_members.Shared)
                assert.is_true(
                    ast[1]._type.type_members.Shared.complete)
            end)
        end)
    end)

    it("binds prototype references to visible file-scope tags", function()
        with_header([[
            struct SameHeader;
            extern int consume_same(
                struct SameHeader *left,
                struct SameHeader *right);
        ]], function(same_header)
            with_header([[
                struct PriorImport;
            ]], function(prior_header)
                with_header([[
                    extern int consume_prior(
                        struct PriorImport *left,
                        struct PriorImport *right);
                ]], function(consumer_header)
                    local ok, err, ast = run_checker([[
                        local same = foreign import "]]
                        .. same_header .. [["
                        local prior = foreign import "]]
                        .. prior_header .. [["
                        local consumer = foreign import "]]
                        .. consumer_header .. [["
                    ]])
                    assert.truthy(ok, err)

                    local same_type =
                        ast[1]._type.type_members.SameHeader
                    local same_fn =
                        ast[1]._type.members.consume_same.type
                    assert.equal(same_type,
                        same_fn.params[1].pointee)
                    assert.equal(same_type,
                        same_fn.params[2].pointee)

                    local prior_type =
                        ast[2]._type.type_members.PriorImport
                    local prior_fn =
                        ast[3]._type.members.consume_prior.type
                    assert.equal(prior_type,
                        prior_fn.params[1].pointee)
                    assert.equal(prior_type,
                        prior_fn.params[2].pointee)
                end)
            end)
        end)
    end)

    it("keeps repeated prototype-local tags distinct from later file tags",
    function()
        with_header([[
            extern int consume_later(
                struct Later *left,
                struct Later *right);
        ]], function(consumer_header)
            with_header([[
                struct Later { int value; };
            ]], function(later_header)
                local ok, err, ast = run_checker([[
                    local consumer = foreign import "]]
                    .. consumer_header .. [["
                    local later = foreign import "]]
                    .. later_header .. [["
                ]])
                assert.truthy(ok, err)

                local consume =
                    ast[1]._type.members.consume_later.type
                local local_tag = consume.params[1].pointee
                assert.equal(local_tag,
                    consume.params[2].pointee)
                assert.not_equal(local_tag,
                    ast[2]._type.type_members.Later)
            end)
        end)
    end)

    it("rejects a wrong-kind prototype reference across imports", function()
        with_header([[
            struct Shared;
        ]], function(struct_header)
            with_header([[
                extern void consume(union Shared *value);
            ]], function(union_header)
                local ok, err = run_checker([[
                    local first = foreign import "]] .. struct_header .. [["
                    local second = foreign import "]] .. union_header .. [["
                ]])
                assert.falsy(ok)
                assert.matches(
                    "conflicting C tag kinds for 'Shared'", err, 1, true)
                assert.matches(struct_header, err, 1, true)
                assert.matches(union_header, err, 1, true)
                assert.matches("struct", err, 1, true)
                assert.matches("union", err, 1, true)
            end)
        end)
    end)

    it("does not leak aggregate-member callback prototype tags", function()
        with_header([[
            struct Callbacks {
                void (*one)(struct Local *);
                void (*two)(union Local *);
            };
        ]], function(header)
            local ok, err, ast = run_checker([[
                local c = foreign import "]] .. header .. [["
            ]])
            assert.truthy(ok, err)
            local cmod = ast[1]._type
            assert.equal("Type.CStruct",
                cmod.type_members.Callbacks._tag)
            assert.is_nil(cmod.type_members.Local)
            assert.is_nil(cmod.members.Local)
        end)
    end)

    it("retains sizeof and alignof for a complete FAM struct", function()
        with_header([[
            struct Packet {
                int length;
                char data[];
            };
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["
                local packet_size = c.Packet.sizeof
                local packet_alignment = c.Packet.alignof
            ]])
            assert.truthy(ok, err)
        end)
    end)

end)
