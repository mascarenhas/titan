/*
 * Measurement-only helper for the #329 size/speed baseline.
 *
 * baseline_now reports seconds from the engine's monotonic clock (a wall clock,
 * unlike os.clock's CPU time, so a suspension is counted at its real cost).
 * baseline_sleep suspends the promising entry through a JSPI import.
 */
#include <emscripten.h>

#include "baseline.h"

double baseline_now(void)
{
    return emscripten_get_now() / 1000.0;
}

void baseline_sleep(int milliseconds)
{
    emscripten_sleep(milliseconds);
}
