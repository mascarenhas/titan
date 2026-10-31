#include "loader.h"
#include <emscripten.h>

EM_ASYNC_JS(void, browser_loader_async_wait, (), {
    await new Promise(resolve => setTimeout(resolve, 15));
});

void browser_loader_wait(int kind) {
    if (kind == 0) emscripten_sleep(15);
    else browser_loader_async_wait();
}

int browser_loader_pattern(const unsigned char *bytes, size_t length) {
    if (length != 20 * 1024 * 1024) return 0;
    for (size_t index = 0; index < length; ++index) {
        if (bytes[index] != index % 251) return 0;
    }
    return 1;
}
