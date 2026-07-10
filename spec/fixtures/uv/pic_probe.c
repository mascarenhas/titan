#include <uv.h>

/* Pull representative loop/handle objects out of libuv.a while producing a
 * shared DSO. A non-PIC archive fails this link on supported ELF/Mach-O hosts. */
int titan_uv_pic_probe(uv_loop_t *loop, uv_timer_t *timer)
{
    int status = uv_loop_init(loop);
    if (status < 0) return status;
    status = uv_timer_init(loop, timer);
    if (status < 0) return status;
    uv_close((uv_handle_t *)timer, 0);
    status = uv_run(loop, UV_RUN_DEFAULT);
    if (status != 0) return status;
    return uv_loop_close(loop);
}
