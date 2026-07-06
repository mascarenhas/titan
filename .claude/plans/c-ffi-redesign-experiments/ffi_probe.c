#include <stddef.h>
#include <stdio.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lobject.h"
#include "lstate.h"
#include "lstring.h"

struct ProbeUnion {
    int int_value;
    double double_value;
};

struct ProbePoint {
    int x;
    double y;
    struct ProbeUnion u;
};

static const char probe_point_tag_storage = 0;

static Udata *new_owned_points(lua_State *L, size_t count) {
    Udata *box;
    struct ProbePoint *points;

    lua_checkstack(L, 1);
    box = luaS_newudata(L, sizeof(struct ProbePoint) * count, 2);
    setuvalue(L, s2v(L->top.p), box);
    L->top.p++;

    setpvalue(&box->uv[0].uv, cast_voidp(&probe_point_tag_storage));
    setivalue(&box->uv[1].uv, cast(lua_Integer, count));

    points = (struct ProbePoint *)getudatamem(box);
    points[0].x = 7;
    points[0].y = 3.5;
    points[0].u.int_value = 11;
    points[1].x = 13;
    points[1].y = 8.25;
    points[1].u.int_value = 17;
    return box;
}

int main(void) {
    lua_State *L = luaL_newstate();

    if (L == NULL) {
        fprintf(stderr, "failed to create Lua state\n");
        return 1;
    }
    luaL_openlibs(L);

    printf("layout:size=%zu x=%zu y=%zu u=%zu union.double=%zu\n",
           sizeof(struct ProbePoint),
           offsetof(struct ProbePoint, x),
           offsetof(struct ProbePoint, y),
           offsetof(struct ProbePoint, u),
           offsetof(struct ProbeUnion, double_value));

    Udata *owned = new_owned_points(L, 2);
    struct ProbePoint *points = (struct ProbePoint *)getudatamem(owned);
    printf("owned-inline:x0=%d y0=%.1f u0=%d x1=%d len_count=%zu uv_count=%lld tagged=%s anchored=%s\n",
           points[0].x,
           points[0].y,
           points[0].u.int_value,
           points[1].x,
           owned->len / sizeof(struct ProbePoint),
           (long long)ivalue(&owned->uv[1].uv),
           pvalue(&owned->uv[0].uv) == cast_voidp(&probe_point_tag_storage) ? "yes" : "no",
           uvalue(s2v(L->top.p - 1)) == owned ? "yes" : "no");
    lua_pop(L, 1);
    lua_gc(L, LUA_GCCOLLECT, 0);
    printf("owned-after-gc:no-finalizer-needed\n");

    lua_close(L);
    return 0;
}
