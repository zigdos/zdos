/* lwIP for the ZDOS kernel: the interfaces (a
   card each, or a bridge of cards;
   lwIP's loopback), routes, DNS, ping, ARP, the
   connection list and sockets on lwIP's raw API.
   Everything here runs under net.zig's lock (the
   kernel lock, or the network core's spin lock):
   lwIP is never entered twice. Events wake the
   waiters of an object through zdos_net_wake. */
#include <string.h>
#include "lwip/init.h"
#include "lwip/netif.h"
#include "lwip/etharp.h"
#include "lwip/dhcp.h"
#include "lwip/dns.h"
#include "lwip/tcp.h"
#include "lwip/udp.h"
#include "lwip/raw.h"
#include "lwip/inet_chksum.h"
#include "lwip/timeouts.h"
#include "lwip/priv/tcp_priv.h"
#include "lwip/icmp.h"
#include "lwip/prot/icmp.h"
#include "lwip/prot/ip4.h"
#include "netif/ethernet.h"
#include "glue.h"
#include "lan.h"

/* From net.zig */
void zdos_net_wake(const void *obj);
int zdos_net_link_send(int card, const void *frame, size_t len);
unsigned int zdos_net_millis(void);

u32_t sys_timeouts_sleeptime(void); /* timeouts.c, public with NO_SYS */
err_t etharp_zdos_remove(const ip4_addr_t *ipaddr);
u8_t etharp_zdos_is_static(u8_t i);

u32_t sys_now(void) {
    return zdos_net_millis();
}

/* INTERFACES */

/* An interface: one card, or a bridge of several (its ports) */
struct iface {
    struct netif n;
    u8_t ports[ZN_CARDS];
    u8_t port_count;
};

static struct iface ifaces[ZN_CARDS];
static int iface_count;
static s8_t card_iface[ZN_CARDS]; /* the interface a card belongs to, -1 none */
static u8_t card_up[ZN_CARDS];
static u8_t forwarding; /* ROUTING=true */
static ip4_addr_t static_dns[DNS_MAX_SERVERS]; /* DNS= of SYSTEM.CFG: replaces DHCP's */
static u8_t static_dns_count;
static u8_t frame_out[1536];

static void bridge_output(struct iface *b, const u8_t *frame, size_t len);

static struct iface *iface_of(struct netif *n) {
    return (struct iface *)n->state;
}

/* Short frames padded to Ethernet's 60 bytes: not every card
   does it (QEMU's e1000e doesn't), and some receivers drop
   runts (an ARP is 42 bytes) */
#define MIN_FRAME 60

static err_t link_output(struct netif *n, struct pbuf *p) {
    struct iface *f = iface_of(n);
    if (p->tot_len > sizeof(frame_out)) return ERR_BUF;
    pbuf_copy_partial(p, frame_out, p->tot_len, 0);
    size_t len = p->tot_len;
    if (len < MIN_FRAME) {
        memset(frame_out + len, 0, MIN_FRAME - len);
        len = MIN_FRAME;
    }
    if (f->port_count > 1) {
        bridge_output(f, frame_out, len);
        return ERR_OK;
    }
    return zdos_net_link_send(f->ports[0], frame_out, len) ? ERR_OK : ERR_IF;
}

static err_t interface_init(struct netif *n) {
    struct iface *f = iface_of(n);
    n->name[0] = f->port_count > 1 ? 'b' : 'e';
    n->name[1] = f->port_count > 1 ? 'r' : 'n';
    n->output = etharp_output;
    n->linkoutput = link_output;
    n->mtu = 1500;
    n->hwaddr_len = ETH_HWADDR_LEN;
    n->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP | NETIF_FLAG_ETHERNET;
    n->hostname = "zdos";
    return ERR_OK;
}

static void use_static_dns(void) {
    if (static_dns_count == 0) return;
    for (u8_t i = 0; i < DNS_MAX_SERVERS; i++) {
        ip_addr_t a;
        ip_addr_copy_from_ip4(a, static_dns[i]);
        dns_setserver(i, &a);
    }
}

/* The default route: the first interface with a router */
static void choose_default(void) {
    for (int i = 0; i < iface_count; i++) {
        if (!ip4_addr_isany_val(*netif_ip4_gw(&ifaces[i].n))) {
            netif_set_default(&ifaces[i].n);
            return;
        }
    }
    if (iface_count > 0) netif_set_default(&ifaces[0].n);
}

/* An address came or went (DHCP): DNS= stays */
static void status_changed(struct netif *n) {
    use_static_dns();
    choose_default();
    zdos_net_wake(n);
}

void zn_start(const unsigned int dns[8], int forward) {
    lwip_init();
    for (u8_t i = 0; i < DNS_MAX_SERVERS; i++) {
        ip4_addr_set_u32(&static_dns[i], dns[i]);
        if (dns[i] != 0) static_dns_count++;
    }
    for (int c = 0; c < ZN_CARDS; c++) card_iface[c] = -1;
    forwarding = forward ? 1 : 0;
    use_static_dns();
}

/* A new interface: its number (0 ...), -1 if there is no room */
int zn_add(const struct zn_setup *s) {
    if (iface_count == ZN_CARDS || s->port_count == 0 || s->port_count > ZN_CARDS) return -1;
    struct iface *f = &ifaces[iface_count];
    memset(f, 0, sizeof(*f));
    MEMCPY(f->ports, s->ports, s->port_count);
    f->port_count = s->port_count;
    for (int i = 0; i < s->port_count; i++) {
        if (s->ports[i] >= ZN_CARDS) return -1;
        card_iface[s->ports[i]] = (s8_t)iface_count;
        card_up[s->ports[i]] = s->link_up;
    }
    ip4_addr_t ip, mask, gw;
    ip4_addr_set_u32(&ip, s->ip);
    ip4_addr_set_u32(&mask, s->mask);
    ip4_addr_set_u32(&gw, s->gateway);
    netif_add(&f->n, &ip, &mask, &gw, f, interface_init, ethernet_input);
    MEMCPY(f->n.hwaddr, s->mac, ETH_HWADDR_LEN);
    netif_set_status_callback(&f->n, status_changed);
    netif_set_up(&f->n);
    if (s->link_up) netif_set_link_up(&f->n);
    iface_count++;
    choose_default();
    if (s->dhcp) dhcp_start(&f->n);
    return iface_count - 1;
}

/* A card's cable: a bridge's link is up while one of its ports' is */
void zn_link(int card, int up) {
    if (card < 0 || card >= ZN_CARDS || card_iface[card] < 0) return;
    card_up[card] = up ? 1 : 0;
    struct iface *f = &ifaces[card_iface[card]];
    int any = 0;
    for (int i = 0; i < f->port_count; i++) any |= card_up[f->ports[i]];
    if (any && !netif_is_link_up(&f->n)) netif_set_link_up(&f->n);
    if (!any && netif_is_link_up(&f->n)) netif_set_link_down(&f->n);
}

static void deliver(struct iface *f, const void *frame, size_t len) {
    struct pbuf *p = pbuf_alloc(PBUF_RAW, (u16_t)len, PBUF_POOL);
    if (p == NULL) return; /* out of buffers: dropped, as a busy card would */
    pbuf_take(p, frame, (u16_t)len);
    if (f->n.input(p, &f->n) != ERR_OK) pbuf_free(p);
}

static void bridge_input(struct iface *b, int card, const u8_t *frame, size_t len);

/* A frame a card received (copied: the driver keeps its buffer) */
void zn_input(int card, const void *frame, size_t len) {
    if (len < SIZEOF_ETH_HDR || len > 0xFFFF || card < 0 || card >= ZN_CARDS || card_iface[card] < 0) return;
    struct iface *f = &ifaces[card_iface[card]];
    if (f->port_count > 1) {
        bridge_input(f, card, frame, len);
    } else {
        deliver(f, frame, len);
    }
}

void zn_timers(void) {
    sys_check_timeouts();
}

/* Whether lwIP sent itself packets (lo, an interface's own address) */
int zn_loop_waiting(void) {
    struct netif *n;
    NETIF_FOREACH(n) {
        if (n->loop_first != NULL) return 1;
    }
    return 0;
}

/* Those packets delivered, and what they bring about (replies,
   ACKs): 1 if there were some */
int zn_loop(void) {
    if (!zn_loop_waiting()) return 0;
    netif_poll_all();
    return 1;
}

/* Milliseconds until a timer is due (0xFFFFFFFF: none) */
unsigned int zn_sleeptime(void) {
    return sys_timeouts_sleeptime();
}

/* Interface i's settings: 0 if there is none */
int zn_config(int i, struct zn_config *c) {
    if (i < 0 || i >= iface_count) return 0;
    struct netif *n = &ifaces[i].n;
    c->ip = ip4_addr_get_u32(netif_ip4_addr(n));
    c->mask = ip4_addr_get_u32(netif_ip4_netmask(n));
    c->gateway = ip4_addr_get_u32(netif_ip4_gw(n));
    for (u8_t k = 0; k < DNS_MAX_SERVERS; k++) {
        const ip_addr_t *d = dns_getserver(k);
        c->dns[k] = ip4_addr_get_u32(ip_2_ip4(d));
    }
    MEMCPY(c->mac, n->hwaddr, ETH_HWADDR_LEN);
    c->link_up = netif_is_link_up(n) ? 1 : 0;
    struct dhcp *d = netif_dhcp_data(n);
    c->dhcp = d != NULL && d->state != 0 ? 1 : 0;
    c->dhcp_bound = dhcp_supplied_address(n) ? 1 : 0;
    c->lease_s = c->dhcp_bound ? d->offered_t0_lease : 0;
    c->dhcp_server = c->dhcp_bound ? ip4_addr_get_u32(ip_2_ip4(&d->server_ip_addr)) : 0;
    c->is_default = n == netif_default ? 1 : 0;
    return 1;
}

/* The object waited on for interface
   i's address changes (IPCONFIG -RENEW) */
struct netif *zn_netif(int i) {
    return i >= 0 && i < iface_count ? &ifaces[i].n : NULL;
}

const void *zn_interface(int i) {
    return &ifaces[i].n;
}

void zn_dhcp_renew(int i) {
    struct netif *n = &ifaces[i].n;
    if (dhcp_supplied_address(n)) {
        dhcp_renew(n);
    } else {
        dhcp_start(n);
    }
}

void zn_dhcp_release(int i) {
    struct netif *n = &ifaces[i].n;
    struct dhcp *d = netif_dhcp_data(n);
    if (d != NULL && d->state != 0) dhcp_release(n);
}

/* THE BRIDGE: CARDS AS ONE ETHERNET SEGMENT */

/* Where each address was last seen (a port), for 5 minutes */
#define BRIDGE_MACS 128
#define BRIDGE_AGE_MS (300 * 1000)
static struct {
    u8_t used, iface, card;
    u8_t mac[ETH_HWADDR_LEN];
    u32_t seen;
} macs[BRIDGE_MACS];

static int mac_slot(int iface, const u8_t *mac) {
    for (int i = 0; i < BRIDGE_MACS; i++) {
        if (macs[i].used && macs[i].iface == iface && memcmp(macs[i].mac, mac, ETH_HWADDR_LEN) == 0) return i;
    }
    return -1;
}

static int mac_find(int iface, const u8_t *mac) {
    int i = mac_slot(iface, mac);
    return i >= 0 && sys_now() - macs[i].seen < BRIDGE_AGE_MS ? i : -1;
}

/* Its slot, a free one, else the oldest */
static void mac_learn(int iface, const u8_t *mac, int card) {
    u32_t now = sys_now();
    int slot = mac_slot(iface, mac);
    for (int i = 0; slot < 0 && i < BRIDGE_MACS; i++) {
        if (!macs[i].used) slot = i;
    }
    if (slot < 0) {
        slot = 0;
        for (int i = 1; i < BRIDGE_MACS; i++) {
            if (now - macs[i].seen > now - macs[slot].seen) slot = i;
        }
    }
    MEMCPY(macs[slot].mac, mac, ETH_HWADDR_LEN);
    macs[slot].used = 1;
    macs[slot].iface = (u8_t)iface;
    macs[slot].card = (u8_t)card;
    macs[slot].seen = now;
}

/* To every port but `from` (-1: all) */
static void flood(struct iface *b, int from, const u8_t *frame, size_t len) {
    for (int i = 0; i < b->port_count; i++) {
        if (b->ports[i] != from && card_up[b->ports[i]]) zdos_net_link_send(b->ports[i], frame, len);
    }
}

static void bridge_input(struct iface *b, int card, const u8_t *frame, size_t len) {
    int self = (int)(b - ifaces);
    const u8_t *dst = frame, *src = frame + ETH_HWADDR_LEN;
    if ((src[0] & 1) == 0 && memcmp(src, b->n.hwaddr, ETH_HWADDR_LEN) != 0) mac_learn(self, src, card);
    if (dst[0] & 1) { /* broadcast, multicast: everyone's */
        flood(b, card, frame, len);
        deliver(b, frame, len);
        return;
    }
    if (memcmp(dst, b->n.hwaddr, ETH_HWADDR_LEN) == 0) {
        deliver(b, frame, len);
        return;
    }
    int at = mac_find(self, dst);
    if (at < 0) {
        flood(b, card, frame, len);
    } else if (macs[at].card != card) {
        zdos_net_link_send(macs[at].card, frame, len);
    } /* else: on the segment it came from */
}

static void bridge_output(struct iface *b, const u8_t *frame, size_t len) {
    int at = (frame[0] & 1) ? -1 : mac_find((int)(b - ifaces), frame);
    if (at < 0) {
        flood(b, -1, frame, len);
    } else {
        zdos_net_link_send(macs[at].card, frame, len);
    }
}

/* ROUTES: STATIC ONES (ROUTE=), FORWARDING (ROUTING=) */

static struct {
    ip4_addr_t dest, mask, gateway;
} routes[ZN_ROUTES];
static int route_count;

int zn_route_add(unsigned int dest, unsigned int mask, unsigned int gateway) {
    if (route_count == ZN_ROUTES) return 0;
    ip4_addr_set_u32(&routes[route_count].dest, dest & mask);
    ip4_addr_set_u32(&routes[route_count].mask, mask);
    ip4_addr_set_u32(&routes[route_count].gateway, gateway);
    route_count++;
    return 1;
}

/* The interface that reaches a gateway: its subnet */
static struct netif *link_to(const ip4_addr_t *gw) {
    for (int i = 0; i < iface_count; i++) {
        struct netif *n = &ifaces[i].n;
        if (netif_is_up(n) && netif_is_link_up(n) && !ip4_addr_isany_val(*netif_ip4_addr(n)) &&
            ip4_addr_netcmp(gw, netif_ip4_addr(n), netif_ip4_netmask(n))) {
            return n;
        }
    }
    return NULL;
}

/* The longest static route to dest that has a way out now: -1 none */
static int best_route(const ip4_addr_t *dest) {
    int best = -1;
    for (int i = 0; i < route_count; i++) {
        if (!ip4_addr_netcmp(dest, &routes[i].dest, &routes[i].mask)) continue;
        if (link_to(&routes[i].gateway) == NULL) continue;
        if (best < 0 || lwip_ntohl(ip4_addr_get_u32(&routes[i].mask)) > lwip_ntohl(ip4_addr_get_u32(&routes[best].mask))) best = i;
    }
    return best;
}

/* ip4_route: after the interfaces' own subnets, before the default */
struct netif *zn_route_hook(const ip4_addr_t *dest) {
    int r = best_route(dest);
    return r < 0 ? NULL : link_to(&routes[r].gateway);
}

/* etharp_output: a static route's gateway instead of the interface's */
const ip4_addr_t *zn_gateway_hook(struct netif *n, const ip4_addr_t *dest) {
    int r = best_route(dest);
    if (r < 0 || link_to(&routes[r].gateway) != n) return NULL;
    return &routes[r].gateway;
}

/* -1: lwIP's own checks decide; 0: not forwarded (ROUTING=false) */
int zn_canforward_hook(struct pbuf *p, unsigned int dest) {
    (void)p;
    (void)dest;
    return forwarding ? -1 : 0;
}

/* Each forwarded packet on its way out: 1 sends it (NAT=: nat.c) */
int zn_forward_hook(struct pbuf *p, struct netif *in, struct netif *out) {
    return zn_nat_out(p, in, out);
}

/* Static route i: 1 with it; *iface the
   interface it leaves by now (-1: none) */
int zn_route_entry(int i, unsigned int *dest, unsigned int *mask, unsigned int *gateway, int *iface) {
    if (i < 0 || i >= route_count) return 0;
    *dest = ip4_addr_get_u32(&routes[i].dest);
    *mask = ip4_addr_get_u32(&routes[i].mask);
    *gateway = ip4_addr_get_u32(&routes[i].gateway);
    struct netif *n = link_to(&routes[i].gateway);
    *iface = n == NULL ? -1 : (int)(iface_of(n) - ifaces);
    return 1;
}

/* DNS */

#define DNS_QUERIES 8
static struct {
    u8_t used;
    u8_t abandoned; /* its waiter gave up: freed when lwIP answers */
    s8_t state; /* 0 asking, 1 found, -1 not found */
    u32_t addr;
} queries[DNS_QUERIES];

static void dns_found(const char *name, const ip_addr_t *addr, void *arg) {
    (void)name;
    int i = (int)(uintptr_t)arg;
    if (queries[i].abandoned) {
        queries[i].used = 0;
        return;
    }
    queries[i].state = addr != NULL ? 1 : -1;
    if (addr != NULL) queries[i].addr = ip4_addr_get_u32(ip_2_ip4(addr));
    zdos_net_wake(&queries[i]);
}

/* A lookup of name: its number (zn_dns_result,
   zn_dns_end), -1 if none is free */
int zn_dns_start(const char *name) {
    int i = 0;
    while (i < DNS_QUERIES && queries[i].used) i++;
    if (i == DNS_QUERIES) return -1;
    queries[i].used = 1;
    queries[i].abandoned = 0;
    queries[i].state = 0;
    use_static_dns(); /* a DHCP renewal may have set its own */
    ip_addr_t a;
    err_t e = dns_gethostbyname(name, &a, dns_found, (void *)(uintptr_t)i);
    if (e == ERR_OK) {
        queries[i].state = 1;
        queries[i].addr = ip4_addr_get_u32(ip_2_ip4(&a));
    } else if (e != ERR_INPROGRESS) {
        queries[i].state = -1;
    }
    return i;
}

const void *zn_dns_object(int q) {
    return &queries[q];
}

/* 0 still asking, 1 found (*addr), -1 not found */
int zn_dns_result(int q, unsigned int *addr) {
    if (queries[q].state == 1) *addr = queries[q].addr;
    return queries[q].state;
}

void zn_dns_end(int q) {
    if (queries[q].state == 0) {
        queries[q].abandoned = 1;
    } else {
        queries[q].used = 0;
    }
}

/* PING (ICMP ECHO) */

#define PINGS 4
static struct raw_pcb *icmp_pcb;
static struct {
    u8_t used;
    u8_t state; /* ZN_PING_* */
    u8_t ttl;
    u16_t id, seq;
    u32_t sent, rtt, from;
    u16_t bytes;
} pings[PINGS];

/* An echo reply, or an error about an echo of ours (the
   original IP header and 8 bytes
   of it follow the ICMP header) */
static u8_t icmp_received(void *arg, struct raw_pcb *pcb, struct pbuf *p, const ip_addr_t *addr) {
    (void)arg;
    (void)pcb;
    struct ip_hdr ip;
    struct icmp_echo_hdr icmp;
    if (pbuf_copy_partial(p, &ip, sizeof(ip), 0) != sizeof(ip)) return 0;
    u16_t hlen = (u16_t)(IPH_HL(&ip) * 4);
    if (pbuf_copy_partial(p, &icmp, sizeof(icmp), hlen) != sizeof(icmp)) return 0;
    u8_t type = ICMPH_TYPE(&icmp);
    u16_t id = icmp.id, seq = icmp.seqno;
    u8_t state;
    if (type == ICMP_ER) {
        state = ZN_PING_REPLY;
    } else if (type == ICMP_DUR || type == ICMP_TE) {
        /* The echo it is about: its IP header, then its ICMP header */
        struct ip_hdr orig;
        struct icmp_echo_hdr oicmp;
        u16_t at = (u16_t)(hlen + 8);
        if (pbuf_copy_partial(p, &orig, sizeof(orig), at) != sizeof(orig)) return 0;
        at = (u16_t)(at + IPH_HL(&orig) * 4);
        if (pbuf_copy_partial(p, &oicmp, sizeof(oicmp), at) != sizeof(oicmp)) return 0;
        if (ICMPH_TYPE(&oicmp) != ICMP_ECHO) return 0;
        id = oicmp.id;
        seq = oicmp.seqno;
        state = type == ICMP_DUR ? ZN_PING_UNREACHABLE : ZN_PING_TTL_EXPIRED;
    } else {
        return 0; /* not ours: lwIP's ICMP goes on (answers echo requests) */
    }
    for (int i = 0; i < PINGS; i++) {
        if (pings[i].used && pings[i].state == ZN_PING_WAITING && pings[i].id == id && pings[i].seq == seq) {
            pings[i].state = state;
            pings[i].rtt = sys_now() - pings[i].sent;
            pings[i].from = ip4_addr_get_u32(ip_2_ip4(addr));
            pings[i].ttl = IPH_TTL(&ip);
            pings[i].bytes = (u16_t)(p->tot_len - hlen - sizeof(icmp));
            zdos_net_wake(&pings[i]);
            pbuf_free(p);
            return 1;
        }
    }
    return 0;
}

/* Sends an echo request of size data bytes: its number, -1
   (none free, no memory), -2 (no route) */
int zn_ping_send(unsigned int dst, unsigned short id, unsigned short seq, unsigned short size, unsigned char ttl) {
    if (icmp_pcb == NULL) {
        icmp_pcb = raw_new(IP_PROTO_ICMP);
        if (icmp_pcb == NULL) return -1;
        raw_recv(icmp_pcb, icmp_received, NULL);
        raw_bind(icmp_pcb, IP_ADDR_ANY);
    }
    int i = 0;
    while (i < PINGS && pings[i].used) i++;
    if (i == PINGS) return -1;
    struct pbuf *p = pbuf_alloc(PBUF_IP, (u16_t)(sizeof(struct icmp_echo_hdr) + size), PBUF_RAM);
    if (p == NULL) return -1;
    struct icmp_echo_hdr *h = (struct icmp_echo_hdr *)p->payload;
    ICMPH_TYPE_SET(h, ICMP_ECHO);
    ICMPH_CODE_SET(h, 0);
    h->id = lwip_htons(id);
    h->seqno = lwip_htons(seq);
    u8_t *data = (u8_t *)p->payload + sizeof(*h);
    for (u16_t k = 0; k < size; k++) data[k] = (u8_t)('a' + k % 23);
    h->chksum = 0;
    h->chksum = inet_chksum(h, p->len);
    pings[i].used = 1;
    pings[i].state = ZN_PING_WAITING;
    pings[i].id = h->id;
    pings[i].seq = h->seqno;
    pings[i].sent = sys_now();
    ip_addr_t a;
    ip_addr_set_ip4_u32(&a, dst);
    icmp_pcb->ttl = ttl;
    err_t e = raw_sendto(icmp_pcb, p, &a);
    pbuf_free(p);
    if (e != ERR_OK) {
        pings[i].used = 0;
        return e == ERR_RTE ? -2 : -1;
    }
    return i;
}

const void *zn_ping_object(int n) {
    return &pings[n];
}

/* Its state; with an answer, what it says */
int zn_ping_result(int n, struct zn_ping *out) {
    out->rtt = pings[n].rtt;
    out->from = pings[n].from;
    out->ttl = pings[n].ttl;
    out->bytes = pings[n].bytes;
    return pings[n].state;
}

void zn_ping_end(int n) {
    pings[n].used = 0;
}

/* ARP */

/* Entry i of the table: 1 with it, 0 if empty (i < ZN_ARP_SIZE) */
int zn_arp_entry(int i, unsigned int *ip, unsigned char mac[6], int *is_static) {
    ip4_addr_t *a;
    struct netif *n;
    struct eth_addr *e;
    if (i < 0 || i >= ARP_TABLE_SIZE || !etharp_get_entry((u8_t)i, &a, &n, &e)) return 0;
    *ip = ip4_addr_get_u32(a);
    MEMCPY(mac, e->addr, ETH_HWADDR_LEN);
    *is_static = etharp_zdos_is_static((u8_t)i);
    return 1;
}

int zn_arp_size(void) {
    return ARP_TABLE_SIZE;
}

int zn_arp_add(unsigned int ip, const unsigned char mac[6]) {
    ip4_addr_t a;
    struct eth_addr e;
    ip4_addr_set_u32(&a, ip);
    MEMCPY(e.addr, mac, ETH_HWADDR_LEN);
    return etharp_add_static_entry(&a, &e) == ERR_OK;
}

int zn_arp_remove(unsigned int ip) {
    ip4_addr_t a;
    ip4_addr_set_u32(&a, ip);
    return etharp_zdos_remove(&a) == ERR_OK;
}

void zn_arp_clear(void) {
    for (int i = 0; i < ARP_TABLE_SIZE; i++) {
        ip4_addr_t *a;
        struct netif *n;
        struct eth_addr *e;
        if (etharp_get_entry((u8_t)i, &a, &n, &e)) {
            ip4_addr_t copy = *a;
            etharp_zdos_remove(&copy);
        }
    }
}

/* SOCKETS */

#define SOCKETS 64
#define ACCEPT_QUEUE 16
#define DATAGRAMS 32

struct datagram {
    struct pbuf *p;
    u32_t addr, local; /* local: the address it was sent to */
    u16_t port;
    s8_t iface; /* the interface it came in by, -1 the loopback */
};

struct zn_socket {
    u8_t used;
    u8_t kind; /* ZN_TCP, ZN_UDP */
    u8_t listening, connecting, connected, eof, shut_wr, bound;
    s8_t error; /* an lwIP err_t to report once (0: none) */
    s8_t reset; /* the connection is gone (error, reset, aborted) */
    u8_t refused; /* reset while connecting: nobody listens there */
    u8_t want_output; /* zn_defer: for zn_flush */
    u32_t recved; /* zn_defer: read, the window not yet opened for it */
    union {
        struct tcp_pcb *tcp;
        struct udp_pcb *udp;
    } pcb;
    struct pbuf *rx; /* TCP: received, not yet read */
    u16_t rx_off; /* read of the first pbuf */
    struct zn_socket *accepted[ACCEPT_QUEUE];
    u8_t acc_first, acc_count, backlog;
    struct datagram dgrams[DATAGRAMS];
    u8_t dg_first, dg_count;
};

static struct zn_socket sockets[SOCKETS];

/* 1: sending and window updates wait
   for zn_flush (on the network core) */
int zn_defer = 0;

static struct zn_socket *new_socket(u8_t kind) {
    for (int i = 0; i < SOCKETS; i++) {
        if (!sockets[i].used) {
            struct zn_socket *s = &sockets[i];
            memset(s, 0, sizeof(*s));
            s->used = 1;
            s->kind = kind;
            return s;
        }
    }
    return NULL;
}

/* -- TCP events -- */

static err_t tcp_received(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err) {
    (void)pcb;
    (void)err;
    struct zn_socket *s = arg;
    if (p == NULL) {
        s->eof = 1;
    } else if (s->rx == NULL) {
        s->rx = p;
    } else {
        pbuf_cat(s->rx, p);
    }
    zdos_net_wake(s);
    return ERR_OK;
}

static err_t tcp_sent_some(void *arg, struct tcp_pcb *pcb, u16_t len) {
    (void)pcb;
    (void)len;
    zdos_net_wake(arg);
    return ERR_OK;
}

/* The pcb is gone already (lwIP freed it) */
static void tcp_failed(void *arg, err_t err) {
    struct zn_socket *s = arg;
    s->pcb.tcp = NULL;
    s->refused = s->connecting && err == ERR_RST;
    s->error = err;
    s->reset = 1;
    s->connecting = 0;
    s->connected = 0;
    s->eof = 1;
    zdos_net_wake(s);
}

static err_t tcp_connected_now(void *arg, struct tcp_pcb *pcb, err_t err) {
    (void)pcb;
    struct zn_socket *s = arg;
    s->connecting = 0;
    s->connected = err == ERR_OK;
    if (err != ERR_OK) s->error = err;
    zdos_net_wake(s);
    return ERR_OK;
}

static void tcp_events(struct zn_socket *s, struct tcp_pcb *pcb) {
    tcp_arg(pcb, s);
    tcp_recv(pcb, tcp_received);
    tcp_sent(pcb, tcp_sent_some);
    tcp_err(pcb, tcp_failed);
}

static err_t tcp_incoming(void *arg, struct tcp_pcb *pcb, err_t err) {
    struct zn_socket *l = arg;
    if (err != ERR_OK || pcb == NULL) return ERR_VAL;
    struct zn_socket *s = l->acc_count < l->backlog ? new_socket(ZN_TCP) : NULL;
    if (s == NULL) {
        tcp_abort(pcb);
        return ERR_ABRT;
    }
    s->pcb.tcp = pcb;
    s->connected = 1;
    s->bound = 1;
    tcp_events(s, pcb);
    l->accepted[(l->acc_first + l->acc_count) % ACCEPT_QUEUE] = s;
    l->acc_count++;
    zdos_net_wake(l);
    return ERR_OK;
}

/* -- UDP events -- */

static void udp_received(void *arg, struct udp_pcb *pcb, struct pbuf *p, const ip_addr_t *addr, u16_t port) {
    (void)pcb;
    struct zn_socket *s = arg;
    if (s->dg_count == DATAGRAMS) {
        pbuf_free(p); /* full: dropped, as UDP may */
        return;
    }
    struct datagram *d = &s->dgrams[(s->dg_first + s->dg_count) % DATAGRAMS];
    d->p = p;
    d->addr = ip4_addr_get_u32(ip_2_ip4(addr));
    d->port = port;
    d->local = ip4_addr_get_u32(ip4_current_dest_addr());
    d->iface = -1;
    for (int i = 0; i < iface_count; i++) {
        if (ip_current_input_netif() == &ifaces[i].n) d->iface = (s8_t)i;
    }
    s->dg_count++;
    zdos_net_wake(s);
}

/* -- Operations: none waits; net.zig
   waits on the socket and tries again -- */

struct zn_socket *zn_socket_new(int kind) {
    struct zn_socket *s = new_socket((u8_t)kind);
    if (s == NULL) return NULL;
    if (kind == ZN_TCP) {
        s->pcb.tcp = tcp_new();
        if (s->pcb.tcp != NULL) tcp_events(s, s->pcb.tcp);
    } else {
        s->pcb.udp = udp_new();
        if (s->pcb.udp != NULL) udp_recv(s->pcb.udp, udp_received, s);
    }
    if (s->pcb.tcp == NULL) {
        s->used = 0;
        return NULL;
    }
    return s;
}

static int result(err_t e) {
    switch (e) {
        case ERR_OK: return ZN_OK;
        case ERR_MEM:
        case ERR_BUF: return ZN_NO_MEMORY;
        case ERR_USE: return ZN_IN_USE;
        case ERR_RTE: return ZN_UNREACHABLE;
        case ERR_ISCONN: return ZN_IS_CONNECTED;
        case ERR_RST: return ZN_RESET;
        case ERR_ABRT: return ZN_ABORTED;
        case ERR_CLSD:
        case ERR_CONN: return ZN_NOT_CONNECTED;
        case ERR_TIMEOUT: return ZN_TIMED_OUT;
        case ERR_VAL:
        case ERR_ARG: return ZN_INVALID;
        default: return ZN_FAILED;
    }
}

/* The error a failed connection left, once */
int zn_socket_error(struct zn_socket *s) {
    int r = s->refused ? ZN_REFUSED : s->error != 0 ? result(s->error) : ZN_OK;
    s->error = 0;
    s->refused = 0;
    return r;
}

int zn_socket_bind(struct zn_socket *s, unsigned int ip, unsigned short port) {
    ip_addr_t a;
    ip_addr_set_ip4_u32(&a, ip);
    if (s->kind == ZN_TCP) {
        if (s->pcb.tcp == NULL || s->listening) return ZN_INVALID;
        int r = result(tcp_bind(s->pcb.tcp, &a, port));
        if (r == ZN_OK) s->bound = 1;
        return r;
    }
    int r = result(udp_bind(s->pcb.udp, &a, port));
    if (r == ZN_OK) s->bound = 1;
    return r;
}

int zn_socket_listen(struct zn_socket *s, int backlog) {
    if (s->kind != ZN_TCP || s->pcb.tcp == NULL || s->connected || s->connecting) return ZN_INVALID;
    s->backlog = (u8_t)(backlog < 1 ? 1 : backlog > ACCEPT_QUEUE ? ACCEPT_QUEUE : backlog);
    if (s->listening) return ZN_OK;
    if (!s->bound) {
        int r = result(tcp_bind(s->pcb.tcp, IP_ADDR_ANY, 0));
        if (r != ZN_OK) return r;
    }
    struct tcp_pcb *l = tcp_listen(s->pcb.tcp); /* frees the old pcb if it worked */
    if (l == NULL) return ZN_NO_MEMORY;
    s->pcb.tcp = l;
    s->listening = 1;
    tcp_arg(l, s);
    tcp_accept(l, tcp_incoming);
    return ZN_OK;
}

/* A connection that came in, or NULL (none yet) */
struct zn_socket *zn_socket_accept(struct zn_socket *s) {
    if (!s->listening || s->acc_count == 0) return NULL;
    struct zn_socket *c = s->accepted[s->acc_first];
    s->acc_first = (u8_t)((s->acc_first + 1) % ACCEPT_QUEUE);
    s->acc_count--;
    return c;
}

/* TCP: starts connecting (ZN_IN_PROGRESS); UDP: the default peer */
int zn_socket_connect(struct zn_socket *s, unsigned int ip, unsigned short port) {
    ip_addr_t a;
    ip_addr_set_ip4_u32(&a, ip);
    if (s->kind == ZN_UDP) return result(udp_connect(s->pcb.udp, &a, port));
    if (s->listening || s->pcb.tcp == NULL) return ZN_INVALID;
    if (s->connected) return ZN_IS_CONNECTED;
    if (s->connecting) return ZN_ALREADY;
    int r = result(tcp_connect(s->pcb.tcp, &a, port, tcp_connected_now));
    if (r != ZN_OK) return r;
    s->connecting = 1;
    s->bound = 1;
    return ZN_IN_PROGRESS;
}

/* A connection to this machine itself: nothing of it goes to a
   card, so zn_defer doesn't hold it
   back (the caller delivers it: zn_loop) */
static int to_self(const struct tcp_pcb *p) {
    return ip_addr_cmp(&p->local_ip, &p->remote_ip);
}

/* TCP: what fits in the send buffer now (0:
   none fits), or a ZN_ error */
int zn_socket_send(struct zn_socket *s, const void *buf, int len) {
    if (s->kind == ZN_UDP) {
        if (len > 65507) return ZN_TOO_BIG;
        struct pbuf *p = pbuf_alloc(PBUF_TRANSPORT, (u16_t)len, PBUF_RAM);
        if (p == NULL) return ZN_NO_MEMORY;
        pbuf_take(p, buf, (u16_t)len);
        err_t e = udp_send(s->pcb.udp, p);
        pbuf_free(p);
        return e == ERR_OK ? len : result(e);
    }
    if (s->pcb.tcp == NULL) return s->reset ? ZN_RESET : ZN_NOT_CONNECTED;
    if (!s->connected) return ZN_NOT_CONNECTED;
    if (s->shut_wr) return ZN_SHUT_DOWN;
    u16_t room = tcp_sndbuf(s->pcb.tcp);
    if (tcp_sndqueuelen(s->pcb.tcp) >= TCP_SND_QUEUELEN - 4) room = 0;
    int n = len < room ? len : room;
    if (n == 0) return 0;
    err_t e = tcp_write(s->pcb.tcp, buf, (u16_t)n, TCP_WRITE_FLAG_COPY);
    if (e == ERR_MEM) return 0;
    if (e != ERR_OK) return result(e);
    if (zn_defer && !to_self(s->pcb.tcp)) s->want_output = 1; else tcp_output(s->pcb.tcp);
    return n;
}

int zn_socket_send_to(struct zn_socket *s, const void *buf, int len, unsigned int ip, unsigned short port) {
    return zn_socket_send_via(s, buf, len, ip, port, -1, 0);
}

/* iface >= 0: out of that interface (a
   broadcast too), from src (0: its address) */
int zn_socket_send_via(struct zn_socket *s, const void *buf, int len, unsigned int ip, unsigned short port, int iface, unsigned int src) {
    if (s->kind != ZN_UDP) return ZN_IS_CONNECTED;
    if (iface >= iface_count) return ZN_UNREACHABLE;
    if (len > 65507) return ZN_TOO_BIG;
    struct pbuf *p = pbuf_alloc(PBUF_TRANSPORT, (u16_t)len, PBUF_RAM);
    if (p == NULL) return ZN_NO_MEMORY;
    pbuf_take(p, buf, (u16_t)len);
    ip_addr_t a, from;
    ip_addr_set_ip4_u32(&a, ip);
    ip_addr_set_ip4_u32(&from, src);
    err_t e = iface < 0 ? udp_sendto(s->pcb.udp, p, &a, port)
              : src == 0 ? udp_sendto_if(s->pcb.udp, p, &a, port, &ifaces[iface].n)
                         : udp_sendto_if_src(s->pcb.udp, p, &a, port, &ifaces[iface].n, &from);
    pbuf_free(p);
    return e == ERR_OK ? len : result(e);
}

/* TCP: bytes read (0: the peer closed), ZN_WOULD_BLOCK, or an error */
int zn_socket_recv(struct zn_socket *s, void *buf, int len, int peek) {
    if (s->kind == ZN_UDP) return zn_socket_recv_from(s, buf, len, peek, NULL, NULL);
    if (s->listening) return ZN_NOT_CONNECTED;
    if (s->rx == NULL) {
        if (s->reset && s->error != 0) return zn_socket_error(s);
        if (s->eof) return 0;
        if (!s->connected) return s->connecting ? ZN_WOULD_BLOCK : ZN_NOT_CONNECTED;
        return ZN_WOULD_BLOCK;
    }
    u16_t avail = (u16_t)(s->rx->tot_len - s->rx_off);
    u16_t n = (u16_t)(len < avail ? len : avail);
    pbuf_copy_partial(s->rx, buf, n, s->rx_off);
    if (peek) return n;
    u16_t off = (u16_t)(s->rx_off + n);
    /* Whole pbufs read go */
    while (s->rx != NULL && off >= s->rx->len) {
        struct pbuf *p = s->rx;
        off = (u16_t)(off - p->len);
        s->rx = p->next;
        if (s->rx != NULL) pbuf_ref(s->rx);
        pbuf_free(p);
    }
    s->rx_off = off;
    if (s->pcb.tcp != NULL) {
        if (zn_defer && !to_self(s->pcb.tcp)) {
            s->recved += n;
            s->want_output = 1;
        } else tcp_recved(s->pcb.tcp, n);
    }
    return n;
}

/* zn_defer: what the sockets left for the network core */
void zn_flush(void) {
    for (int i = 0; i < SOCKETS; i++) {
        struct zn_socket *s = &sockets[i];
        if (!s->used || s->kind != ZN_TCP || !s->want_output) continue;
        s->want_output = 0;
        if (s->pcb.tcp == NULL) continue;
        while (s->recved > 0) {
            u16_t n = (u16_t)(s->recved > 0xFFFF ? 0xFFFF : s->recved);
            tcp_recved(s->pcb.tcp, n);
            s->recved -= n;
        }
        tcp_output(s->pcb.tcp);
    }
}

/* Whether p is something zdos_net_wake wakes waiters of */
int zn_is_object(const void *p) {
    const char *c = (const char *)p;
    if (c >= (const char *)sockets && c < (const char *)(sockets + SOCKETS)) return 1;
    if (c >= (const char *)queries && c < (const char *)(queries + DNS_QUERIES)) return 1;
    if (c >= (const char *)pings && c < (const char *)(pings + PINGS)) return 1;
    for (int i = 0; i < iface_count; i++) {
        if (p == (const void *)&ifaces[i].n) return 1;
    }
    return 0;
}

/* UDP: one datagram (cut to len), its sender in *ip, *port */
int zn_socket_recv_from(struct zn_socket *s, void *buf, int len, int peek, unsigned int *ip, unsigned short *port) {
    return zn_socket_recv_via(s, buf, len, peek, ip, port, NULL, NULL);
}

/* And the interface it came in by (-1: the loopback, TCP) and
   the address it was sent to */
int zn_socket_recv_via(struct zn_socket *s, void *buf, int len, int peek, unsigned int *ip, unsigned short *port, int *iface, unsigned int *local) {
    if (iface != NULL) *iface = -1;
    if (local != NULL) *local = 0;
    if (s->kind != ZN_UDP) {
        int n = zn_socket_recv(s, buf, len, peek);
        if (n >= 0 && ip != NULL) zn_socket_address(s, 1, ip, port);
        return n;
    }
    if (s->dg_count == 0) return ZN_WOULD_BLOCK;
    struct datagram *d = &s->dgrams[s->dg_first];
    u16_t n = (u16_t)(len < d->p->tot_len ? len : d->p->tot_len);
    pbuf_copy_partial(d->p, buf, n, 0);
    if (ip != NULL) *ip = d->addr;
    if (port != NULL) *port = d->port;
    if (iface != NULL) *iface = d->iface;
    if (local != NULL) *local = d->local;
    if (!peek) {
        pbuf_free(d->p);
        s->dg_first = (u8_t)((s->dg_first + 1) % DATAGRAMS);
        s->dg_count--;
    }
    return n;
}

int zn_socket_shutdown(struct zn_socket *s, int rd, int wr) {
    if (s->kind != ZN_TCP) return ZN_OK;
    if (s->pcb.tcp == NULL || !s->connected) return ZN_NOT_CONNECTED;
    if (rd) {
        if (s->rx != NULL) {
            tcp_recved(s->pcb.tcp, (u16_t)(s->rx->tot_len - s->rx_off));
            pbuf_free(s->rx);
            s->rx = NULL;
            s->rx_off = 0;
        }
        s->eof = 1;
    }
    if (wr) s->shut_wr = 1;
    return result(tcp_shutdown(s->pcb.tcp, rd, wr));
}

void zn_socket_close(struct zn_socket *s) {
    if (s->kind == ZN_TCP) {
        while (s->acc_count > 0) zn_socket_close(zn_socket_accept(s));
        /* What was read (its window update perhaps still deferred) and
           what is left unread both count as taken: lwIP resets a
           connection closed with its receive window not all open, and
           the reply just sent would be lost on its way */
        u32_t taken = s->recved;
        s->recved = 0;
        if (s->rx != NULL) {
            taken += s->rx->tot_len - s->rx_off;
            pbuf_free(s->rx);
            s->rx = NULL;
        }
        struct tcp_pcb *pcb = s->pcb.tcp;
        if (pcb != NULL && !s->listening) {
            while (taken > 0) {
                u16_t n = (u16_t)(taken > 0xFFFF ? 0xFFFF : taken);
                tcp_recved(pcb, n);
                taken -= n;
            }
        }
        if (pcb != NULL) {
            tcp_arg(pcb, NULL);
            if (s->listening) {
                tcp_accept(pcb, NULL);
            } else {
                tcp_recv(pcb, NULL);
                tcp_sent(pcb, NULL);
                tcp_err(pcb, NULL);
            }
            /* Unsent data still goes out; if it can't, the connection is reset */
            if (tcp_close(pcb) != ERR_OK) tcp_abort(pcb);
        }
    } else {
        while (s->dg_count > 0) {
            pbuf_free(s->dgrams[s->dg_first].p);
            s->dg_first = (u8_t)((s->dg_first + 1) % DATAGRAMS);
            s->dg_count--;
        }
        if (s->pcb.udp != NULL) udp_remove(s->pcb.udp);
    }
    s->used = 0;
}

/* ZN_READABLE ... BITS */
int zn_socket_state(struct zn_socket *s) {
    int st = 0;
    if (s->kind == ZN_UDP) {
        if (s->dg_count > 0) st |= ZN_READABLE;
        return st | ZN_WRITABLE;
    }
    if (s->listening) return s->acc_count > 0 ? ZN_READABLE : 0;
    if (s->rx != NULL || s->eof || s->error != 0) st |= ZN_READABLE;
    if (s->eof) st |= ZN_HANGUP;
    if (s->error != 0) st |= ZN_FAILED_BIT;
    if (s->connecting) st |= ZN_CONNECTING;
    if (s->connected) {
        st |= ZN_CONNECTED_BIT;
        if (s->pcb.tcp != NULL && !s->shut_wr && tcp_sndbuf(s->pcb.tcp) > 0 &&
            tcp_sndqueuelen(s->pcb.tcp) < TCP_SND_QUEUELEN - 4) {
            st |= ZN_WRITABLE;
        }
    }
    if (s->reset) st |= ZN_WRITABLE | ZN_HANGUP; /* a write fails at once */
    return st;
}

int zn_socket_kind(struct zn_socket *s) {
    return s->kind;
}

/* peer 0: the local address; 1 if known */
int zn_socket_address(struct zn_socket *s, int peer, unsigned int *ip, unsigned short *port) {
    const ip_addr_t *a = NULL;
    u16_t p = 0;
    if (s->kind == ZN_TCP && s->pcb.tcp != NULL) {
        if (peer && !s->connected) return 0;
        a = peer ? &s->pcb.tcp->remote_ip : &s->pcb.tcp->local_ip;
        p = peer ? s->pcb.tcp->remote_port : s->pcb.tcp->local_port;
    } else if (s->kind == ZN_UDP && s->pcb.udp != NULL) {
        if (peer && (s->pcb.udp->flags & UDP_FLAGS_CONNECTED) == 0) return 0;
        a = peer ? &s->pcb.udp->remote_ip : &s->pcb.udp->local_ip;
        p = peer ? s->pcb.udp->remote_port : s->pcb.udp->local_port;
    } else {
        return 0;
    }
    /* Bound to any address: that of the interface towards the peer */
    u32_t v = ip4_addr_get_u32(ip_2_ip4(a));
    int towards = s->kind == ZN_TCP ? s->connected : (s->pcb.udp->flags & UDP_FLAGS_CONNECTED) != 0;
    if (!peer && v == 0 && towards) {
        const ip_addr_t *r = s->kind == ZN_TCP ? &s->pcb.tcp->remote_ip : &s->pcb.udp->remote_ip;
        struct netif *n = ip4_route(ip_2_ip4(r));
        if (n != NULL) v = ip4_addr_get_u32(netif_ip4_addr(n));
    }
    *ip = v;
    *port = p;
    return 1;
}

int zn_socket_option(struct zn_socket *s, int option, int value) {
    struct ip_pcb *any = s->kind == ZN_TCP ? (struct ip_pcb *)s->pcb.tcp : (struct ip_pcb *)s->pcb.udp;
    if (any == NULL) return ZN_INVALID;
    switch (option) {
        case ZN_OPT_REUSE_ADDRESS:
            if (value) ip_set_option(any, SOF_REUSEADDR); else ip_reset_option(any, SOF_REUSEADDR);
            return ZN_OK;
        case ZN_OPT_KEEPALIVE:
            if (value) ip_set_option(any, SOF_KEEPALIVE); else ip_reset_option(any, SOF_KEEPALIVE);
            return ZN_OK;
        case ZN_OPT_BROADCAST:
            if (value) ip_set_option(any, SOF_BROADCAST); else ip_reset_option(any, SOF_BROADCAST);
            return ZN_OK;
        case ZN_OPT_NO_DELAY:
            if (s->kind != ZN_TCP) return ZN_INVALID;
            if (value) tcp_nagle_disable(s->pcb.tcp); else tcp_nagle_enable(s->pcb.tcp);
            return ZN_OK;
        case ZN_OPT_TTL:
            any->ttl = (u8_t)value;
            return ZN_OK;
        default:
            return ZN_INVALID;
    }
}

/* CONNECTIONS (NETSTAT) */

/* Connection number index (TCP listening,
   active, closing, then UDP): 1 with it */
int zn_connection(int index, struct zn_conn *out) {
    struct tcp_pcb *lists[3] = {(struct tcp_pcb *)tcp_listen_pcbs.listen_pcbs, tcp_active_pcbs, tcp_tw_pcbs};
    int at = 0;
    for (int l = 0; l < 3; l++) {
        for (struct tcp_pcb *p = lists[l]; p != NULL; p = p->next) {
            if (at++ != index) continue;
            out->proto = 6;
            out->state = (u8_t)p->state;
            out->local = ip4_addr_get_u32(ip_2_ip4(&p->local_ip));
            out->local_port = p->local_port;
            if (l == 0) {
                out->remote = 0;
                out->remote_port = 0;
                out->rx_queued = 0;
                out->tx_queued = 0;
            } else {
                out->remote = ip4_addr_get_u32(ip_2_ip4(&p->remote_ip));
                out->remote_port = p->remote_port;
                struct zn_socket *s = p->callback_arg;
                out->rx_queued = s != NULL && s->rx != NULL ? (u32_t)(s->rx->tot_len - s->rx_off) : 0;
                out->tx_queued = (u32_t)(TCP_SND_BUF - p->snd_buf);
            }
            return 1;
        }
    }
    for (struct udp_pcb *u = udp_pcbs; u != NULL; u = u->next) {
        if (at++ != index) continue;
        out->proto = 17;
        out->state = 0;
        out->local = ip4_addr_get_u32(ip_2_ip4(&u->local_ip));
        out->local_port = u->local_port;
        int connected = (u->flags & UDP_FLAGS_CONNECTED) != 0;
        out->remote = connected ? ip4_addr_get_u32(ip_2_ip4(&u->remote_ip)) : 0;
        out->remote_port = connected ? u->remote_port : 0;
        out->rx_queued = 0;
        out->tx_queued = 0;
        return 1;
    }
    return 0;
}
