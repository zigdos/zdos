# Mbed TLS

Mbed TLS 4 (with TF-PSA-Crypto) as static libraries for other ports: curl's
TLS, so NetSurf has `https://`. `libmbedtls.a`, `libmbedx509.a` and
`libmbedcrypto.a` in `build/sdk-ports/lib/<arch>`, the headers (`mbedtls/`,
`psa/`, `tf-psa-crypto/`) in `build/sdk-ports/include`
(`-lmbedtls -lmbedx509 -lmbedcrypto`).

```sh
ports/libs/mbedtls/build.sh [x86|x86_64|arm64]
```

Sources: an Mbed TLS release archive unpacked in `../mbedtls`
(`MBEDTLS_SRC=...`), unchanged. A git checkout lacks the generated files
(driver wrappers, config checks) and is refused.

- The configuration is the default with `zdos_tls_config.h` and
  `zdos_crypto_config.h` appended to its two config headers; the installed
  headers are those copies, so programs see what the library was built with.
  A TLS client: no `net_sockets.c` or `timing.c` (curl does its own I/O and
  timeouts), no server side, no persistent keys in files.
- `mbedtls_zdos.c`: entropy from the SDK's `getrandom` (the CPU's generator)
  and the millisecond clock; the built-in ones know only Unix and Windows.
- Certificates: programs pass a bundle (curl: `C:/CONF/CACERT.PEM`, the one
  FETCH uses). Certificate dates are checked against ZDOS's clock, which has
  no time zone.

License: Apache-2.0 (or GPL-2.0-or-later), `LICENSE` in its tree.
