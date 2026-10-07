#define USING_UV_SHARED 1
#include <uv.h>
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <llhttp.h>
#include <sqlite3.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/ssl.h>

static int async_calls;
static int messages;
static void on_async(uv_async_t *handle) {
    ++async_calls;
    uv_close((uv_handle_t *)handle, NULL);
}
static int on_message_complete(llhttp_t *parser) {
    (void)parser;
    ++messages;
    return 0;
}
#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "native SDK check failed at line %d: %s\n", __LINE__, #condition); \
    return 1; } } while (0)

int main(int argc, char **argv) {
    uv_loop_t loop;
    uv_async_t async;
    llhttp_t parser;
    llhttp_settings_t settings;
    const char request[] = "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n";
    sqlite3 *database = NULL;
    sqlite3_stmt *statement = NULL;
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int digest_size = 0;
    static const unsigned char expected[32] = {
        0xba,0x78,0x16,0xbf,0x8f,0x01,0xcf,0xea,0x41,0x41,0x40,0xde,0x5d,0xae,0x22,0x23,
        0xb0,0x03,0x61,0xa3,0x96,0x17,0x7a,0x9c,0xb4,0x10,0xff,0x61,0xf2,0x00,0x15,0xad
    };
    SSL_CTX *tls;
    CHECK(uv_version() == UV_VERSION_HEX);
    CHECK(uv_loop_init(&loop) == 0);
    CHECK(uv_async_init(&loop, &async, on_async) == 0);
    CHECK(uv_async_send(&async) == 0);
    CHECK(uv_run(&loop, UV_RUN_DEFAULT) == 0);
    CHECK(async_calls == 1 && uv_loop_close(&loop) == 0);
    llhttp_settings_init(&settings);
    settings.on_message_complete = on_message_complete;
    llhttp_init(&parser, HTTP_REQUEST, &settings);
    CHECK(llhttp_execute(&parser, request, sizeof(request) - 1) == HPE_OK);
    CHECK(messages == 1);
    CHECK(strcmp(sqlite3_libversion(), SQLITE_VERSION) == 0);
    CHECK((const void *)GetProcAddress(GetModuleHandleW(L"libsqlite3-0.dll"),
        "sqlite3_version") == (const void *)sqlite3_version);
    CHECK(sqlite3_open(":memory:", &database) == SQLITE_OK);
    CHECK(sqlite3_prepare_v2(database, "SELECT 6 * 7", -1, &statement, NULL) == SQLITE_OK);
    CHECK(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 42);
    CHECK(sqlite3_finalize(statement) == SQLITE_OK && sqlite3_close(database) == SQLITE_OK);
    CHECK(OpenSSL_version_num() == OPENSSL_VERSION_NUMBER);
    CHECK(argc == 2);
    if (strcmp(argv[1], "system") != 0)
        CHECK(strcmp(OPENSSL_info(OPENSSL_INFO_CONFIG_DIR), argv[1]) == 0);
    CHECK(EVP_Digest("abc", 3, digest, &digest_size, EVP_sha256(), NULL) == 1);
    CHECK(digest_size == sizeof(expected) && memcmp(digest, expected, sizeof(expected)) == 0);
    tls = SSL_CTX_new(TLS_method());
    CHECK(tls != NULL);
    SSL_CTX_free(tls);
    puts("Windows native SDK: libuv async, llhttp request, SQLite data/query, OpenSSL digest/TLS passed");
    return 0;
}
