#ifndef TITAN_OS_ENVIRONMENT_BROWSER_H
#define TITAN_OS_ENVIRONMENT_BROWSER_H

/* emsdk 6.0.13's stdlib.h hides these without POSIX feature macros; a feature macro in a header would come too late in the generated translation unit. */
int setenv(const char *, const char *, int);
int unsetenv(const char *);

#endif
