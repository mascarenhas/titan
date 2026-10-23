/* This object belongs only to the isolated archive-linked SSL test child.
 * Install OpenSSL's public paired allocation callbacks before module startup;
 * all allocations pass through until a public operation explicitly arms one
 * failure. The one-shot gate clears before error reporting or cleanup runs.
 * The callbacks also count OpenSSL's live blocks, so a scenario can check
 * that a native owner released everything it allocated.
 */
#include <openssl/crypto.h>
#include <openssl/ssl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include "ssl_allocator_fixture.h"

static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
static int installed, armed, requested, matched, fired;
static long live;
static const char *wanted_file;
static int wanted_line;

static int fail_requested(const char *file, int line) {
    int fail = 0;
    pthread_mutex_lock(&gate);
    if (armed) {
        const char *base = file ? strrchr(file, '/') : NULL;
        base = base ? base + 1 : file;
        if ((!wanted_file || (base && !strcmp(base, wanted_file))) &&
            (!wanted_line || line == wanted_line)) {
            matched++;
            if (matched == requested) {
                fired++;
                armed = 0; /* Error reporting and cleanup immediately work. */
                fail = 1;
            }
        }
    }
    pthread_mutex_unlock(&gate);
    return fail;
}
static void count_live(long change) {
    pthread_mutex_lock(&gate);
    live += change;
    pthread_mutex_unlock(&gate);
}
static void *probe_malloc(size_t bytes, const char *file, int line) {
    void *result;
    if (fail_requested(file, line)) return NULL;
    result = malloc(bytes);
    if (result) count_live(1);
    return result;
}
static void *probe_realloc(void *pointer, size_t bytes, const char *file, int line) {
    void *result;
    if (fail_requested(file, line)) return NULL;
    result = realloc(pointer, bytes);
    if (!pointer && result) count_live(1);
    /* A zero-byte realloc may free the block and return NULL. */
    else if (pointer && !result && bytes == 0) count_live(-1);
    return result;
}
static void probe_free(void *pointer, const char *file, int line) {
    (void)file; (void)line;
    if (pointer) count_live(-1);
    free(pointer);
}
__attribute__((constructor)) static void install_probe(void) {
    installed = CRYPTO_set_mem_functions(probe_malloc, probe_realloc, probe_free);
}
int titan_ssl_allocator_installed(void) { return installed; }
/* Callback source locations are OpenSSL implementation details. These targeted
 * layout cases are verified against bundled 3.5.7 and system 3.5.9; other release
 * lines still exercise the location-independent first-allocation cases.
 */
int titan_ssl_allocator_layout_supported(void) {
    return OPENSSL_version_major() == 3 && OPENSSL_version_minor() == 5 &&
           (OPENSSL_version_patch() == 7 || OPENSSL_version_patch() == 9);
}
void titan_ssl_allocator_arm(const char *file, int line, int ordinal) {
    pthread_mutex_lock(&gate);
    wanted_file = file && *file ? file : NULL;
    wanted_line = line;
    requested = ordinal;
    matched = fired = 0;
    armed = ordinal > 0;
    pthread_mutex_unlock(&gate);
}
/* SSL_CTX_new can itself use a BIO for optional configuration in system mode.
 * Count that successful public constructor's BIO allocations without failing
 * any, then select the following PEM input BIO in the actual Titan operation.
 */
int titan_ssl_allocator_pem_bio_ordinal(void) {
    SSL_CTX *context;
    int result;
    pthread_mutex_lock(&gate);
    wanted_file = "bio_lib.c";
    wanted_line = requested = matched = fired = 0;
    armed = 1; /* No positive match can equal requested zero: pass-through only. */
    pthread_mutex_unlock(&gate);
    context = SSL_CTX_new(TLS_client_method());
    pthread_mutex_lock(&gate);
    result = matched + 1;
    armed = 0;
    wanted_file = NULL;
    pthread_mutex_unlock(&gate);
    SSL_CTX_free(context);
    return context ? result : 0;
}
void titan_ssl_allocator_disarm(void) {
    pthread_mutex_lock(&gate);
    armed = 0;
    wanted_file = NULL;
    pthread_mutex_unlock(&gate);
}
int titan_ssl_allocator_fired(void) {
    int result;
    pthread_mutex_lock(&gate);
    result = fired;
    pthread_mutex_unlock(&gate);
    return result;
}
long titan_ssl_allocator_live(void) {
    long result;
    pthread_mutex_lock(&gate);
    result = live;
    pthread_mutex_unlock(&gate);
    return result;
}
