#ifndef TITAN_MINI_DRIVER_H
#define TITAN_MINI_DRIVER_H
#include <titan/browser.h>

/* Test-only controls for the mini-driver fixture (mini_driver.c). */
void mini_driver_publish_controls(void);
void mini_driver_poke(void);
int mini_driver_switch(uint32_t state);
TValue mini_driver_new_child(lua_State *L);
int mini_driver_overflow(void);
#endif
