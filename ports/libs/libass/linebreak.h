/* libunibreak's interface, as libass uses it, for linebreak.zig (our
 * own line breaking, built into LIBASS.ZDL) */
#ifndef LINEBREAK_H
#define LINEBREAK_H
#include <stddef.h>
#include <stdint.h>

#define UNIBREAK_VERSION 0x0600 /* the last character: INDETERMINATE */

#define LINEBREAK_MUSTBREAK 0
#define LINEBREAK_ALLOWBREAK 1
#define LINEBREAK_NOBREAK 2
#define LINEBREAK_INSIDEACHAR 3
#define LINEBREAK_INDETERMINATE 4

typedef uint32_t utf32_t;

void init_linebreak(void);
void set_linebreaks_utf32(const utf32_t *s, size_t len, const char *lang, char *brks);

#endif
