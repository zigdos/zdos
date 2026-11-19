/* zdos:net: TCP server sockets and TLS (Mbed TLS) for zdos:web,
 * non-blocking, in qjs's event loop (ZDOSMODS.md).
 * ZDOS_NET_NO_TLS: without TLS. */
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <arpa/inet.h>

#ifndef ZDOS_NET_NO_TLS
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/pk.h>
#include <psa/crypto.h>
#endif

#include "quickjs.h"
#include "zdos_modules.h"

#define countof(a) (sizeof(a) / sizeof((a)[0]))

static JSValue throw_errno(JSContext *ctx, const char *what) {
    return JS_ThrowPlainError(ctx, "%s: %s", what, strerror(errno));
}

/* data: an ArrayBuffer, a typed array or a string (UTF-8); its bytes
   from offset, length of them (all the rest without length) */
static const uint8_t *bytes_of(JSContext *ctx, JSValueConst data, int argc, JSValueConst *argv, int first,
                               size_t *len, const char **str) {
    size_t size = 0, off = 0, n;
    const uint8_t *p;
    *str = NULL;
    if (JS_IsString(data)) {
        *str = JS_ToCStringLen(ctx, &size, data);
        if (*str == NULL) return NULL;
        p = (const uint8_t *)*str;
    } else if (JS_IsArrayBuffer(data)) {
        p = JS_GetArrayBuffer(ctx, &size, data);
    } else {
        size_t boff, blen, per;
        JSValue buf = JS_GetTypedArrayBuffer(ctx, data, &boff, &blen, &per);
        if (JS_IsException(buf)) return NULL;
        p = JS_GetArrayBuffer(ctx, &size, buf);
        JS_FreeValue(ctx, buf);
        if (p == NULL) return NULL;
        p += boff;
        size = blen;
    }
    if (p == NULL) return NULL;
    if (argc > first && !JS_IsUndefined(argv[first])) {
        int64_t v;
        if (JS_ToInt64(ctx, &v, argv[first])) return NULL;
        off = v < 0 ? 0 : (size_t)v > size ? size : (size_t)v;
    }
    n = size - off;
    if (argc > first + 1 && !JS_IsUndefined(argv[first + 1])) {
        int64_t v;
        if (JS_ToInt64(ctx, &v, argv[first + 1])) return NULL;
        if (v < 0) v = 0;
        if ((size_t)v < n) n = (size_t)v;
    }
    *len = n;
    return p + off;
}

static void release(JSContext *ctx, const char *str) {
    if (str != NULL) JS_FreeCString(ctx, str);
}

static int nonblocking(int fd) {
    int fl = fcntl(fd, F_GETFL);
    return fl < 0 ? -1 : fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

/* SOCKETS */

static JSValue js_listen(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    int port, backlog = 128, one = 1, fd;
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (JS_ToInt32(ctx, &port, argv[0])) return JS_EXCEPTION;
    if (port < 0 || port > 65535) return JS_ThrowRangeError(ctx, "port %d", port);
    a.sin_port = htons((uint16_t)port);
    if (argc > 1 && !JS_IsUndefined(argv[1]) && !JS_IsNull(argv[1])) {
        const char *host = JS_ToCString(ctx, argv[1]);
        if (host == NULL) return JS_EXCEPTION;
        int ok = inet_pton(AF_INET, host, &a.sin_addr);
        JS_FreeCString(ctx, host);
        if (ok != 1) return JS_ThrowTypeError(ctx, "not an IPv4 address");
    }
    if (argc > 2 && !JS_IsUndefined(argv[2]) && JS_ToInt32(ctx, &backlog, argv[2])) return JS_EXCEPTION;
    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return throw_errno(ctx, "socket");
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0 || listen(fd, backlog) < 0 || nonblocking(fd) < 0) {
        int e = errno;
        close(fd);
        errno = e;
        return throw_errno(ctx, "listen");
    }
    return JS_NewInt32(ctx, fd);
}

static JSValue js_accept(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    int fd, c;
    struct sockaddr_in a;
    socklen_t len = sizeof(a);
    char ip[INET_ADDRSTRLEN];
    if (JS_ToInt32(ctx, &fd, argv[0])) return JS_EXCEPTION;
    c = accept(fd, (struct sockaddr *)&a, &len);
    if (c < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR || errno == ECONNABORTED) return JS_NULL;
        return throw_errno(ctx, "accept");
    }
    nonblocking(c);
    if (inet_ntop(AF_INET, &a.sin_addr, ip, sizeof(ip)) == NULL) strcpy(ip, "0.0.0.0");
    JSValue r = JS_NewArray(ctx);
    JS_SetPropertyUint32(ctx, r, 0, JS_NewInt32(ctx, c));
    JS_SetPropertyUint32(ctx, r, 1, JS_NewString(ctx, ip));
    JS_SetPropertyUint32(ctx, r, 2, JS_NewInt32(ctx, ntohs(a.sin_port)));
    return r;
}

static JSValue js_read(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    int fd, max = 65536;
    if (JS_ToInt32(ctx, &fd, argv[0])) return JS_EXCEPTION;
    if (argc > 1 && JS_ToInt32(ctx, &max, argv[1])) return JS_EXCEPTION;
    if (max < 1) max = 1;
    uint8_t *buf = malloc((size_t)max);
    if (buf == NULL) return JS_ThrowOutOfMemory(ctx);
    ssize_t n = recv(fd, buf, (size_t)max, 0);
    JSValue r;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) r = JS_NULL;
    else r = JS_NewArrayBufferCopy(ctx, buf, n < 0 ? 0 : (size_t)n); /* error or end: empty */
    free(buf);
    return r;
}

static JSValue js_write(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    int fd;
    size_t len;
    const char *str;
    if (JS_ToInt32(ctx, &fd, argv[0])) return JS_EXCEPTION;
    const uint8_t *p = bytes_of(ctx, argv[1], argc, argv, 2, &len, &str);
    if (p == NULL) return JS_EXCEPTION;
    ssize_t n = len == 0 ? 0 : send(fd, p, len, MSG_NOSIGNAL);
    release(ctx, str);
    if (n < 0) return JS_NewInt32(ctx, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? 0 : -1);
    return JS_NewInt64(ctx, n);
}

static JSValue js_close(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    int fd;
    if (JS_ToInt32(ctx, &fd, argv[0])) return JS_EXCEPTION;
    close(fd);
    return JS_UNDEFINED;
}

static JSValue js_encode(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    size_t len;
    const char *s = JS_ToCStringLen(ctx, &len, argv[0]);
    if (s == NULL) return JS_EXCEPTION;
    JSValue r = JS_NewArrayBufferCopy(ctx, (const uint8_t *)s, len);
    JS_FreeCString(ctx, s);
    return r;
}

static JSValue js_decode(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    size_t len;
    const char *str;
    const uint8_t *p = bytes_of(ctx, argv[0], argc, argv, 1, &len, &str);
    if (p == NULL) return JS_EXCEPTION;
    JSValue r = JS_NewStringLen(ctx, (const char *)p, len);
    release(ctx, str);
    return r;
}

/* TLS */

#ifndef ZDOS_NET_NO_TLS
static JSClassID tls_server_class, tls_conn_class;
static int psa_ready;

typedef struct {
    mbedtls_ssl_config conf;
    mbedtls_x509_crt cert;
    mbedtls_pk_context key;
    int refs; /* the server object and each connection */
} TlsServer;

typedef struct {
    mbedtls_ssl_context ssl;
    TlsServer *server;
    int fd;
} TlsConn;

static void server_unref(TlsServer *s) {
    if (s != NULL && --s->refs == 0) {
        mbedtls_ssl_config_free(&s->conf);
        mbedtls_x509_crt_free(&s->cert);
        mbedtls_pk_free(&s->key);
        free(s);
    }
}

static void tls_server_finalizer(JSRuntime *rt, JSValueConst val) {
    server_unref(JS_GetOpaque(val, tls_server_class));
}

static void tls_conn_free(TlsConn *c) {
    if (c == NULL) return;
    mbedtls_ssl_free(&c->ssl);
    server_unref(c->server);
    free(c);
}

static void tls_conn_finalizer(JSRuntime *rt, JSValueConst val) {
    tls_conn_free(JS_GetOpaque(val, tls_conn_class));
}

static JSValue tls_error(JSContext *ctx, const char *what, int ret) {
    return JS_ThrowPlainError(ctx, "%s: Mbed TLS error -0x%04x", what, (unsigned)-ret);
}

/* PEM text needs its 0 counted */
static int parse_pem(JSContext *ctx, JSValueConst v, uint8_t **out, size_t *len) {
    size_t n;
    const char *s = JS_ToCStringLen(ctx, &n, v);
    if (s == NULL) return -1;
    *out = malloc(n + 1);
    if (*out == NULL) {
        JS_FreeCString(ctx, s);
        return -1;
    }
    memcpy(*out, s, n + 1);
    *len = n + 1;
    JS_FreeCString(ctx, s);
    return 0;
}

static JSValue js_tls_server_ctor(JSContext *ctx, JSValueConst new_target, int argc, JSValueConst *argv) {
    uint8_t *cert = NULL, *key = NULL;
    size_t cert_len, key_len;
    int ret;
    if (!psa_ready) {
        if (psa_crypto_init() != PSA_SUCCESS) return JS_ThrowPlainError(ctx, "TLS: no random numbers (psa_crypto_init)");
        psa_ready = 1;
    }
    TlsServer *s = calloc(1, sizeof(*s));
    if (s == NULL) return JS_ThrowOutOfMemory(ctx);
    s->refs = 1;
    mbedtls_ssl_config_init(&s->conf);
    mbedtls_x509_crt_init(&s->cert);
    mbedtls_pk_init(&s->key);
    if (parse_pem(ctx, argv[0], &cert, &cert_len) || parse_pem(ctx, argv[1], &key, &key_len)) {
        free(cert);
        server_unref(s);
        return JS_EXCEPTION;
    }
    if ((ret = mbedtls_x509_crt_parse(&s->cert, cert, cert_len)) != 0) {
        free(cert);
        free(key);
        server_unref(s);
        return tls_error(ctx, "TLS certificate", ret);
    }
    ret = mbedtls_pk_parse_key(&s->key, key, key_len, NULL, 0);
    free(cert);
    free(key);
    if (ret != 0) {
        server_unref(s);
        return tls_error(ctx, "TLS key", ret);
    }
    if ((ret = mbedtls_ssl_config_defaults(&s->conf, MBEDTLS_SSL_IS_SERVER, MBEDTLS_SSL_TRANSPORT_STREAM,
                                           MBEDTLS_SSL_PRESET_DEFAULT)) != 0 ||
        (ret = mbedtls_ssl_conf_own_cert(&s->conf, &s->cert, &s->key)) != 0) {
        server_unref(s);
        return tls_error(ctx, "TLS setup", ret);
    }
    JSValue obj = JS_NewObjectClass(ctx, tls_server_class);
    if (JS_IsException(obj)) {
        server_unref(s);
        return obj;
    }
    JS_SetOpaque(obj, s);
    return obj;
}

static int bio_send(void *p, const unsigned char *buf, size_t len) {
    ssize_t n = send(((TlsConn *)p)->fd, buf, len, MSG_NOSIGNAL);
    if (n >= 0) return (int)n;
    return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? MBEDTLS_ERR_SSL_WANT_WRITE : -1;
}

static int bio_recv(void *p, unsigned char *buf, size_t len) {
    ssize_t n = recv(((TlsConn *)p)->fd, buf, len, 0);
    if (n >= 0) return (int)n;
    return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? MBEDTLS_ERR_SSL_WANT_READ : -1;
}

static JSValue js_tls_accept(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    TlsServer *s = JS_GetOpaque2(ctx, this_val, tls_server_class);
    int fd, ret;
    if (s == NULL || JS_ToInt32(ctx, &fd, argv[0])) return JS_EXCEPTION;
    TlsConn *c = calloc(1, sizeof(*c));
    if (c == NULL) return JS_ThrowOutOfMemory(ctx);
    mbedtls_ssl_init(&c->ssl);
    c->fd = fd;
    c->server = s;
    s->refs++;
    if ((ret = mbedtls_ssl_setup(&c->ssl, &s->conf)) != 0) {
        tls_conn_free(c);
        return tls_error(ctx, "TLS", ret);
    }
    mbedtls_ssl_set_bio(&c->ssl, c, bio_send, bio_recv, NULL);
    JSValue obj = JS_NewObjectClass(ctx, tls_conn_class);
    if (JS_IsException(obj)) {
        tls_conn_free(c);
        return obj;
    }
    JS_SetOpaque(obj, c);
    return obj;
}

/* What a call that would wait waits for, else NULL */
static const char *want(int ret) {
    if (ret == MBEDTLS_ERR_SSL_WANT_READ) return "read";
    if (ret == MBEDTLS_ERR_SSL_WANT_WRITE || ret == MBEDTLS_ERR_SSL_ASYNC_IN_PROGRESS ||
        ret == MBEDTLS_ERR_SSL_CRYPTO_IN_PROGRESS)
        return "write";
    return NULL;
}

static TlsConn *conn_of(JSContext *ctx, JSValueConst this_val) {
    TlsConn *c = JS_GetOpaque2(ctx, this_val, tls_conn_class);
    if (c != NULL && c->fd < 0) {
        JS_ThrowTypeError(ctx, "TLS connection closed");
        return NULL;
    }
    return c;
}

static JSValue js_tls_handshake(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    TlsConn *c = conn_of(ctx, this_val);
    if (c == NULL) return JS_EXCEPTION;
    int ret = mbedtls_ssl_handshake(&c->ssl);
    if (ret == 0) return JS_TRUE;
    const char *w = want(ret);
    return w != NULL ? JS_NewString(ctx, w) : tls_error(ctx, "TLS handshake", ret);
}

static JSValue js_tls_read(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    TlsConn *c = conn_of(ctx, this_val);
    int max = 16384;
    if (c == NULL || (argc > 0 && JS_ToInt32(ctx, &max, argv[0]))) return JS_EXCEPTION;
    if (max < 1) max = 1;
    uint8_t *buf = malloc((size_t)max);
    if (buf == NULL) return JS_ThrowOutOfMemory(ctx);
    int ret;
    do {
        ret = mbedtls_ssl_read(&c->ssl, buf, (size_t)max);
    } while (ret == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET);
    JSValue r;
    const char *w = ret < 0 ? want(ret) : NULL;
    if (ret >= 0) r = JS_NewArrayBufferCopy(ctx, buf, (size_t)ret);
    else if (w != NULL) r = JS_NewString(ctx, w);
    else r = JS_NewArrayBufferCopy(ctx, buf, 0); /* closed or broken: the end */
    free(buf);
    return r;
}

static JSValue js_tls_write(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    TlsConn *c = conn_of(ctx, this_val);
    size_t len;
    const char *str;
    if (c == NULL) return JS_EXCEPTION;
    const uint8_t *p = bytes_of(ctx, argv[0], argc, argv, 1, &len, &str);
    if (p == NULL) return JS_EXCEPTION;
    int ret = len == 0 ? 0 : mbedtls_ssl_write(&c->ssl, p, len);
    release(ctx, str);
    if (ret >= 0) return JS_NewInt32(ctx, ret);
    const char *w = want(ret);
    return w != NULL ? JS_NewString(ctx, w) : JS_NewInt32(ctx, -1);
}

/* close_notify if it goes out at once; the descriptor stays the caller's */
static JSValue js_tls_close(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    TlsConn *c = JS_GetOpaque2(ctx, this_val, tls_conn_class);
    if (c == NULL) return JS_EXCEPTION;
    if (c->fd >= 0) {
        mbedtls_ssl_close_notify(&c->ssl);
        c->fd = -1;
    }
    return JS_UNDEFINED;
}

static const JSCFunctionListEntry tls_server_proto[] = {
    JS_CFUNC_DEF("accept", 1, js_tls_accept),
};

static const JSCFunctionListEntry tls_conn_proto[] = {
    JS_CFUNC_DEF("handshake", 0, js_tls_handshake),
    JS_CFUNC_DEF("read", 1, js_tls_read),
    JS_CFUNC_DEF("write", 3, js_tls_write),
    JS_CFUNC_DEF("close", 0, js_tls_close),
};

#endif

static const JSCFunctionListEntry net_funcs[] = {
    JS_CFUNC_DEF("listen", 3, js_listen),
    JS_CFUNC_DEF("accept", 1, js_accept),
    JS_CFUNC_DEF("read", 2, js_read),
    JS_CFUNC_DEF("write", 4, js_write),
    JS_CFUNC_DEF("close", 1, js_close),
    JS_CFUNC_DEF("encode", 1, js_encode),
    JS_CFUNC_DEF("decode", 3, js_decode),
};

#ifndef ZDOS_NET_NO_TLS
static JSClassDef tls_server_def = {"TlsServer", .finalizer = tls_server_finalizer};
static JSClassDef tls_conn_def = {"TlsConnection", .finalizer = tls_conn_finalizer};
#endif

static int net_init(JSContext *ctx, JSModuleDef *m) {
#ifndef ZDOS_NET_NO_TLS
    JSRuntime *rt = JS_GetRuntime(ctx);
    JS_NewClassID(rt, &tls_server_class);
    JS_NewClassID(rt, &tls_conn_class);
    JS_NewClass(rt, tls_server_class, &tls_server_def);
    JS_NewClass(rt, tls_conn_class, &tls_conn_def);
    JSValue proto = JS_NewObject(ctx);
    JS_SetPropertyFunctionList(ctx, proto, tls_server_proto, countof(tls_server_proto));
    JS_SetClassProto(ctx, tls_server_class, proto);
    proto = JS_NewObject(ctx);
    JS_SetPropertyFunctionList(ctx, proto, tls_conn_proto, countof(tls_conn_proto));
    JS_SetClassProto(ctx, tls_conn_class, proto);
    JSValue ctor = JS_NewCFunction2(ctx, js_tls_server_ctor, "TlsServer", 2, JS_CFUNC_constructor, 0);
    JS_SetConstructor(ctx, ctor, JS_GetClassProto(ctx, tls_server_class));
    JS_FreeValue(ctx, JS_GetClassProto(ctx, tls_server_class));
    JS_SetModuleExport(ctx, m, "TlsServer", ctor);
#else
    JS_SetModuleExport(ctx, m, "TlsServer", JS_UNDEFINED);
#endif
    return JS_SetModuleExportList(ctx, m, net_funcs, countof(net_funcs));
}

JSModuleDef *zdos_init_module_net(JSContext *ctx, const char *name) {
    JSModuleDef *m = JS_NewCModule(ctx, name, net_init);
    if (m == NULL) return NULL;
    JS_AddModuleExportList(ctx, m, net_funcs, countof(net_funcs));
    JS_AddModuleExport(ctx, m, "TlsServer");
    return m;
}
