// doomgeneric's platform file for ZDOS.
// Graphics start with the first frame: the startup text stays readable.
// Where ZDOS sees no releases (UEFI), the keyboard's repeat makes them.
// Runs in ..\DATA\DOOM next to DOOM.APP's folder, or in that folder.

#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "zdos.h"

#include "d_event.h"
#include "doomgeneric.h"
#include "doomkeys.h"
#include "i_system.h"
#include "i_video.h"

// The version for ZDOS: config.h's PACKAGE_VERSION (build.sh),
// expanded before ZDOS_FILE_VERSION's #
#define DOOM_FILE_VERSION(a, b, c) ZDOS_FILE_VERSION(a, b, c, 0)
#define DOOM_FILE_VERSION_OF(a, b, c) DOOM_FILE_VERSION(a, b, c)
DOOM_FILE_VERSION_OF(ZDOS_DOOM_MAJOR, ZDOS_DOOM_MINOR, ZDOS_DOOM_PATCH);

static bool graphics_on;

void DG_Init(void)
{
}

void DG_DrawFrame(void)
{
    if (!graphics_on)
    {
        if (!zdos->gfx->begin(DOOMGENERIC_RESX, DOOMGENERIC_RESY))
        {
            I_Error("This screen can't show %dx%d graphics: %s", DOOMGENERIC_RESX, DOOMGENERIC_RESY,
                    zdos_error_message(zdos->programs->last_error()));
        }
        graphics_on = true;
        palette_changed = true;
    }
    if (palette_changed)
    {
        uint8_t rgb[256 * 3];
        for (int i = 0; i < 256; ++i)
        {
            rgb[i * 3] = colors[i].r;
            rgb[i * 3 + 1] = colors[i].g;
            rgb[i * 3 + 2] = colors[i].b;
        }
        zdos->gfx->palette(0, 256, rgb);
        palette_changed = false;
    }
    zdos->gfx->draw((const uint8_t *)DG_ScreenBuffer);
}

void DG_SetWindowTitle(const char *title)
{
    (void)title;
}

void DG_SleepMs(uint32_t ms)
{
    zdos->time->sleep(ms);
}

uint32_t DG_GetTicksMs(void)
{
    return (uint32_t)zdos->time->millis();
}

#define QUEUE_SIZE 64

static unsigned char queue_key[QUEUE_SIZE];
static bool queue_pressed[QUEUE_SIZE];
static int queue_start, queue_len;

static void push(bool pressed, unsigned char key)
{
    if (key == 0 || queue_len == QUEUE_SIZE)
    {
        return;
    }
    int i = (queue_start + queue_len) % QUEUE_SIZE;
    queue_key[i] = key;
    queue_pressed[i] = pressed;
    ++queue_len;
}

// Doom's key for a PC scan code (set 1; E0 keys as 0xE000 | code) WASD: W
// (0x11) forward, A (0x1E) strafe left, S (0x1F) back, D (0x20) strafe right
static unsigned char from_scan_code(uint16_t code)
{
    static const unsigned char main_keys[0x59] = {
        0, KEY_ESCAPE, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', KEY_BACKSPACE, KEY_TAB,
        'q', KEY_UPARROW, 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', KEY_ENTER, KEY_FIRE, KEY_STRAFE_L, KEY_DOWNARROW,
        KEY_STRAFE_R, 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`', KEY_RSHIFT, '\\', 'z', 'x', 'c', 'v',
        'b', 'n', 'm', KEY_STRAFE_L, KEY_STRAFE_R, '/', KEY_RSHIFT, KEYP_MULTIPLY, KEY_LALT, KEY_USE, KEY_CAPSLOCK, KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5,
        KEY_F6, KEY_F7, KEY_F8, KEY_F9, KEY_F10, KEY_NUMLOCK, KEY_SCRLCK, KEY_HOME, KEY_UPARROW, KEY_PGUP, KEYP_MINUS, KEY_LEFTARROW, '5', KEY_RIGHTARROW, KEYP_PLUS, KEY_END,
        KEY_DOWNARROW, KEY_PGDN, KEY_INS, KEY_DEL, 0, 0, '\\', KEY_F11, KEY_F12,
    };
    if (code < sizeof(main_keys))
    {
        return main_keys[code];
    }
    switch (code)
    {
        case 0xE01C: return KEY_ENTER; // keypad Enter
        case 0xE01D: return KEY_FIRE;  // right Ctrl
        case 0xE035: return '/';       // keypad /
        case 0xE038: return KEY_RALT;
        case 0xE047: return KEY_HOME;
        case 0xE048: return KEY_UPARROW;
        case 0xE049: return KEY_PGUP;
        case 0xE04B: return KEY_LEFTARROW;
        case 0xE04D: return KEY_RIGHTARROW;
        case 0xE04F: return KEY_END;
        case 0xE050: return KEY_DOWNARROW;
        case 0xE051: return KEY_PGDN;
        case 0xE052: return KEY_INS;
        case 0xE053: return KEY_DEL;
        default: return 0;
    }
}

// Doom's key for a ZDOS key press (the UEFI way)
static unsigned char from_key(zdos_key k)
{
    switch (k.scan)
    {
        case ZDOS_SCAN_UP: return KEY_UPARROW;
        case ZDOS_SCAN_DOWN: return KEY_DOWNARROW;
        case ZDOS_SCAN_LEFT: return KEY_LEFTARROW;
        case ZDOS_SCAN_RIGHT: return KEY_RIGHTARROW;
        case ZDOS_SCAN_HOME: return KEY_HOME;
        case ZDOS_SCAN_END: return KEY_END;
        case ZDOS_SCAN_INSERT: return KEY_INS;
        case ZDOS_SCAN_DELETE: return KEY_DEL;
        case ZDOS_SCAN_PAGE_UP: return KEY_PGUP;
        case ZDOS_SCAN_PAGE_DOWN: return KEY_PGDN;
        case ZDOS_SCAN_F11: return KEY_F11;
        case ZDOS_SCAN_F12: return KEY_F12;
        case ZDOS_SCAN_ESC: return KEY_ESCAPE;
        default: break;
    }
    if (k.scan >= ZDOS_SCAN_F1 && k.scan < ZDOS_SCAN_F1 + 10)
    {
        return (unsigned char)(KEY_F1 + (k.scan - ZDOS_SCAN_F1));
    }
    uint16_t c = k.char_;
    switch (c)
    {
        case 0: return 0;
        case '\r': return KEY_ENTER;
        case 0x08: return KEY_BACKSPACE;
        case '\t': return KEY_TAB;
        case 0x1B: return KEY_ESCAPE;
        case ' ': return KEY_USE;
        case '+': return '='; // the same key, for the screen size
        case '_': return '-';
        case ',': case '<': return KEY_STRAFE_L; // as in DOS Doom
        case '.': case '>': return KEY_STRAFE_R;
        // WASD (before the letter lowercasing below)
        case 'w': case 'W': return KEY_UPARROW;
        case 'a': case 'A': return KEY_STRAFE_L;
        case 's': case 'S': return KEY_DOWNARROW;
        case 'd': case 'D': return KEY_STRAFE_R;
        default: break;
    }
    if (c >= 1 && c <= 26)
    {
        return (unsigned char)('a' + c - 1); // Ctrl with a letter
    }
    if (c >= 'A' && c <= 'Z')
    {
        return (unsigned char)(c - 'A' + 'a');
    }
    return c < 0x7F ? (unsigned char)c : 0;
}

// Releases made up from key presses: a key counts as held while the
// keyboard repeats it. The first repeat comes only after a delay (about
// half a second), the next ones quickly. A press alone counts as held for
// first_hold_ms (-keyhold ms): short, so a tap turns only a little; a key
// held down then stops until the repeat starts, and goes on from there.
#define REPEAT_HOLD_MS 150

static uint32_t first_hold_ms = 300;

static uint32_t held_until[256];
static bool held[256];

static void hold(unsigned char key, uint32_t now)
{
    if (key == 0)
    {
        return;
    }
    if (!held[key])
    {
        held[key] = true;
        push(true, key);
        held_until[key] = now + first_hold_ms;
    }
    else
    {
        held_until[key] = now + REPEAT_HOLD_MS;
    }
}

static void poll_presses(void)
{
    uint32_t now = DG_GetTicksMs();
    zdos_key k;
    while (zdos->console->poll_key(&k))
    {
        hold(from_key(k), now);
        // Modifiers come with the keys they are held with
        if (k.mods & ZDOS_MOD_CTRL)
        {
            hold(KEY_FIRE, now);
        }
        if (k.mods & ZDOS_MOD_SHIFT)
        {
            hold(KEY_RSHIFT, now);
        }
        if (k.mods & ZDOS_MOD_ALT)
        {
            hold(KEY_RALT, now);
        }
    }
    for (int key = 0; key < 256; ++key)
    {
        if (held[key] && (int32_t)(now - held_until[key]) > 0)
        {
            held[key] = false;
            push(false, (unsigned char)key);
        }
    }
}

// 1: ZDOS has key_event, 0: it hasn't, -1: not known yet
static int real_events = -1;

static void poll_keys(void)
{
    if (real_events != 0)
    {
        zdos_key_event e;
        while (zdos->gfx->key_event(&e))
        {
            if (!e.repeat)
            {
                push(e.pressed, from_scan_code(e.code));
            }
        }
        if (real_events < 0)
        {
            real_events = zdos->programs->last_error() == ZDOS_ERROR_NOT_SUPPORTED ? 0 : 1;
        }
        if (real_events > 0)
        {
            return;
        }
    }
    poll_presses();
}

static bool no_mouse; // ZDOS has none here
static bool no_vertical; // -novert: moving the mouse forward doesn't walk
static uint32_t mouse_buttons;

// Doom asks for keys until there are none, once a tic: the mouse's movement
// since then goes along as one event
static void poll_mouse(void)
{
    zdos_mouse m;
    if (no_mouse)
    {
        return;
    }
    if (!zdos->gfx->mouse(&m))
    {
        no_mouse = true;
        return;
    }
    if (m.dx == 0 && m.dy == 0 && m.buttons == mouse_buttons)
    {
        return;
    }
    mouse_buttons = m.buttons;
    event_t event;
    event.type = ev_mouse;
    event.data1 = (int)(m.buttons & 7); // left, right, middle: Doom's order
    event.data2 = m.dx;
    event.data3 = no_vertical ? 0 : -m.dy; // forward is up
    event.data4 = 0;
    D_PostEvent(&event);
}

int DG_GetKey(int *pressed, unsigned char *key)
{
    if (queue_len == 0)
    {
        poll_keys();
        if (queue_len == 0)
        {
            poll_mouse();
            return 0;
        }
    }
    *pressed = queue_pressed[queue_start];
    *key = queue_key[queue_start];
    queue_start = (queue_start + 1) % QUEUE_SIZE;
    --queue_len;
    return 1;
}

// START AND END

static char start_dir[PATH_MAX];

static void restore_dir(void)
{
    if (start_dir[0] != '\0')
    {
        chdir(start_dir);
    }
}

// Doom's quit doesn't end the program by itself (I_Quit in i_system.c)
static void quit(void)
{
    exit(0);
}

// The data folder (see the top): into buf
static void find_data_dir(char *buf, size_t size)
{
    char path[PATH_MAX];
    size_t n = zdos->programs->program_path(path, sizeof(path) - 2);
    path[n] = '\0';
    char *slash = strrchr(path, '\\');
    if (slash == NULL)
    {
        snprintf(buf, size, ".");
        return;
    }
    *slash = '\0'; // C:\GAMES, the folder of DOOM.APP
    char *up = strrchr(path, '\\');
    if (up != NULL)
    {
        snprintf(buf, size, "%.*s\\DATA\\DOOM", (int)(up - path), path); // C:\DATA\DOOM
        struct stat st;
        if (stat(buf, &st) == 0 && S_ISDIR(st.st_mode))
        {
            return;
        }
    }
    if (slash > path && slash[-1] == ':')
    {
        strcpy(slash, "\\"); // DOOM.APP in a root: C:\, not C:
    }
    snprintf(buf, size, "%s", path);
}

static bool has_arg(int argc, char **argv, const char *name)
{
    for (int i = 1; i < argc; ++i)
    {
        if (strcasecmp(argv[i], name) == 0)
        {
            return true;
        }
    }
    return false;
}

int main(int argc, char **argv)
{
    // Ctrl is Doom's fire key: Ctrl+C mustn't end the game
    zdos->programs->set_ctrl_c(true);

    for (int i = 1; i + 1 < argc; ++i)
    {
        if (strcasecmp(argv[i], "-keyhold") == 0)
        {
            first_hold_ms = (uint32_t)atoi(argv[i + 1]);
        }
    }
    no_vertical = has_arg(argc, argv, "-novert");

    // Files named on the command line, from where Doom was started
    char **args = malloc((size_t)(argc + 8) * sizeof(char *));
    if (args == NULL)
    {
        printf("Not enough memory\n");
        return 1;
    }
    int n = 0;
    bool files = false;
    for (int i = 0; i < argc; ++i)
    {
        char *a = argv[i];
        if (a[0] == '-')
        {
            files = strcasecmp(a, "-iwad") == 0 || strcasecmp(a, "-file") == 0 || strcasecmp(a, "-deh") == 0 ||
                    strcasecmp(a, "-merge") == 0 || strcasecmp(a, "-playdemo") == 0 || strcasecmp(a, "-timedemo") == 0;
        }
        else if (files && i > 0)
        {
            char *full = realpath(a, NULL);
            if (full != NULL)
            {
                a = full;
            }
        }
        args[n++] = a;
    }
    if (!has_arg(argc, argv, "-config"))
    {
        args[n++] = "-config";
        args[n++] = "default.cfg";
    }
    if (!has_arg(argc, argv, "-extraconfig"))
    {
        args[n++] = "-extraconfig";
        args[n++] = "extra.cfg";
    }
    args[n++] = "-nogui"; // errors are printed, no dialog box
    args[n] = NULL;

    char data[PATH_MAX];
    find_data_dir(data, sizeof(data));
    if (getcwd(start_dir, sizeof(start_dir)) == NULL)
    {
        start_dir[0] = '\0';
    }
    atexit(restore_dir);
    if (chdir(data) != 0)
    {
        printf("Can't open the data folder %s\n", data);
        return 1;
    }
    printf("Data folder: %s\n", data);

    I_AtExit(quit, false); // registered first: runs after Doom's own ones

    doomgeneric_Create(n, args);
    for (;;)
    {
        doomgeneric_Tick();
    }
}
