/* SQLite's file layer (VFS "zdos") on ZDOS's file calls, for a build with
 * SQLITE_OS_OTHER=1. Locks are ZDOS's (files->lock), on os_win.c's bytes.
 * They are each handle's own, so connections in one program and in others
 * see each other's. No WAL (no shared memory), no loadable extensions. */
#include <string.h>
#include <sys/random.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include "zdos.h"

#define ZDOS_MAX_PATHNAME 512

enum { HELD_PENDING = 1, HELD_RESERVED = 2 };

typedef struct {
    sqlite3_file base;
    int32_t handle;
    int level;        /* this file's lock */
    int held;         /* PENDING, RESERVED: HELD_* */
    bool locks;       /* the main database; journals, temporary files have none */
    char *delete_on_close;
} ZdosFile;

static int error_code(int fallback) {
    uint32_t e = zdos->programs->last_error();
    if (e == ZDOS_ERROR_DISK_FULL) return SQLITE_FULL;
    if (e == ZDOS_ERROR_OUT_OF_MEMORY) return SQLITE_IOERR_NOMEM;
    return fallback;
}

static int64_t file_size(ZdosFile *f) {
    return zdos->files->size(f->handle);
}

static int zdos_close(sqlite3_file *id) {
    ZdosFile *f = (ZdosFile *)id;
    zdos->files->close(f->handle);
    if (f->delete_on_close) {
        zdos->files->delete_file(f->delete_on_close, strlen(f->delete_on_close));
        sqlite3_free(f->delete_on_close);
    }
    return SQLITE_OK;
}

static int zdos_read(sqlite3_file *id, void *buf, int amt, sqlite3_int64 off) {
    ZdosFile *f = (ZdosFile *)id;
    int64_t size = file_size(f);
    if (size < 0) return error_code(SQLITE_IOERR_READ);
    int64_t got = 0;
    if (off < size) {
        if (!zdos->files->seek(f->handle, (uint64_t)off)) return error_code(SQLITE_IOERR_READ);
        while (got < amt) {
            int64_t n = zdos->files->read(f->handle, (char *)buf + got, (size_t)(amt - got));
            if (n < 0) return error_code(SQLITE_IOERR_READ);
            if (n == 0) break;
            got += n;
        }
    }
    if (got < amt) {
        /* SQLite wants the rest zeroed */
        memset((char *)buf + got, 0, (size_t)(amt - got));
        return SQLITE_IOERR_SHORT_READ;
    }
    return SQLITE_OK;
}

static int write_all(ZdosFile *f, const void *buf, int64_t amt) {
    int64_t done = 0;
    while (done < amt) {
        int64_t n = zdos->files->write(f->handle, (const char *)buf + done, (size_t)(amt - done));
        if (n <= 0) return error_code(SQLITE_IOERR_WRITE);
        done += n;
    }
    return SQLITE_OK;
}

static int zdos_write(sqlite3_file *id, const void *buf, int amt, sqlite3_int64 off) {
    ZdosFile *f = (ZdosFile *)id;
    int64_t size = file_size(f);
    if (size < 0) return error_code(SQLITE_IOERR_WRITE);
    /* Past the end: zeros up to off (not every file system seeks there): */
    if (off > size) {
        static const char zeros[4096];
        if (!zdos->files->seek(f->handle, (uint64_t)size)) return error_code(SQLITE_IOERR_WRITE);
        while (size < off) {
            int64_t n = off - size < (int64_t)sizeof zeros ? off - size : (int64_t)sizeof zeros;
            int rc = write_all(f, zeros, n);
            if (rc != SQLITE_OK) return rc;
            size += n;
        }
    } else if (!zdos->files->seek(f->handle, (uint64_t)off)) {
        return error_code(SQLITE_IOERR_WRITE);
    }
    return write_all(f, buf, amt);
}

static int zdos_truncate(sqlite3_file *id, sqlite3_int64 size) {
    ZdosFile *f = (ZdosFile *)id;
    return zdos->files->set_size(f->handle, (uint64_t)size) ? SQLITE_OK : error_code(SQLITE_IOERR_TRUNCATE);
}

static int zdos_sync(sqlite3_file *id, int flags) {
    (void)flags;
    ZdosFile *f = (ZdosFile *)id;
    return zdos->files->commit(f->handle) ? SQLITE_OK : error_code(SQLITE_IOERR_FSYNC);
}

static int zdos_file_size(sqlite3_file *id, sqlite3_int64 *out) {
    int64_t size = file_size((ZdosFile *)id);
    if (size < 0) return error_code(SQLITE_IOERR_FSTAT);
    *out = size;
    return SQLITE_OK;
}

/* LOCKS */

/* n bytes at off, failing at once if another handle's are in the way; a ZDOS
 * without locks (NOT_SUPPORTED) grants every one */
static bool take(ZdosFile *f, uint64_t off, uint64_t n, bool exclusive) {
    if (zdos->files->lock(f->handle, off, n, exclusive ? ZDOS_LOCK_EXCLUSIVE : 0, 0)) return true;
    return zdos->programs->last_error() == ZDOS_ERROR_NOT_SUPPORTED;
}

static void drop(ZdosFile *f, uint64_t off, uint64_t n) {
    zdos->files->unlock(f->handle, off, n);
}

static int refused(void) {
    return zdos->programs->last_error() == ZDOS_ERROR_WOULD_BLOCK ? SQLITE_BUSY : SQLITE_IOERR_LOCK;
}

/* SQLite asks for SHARED, RESERVED and EXCLUSIVE (through PENDING), as
 * os_win.c grants them:
 * - SHARED, a shared lock on the readers' range under a shared PENDING
 *   (a writer's PENDING keeps new readers out);
 * - RESERVED, its byte;
 * - EXCLUSIVE, PENDING and then the readers' range converted. */
static int zdos_lock(sqlite3_file *id, int level) {
    ZdosFile *f = (ZdosFile *)id;
    if (f->level >= level) return SQLITE_OK;
    if (!f->locks) {
        f->level = level;
        return SQLITE_OK;
    }
    if (level == SQLITE_LOCK_SHARED) {
        if (!take(f, PENDING_BYTE, 1, false)) return refused();
        bool ok = take(f, SHARED_FIRST, SHARED_SIZE, false);
        int rc = ok ? SQLITE_OK : refused();
        drop(f, PENDING_BYTE, 1);
        if (ok) f->level = SQLITE_LOCK_SHARED;
        return rc;
    }
    if (level == SQLITE_LOCK_RESERVED) {
        if (!take(f, RESERVED_BYTE, 1, true)) return refused();
        f->held |= HELD_RESERVED;
        f->level = SQLITE_LOCK_RESERVED;
        return SQLITE_OK;
    }
    if (!(f->held & HELD_PENDING)) {
        if (!take(f, PENDING_BYTE, 1, true)) return refused();
        f->held |= HELD_PENDING;
        f->level = SQLITE_LOCK_PENDING;
    }
    if (!take(f, SHARED_FIRST, SHARED_SIZE, true)) return refused();
    f->level = SQLITE_LOCK_EXCLUSIVE;
    return SQLITE_OK;
}

static int zdos_unlock(sqlite3_file *id, int level) {
    ZdosFile *f = (ZdosFile *)id;
    if (f->level <= level) return SQLITE_OK;
    if (!f->locks) {
        f->level = level;
        return SQLITE_OK;
    }
    if (f->level == SQLITE_LOCK_EXCLUSIVE && level == SQLITE_LOCK_SHARED) {
        take(f, SHARED_FIRST, SHARED_SIZE, false); /* back to shared: nobody else can be in the way */
    }
    if (f->held & HELD_PENDING) drop(f, PENDING_BYTE, 1);
    if (f->held & HELD_RESERVED) drop(f, RESERVED_BYTE, 1);
    f->held = 0;
    if (level == SQLITE_LOCK_NONE) drop(f, SHARED_FIRST, SHARED_SIZE);
    f->level = level;
    return SQLITE_OK;
}

/* RESERVED held by this file, or by another (its byte can't be taken) */
static int zdos_check_reserved(sqlite3_file *id, int *out) {
    ZdosFile *f = (ZdosFile *)id;
    *out = 0;
    if (!f->locks) return SQLITE_OK;
    if (f->held & HELD_RESERVED) {
        *out = 1;
        return SQLITE_OK;
    }
    if (zdos->files->lock(f->handle, RESERVED_BYTE, 1, ZDOS_LOCK_EXCLUSIVE, 0)) {
        drop(f, RESERVED_BYTE, 1);
        return SQLITE_OK;
    }
    uint32_t e = zdos->programs->last_error();
    if (e == ZDOS_ERROR_WOULD_BLOCK) *out = 1;
    return e == ZDOS_ERROR_WOULD_BLOCK || e == ZDOS_ERROR_NOT_SUPPORTED ? SQLITE_OK : SQLITE_IOERR_CHECKRESERVEDLOCK;
}

static int zdos_file_control(sqlite3_file *id, int op, void *arg) {
    (void)id;
    if (op == SQLITE_FCNTL_VFSNAME) {
        *(char **)arg = sqlite3_mprintf("zdos");
        return SQLITE_OK;
    }
    return SQLITE_NOTFOUND;
}

static int zdos_sector_size(sqlite3_file *id) {
    (void)id;
    return 512;
}

static int zdos_device_characteristics(sqlite3_file *id) {
    (void)id;
    return 0; /* nothing promised: SQLite then journals and syncs fully */
}

static const sqlite3_io_methods zdos_io = {
    1,
    zdos_close,
    zdos_read,
    zdos_write,
    zdos_truncate,
    zdos_sync,
    zdos_file_size,
    zdos_lock,
    zdos_unlock,
    zdos_check_reserved,
    zdos_file_control,
    zdos_sector_size,
    zdos_device_characteristics,
};

static bool exists(const char *path, zdos_dir_entry *e) {
    return zdos->files->stat(path, strlen(path), e);
}

/* A temporary file's name: in TEMP (SYSTEM.CFG), else the current folder */
static int temp_name(char *buf, int len) {
    static unsigned counter;
    char dir[ZDOS_MAX_PATHNAME];
    int64_t n = zdos->programs->get_var("TEMP", 4, dir, sizeof dir - 1);
    if (n <= 0 || n >= (int64_t)sizeof dir) {
        n = 0;
    }
    dir[n] = 0;
    for (int tries = 0; tries < 100; tries++) {
        unsigned r;
        sqlite3_randomness(sizeof r, &r);
        sqlite3_snprintf(len, buf, "%s%sSQL%05X.TMP", dir, n > 0 && dir[n - 1] != '\\' ? "\\" : "",
                         (r ^ ++counter) & 0xFFFFF);
        zdos_dir_entry e;
        if (!exists(buf, &e)) return SQLITE_OK;
    }
    return SQLITE_IOERR_GETTEMPPATH;
}

static int zdos_open_file(sqlite3_vfs *vfs, sqlite3_filename name, sqlite3_file *id, int flags, int *out_flags) {
    (void)vfs;
    ZdosFile *f = (ZdosFile *)id;
    char temp[ZDOS_MAX_PATHNAME];
    memset(f, 0, sizeof *f);
    f->handle = -1;

    const char *path = name;
    if (path == NULL) {
        int rc = temp_name(temp, sizeof temp);
        if (rc != SQLITE_OK) return rc;
        path = temp;
        flags |= SQLITE_OPEN_DELETEONCLOSE;
    }
    size_t len = strlen(path);
    zdos_dir_entry e;
    bool there = exists(path, &e);
    if (there && e.is_dir) return SQLITE_CANTOPEN;
    if (there && (flags & SQLITE_OPEN_EXCLUSIVE)) return SQLITE_CANTOPEN;
    if (!there && !(flags & SQLITE_OPEN_CREATE)) return SQLITE_CANTOPEN;

    /* UPDATE keeps what is there and creates a missing file */
    bool writable = (flags & SQLITE_OPEN_READWRITE) != 0;
    f->handle = zdos->files->open(path, len, writable ? ZDOS_UPDATE : ZDOS_READ);
    if (f->handle < 0 && writable && there) {
        /* Read-only file or drive: SQLite then opens it read-only */
        f->handle = zdos->files->open(path, len, ZDOS_READ);
        flags = (flags & ~(SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) | SQLITE_OPEN_READONLY;
    }
    if (f->handle < 0) return SQLITE_CANTOPEN;

    f->locks = (flags & SQLITE_OPEN_MAIN_DB) != 0;
    if (flags & SQLITE_OPEN_DELETEONCLOSE) {
        f->delete_on_close = sqlite3_mprintf("%s", path);
    }
    if (out_flags) *out_flags = flags;
    f->base.pMethods = &zdos_io;
    return SQLITE_OK;
}

static int zdos_delete(sqlite3_vfs *vfs, const char *path, int sync_dir) {
    (void)vfs;
    (void)sync_dir;
    if (zdos->files->delete_file(path, strlen(path))) return SQLITE_OK;
    uint32_t e = zdos->programs->last_error();
    if (e == ZDOS_ERROR_NOT_FOUND || e == ZDOS_ERROR_PATH_NOT_FOUND) return SQLITE_IOERR_DELETE_NOENT;
    return SQLITE_IOERR_DELETE;
}

static int zdos_access(sqlite3_vfs *vfs, const char *path, int what, int *out) {
    (void)vfs;
    zdos_dir_entry e;
    *out = 0;
    if (!exists(path, &e)) return SQLITE_OK;
    if (what == SQLITE_ACCESS_EXISTS) {
        /* An empty journal counts as none (as os_unix.c) */
        *out = e.is_dir || e.size > 0;
    } else {
        *out = access(path, what == SQLITE_ACCESS_READWRITE ? R_OK | W_OK : R_OK) == 0;
    }
    return SQLITE_OK;
}

static int zdos_full_pathname(sqlite3_vfs *vfs, const char *path, int len, char *out) {
    (void)vfs;
    size_t n = zdos->files->full_path(path, strlen(path), out, (size_t)len);
    if (n == 0 || n >= (size_t)len) return SQLITE_CANTOPEN_FULLPATH;
    out[n] = 0;
    return SQLITE_OK;
}

static void *zdos_dl_open(sqlite3_vfs *vfs, const char *path) {
    (void)vfs;
    (void)path;
    return NULL;
}

static void zdos_dl_error(sqlite3_vfs *vfs, int len, char *out) {
    (void)vfs;
    sqlite3_snprintf(len, out, "ZDOS loads no SQLite extensions");
}

static void (*zdos_dl_sym(sqlite3_vfs *vfs, void *lib, const char *sym))(void) {
    (void)vfs;
    (void)lib;
    (void)sym;
    return NULL;
}

static void zdos_dl_close(sqlite3_vfs *vfs, void *lib) {
    (void)vfs;
    (void)lib;
}

/* getrandom; SQLite's own generator takes it from there */
static int zdos_randomness(sqlite3_vfs *vfs, int len, char *out) {
    (void)vfs;
    return getrandom(out, (size_t)len, 0) == len ? len : 0;
}

static int zdos_sleep(sqlite3_vfs *vfs, int us) {
    (void)vfs;
    usleep((useconds_t)us);
    return us;
}

/* Julian day in milliseconds */
static int zdos_current_time_int64(sqlite3_vfs *vfs, sqlite3_int64 *out) {
    (void)vfs;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    *out = (sqlite3_int64)210866760000000 + (sqlite3_int64)tv.tv_sec * 1000 + tv.tv_usec / 1000;
    return SQLITE_OK;
}

static int zdos_current_time(sqlite3_vfs *vfs, double *out) {
    sqlite3_int64 ms;
    zdos_current_time_int64(vfs, &ms);
    *out = ms / 86400000.0;
    return SQLITE_OK;
}

static int zdos_last_error(sqlite3_vfs *vfs, int len, char *out) {
    (void)vfs;
    (void)len;
    (void)out;
    return 0;
}

static sqlite3_vfs zdos_vfs = {
    2,
    sizeof(ZdosFile),
    ZDOS_MAX_PATHNAME,
    NULL,
    "zdos",
    NULL,
    zdos_open_file,
    zdos_delete,
    zdos_access,
    zdos_full_pathname,
    zdos_dl_open,
    zdos_dl_error,
    zdos_dl_sym,
    zdos_dl_close,
    zdos_randomness,
    zdos_sleep,
    zdos_current_time,
    zdos_last_error,
    zdos_current_time_int64,
    NULL,
    NULL,
    NULL,
};

int sqlite3_os_init(void) {
    return sqlite3_vfs_register(&zdos_vfs, 1);
}

int sqlite3_os_end(void) {
    return SQLITE_OK;
}
