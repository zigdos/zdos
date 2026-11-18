/* Display, input and audio for ported libraries and games (SDL's backends,
   TinyGL, PortableGL): frames in common pixel formats shown on every
   edition, ZDOS's keys and mouse as an event queue, a sound feeding thread.
   On the API's groups gfx, keyb, console and sound; sdk/README.md has more. */
#ifndef ZDOS_MEDIA_H
#define ZDOS_MEDIA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Pixel formats, as 32-bit words in memory where 32 bits (little-endian) */
enum {
    ZDOS_PIXELS_XRGB8888, /* 0x00RRGGBB (SDL's RGB888 / ARGB8888; ZDOS's own) */
    ZDOS_PIXELS_XBGR8888, /* 0x00BBGGRR: bytes R, G, B (SDL's ABGR8888) */
    ZDOS_PIXELS_RGB565,   /* 16 bits */
    ZDOS_PIXELS_INDEX8,   /* palette indexes (zdos_display_palette) */
};
#define ZDOS_PIXELS_ARGB8888 ZDOS_PIXELS_XRGB8888 /* the alpha is ignored */
#define ZDOS_PIXELS_ABGR8888 ZDOS_PIXELS_XBGR8888

/* Where a picture goes on the screen */
typedef struct {
    int width, height;   /* the picture's */
    int out_w, out_h;    /* what ZDOS is given (scaled to fit) */
    bool true_color;     /* false: VGA (BIOS without VESA) */
    int colors;          /* true color: 0, else 256 or 16 */
} zdos_display_info;

/* Graphics for pictures of width x height in format, again for another size.
   A picture larger than the screen is scaled down to fit (nearest pixel, the
   shape kept), a smaller one is shown centered, scaled up by a whole number.
   BIOS: 320 x 200 in 256 colors (palette pictures as they are, others dithered
   to 3-3-2), larger ones in 640 x 480 with 16 colors (dithered). False with the
   reason in programs->last_error. */
bool zdos_display_open(int width, int height, int format);
/* INDEX8: colors first.. as red, green, blue bytes */
void zdos_display_palette(int first, int count, const uint8_t *rgb);
/* Shows a picture: rows of pitch bytes (0: width times the pixel size) */
void zdos_display_present(const void *pixels, int pitch);
/* ZDOS's arrow pointer (as gfx.zig's) drawn into each picture at x, y
   (the picture's pixels) */
void zdos_display_cursor(int x, int y, bool shown);
void zdos_display_get(zdos_display_info *info);
/* Back to text (the program's end does it too) */
void zdos_display_close(void);

enum {
    ZDOS_EVENT_KEY_DOWN = 1,  /* scancode, code, mods, repeat */
    ZDOS_EVENT_KEY_UP,
    ZDOS_EVENT_TEXT,          /* text: a character typed, UTF-8 */
    ZDOS_EVENT_MOUSE_MOTION,  /* x, y; dx, dy; button: the buttons held */
    ZDOS_EVENT_MOUSE_DOWN,    /* button: ZDOS_MOUSE_LEFT ...; x, y */
    ZDOS_EVENT_MOUSE_UP,
    ZDOS_EVENT_MOUSE_WHEEL,   /* dy steps, positive toward the user */
    ZDOS_EVENT_FOCUS_GAINED,  /* the program's tab came to the front */
    ZDOS_EVENT_FOCUS_LOST,    /* ... went behind another (Alt+Tab) */
};

typedef struct {
    uint8_t type;
    bool repeat;
    uint16_t scancode; /* a USB HID usage (keyboard page): SDL's scancodes */
    uint16_t code;     /* ZDOS's key code (set 1, 0xE0xx); 0 where made up */
    uint16_t mods;     /* ZDOS_MOD_* */
    int32_t x, y;      /* the mouse, in the picture (0 .. width - 1) */
    int32_t dx, dy;
    uint32_t button;
    char text[8];
} zdos_input_event;

/* The next event, false if none: reads ZDOS's keys and mouse when the
   queue is empty. Key events where ZDOS has them (metal, BIOS); on UEFI
   presses, their releases made up from the keyboard's repeat. */
bool zdos_input_poll(zdos_input_event *event);
/* Text events (ZDOS_EVENT_TEXT) on or off; off at the start */
void zdos_input_text(bool on);
/* The mouse's area (zdos_display_open sets it to the picture) and position */
void zdos_input_area(int width, int height);
void zdos_input_warp(int x, int y);
/* A ZDOS key code as a USB HID usage, 0 if unknown */
uint16_t zdos_key_to_hid(uint16_t code);

/* Fills len bytes of samples (on the sound thread) */
typedef void (*zdos_audio_fill)(void *user, uint8_t *buf, size_t len);

/* Plays rate Hz, channels 1-2, bits 8 (unsigned) or 16 (signed): a thread
   asks fill for frames frames at a time and writes them to the card. False
   with the reason in programs->last_error (no card, another program has it). */
bool zdos_audio_start(uint32_t rate, uint32_t channels, uint32_t bits, uint32_t frames, zdos_audio_fill fill, void *user);
/* Holds fill off while the program changes what it plays */
void zdos_audio_lock(void);
void zdos_audio_unlock(void);
void zdos_audio_stop(void);

#ifdef __cplusplus
}
#endif

#endif
