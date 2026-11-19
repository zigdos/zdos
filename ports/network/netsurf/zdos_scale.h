/* Images drawn smaller than they are, area-averaged (zdos_scale.c) */
#ifndef NETSURF_FB_ZDOS_SCALE_H
#define NETSURF_FB_ZDOS_SCALE_H

#include <stdbool.h>
#include <stdint.h>

/* The bitmap (ABGR8888, stride in pixels) at dw x dh, kept for the next
 * draw of that size; NULL: not possible, draw it as before */
const uint32_t *zdos_scaled(const void *bitmap, const uint32_t *src, int sw, int sh,
                            int stride, int dw, int dh, bool alpha);

/* The bitmap changed or goes: its copies go */
void zdos_scaled_forget(const void *bitmap);

#endif
