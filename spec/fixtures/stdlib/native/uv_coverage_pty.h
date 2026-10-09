#ifndef TITAN_TEST_UV_COVERAGE_PTY_H
#define TITAN_TEST_UV_COVERAGE_PTY_H

/* Only the POSIX test boundary lives here. Public libuv operations are called
 * from Titan, and no real user terminal or libuv layout is used. */
typedef struct titan_cov_pty {
  int master;
  int slave;
} titan_cov_pty;

typedef struct titan_cov_pty_child_result {
  int exit_status;
  int output_length;
  int timed_out;
} titan_cov_pty_child_result;

#if defined(_WIN32)
static int titan_cov_pty_available(void) { return 0; }
static int titan_cov_pty_open(titan_cov_pty *pty) {
  pty->master = pty->slave = -1;
  return -1;
}
static void titan_cov_pty_close(titan_cov_pty *pty) { (void)pty; }
static int titan_cov_pty_write(titan_cov_pty *pty, const char *bytes, int size) {
  (void)pty; (void)bytes; (void)size; return -1;
}
static int titan_cov_pty_read(titan_cov_pty *pty, char *bytes, int size) {
  (void)pty; (void)bytes; (void)size; return -1;
}
static int titan_cov_pty_canonical(titan_cov_pty *pty) { (void)pty; return -1; }
static int titan_cov_pty_echo(titan_cov_pty *pty) { (void)pty; return -1; }
static int titan_cov_pty_output_processing(titan_cov_pty *pty) { (void)pty; return -1; }
static int titan_cov_pty_is_terminal(int fd) { (void)fd; return 0; }
static int titan_cov_pty_run_child(const char *program, const char *resultpath,
                                 const char *input, int input_length,
                                 char *output, int output_capacity,
                                 titan_cov_pty_child_result *result) {
  (void)program; (void)resultpath; (void)input; (void)input_length;
  (void)output; (void)output_capacity;
  result->exit_status = -1; result->output_length = 0; result->timed_out = 0;
  return -1;
}
#else
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <poll.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static int titan_cov_pty_available(void) { return 1; }

static void titan_cov_pty_close(titan_cov_pty *pty) {
  if (pty->slave >= 0) close(pty->slave);
  if (pty->master >= 0) close(pty->master);
  pty->slave = pty->master = -1;
}

static int titan_cov_pty_open(titan_cov_pty *pty) {
  struct termios settings;
  struct winsize dimensions = {29, 97, 0, 0};
  char *name;
  int saved;
  pty->master = pty->slave = -1;
  pty->master = posix_openpt(O_RDWR | O_NOCTTY | O_NONBLOCK);
  if (pty->master < 0) goto failed;
  if (grantpt(pty->master) != 0 || unlockpt(pty->master) != 0) goto failed;
  name = ptsname(pty->master);
  if (name == NULL) goto failed;
  pty->slave = open(name, O_RDWR | O_NOCTTY | O_NONBLOCK);
  if (pty->slave < 0) goto failed;
  if (fcntl(pty->master, F_SETFD, FD_CLOEXEC) < 0 ||
      fcntl(pty->slave, F_SETFD, FD_CLOEXEC) < 0) goto failed;
  if (tcgetattr(pty->slave, &settings) != 0) goto failed;
  settings.c_lflag |= ICANON | ECHO | ISIG;
  settings.c_oflag |= OPOST | ONLCR;
  if (tcsetattr(pty->slave, TCSANOW, &settings) != 0 ||
      ioctl(pty->slave, TIOCSWINSZ, &dimensions) != 0) goto failed;
  return 0;
failed:
  saved = errno;
  titan_cov_pty_close(pty);
  return saved == 0 ? -1 : -saved;
}

static int titan_cov_pty_write(titan_cov_pty *pty, const char *bytes, int size) {
  ssize_t result;
  do { result = write(pty->master, bytes, (size_t)size); }
  while (result < 0 && errno == EINTR);
  return result < 0 ? -errno : (int)result;
}

static int titan_cov_pty_read(titan_cov_pty *pty, char *bytes, int size) {
  ssize_t result;
  do { result = read(pty->master, bytes, (size_t)size); }
  while (result < 0 && errno == EINTR);
  if (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
  return result < 0 ? -errno : (int)result;
}

static int titan_cov_pty_canonical(titan_cov_pty *pty) {
  struct termios settings;
  if (tcgetattr(pty->slave, &settings) != 0) return -errno;
  return (settings.c_lflag & ICANON) != 0;
}
static int titan_cov_pty_echo(titan_cov_pty *pty) {
  struct termios settings;
  if (tcgetattr(pty->slave, &settings) != 0) return -errno;
  return (settings.c_lflag & ECHO) != 0;
}
static int titan_cov_pty_output_processing(titan_cov_pty *pty) {
  struct termios settings;
  if (tcgetattr(pty->slave, &settings) != 0) return -errno;
  return (settings.c_oflag & OPOST) != 0;
}
static int titan_cov_pty_is_terminal(int fd) { return isatty(fd); }

/* The only work between fork and exec is async-signal-safe descriptor setup,
 * execv and _exit. The parent owns/reaps this exact PID on every return path.
 * Each call uses its own noecho terminal, never the process's real terminal. */
static int titan_cov_pty_run_child(const char *program, const char *resultpath,
                                 const char *input, int input_length,
                                 char *output, int output_capacity,
                                 titan_cov_pty_child_result *result) {
  titan_cov_pty pty;
  struct termios settings;
  struct timespec started, now;
  struct pollfd ready;
  char *arguments[3];
  pid_t child, observed;
  int status = 0, error = 0, reaped = 0, sent = 0, drained = 0, attempt;
  result->exit_status = -1; result->output_length = 0; result->timed_out = 0;
  if (input_length < 0 || output_capacity < 1) return -EINVAL;
  output[0] = 0;
  error = titan_cov_pty_open(&pty);
  if (error != 0) return error;
  if (tcgetattr(pty.slave, &settings) != 0) { error = -errno; goto close_pair; }
  settings.c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
  settings.c_oflag &= ~OPOST;
  settings.c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
  settings.c_cflag = (settings.c_cflag & ~(CSIZE | PARENB)) | CS8;
  settings.c_cc[VMIN] = 1; settings.c_cc[VTIME] = 0;
  if (tcsetattr(pty.slave, TCSANOW, &settings) != 0 ||
      clock_gettime(CLOCK_MONOTONIC, &started) != 0) { error = -errno; goto close_pair; }
  arguments[0] = (char *)program; arguments[1] = (char *)resultpath; arguments[2] = NULL;
  child = fork();
  if (child < 0) { error = -errno; goto close_pair; }
  if (child == 0) {
    if (dup2(pty.slave, 0) < 0 || dup2(pty.slave, 1) < 0 || dup2(pty.slave, 2) < 0) _exit(126);
    if (pty.master > 2) close(pty.master);
    if (pty.slave > 2) close(pty.slave);
    execv(program, arguments);
    _exit(127);
  }
  close(pty.slave); pty.slave = -1;
  ready.fd = pty.master;
  while (!reaped || !drained) {
    ssize_t amount;
    ready.events = POLLIN | (sent < input_length ? POLLOUT : 0);
    ready.revents = 0;
    if (poll(&ready, 1, 10) < 0 && errno != EINTR) { error = -errno; break; }
    if (sent < input_length && (ready.revents & POLLOUT)) {
      amount = write(pty.master, input + sent, (size_t)(input_length - sent));
      if (amount > 0) sent += (int)amount;
      else if (amount < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
        error = -errno; break;
      }
    }
    /* Even after waitpid reports exit, drain every byte still in the PTY. */
    if (ready.revents & (POLLIN | POLLHUP | POLLERR)) {
      char bytes[256];
      do {
        amount = read(pty.master, bytes, sizeof(bytes));
        if (amount > 0) {
          int index;
          if (amount > output_capacity - 1 - result->output_length) { error = -EOVERFLOW; break; }
          for (index = 0; index < amount; index++) output[result->output_length++] = bytes[index];
          output[result->output_length] = 0;
        }
      } while (amount > 0 || (amount < 0 && errno == EINTR));
      if (error != 0) break;
      if (amount == 0 || (amount < 0 && errno == EIO)) drained = 1;
      else if (amount < 0 && errno != EAGAIN && errno != EWOULDBLOCK) { error = -errno; break; }
    }
    if (!reaped) {
      do { observed = waitpid(child, &status, WNOHANG); } while (observed < 0 && errno == EINTR);
      if (observed == child) reaped = 1;
      else if (observed < 0) { error = -errno; break; }
    }
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) { error = -errno; break; }
    if (now.tv_sec - started.tv_sec > 5 ||
        (now.tv_sec - started.tv_sec == 5 && now.tv_nsec >= started.tv_nsec)) {
      result->timed_out = 1; error = -ETIMEDOUT; break;
    }
  }
  if (!reaped) {
    kill(child, SIGTERM);
    for (attempt = 0; attempt < 20; attempt++) {
      do { observed = waitpid(child, &status, WNOHANG); } while (observed < 0 && errno == EINTR);
      if (observed == child) { reaped = 1; break; }
      if (observed < 0) break;
      poll(NULL, 0, 10);
    }
    if (!reaped) {
      kill(child, SIGKILL);
      do { observed = waitpid(child, &status, 0); } while (observed < 0 && errno == EINTR);
      if (observed == child) reaped = 1;
    }
  }
  if (reaped) result->exit_status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
close_pair:
  titan_cov_pty_close(&pty);
  return error;
}
#endif
#endif
