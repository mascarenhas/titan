#ifndef TITAN_SPECULATIVE_PROBES_H
#define TITAN_SPECULATIVE_PROBES_H

#include <stddef.h>

/* probe_cc.sh rejects a probe naming a `speculative_reject` declaration and
   reports a `speculative_missing` one as an unavailable command. */
typedef int spec_ok_t;
typedef long spec_wide_t;
typedef int speculative_reject_t;
typedef int speculative_missing_t;

typedef struct spec_item { int value; } spec_item;
typedef struct spec_other { int value; } spec_other;
typedef struct speculative_reject_item { int value; } speculative_reject_item;

typedef struct spec_fam { size_t count; int items[]; } spec_fam;
typedef struct speculative_reject_fam { size_t count; int items[]; } speculative_reject_fam;

/* The C parser leaves a sizeof-based extent to the target compiler. */
#define SPEC_ROW_COUNT (sizeof(spec_item) / sizeof(int) * 4)
typedef int spec_row[SPEC_ROW_COUNT];
typedef int speculative_reject_row[SPEC_ROW_COUNT];

typedef enum spec_color { SPEC_RED, SPEC_GREEN, SPEC_BLUE } spec_color;

static spec_ok_t spec_three(void) { return 3; }
static spec_item spec_items[2];
static spec_item *spec_first(void) { return &spec_items[0]; }

#endif
