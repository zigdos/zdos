#pragma once
#ifndef _ZDOS_SYS_SELECT_H_
#define _ZDOS_SYS_SELECT_H_

#include <stdint.h>
#include <sys/time.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FD_SETSIZE 128

typedef struct {
    uint64_t bits[FD_SETSIZE / 64];
} fd_set;

#define FD_ZERO(s) ((s)->bits[0] = (s)->bits[1] = 0)
#define FD_SET(fd, s) ((s)->bits[(fd) / 64] |= (uint64_t)1 << ((fd) % 64))
#define FD_CLR(fd, s) ((s)->bits[(fd) / 64] &= ~((uint64_t)1 << ((fd) % 64)))
#define FD_ISSET(fd, s) (((s)->bits[(fd) / 64] >> ((fd) % 64)) & 1)

/* On poll (poll.h): the same readiness. struct timeval is sys/time.h's,
   which may still be on its way (it includes this through sys/types.h) */
struct timeval;
int select(int nfds, fd_set *readfds, fd_set *writefds, fd_set *exceptfds, struct timeval *timeout);

#ifdef __cplusplus
}
#endif

#endif
