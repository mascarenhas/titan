local h = require "spec.support.helpers"

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

describe("named C tag code generation", function()
    after_each(function()
        os.remove("test.o")
        os.remove("test.so")
        if not h.verbose then os.remove("test.c") end
        os.execute("rm -rf test.so.dSYM")
    end)

    it("uses exact struct and union specifiers without invented typedefs",
    function()
        with_header([[
            struct Item { int count; };
            union Cell { int count; double number; };

            static struct Item make_item(int value) {
                struct Item item = { value };
                return item;
            }

            static union Cell make_cell(int value) {
                union Cell cell = { .count = value };
                return cell;
            }
        ]], function(header)
            local source = [[
                local c = foreign import "]] .. header .. [["

                function item_value(): integer
                    local item: c.Item = c.make_item(17)
                    return item.count as integer
                end

                function cell_value(): integer
                    local cell: c.Cell = c.make_cell(23)
                    return cell.count as integer
                end
            ]]

            local csrc = h.compile_and_read_c(source)
            assert.matches("struct Item", csrc, 1, true)
            assert.matches("union Cell", csrc, 1, true)
            assert.not_matches("typedef struct Item Item", csrc, 1, true)
            assert.not_matches("typedef union Cell Cell", csrc, 1, true)

            local ok, err = h.call("test", [[
                assert(test.item_value() == 17)
                assert(test.cell_value() == 23)
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("keeps a same-named function callable beside the tag type", function()
        with_header([[
            struct stat { int new; };
            static int stat(void) { return 31; }
            static struct stat make_stat(void) {
                struct stat result = { 47 };
                return result;
            }
        ]], function(header)
            h.run_coder([[
                local c = foreign import "]] .. header .. [["

                function function_value(): integer
                    return c.stat() as integer
                end

                function field_value(): integer
                    local result: c.stat = c.make_stat()
                    return result.new as integer
                end
            ]], [[
                assert(test.function_value() == 31)
                assert(test.field_value() == 47)
            ]])
        end)
    end)

    it("renders an incomplete tag alias only through legal pointers",
    function()
        with_header([[
            struct Opaque;
            static struct Opaque *identity(struct Opaque *pointer);
            static struct Opaque *identity(struct Opaque *pointer) {
                return pointer;
            }
        ]], function(header)
            local csrc = h.compile_and_read_c([[
                local c = foreign import "]] .. header .. [["

                local function pass(
                    pointer: *c.Opaque): *c.Opaque
                    return c.identity(pointer)
                end
            ]])
            assert.matches("struct Opaque %*", csrc)
            assert.not_matches("typedef struct Opaque Opaque",
                csrc, 1, true)
        end)
    end)

    it("renders the production libuv DNS tags and callback types", function()
        assert(os.getenv("PREFIX"),
            "the real-libuv fixture requires the prepared Titan prefix")
        local csrc = h.compile_and_read_c([[
            local libuv = foreign import "uv.h"
            local shim = foreign import "titan/uv.h"
            local ffi = foreign import "titan/ffi.h"

            local function dns_shape(
                loop: *libuv.uv_loop_t,
                dns: *libuv.uv_getaddrinfo_t,
                connect: *libuv.uv_connect_t,
                tcp: *libuv.uv_tcp_t,
                node: const *ffi.titan_ffi_char):
                (ffi.titan_ffi_int, ffi.titan_ffi_int)
                local service: ffi.titan_ffi_char[6]
                local hints: libuv.addrinfo
                local address: libuv.sockaddr
                local storage: libuv.sockaddr_storage
                hints.ai_family = libuv.AF_UNSPEC
                hints.ai_socktype = libuv.SOCK_STREAM
                hints.ai_protocol = libuv.IPPROTO_TCP
                hints.ai_flags = libuv.AI_NUMERICSERV
                if libuv.AF_INET == libuv.AF_INET6 then
                    address.sa_family = 0
                end
                local dns_status = libuv.uv_getaddrinfo(
                    loop, dns, shim.titan_uvshim_getaddrinfo_cb,
                    node, service, hints)
                local generic =
                    storage as const *libuv.sockaddr
                local connect_status = libuv.uv_tcp_connect(
                    connect, tcp, generic,
                    shim.titan_uvshim_connect_cb)
                return dns_status, connect_status
            end
        ]])
        assert.match("struct addrinfo _local_hints_%d+ = %{0%};", csrc)
        assert.match("struct sockaddr _local_address_%d+ = %{0%};", csrc)
        assert.match(
            "struct sockaddr_storage _local_storage_%d+ = %{0%};", csrc)
        for _, spelling in ipairs({
            "AF_UNSPEC", "AF_INET", "AF_INET6", "SOCK_STREAM",
            "IPPROTO_TCP", "AI_NUMERICSERV",
            "titan_uvshim_getaddrinfo_cb", "titan_uvshim_connect_cb",
            "uv_getaddrinfo(", "uv_tcp_connect(",
        }) do
            assert.matches(spelling, csrc, 1, true)
        end
    end)
end)
