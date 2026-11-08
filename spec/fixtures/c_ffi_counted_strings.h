#ifndef TITAN_TEST_COUNTED_STRINGS_H
#define TITAN_TEST_COUNTED_STRINGS_H

#include <stdio.h>

static int (*const titan_test_counted_snprintf)(char *, size_t, const char *, ...) = snprintf;

#endif
