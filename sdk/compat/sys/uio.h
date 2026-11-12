#pragma once
#ifndef _ZDOS_SYS_UIO_H_
#define _ZDOS_SYS_UIO_H_

#include <sys/types.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

struct iovec {
    void *iov_base;
    size_t iov_len;
};
#define IOV_MAX 1024

/* One read or write per buffer, in turn (zdos_unix.c) */
ssize_t readv(int fd, const struct iovec *iov, int count);
ssize_t writev(int fd, const struct iovec *iov, int count);
ssize_t preadv(int fd, const struct iovec *iov, int count, off_t offset);
ssize_t pwritev(int fd, const struct iovec *iov, int count, off_t offset);

#ifdef __cplusplus
}
#endif
#endif
