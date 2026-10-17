#ifndef TITAN_UV_ADDRESS_NATIVE_H
#define TITAN_UV_ADDRESS_NATIVE_H
#include <stddef.h>
#include <uv.h>
/* Darwin exposes ntohs as a function-like macro, which Titan cannot import as
 * a callable. Keep the platform's actual byte-order operation in this wrapper. */
static inline uint16_t titan_sockaddr_ntohs(uint16_t port) {
  return ntohs(port);
}
/* BSD sockaddr includes sa_len before sa_family; Windows/Unix family typedefs
 * differ. This is the exact number of bytes required to observe the family. */
static inline size_t titan_sockaddr_family_size(void) {
  return offsetof(struct sockaddr, sa_family) +
         sizeof(((struct sockaddr*) 0)->sa_family);
}
static inline int titan_sockaddr_length_field(const struct sockaddr* address) {
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || \
    defined(__OpenBSD__) || defined(__DragonFly__)
  return address->sa_len;
#else
  (void) address;
  return -1;
#endif
}
#endif
