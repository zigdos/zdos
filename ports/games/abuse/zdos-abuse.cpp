// Abuse on ZDOS: the version, Ctrl+C, the data folder, screenshots.
#include "config.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <SDL.h>

#include "zdos.h"

// The version for ZDOS: configure.ac's (version.h), expanded before
// ZDOS_FILE_VERSION's #
#define ABUSE_FILE_VERSION(a, b, c) ZDOS_FILE_VERSION(a, b, c, 0)
#define ABUSE_FILE_VERSION_OF(a, b, c) ABUSE_FILE_VERSION(a, b, c)
ABUSE_FILE_VERSION_OF(ABUSE_VERSION_MAJOR, ABUSE_VERSION_MINOR, ABUSE_VERSION_PATCH);

// At the start: Ctrl+C a key (right Ctrl is a game key), not the end
void zdos_setup()
{
    if (zdos->programs->set_ctrl_c != NULL)
        zdos->programs->set_ctrl_c(true);
}

// ..\DATA\ABUSE beside ABUSE.APP's folder (C:\GAMES -> C:\DATA\ABUSE),
// else that folder itself
char const *zdos_data_dir()
{
    static char dir[PATH_MAX];
    if (dir[0])
        return dir;
    char path[PATH_MAX];
    size_t n = zdos->programs->program_path(path, sizeof(path) - 2);
    path[n] = '\0';
    char *slash = strrchr(path, '\\');
    if (slash == NULL)
    {
        strcpy(dir, ".\\");
        return dir;
    }
    *slash = '\0';
    char *up = strrchr(path, '\\');
    if (up != NULL)
    {
        snprintf(dir, sizeof(dir), "%.*s\\DATA\\ABUSE", (int)(up - path), path);
        struct stat st;
        if (stat(dir, &st) == 0 && S_ISDIR(st.st_mode))
        {
            strcat(dir, "\\");
            return dir;
        }
    }
    snprintf(dir, sizeof(dir), "%s\\", path);
    return dir;
}

static void put16(unsigned char *p, unsigned v)
{
    p[0] = (unsigned char)v;
    p[1] = (unsigned char)(v >> 8);
}

static void put32(unsigned char *p, unsigned long v)
{
    put16(p, (unsigned)(v & 0xffff));
    put16(p + 2, (unsigned)(v >> 16));
}

// SDL_SaveBMP's job: any surface as a 24-bit BMP; 1 when written
int zdos_save_bmp(SDL_Surface *s, char const *file)
{
    if (s == NULL)
        return 0;
    FILE *f = fopen(file, "wb");
    if (f == NULL)
        return 0;
    unsigned row = ((unsigned)s->w * 3 + 3) & ~3u;
    unsigned char h[54] = { 'B', 'M' };
    put32(h + 2, 54 + (unsigned long)row * s->h);
    put32(h + 10, 54);
    put32(h + 14, 40);
    put32(h + 18, (unsigned long)s->w);
    put32(h + 22, (unsigned long)s->h);
    put16(h + 26, 1);
    put16(h + 28, 24);
    put32(h + 34, (unsigned long)row * s->h);
    int ok = fwrite(h, sizeof(h), 1, f) == 1;
    unsigned char *line = (unsigned char *)calloc(1, row);
    int bpp = s->format->BytesPerPixel;
    for (int y = s->h - 1; ok && line && y >= 0; y--)
    {
        Uint8 const *p = (Uint8 const *)s->pixels + (size_t)y * s->pitch;
        for (int x = 0; x < s->w; x++, p += bpp)
        {
            Uint32 c = bpp == 1 ? *p : bpp == 2 ? *(Uint16 const *)p
                     : bpp == 3 ? (Uint32)(p[0] | p[1] << 8 | p[2] << 16)
                     : *(Uint32 const *)p;
            SDL_GetRGB(c, s->format, &line[x * 3 + 2], &line[x * 3 + 1], &line[x * 3]);
        }
        ok = fwrite(line, row, 1, f) == 1;
    }
    free(line);
    return fclose(f) == 0 && ok;
}
