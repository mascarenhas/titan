#ifndef TITAN_TEST_OS_DESCRIPTOR_LIMIT_H
#define TITAN_TEST_OS_DESCRIPTOR_LIMIT_H
int titan_test_fd_limit_lower(void);
int titan_test_fd_limit_restore(void);
int titan_test_fd_limit_restored(void);
#endif
