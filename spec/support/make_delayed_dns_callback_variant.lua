-- Generate an isolated DNS callback/ownership titan.uv folder from production.
-- Usage: lua make_delayed_dns_callback_variant.lua INPUT_DIR OUTPUT_DIR
local lfs = require "lfs"

local input_dir, output_dir = assert(arg[1]), assert(arg[2])
assert(lfs.attributes(input_dir, "mode") == "directory",
    "delayed-DNS input is not a directory: " .. input_dir)
if not lfs.attributes(output_dir, "mode") then
    assert(lfs.mkdir(output_dir), "could not create " .. output_dir)
else
    assert(lfs.attributes(output_dir, "mode") == "directory",
        "delayed-DNS output is not a directory: " .. output_dir)
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    assert(file:close())
    return contents
end

local function write(path, contents)
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
end

local function replace_once(source, needle, replacement, label)
    local first = assert(source:find(needle, 1, true),
        "missing delayed-DNS test-variant anchor: " .. label)
    assert(not source:find(needle, first + #needle, true),
        "duplicate delayed-DNS test-variant anchor: " .. label)
    return source:sub(1, first - 1) .. replacement ..
           source:sub(first + #needle)
end

local sources = {}
local filenames = {}
for entry in lfs.dir(input_dir) do
    local path = input_dir .. "/" .. entry
    if entry:match("%.titan$") and
            lfs.attributes(path, "mode") == "file" then
        sources[entry] = read(path)
        filenames[#filenames + 1] = entry
    end
end
table.sort(filenames)
for _, required in ipairs({
    "uv.titan", "runtime.titan", "task.titan", "file.titan",
    "tcp.titan", "os.titan", "process.titan",
}) do
    assert(sources[required], "missing delayed-DNS source " .. required)
end

local variant_hooks = {
    "__test_delay_next_dns_callback",
    "__test_dns_callback_is_delayed",
    "__test_dns_delivery_count",
    "__test_reset_dns_release_count",
    "__test_dns_release_count",
    "__test_raise_during_next_dns_copy",
    "__test_prepend_invalid_dns_address",
    "__test_collect_after_next_dns_address_root",
    "__test_collect_across_next_dns_retry",
    "__test_dns_root_gc_count",
    "__test_dns_retry_gc_count",
    "__test_dns_invalid_sync_failures",
    "__test_dns_retry_after_close_count",
    "__test_format_dns_port",
}
for _, hook in ipairs(variant_hooks) do
    for _, filename in ipairs(filenames) do
        assert(not sources[filename]:find(hook, 1, true),
            "production source already exposes delayed-DNS hook " .. hook ..
            " in " .. filename)
    end
end

local function patch(filename, needle, replacement, label)
    sources[filename] = replace_once(sources[filename], needle, replacement,
        filename .. ": " .. label)
end

local function require_once(filename, needle, label)
    local source = sources[filename]
    local first = assert(source:find(needle, 1, true),
        "missing delayed-DNS direct-call contract: " .. filename .. ": " ..
        label)
    assert(not source:find(needle, first + #needle, true),
        "duplicate delayed-DNS direct-call contract: " .. filename .. ": " ..
        label)
end

patch("uv.titan", [==[
local OWNER_TASK_DRIVE = 8
]==], [==[
local OWNER_TASK_DRIVE = 8
-- Variant-only timer that holds a successful borrowed addrinfo chain after
-- libuv's physical callback and before Titan's logical DNS delivery.
local OWNER_DELAYED_DNS_CALLBACK = 101
]==], "delayed DNS owner kind")

patch("uv.titan", [==[
local active_runtime: Runtime? = nil
]==], [==[
local active_runtime: Runtime? = nil

-- Variant-only controls. This generated source is never installed.
local test_dns_delay = 0
local test_dns_callback_delayed = false
local test_dns_delivery_count = 0
local test_dns_release_count = 0
local test_dns_raise_during_copy = false
local test_dns_prepend_invalid = false
local test_dns_invalid_connect_pending = false
local test_dns_retry_waiting_close = false
local test_dns_invalid_sync_failures = 0
local test_dns_retry_after_close_count = 0
local test_dns_gc_after_root = false
local test_dns_root_gc_count = 0
local test_dns_gc_across_retry = false
local test_dns_retry_gc_count = 0
]==], "DNS test-control state")

-- Keep the zeroed typed allocation as the sole address-storage owner. The
-- variant can reserve cell zero without reading or writing sockaddr fields.
patch("tcp.titan", [==[
  local owned = shim.titan_uvshim_address.new_array(count)
  local data = owned as *shim.titan_uvshim_address
  local copied = 0
]==], [==[
  local leading = 0
  if test_dns_prepend_invalid then
    test_dns_prepend_invalid = false
    test_dns_invalid_connect_pending = true
    leading = 1
  end
  local owned = shim.titan_uvshim_address.new_array(count + leading)
  local data = owned as *shim.titan_uvshim_address
  local copied = leading
]==], "optional leading zeroed address cell")

patch("tcp.titan", [==[
      cstring.memcpy(destination.bytes, entry.ai_addr, copy_length)
      copied = copied + 1
]==], [==[
      cstring.memcpy(destination.bytes, entry.ai_addr, copy_length)
      if test_dns_raise_during_copy then
        test_dns_raise_during_copy = false
        raise "injected delayed-DNS address copy failure"
      end
      copied = copied + 1
]==], "copy-longjmp injection")

patch("tcp.titan", [==[
  return AddressList.new(data, owned, count)
]==], [==[
  return AddressList.new(data, owned, count + leading)
]==], "variant address count")

-- Count each physical release immediately after its direct non-raising C call.
-- There is deliberately no helper call or allocation between the call and the
-- counter update.
patch("tcp.titan", [==[
    libuv.uv_freeaddrinfo(control.result_pointer)
    control.result_pointer = nil
]==], [==[
    libuv.uv_freeaddrinfo(control.result_pointer)
    test_dns_release_count = test_dns_release_count + 1
    control.result_pointer = nil
]==], "normal addrinfo release counter")

patch("tcp.titan", [==[
    libuv.uv_freeaddrinfo(owner.metadata.result_pointer)
    owner.metadata.result_pointer = nil
]==], [==[
    libuv.uv_freeaddrinfo(owner.metadata.result_pointer)
    test_dns_release_count = test_dns_release_count + 1
    owner.metadata.result_pointer = nil
]==], "emergency addrinfo release counter")

-- Force both a generational step and a full collection only after the owned
-- AddressList is installed in the operation, while the borrowed chain is still
-- available to the dispatch catch if collection raises.
patch("tcp.titan", [==[
    operation.addresses = addresses
    free_dns_result(control)
]==], [==[
    operation.addresses = addresses
    if test_dns_gc_after_root then
      test_dns_gc_after_root = false
      test_dns_root_gc_count = test_dns_root_gc_count + 1
      lua.lua_gc(L, lua.LUA_GCGEN)
      lua.lua_gc(L, lua.LUA_GCSTEP, 0 as lua.lua_Integer)
      lua.lua_gc(L, lua.LUA_GCCOLLECT)
    end
    free_dns_result(control)
]==], "GC after owned address root")

-- The physical callback has already returned ownership of a successful result
-- to Titan. Capture it in the typed control field, then defer before entering
-- dns_dispatch_body and before changing NET_OWNER_SUBMITTED to CALLBACK.
patch("tcp.titan", [==[
  owner.metadata.result_pointer = pointer as *libuv.addrinfo
  dns_dispatch_body(owner, result, pointer)
]==], [==[
  owner.metadata.result_pointer = pointer as *libuv.addrinfo
  if result >= 0 and owner.metadata.result_pointer ~= nil and
      test_dns_delay > 0 then
    local delay = test_dns_delay
    test_dns_delay = 0
    test_dns_callback_delayed = true
    local wake, status = start_owner(owner.metadata.runtime,
        OWNER_DELAYED_DNS_CALLBACK, nil, owner, result, delay, 0)
    if status < 0 then
      raise make_error(status, "test.dns.delay", nil)
    end
    return
  end
  dns_dispatch_body(owner, result, pointer)
]==], "successful DNS callback deferral")

-- Observe the required synchronous rejection of the prepended AF_UNSPEC cell.
-- The retry marker is not advanced until finish_closed_tcp runs.
patch("tcp.titan", [==[
        tcp.metadata.connect_pending = false
        retire_net_control(owner.metadata)
]==], [==[
        if test_dns_invalid_connect_pending then
          test_dns_invalid_connect_pending = false
          test_dns_retry_waiting_close = true
          test_dns_invalid_sync_failures =
            test_dns_invalid_sync_failures + 1
        end
        tcp.metadata.connect_pending = false
        retire_net_control(owner.metadata)
]==], "synchronous invalid-cell rejection")

patch("tcp.titan", [==[
    operation.tcp = nil
    continue_net_setup(operation)
]==], [==[
    operation.tcp = nil
    if test_dns_retry_waiting_close then
      test_dns_retry_waiting_close = false
      test_dns_retry_after_close_count =
        test_dns_retry_after_close_count + 1
      if test_dns_gc_across_retry then
        test_dns_gc_across_retry = false
        test_dns_retry_gc_count = test_dns_retry_gc_count + 1
        lua.lua_gc(L, lua.LUA_GCGEN)
        lua.lua_gc(L, lua.LUA_GCSTEP, 0 as lua.lua_Integer)
        lua.lua_gc(L, lua.LUA_GCCOLLECT)
      end
    end
    continue_net_setup(operation)
]==], "closed invalid candidate before retry")

-- Runtime shutdown closes every ordinary timer owner, but the delayed DNS
-- timer is the sole physical owner of a borrowed result awaiting delivery.
patch("task.titan", [==[
  while owner do
    close_owner(owner)
    owner = owner.metadata.next_owner
  end
]==], [==[
  while owner do
    if owner.metadata.kind ~= OWNER_DELAYED_DNS_CALLBACK then
      close_owner(owner)
    end
    owner = owner.metadata.next_owner
  end
]==], "cleanup-shield delayed DNS owner")

-- Ordinary one-shot timers close before delivery. Delayed DNS must instead
-- re-enter the production dispatcher, retire the DNS control, and only then
-- close its delivery owner.
patch("task.titan", [==[
  if kind ~= OWNER_TICKER then
    close_owner(owner)
  end
]==], [==[
  if kind ~= OWNER_TICKER and
      kind ~= OWNER_DELAYED_DNS_CALLBACK then
    close_owner(owner)
  end
]==], "preserve delayed DNS owner through delivery")

patch("task.titan", [==[
  elseif kind == OWNER_TASK_DRIVE then
    local task = owner.metadata.task
]==], [==[
  elseif kind == OWNER_DELAYED_DNS_CALLBACK then
    local dns_owner = owner.metadata.peer as uv_getaddrinfo_t
    local result_pointer = dns_owner.metadata.result_pointer
    dns_dispatch(dns_owner, 0, owner.metadata.epoch,
                 0 as libuv.size_t,
                 result_pointer as ffi.titan_ffi_void_ptr)
    test_dns_delivery_count = test_dns_delivery_count + 1
    close_owner(owner)
  elseif kind == OWNER_TASK_DRIVE then
    local task = owner.metadata.task
]==], "delayed DNS logical delivery")

local hook_api = [==[

-- Variant-only controls. The generated DSO is isolated and never installed.
function __test_delay_next_dns_callback(milliseconds: integer)
  test_dns_delay = milliseconds
  test_dns_callback_delayed = false
  test_dns_delivery_count = 0
end

function __test_dns_callback_is_delayed(): boolean
  return test_dns_callback_delayed
end

function __test_dns_delivery_count(): integer
  return test_dns_delivery_count
end

function __test_reset_dns_release_count()
  test_dns_release_count = 0
end

function __test_dns_release_count(): integer
  return test_dns_release_count
end

function __test_raise_during_next_dns_copy()
  test_dns_raise_during_copy = true
end

function __test_prepend_invalid_dns_address()
  test_dns_prepend_invalid = true
  test_dns_invalid_connect_pending = false
  test_dns_retry_waiting_close = false
  test_dns_invalid_sync_failures = 0
  test_dns_retry_after_close_count = 0
end

function __test_collect_after_next_dns_address_root()
  test_dns_gc_after_root = true
  test_dns_root_gc_count = 0
end

function __test_collect_across_next_dns_retry()
  test_dns_gc_across_retry = true
  test_dns_retry_gc_count = 0
end

function __test_dns_root_gc_count(): integer
  return test_dns_root_gc_count
end

function __test_dns_retry_gc_count(): integer
  return test_dns_retry_gc_count
end

function __test_dns_invalid_sync_failures(): integer
  return test_dns_invalid_sync_failures
end

function __test_dns_retry_after_close_count(): integer
  return test_dns_retry_after_close_count
end

function __test_format_dns_port(port: integer): (string, integer)
  local service: ffi.titan_ffi_char[6]
  local pointer = format_port(port as ffi.titan_ffi_int, service)
  local length = cstring.strlen(pointer) as libuv.size_t
  return bytes_to_string(pointer, length), service[5] as integer
end
]==]

patch("uv.titan", [==[
do
  local sigpipe_status =
]==], hook_api .. [==[

do
  local sigpipe_status =
]==], "variant hook API")

-- Fail before generating a stale test variant if any production ownership
-- boundary or direct public-libuv call moves to a different contributor.
require_once("tcp.titan",
    "owner.metadata.result_pointer = pointer as *libuv.addrinfo",
    "typed borrowed-result capture")
require_once("tcp.titan",
    "entry.ai_addrlen <= libuv.sockaddr_storage.sizeof",
    "sockaddr_storage usability predicate")
require_once("tcp.titan",
    "shim.titan_uvshim_address.new_array(count + leading)",
    "typed zeroed address allocation")
require_once("tcp.titan",
    "libuv.uv_req_set_data(owner.handle, pointer)\n" ..
    "  local status = libuv.uv_getaddrinfo {",
    "DNS request data installation and direct submission")
require_once("tcp.titan", "libuv.uv_tcp_bind(tcp.handle, address, 0)",
    "direct TCP bind")
require_once("tcp.titan", "local status = libuv.uv_tcp_connect {",
    "direct TCP connect")
require_once("tcp.titan",
    "libuv.uv_freeaddrinfo(control.result_pointer)\n" ..
    "    test_dns_release_count = test_dns_release_count + 1",
    "normal direct addrinfo release and adjacent counter")
require_once("tcp.titan",
    "libuv.uv_freeaddrinfo(owner.metadata.result_pointer)\n" ..
    "    test_dns_release_count = test_dns_release_count + 1",
    "emergency direct addrinfo release and adjacent counter")
require_once("task.titan", "libuv.uv_cancel(dns.handle)",
    "submitted DNS cancellation")

for _, retired in ipairs({
    "titan_uvshim_format_port",
    "titan_uvshim_getaddrinfo_start",
    "titan_uvshim_addrinfo_is_usable",
    "titan_uvshim_addrinfo_count",
    "titan_uvshim_addrinfo_copy",
    "titan_uvshim_address_at",
    "titan_uvshim_tcp_bind",
    "titan_uvshim_tcp_connect_start",
    "titan_uvshim_getaddrinfo_cancel",
    "titan_uvshim_addrinfo_free",
}) do
    for _, filename in ipairs(filenames) do
        assert(not sources[filename]:find(retired, 1, true),
            "delayed-DNS variant retained retired symbol " .. retired ..
            " in " .. filename)
    end
end

for _, filename in ipairs(filenames) do
    local output = output_dir .. "/" .. filename
    assert(not lfs.attributes(output), "refusing to overwrite " .. output)
end
for _, filename in ipairs(filenames) do
    local output = output_dir .. "/" .. filename
    write(output, sources[filename])
end
