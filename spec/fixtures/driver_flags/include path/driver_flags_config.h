#ifndef TITAN_DRIVER_FLAGS_CONFIG_H
#define TITAN_DRIVER_FLAGS_CONFIG_H

/* The declaration exists only when both halves of the configured toolchain
 * reach this header. TITAN_DRIVER_CC_HONORED comes from CC itself, while
 * TITAN_DRIVER_CPP_BRANCH comes from TITAN_EXTRA_CPPFLAGS. */
#if TITAN_DRIVER_CC_HONORED == 1 && TITAN_DRIVER_CPP_BRANCH == 37
static inline int titan_driver_selected_branch(void)
{
    return TITAN_DRIVER_CPP_BRANCH;
}
#else
static inline int titan_driver_wrong_branch(void)
{
    return -1;
}
#endif

#endif
