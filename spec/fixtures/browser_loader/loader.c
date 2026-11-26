#include "loader.h"
#include <stdint.h>
#include <stdio.h>
#include "../browser_runtime/fixture_controls.h"

/* Loader-suite host hooks and waits (fixture-imports.mjs). */
TITAN_WASM_IMPORT("browser_loader_initialize_hook") void browser_loader_initialize_hook(void);
TITAN_WASM_IMPORT("browser_loader_async_wait") void browser_loader_async_wait(void);
TITAN_WASM_IMPORT("browser_loader_current_operation") uint64_t browser_loader_current_operation(void);

void browser_loader_publish(void) {
    gate_test_publish();
    browser_loader_initialize_hook();
}

static char loader_stdout_buffer[512];
static char loader_stderr_buffer[512];

int browser_loader_buffer_stdio(void) {
    int out = setvbuf(stdout, loader_stdout_buffer, _IOFBF, sizeof(loader_stdout_buffer));
    int err = setvbuf(stderr, loader_stderr_buffer, _IOFBF, sizeof(loader_stderr_buffer));
    return out != 0 || err != 0;
}

void browser_loader_wait(int kind) {
    if (kind == 0) fixture_sleep(15);
    else browser_loader_async_wait();
}

void browser_loader_completion(int kind) {
    titan_browser_completion completion = {0};
    completion.operation_id = browser_loader_current_operation();
    completion.operation = kind == 9 ? 9 : TITAN_BROWSER_MAIN;
    completion.application_status = 99;
    titan_browser_complete(&completion);
}

int browser_loader_pattern(const unsigned char *bytes, size_t length) {
    if (length != 20 * 1024 * 1024) return 0;
    for (size_t index = 0; index < length; ++index) {
        if (bytes[index] != index % 251) return 0;
    }
    return 1;
}
