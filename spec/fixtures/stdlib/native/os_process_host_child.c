#if defined(_WIN32)
#include "os_process_host_child_windows.h"
#else
#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>

static int write_all(FILE *stream, const void *data, size_t length) {
  const unsigned char *cursor = (const unsigned char *)data;
  while (length > 0) {
    size_t written = fwrite(cursor, 1, length, stream);
    if (written == 0)
      return 1;
    cursor += written;
    length -= written;
  }
  return 0;
}

static int write_field(const char *label, const char *value) {
  size_t length = strlen(value);
  if (printf("%s:%zu:", label, length) < 0 ||
      write_all(stdout, value, length) != 0 || fputc('\n', stdout) == EOF)
    return 1;
  return 0;
}

static int argv_env_cwd(int argc, char **argv) {
  char cwd[8192];
  const char *environment;
  int index;
  if (argc < 3)
    return 2;
  if (getcwd(cwd, sizeof(cwd)) == NULL)
    return 3;
  environment = getenv(argv[2]);
  if (environment == NULL)
    environment = "";
  if (write_field("cwd", cwd) != 0 ||
      write_field("env", environment) != 0 ||
      write_field("argv0", argv[0]) != 0)
    return 4;
  for (index = 3; index < argc; index++) {
    if (write_field("arg", argv[index]) != 0)
      return 5;
  }
  return fflush(stdout) == 0 ? 0 : 6;
}

static int echo_input(void) {
  unsigned char buffer[4096];
  size_t count;
  while ((count = fread(buffer, 1, sizeof(buffer), stdin)) > 0) {
    if (write_all(stdout, buffer, count) != 0)
      return 1;
  }
  return ferror(stdin) || fflush(stdout) != 0 ? 2 : 0;
}

static int dual_output(const char *count_text) {
  long count = strtol(count_text, NULL, 10);
  long index;
  for (index = 0; index < count; index++) {
    if (fputc('O', stdout) == EOF || fputc('E', stderr) == EOF)
      return 1;
  }
  return fflush(stdout) == 0 && fflush(stderr) == 0 ? 0 : 2;
}

int main(int argc, char **argv) {
  if (argc < 2)
    return 2;
  if (strcmp(argv[1], "argv-env-cwd") == 0)
    return argv_env_cwd(argc, argv);
  if (strcmp(argv[1], "environment") == 0) {
    int index;
    for (index = 2; index < argc; index++) {
      const char *value = getenv(argv[index]);
      if (value == NULL) {
        if (fputs("absent\n", stdout) == EOF)
          return 3;
      } else if (write_field("env", value) != 0) {
        return 4;
      }
    }
    return fflush(stdout) == 0 ? 0 : 5;
  }
  if (strcmp(argv[1], "echo") == 0)
    return echo_input();
  if (strcmp(argv[1], "echo-count") == 0 && (argc == 3 || argc == 4)) {
    long remaining = strtol(argv[2], NULL, 10);
    if (remaining < 0) return 2;
    while (remaining-- > 0) {
      int byte = fgetc(stdin);
      if (byte == EOF || fputc(byte, stdout) == EOF) return 1;
    }
    if (argc == 4 && fputs(argv[3], stdout) == EOF) return 1;
    return fflush(stdout) == 0 ? 0 : 2;
  }
  if (strcmp(argv[1], "output") == 0 && argc == 4) {
    return write_all(stdout, argv[2], strlen(argv[2])) || fflush(stdout) != 0 ||
           write_all(stderr, argv[3], strlen(argv[3])) || fflush(stderr) != 0;
  }
  if (strcmp(argv[1], "popen-interactive") == 0) {
    int byte;
    if (fputs("OUT:", stdout) == EOF) return 1;
    while ((byte = fgetc(stdin)) != '\n') {
      if (byte == EOF || fputc(byte, stdout) == EOF) return 1;
    }
    if (fflush(stdout) != 0 || fputs(":ERR", stderr) == EOF ||
        fflush(stderr) != 0) return 1;
    return 7;
  }
  if (strcmp(argv[1], "wait") == 0) {
    for (;;) pause();
  }
  if (strcmp(argv[1], "signal-parent") == 0 && argc == 3) {
    int signal_number;
    if (strcmp(argv[2], "usr1") == 0) signal_number = SIGUSR1;
    else if (strcmp(argv[2], "usr2") == 0) signal_number = SIGUSR2;
    else return 2;
    return kill(getppid(), signal_number) == 0 ? 0 : 1;
  }
  if (strcmp(argv[1], "dual") == 0 && argc == 3)
    return dual_output(argv[2]);
  if (strcmp(argv[1], "exit") == 0 && argc == 3)
    return (int)strtol(argv[2], NULL, 10);
  if (strcmp(argv[1], "ready-wait") == 0) {
    if (fputs("READY\n", stdout) == EOF || fflush(stdout) != 0)
      return 3;
    for (;;)
      pause();
  }
  return 2;
}

#endif
