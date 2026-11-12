/*
  Simple DirectMedia Layer: SDL's folders on ZDOS. The base path is the
  program's folder (C:\GAMES\); the preferences go to DATA on the program's
  drive, C:\DATA\<org>\<app>\, as ZDOS programs keep their data.

  This software is provided 'as-is', under the zlib license (LICENSE.txt in
  SDL's sources).
*/
#include "../../SDL_internal.h"

#ifdef SDL_FILESYSTEM_ZDOS

#include <errno.h>
#include <string.h>
#include <sys/stat.h>

#include "SDL_error.h"
#include "SDL_filesystem.h"

#include "zdos.h"

char *SDL_GetBasePath(void)
{
    char path[1028];
    size_t n = zdos->programs->program_path(path, sizeof(path) - 1);
    char *slash;

    if (n == 0 || n >= sizeof(path)) {
        SDL_SetError("The program's path is unknown");
        return NULL;
    }
    path[n] = '\0';
    slash = SDL_strrchr(path, '\\');
    if (slash) {
        slash[1] = '\0';
    }
    return SDL_strdup(path);
}

static int make_dir(const char *path)
{
    if (mkdir(path, 0700) != 0 && errno != EEXIST) {
        return SDL_SetError("Can't make %s: %s", path, strerror(errno));
    }
    return 0;
}

char *SDL_GetPrefPath(const char *org, const char *app)
{
    char drive = 'C';
    char path[1028];
    char *base = SDL_GetBasePath();
    size_t len;

    if (!app) {
        SDL_InvalidParamError("app");
        return NULL;
    }
    if (base) {
        if (base[0] != '\0' && base[1] == ':') {
            drive = base[0];
        }
        SDL_free(base);
    }
    SDL_snprintf(path, sizeof(path), "%c:\\DATA", drive);
    if (make_dir(path) < 0) {
        return NULL;
    }
    if (org && *org) {
        len = SDL_strlen(path);
        SDL_snprintf(path + len, sizeof(path) - len, "\\%s", org);
        if (make_dir(path) < 0) {
            return NULL;
        }
    }
    len = SDL_strlen(path);
    SDL_snprintf(path + len, sizeof(path) - len, "\\%s", app);
    if (make_dir(path) < 0) {
        return NULL;
    }
    SDL_strlcat(path, "\\", sizeof(path));
    return SDL_strdup(path);
}

#endif /* SDL_FILESYSTEM_ZDOS */
