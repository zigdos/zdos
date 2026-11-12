#pragma once
#ifndef _ZDOS_STDIO_H_
#define _ZDOS_STDIO_H_

#include <stddef.h>
#include <stdarg.h>
#include <sys/types.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef NULL
#define NULL ((void*)0)
#endif

#define EOF (-1)
#define FILENAME_MAX 1028
#define FOPEN_MAX 125
#define BUFSIZ 4096
#define L_tmpnam 32
#define TMP_MAX 10000

#ifndef SEEK_SET
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#endif

#define _IOFBF 0
#define _IOLBF 1
#define _IONBF 2

/* Streams on top of the descriptors of unistd.h. Files are buffered;
   stdout and stderr are not (they print at once, like printf), stdin reads
   the keyboard a line at a time or the redirected input. "t" and "b" in a
   mode do nothing: files are always binary. */
typedef struct zdos_file FILE;
typedef long long fpos_t;

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

FILE *fopen(const char *path, const char *mode); /* r w a, +, b t x */
FILE *freopen(const char *path, const char *mode, FILE *stream);
FILE *fdopen(int fd, const char *mode);
int fclose(FILE *stream);
int fflush(FILE *stream); /* NULL: every stream */
int setvbuf(FILE *stream, char *buf, int mode, size_t size);
void setbuf(FILE *stream, char *buf);
int fileno(FILE *stream);

/* zdos: a stream over a pipe of the program API (create_pipe handle). "r"
   reads it, "w" writes it, from position 0. It owns the handle: fclose
   closes it and frees the pipe. NULL with errno if the mode is wrong or no
   descriptor is free (the handle is closed then too). */
FILE *zdos_pipe_stream(int32_t handle, const char *mode);
/* zdos: the handle of a stream made by zdos_pipe_stream (or a file), or -1 */
int32_t zdos_stream_handle(FILE *stream);

size_t fread(void *ptr, size_t size, size_t count, FILE *stream);
size_t fwrite(const void *ptr, size_t size, size_t count, FILE *stream);
int fgetc(FILE *stream);
int getc(FILE *stream);
int ungetc(int c, FILE *stream); /* one character */
char *fgets(char *s, int size, FILE *stream);
int fputc(int c, FILE *stream);
int putc(int c, FILE *stream);
int fputs(const char *s, FILE *stream);

int fseek(FILE *stream, long offset, int whence);
long ftell(FILE *stream);
int fseeko(FILE *stream, long long offset, int whence);
long long ftello(FILE *stream);
int fgetpos(FILE *stream, fpos_t *pos);
int fsetpos(FILE *stream, const fpos_t *pos);
void rewind(FILE *stream);
int feof(FILE *stream);
int ferror(FILE *stream);
void clearerr(FILE *stream);

/* C99 formats; floating point digits are exact (as
   glibc), precision up to 380. */
int printf(const char *format, ...);
int vprintf(const char *format, va_list ap);
int fprintf(FILE *stream, const char *format, ...);
int vfprintf(FILE *stream, const char *format, va_list ap);
int sprintf(char *str, const char *format, ...);
int vsprintf(char *str, const char *format, va_list ap);
int snprintf(char *str, size_t size, const char *format, ...);
int vsnprintf(char *str, size_t size, const char *format, va_list ap);

/* C99 scan conversions; numbers converted as strtol / strtod do. */
int scanf(const char *format, ...);
int vscanf(const char *format, va_list ap);
int fscanf(FILE *stream, const char *format, ...);
int vfscanf(FILE *stream, const char *format, va_list ap);
int sscanf(const char *str, const char *format, ...);
int vsscanf(const char *str, const char *format, va_list ap);

/* The text in new memory (*out, free it with free); its length, or -1 */
int asprintf(char **out, const char *format, ...);
int vasprintf(char **out, const char *format, va_list ap);

/* POSIX getline / getdelim: *line grows with realloc. */
ssize_t getline(char **line, size_t *size, FILE *stream);
ssize_t getdelim(char **line, size_t *size, int delim, FILE *stream);

/* Streams in memory, as POSIX (fmemopen writing past the end: ENOSPC). */
FILE *fmemopen(void *buf, size_t size, const char *mode);
FILE *open_memstream(char **ptr, size_t *size);

/* "w": the command runs at pclose with what was written (one program
   at a time). pclose returns the command's ERRORLEVEL, or -1. */
FILE *popen(const char *command, const char *mode);
int pclose(FILE *stream);

int putchar(int c);
int puts(const char *s);
int getchar(void);

/* Locking between threads (metal editions): each stream operation
   locks its stream; flockfile holds it across several (recursive).
   The _unlocked forms don't lock. Without threads a lock is only a count. */
void flockfile(FILE *stream);
int ftrylockfile(FILE *stream); /* 0 when locked */
void funlockfile(FILE *stream);
int getc_unlocked(FILE *stream);
int getchar_unlocked(void);
int putc_unlocked(int c, FILE *stream);
int putchar_unlocked(int c);
int fgetc_unlocked(FILE *stream);
int fputc_unlocked(int c, FILE *stream);
size_t fread_unlocked(void *ptr, size_t size, size_t count, FILE *stream);
size_t fwrite_unlocked(const void *ptr, size_t size, size_t count, FILE *stream);
char *fgets_unlocked(char *s, int size, FILE *stream);
int fputs_unlocked(const char *s, FILE *stream);
int fflush_unlocked(FILE *stream);
int feof_unlocked(FILE *stream);
int ferror_unlocked(FILE *stream);
void clearerr_unlocked(FILE *stream);
int fileno_unlocked(FILE *stream);
void perror(const char *s);
int remove(const char *path); /* a file, or an empty directory */
int rename(const char *from, const char *to); /* an existing file at to is replaced */
int renameat(int fromdir, const char *from, int todir, const char *to); /* fcntl.h's AT_FDCWD */

/* Temporary files go in the TEMP variable's folder (ENOENT when TEMP is
   unset or empty), named ZDnnnnnn.TMP. No exclusive create: checking and
   creating a name are two steps. */
/* tmpnam: NULL with errno if TEMP is not usable. */
char *tmpnam(char *s);
/* tmpfile: a program that ends without closing it leaves the file there. */
FILE *tmpfile(void);
/* zdos: an empty file at a free name in TEMP, its path written to
   out (size bytes). 0, or -1 with errno. Used for os.tmpname. */
int zdos_tmpname_create(char *out, size_t size);

#ifdef __cplusplus
}
#endif

#endif
