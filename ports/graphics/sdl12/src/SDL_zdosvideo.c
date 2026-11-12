/* The partial SDL 1.2's video: software surfaces, blits and fills, and the
   screen, one surface shown with zdos_display_present (8 bits as palette
   indexes, 16 as RGB565, 32 as XRGB8888; 15 and 24 converted). Where the
   screen is VGA (BIOS), a picture up to 320 wide and 201-240 high is shown
   as its middle 200 lines in mode 13h, as DOS games cropped 224-line
   pictures, instead of being shrunk. */
#include "sdl12_internal.h"
#include "SDL_syswm.h"

#include "zdos.h"
#include "zdos_media.h"

static struct {
    SDL_Surface *screen;
    int format;        /* ZDOS_PIXELS_* given to zdos_display */
    int crop_y, shown_h;
    uint32_t *conv;    /* 15 and 24 bits converted to 32 */
    SDL_PixelFormat vfmt;
    SDL_VideoInfo info;
    SDL_GrabMode grab;
    char title[128], icon[128];
} v;

/* PIXEL FORMATS */

static void mask_bits(Uint32 mask, Uint8 *shift, Uint8 *loss)
{
    Uint8 s = 0, n = 0;
    if (mask) {
        while (!(mask & 1)) mask >>= 1, s++;
        while (mask & 1) mask >>= 1, n++;
    }
    *shift = s;
    *loss = (Uint8)(8 - (n > 8 ? 8 : n));
}

/* A format of bpp bits; zero masks: the usual ones (565, 555, 888) */
static SDL_PixelFormat *new_format(int bpp, Uint32 r, Uint32 g, Uint32 b, Uint32 a)
{
    SDL_PixelFormat *f = calloc(1, sizeof(*f));
    if (f == NULL) return NULL;
    f->BitsPerPixel = (Uint8)bpp;
    f->BytesPerPixel = (Uint8)((bpp + 7) / 8);
    f->alpha = SDL_ALPHA_OPAQUE;
    if (bpp <= 8) {
        int n = 1 << (bpp < 1 ? 1 : bpp);
        f->palette = calloc(1, sizeof(SDL_Palette));
        if (f->palette) f->palette->colors = calloc((size_t)n, sizeof(SDL_Color));
        if (f->palette == NULL || f->palette->colors == NULL) {
            if (f->palette) free(f->palette);
            free(f);
            return NULL;
        }
        f->palette->ncolors = n;
        /* SDL 1.2's default for 8 bits: 3-3-2 */
        for (int i = 0; i < n && n == 256; i++) {
            SDL_Color *c = &f->palette->colors[i];
            c->r = (Uint8)((i >> 5) * 255 / 7);
            c->g = (Uint8)(((i >> 2) & 7) * 255 / 7);
            c->b = (Uint8)((i & 3) * 255 / 3);
        }
        f->Rloss = f->Gloss = f->Bloss = f->Aloss = 8;
        return f;
    }
    if (!r && !g && !b) {
        if (bpp == 15) r = 0x7C00, g = 0x03E0, b = 0x001F;
        else if (bpp == 16) r = 0xF800, g = 0x07E0, b = 0x001F;
        else r = 0xFF0000, g = 0x00FF00, b = 0x0000FF;
    }
    f->Rmask = r, f->Gmask = g, f->Bmask = b, f->Amask = a;
    mask_bits(r, &f->Rshift, &f->Rloss);
    mask_bits(g, &f->Gshift, &f->Gloss);
    mask_bits(b, &f->Bshift, &f->Bloss);
    mask_bits(a, &f->Ashift, &f->Aloss);
    return f;
}

static void free_format(SDL_PixelFormat *f)
{
    if (f == NULL) return;
    if (f->palette) {
        free(f->palette->colors);
        free(f->palette);
    }
    free(f);
}

static Uint8 expand(Uint32 pixel, Uint32 mask, Uint8 shift, Uint8 loss)
{
    if (loss >= 8) return 0;
    Uint32 c = (pixel & mask) >> shift;
    return (Uint8)((c << loss) | (loss ? c >> (8 - 2 * loss > 0 ? 8 - 2 * loss : 0) : 0));
}

Uint32 SDL_MapRGBA(const SDL_PixelFormat *const f, const Uint8 r, const Uint8 g, const Uint8 b, const Uint8 a)
{
    if (f->palette) {
        /* the nearest color */
        Uint32 best = 0, dist = ~0u;
        for (int i = 0; i < f->palette->ncolors; i++) {
            const SDL_Color *c = &f->palette->colors[i];
            int dr = c->r - r, dg = c->g - g, db = c->b - b;
            Uint32 d = (Uint32)(dr * dr + dg * dg + db * db);
            if (d < dist) {
                dist = d, best = (Uint32)i;
                if (d == 0) break;
            }
        }
        return best;
    }
    return (Uint32)(r >> f->Rloss) << f->Rshift | (Uint32)(g >> f->Gloss) << f->Gshift |
           (Uint32)(b >> f->Bloss) << f->Bshift | ((Uint32)(a >> f->Aloss) << f->Ashift & f->Amask);
}

Uint32 SDL_MapRGB(const SDL_PixelFormat *const f, const Uint8 r, const Uint8 g, const Uint8 b)
{
    if (f->palette) return SDL_MapRGBA(f, r, g, b, 255);
    return SDL_MapRGBA(f, r, g, b, 0) | f->Amask;
}

void SDL_GetRGBA(Uint32 pixel, const SDL_PixelFormat *const f, Uint8 *r, Uint8 *g, Uint8 *b, Uint8 *a)
{
    if (f->palette) {
        const SDL_Color *c = &f->palette->colors[pixel < (Uint32)f->palette->ncolors ? pixel : 0];
        *r = c->r, *g = c->g, *b = c->b, *a = SDL_ALPHA_OPAQUE;
        return;
    }
    *r = expand(pixel, f->Rmask, f->Rshift, f->Rloss);
    *g = expand(pixel, f->Gmask, f->Gshift, f->Gloss);
    *b = expand(pixel, f->Bmask, f->Bshift, f->Bloss);
    *a = f->Amask ? expand(pixel, f->Amask, f->Ashift, f->Aloss) : SDL_ALPHA_OPAQUE;
}

void SDL_GetRGB(Uint32 pixel, const SDL_PixelFormat *const f, Uint8 *r, Uint8 *g, Uint8 *b)
{
    Uint8 a;
    SDL_GetRGBA(pixel, f, r, g, b, &a);
}

/* SURFACES */

static SDL_Surface *new_surface(Uint32 flags, int w, int h, int depth, Uint32 r, Uint32 g, Uint32 b, Uint32 a, void *pixels, int pitch)
{
    if (w < 0 || h < 0 || w > 16384 || h > 16384) {
        SDL_SetError("Invalid surface size");
        return NULL;
    }
    SDL_Surface *s = calloc(1, sizeof(*s));
    if (s == NULL || (s->format = new_format(depth, r, g, b, a)) == NULL) {
        free(s);
        SDL_OutOfMemory();
        return NULL;
    }
    s->flags = flags;
    s->w = w;
    s->h = h;
    if (pixels) {
        s->pitch = (Uint16)pitch;
        s->pixels = pixels;
        s->flags |= SDL_PREALLOC;
    } else {
        s->pitch = (Uint16)((w * s->format->BytesPerPixel + 3) & ~3);
        if (w && h && (s->pixels = calloc((size_t)h, s->pitch)) == NULL) {
            free_format(s->format);
            free(s);
            SDL_OutOfMemory();
            return NULL;
        }
    }
    s->clip_rect.w = (Uint16)w;
    s->clip_rect.h = (Uint16)h;
    s->refcount = 1;
    return s;
}

SDL_Surface *SDL_CreateRGBSurface(Uint32 flags, int width, int height, int depth, Uint32 Rmask, Uint32 Gmask, Uint32 Bmask, Uint32 Amask)
{
    return new_surface(flags & (SDL_SRCCOLORKEY | SDL_SRCALPHA), width, height, depth, Rmask, Gmask, Bmask, Amask, NULL, 0);
}

SDL_Surface *SDL_CreateRGBSurfaceFrom(void *pixels, int width, int height, int depth, int pitch, Uint32 Rmask, Uint32 Gmask, Uint32 Bmask, Uint32 Amask)
{
    return new_surface(0, width, height, depth, Rmask, Gmask, Bmask, Amask, pixels, pitch);
}

void SDL_FreeSurface(SDL_Surface *s)
{
    if (s == NULL || s == v.screen || --s->refcount > 0) return;
    if (!(s->flags & SDL_PREALLOC)) free(s->pixels);
    free_format(s->format);
    free(s);
}

int SDL_LockSurface(SDL_Surface *s)
{
    s->locked++;
    return 0;
}

void SDL_UnlockSurface(SDL_Surface *s)
{
    if (s->locked) s->locked--;
}

int SDL_SetColorKey(SDL_Surface *s, Uint32 flag, Uint32 key)
{
    if (flag & SDL_SRCCOLORKEY) {
        s->flags |= SDL_SRCCOLORKEY;
        s->format->colorkey = key;
    } else {
        s->flags &= ~SDL_SRCCOLORKEY;
        s->format->colorkey = 0;
    }
    return 0;
}

int SDL_SetAlpha(SDL_Surface *s, Uint32 flag, Uint8 alpha)
{
    if (flag & SDL_SRCALPHA) s->flags |= SDL_SRCALPHA;
    else s->flags &= ~SDL_SRCALPHA;
    s->format->alpha = alpha;
    return 0;
}

static SDL_bool intersect(const SDL_Rect *a, const SDL_Rect *b, SDL_Rect *out)
{
    int x0 = a->x > b->x ? a->x : b->x, y0 = a->y > b->y ? a->y : b->y;
    int x1 = a->x + a->w < b->x + b->w ? a->x + a->w : b->x + b->w;
    int y1 = a->y + a->h < b->y + b->h ? a->y + a->h : b->y + b->h;
    out->x = (Sint16)x0, out->y = (Sint16)y0;
    out->w = (Uint16)(x1 > x0 ? x1 - x0 : 0), out->h = (Uint16)(y1 > y0 ? y1 - y0 : 0);
    return out->w && out->h ? SDL_TRUE : SDL_FALSE;
}

SDL_bool SDL_SetClipRect(SDL_Surface *s, const SDL_Rect *rect)
{
    SDL_Rect full = {0, 0, (Uint16)s->w, (Uint16)s->h};
    if (rect == NULL) {
        s->clip_rect = full;
        return SDL_TRUE;
    }
    return intersect(rect, &full, &s->clip_rect);
}

void SDL_GetClipRect(SDL_Surface *s, SDL_Rect *rect)
{
    if (s && rect) *rect = s->clip_rect;
}

static inline Uint32 get_pixel(const Uint8 *p, int bpp)
{
    switch (bpp) {
    case 1: return *p;
    case 2: return *(const Uint16 *)p;
    case 3: return (Uint32)p[0] | (Uint32)p[1] << 8 | (Uint32)p[2] << 16;
    default: return *(const Uint32 *)p;
    }
}

static inline void put_pixel(Uint8 *p, int bpp, Uint32 c)
{
    switch (bpp) {
    case 1: *p = (Uint8)c; break;
    case 2: *(Uint16 *)p = (Uint16)c; break;
    case 3: p[0] = (Uint8)c, p[1] = (Uint8)(c >> 8), p[2] = (Uint8)(c >> 16); break;
    default: *(Uint32 *)p = c; break;
    }
}

int SDL_FillRect(SDL_Surface *dst, SDL_Rect *dstrect, Uint32 color)
{
    SDL_Rect r;
    if (dstrect == NULL) r = dst->clip_rect;
    else if (!intersect(dstrect, &dst->clip_rect, &r)) {
        dstrect->w = dstrect->h = 0;
        return 0;
    }
    if (dstrect) *dstrect = r;
    int bpp = dst->format->BytesPerPixel;
    for (int y = 0; y < r.h; y++) {
        Uint8 *row = (Uint8 *)dst->pixels + (size_t)(r.y + y) * dst->pitch + (size_t)r.x * bpp;
        if (bpp == 1) {
            memset(row, (int)color, r.w);
        } else {
            for (int x = 0; x < r.w; x++) put_pixel(row + x * bpp, bpp, color);
        }
    }
    return 0;
}

static SDL_bool same_format(const SDL_PixelFormat *a, const SDL_PixelFormat *b)
{
    if (a->BitsPerPixel != b->BitsPerPixel) return SDL_FALSE;
    if (a->palette || b->palette) return SDL_TRUE; /* indexes copied as they are */
    return a->Rmask == b->Rmask && a->Gmask == b->Gmask && a->Bmask == b->Bmask ? SDL_TRUE : SDL_FALSE;
}

/* Rectangles already clipped: copied, converted where the formats differ,
   the color key left out; alpha is not blended */
int SDL_LowerBlit(SDL_Surface *src, SDL_Rect *srcrect, SDL_Surface *dst, SDL_Rect *dstrect)
{
    const SDL_PixelFormat *sf = src->format, *df = dst->format;
    int sb = sf->BytesPerPixel, db = df->BytesPerPixel;
    int w = srcrect->w, h = srcrect->h;
    SDL_bool same = same_format(sf, df), key = (src->flags & SDL_SRCCOLORKEY) ? SDL_TRUE : SDL_FALSE;
    for (int y = 0; y < h; y++) {
        const Uint8 *s = (const Uint8 *)src->pixels + (size_t)(srcrect->y + y) * src->pitch + (size_t)srcrect->x * sb;
        Uint8 *d = (Uint8 *)dst->pixels + (size_t)(dstrect->y + y) * dst->pitch + (size_t)dstrect->x * db;
        if (same && !key) {
            memmove(d, s, (size_t)w * sb);
            continue;
        }
        for (int x = 0; x < w; x++) {
            Uint32 c = get_pixel(s + x * sb, sb);
            if (key && c == sf->colorkey) continue;
            if (!same) {
                Uint8 r, g, b, a;
                SDL_GetRGBA(c, sf, &r, &g, &b, &a);
                c = SDL_MapRGBA(df, r, g, b, a);
            }
            put_pixel(d + x * db, db, c);
        }
    }
    return 0;
}

int SDL_UpperBlit(SDL_Surface *src, SDL_Rect *srcrect, SDL_Surface *dst, SDL_Rect *dstrect)
{
    if (src == NULL || dst == NULL) {
        SDL_SetError("SDL_UpperBlit: passed a NULL surface");
        return -1;
    }
    if (src->locked || dst->locked) {
        /* SDL 1.2 refuses locked surfaces; software ones need no lock */
    }
    SDL_Rect s = srcrect ? *srcrect : (SDL_Rect){0, 0, (Uint16)src->w, (Uint16)src->h};
    SDL_Rect full = {0, 0, (Uint16)src->w, (Uint16)src->h}, c;
    int dx = dstrect ? dstrect->x : 0, dy = dstrect ? dstrect->y : 0;
    /* the source inside itself, moving the destination with it */
    int ox = s.x, oy = s.y;
    if (!intersect(&s, &full, &c)) goto none;
    dx += c.x - ox, dy += c.y - oy;
    s = c;
    /* then the destination inside its clip rectangle */
    SDL_Rect d = {(Sint16)dx, (Sint16)dy, s.w, s.h};
    if (!intersect(&d, &dst->clip_rect, &c)) goto none;
    s.x = (Sint16)(s.x + c.x - d.x), s.y = (Sint16)(s.y + c.y - d.y);
    s.w = c.w, s.h = c.h;
    if (dstrect) *dstrect = c;
    return SDL_LowerBlit(src, &s, dst, &c);
none:
    if (dstrect) dstrect->w = dstrect->h = 0;
    return 0;
}

SDL_Surface *SDL_ConvertSurface(SDL_Surface *src, SDL_PixelFormat *fmt, Uint32 flags)
{
    SDL_Surface *n = new_surface(flags & (SDL_SRCCOLORKEY | SDL_SRCALPHA), src->w, src->h, fmt->BitsPerPixel, fmt->Rmask,
                                 fmt->Gmask, fmt->Bmask, fmt->Amask, NULL, 0);
    if (n == NULL) return NULL;
    if (fmt->palette && n->format->palette) {
        int k = fmt->palette->ncolors < n->format->palette->ncolors ? fmt->palette->ncolors : n->format->palette->ncolors;
        memcpy(n->format->palette->colors, fmt->palette->colors, (size_t)k * sizeof(SDL_Color));
    }
    Uint32 had = src->flags & SDL_SRCCOLORKEY;
    src->flags &= ~SDL_SRCCOLORKEY;
    SDL_Rect r = {0, 0, (Uint16)src->w, (Uint16)src->h}, d = r;
    SDL_LowerBlit(src, &r, n, &d);
    src->flags |= had;
    if (had) {
        Uint8 cr, cg, cb, ca;
        SDL_GetRGBA(src->format->colorkey, src->format, &cr, &cg, &cb, &ca);
        SDL_SetColorKey(n, SDL_SRCCOLORKEY, SDL_MapRGB(n->format, cr, cg, cb));
    }
    n->format->alpha = src->format->alpha;
    n->flags |= src->flags & SDL_SRCALPHA;
    return n;
}

SDL_Surface *SDL_DisplayFormat(SDL_Surface *s)
{
    if (v.screen == NULL) {
        SDL_SetError("No video mode has been set");
        return NULL;
    }
    return SDL_ConvertSurface(s, v.screen->format, s->flags & SDL_SRCCOLORKEY);
}

SDL_Surface *SDL_DisplayFormatAlpha(SDL_Surface *s)
{
    SDL_PixelFormat f;
    memset(&f, 0, sizeof(f));
    f.BitsPerPixel = 32;
    f.Rmask = 0xFF0000, f.Gmask = 0xFF00, f.Bmask = 0xFF, f.Amask = 0xFF000000;
    return SDL_ConvertSurface(s, &f, SDL_SRCALPHA);
}

/* THE SCREEN */

static void push_palette(int first, int count)
{
    SDL_Palette *p = v.screen->format->palette;
    Uint8 rgb[256 * 3];
    for (int i = 0; i < count; i++) {
        rgb[i * 3] = p->colors[first + i].r;
        rgb[i * 3 + 1] = p->colors[first + i].g;
        rgb[i * 3 + 2] = p->colors[first + i].b;
    }
    zdos_display_palette(first, count, rgb);
}

int SDL_SetPalette(SDL_Surface *s, int flags, SDL_Color *colors, int first, int n)
{
    if (s == NULL || s->format->palette == NULL || colors == NULL) return 0;
    SDL_Palette *p = s->format->palette;
    int ok = 1;
    if (first < 0) return 0;
    if (first + n > p->ncolors) {
        n = p->ncolors - first;
        ok = 0;
    }
    if (n <= 0) return 0;
    memcpy(&p->colors[first], colors, (size_t)n * sizeof(SDL_Color));
    if (s == v.screen && (flags & SDL_PHYSPAL)) push_palette(first, n);
    return ok;
}

int SDL_SetColors(SDL_Surface *s, SDL_Color *colors, int first, int n)
{
    return SDL_SetPalette(s, SDL_LOGPAL | SDL_PHYSPAL, colors, first, n);
}

static zdos_screen_info screen_info(void)
{
    zdos_screen_info s;
    if (!zdos->gfx->screen(&s)) {
        s.width = 320, s.height = 200;
        s.true_color = false;
    }
    return s;
}

void SDL12_VideoQuit(void)
{
    zdos_display_close();
    if (v.screen) {
        SDL_Surface *s = v.screen;
        v.screen = NULL;
        SDL_FreeSurface(s);
    }
    free(v.conv);
    v.conv = NULL;
}

SDL_Surface *SDL_SetVideoMode(int width, int height, int bpp, Uint32 flags)
{
    if (flags & SDL_OPENGL) {
        SDL_SetError("OpenGL not available");
        return NULL;
    }
    zdos_screen_info s = screen_info();
    if (width <= 0 || height <= 0) {
        width = (int)s.width;
        height = (int)s.height;
    }
    int native = s.true_color ? 32 : 8;
    if (bpp == 0) bpp = native;
    else if (bpp != 8 && bpp != 15 && bpp != 16 && bpp != 24 && bpp != 32) bpp = (flags & SDL_ANYFORMAT) ? native : bpp < 8 ? 8 : 32;
    v.format = bpp == 8 ? ZDOS_PIXELS_INDEX8 : bpp == 16 ? ZDOS_PIXELS_RGB565 : ZDOS_PIXELS_XRGB8888;
    v.crop_y = 0;
    v.shown_h = height;
    if (!s.true_color && width <= 320 && height > 200 && height <= 240) {
        v.shown_h = 200;
        v.crop_y = (height - 200) / 2;
    }
    SDL12_VideoQuit();
    SDL_Surface *n = new_surface(0, width, height, bpp, 0, 0, 0, 0, NULL, 0);
    if (n == NULL) return NULL;
    if (bpp == 15 || bpp == 24) {
        v.conv = malloc((size_t)width * height * 4);
        if (v.conv == NULL) {
            SDL_FreeSurface(n);
            SDL_OutOfMemory();
            return NULL;
        }
    }
    if (!zdos_display_open(width, v.shown_h, v.format)) {
        SDL_SetError("Couldn't set a %dx%d video mode", width, v.shown_h);
        SDL_FreeSurface(n);
        free(v.conv);
        v.conv = NULL;
        return NULL;
    }
    n->flags = SDL_SWSURFACE | (flags & (SDL_FULLSCREEN | SDL_DOUBLEBUF | SDL_RESIZABLE | SDL_NOFRAME | SDL_ANYFORMAT)) |
               (bpp == 8 ? SDL_HWPALETTE : 0);
    v.screen = n;
    if (bpp == 8) push_palette(0, 256);
    zdos_input_area(width, height);
    zdos_display_present(n->pixels, n->pitch); /* black */
    return n;
}

SDL_Surface *SDL_GetVideoSurface(void) { return v.screen; }

static void present(void)
{
    SDL_Surface *s = v.screen;
    int x, y, shown;
    SDL12_MouseCursor(&x, &y, &shown);
    zdos_display_cursor(x, y - v.crop_y, shown);
    const Uint8 *src = (const Uint8 *)s->pixels + (size_t)v.crop_y * s->pitch;
    if (v.conv == NULL) {
        zdos_display_present(src, s->pitch);
        return;
    }
    int bpp = s->format->BytesPerPixel;
    for (int r = 0; r < v.shown_h; r++) {
        const Uint8 *row = src + (size_t)r * s->pitch;
        uint32_t *out = v.conv + (size_t)r * s->w;
        for (int c = 0; c < s->w; c++) {
            Uint8 cr, cg, cb;
            SDL_GetRGB(get_pixel(row + c * bpp, bpp), s->format, &cr, &cg, &cb);
            out[c] = (uint32_t)cr << 16 | (uint32_t)cg << 8 | cb;
        }
    }
    zdos_display_present(v.conv, s->w * 4);
}

int SDL_Flip(SDL_Surface *s)
{
    if (s == NULL || s != v.screen) return -1;
    present();
    return 0;
}

void SDL_UpdateRects(SDL_Surface *s, int numrects, SDL_Rect *rects)
{
    (void)rects;
    if (s == v.screen && numrects > 0) present();
}

void SDL_UpdateRect(SDL_Surface *s, Sint32 x, Sint32 y, Uint32 w, Uint32 h)
{
    (void)x, (void)y, (void)w, (void)h;
    if (s == v.screen) present();
}

int SDL_VideoInit(const char *driver_name, Uint32 flags)
{
    (void)driver_name, (void)flags;
    return 0;
}

void SDL_VideoQuit(void) { SDL12_VideoQuit(); }

char *SDL_VideoDriverName(char *namebuf, int maxlen)
{
    if (namebuf == NULL || maxlen <= 0) return NULL;
    SDL_strlcpy(namebuf, "zdos", (size_t)maxlen);
    return namebuf;
}

const SDL_VideoInfo *SDL_GetVideoInfo(void)
{
    zdos_screen_info s = screen_info();
    SDL_PixelFormat *f = new_format(s.true_color ? 32 : 8, 0, 0, 0, 0);
    if (f) {
        free(v.vfmt.palette ? v.vfmt.palette->colors : NULL);
        free(v.vfmt.palette);
        v.vfmt = *f;
        free(f);
    }
    if (v.screen) {
        free(v.vfmt.palette ? v.vfmt.palette->colors : NULL);
        free(v.vfmt.palette);
        v.vfmt = *v.screen->format;
        v.vfmt.palette = NULL;
    }
    memset(&v.info, 0, sizeof(v.info));
    v.info.blit_sw = 1;
    v.info.blit_fill = 0;
    v.info.vfmt = &v.vfmt;
    v.info.current_w = (int)s.width;
    v.info.current_h = (int)s.height;
    return &v.info;
}

int SDL_VideoModeOK(int width, int height, int bpp, Uint32 flags)
{
    (void)width, (void)height;
    if (flags & SDL_OPENGL) return 0;
    if (bpp == 8 || bpp == 15 || bpp == 16 || bpp == 24 || bpp == 32) return bpp;
    return screen_info().true_color ? 32 : 8;
}

SDL_Rect **SDL_ListModes(SDL_PixelFormat *format, Uint32 flags)
{
    (void)format;
    if (flags & SDL_OPENGL) return NULL;
    return (SDL_Rect **)-1; /* any size: ZDOS scales the picture */
}

int SDL_SetGamma(float red, float green, float blue)
{
    (void)red, (void)green, (void)blue;
    SDL_SetError("Gamma correction not supported");
    return -1;
}

int SDL_SetGammaRamp(const Uint16 *red, const Uint16 *green, const Uint16 *blue)
{
    (void)red, (void)green, (void)blue;
    SDL_SetError("Gamma correction not supported");
    return -1;
}

int SDL_GetGammaRamp(Uint16 *red, Uint16 *green, Uint16 *blue)
{
    (void)red, (void)green, (void)blue;
    SDL_SetError("Gamma correction not supported");
    return -1;
}

int SDL_GL_LoadLibrary(const char *path)
{
    (void)path;
    SDL_SetError("OpenGL not available");
    return -1;
}

void *SDL_GL_GetProcAddress(const char *proc)
{
    (void)proc;
    return NULL;
}

int SDL_GL_SetAttribute(SDL_GLattr attr, int value)
{
    (void)attr, (void)value;
    SDL_SetError("OpenGL not available");
    return -1;
}

int SDL_GL_GetAttribute(SDL_GLattr attr, int *value)
{
    (void)attr;
    if (value) *value = 0;
    SDL_SetError("OpenGL not available");
    return -1;
}

void SDL_GL_SwapBuffers(void) {}

/* YUV OVERLAYS: NONE */

SDL_Overlay *SDL_CreateYUVOverlay(int width, int height, Uint32 format, SDL_Surface *display)
{
    (void)width, (void)height, (void)format, (void)display;
    SDL_SetError("YUV overlays not supported");
    return NULL;
}

int SDL_LockYUVOverlay(SDL_Overlay *overlay) { (void)overlay; return -1; }
void SDL_UnlockYUVOverlay(SDL_Overlay *overlay) { (void)overlay; }
int SDL_DisplayYUVOverlay(SDL_Overlay *overlay, SDL_Rect *dstrect) { (void)overlay, (void)dstrect; return -1; }
void SDL_FreeYUVOverlay(SDL_Overlay *overlay) { (void)overlay; }

/* WINDOW MANAGER: THE PROGRAM'S TAB */

void SDL_WM_SetCaption(const char *title, const char *icon)
{
    if (title) {
        SDL_strlcpy(v.title, title, sizeof(v.title));
        zdos->gfx->set_title(title, strlen(title));
    }
    if (icon) SDL_strlcpy(v.icon, icon, sizeof(v.icon));
}

void SDL_WM_GetCaption(char **title, char **icon)
{
    if (title) *title = v.title;
    if (icon) *icon = v.icon;
}

void SDL_WM_SetIcon(SDL_Surface *icon, Uint8 *mask) { (void)icon, (void)mask; }
int SDL_WM_IconifyWindow(void) { return 0; }

int SDL_WM_ToggleFullScreen(SDL_Surface *s)
{
    if (s == NULL || s != v.screen) return 0;
    s->flags ^= SDL_FULLSCREEN;
    return 1;
}

SDL_GrabMode SDL_WM_GrabInput(SDL_GrabMode mode)
{
    if (mode != SDL_GRAB_QUERY) v.grab = mode == SDL_GRAB_OFF ? SDL_GRAB_OFF : SDL_GRAB_ON;
    return v.grab;
}

int SDL_GetWMInfo(SDL_SysWMinfo *info)
{
    (void)info;
    SDL_SetError("No window system information");
    return 0;
}
