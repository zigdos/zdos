/* zdos_media.h's display: pictures in common pixel formats converted, scaled
   and dithered to what the screen shows (gfx begin_rgb / draw_rgb, or on
   a BIOS without VESA begin / palette / draw), with an arrow pointer
   drawn in. */
#include <stdlib.h>
#include <string.h>
#include "zdos.h"
#include "zdos_media.h"

enum { OUT_RGB, OUT_PAL8, OUT_332, OUT_VGA16 };

static struct {
    bool on;
    int w, h, format;
    int out_w, out_h, kind, colors;
    uint32_t *rgb;     /* OUT_RGB's picture */
    uint8_t *idx;      /* the others' */
    int *xmap;         /* each output column's source column */
    uint32_t pal[256]; /* INDEX8's palette, 0xRRGGBB */
    uint8_t black, white;
    bool cursor;
    int cx, cy;
} d;

static int pixel_size(int format) {
    return format == ZDOS_PIXELS_INDEX8 ? 1 : format == ZDOS_PIXELS_RGB565 ? 2 : 4;
}

/* w x h into sw x sh: scaled up by a whole number, or shrunk with
   its shape kept */
static void fit(int w, int h, int sw, int sh, bool up, int *ow, int *oh) {
    if (w <= sw && h <= sh) {
        int k = up ? (sw / w < sh / h ? sw / w : sh / h) : 1;
        *ow = w * k;
        *oh = h * k;
    } else if ((int64_t)w * sh > (int64_t)h * sw) {
        *ow = sw;
        *oh = (int)((int64_t)h * sw / w);
    } else {
        *oh = sh;
        *ow = (int)((int64_t)w * sh / h);
    }
    if (*ow < 1) *ow = 1;
    if (*oh < 1) *oh = 1;
}

static void release(void) {
    free(d.rgb);
    free(d.idx);
    free(d.xmap);
    d.rgb = NULL;
    d.idx = NULL;
    d.xmap = NULL;
}

/* The fixed palettes: 3-3-2 (256 colors), and for 16 colors 2 levels of
   red and blue, 4 of green (index r * 8 + g * 2 + b) */
static void fixed_palette(void) {
    uint8_t rgb[256 * 3];
    int n = d.kind == OUT_332 ? 256 : 16;
    for (int i = 0; i < n; i++) {
        if (d.kind == OUT_332) {
            rgb[i * 3] = (uint8_t)((i >> 5) * 255 / 7);
            rgb[i * 3 + 1] = (uint8_t)(((i >> 2) & 7) * 255 / 7);
            rgb[i * 3 + 2] = (uint8_t)((i & 3) * 255 / 3);
        } else {
            rgb[i * 3] = (uint8_t)((i >> 3) * 255);
            rgb[i * 3 + 1] = (uint8_t)(((i >> 1) & 3) * 85);
            rgb[i * 3 + 2] = (uint8_t)((i & 1) * 255);
        }
    }
    zdos->gfx->palette(0, (uint32_t)n, rgb);
}

bool zdos_display_open(int width, int height, int format) {
    zdos_screen_info s;
    if (width <= 0 || height <= 0 || format < 0 || format > ZDOS_PIXELS_INDEX8) {
        zdos->gfx->begin(0, 0); /* fails with INVALID_ARGUMENT */
        return false;
    }
    if (!zdos->gfx->screen(&s)) return false;
    release();
    d.on = false;
    int ow, oh;
    bool ok = false;
    if (s.true_color) {
        fit(width, height, (int)s.width, (int)s.height, false, &ow, &oh);
        ok = zdos->gfx->begin_rgb((uint32_t)ow, (uint32_t)oh);
        d.kind = OUT_RGB;
        d.colors = 0;
    } else {
        /* BIOS without VESA: 13h, else 12h (13h shrunk if it fails): */
        if (width > 320 || height > 200) {
            fit(width, height, 640, 480, true, &ow, &oh);
            ok = zdos->gfx->begin((uint32_t)ow, (uint32_t)oh);
            d.kind = OUT_VGA16;
            d.colors = 16;
        }
        if (!ok) {
            fit(width, height, 320, 200, true, &ow, &oh);
            ok = zdos->gfx->begin((uint32_t)ow, (uint32_t)oh);
            d.kind = format == ZDOS_PIXELS_INDEX8 ? OUT_PAL8 : OUT_332;
            d.colors = 256;
        }
    }
    if (!ok) return false;
    d.w = width;
    d.h = height;
    d.format = format;
    d.out_w = ow;
    d.out_h = oh;
    if (d.kind == OUT_RGB) {
        d.rgb = malloc((size_t)ow * (size_t)oh * 4);
    } else {
        d.idx = malloc((size_t)ow * (size_t)oh);
    }
    if (ow != width) {
        d.xmap = malloc((size_t)ow * sizeof(int));
        if (d.xmap != NULL) {
            for (int x = 0; x < ow; x++) d.xmap[x] = (int)((int64_t)x * width / ow);
        }
    }
    if ((d.rgb == NULL && d.idx == NULL) || (ow != width && d.xmap == NULL)) {
        release();
        zdos->gfx->end();
        return false;
    }
    if (d.kind == OUT_332 || d.kind == OUT_VGA16) {
        fixed_palette();
    } else if (d.kind == OUT_PAL8) {
        uint8_t rgb[256 * 3];
        for (int i = 0; i < 256; i++) {
            rgb[i * 3] = (uint8_t)(d.pal[i] >> 16);
            rgb[i * 3 + 1] = (uint8_t)(d.pal[i] >> 8);
            rgb[i * 3 + 2] = (uint8_t)d.pal[i];
        }
        zdos->gfx->palette(0, 256, rgb);
    }
    d.on = true;
    zdos_input_area(width, height);
    return true;
}

void zdos_display_close(void) {
    if (!d.on) return;
    d.on = false;
    release();
    zdos->gfx->end();
}

void zdos_display_get(zdos_display_info *info) {
    info->width = d.on ? d.w : 0;
    info->height = d.on ? d.h : 0;
    info->out_w = d.on ? d.out_w : 0;
    info->out_h = d.on ? d.out_h : 0;
    info->true_color = d.on && d.kind == OUT_RGB;
    info->colors = d.on ? d.colors : 0;
}

/* The palette entries nearest black and white, for the pointer */
static void find_black_white(void) {
    int best_b = 1 << 30, best_w = -1;
    for (int i = 0; i < 256; i++) {
        uint32_t c = d.pal[i];
        int sum = (int)((c >> 16) & 255) + (int)((c >> 8) & 255) + (int)(c & 255);
        if (sum < best_b) best_b = sum, d.black = (uint8_t)i;
        if (sum > best_w) best_w = sum, d.white = (uint8_t)i;
    }
}

void zdos_display_palette(int first, int count, const uint8_t *rgb) {
    if (first < 0 || count <= 0 || first >= 256) return;
    if (count > 256 - first) count = 256 - first;
    for (int i = 0; i < count; i++) {
        d.pal[first + i] = (uint32_t)rgb[i * 3] << 16 | (uint32_t)rgb[i * 3 + 1] << 8 | rgb[i * 3 + 2];
    }
    find_black_white();
    if (d.on && d.kind == OUT_PAL8) zdos->gfx->palette((uint32_t)first, (uint32_t)count, rgb);
}

void zdos_display_cursor(int x, int y, bool shown) {
    d.cx = x;
    d.cy = y;
    d.cursor = shown;
}

static uint32_t to_rgb(const uint8_t *row, int x, int format) {
    switch (format) {
        case ZDOS_PIXELS_XRGB8888: return ((const uint32_t *)row)[x] & 0xFFFFFF;
        case ZDOS_PIXELS_XBGR8888: {
            uint32_t p = ((const uint32_t *)row)[x];
            return (p & 0xFF) << 16 | (p & 0xFF00) | ((p >> 16) & 0xFF);
        }
        case ZDOS_PIXELS_RGB565: {
            uint32_t p = ((const uint16_t *)row)[x];
            uint32_t r = p >> 11, g = (p >> 5) & 63, b = p & 31;
            return (r << 3 | r >> 2) << 16 | (g << 2 | g >> 4) << 8 | (b << 3 | b >> 2);
        }
        default: return d.pal[row[x]];
    }
}

/* Ordered (4 x 4 Bayer) dithering of one component to levels steps */
static const uint8_t bayer[4][4] = {{0, 8, 2, 10}, {12, 4, 14, 6}, {3, 11, 1, 9}, {15, 7, 13, 5}};

static inline uint32_t dither(uint32_t c, int levels, int t) {
    return (c * (uint32_t)(levels - 1) * 16 + (uint32_t)t * 255 + 128) / 4080;
}

static uint8_t to_index(uint32_t c, int x, int y) {
    int t = bayer[y & 3][x & 3];
    uint32_t r = (c >> 16) & 255, g = (c >> 8) & 255, b = c & 255;
    if (d.kind == OUT_332) return (uint8_t)(dither(r, 8, t) << 5 | dither(g, 8, t) << 2 | dither(b, 4, t));
    return (uint8_t)(dither(r, 2, t) << 3 | dither(g, 4, t) << 1 | dither(b, 2, t));
}

/* The pointer: X its outline, o its inside */
static const char *const arrow[] = {
    "X", "XX", "XoX", "XooX", "XoooX", "XooooX", "XoooooX", "XooooooX", "XoooooooX", "XooooooooX",
    "XoooooXXXXX", "XooXooX", "XoX XooX", "XX  XooX", "X    XooX", "     XooX", "      XX",
};

static void draw_cursor(void) {
    int ox = (int)((int64_t)d.cx * d.out_w / d.w), oy = (int)((int64_t)d.cy * d.out_h / d.h);
    uint32_t dark = 0, light = 0xFFFFFF;
    if (d.kind == OUT_PAL8) dark = d.black, light = d.white;
    else if (d.kind == OUT_332) light = 255;
    else if (d.kind == OUT_VGA16) light = 15;
    for (int r = 0; r < (int)(sizeof(arrow) / sizeof(arrow[0])); r++) {
        int y = oy + r;
        if (y < 0 || y >= d.out_h) continue;
        for (int c = 0; arrow[r][c] != '\0'; c++) {
            int x = ox + c;
            if (x < 0 || x >= d.out_w || arrow[r][c] == ' ') continue;
            uint32_t v = arrow[r][c] == 'X' ? dark : light;
            if (d.rgb != NULL) d.rgb[(size_t)y * d.out_w + x] = v;
            else d.idx[(size_t)y * d.out_w + x] = (uint8_t)v;
        }
    }
}

void zdos_display_present(const void *pixels, int pitch) {
    if (!d.on || pixels == NULL) return;
    if (pitch <= 0) pitch = d.w * pixel_size(d.format);
    const uint8_t *src = pixels;
    int w = d.out_w, h = d.out_h;
    bool scaled = d.out_w != d.w || d.out_h != d.h;
    if (d.kind == OUT_RGB && d.format == ZDOS_PIXELS_XRGB8888 && !scaled && !d.cursor && pitch == d.w * 4) {
        zdos->gfx->draw_rgb(pixels); /* ZDOS's own format: shown as it is */
        return;
    }
    for (int y = 0; y < h; y++) {
        const uint8_t *row = src + (size_t)(scaled ? (int)((int64_t)y * d.h / h) : y) * (size_t)pitch;
        if (d.kind == OUT_RGB) {
            uint32_t *out = d.rgb + (size_t)y * w;
            if (!scaled && d.format == ZDOS_PIXELS_XRGB8888) {
                memcpy(out, row, (size_t)w * 4);
            } else {
                for (int x = 0; x < w; x++) out[x] = to_rgb(row, d.xmap ? d.xmap[x] : x, d.format);
            }
        } else {
            uint8_t *out = d.idx + (size_t)y * w;
            if (d.kind == OUT_PAL8) {
                if (!scaled) memcpy(out, row, (size_t)w);
                else for (int x = 0; x < w; x++) out[x] = row[d.xmap ? d.xmap[x] : x];
            } else {
                for (int x = 0; x < w; x++) out[x] = to_index(to_rgb(row, d.xmap ? d.xmap[x] : x, d.format), x, y);
            }
        }
    }
    if (d.cursor) draw_cursor();
    if (d.rgb != NULL) zdos->gfx->draw_rgb(d.rgb);
    else zdos->gfx->draw(d.idx);
}
