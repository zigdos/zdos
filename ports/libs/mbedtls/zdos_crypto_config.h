
/* ZDOS:
   Entropy from ZDOS's random numbers and the millisecond clock from the
   SDK (mbedtls_zdos.c): the built-in ones know only Unix and Windows. No
   persistent keys in files (TLS has none). */
#undef MBEDTLS_PSA_BUILTIN_GET_ENTROPY
#define MBEDTLS_PSA_DRIVER_GET_ENTROPY
#define MBEDTLS_PLATFORM_MS_TIME_ALT
#undef MBEDTLS_PSA_CRYPTO_STORAGE_C
#undef MBEDTLS_PSA_ITS_FILE_C
