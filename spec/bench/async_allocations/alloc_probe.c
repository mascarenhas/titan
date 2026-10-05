#define _POSIX_C_SOURCE 200809L
#include <lua.h>
#include <lauxlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <sys/resource.h>

typedef struct {
  uint64_t allocations, resizes, frees, attempted_bytes, requested_bytes;
  uint64_t growth_bytes, failed_requests, tags[16];
  int64_t live, peak;
} Counters;
typedef struct {
  lua_Alloc allocator;
  void *allocator_ud;
  Counters current, body, teardown, postgc;
  int active, hooked, body_stopped, gc_stopped;
  int64_t initial_live;
  double wall_start, cpu_start, body_wall, body_cpu, total_wall, total_cpu;
  double gc_wall, gc_cpu;
  long peak_rss_kib;
} Probe;
/* One process owns one measured Lua state; static storage also survives Lua close after an error. */
static Probe singleton;
static double time_seconds(clockid_t which) {
  struct timespec t; if (clock_gettime(which, &t)) return 0;
  return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}
static int64_t heap_bytes(lua_State *L) {
  return (int64_t)lua_gc(L, LUA_GCCOUNT) * 1024 + lua_gc(L, LUA_GCCOUNTB);
}
static void *meter(void *ud, void *ptr, size_t osize, size_t nsize) {
  Probe *p=ud; Counters *c=&p->current;
  if (nsize) c->attempted_bytes += nsize;
  void *result=p->allocator(p->allocator_ud,ptr,osize,nsize);
  if (!nsize) {
    if (ptr) { c->frees++; c->live -= (int64_t)osize; }
  } else if (result) {
    c->requested_bytes += nsize;
    if (ptr) {
      c->resizes++; c->live += (int64_t)nsize-(int64_t)osize;
      if (nsize > osize) c->growth_bytes += nsize-osize;
    } else {
      c->allocations++; c->live += (int64_t)nsize; c->growth_bytes += nsize;
      if (osize < 16) c->tags[osize]++;
    }
    if (c->live > c->peak) c->peak=c->live;
  } else c->failed_requests++;
  return result;
}
static Probe *probe(lua_State *L) { return lua_touserdata(L,lua_upvalueindex(1)); }
static int start(lua_State *L) {
  Probe *p=probe(L); if(p->active) return luaL_error(L,"measurement already active");
  int hooked=lua_toboolean(L,1), stopped=lua_toboolean(L,2);
  lua_gc(L,LUA_GCRESTART); lua_gc(L,LUA_GCCOLLECT);
  memset(p,0,sizeof(*p)); p->hooked=hooked; p->gc_stopped=stopped;
  if(stopped) lua_gc(L,LUA_GCSTOP);
  p->initial_live=heap_bytes(L); p->current.live=p->current.peak=p->initial_live;
  p->allocator=lua_getallocf(L,&p->allocator_ud); p->active=1;
  p->cpu_start=time_seconds(CLOCK_PROCESS_CPUTIME_ID); p->wall_start=time_seconds(CLOCK_MONOTONIC);
  if(hooked) lua_setallocf(L,meter,p);
  return 0;
}
static int stop_body(lua_State *L) {
  Probe *p=probe(L); if(!p->active||p->body_stopped) return luaL_error(L,"invalid body boundary");
  p->body_wall=time_seconds(CLOCK_MONOTONIC)-p->wall_start;
  p->body_cpu=time_seconds(CLOCK_PROCESS_CPUTIME_ID)-p->cpu_start;
  if(!p->hooked) p->current.live=heap_bytes(L);
  p->body=p->current; p->body_stopped=1; return 0;
}
static void integer(lua_State *L,const char *name,lua_Integer n) { lua_pushinteger(L,n);lua_setfield(L,-2,name); }
static void number(lua_State *L,const char *name,double n) { lua_pushnumber(L,n);lua_setfield(L,-2,name); }
static void counters(lua_State *L,const char *name,const Counters *c) {
  lua_newtable(L);
  integer(L,"allocations",c->allocations); integer(L,"resizes",c->resizes); integer(L,"frees",c->frees);
  integer(L,"attempted_bytes",c->attempted_bytes); integer(L,"requested_bytes",c->requested_bytes);
  integer(L,"growth_bytes",c->growth_bytes); integer(L,"failed_requests",c->failed_requests);
  integer(L,"live_bytes",c->live); integer(L,"peak_live_bytes",c->peak);
  integer(L,"userdata",c->tags[LUA_TUSERDATA]); integer(L,"functions",c->tags[LUA_TFUNCTION]);
  integer(L,"tables",c->tags[LUA_TTABLE]); integer(L,"strings",c->tags[LUA_TSTRING]);
  lua_setfield(L,-2,name);
}
static int finish(lua_State *L) {
  Probe *p=probe(L); if(!p->active||!p->body_stopped) return luaL_error(L,"unfinished body");
  p->total_wall=time_seconds(CLOCK_MONOTONIC)-p->wall_start;
  p->total_cpu=time_seconds(CLOCK_PROCESS_CPUTIME_ID)-p->cpu_start;
  if(!p->hooked) p->current.live=heap_bytes(L);
  p->teardown=p->current;
  double wall=time_seconds(CLOCK_MONOTONIC),cpu=time_seconds(CLOCK_PROCESS_CPUTIME_ID);
  lua_gc(L,LUA_GCRESTART); lua_gc(L,LUA_GCCOLLECT);
  p->gc_wall=time_seconds(CLOCK_MONOTONIC)-wall;
  p->gc_cpu=time_seconds(CLOCK_PROCESS_CPUTIME_ID)-cpu;
  if(!p->hooked) p->current.live=heap_bytes(L);
  p->postgc=p->current;
  int64_t actual=heap_bytes(L);
  if(p->hooked) lua_setallocf(L,p->allocator,p->allocator_ud);
  p->active=0;
  struct rusage use; memset(&use,0,sizeof(use)); getrusage(RUSAGE_SELF,&use); p->peak_rss_kib=use.ru_maxrss;
  lua_newtable(L);
  integer(L,"instrumented",p->hooked); integer(L,"gc_stopped_during_body",p->gc_stopped);
  integer(L,"initial_live_bytes",p->initial_live); integer(L,"postgc_actual_live_bytes",actual);
  integer(L,"postgc_ledger_error_bytes",p->postgc.live-actual); integer(L,"process_peak_rss_kib",p->peak_rss_kib);
  number(L,"body_wall_seconds",p->body_wall); number(L,"body_cpu_seconds",p->body_cpu);
  number(L,"body_and_teardown_wall_seconds",p->total_wall); number(L,"body_and_teardown_cpu_seconds",p->total_cpu);
  number(L,"forced_postgc_wall_seconds",p->gc_wall); number(L,"forced_postgc_cpu_seconds",p->gc_cpu);
  counters(L,"body",&p->body); counters(L,"teardown",&p->teardown); counters(L,"postgc",&p->postgc);
  return 1;
}
int luaopen_alloc_probe(lua_State *L) {
  Probe *p=&singleton; if(p->active) return luaL_error(L,"probe already open and active"); memset(p,0,sizeof(*p)); lua_pushlightuserdata(L,p); lua_newtable(L);
  const luaL_Reg api[]={{"start",start},{"stop_body",stop_body},{"finish",finish},{NULL,NULL}};
  lua_pushvalue(L,-2);luaL_setfuncs(L,api,1);return 1;
}
