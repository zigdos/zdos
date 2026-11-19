/* ZDOS's own QuickJS modules: zdos:net (zdos_net.c), zdos:sqlite
 * (zdos_sqlite.c), zdos:web (web.js, embedded by zdos_web.c). qjs.c
 * creates the first two with each context, and quickjs-libc.c's
 * module loader gets zdos:web's source here (quickjs-zdos.patch). */
#ifndef ZDOS_MODULES_H
#define ZDOS_MODULES_H

#include <stddef.h>
#include <stdint.h>
#include "quickjs.h"

JSModuleDef *zdos_init_module_net(JSContext *ctx, const char *name);
JSModuleDef *zdos_init_module_sqlite(JSContext *ctx, const char *name);

/* zdos:net and zdos:sqlite in a new context (qjs.c) */
void zdos_init_modules(JSContext *ctx);

/* zdos:web's source, js_malloc'd as js_load_file gives a file's;
   NULL for other names */
uint8_t *zdos_module_source(JSContext *ctx, size_t *len, const char *name);

#endif
