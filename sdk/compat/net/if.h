#pragma once
#ifndef _ZDOS_NET_IF_H_
#define _ZDOS_NET_IF_H_

#ifdef __cplusplus
extern "C" {
#endif

#define IF_NAMESIZE 16
#define IFNAMSIZ IF_NAMESIZE

/* Interface flags (Linux's values), as getifaddrs gives them */
#define IFF_UP 0x1
#define IFF_BROADCAST 0x2
#define IFF_LOOPBACK 0x8
#define IFF_RUNNING 0x40
#define IFF_MULTICAST 0x1000

/* "lo" is 1, "netN" (SYSTEM.CFG's NETn=) N + 2; 0 / NULL: no such interface */
unsigned if_nametoindex(const char *name);
char *if_indextoname(unsigned index, char *name);

#ifdef __cplusplus
}
#endif

#endif
