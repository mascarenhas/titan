#include "budget.h"

/* Separate translation unit intentionally prevents scalar replacement of the
 * caller's fixed C frame without requiring LTO/inline-asm exceptions. */
int budget_check_pad(const unsigned int *pad, unsigned int expected) {
  return pad[0] == expected && pad[63] == (expected ^ 0x329U);
}

int budget_check_tail(const unsigned int *pad, unsigned int expected) {
  return pad[0] == expected && pad[3] == (expected ^ 0x329U);
}
