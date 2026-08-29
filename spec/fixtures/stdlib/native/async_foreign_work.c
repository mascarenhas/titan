#include "async_foreign_work.h"

#include <errno.h>
#include <poll.h>
#include <unistd.h>

enum {
  TITAN_ASYNC_WORK_POLL_TIMEOUT_MS = 2000,
  TITAN_ASYNC_WORK_POLL_FAILED = -101,
  TITAN_ASYNC_WORK_POLL_TIMED_OUT = -102,
  TITAN_ASYNC_WORK_READ_FAILED = -103,
};

int titan_async_work_fixture_init(titan_async_work_fixture *fixture,
                                  int input) {
  int descriptors[2];
  fixture->release_read = -1;
  fixture->release_write = -1;
  fixture->input = input;
  fixture->result = 0;
  if (pipe(descriptors) != 0)
    return -errno;
  fixture->release_read = descriptors[0];
  fixture->release_write = descriptors[1];
  return 0;
}

void titan_async_work_fixture_destroy(titan_async_work_fixture *fixture) {
  if (fixture->release_read >= 0) {
    (void)close(fixture->release_read);
    fixture->release_read = -1;
  }
  if (fixture->release_write >= 0) {
    (void)close(fixture->release_write);
    fixture->release_write = -1;
  }
}

int titan_async_work_fixture_release_fd(
    const titan_async_work_fixture *fixture) {
  return fixture->release_write;
}

int titan_async_work_fixture_release(int descriptor) {
  const unsigned char release = 1;
  ssize_t written;
  do {
    written = write(descriptor, &release, sizeof(release));
  } while (written < 0 && errno == EINTR);
  return written == (ssize_t)sizeof(release) ? 0 : -errno;
}

void titan_async_work_fixture_block(void *argument) {
  titan_async_work_fixture *fixture = argument;
  struct pollfd waiter;
  unsigned char release;
  int status;
  ssize_t received;

  waiter.fd = fixture->release_read;
  waiter.events = POLLIN;
  waiter.revents = 0;
  do {
    status = poll(&waiter, 1, TITAN_ASYNC_WORK_POLL_TIMEOUT_MS);
  } while (status < 0 && errno == EINTR);
  if (status < 0) {
    fixture->result = TITAN_ASYNC_WORK_POLL_FAILED;
    return;
  }
  if (status == 0) {
    fixture->result = TITAN_ASYNC_WORK_POLL_TIMED_OUT;
    return;
  }

  do {
    received = read(fixture->release_read, &release, sizeof(release));
  } while (received < 0 && errno == EINTR);
  if (received != (ssize_t)sizeof(release)) {
    fixture->result = TITAN_ASYNC_WORK_READ_FAILED;
    return;
  }
  fixture->result = fixture->input + (int)release;
}

int titan_async_work_fixture_result(const titan_async_work_fixture *fixture) {
  return fixture->result;
}
