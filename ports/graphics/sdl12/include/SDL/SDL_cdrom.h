/* ZDOS's partial SDL 1.2 (ports/graphics/sdl12): CD-ROM audio; ZDOS has no
   CD drives for it, so there are none to open (SDL_CDNumDrives is 0) */
#ifndef _SDL_cdrom_h
#define _SDL_cdrom_h

#include "SDL_stdinc.h"
#include "SDL_error.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SDL_MAX_TRACKS 99
#define SDL_AUDIO_TRACK 0x00
#define SDL_DATA_TRACK 0x04

typedef enum { CD_TRAYEMPTY, CD_STOPPED, CD_PLAYING, CD_PAUSED, CD_ERROR = -1 } CDstatus;
#define CD_INDRIVE(status) ((int)(status) > 0)

typedef struct SDL_CDtrack {
    Uint8 id;
    Uint8 type;
    Uint16 unused;
    Uint32 length;
    Uint32 offset;
} SDL_CDtrack;

typedef struct SDL_CD {
    int id;
    CDstatus status;
    int numtracks;
    int cur_track;
    int cur_frame;
    SDL_CDtrack track[SDL_MAX_TRACKS + 1];
} SDL_CD;

#define CD_FPS 75
#define FRAMES_TO_MSF(f, M, S, F) \
    {                             \
        int value = f;            \
        *(F) = value % CD_FPS;    \
        value /= CD_FPS;          \
        *(S) = value % 60;        \
        value /= 60;              \
        *(M) = value;             \
    }
#define MSF_TO_FRAMES(M, S, F) ((M) * 60 * CD_FPS + (S) * CD_FPS + (F))

int SDL_CDNumDrives(void);
const char *SDL_CDName(int drive);
SDL_CD *SDL_CDOpen(int drive);
CDstatus SDL_CDStatus(SDL_CD *cdrom);
int SDL_CDPlayTracks(SDL_CD *cdrom, int start_track, int start_frame, int ntracks, int nframes);
int SDL_CDPlay(SDL_CD *cdrom, int start, int length);
int SDL_CDPause(SDL_CD *cdrom);
int SDL_CDResume(SDL_CD *cdrom);
int SDL_CDStop(SDL_CD *cdrom);
int SDL_CDEject(SDL_CD *cdrom);
void SDL_CDClose(SDL_CD *cdrom);

#ifdef __cplusplus
}
#endif

#endif
