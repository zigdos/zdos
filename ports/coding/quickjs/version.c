/* The version for ZDOS: QuickJS's (quickjs.h), expanded before
 * ZDOS_FILE_VERSION's # */
#include "quickjs.h"
#include "zdos.h"

#define QJS_FILE_VERSION(a, b, c) ZDOS_FILE_VERSION(a, b, c, 0)
#define QJS_FILE_VERSION_OF(a, b, c) QJS_FILE_VERSION(a, b, c)
QJS_FILE_VERSION_OF(QJS_VERSION_MAJOR, QJS_VERSION_MINOR, QJS_VERSION_PATCH);
