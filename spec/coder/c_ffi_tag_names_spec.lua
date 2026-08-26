require "titan-compiler.coder.core"
local h = require "spec.support.helpers"
local coder_names = require "titan-compiler.coder.names"

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
            struct external_stat { int value; };
            extern int external_stat(void);
            int external_stat(void) { return 37; }
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

                function external_function_value(): integer
                    return c.external_stat() as integer
                end

                function field_value(): integer
                    local result: c.stat = c.make_stat()
                    return result.new as integer
                end
            ]], [[
                assert(test.function_value() == 31)
                assert(test.external_function_value() == 37)
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

    it("renders DNS-shaped tags and callback types from a minimal header",
    function()
        with_header([[
            typedef int ffi_int;
            typedef char ffi_char;

            typedef struct ffi_loop { int state; } ffi_loop;
            typedef struct ffi_dns_request { int state; } ffi_dns_request;
            typedef struct ffi_connect_request {
                int state;
            } ffi_connect_request;
            typedef struct ffi_tcp { int state; } ffi_tcp;

            struct ffi_addrinfo {
                int family;
                int socket_type;
                int protocol;
                int flags;
            };
            struct ffi_sockaddr { int family; };
            struct ffi_sockaddr_storage { long alignment; char bytes[32]; };

            #define FFI_AF_UNSPEC 0
            #define FFI_AF_INET 2
            #define FFI_AF_INET6 10
            #define FFI_SOCK_STREAM 1
            #define FFI_IPPROTO_TCP 6
            #define FFI_AI_NUMERICSERV 1024

            typedef void (*ffi_dns_callback)(
                ffi_dns_request *, int, struct ffi_addrinfo *);
            typedef void (*ffi_connect_callback)(
                ffi_connect_request *, int);

            static int ffi_getaddrinfo(
                ffi_loop *loop,
                ffi_dns_request *request,
                ffi_dns_callback callback,
                const char *node,
                const char *service,
                const struct ffi_addrinfo *hints
            ) {
                (void)loop;
                (void)request;
                (void)callback;
                (void)node;
                (void)service;
                (void)hints;
                return 0;
            }

            static int ffi_tcp_connect(
                ffi_connect_request *request,
                ffi_tcp *tcp,
                const struct ffi_sockaddr *address,
                ffi_connect_callback callback
            ) {
                (void)request;
                (void)tcp;
                (void)address;
                (void)callback;
                return 0;
            }
        ]], function(header)
            local csrc, ast = h.compile_and_read_c([[
                local c = foreign import "]] .. header .. [["

                foreign function dns_callback(
                    request: *c.ffi_dns_request,
                    status: c.ffi_int,
                    result: *c.ffi_addrinfo): ()
                end

                foreign function connect_callback(
                    request: *c.ffi_connect_request,
                    status: c.ffi_int): ()
                end

                local function dns_shape(
                    loop: *c.ffi_loop,
                    dns: *c.ffi_dns_request,
                    connect: *c.ffi_connect_request,
                    tcp: *c.ffi_tcp,
                    node: const *c.ffi_char):
                    (c.ffi_int, c.ffi_int)
                    local service: c.ffi_char[6] =
                        c.ffi_char.new_array(6)
                    local hints = c.ffi_addrinfo.new()
                    local address = c.ffi_sockaddr.new()
                    local storage = c.ffi_sockaddr_storage.new()
                    hints.family = c.FFI_AF_UNSPEC
                    hints.socket_type = c.FFI_SOCK_STREAM
                    hints.protocol = c.FFI_IPPROTO_TCP
                    hints.flags = c.FFI_AI_NUMERICSERV
                    if c.FFI_AF_INET == c.FFI_AF_INET6 then
                        address.family = 0
                    end
                    local dns_status = c.ffi_getaddrinfo(
                        loop, dns, dns_callback, node, service, hints)
                    local generic =
                        storage as const *c.ffi_sockaddr
                    local connect_status = c.ffi_tcp_connect(
                        connect, tcp, generic, connect_callback)
                    return dns_status, connect_status
                end
            ]])
            assert.match(
                "struct ffi_addrinfo _local_hints_%d+ = %{0%};", csrc)
            assert.match(
                "struct ffi_sockaddr _local_address_%d+ = %{0%};", csrc)
            assert.match(
                "struct ffi_sockaddr_storage _local_storage_%d+ = %{0%};",
                csrc)
            local aliases = ast[1]._type.type_members
            for _, name in ipairs({
                "ffi_addrinfo", "ffi_sockaddr", "ffi_sockaddr_storage",
            }) do
                assert.truthy(aliases[name], name)
                assert.is_true(aliases[name].complete, name)
            end
            for _, name in ipairs({
                "FFI_AF_UNSPEC", "FFI_AF_INET", "FFI_AF_INET6",
                "FFI_SOCK_STREAM", "FFI_IPPROTO_TCP",
                "FFI_AI_NUMERICSERV",
            }) do
                assert.truthy(ast[1]._type.members[name], name)
            end
            for _, spelling in ipairs({
                "FFI_AF_UNSPEC", "FFI_AF_INET", "FFI_AF_INET6",
                "FFI_SOCK_STREAM", "FFI_IPPROTO_TCP",
                "FFI_AI_NUMERICSERV",
                coder_names._foreign_func_name("test", "dns_callback"),
                coder_names._foreign_func_name("test", "connect_callback"),
                "ffi_getaddrinfo(", "ffi_tcp_connect(",
            }) do
                assert.matches(spelling, csrc, 1, true)
            end
        end)
    end)
end)
