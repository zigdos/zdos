/* zdos_media.h's input: ZDOS's key events, typed text, the mouse and the
   tab's focus as one queue, keys as USB HID usages. On UEFI (no key events)
   presses come from poll_key and count as held while the keyboard repeats. */
#include <string.h>
#include "zdos.h"
#include "zdos_media.h"

/* Set 1 make codes 0x00-0x7F as HID usages */
static const uint8_t set1_hid[0x80] = {
    0, 0x29, 0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2D, 0x2E, 0x2A, 0x2B,
    0x14, 0x1A, 0x08, 0x15, 0x17, 0x1C, 0x18, 0x0C, 0x12, 0x13, 0x2F, 0x30, 0x28, 0xE0, 0x04, 0x16,
    0x07, 0x09, 0x0A, 0x0B, 0x0D, 0x0E, 0x0F, 0x33, 0x34, 0x35, 0xE1, 0x31, 0x1D, 0x1B, 0x06, 0x19,
    0x05, 0x11, 0x10, 0x36, 0x37, 0x38, 0xE5, 0x55, 0xE2, 0x2C, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E,
    0x3F, 0x40, 0x41, 0x42, 0x43, 0x53, 0x47, 0x5F, 0x60, 0x61, 0x56, 0x5C, 0x5D, 0x5E, 0x57, 0x59,
    0x5A, 0x5B, 0x62, 0x63, 0x46, 0, 0x64, 0x44, 0x45, 0x67, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0x88, 0, 0, 0x87, 0, 0, 0, 0, 0, 0x8A, 0, 0x8B, 0, 0x89, 0, 0,
};

uint16_t zdos_key_to_hid(uint16_t code) {
    if (code < 0x80) return set1_hid[code];
    switch (code) {
        case 0xE01C: return 0x58; /* keypad Enter */
        case 0xE01D: return 0xE4; /* right Ctrl */
        case 0xE020: return 0x7F; /* mute */
        case 0xE02E: return 0x81; /* volume down */
        case 0xE030: return 0x80; /* volume up */
        case 0xE035: return 0x54; /* keypad / */
        case 0xE037: return 0x46; /* Print Screen */
        case 0xE038: return 0xE6; /* right Alt */
        case 0xE047: return 0x4A;
        case 0xE048: return 0x52;
        case 0xE049: return 0x4B;
        case 0xE04B: return 0x50;
        case 0xE04D: return 0x4F;
        case 0xE04F: return 0x4D;
        case 0xE050: return 0x51;
        case 0xE051: return 0x4E;
        case 0xE052: return 0x49;
        case 0xE053: return 0x4C;
        case 0xE05B: return 0xE3; /* left Windows */
        case 0xE05C: return 0xE7;
        case 0xE05D: return 0x65; /* Menu */
        case 0xE11D: return 0x48; /* Pause */
        default: return 0;
    }
}

/* A key press from poll_key (UEFI), US layout */
static uint16_t press_to_hid(zdos_key k) {
    static const char punct[] = " !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";
    static const uint8_t punct_hid[] = {0x2C, 0x1E, 0x34, 0x20, 0x21, 0x22, 0x24, 0x34, 0x26, 0x27, 0x25,
                                        0x2E, 0x36, 0x2D, 0x37, 0x38, 0x33, 0x33, 0x36, 0x2E, 0x37, 0x38,
                                        0x1F, 0x2F, 0x31, 0x30, 0x23, 0x2D, 0x35, 0x2F, 0x31, 0x30, 0x35};
    switch (k.scan) {
        case ZDOS_SCAN_UP: return 0x52;
        case ZDOS_SCAN_DOWN: return 0x51;
        case ZDOS_SCAN_RIGHT: return 0x4F;
        case ZDOS_SCAN_LEFT: return 0x50;
        case ZDOS_SCAN_HOME: return 0x4A;
        case ZDOS_SCAN_END: return 0x4D;
        case ZDOS_SCAN_INSERT: return 0x49;
        case ZDOS_SCAN_DELETE: return 0x4C;
        case ZDOS_SCAN_PAGE_UP: return 0x4B;
        case ZDOS_SCAN_PAGE_DOWN: return 0x4E;
        case ZDOS_SCAN_F11: return 0x44;
        case ZDOS_SCAN_F12: return 0x45;
        case ZDOS_SCAN_ESC: return 0x29;
        default: break;
    }
    if (k.scan >= ZDOS_SCAN_F1 && k.scan < ZDOS_SCAN_F1 + 10) return (uint16_t)(0x3A + k.scan - ZDOS_SCAN_F1);
    uint16_t c = k.char_;
    if (c >= 1 && c <= 26 && (k.mods & ZDOS_MOD_CTRL)) return (uint16_t)(0x04 + c - 1);
    if (c >= 'a' && c <= 'z') return (uint16_t)(0x04 + c - 'a');
    if (c >= 'A' && c <= 'Z') return (uint16_t)(0x04 + c - 'A');
    if (c >= '1' && c <= '9') return (uint16_t)(0x1E + c - '1');
    if (c == '0') return 0x27;
    switch (c) {
        case '\r': return 0x28;
        case 0x08: return 0x2A;
        case '\t': return 0x2B;
        case 0x1B: return 0x29;
        case 0x7F: return 0x4C;
        default: break;
    }
    for (int i = 0; punct[i] != '\0'; i++) {
        if (punct[i] == c) return punct_hid[i];
    }
    return 0;
}

#define QUEUE_SIZE 128

static zdos_input_event queue[QUEUE_SIZE];
static int queue_start, queue_len;

static struct {
    int w, h, x, y;
    bool text;
    int real_keys; /* key events: 1 yes, 0 no (UEFI), -1 not known yet */
    bool no_mouse;
    uint32_t buttons;
    int focus; /* -1 not known yet */
    uint16_t mods;
} in = {0, 0, 0, 0, false, -1, false, 0, -1, 0};

static zdos_input_event *push(uint8_t type) {
    if (queue_len == QUEUE_SIZE) return NULL;
    zdos_input_event *e = &queue[(queue_start + queue_len++) % QUEUE_SIZE];
    memset(e, 0, sizeof(*e));
    e->type = type;
    e->mods = in.mods;
    e->x = in.x;
    e->y = in.y;
    return e;
}

static void push_key(bool down, bool repeat, uint16_t hid, uint16_t code) {
    if (hid == 0) return;
    zdos_input_event *e = push(down ? ZDOS_EVENT_KEY_DOWN : ZDOS_EVENT_KEY_UP);
    if (e == NULL) return;
    e->repeat = repeat;
    e->scancode = hid;
    e->code = code;
}

/* Text: one event per UTF-8 character */
static void push_text(const char *s, size_t n) {
    for (size_t i = 0; i < n;) {
        size_t len = ((uint8_t)s[i] & 0xE0) == 0xC0 ? 2 : ((uint8_t)s[i] & 0xF0) == 0xE0 ? 3 : ((uint8_t)s[i] & 0xF8) == 0xF0 ? 4 : 1;
        if (i + len > n) break;
        zdos_input_event *e = push(ZDOS_EVENT_TEXT);
        if (e == NULL) return;
        memcpy(e->text, s + i, len);
        i += len;
    }
}

/* UEFI: PRESSES HELD WHILE THEY REPEAT */

#define FIRST_HOLD_MS 300
#define REPEAT_HOLD_MS 150

static bool held[256];
static uint32_t held_until[256];

static void hold(uint16_t hid, uint32_t now) {
    if (hid == 0 || hid > 255) return;
    push_key(true, held[hid], hid, 0);
    held_until[hid] = now + (held[hid] ? REPEAT_HOLD_MS : FIRST_HOLD_MS);
    held[hid] = true;
}

static void poll_presses(void) {
    uint32_t now = (uint32_t)zdos->time->millis();
    zdos_key k;
    while (zdos->console->poll_key(&k)) {
        in.mods = k.mods;
        /* Modifiers come with the keys they are held with */
        static const uint16_t mod_bit[8] = {ZDOS_MOD_LEFT_CTRL, ZDOS_MOD_LEFT_SHIFT, ZDOS_MOD_LEFT_ALT, ZDOS_MOD_LEFT_LOGO,
                                            ZDOS_MOD_RIGHT_CTRL, ZDOS_MOD_RIGHT_SHIFT, ZDOS_MOD_RIGHT_ALT, ZDOS_MOD_RIGHT_LOGO};
        for (int i = 0; i < 8; i++) {
            if ((k.mods & mod_bit[i]) && !held[0xE0 + i]) hold((uint16_t)(0xE0 + i), now);
            else if (k.mods & mod_bit[i]) held_until[0xE0 + i] = now + REPEAT_HOLD_MS;
        }
        hold(press_to_hid(k), now);
        uint16_t c = k.char_;
        if (in.text && c >= 0x20 && c != 0x7F && !(k.mods & (ZDOS_MOD_CTRL | ZDOS_MOD_ALT))) {
            char utf8[3];
            size_t n;
            if (c < 0x80) utf8[0] = (char)c, n = 1;
            else if (c < 0x800) utf8[0] = (char)(0xC0 | c >> 6), utf8[1] = (char)(0x80 | (c & 63)), n = 2;
            else utf8[0] = (char)(0xE0 | c >> 12), utf8[1] = (char)(0x80 | ((c >> 6) & 63)), utf8[2] = (char)(0x80 | (c & 63)), n = 3;
            push_text(utf8, n);
        }
    }
    for (int hid = 0; hid < 256; hid++) {
        if (held[hid] && (int32_t)(now - held_until[hid]) > 0) {
            held[hid] = false;
            push_key(false, false, (uint16_t)hid, 0);
        }
    }
}

static void pump(void) {
    bool front = zdos->gfx->visible();
    if (in.focus != (int)front) {
        if (in.focus >= 0 || !front) push(front ? ZDOS_EVENT_FOCUS_GAINED : ZDOS_EVENT_FOCUS_LOST);
        in.focus = front;
    }
    if (!front) return; /* a tab behind gets no input */
    if (in.real_keys != 0) {
        zdos_key_event k;
        while (zdos->gfx->key_event(&k)) {
            in.mods = k.mods;
            push_key(k.pressed, k.repeat, zdos_key_to_hid(k.code), k.code);
        }
        if (in.real_keys < 0) in.real_keys = zdos->programs->last_error() == ZDOS_ERROR_NOT_SUPPORTED ? 0 : 1;
        if (in.real_keys > 0 && in.text) {
            char buf[64];
            size_t n;
            while ((n = zdos->gfx->text_input(buf, sizeof(buf))) > 0) push_text(buf, n);
        }
    }
    if (in.real_keys == 0) poll_presses();
    if (in.no_mouse) return;
    zdos_mouse m;
    if (!zdos->gfx->mouse(&m)) {
        in.no_mouse = zdos->programs->last_error() == ZDOS_ERROR_NOT_SUPPORTED;
        return;
    }
    if (m.dx != 0 || m.dy != 0) {
        in.x += m.dx;
        in.y += m.dy;
        if (in.w > 0) {
            if (in.x < 0) in.x = 0;
            if (in.y < 0) in.y = 0;
            if (in.x >= in.w) in.x = in.w - 1;
            if (in.y >= in.h) in.y = in.h - 1;
        }
        zdos_input_event *e = push(ZDOS_EVENT_MOUSE_MOTION);
        if (e != NULL) e->dx = m.dx, e->dy = m.dy, e->button = m.buttons;
    }
    for (uint32_t b = 1; b <= 4; b <<= 1) {
        if ((m.buttons ^ in.buttons) & b) {
            zdos_input_event *e = push(m.buttons & b ? ZDOS_EVENT_MOUSE_DOWN : ZDOS_EVENT_MOUSE_UP);
            if (e != NULL) e->button = b;
        }
    }
    in.buttons = m.buttons;
    if (m.wheel != 0) {
        zdos_input_event *e = push(ZDOS_EVENT_MOUSE_WHEEL);
        if (e != NULL) e->dy = m.wheel;
    }
}

bool zdos_input_poll(zdos_input_event *event) {
    if (queue_len == 0) pump();
    if (queue_len == 0) return false;
    *event = queue[queue_start];
    queue_start = (queue_start + 1) % QUEUE_SIZE;
    queue_len--;
    return true;
}

void zdos_input_text(bool on) {
    in.text = on;
}

void zdos_input_area(int width, int height) {
    bool first = in.w == 0;
    in.w = width;
    in.h = height;
    if (first || in.x >= width || in.y >= height) zdos_input_warp(width / 2, height / 2);
}

void zdos_input_warp(int x, int y) {
    in.x = x;
    in.y = y;
}
