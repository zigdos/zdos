#include <unistd.h>
#include "py/mpconfig.h"
#include "py/runtime.h"
#include "py/mphal.h"
#include "zdos.h"

// KEYBOARD: CTRL+C AS KEYBOARDINTERRUPT
// While code runs, the interpreter calls zdos_poll_interrupt now and then
// (MICROPY_VM_HOOK_* in mpconfigport.h). Ctrl+C schedules KeyboardInterrupt;
// other keys typed meanwhile wait in this queue for mp_hal_stdin_rx_chr.
#define KEY_QUEUE_SIZE 32
static zdos_key key_queue[KEY_QUEUE_SIZE];
static unsigned int key_start;
static unsigned int key_count;

void zdos_poll_interrupt(void) {
    if (zdos == NULL || zdos->console->poll_key == NULL || mp_interrupt_char < 0) {
        return;
    }
    zdos_key k;
    while (zdos->console->poll_key(&k)) {
        if (k.char_ == mp_interrupt_char) {
            mp_sched_keyboard_interrupt();
        } else if (key_count < KEY_QUEUE_SIZE) {
            key_queue[(key_start + key_count) % KEY_QUEUE_SIZE] = k;
            ++key_count;
        }
    }
}

static zdos_key next_key(void) {
    if (key_count > 0) {
        zdos_key k = key_queue[key_start];
        key_start = (key_start + 1) % KEY_QUEUE_SIZE;
        --key_count;
        return k;
    }
    return zdos->console->read_key();
}

// time.sleep(): in steps, looking for Ctrl+C in between
void mp_hal_delay_ms(mp_uint_t ms) {
    if (zdos == NULL || zdos->time->sleep == NULL) {
        return;
    }
    for (;;) {
        zdos_poll_interrupt();
        mp_handle_pending(MP_HANDLE_PENDING_CALLBACKS_AND_EXCEPTIONS);
        if (ms == 0) {
            return;
        }
        mp_uint_t step = ms < 20 ? ms : 20;
        zdos->time->sleep((uint32_t)step);
        ms -= step;
    }
}

// readline.c uses these hooks when the console is not a VT100 terminal.
void mp_hal_move_cursor_back(unsigned int pos) {
    if (zdos == NULL || zdos->console->get_cursor == NULL || zdos->console->set_cursor == NULL || pos == 0) {
        return;
    }
    zdos_pos cursor = zdos->console->get_cursor();
    if (pos <= cursor.col) {
        cursor.col -= pos;
    } else {
        zdos_pos size = zdos->console->screen_size();
        unsigned int remaining = pos - cursor.col;
        if (cursor.row == 0 || size.col == 0) {
            cursor.col = 0;
        } else {
            --cursor.row;
            cursor.col = remaining >= size.col ? 0 : size.col - remaining;
        }
    }
    zdos->console->set_cursor(cursor.col, cursor.row);
}

void mp_hal_erase_line_from_cursor(unsigned int n_chars_to_erase) {
    if (zdos == NULL || zdos->console->get_cursor == NULL || zdos->console->set_cursor == NULL || zdos->console->print == NULL) {
        return;
    }
    zdos_pos cursor = zdos->console->get_cursor();
    static const char spaces[] = "                                ";
    while (n_chars_to_erase != 0) {
        unsigned int n = n_chars_to_erase < sizeof(spaces) - 1 ? n_chars_to_erase : sizeof(spaces) - 1;
        zdos->console->print(spaces, n);
        n_chars_to_erase -= n;
    }
    zdos->console->set_cursor(cursor.col, cursor.row);
}

/*
 * Core UART functions to implement for a port
 */

#if MICROPY_MIN_USE_STM32_MCU
typedef struct {
    volatile uint32_t SR;
    volatile uint32_t DR;
} periph_uart_t;
#define USART1 ((periph_uart_t *)0x40011000)
#endif

// Receive single character
int mp_hal_stdin_rx_chr(void) {
    unsigned char c = 0;
    if (zdos != NULL) {
        static char escape_sequence[2];
        static unsigned int escape_pos;
        static bool escape_pending;
        if (escape_pending) {
            int c = escape_sequence[escape_pos++];
            if (escape_pos == sizeof(escape_sequence)) {
                escape_pending = false;
            }
            return c;
        }
        if (zdos->console->input_redirected && zdos->console->input_redirected()) {
            size_t n = zdos->console->read_input(&c, 1);
            return n == 1 ? c : '\n';
        }
        zdos_key key = next_key();
        char arrow = 0;
        switch (key.scan) {
            case ZDOS_SCAN_UP: arrow = 'A'; break;
            case ZDOS_SCAN_DOWN: arrow = 'B'; break;
            case ZDOS_SCAN_RIGHT: arrow = 'C'; break;
            case ZDOS_SCAN_LEFT: arrow = 'D'; break;
            case ZDOS_SCAN_HOME: arrow = 'H'; break;
            case ZDOS_SCAN_END: arrow = 'F'; break;
            default: break;
        }
        if (arrow != 0) {
            escape_sequence[0] = '[';
            escape_sequence[1] = arrow;
            escape_pos = 0;
            escape_pending = true;
            return 27;
        }
        if (key.char_ == '\r') {
            return '\r';
        }
        return (int)key.char_;
    }
    #if MICROPY_MIN_USE_STDOUT
    int r = read(STDIN_FILENO, &c, 1);
    (void)r;
    #elif MICROPY_MIN_USE_STM32_MCU
    // wait for RXNE
    while ((USART1->SR & (1 << 5)) == 0) {
    }
    c = USART1->DR;
    #endif
    return c;
}

// Send string of given length
mp_uint_t mp_hal_stdout_tx_strn(const char *str, mp_uint_t len) {
    mp_uint_t ret = len;
    if (zdos != NULL) {
        zdos->console->print(str, len);
        return len;
    }
    #if MICROPY_MIN_USE_STDOUT
    int r = write(STDOUT_FILENO, str, len);
    if (r < 0) {
        // in case of an error in the syscall, report no bytes written
        ret = 0;
    }
    #elif MICROPY_MIN_USE_STM32_MCU
    while (len--) {
        // wait for TXE
        while ((USART1->SR & (1 << 7)) == 0) {
        }
        USART1->DR = *str++;
    }
    #endif
    return ret;
}
