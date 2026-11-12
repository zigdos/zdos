/* The router's NAT for its networks (nat.c); lan.zig sets it up
   (the DHCP and DNS servers are programs:
   apps/dhcpd.zig, apps/dnsd.zig) */
#ifndef ZDOS_NET_LAN_H
#define ZDOS_NET_LAN_H

#include <stddef.h>
#include "lwip/netif.h"
#include "lwip/sys.h"

/* From glue.c: interface i's netif (NULL past the last) */
struct netif *zn_netif(int i);

int zn_nat_enable(int iface);
int zn_nat_forward(int proto, unsigned short port, unsigned int to, unsigned short to_port);
int zn_nat_on(struct netif *n);
int zn_nat_entries(void);
int zn_nat_out(struct pbuf *p, struct netif *in, struct netif *out);

#endif
