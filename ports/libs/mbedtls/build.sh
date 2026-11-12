#!/usr/bin/env bash
# Mbed TLS 4 (curl's TLS): libmbedtls.a, libmbedx509.a,
# libmbedcrypto.a and the headers in sdk-ports.
#   build.sh [x86|x86_64|arm64]...   (none: all three)
# Sources: MBEDTLS_SRC=..., unchanged. ZDOS's settings are appended to
# the two config headers in build/mbedtls/include, which go before the
# tree's, so programs see the library's configuration.
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/libs/mbedtls
MBEDTLS_SRC=${MBEDTLS_SRC:-$SRC_ROOT/mbedtls}
T=$MBEDTLS_SRC/tf-psa-crypto
[ -f "$MBEDTLS_SRC/library/ssl_tls.c" ] && [ -f "$T/core/psa_crypto.c" ] ||
    die "no Mbed TLS release tree (with tf-psa-crypto) in $MBEDTLS_SRC (MBEDTLS_SRC=...)"
[ -f "$T/core/psa_crypto_driver_wrappers_no_static.c" ] ||
    die "$MBEDTLS_SRC lacks the generated files: use a release archive, not a git checkout"
BUILD=$ZIGDOS/build/mbedtls
CONF=$BUILD/include
mkdir -p "$CONF/mbedtls" "$CONF/psa"
cat "$MBEDTLS_SRC/include/mbedtls/mbedtls_config.h" "$PORT/zdos_tls_config.h" >"$CONF/mbedtls/mbedtls_config.h"
cat "$T/include/psa/crypto_config.h" "$PORT/zdos_crypto_config.h" >"$CONF/psa/crypto_config.h"

D=$T/drivers
PUBLIC="-I$CONF -I$MBEDTLS_SRC/include -I$T/include -I$D/builtin/include
    -I$D/everest/include -I$D/everest/include/tf-psa-crypto/private/everest
    -I$D/everest/include/tf-psa-crypto/private/everest/kremlib
    -I$D/p256-m/p256-m/include -I$D/p256-m/p256-m/include/p256-m -I$D/p256-m/p256-m_driver_interface
    -I$D/pqcp/include"
PRIVATE="-I$MBEDTLS_SRC/library -I$T/core -I$D/builtin/src -I$T/dispatch -I$T/extras -I$T/platform
    -I$T/utilities -I$D/pqcp/src -I$D/pqcp/mldsa-native/mldsa"
FLAGS="-O2 $PUBLIC $PRIVATE"
# library/Makefile's and crypto-library.make's sources:
TLS="debug mps_reader mps_trace net_sockets ssl_cache ssl_ciphersuites ssl_client ssl_cookie
    ssl_debug_helpers_generated ssl_msg ssl_ticket ssl_tls ssl_tls12_client ssl_tls12_server
    ssl_tls13_keys ssl_tls13_client ssl_tls13_server ssl_tls13_generic timing version version_features"
X509="mbedtls_config x509 x509_create x509_crl x509_crt x509_csr x509_oid x509write x509write_crt
    x509write_csr pkcs7 error"
# pqcp/src may have none: the wildcard then gives nothing:
CRYPTO=$(for f in "$T"/core/*.c "$D"/builtin/src/*.c "$T"/dispatch/*.c "$T"/extras/*.c "$T"/platform/*.c \
    "$T"/utilities/*.c "$D"/everest/library/x25519.c "$D"/everest/library/Hacl_Curve25519_joined.c \
    "$D"/p256-m/p256-m_driver_entrypoints.c "$D"/p256-m/p256-m/p256-m.c "$D"/pqcp/src/*.c; do
    [ -f "$f" ] && echo "$f"
done)

# compile <out dir> <source>...: objects named by their path, so the
# same names in two folders don't collide.
compile() {
    local out=$1 s o
    shift
    mkdir -p "$out"
    for s in "$@"; do
        o=$out/$(echo "${s#$MBEDTLS_SRC/}" | tr / _ | sed 's/\.c$/.o/')
        $CC $FLAGS -c "$s" -o "$o" &
        while [ "$(jobs -r | wc -l)" -ge "$(cpus)" ]; do wait -n; done
    done
    wait
}

for arch in $(arches "$@"); do
    select_arch "$arch"
    obj=$BUILD/$arch
    rm -rf "$obj"
    echo "=== Mbed TLS for $arch ==="
    compile "$obj/tls" $(for f in $TLS; do echo "$MBEDTLS_SRC/library/$f.c"; done)
    compile "$obj/x509" $(for f in $X509; do echo "$MBEDTLS_SRC/library/$f.c"; done)
    compile "$obj/crypto" $CRYPTO "$PORT/mbedtls_zdos.c"
    for lib in tls x509 crypto; do
        zig ar rcs "$obj/libmbed$lib.a" "$obj/$lib"/*.o
        install_file "$obj/libmbed$lib.a" "sdk-ports/lib/$arch"
    done
done

# The tree's, with the two config headers replaced:
inc=$ZIGDOS/build/sdk-ports/include
rm -rf "$inc/mbedtls" "$inc/psa" "$inc/tf-psa-crypto"
for d in "$MBEDTLS_SRC/include" "$T/include" "$D/builtin/include"; do
    (cd "$d" && find . -name '*.h' | while read -r h; do
        mkdir -p "$inc/$(dirname "$h")"
        cp "$h" "$inc/$h"
    done)
done
cp "$CONF/mbedtls/mbedtls_config.h" "$inc/mbedtls/mbedtls_config.h"
cp "$CONF/psa/crypto_config.h" "$inc/psa/crypto_config.h"
echo "Headers in build/sdk-ports/include (mbedtls, psa, tf-psa-crypto)"
