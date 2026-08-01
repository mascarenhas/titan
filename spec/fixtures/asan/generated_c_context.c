#line 725 "synthetic_input.titan"
__attribute__((noinline, visibility("default")))
int titan_test_generated_c_context(volatile int *value) { /* GENERATED_C_CONTEXT_TARGET */
    return *value + 7;
}

/* Its line metadata deliberately changes the unrelated function's code. */
#line 900 "unrelated_input.titan"
__attribute__((noinline, visibility("default")))
int titan_test_unrelated_line_value(void) {
    return __LINE__;
}

#line 950 "second_input.titan"
__attribute__((noinline, visibility("default")))
int titan_test_second_context(volatile int *value) { /* SECOND_CONTEXT_TARGET */
    return *value - 3;
}
