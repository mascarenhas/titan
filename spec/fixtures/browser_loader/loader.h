#ifndef TITAN_BROWSER_LOADER_FIXTURE_H
#define TITAN_BROWSER_LOADER_FIXTURE_H
#include <stddef.h>
void browser_loader_wait(int kind);
void browser_loader_abort_wait(void);
int browser_loader_pattern(const unsigned char *bytes, size_t length);
#endif
