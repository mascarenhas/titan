#ifndef TITAN_DRIVER_COLLIDING_FFI_H
#define TITAN_DRIVER_COLLIDING_FFI_H

/* This deliberately shadows Titan's built-in titan/ffi.h. The user's
 * quote-only path precedes fixed runtime includes in both the parser probe
 * and real compile. */
static inline int titan_driver_collision_value(void)
{
    return 5;
}

#endif
