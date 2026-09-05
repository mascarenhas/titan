#ifndef TITAN_SPEC_REFLECTION_RECURSIVE_H
#define TITAN_SPEC_REFLECTION_RECURSIVE_H

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
