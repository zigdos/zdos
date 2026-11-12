#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <webp/encode.h>
#include <webp/types.h>

int main(void) {
    const uint8_t rgba[] = {
        0xff, 0x00, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff,
        0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    };
    uint8_t *encoded = NULL;
    size_t size = WebPEncodeRGBA(rgba, 2, 2, 8, 75.0f, &encoded);
    int ok = size > 12 && encoded != NULL &&
             memcmp(encoded, "RIFF", 4) == 0 &&
             memcmp(encoded + 8, "WEBP", 4) == 0;
    WebPFree(encoded);
    if (!ok) {
        fputs("WebP encode failed\n", stderr);
        return 1;
    }
    printf("WebP encode ok: %lu bytes\n", (unsigned long)size);
    return 0;
}
