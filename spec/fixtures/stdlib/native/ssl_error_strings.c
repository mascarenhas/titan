/* This object belongs only to one fresh archive-linked child. It selects
 * OpenSSL's documented sticky no-error-strings initialization before Titan
 * module startup; it never mutates the native error queue.
 */
#include <openssl/ssl.h>
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/pemerr.h>
#include "ssl_error_strings.h"
static int initialized, suppressed;
__attribute__((constructor)) static void select_no_error_strings(void) {
    initialized = OPENSSL_init_ssl(OPENSSL_INIT_NO_LOAD_CRYPTO_STRINGS |
                                  OPENSSL_INIT_NO_LOAD_SSL_STRINGS, NULL);
    suppressed = ERR_reason_error_string(
        ERR_PACK(ERR_LIB_PEM, 0, PEM_R_NO_START_LINE)) == NULL;
}
int titan_test_ssl_no_strings_initialized(void) { return initialized; }
int titan_test_ssl_error_strings_suppressed(void) { return suppressed; }
