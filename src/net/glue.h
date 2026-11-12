/* glue.c's interface; net.zig mirrors it (change both together) */
#ifndef ZDOS_NET_GLUE_H
#define ZDOS_NET_GLUE_H

/* Addresses as lwIP keeps them: network byte order in a 32-bit word */
#define ZN_CARDS 8  /* cards, and interfaces */
#define ZN_ROUTES 16

/* An interface: one card, or a bridge
   of several (its ports: card numbers) */
struct zn_setup {
    unsigned char mac[6];
    unsigned char dhcp;
    unsigned char link_up;
    unsigned int ip, mask, gateway;
    unsigned char ports[ZN_CARDS];
    unsigned char port_count;
    unsigned char pad[3];
};

struct zn_config {
    unsigned int ip, mask, gateway;
    unsigned int dns[8];
    unsigned int lease_s, dhcp_server;
    unsigned char mac[6];
    unsigned char link_up, dhcp, dhcp_bound;
    unsigned char is_default; /* the default route goes out here */
    unsigned char pad[2];
};

struct zn_ping {
    unsigned int rtt, from;
    unsigned short bytes;
    unsigned char ttl;
    unsigned char pad;
};

enum { ZN_PING_WAITING = 1, ZN_PING_REPLY, ZN_PING_UNREACHABLE, ZN_PING_TTL_EXPIRED };

struct zn_conn {
    unsigned int local, remote;
    unsigned short local_port, remote_port;
    unsigned int rx_queued, tx_queued;
    unsigned char proto; /* 6 TCP, 17 UDP */
    unsigned char state; /* TCP: lwIP's enum tcp_state */
    unsigned char pad[2];
};

enum { ZN_TCP = 1, ZN_UDP = 2 };

/* Results of the socket operations: >=
   0 success (a count where one is due) */
enum {
    ZN_OK = 0,
    ZN_WOULD_BLOCK = -1,
    ZN_IN_PROGRESS = -2,
    ZN_ALREADY = -3,
    ZN_NO_MEMORY = -4,
    ZN_IN_USE = -5,
    ZN_UNREACHABLE = -6,
    ZN_IS_CONNECTED = -7,
    ZN_NOT_CONNECTED = -8,
    ZN_RESET = -9,
    ZN_ABORTED = -10,
    ZN_TIMED_OUT = -11,
    ZN_INVALID = -12,
    ZN_SHUT_DOWN = -13,
    ZN_TOO_BIG = -14,
    ZN_FAILED = -15,
    ZN_REFUSED = -16,
};

/* zn_socket_state bits */
enum {
    ZN_READABLE = 1,
    ZN_WRITABLE = 2,
    ZN_HANGUP = 4,
    ZN_FAILED_BIT = 8,
    ZN_CONNECTING = 16,
    ZN_CONNECTED_BIT = 32,
};

enum { ZN_OPT_REUSE_ADDRESS = 1, ZN_OPT_KEEPALIVE, ZN_OPT_BROADCAST, ZN_OPT_NO_DELAY, ZN_OPT_TTL };

struct zn_socket;

void zn_start(const unsigned int dns[8], int forwarding);
int zn_add(const struct zn_setup *s);
void zn_link(int card, int up);
void zn_input(int card, const void *frame, size_t len);
void zn_flush(void);
int zn_loop_waiting(void);
int zn_loop(void);
int zn_is_object(const void *p);
extern int zn_defer;
void zn_timers(void);
unsigned int zn_sleeptime(void);
int zn_config(int iface, struct zn_config *c);
const void *zn_interface(int iface);
void zn_dhcp_renew(int iface);
void zn_dhcp_release(int iface);
int zn_route_add(unsigned int dest, unsigned int mask, unsigned int gateway);
int zn_route_entry(int i, unsigned int *dest, unsigned int *mask, unsigned int *gateway, int *iface);

int zn_dns_start(const char *name);
const void *zn_dns_object(int q);
int zn_dns_result(int q, unsigned int *addr);
void zn_dns_end(int q);

int zn_ping_send(unsigned int dst, unsigned short id, unsigned short seq, unsigned short size, unsigned char ttl);
const void *zn_ping_object(int n);
int zn_ping_result(int n, struct zn_ping *out);
void zn_ping_end(int n);

int zn_arp_entry(int i, unsigned int *ip, unsigned char mac[6], int *is_static);
int zn_arp_size(void);
int zn_arp_add(unsigned int ip, const unsigned char mac[6]);
int zn_arp_remove(unsigned int ip);
void zn_arp_clear(void);

struct zn_socket *zn_socket_new(int kind);
int zn_socket_error(struct zn_socket *s);
int zn_socket_bind(struct zn_socket *s, unsigned int ip, unsigned short port);
int zn_socket_listen(struct zn_socket *s, int backlog);
struct zn_socket *zn_socket_accept(struct zn_socket *s);
int zn_socket_connect(struct zn_socket *s, unsigned int ip, unsigned short port);
int zn_socket_send(struct zn_socket *s, const void *buf, int len);
int zn_socket_send_to(struct zn_socket *s, const void *buf, int len, unsigned int ip, unsigned short port);
int zn_socket_recv(struct zn_socket *s, void *buf, int len, int peek);
int zn_socket_recv_from(struct zn_socket *s, void *buf, int len, int peek, unsigned int *ip, unsigned short *port);
int zn_socket_send_via(struct zn_socket *s, const void *buf, int len, unsigned int ip, unsigned short port, int iface, unsigned int src);
int zn_socket_recv_via(struct zn_socket *s, void *buf, int len, int peek, unsigned int *ip, unsigned short *port, int *iface, unsigned int *local);
int zn_socket_shutdown(struct zn_socket *s, int rd, int wr);
void zn_socket_close(struct zn_socket *s);
int zn_socket_state(struct zn_socket *s);
int zn_socket_kind(struct zn_socket *s);
int zn_socket_address(struct zn_socket *s, int peer, unsigned int *ip, unsigned short *port);
int zn_socket_option(struct zn_socket *s, int option, int value);

int zn_connection(int index, struct zn_conn *out);

#endif
