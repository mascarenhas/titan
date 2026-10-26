#ifndef TITAN_IO_TRANSFER_DUP_FAILURE_H
#define TITAN_IO_TRANSFER_DUP_FAILURE_H
/* Counters belong only to the isolated link-wrapped child executable. */
int titan_io_close_failure_attempts(void);
void titan_io_close_failure_release_guard(void);
#endif
