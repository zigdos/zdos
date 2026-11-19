/* ZDOS's font provider for libass: the fonts of C:\SYSTEM\TTF, as
 * fontconfig gives a system's elsewhere. Each .ttf / .otf there is
 * added by path (libass reads its names, weight and style); common
 * families map to the ones ZDOS has; a glyph a font lacks is looked
 * for in the other fonts. */
#include "config.h"
#include "ass_compat.h"

#include <dirent.h>
#include <stdlib.h>
#include <string.h>
#include <ft2build.h>
#include FT_FREETYPE_H

#include "ass_fontselect.h"
#include "ass_string.h"
#include "ass_utils.h"
#include "ass_zdosfonts.h"

#define FONT_DIR "C:/SYSTEM/TTF"

typedef struct {
    char *path;
    FT_Library ftlibrary;
    FT_Face face; /* opened when a glyph is asked about */
    bool failed;
} ZdosFont;

typedef struct {
    FT_Library ftlibrary;
    ZdosFont **fonts;
    size_t count;
} ZdosProvider;

/* Families asked for that ZDOS doesn't have, and the ones of the same
 * widths it has (Arimo: Arial's, Tinos: Times New Roman's): */
static const ASS_FontMapping aliases[] = {
    { "Arial", "Arimo" },           { "Helvetica", "Arimo" },
    { "Verdana", "Arimo" },         { "Tahoma", "Arimo" },
    { "Liberation Sans", "Arimo" }, { "sans-serif", "Arimo" },
    { "sans", "Arimo" },            { "Times New Roman", "Tinos" },
    { "Times", "Tinos" },           { "Georgia", "Tinos" },
    { "Liberation Serif", "Tinos" }, { "serif", "Tinos" },
    { "Courier New", "IBM Plex Mono" }, { "Courier", "IBM Plex Mono" },
    { "Consolas", "IBM Plex Mono" }, { "monospace", "IBM Plex Mono" },
};

/* Looked at first for a glyph a font lacks: */
static const char *const fallback_order[] = { "Arimo", "Tinos", "IBM Plex Mono" };

static FT_Face face_of(ZdosFont *f)
{
    if (!f->face && !f->failed && FT_New_Face(f->ftlibrary, f->path, 0, &f->face))
        f->failed = true;
    return f->face;
}

static bool check_glyph(void *priv, uint32_t code)
{
    if (code == 0)
        return true;
    FT_Face face = face_of(priv);
    return face && FT_Get_Char_Index(face, code) != 0;
}

static void destroy_font(void *priv)
{
    ZdosFont *f = priv;
    if (f->face)
        FT_Done_Face(f->face);
    free(f->path);
    free(f);
}

static void destroy_provider(void *priv)
{
    ZdosProvider *p = priv;
    free(p->fonts); /* the fonts themselves: destroy_font */
    free(p);
}

static void get_substitutions(void *priv, const char *name, ASS_FontProviderMetaData *meta)
{
    (void)priv;
    ass_map_font(aliases, sizeof(aliases) / sizeof(aliases[0]), name, meta);
}

static bool has_family(FT_Face face, const char *family)
{
    return face && face->family_name && !ass_strcasecmp(face->family_name, family);
}

/* A family with the glyph: the usual three first, then any */
static char *get_fallback(void *priv, ASS_Library *lib, const char *family, uint32_t code)
{
    ZdosProvider *p = priv;
    (void)lib;
    (void)family;
    for (size_t k = 0; k <= sizeof(fallback_order) / sizeof(fallback_order[0]); k++) {
        for (size_t i = 0; i < p->count; i++) {
            FT_Face face = face_of(p->fonts[i]);
            if (!face || !face->family_name)
                continue;
            bool preferred = k < sizeof(fallback_order) / sizeof(fallback_order[0]);
            if (preferred && !has_family(face, fallback_order[k]))
                continue;
            if (FT_Get_Char_Index(face, code))
                return strdup(face->family_name);
        }
    }
    return NULL;
}

static ASS_FontProviderFuncs funcs = {
    .check_glyph = check_glyph,
    .destroy_font = destroy_font,
    .destroy_provider = destroy_provider,
    .get_substitutions = get_substitutions,
    .get_fallback = get_fallback,
};

static bool is_font_file(const char *name)
{
    size_t n = strlen(name);
    return n > 4 && (!ass_strcasecmp(name + n - 4, ".ttf") || !ass_strcasecmp(name + n - 4, ".otf"));
}

ASS_FontProvider *ass_zdos_add_provider(ASS_Library *lib, ASS_FontSelector *selector,
                                        const char *config, FT_Library ftlibrary)
{
    (void)config;
    DIR *dir = opendir(FONT_DIR);
    if (!dir)
        return NULL;
    ZdosProvider *p = calloc(1, sizeof(*p));
    ASS_FontProvider *provider = p ? ass_font_provider_new(selector, &funcs, p) : NULL;
    if (!provider) {
        free(p);
        closedir(dir);
        return NULL;
    }
    p->ftlibrary = ftlibrary;
    size_t capacity = 0;
    struct dirent *e;
    while ((e = readdir(dir)) != NULL) {
        if (!is_font_file(e->d_name))
            continue;
        if (p->count == capacity) {
            size_t more = capacity ? capacity * 2 : 64;
            ZdosFont **grown = realloc(p->fonts, more * sizeof(*grown));
            if (!grown)
                break;
            p->fonts = grown;
            capacity = more;
        }
        ZdosFont *f = calloc(1, sizeof(*f));
        if (!f)
            break;
        size_t len = strlen(FONT_DIR) + 1 + strlen(e->d_name) + 1;
        f->path = malloc(len);
        if (!f->path) {
            free(f);
            break;
        }
        snprintf(f->path, len, "%s/%s", FONT_DIR, e->d_name);
        f->ftlibrary = ftlibrary;
        /* No names given: libass reads them from the file (and on
           failure frees f through destroy_font): */
        ASS_FontProviderMetaData meta = {0};
        if (ass_font_provider_add_font(provider, &meta, f->path, 0, f))
            p->fonts[p->count++] = f;
    }
    closedir(dir);
    ass_msg(lib, MSGL_INFO, "zdos fonts: %zu in " FONT_DIR, p->count);
    return provider;
}
