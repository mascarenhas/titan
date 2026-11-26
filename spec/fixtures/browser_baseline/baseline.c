/*
 * Measurement-only helper for the #329 size/speed baseline.
 *
 * baseline_now reports seconds from the engine's monotonic clock (a wall clock,
 * unlike os.clock's CPU time, so a suspension is counted at its real cost).
 * baseline_sleep suspends the promising entry through a JSPI import.
 */
#define _POSIX_C_SOURCE 200809L /* clock_gettime under --std=c99 */
#include <time.h>

#include "baseline.h"
#include "../browser_runtime/fixture_controls.h"

double baseline_now(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}

void baseline_sleep(int milliseconds)
{
    fixture_sleep(milliseconds);
}
