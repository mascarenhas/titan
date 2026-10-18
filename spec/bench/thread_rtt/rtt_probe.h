#ifndef TITAN_BENCH_RTT_PROBE_H
#define TITAN_BENCH_RTT_PROBE_H

#include <stdint.h>

enum {
  RTT_OP_NONE = 0,
  RTT_OP_SEND = 1,
  RTT_OP_RECV = 2,
  RTT_OP_JOIN = 3,
  RTT_OP_CLEANUP_JOIN = 4
};

enum {
  RTT_OUTCOME_OK = 0,
  RTT_OUTCOME_CLOSED = 1,
  RTT_OUTCOME_CANCELLED = 2
};

int64_t rtt_probe_now_ns(void);

int rtt_probe_init(int64_t sample_capacity, int64_t trace_capacity,
                   int instrumented);
void rtt_probe_set_wire_bytes(int64_t payload_wire_bytes_per_op);

void rtt_probe_mark_cold_done(int64_t cold_ns);
void rtt_probe_mark_warmup_done(int64_t warmup_ns, int64_t warmup_ops);
void rtt_probe_mark_setup_start(int64_t lua_bytes);
void rtt_probe_start_body(int64_t lua_bytes);
void rtt_probe_stop_body(int64_t lua_bytes);
void rtt_probe_mark_workers_retired(int64_t lua_bytes);
void rtt_probe_mark_post_gc1(int64_t gc1_ns, int64_t lua_bytes);
void rtt_probe_mark_post_gc2(int64_t gc2_ns, int64_t lua_bytes);

int rtt_probe_op_begin(int op_kind, int endpoint_retains);
void rtt_probe_op_end(int slot_id, int outcome);

/* Private source probes; emitted only into the harness-owned provider copy. */
int64_t rtt_probe_attempt_begin(int kind);
void rtt_probe_attempt_end(int kind, void *waiter, int result, int64_t started);
void rtt_probe_cancelled_wait(void);
void rtt_probe_fast_success(void);
void rtt_probe_join_check(int done);
void rtt_probe_waiter_bind(void *waiter);
void rtt_probe_waiter_notify(void *waiter);
void rtt_probe_cleanup_prepare(void *waiter);
void rtt_probe_waiter_complete(void *waiter, int normal);
void rtt_probe_waiter_signal_result(void *waiter, int result);
void rtt_probe_resource(int kind, int delta);
int rtt_probe_quiesce(void);

void rtt_probe_record_sample(int64_t elapsed_ns);

void rtt_probe_trace_client_send_start(int64_t req_id, int64_t t_ns);
void rtt_probe_trace_client_send_done(int64_t req_id, int64_t t_ns);
void rtt_probe_trace_worker_recv(int64_t req_id);
void rtt_probe_trace_worker_reply_start(int64_t req_id);
void rtt_probe_trace_worker_reply_done(int64_t req_id);
void rtt_probe_trace_client_reply_done(int64_t req_id, int64_t t_ns);


int rtt_probe_finish_json(const char *case_name, const char *category,
                          const char *protocol, int64_t operations,
                          int64_t in_flight, int64_t producers,
                          int64_t consumers, int64_t capacity,
                          int64_t checksum, const char *raw_samples_path);
void rtt_probe_cleanup(void);

#endif
