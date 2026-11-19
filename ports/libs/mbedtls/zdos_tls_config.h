
/* ZDOS: TLS for curl (client) and QuickJS's zdos:net (server). No
   sockets or timers of mbedTLS's own (the programs do their own I/O
   and timeouts; net_sockets.c and timing.c want a Unix), no session
   cache, cookies or tickets */
#undef MBEDTLS_NET_C
#undef MBEDTLS_TIMING_C
#undef MBEDTLS_SSL_CACHE_C
#undef MBEDTLS_SSL_COOKIE_C
#undef MBEDTLS_SSL_TICKET_C
#undef MBEDTLS_SSL_DTLS_HELLO_VERIFY
#undef MBEDTLS_SSL_DTLS_CLIENT_PORT_REUSE
