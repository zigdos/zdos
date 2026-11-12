/* NATTEST: nat-tests.py's test program. Exit code: failures.
 *   NATTEST serve SECONDS [LOG [dns]]  TCP 7000, UDP 7001 (and DNS 53)
 *   NATTEST client HOST N [PORT]       N TCP connections, 10 datagrams
 *   NATTEST dns SERVER                 the DNS cache test's queries
 *   NATTEST chmod FILE...              mode 0755 */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define BULK 32768

static unsigned char bulk[BULK];

static struct sockaddr_in at(const char *host, int port) {
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    inet_pton(AF_INET, host, &a.sin_addr);
    return a;
}

static void peer_text(const struct sockaddr_in *a, char *out, size_t cap) {
    char ip[16];
    inet_ntop(AF_INET, &a->sin_addr, ip, sizeof(ip));
    snprintf(out, cap, "%s:%d", ip, ntohs(a->sin_port));
}

static void log_line(const char *log, const char *kind, const char *peer) {
    if (log == NULL) return;
    FILE *f = fopen(log, "a");
    if (f == NULL) return;
    fprintf(f, "%s %s\n", kind, peer);
    fclose(f);
}

/* DNS */

static unsigned short get16(const unsigned char *p) {
    return (unsigned short)(p[0] << 8 | p[1]);
}

static unsigned char *put16(unsigned char *p, unsigned v) {
    p[0] = (unsigned char)(v >> 8);
    p[1] = (unsigned char)v;
    return p + 2;
}

static unsigned char *put32(unsigned char *p, unsigned long v) {
    return put16(put16(p, (unsigned)(v >> 16)), (unsigned)(v & 0xFFFF));
}

/* Lower case, and where the question ends; 0 bad */
static int qname(const unsigned char *m, int len, char *name) {
    int at = 12, n = 0;
    while (at < len && m[at] != 0) {
        int l = m[at];
        if (l > 63 || at + 1 + l >= len || n + l + 2 > 255) return 0;
        if (n) name[n++] = '.';
        for (int k = 0; k < l; k++) {
            char c = (char)m[at + 1 + k];
            name[n++] = c >= 'A' && c <= 'Z' ? (char)(c + 32) : c;
        }
        at += 1 + l;
    }
    name[n] = 0;
    return at + 5 <= len ? at + 5 : 0;
}

/* The fake upstream: far.test, short.test (TTL 2), nx.test NXDOMAIN,
 * else SERVFAIL */
static int dns_answer(const unsigned char *m, int len, unsigned char *out, const char *log) {
    char name[256];
    int qend = qname(m, len, name);
    if (len < 12 || qend == 0) return 0;
    unsigned type = get16(m + qend - 4);
    char line[300];
    snprintf(line, sizeof(line), "%s %u", name, type);
    log_line(log, "DNS", line);
    memcpy(out, m, (size_t)qend);
    out[2] = (unsigned char)(0x84 | (m[2] & 1)); /* QR, AA, RD */
    out[3] = 0x80;
    put16(out + 6, 0);
    put16(out + 8, 0);
    put16(out + 10, 0);
    unsigned char *o = out + qend;
    int far = strcmp(name, "far.test") == 0, shrt = strcmp(name, "short.test") == 0;
    if ((far || shrt) && type == 1) {
        put16(out + 6, 1);
        o = put16(o, 0xC00C);
        o = put16(o, 1);
        o = put16(o, 1);
        o = put32(o, far ? 300 : 2);
        o = put16(o, 4);
        static const unsigned char a[2][4] = {{192, 168, 20, 10}, {192, 168, 20, 11}};
        memcpy(o, a[shrt], 4);
        o += 4;
    } else if (far || shrt || strcmp(name, "nx.test") == 0) {
        /* No data (other types), or NXDOMAIN: an SOA, minimum 300: */
        if (!far && !shrt) out[3] |= 3;
        put16(out + 8, 1);
        o = put16(o, 0xC00C);
        o = put16(o, 6);
        o = put16(o, 1);
        o = put32(o, 600);
        o = put16(o, 2 + 2 + 20);
        o = put16(o, 0xC00C);
        o = put16(o, 0xC00C);
        o = put32(o, 1);
        o = put32(o, 3600);
        o = put32(o, 600);
        o = put32(o, 86400);
        o = put32(o, far ? 300 : 3);
    } else {
        out[3] |= 2; /* SERVFAIL */
    }
    return (int)(o - out);
}

static int serve(int seconds, const char *log, int dns) {
    int one = 1;
    int l = socket(AF_INET, SOCK_STREAM, 0), u = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in any = at("0.0.0.0", 7000), anyu = at("0.0.0.0", 7001);
    setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (bind(l, (struct sockaddr *)&any, sizeof(any)) != 0 || listen(l, 16) != 0 || bind(u, (struct sockaddr *)&anyu, sizeof(anyu)) != 0) {
        printf("serve: can't listen\n");
        return 1;
    }
    int d = -1;
    if (dns) {
        struct sockaddr_in a53 = at("0.0.0.0", 53);
        d = socket(AF_INET, SOCK_DGRAM, 0);
        if (bind(d, (struct sockaddr *)&a53, sizeof(a53)) != 0) {
            printf("serve: can't take UDP 53\n");
            return 1;
        }
    }
    printf("serving %d s\n", seconds);
    time_t end = time(NULL) + seconds;
    int tcp = 0, udp = 0;
    while (time(NULL) < end) {
        struct pollfd p[3] = {{l, POLLIN, 0}, {u, POLLIN, 0}, {d, POLLIN, 0}};
        if (poll(p, d >= 0 ? 3 : 2, 500) <= 0) continue;
        if (d >= 0 && (p[2].revents & POLLIN)) {
            struct sockaddr_in from;
            socklen_t fl = sizeof(from);
            unsigned char q[512], a[512];
            ssize_t k = recvfrom(d, q, sizeof(q), 0, (struct sockaddr *)&from, &fl);
            int n = k > 0 ? dns_answer(q, (int)k, a, log) : 0;
            if (n > 0) sendto(d, a, (size_t)n, 0, (struct sockaddr *)&from, fl);
        }
        char peer[32], line[64];
        if (p[0].revents & POLLIN) {
            struct sockaddr_in from;
            socklen_t fl = sizeof(from);
            int c = accept(l, (struct sockaddr *)&from, &fl);
            if (c >= 0) {
                peer_text(&from, peer, sizeof(peer));
                int n = snprintf(line, sizeof(line), "PEER %s\n", peer);
                send(c, line, (size_t)n, 0);
                size_t sent = 0;
                while (sent < BULK) {
                    ssize_t k = send(c, bulk + sent, BULK - sent, 0);
                    if (k <= 0) break;
                    sent += (size_t)k;
                }
                close(c);
                log_line(log, "TCP", peer);
                tcp++;
            }
        }
        if (p[1].revents & POLLIN) {
            struct sockaddr_in from;
            socklen_t fl = sizeof(from);
            char data[256];
            ssize_t k = recvfrom(u, data, sizeof(data), 0, (struct sockaddr *)&from, &fl);
            if (k >= 0) {
                peer_text(&from, peer, sizeof(peer));
                int n = snprintf(line, sizeof(line), "PEER %s", peer);
                sendto(u, line, (size_t)n, 0, (struct sockaddr *)&from, fl);
                log_line(log, "UDP", peer);
                udp++;
            }
        }
    }
    printf("served %d TCP, %d UDP\n", tcp, udp);
    return 0;
}

/* The peer line and BULK bytes; 1 if all came */
static int finish(int s, char *seen, size_t cap) {
    char buf[4096];
    size_t got = 0, line = 0;
    char head[64];
    for (;;) {
        struct pollfd p = {s, POLLIN, 0};
        if (poll(&p, 1, 10000) <= 0) break;
        ssize_t k = recv(s, buf, sizeof(buf), 0);
        if (k <= 0) break;
        for (ssize_t i = 0; i < k; i++) {
            if (line < sizeof(head) && (line == 0 || head[line - 1] != '\n')) {
                head[line++] = buf[i];
            } else {
                if ((unsigned char)buf[i] != bulk[got % BULK]) return 0;
                got++;
            }
        }
    }
    close(s);
    if (line < 6 || head[line - 1] != '\n') return 0;
    head[line - 1] = 0;
    snprintf(seen, cap, "%s", head + 5);
    return got == BULK;
}

static double ms_now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

/* "NAME TYPE: rcode R, N answers, ADDRESS ttl T, id ok, M ms" */
static void dns_query(const char *server, const char *name, unsigned type) {
    unsigned char q[300], a[512];
    unsigned id = (unsigned)rand() & 0xFFFF;
    unsigned char *o = put16(q, id);
    o = put16(o, 0x0100); /* RD */
    o = put16(o, 1);
    o = put16(o, 0);
    o = put16(o, 0);
    o = put16(o, 0);
    for (const char *p = name; *p;) {
        const char *dot = strchr(p, '.');
        size_t l = dot ? (size_t)(dot - p) : strlen(p);
        *o++ = (unsigned char)l;
        memcpy(o, p, l);
        o += l;
        p += l + (dot != NULL);
    }
    *o++ = 0;
    o = put16(o, type);
    o = put16(o, 1);
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in to = at(server, 53);
    double t0 = ms_now();
    sendto(s, q, (size_t)(o - q), 0, (struct sockaddr *)&to, sizeof(to));
    struct pollfd p = {s, POLLIN, 0};
    ssize_t k = poll(&p, 1, 5000) > 0 ? recv(s, a, sizeof(a), 0) : -1;
    double ms = ms_now() - t0;
    close(s);
    if (k < 12) {
        printf("%s %u: no answer\n", name, type);
        return;
    }
    char qn[256];
    int at_ = qname(a, (int)k, qn), ancount = get16(a + 6);
    char addr[32] = "-";
    unsigned long ttl = 0;
    if (at_ > 0 && ancount > 0 && at_ + 16 <= k && get16(a + at_ + 2) == 1) {
        const unsigned char *r = a + at_;
        ttl = (unsigned long)get16(r + 6) << 16 | get16(r + 8);
        snprintf(addr, sizeof(addr), "%u.%u.%u.%u", r[12], r[13], r[14], r[15]);
    } else if (at_ > 0 && get16(a + 8) > 0 && at_ + 10 <= k) {
        const unsigned char *r = a + at_; /* the SOA's TTL */
        ttl = (unsigned long)get16(r + 6) << 16 | get16(r + 8);
    }
    /* The question as we wrote it, in its case: */
    int same = k >= o - q && memcmp(a + 12, q + 12, (size_t)(o - q - 12)) == 0;
    printf("%s %u: rcode %d, %d answers, %s ttl %lu, id %s, question %s, %.0f ms\n", name, type, a[3] & 15, ancount,
           addr, ttl, get16(a) == id ? "ok" : "wrong", same ? "ok" : "wrong", ms);
}

static void pause_ms(int ms) {
    struct timespec t = {ms / 1000, (ms % 1000) * 1000000L};
    nanosleep(&t, NULL);
}

/* As nat-tests.py checks it, with the counts the fake upstream logs */
static int dns_test(const char *server) {
    srand((unsigned)time(NULL));
    dns_query(server, "far.test", 1);
    dns_query(server, "FAR.Test", 1);   /* the cache, any case */
    dns_query(server, "far.test", 28);  /* AAAA: no data, its own entry */
    dns_query(server, "far.test", 28);
    dns_query(server, "short.test", 1); /* TTL 2 */
    dns_query(server, "short.test", 1);
    dns_query(server, "nx.test", 1);    /* NXDOMAIN, SOA minimum 3 */
    dns_query(server, "nx.test", 1);
    dns_query(server, "fail.test", 1);  /* SERVFAIL: not kept */
    dns_query(server, "fail.test", 1);
    pause_ms(4000);
    dns_query(server, "short.test", 1); /* gone: asked again */
    dns_query(server, "nx.test", 1);
    dns_query(server, "far.test", 1);   /* still there, its TTL lower */
    return 0;
}

static int client(const char *host, int n, int port) {
    int ok = 0, failed = 0;
    char seen[64] = "", first[64] = "";
    for (int done = 0; done < n;) {
        int s[8], k = n - done < 8 ? n - done : 8;
        for (int i = 0; i < k; i++) {
            struct sockaddr_in a = at(host, port);
            s[i] = socket(AF_INET, SOCK_STREAM, 0);
            if (connect(s[i], (struct sockaddr *)&a, sizeof(a)) != 0) {
                close(s[i]);
                s[i] = -1;
            }
        }
        for (int i = 0; i < k; i++) {
            if (s[i] >= 0 && finish(s[i], seen, sizeof(seen))) {
                ok++;
                if (first[0] == 0) snprintf(first, sizeof(first), "%s", seen);
            } else {
                failed++;
            }
        }
        done += k;
    }
    char ip[64];
    snprintf(ip, sizeof(ip), "%s", first);
    char *colon = strchr(ip, ':');
    if (colon) *colon = 0;
    printf("TCP %d of %d, seen as %s\n", ok, n, ip);
    int u = socket(AF_INET, SOCK_DGRAM, 0), uok = 0;
    struct sockaddr_in a = at(host, port + 1);
    first[0] = 0;
    for (int i = 0; i < 10; i++) {
        sendto(u, "hello", 5, 0, (struct sockaddr *)&a, sizeof(a));
        struct pollfd p = {u, POLLIN, 0};
        if (poll(&p, 1, 2000) <= 0) continue;
        char data[128];
        ssize_t k = recv(u, data, sizeof(data) - 1, 0);
        if (k > 5 && memcmp(data, "PEER ", 5) == 0) {
            data[k] = 0;
            uok++;
            if (first[0] == 0) snprintf(first, sizeof(first), "%s", data + 5);
        }
    }
    snprintf(ip, sizeof(ip), "%s", first);
    colon = strchr(ip, ':');
    if (colon) *colon = 0;
    printf("UDP %d of 10, seen as %s\n", uok, ip);
    return failed + (10 - uok);
}

int main(int argc, char **argv) {
    for (int i = 0; i < BULK; i++) bulk[i] = (unsigned char)(i * 7 + i / 256);
    if (argc >= 3 && strcmp(argv[1], "serve") == 0)
        return serve(atoi(argv[2]), argc > 3 ? argv[3] : NULL, argc > 4 && strcmp(argv[4], "dns") == 0);
    if (argc >= 3 && strcmp(argv[1], "dns") == 0) return dns_test(argv[2]);
    if (argc >= 3 && strcmp(argv[1], "chmod") == 0) {
        int bad = 0;
        for (int i = 2; i < argc; i++) bad += chmod(argv[i], 0755) != 0;
        return bad;
    }
    if (argc >= 4 && strcmp(argv[1], "client") == 0) return client(argv[2], atoi(argv[3]), argc > 4 ? atoi(argv[4]) : 7000);
    printf("NATTEST serve SECONDS [LOG [dns]] | NATTEST client HOST N [PORT] | NATTEST dns SERVER\n");
    return 1;
}
