/* Abuse's configuration for ZDOS, instead of its configure script's
   (given with -DHAVE_CONFIG_H): no OpenGL, no SDL_mixer (sound-zdos.cpp
   mixes the effects), the version from configure.ac (version.h, made by
   build.sh) */
#include "version.h"
#define PACKAGE "abuse"
#define PACKAGE_NAME "abuse"
#define PACKAGE_TARNAME "abuse"
#define PACKAGE_STRING PACKAGE_NAME " " PACKAGE_VERSION
#define VERSION PACKAGE_VERSION
#define HAVE_RELEASE 1
#define HAVE_ATEXIT 1
#define HAVE_DIRENT_H 1
#define HAVE_FCNTL_H 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_INTTYPES_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_STRSTR 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define STDC_HEADERS 1
#define NO_CHECK 1

/* glibc's headers bring these in on their own */
#include <stdint.h>
#include <sys/types.h>
typedef unsigned short ushort;

/* From a root or a drive (\x, C:\x): not under the data folder */
#define ZDOS_ABSOLUTE(f) \
    ((f)[0] == '/' || (f)[0] == '\\' || ((f)[0] != '\0' && (f)[1] == ':'))
