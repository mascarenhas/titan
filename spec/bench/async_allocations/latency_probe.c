#define _POSIX_C_SOURCE 200809L
#include <lua.h>
#include <lauxlib.h>
#include <stdlib.h>
#include <time.h>
#include <stdint.h>
typedef struct { double *last,*yield_values,*timer_values;size_t tasks,yield_capacity,yield_count,timer_count;double wall_start,cpu_start; } Probe;
static Probe p;
static double now(clockid_t which) { struct timespec t;clock_gettime(which,&t);return t.tv_sec+t.tv_nsec/1e9; }
static int start(lua_State *L) {
 lua_Integer tasks=luaL_checkinteger(L,1),iterations=luaL_checkinteger(L,2);
 luaL_argcheck(L,tasks>0&&tasks<=4096,1,"task count out of range");luaL_argcheck(L,iterations>0&&iterations<=1000000,2,"iteration count out of range");
 if((uint64_t)tasks*(uint64_t)iterations>4000000) return luaL_error(L,"sample budget exceeded");
 free(p.last);free(p.yield_values);free(p.timer_values);p=(Probe){0};p.tasks=tasks;p.yield_capacity=(size_t)tasks*(size_t)iterations;
 p.last=calloc((size_t)tasks+1,sizeof(double));p.yield_values=malloc(p.yield_capacity*sizeof(double));p.timer_values=malloc(1000000*sizeof(double));
 if(!p.last||!p.yield_values||!p.timer_values) return luaL_error(L,"cannot allocate latency samples");
 p.wall_start=now(CLOCK_MONOTONIC);p.cpu_start=now(CLOCK_PROCESS_CPUTIME_ID);return 0;
}
static int sample(lua_State *L) {
 lua_Integer owner=luaL_checkinteger(L,1);luaL_argcheck(L,owner>=0&&(size_t)owner<=p.tasks,1,"sample owner out of range");
 double current=now(CLOCK_MONOTONIC),previous=p.last[owner];p.last[owner]=current;if(previous==0) return 0;
 if(owner==0) { if(p.timer_count==1000000) return luaL_error(L,"timer sample budget exceeded");p.timer_values[p.timer_count++]=current-previous; }
 else { if(p.yield_count==p.yield_capacity) return luaL_error(L,"yield sample budget exceeded");p.yield_values[p.yield_count++]=current-previous; }
 return 0;
}
static int compare(const void*a,const void*b) { double x=*(const double*)a,y=*(const double*)b;return(x>y)-(x<y); }
static void number(lua_State*L,const char*key,double n) {lua_pushnumber(L,n);lua_setfield(L,-2,key);}
static void summary(lua_State*L,const char*key,double*values,size_t count) {
 lua_newtable(L);number(L,"samples",count);if(count) {qsort(values,count,sizeof(double),compare);double sum=0;for(size_t i=0;i<count;i++)sum+=values[i];number(L,"mean_seconds",sum/count);number(L,"p50_seconds",values[(count-1)/2]);number(L,"p95_seconds",values[(count-1)*95/100]);number(L,"p99_seconds",values[(count-1)*99/100]);number(L,"max_seconds",values[count-1]);}lua_setfield(L,-2,key);
}
static int finish(lua_State*L) {
 double wall=now(CLOCK_MONOTONIC)-p.wall_start,cpu=now(CLOCK_PROCESS_CPUTIME_ID)-p.cpu_start;
 lua_newtable(L);number(L,"wall_seconds",wall);number(L,"cpu_seconds",cpu);summary(L,"yield_latency",p.yield_values,p.yield_count);summary(L,"one_ms_timer_interarrival",p.timer_values,p.timer_count);
 free(p.last);free(p.yield_values);free(p.timer_values);p=(Probe){0};return 1;
}
int luaopen_latency_probe(lua_State*L) { const luaL_Reg api[]={{"start",start},{"sample",sample},{"finish",finish},{NULL,NULL}};luaL_newlib(L,api);return 1; }
