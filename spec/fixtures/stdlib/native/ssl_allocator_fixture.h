#ifndef TITAN_SSL_ALLOCATOR_FIXTURE_H
#define TITAN_SSL_ALLOCATOR_FIXTURE_H
int titan_ssl_allocator_installed(void);
int titan_ssl_allocator_layout_supported(void);
int titan_ssl_allocator_pem_bio_ordinal(void);
void titan_ssl_allocator_arm(const char *file, int line, int ordinal);
void titan_ssl_allocator_disarm(void);
int titan_ssl_allocator_fired(void);
#endif
