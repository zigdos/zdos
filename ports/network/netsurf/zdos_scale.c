/* Images drawn smaller than they are, area-averaged: libnsfb takes one
 * source pixel per screen pixel, which drops thin lines and breaks
 * up small text. A copy per bitmap and size is kept until the
 * bitmap changes or goes (zdos_scaled_forget). */
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "framebuffer/zdos_scale.h"

#define ENTRIES 16
#define MAX_BYTES (48u << 20) /* all copies together */

static struct {
    const void *bitmap;
    int width, height;
    uint32_t *pixels;
    uint64_t used; /* the last use, for evicting */
} cache[ENTRIES];
static uint64_t clock_now;
static size_t cache_bytes;

static void drop(int i)
{
    if (cache[i].pixels != NULL) {
        cache_bytes -= (size_t)cache[i].width * cache[i].height * 4;
        free(cache[i].pixels);
    }
    memset(&cache[i], 0, sizeof(cache[i]));
}

void zdos_scaled_forget(const void *bitmap)
{
    for (int i = 0; i < ENTRIES; i++)
        if (cache[i].bitmap == bitmap)
            drop(i);
}

/* ABGR8888 (0xAABBGGRR) into dw x dh: each target pixel the average of
 * the source pixels it covers, colours weighted by alpha. A target
 * axis larger than the source repeats pixels, as before. */
static void scale(const uint32_t *src, int sw, int sh, int stride, uint32_t *dst,
                  int dw, int dh, bool alpha)
{
    int *x0 = malloc(sizeof(int) * (size_t)dw * 2);
    uint64_t *acc = calloc((size_t)dw * 4, sizeof(uint64_t));
    if (x0 == NULL || acc == NULL) {
        free(x0);
        free(acc);
        memset(dst, 0, (size_t)dw * dh * 4);
        return;
    }
    int *x1 = x0 + dw;
    for (int x = 0; x < dw; x++) {
        x0[x] = (int)((int64_t)x * sw / dw);
        x1[x] = (int)((int64_t)(x + 1) * sw / dw);
        if (x1[x] <= x0[x])
            x1[x] = x0[x] + 1;
    }
    for (int y = 0; y < dh; y++) {
        int y0 = (int)((int64_t)y * sh / dh);
        int y1 = (int)((int64_t)(y + 1) * sh / dh);
        if (y1 <= y0)
            y1 = y0 + 1;
        memset(acc, 0, sizeof(uint64_t) * (size_t)dw * 4);
        for (int sy = y0; sy < y1; sy++) {
            const uint32_t *row = src + (size_t)sy * stride;
            for (int x = 0; x < dw; x++) {
                uint64_t *a = acc + (size_t)x * 4;
                for (int sx = x0[x]; sx < x1[x]; sx++) {
                    uint32_t p = row[sx];
                    uint32_t al = alpha ? p >> 24 : 255;
                    a[0] += al;
                    a[1] += (uint64_t)(p & 0xff) * al;
                    a[2] += (uint64_t)((p >> 8) & 0xff) * al;
                    a[3] += (uint64_t)((p >> 16) & 0xff) * al;
                }
            }
        }
        uint32_t *out = dst + (size_t)y * dw;
        for (int x = 0; x < dw; x++) {
            uint64_t *a = acc + (size_t)x * 4;
            uint64_t n = (uint64_t)(x1[x] - x0[x]) * (y1 - y0);
            if (a[0] == 0) {
                out[x] = 0;
                continue;
            }
            uint32_t al = (uint32_t)((a[0] + n / 2) / n);
            uint32_t r = (uint32_t)((a[1] + a[0] / 2) / a[0]);
            uint32_t g = (uint32_t)((a[2] + a[0] / 2) / a[0]);
            uint32_t b = (uint32_t)((a[3] + a[0] / 2) / a[0]);
            out[x] = (alpha ? al : 255u) << 24 | b << 16 | g << 8 | r;
        }
    }
    free(x0);
    free(acc);
}

const uint32_t *zdos_scaled(const void *bitmap, const uint32_t *src, int sw, int sh,
                            int stride, int dw, int dh, bool alpha)
{
    if (dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0)
        return NULL;
    size_t bytes = (size_t)dw * dh * 4;
    if (bytes > MAX_BYTES / 2)
        return NULL; /* too big to keep: drawn as before */
    clock_now++;
    for (int i = 0; i < ENTRIES; i++) {
        if (cache[i].bitmap == bitmap && cache[i].width == dw && cache[i].height == dh) {
            cache[i].used = clock_now;
            return cache[i].pixels;
        }
    }
    /* Room: the least recently used go */
    for (;;) {
        int free_slot = -1, oldest = -1;
        for (int i = 0; i < ENTRIES; i++) {
            if (cache[i].pixels == NULL) {
                if (free_slot < 0)
                    free_slot = i;
            } else if (oldest < 0 || cache[i].used < cache[oldest].used) {
                oldest = i;
            }
        }
        if (free_slot >= 0 && cache_bytes + bytes <= MAX_BYTES) {
            uint32_t *pixels = malloc(bytes);
            if (pixels == NULL)
                return NULL;
            scale(src, sw, sh, stride, pixels, dw, dh, alpha);
            cache[free_slot].bitmap = bitmap;
            cache[free_slot].width = dw;
            cache[free_slot].height = dh;
            cache[free_slot].pixels = pixels;
            cache[free_slot].used = clock_now;
            cache_bytes += bytes;
            return pixels;
        }
        if (oldest < 0)
            return NULL;
        drop(oldest);
    }
}
