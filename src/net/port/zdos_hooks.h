/* lwIP's hooks into glue.c (lwipopts.h names this file):
   static routes, ROUTING=; NAT=
   (nat.c) in forwarding and input */
#ifndef ZDOS_HOOKS_H
#define ZDOS_HOOKS_H

struct netif;
struct pbuf;
struct ip4_addr;

struct netif *zn_route_hook(const struct ip4_addr *dest);
const struct ip4_addr *zn_gateway_hook(struct netif *n, const struct ip4_addr *dest);
int zn_canforward_hook(struct pbuf *p, unsigned int dest);
int zn_forward_hook(struct pbuf *p, struct netif *in, struct netif *out);
int zn_nat_in(struct pbuf *p, struct netif *in);

#define LWIP_HOOK_IP4_ROUTE(dest) zn_route_hook(dest)
#define LWIP_HOOK_ETHARP_GET_GW(netif, dest) zn_gateway_hook(netif, dest)
#define LWIP_HOOK_IP4_CANFORWARD(p, dest) zn_canforward_hook(p, dest)
#define ZDOS_HOOK_IP4_FORWARD(p, in, out) zn_forward_hook(p, in, out)
#define LWIP_HOOK_IP4_INPUT(p, in) zn_nat_in(p, in)

#endif
