/* The partial SDL 1.2's events: zdos_input_poll's keys (USB HID usages as
   SDL 1.2 keysyms, the keypad's keys always SDLK_KP*, whatever Num Lock),
   typed text as the keys' unicode, the mouse and the tab's focus, in a queue
   of SDL_Events */
#include "sdl12_internal.h"

#include "zdos.h"
#include "zdos_media.h"

#define QUEUE 256

static struct {
    SDL_Event q[QUEUE];
    int head, count;
    int unicode, repeat_delay, repeat_interval;
    Uint8 keys[SDLK_LAST];
    SDLMod mods;
    int mx, my, rx, ry, cursor;
    Uint8 buttons;
    Uint8 ignored[SDL_NUMEVENTS];
    SDL_EventFilter filter;
    Uint8 app_state;
} ev = {.cursor = 1, .app_state = SDL_APPMOUSEFOCUS | SDL_APPINPUTFOCUS | SDL_APPACTIVE};

void SDL12_MouseCursor(int *x, int *y, int *shown)
{
    *x = ev.mx, *y = ev.my, *shown = ev.cursor;
}

static SDLKey key_of(unsigned sc)
{
    static const char punct[] = "\r\x1b\b\t -=[]\\#;'`,./"; /* 0x28 .. 0x38 */
    if (sc >= 0x04 && sc <= 0x1D) return (SDLKey)(SDLK_a + sc - 0x04);
    if (sc >= 0x1E && sc <= 0x26) return (SDLKey)(SDLK_1 + sc - 0x1E);
    if (sc == 0x27) return SDLK_0;
    if (sc >= 0x28 && sc <= 0x38) return (SDLKey)(unsigned char)punct[sc - 0x28];
    if (sc >= 0x3A && sc <= 0x45) return (SDLKey)(SDLK_F1 + sc - 0x3A);
    if (sc >= 0x59 && sc <= 0x61) return (SDLKey)(SDLK_KP1 + sc - 0x59);
    if (sc >= 0x68 && sc <= 0x6A) return (SDLKey)(SDLK_F13 + sc - 0x68);
    switch (sc) {
    case 0x39: return SDLK_CAPSLOCK;
    case 0x46: return SDLK_PRINT;
    case 0x47: return SDLK_SCROLLOCK;
    case 0x48: return SDLK_PAUSE;
    case 0x49: return SDLK_INSERT;
    case 0x4A: return SDLK_HOME;
    case 0x4B: return SDLK_PAGEUP;
    case 0x4C: return SDLK_DELETE;
    case 0x4D: return SDLK_END;
    case 0x4E: return SDLK_PAGEDOWN;
    case 0x4F: return SDLK_RIGHT;
    case 0x50: return SDLK_LEFT;
    case 0x51: return SDLK_DOWN;
    case 0x52: return SDLK_UP;
    case 0x53: return SDLK_NUMLOCK;
    case 0x54: return SDLK_KP_DIVIDE;
    case 0x55: return SDLK_KP_MULTIPLY;
    case 0x56: return SDLK_KP_MINUS;
    case 0x57: return SDLK_KP_PLUS;
    case 0x58: return SDLK_KP_ENTER;
    case 0x62: return SDLK_KP0;
    case 0x63: return SDLK_KP_PERIOD;
    case 0x64: return SDLK_LESS;
    case 0x65: return SDLK_MENU;
    case 0x66: return SDLK_POWER;
    case 0x67: return SDLK_KP_EQUALS;
    case 0x75: return SDLK_HELP;
    case 0x7A: return SDLK_UNDO;
    case 0x9A: return SDLK_SYSREQ;
    case 0xE0: return SDLK_LCTRL;
    case 0xE1: return SDLK_LSHIFT;
    case 0xE2: return SDLK_LALT;
    case 0xE3: return SDLK_LSUPER;
    case 0xE4: return SDLK_RCTRL;
    case 0xE5: return SDLK_RSHIFT;
    case 0xE6: return SDLK_RALT;
    case 0xE7: return SDLK_RSUPER;
    }
    return SDLK_UNKNOWN;
}

static SDLMod mod_of(unsigned m)
{
    unsigned r = 0;
    if (m & ZDOS_MOD_LEFT_SHIFT) r |= KMOD_LSHIFT;
    if (m & ZDOS_MOD_RIGHT_SHIFT) r |= KMOD_RSHIFT;
    if (m & ZDOS_MOD_LEFT_CTRL) r |= KMOD_LCTRL;
    if (m & ZDOS_MOD_RIGHT_CTRL) r |= KMOD_RCTRL;
    if (m & ZDOS_MOD_LEFT_ALT) r |= KMOD_LALT;
    if (m & ZDOS_MOD_RIGHT_ALT) r |= KMOD_RALT;
    if (m & ZDOS_MOD_LEFT_LOGO) r |= KMOD_LMETA;
    if (m & ZDOS_MOD_RIGHT_LOGO) r |= KMOD_RMETA;
    if (m & ZDOS_MOD_NUM_LOCK) r |= KMOD_NUM;
    if (m & ZDOS_MOD_CAPS_LOCK) r |= KMOD_CAPS;
    return (SDLMod)r;
}

/* A key's character where no text event came with it: control keys, and
   US-layout ASCII */
static Uint16 ascii_of(SDLKey k, SDLMod m)
{
    static const char shifted[] = ")!@#$%^&*(";
    int shift = (m & KMOD_SHIFT) != 0;
    if (k == SDLK_BACKSPACE || k == SDLK_TAB || k == SDLK_RETURN || k == SDLK_ESCAPE || k == SDLK_DELETE) return (Uint16)k;
    if (m & KMOD_CTRL) return k >= SDLK_a && k <= SDLK_z ? (Uint16)(k - SDLK_a + 1) : 0;
    if (k >= SDLK_a && k <= SDLK_z) return (Uint16)((shift ^ ((m & KMOD_CAPS) != 0)) ? k - 32 : k);
    if (k >= SDLK_0 && k <= SDLK_9) return (Uint16)(shift ? shifted[k - SDLK_0] : k);
    if (k >= SDLK_KP0 && k <= SDLK_KP9) return (Uint16)((m & KMOD_NUM) ? '0' + k - SDLK_KP0 : 0);
    if (k >= 32 && k < 127) {
        static const char from[] = "-=[]\\;'`,./", to[] = "_+{}|:\"~<>?";
        const char *p = shift ? strchr(from, (int)k) : NULL;
        return (Uint16)(p ? to[p - from] : k);
    }
    switch (k) {
    case SDLK_KP_DIVIDE: return '/';
    case SDLK_KP_MULTIPLY: return '*';
    case SDLK_KP_MINUS: return '-';
    case SDLK_KP_PLUS: return '+';
    case SDLK_KP_ENTER: return '\r';
    case SDLK_KP_PERIOD: return (m & KMOD_NUM) ? '.' : 0;
    default: return 0;
    }
}

static Uint16 utf8_ucs2(const char *s)
{
    const unsigned char *u = (const unsigned char *)s;
    if (u[0] < 0x80) return u[0];
    if ((u[0] & 0xE0) == 0xC0) return (Uint16)((u[0] & 0x1F) << 6 | (u[1] & 0x3F));
    if ((u[0] & 0xF0) == 0xE0) return (Uint16)((u[0] & 0x0F) << 12 | (u[1] & 0x3F) << 6 | (u[2] & 0x3F));
    return 0; /* beyond UCS-2 */
}

static int push(const SDL_Event *e)
{
    if (ev.ignored[e->type]) return 0;
    if (ev.filter && !ev.filter(e)) return 0;
    if (ev.count == QUEUE) return -1;
    ev.q[(ev.head + ev.count++) % QUEUE] = *e;
    return 1;
}

/* Whether a key press types a character (the glue's text events come after
   the key events read with them, one per such press, repeats included) */
static int types_text(const zdos_input_event *z)
{
    unsigned sc = z->scancode;
    if (z->mods & (ZDOS_MOD_CTRL | ZDOS_MOD_ALT)) return 0;
    if ((sc >= 0x04 && sc <= 0x27) || (sc >= 0x2C && sc <= 0x38) || sc == 0x64) return 1;
    if (sc >= 0x54 && sc <= 0x57) return 1;
    if ((sc >= 0x59 && sc <= 0x63) || sc == 0x67) return (z->mods & ZDOS_MOD_NUM_LOCK) != 0;
    return 0;
}

static void key_event(const zdos_input_event *z, Uint16 text)
{
    int down = z->type == ZDOS_EVENT_KEY_DOWN;
    SDL_Event e;
    memset(&e, 0, sizeof(e));
    SDLKey k = key_of(z->scancode);
    if (down && z->repeat && ev.repeat_delay == 0) return; /* SDL 1.2: no repeats by default */
    e.type = down ? SDL_KEYDOWN : SDL_KEYUP;
    e.key.state = down ? SDL_PRESSED : SDL_RELEASED;
    e.key.keysym.scancode = (Uint8)z->scancode;
    e.key.keysym.sym = k;
    ev.mods = e.key.keysym.mod = mod_of(z->mods);
    if (k < SDLK_LAST) ev.keys[k] = e.key.state;
    if (down && ev.unicode) {
        e.key.keysym.unicode = text;
        if (text == 0 || (k >= SDLK_KP0 && k <= SDLK_KP_EQUALS && !(e.key.keysym.mod & KMOD_NUM)))
            e.key.keysym.unicode = ascii_of(k, e.key.keysym.mod);
    }
    push(&e);
}

void SDL_PumpEvents(void)
{
    /* What the glue has, at once: its text events are paired, in order,
       with the presses that typed them (taking the next event as a press's
       text gave it another key's character after repeats or overlapping
       keys, and DGen then released the wrong key on its release) */
    static zdos_input_event in[QUEUE];
    static Uint16 text[QUEUE];
    int n = 0, presses = 0, texts = 0;
    while (n < QUEUE / 2 && n < QUEUE - 2 - ev.count && zdos_input_poll(&in[n])) {
        presses += in[n].type == ZDOS_EVENT_KEY_DOWN && types_text(&in[n]);
        texts += in[n].type == ZDOS_EVENT_TEXT;
        text[n++] = 0;
    }
    if (presses == texts) {
        for (int i = 0, t = 0; i < n; i++) {
            if (in[i].type != ZDOS_EVENT_KEY_DOWN || !types_text(&in[i])) continue;
            while (in[t].type != ZDOS_EVENT_TEXT) t++;
            text[i] = utf8_ucs2(in[t++].text);
        }
    } /* else the US layout's characters (ascii_of) */
    SDL_Event e;
    for (int i = 0; i < n; i++) {
        const zdos_input_event z = in[i];
        memset(&e, 0, sizeof(e));
        switch (z.type) {
        case ZDOS_EVENT_KEY_DOWN:
        case ZDOS_EVENT_KEY_UP:
            key_event(&z, text[i]);
            break;
        case ZDOS_EVENT_MOUSE_MOTION:
            ev.rx += z.dx, ev.ry += z.dy;
            ev.mx = z.x, ev.my = z.y;
            e.type = SDL_MOUSEMOTION;
            e.motion.state = ev.buttons;
            e.motion.x = (Uint16)z.x, e.motion.y = (Uint16)z.y;
            e.motion.xrel = (Sint16)z.dx, e.motion.yrel = (Sint16)z.dy;
            push(&e);
            break;
        case ZDOS_EVENT_MOUSE_DOWN:
        case ZDOS_EVENT_MOUSE_UP: {
            Uint8 b = z.button == ZDOS_MOUSE_LEFT ? SDL_BUTTON_LEFT : z.button == ZDOS_MOUSE_RIGHT ? SDL_BUTTON_RIGHT : SDL_BUTTON_MIDDLE;
            int down = z.type == ZDOS_EVENT_MOUSE_DOWN;
            if (down) ev.buttons |= SDL_BUTTON(b);
            else ev.buttons &= ~SDL_BUTTON(b);
            e.type = down ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
            e.button.button = b;
            e.button.state = down ? SDL_PRESSED : SDL_RELEASED;
            e.button.x = (Uint16)ev.mx, e.button.y = (Uint16)ev.my;
            push(&e);
            break;
        }
        case ZDOS_EVENT_MOUSE_WHEEL:
            /* SDL 1.2: buttons 4 and 5, pressed and released */
            for (int n = z.dy < 0 ? -z.dy : z.dy; n > 0; n--) {
                e.button.button = z.dy < 0 ? SDL_BUTTON_WHEELUP : SDL_BUTTON_WHEELDOWN;
                e.button.x = (Uint16)ev.mx, e.button.y = (Uint16)ev.my;
                e.type = SDL_MOUSEBUTTONDOWN, e.button.state = SDL_PRESSED;
                push(&e);
                e.type = SDL_MOUSEBUTTONUP, e.button.state = SDL_RELEASED;
                push(&e);
            }
            break;
        case ZDOS_EVENT_FOCUS_GAINED:
        case ZDOS_EVENT_FOCUS_LOST:
            e.type = SDL_ACTIVEEVENT;
            e.active.gain = z.type == ZDOS_EVENT_FOCUS_GAINED;
            e.active.state = SDL_APPINPUTFOCUS | SDL_APPACTIVE;
            ev.app_state = e.active.gain ? (SDL_APPMOUSEFOCUS | SDL_APPINPUTFOCUS | SDL_APPACTIVE) : 0;
            if (!e.active.gain) memset(ev.keys, 0, sizeof(ev.keys)); /* a tab behind gets no releases */
            push(&e);
            break;
        }
    }
}

int SDL_PeepEvents(SDL_Event *events, int numevents, SDL_eventaction action, Uint32 mask)
{
    int n = 0;
    if (action == SDL_ADDEVENT) {
        for (; n < numevents && ev.count < QUEUE; n++) ev.q[(ev.head + ev.count++) % QUEUE] = events[n];
        return n;
    }
    for (int i = 0; i < ev.count && (events == NULL || n < numevents);) {
        SDL_Event *e = &ev.q[(ev.head + i) % QUEUE];
        if (!(SDL_EVENTMASK(e->type) & mask)) {
            i++;
            continue;
        }
        if (events) events[n] = *e;
        n++;
        if (action == SDL_GETEVENT) {
            /* close the gap */
            for (int j = i; j < ev.count - 1; j++) ev.q[(ev.head + j) % QUEUE] = ev.q[(ev.head + j + 1) % QUEUE];
            ev.count--;
        } else {
            i++;
        }
        if (events == NULL && action == SDL_PEEKEVENT) break;
    }
    return n;
}

int SDL_PollEvent(SDL_Event *event)
{
    SDL_PumpEvents();
    if (ev.count == 0) return 0;
    if (event) {
        *event = ev.q[ev.head];
        ev.head = (ev.head + 1) % QUEUE;
        ev.count--;
    }
    return 1;
}

int SDL_WaitEvent(SDL_Event *event)
{
    while (!SDL_PollEvent(event)) zdos->time->sleep(10);
    return 1;
}

int SDL_PushEvent(SDL_Event *event)
{
    if (ev.count == QUEUE) return -1;
    ev.q[(ev.head + ev.count++) % QUEUE] = *event;
    return 0;
}

void SDL_SetEventFilter(SDL_EventFilter filter) { ev.filter = filter; }
SDL_EventFilter SDL_GetEventFilter(void) { return ev.filter; }

Uint8 SDL_EventState(Uint8 type, int state)
{
    if (type >= SDL_NUMEVENTS) return SDL_IGNORE;
    Uint8 was = ev.ignored[type] ? SDL_IGNORE : SDL_ENABLE;
    if (state == SDL_IGNORE || state == SDL_ENABLE) {
        ev.ignored[type] = state == SDL_IGNORE;
        if (state == SDL_IGNORE) {
            SDL_Event drop;
            while (SDL_PeepEvents(&drop, 1, SDL_GETEVENT, SDL_EVENTMASK(type)) > 0) {}
        }
    }
    return was;
}

Uint8 SDL_GetAppState(void) { return ev.app_state; }

int SDL_EnableUNICODE(int enable)
{
    int was = ev.unicode;
    if (enable >= 0) {
        ev.unicode = enable != 0;
        zdos_input_text(ev.unicode);
    }
    return was;
}

int SDL_EnableKeyRepeat(int delay, int interval)
{
    if (delay < 0 || interval < 0) {
        SDL_SetError("keyboard repeat value less than zero");
        return -1;
    }
    ev.repeat_delay = delay;
    ev.repeat_interval = interval;
    return 0;
}

void SDL_GetKeyRepeat(int *delay, int *interval)
{
    if (delay) *delay = ev.repeat_delay;
    if (interval) *interval = ev.repeat_interval;
}

Uint8 *SDL_GetKeyState(int *numkeys)
{
    if (numkeys) *numkeys = SDLK_LAST;
    return ev.keys;
}

SDLMod SDL_GetModState(void) { return ev.mods; }
void SDL_SetModState(SDLMod modstate) { ev.mods = modstate; }

char *SDL_GetKeyName(SDLKey key)
{
    static char one[2];
    static const struct { SDLKey k; const char *name; } names[] = {
        {SDLK_BACKSPACE, "backspace"}, {SDLK_TAB, "tab"}, {SDLK_RETURN, "return"}, {SDLK_PAUSE, "pause"},
        {SDLK_ESCAPE, "escape"}, {SDLK_SPACE, "space"}, {SDLK_DELETE, "delete"},
        {SDLK_KP0, "[0]"}, {SDLK_KP1, "[1]"}, {SDLK_KP2, "[2]"}, {SDLK_KP3, "[3]"}, {SDLK_KP4, "[4]"},
        {SDLK_KP5, "[5]"}, {SDLK_KP6, "[6]"}, {SDLK_KP7, "[7]"}, {SDLK_KP8, "[8]"}, {SDLK_KP9, "[9]"},
        {SDLK_KP_PERIOD, "[.]"}, {SDLK_KP_DIVIDE, "[/]"}, {SDLK_KP_MULTIPLY, "[*]"}, {SDLK_KP_MINUS, "[-]"},
        {SDLK_KP_PLUS, "[+]"}, {SDLK_KP_ENTER, "enter"}, {SDLK_KP_EQUALS, "equals"},
        {SDLK_UP, "up"}, {SDLK_DOWN, "down"}, {SDLK_RIGHT, "right"}, {SDLK_LEFT, "left"},
        {SDLK_INSERT, "insert"}, {SDLK_HOME, "home"}, {SDLK_END, "end"}, {SDLK_PAGEUP, "page up"},
        {SDLK_PAGEDOWN, "page down"}, {SDLK_F1, "f1"}, {SDLK_F2, "f2"}, {SDLK_F3, "f3"}, {SDLK_F4, "f4"},
        {SDLK_F5, "f5"}, {SDLK_F6, "f6"}, {SDLK_F7, "f7"}, {SDLK_F8, "f8"}, {SDLK_F9, "f9"}, {SDLK_F10, "f10"},
        {SDLK_F11, "f11"}, {SDLK_F12, "f12"}, {SDLK_F13, "f13"}, {SDLK_F14, "f14"}, {SDLK_F15, "f15"},
        {SDLK_NUMLOCK, "numlock"}, {SDLK_CAPSLOCK, "caps lock"}, {SDLK_SCROLLOCK, "scroll lock"},
        {SDLK_RSHIFT, "right shift"}, {SDLK_LSHIFT, "left shift"}, {SDLK_RCTRL, "right ctrl"},
        {SDLK_LCTRL, "left ctrl"}, {SDLK_RALT, "right alt"}, {SDLK_LALT, "left alt"}, {SDLK_RMETA, "right meta"},
        {SDLK_LMETA, "left meta"}, {SDLK_LSUPER, "left super"}, {SDLK_RSUPER, "right super"},
        {SDLK_MODE, "alt gr"}, {SDLK_HELP, "help"}, {SDLK_PRINT, "print screen"}, {SDLK_SYSREQ, "sys req"},
        {SDLK_BREAK, "break"}, {SDLK_MENU, "menu"}, {SDLK_POWER, "power"}, {SDLK_UNDO, "undo"},
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++)
        if (names[i].k == key) return (char *)names[i].name;
    if (key > 32 && key < 127) {
        one[0] = (char)key;
        return one;
    }
    return (char *)"unknown key";
}

Uint8 SDL_GetMouseState(int *x, int *y)
{
    SDL_PumpEvents();
    if (x) *x = ev.mx;
    if (y) *y = ev.my;
    return ev.buttons;
}

Uint8 SDL_GetRelativeMouseState(int *x, int *y)
{
    SDL_PumpEvents();
    if (x) *x = ev.rx;
    if (y) *y = ev.ry;
    ev.rx = ev.ry = 0;
    return ev.buttons;
}

void SDL_WarpMouse(Uint16 x, Uint16 y)
{
    zdos_input_warp(x, y);
    ev.mx = x, ev.my = y;
}

static SDL_Cursor the_cursor;

SDL_Cursor *SDL_CreateCursor(Uint8 *data, Uint8 *mask, int w, int h, int hot_x, int hot_y)
{
    /* kept for SDL_GetCursor; ZDOS's arrow is drawn whatever it is */
    SDL_Cursor *c = calloc(1, sizeof(*c));
    if (c == NULL) return NULL;
    (void)data, (void)mask;
    c->area.w = (Uint16)w, c->area.h = (Uint16)h;
    c->hot_x = (Sint16)hot_x, c->hot_y = (Sint16)hot_y;
    return c;
}

void SDL_SetCursor(SDL_Cursor *cursor) { (void)cursor; }
SDL_Cursor *SDL_GetCursor(void) { return &the_cursor; }

void SDL_FreeCursor(SDL_Cursor *cursor)
{
    if (cursor != &the_cursor) free(cursor);
}

int SDL_ShowCursor(int toggle)
{
    int was = ev.cursor;
    if (toggle >= 0) ev.cursor = toggle != 0;
    return was;
}
