#ifndef TITAN_SPEC_REFLECTION_RECURSIVE_H
#define TITAN_SPEC_REFLECTION_RECURSIVE_H

typedef int titan_reflect_row[3];

typedef struct titan_reflect_pair {
    int quot;
    int rem;
} titan_reflect_pair;

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
