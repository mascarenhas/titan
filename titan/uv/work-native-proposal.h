#ifndef TITAN_ISSUE194_WORK_NATIVE_PROPOSAL_H
#define TITAN_ISSUE194_WORK_NATIVE_PROPOSAL_H

#include <uv.h>

/* Private binding storage, naturally aligned; "packed" means embedded in one
 * final Titan owner, never a compiler packed-struct attribute. The first-member
 * guarantee lets the worker recover these C-only fields from uv_work_t*. It
 * must never inspect the Titan owner or request.data on its foreign thread. */
typedef void (*titan_issue194_work_function)(void *arg);

typedef struct titan_issue194_work_storage {
  uv_work_t request;
  titan_issue194_work_function worker;
  void *arg;
} titan_issue194_work_storage;

#endif
