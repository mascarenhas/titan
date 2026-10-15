#ifndef TITAN_UV_PLATFORM_CONSTANTS_H
#define TITAN_UV_PLATFORM_CONSTANTS_H
#include <uv.h>
#include <signal.h>
#include <sys/stat.h>
#include <string.h>
#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#endif
static inline int titan_uv_platform_constant(const char* name, int* out) {
#ifdef AF_UNIX
  if (strcmp(name, "AF_UNIX") == 0) { *out = (int) AF_UNIX; return 1; }
#endif
#ifdef S_IRUSR
  if (strcmp(name, "S_IRUSR") == 0) { *out = (int) S_IRUSR; return 1; }
#endif
#ifdef S_IWUSR
  if (strcmp(name, "S_IWUSR") == 0) { *out = (int) S_IWUSR; return 1; }
#endif
#ifdef S_IXUSR
  if (strcmp(name, "S_IXUSR") == 0) { *out = (int) S_IXUSR; return 1; }
#endif
#ifdef S_IRGRP
  if (strcmp(name, "S_IRGRP") == 0) { *out = (int) S_IRGRP; return 1; }
#endif
#ifdef S_IWGRP
  if (strcmp(name, "S_IWGRP") == 0) { *out = (int) S_IWGRP; return 1; }
#endif
#ifdef S_IXGRP
  if (strcmp(name, "S_IXGRP") == 0) { *out = (int) S_IXGRP; return 1; }
#endif
#ifdef S_IROTH
  if (strcmp(name, "S_IROTH") == 0) { *out = (int) S_IROTH; return 1; }
#endif
#ifdef S_IWOTH
  if (strcmp(name, "S_IWOTH") == 0) { *out = (int) S_IWOTH; return 1; }
#endif
#ifdef S_IXOTH
  if (strcmp(name, "S_IXOTH") == 0) { *out = (int) S_IXOTH; return 1; }
#endif
#ifdef S_IFMT
  if (strcmp(name, "S_IFMT") == 0) { *out = (int) S_IFMT; return 1; }
#endif
#ifdef S_IFREG
  if (strcmp(name, "S_IFREG") == 0) { *out = (int) S_IFREG; return 1; }
#endif
#ifdef S_IFDIR
  if (strcmp(name, "S_IFDIR") == 0) { *out = (int) S_IFDIR; return 1; }
#endif
#ifdef S_IFLNK
  if (strcmp(name, "S_IFLNK") == 0) { *out = (int) S_IFLNK; return 1; }
#endif
#ifdef S_IFSOCK
  if (strcmp(name, "S_IFSOCK") == 0) { *out = (int) S_IFSOCK; return 1; }
#endif
#ifdef S_IFIFO
  if (strcmp(name, "S_IFIFO") == 0) { *out = (int) S_IFIFO; return 1; }
#endif
#ifdef S_IFCHR
  if (strcmp(name, "S_IFCHR") == 0) { *out = (int) S_IFCHR; return 1; }
#endif
#ifdef S_IFBLK
  if (strcmp(name, "S_IFBLK") == 0) { *out = (int) S_IFBLK; return 1; }
#endif
#ifdef F_OK
  if (strcmp(name, "F_OK") == 0) { *out = (int) F_OK; return 1; }
#endif
#ifdef R_OK
  if (strcmp(name, "R_OK") == 0) { *out = (int) R_OK; return 1; }
#endif
#ifdef W_OK
  if (strcmp(name, "W_OK") == 0) { *out = (int) W_OK; return 1; }
#endif
#ifdef X_OK
  if (strcmp(name, "X_OK") == 0) { *out = (int) X_OK; return 1; }
#endif
#ifdef SIGABRT
  if (strcmp(name, "SIGABRT") == 0) { *out = (int) SIGABRT; return 1; }
#endif
#ifdef SIGALRM
  if (strcmp(name, "SIGALRM") == 0) { *out = (int) SIGALRM; return 1; }
#endif
#ifdef SIGBREAK
  if (strcmp(name, "SIGBREAK") == 0) { *out = (int) SIGBREAK; return 1; }
#endif
#ifdef SIGBUS
  if (strcmp(name, "SIGBUS") == 0) { *out = (int) SIGBUS; return 1; }
#endif
#ifdef SIGCHLD
  if (strcmp(name, "SIGCHLD") == 0) { *out = (int) SIGCHLD; return 1; }
#endif
#ifdef SIGCONT
  if (strcmp(name, "SIGCONT") == 0) { *out = (int) SIGCONT; return 1; }
#endif
#ifdef SIGFPE
  if (strcmp(name, "SIGFPE") == 0) { *out = (int) SIGFPE; return 1; }
#endif
#ifdef SIGHUP
  if (strcmp(name, "SIGHUP") == 0) { *out = (int) SIGHUP; return 1; }
#endif
#ifdef SIGILL
  if (strcmp(name, "SIGILL") == 0) { *out = (int) SIGILL; return 1; }
#endif
#ifdef SIGINT
  if (strcmp(name, "SIGINT") == 0) { *out = (int) SIGINT; return 1; }
#endif
#ifdef SIGIO
  if (strcmp(name, "SIGIO") == 0) { *out = (int) SIGIO; return 1; }
#endif
#ifdef SIGIOT
  if (strcmp(name, "SIGIOT") == 0) { *out = (int) SIGIOT; return 1; }
#endif
#ifdef SIGKILL
  if (strcmp(name, "SIGKILL") == 0) { *out = (int) SIGKILL; return 1; }
#endif
#ifdef SIGPIPE
  if (strcmp(name, "SIGPIPE") == 0) { *out = (int) SIGPIPE; return 1; }
#endif
#ifdef SIGPOLL
  if (strcmp(name, "SIGPOLL") == 0) { *out = (int) SIGPOLL; return 1; }
#endif
#ifdef SIGPROF
  if (strcmp(name, "SIGPROF") == 0) { *out = (int) SIGPROF; return 1; }
#endif
#ifdef SIGPWR
  if (strcmp(name, "SIGPWR") == 0) { *out = (int) SIGPWR; return 1; }
#endif
#ifdef SIGQUIT
  if (strcmp(name, "SIGQUIT") == 0) { *out = (int) SIGQUIT; return 1; }
#endif
#ifdef SIGSEGV
  if (strcmp(name, "SIGSEGV") == 0) { *out = (int) SIGSEGV; return 1; }
#endif
#ifdef SIGSTKFLT
  if (strcmp(name, "SIGSTKFLT") == 0) { *out = (int) SIGSTKFLT; return 1; }
#endif
#ifdef SIGSTOP
  if (strcmp(name, "SIGSTOP") == 0) { *out = (int) SIGSTOP; return 1; }
#endif
#ifdef SIGSYS
  if (strcmp(name, "SIGSYS") == 0) { *out = (int) SIGSYS; return 1; }
#endif
#ifdef SIGTERM
  if (strcmp(name, "SIGTERM") == 0) { *out = (int) SIGTERM; return 1; }
#endif
#ifdef SIGTRAP
  if (strcmp(name, "SIGTRAP") == 0) { *out = (int) SIGTRAP; return 1; }
#endif
#ifdef SIGTSTP
  if (strcmp(name, "SIGTSTP") == 0) { *out = (int) SIGTSTP; return 1; }
#endif
#ifdef SIGTTIN
  if (strcmp(name, "SIGTTIN") == 0) { *out = (int) SIGTTIN; return 1; }
#endif
#ifdef SIGTTOU
  if (strcmp(name, "SIGTTOU") == 0) { *out = (int) SIGTTOU; return 1; }
#endif
#ifdef SIGURG
  if (strcmp(name, "SIGURG") == 0) { *out = (int) SIGURG; return 1; }
#endif
#ifdef SIGUSR1
  if (strcmp(name, "SIGUSR1") == 0) { *out = (int) SIGUSR1; return 1; }
#endif
#ifdef SIGUSR2
  if (strcmp(name, "SIGUSR2") == 0) { *out = (int) SIGUSR2; return 1; }
#endif
#ifdef SIGVTALRM
  if (strcmp(name, "SIGVTALRM") == 0) { *out = (int) SIGVTALRM; return 1; }
#endif
#ifdef SIGWINCH
  if (strcmp(name, "SIGWINCH") == 0) { *out = (int) SIGWINCH; return 1; }
#endif
#ifdef SIGXCPU
  if (strcmp(name, "SIGXCPU") == 0) { *out = (int) SIGXCPU; return 1; }
#endif
#ifdef SIGXFSZ
  if (strcmp(name, "SIGXFSZ") == 0) { *out = (int) SIGXFSZ; return 1; }
#endif
#ifdef SIGRTMIN
  if (strcmp(name, "SIGRTMIN") == 0) { *out = (int) SIGRTMIN; return 1; }
#endif
#ifdef SIGRTMAX
  if (strcmp(name, "SIGRTMAX") == 0) { *out = (int) SIGRTMAX; return 1; }
#endif
  (void) name; (void) out; return 0;
}
#endif
