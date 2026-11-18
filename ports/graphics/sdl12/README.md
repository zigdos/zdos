# SDL 1.2 (partial, ZDOS's own)

A partial SDL 1.2 written for ZDOS: SDL 1.2's API (its headers' structures, constants and functions, as SDL 1.2.15 documents them) implemented directly on the SDK's display, input and sound glue (`sdk/src/zdos_media.h`) and the C library's pthreads. It is **not SDL**: no SDL code, not a wrapper over SDL 2 (`ports/graphics/SDL`), only what SDL 1.2 programs commonly use (written for DGen, `ports/games/dgen`). Its license is ZDOS's (`docs/COPYING/SDL12.TXT`).

```sh
ports/graphics/sdl12/build.sh             # all three CPUs
ports/graphics/sdl12/build.sh x86_64      # one or more: x86, x86_64, arm64
```

It installs into `build/sdk-ports/`, which `zdos-cc` searches, as SDL 1.2 installs itself:

- `lib/<arch>/libSDL.a` (220-350 KB as an archive, a program takes what it uses; objects in `build/sdl12/<arch>/`) and an empty `libSDLmain.a` (ZDOS calls `main` itself);
- `include/SDL/`: `SDL.h` and `SDL_*.h`;
- `bin/sdl-config` (`--cflags`: `-I.../include/SDL`, `--libs`: `-lSDL`).

```sh
zdos-cc -O2 game.c -lSDL -o GAME.APP                                # #include <SDL/SDL.h>
zdos-cc -O2 -Ibuild/sdk-ports/include/SDL game.c -lSDL -o GAME.APP  # #include "SDL.h"
```

## What it covers

- **Start, errors**: `SDL_Init`, `SDL_InitSubSystem`, `SDL_QuitSubSystem`, `SDL_WasInit`, `SDL_Quit`, `SDL_GetError` / `SetError` / `ClearError` / `Error`, `SDL_Linked_Version`; `SDL_stdinc.h`'s types and `SDL_*` C library names, `SDL_endian.h`.
- **Video**: `SDL_SetVideoMode` (8, 15, 16, 24, 32 bits; 0 or `SDL_ANYFORMAT`: 32 on true-color screens, 8 on VGA), `SDL_GetVideoSurface`, `SDL_GetVideoInfo`, `SDL_VideoModeOK`, `SDL_ListModes` (any size: `(SDL_Rect **)-1`), `SDL_VideoDriverName` (`zdos`), `SDL_Flip`, `SDL_UpdateRect(s)` (the whole picture), `SDL_SetColors` / `SDL_SetPalette`, `SDL_MapRGB(A)` / `SDL_GetRGB(A)`, `SDL_CreateRGBSurface(From)`, `SDL_FreeSurface`, `SDL_Lock` / `UnlockSurface`, `SDL_MUSTLOCK`, `SDL_FillRect`, `SDL_BlitSurface` (clipped, converting between formats, color keys), `SDL_SetColorKey`, `SDL_SetClipRect` / `GetClipRect`, `SDL_ConvertSurface`, `SDL_DisplayFormat(Alpha)`.
- **Window manager**: `SDL_WM_SetCaption` (the tab's name) / `GetCaption`, `SDL_WM_ToggleFullScreen` (the flag only: the picture always fills the tab), `SDL_WM_GrabInput`, `SDL_WM_SetIcon` and `IconifyWindow` (nothing), `SDL_ShowCursor`.
- **Events**: `SDL_PollEvent`, `SDL_WaitEvent`, `SDL_PumpEvents`, `SDL_PeepEvents`, `SDL_PushEvent`, `SDL_EventState`, `SDL_SetEventFilter`, `SDL_GetAppState`; key, mouse motion and button (the wheel as buttons 4 and 5) and active (the tab's focus) events.
- **Keyboard**: SDL 1.2's `SDLKey` and `SDLMod` values from the keys' USB HID usages (the keypad's keys are always `SDLK_KP0` ... `SDLK_KP9`, `SDLK_KP_ENTER` ..., whatever Num Lock); `SDL_EnableUNICODE` (`keysym.unicode` from ZDOS's typed text, with its keyboard layout: the glue's text events, which come after the key events read with them, are paired in order with the presses that type characters, repeats included; where the counts differ, the US layout's characters), `SDL_EnableKeyRepeat` (ZDOS repeats at the keyboard's rate: on or off), `SDL_GetKeyState`, `SDL_GetModState` / `SetModState`, `SDL_GetKeyName`.
- **Mouse**: `SDL_GetMouseState`, `SDL_GetRelativeMouseState`, `SDL_WarpMouse`; cursors are kept but ZDOS's arrow is drawn whatever they are.
- **Audio**: `SDL_OpenAudio` (U8, S8, U16 and S16 in either byte order, mono or stereo; starts paused; `samples` 0 picks about 46 ms as SDL 1.2 does), `SDL_PauseAudio`, `SDL_GetAudioStatus`, `SDL_LockAudio` / `UnlockAudio`, `SDL_CloseAudio`, `SDL_MixAudio`, `SDL_AudioDriverName`. The callback runs on zdos_media.h's sound thread; the card's driver converts the rate (if it refuses one and `obtained` is given, 48000, 44100, 22050 or 11025 Hz is tried and reported).
- **Threads**: `SDL_CreateThread`, `SDL_WaitThread`, `SDL_ThreadID`, `SDL_GetThreadID`; recursive mutexes (`SDL_CreateMutex`, `SDL_mutexP` / `SDL_LockMutex` ...), semaphores, conditions (also with time-outs). Pthreads: preemptive on the metal editions, cooperative on UEFI and BIOS.
- **Time**: `SDL_GetTicks`, `SDL_Delay`, `SDL_AddTimer` / `SDL_RemoveTimer` / `SDL_SetTimer` (on one timer thread).
- **Joysticks**: the functions, with no joysticks (`SDL_NumJoysticks` is 0).
- **Stubs** (for DOSBox): CD-ROM audio with no drives (`SDL_CDNumDrives` 0, `SDL_CDOpen` fails; `SDL_cdrom.h`), YUV overlays that fail (`SDL_CreateYUVOverlay` returns NULL), `SDL_GetWMInfo` returning 0 (`SDL_syswm.h`).

Not there: OpenGL (`SDL_OPENGL` modes fail, `SDL_GL_*` fail), YUV overlays and CD-ROM (stubs), `SDL_RWops` and `SDL_LoadBMP` / `SaveBMP`, gamma, alpha blending (`SDL_SetAlpha` is kept, blits copy), `SDL_KillThread` (waits instead), the `SDL_syswm.h` window information.

## The screen

`SDL_SetVideoMode` allocates the surface (a software surface: `SDL_MUSTLOCK` is 0) and opens the display with `zdos_display_open`; `SDL_Flip` shows it with `zdos_display_present`:

- 8 bits as palette indexes (`ZDOS_PIXELS_INDEX8`, the palette from `SDL_SetColors`), 16 as RGB565, 32 as XRGB8888; 15 and 24 are converted to 32 at each flip.
- UEFI and metal: a picture up to the screen's size is centered and scaled up by a whole number, a larger one scaled down to fit.
- BIOS: with VESA, as on UEFI and metal, in a true-color VESA mode. Without VESA (VGA): a picture up to 320×200 goes to mode 13h, 8-bit ones with their own palette. A picture up to 320 wide and 201 to 240 high (a console's 224 or 240 lines) is shown as **its middle 200 lines** in mode 13h, as DOS-era emulators did, instead of being shrunk or going to the 16-color mode 12h. Larger pictures go to mode 12h (`zdos_media.h`).
