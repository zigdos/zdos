/* zdos_media.h's audio: a thread that fills a buffer from the program's
   callback and writes it to the sound card (sound->write waits while the
   card's queue is full, which paces it). */
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include "zdos.h"
#include "zdos_media.h"

static struct {
    bool on;
    int handle;
    uint8_t *buf;
    size_t len;
    zdos_audio_fill fill;
    void *user;
    pthread_t thread;
    pthread_mutex_t lock;
    int run;
} au;

static void *feed(void *arg) {
    (void)arg;
    while (__atomic_load_n(&au.run, __ATOMIC_ACQUIRE)) {
        pthread_mutex_lock(&au.lock);
        au.fill(au.user, au.buf, au.len);
        pthread_mutex_unlock(&au.lock);
        for (size_t done = 0; done < au.len && __atomic_load_n(&au.run, __ATOMIC_ACQUIRE);) {
            intptr_t n = zdos->sound->write(au.handle, au.buf + done, au.len - done);
            if (n < 0) return NULL;
            done += (size_t)n;
        }
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
    au.len = (size_t)frames * channels * (bits / 8);
    au.buf = malloc(au.len);
    if (au.buf == NULL) {
        zdos->sound->close(h, true);
        return false;
    }
    au.handle = h;
    au.fill = fill;
    au.user = user;
    au.run = 1;
    pthread_mutex_init(&au.lock, NULL);
    if (pthread_create(&au.thread, NULL, feed, NULL) != 0) {
        zdos->sound->close(h, true);
        free(au.buf);
        pthread_mutex_destroy(&au.lock);
        return false;
    }
    au.on = true;
    return true;
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
    pthread_join(au.thread, NULL);
    zdos->sound->close(au.handle, true);
    pthread_mutex_destroy(&au.lock);
    free(au.buf);
    au.on = false;
}
