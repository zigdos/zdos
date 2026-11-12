/* The partial SDL 1.2's start and end, errors, threads and their locks
   (pthreads), time and timers, and joysticks (none) */
#include "sdl12_internal.h"

#include <errno.h>
#include <pthread.h>
#include <semaphore.h>
#include <time.h>

#include "zdos.h"

static Uint32 inited;
static uint64_t start_ms;
static char error[256];

/* START AND END */

int SDL_Init(Uint32 flags)
{
    if (!start_ms) start_ms = zdos->time->millis();
    return SDL_InitSubSystem(flags);
}

int SDL_InitSubSystem(Uint32 flags)
{
    if (!start_ms) start_ms = zdos->time->millis();
    inited |= flags & (SDL_INIT_TIMER | SDL_INIT_AUDIO | SDL_INIT_VIDEO | SDL_INIT_JOYSTICK);
    return 0;
}

void SDL_QuitSubSystem(Uint32 flags)
{
    if (flags & inited & SDL_INIT_AUDIO) SDL12_AudioQuit();
    if (flags & inited & SDL_INIT_VIDEO) SDL12_VideoQuit();
    if (flags & inited & SDL_INIT_TIMER) SDL12_TimerQuit();
    inited &= ~flags;
}

Uint32 SDL_WasInit(Uint32 flags)
{
    return inited & (flags ? flags : SDL_INIT_EVERYTHING);
}

void SDL_Quit(void)
{
    /* also what was opened without SDL_Init */
    SDL12_AudioQuit();
    SDL12_VideoQuit();
    SDL12_TimerQuit();
    inited = 0;
}

const SDL_version *SDL_Linked_Version(void)
{
    static SDL_version v = {SDL_MAJOR_VERSION, SDL_MINOR_VERSION, SDL_PATCHLEVEL};
    return &v;
}

void SDL_SetError(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(error, sizeof(error), fmt, ap);
    va_end(ap);
}

char *SDL_GetError(void) { return error; }
void SDL_ClearError(void) { error[0] = '\0'; }

void SDL_Error(SDL_errorcode code)
{
    static const char *const text[] = {"Out of memory", "Error reading from datastream", "Error writing to datastream",
                                       "Error seeking in datastream", "That operation is not supported"};
    SDL_SetError("%s", code < SDL_LASTERROR ? text[code] : "Unknown SDL error");
}

struct SDL_Thread {
    pthread_t thread;
    int (*fn)(void *);
    void *data;
    int status;
};

static void *thread_start(void *arg)
{
    SDL_Thread *t = arg;
    t->status = t->fn(t->data);
    return NULL;
}

SDL_Thread *SDL_CreateThread(int (*fn)(void *), void *data)
{
    SDL_Thread *t = calloc(1, sizeof(*t));
    if (t == NULL) {
        SDL_OutOfMemory();
        return NULL;
    }
    t->fn = fn;
    t->data = data;
    int e = pthread_create(&t->thread, NULL, thread_start, t);
    if (e != 0) {
        SDL_SetError("Not enough resources to create thread: %s", strerror(e));
        free(t);
        return NULL;
    }
    return t;
}

Uint32 SDL_ThreadID(void) { return (Uint32)pthread_self(); }
Uint32 SDL_GetThreadID(SDL_Thread *t) { return t ? (Uint32)t->thread : SDL_ThreadID(); }

void SDL_WaitThread(SDL_Thread *t, int *status)
{
    if (t == NULL) return;
    pthread_join(t->thread, NULL);
    if (status) *status = t->status;
    free(t);
}

void SDL_KillThread(SDL_Thread *t) { SDL_WaitThread(t, NULL); }

/* MUTEXES, SEMAPHORES, CONDITIONS */

struct SDL_mutex {
    pthread_mutex_t m;
};

SDL_mutex *SDL_CreateMutex(void)
{
    SDL_mutex *m = malloc(sizeof(*m));
    pthread_mutexattr_t a;
    if (m == NULL) {
        SDL_OutOfMemory();
        return NULL;
    }
    pthread_mutexattr_init(&a);
    pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE); /* as SDL 1.2's */
    if (pthread_mutex_init(&m->m, &a) != 0) {
        SDL_SetError("pthread_mutex_init() failed");
        free(m);
        m = NULL;
    }
    pthread_mutexattr_destroy(&a);
    return m;
}

int SDL_mutexP(SDL_mutex *m)
{
    if (m == NULL) {
        SDL_SetError("Passed a NULL mutex");
        return -1;
    }
    return pthread_mutex_lock(&m->m) ? -1 : 0;
}

int SDL_mutexV(SDL_mutex *m)
{
    if (m == NULL) {
        SDL_SetError("Passed a NULL mutex");
        return -1;
    }
    return pthread_mutex_unlock(&m->m) ? -1 : 0;
}

void SDL_DestroyMutex(SDL_mutex *m)
{
    if (m == NULL) return;
    pthread_mutex_destroy(&m->m);
    free(m);
}

/* An absolute time ms from now, for the timed waits */
static struct timespec deadline(Uint32 ms)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += ms / 1000;
    ts.tv_nsec += (long)(ms % 1000) * 1000000;
    if (ts.tv_nsec >= 1000000000) {
        ts.tv_sec++;
        ts.tv_nsec -= 1000000000;
    }
    return ts;
}

struct SDL_semaphore {
    sem_t s;
};

SDL_sem *SDL_CreateSemaphore(Uint32 value)
{
    SDL_sem *s = malloc(sizeof(*s));
    if (s == NULL) {
        SDL_OutOfMemory();
        return NULL;
    }
    if (sem_init(&s->s, 0, value) != 0) {
        SDL_SetError("sem_init() failed");
        free(s);
        return NULL;
    }
    return s;
}

void SDL_DestroySemaphore(SDL_sem *s)
{
    if (s == NULL) return;
    sem_destroy(&s->s);
    free(s);
}

int SDL_SemWait(SDL_sem *s)
{
    if (s == NULL) return -1;
    while (sem_wait(&s->s) != 0)
        if (errno != EINTR) return -1;
    return 0;
}

int SDL_SemTryWait(SDL_sem *s)
{
    if (s == NULL) return -1;
    return sem_trywait(&s->s) == 0 ? 0 : SDL_MUTEX_TIMEDOUT;
}

int SDL_SemWaitTimeout(SDL_sem *s, Uint32 ms)
{
    if (s == NULL) return -1;
    if (ms == SDL_MUTEX_MAXWAIT) return SDL_SemWait(s);
    struct timespec ts = deadline(ms);
    while (sem_timedwait(&s->s, &ts) != 0) {
        if (errno == ETIMEDOUT) return SDL_MUTEX_TIMEDOUT;
        if (errno != EINTR) return -1;
    }
    return 0;
}

int SDL_SemPost(SDL_sem *s) { return s && sem_post(&s->s) == 0 ? 0 : -1; }

Uint32 SDL_SemValue(SDL_sem *s)
{
    int v = 0;
    if (s) sem_getvalue(&s->s, &v);
    return v > 0 ? (Uint32)v : 0;
}

struct SDL_cond {
    pthread_cond_t c;
};

SDL_cond *SDL_CreateCond(void)
{
    SDL_cond *c = malloc(sizeof(*c));
    if (c == NULL) {
        SDL_OutOfMemory();
        return NULL;
    }
    if (pthread_cond_init(&c->c, NULL) != 0) {
        SDL_SetError("pthread_cond_init() failed");
        free(c);
        return NULL;
    }
    return c;
}

void SDL_DestroyCond(SDL_cond *c)
{
    if (c == NULL) return;
    pthread_cond_destroy(&c->c);
    free(c);
}

int SDL_CondSignal(SDL_cond *c) { return c && pthread_cond_signal(&c->c) == 0 ? 0 : -1; }
int SDL_CondBroadcast(SDL_cond *c) { return c && pthread_cond_broadcast(&c->c) == 0 ? 0 : -1; }

int SDL_CondWait(SDL_cond *c, SDL_mutex *m)
{
    if (c == NULL || m == NULL) return -1;
    return pthread_cond_wait(&c->c, &m->m) ? -1 : 0;
}

int SDL_CondWaitTimeout(SDL_cond *c, SDL_mutex *m, Uint32 ms)
{
    if (c == NULL || m == NULL) return -1;
    if (ms == SDL_MUTEX_MAXWAIT) return SDL_CondWait(c, m);
    struct timespec ts = deadline(ms);
    int e = pthread_cond_timedwait(&c->c, &m->m, &ts);
    return e == ETIMEDOUT ? SDL_MUTEX_TIMEDOUT : e ? -1 : 0;
}

/* TIME AND TIMERS */

Uint32 SDL_GetTicks(void)
{
    if (!start_ms) start_ms = zdos->time->millis();
    return (Uint32)(zdos->time->millis() - start_ms);
}

void SDL_Delay(Uint32 ms) { zdos->time->sleep(ms); }

/* The timers: a list the timer thread runs, each at its due time */
struct _SDL_TimerID {
    struct _SDL_TimerID *next;
    Uint32 interval, due;
    SDL_NewTimerCallback callback;
    void *param;
};

static struct {
    pthread_mutex_t lock;
    pthread_cond_t wake;
    pthread_t thread;
    int running;
    struct _SDL_TimerID *list;
    SDL_TimerCallback old; /* SDL_SetTimer's */
    SDL_TimerID old_id;
} tm = {.lock = PTHREAD_MUTEX_INITIALIZER, .wake = PTHREAD_COND_INITIALIZER};

static void *timer_thread(void *arg)
{
    (void)arg;
    pthread_mutex_lock(&tm.lock);
    while (tm.running) {
        Uint32 now = SDL_GetTicks(), wait = 100;
        struct _SDL_TimerID *t = tm.list;
        for (; t != NULL; t = t->next) {
            if ((Sint32)(t->due - now) <= 0) break;
            if (t->due - now < wait) wait = t->due - now;
        }
        if (t == NULL) {
            struct timespec ts = deadline(wait);
            pthread_cond_timedwait(&tm.wake, &tm.lock, &ts);
            continue;
        }
        /* the callback runs unlocked: it may add or remove timers */
        SDL_NewTimerCallback cb = t->callback;
        void *param = t->param;
        Uint32 interval = t->interval;
        t->due = now + (interval ? interval : 1);
        pthread_mutex_unlock(&tm.lock);
        Uint32 next = cb(interval, param);
        pthread_mutex_lock(&tm.lock);
        for (struct _SDL_TimerID **p = &tm.list; *p; p = &(*p)->next) {
            if (*p != t) continue;
            if (next == 0) {
                *p = t->next;
                free(t);
            } else {
                t->interval = next;
                t->due = SDL_GetTicks() + next;
            }
            break;
        }
    }
    pthread_mutex_unlock(&tm.lock);
    return NULL;
}

SDL_TimerID SDL_AddTimer(Uint32 interval, SDL_NewTimerCallback callback, void *param)
{
    struct _SDL_TimerID *t = calloc(1, sizeof(*t));
    if (t == NULL) {
        SDL_OutOfMemory();
        return NULL;
    }
    t->interval = interval;
    t->due = SDL_GetTicks() + interval;
    t->callback = callback;
    t->param = param;
    pthread_mutex_lock(&tm.lock);
    if (!tm.running) {
        tm.running = 1;
        if (pthread_create(&tm.thread, NULL, timer_thread, NULL) != 0) {
            tm.running = 0;
            pthread_mutex_unlock(&tm.lock);
            free(t);
            SDL_SetError("Can't create the timer thread");
            return NULL;
        }
    }
    t->next = tm.list;
    tm.list = t;
    pthread_cond_signal(&tm.wake);
    pthread_mutex_unlock(&tm.lock);
    return t;
}

SDL_bool SDL_RemoveTimer(SDL_TimerID id)
{
    SDL_bool found = SDL_FALSE;
    pthread_mutex_lock(&tm.lock);
    for (struct _SDL_TimerID **p = &tm.list; *p; p = &(*p)->next) {
        if (*p == id) {
            *p = id->next;
            free(id);
            found = SDL_TRUE;
            break;
        }
    }
    pthread_mutex_unlock(&tm.lock);
    return found;
}

static Uint32 old_callback(Uint32 interval, void *param)
{
    (void)param;
    return tm.old ? tm.old(interval) : 0;
}

int SDL_SetTimer(Uint32 interval, SDL_TimerCallback callback)
{
    if (tm.old_id) SDL_RemoveTimer(tm.old_id);
    tm.old_id = NULL;
    tm.old = callback;
    if (interval && callback) {
        tm.old_id = SDL_AddTimer(interval, old_callback, NULL);
        if (tm.old_id == NULL) return -1;
    }
    return 0;
}

void SDL12_TimerQuit(void)
{
    pthread_mutex_lock(&tm.lock);
    int was = tm.running;
    tm.running = 0;
    pthread_cond_signal(&tm.wake);
    pthread_mutex_unlock(&tm.lock);
    if (was) pthread_join(tm.thread, NULL);
    while (tm.list) {
        struct _SDL_TimerID *t = tm.list;
        tm.list = t->next;
        free(t);
    }
    tm.old_id = NULL;
}

/* JOYSTICKS: NONE */

int SDL_NumJoysticks(void) { return 0; }
const char *SDL_JoystickName(int i) { (void)i; return NULL; }

SDL_Joystick *SDL_JoystickOpen(int i)
{
    SDL_SetError("There are %d joysticks available", 0);
    (void)i;
    return NULL;
}

int SDL_JoystickOpened(int i) { (void)i; return 0; }
int SDL_JoystickIndex(SDL_Joystick *j) { (void)j; return -1; }
int SDL_JoystickNumAxes(SDL_Joystick *j) { (void)j; return 0; }
int SDL_JoystickNumBalls(SDL_Joystick *j) { (void)j; return 0; }
int SDL_JoystickNumHats(SDL_Joystick *j) { (void)j; return 0; }
int SDL_JoystickNumButtons(SDL_Joystick *j) { (void)j; return 0; }
void SDL_JoystickUpdate(void) {}
int SDL_JoystickEventState(int state) { return state == SDL_QUERY ? SDL_IGNORE : state; }
Sint16 SDL_JoystickGetAxis(SDL_Joystick *j, int a) { (void)j, (void)a; return 0; }
Uint8 SDL_JoystickGetHat(SDL_Joystick *j, int h) { (void)j, (void)h; return SDL_HAT_CENTERED; }
int SDL_JoystickGetBall(SDL_Joystick *j, int b, int *dx, int *dy) { (void)j, (void)b, (void)dx, (void)dy; return -1; }
Uint8 SDL_JoystickGetButton(SDL_Joystick *j, int b) { (void)j, (void)b; return 0; }
void SDL_JoystickClose(SDL_Joystick *j) { (void)j; }

/* CD-ROM AUDIO: NO DRIVES */

int SDL_CDNumDrives(void) { return 0; }
const char *SDL_CDName(int drive) { (void)drive; SDL_SetError("Invalid CD-ROM drive index"); return NULL; }

SDL_CD *SDL_CDOpen(int drive)
{
    (void)drive;
    SDL_SetError("Invalid CD-ROM drive index");
    return NULL;
}

CDstatus SDL_CDStatus(SDL_CD *cdrom) { (void)cdrom; return CD_ERROR; }
int SDL_CDPlayTracks(SDL_CD *cdrom, int start_track, int start_frame, int ntracks, int nframes)
{
    (void)cdrom, (void)start_track, (void)start_frame, (void)ntracks, (void)nframes;
    return -1;
}
int SDL_CDPlay(SDL_CD *cdrom, int start, int length) { (void)cdrom, (void)start, (void)length; return -1; }
int SDL_CDPause(SDL_CD *cdrom) { (void)cdrom; return -1; }
int SDL_CDResume(SDL_CD *cdrom) { (void)cdrom; return -1; }
int SDL_CDStop(SDL_CD *cdrom) { (void)cdrom; return -1; }
int SDL_CDEject(SDL_CD *cdrom) { (void)cdrom; return -1; }
void SDL_CDClose(SDL_CD *cdrom) { (void)cdrom; }
