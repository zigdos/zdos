#include "zdos.h"
#include "zdos_errno.h"
#include "zdos_internal.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/statvfs.h>
#include <unistd.h>
#include <fnmatch.h>
#include <ftw.h>
#include <glob.h>
#include <sys/time.h>
#include <time.h>
#include <utime.h>

// Three descriptors are reserved for the process standard streams. A slot is
// free while zdos_file_used is false (static storage starts out all false).
#define MAX_ZDOS_FILES ZDOS_MAX_FILES
static bool zdos_file_used[MAX_ZDOS_FILES];
static int32_t zdos_file_handles[MAX_ZDOS_FILES];
static uint64_t zdos_file_positions[MAX_ZDOS_FILES];
static bool zdos_file_append[MAX_ZDOS_FILES];
static bool zdos_file_readable[MAX_ZDOS_FILES];
static bool zdos_file_writable[MAX_ZDOS_FILES];
static char zdos_file_drive[MAX_ZDOS_FILES]; /* for fstatvfs */

/* A descriptor whose bytes are in memory (fmemopen, open_memstream) instead
   of a ZDOS file; its position is in zdos_file_positions. */
struct zdos_memfile {
    char *buf;
    size_t size;     /* fmemopen: the buffer's size; open_memstream: what is allocated */
    size_t len;      /* the bytes written or given */
    bool own_buf;    /* fmemopen with buf NULL: freed at close */
    bool grows;      /* open_memstream: buf grows, and *out / *out_size follow it */
    char **out;
    size_t *out_size;
};
static struct zdos_memfile *zdos_file_mem[MAX_ZDOS_FILES];
/* dup of 0, 1 or 2 while that stream isn't redirected: 1 + the stream */
static uint8_t zdos_file_alias[MAX_ZDOS_FILES];
static bool zdos_file_nonblock[MAX_ZDOS_FILES]; /* O_NONBLOCK: a pipe read doesn't wait */
static bool zdos_file_tty[MAX_ZDOS_FILES]; /* opened as /dev/tty: a terminal */
static bool zdos_file_socket[MAX_ZDOS_FILES]; /* a socket (zdos_net.c) */

/* Standard streams moved by dup2: a handle of ours for each (-1:
   none). ZDOS's own streams are redirected to it too (programs
   started from here get them). */
static int32_t std_handle[3] = {-1, -1, -1};

zdos_vfork_fds *zdos_vfork_child;
ssize_t (*zdos_tty_read_hook)(void *buf, size_t count);

// ZDOS error codes as errno values. Where POSIX has no exact match the
// nearest one is used: a missing folder on the way is ENOENT too, a
// write-protected disk EROFS, a failing disk EIO.
int zdos_errno_from_code(unsigned int code) {
    switch (code) {
        case ZDOS_ERROR_NONE: return 0;
        case ZDOS_ERROR_NOT_FOUND:
        case ZDOS_ERROR_PATH_NOT_FOUND: return ENOENT;
        case ZDOS_ERROR_ALREADY_EXISTS: return EEXIST;
        case ZDOS_ERROR_ACCESS_DENIED: return EACCES;
        case ZDOS_ERROR_WRITE_PROTECTED: return EROFS;
        case ZDOS_ERROR_DISK_FULL: return ENOSPC;
        case ZDOS_ERROR_TOO_MANY_OPEN: return EMFILE;
        case ZDOS_ERROR_INVALID_HANDLE: return EBADF;
        case ZDOS_ERROR_OUT_OF_MEMORY: return ENOMEM;
        case ZDOS_ERROR_INVALID_NAME: return EINVAL;
        case ZDOS_ERROR_NOT_SUPPORTED: return EOPNOTSUPP;
        case ZDOS_ERROR_NOT_A_DIRECTORY: return ENOTDIR;
        case ZDOS_ERROR_IS_A_DIRECTORY: return EISDIR;
        case ZDOS_ERROR_DIR_NOT_EMPTY: return ENOTEMPTY;
        case ZDOS_ERROR_INVALID_ARGUMENT: return EINVAL;
        case ZDOS_ERROR_INTERRUPTED: return EINTR;
        case ZDOS_ERROR_TIMED_OUT: return ETIMEDOUT;
        case ZDOS_ERROR_WOULD_BLOCK: return EAGAIN;
        case ZDOS_ERROR_BROKEN_PIPE: return EPIPE;
        case ZDOS_ERROR_NO_CHILD: return ECHILD;
        case ZDOS_ERROR_NETWORK_DOWN: return ENETDOWN;
        case ZDOS_ERROR_IN_PROGRESS: return EINPROGRESS;
        case ZDOS_ERROR_ALREADY: return EALREADY;
        case ZDOS_ERROR_ADDRESS_IN_USE: return EADDRINUSE;
        case ZDOS_ERROR_HOST_UNREACHABLE: return EHOSTUNREACH;
        case ZDOS_ERROR_IS_CONNECTED: return EISCONN;
        case ZDOS_ERROR_NOT_CONNECTED: return ENOTCONN;
        case ZDOS_ERROR_CONNECTION_REFUSED: return ECONNREFUSED;
        case ZDOS_ERROR_CONNECTION_RESET: return ECONNRESET;
        case ZDOS_ERROR_CONNECTION_ABORTED: return ECONNABORTED;
        case ZDOS_ERROR_MESSAGE_TOO_LONG: return EMSGSIZE;
        case ZDOS_ERROR_HOST_NOT_FOUND: return EHOSTUNREACH;
        case ZDOS_ERROR_NOT_A_SOCKET: return ENOTSOCK;
        default: return EIO; /* ZDOS_ERROR_DEVICE_ERROR and unknown codes */
    }
}

// No last_error in the table: the cause is unknown
int zdos_errno_from_last_error(void) {
    if (zdos == NULL || zdos->programs->last_error == NULL) return EIO;
    int e = zdos_errno_from_code(zdos->programs->last_error());
    return e != 0 ? e : EIO; /* the call failed, so never "no error" */
}

// The last call's ZDOS error code (ZDOS_ERROR_NONE if it can't be told)
static uint32_t last_code(void) {
    return zdos != NULL && zdos->programs->last_error != NULL ? zdos->programs->last_error() : ZDOS_ERROR_NONE;
}

// -1 with errno from the ZDOS call that just failed
static int fail_last(void) {
    errno = zdos_errno_from_last_error();
    return -1;
}

static int fail(int e) {
    errno = e;
    return -1;
}

static bool valid_fd(int fd) {
    return fd >= 3 && fd < MAX_ZDOS_FILES && zdos_file_used[fd];
}

static bool is_std_fd(int fd) {
    return fd >= 0 && fd <= 2;
}

// A dup of a standard stream acts as that stream
static int resolve_fd(int fd) {
    if (fd >= 3 && fd < MAX_ZDOS_FILES && zdos_file_used[fd] && zdos_file_alias[fd] != 0) {
        return zdos_file_alias[fd] - 1;
    }
    return fd;
}

/* STANDARD INPUT FROM THE KEYBOARD
   Without redirection, a line editor: Backspace, Delete, Esc (the whole
   line), Left / Right / Home / End, Up / Down recall earlier lines. Enter ends
   the line ('\n' included); Ctrl+Z or Ctrl+D at its start ends the input.
   Echo only while the output goes to the screen. */

#define HISTORY_LINES 16

static char stdin_line[256];
static size_t stdin_len;     /* bytes in the line being typed */
static size_t stdin_cur;     /* the cursor: a byte index into stdin_line */
static size_t stdin_pos;     /* how much of the line the program has read */

static char history[HISTORY_LINES][256];
static size_t history_size[HISTORY_LINES];
static size_t history_count; /* lines kept, the newest last */
static size_t history_next;  /* the slot the next line goes to */

static void echo(const char *s, size_t n) {
    if (zdos->console->output_redirected == NULL || !zdos->console->output_redirected()) {
        zdos->console->print(s, n);
    }
}

// Sends an ANSI sequence: ESC [ n final
// (the cursor moves, erase to end of line)
static void csi(size_t n, char final) {
    char seq[24];
    size_t len = 0;
    seq[len++] = '\x1b';
    seq[len++] = '[';
    char digits[20];
    size_t d = 0;
    do {
        digits[d++] = (char)('0' + n % 10);
        n /= 10;
    } while (n > 0);
    while (d > 0) seq[len++] = digits[--d];
    seq[len++] = final;
    echo(seq, len);
}

// The number of characters (not bytes) in s[0..n)
static size_t count_chars(const char *s, size_t n) {
    size_t count = 0;
    for (size_t i = 0; i < n; i++) {
        if (((unsigned char)s[i] & 0xC0) != 0x80) count++;
    }
    return count;
}

// The byte index of the character before (or after) index i in the line
static size_t char_before(size_t i) {
    do {
        --i;
    } while (i > 0 && ((unsigned char)stdin_line[i] & 0xC0) == 0x80);
    return i;
}

static size_t char_after(size_t i) {
    i++;
    while (i < stdin_len && ((unsigned char)stdin_line[i] & 0xC0) == 0x80) i++;
    return i;
}

// Shows the line from index from again, clears the rest of the line and puts
// the cursor back at stdin_cur (the cursor is at the end after the echo)
static void redraw(size_t from) {
    echo(stdin_line + from, stdin_len - from);
    csi(0, 'K');
    size_t back = count_chars(stdin_line + stdin_cur, stdin_len - stdin_cur);
    if (back > 0) csi(back, 'D');
}

// Replaces the line with the text (Up / Down); the cursor goes to the end
static void show_line(const char *text, size_t n) {
    csi(count_chars(stdin_line, stdin_cur), 'D');
    memcpy(stdin_line, text, n);
    stdin_len = n;
    stdin_cur = n;
    echo(stdin_line, stdin_len);
    csi(0, 'K');
}

// Recall position: history_count is the line being typed, lower numbers older
static size_t history_at;

/* What the program printed on the screen since its last newline
   (its prompt, usually): shown again with the line being typed when
   another task's output took the line's place (ZDOS_SCAN_REDRAW) */
static char tail_line[128];
static size_t tail_len;

static void note_output(const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '\n' || s[i] == '\r') {
            tail_len = 0;
        } else if (tail_len < sizeof(tail_line)) {
            tail_line[tail_len++] = s[i];
        }
    }
}

// Where the line being typed starts, for ZDOS (console->edit_line)
static void tell_edit_row(void) {
    if (zdos->console->edit_line != NULL && zdos->console->get_cursor != NULL) {
        zdos->console->edit_line((int32_t)zdos->console->get_cursor().row);
    }
}

// Prompt and line again below another task's output;
// the cursor where it was in the line
static void show_again(void) {
    if (zdos->console->get_cursor().col != 0) {
        echo("\n", 1);
    }
    echo(tail_line, tail_len);
    echo(stdin_line, stdin_len);
    size_t back = count_chars(stdin_line + stdin_cur, stdin_len - stdin_cur);
    if (back > 0) csi(back, 'D');
}

static void remember_line(void) {
    if (stdin_len == 0) return;
    memcpy(history[history_next], stdin_line, stdin_len);
    history_size[history_next] = stdin_len;
    history_next = (history_next + 1) % HISTORY_LINES;
    if (history_count < HISTORY_LINES) history_count++;
}

// Reads a line into stdin_line; false at the end of the input (Ctrl+Z, Ctrl+D)
static bool read_keyboard_line(void) {
    stdin_len = 0;
    stdin_cur = 0;
    stdin_pos = 0;
    history_at = history_count;
    bool told = false; /* ZDOS knows where the line starts */
    for (;;) {
        if (!told) {
            tell_edit_row();
            told = true;
        }
        zdos_key k = zdos->console->read_key();
        uint16_t c = k.char_;
        // Special keys (no character)
        switch (k.scan) {
        case ZDOS_SCAN_REDRAW:
            show_again();
            told = false;
            continue;
        case ZDOS_SCAN_LEFT:
            if (stdin_cur > 0) {
                stdin_cur = char_before(stdin_cur);
                csi(1, 'D');
            }
            continue;
        case ZDOS_SCAN_RIGHT:
            if (stdin_cur < stdin_len) {
                stdin_cur = char_after(stdin_cur);
                csi(1, 'C');
            }
            continue;
        case ZDOS_SCAN_HOME:
            csi(count_chars(stdin_line, stdin_cur), 'D');
            stdin_cur = 0;
            continue;
        case ZDOS_SCAN_END:
            csi(count_chars(stdin_line + stdin_cur, stdin_len - stdin_cur), 'C');
            stdin_cur = stdin_len;
            continue;
        case ZDOS_SCAN_DELETE:
            if (stdin_cur < stdin_len) {
                size_t next = char_after(stdin_cur);
                memmove(stdin_line + stdin_cur, stdin_line + next, stdin_len - next);
                stdin_len -= next - stdin_cur;
                redraw(stdin_cur);
            }
            continue;
        case ZDOS_SCAN_UP:
            if (history_at > 0) {
                history_at--;
                size_t slot = (history_next + HISTORY_LINES - history_count + history_at) % HISTORY_LINES;
                show_line(history[slot], history_size[slot]);
            }
            continue;
        case ZDOS_SCAN_DOWN:
            if (history_at < history_count) {
                history_at++;
                if (history_at == history_count) {
                    show_line("", 0);
                } else {
                    size_t slot = (history_next + HISTORY_LINES - history_count + history_at) % HISTORY_LINES;
                    show_line(history[slot], history_size[slot]);
                }
            }
            continue;
        default:
            break;
        }
        if (c == '\r') {
            if (stdin_cur < stdin_len) csi(count_chars(stdin_line + stdin_cur, stdin_len - stdin_cur), 'C');
            remember_line();
            echo("\n", 1);
            stdin_line[stdin_len++] = '\n';
            stdin_cur = stdin_len;
            if (zdos->console->edit_line != NULL) zdos->console->edit_line(-1);
            tail_len = 0;
            return true;
        }
        if ((c == 0x1A || c == 0x04) && stdin_len == 0) { /* Ctrl+Z (DOS) or Ctrl+D (Unix) */
            echo(c == 0x1A ? "^Z\n" : "^D\n", 3);
            if (zdos->console->edit_line != NULL) zdos->console->edit_line(-1);
            return false;
        }
        if (c == 3) { /* Ctrl+C, when SIGINT is handled: the line is dropped */
            echo("^C\n", 3);
            stdin_len = 0;
            stdin_cur = 0;
            zdos_ctrl_c_typed();
            continue;
        }
        if (c == 0x08) { /* Backspace: the character before the cursor */
            if (stdin_cur > 0) {
                size_t prev = char_before(stdin_cur);
                memmove(stdin_line + prev, stdin_line + stdin_cur, stdin_len - stdin_cur);
                stdin_len -= stdin_cur - prev;
                stdin_cur = prev;
                csi(1, 'D');
                redraw(stdin_cur);
            }
            continue;
        }
        if (c == 0x1B) { /* Esc: the whole line */
            csi(count_chars(stdin_line, stdin_cur), 'D');
            stdin_len = 0;
            stdin_cur = 0;
            csi(0, 'K');
            continue;
        }
        if (c < 0x20) {
            continue;
        }
        // UTF-8, keeping room for '\n'
        char utf8[3];
        size_t n;
        if (c < 0x80) {
            utf8[0] = (char)c;
            n = 1;
        } else if (c < 0x800) {
            utf8[0] = (char)(0xC0 | (c >> 6));
            utf8[1] = (char)(0x80 | (c & 0x3F));
            n = 2;
        } else {
            utf8[0] = (char)(0xE0 | (c >> 12));
            utf8[1] = (char)(0x80 | ((c >> 6) & 0x3F));
            utf8[2] = (char)(0x80 | (c & 0x3F));
            n = 3;
        }
        if (stdin_len + n + 1 > sizeof(stdin_line)) {
            continue;
        }
        // Insert at the cursor: the rest of the line moves along
        memmove(stdin_line + stdin_cur + n, stdin_line + stdin_cur, stdin_len - stdin_cur);
        memcpy(stdin_line + stdin_cur, utf8, n);
        stdin_len += n;
        stdin_cur += n;
        echo(utf8, n);
        if (stdin_cur < stdin_len) redraw(stdin_cur);
    }
}

static ssize_t read_stdin(void *buf, size_t count) {
    if (std_handle[0] >= 0) {
        int64_t n = zdos->files->read(std_handle[0], buf, count);
        return n < 0 ? fail_last() : (ssize_t)n;
    }
    if (zdos->console->input_redirected != NULL && zdos->console->input_redirected()) {
        return (ssize_t)zdos->console->read_input(buf, count);
    }
    if (count == 0) {
        return 0;
    }
    if (zdos_tty_read_hook != NULL) {
        ssize_t r = zdos_tty_read_hook(buf, count); /* raw mode (termios) */
        if (r != -2) {
            return r;
        }
    }
    if (stdin_pos == stdin_len && !read_keyboard_line()) {
        return 0;
    }
    size_t n = stdin_len - stdin_pos;
    if (n > count) {
        n = count;
    }
    memcpy(buf, stdin_line + stdin_pos, n);
    stdin_pos += n;
    return (ssize_t)n;
}

/* DESCRIPTORS */

// The drive letter a path is on ("D:X" and
// "/D:/X" -> 'D', "X" -> the current drive)
static dev_t drive_of(const char *path) {
    if ((path[0] == '/' || path[0] == '\\') && path[1] != '\0' && path[2] == ':') {
        ++path;
    }
    if (path[0] != '\0' && path[1] == ':') {
        return (dev_t)(path[0] >= 'a' && path[0] <= 'z' ? path[0] - 'a' + 'A' : path[0]);
    }
    char cwd[PATH_MAX];
    return zdos->files->get_cwd != NULL && zdos->files->get_cwd(cwd, sizeof(cwd)) > 0 ? (dev_t)cwd[0] : 0;
}


#ifndef O_RDONLY
#define O_RDONLY 00000000
#define O_WRONLY 00000001
#define O_RDWR   00000002
#define O_CREAT  00000100
#define O_TRUNC  00001000
#define O_APPEND 00002000
#define O_ACCMODE 00000003
#endif

#ifndef SEEK_SET
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#endif

/* MEMORY DESCRIPTORS (fmemopen, open_memstream) */

// A free descriptor (3 and up), or -1 with EMFILE
static int free_fd(void) {
    for (int fd = 3; fd < MAX_ZDOS_FILES; fd++) {
        if (!zdos_file_used[fd]) {
            return fd;
        }
    }
    errno = EMFILE;
    return -1;
}

// open_memstream: *out and *out_size show the text so far (with a 0 after it)
static void mem_publish(struct zdos_memfile *m) {
    if (m->grows) {
        *m->out = m->buf;
        *m->out_size = m->len;
    }
}

static ssize_t mem_read(int fd, void *buf, size_t count) {
    struct zdos_memfile *m = zdos_file_mem[fd];
    uint64_t pos = zdos_file_positions[fd];
    size_t n = pos >= m->len ? 0 : m->len - (size_t)pos;
    if (n > count) {
        n = count;
    }
    memcpy(buf, m->buf + pos, n);
    zdos_file_positions[fd] += n;
    return (ssize_t)n;
}

static ssize_t mem_write(int fd, const void *buf, size_t count) {
    struct zdos_memfile *m = zdos_file_mem[fd];
    size_t pos = zdos_file_append[fd] ? m->len : (size_t)zdos_file_positions[fd];
    size_t end = pos + count;
    if (m->grows && end + 1 > m->size) { /* room for the text and its 0 */
        size_t size = m->size * 2 > end + 1 ? m->size * 2 : end + 1;
        char *bigger = realloc(m->buf, size);
        if (bigger == NULL) {
            return fail(ENOMEM);
        }
        memset(bigger + m->size, 0, size - m->size);
        m->buf = bigger;
        m->size = size;
    }
    if (!m->grows && end > m->size) { /* fmemopen: what fits */
        count = pos < m->size ? m->size - pos : 0;
        end = pos + count;
        if (count == 0) {
            return fail(ENOSPC);
        }
    }
    if (pos > m->len) { /* after a seek past the end: zeros between */
        memset(m->buf + m->len, 0, pos - m->len);
    }
    memcpy(m->buf + pos, buf, count);
    if (end > m->len) {
        m->len = end;
        if (m->len < m->size) {
            m->buf[m->len] = '\0';
        }
    }
    zdos_file_positions[fd] = end;
    mem_publish(m);
    return (ssize_t)count;
}

static off_t mem_seek(int fd, off_t offset, int whence) {
    struct zdos_memfile *m = zdos_file_mem[fd];
    int64_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? (int64_t)zdos_file_positions[fd] :
                   whence == SEEK_END ? (int64_t)m->len : -1;
    if (base < 0 || base + offset < 0 || (!m->grows && (uint64_t)(base + offset) > m->size)) {
        return fail(EINVAL);
    }
    zdos_file_positions[fd] = (uint64_t)(base + offset);
    return (off_t)(base + offset);
}

static void mem_close(int fd) {
    struct zdos_memfile *m = zdos_file_mem[fd];
    mem_publish(m);
    if (m->own_buf) {
        free(m->buf);
    }
    free(m);
    zdos_file_mem[fd] = NULL;
    zdos_file_used[fd] = false;
    zdos_file_positions[fd] = 0;
    zdos_file_append[fd] = false;
    zdos_file_readable[fd] = false;
    zdos_file_writable[fd] = false;
}

// A descriptor over m, or -1 (m is freed then)
static int mem_fd(struct zdos_memfile *m, bool readable, bool writable, bool append, uint64_t pos) {
    int fd = free_fd();
    if (fd < 0) {
        if (m->own_buf || m->grows) {
            free(m->buf);
        }
        free(m);
        return -1;
    }
    zdos_file_used[fd] = true;
    zdos_file_handles[fd] = -1;
    zdos_file_positions[fd] = pos;
    zdos_file_append[fd] = append;
    zdos_file_readable[fd] = readable;
    zdos_file_writable[fd] = writable;
    zdos_file_drive[fd] = 0;
    zdos_file_mem[fd] = m;
    return fd;
}

// A descriptor for handle (closed again if none is free)
static int fd_for_handle(int32_t handle, bool readable, bool writable, int min_fd) {
    for (int i = min_fd < 3 ? 3 : min_fd; i < MAX_ZDOS_FILES; i++) {
        if (!zdos_file_used[i]) {
            zdos_file_used[i] = true;
            zdos_file_handles[i] = handle;
            zdos_file_positions[i] = 0;
            zdos_file_append[i] = false;
            zdos_file_readable[i] = readable;
            zdos_file_writable[i] = writable;
            zdos_file_drive[i] = 0;
            zdos_file_mem[i] = NULL;
            zdos_file_alias[i] = 0;
            zdos_file_nonblock[i] = false;
            zdos_file_tty[i] = false;
            zdos_file_socket[i] = false;
            return i;
        }
    }
    zdos->files->close(handle);
    return fail(EMFILE);
}

int zdos_fd_for_socket(int32_t handle) {
    int fd = fd_for_handle(handle, true, true, 3);
    if (fd >= 0) {
        zdos_file_socket[fd] = true;
    }
    return fd;
}

int zdos_fd_for_handle(int32_t handle) {
    return fd_for_handle(handle, true, true, 3);
}

int32_t zdos_fd_socket(int fd) {
    fd = resolve_fd(fd);
    if (!valid_fd(fd)) {
        return fail(EBADF);
    }
    if (!zdos_file_socket[fd]) {
        return fail(ENOTSOCK);
    }
    return zdos_file_handles[fd];
}

static int open_file(const char *pathname, int flags);

int open(const char *pathname, int flags, ...) {
    int fd = open_file(pathname, flags);
    if (fd >= 0 && zdos_vfork_child != NULL) {
        zdos_vfork_child->opened[fd] = true;
    }
    return fd;
}

static int open_file(const char *pathname, int flags) {
    if (zdos == NULL || zdos->files->open == NULL) {
        return fail(ENODEV);
    }
    size_t len = zdos_strlen(pathname);
    bool want_write = (flags & O_ACCMODE) != O_RDONLY;

    // What is there decides the mode: ZDOS's write mode always creates and its
    // update mode creates a missing file, which POSIX does only with O_CREAT
    zdos_dir_entry entry;
    zdos_open_mode mode;
    if (zdos->files->stat(pathname, len, &entry)) {
        if ((flags & O_CREAT) && (flags & O_EXCL)) {
            return fail(EEXIST);
        }
        if (entry.is_dir) {
            return fail(EISDIR);
        }
        mode = !want_write ? ZDOS_READ : (flags & O_TRUNC) ? ZDOS_WRITE : ZDOS_UPDATE;
    } else {
        uint32_t code = last_code();
        if (!(flags & O_CREAT) || (code != ZDOS_ERROR_NOT_FOUND && code != ZDOS_ERROR_NONE)) {
            return fail_last(); /* missing without O_CREAT, or the folder / disk failed */
        }
        mode = ZDOS_UPDATE; /* creates it */
    }

    int32_t handle = zdos->files->open(pathname, len, mode);
    if (handle < 0) {
        return fail_last();
    }

    // Slots 0, 1, 2 are reserved for stdin/stdout/stderr
    for (int i = 3; i < MAX_ZDOS_FILES; i++) {
        if (!zdos_file_used[i]) {
            zdos_file_used[i] = true;
            zdos_file_handles[i] = handle;
            zdos_file_positions[i] = 0;
            zdos_file_append[i] = (flags & O_APPEND) != 0;
            zdos_file_readable[i] = (flags & O_ACCMODE) != O_WRONLY;
            zdos_file_writable[i] = want_write;
            zdos_file_drive[i] = (char)drive_of(pathname);
            zdos_file_mem[i] = NULL;
            zdos_file_alias[i] = 0;
            zdos_file_nonblock[i] = false;
            zdos_file_tty[i] = strcmp(pathname, "/dev/tty") == 0;
            if (zdos_file_append[i]) {
                int64_t end = zdos->files->size(handle);
                if (end < 0 || !zdos->files->seek(handle, (uint64_t)end)) {
                    int e = zdos_errno_from_last_error(); /* before close changes it */
                    zdos->files->close(handle);
                    zdos_file_used[i] = false;
                    return fail(e);
                }
                zdos_file_positions[i] = (uint64_t)end;
            }
            return i;
        }
    }
    zdos->files->close(handle);
    return fail(EMFILE);
}

int creat(const char *pathname, mode_t mode) {
    (void)mode;
    return open(pathname, O_WRONLY | O_CREAT | O_TRUNC);
}

ssize_t read(int fd, void *buf, size_t count) {
    fd = resolve_fd(fd);
    if (fd == STDIN_FILENO && zdos != NULL) {
        return read_stdin(buf, count);
    }
    if (!valid_fd(fd) || !zdos_file_readable[fd]) {
        return fail(EBADF);
    }
    if (zdos_file_mem[fd] != NULL) {
        return mem_read(fd, buf, count);
    }
    if (zdos_file_nonblock[fd] && zdos->files->poll != NULL) {
        zdos_poll_fd p = {zdos_file_handles[fd], ZDOS_POLLIN, 0};
        if (zdos->files->poll(&p, 1, 0) == 0) {
            return fail(EAGAIN);
        }
    }
    int64_t n = zdos->files->read(zdos_file_handles[fd], buf, count);
    if (n < 0) {
        return fail_last();
    }
    zdos_file_positions[fd] += (uint64_t)n;
    return (ssize_t)n;
}

ssize_t write(int fd, const void *buf, size_t count) {
    fd = resolve_fd(fd);
    if (fd == STDERR_FILENO && zdos != NULL && std_handle[2] >= 0) {
        int64_t n = zdos->files->write(std_handle[2], buf, count);
        return n < 0 ? fail_last() : (ssize_t)n;
    }
    if (fd == STDERR_FILENO && zdos != NULL && zdos->console->print_error != NULL) {
        zdos->console->print_error(buf, count); /* the error output: the screen unless redirected */
        note_output(buf, count);
        return (ssize_t)count;
    }
    if ((fd == STDOUT_FILENO || fd == STDERR_FILENO) && zdos != NULL) {
        zdos->console->print(buf, count);
        note_output(buf, count);
        return (ssize_t)count;
    }
    if (!valid_fd(fd) || !zdos_file_writable[fd]) {
        return fail(EBADF);
    }
    if (zdos_file_mem[fd] != NULL) {
        return mem_write(fd, buf, count);
    }
    if (zdos_file_append[fd]) {
        int64_t end = zdos->files->size(zdos_file_handles[fd]);
        if (end < 0 || !zdos->files->seek(zdos_file_handles[fd], (uint64_t)end)) {
            return fail_last();
        }
        zdos_file_positions[fd] = (uint64_t)end;
    }
    int64_t n = zdos->files->write(zdos_file_handles[fd], buf, count);
    if (n < 0) {
        return fail_last();
    }
    zdos_file_positions[fd] += (uint64_t)n;
    return (ssize_t)n;
}

off_t lseek(int fd, off_t offset, int whence) {
    if (is_std_fd(fd)) {
        return fail(ESPIPE);
    }
    if (!valid_fd(fd)) {
        return fail(EBADF);
    }
    if (zdos_file_mem[fd] != NULL) {
        return mem_seek(fd, offset, whence);
    }
    int32_t handle = zdos_file_handles[fd];

    int64_t target;
    if (whence == SEEK_SET) {
        target = offset;
    } else if (whence == SEEK_CUR) {
        target = (int64_t)zdos_file_positions[fd] + offset;
    } else if (whence == SEEK_END) {
        int64_t end = zdos->files->size(handle);
        if (end < 0) {
            return fail_last();
        }
        target = end + offset;
    } else {
        return fail(EINVAL);
    }
    if (target < 0) {
        return fail(EINVAL);
    }
    if (!zdos->files->seek(handle, (uint64_t)target)) {
        return fail_last();
    }
    zdos_file_positions[fd] = (uint64_t)target;
    return (off_t)target;
}

int ftruncate(int fd, off_t length) {
    if (length < 0) {
        return fail(EINVAL);
    }
    if (is_std_fd(fd)) {
        return fail(EINVAL); /* not a file */
    }
    if (!valid_fd(fd) || !zdos_file_writable[fd] || zdos_file_mem[fd] != NULL) {
        return fail(EBADF);
    }
    if (zdos->files->set_size == NULL) {
        return fail(ENOSYS); /* an older zdos */
    }
    if (!zdos->files->set_size(zdos_file_handles[fd], (uint64_t)length)) {
        return fail_last();
    }
    return 0;
}

int fsync(int fd) {
    if (is_std_fd(fd)) {
        return 0;
    }
    if (!valid_fd(fd)) {
        return fail(EBADF);
    }
    if (zdos_file_mem[fd] != NULL) {
        return 0;
    }
    if (zdos->files->commit == NULL) {
        return fail(ENOSYS); /* an older zdos */
    }
    if (!zdos->files->commit(zdos_file_handles[fd])) {
        return fail_last();
    }
    return 0;
}

int truncate(const char *path, off_t length) {
    int fd = open(path, O_WRONLY);
    if (fd < 0) {
        return -1;
    }
    int result = ftruncate(fd, length);
    int e = errno;
    if (close(fd) != 0 && result == 0) {
        return -1;
    }
    errno = e;
    return result;
}

// The descriptor is released even when closing fails; -1 then says that the
// file's size and date could not be written (as POSIX close reports EIO).
// Closing 0, 1 or 2 does nothing.
int close(int fd) {
    if (zdos_vfork_child != NULL) {
        // A vfork child's: the parent's descriptors stay
        if (is_std_fd(fd)) {
            zdos_vfork_child->std[fd] = ZDOS_NUL_STREAM;
            return 0;
        }
        if (valid_fd(fd) && !zdos_vfork_child->opened[fd]) {
            zdos_vfork_child->closed[fd] = true;
            return 0;
        }
    }
    if (is_std_fd(fd)) {
        // Moved by dup2: back to what the program started with
        if (zdos != NULL && std_handle[fd] >= 0) {
            zdos->system->redirect((uint32_t)fd, -1);
            zdos->files->close(std_handle[fd]);
            std_handle[fd] = -1;
        }
        return 0;
    }
    if (!valid_fd(fd)) {
        return fail(EBADF);
    }
    if (zdos_close_hook != NULL) {
        zdos_close_hook(fd);
    }
    if (zdos_file_alias[fd] != 0) {
        zdos_file_used[fd] = false;
        zdos_file_alias[fd] = 0;
        return 0;
    }
    if (zdos_file_mem[fd] != NULL) {
        mem_close(fd);
        return 0;
    }
    zdos->files->close(zdos_file_handles[fd]);
    uint32_t code = last_code();
    zdos_file_used[fd] = false;
    zdos_file_positions[fd] = 0;
    zdos_file_append[fd] = false;
    zdos_file_readable[fd] = false;
    zdos_file_writable[fd] = false;
    if (code != ZDOS_ERROR_NONE) {
        return fail(zdos_errno_from_code(code));
    }
    return 0;
}

// The keyboard and screen are terminals; redirected streams and files are not
int isatty(int fd) {
    fd = resolve_fd(fd);
    if (is_std_fd(fd) && std_handle[fd] >= 0) {
        errno = ENOTTY;
        return 0;
    }
    if (zdos != NULL && fd == STDIN_FILENO) {
        return zdos->console->input_redirected == NULL || !zdos->console->input_redirected();
    }
    if (valid_fd(fd) && zdos_file_tty[fd]) {
        return 1;
    }
    if (zdos != NULL && fd == STDERR_FILENO && zdos->console->error_redirected != NULL) {
        return !zdos->console->error_redirected();
    }
    if (zdos != NULL && (fd == STDOUT_FILENO || fd == STDERR_FILENO)) {
        return zdos->console->output_redirected == NULL || !zdos->console->output_redirected();
    }
    errno = valid_fd(fd) ? ENOTTY : EBADF;
    return 0;
}

/* FILE INFORMATION */

// A drive's block size (st_blksize, statvfs), asked once per drive: 512 if
// unknown
static uint32_t block_sizes[26];

static uint32_t block_size_of(zdos_drive_info *info) {
    return info->block_size != 0 ? info->block_size : 512;
}

static uint32_t drive_block_size(uint32_t letter) {
    if (letter >= 'a' && letter <= 'z') {
        letter -= 'a' - 'A';
    }
    if (letter < 'A' || letter > 'Z' || zdos->drives->info == NULL) {
        return 512;
    }
    uint32_t *known = &block_sizes[letter - 'A'];
    if (*known == 0) {
        zdos_drive_info info;
        *known = zdos->drives->info((uint8_t)letter, &info) ? block_size_of(&info) : 512;
    }
    return *known;
}

// st_ctime is the last status change where the file system keeps it (ext2),
// else the creation time, as on DOS and Windows; unknown times are the
// modification time
static void stat_from(const zdos_stat_ex *x, struct stat *st) {
    memset(st, 0, sizeof(*st));
    st->st_dev = x->drive;
    st->st_ino = x->ino;
    st->st_mode = (mode_t)x->mode; /* made up from read-only on FAT */
    st->st_nlink = x->links;
    st->st_uid = x->uid;
    st->st_gid = x->gid;
    st->st_size = (off_t)x->file_size;
    st->st_blksize = (blksize_t)drive_block_size(x->drive);
    st->st_blocks = (blkcnt_t)x->blocks; /* 512-byte units, as POSIX has them */
    if (x->modified.year != 0) {
        st->st_mtime = zdos_epoch_from_time(&x->modified);
    }
    st->st_atime = x->accessed.year != 0 ? zdos_epoch_from_time(&x->accessed) : st->st_mtime;
    const zdos_time *c = x->changed.year != 0 ? &x->changed : &x->created;
    st->st_ctime = c->year != 0 ? zdos_epoch_from_time(c) : st->st_mtime;
}

int stat(const char *path, struct stat *st) {
    zdos_stat_ex x = {.size = sizeof(x)};
    if (zdos == NULL || !zdos->files->stat_ex(path, zdos_strlen(path), &x)) {
        return zdos == NULL ? fail(ENODEV) : fail_last();
    }
    stat_from(&x, st);
    return 0;
}

int fstat(int fd, struct stat *st) {
    memset(st, 0, sizeof(*st));
    st->st_nlink = 1;
    fd = resolve_fd(fd);
    if (is_std_fd(fd) && std_handle[fd] >= 0) {
        zdos_stat_ex x = {.size = sizeof(x)};
        if (!zdos->files->fstat_ex(std_handle[fd], &x)) {
            return fail_last();
        }
        stat_from(&x, st);
        return 0;
    }
    if (is_std_fd(fd)) {
        st->st_mode = (isatty(fd) ? S_IFCHR : S_IFIFO) | 0666;
        return 0;
    }
    if (!valid_fd(fd)) {
        return fail(EBADF);
    }
    if (zdos_file_mem[fd] != NULL) {
        st->st_mode = S_IFREG | 0644;
        st->st_size = (off_t)zdos_file_mem[fd]->len;
        return 0;
    }
    zdos_stat_ex x = {.size = sizeof(x)};
    if (!zdos->files->fstat_ex(zdos_file_handles[fd], &x)) {
        return fail_last();
    }
    stat_from(&x, st);
    return 0;
}

/* FILE SYSTEM STATISTICS */

static int drive_statvfs(dev_t letter, struct statvfs *sv) {
    zdos_drive_info info;
    if (letter == 0 || zdos->drives->info == NULL) {
        return fail(ENODEV);
    }
    if (!zdos->drives->info((uint8_t)letter, &info)) {
        return fail_last();
    }
    memset(sv, 0, sizeof(*sv));
    uint32_t bs = block_size_of(&info);
    sv->f_bsize = bs;
    sv->f_frsize = bs;
    sv->f_blocks = info.size / bs;
    sv->f_bfree = info.free / bs;
    sv->f_bavail = sv->f_bfree;
    sv->f_fsid = info.has_serial ? info.serial : (unsigned long)letter;
    sv->f_namemax = NAME_MAX;
    return 0;
}

int statvfs(const char *path, struct statvfs *sv) {
    zdos_dir_entry e;
    if (zdos == NULL) {
        return fail(ENODEV);
    }
    if (!zdos->files->stat(path, zdos_strlen(path), &e)) {
        return fail_last(); /* the path must exist */
    }
    return drive_statvfs(drive_of(path), sv);
}

/* statvfs as Linux's statfs (sys/statfs.h), f_type Linux's magic number */
static int statfs_from(dev_t letter, int r, const struct statvfs *sv, struct statfs *buf) {
    if (r != 0) {
        return r;
    }
    memset(buf, 0, sizeof(*buf));
    zdos_drive_info info;
    if (zdos->drives->info != NULL && zdos->drives->info((uint8_t)letter, &info)) {
        switch (info.file_system) {
            case ZDOS_FS_FAT12: case ZDOS_FS_FAT16: case ZDOS_FS_FAT32: buf->f_type = 0x4d44; break;
            case ZDOS_FS_MINIX3: buf->f_type = 0x4d5a; break;
            case ZDOS_FS_EXT2: case ZDOS_FS_EXT3: case ZDOS_FS_EXT4: buf->f_type = 0xef53; break;
            case ZDOS_FS_ZFS: buf->f_type = 0x2fc12fc1; break;
            case ZDOS_FS_NTFS: buf->f_type = 0x5346544e; break;
            case ZDOS_FS_EXFAT: buf->f_type = 0x2011bab0; break;
        }
    }
    buf->f_bsize = sv->f_bsize;
    buf->f_frsize = sv->f_frsize;
    buf->f_blocks = sv->f_blocks;
    buf->f_bfree = sv->f_bfree;
    buf->f_bavail = sv->f_bavail;
    buf->f_files = sv->f_files;
    buf->f_ffree = sv->f_ffree;
    buf->f_fsid.__val[0] = (int)sv->f_fsid;
    buf->f_namelen = sv->f_namemax;
    return 0;
}

int statfs(const char *path, struct statfs *buf) {
    struct statvfs sv;
    int r = statvfs(path, &sv);
    return statfs_from(drive_of(path), r, &sv, buf);
}

int fstatfs(int fd, struct statfs *buf) {
    struct statvfs sv;
    int r = fstatvfs(fd, &sv);
    dev_t letter = is_std_fd(fd) || !valid_fd(fd) ? drive_of("") : (dev_t)zdos_file_drive[fd];
    return statfs_from(letter, r, &sv, buf);
}

int fstatvfs(int fd, struct statvfs *sv) {
    if (zdos == NULL) {
        return fail(ENODEV);
    }
    if (is_std_fd(fd)) {
        return drive_statvfs(drive_of(""), sv);
    }
    if (!valid_fd(fd)) {
        return fail(EBADF);
    }
    return drive_statvfs((dev_t)zdos_file_drive[fd], sv);
}

// "DIR/" is "DIR", as POSIX allows
int mkdir(const char *path, mode_t mode) {
    (void)mode;
    size_t len = zdos_strlen(path);
    while (len > 1 && (path[len - 1] == '/' || path[len - 1] == '\\') && path[len - 2] != ':') {
        --len;
    }
    if (zdos == NULL || !zdos->files->make_dir(path, len)) {
        return zdos == NULL ? fail(ENODEV) : fail_last();
    }
    return 0;
}

// Unix permissions where the file system has them (ext2); on FAT only the
// write bits count: none makes the file read-only
int chmod(const char *path, mode_t mode) {
    if (zdos == NULL) return fail(ENODEV);
    if (!zdos->files->set_mode(path, zdos_strlen(path), (uint32_t)(mode & 07777))) {
        return fail_last();
    }
    return 0;
}

int fchmod(int fd, mode_t mode) {
    (void)mode;
    struct stat st;
    return fstat(fd, &st);
}

long pathconf(const char *path, int name) {
    (void)path;
    switch (name) {
        case _PC_LINK_MAX: return 1;
        case _PC_MAX_CANON:
        case _PC_MAX_INPUT: return 255;
        case _PC_NAME_MAX: return NAME_MAX;
        case _PC_PATH_MAX: return PATH_MAX;
        case _PC_PIPE_BUF: return 4096;
        default: return fail(EINVAL);
    }
}

long fpathconf(int fd, int name) {
    (void)fd;
    return pathconf(NULL, name);
}

// (uid_t)-1 or (gid_t)-1 leaves one as it is; FAT has no owners (EOPNOTSUPP)
int chown(const char *path, uid_t owner, gid_t group) {
    if (zdos == NULL) return fail(ENODEV);
    if (!zdos->files->set_owner(path, zdos_strlen(path), owner, group)) {
        return fail_last();
    }
    return 0;
}

int access(const char *path, int mode) {
    zdos_dir_entry e;
    if (zdos == NULL || !zdos->files->stat(path, zdos_strlen(path), &e)) {
        return zdos == NULL ? fail(ENODEV) : fail_last();
    }
    if ((mode & W_OK) && (e.attrs & ZDOS_ATTR_READ_ONLY)) {
        return fail(EACCES);
    }
    return 0;
}

/* DIRECTORIES */

struct zdos_dir {
    int32_t handle;
    char *path; /* for rewinddir */
    struct dirent entry;
};

void (*zdos_close_hook)(int fd);
void (*zdos_closedir_hook)(DIR *dir);

const char *zdos_dir_path(DIR *dir) {
    return dir->path;
}

DIR *opendir(const char *path) {
    if (zdos == NULL) {
        errno = ENODEV;
        return NULL;
    }
    int32_t handle = zdos->files->open_dir(path, zdos_strlen(path));
    if (handle < 0) {
        errno = zdos_errno_from_last_error();
        return NULL;
    }
    DIR *d = malloc(sizeof(*d));
    char *copy = strdup(path);
    if (d == NULL || copy == NULL) {
        zdos->files->close(handle);
        free(d);
        free(copy);
        errno = ENOMEM;
        return NULL;
    }
    d->handle = handle;
    d->path = copy;
    return d;
}

struct dirent *readdir(DIR *d) {
    zdos_stat_ex x = {.size = sizeof(x)};
    if (d->handle < 0) {
        errno = EBADF;
        return NULL;
    }
    size_t n = zdos->files->read_dir_ex(d->handle, &x, d->entry.d_name, sizeof(d->entry.d_name) - 1);
    if (n == 0) {
        uint32_t code = last_code();
        if (code != ZDOS_ERROR_NONE) {
            errno = zdos_errno_from_code(code); /* else the end: errno unchanged */
        }
        return NULL;
    }
    d->entry.d_name[n] = '\0';
    d->entry.d_type = x.is_dir ? DT_DIR : DT_REG;
    d->entry.d_ino = (ino_t)x.ino;
    return &d->entry;
}

void rewinddir(DIR *d) {
    if (d->handle >= 0) {
        zdos->files->close(d->handle);
    }
    d->handle = zdos->files->open_dir(d->path, zdos_strlen(d->path));
}

int closedir(DIR *d) {
    if (d == NULL) {
        return fail(EBADF);
    }
    if (zdos_closedir_hook != NULL) {
        zdos_closedir_hook(d);
    }
    if (d->handle >= 0) {
        zdos->files->close(d->handle);
    }
    free(d->path);
    free(d);
    return 0;
}

char *getcwd(char *buf, size_t size) {
    bool allocated = false;
    if (buf == NULL) {
        size = size != 0 ? size : PATH_MAX;
        buf = malloc(size);
        if (buf == NULL) {
            errno = ENOMEM;
            return NULL;
        }
        allocated = true;
    }
    size_t n = size > 1 && zdos != NULL ? zdos->files->get_cwd(buf, size - 1) : 0;
    if (n == 0) {
        if (allocated) {
            free(buf);
        }
        errno = ERANGE;
        return NULL;
    }
    buf[n] = '\0';
    return buf;
}

int chdir(const char *path) {
    if (zdos == NULL || !zdos->files->set_cwd(path, zdos_strlen(path))) {
        return zdos == NULL ? fail(ENODEV) : fail_last();
    }
    return 0;
}

// The API deletes folders only with everything in them: check first that
// this one is empty, as rmdir must not delete more
int rmdir(const char *path) {
    if (zdos == NULL) {
        return fail(ENODEV);
    }
    size_t len = zdos_strlen(path);
    int32_t handle = zdos->files->open_dir(path, len);
    if (handle < 0) {
        return fail_last();
    }
    zdos_dir_entry e;
    bool empty = true;
    while (zdos->files->read_dir(handle, &e)) {
        if (!((e.name_len == 1 && e.name[0] == '.') || (e.name_len == 2 && e.name[0] == '.' && e.name[1] == '.'))) {
            empty = false;
            break;
        }
    }
    uint32_t code = empty ? last_code() : ZDOS_ERROR_NONE;
    zdos->files->close(handle);
    if (code != ZDOS_ERROR_NONE) {
        return fail(zdos_errno_from_code(code));
    }
    if (!empty) {
        return fail(ENOTEMPTY);
    }
    if (!zdos->files->delete_tree(path, len)) {
        return fail_last();
    }
    return 0;
}

int unlink(const char *path) {
    if (zdos == NULL || !zdos->files->delete_file(path, zdos_strlen(path))) {
        return zdos == NULL ? fail(ENODEV) : fail_last();
    }
    return 0;
}

int remove(const char *path) {
    if (zdos == NULL) {
        return fail(ENODEV);
    }
    if (zdos->files->delete_file(path, zdos_strlen(path))) {
        return 0;
    }
    if (last_code() == ZDOS_ERROR_IS_A_DIRECTORY) {
        return rmdir(path);
    }
    return fail_last();
}

// An existing file at to is replaced, as POSIX asks (ZDOS's move refuses it):
// deleted first, so not in one step
int rename(const char *from, const char *to) {
    if (zdos == NULL) {
        return fail(ENODEV);
    }
    size_t from_len = zdos_strlen(from);
    size_t to_len = zdos_strlen(to);
    if (zdos->files->move(from, from_len, to, to_len)) {
        return 0;
    }
    if (last_code() != ZDOS_ERROR_ALREADY_EXISTS) {
        return fail_last();
    }
    zdos_dir_entry src, dst;
    if (!zdos->files->stat(from, from_len, &src) || !zdos->files->stat(to, to_len, &dst)) {
        return fail_last();
    }
    if (dst.is_dir) {
        return fail(src.is_dir ? EEXIST : EISDIR);
    }
    if (src.is_dir) {
        return fail(ENOTDIR);
    }
    if (!zdos->files->delete_file(to, to_len) || !zdos->files->move(from, from_len, to, to_len)) {
        return fail_last();
    }
    return 0;
}

char *realpath(const char *path, char *resolved) {
    if (zdos == NULL || zdos->files->full_path == NULL) {
        errno = ENOSYS;
        return NULL;
    }
    zdos_dir_entry e;
    size_t len = zdos_strlen(path);
    if (!zdos->files->stat(path, len, &e)) { /* realpath wants something that exists */
        errno = zdos_errno_from_last_error();
        return NULL;
    }
    char *out = resolved != NULL ? resolved : malloc(PATH_MAX);
    if (out == NULL) {
        errno = ENOMEM;
        return NULL;
    }
    size_t n = zdos->files->full_path(path, len, out, PATH_MAX - 1);
    if (n == 0) {
        errno = zdos_errno_from_last_error();
        if (resolved == NULL) {
            free(out);
        }
        return NULL;
    }
    out[n] = '\0';
    return out;
}

/* Process IDs are task numbers (the first task is 1) */
pid_t getpid(void) {
    return zdos != NULL && zdos->tasks->id != NULL ? (pid_t)zdos->tasks->id() : 1;
}

pid_t getppid(void) {
    return zdos != NULL && zdos->tasks->parent != NULL ? (pid_t)zdos->tasks->parent() : 0;
}

/* PIPES, DUP, FCNTL */

int pipe(int fds[2]) {
    int32_t h[2];
    if (zdos == NULL || !zdos->files->pipe(h)) {
        return zdos == NULL ? fail(ENOSYS) : fail_last();
    }
    int r = fd_for_handle(h[0], true, false, 3);
    if (r < 0) {
        zdos->files->close(h[1]);
        return -1;
    }
    int w = fd_for_handle(h[1], false, true, 3);
    if (w < 0) {
        close(r);
        return -1;
    }
    fds[0] = r;
    fds[1] = w;
    return 0;
}

// fd's handle as dup2 needs it: a new handle for the same object (-1: the
// standard stream as the program started with it), or -2 with errno
static int32_t dup_handle(int fd) {
    fd = resolve_fd(fd);
    if (is_std_fd(fd)) {
        int32_t h = std_handle[fd];
        if (h < 0) {
            return -1;
        }
        int32_t d = zdos->files->dup(h);
        return d < 0 ? (fail_last(), -2) : d;
    }
    if (!valid_fd(fd) || zdos_file_mem[fd] != NULL) {
        return (fail(EBADF), -2);
    }
    int32_t d = zdos->files->dup(zdos_file_handles[fd]);
    return d < 0 ? (fail_last(), -2) : d;
}

// Moves standard stream std to handle h, or to a stream code (-1:
// back to the start; ZDOS_CALLER_OUTPUT / _ERROR: where 1 / 2 go now)
static void set_std(int std, int32_t h) {
    if (std_handle[std] >= 0) {
        zdos->files->close(std_handle[std]);
    }
    std_handle[std] = h >= 0 ? h : -1;
    zdos->system->redirect((uint32_t)std, h);
}

static int dup_at_least(int fd, int min_fd) {
    if (zdos == NULL) {
        return fail(ENOSYS);
    }
    int src = resolve_fd(fd);
    if (is_std_fd(src) && std_handle[src] < 0) {
        // The keyboard or screen: a descriptor standing for the stream
        for (int i = min_fd < 3 ? 3 : min_fd; i < MAX_ZDOS_FILES; i++) {
            if (!zdos_file_used[i]) {
                zdos_file_used[i] = true;
                zdos_file_alias[i] = (uint8_t)(src + 1);
                zdos_file_mem[i] = NULL;
                return i;
            }
        }
        return fail(EMFILE);
    }
    int32_t h = dup_handle(fd);
    if (h < 0) {
        return -1;
    }
    bool readable = is_std_fd(src) ? src == 0 : zdos_file_readable[src];
    bool writable = is_std_fd(src) ? src != 0 : zdos_file_writable[src];
    int n = fd_for_handle(h, readable, writable, min_fd);
    if (n >= 0 && !is_std_fd(src)) {
        zdos_file_positions[n] = zdos_file_positions[src];
        zdos_file_append[n] = zdos_file_append[src];
        zdos_file_drive[n] = zdos_file_drive[src];
        zdos_file_socket[n] = zdos_file_socket[src];
        zdos_file_nonblock[n] = zdos_file_nonblock[src];
    }
    return n;
}

int dup(int fd) {
    return dup_at_least(fd, 3);
}

int dup2(int fd, int new_fd) {
    if (new_fd < 0 || new_fd >= MAX_ZDOS_FILES) {
        return fail(EBADF);
    }
    if (zdos_vfork_child != NULL) {
        // A vfork child's: only what it starts gets them
        if (is_std_fd(new_fd)) {
            int32_t h = zdos_fd_spawn_handle(fd);
            if (h == -100) {
                return fail(EBADF);
            }
            zdos_vfork_child->std[new_fd] = h;
        }
        return new_fd;
    }
    // A dup of a standard stream made while it wasn't moved stands for it as
    // the program started with it: dup2 of it moves the stream back
    bool original = valid_fd(fd) && zdos_file_alias[fd] != 0;
    if (!original && resolve_fd(fd) == resolve_fd(new_fd) && (is_std_fd(fd) || valid_fd(fd))) {
        return new_fd;
    }
    if (is_std_fd(new_fd) && original) {
        set_std(new_fd, -1);
        return new_fd;
    }
    if (is_std_fd(new_fd)) {
        int src = resolve_fd(fd);
        if ((src == 1 || src == 2) && std_handle[src] < 0) {
            // 2>&1, 1>&2: wherever that stream goes
            // now (perhaps a pipe from the parent)
            set_std(new_fd, src == 1 ? ZDOS_CALLER_OUTPUT : ZDOS_CALLER_ERROR);
            return new_fd;
        }
        int32_t h = dup_handle(fd);
        if (h == -2) {
            return -1;
        }
        set_std(new_fd, h);
        return new_fd;
    }
    if (zdos_file_used[new_fd]) {
        close(new_fd);
    }
    int n = dup_at_least(fd, new_fd);
    if (n >= 0 && n != new_fd) {
        close(n); /* new_fd was taken meanwhile: can't be */
        return fail(EBADF);
    }
    return n;
}

int fcntl(int fd, int cmd, ...) {
    va_list ap;
    va_start(ap, cmd);
    long arg = va_arg(ap, long);
    va_end(ap);
    int r = resolve_fd(fd);
    if (!is_std_fd(r) && !valid_fd(r)) {
        return fail(EBADF);
    }
    switch (cmd) {
        case F_DUPFD:
        case F_DUPFD_CLOEXEC:
            return dup_at_least(fd, (int)arg);
        case F_GETFD:
        case F_SETFD:
            return 0; /* no exec that keeps descriptors: FD_CLOEXEC changes nothing */
        case F_GETFL: {
            if (is_std_fd(r)) {
                return r == 0 ? O_RDONLY : O_WRONLY;
            }
            int fl = zdos_file_readable[r] && zdos_file_writable[r] ? O_RDWR : zdos_file_writable[r] ? O_WRONLY : O_RDONLY;
            if (zdos_file_append[r]) {
                fl |= O_APPEND;
            }
            if (zdos_file_nonblock[r]) {
                fl |= O_NONBLOCK;
            }
            return fl;
        }
        case F_SETFL:
            if (!is_std_fd(r)) {
                zdos_file_append[r] = (arg & O_APPEND) != 0;
                zdos_file_nonblock[r] = (arg & O_NONBLOCK) != 0;
                if (zdos_file_socket[r]) {
                    /* The kernel's too: connect and accept don't wait then */
                    zdos->net->set_option(zdos_file_handles[r], ZDOS_SO_NONBLOCKING, (arg & O_NONBLOCK) != 0);
                }
            }
            return 0;
        default:
            return fail(EINVAL);
    }
}

int32_t zdos_fd_spawn_handle(int fd) {
    if (zdos_vfork_child != NULL && is_std_fd(fd)) {
        return zdos_vfork_child->std[fd];
    }
    fd = resolve_fd(fd);
    if (is_std_fd(fd)) {
        // ZDOS's streams already follow dup2 onto 0, 1, 2: as they are now
        return fd == 0 ? ZDOS_SAME_STREAM : fd == 1 ? ZDOS_CALLER_OUTPUT : ZDOS_CALLER_ERROR;
    }
    if (!valid_fd(fd) || zdos_file_mem[fd] != NULL) {
        return -100;
    }
    return zdos_file_handles[fd];
}

/* For poll (zdos_posix.c): what ZDOS polls for descriptor fd: a handle,
   ZDOS_POLL_STDIN, -3 for one that is always ready (the screen, memory
   streams, files), -100 for a bad one */
int32_t zdos_fd_poll_handle(int fd) {
    fd = resolve_fd(fd);
    if (fd == 0) {
        return std_handle[0] >= 0 ? std_handle[0] : ZDOS_POLL_STDIN;
    }
    if (fd == 1 || fd == 2) {
        return std_handle[fd] >= 0 ? std_handle[fd] : -3;
    }
    if (!valid_fd(fd)) {
        return -100;
    }
    return zdos_file_mem[fd] != NULL ? -3 : zdos_file_handles[fd];
}

/* STREAMS (FILE) A stream is a descriptor with a buffer. It is either
   reading (buf holds rpos..rlen not yet given out) or writing (buf holds
   wlen bytes not yet written); switching drops or writes the buffer first.
   stdout and stderr are unbuffered, so they keep their order with
   everything else printed. */

#define STREAM_READ 1
#define STREAM_WRITE 2
#define STREAM_EOF 4
#define STREAM_ERROR 8
#define STREAM_OWN_BUF 16 /* buf came from malloc */
#define STREAM_STATIC 32 /* stdin, stdout, stderr: not freed */

struct zdos_file {
    int fd;
    int flags;
    int buf_mode; /* _IOFBF, _IOLBF, _IONBF */
    unsigned char *buf;
    size_t buf_size;
    size_t rpos, rlen;
    size_t wlen;
    int ungot; /* the character ungetc gave back, -1: none */
    struct zdos_file *next; /* every open stream, for fflush(NULL) and exit */
    char *temp_name; /* tmpfile: the file, removed when the stream closes */
    zdos_rlock lock; /* flockfile's */
};

static FILE std_err = { 2, STREAM_WRITE | STREAM_STATIC, _IONBF, NULL, 0, 0, 0, 0, -1, NULL, NULL, {0, 0, 0} };
static FILE std_out = { 1, STREAM_WRITE | STREAM_STATIC, _IONBF, NULL, 0, 0, 0, 0, -1, &std_err, NULL, {0, 0, 0} };
static FILE std_in = { 0, STREAM_READ | STREAM_STATIC, _IOLBF, NULL, 0, 0, 0, 0, -1, &std_out, NULL, {0, 0, 0} };
static FILE *streams = &std_in;
static zdos_rlock streams_lock; /* the list */

/* LOCKING BETWEEN THREADS (zdos_rlock, zdos_libc.c) */

void flockfile(FILE *f) {
    zdos_rlock_take(&f->lock, false);
}

int ftrylockfile(FILE *f) {
    return zdos_rlock_take(&f->lock, true) ? 0 : -1;
}

void funlockfile(FILE *f) {
    zdos_rlock_give(&f->lock);
}

static FILE *freopen_unlocked(const char *path, const char *mode, FILE *f);
static long long ftello_unlocked(FILE *f);
static int fseeko_unlocked(FILE *f, long long offset, int whence);

static void streams_take(void) {
    zdos_rlock_take(&streams_lock, false);
}

static void streams_give(void) {
    zdos_rlock_give(&streams_lock);
}

FILE *stdin = &std_in;
FILE *stdout = &std_out;
FILE *stderr = &std_err;

// Gets the buffer when first needed; without memory the stream is unbuffered
static bool stream_buffer(FILE *f) {
    if (f->buf == NULL && f->buf_mode != _IONBF) {
        size_t size = f->buf_size != 0 ? f->buf_size : BUFSIZ;
        f->buf = malloc(size);
        if (f->buf == NULL) {
            f->buf_mode = _IONBF;
            f->buf_size = 0;
        } else {
            f->buf_size = size;
            f->flags |= STREAM_OWN_BUF;
        }
    }
    return f->buf != NULL;
}

static bool write_all(FILE *f, const unsigned char *p, size_t n) {
    while (n > 0) {
        ssize_t done = write(f->fd, p, n);
        if (done <= 0) {
            if (done == 0) {
                errno = ENOSPC;
            }
            f->flags |= STREAM_ERROR;
            return false;
        }
        p += done;
        n -= (size_t)done;
    }
    return true;
}

// Writes what is waiting in the buffer
static int stream_flush_write(FILE *f) {
    size_t n = f->wlen;
    f->wlen = 0;
    return n == 0 || write_all(f, f->buf, n) ? 0 : EOF;
}

// Drops what was read ahead, moving a file back to where the reader is
static void stream_drop_read(FILE *f) {
    off_t ahead = (off_t)(f->rlen - f->rpos) + (f->ungot >= 0 ? 1 : 0);
    if (ahead > 0 && f->fd > 2) {
        lseek(f->fd, -ahead, SEEK_CUR);
    }
    f->rpos = f->rlen = 0;
    f->ungot = -1;
}

// Makes a stream ready for writing; false (and errno) if it can't write
static bool stream_to_write(FILE *f) {
    if (!(f->flags & STREAM_WRITE)) {
        errno = EBADF;
        f->flags |= STREAM_ERROR;
        return false;
    }
    if (f->rpos < f->rlen || f->ungot >= 0) {
        stream_drop_read(f);
    }
    return true;
}

static bool stream_to_read(FILE *f) {
    if (!(f->flags & STREAM_READ)) {
        errno = EBADF;
        f->flags |= STREAM_ERROR;
        return false;
    }
    if (f->wlen > 0 && stream_flush_write(f) != 0) {
        return false;
    }
    return true;
}

// Reads into the buffer; false at the end or on an error (flags say which)
static bool stream_fill(FILE *f) {
    f->rpos = f->rlen = 0;
    if (!stream_buffer(f)) {
        return false;
    }
    ssize_t n = read(f->fd, f->buf, f->buf_size);
    if (n <= 0) {
        f->flags |= n == 0 ? STREAM_EOF : STREAM_ERROR;
        return false;
    }
    f->rlen = (size_t)n;
    return true;
}

// mode -> open flags and stream flags; -1 for a mode that isn't one
static int parse_mode(const char *mode, int *stream_flags) {
    int flags;
    switch (mode[0]) {
        case 'r': flags = O_RDONLY; *stream_flags = STREAM_READ; break;
        case 'w': flags = O_WRONLY | O_CREAT | O_TRUNC; *stream_flags = STREAM_WRITE; break;
        case 'a': flags = O_WRONLY | O_CREAT | O_APPEND; *stream_flags = STREAM_WRITE; break;
        default: return -1;
    }
    for (const char *m = mode + 1; *m != '\0'; ++m) {
        if (*m == '+') {
            flags = (flags & ~O_ACCMODE) | O_RDWR;
            *stream_flags = STREAM_READ | STREAM_WRITE;
        } else if (*m == 'x') {
            flags |= O_EXCL;
        }
    }
    return flags;
}

static FILE *new_stream(int fd, int stream_flags) {
    FILE *f = malloc(sizeof(*f));
    if (f == NULL) {
        errno = ENOMEM;
        return NULL;
    }
    memset(f, 0, sizeof(*f));
    f->fd = fd;
    f->flags = stream_flags;
    f->buf_mode = fd <= 2 && (stream_flags & STREAM_WRITE) ? _IONBF : _IOFBF;
    f->ungot = -1;
    streams_take();
    f->next = streams;
    streams = f;
    streams_give();
    return f;
}

FILE *fopen(const char *path, const char *mode) {
    int stream_flags;
    int flags = parse_mode(mode, &stream_flags);
    if (flags < 0) {
        errno = EINVAL;
        return NULL;
    }
    int fd = open(path, flags);
    if (fd < 0) {
        return NULL;
    }
    FILE *f = new_stream(fd, stream_flags);
    if (f == NULL) {
        close(fd);
    }
    return f;
}

FILE *fdopen(int fd, const char *mode) {
    int stream_flags;
    if (parse_mode(mode, &stream_flags) < 0) {
        errno = EINVAL;
        return NULL;
    }
    if (!is_std_fd(fd) && !valid_fd(fd)) {
        errno = EBADF;
        return NULL;
    }
    return new_stream(fd, stream_flags);
}

// A stream over a pipe of the program API (create_pipe). fclose closes the
// handle, which frees the pipe; on failure the handle is closed too.
FILE *zdos_pipe_stream(int32_t handle, const char *mode) {
    int stream_flags;
    if (parse_mode(mode, &stream_flags) < 0) {
        zdos->files->close(handle);
        errno = EINVAL;
        return NULL;
    }
    int fd = 3;
    while (fd < MAX_ZDOS_FILES && zdos_file_used[fd]) {
        fd++;
    }
    if (fd == MAX_ZDOS_FILES) {
        zdos->files->close(handle);
        errno = EMFILE;
        return NULL;
    }
    zdos_file_used[fd] = true;
    zdos_file_handles[fd] = handle;
    zdos_file_positions[fd] = 0;
    zdos_file_append[fd] = false;
    zdos_file_readable[fd] = (stream_flags & STREAM_READ) != 0;
    zdos_file_writable[fd] = (stream_flags & STREAM_WRITE) != 0;
    zdos_file_drive[fd] = 0;
    FILE *f = new_stream(fd, stream_flags);
    if (f == NULL) {
        zdos->files->close(handle);
        zdos_file_used[fd] = false;
    }
    return f;
}

// The program API handle under a stream, or -1 (not a file or pipe stream)
int32_t zdos_stream_handle(FILE *f) {
    if (f == NULL || !valid_fd(f->fd) || zdos_file_mem[f->fd] != NULL) {
        return -1;
    }
    return zdos_file_handles[f->fd];
}

// Closes the stream's file and opens path in its place, in the same FILE
// (freopen("OUT.TXT", "w", stdout) sends printf there)
FILE *freopen(const char *path, const char *mode, FILE *f) {
    flockfile(f);
    FILE *result = freopen_unlocked(path, mode, f);
    funlockfile(f);
    return result;
}

static FILE *freopen_unlocked(const char *path, const char *mode, FILE *f) {
    int stream_flags;
    int flags = parse_mode(mode, &stream_flags);
    fflush_unlocked(f);
    close(f->fd);
    if (f->temp_name != NULL) { /* a tmpfile is removed with its stream */
        remove(f->temp_name);
        free(f->temp_name);
        f->temp_name = NULL;
    }
    f->rpos = f->rlen = f->wlen = 0;
    f->ungot = -1;
    f->flags &= STREAM_OWN_BUF | STREAM_STATIC;
    f->fd = -1;
    if (path == NULL || flags < 0) { /* changing only the mode isn't supported */
        errno = EINVAL;
        return NULL;
    }
    int fd = open(path, flags);
    if (fd < 0) {
        return NULL;
    }
    f->fd = fd;
    f->flags |= stream_flags;
    f->buf_mode = _IOFBF;
    return f;
}

int fclose(FILE *f) {
    streams_take(); /* off the list first: fflush(NULL) takes the list, then streams */
    for (FILE **p = &streams; *p != NULL; p = &(*p)->next) {
        if (*p == f) {
            *p = f->next;
            break;
        }
    }
    streams_give();
    flockfile(f);
    int result = fflush_unlocked(f);
    if (f->fd >= 0 && close(f->fd) != 0) {
        result = EOF;
    }
    if (f->temp_name != NULL) { /* a tmpfile: the file goes with the stream */
        if (remove(f->temp_name) != 0) {
            result = EOF;
        }
        free(f->temp_name);
        f->temp_name = NULL;
    }
    if (f->flags & STREAM_OWN_BUF) {
        free(f->buf);
    }
    funlockfile(f);
    if (f->flags & STREAM_STATIC) {
        memset(f, 0, offsetof(FILE, lock)); /* other threads may still lock stdout */
        f->fd = -1;
        f->ungot = -1;
        f->flags = STREAM_STATIC;
    } else {
        free(f);
    }
    return result;
}

// Writes what waits; a reading file goes back to where the reader is
int fflush(FILE *f) {
    if (f == NULL) {
        int result = 0;
        streams_take();
        for (FILE *s = streams; s != NULL; s = s->next) {
            flockfile(s);
            if (fflush_unlocked(s) != 0) {
                result = EOF;
            }
            funlockfile(s);
        }
        streams_give();
        return result;
    }
    flockfile(f);
    int result = fflush_unlocked(f);
    funlockfile(f);
    return result;
}

int fflush_unlocked(FILE *f) {
    if (f == NULL) {
        return fflush(NULL);
    }
    if (f->wlen > 0) {
        return stream_flush_write(f);
    }
    if (f->fd > 2 && (f->rpos < f->rlen || f->ungot >= 0)) {
        stream_drop_read(f);
    }
    return 0;
}

static void mmap_sync_all(void);

// At exit: without locks, so a thread stuck holding one can't stop the end
void zdos_flush_streams(void) {
    for (FILE *s = streams; s != NULL; s = s->next) {
        fflush_unlocked(s);
    }
    mmap_sync_all();
}

int setvbuf(FILE *f, char *buf, int mode, size_t size) {
    if (mode != _IOFBF && mode != _IOLBF && mode != _IONBF) {
        return -1;
    }
    flockfile(f);
    fflush_unlocked(f);
    if (f->flags & STREAM_OWN_BUF) {
        free(f->buf);
        f->flags &= ~STREAM_OWN_BUF;
    }
    f->buf = mode != _IONBF ? (unsigned char *)buf : NULL;
    f->buf_size = mode != _IONBF ? size : 0;
    f->buf_mode = mode;
    funlockfile(f);
    return 0;
}

void setbuf(FILE *f, char *buf) {
    setvbuf(f, buf, buf != NULL ? _IOFBF : _IONBF, BUFSIZ);
}

int fileno(FILE *f) {
    if (f->fd < 0) {
        errno = EBADF;
    }
    return f->fd;
}

int fileno_unlocked(FILE *f) {
    return fileno(f);
}

size_t fread(void *ptr, size_t size, size_t count, FILE *f) {
    flockfile(f);
    size_t n = fread_unlocked(ptr, size, count, f);
    funlockfile(f);
    return n;
}

size_t fread_unlocked(void *ptr, size_t size, size_t count, FILE *f) {
    if (size == 0 || count == 0) {
        return 0;
    }
    if (count > SIZE_MAX / size) {
        errno = EINVAL;
        return 0;
    }
    if (!stream_to_read(f)) {
        return 0;
    }
    stream_buffer(f);
    unsigned char *p = ptr;
    size_t want = size * count;
    size_t got = 0;
    if (f->ungot >= 0) {
        p[got++] = (unsigned char)f->ungot;
        f->ungot = -1;
    }
    while (got < want) {
        if (f->rpos < f->rlen) {
            size_t n = f->rlen - f->rpos;
            if (n > want - got) {
                n = want - got;
            }
            memcpy(p + got, f->buf + f->rpos, n);
            f->rpos += n;
            got += n;
        } else if (f->flags & STREAM_EOF) {
            break;
        } else if (want - got >= f->buf_size || f->buf_mode == _IONBF) {
            // Large reads go straight to the caller's memory
            ssize_t n = read(f->fd, p + got, want - got);
            if (n <= 0) {
                f->flags |= n == 0 ? STREAM_EOF : STREAM_ERROR;
                break;
            }
            got += (size_t)n;
        } else if (!stream_fill(f)) {
            break;
        }
    }
    return got / size;
}

size_t fwrite(const void *ptr, size_t size, size_t count, FILE *f) {
    flockfile(f);
    size_t n = fwrite_unlocked(ptr, size, count, f);
    funlockfile(f);
    return n;
}

size_t fwrite_unlocked(const void *ptr, size_t size, size_t count, FILE *f) {
    if (size == 0 || count == 0) {
        return 0;
    }
    if (count > SIZE_MAX / size) {
        errno = EINVAL;
        return 0;
    }
    if (!stream_to_write(f)) {
        return 0;
    }
    const unsigned char *p = ptr;
    size_t n = size * count;
    if (!stream_buffer(f) || n >= f->buf_size) {
        if (stream_flush_write(f) != 0 || !write_all(f, p, n)) {
            return 0;
        }
        return count;
    }
    if (f->wlen + n > f->buf_size && stream_flush_write(f) != 0) {
        return 0;
    }
    memcpy(f->buf + f->wlen, p, n);
    f->wlen += n;
    if (f->wlen == f->buf_size || (f->buf_mode == _IOLBF && memchr(p, '\n', n) != NULL)) {
        if (stream_flush_write(f) != 0) {
            return 0;
        }
    }
    return count;
}

int fgetc(FILE *f) {
    flockfile(f);
    int c = fgetc_unlocked(f);
    funlockfile(f);
    return c;
}

int fgetc_unlocked(FILE *f) {
    if (f->ungot >= 0) {
        int c = f->ungot;
        f->ungot = -1;
        return c;
    }
    if (f->rpos < f->rlen) {
        return f->buf[f->rpos++];
    }
    if (f->flags & STREAM_EOF) {
        return EOF;
    }
    unsigned char c;
    return fread_unlocked(&c, 1, 1, f) == 1 ? c : EOF;
}

int getc(FILE *f) {
    return fgetc(f);
}

int getc_unlocked(FILE *f) {
    return fgetc_unlocked(f);
}

int getchar_unlocked(void) {
    return fgetc_unlocked(stdin);
}

int ungetc(int c, FILE *f) {
    if (c == EOF || f->ungot >= 0) {
        return EOF;
    }
    flockfile(f);
    f->ungot = (unsigned char)c;
    f->flags &= ~STREAM_EOF;
    funlockfile(f);
    return (unsigned char)c;
}

// A line, '\n' included, or what fits in size - 1 bytes; NULL at the end
// when nothing was read
char *fgets(char *s, int size, FILE *f) {
    flockfile(f);
    char *result = fgets_unlocked(s, size, f);
    funlockfile(f);
    return result;
}

char *fgets_unlocked(char *s, int size, FILE *f) {
    if (size <= 0) {
        return NULL;
    }
    int n = 0;
    while (n < size - 1) {
        int c = fgetc_unlocked(f);
        if (c == EOF) {
            break;
        }
        s[n++] = (char)c;
        if (c == '\n') {
            break;
        }
    }
    if (n == 0 || (f->flags & STREAM_ERROR)) {
        return NULL;
    }
    s[n] = '\0';
    return s;
}

int fputc(int c, FILE *f) {
    unsigned char ch = (unsigned char)c;
    return fwrite(&ch, 1, 1, f) == 1 ? ch : EOF;
}

int fputc_unlocked(int c, FILE *f) {
    unsigned char ch = (unsigned char)c;
    return fwrite_unlocked(&ch, 1, 1, f) == 1 ? ch : EOF;
}

int putc(int c, FILE *f) {
    return fputc(c, f);
}

int putc_unlocked(int c, FILE *f) {
    return fputc_unlocked(c, f);
}

int putchar_unlocked(int c) {
    return fputc_unlocked(c, stdout);
}

int fputs(const char *s, FILE *f) {
    size_t n = strlen(s);
    return n == 0 || fwrite(s, n, 1, f) == 1 ? 0 : EOF;
}

int fputs_unlocked(const char *s, FILE *f) {
    size_t n = strlen(s);
    return n == 0 || fwrite_unlocked(s, n, 1, f) == 1 ? 0 : EOF;
}

long long ftello(FILE *f) {
    flockfile(f);
    long long pos = ftello_unlocked(f);
    funlockfile(f);
    return pos;
}

static long long ftello_unlocked(FILE *f) {
    off_t pos = lseek(f->fd, 0, SEEK_CUR);
    if (pos < 0) {
        return -1;
    }
    return pos - (off_t)(f->rlen - f->rpos) - (f->ungot >= 0 ? 1 : 0) + (off_t)f->wlen;
}

long ftell(FILE *f) {
    long long pos = ftello(f);
    if (pos > LONG_MAX) {
        errno = EOVERFLOW;
        return -1;
    }
    return (long)pos;
}

int fseeko(FILE *f, long long offset, int whence) {
    flockfile(f);
    int result = fseeko_unlocked(f, offset, whence);
    funlockfile(f);
    return result;
}

static int fseeko_unlocked(FILE *f, long long offset, int whence) {
    if (whence == SEEK_CUR) {
        long long pos = ftello_unlocked(f);
        if (pos < 0) {
            return -1;
        }
        offset += pos;
        whence = SEEK_SET;
    }
    if (f->wlen > 0 && stream_flush_write(f) != 0) {
        return -1;
    }
    f->rpos = f->rlen = 0;
    f->ungot = -1;
    if (lseek(f->fd, offset, whence) < 0) {
        return -1;
    }
    f->flags &= ~STREAM_EOF;
    return 0;
}

int fseek(FILE *f, long offset, int whence) {
    return fseeko(f, offset, whence);
}

int fgetpos(FILE *f, fpos_t *pos) {
    long long p = ftello(f);
    if (p < 0) {
        return -1;
    }
    *pos = p;
    return 0;
}

int fsetpos(FILE *f, const fpos_t *pos) {
    return fseeko(f, *pos, SEEK_SET);
}

void rewind(FILE *f) {
    flockfile(f);
    fseeko_unlocked(f, 0, SEEK_SET);
    f->flags &= ~STREAM_ERROR;
    funlockfile(f);
}

int feof(FILE *f) {
    return (f->flags & STREAM_EOF) != 0;
}

int ferror(FILE *f) {
    return (f->flags & STREAM_ERROR) != 0;
}

void clearerr(FILE *f) {
    flockfile(f);
    f->flags &= ~(STREAM_EOF | STREAM_ERROR);
    funlockfile(f);
}

int feof_unlocked(FILE *f) {
    return feof(f);
}

int ferror_unlocked(FILE *f) {
    return ferror(f);
}

void clearerr_unlocked(FILE *f) {
    f->flags &= ~(STREAM_EOF | STREAM_ERROR);
}

/* TEMPORARY FILES
   Names are ZD, six decimal digits and .TMP, in the folder of TEMP. The
   number starts at a counter seeded by the clock, and each name found goes
   on from the one after it. */

#define TMP_TRIES 1000      /* numbers tried before giving up */
#define TMP_NUMBERS 1000000 /* ZD000000 .. ZD999999 */

typedef bool (*tmp_taken_fn)(const char *path, void *ctx);

// Writes dir + "\" + ZDnnnnnn.TMP into out (size bytes), for
// the first free number from counter on. Returns that number,
// -1 when all TMP_TRIES numbers are taken, -2 when the path
// does not fit. dir_len bytes of dir, no NUL needed.
static int tmp_name_find(char *out, size_t size, const char *dir, size_t dir_len,
                         uint32_t counter, tmp_taken_fn taken, void *ctx) {
    size_t sep = dir_len > 0 && (dir[dir_len - 1] == '\\' || dir[dir_len - 1] == '/') ? 0 : 1;
    if (dir_len + sep + 8 + 4 >= size) {
        return -2;
    }
    for (uint32_t i = 0; i < TMP_TRIES; i++) {
        uint32_t num = (counter + i) % TMP_NUMBERS;
        uint32_t digits = num;
        size_t p = dir_len;
        memcpy(out, dir, dir_len);
        if (sep) {
            out[p++] = '\\';
        }
        out[p++] = 'Z';
        out[p++] = 'D';
        for (int d = 5; d >= 0; d--) {
            out[p + d] = (char)('0' + digits % 10);
            digits /= 10;
        }
        p += 6;
        memcpy(out + p, ".TMP", 5); /* with the NUL */
        if (!taken(out, ctx)) {
            return (int)num;
        }
    }
    return -1;
}

// Taken: it is there, or stat failed for another reason than "not
// found" (then it can't be told apart, so it is kept). Opening it for
// reading is the second check.
static bool tmp_taken(const char *path, void *ctx) {
    (void)ctx;
    zdos_dir_entry e;
    if (zdos->files->stat(path, zdos_strlen(path), &e) || last_code() != ZDOS_ERROR_NOT_FOUND) {
        return true;
    }
    int fd = open(path, O_RDONLY);
    if (fd >= 0) {
        close(fd);
        return true;
    }
    return false;
}

static uint32_t tmp_next; /* the number tried first; seeded by the clock */
static bool tmp_seeded;

// A free name in TEMP into out (size bytes); 0, or -1 with errno (ENOENT:
// TEMP unset or empty; EEXIST: no name of TMP_TRIES free). A missing TEMP
// folder is made. The caller creates the file, so the name isn't reserved.
static int tmp_path(char *out, size_t size) {
    const char *temp = getenv("TEMP");
    if (temp == NULL || temp[0] == '\0') {
        return fail(ENOENT);
    }
    size_t len = strlen(temp);
    zdos_dir_entry e;
    if (zdos->files->stat(temp, len, &e)) {
        if (!e.is_dir) {
            return fail(ENOTDIR);
        }
    } else {
        uint32_t code = last_code();
        if (code != ZDOS_ERROR_NOT_FOUND && code != ZDOS_ERROR_PATH_NOT_FOUND) {
            return fail_last();
        }
        if (mkdir(temp, 0777) != 0) {
            return -1;
        }
    }
    if (!tmp_seeded) {
        tmp_seeded = true;
        tmp_next = zdos->time->millis != NULL ? (uint32_t)zdos->time->millis() : 0;
    }
    int n = tmp_name_find(out, size, temp, len, tmp_next, tmp_taken, NULL);
    if (n == -2) {
        return fail(ENAMETOOLONG);
    }
    if (n < 0) {
        return fail(EEXIST);
    }
    tmp_next = (uint32_t)n + 1;
    return 0;
}

char *tmpnam(char *s) {
    static char name[L_tmpnam];
    char *out = s != NULL ? s : name;
    return tmp_path(out, L_tmpnam) == 0 ? out : NULL;
}

// A new file opened "w+", removed by fclose (or freopen) through temp_name
FILE *tmpfile(void) {
    char name[L_tmpnam];
    if (tmp_path(name, sizeof(name)) != 0) {
        return NULL;
    }
    char *copy = strdup(name);
    if (copy == NULL) {
        errno = ENOMEM;
        return NULL;
    }
    FILE *f = fopen(name, "w+");
    if (f == NULL) {
        free(copy);
        return NULL;
    }
    f->temp_name = copy;
    return f;
}

// For Lua's os.tmpname: the file exists (empty) when 0 is returned
int zdos_tmpname_create(char *out, size_t size) {
    if (tmp_path(out, size) != 0) {
        return -1;
    }
    int fd = open(out, O_WRONLY | O_CREAT);
    if (fd < 0) {
        return -1;
    }
    return close(fd) == 0 ? 0 : -1;
}

/* MEMORY STREAMS */

// fmemopen: writing stops at the end of the buffer (ENOSPC); a 0 follows the
// text while there is room.
FILE *fmemopen(void *buf, size_t size, const char *mode) {
    int stream_flags;
    if (size == 0 || parse_mode(mode, &stream_flags) < 0) {
        errno = EINVAL;
        return NULL;
    }
    struct zdos_memfile *m = calloc(1, sizeof(*m));
    if (m == NULL) {
        errno = ENOMEM;
        return NULL;
    }
    m->size = size;
    if (buf == NULL) {
        m->buf = calloc(1, size);
        m->own_buf = true;
        if (m->buf == NULL) {
            free(m);
            errno = ENOMEM;
            return NULL;
        }
    } else {
        m->buf = buf;
    }
    uint64_t pos = 0;
    if (mode[0] == 'r') {
        m->len = m->own_buf ? 0 : size;
    } else if (mode[0] == 'w') {
        m->buf[0] = '\0';
    } else {
        m->len = strnlen(m->buf, size);
        pos = m->len;
    }
    int fd = mem_fd(m, (stream_flags & STREAM_READ) != 0, (stream_flags & STREAM_WRITE) != 0, mode[0] == 'a', pos);
    if (fd < 0) {
        return NULL;
    }
    FILE *f = new_stream(fd, stream_flags);
    if (f == NULL) {
        close(fd);
    }
    return f;
}

// open_memstream: *ptr and *size are valid after fflush or fclose.
FILE *open_memstream(char **ptr, size_t *size) {
    if (ptr == NULL || size == NULL) {
        errno = EINVAL;
        return NULL;
    }
    struct zdos_memfile *m = calloc(1, sizeof(*m));
    char *buf = calloc(1, 64);
    if (m == NULL || buf == NULL) {
        free(m);
        free(buf);
        errno = ENOMEM;
        return NULL;
    }
    m->buf = buf;
    m->size = 64;
    m->grows = true;
    m->out = ptr;
    m->out_size = size;
    mem_publish(m);
    int fd = mem_fd(m, false, true, false, 0);
    if (fd < 0) {
        return NULL;
    }
    FILE *f = new_stream(fd, STREAM_WRITE);
    if (f == NULL) {
        close(fd);
    }
    return f;
}

/* LINES OF ANY LENGTH */

ssize_t getdelim(char **line, size_t *size, int delim, FILE *f) {
    if (line == NULL || size == NULL || f == NULL) {
        errno = EINVAL;
        return -1;
    }
    size_t len = 0;
    flockfile(f);
    for (;;) {
        int c = fgetc_unlocked(f);
        if (c == EOF) {
            break;
        }
        if (len + 2 > *size || *line == NULL) {
            size_t bigger = *size >= 64 ? *size * 2 : 128;
            char *p = realloc(*line, bigger);
            if (p == NULL) {
                funlockfile(f);
                errno = ENOMEM;
                return -1;
            }
            *line = p;
            *size = bigger;
        }
        (*line)[len++] = (char)c;
        if (c == delim) {
            break;
        }
    }
    funlockfile(f);
    if (len == 0) {
        return -1;
    }
    (*line)[len] = '\0';
    return (ssize_t)len;
}

ssize_t getline(char **line, size_t *size, FILE *f) {
    return getdelim(line, size, '\n', f);
}

/* POPEN
   Over the program API's pipes: "r" runs the command at popen with its
   output in a pipe, which the stream then reads; "w" collects what is
   written and runs the command at pclose with that as its input (programs
   run one at a time). pclose returns the command's ERRORLEVEL, as system()
   does, or -1 with errno. */
#define POPEN_MAX 8

struct popen_entry {
    FILE *file; /* NULL: the slot is free */
    char *cmd;  /* "w": the command, run at pclose; NULL for "r" */
    int status; /* "r": the ERRORLEVEL of the command run at popen */
};
static struct popen_entry popen_list[POPEN_MAX];

static struct popen_entry *popen_find(FILE *file) {
    for (int i = 0; i < POPEN_MAX; i++) {
        if (popen_list[i].file == file) {
            return &popen_list[i];
        }
    }
    return NULL;
}

FILE *popen(const char *command, const char *mode) {
    if (zdos == NULL || command == NULL || mode == NULL || (mode[0] != 'r' && mode[0] != 'w') || mode[1] == '+') {
        errno = EINVAL;
        return NULL;
    }
    struct popen_entry *slot = popen_find(NULL);
    if (slot == NULL) {
        errno = EMFILE;
        return NULL;
    }
    bool writing = mode[0] == 'w';
    char *copy = NULL;
    if (writing) {
        copy = strdup(command);
        if (copy == NULL) {
            errno = ENOMEM;
            return NULL;
        }
    }
    fflush(NULL); /* the command sees what the program wrote to its files */
    int32_t pipe = zdos->system->create_pipe();
    if (pipe < 0) {
        free(copy);
        errno = zdos_errno_from_last_error();
        return NULL;
    }
    FILE *f;
    int status = 0;
    if (writing) {
        f = zdos_pipe_stream(pipe, "w"); /* closes the pipe on failure */
    } else {
        if (!zdos->system->redirect(1, pipe)) {
            int e = zdos_errno_from_last_error();
            zdos->files->close(pipe);
            errno = e;
            return NULL;
        }
        status = zdos->programs->run_command(command, strlen(command));
        zdos->system->redirect(1, -1); /* back to the program's own output */
        f = zdos_pipe_stream(pipe, "r"); /* a pipe is read from its start */
    }
    if (f == NULL) {
        free(copy);
        return NULL;
    }
    slot->file = f;
    slot->cmd = copy;
    slot->status = status;
    return f;
}

int pclose(FILE *file) {
    struct popen_entry *e = file != NULL ? popen_find(file) : NULL;
    if (e == NULL) {
        errno = EINVAL;
        return -1;
    }
    int status = e->status;
    int err = 0;
    if (e->cmd != NULL) { /* "w": the pipe is the command's input */
        if (fflush(file) != 0) {
            err = errno;
        } else if (!zdos->system->redirect(0, zdos_stream_handle(file))) {
            err = zdos_errno_from_last_error();
        } else {
            fflush(NULL);
            status = zdos->programs->run_command(e->cmd, strlen(e->cmd));
            zdos->system->redirect(0, -1); /* back to the program's own input */
        }
        free(e->cmd);
        e->cmd = NULL;
    }
    if (fclose(file) != 0 && err == 0) { /* frees the pipe */
        err = errno;
    }
    e->file = NULL;
    if (err == 0 && status < 0) {
        err = EIO; /* the command interpreter could not be started */
    }
    if (err != 0) {
        errno = err;
        return -1;
    }
    return status;
}

/* UNIQUE TEMPORARY NAMES FROM A TEMPLATE
   The last six characters of template must be XXXXXX; they become letters
   and digits that make a name not yet there. */
static char *temp_suffix(char *template) {
    size_t n = template != NULL ? strlen(template) : 0;
    if (n < 6 || strcmp(template + n - 6, "XXXXXX") != 0) {
        errno = EINVAL;
        return NULL;
    }
    return template + n - 6;
}

static void temp_fill(char *suffix) {
    static const char chars[] = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    if (!tmp_seeded) {
        tmp_seeded = true;
        tmp_next = zdos->time->millis != NULL ? (uint32_t)zdos->time->millis() : 0;
    }
    uint32_t v = tmp_next++ * 2654435761u; /* spread the numbers out */
    for (int i = 0; i < 6; i++) {
        suffix[i] = chars[v % 36];
        v /= 36;
    }
}

// A new file at a free name, opened for reading and writing: its descriptor
int mkstemp(char *template) {
    char *suffix = temp_suffix(template);
    if (suffix == NULL) {
        return -1;
    }
    for (int i = 0; i < TMP_TRIES; i++) {
        temp_fill(suffix);
        int fd = open(template, O_RDWR | O_CREAT | O_EXCL);
        if (fd >= 0 || errno != EEXIST) {
            return fd;
        }
    }
    return fail(EEXIST);
}

// A new folder at a free name: template
char *mkdtemp(char *template) {
    char *suffix = temp_suffix(template);
    if (suffix == NULL) {
        return NULL;
    }
    for (int i = 0; i < TMP_TRIES; i++) {
        temp_fill(suffix);
        if (mkdir(template, 0700) == 0) {
            return template;
        }
        if (errno != EEXIST) {
            return NULL;
        }
    }
    errno = EEXIST;
    return NULL;
}

/* LINKS AND FILE TIMES
   FAT has no links: lstat is stat, readlink finds no link, making one fails. */
int lstat(const char *path, struct stat *st) {
    return stat(path, st);
}

ssize_t readlink(const char *path, char *buf, size_t size) {
    (void)buf;
    (void)size;
    struct stat st;
    if (stat(path, &st) != 0) {
        return -1;
    }
    return fail(EINVAL); /* there, but not a link */
}

int symlink(const char *target, const char *path) {
    (void)target;
    (void)path;
    return fail(EPERM);
}

int link(const char *existing, const char *path) {
    (void)existing;
    (void)path;
    return fail(EPERM);
}

// ZDOS keeps local time
static bool zdos_time_of(time_t t, zdos_time *zt) {
    struct tm tm;
    if (localtime_r(&t, &tm) == NULL) {
        return false;
    }
    *zt = (zdos_time){(uint16_t)(tm.tm_year + 1900), (uint8_t)(tm.tm_mon + 1), (uint8_t)tm.tm_mday,
                      (uint8_t)tm.tm_hour, (uint8_t)tm.tm_min, (uint8_t)tm.tm_sec, 0};
    return true;
}

// Sets a file's modification time (FAT keeps it to 2 seconds); the access
// time is not changed
static int set_modified(const char *path, time_t t) {
    zdos_time zt;
    if (zdos == NULL || !zdos_time_of(t, &zt)) {
        return fail(EINVAL);
    }
    if (!zdos->files->set_time(path, zdos_strlen(path), &zt)) {
        return fail_last();
    }
    return 0;
}

// The same through an open descriptor (futimens, futimes)
int zdos_fd_set_modified(int fd, time_t t) {
    zdos_time zt;
    if (zdos == NULL) {
        return fail(ENOSYS);
    }
    fd = resolve_fd(fd);
    int32_t h = is_std_fd(fd) ? std_handle[fd] : valid_fd(fd) && zdos_file_mem[fd] == NULL ? zdos_file_handles[fd] : -1;
    if (h < 0) {
        return fail(valid_fd(fd) || is_std_fd(fd) ? EINVAL : EBADF);
    }
    if (!zdos_time_of(t, &zt)) {
        return fail(EINVAL);
    }
    if (!zdos->files->fset_time(h, &zt)) {
        return zdos->programs->last_error() == ZDOS_ERROR_NOT_SUPPORTED ? fail(ENOSYS) : fail_last();
    }
    return 0;
}

int futimes(int fd, const struct timeval times[2]) {
    return zdos_fd_set_modified(fd, times != NULL ? times[1].tv_sec : time(NULL));
}

int utime(const char *path, const struct utimbuf *times) {
    return set_modified(path, times != NULL ? times->modtime : time(NULL));
}

int utimes(const char *path, const struct timeval times[2]) {
    return set_modified(path, times != NULL ? times[1].tv_sec : time(NULL));
}

/* DIRECTORY LISTINGS */

// The entries of dir that filter accepts (all with NULL), sorted by compar
// (unsorted with NULL), in *namelist; free each entry, then the list
int scandir(const char *dir, struct dirent ***namelist, int (*filter)(const struct dirent *),
            int (*compar)(const struct dirent **, const struct dirent **)) {
    DIR *d = opendir(dir);
    if (d == NULL) {
        return -1;
    }
    struct dirent **list = NULL;
    size_t n = 0, cap = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (filter != NULL && !filter(e)) {
            continue;
        }
        struct dirent *copy = malloc(sizeof(*copy));
        if (n == cap) {
            cap = cap != 0 ? cap * 2 : 16;
            struct dirent **bigger = realloc(list, cap * sizeof(*list));
            if (bigger == NULL) {
                free(copy);
                copy = NULL;
            } else {
                list = bigger;
            }
        }
        if (copy == NULL) {
            while (n > 0) {
                free(list[--n]);
            }
            free(list);
            closedir(d);
            return fail(ENOMEM);
        }
        memcpy(copy, e, sizeof(*copy));
        list[n++] = copy;
    }
    closedir(d);
    if (compar != NULL && n > 1) {
        qsort(list, n, sizeof(*list), (int (*)(const void *, const void *))compar);
    }
    *namelist = list;
    return (int)n;
}

int alphasort(const struct dirent **a, const struct dirent **b) {
    return strcoll((*a)->d_name, (*b)->d_name);
}

/* GLOB Each part of the pattern between / or \ may hold * ? and [...]; letters
   match in either case and a leading . only a written one, as ZDOS names go.
   \ separates folders here, so it doesn't escape (GLOB_NOESCAPE is always on).
   The names found keep the pattern's separators. */
struct glob_state {
    glob_t *g;
    int flags;
    int (*errfunc)(const char *path, int err);
};

static int glob_add(struct glob_state *st, const char *path, bool is_dir) {
    glob_t *g = st->g;
    size_t n = strlen(path);
    bool mark = (st->flags & GLOB_MARK) && is_dir && n > 0 && path[n - 1] != '/' && path[n - 1] != '\\';
    char *copy = malloc(n + (mark ? 2 : 1));
    char **v = realloc(g->gl_pathv, (g->gl_offs + g->gl_pathc + 2) * sizeof(char *));
    if (copy == NULL || v == NULL) {
        free(copy);
        if (v != NULL) {
            g->gl_pathv = v;
        }
        return GLOB_NOSPACE;
    }
    if (g->gl_pathv == NULL) {
        for (size_t i = 0; i < g->gl_offs; i++) {
            v[i] = NULL;
        }
    }
    g->gl_pathv = v;
    memcpy(copy, path, n + 1);
    if (mark) {
        copy[n] = '/';
        copy[n + 1] = '\0';
    }
    v[g->gl_offs + g->gl_pathc++] = copy;
    v[g->gl_offs + g->gl_pathc] = NULL;
    return 0;
}

// path[0..len) is the folder so far; rest the pattern still to match
static int glob_part(struct glob_state *st, char *path, size_t len, const char *rest) {
    while (*rest == '/' || *rest == '\\') {
        if (len + 1 >= PATH_MAX) {
            return 0;
        }
        path[len++] = *rest++;
    }
    path[len] = '\0';
    if (*rest == '\0') {
        struct stat s;
        return len > 0 && stat(path, &s) == 0 ? glob_add(st, path, S_ISDIR(s.st_mode)) : 0;
    }
    size_t part_len = strcspn(rest, "/\\");
    const char *next = rest + part_len;
    bool wild = false;
    for (size_t i = 0; i < part_len; i++) {
        if (rest[i] == '*' || rest[i] == '?' || rest[i] == '[') {
            wild = true;
        }
    }
    if (!wild) {
        if (len + part_len >= PATH_MAX) {
            return 0;
        }
        memcpy(path + len, rest, part_len);
        path[len + part_len] = '\0';
        if (*next == '\0') {
            struct stat s;
            return stat(path, &s) == 0 ? glob_add(st, path, S_ISDIR(s.st_mode)) : 0;
        }
        return glob_part(st, path, len + part_len, next);
    }
    char part[NAME_MAX + 1];
    if (part_len > NAME_MAX) {
        return 0;
    }
    memcpy(part, rest, part_len);
    part[part_len] = '\0';
    DIR *d = opendir(len > 0 ? path : ".");
    if (d == NULL) {
        if ((st->errfunc != NULL && st->errfunc(len > 0 ? path : ".", errno) != 0) || (st->flags & GLOB_ERR)) {
            return GLOB_ABORTED;
        }
        return 0;
    }
    struct dirent *e;
    int result = 0;
    while (result == 0 && (e = readdir(d)) != NULL) {
        if ((strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) && part[0] != '.') {
            continue;
        }
        if (fnmatch(part, e->d_name, FNM_PERIOD | FNM_NOESCAPE | FNM_CASEFOLD) != 0) {
            continue;
        }
        size_t n = strlen(e->d_name);
        if (len + n >= PATH_MAX) {
            continue;
        }
        memcpy(path + len, e->d_name, n + 1);
        if (*next == '\0') {
            result = glob_add(st, path, e->d_type == DT_DIR);
        } else if (e->d_type == DT_DIR) {
            result = glob_part(st, path, len + n, next);
        }
    }
    closedir(d);
    return result;
}

static int glob_compare(const void *a, const void *b) {
    return strcmp(*(char *const *)a, *(char *const *)b);
}

int glob(const char *pattern, int flags, int (*errfunc)(const char *path, int err), glob_t *g) {
    if (!(flags & GLOB_APPEND)) {
        g->gl_pathc = 0;
        g->gl_pathv = NULL;
        if (!(flags & GLOB_DOOFFS)) {
            g->gl_offs = 0;
        }
    }
    size_t before = g->gl_pathc;
    struct glob_state st = {g, flags, errfunc};
    char path[PATH_MAX];
    int result = glob_part(&st, path, 0, pattern);
    if (result != 0) {
        return result;
    }
    if (g->gl_pathc == before) {
        if (!(flags & GLOB_NOCHECK)) {
            return GLOB_NOMATCH;
        }
        return glob_add(&st, pattern, false); /* GLOB_NOCHECK: the pattern itself */
    }
    if (!(flags & GLOB_NOSORT)) {
        qsort(g->gl_pathv + g->gl_offs + before, g->gl_pathc - before, sizeof(char *), glob_compare);
    }
    return 0;
}

void globfree(glob_t *g) {
    if (g->gl_pathv != NULL) {
        for (size_t i = 0; i < g->gl_pathc; i++) {
            free(g->gl_pathv[g->gl_offs + i]);
        }
        free(g->gl_pathv);
    }
    g->gl_pathv = NULL;
    g->gl_pathc = 0;
}

/* WALKING A TREE (ftw.h) Every file and folder under path, the folder before
   its contents (after them with FTW_DEPTH). A non-zero result from fn stops
   the walk and is returned. nopenfd is not needed; FTW_PHYS and FTW_MOUNT
   change nothing (FAT has no links, every folder is on its drive);
   FTW_CHDIR is not done. */
struct walk {
    int (*nfn)(const char *path, const struct stat *st, int type, struct FTW *ftw);
    int (*fn)(const char *path, const struct stat *st, int type);
    int flags;
    char sep;
    char path[PATH_MAX];
};

static int walk_call(struct walk *w, const struct stat *st, int type, int base, int level) {
    if (w->nfn != NULL) {
        struct FTW ftw = {base, level};
        return w->nfn(w->path, st, type, &ftw);
    }
    return w->fn(w->path, st, type == FTW_DP ? FTW_D : type);
}

static int walk_at(struct walk *w, size_t len, int base, int level) {
    struct stat st;
    if (stat(w->path, &st) != 0) {
        memset(&st, 0, sizeof(st));
        return walk_call(w, &st, FTW_NS, base, level);
    }
    if (!S_ISDIR(st.st_mode)) {
        return walk_call(w, &st, FTW_F, base, level);
    }
    int result;
    if (!(w->flags & FTW_DEPTH) && (result = walk_call(w, &st, FTW_D, base, level)) != 0) {
        return result;
    }
    DIR *d = opendir(w->path);
    if (d == NULL) {
        return walk_call(w, &st, FTW_DNR, base, level);
    }
    bool ends_with_sep = len > 0 && (w->path[len - 1] == '/' || w->path[len - 1] == '\\');
    size_t at = len + (ends_with_sep ? 0 : 1);
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) {
            continue;
        }
        size_t n = strlen(e->d_name);
        if (at + n >= sizeof(w->path)) {
            closedir(d);
            return fail(ENAMETOOLONG);
        }
        if (!ends_with_sep) {
            w->path[len] = w->sep;
        }
        memcpy(w->path + at, e->d_name, n + 1);
        result = walk_at(w, at + n, (int)at, level + 1);
        w->path[len] = '\0';
        if (result != 0) {
            closedir(d);
            return result;
        }
    }
    closedir(d);
    return (w->flags & FTW_DEPTH) ? walk_call(w, &st, FTW_DP, base, level) : 0;
}

static int walk_start(struct walk *w, const char *path) {
    size_t len = strlen(path);
    if (len >= sizeof(w->path)) {
        return fail(ENAMETOOLONG);
    }
    memcpy(w->path, path, len + 1);
    w->sep = strchr(path, '\\') != NULL ? '\\' : '/';
    int base = 0;
    for (size_t i = 0; i + 1 < len; i++) {
        if (path[i] == '/' || path[i] == '\\') {
            base = (int)i + 1;
        }
    }
    return walk_at(w, len, base, 0);
}

int nftw(const char *path, int (*fn)(const char *, const struct stat *, int, struct FTW *), int nopenfd, int flags) {
    (void)nopenfd;
    struct walk *w = calloc(1, sizeof(*w));
    if (w == NULL) {
        return fail(ENOMEM);
    }
    w->nfn = fn;
    w->flags = flags;
    int result = walk_start(w, path);
    free(w);
    return result;
}

int ftw(const char *path, int (*fn)(const char *, const struct stat *, int), int nopenfd) {
    (void)nopenfd;
    struct walk *w = calloc(1, sizeof(*w));
    if (w == NULL) {
        return fail(ENOMEM);
    }
    w->fn = fn;
    int result = walk_start(w, path);
    free(w);
    return result;
}

/* MMAP
   One address space: a mapping is page-aligned heap memory. A file's part
   is read in at mmap; a shared writable one is written back at msync,
   munmap and exit, through a duplicate of the descriptor (the program may
   close its own). munmap of the start or the end of a mapping shortens it;
   its memory is freed when nothing of it is left. */

#define MMAP_PAGE 4096u

typedef struct mmap_region {
    struct mmap_region *next;
    void *block; /* from zdos->memory->alloc */
    unsigned char *start; /* the mapping as returned, page-aligned */
    size_t length; /* rounded up to pages */
    unsigned char *live_lo, *live_hi; /* what isn't unmapped yet */
    int fd; /* the duplicate, for writing back; -1 if none */
    off_t offset;
    size_t file_bytes; /* the mapping's part that was in the file at mmap */
    bool anonymous, shared_write;
} mmap_region;

static mmap_region *mmap_regions;

static mmap_region *mmap_find(const void *addr, size_t length) {
    const unsigned char *a = addr;
    for (mmap_region *r = mmap_regions; r != NULL; r = r->next) {
        if (a >= r->start && a < r->start + r->length && length <= (size_t)(r->start + r->length - a)) {
            return r;
        }
    }
    return NULL;
}

/* fd's bytes at offset into buf, its position kept; the count read */
static ssize_t mmap_read(int fd, void *buf, size_t count, off_t offset) {
    off_t saved = lseek(fd, 0, SEEK_CUR);
    if (saved < 0 || lseek(fd, offset, SEEK_SET) < 0) {
        return -1;
    }
    size_t done = 0;
    while (done < count) {
        ssize_t n = read(fd, (unsigned char *)buf + done, count - done);
        if (n < 0) {
            lseek(fd, saved, SEEK_SET);
            return -1;
        }
        if (n == 0) {
            break;
        }
        done += (size_t)n;
    }
    lseek(fd, saved, SEEK_SET);
    return (ssize_t)done;
}

/* A shared writable mapping's [from, to) back into its file (only what was
   in the file: a mapping doesn't make the file longer) */
static int mmap_write_back(mmap_region *r, unsigned char *from, unsigned char *to) {
    if (!r->shared_write || r->fd < 0) {
        return 0;
    }
    unsigned char *file_end = r->start + r->file_bytes;
    if (from < r->live_lo) {
        from = r->live_lo;
    }
    if (to > r->live_hi) {
        to = r->live_hi;
    }
    if (to > file_end) {
        to = file_end;
    }
    if (from >= to) {
        return 0;
    }
    off_t saved = lseek(r->fd, 0, SEEK_CUR);
    if (lseek(r->fd, r->offset + (off_t)(from - r->start), SEEK_SET) < 0) {
        return -1;
    }
    int result = 0;
    while (from < to) {
        ssize_t n = write(r->fd, from, (size_t)(to - from));
        if (n <= 0) {
            errno = EIO;
            result = -1;
            break;
        }
        from += n;
    }
    if (saved >= 0) {
        lseek(r->fd, saved, SEEK_SET);
    }
    // To the disk now: other descriptors of the file read what was written
    if (result == 0 && fsync(r->fd) != 0) {
        errno = EIO;
        result = -1;
    }
    return result;
}

static void mmap_release(mmap_region *r) {
    for (mmap_region **p = &mmap_regions; *p != NULL; p = &(*p)->next) {
        if (*p == r) {
            *p = r->next;
            break;
        }
    }
    if (r->fd >= 0) {
        close(r->fd);
    }
    zdos->memory->free(r->block);
    free(r);
}

static void mmap_sync_all(void) {
    for (mmap_region *r = mmap_regions; r != NULL; r = r->next) {
        mmap_write_back(r, r->live_lo, r->live_hi);
    }
}

/* The contents of [at, at + length) of a mapping: zeroes, then the file's
   part (file mappings); the count from the file, or -1 */
static ssize_t mmap_fill(unsigned char *at, size_t length, int fd, off_t offset) {
    memset(at, 0, length);
    return fd < 0 ? 0 : mmap_read(fd, at, length, offset);
}

void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    (void)prot;
    int type = flags & MAP_TYPE;
    bool anonymous = (flags & MAP_ANONYMOUS) != 0;
    if (length == 0 || (type != MAP_SHARED && type != MAP_PRIVATE && type != MAP_SHARED_VALIDATE) ||
        (offset & (MMAP_PAGE - 1)) != 0 || offset < 0 || length > SIZE_MAX - 2 * MMAP_PAGE) {
        errno = EINVAL;
        return MAP_FAILED;
    }
    if (zdos == NULL || zdos->memory->alloc == NULL) {
        errno = ENOMEM;
        return MAP_FAILED;
    }
    if (anonymous) {
        fd = -1;
        offset = 0;
    } else {
        struct stat st;
        if (fstat(fd, &st) != 0) {
            errno = EBADF;
            return MAP_FAILED;
        }
        if (S_ISDIR(st.st_mode)) {
            errno = ENODEV;
            return MAP_FAILED;
        }
    }
    size_t pages = (length + MMAP_PAGE - 1) & ~(size_t)(MMAP_PAGE - 1);

    // MAP_FIXED: only over a mapping of ours, which gets the new contents
    if (flags & (MAP_FIXED | MAP_FIXED_NOREPLACE)) {
        mmap_region *r = mmap_find(addr, pages);
        if (((uintptr_t)addr & (MMAP_PAGE - 1)) != 0) {
            errno = EINVAL;
            return MAP_FAILED;
        }
        if (r == NULL || (flags & MAP_FIXED_NOREPLACE)) {
            errno = (flags & MAP_FIXED_NOREPLACE) && r != NULL ? EEXIST : ENOMEM;
            return MAP_FAILED;
        }
        if (mmap_fill(addr, pages, fd, offset) < 0) {
            return MAP_FAILED;
        }
        return addr;
    }

    mmap_region *r = malloc(sizeof(*r));
    void *block = r != NULL ? zdos->memory->alloc(pages + MMAP_PAGE) : NULL;
    if (block == NULL) {
        free(r);
        errno = ENOMEM;
        return MAP_FAILED;
    }
    unsigned char *start = (unsigned char *)(((uintptr_t)block + MMAP_PAGE - 1) & ~(uintptr_t)(MMAP_PAGE - 1));
    ssize_t got = mmap_fill(start, pages, fd, offset);
    if (got < 0) {
        int e = errno;
        zdos->memory->free(block);
        free(r);
        errno = e == 0 ? EACCES : e;
        return MAP_FAILED;
    }
    *r = (mmap_region){
        .block = block,
        .start = start,
        .length = pages,
        .live_lo = start,
        .live_hi = start + pages,
        .fd = -1,
        .offset = offset,
        .file_bytes = (size_t)got,
        .anonymous = anonymous,
        .shared_write = !anonymous && type != MAP_PRIVATE && (prot & PROT_WRITE) != 0,
    };
    if (r->shared_write) {
        r->fd = dup(fd);
        if (r->fd < 0) {
            int e = errno;
            zdos->memory->free(block);
            free(r);
            errno = e;
            return MAP_FAILED;
        }
    }
    r->next = mmap_regions;
    mmap_regions = r;
    return start;
}

int munmap(void *addr, size_t length) {
    unsigned char *lo = addr;
    if (((uintptr_t)addr & (MMAP_PAGE - 1)) != 0 || length == 0) {
        return fail(EINVAL);
    }
    unsigned char *hi = lo + ((length + MMAP_PAGE - 1) & ~(size_t)(MMAP_PAGE - 1));
    // Every mapping the range touches (unmapping what isn't mapped is fine)
    mmap_region *r = mmap_regions;
    while (r != NULL) {
        mmap_region *next = r->next;
        if (lo < r->live_hi && hi > r->live_lo) {
            mmap_write_back(r, lo, hi);
            if (lo <= r->live_lo && hi >= r->live_hi) {
                mmap_release(r);
            } else if (lo <= r->live_lo) {
                r->live_lo = hi;
            } else if (hi >= r->live_hi) {
                r->live_hi = lo;
            }
            // a hole in the middle: the memory stays until the rest goes
        }
        r = next;
    }
    return 0;
}

void *mremap(void *old_address, size_t old_size, size_t new_size, int flags, ...) {
    size_t old_pages = (old_size + MMAP_PAGE - 1) & ~(size_t)(MMAP_PAGE - 1);
    size_t new_pages = (new_size + MMAP_PAGE - 1) & ~(size_t)(MMAP_PAGE - 1);
    mmap_region *r = old_size != 0 ? mmap_find(old_address, old_pages) : NULL;
    if (((uintptr_t)old_address & (MMAP_PAGE - 1)) != 0 || new_size == 0 || (flags & ~MREMAP_MAYMOVE) != 0) {
        errno = EINVAL;
        return MAP_FAILED;
    }
    if (r == NULL) {
        errno = EFAULT;
        return MAP_FAILED;
    }
    if (new_pages <= old_pages) {
        if (new_pages < old_pages) {
            munmap((unsigned char *)old_address + new_pages, old_pages - new_pages);
        }
        return old_address;
    }
    if (!r->anonymous || !(flags & MREMAP_MAYMOVE)) {
        errno = !r->anonymous ? EINVAL : ENOMEM;
        return MAP_FAILED;
    }
    void *moved = mmap(NULL, new_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (moved == MAP_FAILED) {
        return MAP_FAILED;
    }
    memcpy(moved, old_address, old_size);
    munmap(old_address, old_size);
    return moved;
}

int msync(void *addr, size_t length, int flags) {
    (void)flags;
    unsigned char *lo = addr;
    if (((uintptr_t)addr & (MMAP_PAGE - 1)) != 0) {
        return fail(EINVAL);
    }
    mmap_region *r = mmap_find(addr, length);
    if (r == NULL) {
        return fail(ENOMEM);
    }
    return mmap_write_back(r, lo, lo + length);
}

int mprotect(void *addr, size_t length, int prot) {
    (void)prot;
    if (((uintptr_t)addr & (MMAP_PAGE - 1)) != 0) {
        return fail(EINVAL);
    }
    return mmap_find(addr, length) != NULL ? 0 : fail(ENOMEM);
}

int madvise(void *addr, size_t length, int advice) {
    mmap_region *r = mmap_find(addr, length);
    if (r == NULL) {
        return fail(ENOMEM);
    }
    // As on Linux: an anonymous private page is zero when next read
    if (advice == MADV_DONTNEED && r->anonymous) {
        memset(addr, 0, length);
    }
    return 0;
}

int posix_madvise(void *addr, size_t length, int advice) {
    (void)advice;
    return mmap_find(addr, length) != NULL ? 0 : ENOMEM;
}

int mlock(const void *addr, size_t length) {
    (void)addr;
    (void)length;
    return 0; /* nothing is ever paged out */
}

int munlock(const void *addr, size_t length) {
    (void)addr;
    (void)length;
    return 0;
}

int mlockall(int flags) {
    (void)flags;
    return 0;
}

int munlockall(void) {
    return 0;
}

int getpagesize(void) {
    return MMAP_PAGE;
}
