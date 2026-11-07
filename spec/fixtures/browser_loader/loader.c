#include "loader.h"
#include <emscripten.h>
#include <stdio.h>
#include <titan/browser.h>
#include "../browser_runtime/fixture_controls.h"

EM_JS(void, browser_loader_initialize_hook, (), {
    const bindings = Module['titanBrowserBridge'].options.bindings;
    const publish = bindings?.__loaderTest;
    if (publish) publish(Object.freeze({
        rawEntry: () => Module['_titan_browser_entry'](0n, 0, 0, 0),
        privateEntry: () => Module['_titan_mco_entry'](0),
        abort: () => abort('loader abort inside bridge binding'),
        watchMemoryCalls: callback => {
            const owner = Module['titanBrowserBridge'];
            const allocate = Module['_malloc'], free = Module['_free'];
            Module['_malloc'] = size => {
                callback(Object.freeze({kind: 'allocate', poisoned: !!owner.terminal}));
                return allocate(size);
            };
            Module['_free'] = pointer => {
                callback(Object.freeze({kind: 'free', poisoned: !!owner.terminal}));
                return free(pointer);
            };
            return () => {
                Module['_malloc'] = allocate;
                Module['_free'] = free;
            };
        },
        watchResponses: callback => {
            const owner = Module['titanBrowserBridge'], respond = owner.importResponse;
            owner.importResponse = (pointer, state, action) => {
                callback(Object.freeze({copy: () => Module.HEAPU8.slice(pointer, pointer + 56)}));
                return respond.call(owner, pointer, state, action);
            };
            return () => { owner.importResponse = respond; };
        },
    }));
    bindings?.initialize_hook?.();
});

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

EM_JS(uint64_t, browser_loader_current_operation, (), {
    return Module['titanBrowserBridge'].pending.id;
});

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
