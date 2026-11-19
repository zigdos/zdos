/* The ZDOS program interface for C and C++: mirrors abi.zig, so
   change both together. */
#ifndef ZDOS_H
#define ZDOS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The kernel's conventions: x86-64 ZDOS is a UEFI program (Microsoft x64) */
#if defined(__x86_64__)
#define ZDOS_CALL __attribute__((ms_abi))
#elif defined(__aarch64__)
#define ZDOS_CALL
#else
#define ZDOS_CALL __attribute__((cdecl))
#endif

#define ZDOS_SDK_API_VERSION 1 /* abi.version: the API version this SDK provides */

/* The file's own version in its header (VER FILE.APP), once at file level:
   ZDOS_FILE_VERSION(1, 2, 0, 0); each part 0-255 */
#define ZDOS_FILE_VERSION(major, minor, patch, build) \
    __asm__(".globl zdos_file_version\n.set zdos_file_version, (" #major ")*16777216+(" #minor ")*65536+(" #patch ")*256+(" #build ")\n")

/* The API version the program needs, at file level: ZDOS_API_VERSION(2);
   without it 1. A newer one than ZDOS has: the program isn't loaded. */
#ifdef __cplusplus
#define ZDOS_API_ASSERT static_assert
#else
#define ZDOS_API_ASSERT _Static_assert
#endif
#define ZDOS_API_VERSION(v) \
    ZDOS_API_ASSERT((v) >= 1 && (v) <= ZDOS_SDK_API_VERSION, "ZDOS_API_VERSION: not one this SDK has"); \
    __asm__(".globl zdos_api_version\n.set zdos_api_version, " #v "\n")

typedef struct {
    uint16_t scan;
    uint16_t char_;
    uint16_t mods;
    uint16_t pad;
} zdos_key;

typedef struct {
    uint16_t code;
    bool pressed;
    bool repeat;
    uint16_t mods;
    uint16_t pad;
} zdos_key_event;

typedef struct {
    int32_t dx, dy;
    int32_t wheel;
    uint32_t buttons;
} zdos_mouse;

enum { ZDOS_MOUSE_LEFT = 1, ZDOS_MOUSE_RIGHT = 2, ZDOS_MOUSE_MIDDLE = 4 };

enum {
    ZDOS_MOD_LEFT_SHIFT = 0x0001, ZDOS_MOD_RIGHT_SHIFT = 0x0002,
    ZDOS_MOD_LEFT_CTRL = 0x0004, ZDOS_MOD_RIGHT_CTRL = 0x0008,
    ZDOS_MOD_LEFT_ALT = 0x0010, ZDOS_MOD_RIGHT_ALT = 0x0020,
    ZDOS_MOD_LEFT_LOGO = 0x0040, ZDOS_MOD_RIGHT_LOGO = 0x0080,
    ZDOS_MOD_MENU = 0x0100,
    ZDOS_MOD_CAPS_LOCK = 0x1000, ZDOS_MOD_NUM_LOCK = 0x2000, ZDOS_MOD_SCROLL_LOCK = 0x4000,
    ZDOS_MOD_SHIFT = 0x0003, ZDOS_MOD_CTRL = 0x000C, ZDOS_MOD_ALT = 0x0030, ZDOS_MOD_LOGO = 0x00C0,
};

enum {
    ZDOS_SCAN_UP = 0x01, ZDOS_SCAN_DOWN = 0x02, ZDOS_SCAN_RIGHT = 0x03, ZDOS_SCAN_LEFT = 0x04,
    ZDOS_SCAN_HOME = 0x05, ZDOS_SCAN_END = 0x06, ZDOS_SCAN_INSERT = 0x07, ZDOS_SCAN_DELETE = 0x08,
    ZDOS_SCAN_PAGE_UP = 0x09, ZDOS_SCAN_PAGE_DOWN = 0x0a,
    ZDOS_SCAN_F1 = 0x0b,
    ZDOS_SCAN_F11 = 0x15, ZDOS_SCAN_F12 = 0x16, ZDOS_SCAN_ESC = 0x17,
    ZDOS_SCAN_REDRAW = 0xFE, /* not a key: see console->edit_line */
};

typedef struct {
    uint16_t year;
    uint8_t month, day, hour, minute, second, pad;
} zdos_time;

typedef enum {
    ZDOS_READ = 0,
    ZDOS_WRITE = 1,
    ZDOS_UPDATE = 2,
} zdos_open_mode;

#define ZDOS_SEEK_END UINT64_MAX
#define ZDOS_LOCK_EXCLUSIVE 1u /* files->lock's flags */

/* ZDOS's own codes, not errno; the SDK's POSIX functions translate them */
typedef enum {
    ZDOS_ERROR_NONE = 0,
    ZDOS_ERROR_NOT_FOUND = 1,
    ZDOS_ERROR_PATH_NOT_FOUND = 2,
    ZDOS_ERROR_ALREADY_EXISTS = 3,
    ZDOS_ERROR_ACCESS_DENIED = 4,
    ZDOS_ERROR_WRITE_PROTECTED = 5,
    ZDOS_ERROR_DISK_FULL = 6,
    ZDOS_ERROR_TOO_MANY_OPEN = 7,
    ZDOS_ERROR_INVALID_HANDLE = 8,
    ZDOS_ERROR_OUT_OF_MEMORY = 9,
    ZDOS_ERROR_INVALID_NAME = 10,
    ZDOS_ERROR_DEVICE_ERROR = 11,
    ZDOS_ERROR_NOT_SUPPORTED = 12,
    ZDOS_ERROR_NOT_A_DIRECTORY = 13,
    ZDOS_ERROR_IS_A_DIRECTORY = 14,
    ZDOS_ERROR_DIR_NOT_EMPTY = 15,
    ZDOS_ERROR_INVALID_ARGUMENT = 16,
    ZDOS_ERROR_INTERRUPTED = 17,     /* a signal ended the wait */
    ZDOS_ERROR_TIMED_OUT = 18,
    ZDOS_ERROR_WOULD_BLOCK = 19,     /* it would have to wait, and wasn't to */
    ZDOS_ERROR_BROKEN_PIPE = 20,     /* writing with nobody left to read */
    ZDOS_ERROR_NO_CHILD = 21,        /* no task of this one's to wait for */
    ZDOS_ERROR_NETWORK_DOWN = 22,    /* no network: NETWORK=false, or no card */
    ZDOS_ERROR_IN_PROGRESS = 23,     /* connecting, without waiting for it */
    ZDOS_ERROR_ALREADY = 24,         /* a connect is already under way */
    ZDOS_ERROR_ADDRESS_IN_USE = 25,
    ZDOS_ERROR_HOST_UNREACHABLE = 26,
    ZDOS_ERROR_IS_CONNECTED = 27,
    ZDOS_ERROR_NOT_CONNECTED = 28,
    ZDOS_ERROR_CONNECTION_REFUSED = 29,
    ZDOS_ERROR_CONNECTION_RESET = 30,
    ZDOS_ERROR_CONNECTION_ABORTED = 31,
    ZDOS_ERROR_MESSAGE_TOO_LONG = 32,
    ZDOS_ERROR_HOST_NOT_FOUND = 33,
    ZDOS_ERROR_NOT_A_SOCKET = 34,
} zdos_error;

#define ZDOS_ATTR_READ_ONLY 0x01
#define ZDOS_ATTR_HIDDEN 0x02
#define ZDOS_ATTR_SYSTEM 0x04
#define ZDOS_ATTR_ARCHIVE 0x20

/* zdos_drive_info's file_system: abi.zig's FileSystem */
enum {
    ZDOS_FS_UNKNOWN = 0,
    ZDOS_FS_FAT12 = 1,
    ZDOS_FS_FAT16 = 2,
    ZDOS_FS_FAT32 = 3,
    ZDOS_FS_MINIX3 = 4,
    ZDOS_FS_EXT2 = 5,
    ZDOS_FS_EXT3 = 6,
    ZDOS_FS_EXT4 = 7,
    ZDOS_FS_ZFS = 8,
    ZDOS_FS_NTFS = 9,
    ZDOS_FS_EXFAT = 10,
};

typedef struct {
    uint8_t os_version[4]; /* ZDOS's: 0, 2, 0, 0 is 0.2.0.0 */
    uint8_t pad0[4];
    uint64_t total_memory;
    uint64_t free_memory;
    uint64_t largest_free;
    uint32_t cpu_mhz;
    uint8_t cpu_name_len;
    uint8_t pad[3];
    char cpu_name[128];
} zdos_system_info;

typedef struct {
    uint64_t size, free;
    uint32_t serial;
    uint8_t letter;
    bool boot;
    bool system;
    bool hidden;
    bool has_serial;
    uint8_t file_system;
    uint8_t label_len;
    char label[64];
    bool floppy;
    bool ready;
    /* A partition no driver reads (no letter, not ready): file_system and
       size say what it seems to hold */
    bool unreadable;
    bool removable; /* a USB stick, a card reader ... (UEFI); not ready: no disk */
    uint32_t block_size; /* bytes per cluster or block; 0 if unknown */
} zdos_drive_info;

typedef struct {
    uint32_t disk;
    uint64_t start;
    uint64_t sectors;
} zdos_disk_location;

typedef struct {
    uint64_t sectors;
    uint32_t sector_size;
    bool removable;
    bool read_only;
} zdos_disk_info;

typedef struct {
    uint32_t col, row;
} zdos_pos;

enum {
    ZDOS_BLACK, ZDOS_BLUE, ZDOS_GREEN, ZDOS_CYAN, ZDOS_RED, ZDOS_MAGENTA, ZDOS_BROWN, ZDOS_LIGHT_GRAY,
    ZDOS_DARK_GRAY, ZDOS_LIGHT_BLUE, ZDOS_LIGHT_GREEN, ZDOS_LIGHT_CYAN, ZDOS_LIGHT_RED,
    ZDOS_LIGHT_MAGENTA, ZDOS_YELLOW, ZDOS_WHITE,
};

typedef struct {
    char name[768];
    uint16_t name_len;
    bool is_dir;
    uint8_t attrs;
    uint64_t size;
    zdos_time modified;
    zdos_time created;
    zdos_time accessed;
} zdos_dir_entry;

/* files->permissions: type and permission bits (S_IFMT, 07777),
   owner and group. unix false: the file system has none (FAT);
   made up from the read-only attribute, owner and group 0. */
typedef struct {
    uint32_t mode;
    uint32_t uid;
    uint32_t gid;
    bool unix;
    uint8_t pad[3];
} zdos_permissions;

/* files->set_owner: leaves the owner or the group as it is */
#define ZDOS_KEEP_ID 0xFFFFFFFFu

/* programs->get_ids / set_ids: the user a program runs as (real:
   who started it; uid: whose rights it has; saved: what it may switch back
   to), its group and other groups. In set_ids ZDOS_KEEP_ID leaves a value
   as it is, group_count ZDOS_KEEP_GROUPS the groups. */
typedef struct {
    uint32_t real;
    uint32_t uid;
    uint32_t saved;
    uint32_t gid;
    uint32_t group_count;
    uint32_t groups[16];
} zdos_ids;
#define ZDOS_KEEP_GROUPS 0xFFFFFFFFu

/* files->stat_ex, fstat_ex, read_dir_ex: stat's information and
   what Unix file systems add. Set size to sizeof(zdos_stat_ex) (and
   flags to 0); the kernel fills that many bytes at most and sets
   size to how many it filled. New fields go only at the end.
   Times have year 0 where the file system keeps none; changed is
   the inode's last change (POSIX st_ctime). */
typedef struct {
    uint32_t size;
    uint32_t valid; /* ZDOS_STAT_* bits: the fields the file system has */
    uint32_t flags;
    uint32_t attrs; /* ZDOS_ATTR_* */
    uint32_t mode; /* type and permission bits (S_IFMT, 07777); made up on FAT */
    uint32_t uid;
    uint32_t gid;
    uint32_t links;
    uint32_t drive; /* the drive letter */
    bool is_dir;
    uint8_t pad[3];
    uint64_t file_size;
    uint64_t ino;
    uint64_t blocks; /* 512-byte units in use */
    zdos_time modified;
    zdos_time accessed;
    zdos_time created;
    zdos_time changed;
} zdos_stat_ex;

#define ZDOS_STAT_MODE 0x01u /* the file system's mode, not one made up */
#define ZDOS_STAT_OWNER 0x02u
#define ZDOS_STAT_LINKS 0x04u
#define ZDOS_STAT_INO 0x08u
#define ZDOS_STAT_BLOCKS 0x10u

/* Unused slots after each part of a group, so the part can grow without moving
   the ones after it (abi.Reserved): a new function takes the next one. They
   point to a function that fails with NOT_SUPPORTED and returns 0. Each group
   starts with slots, how many function pointers follow. */
typedef uintptr_t (ZDOS_CALL *zdos_reserved)(void);

/* Text output, keys, standard input and output, the screen (group "console") */
typedef struct {
    uintptr_t slots;

    /* Console and keyboard */
    void (ZDOS_CALL *print)(const char *str, size_t len);
    zdos_key (ZDOS_CALL *read_key)(void);
    bool (ZDOS_CALL *poll_key)(zdos_key *key);
    /* A line editor waits for keys with its line starting at
       this screen row (prompt included; -1: done). Output of
       other tasks then goes there, the line is cleared for it,
       and read_key gives ZDOS_SCAN_REDRAW: print the prompt and
       the line again where the cursor is. Only for the task
       that reads the keyboard. */
    void (ZDOS_CALL *edit_line)(int32_t row);
    zdos_reserved reserved_console[3];

    /* Standard input and output */
    size_t (ZDOS_CALL *read_input)(void *buf, size_t len);
    bool (ZDOS_CALL *input_redirected)(void);
    bool (ZDOS_CALL *output_redirected)(void);
    /* The error output (stream 2 of system->redirect): the screen unless
       redirected, also while the output is */
    void (ZDOS_CALL *print_error)(const char *str, size_t len);
    bool (ZDOS_CALL *error_redirected)(void);

    /* Screen */
    void (ZDOS_CALL *clear_screen)(void);
    void (ZDOS_CALL *set_cursor)(uint32_t col, uint32_t row);
    zdos_pos (ZDOS_CALL *get_cursor)(void);
    zdos_pos (ZDOS_CALL *screen_size)(void);
    void (ZDOS_CALL *set_color)(uint8_t fg, uint8_t bg);
    void (ZDOS_CALL *show_cursor)(bool visible);
    zdos_reserved reserved_screen[4];
} zdos_console_api;

/* The heap (group "memory") */
typedef struct {
    uintptr_t slots;

    /* Memory */
    void *(ZDOS_CALL *alloc)(size_t size);
    void (ZDOS_CALL *free)(void *ptr);
    zdos_reserved reserved_memory[4];
} zdos_memory_api;

/* For files->poll: a handle (or ZDOS_POLL_STDIN: the standard input, the
   keyboard if it isn't redirected), the events wanted, and those that
   happened (the POSIX POLLIN ... values) */
typedef struct {
    int32_t handle;
    uint16_t events;
    uint16_t revents;
} zdos_poll_fd;

#define ZDOS_POLL_STDIN (-2)
#define ZDOS_POLLIN 0x001
#define ZDOS_POLLOUT 0x004
#define ZDOS_POLLERR 0x008
#define ZDOS_POLLHUP 0x010
#define ZDOS_POLLNVAL 0x020

/* files->queue_events: a change to a queue's watch of a handle.
   Edge (ZDOS_QUEUE_EDGE): an event each time the handle's object changes,
   and once at add and modify; else while it holds. ONCE: reported once, then
   off until modified. ERR and HUP come unasked. */
typedef struct {
    int32_t handle;
    uint32_t op; /* ZDOS_QUEUE_ADD ... */
    uint32_t events; /* ZDOS_QUEUE_IN ... */
    uint32_t pad;
    uint64_t data; /* given back with its events */
} zdos_queue_change;

typedef struct {
    uint32_t events; /* those that hold */
    uint32_t pad;
    uint64_t data;
} zdos_queue_event;

#define ZDOS_QUEUE_ADD 1
#define ZDOS_QUEUE_MODIFY 2
#define ZDOS_QUEUE_DELETE 3
/* Linux's epoll bit values */
#define ZDOS_QUEUE_IN 0x001u
#define ZDOS_QUEUE_OUT 0x004u
#define ZDOS_QUEUE_ERR 0x008u
#define ZDOS_QUEUE_HUP 0x010u
#define ZDOS_QUEUE_READ_HUP 0x2000u /* the peer sends no more */
#define ZDOS_QUEUE_ONCE (1u << 30)
#define ZDOS_QUEUE_EDGE (1u << 31)

/* threads->counter_create */
#define ZDOS_COUNTER_SEMAPHORE 1u
#define ZDOS_COUNTER_NONBLOCKING 2u

/* Files, folders, copying, moving and deleting (group "files") */
typedef struct {
    uintptr_t slots;

    /* Files */
    int32_t (ZDOS_CALL *open)(const char *path, size_t len, zdos_open_mode mode);
    void (ZDOS_CALL *close)(int32_t handle);
    int64_t (ZDOS_CALL *read)(int32_t handle, void *buf, size_t len);
    int64_t (ZDOS_CALL *write)(int32_t handle, const void *buf, size_t len);
    bool (ZDOS_CALL *seek)(int32_t handle, uint64_t pos);
    int64_t (ZDOS_CALL *size)(int32_t handle);
    bool (ZDOS_CALL *set_size)(int32_t handle, uint64_t size);
    bool (ZDOS_CALL *commit)(int32_t handle);
    bool (ZDOS_CALL *delete_file)(const char *path, size_t len);
    bool (ZDOS_CALL *stat)(const char *path, size_t len, zdos_dir_entry *entry);
    bool (ZDOS_CALL *set_attributes)(const char *path, size_t len, uint8_t attrs);
    bool (ZDOS_CALL *set_time)(const char *path, size_t len, const zdos_time *time);
    bool (ZDOS_CALL *permissions)(const char *path, size_t len, zdos_permissions *out);
    /* mode: 07777 at most; without Unix permissions only write bits count */
    bool (ZDOS_CALL *set_mode)(const char *path, size_t len, uint32_t mode);
    /* ZDOS_KEEP_ID leaves one as it is; NOT_SUPPORTED without Unix modes */
    bool (ZDOS_CALL *set_owner)(const char *path, size_t len, uint32_t uid, uint32_t gid);
    bool (ZDOS_CALL *stat_ex)(const char *path, size_t len, zdos_stat_ex *info);
    bool (ZDOS_CALL *fstat_ex)(int32_t handle, zdos_stat_ex *info); /* a pipe: S_IFIFO, its size */
    /* A pipe between tasks: handles[0] reads, handles[1] writes.
       Reading waits for data while a writer is left (0: the end); writing
       waits while 64 KiB are unread, and with no reader left fails
       (BROKEN_PIPE, and SIGPIPE). */
    bool (ZDOS_CALL *pipe)(int32_t handles[2]);
    /* Another handle for the same file or pipe (shared position); -1 */
    int32_t (ZDOS_CALL *dup)(int32_t handle);
    /* Which of the handles are ready (zdos_poll_fd.revents), waiting up
       to timeout_ms (-1: no limit, 0: not at all); how many are, -1
       (INTERRUPTED, INVALID_ARGUMENT) */
    int32_t (ZDOS_CALL *poll)(zdos_poll_fd *fds, uint32_t count, int32_t timeout_ms);
    /* set_time of an open file (futimens): the caller must be root, have
       opened it for writing, or own it (Unix file systems) */
    bool (ZDOS_CALL *fset_time)(int32_t handle, const zdos_time *time);
    /* An event queue (Linux's epoll, kept as kqueue keeps its own):
       watches sockets, pipe ends and counters; flags: 0 */
    int32_t (ZDOS_CALL *queue_create)(uint32_t flags);
    /* Applies count changes to the queue's watches, then gives up to max
       events, waiting up to timeout_ms for one (-1: no limit; max 0: no wait):
       how many, or -1 (INTERRUPTED; a change's error:
       INVALID_HANDLE, ALREADY_EXISTS, NOT_FOUND, NOT_SUPPORTED for a handle
       that can't be watched, OUT_OF_MEMORY; the changes before it stay).
       A watch goes when its handle is closed. */
    int32_t (ZDOS_CALL *queue_events)(int32_t queue, const zdos_queue_change *changes, uint32_t count,
                                      zdos_queue_event *out, uint32_t max, int32_t timeout_ms);
    /* length bytes of an open file from offset (0: on to the end, however
       far it grows), as Windows' LockFileEx: the handle's (and its dup
       copies'), gone when they close. flags: ZDOS_LOCK_EXCLUSIVE, else
       shared. Other handles' locks in the way: waits up to timeout_ms (-1:
       no limit; 0: fails at once, WOULD_BLOCK; else TIMED_OUT,
       INTERRUPTED). The handle's own locks never are; the same range again
       converts its lock. Advisory: reads and writes don't look at locks.
       OUT_OF_MEMORY: the table is full. */
    bool (ZDOS_CALL *lock)(int32_t handle, uint64_t offset, uint64_t length, uint32_t flags, int32_t timeout_ms);
    /* The handle's lock of exactly that range goes (INVALID_ARGUMENT: none) */
    bool (ZDOS_CALL *unlock)(int32_t handle, uint64_t offset, uint64_t length);
    zdos_reserved reserved_files[4];

    /* Folders */
    int32_t (ZDOS_CALL *open_dir)(const char *path, size_t len);
    bool (ZDOS_CALL *read_dir)(int32_t handle, zdos_dir_entry *entry);
    bool (ZDOS_CALL *make_dir)(const char *path, size_t len);
    size_t (ZDOS_CALL *get_cwd)(char *buf, size_t len);
    bool (ZDOS_CALL *set_cwd)(const char *path, size_t len);
    size_t (ZDOS_CALL *full_path)(const char *path, size_t len, char *buf, size_t buf_len);
    /* The next entry's name (cut at a character boundary to fit, no
       0) and its information; the name's length, 0 at the end
       (last_error none) or on an error */
    size_t (ZDOS_CALL *read_dir_ex)(int32_t handle, zdos_stat_ex *info, char *name, size_t name_len);
    zdos_reserved reserved_folders[2];

    /* Copying, moving, deleting */
    bool (ZDOS_CALL *copy)(const char *from, size_t from_len, const char *to, size_t to_len);
    bool (ZDOS_CALL *move)(const char *from, size_t from_len, const char *to, size_t to_len);
    bool (ZDOS_CALL *delete_tree)(const char *path, size_t len);
    zdos_reserved reserved_other[1];
} zdos_files_api;

/* Drive letters, their volumes and where they are (group "drives") */
typedef struct {
    uintptr_t slots;

    /* Drives */
    size_t (ZDOS_CALL *letters)(char *buf, size_t len);
    bool (ZDOS_CALL *info)(uint8_t letter, zdos_drive_info *info);
    bool (ZDOS_CALL *set_label)(uint8_t letter, const char *label, size_t len);
    bool (ZDOS_CALL *at)(uint32_t index, zdos_drive_info *info);
    uint32_t (ZDOS_CALL *assign_letters)(void);
    /* The volume's disk (disk_info index), first sector and length.
       PATH_NOT_FOUND (no such drive) or NOT_SUPPORTED (UEFI can't say). */
    bool (ZDOS_CALL *location)(uint8_t letter, zdos_disk_location *loc);
    /* Writes out the drive's disk and lets it go (missing until
       plugged in again). NOT_SUPPORTED (not removable, or the
       edition can't), ACCESS_DENIED (the boot or system disk, or a
       file open for writing). */
    bool (ZDOS_CALL *eject)(uint8_t letter);
    zdos_reserved reserved_drives[3];

    /* A drive's volume by letter (FORMAT X:): its size in sectors, and whole
       sectors from lba relative to its start. drive_changed after raw writes:
       re-read on BIOS; UEFI needs a restart. */
    bool (ZDOS_CALL *sectors)(uint8_t letter, uint64_t *out);
    bool (ZDOS_CALL *read)(uint8_t letter, uint64_t lba, void *buf, size_t len);
    bool (ZDOS_CALL *write)(uint8_t letter, uint64_t lba, const void *data, size_t len);
    /* Before raw writes replace this volume */
    bool (ZDOS_CALL *sync)(uint8_t letter);
    bool (ZDOS_CALL *changed)(uint8_t letter);
    zdos_reserved reserved_volume[1];
} zdos_drives_api;

/* Milliseconds, sleeping, the date and time (group "time") */
typedef struct {
    uintptr_t slots;

    /* Time */
    uint64_t (ZDOS_CALL *millis)(void);
    void (ZDOS_CALL *sleep)(uint32_t ms);
    void (ZDOS_CALL *get)(zdos_time *time);
    bool (ZDOS_CALL *set)(const zdos_time *time);
    /* Sleeps ms milliseconds unless a signal comes first: the milliseconds
       left then (0: all slept) */
    uint32_t (ZDOS_CALL *nap)(uint32_t ms);
    /* Nanoseconds since startup, from the CPU's
       free-running counter (monotonic; it may stand still
       between two calls closer than its step) */
    uint64_t (ZDOS_CALL *nanos)(void);
    /* That counter's step in nanoseconds (1 or more: a 1 MHz counter's 1000) */
    uint64_t (ZDOS_CALL *resolution)(void);
    /* Sleeps until nanos() reaches deadline (metal, BIOS: to the timer's
       precision, microseconds) unless a signal comes first: the nanoseconds
       left then (0: reached) */
    uint64_t (ZDOS_CALL *nap_until)(uint64_t deadline);
    zdos_reserved reserved_time[4];
} zdos_time_api;

/* Running programs, variables, errors, system information (group "programs") */
typedef struct {
    uintptr_t slots;

    /* Programs */
    int32_t (ZDOS_CALL *exec)(const char *path, size_t len, const char *args, size_t args_len);
    int32_t (ZDOS_CALL *run_command)(const char *line, size_t len);
    void (ZDOS_CALL *exit)(uint8_t code) __attribute__((noreturn));
    size_t (ZDOS_CALL *program_path)(char *buf, size_t len);
    void (ZDOS_CALL *set_ctrl_c)(bool as_key);
    void (ZDOS_CALL *system_info)(zdos_system_info *info);
    /* The running program's user and groups; changing them: root may set
       any, others only switch among their real, effective and saved user */
    void (ZDOS_CALL *get_ids)(zdos_ids *out);
    bool (ZDOS_CALL *set_ids)(const zdos_ids *ids);
    /* A library, NAME.ZDL in the program's folder, else \LIBS\NAME.ZDL on
       the boot drive: its export table (it starts with slots, like a group).
       Loaded for this program and freed when it ends; a shared library is
       loaded once per file for all programs. NULL:
       NOT_FOUND, INVALID_ARGUMENT (not a ZDOS library, a bad name),
       OUT_OF_MEMORY, TOO_MANY_OPEN. Programs built with import stubs load
       theirs at start (zdos_crt0.c). */
    const void *(ZDOS_CALL *load_library)(const char *name, size_t len);
    zdos_reserved reserved_programs[2];

    /* Variables */
    int64_t (ZDOS_CALL *get_var)(const char *name, size_t name_len, char *buf, size_t len);
    bool (ZDOS_CALL *set_var)(const char *name, size_t name_len, const char *value, size_t value_len);
    int64_t (ZDOS_CALL *var_at)(uint32_t index, char *buf, size_t len);
    zdos_reserved reserved_variables[2];

    /* Errors */
    uint32_t (ZDOS_CALL *last_error)(void);
    zdos_reserved reserved_errors[1];
} zdos_programs_api;

/* For command interpreters and system tools (group "system") */
typedef struct {
    uintptr_t slots;

    /* Redirection, pipes, Ctrl+C, variable scopes */
    /* stream 0: input, 1: output, 2: error output; handle -1: what the
       program started with, -2: the keyboard / the screen, -3: NUL; for 1
       and 2 also -4 / -5: where the output / error output goes now (2>&1) */
    bool (ZDOS_CALL *redirect)(uint32_t stream, int32_t handle);
    int32_t (ZDOS_CALL *create_pipe)(void);
    void (ZDOS_CALL *catch_ctrl_c)(bool on);
    bool (ZDOS_CALL *ctrl_c_pressed)(bool clear);
    bool (ZDOS_CALL *push_vars)(void);
    void (ZDOS_CALL *pop_vars)(void);
    /* A remote console (SSHD's sessions): a handle whose read gives what its
       tasks print (VT100), whose write types keys; spawn_ex's term starts a
       task on it. -1 (NOT_SUPPORTED without tasks, OUT_OF_MEMORY). */
    int32_t (ZDOS_CALL *term_create)(uint32_t cols, uint32_t rows);
    /* Its size changed: its tasks get SIGWINCH */
    bool (ZDOS_CALL *term_resize)(int32_t handle, uint32_t cols, uint32_t rows);
    zdos_reserved reserved_system[2];

    /* Power and boot */
    /* All file systems synced first; a failure cancels it */
    bool (ZDOS_CALL *shutdown)(void);
    bool (ZDOS_CALL *restart)(void);
    /* UEFI: a boot entry for path (UTF-8, backslashes) on the drive's
       volume, first in the boot order; an existing entry is kept. */
    bool (ZDOS_CALL *add_boot_entry)(uint8_t letter, const char *path, size_t len);
    /* On the boot drive: "\\EFI\\BOOT\\BOOTX64.EFI", BIOS "\\ZIGDOS.SYS".
       The full length (as much as fits is written); 0 with NOT_SUPPORTED
       if the firmware didn't say. */
    size_t (ZDOS_CALL *boot_file)(char *buf, size_t len);
    zdos_reserved reserved_power_boot[2];
} zdos_system_api;

typedef struct {
    uint32_t width;
    uint32_t height;
    bool true_color;
    uint8_t pad[3];
} zdos_screen_info;

typedef struct {
    uint32_t width;
    uint32_t height;
} zdos_screen_size;

/* The picture (256 colors or true color), key presses and releases, the
   mouse (group "gfx") */
typedef struct {
    uintptr_t slots;

    /* Graphics */
    bool (ZDOS_CALL *begin)(uint32_t width, uint32_t height);
    /* As begin, but shown 4:3 as a DOS screen did (320 x 200
       has tall pixels): for ports of DOS programs. UEFI only;
       on BIOS the monitor gives the shape. */
    bool (ZDOS_CALL *begin_dos_aspect)(uint32_t width, uint32_t height);
    void (ZDOS_CALL *palette)(uint32_t first, uint32_t count, const uint8_t *rgb);
    void (ZDOS_CALL *draw)(const uint8_t *pixels);
    void (ZDOS_CALL *end)(void);
    /* The screen pictures are shown on: its size (a picture that size
       is shown 1:1; smaller ones are scaled by a whole number and
       centered) and whether true color works; false without graphics */
    bool (ZDOS_CALL *screen)(zdos_screen_info *info);
    /* A true-color picture: draw_rgb takes width * height pixels 0x00RRGGBB
       (bytes blue, green, red, unused); BIOS: a VESA mode (none without) */
    bool (ZDOS_CALL *begin_rgb)(uint32_t width, uint32_t height);
    void (ZDOS_CALL *draw_rgb)(const uint32_t *pixels);
    /* The screen modes the firmware offers (RESOLUTION= in
       SYSTEM.CFG), smallest first: up to max into sizes; returns how
       many there are (BIOS: 320 x 200, 640 x 480 and the VESA modes) */
    size_t (ZDOS_CALL *modes)(zdos_screen_size *sizes, size_t max);
    /* Tabs: each program in graphics has its own screen; Alt+Tab or Win+Tab
       brings the next to the front (the text console is one too). Only the
       front one is shown and gets keys and the mouse; the others go on, their
       last picture kept. Whether this program's tab is in front (a game may
       pause while it isn't) */
    bool (ZDOS_CALL *visible)(void);
    /* The tab's name (SDL's window title); its program's name until set */
    void (ZDOS_CALL *set_title)(const char *title, size_t len);
    zdos_reserved reserved_gfx[3];

    /* Key presses and releases */
    bool (ZDOS_CALL *key_event)(zdos_key_event *event);
    /* The characters typed since the last call, as UTF-8 into buf (the keyboard
       layout applied, dead keys too): SDL's text input beside key events.
       Its length; 0: none. Once called, the characters are kept for it instead
       of being dropped by key_event. */
    size_t (ZDOS_CALL *text_input)(char *buf, size_t len);
    zdos_reserved reserved_key_events[1];

    /* Mouse */
    bool (ZDOS_CALL *mouse)(zdos_mouse *state);
    zdos_reserved reserved_mouse[2];
} zdos_gfx_api;

/* Raw disks, for the disk tools (CHKDSK, FORMAT, FDISK, SYS) (group "disks") */
typedef struct {
    uintptr_t slots;

    /* Raw disks */
    uint32_t (ZDOS_CALL *count)(void);
    bool (ZDOS_CALL *info)(uint32_t index, zdos_disk_info *info);
    bool (ZDOS_CALL *read)(uint32_t index, uint64_t lba, uint32_t count, void *buf);
    bool (ZDOS_CALL *write)(uint32_t index, uint64_t lba, uint32_t count, const void *data);
    /* After raw writes to disk index: its volumes are mounted again */
    bool (ZDOS_CALL *changed)(uint32_t index);
    /* Before raw writes to this disk */
    bool (ZDOS_CALL *sync)(uint32_t index);
    zdos_reserved reserved_disks[2];
} zdos_disks_api;

/* Keyboard layouts (group "keyb") */
typedef struct {
    uintptr_t slots;

    /* Keyboard layouts: two-letter names; indexes count all available */
    uint32_t (ZDOS_CALL *count)(void);
    /* The length, 0 with INVALID_ARGUMENT past the last */
    size_t (ZDOS_CALL *name)(uint32_t index, char *buf, size_t len);
    uint32_t (ZDOS_CALL *active)(void);
    /* INVALID_ARGUMENT if it isn't loaded */
    bool (ZDOS_CALL *set_active)(uint32_t index);
    /* "EN,ES,FR" in switching order; returns the length written */
    size_t (ZDOS_CALL *loaded)(char *buf, size_t len);
    /* The first becomes active unless the active one stays loaded.
       INVALID_ARGUMENT for an unknown name or an empty list. */
    bool (ZDOS_CALL *set_loaded)(const char *list, size_t len);
    zdos_reserved reserved_keyb[2];
} zdos_keyb_api;

/* A task, as tasks->info describes it */
typedef struct {
    uint32_t id;
    uint32_t parent;        /* the task that started it */
    uint8_t priority;       /* with what it inherits from mutexes */
    uint8_t base_priority;
    uint8_t state;          /* ZDOS_TASK_... */
    uint8_t pad;
    char name[32];          /* its program, 0-terminated */
    uint64_t cpu_ms;        /* milliseconds it has run (0 without task switching) */
} zdos_task_info;

/* tasks->times: since startup, milliseconds in all and those no task ran in */
typedef struct {
    uint64_t total_ms;
    uint64_t idle_ms;
} zdos_cpu_times;

#define ZDOS_TASK_READY 1
#define ZDOS_TASK_RUNNING 2
#define ZDOS_TASK_SLEEPING 3
#define ZDOS_TASK_WAITING 4 /* for another task's end, a mutex, a pipe ... */
#define ZDOS_TASK_ENDED 5
#define ZDOS_TASK_STOPPED 6 /* SIGSTOP */

/* How tasks->spawn_ex starts a program. A stream is a handle of the caller,
   or ZDOS_SAME_STREAM (the caller's current one), ZDOS_NO_STREAM (input
   none, output the screen) or ZDOS_NUL_STREAM. */
typedef struct {
    uint32_t size;      /* sizeof(zdos_spawn_options) */
    int32_t priority;   /* -1: the caller's */
    int32_t input;
    int32_t output;
    int32_t err;        /* the error output */
    int32_t term;       /* a remote console's handle (term_create); other values: the caller's */
} zdos_spawn_options;

#define ZDOS_SAME_STREAM (-1)
#define ZDOS_NO_STREAM (-2)
#define ZDOS_NUL_STREAM (-3)
/* For output and err (and redirect's streams 1 and 2): where the caller's
   output / error output goes now (2>&1, 1>&2) */
#define ZDOS_CALLER_OUTPUT (-4)
#define ZDOS_CALLER_ERROR (-5)

/* A task that ended: id, exit code, and the signal that ended it */
typedef struct {
    uint32_t id;
    uint8_t code;
    uint8_t signal;
    uint16_t pad;
} zdos_task_end;

#define ZDOS_WAIT_NO_HANG 1

/* tasks->set_policy: POSIX's SCHED_FIFO, SCHED_RR numbers */
#define ZDOS_POLICY_FIFO 1
#define ZDOS_POLICY_RR 2

/* Tasks (group "tasks"): metal preemptive, UEFI and BIOS cooperative.
   Priorities 0-31, higher first; mutexes inherit priority and go when
   their program ends. */
/* A deadline task's setting (tasks->deadline), in nanoseconds */
typedef struct {
    uint64_t runtime;
    uint64_t deadline;
    uint64_t period;
} zdos_deadline_setting;

typedef struct {
    uintptr_t slots;

    /* Tasks */
    /* Starts the program (as exec finds it) as a new task; its id, or -1
       (NOT_FOUND, INVALID_ARGUMENT for a batch file, NOT_SUPPORTED,
       OUT_OF_MEMORY, TOO_MANY_OPEN). Standard input none, output the screen. */
    int32_t (ZDOS_CALL *spawn)(const char *path, size_t len, const char *args, size_t args_len);
    /* Until task id, one this task started, has ended: its exit code, or -1
       (INTERRUPTED by a signal, INVALID_ARGUMENT) */
    int32_t (ZDOS_CALL *wait)(uint32_t id);
    /* Whether task id has ended, with its exit code in *code */
    bool (ZDOS_CALL *ended)(uint32_t id, uint8_t *code);
    /* The calling task's id: a POSIX process ID, the first 1, never 0 */
    uint32_t (ZDOS_CALL *id)(void);
    /* Lets tasks of the same priority run */
    void (ZDOS_CALL *yield)(void);
    bool (ZDOS_CALL *set_priority)(uint32_t id, uint32_t priority);
    /* -1 for an unknown task */
    int32_t (ZDOS_CALL *priority)(uint32_t id);
    /* The task at index (0, 1 ...); false past the last */
    bool (ZDOS_CALL *info)(uint32_t index, zdos_task_info *info);
    /* spawn with its standard streams and priority chosen */
    int32_t (ZDOS_CALL *spawn_ex)(const char *path, size_t len, const char *args, size_t args_len, const zdos_spawn_options *options);
    /* A task this one started that has ended, collected into *out: its id;
       0 if none has yet and flags has ZDOS_WAIT_NO_HANG; -1 (NO_CHILD,
       INTERRUPTED) */
    int32_t (ZDOS_CALL *wait_any)(uint32_t flags, zdos_task_end *out);
    /* wait, telling the signal that ended it too */
    bool (ZDOS_CALL *wait_end)(uint32_t id, zdos_task_end *out);
    /* The task that started the calling one (0 for the first) */
    uint32_t (ZDOS_CALL *parent)(void);
    /* Since startup: all milliseconds, and those no task ran in (for TOP) */
    void (ZDOS_CALL *times)(zdos_cpu_times *out);
    /* spawn_ex (options NULL: spawn's) with its own variables instead of
       the global ones: env_len bytes of "NAME=value" entries, each ended by
       a 0 byte (empty ones are skipped). INVALID_ARGUMENT for an entry
       without '=', a bad name or a value too long; OUT_OF_MEMORY for more
       than a scope holds (48). */
    int32_t (ZDOS_CALL *spawn_env)(const char *path, size_t len, const char *args, size_t args_len,
                                   const zdos_spawn_options *options, const char *env, size_t env_len);
    /* A task's scheduling policy (ZDOS_POLICY_*): RR (the default)
       takes turns within a priority every 10 ms, FIFO keeps the CPU
       until it waits or a higher priority comes. Threads and
       programs it starts inherit it; a foreground program's is put
       back at its end. Own tasks only, unless root. */
    bool (ZDOS_CALL *set_policy)(uint32_t id, uint32_t policy);
    /* -1 for an unknown task */
    int32_t (ZDOS_CALL *policy)(uint32_t id);
    zdos_reserved reserved_tasks[2];

    /* Mutexes */
    /* A new mutex's number, or -1 */
    int32_t (ZDOS_CALL *mutex_create)(void);
    /* Waits until it's free; INVALID_ARGUMENT if this task holds it already */
    bool (ZDOS_CALL *mutex_lock)(int32_t mutex);
    /* Only the task holding it may */
    bool (ZDOS_CALL *mutex_unlock)(int32_t mutex);
    void (ZDOS_CALL *mutex_destroy)(int32_t mutex);
    /* lock without waiting: WOULD_BLOCK if another task holds it */
    bool (ZDOS_CALL *mutex_try_lock)(int32_t mutex);
    /* Task id runs earliest deadline first, above every priority (Linux's
       SCHED_DEADLINE): runtime ns each period, done by deadline ns after the
       period's start (period 0: = deadline); would_block if the deadline
       tasks would need over 95% of the cores. set_policy ends it. */
    bool (ZDOS_CALL *set_deadline)(uint32_t id, uint64_t runtime, uint64_t deadline, uint64_t period);
    /* A deadline task's three values (false: not one) */
    bool (ZDOS_CALL *deadline)(uint32_t id, zdos_deadline_setting *out);
    zdos_reserved reserved_mutexes[1];
} zdos_tasks_api;

/* A thread's function: what it returns is what join gets */
typedef uintptr_t (ZDOS_CALL *zdos_thread_entry)(void *arg);

/* Threads of a program (group "threads"), every edition: tasks running in the
   program's memory with their own stack. Mutexes are in group tasks. The
   program's end (exit in any thread) ends its threads. */
typedef struct {
    uintptr_t slots;

    /* Threads */
    /* entry(arg) on a stack of stack_size bytes (0: 256 KiB on PCs),
       at priority (-1: the caller's); its task id, or -1 */
    int32_t (ZDOS_CALL *create)(zdos_thread_entry entry, void *arg, size_t stack_size, int32_t priority);
    /* Until the thread has ended: what entry returned (or exit's value) */
    bool (ZDOS_CALL *join)(uint32_t id, uintptr_t *result);
    /* Nobody joins it: it goes away when it ends */
    bool (ZDOS_CALL *detach)(uint32_t id);
    /* Ends the calling thread */
    void (ZDOS_CALL *exit)(uintptr_t result) __attribute__((noreturn));
    /* A value of the calling thread's own (for thread-local data) */
    void (ZDOS_CALL *set_local)(uintptr_t value);
    uintptr_t (ZDOS_CALL *local)(void);
    /* The thread pointer for thread_local data (zdos_tls.c sets it) */
    void (ZDOS_CALL *set_thread_pointer)(uintptr_t tp);
    /* The stack a thread gets with stack_size 0 (the platform's choice); 0
       from a ZDOS without it */
    size_t (ZDOS_CALL *default_stack_size)(void);
    /* Futexes: waiting on a 32-bit word of the program's memory (4-byte
       aligned) while it holds the expected value, woken by address (Linux's
       FUTEX_WAIT_BITSET and FUTEX_WAKE_BITSET). bits: a waker wakes only
       waiters whose bits share one with its own (0: INVALID_ARGUMENT).
       Waits until a wake, timeout_ms (-1: no limit; TIMED_OUT) or
       a signal (INTERRUPTED); WOULD_BLOCK at once if *addr isn't expected.
       Returns why (also as last_error, which the program's threads share):
       ZDOS_ERROR_NONE when woken, maybe spuriously: check the word. */
    uint32_t (ZDOS_CALL *futex_wait)(const uint32_t *addr, uint32_t expected, int32_t timeout_ms, uint32_t bits);
    /* Wakes up to count waiters of addr, highest priority first (then
       the longest waiting): how many, or -1 (INVALID_ARGUMENT) */
    int32_t (ZDOS_CALL *futex_wake)(const uint32_t *addr, uint32_t count, uint32_t bits);

    /* Conditions */
    int32_t (ZDOS_CALL *cond_create)(void);
    /* Lets the mutex go and waits for signal or
       broadcast (or timeout_ms; -1: none:
       TIMED_OUT), then takes the mutex again. May end
       early (a signal): check what was waited for. */
    bool (ZDOS_CALL *cond_wait)(int32_t cond, int32_t mutex, int32_t timeout_ms);
    /* Wakes the highest waiting thread, or all of them */
    void (ZDOS_CALL *cond_signal)(int32_t cond);
    void (ZDOS_CALL *cond_broadcast)(int32_t cond);
    void (ZDOS_CALL *cond_destroy)(int32_t cond);
    /* For conditions built on futexes (FUTEX_CMP_REQUEUE): if *addr is
       expected, wakes up to count waiters of addr and moves up to move_count
       more to wait on addr2; how many were woken and moved, or -1 (WOULD_BLOCK:
       *addr isn't expected; INVALID_ARGUMENT) */
    int32_t (ZDOS_CALL *futex_requeue)(const uint32_t *addr, uint32_t expected, uint32_t count, const uint32_t *addr2,
                                       uint32_t move_count);
    zdos_reserved reserved_conds[2];

    /* Semaphores */
    int32_t (ZDOS_CALL *sem_create)(uint32_t value);
    /* Waits up to timeout_ms (-1: no limit; 0: WOULD_BLOCK at once) */
    bool (ZDOS_CALL *sem_wait)(int32_t sem, int32_t timeout_ms);
    bool (ZDOS_CALL *sem_post)(int32_t sem);
    /* -1 for an unknown semaphore */
    int32_t (ZDOS_CALL *sem_value)(int32_t sem);
    void (ZDOS_CALL *sem_destroy)(int32_t sem);
    /* A counter as a handle (Linux's eventfd): files->write adds an 8-byte
       value, files->read takes the count as 8 bytes (ZDOS_COUNTER_SEMAPHORE:
       one), waiting while it is 0; writing waits while it would pass 2^64-2.
       ZDOS_COUNTER_NONBLOCKING: WOULD_BLOCK instead of waiting. files->poll
       and event queues see it. */
    int32_t (ZDOS_CALL *counter_create)(uint32_t value, uint32_t flags);
    zdos_reserved reserved_sems[2];
} zdos_threads_api;

/* The program's signal handler: called with each signal it catches */
typedef void (ZDOS_CALL *zdos_signal_entry)(int sig);

/* A timer: nanoseconds to its next signal (0: off), and its period (0: once) */
typedef struct {
    uint64_t left;
    uint64_t interval;
} zdos_timer_setting;

/* Signals (group "signals"), between tasks on every edition, Linux numbers. A
   program has one entry for all signals it catches; the others get the
   default action (see compat/signal.h). A signal ends waits (INTERRUPTED). */
typedef struct {
    uintptr_t slots;

    /* Signals */
    /* To task id; 0 only checks that the task exists */
    bool (ZDOS_CALL *send)(uint32_t task, uint32_t sig);
    /* The program's handler (NULL: none) for the signals in caught (bit n:
       signal n); those in ignored are dropped */
    void (ZDOS_CALL *set_handler)(zdos_signal_entry entry, uint64_t caught, uint64_t ignored);
    /* The calling task's blocked signals: how 0 adds set, 1 removes it, 2
       makes it the set; the set before */
    uint64_t (ZDOS_CALL *mask)(uint32_t how, uint64_t set);
    /* Sent but blocked */
    uint64_t (ZDOS_CALL *pending)(void);
    /* SIGALRM in ms (0: none); what the previous one had left */
    uint64_t (ZDOS_CALL *alarm)(uint64_t ms);
    /* Waits until a signal is handled, with mask blocked meanwhile */
    void (ZDOS_CALL *wait)(uint64_t mask);
    /* The calling task's timer (one per task; alarm's too): signal sig in
       first nanoseconds (0: off), then every interval (0: once). The setting
       before goes to old (if not NULL). False for a bad signal. */
    bool (ZDOS_CALL *set_timer)(uint32_t sig, uint64_t first, uint64_t interval, zdos_timer_setting *old);
    /* Its setting now */
    void (ZDOS_CALL *timer)(zdos_timer_setting *now);
    zdos_reserved reserved_signals[4];
} zdos_signals_api;

/* A job for another core: called there with the argument given to start */
typedef void (ZDOS_CALL *zdos_core_job)(void *arg);

/* More CPU cores for a program's own computing (group "cores"). Jobs share
   the program's memory and must not call ZDOS (on metal with tasks on all
   cores a job is a thread pinned to its core);
   the program allocates what they need first. Its end waits for them. */
typedef struct {
    uintptr_t slots;

    /* Cores */
    /* How many cores, core 0 included (1: no others) */
    uint32_t (ZDOS_CALL *count)(void);
    /* Runs job(arg) on core 1..count-1; INVALID_ARGUMENT for another core,
       ACCESS_DENIED if it is still running a job */
    bool (ZDOS_CALL *start)(uint32_t core, zdos_core_job job, void *arg);
    /* Whether the core is still running a job */
    bool (ZDOS_CALL *busy)(uint32_t core);
    /* Until the core's job has returned */
    void (ZDOS_CALL *wait)(uint32_t core);
    /* The cores task id may run on (bit n: core n;
       all ones: any but those ISOLCPUS= keeps).
       Threads and programs it starts inherit it;
       a foreground program's is put back at its end.
       Own tasks only, unless root; INVALID_ARGUMENT for a
       set without a core running tasks. */
    bool (ZDOS_CALL *set_affinity)(uint32_t id, uint64_t mask);
    /* Its set (all ones: any); 0 for an unknown task */
    uint64_t (ZDOS_CALL *affinity)(uint32_t id);
    zdos_reserved reserved_cores[2];
} zdos_cores_api;

/* An IPv4 address in the order written (192.168.0.1: {192, 168, 0, 1}) and
   a port */
typedef struct {
    uint8_t addr[4];
    uint16_t port;
    uint16_t pad;
} zdos_net_address;

#define ZDOS_NET_STARTED 1    /* NETWORK=true found a card */
#define ZDOS_NET_LINK 2       /* a cable, a link */
#define ZDOS_NET_DHCP 4       /* the address comes from DHCP */
#define ZDOS_NET_DHCP_BOUND 8 /* and it has one */
#define ZDOS_NET_INTERRUPTS 16 /* the card's interrupts arrive (else polled) */
#define ZDOS_NET_OWN_CORE 32   /* the network runs on a CPU core of its own (metal, BIOS) */
#define ZDOS_NET_BRIDGE 64     /* the interface is a bridge of several cards (BRIDGE=) */
#define ZDOS_NET_ROUTING 128   /* packets are forwarded between the interfaces (ROUTING=true) */
#define ZDOS_NET_DEFAULT_ROUTE 256 /* the default route leaves by this interface */
#define ZDOS_NET_NAT 512           /* NAT= masquerades behind it (an outside card) */

typedef struct {
    uint32_t flags; /* ZDOS_NET_ bits; 0: no network */
    uint32_t lease_s;
    uint8_t mac[6];
    uint8_t card_len;
    uint8_t number; /* n of its SYSTEM.CFG setting NETn, from 0 (a bridge: its first card's) */
    uint8_t address[4], netmask[4], gateway[4];
    uint8_t dns[8][4]; /* unused ones 0.0.0.0 */
    uint8_t dhcp_server[4];
    uint64_t rx_frames, tx_frames;
    char card[32]; /* its name, card_len bytes */
} zdos_net_info;

/* A route (gateway 0.0.0.0: the destination is on the link) */
#define ZDOS_ROUTE_LINK 1    /* an interface's own network */
#define ZDOS_ROUTE_STATIC 2  /* ROUTE= in SYSTEM.CFG */
#define ZDOS_ROUTE_DEFAULT 4 /* the default route (the interface's router) */
typedef struct {
    uint8_t destination[4], netmask[4], gateway[4];
    uint8_t interface; /* zdos_net_info.number of the one it leaves by (0xFF: none now) */
    uint8_t flags;     /* ZDOS_ROUTE_ */
    uint16_t pad;
} zdos_net_route;

/* recv_via, send_via: a datagram's interface and local
   address (as IP_PKTINFO). recv: the interface it came in by,
   the address it was sent to (255.255.255.255: a broadcast);
   send: the interface it goes out of (to 255.255.255.255:
   a broadcast on it), its source (0.0.0.0: the interface's).
   card ZDOS_NET_VIA_NONE: the loopback (recv), any (send). */
#define ZDOS_NET_VIA_NONE 0xFF
typedef struct {
    uint8_t card; /* zdos_net_info.number */
    uint8_t pad[3];
    uint8_t local[4];
} zdos_net_via;

enum { ZDOS_PING_REPLY = 1, ZDOS_PING_UNREACHABLE, ZDOS_PING_TTL_EXPIRED };

typedef struct {
    uint8_t result; /* ZDOS_PING_ */
    uint8_t ttl;
    uint16_t bytes;
    uint32_t rtt_ms;
    uint8_t from[4];
} zdos_ping_reply;

typedef struct {
    uint8_t address[4];
    uint8_t mac[6];
    bool is_static;
    uint8_t pad;
} zdos_arp_entry;

typedef struct {
    uint8_t proto; /* 6 TCP, 17 UDP */
    uint8_t state; /* TCP: 0 closed, 1 listen ... 4 established ... 10 time wait */
    uint16_t pad;
    zdos_net_address local, remote;
    uint32_t rx_queued, tx_queued;
} zdos_connection;

#define ZDOS_SOCKET_STREAM 1
#define ZDOS_SOCKET_DATAGRAM 2
#define ZDOS_SOCKET_PEEK 1      /* recv: leave the data there */
#define ZDOS_SOCKET_DONT_WAIT 2 /* as if nonblocking, this once */
#define ZDOS_SOCKET_NO_SIGNAL 4 /* send: no SIGPIPE */
enum {
    ZDOS_SO_NONBLOCKING = 1,
    ZDOS_SO_REUSE_ADDRESS,
    ZDOS_SO_KEEPALIVE,
    ZDOS_SO_BROADCAST,
    ZDOS_SO_NO_DELAY,
    ZDOS_SO_TTL,
    ZDOS_SO_RECV_TIMEOUT, /* ms (0: none) */
    ZDOS_SO_SEND_TIMEOUT,
    ZDOS_SO_PENDING_ERROR, /* get: the error code a failed connect left, once */
    ZDOS_SO_TYPE,          /* get: ZDOS_SOCKET_STREAM / DATAGRAM */
};

/* The network (group "net"): TCP/IP, started at boot with NETWORK=true.
   Without it the calls fail with NETWORK_DOWN. Sockets are handles:
   files->read, write, poll, dup and close work on them too. */
typedef struct {
    uintptr_t slots;

    /* The interface */
    void (ZDOS_CALL *info)(zdos_net_info *out);
    /* DHCP again on the interfaces that use it, waiting up to timeout_ms */
    bool (ZDOS_CALL *renew)(uint32_t timeout_ms);
    bool (ZDOS_CALL *release)(void);
    /* The index-th interface (info: the first) / route; false past the last */
    bool (ZDOS_CALL *interface)(uint32_t index, zdos_net_info *out);
    bool (ZDOS_CALL *route)(uint32_t index, zdos_net_route *out);
    zdos_reserved reserved_interface[3];

    /* Names, ping, ARP, connections */
    /* Written out, localhost, HOSTS.CFG, then DNS (HOST_NOT_FOUND) */
    bool (ZDOS_CALL *resolve)(const char *name, size_t len, uint8_t out[4]);
    bool (ZDOS_CALL *ping)(const uint8_t addr[4], uint16_t seq, uint16_t size, uint8_t ttl, uint32_t timeout_ms, zdos_ping_reply *out);
    bool (ZDOS_CALL *arp_entry)(uint32_t index, zdos_arp_entry *out);
    bool (ZDOS_CALL *arp_add)(const uint8_t addr[4], const uint8_t mac[6]);
    /* NULL: every entry */
    bool (ZDOS_CALL *arp_remove)(const uint8_t *addr);
    bool (ZDOS_CALL *connection)(uint32_t index, zdos_connection *out);
    zdos_reserved reserved_names[1];

    /* Sockets */
    int32_t (ZDOS_CALL *socket)(uint32_t kind);
    bool (ZDOS_CALL *bind)(int32_t handle, const zdos_net_address *addr);
    bool (ZDOS_CALL *listen)(int32_t handle, uint32_t backlog);
    int32_t (ZDOS_CALL *accept)(int32_t handle, zdos_net_address *peer);
    bool (ZDOS_CALL *connect)(int32_t handle, const zdos_net_address *addr);
    int64_t (ZDOS_CALL *send)(int32_t handle, const void *buf, size_t len, uint32_t flags);
    int64_t (ZDOS_CALL *recv)(int32_t handle, void *buf, size_t len, uint32_t flags);
    int64_t (ZDOS_CALL *send_to)(int32_t handle, const void *buf, size_t len, uint32_t flags, const zdos_net_address *to);
    int64_t (ZDOS_CALL *recv_from)(int32_t handle, void *buf, size_t len, uint32_t flags, zdos_net_address *from);
    /* how: 0 receiving, 1 sending, 2 both */
    bool (ZDOS_CALL *shutdown)(int32_t handle, uint32_t how);
    bool (ZDOS_CALL *address)(int32_t handle, bool peer, zdos_net_address *out);
    bool (ZDOS_CALL *set_option)(int32_t handle, uint32_t option, uint32_t value);
    bool (ZDOS_CALL *get_option)(int32_t handle, uint32_t option, uint32_t *out);
    /* Datagram: recv_from, and the interface it came in by */
    int64_t (ZDOS_CALL *recv_via)(int32_t handle, void *buf, size_t len, uint32_t flags, zdos_net_address *from, zdos_net_via *via);
    /* Datagram: send_to out of via's interface, from via's address */
    int64_t (ZDOS_CALL *send_via)(int32_t handle, const void *buf, size_t len, uint32_t flags, const zdos_net_address *to, const zdos_net_via *via);
    zdos_reserved reserved_sockets[4];
} zdos_net_api;

/* Sound (group "sound"): the PC speaker (x86), and samples on a sound card
   (its .SYS driver; without one they fail with NOT_SUPPORTED). */
typedef struct {
    uintptr_t slots;

    /* The PC speaker: a square wave of hz (20-20000) until the next call, 0
       silence (also the program's end); beep: tone for ms, then silence */
    bool (ZDOS_CALL *tone)(uint32_t hz);
    bool (ZDOS_CALL *beep)(uint32_t hz, uint32_t ms);
    /* tone with a short pulse per period: quieter on a real speaker,
       silent in QEMU */
    bool (ZDOS_CALL *soft_tone)(uint32_t hz);
    zdos_reserved reserved_speaker[1];

    /* Samples: rate Hz, channels 1-2, bits 8 (unsigned) or
       16 (signed), interleaved: a handle or -1
       (NOT_SUPPORTED without a card, ACCESS_DENIED while
       another program has it) */
    int32_t (ZDOS_CALL *open)(uint32_t rate, uint32_t channels, uint32_t bits);
    /* Queues samples, waiting while the queue is full: bytes taken or -1 */
    intptr_t (ZDOS_CALL *write)(int32_t handle, const void *data, size_t len);
    /* Bytes queued and not yet heard */
    size_t (ZDOS_CALL *queued)(int32_t handle);
    /* Plays what is queued, then ends (at once if drop) */
    void (ZDOS_CALL *close)(int32_t handle, bool drop);
    /* The card's output volume, 0-100 (volume: -1 without a card) */
    bool (ZDOS_CALL *set_volume)(uint32_t percent);
    int32_t (ZDOS_CALL *volume)(void);
    zdos_reserved reserved_samples[6];
} zdos_sound_api;

/* The groups a program uses (abi.Api), filled by zdos_init when
   the program starts: a group this ZDOS lacks, or has fewer slots
   of, is padded so its missing functions fail with NOT_SUPPORTED. */
typedef struct {
    const zdos_console_api *console;
    const zdos_memory_api *memory;
    const zdos_files_api *files;
    const zdos_drives_api *drives;
    const zdos_time_api *time;
    const zdos_programs_api *programs;
    const zdos_system_api *system;
    const zdos_gfx_api *gfx;
    const zdos_disks_api *disks;
    const zdos_keyb_api *keyb;
    const zdos_cores_api *cores;
    const zdos_tasks_api *tasks;
    const zdos_threads_api *threads;
    const zdos_signals_api *signals;
    const zdos_net_api *net;
    const zdos_sound_api *sound;
} zdos_api;

/* Each group's slot count (abi.zig checks the same): a function put into a
   reserved slot keeps it; if it changes, a reserve wasn't shrunk */
#ifdef __cplusplus
#define ZDOS_ASSERT static_assert
#else
#define ZDOS_ASSERT _Static_assert
#endif
ZDOS_ASSERT(sizeof(zdos_console_api) == (22 + 1) * sizeof(void *), "group console: shrink the reserve the new function went into");
ZDOS_ASSERT(sizeof(zdos_memory_api) == (6 + 1) * sizeof(void *), "group memory: shrink the reserve the new function went into");
ZDOS_ASSERT(sizeof(zdos_files_api) == (42 + 1) * sizeof(void *), "group files: shrink the reserve the new function went into");
ZDOS_ASSERT(sizeof(zdos_drives_api) == (16 + 1) * sizeof(void *), "group drives: shrink the reserve the new function went into");
ZDOS_ASSERT(sizeof(zdos_time_api) == (12 + 1) * sizeof(void *), "group time: shrink the reserve the new function went into");
ZDOS_ASSERT(sizeof(zdos_programs_api) == (18 + 1) * sizeof(void *), "group programs: shrink the reserve the new function went into");
ZDOS_ASSERT(sizeof(zdos_system_api) == (16 + 1) * sizeof(void *), "group system: shrink the reserve the new function went into");
ZDOS_ASSERT(sizeof(zdos_gfx_api) == (20 + 1) * sizeof(void *), "group gfx: shrink the reserve the new function went into");
ZDOS_ASSERT(sizeof(zdos_disks_api) == (8 + 1) * sizeof(void *), "group disks: shrink the reserve the new function went into");
ZDOS_ASSERT(sizeof(zdos_keyb_api) == (8 + 1) * sizeof(void *), "group keyb: shrink the reserve the new function went into");
ZDOS_ASSERT(sizeof(zdos_cores_api) == (8 + 1) * sizeof(void *), "group cores: shrink the reserve the new function went into");
ZDOS_ASSERT(sizeof(zdos_tasks_api) == (26 + 1) * sizeof(void *), "group tasks: shrink the reserve the new function went into");
ZDOS_ASSERT(sizeof(zdos_threads_api) == (26 + 1) * sizeof(void *), "group threads: shrink the reserve the new function went into");
ZDOS_ASSERT(sizeof(zdos_signals_api) == (12 + 1) * sizeof(void *), "group signals: shrink the reserve the new function went into");
ZDOS_ASSERT(sizeof(zdos_net_api) == (34 + 1) * sizeof(void *), "group net: shrink the reserve the new function went into");
ZDOS_ASSERT(sizeof(zdos_sound_api) == (16 + 1) * sizeof(void *), "group sound: shrink the reserve the new function went into");
ZDOS_ASSERT(sizeof(zdos_net_info) == 112 && sizeof(zdos_connection) == 28 && sizeof(zdos_net_route) == 16 && sizeof(zdos_net_via) == 8, "the net records must match the kernel's");
ZDOS_ASSERT(sizeof(zdos_stat_ex) == 96 && offsetof(zdos_stat_ex, file_size) == 40, "zdos_stat_ex must match the kernel's StatEx");
#undef ZDOS_ASSERT

/* What a program's entry function gets: its arguments (text, not
   0-terminated), a function that fails with NOT_SUPPORTED and returns 0, and
   group, which gives the group of that name ("files" ...) or NULL. The start
   of every program: never changes. */
typedef struct {
    uint32_t version;
    const char *args;
    size_t args_len;
    zdos_reserved not_supported;
    const void *(ZDOS_CALL *group)(const char *name, size_t len);
} zdos_start;

/* Defined by the program (declared so it keeps its plain name in C++) */
ZDOS_CALL unsigned char zdos_entry(const zdos_start *start);

/* The groups, set by zdos_init first thing in zdos_entry (zdos_crt0.c does
   it for main): zdos->files->open(...). Weak, so every file that includes
   this header shares them; the copies hold groups padded by zdos_init. */
__attribute__((weak)) const zdos_api *zdos;
__attribute__((weak)) zdos_api zdos_groups;
__attribute__((weak)) zdos_console_api zdos_console_copy;
__attribute__((weak)) zdos_memory_api zdos_memory_copy;
__attribute__((weak)) zdos_files_api zdos_files_copy;
__attribute__((weak)) zdos_drives_api zdos_drives_copy;
__attribute__((weak)) zdos_time_api zdos_time_copy;
__attribute__((weak)) zdos_programs_api zdos_programs_copy;
__attribute__((weak)) zdos_system_api zdos_system_copy;
__attribute__((weak)) zdos_gfx_api zdos_gfx_copy;
__attribute__((weak)) zdos_disks_api zdos_disks_copy;
__attribute__((weak)) zdos_keyb_api zdos_keyb_copy;
__attribute__((weak)) zdos_cores_api zdos_cores_copy;
__attribute__((weak)) zdos_tasks_api zdos_tasks_copy;
__attribute__((weak)) zdos_threads_api zdos_threads_copy;
__attribute__((weak)) zdos_signals_api zdos_signals_copy;
__attribute__((weak)) zdos_net_api zdos_net_copy;
__attribute__((weak)) zdos_sound_api zdos_sound_copy;

static inline size_t zdos_strlen(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    return n;
}

/* The group called name, of want slots. If this ZDOS lacks it or has fewer
   slots, copy is filled instead: what ZDOS has, then not_supported. */
static inline const void *zdos_connect(const zdos_start *start, const char *name, void *copy, size_t size) {
    size_t want = size / sizeof(void *) - 1;
    const uintptr_t *found = (const uintptr_t *)start->group(name, zdos_strlen(name));
    size_t have = found != NULL ? found[0] : 0;
    if (have >= want) return found;
    uintptr_t *words = (uintptr_t *)copy;
    words[0] = want;
    for (size_t i = 1; i <= want; i++) {
        words[i] = i <= have ? found[i] : (uintptr_t)start->not_supported;
    }
    return copy;
}

/* Connects every group and sets zdos: first thing in zdos_entry. A newer
   program on an older ZDOS runs; what it lacks fails with NOT_SUPPORTED. */
static inline void zdos_init(const zdos_start *start) {
    zdos_groups.console = (const zdos_console_api *)zdos_connect(start, "console", &zdos_console_copy, sizeof(zdos_console_copy));
    zdos_groups.memory = (const zdos_memory_api *)zdos_connect(start, "memory", &zdos_memory_copy, sizeof(zdos_memory_copy));
    zdos_groups.files = (const zdos_files_api *)zdos_connect(start, "files", &zdos_files_copy, sizeof(zdos_files_copy));
    zdos_groups.drives = (const zdos_drives_api *)zdos_connect(start, "drives", &zdos_drives_copy, sizeof(zdos_drives_copy));
    zdos_groups.time = (const zdos_time_api *)zdos_connect(start, "time", &zdos_time_copy, sizeof(zdos_time_copy));
    zdos_groups.programs = (const zdos_programs_api *)zdos_connect(start, "programs", &zdos_programs_copy, sizeof(zdos_programs_copy));
    zdos_groups.system = (const zdos_system_api *)zdos_connect(start, "system", &zdos_system_copy, sizeof(zdos_system_copy));
    zdos_groups.gfx = (const zdos_gfx_api *)zdos_connect(start, "gfx", &zdos_gfx_copy, sizeof(zdos_gfx_copy));
    zdos_groups.disks = (const zdos_disks_api *)zdos_connect(start, "disks", &zdos_disks_copy, sizeof(zdos_disks_copy));
    zdos_groups.keyb = (const zdos_keyb_api *)zdos_connect(start, "keyb", &zdos_keyb_copy, sizeof(zdos_keyb_copy));
    zdos_groups.cores = (const zdos_cores_api *)zdos_connect(start, "cores", &zdos_cores_copy, sizeof(zdos_cores_copy));
    zdos_groups.tasks = (const zdos_tasks_api *)zdos_connect(start, "tasks", &zdos_tasks_copy, sizeof(zdos_tasks_copy));
    zdos_groups.threads = (const zdos_threads_api *)zdos_connect(start, "threads", &zdos_threads_copy, sizeof(zdos_threads_copy));
    zdos_groups.signals = (const zdos_signals_api *)zdos_connect(start, "signals", &zdos_signals_copy, sizeof(zdos_signals_copy));
    zdos_groups.net = (const zdos_net_api *)zdos_connect(start, "net", &zdos_net_copy, sizeof(zdos_net_copy));
    zdos_groups.sound = (const zdos_sound_api *)zdos_connect(start, "sound", &zdos_sound_copy, sizeof(zdos_sound_copy));
    zdos = &zdos_groups;
}

static inline void zdos_puts(const char *s) {
    zdos->console->print(s, zdos_strlen(s));
}

/* A library imported through import stubs (sdk/README.md): its name, and
   where its export table goes. The stubs put these in .zdos_imports; the
   linker scripts give their start and end. */
typedef struct {
    const char *name;
    const void **table;
} zdos_import;

extern const zdos_import __zdos_imports_start[];
extern const zdos_import __zdos_imports_end[];

/* The imported libraries loaded (zdos_crt0.c, zdos_libinit.c); false, with
   a message on the error output, if one can't be */
static inline bool zdos_load_imports(void) {
    for (const zdos_import *i = __zdos_imports_start; i < __zdos_imports_end; ++i) {
        size_t n = zdos_strlen(i->name);
        if (n == 0) continue; /* the C runtime's entry (zdos_imports_runtime) */
        const void *t = zdos->programs->load_library(i->name, n);
        if (t == NULL) {
            static const char msg[] = ".ZDL: can't load the library\n";
            zdos->console->print_error(i->name, n);
            zdos->console->print_error(msg, sizeof msg - 1);
            return false;
        }
        *i->table = t;
    }
    return true;
}

/* The C runtime offered to the libraries (an entry with an empty name, from
   the import stubs; zdos_internal.h's zdos_runtime), or NULL */
static inline const void *zdos_imports_runtime(void) {
    for (const zdos_import *i = __zdos_imports_start; i < __zdos_imports_end; ++i) {
        if (i->name[0] == '\0') return (const void *)i->table;
    }
    return NULL;
}

/* zdos_load_imports with the C runtime rt (or none) in threads->local()
   meanwhile, where the libraries' start-up finds it */
static inline bool zdos_load_imports_offering(const void *rt) {
    if (rt == NULL) return zdos_load_imports();
    uintptr_t saved = zdos->threads->local();
    zdos->threads->set_local((uintptr_t)rt);
    bool ok = zdos_load_imports();
    zdos->threads->set_local(saved);
    return ok;
}

static inline int32_t zdos_open(const char *path, zdos_open_mode mode) {
    return zdos->files->open(path, zdos_strlen(path), mode);
}

static inline const char *zdos_error_message(uint32_t code) {
    switch (code) {
        case ZDOS_ERROR_NONE: return "No error";
        case ZDOS_ERROR_NOT_FOUND: return "File not found";
        case ZDOS_ERROR_PATH_NOT_FOUND: return "Path not found";
        case ZDOS_ERROR_ALREADY_EXISTS: return "File already exists";
        case ZDOS_ERROR_ACCESS_DENIED: return "Access denied";
        case ZDOS_ERROR_WRITE_PROTECTED: return "Disk is write-protected";
        case ZDOS_ERROR_DISK_FULL: return "Disk full";
        case ZDOS_ERROR_TOO_MANY_OPEN: return "Too many open files";
        case ZDOS_ERROR_INVALID_HANDLE: return "Invalid handle";
        case ZDOS_ERROR_OUT_OF_MEMORY: return "Not enough memory";
        case ZDOS_ERROR_INVALID_NAME: return "Invalid name";
        case ZDOS_ERROR_DEVICE_ERROR: return "Disk error";
        case ZDOS_ERROR_NOT_SUPPORTED: return "Not supported";
        case ZDOS_ERROR_NOT_A_DIRECTORY: return "Not a directory";
        case ZDOS_ERROR_IS_A_DIRECTORY: return "Is a directory";
        case ZDOS_ERROR_DIR_NOT_EMPTY: return "Directory not empty";
        case ZDOS_ERROR_INVALID_ARGUMENT: return "Invalid argument";
        case ZDOS_ERROR_INTERRUPTED: return "Interrupted";
        case ZDOS_ERROR_TIMED_OUT: return "Timed out";
        case ZDOS_ERROR_WOULD_BLOCK: return "Would block";
        case ZDOS_ERROR_BROKEN_PIPE: return "Broken pipe";
        case ZDOS_ERROR_NO_CHILD: return "No child task";
        case ZDOS_ERROR_NETWORK_DOWN: return "No network";
        case ZDOS_ERROR_IN_PROGRESS: return "Connecting";
        case ZDOS_ERROR_ALREADY: return "Already connecting";
        case ZDOS_ERROR_ADDRESS_IN_USE: return "Address in use";
        case ZDOS_ERROR_HOST_UNREACHABLE: return "Host unreachable";
        case ZDOS_ERROR_IS_CONNECTED: return "Already connected";
        case ZDOS_ERROR_NOT_CONNECTED: return "Not connected";
        case ZDOS_ERROR_CONNECTION_REFUSED: return "Connection refused";
        case ZDOS_ERROR_CONNECTION_RESET: return "Connection reset";
        case ZDOS_ERROR_CONNECTION_ABORTED: return "Connection aborted";
        case ZDOS_ERROR_MESSAGE_TOO_LONG: return "Message too long";
        case ZDOS_ERROR_HOST_NOT_FOUND: return "Host not found";
        case ZDOS_ERROR_NOT_A_SOCKET: return "Not a socket";
        default: return "Unknown error";
    }
}

#ifdef __cplusplus
}
#endif

#endif
