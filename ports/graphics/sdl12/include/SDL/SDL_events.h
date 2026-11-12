/* ZDOS's partial SDL 1.2 (ports/graphics/sdl12): events, with SDL 1.2's
   structures and numbers */
#ifndef _SDL_events_h
#define _SDL_events_h

#include "SDL_stdinc.h"
#include "SDL_error.h"
#include "SDL_active.h"
#include "SDL_keyboard.h"
#include "SDL_mouse.h"
#include "SDL_joystick.h"
#include "SDL_quit.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SDL_RELEASED 0
#define SDL_PRESSED 1

typedef enum {
    SDL_NOEVENT = 0,
    SDL_ACTIVEEVENT,
    SDL_KEYDOWN,
    SDL_KEYUP,
    SDL_MOUSEMOTION,
    SDL_MOUSEBUTTONDOWN,
    SDL_MOUSEBUTTONUP,
    SDL_JOYAXISMOTION,
    SDL_JOYBALLMOTION,
    SDL_JOYHATMOTION,
    SDL_JOYBUTTONDOWN,
    SDL_JOYBUTTONUP,
    SDL_QUIT,
    SDL_SYSWMEVENT,
    SDL_EVENT_RESERVEDA,
    SDL_EVENT_RESERVEDB,
    SDL_VIDEORESIZE,
    SDL_VIDEOEXPOSE,
    SDL_EVENT_RESERVED2,
    SDL_EVENT_RESERVED3,
    SDL_EVENT_RESERVED4,
    SDL_EVENT_RESERVED5,
    SDL_EVENT_RESERVED6,
    SDL_EVENT_RESERVED7,
    SDL_USEREVENT = 24,
    SDL_NUMEVENTS = 32
} SDL_EventType;

#define SDL_EVENTMASK(X) (1 << (X))
typedef enum {
    SDL_ACTIVEEVENTMASK = SDL_EVENTMASK(SDL_ACTIVEEVENT),
    SDL_KEYDOWNMASK = SDL_EVENTMASK(SDL_KEYDOWN),
    SDL_KEYUPMASK = SDL_EVENTMASK(SDL_KEYUP),
    SDL_KEYEVENTMASK = SDL_EVENTMASK(SDL_KEYDOWN) | SDL_EVENTMASK(SDL_KEYUP),
    SDL_MOUSEMOTIONMASK = SDL_EVENTMASK(SDL_MOUSEMOTION),
    SDL_MOUSEBUTTONDOWNMASK = SDL_EVENTMASK(SDL_MOUSEBUTTONDOWN),
    SDL_MOUSEBUTTONUPMASK = SDL_EVENTMASK(SDL_MOUSEBUTTONUP),
    SDL_MOUSEEVENTMASK = SDL_EVENTMASK(SDL_MOUSEMOTION) | SDL_EVENTMASK(SDL_MOUSEBUTTONDOWN) | SDL_EVENTMASK(SDL_MOUSEBUTTONUP),
    SDL_JOYAXISMOTIONMASK = SDL_EVENTMASK(SDL_JOYAXISMOTION),
    SDL_JOYBALLMOTIONMASK = SDL_EVENTMASK(SDL_JOYBALLMOTION),
    SDL_JOYHATMOTIONMASK = SDL_EVENTMASK(SDL_JOYHATMOTION),
    SDL_JOYBUTTONDOWNMASK = SDL_EVENTMASK(SDL_JOYBUTTONDOWN),
    SDL_JOYBUTTONUPMASK = SDL_EVENTMASK(SDL_JOYBUTTONUP),
    SDL_JOYEVENTMASK = SDL_EVENTMASK(SDL_JOYAXISMOTION) | SDL_EVENTMASK(SDL_JOYBALLMOTION) | SDL_EVENTMASK(SDL_JOYHATMOTION) |
                       SDL_EVENTMASK(SDL_JOYBUTTONDOWN) | SDL_EVENTMASK(SDL_JOYBUTTONUP),
    SDL_VIDEORESIZEMASK = SDL_EVENTMASK(SDL_VIDEORESIZE),
    SDL_VIDEOEXPOSEMASK = SDL_EVENTMASK(SDL_VIDEOEXPOSE),
    SDL_QUITMASK = SDL_EVENTMASK(SDL_QUIT),
    SDL_SYSWMEVENTMASK = SDL_EVENTMASK(SDL_SYSWMEVENT)
} SDL_EventMask;
#define SDL_ALLEVENTS 0xFFFFFFFF

typedef struct SDL_ActiveEvent { Uint8 type; Uint8 gain; Uint8 state; } SDL_ActiveEvent;
typedef struct SDL_KeyboardEvent { Uint8 type; Uint8 which; Uint8 state; SDL_keysym keysym; } SDL_KeyboardEvent;
typedef struct SDL_MouseMotionEvent {
    Uint8 type; Uint8 which; Uint8 state;
    Uint16 x, y;
    Sint16 xrel, yrel;
} SDL_MouseMotionEvent;
typedef struct SDL_MouseButtonEvent { Uint8 type; Uint8 which; Uint8 button; Uint8 state; Uint16 x, y; } SDL_MouseButtonEvent;
typedef struct SDL_JoyAxisEvent { Uint8 type; Uint8 which; Uint8 axis; Sint16 value; } SDL_JoyAxisEvent;
typedef struct SDL_JoyBallEvent { Uint8 type; Uint8 which; Uint8 ball; Sint16 xrel, yrel; } SDL_JoyBallEvent;
typedef struct SDL_JoyHatEvent { Uint8 type; Uint8 which; Uint8 hat; Uint8 value; } SDL_JoyHatEvent;
typedef struct SDL_JoyButtonEvent { Uint8 type; Uint8 which; Uint8 button; Uint8 state; } SDL_JoyButtonEvent;
typedef struct SDL_ResizeEvent { Uint8 type; int w; int h; } SDL_ResizeEvent;
typedef struct SDL_ExposeEvent { Uint8 type; } SDL_ExposeEvent;
typedef struct SDL_QuitEvent { Uint8 type; } SDL_QuitEvent;
typedef struct SDL_UserEvent { Uint8 type; int code; void *data1; void *data2; } SDL_UserEvent;
struct SDL_SysWMmsg;
typedef struct SDL_SysWMmsg SDL_SysWMmsg;
typedef struct SDL_SysWMEvent { Uint8 type; SDL_SysWMmsg *msg; } SDL_SysWMEvent;

typedef union SDL_Event {
    Uint8 type;
    SDL_ActiveEvent active;
    SDL_KeyboardEvent key;
    SDL_MouseMotionEvent motion;
    SDL_MouseButtonEvent button;
    SDL_JoyAxisEvent jaxis;
    SDL_JoyBallEvent jball;
    SDL_JoyHatEvent jhat;
    SDL_JoyButtonEvent jbutton;
    SDL_ResizeEvent resize;
    SDL_ExposeEvent expose;
    SDL_QuitEvent quit;
    SDL_UserEvent user;
    SDL_SysWMEvent syswm;
} SDL_Event;

void SDL_PumpEvents(void);
typedef enum { SDL_ADDEVENT, SDL_PEEKEVENT, SDL_GETEVENT } SDL_eventaction;
int SDL_PeepEvents(SDL_Event *events, int numevents, SDL_eventaction action, Uint32 mask);
int SDL_PollEvent(SDL_Event *event);
int SDL_WaitEvent(SDL_Event *event);
int SDL_PushEvent(SDL_Event *event);

typedef int (*SDL_EventFilter)(const SDL_Event *event);
void SDL_SetEventFilter(SDL_EventFilter filter);
SDL_EventFilter SDL_GetEventFilter(void);

#define SDL_QUERY -1
#define SDL_IGNORE 0
#define SDL_DISABLE 0
#define SDL_ENABLE 1
Uint8 SDL_EventState(Uint8 type, int state);

#ifdef __cplusplus
}
#endif

#endif
