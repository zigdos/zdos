#pragma once
#ifndef _ZDOS_SYS_PARAM_H_
#define _ZDOS_SYS_PARAM_H_

#include <limits.h>
#include <sys/types.h>
#include <endian.h>

#ifndef MAXPATHLEN
#define MAXPATHLEN PATH_MAX
#endif
#define MAXHOSTNAMELEN 64
#define NOFILE 128
#define NBBY 8
#ifndef MIN
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#endif
#define howmany(x, y) (((x) + ((y) - 1)) / (y))
#define roundup(x, y) ((((x) + ((y) - 1)) / (y)) * (y))
#define rounddown(x, y) (((x) / (y)) * (y))
#define powerof2(x) ((((x) - 1) & (x)) == 0)
#define nitems(a) (sizeof(a) / sizeof((a)[0]))
#define setbit(a, i) (((unsigned char *)(a))[(i) / NBBY] |= 1 << ((i) % NBBY))
#define clrbit(a, i) (((unsigned char *)(a))[(i) / NBBY] &= ~(1 << ((i) % NBBY)))
#define isset(a, i) (((const unsigned char *)(a))[(i) / NBBY] & (1 << ((i) % NBBY)))
#define isclr(a, i) (!isset(a, i))

#endif
