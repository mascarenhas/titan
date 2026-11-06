#include "loader.h"
#include <emscripten.h>
#include <stdio.h>

static char loader_stdout_buffer[512];
static char loader_stderr_buffer[512];

int browser_loader_buffer_stdio(void) {
    int out = setvbuf(stdout, loader_stdout_buffer, _IOFBF, sizeof(loader_stdout_buffer));
    int err = setvbuf(stderr, loader_stderr_buffer, _IOFBF, sizeof(loader_stderr_buffer));
    return out != 0 || err != 0;
}

EM_ASYNC_JS(void, browser_loader_async_wait, (), {
    await new Promise(resolve => setTimeout(resolve, 15));
});

/* Abort while a real JSPI entry is parked and never resolve its import.
 * Fatal disposal must not wait for that permanently pending Promise. */
EM_ASYNC_JS(void, browser_loader_abort_wait, (), {
    setTimeout(() => abort('loader abort while suspended'), 10);
    await new Promise(() => {});
});

void browser_loader_wait(int kind) {
    if (kind == 0) emscripten_sleep(15);
    else browser_loader_async_wait();
}

extern void titan_browser_complete(int kind, int status,
    const unsigned char *bytes, size_t length);

void browser_loader_completion(int kind) {
    titan_browser_complete(kind, 99, NULL, 0);
}

int browser_loader_pattern(const unsigned char *bytes, size_t length) {
    if (length != 20 * 1024 * 1024) return 0;
    for (size_t index = 0; index < length; ++index) {
        if (bytes[index] != index % 251) return 0;
    }
    return 1;
}
