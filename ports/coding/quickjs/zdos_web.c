/* zdos:web: web.js inside qjs.app (#embed), handed to the module
 * loader as if read from a file; and the modules a context gets. */
#include <string.h>

#include "quickjs.h"
#include "zdos_modules.h"

static const char web_js[] = {
#embed "web.js"
};

uint8_t *zdos_module_source(JSContext *ctx, size_t *len, const char *name) {
    if (strcmp(name, "zdos:web") != 0) return NULL;
    uint8_t *buf = js_malloc(ctx, sizeof(web_js) + 1);
    if (buf == NULL) return NULL;
    memcpy(buf, web_js, sizeof(web_js));
    buf[sizeof(web_js)] = 0;
    *len = sizeof(web_js);
    return buf;
}

void zdos_init_modules(JSContext *ctx) {
    zdos_init_module_net(ctx, "zdos:net");
    zdos_init_module_sqlite(ctx, "zdos:sqlite");
}
