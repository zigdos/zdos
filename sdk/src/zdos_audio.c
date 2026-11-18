/* zdos_media.h's audio, on WASAPI's event model with a timer for
   the event: the thread wakes once a period (the program's frames
   at its rate, absolute deadlines), asks the program's callback for
   one period and writes it, keeping the card's queue about TARGET
   deep. Uneven reads by the card (QEMU's AC'97) stay in that queue:
   the callback runs at an even pace. Paused: no wake-ups. */
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include "zdos.h"
#include "zdos_media.h"

/* The queue kept: 3 periods, at least TARGET_MS */
#define TARGET_PERIODS 3
#define TARGET_MS 60
/* Above the default 16, as Windows (MMCSS) puts audio threads */
#define FEED_PRIORITY 20

static struct {
    bool on;
    int handle;
    uint8_t *buf;
    size_t len;        /* one period */
    size_t target;     /* bytes queued at the card */
    uint64_t period;   /* nanoseconds */
    uint8_t silence;
    zdos_audio_fill fill;
    void *user;
    pthread_t thread;
    pthread_mutex_t lock; /* around fill */
    pthread_mutex_t wait; /* the paused state */
    pthread_cond_t resume;
    int run;
    bool paused;
} au;

/* Silence to TARGET: the queue the periods then keep */
static bool prime(void) {
    size_t q = zdos->sound->queued(au.handle);
    memset(au.buf, au.silence, au.len);
    for (size_t at = q; at < au.target;) {
        size_t n = au.target - at < au.len ? au.target - at : au.len;
        intptr_t w = zdos->sound->write(au.handle, au.buf, n & ~(size_t)3);
        if (w <= 0) return w == 0;
        at += (size_t)w;
    }
    return true;
}

static bool write_all(const uint8_t *p, size_t len) {
    for (size_t done = 0; done < len;) {
        intptr_t n = zdos->sound->write(au.handle, p + done, len - done);
        if (n < 0) return false;
        done += (size_t)n;
    }
    return true;
}

static bool running(void) {
    return __atomic_load_n(&au.run, __ATOMIC_ACQUIRE) != 0;
}

static void *feed(void *arg) {
    (void)arg;
    zdos->tasks->set_priority(zdos->tasks->id(), FEED_PRIORITY); /* refused: as it is */
    if (!prime()) return NULL;
    uint64_t next = zdos->time->nanos();
    while (running()) {
        pthread_mutex_lock(&au.wait);
        if (au.paused) {
            while (au.paused && running()) pthread_cond_wait(&au.resume, &au.wait);
            pthread_mutex_unlock(&au.wait);
            if (!running() || !prime()) break;
            next = zdos->time->nanos();
            continue;
        }
        pthread_mutex_unlock(&au.wait);

        /* One period, unless the card's queue is deep already (its
           clock slower than ours) */
        size_t q = zdos->sound->queued(au.handle);
        if (q < au.target + au.len) {
            pthread_mutex_lock(&au.lock);
            au.fill(au.user, au.buf, au.len);
            pthread_mutex_unlock(&au.lock);
            if (!write_all(au.buf, au.len)) break;
            q += au.len;
        }
        /* Below TARGET (the card's clock faster than ours): the next
           period an eighth sooner, so the queue stays at TARGET; below
           half (a stall), twice the pace, never in a burst */
        next += q < au.target / 2 ? au.period / 2 : q < au.target ? au.period - au.period / 8 : au.period;
        uint64_t now = zdos->time->nanos();
        if (next + au.period < now) next = now; /* late by more than a period: on from now */
        while (running() && zdos->time->nanos() < next) zdos->time->nap_until(next);
    }
    return NULL;
}

bool zdos_audio_start(uint32_t rate, uint32_t channels, uint32_t bits, uint32_t frames, zdos_audio_fill fill, void *user) {
    if (au.on) zdos_audio_stop();
    if (fill == NULL || frames == 0) {
        zdos->sound->open(0, 0, 0); /* fails with INVALID_ARGUMENT */
        return false;
    }
    int h = zdos->sound->open(rate, channels, bits);
    if (h < 0) return false;
    size_t frame = (size_t)channels * (bits / 8);
    au.len = (size_t)frames * frame;
    au.buf = malloc(au.len);
    if (au.buf == NULL) {
        zdos->sound->close(h, true);
        return false;
    }
    size_t floor = (size_t)rate * TARGET_MS / 1000 * frame;
    au.target = TARGET_PERIODS * au.len > floor ? TARGET_PERIODS * au.len : floor;
    au.period = (uint64_t)frames * 1000000000u / rate;
    au.silence = bits == 8 ? 0x80 : 0;
    au.handle = h;
    au.fill = fill;
    au.user = user;
    au.run = 1;
    au.paused = false;
    // Recursive, as SDL's audio lock: a program may lock it again in
    // what its locked code calls (DOSBox's mixer does)
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&au.lock, &attr);
    pthread_mutexattr_destroy(&attr);
    pthread_mutex_init(&au.wait, NULL);
    pthread_cond_init(&au.resume, NULL);
    if (pthread_create(&au.thread, NULL, feed, NULL) != 0) {
        zdos->sound->close(h, true);
        free(au.buf);
        pthread_mutex_destroy(&au.lock);
        pthread_mutex_destroy(&au.wait);
        pthread_cond_destroy(&au.resume);
        return false;
    }
    au.on = true;
    return true;
}

void zdos_audio_pause(bool pause) {
    if (!au.on) return;
    pthread_mutex_lock(&au.wait);
    au.paused = pause;
    pthread_cond_signal(&au.resume);
    pthread_mutex_unlock(&au.wait);
}

void zdos_audio_lock(void) {
    if (au.on) pthread_mutex_lock(&au.lock);
}

void zdos_audio_unlock(void) {
    if (au.on) pthread_mutex_unlock(&au.lock);
}

void zdos_audio_stop(void) {
    if (!au.on) return;
    __atomic_store_n(&au.run, 0, __ATOMIC_RELEASE);
    zdos_audio_pause(false); /* a paused thread wakes to end */
    pthread_join(au.thread, NULL);
    zdos->sound->close(au.handle, true);
    pthread_mutex_destroy(&au.lock);
    pthread_mutex_destroy(&au.wait);
    pthread_cond_destroy(&au.resume);
    free(au.buf);
    au.on = false;
}
