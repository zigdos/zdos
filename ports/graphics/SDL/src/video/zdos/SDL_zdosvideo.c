/*
  Simple DirectMedia Layer: the ZDOS video backend, on the SDK's display and
  input glue (sdk/src/zdos_media.h). One window, shown full-screen: its
  framebuffer goes to ZDOS's tab scaled to fit; events from ZDOS's keys,
  mouse and tab focus. SDL's software renderer draws into it.

  This software is provided 'as-is', under the zlib license (LICENSE.txt in
  SDL's sources).
*/
#include "../../SDL_internal.h"

#ifdef SDL_VIDEO_DRIVER_ZDOS

#include "SDL_video.h"
#include "SDL_mouse.h"
#include "../SDL_sysvideo.h"
#include "../../events/SDL_events_c.h"
#include "../../events/SDL_keyboard_c.h"
#include "../../events/SDL_mouse_c.h"

#include "zdos.h"
#include "zdos_media.h"

#define ZDOS_SURFACE "_SDL_ZDOSSurface"

static SDL_bool cursor_shown;

static void ZDOS_InitMouse(void);

static int ZDOS_VideoInit(_THIS)
{
    zdos_screen_info screen;
    zdos_screen_size sizes[64];
    SDL_DisplayMode mode;
    size_t n, i;

    if (!zdos->gfx->screen(&screen)) {
        return SDL_SetError("No graphics here: %s", zdos_error_message(zdos->programs->last_error()));
    }
    SDL_zero(mode);
    mode.format = SDL_PIXELFORMAT_RGB888;
    mode.w = (int)screen.width;
    mode.h = (int)screen.height;
    if (SDL_AddBasicVideoDisplay(&mode) < 0) {
        return -1;
    }
    /* The firmware's modes: a picture of any of them is scaled to the screen */
    n = zdos->gfx->modes(sizes, SDL_arraysize(sizes));
    for (i = 0; i < n && i < SDL_arraysize(sizes); i++) {
        mode.w = (int)sizes[i].width;
        mode.h = (int)sizes[i].height;
        SDL_AddDisplayMode(&_this->displays[0], &mode);
    }
    ZDOS_InitMouse();
    return 0;
}

static void ZDOS_VideoQuit(_THIS)
{
    zdos_display_close();
}

static int ZDOS_SetDisplayMode(_THIS, SDL_VideoDisplay *display, SDL_DisplayMode *mode)
{
    return 0; /* nothing to switch: the window's picture is scaled */
}

static int ZDOS_CreateWindow(_THIS, SDL_Window *window)
{
    if (_this->windows != window || window->next != NULL) {
        return SDL_SetError("ZDOS shows one window");
    }
    window->x = 0;
    window->y = 0;
    SDL_SetMouseFocus(window);
    SDL_SetKeyboardFocus(window);
    return 0;
}

static void ZDOS_SetWindowTitle(_THIS, SDL_Window *window)
{
    const char *title = window->title ? window->title : "";
    zdos->gfx->set_title(title, SDL_strlen(title));
}

static void ZDOS_DestroyWindow(_THIS, SDL_Window *window)
{
    zdos_display_close();
}

static void ZDOS_DestroyWindowFramebuffer(_THIS, SDL_Window *window)
{
    SDL_FreeSurface((SDL_Surface *)SDL_SetWindowData(window, ZDOS_SURFACE, NULL));
}

static int ZDOS_CreateWindowFramebuffer(_THIS, SDL_Window *window, Uint32 *format, void **pixels, int *pitch)
{
    SDL_Surface *surface;
    int w, h;

    ZDOS_DestroyWindowFramebuffer(_this, window);
    SDL_GetWindowSizeInPixels(window, &w, &h);
    if (!zdos_display_open(w, h, ZDOS_PIXELS_XRGB8888)) {
        return SDL_SetError("Can't show %dx%d: %s", w, h, zdos_error_message(zdos->programs->last_error()));
    }
    ZDOS_SetWindowTitle(_this, window); /* the tab exists now */
    zdos_input_warp(SDL_GetMouse()->x, SDL_GetMouse()->y);
    surface = SDL_CreateRGBSurfaceWithFormat(0, w, h, 0, SDL_PIXELFORMAT_RGB888);
    if (!surface) {
        return -1;
    }
    SDL_SetWindowData(window, ZDOS_SURFACE, surface);
    *format = SDL_PIXELFORMAT_RGB888;
    *pixels = surface->pixels;
    *pitch = surface->pitch;
    return 0;
}

static int ZDOS_UpdateWindowFramebuffer(_THIS, SDL_Window *window, const SDL_Rect *rects, int numrects)
{
    SDL_Surface *surface = (SDL_Surface *)SDL_GetWindowData(window, ZDOS_SURFACE);
    SDL_Mouse *mouse = SDL_GetMouse();

    if (!surface) {
        return SDL_SetError("No framebuffer for the window");
    }
    zdos_display_cursor(mouse->x, mouse->y, cursor_shown && !mouse->relative_mode);
    zdos_display_present(surface->pixels, surface->pitch);
    return 0;
}

/* THE MOUSE: ZDOS DRAWS NO POINTER, THE GLUE DRAWS AN ARROW */

static SDL_Cursor *ZDOS_CreateCursor(SDL_Surface *surface, int hot_x, int hot_y)
{
    SDL_Cursor *cursor = (SDL_Cursor *)SDL_calloc(1, sizeof(*cursor));
    if (!cursor) {
        SDL_OutOfMemory();
    }
    return cursor;
}

static SDL_Cursor *ZDOS_CreateSystemCursor(SDL_SystemCursor id)
{
    return ZDOS_CreateCursor(NULL, 0, 0);
}

static int ZDOS_ShowCursor(SDL_Cursor *cursor)
{
    cursor_shown = cursor != NULL;
    return 0;
}

static void ZDOS_FreeCursor(SDL_Cursor *cursor)
{
    SDL_free(cursor);
}

static void ZDOS_WarpMouse(SDL_Window *window, int x, int y)
{
    zdos_input_warp(x, y);
    SDL_SendMouseMotion(window, 0, 0, x, y);
}

static int ZDOS_SetRelativeMouseMode(SDL_bool enabled)
{
    return 0; /* ZDOS's mouse gives movements: relative mode as it is */
}

static void ZDOS_InitMouse(void)
{
    SDL_Mouse *mouse = SDL_GetMouse();

    mouse->CreateCursor = ZDOS_CreateCursor;
    mouse->CreateSystemCursor = ZDOS_CreateSystemCursor;
    mouse->ShowCursor = ZDOS_ShowCursor;
    mouse->FreeCursor = ZDOS_FreeCursor;
    mouse->WarpMouse = ZDOS_WarpMouse;
    mouse->SetRelativeMouseMode = ZDOS_SetRelativeMouseMode;
    SDL_SetDefaultCursor(ZDOS_CreateCursor(NULL, 0, 0));
}

static void ZDOS_PumpEvents(_THIS)
{
    SDL_Window *window = _this->windows;
    SDL_Mouse *mouse = SDL_GetMouse();
    zdos_input_event e;
    Uint8 button;

    while (zdos_input_poll(&e)) {
        if (!window && e.type >= ZDOS_EVENT_MOUSE_MOTION) {
            continue; /* no window for the mouse and focus */
        }
        switch (e.type) {
        case ZDOS_EVENT_KEY_DOWN:
        case ZDOS_EVENT_KEY_UP:
            SDL_ToggleModState(KMOD_CAPS, (e.mods & ZDOS_MOD_CAPS_LOCK) ? SDL_TRUE : SDL_FALSE);
            SDL_ToggleModState(KMOD_NUM, (e.mods & ZDOS_MOD_NUM_LOCK) ? SDL_TRUE : SDL_FALSE);
            SDL_SendKeyboardKey(e.type == ZDOS_EVENT_KEY_DOWN ? SDL_PRESSED : SDL_RELEASED, (SDL_Scancode)e.scancode);
            break;
        case ZDOS_EVENT_TEXT:
            SDL_SendKeyboardText(e.text);
            break;
        case ZDOS_EVENT_MOUSE_MOTION:
            if (mouse->relative_mode) {
                SDL_SendMouseMotion(window, 0, 1, e.dx, e.dy);
            } else {
                SDL_SendMouseMotion(window, 0, 0, e.x, e.y);
            }
            break;
        case ZDOS_EVENT_MOUSE_DOWN:
        case ZDOS_EVENT_MOUSE_UP:
            button = e.button == ZDOS_MOUSE_LEFT ? SDL_BUTTON_LEFT : e.button == ZDOS_MOUSE_RIGHT ? SDL_BUTTON_RIGHT : SDL_BUTTON_MIDDLE;
            SDL_SendMouseButton(window, 0, e.type == ZDOS_EVENT_MOUSE_DOWN ? SDL_PRESSED : SDL_RELEASED, button);
            break;
        case ZDOS_EVENT_MOUSE_WHEEL:
            SDL_SendMouseWheel(window, 0, 0.0f, (float)-e.dy, SDL_MOUSEWHEEL_NORMAL); /* SDL's up is away from the user */
            break;
        case ZDOS_EVENT_FOCUS_GAINED: /* the tab in front again (Alt+Tab) */
            SDL_SendWindowEvent(window, SDL_WINDOWEVENT_RESTORED, 0, 0);
            SDL_SetKeyboardFocus(window);
            SDL_SetMouseFocus(window);
            break;
        case ZDOS_EVENT_FOCUS_LOST:
            SDL_SetKeyboardFocus(NULL);
            SDL_SetMouseFocus(NULL);
            SDL_SendWindowEvent(window, SDL_WINDOWEVENT_MINIMIZED, 0, 0);
            break;
        }
    }
}

static void ZDOS_StartTextInput(_THIS)
{
    zdos_input_text(SDL_TRUE);
}

static void ZDOS_StopTextInput(_THIS)
{
    zdos_input_text(SDL_FALSE);
}

static void ZDOS_DeleteDevice(SDL_VideoDevice *device)
{
    SDL_free(device);
}

static SDL_VideoDevice *ZDOS_CreateDevice(void)
{
    SDL_VideoDevice *device = (SDL_VideoDevice *)SDL_calloc(1, sizeof(SDL_VideoDevice));

    if (!device) {
        SDL_OutOfMemory();
        return NULL;
    }
    device->VideoInit = ZDOS_VideoInit;
    device->VideoQuit = ZDOS_VideoQuit;
    device->SetDisplayMode = ZDOS_SetDisplayMode;
    device->CreateSDLWindow = ZDOS_CreateWindow;
    device->SetWindowTitle = ZDOS_SetWindowTitle;
    device->DestroyWindow = ZDOS_DestroyWindow;
    device->CreateWindowFramebuffer = ZDOS_CreateWindowFramebuffer;
    device->UpdateWindowFramebuffer = ZDOS_UpdateWindowFramebuffer;
    device->DestroyWindowFramebuffer = ZDOS_DestroyWindowFramebuffer;
    device->PumpEvents = ZDOS_PumpEvents;
    device->StartTextInput = ZDOS_StartTextInput;
    device->StopTextInput = ZDOS_StopTextInput;
    device->free = ZDOS_DeleteDevice;
    /* A tab going behind is "minimized"; fullscreen stays as it is */
    device->quirk_flags = VIDEO_DEVICE_QUIRK_DISABLE_UNSET_FULLSCREEN_ON_MINIMIZE;

    return device;
}

VideoBootStrap ZDOS_bootstrap = {
    "zdos", "ZDOS video driver",
    ZDOS_CreateDevice,
    NULL /* no message boxes */
};

#endif /* SDL_VIDEO_DRIVER_ZDOS */
