/* __cxa_thread_atexit_impl (glibc's name, which libc++abi calls): C++
 * thread_local destructors, each thread's in reverse order when it ends, the
 * program's own thread's at exit before atexit's functions. */
#include <stdlib.h>
#include "zdos_internal.h"

struct thread_dtor {
    void (*fn)(void *);
    void *obj;
    struct thread_dtor *next;
};
static _Thread_local struct thread_dtor *thread_dtors;

static void run_thread_dtors(void) {
    struct thread_dtor *d;
    while ((d = thread_dtors) != NULL) { /* a destructor may add more */
        thread_dtors = d->next;
        d->fn(d->obj);
        free(d);
    }
}

int __cxa_thread_atexit_impl(void (*fn)(void *), void *obj, void *dso) {
    (void)dso;
    struct thread_dtor *d = malloc(sizeof(*d));
    if (d == NULL) return -1;
    d->fn = fn;
    d->obj = obj;
    d->next = thread_dtors;
    thread_dtors = d;
    zdos_thread_dtors_hook = run_thread_dtors;
    return 0;
}
