#pragma once
#ifndef _ZDOS_IFADDRS_H_
#define _ZDOS_IFADDRS_H_

#include <sys/socket.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The network interfaces and their IPv4 addresses, laid out as musl's:
   "lo" (127.0.0.1) first, then "net0", "net1" ... as SYSTEM.CFG numbers
   the cards (NETn=). One list, freed by freeifaddrs. */
struct ifaddrs {
    struct ifaddrs *ifa_next;
    char *ifa_name;
    unsigned ifa_flags;
    struct sockaddr *ifa_addr;
    struct sockaddr *ifa_netmask;
    union {
        struct sockaddr *ifu_broadaddr;
        struct sockaddr *ifu_dstaddr;
    } ifa_ifu;
    void *ifa_data;
};
#define ifa_broadaddr ifa_ifu.ifu_broadaddr
#define ifa_dstaddr ifa_ifu.ifu_dstaddr

int getifaddrs(struct ifaddrs **list);
void freeifaddrs(struct ifaddrs *list);

#ifdef __cplusplus
}
#endif

#endif
