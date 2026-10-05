# Public types, fields, callbacks, and constants

This reference describes header-free public types. Packed native fields are private. Empty record blocks below mean opaque owners, not empty storage. Constructors/methods remain listed explicitly. Ordinary callback aliases use normal callable dispatch; C-only callbacks are documented separately. Each listed constructor or method has its operation and lifetime rules in the [supplemental reference](supplemental.md); native callback rules are in the [callback reference](callbacks.md).

Source-level optional constant annotations support module initialization. Pinned initialized constants are immutable values; `?` alone is not a capability probe. Constants from platform_constants.titan are explicitly nil when the native platform lacks their definition; test these before use.

## addrinfo_hints_t

```titan
record addrinfo_hints_t
  ai_flags: integer
  ai_family: integer
  ai_socktype: integer
  ai_protocol: integer
end
```


## addrinfo_result_t

```titan
record addrinfo_result_t
end
```

```titan
function addrinfo_result_t:entries(): {addrinfo_t}
```


## addrinfo_t

```titan
record addrinfo_t
  ai_flags: integer
  ai_family: integer
  ai_socktype: integer
  ai_protocol: integer
  ai_addrlen: integer
  ai_addr: sockaddr_t?
  ai_addr_bytes: string?
  ai_canonname: string?
end
```

`ai_addr_bytes` supplements the typed address with an exact copied byte representation. Native `ai_next` is represented by result Array order. Copies survive native result cleanup.


## after_work_cb

```titan
type after_work_cb = function (work_t, integer): ()
```


## alloc_cb

```titan
type alloc_cb = function (handle_t, integer): (buf_t)
```


## async_cb

```titan
type async_cb = function (async_t): ()
```


## async_t

```titan
record async_t
end
```

```titan
function async_t.new(): async_t
function async_t:as_handle_t(): handle_t
function async_t:borrow(): foreign *void
```


## barrier_t

```titan
record barrier_t
end
```

```titan
function barrier_t.new(): barrier_t
function barrier_t.wait_function(): foreign function(*void): int
function barrier_t:borrow(): foreign *void
function barrier_t:destroy()
function barrier_t:init(count: integer): integer
function barrier_t:wait(): integer
```


## buf_t

```titan
record buf_t
end
```

```titan
function buf_t.allocate(capacity: integer): buf_t
function buf_t.from_string(base: string): buf_t
function buf_t:get(index: integer): integer
function buf_t:is_writable(): boolean
function buf_t:length(): integer
function buf_t:set(index: integer, byte: integer)
function buf_t:slice(first: integer, length: integer): buf_t
function buf_t:to_string(length: integer): string
```


## check_cb

```titan
type check_cb = function (check_t): ()
```


## check_t

```titan
record check_t
end
```

```titan
function check_t.new(): check_t
function check_t:as_handle_t(): handle_t
```


## clock_id

```titan
union clock_id
  monotonic()
  realtime()
end
```

Use one alternative at a time. This union is not a bitmask.


## close_cb

```titan
type close_cb = function (handle_t): ()
```


## cond_t

```titan
record cond_t
end
```

```titan
function cond_t.broadcast_function(): foreign function(*void): void
function cond_t.new(): cond_t
function cond_t.signal_function(): foreign function(*void): void
function cond_t.timedwait_function(): foreign function(*void, *void, unsigned long long): int
function cond_t.wait_function(): foreign function(*void, *void): void
function cond_t:borrow(): foreign *void
function cond_t:broadcast()
function cond_t:destroy()
function cond_t:init(): integer
function cond_t:signal()
function cond_t:timedwait(mutex: mutex_t, timeout_ns: foreign unsigned long long): integer
function cond_t:wait(mutex: mutex_t)
```


## connect_cb

```titan
type connect_cb = function (connect_t, integer): ()
```


## connect_t

```titan
record connect_t
end
```

```titan
function connect_t.new(): connect_t
function connect_t:as_req_t(): req_t
function connect_t:handle(): stream_t?
```


## connection_cb

```titan
type connection_cb = function (stream_t, integer): ()
```


## cpu_info_t

```titan
record cpu_info_t
  model: string?
  speed: integer
  cpu_times: cpu_times_t
end
```


## cpu_times_t

```titan
record cpu_times_t
  user: integer
  nice: integer
  sys: integer
  idle: integer
  irq: integer
end
```


## dir_t

```titan
record dir_t
end
```

```titan
function dir_t.new(): dir_t
```


## dirent_t

```titan
record dirent_t
  name: string
  type: dirent_type_t
end
```


## dirent_type_t

```titan
union dirent_type_t
  unknown()
  file()
  directory()
  link()
  fifo()
  socket()
  character()
  block()
end
```

Use one alternative at a time. This union is not a bitmask.


## env_item_t

```titan
record env_item_t
  name: string
  value: string
end
```


## exit_cb

```titan
type exit_cb = function (process_t, integer, integer): ()
```


## fs_cb

```titan
type fs_cb = function (fs_t): ()
```


## fs_event_cb

```titan
type fs_event_cb = function (fs_event_t, string?, integer, integer): ()
```


## fs_event_t

```titan
record fs_event_t
end
```

```titan
function fs_event_t.new(): fs_event_t
function fs_event_t:as_handle_t(): handle_t
```


## fs_poll_cb

```titan
type fs_poll_cb = function (fs_poll_t, integer, stat_t?, stat_t?): ()
```


## fs_poll_t

```titan
record fs_poll_t
end
```

```titan
function fs_poll_t.new(): fs_poll_t
function fs_poll_t:as_handle_t(): handle_t
```


## fs_ptr_t

```titan
union fs_ptr_t
  stat(result: stat_t)
  directory(result: dir_t)
  entries(result: {dirent_t})
  statfs(result: statfs_t)
  path(result: string)
  scandir(request: fs_t)
end
```

Use one alternative at a time. This union is not a bitmask.


## fs_t

```titan
record fs_t
end
```

```titan
function fs_t.new(): fs_t
function fs_t:as_req_t(): req_t
```


## fs_type_t

```titan
union fs_type_t
  unknown()
  custom()
  open()
  close()
  read()
  write()
  sendfile()
  stat()
  lstat()
  fstat()
  ftruncate()
  utime()
  futime()
  access()
  chmod()
  fchmod()
  fsync()
  fdatasync()
  unlink()
  rmdir()
  mkdir()
  mkdtemp()
  rename()
  scandir()
  link()
  symlink()
  readlink()
  chown()
  fchown()
  realpath()
  copyfile()
  lchown()
  opendir()
  readdir()
  closedir()
  statfs()
  mkstemp()
  lutime()
end
```

Use one alternative at a time. This union is not a bitmask.


## getaddrinfo_cb

```titan
type getaddrinfo_cb = function (getaddrinfo_t, integer, addrinfo_result_t?): ()
```


## getaddrinfo_t

```titan
record getaddrinfo_t
end
```

```titan
function getaddrinfo_t.new(): getaddrinfo_t
function getaddrinfo_t:addrinfo(): (integer, addrinfo_result_t?)
function getaddrinfo_t:as_req_t(): req_t
function getaddrinfo_t:get_loop(): loop_t?
```


## getnameinfo_cb

```titan
type getnameinfo_cb = function (getnameinfo_t, integer, string?, string?): ()
```


## getnameinfo_t

```titan
record getnameinfo_t
end
```

```titan
function getnameinfo_t.new(): getnameinfo_t
function getnameinfo_t:as_req_t(): req_t
function getnameinfo_t:get_loop(): loop_t?
function getnameinfo_t:result(): (integer, string?, string?)
```


## group_t

```titan
record group_t
  groupname: string
  gid: integer
  members: {string}
end
```


## handle_t

```titan
union handle_t
  process(owner: process_t)
  tcp(owner: tcp_t)
  pipe(owner: pipe_t)
  tty(owner: tty_t)
  udp(owner: udp_t)
  fs_event(owner: fs_event_t)
  fs_poll(owner: fs_poll_t)
  timer(owner: timer_t)
  idle(owner: idle_t)
  prepare(owner: prepare_t)
  check(owner: check_t)
  async(owner: async_t)
  signal(owner: signal_t)
  poll(owner: poll_t)
end
```

```titan
function handle_t:is_initialized(): boolean
```

Use one alternative at a time. This union is not a bitmask.

This is a finite owner-retaining view. Creating another view does not allocate or initialize a second native handle/request.


## handle_type

```titan
union handle_type
  unknown()
  async()
  check()
  fs_event()
  fs_poll()
  handle()
  idle()
  named_pipe()
  poll()
  prepare()
  process()
  stream()
  tcp()
  timer()
  tty()
  udp()
  signal()
  file()
end
```

Use one alternative at a time. This union is not a bitmask.


## idle_cb

```titan
type idle_cb = function (idle_t): ()
```


## idle_t

```titan
record idle_t
end
```

```titan
function idle_t.new(): idle_t
function idle_t:as_handle_t(): handle_t
```


## interface_address_t

```titan
record interface_address_t
  name: string
  phys_addr: string
  is_internal: boolean
  address: sockaddr_t
  netmask: sockaddr_t?
end
```


## key_t

```titan
record key_t
end
```

```titan
function key_t.get_function(): foreign function(*void): *void
function key_t.new(): key_t
function key_t.set_function(): foreign function(*void, *void): void
function key_t:borrow(): foreign *void
function key_t:create(): integer
function key_t:delete()
function key_t:get(): foreign *void
function key_t:set(value: foreign *void)
```


## lib_t

```titan
record lib_t
end
```

```titan
function lib_t.new(): lib_t
function lib_t:dlclose()
function lib_t:dlerror(): string
function lib_t:dlopen(filename: string): integer
function lib_t:dlsym(name: string): (integer, symbol_t?)
```


## loop_option

```titan
union loop_option
  block_signal()
  metrics_idle_time()
  use_io_uring_sqpoll()
end
```

Use one alternative at a time. This union is not a bitmask.


## loop_t

```titan
record loop_t
end
```

```titan
function loop_t.new(): loop_t
function loop_t:secondary_error_count(): integer
```


## membership

```titan
union membership
  LEAVE_GROUP()
  JOIN_GROUP()
end
```

Use one alternative at a time. This union is not a bitmask.


## metrics_t

```titan
record metrics_t
  loop_count: integer
  events: integer
  events_waiting: integer
end
```


## mutex_t

```titan
record mutex_t
end
```

```titan
function mutex_t.lock_function(): foreign function(*void): void
function mutex_t.new(): mutex_t
function mutex_t.trylock_function(): foreign function(*void): int
function mutex_t.unlock_function(): foreign function(*void): void
function mutex_t:borrow(): foreign *void
function mutex_t:destroy()
function mutex_t:init(): integer
function mutex_t:init_recursive(): integer
function mutex_t:lock()
function mutex_t:trylock(): integer
function mutex_t:unlock()
```


## once_t

```titan
record once_t
end
```

```titan
function once_t.new(): once_t
function once_t:borrow(): foreign *void
```


## os_fd_t

```titan
record os_fd_t
end
```

```titan
function os_fd_t.from_integer(identifier: integer): os_fd_t
function os_fd_t:to_integer(): integer
```


## os_sock_t

```titan
record os_sock_t
end
```

```titan
function os_sock_t.from_integer(socket: integer): os_sock_t
function os_sock_t:to_integer(): integer
```


## passwd_t

```titan
record passwd_t
  username: string
  uid: integer
  gid: integer
  shell: string?
  homedir: string
end
```


## pipe_t

```titan
record pipe_t
end
```

```titan
function pipe_t.new(): pipe_t
function pipe_t:as_handle_t(): handle_t
function pipe_t:as_stream_t(): stream_t
function pipe_t:ipc(): integer
```


## poll_cb

```titan
type poll_cb = function (poll_t, integer, integer): ()
```


## poll_t

```titan
record poll_t
end
```

```titan
function poll_t.new(): poll_t
function poll_t:as_handle_t(): handle_t
```


## prepare_cb

```titan
type prepare_cb = function (prepare_t): ()
```


## prepare_t

```titan
record prepare_t
end
```

```titan
function prepare_t.new(): prepare_t
function prepare_t:as_handle_t(): handle_t
```


## process_options_t

```titan
record process_options_t
  exit_cb: (function (process_t, integer, integer): ())?
  file: string
  args: {string}
  env: {string}?
  cwd: string?
  flags: integer
  stdio: {stdio_container_t}
  uid: integer
  gid: integer
end
```

```titan
function process_options_t.new(file: string, args: {string}): process_options_t
```


## process_t

```titan
record process_t
end
```

```titan
function process_t.new(): process_t
function process_t:as_handle_t(): handle_t
```


## random_cb

```titan
type random_cb = function (random_t, integer, buf_t, integer): ()
```


## random_t

```titan
record random_t
end
```

```titan
function random_t.new(): random_t
function random_t:as_req_t(): req_t
```


## read_cb

```titan
type read_cb = function (stream_t, integer, buf_t?): ()
```


## req_t

```titan
union req_t
  connect(owner: connect_t)
  write(owner: write_t)
  shutdown(owner: shutdown_t)
  udp_send(owner: udp_send_t)
  getaddrinfo(owner: getaddrinfo_t)
  getnameinfo(owner: getnameinfo_t)
  fs(owner: fs_t)
  work(owner: work_t)
  random(owner: random_t)
end
```

```titan
function req_t:get_data(): value
function req_t:set_data(data: value)
```

Use one alternative at a time. This union is not a bitmask.

This is a finite owner-retaining view. Creating another view does not allocate or initialize a second native handle/request.


## req_type

```titan
union req_type
  unknown()
  req()
  connect()
  write()
  shutdown()
  udp_send()
  fs()
  work()
  getaddrinfo()
  getnameinfo()
  random()
end
```

Use one alternative at a time. This union is not a bitmask.


## run_mode

```titan
union run_mode
  default()
  once()
  nowait()
end
```

Use one alternative at a time. This union is not a bitmask.


## rusage_t

```titan
record rusage_t
  ru_utime: timeval_t
  ru_stime: timeval_t
  ru_maxrss: integer
  ru_ixrss: integer
  ru_idrss: integer
  ru_isrss: integer
  ru_minflt: integer
  ru_majflt: integer
  ru_nswap: integer
  ru_inblock: integer
  ru_oublock: integer
  ru_msgsnd: integer
  ru_msgrcv: integer
  ru_nsignals: integer
  ru_nvcsw: integer
  ru_nivcsw: integer
end
```


## rwlock_t

```titan
record rwlock_t
end
```

```titan
function rwlock_t.new(): rwlock_t
function rwlock_t.rdlock_function(): foreign function(*void): void
function rwlock_t.rdunlock_function(): foreign function(*void): void
function rwlock_t.tryrdlock_function(): foreign function(*void): int
function rwlock_t.trywrlock_function(): foreign function(*void): int
function rwlock_t.wrlock_function(): foreign function(*void): void
function rwlock_t.wrunlock_function(): foreign function(*void): void
function rwlock_t:borrow(): foreign *void
function rwlock_t:destroy()
function rwlock_t:init(): integer
function rwlock_t:rdlock()
function rwlock_t:rdunlock()
function rwlock_t:tryrdlock(): integer
function rwlock_t:trywrlock(): integer
function rwlock_t:wrlock()
function rwlock_t:wrunlock()
```


## sem_t

```titan
record sem_t
end
```

```titan
function sem_t.new(): sem_t
function sem_t.post_function(): foreign function(*void): void
function sem_t.trywait_function(): foreign function(*void): int
function sem_t.wait_function(): foreign function(*void): void
function sem_t:borrow(): foreign *void
function sem_t:destroy()
function sem_t:init(value: integer): integer
function sem_t:post()
function sem_t:trywait(): integer
function sem_t:wait()
```


## shutdown_cb

```titan
type shutdown_cb = function (shutdown_t, integer): ()
```


## shutdown_t

```titan
record shutdown_t
end
```

```titan
function shutdown_t.new(): shutdown_t
function shutdown_t:as_req_t(): req_t
function shutdown_t:handle(): stream_t?
```


## signal_cb

```titan
type signal_cb = function (signal_t, integer): ()
```


## signal_t

```titan
record signal_t
end
```

```titan
function signal_t.new(): signal_t
function signal_t:as_handle_t(): handle_t
function signal_t:get_signum(): integer
```


## sockaddr_t

```titan
record sockaddr_t
end
```

```titan
function sockaddr_t:address_bytes(): string
function sockaddr_t:byte_length(): integer
function sockaddr_t:family(): integer
function sockaddr_t:flowinfo(): integer
function sockaddr_t:is_complete(): boolean
function sockaddr_t:port(): integer
function sockaddr_t:raw_bytes(): string?
function sockaddr_t:sa_len(): integer?
function sockaddr_t:scope_id(): integer
function sockaddr_t:set_flowinfo(value: integer)
function sockaddr_t:set_scope_id(value: integer)
```


## stat_t

```titan
record stat_t
  st_dev: integer
  st_mode: integer
  st_nlink: integer
  st_uid: integer
  st_gid: integer
  st_rdev: integer
  st_ino: integer
  st_size: integer
  st_blksize: integer
  st_blocks: integer
  st_flags: integer
  st_gen: integer
  st_atim: timespec_t
  st_mtim: timespec_t
  st_ctim: timespec_t
  st_birthtim: timespec_t
end
```


## statfs_t

```titan
record statfs_t
  f_type: integer
  f_bsize: integer
  f_blocks: integer
  f_bfree: integer
  f_bavail: integer
  f_files: integer
  f_ffree: integer
  f_frsize: integer
  f_spare: {integer}
end
```

`f_spare` is copied reserved native storage and has no portable semantic interpretation. The eight named native value fields are mapped separately.


## stdio_container_t

```titan
record stdio_container_t
  flags: integer
  data: stdio_data_t
end
```


## stdio_data_t

```titan
union stdio_data_t
  fd(file: integer)
  stream(handle: stream_t)
end
```

Use one alternative at a time. This union is not a bitmask.


## stream_t

```titan
union stream_t
  tcp(owner: tcp_t)
  pipe(owner: pipe_t)
  tty(owner: tty_t)
end
```

```titan
function stream_t:as_handle_t(): handle_t
```

Use one alternative at a time. This union is not a bitmask.

This is a finite owner-retaining view. Creating another view does not allocate or initialize a second native handle/request.


## symbol_t

```titan
record symbol_t
end
```

```titan
function symbol_t:library(): lib_t
function symbol_t:pointer(): foreign *void
```


## tcp_t

```titan
record tcp_t
end
```

```titan
function tcp_t.new(): tcp_t
function tcp_t:as_handle_t(): handle_t
function tcp_t:as_stream_t(): stream_t
```


## thread_options_t

```titan
record thread_options_t
  flags: integer
  stack_size: integer
end
```


## thread_t

```titan
record thread_t
end
```

```titan
function thread_t.new(): thread_t
function thread_t:create(entry: foreign function(*void): void, argument: foreign *void, argument_owner: value): integer
function thread_t:create_ex(options: thread_options_t, entry: foreign function(*void): void, argument: foreign *void, argument_owner: value): integer
function thread_t:detach(): integer
function thread_t:equal(other: thread_t): boolean
function thread_t:getaffinity(mask: owned char[]): integer
function thread_t:getname(capacity: integer): (integer, string?)
function thread_t:getpriority(): (integer, integer?)
function thread_t:join(): integer
function thread_t:setaffinity(mask: owned char[], oldmask: (owned char[])?): integer
function thread_t:setpriority(priority: integer): integer
```


## timer_cb

```titan
type timer_cb = function (timer_t): ()
```


## timer_t

```titan
record timer_t
end
```

```titan
function timer_t.new(): timer_t
function timer_t:as_handle_t(): handle_t
```


## timespec64_t

```titan
record timespec64_t
  tv_sec: integer
  tv_nsec: integer
end
```


## timespec_t

```titan
record timespec_t
  tv_sec: integer
  tv_nsec: integer
end
```


## timeval64_t

```titan
record timeval64_t
  tv_sec: integer
  tv_usec: integer
end
```


## timeval_t

```titan
record timeval_t
  tv_sec: integer
  tv_usec: integer
end
```


## tty_mode_t

```titan
union tty_mode_t
  TTY_MODE_NORMAL()
  TTY_MODE_RAW()
  TTY_MODE_IO()
  TTY_MODE_RAW_VT()
end
```

Use one alternative at a time. This union is not a bitmask.


## tty_t

```titan
record tty_t
end
```

```titan
function tty_t.new(): tty_t
function tty_t:as_handle_t(): handle_t
function tty_t:as_stream_t(): stream_t
```


## tty_vtermstate_t

```titan
union tty_vtermstate_t
  TTY_SUPPORTED()
  TTY_UNSUPPORTED()
end
```

Use one alternative at a time. This union is not a bitmask.


## udp_recv_cb

```titan
type udp_recv_cb = function (udp_t, integer, buf_t?, sockaddr_t?, integer): ()
```


## udp_send_cb

```titan
type udp_send_cb = function (udp_send_t, integer): ()
```


## udp_send_t

```titan
record udp_send_t
end
```

```titan
function udp_send_t.new(): udp_send_t
function udp_send_t:as_req_t(): req_t
function udp_send_t:get_handle(): udp_t?
```


## udp_t

```titan
record udp_t
end
```

```titan
function udp_t.new(): udp_t
function udp_t:as_handle_t(): handle_t
```


## utsname_t

```titan
record utsname_t
  sysname: string
  release: string
  version: string
  machine: string
end
```


## walk_cb

```titan
type walk_cb = function (handle_t, value): ()
```


## work_t

```titan
record work_t
end
```

```titan
function work_t.new(): work_t
function work_t:as_req_t(): req_t
function work_t:get_loop(): loop_t?
```


## write_cb

```titan
type write_cb = function (write_t, integer): ()
```


## write_t

```titan
record write_t
end
```

```titan
function write_t.new(): write_t
function write_t:as_req_t(): req_t
function write_t:handle(): stream_t?
function write_t:send_handle(): handle_t?
```


## Numeric levels and flags

OS/thread priority names are integer levels, not combinable flags. Thread-create/process/stdio/FS/TCP/UDP/poll/watcher flags are integers and may combine only as the relevant operation permits. True enum groups (run mode, loop option, handle/request/FS kinds, directory kind, clock, membership, TTY mode/vterm state) are tagged union values.

Inspect a returned enum with `case` and its variant, as in the
[TTY example](examples/signal_poll_tty.titan). Nominal unions use identity
equality: comparing a returned `handle_type.tty()` instance to the separately
constructed `uv.TTY` constant with `==` does not test its variant.

## Public constants

| Name | Exact declaration |
| --- | --- |
| `AF_INET` | `const AF_INET: integer?` |
| `AF_INET6` | `const AF_INET6: integer?` |
| `AF_UNIX` | `const AF_UNIX: integer?` |
| `AF_UNSPEC` | `const AF_UNSPEC: integer?` |
| `AI_ADDRCONFIG` | `const AI_ADDRCONFIG: integer?` |
| `AI_ALL` | `const AI_ALL: integer?` |
| `AI_CANONNAME` | `const AI_CANONNAME: integer?` |
| `AI_NUMERICHOST` | `const AI_NUMERICHOST: integer?` |
| `AI_NUMERICSERV` | `const AI_NUMERICSERV: integer?` |
| `AI_PASSIVE` | `const AI_PASSIVE: integer?` |
| `AI_V4MAPPED` | `const AI_V4MAPPED: integer?` |
| `ASYNC` | `const ASYNC = handle_type.async()` |
| `CHANGE` | `const CHANGE: integer?` |
| `CHECK` | `const CHECK = handle_type.check()` |
| `CLOCK_MONOTONIC` | `const CLOCK_MONOTONIC = clock_id.monotonic()` |
| `CLOCK_REALTIME` | `const CLOCK_REALTIME = clock_id.realtime()` |
| `CONNECT` | `const CONNECT = req_type.connect()` |
| `CREATE_PIPE` | `const CREATE_PIPE: integer?` |
| `DIRENT_BLOCK` | `const DIRENT_BLOCK = dirent_type_t.block()` |
| `DIRENT_CHAR` | `const DIRENT_CHAR = dirent_type_t.character()` |
| `DIRENT_DIR` | `const DIRENT_DIR = dirent_type_t.directory()` |
| `DIRENT_FIFO` | `const DIRENT_FIFO = dirent_type_t.fifo()` |
| `DIRENT_FILE` | `const DIRENT_FILE = dirent_type_t.file()` |
| `DIRENT_LINK` | `const DIRENT_LINK = dirent_type_t.link()` |
| `DIRENT_SOCKET` | `const DIRENT_SOCKET = dirent_type_t.socket()` |
| `DIRENT_UNKNOWN` | `const DIRENT_UNKNOWN = dirent_type_t.unknown()` |
| `DISCONNECT` | `const DISCONNECT: integer?` |
| `E2BIG` | `const E2BIG: integer?` |
| `EACCES` | `const EACCES: integer?` |
| `EADDRINUSE` | `const EADDRINUSE: integer?` |
| `EADDRNOTAVAIL` | `const EADDRNOTAVAIL: integer?` |
| `EAFNOSUPPORT` | `const EAFNOSUPPORT: integer?` |
| `EAGAIN` | `const EAGAIN: integer?` |
| `EAI_ADDRFAMILY` | `const EAI_ADDRFAMILY: integer?` |
| `EAI_AGAIN` | `const EAI_AGAIN: integer?` |
| `EAI_BADFLAGS` | `const EAI_BADFLAGS: integer?` |
| `EAI_BADHINTS` | `const EAI_BADHINTS: integer?` |
| `EAI_CANCELED` | `const EAI_CANCELED: integer?` |
| `EAI_FAIL` | `const EAI_FAIL: integer?` |
| `EAI_FAMILY` | `const EAI_FAMILY: integer?` |
| `EAI_MEMORY` | `const EAI_MEMORY: integer?` |
| `EAI_NODATA` | `const EAI_NODATA: integer?` |
| `EAI_NONAME` | `const EAI_NONAME: integer?` |
| `EAI_OVERFLOW` | `const EAI_OVERFLOW: integer?` |
| `EAI_PROTOCOL` | `const EAI_PROTOCOL: integer?` |
| `EAI_SERVICE` | `const EAI_SERVICE: integer?` |
| `EAI_SOCKTYPE` | `const EAI_SOCKTYPE: integer?` |
| `EALREADY` | `const EALREADY: integer?` |
| `EBADF` | `const EBADF: integer?` |
| `EBUSY` | `const EBUSY: integer?` |
| `ECANCELED` | `const ECANCELED: integer?` |
| `ECHARSET` | `const ECHARSET: integer?` |
| `ECONNABORTED` | `const ECONNABORTED: integer?` |
| `ECONNREFUSED` | `const ECONNREFUSED: integer?` |
| `ECONNRESET` | `const ECONNRESET: integer?` |
| `EDESTADDRREQ` | `const EDESTADDRREQ: integer?` |
| `EEXIST` | `const EEXIST: integer?` |
| `EFAULT` | `const EFAULT: integer?` |
| `EFBIG` | `const EFBIG: integer?` |
| `EFTYPE` | `const EFTYPE: integer?` |
| `EHOSTDOWN` | `const EHOSTDOWN: integer?` |
| `EHOSTUNREACH` | `const EHOSTUNREACH: integer?` |
| `EILSEQ` | `const EILSEQ: integer?` |
| `EINTR` | `const EINTR: integer?` |
| `EINVAL` | `const EINVAL: integer?` |
| `EIO` | `const EIO: integer?` |
| `EISCONN` | `const EISCONN: integer?` |
| `EISDIR` | `const EISDIR: integer?` |
| `ELOOP` | `const ELOOP: integer?` |
| `EMFILE` | `const EMFILE: integer?` |
| `EMLINK` | `const EMLINK: integer?` |
| `EMSGSIZE` | `const EMSGSIZE: integer?` |
| `ENAMETOOLONG` | `const ENAMETOOLONG: integer?` |
| `ENETDOWN` | `const ENETDOWN: integer?` |
| `ENETUNREACH` | `const ENETUNREACH: integer?` |
| `ENFILE` | `const ENFILE: integer?` |
| `ENOBUFS` | `const ENOBUFS: integer?` |
| `ENODATA` | `const ENODATA: integer?` |
| `ENODEV` | `const ENODEV: integer?` |
| `ENOENT` | `const ENOENT: integer?` |
| `ENOEXEC` | `const ENOEXEC: integer?` |
| `ENOMEM` | `const ENOMEM: integer?` |
| `ENONET` | `const ENONET: integer?` |
| `ENOPROTOOPT` | `const ENOPROTOOPT: integer?` |
| `ENOSPC` | `const ENOSPC: integer?` |
| `ENOSYS` | `const ENOSYS: integer?` |
| `ENOTCONN` | `const ENOTCONN: integer?` |
| `ENOTDIR` | `const ENOTDIR: integer?` |
| `ENOTEMPTY` | `const ENOTEMPTY: integer?` |
| `ENOTSOCK` | `const ENOTSOCK: integer?` |
| `ENOTSUP` | `const ENOTSUP: integer?` |
| `ENOTTY` | `const ENOTTY: integer?` |
| `ENXIO` | `const ENXIO: integer?` |
| `EOF` | `const EOF: integer?` |
| `EOVERFLOW` | `const EOVERFLOW: integer?` |
| `EPERM` | `const EPERM: integer?` |
| `EPIPE` | `const EPIPE: integer?` |
| `EPROTO` | `const EPROTO: integer?` |
| `EPROTONOSUPPORT` | `const EPROTONOSUPPORT: integer?` |
| `EPROTOTYPE` | `const EPROTOTYPE: integer?` |
| `ERANGE` | `const ERANGE: integer?` |
| `EREMOTEIO` | `const EREMOTEIO: integer?` |
| `EROFS` | `const EROFS: integer?` |
| `ERRNO_MAX` | `const ERRNO_MAX: integer?` |
| `ESHUTDOWN` | `const ESHUTDOWN: integer?` |
| `ESOCKTNOSUPPORT` | `const ESOCKTNOSUPPORT: integer?` |
| `ESPIPE` | `const ESPIPE: integer?` |
| `ESRCH` | `const ESRCH: integer?` |
| `ETIMEDOUT` | `const ETIMEDOUT: integer?` |
| `ETXTBSY` | `const ETXTBSY: integer?` |
| `EUNATCH` | `const EUNATCH: integer?` |
| `EXDEV` | `const EXDEV: integer?` |
| `FILE` | `const FILE = handle_type.file()` |
| `FS` | `const FS = req_type.fs()` |
| `FS_ACCESS` | `const FS_ACCESS = fs_type_t.access()` |
| `FS_CHMOD` | `const FS_CHMOD = fs_type_t.chmod()` |
| `FS_CHOWN` | `const FS_CHOWN = fs_type_t.chown()` |
| `FS_CLOSE` | `const FS_CLOSE = fs_type_t.close()` |
| `FS_CLOSEDIR` | `const FS_CLOSEDIR = fs_type_t.closedir()` |
| `FS_COPYFILE` | `const FS_COPYFILE = fs_type_t.copyfile()` |
| `FS_COPYFILE_EXCL` | `const FS_COPYFILE_EXCL: integer?` |
| `FS_COPYFILE_FICLONE` | `const FS_COPYFILE_FICLONE: integer?` |
| `FS_COPYFILE_FICLONE_FORCE` | `const FS_COPYFILE_FICLONE_FORCE: integer?` |
| `FS_CUSTOM` | `const FS_CUSTOM = fs_type_t.custom()` |
| `FS_EVENT` | `const FS_EVENT = handle_type.fs_event()` |
| `FS_EVENT_RECURSIVE` | `const FS_EVENT_RECURSIVE: integer?` |
| `FS_EVENT_STAT` | `const FS_EVENT_STAT: integer?` |
| `FS_EVENT_WATCH_ENTRY` | `const FS_EVENT_WATCH_ENTRY: integer?` |
| `FS_FCHMOD` | `const FS_FCHMOD = fs_type_t.fchmod()` |
| `FS_FCHOWN` | `const FS_FCHOWN = fs_type_t.fchown()` |
| `FS_FDATASYNC` | `const FS_FDATASYNC = fs_type_t.fdatasync()` |
| `FS_FSTAT` | `const FS_FSTAT = fs_type_t.fstat()` |
| `FS_FSYNC` | `const FS_FSYNC = fs_type_t.fsync()` |
| `FS_FTRUNCATE` | `const FS_FTRUNCATE = fs_type_t.ftruncate()` |
| `FS_FUTIME` | `const FS_FUTIME = fs_type_t.futime()` |
| `FS_F_OK` | `const FS_F_OK: integer?` |
| `FS_LCHOWN` | `const FS_LCHOWN = fs_type_t.lchown()` |
| `FS_LINK` | `const FS_LINK = fs_type_t.link()` |
| `FS_LSTAT` | `const FS_LSTAT = fs_type_t.lstat()` |
| `FS_LUTIME` | `const FS_LUTIME = fs_type_t.lutime()` |
| `FS_MKDIR` | `const FS_MKDIR = fs_type_t.mkdir()` |
| `FS_MKDTEMP` | `const FS_MKDTEMP = fs_type_t.mkdtemp()` |
| `FS_MKSTEMP` | `const FS_MKSTEMP = fs_type_t.mkstemp()` |
| `FS_OPEN` | `const FS_OPEN = fs_type_t.open()` |
| `FS_OPENDIR` | `const FS_OPENDIR = fs_type_t.opendir()` |
| `FS_O_APPEND` | `const FS_O_APPEND: integer?` |
| `FS_O_CREAT` | `const FS_O_CREAT: integer?` |
| `FS_O_DIRECT` | `const FS_O_DIRECT: integer?` |
| `FS_O_DIRECTORY` | `const FS_O_DIRECTORY: integer?` |
| `FS_O_DSYNC` | `const FS_O_DSYNC: integer?` |
| `FS_O_EXCL` | `const FS_O_EXCL: integer?` |
| `FS_O_EXLOCK` | `const FS_O_EXLOCK: integer?` |
| `FS_O_FILEMAP` | `const FS_O_FILEMAP: integer?` |
| `FS_O_NOATIME` | `const FS_O_NOATIME: integer?` |
| `FS_O_NOCTTY` | `const FS_O_NOCTTY: integer?` |
| `FS_O_NOFOLLOW` | `const FS_O_NOFOLLOW: integer?` |
| `FS_O_NONBLOCK` | `const FS_O_NONBLOCK: integer?` |
| `FS_O_RANDOM` | `const FS_O_RANDOM: integer?` |
| `FS_O_RDONLY` | `const FS_O_RDONLY: integer?` |
| `FS_O_RDWR` | `const FS_O_RDWR: integer?` |
| `FS_O_SEQUENTIAL` | `const FS_O_SEQUENTIAL: integer?` |
| `FS_O_SHORT_LIVED` | `const FS_O_SHORT_LIVED: integer?` |
| `FS_O_SYMLINK` | `const FS_O_SYMLINK: integer?` |
| `FS_O_SYNC` | `const FS_O_SYNC: integer?` |
| `FS_O_TEMPORARY` | `const FS_O_TEMPORARY: integer?` |
| `FS_O_TRUNC` | `const FS_O_TRUNC: integer?` |
| `FS_O_WRONLY` | `const FS_O_WRONLY: integer?` |
| `FS_POLL` | `const FS_POLL = handle_type.fs_poll()` |
| `FS_READ` | `const FS_READ = fs_type_t.read()` |
| `FS_READDIR` | `const FS_READDIR = fs_type_t.readdir()` |
| `FS_READLINK` | `const FS_READLINK = fs_type_t.readlink()` |
| `FS_REALPATH` | `const FS_REALPATH = fs_type_t.realpath()` |
| `FS_RENAME` | `const FS_RENAME = fs_type_t.rename()` |
| `FS_RMDIR` | `const FS_RMDIR = fs_type_t.rmdir()` |
| `FS_R_OK` | `const FS_R_OK: integer?` |
| `FS_SCANDIR` | `const FS_SCANDIR = fs_type_t.scandir()` |
| `FS_SENDFILE` | `const FS_SENDFILE = fs_type_t.sendfile()` |
| `FS_STAT` | `const FS_STAT = fs_type_t.stat()` |
| `FS_STATFS` | `const FS_STATFS = fs_type_t.statfs()` |
| `FS_SYMLINK` | `const FS_SYMLINK = fs_type_t.symlink()` |
| `FS_SYMLINK_DIR` | `const FS_SYMLINK_DIR: integer?` |
| `FS_SYMLINK_JUNCTION` | `const FS_SYMLINK_JUNCTION: integer?` |
| `FS_UNKNOWN` | `const FS_UNKNOWN = fs_type_t.unknown()` |
| `FS_UNLINK` | `const FS_UNLINK = fs_type_t.unlink()` |
| `FS_UTIME` | `const FS_UTIME = fs_type_t.utime()` |
| `FS_UTIME_NOW` | `const FS_UTIME_NOW: float?` |
| `FS_UTIME_OMIT` | `const FS_UTIME_OMIT: float?` |
| `FS_WRITE` | `const FS_WRITE = fs_type_t.write()` |
| `FS_W_OK` | `const FS_W_OK: integer?` |
| `FS_X_OK` | `const FS_X_OK: integer?` |
| `F_OK` | `const F_OK: integer?` |
| `GETADDRINFO` | `const GETADDRINFO = req_type.getaddrinfo()` |
| `GETNAMEINFO` | `const GETNAMEINFO = req_type.getnameinfo()` |
| `HANDLE` | `const HANDLE = handle_type.handle()` |
| `HANDLE_TYPE_MAX` | `const HANDLE_TYPE_MAX: integer?` |
| `IDLE` | `const IDLE = handle_type.idle()` |
| `IF_NAMESIZE` | `const IF_NAMESIZE: integer?` |
| `IGNORE` | `const IGNORE: integer?` |
| `INHERIT_FD` | `const INHERIT_FD: integer?` |
| `INHERIT_STREAM` | `const INHERIT_STREAM: integer?` |
| `IPPROTO_TCP` | `const IPPROTO_TCP: integer?` |
| `IPPROTO_UDP` | `const IPPROTO_UDP: integer?` |
| `JOIN_GROUP` | `const JOIN_GROUP = membership.JOIN_GROUP()` |
| `LEAVE_GROUP` | `const LEAVE_GROUP = membership.LEAVE_GROUP()` |
| `LOOP_BLOCK_SIGNAL` | `const LOOP_BLOCK_SIGNAL = loop_option.block_signal()` |
| `LOOP_USE_IO_URING_SQPOLL` | `const LOOP_USE_IO_URING_SQPOLL = loop_option.use_io_uring_sqpoll()` |
| `MAXHOSTNAMESIZE` | `const MAXHOSTNAMESIZE: integer?` |
| `METRICS_IDLE_TIME` | `const METRICS_IDLE_TIME = loop_option.metrics_idle_time()` |
| `NAMED_PIPE` | `const NAMED_PIPE = handle_type.named_pipe()` |
| `NI_DGRAM` | `const NI_DGRAM: integer?` |
| `NI_NAMEREQD` | `const NI_NAMEREQD: integer?` |
| `NI_NOFQDN` | `const NI_NOFQDN: integer?` |
| `NI_NUMERICHOST` | `const NI_NUMERICHOST: integer?` |
| `NI_NUMERICSERV` | `const NI_NUMERICSERV: integer?` |
| `NONBLOCK_PIPE` | `const NONBLOCK_PIPE: integer = 0x40` |
| `OVERLAPPED_PIPE` | `const OVERLAPPED_PIPE: integer?` |
| `PIPE_NO_TRUNCATE` | `const PIPE_NO_TRUNCATE: integer = 1` |
| `POLL` | `const POLL = handle_type.poll()` |
| `PREPARE` | `const PREPARE = handle_type.prepare()` |
| `PRIORITIZED` | `const PRIORITIZED: integer?` |
| `PRIORITY_ABOVE_NORMAL` | `const PRIORITY_ABOVE_NORMAL: integer?` |
| `PRIORITY_BELOW_NORMAL` | `const PRIORITY_BELOW_NORMAL: integer?` |
| `PRIORITY_HIGH` | `const PRIORITY_HIGH: integer?` |
| `PRIORITY_HIGHEST` | `const PRIORITY_HIGHEST: integer?` |
| `PRIORITY_LOW` | `const PRIORITY_LOW: integer?` |
| `PRIORITY_NORMAL` | `const PRIORITY_NORMAL: integer?` |
| `PROCESS` | `const PROCESS = handle_type.process()` |
| `PROCESS_DETACHED` | `const PROCESS_DETACHED: integer?` |
| `PROCESS_SETGID` | `const PROCESS_SETGID: integer?` |
| `PROCESS_SETUID` | `const PROCESS_SETUID: integer?` |
| `PROCESS_WINDOWS_FILE_PATH_EXACT_NAME` | `const PROCESS_WINDOWS_FILE_PATH_EXACT_NAME: integer?` |
| `PROCESS_WINDOWS_HIDE` | `const PROCESS_WINDOWS_HIDE: integer?` |
| `PROCESS_WINDOWS_HIDE_CONSOLE` | `const PROCESS_WINDOWS_HIDE_CONSOLE: integer?` |
| `PROCESS_WINDOWS_HIDE_GUI` | `const PROCESS_WINDOWS_HIDE_GUI: integer?` |
| `PROCESS_WINDOWS_VERBATIM_ARGUMENTS` | `const PROCESS_WINDOWS_VERBATIM_ARGUMENTS: integer?` |
| `RANDOM` | `const RANDOM = req_type.random()` |
| `READABLE` | `const READABLE: integer = 1` |
| `READABLE_PIPE` | `const READABLE_PIPE: integer?` |
| `RENAME` | `const RENAME: integer?` |
| `REQ` | `const REQ = req_type.req()` |
| `REQ_TYPE_MAX` | `const REQ_TYPE_MAX: integer?` |
| `RUN_DEFAULT` | `const RUN_DEFAULT = run_mode.default()` |
| `RUN_NOWAIT` | `const RUN_NOWAIT = run_mode.nowait()` |
| `RUN_ONCE` | `const RUN_ONCE = run_mode.once()` |
| `R_OK` | `const R_OK: integer?` |
| `SHUTDOWN` | `const SHUTDOWN = req_type.shutdown()` |
| `SIGABRT` | `const SIGABRT: integer?` |
| `SIGALRM` | `const SIGALRM: integer?` |
| `SIGBREAK` | `const SIGBREAK: integer?` |
| `SIGBUS` | `const SIGBUS: integer?` |
| `SIGCHLD` | `const SIGCHLD: integer?` |
| `SIGCONT` | `const SIGCONT: integer?` |
| `SIGFPE` | `const SIGFPE: integer?` |
| `SIGHUP` | `const SIGHUP: integer?` |
| `SIGILL` | `const SIGILL: integer?` |
| `SIGINT` | `const SIGINT: integer?` |
| `SIGIO` | `const SIGIO: integer?` |
| `SIGIOT` | `const SIGIOT: integer?` |
| `SIGKILL` | `const SIGKILL: integer?` |
| `SIGNAL` | `const SIGNAL = handle_type.signal()` |
| `SIGPIPE` | `const SIGPIPE: integer?` |
| `SIGPOLL` | `const SIGPOLL: integer?` |
| `SIGPROF` | `const SIGPROF: integer?` |
| `SIGPWR` | `const SIGPWR: integer?` |
| `SIGQUIT` | `const SIGQUIT: integer?` |
| `SIGRTMAX` | `const SIGRTMAX: integer?` |
| `SIGRTMIN` | `const SIGRTMIN: integer?` |
| `SIGSEGV` | `const SIGSEGV: integer?` |
| `SIGSTKFLT` | `const SIGSTKFLT: integer?` |
| `SIGSTOP` | `const SIGSTOP: integer?` |
| `SIGSYS` | `const SIGSYS: integer?` |
| `SIGTERM` | `const SIGTERM: integer?` |
| `SIGTRAP` | `const SIGTRAP: integer?` |
| `SIGTSTP` | `const SIGTSTP: integer?` |
| `SIGTTIN` | `const SIGTTIN: integer?` |
| `SIGTTOU` | `const SIGTTOU: integer?` |
| `SIGURG` | `const SIGURG: integer?` |
| `SIGUSR1` | `const SIGUSR1: integer?` |
| `SIGUSR2` | `const SIGUSR2: integer?` |
| `SIGVTALRM` | `const SIGVTALRM: integer?` |
| `SIGWINCH` | `const SIGWINCH: integer?` |
| `SIGXCPU` | `const SIGXCPU: integer?` |
| `SIGXFSZ` | `const SIGXFSZ: integer?` |
| `SOCK_DGRAM` | `const SOCK_DGRAM: integer?` |
| `SOCK_RAW` | `const SOCK_RAW: integer?` |
| `SOCK_STREAM` | `const SOCK_STREAM: integer?` |
| `STREAM` | `const STREAM = handle_type.stream()` |
| `S_IFBLK` | `const S_IFBLK: integer?` |
| `S_IFCHR` | `const S_IFCHR: integer?` |
| `S_IFDIR` | `const S_IFDIR: integer?` |
| `S_IFIFO` | `const S_IFIFO: integer?` |
| `S_IFLNK` | `const S_IFLNK: integer?` |
| `S_IFMT` | `const S_IFMT: integer?` |
| `S_IFREG` | `const S_IFREG: integer?` |
| `S_IFSOCK` | `const S_IFSOCK: integer?` |
| `S_IRGRP` | `const S_IRGRP: integer?` |
| `S_IROTH` | `const S_IROTH: integer?` |
| `S_IRUSR` | `const S_IRUSR: integer?` |
| `S_IWGRP` | `const S_IWGRP: integer?` |
| `S_IWOTH` | `const S_IWOTH: integer?` |
| `S_IWUSR` | `const S_IWUSR: integer?` |
| `S_IXGRP` | `const S_IXGRP: integer?` |
| `S_IXOTH` | `const S_IXOTH: integer?` |
| `S_IXUSR` | `const S_IXUSR: integer?` |
| `TCP` | `const TCP = handle_type.tcp()` |
| `TCP_IPV6ONLY` | `const TCP_IPV6ONLY: integer?` |
| `TCP_REUSEPORT` | `const TCP_REUSEPORT: integer?` |
| `THREAD_HAS_STACK_SIZE` | `const THREAD_HAS_STACK_SIZE: integer?` |
| `THREAD_NO_FLAGS` | `const THREAD_NO_FLAGS: integer?` |
| `THREAD_PRIORITY_ABOVE_NORMAL` | `const THREAD_PRIORITY_ABOVE_NORMAL: integer?` |
| `THREAD_PRIORITY_BELOW_NORMAL` | `const THREAD_PRIORITY_BELOW_NORMAL: integer?` |
| `THREAD_PRIORITY_HIGHEST` | `const THREAD_PRIORITY_HIGHEST: integer?` |
| `THREAD_PRIORITY_LOWEST` | `const THREAD_PRIORITY_LOWEST: integer?` |
| `THREAD_PRIORITY_NORMAL` | `const THREAD_PRIORITY_NORMAL: integer?` |
| `TIMER` | `const TIMER = handle_type.timer()` |
| `TTY` | `const TTY = handle_type.tty()` |
| `TTY_MODE_IO` | `const TTY_MODE_IO = tty_mode_t.TTY_MODE_IO()` |
| `TTY_MODE_NORMAL` | `const TTY_MODE_NORMAL = tty_mode_t.TTY_MODE_NORMAL()` |
| `TTY_MODE_RAW` | `const TTY_MODE_RAW = tty_mode_t.TTY_MODE_RAW()` |
| `TTY_MODE_RAW_VT` | `const TTY_MODE_RAW_VT = tty_mode_t.TTY_MODE_RAW_VT()` |
| `TTY_SUPPORTED` | `const TTY_SUPPORTED = tty_vtermstate_t.TTY_SUPPORTED()` |
| `TTY_UNSUPPORTED` | `const TTY_UNSUPPORTED = tty_vtermstate_t.TTY_UNSUPPORTED()` |
| `UDP` | `const UDP = handle_type.udp()` |
| `UDP_IPV6ONLY` | `const UDP_IPV6ONLY: integer?` |
| `UDP_LINUX_RECVERR` | `const UDP_LINUX_RECVERR: integer?` |
| `UDP_MMSG_CHUNK` | `const UDP_MMSG_CHUNK: integer?` |
| `UDP_MMSG_FREE` | `const UDP_MMSG_FREE: integer?` |
| `UDP_PARTIAL` | `const UDP_PARTIAL: integer?` |
| `UDP_RECVMMSG` | `const UDP_RECVMMSG: integer?` |
| `UDP_REUSEADDR` | `const UDP_REUSEADDR: integer?` |
| `UDP_REUSEPORT` | `const UDP_REUSEPORT: integer?` |
| `UDP_SEND` | `const UDP_SEND = req_type.udp_send()` |
| `UNKNOWN` | `const UNKNOWN: integer?` |
| `UNKNOWN_HANDLE` | `const UNKNOWN_HANDLE = handle_type.unknown()` |
| `UNKNOWN_REQ` | `const UNKNOWN_REQ = req_type.unknown()` |
| `VERSION_HEX` | `const VERSION_HEX: integer?` |
| `VERSION_IS_RELEASE` | `const VERSION_IS_RELEASE: integer?` |
| `VERSION_MAJOR` | `const VERSION_MAJOR: integer?` |
| `VERSION_MINOR` | `const VERSION_MINOR: integer?` |
| `VERSION_PATCH` | `const VERSION_PATCH: integer?` |
| `VERSION_SUFFIX` | `const VERSION_SUFFIX: string?` |
| `WORK` | `const WORK = req_type.work()` |
| `WRITABLE` | `const WRITABLE: integer = 2` |
| `WRITABLE_PIPE` | `const WRITABLE_PIPE: integer?` |
| `WRITE` | `const WRITE = req_type.write()` |
| `W_OK` | `const W_OK: integer?` |
| `X_OK` | `const X_OK: integer?` |
