/* sys/socket.h: IPv4 TCP and UDP sockets on ZDOS's group "net". A socket is
 * a descriptor like a file's (zdos_fs.c): read, write, close, poll, select
 * and fcntl O_NONBLOCK work on it. */
#include "zdos.h"
#include "zdos_errno.h"
#include "zdos_internal.h"
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>

static int fail(int e) {
    errno = e;
    return -1;
}

// -1 with errno from the ZDOS call that just failed
static int fail_last(void) {
    errno = zdos_errno_from_last_error();
    return -1;
}

static int to_net(const struct sockaddr *a, socklen_t len, zdos_net_address *out) {
    if (a == NULL || len < sizeof(struct sockaddr_in)) {
        return fail(EINVAL);
    }
    if (a->sa_family != AF_INET) {
        return fail(EAFNOSUPPORT);
    }
    const struct sockaddr_in *sin = (const struct sockaddr_in *)a;
    memcpy(out->addr, &sin->sin_addr.s_addr, 4);
    out->port = ntohs(sin->sin_port);
    out->pad = 0;
    return 0;
}

// Into a, cut to *len; *len gets the whole size
static void from_net(const zdos_net_address *n, struct sockaddr *a, socklen_t *len) {
    if (a == NULL || len == NULL) {
        return;
    }
    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_port = htons(n->port);
    memcpy(&sin.sin_addr.s_addr, n->addr, 4);
    memcpy(a, &sin, *len < sizeof(sin) ? *len : sizeof(sin));
    *len = sizeof(sin);
}

int socket(int domain, int type, int protocol) {
    (void)protocol;
    if (domain != AF_INET) {
        return fail(EAFNOSUPPORT);
    }
    int kind = type & ~(SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (kind != SOCK_STREAM && kind != SOCK_DGRAM) {
        return fail(EINVAL);
    }
    int32_t h = zdos->net->socket(kind == SOCK_STREAM ? ZDOS_SOCKET_STREAM : ZDOS_SOCKET_DATAGRAM);
    if (h < 0) {
        return fail_last();
    }
    int fd = zdos_fd_for_socket(h);
    if (fd >= 0 && (type & SOCK_NONBLOCK)) {
        fcntl(fd, F_SETFL, O_NONBLOCK);
    }
    return fd;
}

int socketpair(int domain, int type, int protocol, int fds[2]) {
    (void)domain;
    (void)type;
    (void)protocol;
    (void)fds;
    return fail(EAFNOSUPPORT); /* AF_UNIX: none */
}

int bind(int fd, const struct sockaddr *addr, socklen_t len) {
    int32_t h = zdos_fd_socket(fd);
    zdos_net_address a;
    if (h < 0 || to_net(addr, len, &a) < 0) {
        return -1;
    }
    return zdos->net->bind(h, &a) ? 0 : fail_last();
}

int listen(int fd, int backlog) {
    int32_t h = zdos_fd_socket(fd);
    if (h < 0) {
        return -1;
    }
    return zdos->net->listen(h, backlog < 1 ? 1 : (uint32_t)backlog) ? 0 : fail_last();
}

int accept4(int fd, struct sockaddr *addr, socklen_t *len, int flags) {
    int32_t h = zdos_fd_socket(fd);
    if (h < 0) {
        return -1;
    }
    zdos_net_address peer;
    int32_t c = zdos->net->accept(h, &peer);
    if (c < 0) {
        return fail_last();
    }
    int n = zdos_fd_for_socket(c);
    if (n < 0) {
        return -1;
    }
    from_net(&peer, addr, len);
    if (flags & SOCK_NONBLOCK) {
        fcntl(n, F_SETFL, O_NONBLOCK);
    }
    return n;
}

int accept(int fd, struct sockaddr *addr, socklen_t *len) {
    return accept4(fd, addr, len, 0);
}

int connect(int fd, const struct sockaddr *addr, socklen_t len) {
    int32_t h = zdos_fd_socket(fd);
    zdos_net_address a;
    if (h < 0 || to_net(addr, len, &a) < 0) {
        return -1;
    }
    return zdos->net->connect(h, &a) ? 0 : fail_last();
}

static uint32_t flags_of(int flags) {
    uint32_t f = 0;
    if (flags & MSG_PEEK) f |= ZDOS_SOCKET_PEEK;
    if (flags & MSG_DONTWAIT) f |= ZDOS_SOCKET_DONT_WAIT;
    if (flags & MSG_NOSIGNAL) f |= ZDOS_SOCKET_NO_SIGNAL;
    return f;
}

ssize_t send(int fd, const void *buf, size_t len, int flags) {
    int32_t h = zdos_fd_socket(fd);
    if (h < 0) {
        return -1;
    }
    int64_t n = zdos->net->send(h, buf, len, flags_of(flags));
    return n < 0 ? fail_last() : (ssize_t)n;
}

ssize_t recv(int fd, void *buf, size_t len, int flags) {
    int32_t h = zdos_fd_socket(fd);
    if (h < 0) {
        return -1;
    }
    int64_t n = zdos->net->recv(h, buf, len, flags_of(flags));
    return n < 0 ? fail_last() : (ssize_t)n;
}

ssize_t sendto(int fd, const void *buf, size_t len, int flags, const struct sockaddr *to, socklen_t tolen) {
    if (to == NULL) {
        return send(fd, buf, len, flags);
    }
    int32_t h = zdos_fd_socket(fd);
    zdos_net_address a;
    if (h < 0 || to_net(to, tolen, &a) < 0) {
        return -1;
    }
    int64_t n = zdos->net->send_to(h, buf, len, flags_of(flags), &a);
    return n < 0 ? fail_last() : (ssize_t)n;
}

ssize_t recvfrom(int fd, void *buf, size_t len, int flags, struct sockaddr *from, socklen_t *fromlen) {
    int32_t h = zdos_fd_socket(fd);
    if (h < 0) {
        return -1;
    }
    zdos_net_address a;
    int64_t n = zdos->net->recv_from(h, buf, len, flags_of(flags), &a);
    if (n < 0) {
        return fail_last();
    }
    from_net(&a, from, fromlen);
    return (ssize_t)n;
}

// The pieces of an iovec in one buffer (sendmsg), or spread from one (recvmsg)
ssize_t sendmsg(int fd, const struct msghdr *m, int flags) {
    size_t total = 0;
    for (int i = 0; i < m->msg_iovlen; i++) total += m->msg_iov[i].iov_len;
    char *buf = malloc(total > 0 ? total : 1);
    if (buf == NULL) {
        return fail(ENOMEM);
    }
    size_t at = 0;
    for (int i = 0; i < m->msg_iovlen; i++) {
        memcpy(buf + at, m->msg_iov[i].iov_base, m->msg_iov[i].iov_len);
        at += m->msg_iov[i].iov_len;
    }
    ssize_t n = sendto(fd, buf, total, flags, m->msg_name, m->msg_namelen);
    free(buf);
    return n;
}

ssize_t recvmsg(int fd, struct msghdr *m, int flags) {
    size_t total = 0;
    for (int i = 0; i < m->msg_iovlen; i++) total += m->msg_iov[i].iov_len;
    char *buf = malloc(total > 0 ? total : 1);
    if (buf == NULL) {
        return fail(ENOMEM);
    }
    socklen_t len = m->msg_namelen;
    ssize_t n = recvfrom(fd, buf, total, flags, m->msg_name, m->msg_name != NULL ? &len : NULL);
    if (n >= 0) {
        size_t at = 0;
        for (int i = 0; i < m->msg_iovlen && at < (size_t)n; i++) {
            size_t part = m->msg_iov[i].iov_len < (size_t)n - at ? m->msg_iov[i].iov_len : (size_t)n - at;
            memcpy(m->msg_iov[i].iov_base, buf + at, part);
            at += part;
        }
        m->msg_namelen = len;
        m->msg_controllen = 0;
        m->msg_flags = 0;
    }
    free(buf);
    return n;
}

int shutdown(int fd, int how) {
    int32_t h = zdos_fd_socket(fd);
    if (h < 0) {
        return -1;
    }
    if (how < SHUT_RD || how > SHUT_RDWR) {
        return fail(EINVAL);
    }
    return zdos->net->shutdown(h, (uint32_t)how) ? 0 : fail_last();
}

static int address(int fd, bool peer, struct sockaddr *addr, socklen_t *len) {
    int32_t h = zdos_fd_socket(fd);
    if (h < 0) {
        return -1;
    }
    zdos_net_address a;
    if (!zdos->net->address(h, peer, &a)) {
        return fail_last();
    }
    from_net(&a, addr, len);
    return 0;
}

int getsockname(int fd, struct sockaddr *addr, socklen_t *len) {
    return address(fd, false, addr, len);
}

int getpeername(int fd, struct sockaddr *addr, socklen_t *len) {
    return address(fd, true, addr, len);
}

// The ZDOS option for level / name, 0 if there is none; ms: a struct timeval
static uint32_t option_of(int level, int name, bool *ms) {
    *ms = false;
    if (level == SOL_SOCKET) {
        switch (name) {
            case SO_REUSEADDR: return ZDOS_SO_REUSE_ADDRESS;
            case SO_KEEPALIVE: return ZDOS_SO_KEEPALIVE;
            case SO_BROADCAST: return ZDOS_SO_BROADCAST;
            case SO_ERROR: return ZDOS_SO_PENDING_ERROR;
            case SO_TYPE: return ZDOS_SO_TYPE;
            case SO_RCVTIMEO: *ms = true; return ZDOS_SO_RECV_TIMEOUT;
            case SO_SNDTIMEO: *ms = true; return ZDOS_SO_SEND_TIMEOUT;
        }
    } else if (level == IPPROTO_TCP && name == TCP_NODELAY) {
        return ZDOS_SO_NO_DELAY;
    } else if (level == IPPROTO_IP && name == IP_TTL) {
        return ZDOS_SO_TTL;
    }
    return 0;
}

int setsockopt(int fd, int level, int name, const void *value, socklen_t len) {
    int32_t h = zdos_fd_socket(fd);
    if (h < 0) {
        return -1;
    }
    if (level == SOL_SOCKET && (name == SO_RCVBUF || name == SO_SNDBUF)) {
        return 0; /* fixed sizes: accepted and ignored, as many systems round them anyway */
    }
    bool ms;
    uint32_t opt = option_of(level, name, &ms);
    if (opt == 0 || opt == ZDOS_SO_PENDING_ERROR || opt == ZDOS_SO_TYPE) {
        return fail(ENOPROTOOPT);
    }
    uint32_t v;
    if (ms) {
        if (len < sizeof(struct timeval)) {
            return fail(EINVAL);
        }
        const struct timeval *tv = value;
        v = (uint32_t)(tv->tv_sec * 1000 + tv->tv_usec / 1000);
    } else {
        if (len < sizeof(int)) {
            return fail(EINVAL);
        }
        v = (uint32_t)*(const int *)value;
    }
    return zdos->net->set_option(h, opt, v) ? 0 : fail_last();
}

int getsockopt(int fd, int level, int name, void *value, socklen_t *len) {
    int32_t h = zdos_fd_socket(fd);
    if (h < 0) {
        return -1;
    }
    if (level == SOL_SOCKET && (name == SO_RCVBUF || name == SO_SNDBUF)) {
        if (*len < sizeof(int)) return fail(EINVAL);
        *(int *)value = 46720; /* the TCP window and send buffer */
        *len = sizeof(int);
        return 0;
    }
    bool ms;
    uint32_t opt = option_of(level, name, &ms);
    if (opt == 0) {
        return fail(ENOPROTOOPT);
    }
    uint32_t v;
    if (!zdos->net->get_option(h, opt, &v)) {
        return fail_last();
    }
    if (ms) {
        if (*len < sizeof(struct timeval)) return fail(EINVAL);
        struct timeval *tv = value;
        tv->tv_sec = v / 1000;
        tv->tv_usec = (v % 1000) * 1000;
        *len = sizeof(struct timeval);
        return 0;
    }
    if (*len < sizeof(int)) return fail(EINVAL);
    int iv = (int)v;
    if (opt == ZDOS_SO_PENDING_ERROR) iv = v != 0 ? zdos_errno_from_code(v) : 0;
    if (opt == ZDOS_SO_TYPE) iv = v == ZDOS_SOCKET_STREAM ? SOCK_STREAM : SOCK_DGRAM;
    *(int *)value = iv;
    *len = sizeof(int);
    return 0;
}

/* INTERFACES: ifaddrs.h, net/if.h */
/* "lo" (127.0.0.1), then each card's interface as "netN" by its SYSTEM.CFG
   number (NETn=), with the address the group "net" reports */

typedef struct {
    struct ifaddrs ifa;
    struct sockaddr_in addr, mask, bcast;
    char name[IF_NAMESIZE];
} ifa_block;

static void ifa_name(char *out, unsigned number) {
    char digits[12];
    int n = 0;
    do {
        digits[n++] = (char)('0' + number % 10);
        number /= 10;
    } while (number != 0);
    memcpy(out, "net", 3);
    for (int i = 0; i < n; i++) out[3 + i] = digits[n - 1 - i];
    out[3 + n] = 0;
}

static void ifa_ipv4(struct sockaddr_in *sa, const uint8_t a[4]) {
    memset(sa, 0, sizeof(*sa));
    sa->sin_family = AF_INET;
    memcpy(&sa->sin_addr, a, 4);
}

static ifa_block *ifa_add(struct ifaddrs ***tail) {
    ifa_block *b = calloc(1, sizeof(*b));
    if (b == NULL) {
        return NULL;
    }
    b->ifa.ifa_name = b->name;
    b->ifa.ifa_addr = (struct sockaddr *)&b->addr;
    b->ifa.ifa_netmask = (struct sockaddr *)&b->mask;
    **tail = &b->ifa;
    *tail = &b->ifa.ifa_next;
    return b;
}

void freeifaddrs(struct ifaddrs *list) {
    while (list != NULL) {
        struct ifaddrs *next = list->ifa_next;
        free(list); /* ifa is its block's first member */
        list = next;
    }
}

int getifaddrs(struct ifaddrs **list) {
    struct ifaddrs *head = NULL, **tail = &head;
    ifa_block *b = ifa_add(&tail);
    if (b == NULL) {
        errno = ENOMEM;
        return -1;
    }
    static const uint8_t lo[4] = {127, 0, 0, 1}, lo_mask[4] = {255, 0, 0, 0};
    memcpy(b->name, "lo", 3);
    b->ifa.ifa_flags = IFF_UP | IFF_LOOPBACK | IFF_RUNNING;
    ifa_ipv4(&b->addr, lo);
    ifa_ipv4(&b->mask, lo_mask);
    zdos_net_info info;
    for (uint32_t i = 0; zdos != NULL && zdos->net->interface != NULL && zdos->net->interface(i, &info); i++) {
        if (!(info.flags & ZDOS_NET_STARTED)) {
            continue;
        }
        b = ifa_add(&tail);
        if (b == NULL) {
            freeifaddrs(head);
            errno = ENOMEM;
            return -1;
        }
        ifa_name(b->name, info.number);
        b->ifa.ifa_flags = IFF_UP | IFF_BROADCAST | IFF_MULTICAST | ((info.flags & ZDOS_NET_LINK) ? IFF_RUNNING : 0);
        ifa_ipv4(&b->addr, info.address);
        ifa_ipv4(&b->mask, info.netmask);
        uint8_t bc[4];
        for (int k = 0; k < 4; k++) bc[k] = (uint8_t)(info.address[k] | ~info.netmask[k]);
        ifa_ipv4(&b->bcast, bc);
        b->ifa.ifa_broadaddr = (struct sockaddr *)&b->bcast;
    }
    *list = head;
    return 0;
}

unsigned if_nametoindex(const char *name) {
    if (strcmp(name, "lo") == 0) {
        return 1;
    }
    zdos_net_info info;
    char own[IF_NAMESIZE];
    for (uint32_t i = 0; zdos != NULL && zdos->net->interface != NULL && zdos->net->interface(i, &info); i++) {
        ifa_name(own, info.number);
        if ((info.flags & ZDOS_NET_STARTED) && strcmp(own, name) == 0) {
            return (unsigned)info.number + 2;
        }
    }
    errno = ENXIO;
    return 0;
}

char *if_indextoname(unsigned index, char *name) {
    if (index == 1) {
        memcpy(name, "lo", 3);
        return name;
    }
    zdos_net_info info;
    for (uint32_t i = 0; index >= 2 && zdos != NULL && zdos->net->interface != NULL && zdos->net->interface(i, &info); i++) {
        if ((info.flags & ZDOS_NET_STARTED) && (unsigned)info.number + 2 == index) {
            ifa_name(name, info.number);
            return name;
        }
    }
    errno = ENXIO;
    return NULL;
}
