#pragma once
#ifndef _ZDOS_DLFCN_H_
#define _ZDOS_DLFCN_H_

#ifdef __cplusplus
extern "C" {
#endif

/* ZDOS has no shared libraries: dlopen of a file fails (dlerror says why).
   dlopen(NULL) gives the program itself; dlsym on it or on RTLD_DEFAULT
   looks the name up in tables the program registered (statically linked
   functions found by name, as sdl12-compat finds SDL2's):

       static const zdos_dlsym_entry sdl2[] = {
           ZDOS_DLSYM(SDL_Init), ZDOS_DLSYM(SDL_Quit), {NULL, NULL}};
       __attribute__((constructor)) static void sdl2_table(void) {
           zdos_dlsym_register(sdl2);
       }

   Up to 16 tables, searched from the last registered; RTLD_NEXT finds
   nothing. (zdos_unix.c) */
#define RTLD_LAZY 1
#define RTLD_NOW 2
#define RTLD_GLOBAL 0x100
#define RTLD_LOCAL 0
#define RTLD_DEFAULT ((void *)0)
#define RTLD_NEXT ((void *)-1)

void *dlopen(const char *file, int mode);
void *dlsym(void *handle, const char *name);
int dlclose(void *handle);
char *dlerror(void);

/* zdos: a table of names and addresses, ended by {NULL, NULL};
   it must stay (static). 0, or -1 when 16 are registered already. */
typedef struct {
    const char *name;
    void *address;
} zdos_dlsym_entry;
#define ZDOS_DLSYM(f) {#f, (void *)&(f)}
int zdos_dlsym_register(const zdos_dlsym_entry *table);

#ifdef __cplusplus
}
#endif
#endif
