double titan_bench_wall(void);
double titan_bench_cpu(void);
long long titan_bench_count(const char *text);
int titan_bench_load_wire(const char *path);
int titan_bench_wire_byte(int index);
void titan_bench_sampler_start(void);
void titan_bench_sampler_stop(void);
void titan_bench_sampler_dump(const char *path);
void titan_bench_report(const char *workload, const char *operation,
                       long long count, long long size, long long checksum,
                       double wall, double cpu);
