#ifndef TITAN_SPEC_REFLECTION_RECURSIVE_H
#define TITAN_SPEC_REFLECTION_RECURSIVE_H

typedef int titan_reflect_row[3];

static inline long double titan_reflect_precise_long_double(void) {
    return 0x1.000000000000001p0L;
}

typedef struct titan_reflect_pair {
    int quot;
    int rem;
} titan_reflect_pair;

typedef int *const titan_reflect_const_pointer;

typedef struct titan_reflect_qualified {
    int before;
    const unsigned int first : 3;
    const signed int second : 4;
    unsigned int third : 5;
    int after;
    titan_reflect_const_pointer pointer;
    int row[2];
} titan_reflect_qualified;

static inline titan_reflect_qualified titan_reflect_make_qualified(void) {
    titan_reflect_qualified result = {23, 5, -3, 19, 29, 0, {31, 37}};
    return result;
}

typedef struct titan_reflect_self {
    int marker;
    struct titan_reflect_self *next;
} titan_reflect_self;

typedef struct titan_reflect_left titan_reflect_left;
typedef struct titan_reflect_right titan_reflect_right;

struct titan_reflect_left {
    titan_reflect_right *right;
};

struct titan_reflect_right {
    titan_reflect_left *left;
};

#endif
