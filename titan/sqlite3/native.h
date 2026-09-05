#ifndef TITAN_SQLITE3_NATIVE_H
#define TITAN_SQLITE3_NATIVE_H

#include <stddef.h>
#include <sqlite3.h>

/* This header declares only native carriers. All operations are restricted
 * source foreign functions in worker.titan; no Lua/Titan value reaches them. */
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
} TitanSqlitePacket;

#endif
