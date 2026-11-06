#ifndef TITAN_TRACE_FIXTURE_FRAME_LINES_H
#define TITAN_TRACE_FIXTURE_FRAME_LINES_H
#include <stddef.h>
#include <string.h>

/* Match a suffix of one whole frame line, terminated by newline or string end.
 * Ordinary frame tails include ": in "; anonymous definitions use their exact
 * file/definition-line suffix. Never copy or append to the captured trace. */
static inline int trace_fixture_count_frame_lines(const char *trace,
                                                 const char *suffix) {
  size_t suffix_length = strlen(suffix);
  int count = 0;
  while (*trace) {
    size_t line_length = strcspn(trace, "\n");
    if (line_length >= suffix_length &&
        memcmp(trace + line_length - suffix_length, suffix, suffix_length) == 0)
      ++count;
    trace += line_length;
    if (*trace == '\0') break;
    ++trace;
  }
  return count;
}

#endif
