#ifndef TITAN_TEST_ASYNC_FOREIGN_WORK_H
#define TITAN_TEST_ASYNC_FOREIGN_WORK_H

typedef struct titan_async_work_fixture {
  int release_read;
  int release_write;
  int input;
  int result;
} titan_async_work_fixture;

int titan_async_work_fixture_init(titan_async_work_fixture *fixture,
                                  int input);
void titan_async_work_fixture_destroy(titan_async_work_fixture *fixture);
int titan_async_work_fixture_release_fd(
    const titan_async_work_fixture *fixture);
int titan_async_work_fixture_release(int descriptor);
void titan_async_work_fixture_block(void *argument);
int titan_async_work_fixture_result(const titan_async_work_fixture *fixture);

#endif
