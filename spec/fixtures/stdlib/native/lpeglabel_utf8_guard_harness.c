#define _GNU_SOURCE 1

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>

/*
** Include the production translation unit so this native regression can call
** its private decoder directly. The rest of the vendored engine is linked
** from the ordinary private archive.
*/
#include "lplvm.c"

#if defined(__APPLE__)
#define TITAN_MAP_ANONYMOUS MAP_ANON
#else
#define TITAN_MAP_ANONYMOUS MAP_ANONYMOUS
#endif

int main(void) {
    long configured_page_size = sysconf(_SC_PAGESIZE);
    size_t page_size;
    unsigned char *pages;
    const char *lead;
    int decoded = 0;

    assert(configured_page_size > 0);
    page_size = (size_t)configured_page_size;
    pages = mmap(NULL, page_size * 2u, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | TITAN_MAP_ANONYMOUS, -1, 0);
    assert(pages != MAP_FAILED);
    assert(mprotect(pages + page_size, page_size, PROT_NONE) == 0);

    /*
    ** The byte is readable, but the next byte is not. A decoder that enters
    ** the continuation loop for this impossible five-byte lead faults while
    ** reading the protected page; the Lua-5.5.1-derived guard returns first.
    */
    pages[page_size - 1u] = 0xF8u;
    lead = (const char *)(pages + page_size - 1u);
    assert(utf8_decode(lead, &decoded) == NULL);

    assert(munmap(pages, page_size * 2u) == 0);
    return 0;
}
