lwIP 2.0.2 (BSD license: COPYING, and docs/COPYING/LWIP.TXT on drive C:), the IPv4 parts, from MINIX 3's
minix/lib/liblwip/dist. The kernel runs it single-threaded (NO_SYS) under
its kernel lock; ZDOS's settings and glue are in src/net/port and src/net.

Changed: ip4_route in core/ipv4/ip4.c is no longer __weak (a MINIX patch);
core/ipv4/etharp.c gets etharp_zdos_remove and etharp_zdos_is_static
(ARP -d, ARP's listing). ip4_forward in core/ipv4/ip4.c gets two hooks:
LWIP_HOOK_IP4_CANFORWARD (as in lwIP 2.1: ROUTING=) and
ZDOS_HOOK_IP4_FORWARD (each forwarded packet, its way out: for NAT).
