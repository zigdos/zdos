#ifndef MICROPY_INCLUDED_MINIMAL_MPHALPORT_H
#define MICROPY_INCLUDED_MINIMAL_MPHALPORT_H

// MicroPython's hardware hooks (py/mphal.h includes this file) on top of the
// ZDOS program API: its millisecond clock and sleep
#include "zdos.h"

static inline mp_uint_t mp_hal_ticks_ms(void) {
    return zdos != NULL && zdos->time->millis != NULL ? (mp_uint_t)zdos->time->millis() : 0;
}

// ZDOS exposes millisecond resolution, so microsecond hooks are rounded to ms.
static inline mp_uint_t mp_hal_ticks_us(void) {
    return mp_hal_ticks_ms() * 1000;
}

static inline mp_uint_t mp_hal_ticks_cpu(void) {
    return mp_hal_ticks_us();
}

// In uart_core.c: sleeps in steps, so Ctrl+C interrupts time.sleep()
void mp_hal_delay_ms(mp_uint_t ms);

static inline void mp_hal_delay_us(mp_uint_t us) {
    if (us != 0) {
        mp_hal_delay_ms((us + 999) / 1000);
    }
}

// Ctrl+C as KeyboardInterrupt: pyexec sets the interrupt character while
// code runs (-1 at the REPL prompt, where Ctrl+C just drops the line)
#include "shared/runtime/interrupt_char.h"

#endif
