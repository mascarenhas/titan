/* The SQLite service reactor of a browser image's storage worker
 * (titan-storage-worker.mjs). titan_sql_svc_dispatch decodes one
 * pointer-free little-endian request frame built by titan/sqlite3's browser
 * codec, runs it as the native routines of titan/sqlite3/worker.titan do, and
 * builds one reply frame. Connections and statements are generation-tagged
 * 64-bit identities; the loader's lease ledger, not this reactor, knows which
 * Lua state owns a connection. It links no Lua or Titan runtime: only this
 * file and the pinned sqlite3.c.
 * Wire format: doc/implementation/sqlite3-library.md#browser-service-frames */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "sqlite3.h"

#define EXPORT(name) __attribute__((export_name(name)))

/* CHDIR is the worker's own; the loader's transport never forwards it. */
enum { OP_OPEN = 1, OP_PREPARE, OP_EXECUTE, OP_QUERY, OP_FETCH, OP_RESET, OP_FINALIZE,
    OP_CLOSE, OP_CLOSE_CONN, OP_AUTOCOMMIT, OP_BEGIN, OP_COMMIT, OP_ROLLBACK, OP_CHDIR };
enum { STATUS_OK, STATUS_ERROR, STATUS_PROTOCOL };
enum { MALFORMED, DONE, STALE };
#define VERSION 1
#define HEADER 16
#define MAX_FRAME (64u << 20)
#define MAX_TEXT (16u << 20)
#define MAX_CELL (32u << 20)
#define MAX_PARAMETERS 32766u
#define MAX_CONNECTIONS 1024u
#define MAX_STATEMENTS 4096u
#define ABSENT 0xffffffffu
/* The generation of a slot's first identity; a test build starts near the
 * end of the range to reach slot retirement. */
#ifndef TITAN_SQL_SVC_FIRST_GENERATION
#define TITAN_SQL_SVC_FIRST_GENERATION 1u
#endif

/* A live connection (owner 0) or statement (owner: its connection's slot +
 * 1). A connection's `count` is its statements, and `writing` whether it
 * holds a write a forced stop would lose; a free entry's `count` links the
 * free list. `writers` counts the writing connections. */
typedef struct { void *handle; uint32_t generation, owner, count, writing; } Entry;
static Entry *entries;
static uint32_t capacity, used, free_head, connections, writers;

/* The reply: a u32 frame length, then the frame. The worker copies it out and
 * the next dispatch reuses it; the static start always holds a failure. */
static uint8_t small[256];
static uint8_t *out = small;
static uint32_t out_capacity = sizeof small, out_length;
static int out_failure;

typedef struct { const uint8_t *at, *end; int bad; } Reader;

/* A failure as worker.titan captures it: the first one stands, and a later
 * cleanup failure is kept apart. */
typedef struct {
    int failed, code, extended, cleanup_code;
    const char *message;
    char *owned, *cleanup;
} Failure;

static void put(const void *bytes, uint32_t length) {
    if (out_failure || !length) return;
    if (length > MAX_FRAME + 4 - out_length) { out_failure = SQLITE_TOOBIG; return; }
    if (out_length + length > out_capacity) {
        uint32_t grown = out_capacity;
        while (grown < out_length + length) grown = grown > MAX_FRAME / 2 ? MAX_FRAME + 4 : grown * 2;
        uint8_t *next = out == small ? malloc(grown) : realloc(out, grown);
        if (!next) { out_failure = SQLITE_NOMEM; return; }
        if (out == small) memcpy(next, small, out_length);
        out = next;
        out_capacity = grown;
    }
    memcpy(out + out_length, bytes, length);
    out_length += length;
}

/* wasm32 is little-endian: memcpy is wire order. */
static void put_u8(uint8_t value) { put(&value, 1); }
static void put_u32(uint32_t value) { put(&value, 4); }
static void put_text(const char *text) {
    uint32_t length = (uint32_t)strlen(text);
    put_u32(length);
    put(text, length);
}

static const uint8_t *take(Reader *reader, uint32_t length) {
    if (reader->bad || length > (uint32_t)(reader->end - reader->at)) reader->bad = 1;
    if (reader->bad) return NULL;
    reader->at += length;
    return reader->at - length;
}

static uint32_t take_u32(Reader *reader) {
    uint32_t value = 0;
    const uint8_t *at = take(reader, 4);
    if (at) memcpy(&value, at, 4);
    return value;
}

/* The rest of the frame: one length-prefixed text without NUL. */
static const char *take_text(Reader *reader, uint32_t *length) {
    *length = take_u32(reader);
    const char *text = *length > MAX_TEXT ? NULL : (const char *)take(reader, *length);
    return !text || reader->at != reader->end || memchr(text, 0, *length) ? NULL : text;
}

/* The connection's own diagnostic when it describes `status`. */
static const char *diagnostic(sqlite3 *db, int status, int *extended) {
    if (!db || (sqlite3_extended_errcode(db) & 255) != (status & 255)) return sqlite3_errstr(status);
    *extended = sqlite3_extended_errcode(db);
    return sqlite3_errmsg(db);
}

static void wrapper(Failure *failure, const char *message) {
    if (failure->failed) return;
    failure->failed = 1;
    failure->message = message;
}

static void capture(Failure *failure, sqlite3 *db, int status) {
    if (failure->failed) return;
    failure->failed = 1;
    failure->code = status & 255;
    failure->extended = status;
    failure->owned = sqlite3_mprintf("%s", diagnostic(db, status, &failure->extended));
    failure->message = failure->owned ? failure->owned : "SQLite error (diagnostic allocation failed)";
}

static void cleanup(Failure *failure, sqlite3 *db, int status) {
    int extended;
    if (status == SQLITE_OK) return;
    if (!failure->failed) capture(failure, db, status);
    else if (!failure->cleanup_code) {
        failure->cleanup_code = status & 255;
        failure->cleanup = sqlite3_mprintf("%s", diagnostic(db, status, &extended));
    }
}

static void reset(Failure *failure, sqlite3 *db, sqlite3_stmt *stmt) {
    cleanup(failure, db, sqlite3_reset(stmt));
    cleanup(failure, db, sqlite3_clear_bindings(stmt));
}

/* The new identity, or 0 when the table cannot grow. */
static uint64_t add_entry(void *handle, uint32_t owner) {
    uint32_t slot = free_head ? free_head - 1 : used;
    if (free_head) {
        free_head = entries[slot].count;
    } else if (used == capacity) {
        uint32_t grown = capacity ? capacity * 2 : 64;
        Entry *next = realloc(entries, grown * sizeof *next);
        if (!next) return 0;
        memset(next + capacity, 0, (grown - capacity) * sizeof *next);
        entries = next;
        capacity = grown;
    }
    uint32_t generation = slot < used ? entries[slot].generation + 1 : TITAN_SQL_SVC_FIRST_GENERATION;
    if (slot == used) used++;
    entries[slot] = (Entry){ handle, generation, owner, 0, 0 };
    return (uint64_t)generation << 32 | (slot + 1);
}

/* A slot whose generation is exhausted retires, so no identity revives. */
static void remove_entry(Entry *entry) {
    entry->handle = NULL;
    if (entry->generation == UINT32_MAX) return;
    entry->count = free_head;
    free_head = (uint32_t)(entry - entries) + 1;
}

/* After a request on connection `conn`: an explicit transaction, or the
 * implicit one of a statement stopped at a row, holds a write. A closed
 * connection holds none. */
static void track(Entry *conn) {
    sqlite3 *db = conn->handle;
    uint32_t writing = db && (!sqlite3_get_autocommit(db) || sqlite3_txn_state(db, NULL) == SQLITE_TXN_WRITE);
    if (writing != conn->writing) writers = writing ? writers + 1 : writers - 1;
    conn->writing = writing;
}

/* The default VFS, wrapped so a relative name resolves only against a
 * working directory the guest named (OP_CHDIR); without one, every relative
 * name, `..` included, fails before SQLite joins it to a directory. */
static sqlite3_vfs *base_vfs, titan_vfs;
static int has_cwd;

static int full_pathname(sqlite3_vfs *vfs, const char *path, int size, char *out) {
    (void)vfs;
    if (!has_cwd && path[0] != '/') return SQLITE_CANTOPEN;
    return base_vfs->xFullPathname(base_vfs, path, size, out);
}

static int install_vfs(void) {
    if (base_vfs) return 1;
    if (sqlite3_initialize() != SQLITE_OK || !(base_vfs = sqlite3_vfs_find(NULL))) return 0;
    titan_vfs = *base_vfs;
    titan_vfs.zName = "titan";
    titan_vfs.pNext = NULL;
    titan_vfs.xFullPathname = full_pathname;
    if (sqlite3_vfs_register(&titan_vfs, 1) == SQLITE_OK) return 1;
    base_vfs = NULL;
    return 0;
}

/* The live connection (statement 0) or statement (1) of identity `id`. */
static Entry *find(uint64_t id, int statement) {
    uint32_t slot = (uint32_t)id - 1;
    Entry *entry = (uint32_t)id && slot < used ? &entries[slot] : NULL;
    if (!entry || !entry->handle || entry->generation != (uint32_t)(id >> 32) || !entry->owner != !statement) return NULL;
    return entry;
}

/* The guest resolves a name against its own working directory and the
 * worker's is "/", so a database file name arrives absolute. */
static void open_connection(Failure *failure, const char *path, uint32_t length, uint64_t *id) {
    sqlite3 *db = NULL;
    if (connections >= MAX_CONNECTIONS) wrapper(failure, "too many open SQLite connections");
    else if (length && path[0] != '/' && !(length == 8 && !memcmp(path, ":memory:", 8)))
        wrapper(failure, "SQLite database path must be absolute, \":memory:\" or empty");
    if (failure->failed) return;
    char *name = sqlite3_mprintf("%.*s", (int)length, path);
    int status = name ? sqlite3_open_v2(name, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) : SQLITE_NOMEM;
    sqlite3_free(name);
    if (status == SQLITE_OK) status = sqlite3_extended_result_codes(db, 1);
    if (status != SQLITE_OK) capture(failure, db, status);
    else if (!(*id = add_entry(db, 0))) capture(failure, db, SQLITE_NOMEM);
    if (failure->failed) sqlite3_close(db);
    else connections++;
}

/* sqlite_prepare_worker: SQLite parses the tail itself, so comments, quoted
 * semicolons and empty statements keep its syntax. */
static void prepare(Failure *failure, const char *sql, uint32_t length, uint32_t owner, uint64_t *id) {
    sqlite3 *db = entries[owner - 1].handle;
    sqlite3_stmt *stmt = NULL, *extra = NULL;
    const char *end = sql + length, *tail = sql, *next;
    if (entries[owner - 1].count >= MAX_STATEMENTS) {
        wrapper(failure, "too many open statements on this SQLite connection");
        return;
    }
    int status = sqlite3_prepare_v2(db, sql, (int)length, &stmt, &tail);
    if (status != SQLITE_OK) capture(failure, db, status);
    else if (!stmt) wrapper(failure, "SQL must contain exactly one statement");
    for (next = tail; !failure->failed && tail < end; tail = next) {
        status = sqlite3_prepare_v2(db, tail, (int)(end - tail), &extra, &next);
        if (status != SQLITE_OK) capture(failure, db, status);
        else if (extra) wrapper(failure, "SQL must contain exactly one statement");
        if (extra) cleanup(failure, db, sqlite3_finalize(extra));
        if (next == tail) break;
    }
    if (!failure->failed && !(*id = add_entry(stmt, owner))) capture(failure, db, SQLITE_NOMEM);
    if (failure->failed) {
        cleanup(failure, db, sqlite3_finalize(stmt));
        return;
    }
    entries[owner - 1].count++;
    put_u32((uint32_t)sqlite3_bind_parameter_count(stmt));
    put_u32((uint32_t)sqlite3_column_count(stmt));
}

/* The frame's remaining bytes are exactly `count` well-formed cells. They
 * are checked before the statement is touched. */
static int cells_valid(Reader reader, uint32_t count) {
    for (uint32_t index = 0; index < count && !reader.bad; index++) {
        const uint8_t *tag = take(&reader, 1);
        if (tag && (*tag == SQLITE_INTEGER || *tag == SQLITE_FLOAT)) take(&reader, 8);
        else if (tag && (*tag == SQLITE_TEXT || *tag == SQLITE_BLOB)) {
            uint32_t length = take_u32(&reader);
            const uint8_t *at = take(&reader, length > MAX_CELL ? UINT32_MAX : length);
            if (at && *tag == SQLITE_TEXT && memchr(at, 0, length)) reader.bad = 1;
        } else if (tag && *tag != SQLITE_NULL) reader.bad = 1;
    }
    return !reader.bad && reader.at == reader.end;
}

/* sqlite_bind_arguments: reset, check the count, bind the validated cells.
 * Returns whether execution needs a reset. */
static int bind(Failure *failure, sqlite3 *db, sqlite3_stmt *stmt, Reader *reader, uint32_t count) {
    reset(failure, db, stmt);
    if (failure->failed) return 0;
    if (count != (uint32_t)sqlite3_bind_parameter_count(stmt)) {
        wrapper(failure, "argument count does not match SQL parameter count");
        return 0;
    }
    for (int index = 1, status = SQLITE_OK; index <= (int)count && status == SQLITE_OK; index++) {
        uint8_t tag = *take(reader, 1);
        uint32_t length = tag == SQLITE_TEXT || tag == SQLITE_BLOB ? take_u32(reader) : 0;
        const uint8_t *at = take(reader, tag == SQLITE_INTEGER || tag == SQLITE_FLOAT ? 8 : length);
        union { sqlite3_int64 integer; double number; } scalar = { 0 };
        if (tag == SQLITE_INTEGER || tag == SQLITE_FLOAT) memcpy(&scalar, at, 8);
        if (tag == SQLITE_NULL) status = sqlite3_bind_null(stmt, index);
        else if (tag == SQLITE_INTEGER) status = sqlite3_bind_int64(stmt, index, scalar.integer);
        else if (tag == SQLITE_FLOAT) status = sqlite3_bind_double(stmt, index, scalar.number);
        else if (tag == SQLITE_TEXT)
            status = sqlite3_bind_text64(stmt, index, (const char *)at, length, SQLITE_TRANSIENT, SQLITE_UTF8);
        else status = sqlite3_bind_blob64(stmt, index, at, length, SQLITE_TRANSIENT);
        if (status != SQLITE_OK) capture(failure, db, status);
    }
    return 1;
}

static void put_columns(Failure *failure, sqlite3 *db, sqlite3_stmt *stmt) {
    put_u32((uint32_t)sqlite3_column_count(stmt));
    for (int index = 0; index < sqlite3_column_count(stmt); index++) {
        const char *name = sqlite3_column_name(stmt, index), *declared = name ? sqlite3_column_decltype(stmt, index) : NULL;
        if (!name || (!declared && sqlite3_errcode(db) == SQLITE_NOMEM)) {
            capture(failure, db, SQLITE_NOMEM);
            return;
        }
        put_text(name);
        if (declared) put_text(declared);
        else put_u32(ABSENT);
    }
}

/* sqlite_copy_row: test a suspect NULL before any other call; an empty BLOB
 * is NULL, but TEXT, even empty, has a terminator. */
static void put_row(Failure *failure, sqlite3 *db, sqlite3_stmt *stmt) {
    put_u8(1);
    for (int index = 0; index < sqlite3_column_count(stmt); index++) {
        int type = sqlite3_column_type(stmt, index);
        union { sqlite3_int64 integer; double number; } scalar;
        put_u8((uint8_t)type);
        if (type == SQLITE_INTEGER || type == SQLITE_FLOAT) {
            if (type == SQLITE_INTEGER) scalar.integer = sqlite3_column_int64(stmt, index);
            else scalar.number = sqlite3_column_double(stmt, index);
            put(&scalar, 8);
        } else if (type != SQLITE_NULL) {
            const void *source = type == SQLITE_TEXT ? (const void *)sqlite3_column_text(stmt, index) :
                sqlite3_column_blob(stmt, index);
            int nomem = !source && (type == SQLITE_TEXT || sqlite3_errcode(db) == SQLITE_NOMEM);
            int length = nomem ? 0 : sqlite3_column_bytes(stmt, index);
            if (nomem || (!length && sqlite3_errcode(db) == SQLITE_NOMEM)) {
                capture(failure, db, SQLITE_NOMEM);
                return;
            }
            if ((uint32_t)length > MAX_CELL && !out_failure) out_failure = SQLITE_TOOBIG;
            put_u32((uint32_t)length);
            put(source, (uint32_t)length);
        }
    }
}

/* EXECUTE, QUERY and FETCH: sqlite_execute_worker, sqlite_query_worker and
 * sqlite_fetch_worker. A malformed frame leaves the statement untouched. */
static int step(Failure *failure, Reader *reader, int op, Entry *statement, uint32_t count) {
    sqlite3_stmt *stmt = statement->handle;
    sqlite3 *db = entries[statement->owner - 1].handle;
    if (op == OP_FETCH ? reader->at != reader->end : !cells_valid(*reader, count)) return MALFORMED;
    if (op == OP_QUERY && sqlite3_column_count(stmt) == 0) {
        wrapper(failure, "query requires a statement with result columns");
        return DONE;
    }
    int needs_reset = op == OP_FETCH || bind(failure, db, stmt, reader, count);
    int status = failure->failed ? SQLITE_OK : sqlite3_step(stmt);
    if (op == OP_QUERY && (status == SQLITE_ROW || status == SQLITE_DONE)) put_columns(failure, db, stmt);
    if (op == OP_EXECUTE && status == SQLITE_DONE) {
        sqlite3_int64 changes = sqlite3_changes64(db);
        put(&changes, 8);
    } else if (op == OP_EXECUTE && status == SQLITE_ROW) {
        wrapper(failure, "execute expected SQLITE_DONE; use query for rows");
    } else if (status == SQLITE_ROW) {
        if (!failure->failed) put_row(failure, db, stmt);
        needs_reset = failure->failed || out_failure;
    } else if (status == SQLITE_DONE) {
        put_u8(0);
    } else if (status != SQLITE_OK) {
        capture(failure, db, status);
    }
    if (needs_reset) reset(failure, db, stmt);
    return DONE;
}

static int run(Failure *failure, Reader *reader, int op, uint32_t count, uint64_t *id) {
    uint32_t length;
    int named = op <= OP_PREPARE || op == OP_CHDIR, statement = op >= OP_EXECUTE && op <= OP_FINALIZE;
    const char *text = named ? take_text(reader, &length) : NULL;
    if (op < OP_OPEN || op > OP_CHDIR || (count && op != OP_EXECUTE && op != OP_QUERY) ||
        ((op == OP_OPEN || op == OP_CHDIR) && *id) || (named && !text) || (op > OP_FETCH && reader->at != reader->end))
        return MALFORMED;
    if (!install_vfs()) {
        wrapper(failure, "SQLite service cannot install its VFS");
        return DONE;
    }
    if (op == OP_OPEN) {
        open_connection(failure, text, length, id);
        return DONE;
    }
    /* The guest's working directory, or none (an empty path, or one the
     * service cannot enter): the names SQLite resolves itself (ATTACH,
     * VACUUM INTO) are relative to it, or fail. */
    if (op == OP_CHDIR) {
        char *path = length ? sqlite3_mprintf("%.*s", (int)length, text) : NULL;
        has_cwd = path && chdir(path) == 0;
        if (length && !path) capture(failure, NULL, SQLITE_NOMEM);
        sqlite3_free(path);
        return DONE;
    }
    Entry *entry = find(*id, statement);
    if (!entry) {
        wrapper(failure, "stale SQLite handle");
        return STALE;
    }
    /* PREPARE may grow the table, so the connection is kept by slot. */
    uint32_t slot = (uint32_t)(entry - entries), conn = statement ? entry->owner - 1 : slot;
    sqlite3 *db = entries[conn].handle;
    int status = SQLITE_OK, outcome = DONE;
    if (op == OP_PREPARE) prepare(failure, text, length, slot + 1, id);
    if (op >= OP_EXECUTE && op <= OP_FETCH) outcome = step(failure, reader, op, entry, count);
    if (op == OP_RESET) reset(failure, db, entry->handle);
    if (op == OP_FINALIZE) {
        status = sqlite3_finalize(entry->handle);
        entries[entry->owner - 1].count--;
        remove_entry(entry);
        cleanup(failure, db, status);
    }
    /* CLOSE is Connection:close, SQLITE_BUSY while statements live;
     * CLOSE_CONN is the lease ledger's retirement and always succeeds. */
    for (uint32_t index = 0; op == OP_CLOSE_CONN && index < used; index++) {
        if (entries[index].handle && entries[index].owner == slot + 1) {
            sqlite3_finalize(entries[index].handle);
            remove_entry(&entries[index]);
        }
    }
    if (op == OP_CLOSE_CONN) sqlite3_close_v2(db);
    if (op == OP_CLOSE) status = sqlite3_close(db);
    if ((op == OP_CLOSE || op == OP_CLOSE_CONN) && status == SQLITE_OK) {
        remove_entry(entry);
        connections--;
    }
    if (op == OP_CLOSE) cleanup(failure, db, status);
    if (op >= OP_AUTOCOMMIT) {
        static const char *const commands[] = { "BEGIN DEFERRED", "COMMIT", "ROLLBACK" };
        int autocommit = sqlite3_get_autocommit(db);
        if (op != OP_AUTOCOMMIT && autocommit == (op == OP_BEGIN)) {
            status = sqlite3_exec(db, commands[op - OP_BEGIN], NULL, NULL, NULL);
            if (status != SQLITE_OK) capture(failure, db, status);
            autocommit = sqlite3_get_autocommit(db);
        }
        put_u8((uint8_t)autocommit);
    }
    track(&entries[conn]);
    return outcome;
}

static void put_failure(int code, int extended, const char *message, int cleanup_code, const char *cleanup) {
    put_u32((uint32_t)code);
    put_u32((uint32_t)extended);
    put_text(message);
    put_u32((uint32_t)cleanup_code);
    if (cleanup) put_text(cleanup);
    else put_u32(ABSENT);
}

EXPORT("titan_sql_svc_alloc") void *titan_sql_svc_alloc(uint32_t size) {
    return size && size <= MAX_FRAME ? malloc(size) : NULL;
}

EXPORT("titan_sql_svc_free") void titan_sql_svc_free(void *pointer) { free(pointer); }

/* Returns the reply: a u32 frame length, then the frame. */
EXPORT("titan_sql_svc_dispatch") const uint8_t *titan_sql_svc_dispatch(const uint8_t *frame, uint32_t length) {
    static const uint8_t zero[HEADER];
    Reader reader = { frame, frame + length, 0 };
    Failure failure = { 0 };
    uint8_t head[HEADER] = { 0 };
    uint32_t count = 0;
    uint64_t id = 0;
    int outcome = MALFORMED;
    if (out != small && out_capacity > (1u << 20)) {
        free(out);
        out = small;
        out_capacity = sizeof small;
    }
    out_length = 4;
    out_failure = 0;
    put(zero, HEADER);
    const uint8_t *header = take(&reader, HEADER);
    if (header && header[1] == VERSION && !header[2] && !header[3]) {
        memcpy(&count, header + 4, 4);
        memcpy(&id, header + 8, 8);
        head[0] = header[0];
        if (count <= MAX_PARAMETERS) outcome = run(&failure, &reader, header[0], count, &id);
    }
    int overflow = out_failure;
    if (outcome != DONE || failure.failed || overflow) {
        out_length = 4 + HEADER;
        out_failure = 0;
        head[1] = outcome == DONE ? STATUS_ERROR : STATUS_PROTOCOL;
        if (head[0] == OP_OPEN || head[0] == OP_PREPARE) id = 0;
        if (outcome == MALFORMED) put_failure(0, 0, "malformed SQLite request frame", 0, NULL);
        else if (failure.failed) put_failure(failure.code, failure.extended, failure.message, failure.cleanup_code, failure.cleanup);
        else put_failure(overflow, overflow, overflow == SQLITE_TOOBIG ?
            "SQLite result exceeds the browser frame limit" : "out of memory building SQLite reply", 0, NULL);
        sqlite3_free(failure.owned);
        sqlite3_free(failure.cleanup);
    }
    if (out_failure) { /* Even the failure did not fit; this one always does. */
        out_length = 4 + HEADER;
        out_failure = 0;
        head[1] = STATUS_ERROR;
        put_failure(SQLITE_NOMEM, SQLITE_NOMEM, "out of memory building SQLite reply", 0, NULL);
    }
    /* Byte 2: some connection holds a write a forced stop would lose. */
    head[2] = writers > 0;
    memcpy(head + 8, &id, 8);
    memcpy(out + 4, head, HEADER);
    uint32_t frame_length = out_length - 4;
    memcpy(out, &frame_length, 4);
    return out;
}
