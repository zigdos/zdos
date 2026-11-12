/* What mbedTLS asks of the platform on ZDOS (zdos_crypto_config.h): entropy
   from getrandom (the CPU's generator) and a millisecond clock */
#include <sys/random.h>
#include <time.h>
#include <psa/crypto.h>
#include <mbedtls/platform.h>
#include <mbedtls/platform_time.h>

int mbedtls_platform_get_entropy(psa_driver_get_entropy_flags_t flags, size_t *estimate_bits,
                                 unsigned char *output, size_t output_size) {
    if (flags != 0) {
        return PSA_ERROR_NOT_SUPPORTED;
    }
    if (getrandom(output, output_size, 0) != (ssize_t)output_size) {
        return PSA_ERROR_INSUFFICIENT_ENTROPY;
    }
    *estimate_bits = 8 * output_size;
    return 0;
}

mbedtls_ms_time_t mbedtls_ms_time(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (mbedtls_ms_time_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
