/* MicroPython VFS and file streams backed directly by the ZDOS program API. */
#include <string.h>

#include "py/runtime.h"
#include "py/stream.h"
#include "py/mperrno.h"
#include "extmod/vfs.h"
#include "shared/timeutils/timeutils.h"
#include "zdos.h"
#include "zdos_errno.h"

typedef struct {
    mp_obj_base_t base;
} zdos_vfs_obj_t;

typedef struct {
    mp_obj_base_t base;
    int32_t handle;
    uint64_t position;
    bool readable;
    bool writable;
} zdos_file_obj_t;

extern const mp_obj_type_t mp_type_zdos_text_file;
extern const mp_obj_type_t mp_type_zdos_binary_file;

// OSError with the errno for why the ZDOS call just made failed
// ("[Errno 2] ENOENT", "[Errno 13] EACCES" ...)
static MP_NORETURN void raise_zdos_error(void) {
    mp_raise_OSError(zdos_errno_from_last_error());
}

// A ZDOS date as seconds since MicroPython's epoch; year 0 (unknown): or_else
static mp_obj_t zdos_timestamp(const zdos_time *t, mp_obj_t or_else) {
    if (t->year == 0) {
        return or_else != NULL ? or_else : MP_OBJ_NEW_SMALL_INT(0);
    }
    return timeutils_obj_from_timestamp(timeutils_seconds_since_epoch(t->year, t->month, t->day, t->hour, t->minute, t->second));
}

static bool path_from_str(const char *src, size_t n, char *buf, size_t cap) {
    if (n >= cap) {
        mp_raise_OSError(MP_EINVAL);
    }
    for (size_t i = 0; i < n; ++i) {
        buf[i] = src[i] == '/' ? '\\' : src[i];
    }
    buf[n] = '\0';
    return true;
}

static bool path_from_obj(mp_obj_t obj, char *buf, size_t cap, size_t *len) {
    size_t n;
    const char *src = mp_obj_str_get_data(obj, &n);
    if (n >= cap) {
        mp_raise_OSError(MP_EINVAL);
    }
    for (size_t i = 0; i < n; ++i) {
        buf[i] = src[i] == '/' ? '\\' : src[i];
    }
    buf[n] = '\0';
    *len = n;
    return true;
}

static mp_import_stat_t zdos_vfs_import_stat(void *self, const char *path) {
    (void)self;
    if (zdos == NULL || zdos->files->stat == NULL) {
        return MP_IMPORT_STAT_NO_EXIST;
    }
    char zdos_path[MICROPY_ALLOC_PATH_MAX];
    size_t len = strlen(path);
    path_from_str(path, len, zdos_path, sizeof(zdos_path));
    zdos_dir_entry entry;
    if (!zdos->files->stat(zdos_path, len, &entry)) {
        return MP_IMPORT_STAT_NO_EXIST;
    }
    return entry.is_dir ? MP_IMPORT_STAT_DIR : MP_IMPORT_STAT_FILE;
}

static const mp_vfs_proto_t zdos_vfs_proto = {
    .import_stat = zdos_vfs_import_stat,
};

static mp_uint_t zdos_file_read(mp_obj_t self_in, void *buf, mp_uint_t size, int *errcode) {
    zdos_file_obj_t *self = MP_OBJ_TO_PTR(self_in);
    if (self->handle < 0 || !self->readable) {
        *errcode = MP_EBADF;
        return MP_STREAM_ERROR;
    }
    int64_t n = zdos->files->read(self->handle, buf, size);
    if (n < 0) {
        *errcode = zdos_errno_from_last_error();
        return MP_STREAM_ERROR;
    }
    self->position += (uint64_t)n;
    return (mp_uint_t)n;
}

static mp_uint_t zdos_file_write(mp_obj_t self_in, const void *buf, mp_uint_t size, int *errcode) {
    zdos_file_obj_t *self = MP_OBJ_TO_PTR(self_in);
    if (self->handle < 0 || !self->writable) {
        *errcode = MP_EBADF;
        return MP_STREAM_ERROR;
    }
    int64_t n = zdos->files->write(self->handle, buf, size);
    if (n < 0) {
        *errcode = zdos_errno_from_last_error();
        return MP_STREAM_ERROR;
    }
    self->position += (uint64_t)n;
    return (mp_uint_t)n;
}

static mp_uint_t zdos_file_ioctl(mp_obj_t self_in, mp_uint_t request, uintptr_t arg, int *errcode) {
    zdos_file_obj_t *self = MP_OBJ_TO_PTR(self_in);
    if (request == MP_STREAM_FLUSH) {
        // Nothing is buffered here: writes go to ZDOS at once. What is left
        // is the file's size and date, which ZDOS otherwise writes on close.
        if (self->handle >= 0 && self->writable && !zdos->files->commit(self->handle)) {
            *errcode = zdos_errno_from_last_error();
            return MP_STREAM_ERROR;
        }
        return 0;
    }
    if (request == MP_STREAM_CLOSE) {
        if (self->handle >= 0) {
            zdos->files->close(self->handle);
            self->handle = -1;
            // The file's size and date could not be written
            if (zdos->programs->last_error != NULL && zdos->programs->last_error() != ZDOS_ERROR_NONE) {
                *errcode = zdos_errno_from_last_error();
                return MP_STREAM_ERROR;
            }
        }
        return 0;
    }
    if (request == MP_STREAM_SEEK) {
        if (self->handle < 0) {
            *errcode = MP_EBADF;
            return MP_STREAM_ERROR;
        }
        struct mp_stream_seek_t *seek = (struct mp_stream_seek_t *)arg;
        int64_t target;
        if (seek->whence == MP_SEEK_SET) {
            if (seek->offset < 0) {
                *errcode = MP_EINVAL;
                return MP_STREAM_ERROR;
            }
            target = seek->offset;
        } else if (seek->whence == MP_SEEK_CUR) {
            target = (int64_t)self->position + seek->offset;
        } else if (seek->whence == MP_SEEK_END) {
            int64_t end = zdos->files->size(self->handle);
            if (end < 0) {
                *errcode = zdos_errno_from_last_error();
                return MP_STREAM_ERROR;
            }
            target = end + seek->offset;
        } else {
            *errcode = MP_EINVAL;
            return MP_STREAM_ERROR;
        }
        if (target < 0) {
            *errcode = MP_EINVAL;
            return MP_STREAM_ERROR;
        }
        if (!zdos->files->seek(self->handle, (uint64_t)target)) {
            *errcode = zdos_errno_from_last_error();
            return MP_STREAM_ERROR;
        }
        self->position = (uint64_t)target;
        seek->offset = target;
        return 0;
    }
    *errcode = MP_EINVAL;
    return MP_STREAM_ERROR;
}

static const mp_stream_p_t zdos_file_stream = {
    .read = zdos_file_read,
    .write = zdos_file_write,
    .ioctl = zdos_file_ioctl,
    .is_text = 1,
};

static void zdos_file_print(const mp_print_t *print, mp_obj_t self_in, mp_print_kind_t kind) {
    (void)kind;
    zdos_file_obj_t *self = MP_OBJ_TO_PTR(self_in);
    mp_printf(print, "<ZDOSFile handle=%d>", self->handle);
}

// f.truncate([size]): the file's length (default: the current position);
// shorter cuts off the end, longer adds zeros. Returns the new size.
static mp_obj_t zdos_file_truncate(size_t n_args, const mp_obj_t *args) {
    zdos_file_obj_t *self = MP_OBJ_TO_PTR(args[0]);
    if (self->handle < 0 || !self->writable) {
        mp_raise_OSError(MP_EBADF);
    }
    uint64_t size = self->position;
    if (n_args > 1 && args[1] != mp_const_none) {
        mp_int_t n = mp_obj_get_int(args[1]);
        if (n < 0) {
            mp_raise_ValueError(MP_ERROR_TEXT("negative size"));
        }
        size = (uint64_t)n;
    }
    if (zdos->files->set_size == NULL) {
        mp_raise_OSError(MP_EOPNOTSUPP);
    }
    if (!zdos->files->set_size(self->handle, size)) {
        raise_zdos_error();
    }
    return mp_obj_new_int_from_ull(size);
}
static MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN(zdos_file_truncate_obj, 1, 2, zdos_file_truncate);

static mp_obj_t zdos_file_open(mp_obj_t path_in, mp_obj_t mode_in) {
    if (zdos == NULL) {
        mp_raise_OSError(MP_ENODEV);
    }
    char path[MICROPY_ALLOC_PATH_MAX];
    size_t path_len;
    path_from_obj(path_in, path, sizeof(path), &path_len);
    (void)path_len;

    size_t mode_len;
    const char *mode = mp_obj_str_get_data(mode_in, &mode_len);
    bool read = false, write = false, text = true, append = false;
    zdos_open_mode zdos_mode = ZDOS_READ;
    if (mode_len == 0) {
        mp_raise_ValueError(MP_ERROR_TEXT("invalid file mode"));
    }
    for (size_t i = 0; i < mode_len; ++i) {
        switch (mode[i]) {
            case 'r':
                read = true;
                break;
            case 'w':
                write = true;
                zdos_mode = ZDOS_WRITE;
                break;
            case 'a':
                write = true;
                append = true;
                zdos_mode = ZDOS_UPDATE;
                break;
            case '+':
                read = write = true;
                if (zdos_mode == ZDOS_READ) {
                    zdos_mode = ZDOS_UPDATE;
                }
                break;
            case 'b':
                text = false;
                break;
            case 't':
                text = true;
                break;
            default:
                mp_raise_ValueError(MP_ERROR_TEXT("unsupported file mode"));
        }
    }
    if (!read && !write) {
        mp_raise_ValueError(MP_ERROR_TEXT("invalid file mode"));
    }
    if (zdos_mode == ZDOS_READ && write) {
        zdos_mode = ZDOS_UPDATE;
    }
    int32_t handle = zdos->files->open(path, strlen(path), zdos_mode);
    if (handle < 0) {
        raise_zdos_error();
    }
    uint64_t position = 0;
    if (append) {
        int64_t size = zdos->files->size(handle);
        if (size < 0 || !zdos->files->seek(handle, (uint64_t)size)) {
            int e = zdos_errno_from_last_error(); // before close changes it
            zdos->files->close(handle);
            mp_raise_OSError(e);
        }
        position = (uint64_t)size;
    }
    const mp_obj_type_t *type = text ? &mp_type_zdos_text_file : &mp_type_zdos_binary_file;
    zdos_file_obj_t *self = mp_obj_malloc_with_finaliser(zdos_file_obj_t, type);
    self->handle = handle;
    self->position = position;
    self->readable = read;
    self->writable = write;
    return MP_OBJ_FROM_PTR(self);
}

static const mp_rom_map_elem_t zdos_file_locals_table[] = {
    { MP_ROM_QSTR(MP_QSTR_read), MP_ROM_PTR(&mp_stream_read_obj) },
    { MP_ROM_QSTR(MP_QSTR_readinto), MP_ROM_PTR(&mp_stream_readinto_obj) },
    { MP_ROM_QSTR(MP_QSTR_readline), MP_ROM_PTR(&mp_stream_unbuffered_readline_obj) },
    { MP_ROM_QSTR(MP_QSTR_readlines), MP_ROM_PTR(&mp_stream_unbuffered_readlines_obj) },
    { MP_ROM_QSTR(MP_QSTR_write), MP_ROM_PTR(&mp_stream_write_obj) },
    { MP_ROM_QSTR(MP_QSTR_seek), MP_ROM_PTR(&mp_stream_seek_obj) },
    { MP_ROM_QSTR(MP_QSTR_tell), MP_ROM_PTR(&mp_stream_tell_obj) },
    { MP_ROM_QSTR(MP_QSTR_flush), MP_ROM_PTR(&mp_stream_flush_obj) },
    { MP_ROM_QSTR(MP_QSTR_truncate), MP_ROM_PTR(&zdos_file_truncate_obj) },
    { MP_ROM_QSTR(MP_QSTR_close), MP_ROM_PTR(&mp_stream_close_obj) },
    { MP_ROM_QSTR(MP_QSTR___del__), MP_ROM_PTR(&mp_stream_close_obj) },
    { MP_ROM_QSTR(MP_QSTR___enter__), MP_ROM_PTR(&mp_identity_obj) },
    { MP_ROM_QSTR(MP_QSTR___exit__), MP_ROM_PTR(&mp_stream___exit___obj) },
};
static MP_DEFINE_CONST_DICT(zdos_file_locals, zdos_file_locals_table);

MP_DEFINE_CONST_OBJ_TYPE(
    mp_type_zdos_text_file,
    MP_QSTR_TextIO,
    MP_TYPE_FLAG_ITER_IS_STREAM,
    print, zdos_file_print,
    protocol, &zdos_file_stream,
    locals_dict, &zdos_file_locals
    );

static const mp_stream_p_t zdos_file_binary_stream = {
    .read = zdos_file_read,
    .write = zdos_file_write,
    .ioctl = zdos_file_ioctl,
    .is_text = 0,
};
MP_DEFINE_CONST_OBJ_TYPE(
    mp_type_zdos_binary_file,
    MP_QSTR_FileIO,
    MP_TYPE_FLAG_ITER_IS_STREAM,
    print, zdos_file_print,
    protocol, &zdos_file_binary_stream,
    locals_dict, &zdos_file_locals
    );

static mp_obj_t vfs_mount(size_t n_args, const mp_obj_t *args) {
    (void)n_args;
    (void)args;
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN(vfs_mount_obj, 1, 3, vfs_mount);

static mp_obj_t vfs_umount(mp_obj_t self_in) {
    (void)self_in;
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_1(vfs_umount_obj, vfs_umount);

static mp_obj_t vfs_open(mp_obj_t self_in, mp_obj_t path, mp_obj_t mode) {
    (void)self_in;
    return zdos_file_open(path, mode);
}
static MP_DEFINE_CONST_FUN_OBJ_3(vfs_open_obj, vfs_open);

static mp_obj_t vfs_ilistdir(mp_obj_t self_in, mp_obj_t path_in) {
    (void)self_in;
    char path[MICROPY_ALLOC_PATH_MAX];
    size_t path_len;
    path_from_obj(path_in, path, sizeof(path), &path_len);
    int32_t handle = zdos->files->open_dir(path, path_len);
    if (handle < 0) {
        raise_zdos_error();
    }
    mp_obj_t list = mp_obj_new_list(0, NULL);
    zdos_dir_entry entry;
    for (;;) {
        if (!zdos->files->read_dir(handle, &entry)) {
            // false is the end of the listing, unless last_error says otherwise
            if (zdos->programs->last_error != NULL && zdos->programs->last_error() != ZDOS_ERROR_NONE) {
                int e = zdos_errno_from_last_error();
                zdos->files->close(handle);
                mp_raise_OSError(e);
            }
            break;
        }
        mp_obj_t items[4] = {
            mp_obj_new_str(entry.name, entry.name_len),
            MP_OBJ_NEW_SMALL_INT(entry.is_dir ? MP_S_IFDIR : MP_S_IFREG),
            MP_OBJ_NEW_SMALL_INT(0),
            mp_obj_new_int_from_uint(entry.size),
        };
        mp_obj_list_append(list, mp_obj_new_tuple(4, items));
    }
    zdos->files->close(handle);
    return mp_getiter(list, NULL);
}
static MP_DEFINE_CONST_FUN_OBJ_2(vfs_ilistdir_obj, vfs_ilistdir);

static mp_obj_t vfs_chdir(mp_obj_t self_in, mp_obj_t path_in) {
    (void)self_in;
    char path[MICROPY_ALLOC_PATH_MAX];
    size_t len;
    path_from_obj(path_in, path, sizeof(path), &len);
    if (!zdos->files->set_cwd(path, len)) {
        raise_zdos_error();
    }
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_2(vfs_chdir_obj, vfs_chdir);

static mp_obj_t vfs_getcwd(mp_obj_t self_in) {
    (void)self_in;
    char cwd[MICROPY_ALLOC_PATH_MAX];
    size_t len = zdos->files->get_cwd(cwd, sizeof(cwd));
    if (len == 0) {
        raise_zdos_error();
    }
    if (len >= sizeof(cwd)) {
        mp_raise_OSError(MP_EIO);
    }
    // ZDOS returns "C:\\path"; the root-mounted VFS shows it as "/C:/path",
    // which ZDOS accepts back (so chdir to it works across drives)
    if (len + 1 >= sizeof(cwd)) {
        mp_raise_OSError(MP_EIO);
    }
    memmove(cwd + 1, cwd, len);
    cwd[0] = '/';
    ++len;
    for (size_t i = 0; i < len; ++i) {
        if (cwd[i] == '\\') {
            cwd[i] = '/';
        }
    }
    return mp_obj_new_str(cwd, len);
}
static MP_DEFINE_CONST_FUN_OBJ_1(vfs_getcwd_obj, vfs_getcwd);

static mp_obj_t vfs_stat(mp_obj_t self_in, mp_obj_t path_in) {
    (void)self_in;
    char path[MICROPY_ALLOC_PATH_MAX];
    size_t len;
    path_from_obj(path_in, path, sizeof(path), &len);
    zdos_dir_entry entry;
    if (!zdos->files->stat(path, len, &entry)) {
        raise_zdos_error();
    }
    // st_ctime is the creation time (as on Windows); unknown times are the
    // modification time
    mp_obj_t mtime = zdos_timestamp(&entry.modified, NULL);
    mp_obj_t items[10] = {
        MP_OBJ_NEW_SMALL_INT((entry.is_dir ? MP_S_IFDIR | 0755 : MP_S_IFREG | 0644)),
        MP_OBJ_NEW_SMALL_INT(0), MP_OBJ_NEW_SMALL_INT(0), MP_OBJ_NEW_SMALL_INT(1),
        MP_OBJ_NEW_SMALL_INT(0), MP_OBJ_NEW_SMALL_INT(0),
        mp_obj_new_int_from_uint(entry.size),
        zdos_timestamp(&entry.accessed, mtime), // st_atime
        mtime,                                  // st_mtime
        zdos_timestamp(&entry.created, mtime),  // st_ctime
    };
    return mp_obj_new_tuple(10, items);
}

// os.statvfs: size and free space of the drive the path is on,
// in 512-byte blocks; FAT has no table of files, so the file counts are 0
static mp_obj_t vfs_statvfs(mp_obj_t self_in, mp_obj_t path_in) {
    (void)self_in;
    char path[MICROPY_ALLOC_PATH_MAX];
    size_t len;
    path_from_obj(path_in, path, sizeof(path), &len);
    const char *p = path;
    if (len >= 3 && p[0] == '\\' && p[2] == ':') {
        ++p; // "/C:/..."
    }
    char letter;
    if (p[0] != '\0' && p[1] == ':') {
        letter = p[0];
    } else {
        char cwd[4];
        if (zdos->files->get_cwd(cwd, sizeof(cwd)) == 0) {
            char big[MICROPY_ALLOC_PATH_MAX];
            if (zdos->files->get_cwd(big, sizeof(big)) == 0) {
                raise_zdos_error();
            }
            cwd[0] = big[0];
        }
        letter = cwd[0];
    }
    zdos_drive_info info;
    if (!zdos->drives->info((uint8_t)letter, &info)) {
        raise_zdos_error();
    }
    mp_obj_t items[10] = {
        MP_OBJ_NEW_SMALL_INT(512),                  // f_bsize
        MP_OBJ_NEW_SMALL_INT(512),                  // f_frsize
        mp_obj_new_int_from_ull(info.size / 512),   // f_blocks
        mp_obj_new_int_from_ull(info.free / 512),   // f_bfree
        mp_obj_new_int_from_ull(info.free / 512),   // f_bavail
        MP_OBJ_NEW_SMALL_INT(0),                    // f_files
        MP_OBJ_NEW_SMALL_INT(0),                    // f_ffree
        MP_OBJ_NEW_SMALL_INT(0),                    // f_favail
        MP_OBJ_NEW_SMALL_INT(0),                    // f_flag
        MP_OBJ_NEW_SMALL_INT(768),                  // f_namemax (bytes; FAT's 255 characters)
    };
    return mp_obj_new_tuple(10, items);
}
static MP_DEFINE_CONST_FUN_OBJ_2(vfs_statvfs_obj, vfs_statvfs);
static MP_DEFINE_CONST_FUN_OBJ_2(vfs_stat_obj, vfs_stat);

static mp_obj_t vfs_mkdir(mp_obj_t self_in, mp_obj_t path_in) {
    (void)self_in;
    char path[MICROPY_ALLOC_PATH_MAX];
    size_t len;
    path_from_obj(path_in, path, sizeof(path), &len);
    if (!zdos->files->make_dir(path, len)) {
        raise_zdos_error();
    }
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_2(vfs_mkdir_obj, vfs_mkdir);

static mp_obj_t vfs_remove(mp_obj_t self_in, mp_obj_t path_in) {
    (void)self_in;
    char path[MICROPY_ALLOC_PATH_MAX];
    size_t len;
    path_from_obj(path_in, path, sizeof(path), &len);
    if (!zdos->files->delete_file(path, len)) {
        raise_zdos_error();
    }
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_2(vfs_remove_obj, vfs_remove);

static mp_obj_t vfs_rename(mp_obj_t self_in, mp_obj_t old_in, mp_obj_t new_in) {
    (void)self_in;
    char old_path[MICROPY_ALLOC_PATH_MAX], new_path[MICROPY_ALLOC_PATH_MAX];
    size_t old_len, new_len;
    path_from_obj(old_in, old_path, sizeof(old_path), &old_len);
    path_from_obj(new_in, new_path, sizeof(new_path), &new_len);
    if (!zdos->files->move(old_path, old_len, new_path, new_len)) {
        raise_zdos_error();
    }
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_3(vfs_rename_obj, vfs_rename);

static mp_obj_t vfs_rmdir(mp_obj_t self_in, mp_obj_t path_in) {
    (void)self_in;
    char path[MICROPY_ALLOC_PATH_MAX];
    size_t len;
    path_from_obj(path_in, path, sizeof(path), &len);
    // The API deletes folders only with everything in them: check first that
    // this one is empty, as rmdir must not delete more
    int32_t handle = zdos->files->open_dir(path, len);
    if (handle < 0) {
        raise_zdos_error(); // ENOTDIR for a file, ENOENT ...
    }
    zdos_dir_entry entry;
    bool empty = true;
    while (zdos->files->read_dir(handle, &entry)) {
        if (!((entry.name_len == 1 && entry.name[0] == '.') ||
              (entry.name_len == 2 && entry.name[0] == '.' && entry.name[1] == '.'))) {
            empty = false;
            break;
        }
    }
    int read_error = empty && zdos->programs->last_error != NULL && zdos->programs->last_error() != ZDOS_ERROR_NONE
        ? zdos_errno_from_last_error() : 0;
    zdos->files->close(handle);
    if (read_error != 0) {
        mp_raise_OSError(read_error);
    }
    if (!empty) {
        mp_raise_OSError(zdos_errno_from_code(ZDOS_ERROR_DIR_NOT_EMPTY)); // ENOTEMPTY
    }
    if (!zdos->files->delete_tree(path, len)) {
        raise_zdos_error();
    }
    return mp_const_none;
}
static MP_DEFINE_CONST_FUN_OBJ_2(vfs_rmdir_obj, vfs_rmdir);

static const mp_rom_map_elem_t zdos_vfs_locals_table[] = {
    { MP_ROM_QSTR(MP_QSTR_mount), MP_ROM_PTR(&vfs_mount_obj) },
    { MP_ROM_QSTR(MP_QSTR_umount), MP_ROM_PTR(&vfs_umount_obj) },
    { MP_ROM_QSTR(MP_QSTR_open), MP_ROM_PTR(&vfs_open_obj) },
    { MP_ROM_QSTR(MP_QSTR_ilistdir), MP_ROM_PTR(&vfs_ilistdir_obj) },
    { MP_ROM_QSTR(MP_QSTR_chdir), MP_ROM_PTR(&vfs_chdir_obj) },
    { MP_ROM_QSTR(MP_QSTR_getcwd), MP_ROM_PTR(&vfs_getcwd_obj) },
    { MP_ROM_QSTR(MP_QSTR_stat), MP_ROM_PTR(&vfs_stat_obj) },
    { MP_ROM_QSTR(MP_QSTR_mkdir), MP_ROM_PTR(&vfs_mkdir_obj) },
    { MP_ROM_QSTR(MP_QSTR_remove), MP_ROM_PTR(&vfs_remove_obj) },
    { MP_ROM_QSTR(MP_QSTR_rename), MP_ROM_PTR(&vfs_rename_obj) },
    { MP_ROM_QSTR(MP_QSTR_rmdir), MP_ROM_PTR(&vfs_rmdir_obj) },
    { MP_ROM_QSTR(MP_QSTR_statvfs), MP_ROM_PTR(&vfs_statvfs_obj) },
};
static MP_DEFINE_CONST_DICT(zdos_vfs_locals, zdos_vfs_locals_table);

MP_DEFINE_CONST_OBJ_TYPE(
    mp_type_zdos_vfs,
    MP_QSTR_ZDOSVFS,
    MP_TYPE_FLAG_NONE,
    protocol, &zdos_vfs_proto,
    locals_dict, &zdos_vfs_locals
    );

void zdos_vfs_mount_root(void) {
    zdos_vfs_obj_t *self = mp_obj_malloc(zdos_vfs_obj_t, &mp_type_zdos_vfs);
    mp_obj_t args[] = { MP_OBJ_FROM_PTR(self), mp_obj_new_str("/", 1) };
    mp_vfs_mount(MP_ARRAY_SIZE(args), args, (mp_map_t *)&mp_const_empty_map);
    // Make it the current file system without a chdir: mp_vfs_chdir("/")
    // would also move ZDOS's current directory to the root of the drive.
    // Relative paths ("script.py") then go to ZDOS as they are and resolve
    // against the directory MicroPython was started in.
    MP_STATE_VM(vfs_cur) = MP_STATE_VM(vfs_mount_table);
}
