#pragma once
#ifndef _ZDOS_NETINET_IN_H_
#define _ZDOS_NETINET_IN_H_

#include <sys/socket.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint16_t in_port_t;
typedef uint32_t in_addr_t;

struct in_addr {
    in_addr_t s_addr;
};

struct in6_addr {
    uint8_t s6_addr[16];
};

struct sockaddr_in {
    sa_family_t sin_family;
    in_port_t sin_port;
    struct in_addr sin_addr;
    char sin_zero[8];
};

struct sockaddr_in6 {
    sa_family_t sin6_family;
    in_port_t sin6_port;
    uint32_t sin6_flowinfo;
    struct in6_addr sin6_addr;
    uint32_t sin6_scope_id;
};

#define IPPROTO_IP 0
#define IPPROTO_ICMP 1
#define IPPROTO_TCP 6
#define IPPROTO_UDP 17
#define IPPROTO_IPV6 41
#define INADDR_ANY ((in_addr_t)0)
#define INADDR_BROADCAST ((in_addr_t)0xffffffff)
#define INADDR_NONE ((in_addr_t)0xffffffff)
#define INADDR_LOOPBACK ((in_addr_t)0x7f000001)
#define IP_TTL 2
#define INET_ADDRSTRLEN 16
#define INET6_ADDRSTRLEN 46

#define htons(x) ((uint16_t)__builtin_bswap16(x))
#define ntohs(x) ((uint16_t)__builtin_bswap16(x))
#define htonl(x) ((uint32_t)__builtin_bswap32(x))
#define ntohl(x) ((uint32_t)__builtin_bswap32(x))

#ifdef __cplusplus
}
#endif
#endif
