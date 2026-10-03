#ifndef TITAN_SPEC_FS_FIXTURE_SUPPORT_H
#define TITAN_SPEC_FS_FIXTURE_SUPPORT_H

#include <stddef.h>

/* Synchronous setup/cleanup must also work outside a Titan Runtime. */
int titan_spec_mkdtemp(char *pattern);
/* 1 identifies Windows' missing symbolic-link privilege; other errors < 0. */
int titan_spec_symlink(const char *target, const char *path, int directory);
int titan_spec_remove_if_present(const char *path);

int titan_spec_write_file(const char *path, const char *contents, size_t length);

#endif
