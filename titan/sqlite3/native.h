#ifndef TITAN_SQLITE3_NATIVE_H
#define TITAN_SQLITE3_NATIVE_H

#include <stddef.h>
#include <sqlite3.h>

/* This header declares native carriers, plus the one atomic exchange Titan's
 * FFI cannot spell. All operations are restricted source foreign functions in
 * worker.titan; no Lua/Titan value reaches them. */
typedef struct TitanSqliteCell {
    int kind;
    sqlite3_int64 integer_value;
    double float_value;
    char *bytes;
    size_t length;
} TitanSqliteCell;

typedef struct TitanSqliteColumn {
    char *name;
    char *declared_type;
} TitanSqliteColumn;

typedef struct TitanSqlitePacket {
    sqlite3 *db;
    sqlite3_stmt *stmt;
    char *input;
    size_t input_length;
    TitanSqliteCell *arguments;
    int argument_count;
    TitanSqliteColumn *columns;
    int column_count;
    TitanSqliteCell *cells;
    int cell_count;
    int has_row;
    int done;
    int parameter_count;
    int autocommit;
    sqlite3_int64 changes;

    int failed;
    int code;
    int extended_code;
    char *message;
    const char *fallback_message;
    int cleanup_code;
    int cleanup_extended_code;
    char *cleanup_message;

    /* Native ownership not yet transferred to a published Titan owner. */
    int owns_db;
    int owns_stmt;
    int needs_reset;

    /* Operation entry called by the sqlite_run_worker trampoline. */
    void (*worker)(void *);
    /* Loop thread only: set from submission until the wait returns or
     * raises. A Lua-state-close unwind of the wait leaves it set. */
    int pending;
    /* The trampoline and an abandoning unwind each exchange their side in;
     * whichever finds the other's mark releases the packet. */
    int handoff;
} TitanSqlitePacket;

#define TITAN_SQLITE_WORKER_FINISHED 1
#define TITAN_SQLITE_WORKER_ABANDONED 2

/* Titan's FFI cannot spell the compiler's generic atomic builtin; this one
 * expression is the whole C part of the handoff. */
/* Implementation notes: doc/implementation/sqlite3-library.md#lua-state-close */
static inline int titan_sqlite_handoff(TitanSqlitePacket *packet, int side) {
    return __atomic_exchange_n(&packet->handoff, side, __ATOMIC_ACQ_REL);
}

#endif
