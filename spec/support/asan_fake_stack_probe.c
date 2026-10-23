/* Implementation notes: doc/implementation/continuous-integration.md#fake-stack-probe */
/*
 * Exit 0 only when this compiler and ASAN_OPTIONS place a frame that calls
 * setjmp, and therefore its jmp_buf, on ASan's fake stack. The CI sanitizer
 * job's coroutine unwinding gate depends on that placement to exercise the
 * crossing code's fake-stack address normalization.
 */
#include <sanitizer/asan_interface.h>
#include <setjmp.h>
#include <stdio.h>

static int __attribute__((noinline)) setjmp_buffer_is_on_fake_stack(void) {
  jmp_buf buffer;
  if (setjmp(buffer) != 0) {
    return 0;
  }
  void *fake_stack = __asan_get_current_fake_stack();
  if (fake_stack == NULL) {
    fprintf(stderr, "asan fake-stack probe: no fake stack for this thread "
        "(is detect_stack_use_after_return=1 in ASAN_OPTIONS?)\n");
    return 0;
  }
  if (__asan_addr_is_in_fake_stack(fake_stack, &buffer, NULL, NULL) == NULL) {
    fprintf(stderr, "asan fake-stack probe: the setjmp frame's jmp_buf %p is "
        "on the real stack\n", (void *)&buffer);
    return 0;
  }
  printf("asan fake-stack probe: the setjmp frame's jmp_buf is on the fake stack\n");
  return 1;
}

int main(void) {
  return setjmp_buffer_is_on_fake_stack() ? 0 : 1;
}
