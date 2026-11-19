/* ZDOS's font provider for libass (ass_zdosfonts.c) */
#ifndef LIBASS_ZDOSFONTS_H
#define LIBASS_ZDOSFONTS_H

#include "ass_fontselect.h"

ASS_FontProvider *ass_zdos_add_provider(ASS_Library *lib, ASS_FontSelector *selector,
                                        const char *config, FT_Library ftlibrary);

#endif
