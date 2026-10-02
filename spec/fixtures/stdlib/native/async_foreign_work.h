#ifndef TITAN_TEST_ASYNC_FOREIGN_WORK_H
#define TITAN_TEST_ASYNC_FOREIGN_WORK_H

#include <stdint.h>

typedef struct titan_async_work_fixture {
#ifdef _WIN32
  void *release_event;
#else
  int release_read;
  int release_write;
#endif
  int input;
  int result;
} titan_async_work_fixture;

int titan_async_work_fixture_init(titan_async_work_fixture *fixture,
                                  int input);
void titan_async_work_fixture_destroy(titan_async_work_fixture *fixture);
intptr_t titan_async_work_fixture_release_token(
    const titan_async_work_fixture *fixture);
int titan_async_work_fixture_release(intptr_t token);
void titan_async_work_fixture_block(void *argument);
int titan_async_work_fixture_result(const titan_async_work_fixture *fixture);

#endif
