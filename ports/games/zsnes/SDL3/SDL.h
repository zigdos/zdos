/* ZDOS: the SDL 3 calls ZSNES 2 makes (unix/), on SDL 2 (ports/graphics/SDL).
   Names that SDL 2 has with other arguments or results go
   through zs3_ functions; SDL 3's events are translated from
   SDL 2's in SDL_PollEvent. No joysticks (ZDOS has none),
   properties, HDR or Vulkan. */
#ifndef ZDOS_SDL3_COMPAT_H
#define ZDOS_SDL3_COMPAT_H

#include <SDL.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

/* Start, hints */
static inline bool zs3_Init(Uint32 f) { return SDL_Init(f) == 0; }
static inline bool zs3_InitSubSystem(Uint32 f) { return SDL_InitSubSystem(f) == 0; }
#define SDL_Init zs3_Init
#define SDL_InitSubSystem zs3_InitSubSystem
#define SDL_INIT_GAMEPAD SDL_INIT_GAMECONTROLLER
#define SDL_HINT_AUDIO_DRIVER "SDL_AUDIODRIVER"
static inline Uint64 zs3_GetTicks(void) { return SDL_GetTicks64(); }
#define SDL_GetTicks zs3_GetTicks

/* Displays: SDL 3's ids are SDL 2's indexes + 1 */
typedef Uint32 SDL_DisplayID;
typedef Uint32 SDL_PropertiesID;
static inline SDL_DisplayID* zs3_GetDisplays(int* count)
{
    int n = SDL_GetNumVideoDisplays();
    SDL_DisplayID* ids;
    if (n < 0) {
        n = 0;
    }
    ids = (SDL_DisplayID*)SDL_calloc((size_t)n + 1, sizeof(*ids));
    for (int i = 0; ids && i < n; i++) {
        ids[i] = (SDL_DisplayID)i + 1;
    }
    if (count) {
        *count = ids ? n : 0;
    }
    return ids;
}
static inline char const* zs3_GetDisplayName(SDL_DisplayID id) { return SDL_GetDisplayName((int)id - 1); }
static inline SDL_DisplayID zs3_GetDisplayForWindow(SDL_Window* w) { return (SDL_DisplayID)(SDL_GetWindowDisplayIndex(w) + 1); }
static inline SDL_DisplayMode const* zs3_GetCurrentDisplayMode(SDL_DisplayID id)
{
    static SDL_DisplayMode mode;
    return SDL_GetCurrentDisplayMode((int)id - 1, &mode) == 0 ? &mode : NULL;
}
#define SDL_GetDisplays zs3_GetDisplays
#define SDL_GetDisplayName zs3_GetDisplayName
#define SDL_GetDisplayForWindow zs3_GetDisplayForWindow
#define SDL_GetCurrentDisplayMode zs3_GetCurrentDisplayMode

/* Properties: none */
#define SDL_PROP_DISPLAY_HDR_ENABLED_BOOLEAN "hdr"
#define SDL_PROP_RENDERER_HDR_ENABLED_BOOLEAN "hdr"
#define SDL_PROP_RENDERER_HDR_HEADROOM_FLOAT "headroom"
#define SDL_PROP_RENDERER_CREATE_WINDOW_POINTER "window"
#define SDL_PROP_RENDERER_CREATE_NAME_STRING "name"
#define SDL_PROP_RENDERER_CREATE_OUTPUT_COLORSPACE_NUMBER "colorspace"
#define SDL_COLORSPACE_SRGB_LINEAR 0
static inline SDL_PropertiesID SDL_CreateProperties(void) { return 0; }
static inline void SDL_DestroyProperties(SDL_PropertiesID p) { (void)p; }
static inline SDL_PropertiesID SDL_GetDisplayProperties(SDL_DisplayID d) { (void)d; return 0; }
static inline SDL_PropertiesID SDL_GetRendererProperties(SDL_Renderer* r) { (void)r; return 0; }
static inline bool SDL_GetBooleanProperty(SDL_PropertiesID p, char const* n, bool d) { (void)p; (void)n; return d; }
static inline float SDL_GetFloatProperty(SDL_PropertiesID p, char const* n, float d) { (void)p; (void)n; return d; }
static inline bool SDL_SetPointerProperty(SDL_PropertiesID p, char const* n, void* v) { (void)p; (void)n; (void)v; return false; }
static inline bool SDL_SetStringProperty(SDL_PropertiesID p, char const* n, char const* v) { (void)p; (void)n; (void)v; return false; }
static inline bool SDL_SetNumberProperty(SDL_PropertiesID p, char const* n, Sint64 v) { (void)p; (void)n; (void)v; return false; }

/* Windows, surfaces, the mouse */
static inline SDL_Window* zs3_CreateWindow(char const* title, int w, int h, Uint32 flags)
{
    return SDL_CreateWindow(title, SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, w, h, flags);
}
static inline bool zs3_SetWindowFullscreen(SDL_Window* w, bool on) { return SDL_SetWindowFullscreen(w, on ? SDL_WINDOW_FULLSCREEN : 0) == 0; }
static inline bool zs3_StartTextInput(SDL_Window* w) { (void)w; SDL_StartTextInput(); return true; }
static inline SDL_Surface* zs3_CreateSurface(int w, int h, Uint32 format)
{
    return SDL_CreateRGBSurfaceWithFormat(0, w, h, SDL_BITSPERPIXEL(format), format);
}
#define SDL_CreateWindow zs3_CreateWindow
#define SDL_SetWindowFullscreen zs3_SetWindowFullscreen
#define SDL_StartTextInput zs3_StartTextInput
#define SDL_CreateSurface zs3_CreateSurface
#define SDL_SyncWindow(w) ((void)(w), true)
#define SDL_DestroySurface SDL_FreeSurface
#define SDL_HideCursor() (SDL_ShowCursor(SDL_DISABLE), true)
#define SDL_SCALEMODE_NEAREST SDL_ScaleModeNearest
#define SDL_SCALEMODE_LINEAR SDL_ScaleModeLinear
/* SDL 2 scales software blits to the nearest pixel only */
#define SDL_BlitSurfaceScaled(s, sr, d, dr, mode) ((void)(mode), SDL_BlitScaled(s, sr, d, dr) == 0)
static inline Uint32 zs3_GetRelativeMouseState(float* x, float* y)
{
    int ix, iy;
    Uint32 b = SDL_GetRelativeMouseState(&ix, &iy);
    if (x) {
        *x = (float)ix;
    }
    if (y) {
        *y = (float)iy;
    }
    return b;
}
#define SDL_GetRelativeMouseState zs3_GetRelativeMouseState

/* The renderer (unix/sdl_render.c; used only with OpenGL modes) */
#define SDL_PIXELFORMAT_RGBA128_FLOAT SDL_PIXELFORMAT_UNKNOWN
#define SDL_RENDERER_VSYNC_DISABLED 0
#define SDL_RENDERER_VSYNC_ADAPTIVE (-1)
static inline bool zs3_SetRenderVSync(SDL_Renderer* r, int v) { return v >= 0 && SDL_RenderSetVSync(r, v) == 0; }
static inline bool zs3_LockTexture(SDL_Texture* t, SDL_Rect const* r, void** p, int* pitch) { return SDL_LockTexture(t, r, p, pitch) == 0; }
static inline bool zs3_RenderTexture(SDL_Renderer* r, SDL_Texture* t, SDL_FRect const* s, SDL_FRect const* d)
{
    SDL_Rect src;
    if (s) {
        src.x = (int)s->x;
        src.y = (int)s->y;
        src.w = (int)s->w;
        src.h = (int)s->h;
    }
    return SDL_RenderCopyF(r, t, s ? &src : NULL, d) == 0;
}
static inline SDL_Surface* zs3_RenderReadPixels(SDL_Renderer* r, SDL_Rect const* rect) { (void)r; (void)rect; return NULL; }
static inline SDL_Renderer* SDL_CreateRendererWithProperties(SDL_PropertiesID p) { (void)p; SDL_SetError("no renderer properties"); return NULL; }
static inline char const* zs3_GetRenderDriver(int i)
{
    SDL_RendererInfo info;
    return SDL_GetRenderDriverInfo(i, &info) == 0 ? info.name : NULL;
}
#define SDL_SetRenderVSync zs3_SetRenderVSync
#define SDL_LockTexture zs3_LockTexture
#define SDL_RenderTexture zs3_RenderTexture
#define SDL_RenderReadPixels zs3_RenderReadPixels
#define SDL_GetRenderDriver zs3_GetRenderDriver

/* Semaphores */
#define SDL_Semaphore SDL_sem
#define SDL_SignalSemaphore(s) SDL_SemPost(s)
#define SDL_WaitSemaphoreTimeout(s, ms) (SDL_SemWaitTimeout(s, (Uint32)(ms)) == 0)

/* Joysticks and gamepads: none on ZDOS */
typedef struct zs3_Gamepad SDL_Gamepad;
enum {
    SDL_GAMEPAD_BUTTON_SOUTH,
    SDL_GAMEPAD_BUTTON_EAST,
    SDL_GAMEPAD_BUTTON_WEST,
    SDL_GAMEPAD_BUTTON_NORTH,
    SDL_GAMEPAD_BUTTON_BACK,
    SDL_GAMEPAD_BUTTON_START,
    SDL_GAMEPAD_BUTTON_LEFT_SHOULDER,
    SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER,
    SDL_GAMEPAD_BUTTON_DPAD_UP,
    SDL_GAMEPAD_BUTTON_DPAD_DOWN,
    SDL_GAMEPAD_BUTTON_DPAD_LEFT,
    SDL_GAMEPAD_BUTTON_DPAD_RIGHT
};
enum {
    SDL_GAMEPAD_AXIS_LEFTX,
    SDL_GAMEPAD_AXIS_LEFTY,
    SDL_GAMEPAD_AXIS_LEFT_TRIGGER,
    SDL_GAMEPAD_AXIS_RIGHT_TRIGGER
};
static inline SDL_JoystickID* SDL_GetJoysticks(int* count)
{
    if (count) {
        *count = 0;
    }
    return NULL;
}
#define SDL_SetJoystickEventsEnabled(on) ((void)(on))
#define SDL_SetGamepadEventsEnabled(on) ((void)(on))
#define SDL_IsGamepad(id) ((void)(id), false)
#define SDL_OpenGamepad(id) ((void)(id), (SDL_Gamepad*)NULL)
#define SDL_OpenJoystick(id) ((void)(id), (SDL_Joystick*)NULL)
#define SDL_CloseGamepad(g) ((void)(g))
#define SDL_CloseJoystick(j) ((void)(j))
#define SDL_GetGamepadName(g) ((void)(g), "")
#define SDL_GetJoystickName(j) ((void)(j), "")
#define SDL_GetNumJoystickAxes(j) ((void)(j), 0)
#define SDL_GetNumJoystickButtons(j) ((void)(j), 0)
#define SDL_GetNumJoystickHats(j) ((void)(j), 0)
#define SDL_GamepadConnected(g) ((void)(g), false)
#define SDL_GetGamepadButton(g, b) ((void)(g), (void)(b), false)
#define SDL_GetGamepadAxis(g, a) ((void)(g), (void)(a), (Sint16)0)
#define SDL_RumbleGamepad(g, l, h, ms) ((void)(g), (void)(l), (void)(h), (void)(ms), false)
#define SDL_RumbleJoystick(j, l, h, ms) ((void)(j), (void)(l), (void)(h), (void)(ms), false)

/* Audio: SDL 3's stream bound to the default device, as SDL 2's queue */
typedef struct zs3_AudioStream {
    SDL_AudioDeviceID dev;
    SDL_AudioSpec have;
} zs3_AudioStream;
#define SDL_AudioStream zs3_AudioStream
#define SDL_AUDIO_S16LE AUDIO_S16LSB
#define SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK 0
static inline zs3_AudioStream* SDL_OpenAudioDeviceStream(SDL_AudioDeviceID d, SDL_AudioSpec const* spec, void* cb, void* user)
{
    SDL_AudioSpec want;
    zs3_AudioStream* s = (zs3_AudioStream*)SDL_calloc(1, sizeof(*s));
    (void)d;
    (void)cb;
    (void)user;
    if (!s) {
        return NULL;
    }
    SDL_zero(want);
    want.freq = spec->freq;
    want.format = spec->format;
    want.channels = spec->channels;
    want.samples = 1024;
    /* No changes allowed: SDL converts what is queued to the card's format */
    s->dev = SDL_OpenAudioDevice(NULL, 0, &want, &s->have, 0);
    if (s->dev == 0) {
        SDL_free(s);
        return NULL;
    }
    return s;
}
static inline void SDL_DestroyAudioStream(zs3_AudioStream* s)
{
    if (s) {
        SDL_CloseAudioDevice(s->dev);
        SDL_free(s);
    }
}
static inline bool SDL_ResumeAudioStreamDevice(zs3_AudioStream* s) { SDL_PauseAudioDevice(s->dev, 0); return true; }
static inline bool SDL_PutAudioStreamData(zs3_AudioStream* s, void const* buf, int len) { return SDL_QueueAudio(s->dev, buf, (Uint32)len) == 0; }
static inline int SDL_GetAudioStreamQueued(zs3_AudioStream* s) { return (int)SDL_GetQueuedAudioSize(s->dev); }
static inline bool SDL_SetAudioStreamFrequencyRatio(zs3_AudioStream* s, float r) { (void)s; (void)r; return false; }
static inline zs3_AudioStream* SDL_GetAudioStreamDevice(zs3_AudioStream* s) { return s; }
static inline bool SDL_GetAudioDeviceFormat(zs3_AudioStream* s, SDL_AudioSpec* spec, int* frames)
{
    *spec = s->have;
    if (frames) {
        *frames = s->have.samples;
    }
    return true;
}

/* Keys */
#define SDL_KMOD_ALT KMOD_ALT
#define SDL_KMOD_NUM KMOD_NUM
#define SDLK_APOSTROPHE SDLK_QUOTE
#define SDLK_GRAVE SDLK_BACKQUOTE
#define SDLK_A SDLK_a
#define SDLK_B SDLK_b
#define SDLK_C SDLK_c
#define SDLK_D SDLK_d
#define SDLK_E SDLK_e
#define SDLK_F SDLK_f
#define SDLK_G SDLK_g
#define SDLK_H SDLK_h
#define SDLK_I SDLK_i
#define SDLK_J SDLK_j
#define SDLK_K SDLK_k
#define SDLK_L SDLK_l
#define SDLK_M SDLK_m
#define SDLK_N SDLK_n
#define SDLK_O SDLK_o
#define SDLK_P SDLK_p
#define SDLK_Q SDLK_q
#define SDLK_R SDLK_r
#define SDLK_S SDLK_s
#define SDLK_T SDLK_t
#define SDLK_U SDLK_u
#define SDLK_V SDLK_v
#define SDLK_W SDLK_w
#define SDLK_X SDLK_x
#define SDLK_Y SDLK_y
#define SDLK_Z SDLK_z

/* Events: SDL 3's layout, the types SDL 3 names */
enum {
    SDL_EVENT_QUIT = SDL_QUIT,
    SDL_EVENT_KEY_DOWN = SDL_KEYDOWN,
    SDL_EVENT_KEY_UP = SDL_KEYUP,
    SDL_EVENT_TEXT_INPUT = SDL_TEXTINPUT,
    SDL_EVENT_MOUSE_MOTION = SDL_MOUSEMOTION,
    SDL_EVENT_MOUSE_BUTTON_DOWN = SDL_MOUSEBUTTONDOWN,
    SDL_EVENT_MOUSE_BUTTON_UP = SDL_MOUSEBUTTONUP,
    SDL_EVENT_MOUSE_WHEEL = SDL_MOUSEWHEEL,
    SDL_EVENT_JOYSTICK_AXIS_MOTION = SDL_JOYAXISMOTION,
    SDL_EVENT_JOYSTICK_HAT_MOTION = SDL_JOYHATMOTION,
    SDL_EVENT_JOYSTICK_BUTTON_DOWN = SDL_JOYBUTTONDOWN,
    SDL_EVENT_JOYSTICK_BUTTON_UP = SDL_JOYBUTTONUP,
    SDL_EVENT_JOYSTICK_ADDED = SDL_JOYDEVICEADDED,
    SDL_EVENT_JOYSTICK_REMOVED = SDL_JOYDEVICEREMOVED,
    /* SDL 2's window events are subtypes of SDL_WINDOWEVENT */
    SDL_EVENT_WINDOW_FOCUS_GAINED = SDL_LASTEVENT - 16,
    SDL_EVENT_WINDOW_FOCUS_LOST,
    SDL_EVENT_WINDOW_MOUSE_ENTER,
    SDL_EVENT_WINDOW_RESIZED,
    SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED
};
typedef struct zs3_KeyboardEvent {
    Uint32 type;
    SDL_Scancode scancode;
    SDL_Keycode key;
    Uint16 mod;
    bool down;
    bool repeat;
} zs3_KeyboardEvent;
typedef union zs3_Event {
    Uint32 type;
    zs3_KeyboardEvent key;
    struct { Uint32 type; char text[SDL_TEXTINPUTEVENT_TEXT_SIZE]; } text;
    struct { Uint32 type; float x, y, xrel, yrel; } motion;
    struct { Uint32 type; Uint8 button; } button;
    struct { Uint32 type; float x, y; } wheel;
    struct { Uint32 type; Sint32 data1, data2; } window;
    struct { Uint32 type; SDL_JoystickID which; Uint8 value; } jhat;
    struct { Uint32 type; SDL_JoystickID which; Uint8 axis; Sint16 value; } jaxis;
    struct { Uint32 type; SDL_JoystickID which; Uint8 button; } jbutton;
    struct { Uint32 type; SDL_JoystickID which; } jdevice;
} zs3_Event;
typedef SDL_Event zs3_SDL2Event;
#define SDL_KeyboardEvent zs3_KeyboardEvent
#define SDL_Event zs3_Event

static inline bool zs3_PollEvent(zs3_Event* out)
{
    zs3_SDL2Event e;
    while (SDL_PollEvent(&e)) {
        SDL_memset(out, 0, sizeof(*out));
        out->type = e.type;
        switch (e.type) {
        case SDL_KEYDOWN:
        case SDL_KEYUP:
            out->key.scancode = e.key.keysym.scancode;
            out->key.key = e.key.keysym.sym;
            out->key.mod = e.key.keysym.mod;
            out->key.down = e.key.state == SDL_PRESSED;
            out->key.repeat = e.key.repeat != 0;
            return true;
        case SDL_TEXTINPUT:
            SDL_memcpy(out->text.text, e.text.text, sizeof(out->text.text));
            return true;
        case SDL_MOUSEMOTION:
            out->motion.x = (float)e.motion.x;
            out->motion.y = (float)e.motion.y;
            out->motion.xrel = (float)e.motion.xrel;
            out->motion.yrel = (float)e.motion.yrel;
            return true;
        case SDL_MOUSEBUTTONDOWN:
        case SDL_MOUSEBUTTONUP:
            out->button.button = e.button.button;
            return true;
        case SDL_MOUSEWHEEL:
            out->wheel.x = (float)e.wheel.x;
            out->wheel.y = (float)e.wheel.y;
            return true;
        case SDL_QUIT:
            return true;
        case SDL_WINDOWEVENT:
            out->window.data1 = e.window.data1;
            out->window.data2 = e.window.data2;
            switch (e.window.event) {
            case SDL_WINDOWEVENT_FOCUS_GAINED:
                out->type = SDL_EVENT_WINDOW_FOCUS_GAINED;
                return true;
            case SDL_WINDOWEVENT_FOCUS_LOST:
                out->type = SDL_EVENT_WINDOW_FOCUS_LOST;
                return true;
            case SDL_WINDOWEVENT_ENTER:
                out->type = SDL_EVENT_WINDOW_MOUSE_ENTER;
                return true;
            case SDL_WINDOWEVENT_RESIZED:
                out->type = SDL_EVENT_WINDOW_RESIZED;
                return true;
            case SDL_WINDOWEVENT_SIZE_CHANGED:
                out->type = SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED;
                return true;
            }
            break;
        }
    }
    return false;
}
#define SDL_PollEvent zs3_PollEvent

#endif
