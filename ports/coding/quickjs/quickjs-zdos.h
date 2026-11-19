/* Included before every QuickJS file (-include): what its
 * quickjs-libc.c takes from glibc and the SDK lacks. */
#ifndef QUICKJS_ZDOS_H
#define QUICKJS_ZDOS_H

#include <signal.h>
#include <sys/stat.h>

/* glibc's name for a signal handler's type */
typedef void (*sighandler_t)(int);

/* Set-user-ID and set-group-ID mode bits: ZDOS has neither; os.stat
 * shows them as 0 */
#ifndef S_ISUID
#define S_ISUID 04000
#endif
#ifndef S_ISGID
#define S_ISGID 02000
#endif

#endif
