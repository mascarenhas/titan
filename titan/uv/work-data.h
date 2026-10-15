#ifndef TITAN_UV_WORK_DATA_H
#define TITAN_UV_WORK_DATA_H

/* Native callback data embedded in the same stable Titan owner as uv_work_t.
 * request.data points here from submission until terminal completion. Only
 * worker and arg are read by the worker; owner is used on the loop thread.
 * Titan's FFI imports C aggregates but does not declare new struct layouts. */
typedef struct titan_uv_work_data {
  void (*worker)(void *arg);
  void *arg;
  void *owner;
} titan_uv_work_data;

#endif
