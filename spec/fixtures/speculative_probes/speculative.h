#ifndef TITAN_SPECULATIVE_PROBES_H
#define TITAN_SPECULATIVE_PROBES_H

#include <stddef.h>

/* probe_cc.sh rejects a probe naming a `speculative_reject` declaration,
   reports a `speculative_missing` one as an unavailable command, and fails a
   `speculative_flaky` one once per probe workspace before it recovers. */
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

/* Its compiler-selected carrier is wider than lua_Integer, so each use of an
   enumerator also asks the compiler whether that value fits. */
typedef enum spec_wide_enum {
    SPEC_WIDE_ZERO = 0,
    SPEC_WIDE_HIGH = 0x8000000000000000ULL
} spec_wide_enum;

typedef int speculative_flaky_t;

/* Untagged, so an importer reads its fields through the producer's own
   declaration rather than rebinding them to a file-scope tag it declares. */
typedef struct { spec_color color; } speculative_reject_paint;

static spec_ok_t spec_three(void) { return 3; }
static speculative_flaky_t spec_flaky_value(void) { return 2; }
static spec_item spec_items[2];
static spec_item *spec_first(void) { return &spec_items[0]; }
static speculative_reject_paint spec_paints[2];
static speculative_reject_paint *spec_first_paint(void) { return &spec_paints[0]; }

#endif
