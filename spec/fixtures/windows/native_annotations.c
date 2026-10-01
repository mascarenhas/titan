#include "llhttp.h"
#include "sqlite3.h"

int titan_native_header_probe(llhttp_t *parser, sqlite3 **database) {
    llhttp_init(parser, HTTP_REQUEST, 0);
    return llhttp_get_errno(parser) + sqlite3_open(":memory:", database) +
        sqlite3_version[0];
}
