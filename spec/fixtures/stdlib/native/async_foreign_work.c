#include "async_foreign_work.h"

#include <errno.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <poll.h>
#include <unistd.h>
#endif

enum {
  TITAN_ASYNC_WORK_POLL_TIMEOUT_MS = 2000,
  TITAN_ASYNC_WORK_POLL_FAILED = -101,
  TITAN_ASYNC_WORK_POLL_TIMED_OUT = -102,
  TITAN_ASYNC_WORK_READ_FAILED = -103,
};

#ifdef _WIN32
int titan_async_work_fixture_init(titan_async_work_fixture *fixture,
                                  int input) {
  fixture->input = input;
  fixture->result = 0;
  /* The release event belongs to the owned fixture, never to a Titan worker.
   * Manual reset also preserves release-before-submission tests. */
  fixture->release_event = CreateEventW(NULL, TRUE, FALSE, NULL);
  return fixture->release_event != NULL ? 0 : -(int)GetLastError();
}

void titan_async_work_fixture_destroy(titan_async_work_fixture *fixture) {
  if (fixture->release_event != NULL) {
    CloseHandle((HANDLE)fixture->release_event);
    fixture->release_event = NULL;
  }
}

intptr_t titan_async_work_fixture_release_token(
    const titan_async_work_fixture *fixture) {
  return (intptr_t)fixture->release_event;
}

int titan_async_work_fixture_release(intptr_t token) {
  return SetEvent((HANDLE)token) ? 0 : -(int)GetLastError();
}

void titan_async_work_fixture_block(void *argument) {
  titan_async_work_fixture *fixture = argument;
  DWORD status = WaitForSingleObject((HANDLE)fixture->release_event,
                                     TITAN_ASYNC_WORK_POLL_TIMEOUT_MS);
  if (status == WAIT_OBJECT_0)
    fixture->result = fixture->input + 1;
  else if (status == WAIT_TIMEOUT)
    fixture->result = TITAN_ASYNC_WORK_POLL_TIMED_OUT;
  else
    fixture->result = TITAN_ASYNC_WORK_POLL_FAILED;
}
#else
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

intptr_t titan_async_work_fixture_release_token(
    const titan_async_work_fixture *fixture) {
  return fixture->release_write;
}

int titan_async_work_fixture_release(intptr_t token) {
  int descriptor = (int)token;
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
#endif

int titan_async_work_fixture_result(const titan_async_work_fixture *fixture) {
  return fixture->result;
}
