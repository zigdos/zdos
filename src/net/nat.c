/* NAT (masquerading) for NAT=: packets forwarded out of an
   outside interface take its address and a port (ICMP echo: an
   identifier) of ours, and the answers are mapped back by it.
   FORWARD= sends a port of ours to an inside machine.
   Called from lwIP's forwarding (zn_forward_hook) and input
   (LWIP_HOOK_IP4_INPUT), under the
   network lock like the rest of lwIP. */
#include <string.h>
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/ip4.h"
#include "lwip/ip4_frag.h"
#include "lwip/inet_chksum.h"
#include "lwip/udp.h"
#include "lwip/priv/tcp_priv.h"
#include "lan.h"

#define ENTRIES 1024
#define FORWARDS 16
#define OUTSIDES 8
/* Our ports: below lwIP's own (0xC000 ...), so they don't meet */
#define PORT_FIRST 0x8000
#define PORT_COUNT 0x4000

#define P_ICMP 1
#define P_TCP 6
#define P_UDP 17

/* TCP: what was seen of the connection, for its time-out */
enum { T_REPLIED = 1, T_FIN_OUT = 2, T_FIN_IN = 4, T_RST = 8 };

struct entry {
    u8_t used, proto, tcp;
    u8_t inside[4], remote[4]; /* as in the packets */
    u16_t inside_port, remote_port, port; /* ICMP: identifiers, remote_port 0 */
    struct netif *out;
    u32_t last;
};

static struct entry entries[ENTRIES];
static struct netif *outsides[OUTSIDES];
static int outside_count;
static struct {
    u8_t proto;
    u16_t port, to_port;
    u8_t to[4];
} forwards[FORWARDS];
static int forward_count;
static u16_t next_port;

int zn_nat_enable(int iface) {
    struct netif *n = zn_netif(iface);
    if (n == NULL || outside_count == OUTSIDES) return 0;
    outsides[outside_count++] = n;
    return 1;
}

int zn_nat_forward(int proto, unsigned short port, unsigned int to, unsigned short to_port) {
    if (forward_count == FORWARDS) return 0;
    forwards[forward_count].proto = (u8_t)proto;
    forwards[forward_count].port = port;
    forwards[forward_count].to_port = to_port;
    memcpy(forwards[forward_count].to, &to, 4);
    forward_count++;
    return 1;
}

int zn_nat_on(struct netif *n) {
    for (int i = 0; i < outside_count; i++) {
        if (outsides[i] == n) return 1;
    }
    return 0;
}

/* Live entries (NETSTAT-like counts, tests) */
int zn_nat_entries(void) {
    int k = 0;
    for (int i = 0; i < ENTRIES; i++) k += entries[i].used;
    return k;
}

/* CHECKSUMS: CHANGED IN PLACE (RFC 1624) */

static u16_t rd16(const u8_t *p) {
    return (u16_t)(p[0] << 8 | p[1]);
}

static void wr16(u8_t *p, u16_t v) {
    p[0] = (u8_t)(v >> 8);
    p[1] = (u8_t)v;
}

static void fix16(u8_t *sum, u16_t old, u16_t new) {
    u32_t s = (u32_t)(u16_t)~rd16(sum) + (u16_t)~old + new;
    s = (s & 0xFFFF) + (s >> 16);
    s = (s & 0xFFFF) + (s >> 16);
    wr16(sum, (u16_t)~s);
}

static void fix32(u8_t *sum, const u8_t *old, const u8_t *new) {
    fix16(sum, rd16(old), rd16(new));
    fix16(sum, rd16(old + 2), rd16(new + 2));
}

/* An address at a (IP header field) becomes to;
   sums that cover it follow */
static void set_addr(u8_t *a, const u8_t *to, u8_t *ip_sum, u8_t *l4_sum, int udp) {
    int l4 = l4_sum != NULL && !(udp && rd16(l4_sum) == 0); /* UDP: 0 is none */
    if (ip_sum != NULL) fix32(ip_sum, a, to);
    if (l4) fix32(l4_sum, a, to);
    if (l4 && udp && rd16(l4_sum) == 0) wr16(l4_sum, 0xFFFF);
    memcpy(a, to, 4);
}

static void set_port(u8_t *at, u16_t to, u8_t *l4_sum, int udp) {
    if (l4_sum != NULL && !(udp && rd16(l4_sum) == 0)) {
        fix16(l4_sum, rd16(at), to);
        if (udp && rd16(l4_sum) == 0) wr16(l4_sum, 0xFFFF);
    }
    wr16(at, to);
}

static u32_t lifetime(const struct entry *e) {
    if (e->proto == P_TCP) {
        if ((e->tcp & T_RST) || (e->tcp & (T_FIN_OUT | T_FIN_IN)) == (T_FIN_OUT | T_FIN_IN)) return 10 * 1000;
        if (!(e->tcp & T_REPLIED) || (e->tcp & (T_FIN_OUT | T_FIN_IN))) return 240 * 1000;
        return 7440 * 1000; /* RFC 5382: 2 h 4 min at least */
    }
    return e->proto == P_UDP ? 180 * 1000 : 30 * 1000;
}

static int live(struct entry *e, u32_t now) {
    if (e->used && now - e->last > lifetime(e)) e->used = 0;
    return e->used;
}

static int forwarded_port(u8_t proto, u16_t port) {
    for (int i = 0; i < forward_count; i++) {
        if (forwards[i].proto == proto && forwards[i].port == port) return 1;
    }
    return 0;
}

/* One of lwIP's own sockets has the
   port (the router's own connections) */
static int local_port(u8_t proto, u16_t port) {
    if (proto == P_UDP) {
        for (struct udp_pcb *u = udp_pcbs; u != NULL; u = u->next) {
            if (u->local_port == port) return 1;
        }
    } else if (proto == P_TCP) {
        struct tcp_pcb *lists[] = {tcp_active_pcbs, tcp_tw_pcbs, tcp_bound_pcbs};
        for (int l = 0; l < 3; l++) {
            for (struct tcp_pcb *t = lists[l]; t != NULL; t = t->next) {
                if (t->local_port == port) return 1;
            }
        }
        for (struct tcp_pcb_listen *t = tcp_listen_pcbs.listen_pcbs; t != NULL; t = t->next) {
            if (t->local_port == port) return 1;
        }
    }
    return 0;
}

static int port_free(u8_t proto, struct netif *out, u16_t port, u32_t now) {
    for (int i = 0; i < ENTRIES; i++) {
        struct entry *e = &entries[i];
        if (e->used && e->proto == proto && e->port == port && e->out == out && live(e, now)) return 0;
    }
    return !forwarded_port(proto, port) && !local_port(proto, port);
}

/* A free slot: an unused or timed-out
   one, else the one quiet longest */
static struct entry *new_entry(u32_t now) {
    struct entry *old = &entries[0];
    for (int i = 0; i < ENTRIES; i++) {
        struct entry *e = &entries[i];
        if (!live(e, now)) return e;
        if (now - e->last > now - old->last) old = e;
    }
    old->used = 0;
    return old;
}

static struct entry *find_out(u8_t proto, struct netif *out, const u8_t *inside, u16_t iport, const u8_t *remote, u16_t rport, u32_t now) {
    for (int i = 0; i < ENTRIES; i++) {
        struct entry *e = &entries[i];
        if (e->used && e->proto == proto && e->out == out && e->inside_port == iport && e->remote_port == rport &&
            memcmp(e->inside, inside, 4) == 0 && memcmp(e->remote, remote, 4) == 0 && live(e, now)) {
            return e;
        }
    }
    return NULL;
}

static struct entry *find_in(u8_t proto, struct netif *in, u16_t port, const u8_t *remote, u16_t rport, u32_t now) {
    for (int i = 0; i < ENTRIES; i++) {
        struct entry *e = &entries[i];
        if (e->used && e->proto == proto && e->out == in && e->port == port && e->remote_port == rport &&
            memcmp(e->remote, remote, 4) == 0 && live(e, now)) {
            return e;
        }
    }
    return NULL;
}

static struct entry *add(u8_t proto, struct netif *out, const u8_t *inside, u16_t iport, const u8_t *remote, u16_t rport, int port, u32_t now) {
    if (port < 0) {
        for (int k = 0; k < PORT_COUNT && port < 0; k++) {
            u16_t p = (u16_t)(PORT_FIRST + next_port);
            next_port = (u16_t)((next_port + 1) % PORT_COUNT);
            if (port_free(proto, out, p, now)) port = p;
        }
        if (port < 0) return NULL;
    }
    struct entry *e = new_entry(now);
    memset(e, 0, sizeof(*e));
    e->used = 1;
    e->proto = proto;
    e->out = out;
    memcpy(e->inside, inside, 4);
    memcpy(e->remote, remote, 4);
    e->inside_port = iport;
    e->remote_port = rport;
    e->port = (u16_t)port;
    e->last = now;
    return e;
}

#define IP_SRC 12
#define IP_DST 16
#define IP_SUM 10

static u16_t l4_need(u8_t proto) {
    return proto == P_TCP ? 20 : 8;
}

static u8_t *l4_sum(u8_t proto, u8_t *l4) {
    return proto == P_TCP ? l4 + 16 : proto == P_UDP ? l4 + 6 : l4 + 2;
}

/* Forwarded out of `out`: 1 sends it, 0 drops it (no port left,
   headers not in the first buffer) */
int zn_nat_out(struct pbuf *p, struct netif *in, struct netif *out) {
    if (outside_count == 0 || in == out || !zn_nat_on(out)) return 1;
    u8_t *ip = (u8_t *)p->payload;
    u16_t hlen = (u16_t)((ip[0] & 15) * 4);
    const u8_t *ours = (const u8_t *)netif_ip4_addr(out);
    if (ip4_addr_isany_val(*netif_ip4_addr(out)) || memcmp(ip + IP_SRC, ours, 4) == 0) return 1;
    u8_t proto = ip[9];
    int first = (rd16(ip + 6) & 0x1FFF) == 0;
    u32_t now = sys_now();
    struct entry *e = NULL;
    u8_t *l4 = ip + hlen;
    if (first && (proto == P_TCP || proto == P_UDP || (proto == P_ICMP && p->len >= hlen + 8 && l4[0] == 8))) {
        if (p->len < hlen + l4_need(proto)) return 0;
        int icmp = proto == P_ICMP;
        u16_t iport = icmp ? rd16(l4 + 4) : rd16(l4);
        u16_t rport = icmp ? 0 : rd16(l4 + 2);
        e = find_out(proto, out, ip + IP_SRC, iport, ip + IP_DST, rport, now);
        if (e == NULL) e = add(proto, out, ip + IP_SRC, iport, ip + IP_DST, rport, -1, now);
        if (e == NULL) return 0;
        e->last = now;
        if (proto == P_TCP) {
            u8_t flags = l4[13];
            if ((flags & 0x12) == 0x02) e->tcp = 0; /* a new SYN: a new connection on the same ports */
            if (flags & 0x01) e->tcp |= T_FIN_OUT;
            if (flags & 0x04) e->tcp |= T_RST;
        }
        u8_t *sum = l4_sum(proto, l4);
        set_port(icmp ? l4 + 4 : l4, e->port, sum, proto == P_UDP);
        set_addr(ip + IP_SRC, ours, ip + IP_SUM, icmp ? NULL : sum, proto == P_UDP);
        return 1;
    }
    /* Later fragments, other protocols, other ICMP: the address alone */
    set_addr(ip + IP_SRC, ours, ip + IP_SUM, NULL, 0);
    return 1;
}

/* An ICMP error about a packet of ours (the original header and
   8 bytes or more of it follow): to the
   inside machine that sent that packet */
static void icmp_error_in(struct pbuf *p, struct netif *in, u8_t *ip, u16_t hlen, u16_t len, u32_t now) {
    u8_t *icmp = ip + hlen;
    u8_t *orig = icmp + 8;
    if (len < hlen + 8 + 20 || p->len < len) return;
    u16_t ohlen = (u16_t)((orig[0] & 15) * 4);
    u8_t oproto = orig[9];
    u8_t *ol4 = orig + ohlen;
    u16_t quoted = (u16_t)(len - (ol4 - ip));
    if (ohlen < 20 || len < (ol4 - ip) + 8 || (rd16(orig + 6) & 0x1FFF) != 0) return;
    if (memcmp(orig + IP_SRC, netif_ip4_addr(in), 4) != 0) return;
    int oicmp = oproto == P_ICMP;
    if (!(oproto == P_TCP || oproto == P_UDP || (oicmp && ol4[0] == 8))) return;
    struct entry *e = find_in(oproto, in, oicmp ? rd16(ol4 + 4) : rd16(ol4), orig + IP_DST, oicmp ? 0 : rd16(ol4 + 2), now);
    if (e == NULL) return;
    /* The original's sum, if it is in the quoted part */
    u8_t *osum = oproto == P_TCP ? (quoted >= 18 ? ol4 + 16 : NULL) : l4_sum(oproto, ol4);
    set_port(oicmp ? ol4 + 4 : ol4, e->inside_port, osum, oproto == P_UDP);
    set_addr(orig + IP_SRC, e->inside, orig + IP_SUM, oicmp ? NULL : osum, oproto == P_UDP);
    set_addr(ip + IP_DST, e->inside, ip + IP_SUM, NULL, 0);
    /* The ICMP sum covers all of it: anew */
    wr16(icmp + 2, 0);
    u16_t s = inet_chksum(icmp, (u16_t)(len - hlen));
    memcpy(icmp + 2, &s, 2);
}

/* LWIP_HOOK_IP4_INPUT: answers to our ports become the inside
   machine's (lwIP then forwards them); 1
   when the packet was taken (fragments) */
int zn_nat_in(struct pbuf *p, struct netif *in) {
    if (outside_count == 0 || !zn_nat_on(in) || p->len < 20) return 0;
    u8_t *ip = (u8_t *)p->payload;
    u16_t hlen = (u16_t)((ip[0] & 15) * 4);
    u16_t len = rd16(ip + 2);
    if (hlen < 20 || p->len < hlen || len < hlen || len > p->tot_len) return 0;
    if (memcmp(ip + IP_DST, netif_ip4_addr(in), 4) != 0) return 0;
    if (len < p->tot_len) pbuf_realloc(p, len);
    if (rd16(ip + 6) & 0x3FFF) {
        /* A fragment: whole first (the ports
           are in the first one), then in again */
        if (inet_chksum(ip, hlen) != 0) return 0;
        struct pbuf *whole = ip4_reass(p);
        if (whole != NULL) ip4_input(whole, in);
        return 1;
    }
    u8_t proto = ip[9];
    u8_t *l4 = ip + hlen;
    u32_t now = sys_now();
    if (p->len < hlen + l4_need(proto)) return 0;
    if (proto == P_ICMP) {
        if (l4[0] == 3 || l4[0] == 11 || l4[0] == 12) {
            icmp_error_in(p, in, ip, hlen, len, now);
            return 0;
        }
        if (l4[0] != 0) return 0; /* echo replies only */
        struct entry *e = find_in(P_ICMP, in, rd16(l4 + 4), ip + IP_SRC, 0, now);
        if (e == NULL) return 0;
        e->last = now;
        set_port(l4 + 4, e->inside_port, l4 + 2, 0);
        set_addr(ip + IP_DST, e->inside, ip + IP_SUM, NULL, 0);
        return 0;
    }
    if (proto != P_TCP && proto != P_UDP) return 0;
    u16_t port = rd16(l4 + 2), rport = rd16(l4);
    struct entry *e = find_in(proto, in, port, ip + IP_SRC, rport, now);
    if (e == NULL) {
        int f = 0;
        while (f < forward_count && !(forwards[f].proto == proto && forwards[f].port == port)) f++;
        if (f == forward_count) return 0; /* the router's own */
        e = add(proto, in, forwards[f].to, forwards[f].to_port, ip + IP_SRC, rport, port, now);
        if (e == NULL) return 0;
    }
    e->last = now;
    if (proto == P_TCP) {
        u8_t flags = l4[13];
        if ((flags & 0x12) == 0x02) e->tcp = 0; /* FORWARD=: a new connection */
        e->tcp |= T_REPLIED;
        if (flags & 0x01) e->tcp |= T_FIN_IN;
        if (flags & 0x04) e->tcp |= T_RST;
    }
    u8_t *sum = l4_sum(proto, l4);
    set_port(l4 + 2, e->inside_port, sum, proto == P_UDP);
    set_addr(ip + IP_DST, e->inside, ip + IP_SUM, sum, proto == P_UDP);
    return 0;
}
