#define _GNU_SOURCE 1

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#if defined(_WIN32)
#include <windows.h>
#else
#include <sys/mman.h>
#include <unistd.h>
#endif

/*
** Include the production translation unit so this native regression can call
** its private decoder directly. The rest of the vendored engine is linked
** from the ordinary private archive.
*/
#include "lplvm.c"

#if !defined(_WIN32)
#if defined(__APPLE__)
#define TITAN_MAP_ANONYMOUS MAP_ANON
#else
#define TITAN_MAP_ANONYMOUS MAP_ANONYMOUS
#endif
#endif

int main(void) {
    size_t page_size;
    unsigned char *pages;
    const char *lead;
    int decoded = 0;

#if defined(_WIN32)
    SYSTEM_INFO system_info;
    DWORD old_protection;
    GetSystemInfo(&system_info);
    page_size = (size_t)system_info.dwPageSize;
    assert(page_size > 0);
    pages = VirtualAlloc(NULL, page_size * 2u, MEM_RESERVE | MEM_COMMIT,
                         PAGE_READWRITE);
    assert(pages != NULL);
    assert(VirtualProtect(pages + page_size, page_size, PAGE_NOACCESS,
                          &old_protection) != 0);
#else
    long configured_page_size = sysconf(_SC_PAGESIZE);
    assert(configured_page_size > 0);
    page_size = (size_t)configured_page_size;
    pages = mmap(NULL, page_size * 2u, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | TITAN_MAP_ANONYMOUS, -1, 0);
    assert(pages != MAP_FAILED);
    assert(mprotect(pages + page_size, page_size, PROT_NONE) == 0);
#endif

    /*
    ** The byte is readable, but the next byte is not. A decoder that enters
    ** the continuation loop for this impossible five-byte lead faults while
    ** reading the protected page; the Lua-5.5.1-derived guard returns first.
    */
    pages[page_size - 1u] = 0xF8u;
    lead = (const char *)(pages + page_size - 1u);
    assert(utf8_decode(lead, &decoded) == NULL);

#if defined(_WIN32)
    assert(VirtualFree(pages, 0, MEM_RELEASE) != 0);
#else
    assert(munmap(pages, page_size * 2u) == 0);
#endif
    return 0;
}
