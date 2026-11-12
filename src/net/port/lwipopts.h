/* lwIP's options for ZDOS: IPv4, raw API, single-threaded (the
   kernel lock keeps it to one caller), static pools */
#ifndef ZDOS_LWIPOPTS_H
#define ZDOS_LWIPOPTS_H

#define NO_SYS 1
#define SYS_LIGHTWEIGHT_PROT 0
#define LWIP_SOCKET 0
#define LWIP_NETCONN 0
#define LWIP_IPV4 1
#define LWIP_IPV6 0
#define LWIP_STATS 0

#define LWIP_ARP 1
#define LWIP_ETHERNET 1
#define ARP_TABLE_SIZE 16
#define ARP_QUEUEING 1
#define ETHARP_SUPPORT_STATIC_ENTRIES 1
#define LWIP_ICMP 1
#define LWIP_RAW 1
#define LWIP_UDP 1
#define LWIP_TCP 1
#define LWIP_DHCP 1
#define DHCP_DOES_ARP_CHECK 0
#define LWIP_DHCP_CHECK_LINK_UP 1
#define LWIP_AUTOIP 0
#define LWIP_IGMP 0
#define LWIP_DNS 1
#define DNS_MAX_SERVERS 8
#define DNS_TABLE_SIZE 32 /* names cached for their TTL (and lookups under way); ~270 bytes each */
#define IP_REASSEMBLY 1
#define IP_FRAG 1
#define SO_REUSE 1
#define LWIP_TCP_KEEPALIVE 1
#define LWIP_NETIF_STATUS_CALLBACK 1
#define LWIP_NETIF_LINK_CALLBACK 1
#define LWIP_NETIF_HOSTNAME 1

/* Loopback: lwIP's lo (127.0.0.1/8), and packets to an
   interface's own address; queued
   until glue.c's zn_loop delivers them */
#define LWIP_NETIF_LOOPBACK 1
#define LWIP_LOOPBACK_MAX_PBUFS 128

/* Several cards; forwarding between them is switched on by
   ROUTING= (the hooks: zdos_hooks.h, glue.c) */
#define IP_FORWARD 1
#define IP_FORWARD_ALLOW_TX_ON_RX_NETIF 1
#define LWIP_HOOK_FILENAME "zdos_hooks.h"

/* Memory: a 1 MiB heap for outgoing data, pools for the rest */
#define MEM_ALIGNMENT 8
#define MEM_SIZE (1024 * 1024)
#define MEMP_NUM_PBUF 64
#define MEMP_NUM_RAW_PCB 8
#define MEMP_NUM_UDP_PCB 24
#define MEMP_NUM_TCP_PCB 48
#define MEMP_NUM_TCP_PCB_LISTEN 16
#define MEMP_NUM_REASSDATA 8
#define MEMP_NUM_ARP_QUEUE 32
#define PBUF_POOL_SIZE 256

#define TCP_MSS 1460
#define TCP_WND (32 * TCP_MSS)
#define TCP_SND_BUF (32 * TCP_MSS)
#define TCP_SND_QUEUELEN ((4 * (TCP_SND_BUF) + (TCP_MSS - 1)) / (TCP_MSS))
#define MEMP_NUM_TCP_SEG 512

#endif
