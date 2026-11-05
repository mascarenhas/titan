#ifndef TITAN_SPEC_MODULE_INITIALIZERS_H
#define TITAN_SPEC_MODULE_INITIALIZERS_H

#define INITIALIZER_MACRO 17
enum { INITIALIZER_ENUM = 9 };

static int initializer_value = 23;
static int initializer_array[2] = {3, 5};
static struct { int number; } initializer_object = {11};
static int initializer_trace = 0;

static inline int initializer_mark(int digit) {
    initializer_trace = initializer_trace * 10 + digit;
    return digit;
}

static inline int initializer_read_trace(void) {
    return initializer_trace;
}

static inline int initializer_count(void) {
    return 3;
}

static int (*initializer_pointer)(int) = initializer_mark;

#endif
