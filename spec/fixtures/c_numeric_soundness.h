#ifndef TITAN_SPEC_C_NUMERIC_SOUNDNESS_H
#define TITAN_SPEC_C_NUMERIC_SOUNDNESS_H

#include <float.h>
#include <limits.h>
#include <math.h>

typedef signed char titan_spec_i8;
typedef unsigned char titan_spec_u8;
typedef _Bool titan_spec_bool;
typedef unsigned long long titan_spec_ull;
typedef float titan_spec_float;
typedef double titan_spec_double;
typedef long double titan_spec_long_double;

static int titan_spec_numeric_mutations;

static inline void titan_spec_take_i8(titan_spec_i8 value)
{
    (void)value;
    titan_spec_numeric_mutations++;
}

static inline int titan_spec_numeric_mutation_count(void)
{
    return titan_spec_numeric_mutations;
}

static inline titan_spec_ull titan_spec_ull_max(void)
{
    return ULLONG_MAX;
}

static inline titan_spec_double titan_spec_double_max(void)
{
    return DBL_MAX;
}

static inline titan_spec_double titan_spec_double_inf(void)
{
    return INFINITY;
}

static inline titan_spec_double titan_spec_double_nan(void)
{
    return NAN;
}

static inline titan_spec_float titan_spec_float_inf(void)
{
    return INFINITY;
}

static inline titan_spec_long_double titan_spec_long_double_inf(void)
{
    return INFINITY;
}

#if defined(__SIZEOF_INT128__)
typedef unsigned __int128 titan_spec_u128;

static inline titan_spec_u128 titan_spec_u128_max(void)
{
    return ~(titan_spec_u128)0;
}
#endif

#endif
