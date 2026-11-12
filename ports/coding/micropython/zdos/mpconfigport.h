#include <stdint.h>

// Use basic features instead of absolute
// minimum to enable REPL & compiler support
#define MICROPY_CONFIG_ROM_LEVEL (MICROPY_CONFIG_ROM_LEVEL_BASIC_FEATURES)

// Use MicroPython's bundled fdlibm-based libm_dbl implementation for the
// software math functions on each supported ZDOS architecture.
#define MICROPY_FLOAT_IMPL (MICROPY_FLOAT_IMPL_DOUBLE)

// x86: ints past 31 bits as 64-bit long long, as far as the 64-bit
// builds' small ints go
#if defined(__i386__)
#define MICROPY_LONGINT_IMPL (MICROPY_LONGINT_IMPL_LONGLONG)
#endif

// Custom config.
#define MICROPY_HEAP_SIZE (2 * 1024 * 1024)
#define MICROPY_MODULE_FROZEN           (0)

// You can disable the built-in MicroPython compiler by setting the following
// config option to 0.  If you do this then you won't get a REPL prompt, but you
// will still be able to execute pre-compiled scripts, compiled with mpy-cross.
#define MICROPY_ENABLE_COMPILER     (1)

//#define MICROPY_QSTR_EXTRA_POOL           mp_qstr_frozen_const_pool
#define MICROPY_ENABLE_GC                 (1)
#define MICROPY_HELPER_REPL               (1)
//#define MICROPY_MODULE_FROZEN_MPY         (1)
#define MICROPY_ENABLE_EXTERNAL_IMPORT    (1)
// Return conventional process exit codes for scripts run by ZDOS.
#define MICROPY_PYEXEC_ENABLE_EXIT_CODE_HANDLING (1)
// ZDOS provides a file API; zdos_vfs.c exposes it through MicroPython VFS.
#define MICROPY_VFS                       (1)
#define MICROPY_PY_OS                     (1)
#define MICROPY_PY_SYS_PATH               (1)
#define MICROPY_PY_SYS_MODULES            (1)
#define MICROPY_PY_SYS_ARGV               (1)
#define MICROPY_PY_SYS_EXIT               (1)
// The codes ZDOS reports (zdos_errno_from_code in sdk/src/zdos_fs.c);
// ENOTEMPTY isn't in py/mperrno.h, so the port defines it (Linux's 39).
#define MICROPY_PY_ERRNO                  (1)

// Ctrl+C raises KeyboardInterrupt in running code: every 1000 loop jumps or
// returns the interpreter looks at the keyboard (uart_core.c). Keys found
// there are kept for input() and the REPL.
#define MICROPY_KBD_EXCEPTION             (1)
void zdos_poll_interrupt(void);
#define MICROPY_VM_HOOK_COUNT             (1000)
#define MICROPY_VM_HOOK_INIT static unsigned int vm_hook_divisor = MICROPY_VM_HOOK_COUNT;
#define MICROPY_VM_HOOK_POLL if (--vm_hook_divisor == 0) { \
        vm_hook_divisor = MICROPY_VM_HOOK_COUNT; \
        zdos_poll_interrupt(); \
}
#define MICROPY_VM_HOOK_LOOP MICROPY_VM_HOOK_POLL
#define MICROPY_VM_HOOK_RETURN MICROPY_VM_HOOK_POLL
#define MP_ENOTEMPTY                      (39)
#define MICROPY_PY_ERRNO_LIST \
    X(EPERM) X(ENOENT) X(EIO) X(EBADF) X(EAGAIN) X(ENOMEM) X(EACCES) \
    X(EEXIST) X(ENODEV) X(ENOTDIR) X(EISDIR) X(EINVAL) X(EMFILE) \
    X(ENOSPC) X(EROFS) X(ENOTEMPTY) X(EOPNOTSUPP)
#define MICROPY_PY_COLLECTIONS_DEQUE       (1)
#define MICROPY_PY_COLLECTIONS_DEQUE_ITER  (1)
#define MICROPY_PY_COLLECTIONS_DEQUE_SUBSCR (1)
#define MICROPY_PY_COLLECTIONS_ORDEREDDICT  (1)
#define MICROPY_PY_MATH                   (1)
#define MICROPY_PY_MATH_CONSTANTS         (1)
#define MICROPY_PY_MATH_SPECIAL_FUNCTIONS (1)
#define MICROPY_PY_MATH_FACTORIAL          (1)
#define MICROPY_PY_MATH_ISCLOSE            (1)
#define MICROPY_PY_CMATH                  (1)
#define MICROPY_PY_JSON                   (1)
#define MICROPY_PY_RE                     (1)
#define MICROPY_PY_RE_SUB                 (1)
#define MICROPY_PY_HEAPQ                  (1)
#define MICROPY_PY_BINASCII               (1)
#define MICROPY_PY_HASHLIB                (1)
#define MICROPY_PY_HASHLIB_SHA256         (1)
#define MICROPY_PY_TIME                   (1)
// Enable calendar tuple conversions. ZDOS supplies local wall-clock fields,
// but no UTC offset, so time.time()/time_ns() remain unavailable.
#define MICROPY_PY_TIME_GMTIME_LOCALTIME_MKTIME (1)
// No automatic seed is configured; scripts can seed the PRNG explicitly.
#define MICROPY_PY_RANDOM                 (1)
#define MICROPY_PY_RANDOM_EXTRA_FUNCS     (1)
#define MICROPY_PY_DEFLATE                (1)
#define MICROPY_PY_DEFLATE_COMPRESS       (0)
#define MICROPY_PY_PLATFORM               (1)
#define MICROPY_PY_TIME_INCLUDEFILE       "zdos_time.h"
// Match the familiar interactive-Python quit() helper using sys.exit semantics.
#define MICROPY_PORT_BUILTINS \
    { MP_ROM_QSTR(MP_QSTR_quit), MP_ROM_PTR(&mp_sys_exit_obj) },
// MicroPython's POSIX reader is backed by zdos_fs.c's open/read/close shims.
#define MICROPY_READER_POSIX              (1)
// ZDOS provides cursor APIs but its print callback is not a VT100 terminal.
#define MICROPY_HAL_HAS_VT100              (0)
#define MICROPY_REPL_EMACS_KEYS            (1)
void mp_hal_move_cursor_back(unsigned int pos);
void mp_hal_erase_line_from_cursor(unsigned int n_chars_to_erase);
// ZDOS paths: "C:" and up to 1024 bytes
#define MICROPY_ALLOC_PATH_MAX            (1028)

// Use the minimum headroom in the chunk allocator for parse nodes.
#define MICROPY_ALLOC_PARSE_CHUNK_INIT    (16)

// Disable all optional sys module features.

// type definitions for the specific machine

typedef long mp_off_t;

// We need to provide a declaration/definition of alloca()
#include <alloca.h>

// Shown in the banner: "MicroPython v1.29.0 on <date>;
// zdos-minimal with x86-64"
#define MICROPY_HW_BOARD_NAME "zdos-minimal"
#if defined(__x86_64__)
#define MICROPY_HW_MCU_NAME "x86-64"
#elif defined(__i386__)
#define MICROPY_HW_MCU_NAME "x86"
#elif defined(__aarch64__)
#define MICROPY_HW_MCU_NAME "ARM64"
#else
#define MICROPY_HW_MCU_NAME "unknown-cpu"
#endif

#if defined(__linux__) || defined(__APPLE__)
#define MICROPY_MIN_USE_STDOUT (1)
#define MICROPY_HEAP_SIZE      (25600) // heap size 25 kilobytes
#endif

#ifdef __thumb__
#define MICROPY_MIN_USE_CORTEX_CPU (1)
#define MICROPY_MIN_USE_STM32_MCU (1)
#define MICROPY_HEAP_SIZE      (2048) // heap size 2 kilobytes
#endif

#define MP_STATE_PORT MP_STATE_VM
