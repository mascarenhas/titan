#define _GNU_SOURCE
#include "probe.h"
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <ucontext.h>

#if !defined(__linux__) || !defined(__x86_64__)
#error "The protobuf IP sampler currently supports Linux x86_64 only"
#endif

#define SAMPLE_CAPACITY 262144
static _Atomic(uintptr_t) samples[SAMPLE_CAPACITY];
static volatile sig_atomic_t sample_count, sample_dropped, sampling;
static unsigned char *wire;
static int wire_length;

static void fail(const char *operation) { perror(operation); exit(2); }
static double seconds(clockid_t clock_id) {
    struct timespec now;
    if (clock_gettime(clock_id, &now) != 0) fail("clock_gettime");
    return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}
double titan_bench_wall(void) { return seconds(CLOCK_MONOTONIC); }
double titan_bench_cpu(void) { return seconds(CLOCK_PROCESS_CPUTIME_ID); }
long long titan_bench_count(const char *text) {
    char *end;
    errno = 0;
    long long result = strtoll(text, &end, 10);
    if (errno || *end || result < 0) {
        fputs("invalid benchmark count\n", stderr); exit(2);
    }
    return result;
}
int titan_bench_load_wire(const char *path) {
    FILE *stream = fopen(path, "rb");
    if (!stream) fail("open fixture");
    if (fseek(stream, 0, SEEK_END)) fail("seek fixture");
    long length = ftell(stream);
    if (length < 0 || length > 1048576) fail("fixture size");
    rewind(stream);
    wire = malloc((size_t)length + 1);
    if (!wire) fail("allocate fixture");
    wire_length = (int)length;
    if (fread(wire, 1, (size_t)length, stream) != (size_t)length) fail("read fixture");
    fclose(stream);
    return wire_length;
}
int titan_bench_wire_byte(int index) {
    if (index < 0 || index >= wire_length) abort();
    return wire[index];
}
static void sample_handler(int signal_number, siginfo_t *info, void *context) {
    (void)signal_number; (void)info;
    if (!sampling) return;
    sig_atomic_t index = sample_count;
    if (index < SAMPLE_CAPACITY) {
        ucontext_t *machine = context;
        atomic_store_explicit(&samples[index],
            (uintptr_t)machine->uc_mcontext.gregs[REG_RIP], memory_order_relaxed);
        sample_count = index + 1;
    } else sample_dropped = 1;
}
void titan_bench_sampler_start(void) {
    if (!atomic_is_lock_free(&samples[0])) {
        fputs("profiling requires lock-free instruction-pointer storage\n", stderr); exit(2);
    }
    struct itimerval existing;
    if (getitimer(ITIMER_PROF, &existing)) fail("getitimer");
    if (existing.it_value.tv_sec || existing.it_value.tv_usec) {
        fputs("refusing to replace an existing profiling timer\n", stderr); exit(2);
    }
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = sample_handler;
    action.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGPROF, &action, NULL)) fail("sigaction");
    sample_count = sample_dropped = 0;
    sampling = 1;
    struct itimerval timer = {{0, 1000}, {0, 1000}};
    if (setitimer(ITIMER_PROF, &timer, NULL)) fail("setitimer");
}
void titan_bench_sampler_stop(void) {
    sampling = 0;
    struct itimerval timer = {{0, 0}, {0, 0}};
    if (setitimer(ITIMER_PROF, &timer, NULL)) fail("stop profiling timer");
}
void titan_bench_sampler_dump(const char *path) {
    FILE *output = fopen(path, "w");
    if (!output) fail("open sample output");
    fprintf(output, "# samples=%d dropped=%d interval_usec=1000\n", (int)sample_count, (int)sample_dropped);
    for (sig_atomic_t index = 0; index < sample_count; index++) {
        Dl_info image;
        memset(&image, 0, sizeof(image));
        uintptr_t pc = atomic_load_explicit(&samples[index], memory_order_relaxed);
        dladdr((void *)pc, &image);
        fprintf(output, "%lx\t%lx\t%s\t%s\n", (unsigned long)pc,
                (unsigned long)image.dli_fbase, image.dli_fname ? image.dli_fname : "?",
                image.dli_sname ? image.dli_sname : "?");
    }
    if (fclose(output)) fail("close sample output");
}
void titan_bench_report(const char *workload, const char *operation,
                       long long count, long long size, long long checksum,
                       double wall, double cpu) {
    printf("{\"workload\":\"%s\",\"operation\":\"%s\",\"count\":%lld,"
           "\"wire_bytes\":%lld,\"checksum\":%lld,\"wall_seconds\":%.9f,"
           "\"cpu_seconds\":%.9f,\"samples\":%d,\"dropped\":%d}\n",
           workload, operation, count, size, checksum, wall, cpu,
           (int)sample_count, (int)sample_dropped);
}
