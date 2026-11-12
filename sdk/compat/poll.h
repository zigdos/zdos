#pragma once
#ifndef _ZDOS_POLL_H_
#define _ZDOS_POLL_H_

#ifdef __cplusplus
extern "C" {
#endif

/* Pipes are ready when they hold data (or have no writer left:
   POLLHUP) or room; standard input when a key waits (or its
   redirection has data); files, the screen and memory streams always */
#define POLLIN 0x001
#define POLLPRI 0x002
#define POLLOUT 0x004
#define POLLERR 0x008
#define POLLHUP 0x010
#define POLLNVAL 0x020
#define POLLRDNORM POLLIN
#define POLLWRNORM POLLOUT

typedef unsigned long nfds_t;

struct pollfd {
    int fd;
    short events;
    short revents;
};

int poll(struct pollfd *fds, nfds_t n, int timeout_ms);

#ifdef __cplusplus
}
#endif

#endif
