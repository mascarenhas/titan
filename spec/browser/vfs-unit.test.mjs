// Unit and contract tests of the browser storage runtime: the guest WASI
// filesystem (titan-browser-vfs.mjs) over the vendored uwasi seams, its
// journal to the storage worker (titan-storage-worker.mjs), the SQLite
// service reactor (titan-runtime/browser/sqlite3_service.c) behind its wire
// frames, and the connection ledger (titan-browser-sql.mjs).
//
// A small C guest compiled with wasi-sdk stands in for a Titan image, and the
// frames below stand in for titan/sqlite3's Titan codec. Durable mounts run on
// an Origin Private File System double backed by real files: a write reaches
// its file only at flush() or close(), so a terminated worker loses exactly
// what a crashed browser worker loses.
//
//   WASI_SDK_PATH=... node --test spec/browser/vfs-unit.test.mjs
// The SQLite sources are the Makefile's $(SQLITE3_SRC_DIR) (`make sqlite3`
// fetches them). Builds are cached by input digest in $TMPDIR/titan-vfs-unit-*.
// Without wasi-sdk or those sources the Wasm cases skip, unless
// TITAN_REQUIRE_BROWSER_TOOLCHAIN=1 makes that a failure.
import {after, test} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {createWasiImports} from '../../titan-runtime/browser/titan-wasm-factory.mjs';
import {titanBrowserStorage} from '../../titan-runtime/browser/titan-browser-vfs.mjs';
import {titanBrowserSql} from '../../titan-runtime/browser/titan-browser-sql.mjs';
import {create} from '../../titan-runtime/browser/titan-browser.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');
const browser = join(root, 'titan-runtime/browser');
const release = /^SQLITE3_RELEASE\s*:=\s*(\d+)/m.exec(readFileSync(join(root, 'Makefile'), 'utf8'))[1];
const sqliteDir = join(root, `sqlite-autoconf-${release}`);
const wasiSdk = process.env.WASI_SDK_PATH;
const missing = !wasiSdk ? 'WASI_SDK_PATH is not set' :
  !existsSync(join(wasiSdk, 'bin/clang')) ? `${wasiSdk} has no bin/clang` :
  !existsSync(join(sqliteDir, 'sqlite3.c')) ? `${sqliteDir}/sqlite3.c is missing; run 'make sqlite3'` : undefined;
if (missing && process.env.TITAN_REQUIRE_BROWSER_TOOLCHAIN === '1') throw new Error(missing);
const wasm = {skip: missing};

// The service imports exactly this WASI surface, the `service:sqlite3` class.
const serviceImports = ['clock_time_get', 'environ_get', 'environ_sizes_get', 'fd_close', 'fd_fdstat_get',
  'fd_fdstat_set_flags', 'fd_filestat_get', 'fd_filestat_set_size', 'fd_prestat_dir_name', 'fd_prestat_get',
  'fd_read', 'fd_seek', 'fd_sync', 'fd_write', 'path_create_directory', 'path_filestat_get',
  'path_filestat_set_times', 'path_open', 'path_readlink', 'path_remove_directory', 'path_unlink_file',
  'poll_oneoff', 'proc_exit'];
const serviceFlags = ['--target=wasm32-wasip1', '-O2', '-std=c99', '-DSQLITE_THREADSAFE=0',
  '-DSQLITE_OMIT_LOAD_EXTENSION=1', '-DSQLITE_TEMP_STORE=3'];

const probeSource = String.raw`
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <stdio.h>
#define EXPORT(name) __attribute__((export_name(name)))
static const int modes[] = { O_RDONLY, O_RDWR | O_CREAT, O_WRONLY | O_CREAT | O_TRUNC, O_RDWR };
EXPORT("probe_open") int probe_open(const char *path, int mode) {
  int fd = open(path, modes[mode], 0644);
  return fd < 0 ? -errno : fd;
}
EXPORT("probe_pwrite") int probe_pwrite(int fd, const char *data, int length, int offset) {
  ssize_t count = pwrite(fd, data, (size_t)length, offset);
  return count < 0 ? -errno : (int)count;
}
EXPORT("probe_pread") int probe_pread(int fd, char *out, int length, int offset) {
  ssize_t count = pread(fd, out, (size_t)length, offset);
  return count < 0 ? -errno : (int)count;
}
EXPORT("probe_close") int probe_close(int fd) { return close(fd) ? -errno : 0; }
EXPORT("probe_unlink") int probe_unlink(const char *path) { return unlink(path) ? -errno : 0; }
EXPORT("probe_mkdir") int probe_mkdir(const char *path) { return mkdir(path, 0755) ? -errno : 0; }
EXPORT("probe_rename") int probe_rename(const char *from, const char *to) { return rename(from, to) ? -errno : 0; }
EXPORT("probe_link") int probe_link(const char *from, const char *to) { return link(from, to) ? -errno : 0; }
/* POSIX checks inside directory dir: 0, or check * 1000 + errno. */
EXPORT("probe_posix") int probe_posix(const char *dir) {
  char file[256], symbolic[256], hard[256], target[256];
  struct stat st;
  int fd;
  strcpy(file, dir); strcat(file, "/f");
  strcpy(symbolic, dir); strcat(symbolic, "/l");
  strcpy(hard, dir); strcat(hard, "/h");
  if ((fd = open(file, O_WRONLY | O_CREAT | O_TRUNC, 0644)) < 0 || write(fd, "AB", 2) != 2 || close(fd)) return 1000 + errno;
  if (symlink("f", symbolic) || lstat(symbolic, &st) || !S_ISLNK(st.st_mode)) return 2000 + errno;
  ssize_t length = readlink(symbolic, target, sizeof target);
  if (length != 1 || target[0] != 'f' || stat(symbolic, &st) || !S_ISREG(st.st_mode) || st.st_size != 2) return 3000 + errno;
  if (link(file, hard) || stat(file, &st) || st.st_nlink != 2) return 4000 + errno;
  if (unlink(hard) || stat(file, &st) || st.st_nlink != 1) return 5000 + errno;
  struct timespec times[2] = { { 1000000000, 0 }, { 1234567890, 0 } };
  if (utimensat(AT_FDCWD, file, times, 0) || stat(file, &st) || st.st_mtim.tv_sec != 1234567890) return 6000 + errno;
  if ((fd = open(file, O_WRONLY)) < 0 || fcntl(fd, F_SETFL, O_APPEND) || lseek(fd, 0, SEEK_SET) ||
      write(fd, "CD", 2) != 2 || close(fd)) return 7000 + errno;
  char bytes[8] = { 0 };
  if ((fd = open(file, O_RDONLY)) < 0 || read(fd, bytes, sizeof bytes) != 4 || close(fd) || memcmp(bytes, "ABCD", 4))
    return 8000 + errno;
  return 0;
}
`;

// An Origin Private File System double on real files, loaded in the worker.
// Data files share a byte quota; a write past it is short, as OPFS's is.
const opfsSource = String.raw`
import {appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';
const open = new Set();
let quota = Infinity, used = 0;
function busy() { return Object.assign(new Error('locked'), {name: 'NoModificationAllowedError'}); }
class SyncAccessHandle {
  constructor(path, log) {
    this.path = path;
    this.log = log;
    this.bytes = new Uint8Array(readFileSync(path));
    this.data = path.split('/').pop().startsWith('.uwasi.data.');
    if (this.data) used += this.bytes.byteLength;
  }
  read(buffer, {at = 0} = {}) {
    const count = Math.max(0, Math.min(buffer.byteLength, this.bytes.byteLength - at));
    buffer.set(this.bytes.subarray(at, at + count));
    return count;
  }
  write(data, {at = 0} = {}) {
    const growth = Math.max(0, at + data.byteLength - this.bytes.byteLength), room = this.data ? quota - used : Infinity;
    const count = growth > room ? Math.max(0, data.byteLength - (growth - room)) : data.byteLength;
    if (at + count > this.bytes.byteLength) this.truncate(at + count);
    this.bytes.set(data.subarray(0, count), at);
    return count;
  }
  truncate(size) {
    const next = new Uint8Array(size);
    next.set(this.bytes.subarray(0, Math.min(size, this.bytes.byteLength)));
    if (this.data) used += size - this.bytes.byteLength;
    this.bytes = next;
  }
  getSize() { return this.bytes.byteLength; }
  flush() { writeFileSync(this.path, this.bytes); appendFileSync(this.log, this.path + '\n'); }
  close() {
    this.flush();
    appendFileSync(this.log, 'closed ' + this.path + '\n');
    if (this.data) used -= this.bytes.byteLength;
    open.delete(this.path);
  }
}
class FileHandle {
  constructor(path, log) { this.kind = 'file'; this.name = path.split('/').pop(); this.path = path; this.log = log; }
  async createSyncAccessHandle() {
    if (open.has(this.path)) throw busy();
    open.add(this.path);
    return new SyncAccessHandle(this.path, this.log);
  }
}
class DirectoryHandle {
  constructor(path, log) { this.kind = 'directory'; this.name = path.split('/').pop(); this.path = path; this.log = log; }
  async getFileHandle(name, {create = false} = {}) {
    const path = join(this.path, name);
    if (!existsSync(path)) {
      if (!create) throw Object.assign(new Error(name), {name: 'NotFoundError'});
      writeFileSync(path, new Uint8Array(0));
    }
    return new FileHandle(path, this.log);
  }
  async getDirectoryHandle(name, {create = false} = {}) {
    const path = join(this.path, name);
    if (!existsSync(path) && create) mkdirSync(path);
    return new DirectoryHandle(path, this.log);
  }
  async removeEntry(name) { rmSync(join(this.path, name), {recursive: true}); }
  async *entries() {
    for (const name of readdirSync(this.path)) {
      const path = join(this.path, name);
      yield [name, statSync(path).isDirectory() ? new DirectoryHandle(path, this.log) : new FileHandle(path, this.log)];
    }
  }
}
export function install(path, dataQuota = Infinity) {
  quota = dataQuota;
  mkdirSync(path, {recursive: true});
  Object.defineProperty(globalThis.navigator, 'storage', {value: {getDirectory: async () => new DirectoryHandle(path, join(path, '..', 'flushes.log'))}});
}
`;

let artifacts;
function build() {
  if (artifacts) return artifacts;
  const service = readFileSync(join(browser, 'sqlite3_service.c'));
  const hash = createHash('sha256').update(service).update(readFileSync(join(sqliteDir, 'sqlite3.c')))
    .update(probeSource).update(serviceFlags.join(' ')).digest('hex').slice(0, 16);
  const dir = join(tmpdir(), `titan-vfs-unit-${hash}`);
  const clang = join(wasiSdk, 'bin/clang');
  mkdirSync(dir, {recursive: true});
  if (!existsSync(join(dir, 'titan-sqlite3-service.wasm'))) {
    execFileSync(clang, [...serviceFlags, '-Wall', '-Wextra', '-Werror', '-I', sqliteDir, '-c',
      join(browser, 'sqlite3_service.c'), '-o', join(dir, 'service.o')]);
    execFileSync(clang, [...serviceFlags, '-c', join(sqliteDir, 'sqlite3.c'), '-o', join(dir, 'sqlite3.o')]);
    execFileSync(clang, ['--target=wasm32-wasip1', '-mexec-model=reactor', '-Wl,--gc-sections', '-Wl,--strip-all',
      join(dir, 'service.o'), join(dir, 'sqlite3.o'), '-o', join(dir, 'titan-sqlite3-service.wasm')]);
  }
  if (!existsSync(join(dir, 'probe.wasm'))) {
    writeFileSync(join(dir, 'probe.c'), probeSource);
    execFileSync(clang, ['--target=wasm32-wasip1', '-O2', '-mexec-model=reactor', join(dir, 'probe.c'),
      '-Wl,--export=malloc', '-o', join(dir, 'probe.wasm')]);
  }
  writeFileSync(join(dir, 'opfs.mjs'), opfsSource);
  const bytes = readFileSync(join(dir, 'titan-sqlite3-service.wasm'));
  artifacts = {dir, service: join(dir, 'titan-sqlite3-service.wasm'), bytes,
    sha256: createHash('sha256').update(bytes).digest('hex'),
    probe: new WebAssembly.Module(readFileSync(join(dir, 'probe.wasm')))};
  return artifacts;
}

// The service built to start every slot at the last generation, so the
// first close of a slot retires it.
function lastGeneration() {
  const {dir} = build(), clang = join(wasiSdk, 'bin/clang'), service = join(dir, 'titan-sqlite3-service-last.wasm');
  if (!existsSync(service)) {
    execFileSync(clang, [...serviceFlags, '-DTITAN_SQL_SVC_FIRST_GENERATION=0xffffffffu', '-I', sqliteDir, '-c',
      join(browser, 'sqlite3_service.c'), '-o', join(dir, 'service-last.o')]);
    execFileSync(clang, ['--target=wasm32-wasip1', '-mexec-model=reactor', '-Wl,--gc-sections', '-Wl,--strip-all',
      join(dir, 'service-last.o'), join(dir, 'sqlite3.o'), '-o', service]);
  }
  return {service, sha256: createHash('sha256').update(readFileSync(service)).digest('hex')};
}

// A worker that sees `store` as its Origin Private File System.
function workerWith(store, quota) {
  const {dir} = build(), path = join(store, '..', 'worker.mjs');
  writeFileSync(path, `import {install} from ${JSON.stringify(pathToFileURL(join(dir, 'opfs.mjs')).href)};\n` +
    `install(${JSON.stringify(store)}${quota === undefined ? '' : `, ${quota}`});\n` +
    `await import(${JSON.stringify(pathToFileURL(join(browser, 'titan-storage-worker.mjs')).href)});\n`);
  return pathToFileURL(path).href;
}

const scratch = mkdtempSync(join(tmpdir(), 'titan-vfs-unit-'));
process.on('exit', () => rmSync(scratch, {recursive: true, force: true}));
let stores = 0;
// A failed case still stops its workers, so the run ends.
const live = new Set();
after(() => { for (const storage of live) storage.terminate(); });
function newStore() {
  const dir = join(scratch, `store-${++stores}`);
  mkdirSync(dir);
  return join(dir, 'opfs');
}

// One instance's storage as the loader drives it: `states` is the loader's
// Lua-state table and `sqlite` links titan-browser-sql.mjs.
async function storageOf({store, quota, vfs, sqlite = true, states = new Map([[1, 'open']]), service = build()} = {}) {
  const owner = {states, options: {locateFile: name => name === 'app.sqlite3.wasm' ? pathToFileURL(service.service).href :
    store ? workerWith(store, quota) : pathToFileURL(join(browser, 'titan-storage-worker.mjs')).href}};
  const image = {directory: '', worker: 'app.worker.mjs', sqlite: {wasm: 'app.sqlite3.wasm', sha256: service.sha256},
    sql: sqlite ? titanBrowserSql : undefined};
  const storage = titanBrowserStorage(owner, vfs, image);
  live.add(storage);
  await storage.start();
  return storage;
}

// The C guest on `storage`'s WASI imports, with the factory's standard streams.
function guestOf(storage) {
  const context = {memory: undefined,
    get HEAPU8() { return new Uint8Array(this.memory.buffer); },
    get HEAPU32() { return new Uint32Array(this.memory.buffer); }};
  const base = createWasiImports({output() {}, options: {env: []}}, context, message => { throw new Error(message); });
  const {wasi, env} = storage.imports(context, base);
  const instance = new WebAssembly.Instance(build().probe, {wasi_snapshot_preview1: wasi});
  context.memory = instance.exports.memory;
  instance.exports._initialize();
  const exports = instance.exports;
  const bytes = value => typeof value === 'string' ? new TextEncoder().encode(value) : value;
  const place = value => {
    const data = bytes(value), at = exports.malloc(data.byteLength + 1);
    context.HEAPU8.set(data, at);
    context.HEAPU8[at + data.byteLength] = 0;
    return at;
  };
  return {env,
    open: (path, mode) => exports.probe_open(place(path), mode),
    pwrite: (fd, data, offset) => exports.probe_pwrite(fd, place(data), bytes(data).byteLength, offset),
    pread(fd, length, offset) {
      const at = exports.malloc(length), count = exports.probe_pread(fd, at, length, offset);
      return count < 0 ? count : new TextDecoder().decode(context.HEAPU8.slice(at, at + count));
    },
    close: fd => exports.probe_close(fd),
    unlink: path => exports.probe_unlink(place(path)),
    mkdir: path => exports.probe_mkdir(place(path)),
    rename: (from, to) => exports.probe_rename(place(from), place(to)),
    link: (from, to) => exports.probe_link(place(from), place(to)),
    posix: dir => exports.probe_posix(place(dir)),
  };
}

function text(storage, path) {
  const node = storage.fileSystem.lookup(path);
  return node && new TextDecoder().decode(node.content);
}

const sync = (storage, fd) => storage.vfs('sync', fd === undefined ? null : BigInt(fd)).promise;

// Frames as titan/sqlite3's codec builds them (wire format version 1).
const OP = {OPEN: 1, PREPARE: 2, EXECUTE: 3, QUERY: 4, FETCH: 5, RESET: 6, FINALIZE: 7, CLOSE: 8, CLOSE_CONN: 9,
  AUTOCOMMIT: 10, BEGIN: 11, COMMIT: 12, ROLLBACK: 13};
function frame(op, handle = 0n, body = [], count = 0) {
  const parts = body.map(part => typeof part === 'string' ? withLength(new TextEncoder().encode(part)) : part);
  const out = new Uint8Array(16 + parts.reduce((total, part) => total + part.byteLength, 0));
  const view = new DataView(out.buffer);
  out[0] = op;
  out[1] = 1;
  view.setUint32(4, count, true);
  view.setBigUint64(8, handle, true);
  let at = 16;
  for (const part of parts) { out.set(part, at); at += part.byteLength; }
  return out;
}
function withLength(bytes, tag) {
  const out = new Uint8Array(bytes.byteLength + (tag === undefined ? 4 : 5)), view = new DataView(out.buffer);
  if (tag !== undefined) out[0] = tag;
  view.setUint32(tag === undefined ? 0 : 1, bytes.byteLength, true);
  out.set(bytes, out.byteLength - bytes.byteLength);
  return out;
}
function cell(value) {
  if (value === null) return Uint8Array.of(5);
  const out = new Uint8Array(9), view = new DataView(out.buffer);
  if (typeof value === 'bigint') { out[0] = 1; view.setBigInt64(1, value, true); return out; }
  if (typeof value === 'number') { out[0] = 2; view.setFloat64(1, value, true); return out; }
  return typeof value === 'string' ? withLength(new TextEncoder().encode(value), 3) : withLength(value, 4);
}
function decode(reply) {
  const view = new DataView(reply.buffer, reply.byteOffset, reply.byteLength);
  let at = 16;
  const u8 = () => view.getUint8(at++);
  const u32 = () => { at += 4; return view.getUint32(at - 4, true); };
  const string = () => {
    const length = u32();
    if (length === 0xffffffff) return null;
    at += length;
    return new TextDecoder().decode(reply.subarray(at - length, at));
  };
  const value = () => {
    const tag = u8();
    if (tag === 1) { at += 8; return view.getBigInt64(at - 8, true); }
    if (tag === 2) { at += 8; return view.getFloat64(at - 8, true); }
    if (tag === 3) return string();
    if (tag === 4) { const length = u32(); at += length; return reply.slice(at - length, at); }
    return null;
  };
  const result = {op: reply[0], status: reply[1], flags: reply[2], handle: view.getBigUint64(8, true), u8, u32, string, value,
    row: count => u8() ? Array.from({length: count}, value) : undefined,
    i64: () => { at += 8; return view.getBigInt64(at - 8, true); },
    get end() { return at === reply.byteLength; }};
  if (result.status !== 0) {
    Object.assign(result, {code: view.getInt32(16, true), extended: view.getInt32(20, true)});
    at = 24;
    result.message = string();
    result.cleanupCode = u32();
    result.cleanup = string();
  }
  return result;
}

// A connection driven through the titan:sqlite3 binding of one state, run in
// the working directory `cwd` when given.
function client(storage, state = 1, cwd = undefined) {
  const call = async (op, handle, body, count) => {
    const request = storage.sql.binding(state)('call', frame(op, handle, body, count), cwd);
    assert.equal(request.kind, 'retained');
    return decode(await request.promise);
  };
  const ok = async (...args) => {
    const reply = await call(...args);
    assert.equal(reply.status, 0, reply.message);
    return reply;
  };
  return {
    call, ok,
    open: async path => (await ok(OP.OPEN, 0n, [path])).handle,
    async run(conn, sql, args = []) {
      const statement = await ok(OP.PREPARE, conn, [sql]);
      const reply = await call(OP.EXECUTE, statement.handle, args.map(cell), args.length);
      await ok(OP.FINALIZE, statement.handle);
      assert.equal(reply.status, 0, reply.message);
      return reply.i64();
    },
    async rows(conn, sql, args = []) {
      const statement = await ok(OP.PREPARE, conn, [sql]);
      statement.u32();
      const columns = statement.u32(), rows = [];
      let reply = await ok(OP.QUERY, statement.handle, args.map(cell), args.length);
      assert.equal(reply.u32(), columns);
      for (let index = 0; index < columns; index++) { reply.string(); reply.string(); }
      for (let row = reply.row(columns); row; row = reply.row(columns)) {
        rows.push(row);
        reply = await ok(OP.FETCH, statement.handle);
      }
      await ok(OP.FINALIZE, statement.handle);
      return rows;
    },
  };
}

// One frame straight to the service, past the ledger: what a handle means there.
const raw = async (storage, ...args) => decode(await storage.dispatch(frame(...args)));

test('the checked-in uwasi bundle and storage-core copy are what the builder produces', () => {
  execFileSync(process.execPath, [join(root, 'scripts/build_uwasi_bundle.mjs'), '--check'], {stdio: 'pipe'});
  const declarations = [];
  for (const file of ['titan-wasm-factory.mjs', 'titan-browser-vfs.mjs', 'titan-browser-sql.mjs']) {
    const source = readFileSync(join(browser, file), 'utf8');
    if (file !== 'titan-wasm-factory.mjs') {
      // An image module embeds the file: one exported function, no imports.
      assert.equal(source.match(/^\s*(import|export)\s.*$/gm).length, 1, file);
      assert.match(source, /^export function titanBrowser(Storage|Sql)\(/m);
      // Module names are POSIX paths on every host.
      assert.doesNotMatch(source, /^\/\/ vendor\/uwasi\/src\/.*\\/m);
    }
    declarations.push(source.replace(/^export function /gm, 'function ').replace(/^export default \w+;\s*$/m, ''));
  }
  // Beside the factory in one module scope, no top-level name collides.
  assert.doesNotThrow(() => new Function(declarations.join('\n')));
});

test('the service reactor exports its four entries and imports only the service:sqlite3 WASI surface', wasm, () => {
  const {bytes, dir} = build(), module = new WebAssembly.Module(bytes);
  assert.deepEqual(WebAssembly.Module.exports(module).map(entry => `${entry.name}:${entry.kind}`).sort(),
    ['_initialize:function', 'memory:memory', 'titan_sql_svc_alloc:function', 'titan_sql_svc_dispatch:function',
      'titan_sql_svc_free:function']);
  const imports = WebAssembly.Module.imports(module);
  assert.deepEqual(imports.map(entry => entry.module), imports.map(() => 'wasi_snapshot_preview1'));
  assert.deepEqual(imports.map(entry => entry.name).sort(), serviceImports);
  const undefinedSymbols = execFileSync(join(wasiSdk, 'bin/llvm-nm'), ['-u', join(dir, 'service.o'), join(dir, 'sqlite3.o')],
    {encoding: 'utf8'});
  assert.doesNotMatch(undefinedSymbols, /\b(dlopen|dlsym|dlclose|dlerror|getentropy|__wasi_random_get|lua_\w+)\b/);
});

test('the guest WASI filesystem keeps POSIX semantics, with and without the storage worker', wasm, async () => {
  const plain = await storageOf({sqlite: false});
  assert.equal(plain.worker, undefined, 'an ephemeral filesystem needs no worker');
  assert.equal(guestOf(plain).posix('/tmp'), 0);
  const store = newStore();
  const mirrored = await storageOf({store, vfs: {mounts: {'/data': {backend: 'opfs'}}}});
  const guest = guestOf(mirrored);
  assert.equal(guest.mkdir('/tmp/p'), 0);
  assert.equal(guest.posix('/tmp/p'), 0);
  assert.equal(guest.mkdir('/data/p'), 0);
  // The durable store keeps one name per file: the hard-link step fails.
  assert.equal(guest.posix('/data/p'), 4000 + 58);
  assert.equal(guest.rename('/tmp/p/f', '/data/f'), -75, 'a name never crosses a mount');
  assert.equal(guest.rename('/data', '/moved'), -10, 'a mount root stays mounted');
  await sync(mirrored);
  assert.equal(await mirrored.dispose(), false);
  const reopened = await storageOf({store, vfs: {mounts: {'/data': {backend: 'opfs'}}}});
  assert.equal(text(reopened, '/data/p/f'), 'AB');
  assert.equal(reopened.fileSystem.lookup('/data/p/l').target, 'f');
  assert.equal(reopened.fileSystem.lookup('/tmp/p'), null, '/tmp is ephemeral');
  await reopened.dispose();
});

test('PB-1: an unlinked open file keeps its bytes and its recreated name keeps its own', wasm, async () => {
  const store = newStore(), vfs = {mounts: {'/data': {backend: 'opfs'}}};
  const storage = await storageOf({store, vfs}), guest = guestOf(storage);
  const old = guest.open('/data/p', 1);
  assert.equal(guest.pwrite(old, 'first', 0), 5);
  assert.equal(guest.unlink('/data/p'), 0);
  const fresh = guest.open('/data/p', 1);
  assert.equal(guest.pwrite(fresh, 'N2', 0), 2);
  assert.equal(guest.pwrite(old, 'OLD', 0), 3);
  assert.equal(guest.pread(old, 5, 0), 'OLDst');
  assert.equal(text(storage, '/data/p'), 'N2');
  await sync(storage, fresh);
  assert.equal(guest.close(old), 0);
  assert.equal(guest.close(fresh), 0);
  await sync(storage);
  assert.equal(storage.storage.nodes.size, [...storage.storage.nodes.values()].filter(node => node.type !== 'file' ||
    node.nlink > 0).length, 'the unlinked node was released');
  await storage.dispose();
  const reopened = await storageOf({store, vfs});
  assert.equal(text(reopened, '/data/p'), 'N2');
  await reopened.dispose();
});

test('PB-1: an acknowledgement of an earlier write never overwrites a later one', wasm, async () => {
  const store = newStore(), vfs = {mounts: {'/data': {backend: 'opfs'}}};
  const storage = await storageOf({store, vfs}), guest = guestOf(storage);
  const task1 = guest.open('/data/q', 1), task2 = guest.open('/data/q', 3);
  assert.equal(guest.pwrite(task1, 'AAAA', 0), 4);
  const flushed = sync(storage, task1);
  // While the first write's flush is parked, the second lands synchronously.
  assert.equal(guest.pwrite(task2, 'BBBB', 0), 4);
  await flushed;
  assert.equal(text(storage, '/data/q'), 'BBBB');
  assert.equal(storage.journal.length, 1, 'only the later write awaits its acknowledgement');
  await sync(storage, task2);
  assert.equal(storage.journal.length, 0);
  const flushes = readFileSync(join(store, '..', 'flushes.log'), 'utf8');
  assert.match(flushes, /\.uwasi\.data\.\d+\n/, 'sync flushed the data file');
  guest.close(task1);
  guest.close(task2);
  await storage.dispose();
  const reopened = await storageOf({store, vfs});
  assert.equal(text(reopened, '/data/q'), 'BBBB');
  await reopened.dispose();
});

test('crash durability: a flushed write and a committed transaction survive a terminated worker', wasm, async () => {
  const store = newStore(), vfs = {mounts: {'/data': {backend: 'opfs'}}};
  const storage = await storageOf({store, vfs}), guest = guestOf(storage), sql = client(storage);
  const fd = guest.open('/data/flushed', 1), applied = guest.open('/data/applied', 1);
  const unflushed = guest.open('/data/unflushed', 1);
  guest.pwrite(fd, 'kept', 0);
  await sync(storage, fd);
  // Applied by the worker but never flushed: not durable.
  guest.pwrite(applied, 'gone', 0);
  await sync(storage);
  const conn = await sql.open('/data/test.db');
  await sql.run(conn, 'CREATE TABLE t(x)');
  await sql.run(conn, 'INSERT INTO t VALUES (42)');
  guest.pwrite(unflushed, 'lost', 0);
  storage.terminate();
  assert.equal(await storage.dispose(), true, 'unacknowledged changes are reported lost');
  const reopened = await storageOf({store, vfs});
  assert.equal(text(reopened, '/data/flushed'), 'kept');
  assert.equal(text(reopened, '/data/applied'), '');
  assert.equal(text(reopened, '/data/unflushed'), '');
  const again = client(reopened);
  assert.deepEqual(await again.rows(await again.open('/data/test.db'), 'SELECT x FROM t'), [[42n]]);
  await reopened.dispose();
});

test('D16: the loader\'s dispose({force: true}) stops a running statement and rejects DISPOSED_DIRTY', wasm, async () => {
  const {service, sha256} = build();
  let storage, failLoad;
  const instance = create(() => new Promise((_, reject) => { failLoad = reject; }), {vfs: {},
    locateFile: name => pathToFileURL(name === 'app.sqlite3.wasm' ? service : join(browser, 'titan-storage-worker.mjs')).href},
  {identity: 'a'.repeat(64), wasm: 'app.wasm', directory: '', worker: 'app.worker.mjs',
    sqlite: {wasm: 'app.sqlite3.wasm', sha256}, sql: titanBrowserSql,
    storage: (...args) => (storage = titanBrowserStorage(...args))});
  live.add(storage);
  const initializing = instance.initialize();
  while (!failLoad) await new Promise(resolve => setTimeout(resolve, 5));
  storage.owner.states.set(1, 'open');
  const owner = storage.owner;
  const sql = client(storage), conn = await sql.open(':memory:');
  const statement = await sql.ok(OP.PREPARE, conn, ['WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL ' +
    'SELECT i + 1 FROM n WHERE i < 300000000) SELECT count(*) FROM n']);
  const abandoned = sql.call(OP.QUERY, statement.handle);
  const disposing = instance.dispose({force: true});
  failLoad(new Error('the image never loads'));
  await assert.rejects(initializing);
  await assert.rejects(abandoned, /terminated/);
  await assert.rejects(disposing, error => error.code === 'TITAN_BROWSER_DISPOSED_DIRTY');
  assert.equal(owner.storage, undefined, 'a disposed instance keeps no storage');
  assert.equal(storage.fileSystem, undefined, 'nor the guest\'s files');
  assert.equal(storage.fds, undefined);
  await assert.rejects(instance.dispose({force: 'yes'}), TypeError);
});

test('statement file changes (INSERT ... RETURNING, PRAGMA) reach the guest mirror', wasm, async () => {
  const storage = await storageOf(), sql = client(storage);
  const conn = await sql.open('/tmp/mirror.db');
  await sql.run(conn, 'CREATE TABLE t(id INTEGER PRIMARY KEY, v BLOB)');
  assert.deepEqual(await sql.rows(conn, 'INSERT INTO t(v) VALUES (?) RETURNING id', [new Uint8Array(100)]), [[1n]]);
  const database = storage.fileSystem.lookup('/tmp/mirror.db').content;
  assert.equal(new TextDecoder().decode(database.subarray(0, 15)), 'SQLite format 3');
  assert.equal(storage.fileSystem.lookup('/tmp/mirror.db-journal'), null, 'the journal came and went');
  await sql.run(conn, 'PRAGMA user_version = 7');
  assert.equal(new DataView(storage.fileSystem.lookup('/tmp/mirror.db').content.buffer).getUint32(60), 7);
  await storage.dispose();
});

test('maxHydratedBytes bounds both replicas under concurrent guest growth and a held unlinked file', wasm, async () => {
  const limit = 96 * 1024, store = newStore(), vfs = {mounts: {'/data': {backend: 'opfs'}}, maxHydratedBytes: limit};
  const storage = await storageOf({store, vfs}), guest = guestOf(storage), sql = client(storage);
  // Unlinked but open on the guest: the worker counts it until released.
  const held = guest.open('/data/held', 1);
  assert.equal(guest.pwrite(held, 'h'.repeat(30 * 1024), 0), 30 * 1024);
  assert.equal(guest.unlink('/data/held'), 0);
  const conn = await sql.open('/data/q.db');
  await sql.run(conn, 'CREATE TABLE t(v BLOB)');
  const insert = await sql.ok(OP.PREPARE, conn, ['INSERT INTO t VALUES (zeroblob(4096))']);
  let reply;
  for (let row = 0; row < 64 && !reply; row++) {
    const result = await sql.call(OP.EXECUTE, insert.handle);
    if (result.status !== 0) reply = result;
    assert.ok(storage.storage.resident <= limit);
  }
  assert.equal(reply?.code, 13, 'SQLITE_FULL');
  // While a statement runs, the guest may use half of what is free.
  const grow = await sql.ok(OP.PREPARE, conn, ['DELETE FROM t WHERE 0']);
  const running = sql.call(OP.EXECUTE, grow.handle), free = limit - storage.storage.resident;
  const fd = guest.open('/data/g', 1);
  assert.equal(guest.pwrite(fd, 'g'.repeat(free), 0), -51, 'ENOSPC past the guest\'s share');
  assert.equal((await running).status, 0);
  assert.ok(storage.storage.resident <= limit);
  await sql.ok(OP.FINALIZE, insert.handle);
  await sql.ok(OP.FINALIZE, grow.handle);
  await sql.ok(OP.CLOSE, conn);
  guest.close(held);
  guest.close(fd);
  await storage.dispose();
  const reopened = await storageOf({store, vfs});
  assert.ok(reopened.storage.resident <= limit);
  assert.equal(reopened.fileSystem.lookup('/data/held'), null);
  await reopened.dispose();
});

test('a file the guest holds after unlinking it keeps its stored bytes and their count on the worker', wasm, async () => {
  const limit = 128 * 1024, store = newStore(), vfs = {mounts: {'/data': {backend: 'opfs'}}, maxHydratedBytes: limit};
  const storage = await storageOf({store, vfs}), guest = guestOf(storage), sql = client(storage);
  const held = guest.open('/data/held', 1);
  assert.equal(guest.pwrite(held, 'h'.repeat(80 * 1024), 0), 80 * 1024);
  await sync(storage, held);
  assert.equal(guest.unlink('/data/held'), 0);
  assert.equal(guest.pwrite(held, 'H', 0), 1);
  assert.equal(guest.pread(held, 2, 0), 'Hh');
  assert.equal(guest.close(held), 0);
  // Released and dropped on both sides, so a statement gets half of a nearly empty store.
  const conn = await sql.open('/data/q.db');
  await sql.run(conn, 'CREATE TABLE t(v BLOB)');
  assert.equal(await sql.run(conn, 'INSERT INTO t VALUES (zeroblob(24 * 1024))'), 1n);
  await sql.ok(OP.CLOSE, conn);
  await storage.dispose();
  const reopened = await storageOf({store, vfs});
  assert.ok(reopened.storage.resident < 64 * 1024, `${reopened.storage.resident} bytes resident`);
  await reopened.dispose();
});

test('PB-1: a guest write made during a statement is replayed over the statement\'s changes', wasm, async () => {
  const store = newStore(), vfs = {mounts: {'/data': {backend: 'opfs'}}};
  const storage = await storageOf({store, vfs}), guest = guestOf(storage), sql = client(storage);
  const conn = await sql.open('/data/x.db');
  await sql.run(conn, 'CREATE TABLE t(x)');
  const insert = await sql.ok(OP.PREPARE, conn, ['INSERT INTO t VALUES (randomblob(10000))']);
  const running = sql.call(OP.EXECUTE, insert.handle);
  // The worker applies this write after the statement, which rewrites page 1.
  const fd = guest.open('/data/x.db', 3);
  assert.equal(guest.pwrite(fd, 'GUEST', 100), 5);
  assert.equal((await running).status, 0);
  const mirror = storage.fileSystem.lookup('/data/x.db').content.slice();
  assert.equal(new TextDecoder().decode(mirror.subarray(100, 105)), 'GUEST');
  await sync(storage, fd);
  guest.close(fd);
  await sql.ok(OP.FINALIZE, insert.handle);
  await sql.ok(OP.CLOSE, conn);
  await storage.dispose();
  const reopened = await storageOf({store, vfs});
  assert.deepEqual(reopened.fileSystem.lookup('/data/x.db').content, mirror, 'the worker holds the guest\'s bytes');
  await reopened.dispose();
});

test('hydrating a durable mount past maxHydratedBytes fails initialization with RangeError and closes its stores', wasm, async () => {
  const store = newStore(), vfs = {mounts: {'/a': {backend: 'opfs'}, '/b': {backend: 'opfs'}}};
  const storage = await storageOf({store, vfs}), guest = guestOf(storage), fd = guest.open('/b/big', 1);
  guest.pwrite(fd, 'x'.repeat(4096), 0);
  await sync(storage, fd);
  await storage.dispose();
  // The OPFS double logs every handle it closes.
  const log = join(store, '..', 'flushes.log');
  writeFileSync(log, '');
  await assert.rejects(storageOf({store, vfs: {...vfs, maxHydratedBytes: 1024}}), RangeError);
  const closed = readFileSync(log, 'utf8');
  assert.match(closed, /^closed .*titan\.a/m, 'the store opened before the failure was closed');
  assert.match(closed, /^closed .*titan\.b/m);
});

test('the service frames: statements, cells, cursors, transactions and refusals', wasm, async () => {
  const storage = await storageOf(), sql = client(storage);
  const conn = await sql.open(':memory:');
  assert.equal(conn >> 32n, 1n, 'identities carry a generation');
  await sql.run(conn, 'CREATE TABLE v(a, b, c, d, e)');
  const blob = Uint8Array.of(0, 1, 255);
  assert.equal(await sql.run(conn, 'INSERT INTO v VALUES (?, ?, ?, ?, ?)', [-5n, 2.5, 'héllo', blob, null]), 1n);
  assert.deepEqual(await sql.rows(conn, 'SELECT a, b, c, d, e FROM v'), [[-5n, 2.5, 'héllo', blob, null]]);
  // Empty BLOB and TEXT values are values, not NULL.
  await sql.run(conn, 'CREATE TABLE z(a, b, c)');
  await sql.run(conn, 'INSERT INTO z VALUES (?, ?, zeroblob(0))', [new Uint8Array(0), '']);
  assert.deepEqual(await sql.rows(conn, 'SELECT a, b, c, typeof(a), typeof(b), typeof(c) FROM z'),
    [[new Uint8Array(0), '', new Uint8Array(0), 'blob', 'text', 'blob']]);
  // A malformed frame (a NUL inside TEXT, trailing bytes) leaves the statement and its cursor alone.
  const echo = await sql.ok(OP.PREPARE, conn, ['SELECT ?']);
  assert.equal((await sql.call(OP.QUERY, echo.handle, [cell('a\0b')], 1)).status, 2);
  assert.equal((await sql.call(OP.QUERY, echo.handle, [cell(1n), Uint8Array.of(0)], 1)).status, 2);
  const echoed = await sql.ok(OP.QUERY, echo.handle, [cell('ok')], 1);
  echoed.u32();
  echoed.string();
  echoed.string();
  assert.deepEqual(echoed.row(1), ['ok']);
  await sql.ok(OP.FINALIZE, echo.handle);
  const counter = await sql.ok(OP.PREPARE, conn,
    ['WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 3) SELECT i FROM n']);
  const first = await sql.ok(OP.QUERY, counter.handle);
  first.u32();
  first.string();
  first.string();
  assert.deepEqual(first.row(1), [1n]);
  assert.equal((await sql.call(OP.QUERY, counter.handle, [Uint8Array.of(0)])).status, 2);
  assert.equal((await sql.call(OP.FETCH, counter.handle, [Uint8Array.of(0)])).status, 2);
  assert.deepEqual((await sql.ok(OP.FETCH, counter.handle)).row(1), [2n], 'the cursor kept its place');
  await sql.ok(OP.FINALIZE, counter.handle);
  assert.equal((await sql.call(OP.OPEN, 5n, [':memory:'])).status, 2, 'OPEN names no handle');
  const statement = await sql.ok(OP.PREPARE, conn, ['SELECT a AS first, b FROM v WHERE a < ?']);
  assert.deepEqual([statement.u32(), statement.u32()], [1, 2]);
  const done = await sql.ok(OP.QUERY, statement.handle, [cell(-100n)], 1);
  assert.equal(done.u32(), 2);
  assert.deepEqual([done.string(), done.string(), done.string(), done.string()], ['first', null, 'b', null]);
  assert.equal(done.u8(), 0, 'an empty result still carries its columns');
  assert.ok(done.end);
  await sql.ok(OP.RESET, statement.handle);
  await sql.ok(OP.FINALIZE, statement.handle);
  assert.equal((await raw(storage, OP.FETCH, statement.handle)).status, 2, 'a finalized statement is stale');
  const refused = async (body, message, count = 0, op = OP.PREPARE) => {
    const reply = await sql.call(op, conn, body, count);
    assert.equal(reply.status, 1);
    assert.match(reply.message, message);
    return reply;
  };
  await refused(['SELECT 1; SELECT 2'], /exactly one statement/);
  assert.equal((await refused(['SELEC 1'], /syntax error/)).code, 1);
  const twoStatements = await sql.ok(OP.PREPARE, conn, ['SELECT 1 -- comment; SELECT 2']);
  await sql.ok(OP.FINALIZE, twoStatements.handle);
  const insert = await sql.ok(OP.PREPARE, conn, ['INSERT INTO v(a) VALUES (?)']);
  const mismatch = await sql.call(OP.EXECUTE, insert.handle, [], 0);
  assert.match(mismatch.message, /argument count does not match/);
  assert.match((await sql.call(OP.QUERY, insert.handle, [cell(1n)], 1)).message, /result columns/);
  const select = await sql.ok(OP.PREPARE, conn, ['SELECT a FROM v']);
  assert.match((await sql.call(OP.EXECUTE, select.handle)).message, /use query for rows/);
  const busy = await sql.call(OP.CLOSE, conn);
  assert.equal(busy.code, 5, 'Connection:close leaves live statements to the caller');
  await sql.ok(OP.FINALIZE, insert.handle);
  await sql.ok(OP.FINALIZE, select.handle);
  const begun = await sql.ok(OP.BEGIN, conn);
  assert.deepEqual([begun.u8(), begun.flags, storage.sql.transaction], [0, 1, true], 'replies flag the open transaction');
  await sql.run(conn, 'INSERT INTO v(a) VALUES (1)');
  const rolledBack = await sql.ok(OP.ROLLBACK, conn);
  assert.deepEqual([rolledBack.u8(), rolledBack.flags, storage.sql.transaction], [1, 0, false]);
  assert.equal((await sql.ok(OP.AUTOCOMMIT, conn)).u8(), 1);
  assert.equal((await sql.ok(OP.COMMIT, conn)).u8(), 1, 'commit in autocommit mode does nothing');
  const relative = await sql.call(OP.OPEN, 0n, ['file:test.db']);
  assert.match(relative.message, /must be absolute/);
  assert.equal(relative.handle, 0n);
  await sql.ok(OP.CLOSE, await sql.open(''));
  const malformed = await sql.call(OP.PREPARE, conn, [Uint8Array.of(9, 0, 0, 0)]);
  assert.equal(malformed.status, 2);
  const wrongVersion = frame(OP.AUTOCOMMIT, conn);
  wrongVersion[1] = 2;
  assert.equal(decode(await storage.sql.binding(1)('call', wrongVersion).promise).status, 2);
  await sql.ok(OP.CLOSE, conn);
  await assert.rejects(sql.call(OP.AUTOCOMMIT, conn), /does not own/, 'a closed connection leaves the ledger');
  assert.equal((await raw(storage, OP.AUTOCOMMIT, conn)).message, 'stale SQLite handle');
  await storage.dispose();
});

test('the service retires a slot whose generation is exhausted', wasm, async () => {
  const storage = await storageOf({service: lastGeneration()}), sql = client(storage);
  const first = await sql.open(':memory:');
  assert.equal(first >> 32n, 0xffffffffn);
  await sql.ok(OP.CLOSE, first);
  const second = await sql.open(':memory:');
  assert.notEqual(second & 0xffffffffn, first & 0xffffffffn, 'the exhausted slot is never reused');
  assert.equal((await raw(storage, OP.AUTOCOMMIT, first)).message, 'stale SQLite handle');
  await sql.ok(OP.CLOSE, second);
  await storage.dispose();
});

test('titan:sqlite3 reaches only the connections and statements of the calling state', wasm, async () => {
  const states = new Map([[1, 'open'], [2, 'open'], [3, 'closing']]);
  const storage = await storageOf({states}), mine = client(storage, 1), other = client(storage, 2);
  const conn = await mine.open(':memory:'), statement = await mine.ok(OP.PREPARE, conn, ['SELECT 1']);
  const denied = /does not own/;
  await assert.rejects(other.call(OP.AUTOCOMMIT, conn), denied);
  await assert.rejects(other.call(OP.PREPARE, conn, ['SELECT 2']), denied);
  await assert.rejects(other.call(OP.QUERY, statement.handle), denied);
  await assert.rejects(other.call(OP.FINALIZE, statement.handle), denied);
  await assert.rejects(mine.call(OP.CLOSE_CONN, conn), denied, 'CLOSE_CONN is the ledger\'s alone');
  await assert.rejects(mine.call(14, conn), denied);
  assert.throws(() => storage.sql.binding(1)('call', frame(OP.AUTOCOMMIT, conn).subarray(0, 8)), TypeError);
  assert.throws(() => storage.sql.binding(1)('call', 'frame'), TypeError);
  assert.equal((await mine.ok(OP.QUERY, statement.handle)).u32(), 1, 'the owner reaches both');
  await mine.ok(OP.FINALIZE, statement.handle);
  await assert.rejects(mine.call(OP.FETCH, statement.handle), denied, 'a finalized statement leaves the ledger');
  const nonce = storage.sql.binding(1)('detach', conn);
  await assert.rejects(mine.call(OP.AUTOCOMMIT, conn), denied, 'a detached connection is in transit');
  assert.throws(() => storage.sql.binding(3)('adopt', nonce, conn), /cannot adopt/, 'a closing state adopts nothing');
  storage.sql.retireAll();
  assert.throws(() => storage.sql.binding(2)('adopt', nonce, conn), /cannot adopt/, 'disposal closed it in transit');
  assert.equal((await raw(storage, OP.AUTOCOMMIT, conn)).message, 'stale SQLite handle');
  await storage.dispose();
});

test('a FINALIZE leaves the ledger unless the service refused the frame', async () => {
  const replies = [], sent = [];
  const reply = (status, handle = 0n) => {
    const out = new Uint8Array(16);
    out[1] = status;
    new DataView(out.buffer).setBigUint64(8, handle, true);
    replies.push(out);
  };
  const ledger = titanBrowserSql({owner: {states: new Map([[1, 'open']])},
    dispatch: async request => { sent.push(request[0]); return replies.shift(); }});
  const call = (op, handle, body) => ledger.binding(1)('call', frame(op, handle, body)).promise;
  const conn = 1n << 32n | 1n, first = 1n << 32n | 2n, second = 1n << 32n | 3n;
  reply(0, conn);
  await call(OP.OPEN, 0n, [':memory:']);
  reply(0, first);
  await call(OP.PREPARE, conn, ['SELECT 1']);
  reply(0, second);
  await call(OP.PREPARE, conn, ['SELECT 2']);
  reply(1, first);
  await call(OP.FINALIZE, first);
  assert.throws(() => ledger.binding(1)('call', frame(OP.FETCH, first)), /does not own/, 'SQLite consumed it anyway');
  reply(2, second);
  await call(OP.FINALIZE, second);
  reply(0, second);
  await call(OP.FETCH, second);
  assert.deepEqual(sent, [OP.OPEN, OP.PREPARE, OP.PREPARE, OP.FINALIZE, OP.FINALIZE, OP.FETCH]);
});

test('PB-5: a transferred connection survives its donor state; orphaned opens close', wasm, async () => {
  const states = new Map([[1, 'open'], [2, 'open'], [3, 'open']]);
  const storage = await storageOf({states}), donor = client(storage, 1), receiver = client(storage, 2);
  const c1 = await donor.open('/tmp/pb5.db'), c2 = await donor.open('/tmp/pb5.db');
  await donor.run(c1, 'CREATE TABLE t(x)');
  await donor.ok(OP.BEGIN, c1);
  await donor.run(c1, 'INSERT INTO t VALUES (1)');
  const nonce = storage.sql.binding(1)('detach', c1);
  assert.throws(() => storage.sql.binding(2)('adopt', nonce + 1n, c1), /cannot adopt/);
  states.set(1, 'closed');
  storage.closeState(1);
  storage.sql.binding(2)('adopt', nonce, c1);
  assert.equal((await receiver.ok(OP.AUTOCOMMIT, c1)).u8(), 0, 'the open transaction survived');
  assert.equal((await receiver.ok(OP.COMMIT, c1)).u8(), 1);
  assert.equal((await raw(storage, OP.AUTOCOMMIT, c2)).message, 'stale SQLite handle', 'the donor kept c2');
  storage.sql.retire(2, c1);
  await assert.rejects(receiver.call(OP.AUTOCOMMIT, c1), /does not own/);
  assert.equal((await raw(storage, OP.AUTOCOMMIT, c1)).status, 2);
  const opening = storage.sql.binding(3)('call', frame(OP.OPEN, 0n, ['/tmp/orphan.db'])).promise;
  states.set(3, 'closing');
  const orphan = decode(await opening);
  assert.equal(orphan.status, 0);
  assert.equal((await raw(storage, OP.AUTOCOMMIT, orphan.handle)).message, 'stale SQLite handle');
  await storage.dispose();
});

test('D16: disposal waits for a running statement, and a forced stop reports it lost', wasm, async () => {
  const query = 'WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?) SELECT count(*) FROM n';
  // The statement is posted before disposal begins, as a Task's request is.
  const started = async (sql, count) => {
    const conn = await sql.open(':memory:'), statement = await sql.ok(OP.PREPARE, conn, [query]);
    return {reply: sql.call(OP.QUERY, statement.handle, [cell(count)], 1)};
  };
  const graceful = await storageOf(), {reply} = await started(client(graceful), 1000000n);
  assert.equal(await graceful.dispose(), false);
  const result = await reply;
  assert.equal(result.status, 0, result.message);
  result.u32();
  result.string();
  result.string();
  assert.deepEqual(result.row(1), [1000000n], 'the statement finished before the worker stopped');
  const forced = await storageOf(), {reply: abandoned} = await started(client(forced), 300000000n);
  await new Promise(resolve => setTimeout(resolve, 100));
  forced.terminate();
  await assert.rejects(abandoned, /terminated/);
  assert.equal(await forced.dispose(), true);
});

test('SQLite\'s dot-file locks stay private to the service, so no program directory is removed', wasm, async () => {
  const store = newStore(), vfs = {mounts: {'/data': {backend: 'opfs'}}};
  const storage = await storageOf({store, vfs}), guest = guestOf(storage), sql = client(storage);
  // Program directories named like locks: beside an empty file and beside a database.
  guest.close(guest.open('/data/report', 1));
  assert.equal(guest.mkdir('/data/report.lock'), 0);
  const app = await sql.open('/data/app.db');
  await sql.run(app, 'CREATE TABLE t(x)');
  await sql.ok(OP.CLOSE, app);
  assert.equal(guest.mkdir('/data/app.db.lock'), 0);
  // An open transaction holds its lock outside the namespace; another connection waits for it.
  const conn = await sql.open('/data/x.db'), other = await sql.open('/data/x.db');
  await sql.run(conn, 'CREATE TABLE t(x)');
  const insert = await sql.ok(OP.PREPARE, other, ['INSERT INTO t VALUES (2)']);
  await sql.ok(OP.BEGIN, conn);
  await sql.run(conn, 'INSERT INTO t VALUES (1)');
  assert.equal(storage.fileSystem.lookup('/data/x.db.lock'), null);
  assert.equal((await sql.call(OP.EXECUTE, insert.handle)).code, 5, 'SQLITE_BUSY');
  await sql.ok(OP.FINALIZE, insert.handle);
  await sync(storage);
  storage.terminate();
  assert.equal(await storage.dispose(), true);
  for (const linked of [false, true]) {
    const reopened = await storageOf({store, vfs, sqlite: linked});
    assert.equal(reopened.fileSystem.lookup('/data/report.lock')?.type, 'dir');
    assert.equal(reopened.fileSystem.lookup('/data/app.db.lock')?.type, 'dir');
    assert.equal(reopened.fileSystem.lookup('/data/x.db.lock'), null);
    if (linked) {
      const again = client(reopened);
      assert.deepEqual(await again.rows(await again.open('/data/x.db'), 'SELECT x FROM t'), [], 'the hot journal rolled back');
    }
    await reopened.dispose();
  }
});

test('PB-1: guest namespace changes made during a statement converge with the worker', wasm, async () => {
  const store = newStore(), vfs = {mounts: {'/data': {backend: 'opfs'}}};
  const storage = await storageOf({store, vfs}), guest = guestOf(storage), sql = client(storage);
  // The statement creates c.db; the guest's later create of that name wins on both sides.
  const opening = sql.call(OP.OPEN, 0n, ['/data/c.db']);
  const fd = guest.open('/data/c.db', 1);
  assert.equal(guest.pwrite(fd, 'GUEST', 0), 5);
  guest.close(fd);
  const conn = (await opening).handle;
  assert.equal(text(storage, '/data/c.db'), 'GUEST');
  await sql.run(conn, 'CREATE TABLE t(x)');
  await sql.ok(OP.CLOSE, conn);
  // A journal the statement deletes while the guest renames it is gone on both sides.
  const db = await sql.open('/data/j.db');
  await sql.run(db, 'CREATE TABLE t(x)');
  await sql.ok(OP.BEGIN, db);
  await sql.run(db, 'INSERT INTO t VALUES (1)');
  assert.equal(storage.fileSystem.lookup('/data/j.db-journal')?.type, 'file');
  const committing = sql.call(OP.COMMIT, db);
  assert.equal(guest.rename('/data/j.db-journal', '/data/moved'), 0);
  assert.equal((await committing).status, 0);
  assert.equal(storage.fileSystem.lookup('/data/moved'), null);
  assert.equal(storage.fileSystem.lookup('/data/j.db-journal'), null);
  await sql.ok(OP.CLOSE, db);
  // A rename over the name a statement creates: the guest's file wins on both sides.
  const saved = guest.open('/data/saved', 1);
  assert.equal(guest.pwrite(saved, 'SAVED', 0), 5);
  const opened = sql.call(OP.OPEN, 0n, ['/data/r.db']);
  assert.equal(guest.rename('/data/saved', '/data/r.db'), 0);
  const replaced = (await opened).handle;
  assert.equal(text(storage, '/data/r.db'), 'SAVED');
  assert.equal(storage.fileSystem.lookup('/data/saved'), null);
  assert.equal(guest.pread(saved, 5, 0), 'SAVED', 'the open descriptor still names the file');
  guest.close(saved);
  await sql.ok(OP.CLOSE, replaced);
  // A rename of a journal the statement deletes, over another file: that file stays.
  const keep = guest.open('/data/keep', 1);
  assert.equal(guest.pwrite(keep, 'KEEP', 0), 4);
  guest.close(keep);
  const journal = await sql.open('/data/j.db');
  await sql.ok(OP.BEGIN, journal);
  await sql.run(journal, 'INSERT INTO t VALUES (2)');
  const finishing = sql.call(OP.COMMIT, journal);
  assert.equal(guest.rename('/data/j.db-journal', '/data/keep'), 0);
  assert.equal((await finishing).status, 0);
  assert.equal(text(storage, '/data/keep'), 'KEEP', 'the replaced file is back');
  assert.equal(storage.fileSystem.lookup('/data/j.db-journal'), null);
  await sql.ok(OP.CLOSE, journal);
  const names = Object.keys(storage.fileSystem.lookup('/data').entries).sort();
  await storage.dispose();
  const reopened = await storageOf({store, vfs}), again = client(reopened);
  assert.deepEqual(Object.keys(reopened.fileSystem.lookup('/data').entries).sort(), names);
  assert.equal(text(reopened, '/data/c.db'), 'GUEST');
  assert.equal(text(reopened, '/data/r.db'), 'SAVED');
  assert.equal(text(reopened, '/data/keep'), 'KEEP');
  assert.deepEqual(await again.rows(await again.open('/data/j.db'), 'SELECT x FROM t'), [[1n], [2n]]);
  await reopened.dispose();
});

test('a store write the quota cuts short fails the mirror for good', wasm, async () => {
  const store = newStore(), vfs = {mounts: {'/data': {backend: 'opfs'}}};
  const storage = await storageOf({store, quota: 1024, vfs}), guest = guestOf(storage);
  const fd = guest.open('/data/big', 1);
  assert.equal(guest.pwrite(fd, 'x'.repeat(4096), 0), 4096);
  assert.equal(await sync(storage, fd), 51n, 'the worker\'s ENOSPC, as a Titan integer');
  assert.equal(await sync(storage), 51n, 'the mirror stays behind');
  guest.close(fd);
  await assert.rejects(storage.dispose(), error => error.errno === 51);
});

test('a forced stop after the store refused a write outright reports it lost', wasm, async () => {
  const store = newStore(), vfs = {mounts: {'/data': {backend: 'opfs'}}};
  const storage = await storageOf({store, quota: 64, vfs}), guest = guestOf(storage);
  const fd = guest.open('/data/full', 1);
  assert.equal(guest.pwrite(fd, 'x'.repeat(64), 0), 64);
  assert.equal(await sync(storage, fd), 0n, 'a clean flush');
  const scratch = guest.open('/tmp/scratch', 1);
  assert.equal(await sync(storage, scratch), 0n, 'nothing to flush off the durable mounts');
  // The quota takes no further byte: the worker's write fails before any lands.
  assert.equal(guest.pwrite(fd, 'more', 64), 4);
  while (storage.journal.length) await new Promise(resolve => setTimeout(resolve, 5));
  storage.terminate();
  await assert.rejects(sync(storage, fd), /terminated/, 'a stopped worker rejects');
  await assert.rejects(sync(storage, scratch), /terminated/, 'even with nothing durable to flush');
  assert.equal(await storage.dispose(), true, 'the acknowledged write never reached the store');
});

test('relative names SQLite resolves itself follow the guest\'s working directory', wasm, async () => {
  const store = newStore(), vfs = {mounts: {'/data': {backend: 'opfs'}}};
  const storage = await storageOf({store, vfs}), guest = guestOf(storage);
  assert.equal(guest.mkdir('/data/sub'), 0);
  const sub = client(storage, 1, '/data/sub'), conn = await sub.open('/data/sub/main.db');
  await sub.run(conn, 'ATTACH ? AS aux', ['relative.db']);
  await sub.run(conn, 'CREATE TABLE aux.t(x)');
  await sub.run(conn, 'INSERT INTO aux.t VALUES (42)');
  const files = async (sql, name) => (await sql.rows(conn, 'SELECT name, file FROM pragma_database_list'))
    .find(([database]) => database === name)?.[1];
  assert.equal(await files(sub, 'aux'), '/data/sub/relative.db');
  assert.equal(storage.fileSystem.lookup('/relative.db'), null);
  // Back at the root, a relative name resolves there.
  const root = client(storage, 1, '/');
  await root.run(conn, 'ATTACH ? AS top', ['top.db']);
  assert.equal(await files(root, 'top'), '/top.db');
  await root.run(conn, 'DETACH top');
  // A working directory that is not there, or none, resolves no relative
  // name, and nothing appears at the root or in an earlier directory.
  const attach = async (sql, name, alias) => {
    const statement = await sql.ok(OP.PREPARE, conn, [`ATTACH ? AS ${alias}`]);
    const reply = await sql.call(OP.EXECUTE, statement.handle, [cell(name)], 1);
    await sql.ok(OP.FINALIZE, statement.handle);
    return reply;
  };
  const gone = client(storage, 1, '/data/gone');
  assert.deepEqual(await gone.rows(conn, 'SELECT 1'), [[1n]], 'statements naming no file still run');
  assert.equal((await attach(gone, 'other.db', 'other')).code, 14, 'SQLITE_CANTOPEN');
  assert.equal((await attach(client(storage), 'other.db', 'other')).code, 14, 'no directory given');
  assert.equal((await attach(gone, '../escape.db', 'esc')).code, 14, 'nor a parent-relative one');
  assert.equal((await attach(client(storage), '../escape.db', 'esc')).code, 14);
  for (const path of ['/other.db', '/data/sub/other.db', '/data/other.db', '/escape.db', '/data/escape.db']) {
    assert.equal(storage.fileSystem.lookup(path), null, path);
  }
  // Absolute names keep working, wherever they are.
  assert.equal((await attach(gone, '/data/abs.db', 'abs')).status, 0);
  assert.equal(guest.mkdir('/.titan-sqlite-no-directory'), 0);
  assert.equal((await attach(gone, '/.titan-sqlite-no-directory/kept.db', 'kept')).status, 0);
  assert.equal(storage.fileSystem.lookup('/.titan-sqlite-no-directory/kept.db')?.type, 'file');
  await gone.run(conn, 'DETACH abs');
  await gone.run(conn, 'DETACH kept');
  await assert.rejects(client(storage, 1, '/data\0sub').call(OP.AUTOCOMMIT, conn), /working directory/);
  // Once the directory exists, its relative names resolve there.
  assert.equal(guest.mkdir('/data/gone'), 0);
  assert.equal((await attach(gone, 'other.db', 'other')).status, 0);
  assert.equal(await files(gone, 'other'), '/data/gone/other.db');
  assert.equal(storage.fileSystem.lookup('/data/gone/other.db')?.type, 'file');
  await gone.run(conn, 'DETACH other');
  await gone.run(conn, 'DETACH aux');
  await gone.ok(OP.CLOSE, conn);
  await storage.dispose();
  const reopened = await storageOf({store, vfs}), again = client(reopened);
  assert.deepEqual(await again.rows(await again.open('/data/sub/relative.db'), 'SELECT x FROM t'), [[42n]]);
  await reopened.dispose();
});

test('fsync reaches files created past the spare pool, and a directory sync settles', wasm, async () => {
  const store = newStore(), vfs = {mounts: {'/data': {backend: 'opfs'}}};
  const storage = await storageOf({store, vfs}), guest = guestOf(storage);
  const fds = Array.from({length: 24}, (_, index) => guest.open(`/data/f${index}`, 1));
  fds.forEach((fd, index) => guest.pwrite(fd, `file ${index}`, 0));
  for (const fd of fds) assert.equal(guest.env.titan_browser_vfs_retire_sync(0, fd), 0);
  await sync(storage);
  const dir = guest.open('/data', 0);
  assert.ok(dir >= 0, `open /data: ${dir}`);
  await sync(storage, dir);
  guest.close(dir);
  storage.terminate();
  await storage.dispose();
  const reopened = await storageOf({store, vfs});
  for (let index = 0; index < 24; index++) assert.equal(text(reopened, `/data/f${index}`), `file ${index}`);
  await reopened.dispose();
});

test('a forced stop reports lost exactly the durable changes not yet flushed', wasm, async () => {
  const store = newStore(), vfs = {mounts: {'/data': {backend: 'opfs'}}};
  const stopped = storage => { storage.terminate(); return storage.dispose(); };
  let storage = await storageOf({store, vfs}), guest = guestOf(storage), fd = guest.open('/data/f', 1);
  guest.pwrite(fd, 'applied', 0);
  await sync(storage);
  assert.equal(await stopped(storage), true, 'applied by the worker but not flushed');
  storage = await storageOf({store, vfs});
  guest = guestOf(storage);
  fd = guest.open('/data/f', 1);
  guest.pwrite(fd, 'flushed', 0);
  await sync(storage, fd);
  assert.equal(await stopped(storage), false, 'flushed');
  storage = await storageOf({store, vfs});
  const sql = client(storage), conn = await sql.open('/data/t.db');
  await sql.run(conn, 'CREATE TABLE t(x)');
  await sql.ok(OP.BEGIN, conn);
  assert.equal(await stopped(storage), true, 'an open transaction');
  // A statement stopped at a row holds the implicit transaction of its write.
  storage = await storageOf({store, vfs});
  const returning = client(storage), db = await returning.open('/data/t.db');
  const insert = await returning.ok(OP.PREPARE, db, ['INSERT INTO t VALUES (7) RETURNING x']);
  const row = await returning.ok(OP.QUERY, insert.handle);
  assert.deepEqual([row.flags, storage.sql.transaction], [1, true]);
  assert.equal(await stopped(storage), true, 'an implicit transaction');
  storage = await storageOf({store, vfs});
  const after = client(storage), again = await after.open('/data/t.db');
  assert.deepEqual(await after.rows(again, 'SELECT x FROM t'), [], 'the write rolled back');
  const finished = await after.ok(OP.PREPARE, again, ['INSERT INTO t VALUES (8) RETURNING x']);
  assert.equal((await after.ok(OP.QUERY, finished.handle)).flags, 1);
  assert.equal((await after.ok(OP.FETCH, finished.handle)).flags, 0, 'done, the write committed');
  assert.equal(storage.sql.transaction, false);
  await after.ok(OP.FINALIZE, finished.handle);
  await storage.dispose();
});

test('a forced stop reports durable writes the worker has not flushed, SQLite\'s included', wasm, async () => {
  const vfs = {mounts: {'/data': {backend: 'opfs'}}};
  const stopped = storage => { storage.terminate(); return storage.dispose(); };
  // One committed autocommit INSERT under `pragmas`, then an idle forced stop.
  const committed = async (store, pragmas, settle = () => {}) => {
    const storage = await storageOf({store, vfs}), sql = client(storage), conn = await sql.open('/data/t.db');
    await sql.run(conn, 'CREATE TABLE t(x)');
    await pragmas(sql, conn);
    await sql.run(conn, 'INSERT INTO t VALUES (1)');
    assert.equal(storage.sql.transaction, false, 'no transaction is open');
    await settle(storage);
    await sync(storage);
    return stopped(storage);
  };
  const rows = async store => {
    const storage = await storageOf({store, vfs}), sql = client(storage);
    const result = await sql.rows(await sql.open('/data/t.db'), 'SELECT x FROM t');
    await storage.dispose();
    return result;
  };
  const off = newStore();
  assert.equal(await committed(off, (sql, conn) => sql.run(conn, 'PRAGMA synchronous=OFF')), true,
    'synchronous=OFF never flushes the commit');
  assert.deepEqual(await rows(off), [], 'and the stop lost it');
  const truncate = newStore();
  assert.equal(await committed(truncate, async (sql, conn) => {
    await sql.run(conn, 'PRAGMA synchronous=NORMAL');
    assert.deepEqual(await sql.rows(conn, 'PRAGMA journal_mode=TRUNCATE'), [['truncate']]);
  }), true, 'NORMAL with TRUNCATE never flushes the journal truncation');
  const full = newStore();
  assert.equal(await committed(full, async () => {}), false, 'FULL with DELETE flushes the commit');
  assert.deepEqual(await rows(full), [[1n]]);
  const flushed = newStore();
  assert.equal(await committed(flushed, (sql, conn) => sql.run(conn, 'PRAGMA synchronous=OFF'), async storage => {
    const guest = guestOf(storage), fd = guest.open('/data/t.db', 0);
    await sync(storage, fd);
    guest.close(fd);
  }), false, 'a flush through titan:vfs covers SQLite\'s writes too');
  assert.deepEqual(await rows(flushed), [[1n]]);
});

test('memory mounts keep their identity: roots and their ancestors stay, renames stay inside', wasm, async () => {
  assert.throws(() => titanBrowserStorage({states: new Map()}, {mounts: {'/dev/x': {backend: 'memory'}}}, {}), TypeError);
  const vfs = {mounts: {'/a/scratch': {backend: 'memory'}, '/work': {backend: 'memory'}}};
  for (const storage of [await storageOf({vfs, sqlite: false}), await storageOf({vfs})]) {
    const guest = guestOf(storage);
    assert.equal(guest.rename('/a/scratch', '/moved'), -10, 'EBUSY on a mount root');
    assert.equal(guest.rename('/a', '/b'), -10, 'EBUSY on an ancestor of a mount');
    guest.close(guest.open('/a/scratch/f', 1));
    assert.equal(guest.rename('/a/scratch/f', '/work/f'), -75, 'EXDEV across mounts');
    assert.equal(guest.rename('/a/scratch/f', '/tmp/f'), -75, 'EXDEV out of a mount');
    assert.equal(guest.link('/a/scratch/f', '/a/scratch/g'), 0, 'a memory mount keeps hard links');
    await storage.dispose();
  }
});

test('removed files go at once on explicit memory mounts, with and without the worker', wasm, async () => {
  const vfs = {mounts: {'/scratch': {backend: 'memory'}}};
  for (const storage of [await storageOf({vfs, sqlite: false}), await storageOf({vfs})]) {
    const guest = guestOf(storage), {nodes, dead} = storage.storage, before = nodes.size;
    for (let round = 0; round < 200; round++) {
      const fd = guest.open('/scratch/temp', 1);
      assert.equal(guest.pwrite(fd, 'x'.repeat(1024), 0), 1024);
      guest.close(fd);
      assert.equal(guest.unlink('/scratch/temp'), 0);
      guest.close(guest.open('/scratch/a', 1));
      guest.close(guest.open('/scratch/b', 1));
      assert.equal(guest.rename('/scratch/a', '/scratch/b'), 0);
    }
    assert.ok(nodes.size <= before + 3, `${nodes.size - before} nodes left`);
    assert.ok(dead.size <= 1, `${dead.size} dead nodes left`);
    await storage.dispose();
  }
});

test('a tampered SQLite service never runs', wasm, async () => {
  const {sha256} = build();
  const owner = {states: new Map(), options: {locateFile: name => pathToFileURL(name === 'app.sqlite3.wasm' ?
    build().service : join(browser, 'titan-storage-worker.mjs')).href}};
  const storage = titanBrowserStorage(owner, undefined, {directory: '', worker: 'app.worker.mjs',
    sqlite: {wasm: 'app.sqlite3.wasm', sha256: sha256.replace(/^./, c => c === '0' ? '1' : '0')}, sql: titanBrowserSql});
  await assert.rejects(storage.start(), /digest/);
});
