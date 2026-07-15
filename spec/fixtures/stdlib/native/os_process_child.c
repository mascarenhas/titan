#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <uv.h>

#define CHILD_BUFFER_BYTES 16384u
#define CHILD_TEXT_BYTES 8192u

static const unsigned char stdout_pattern[] = "OUT\0pattern-1234";
static const unsigned char stderr_pattern[] = "ERR\0pattern-5678";

static int write_all(FILE *stream, const void *data, size_t length) {
  const unsigned char *cursor = (const unsigned char *)data;
  while (length > 0) {
    size_t written = fwrite(cursor, 1, length, stream);
    if (written == 0)
      return ferror(stream) ? 1 : 2;
    cursor += written;
    length -= written;
  }
  return 0;
}

static int write_field(const char *label, const char *value, size_t length) {
  if (printf("%s:%zu:", label, length) < 0)
    return 1;
  if (write_all(stdout, value, length) != 0)
    return 1;
  return fputc('\n', stdout) == EOF;
}

static int parse_size(const char *text, size_t *result) {
  char *end;
  unsigned long long value;
  errno = 0;
  value = strtoull(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0' ||
      value > (unsigned long long)SIZE_MAX)
    return 1;
  *result = (size_t)value;
  return 0;
}

static int write_pattern(FILE *stream, size_t length,
                         const unsigned char *pattern,
                         size_t pattern_length) {
  unsigned char buffer[CHILD_BUFFER_BYTES];
  size_t offset;
  size_t chunk;
  size_t index;
  for (index = 0; index < sizeof(buffer); index++)
    buffer[index] = pattern[index % pattern_length];
  for (offset = 0; offset < length; offset += chunk) {
    chunk = length - offset;
    if (chunk > sizeof(buffer))
      chunk = sizeof(buffer);
    if (write_all(stream, buffer, chunk) != 0)
      return 1;
  }
  return fflush(stream) != 0;
}

static int copy_stdin(FILE *destination, size_t *total) {
  unsigned char buffer[CHILD_BUFFER_BYTES];
  size_t count;
  *total = 0;
  while ((count = fread(buffer, 1, sizeof(buffer), stdin)) > 0) {
    if (destination != NULL && write_all(destination, buffer, count) != 0)
      return 1;
    *total += count;
  }
  if (ferror(stdin))
    return 1;
  return destination != NULL && fflush(destination) != 0;
}

static int argv_env_cwd(int argc, char **argv) {
  char cwd[CHILD_TEXT_BYTES];
  char environment[CHILD_TEXT_BYTES];
  size_t cwd_size = sizeof(cwd);
  size_t environment_size = sizeof(environment);
  int status;
  int index;
  if (argc < 3)
    return 64;
  status = uv_cwd(cwd, &cwd_size);
  if (status < 0)
    return 65;
  status = uv_os_getenv(argv[2], environment, &environment_size);
  if (status == UV_ENOENT) {
    environment[0] = '\0';
    environment_size = 0;
  } else if (status < 0) {
    return 66;
  }
  if (write_field("cwd", cwd, cwd_size) != 0 ||
      write_field("env", environment, environment_size) != 0 ||
      write_field("argv0", argv[0], strlen(argv[0])) != 0)
    return 67;
  for (index = 3; index < argc; index++)
    if (write_field("arg", argv[index], strlen(argv[index])) != 0)
      return 68;
  return fflush(stdout) != 0;
}

static int echo_stdin(void) {
  size_t total;
  return copy_stdin(stdout, &total);
}

static int delayed_echo_stdin(void) {
  /* Keep a write larger than the platform pipe capacity physically pending. */
  uv_sleep(1000u);
  return echo_stdin();
}

static int wait_eof(void) {
  size_t total;
  if (copy_stdin(NULL, &total) != 0)
    return 1;
  if (printf("EOF:%zu\n", total) < 0)
    return 1;
  return fflush(stdout) != 0;
}

static int delayed_output(void) {
  uv_sleep(200u);
  if (fwrite("LATE\0OUTPUT", 1, 11, stdout) != 11)
    return 1;
  return fflush(stdout) != 0;
}

static int dual_output(size_t length, int read_input) {
  size_t total;
  if (write_pattern(stdout, length, stdout_pattern,
                    sizeof(stdout_pattern) - 1u) != 0 ||
      write_pattern(stderr, length, stderr_pattern,
                    sizeof(stderr_pattern) - 1u) != 0)
    return 1;
  if (!read_input)
    return 0;
  if (copy_stdin(NULL, &total) != 0)
    return 1;
  if (printf("\nINPUT:%zu\n", total) < 0)
    return 1;
  return fflush(stdout) != 0;
}

static void ignore_signal(uv_signal_t *handle, int signum) {
  (void)handle;
  (void)signum;
}

static int ignore_term(const char *pid_path) {
  uv_loop_t loop;
  uv_signal_t signal_handle;
  FILE *pid_file;
  int status;
  status = uv_loop_init(&loop);
  if (status < 0)
    return 1;
  status = uv_signal_init(&loop, &signal_handle);
  if (status < 0)
    return 2;
  status = uv_signal_start(&signal_handle, ignore_signal, SIGTERM);
  if (status < 0)
    return 3;
  if (pid_path != NULL) {
    pid_file = fopen(pid_path, "wb");
    if (pid_file == NULL)
      return 4;
    if (fprintf(pid_file, "%lld\n", (long long)uv_os_getpid()) < 0 ||
        fclose(pid_file) != 0)
      return 4;
  }
  if (fputs("READY\n", stdout) == EOF || fflush(stdout) != 0)
    return 5;
  uv_run(&loop, UV_RUN_DEFAULT);
  return 6;
}

static int ready_wait(void) {
  if (fputs("READY\n", stdout) == EOF || fflush(stdout) != 0)
    return 1;
  for (;;)
    uv_sleep(1000u);
}

static int self_unknown_signal(void) {
  int status;
  if (fflush(stdout) != 0 || fflush(stderr) != 0)
    return 1;
  status = uv_kill(uv_os_getpid(), SIGALRM);
  if (status < 0)
    return 2;
  uv_sleep(1000u);
  return 3;
}

static int close_stdin_early(void) {
  uv_fs_t request;
  int status = uv_fs_close(NULL, &request, 0, NULL);
  uv_fs_req_cleanup(&request);
  if (status < 0)
    return 1;
  if (fputs("READY\n", stdout) == EOF || fflush(stdout) != 0)
    return 2;
  uv_sleep(500u);
  return 0;
}

static int exec_default_sigpipe(int argc, char **argv) {
  struct sigaction action;
  if (argc < 3)
    return 64;
  memset(&action, 0, sizeof(action));
  action.sa_handler = SIG_DFL;
  if (sigemptyset(&action.sa_mask) != 0 ||
      sigaction(SIGPIPE, &action, NULL) != 0)
    return 70;
  execvp(argv[2], &argv[2]);
  return 71;
}

int main(int argc, char **argv) {
  size_t length;
  int code;
  setvbuf(stdout, NULL, _IONBF, 0);
  setvbuf(stderr, NULL, _IONBF, 0);
  if (argc < 2)
    return 64;
  if (strcmp(argv[1], "argv-env-cwd") == 0)
    return argv_env_cwd(argc, argv);
  if (strcmp(argv[1], "echo") == 0)
    return echo_stdin();
  if (strcmp(argv[1], "delay-read-echo") == 0)
    return delayed_echo_stdin();
  if (strcmp(argv[1], "wait-eof") == 0)
    return wait_eof();
  if (strcmp(argv[1], "delay-read-eof") == 0) {
    uv_sleep(200u);
    return wait_eof();
  }
  if (strcmp(argv[1], "delayed-output") == 0)
    return delayed_output();
  if (strcmp(argv[1], "dual") == 0 || strcmp(argv[1], "duplex") == 0) {
    if (argc != 3 || parse_size(argv[2], &length) != 0)
      return 65;
    return dual_output(length, strcmp(argv[1], "duplex") == 0);
  }
  if (strcmp(argv[1], "exit") == 0) {
    if (argc != 3)
      return 65;
    code = atoi(argv[2]);
    return code < 0 || code > 255 ? 66 : code;
  }
  if (strcmp(argv[1], "ready-wait") == 0)
    return ready_wait();
  if (strcmp(argv[1], "ignore-term") == 0)
    return argc == 2 ? ignore_term(NULL) :
           argc == 3 ? ignore_term(argv[2]) : 65;
  if (strcmp(argv[1], "self-unknown-signal") == 0)
    return self_unknown_signal();
  if (strcmp(argv[1], "early-output-exit") == 0) {
    if (fwrite("early\0stdout", 1, 12, stdout) != 12 ||
        fwrite("early\0stderr", 1, 12, stderr) != 12)
      return 1;
    return 23;
  }
  if (strcmp(argv[1], "close-stdin-early") == 0)
    return close_stdin_early();
  if (strcmp(argv[1], "exec-default-sigpipe") == 0)
    return exec_default_sigpipe(argc, argv);
  return 69;
}
