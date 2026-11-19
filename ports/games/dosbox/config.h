/* DOSBox 0.74-3's configuration for ZDOS, instead of configure's config.h
   (given to every source with -include): the recompiler of each CPU
   (dynamic x86 on x86, dynrec on x86-64, none on ARM64), the FPU; no
   debugger, OpenGL, SDL_net, SDL_sound, screenshots (libpng). C_HEAVY_DEBUG
   and C_SDL_SOUND stay undefined: sources test them with #ifdef */
#define PACKAGE "dosbox"
#include "version-zdos.h" /* VERSION, from configure.ac (build.sh) */

#define C_DEBUG 0
#define C_OPENGL 0
#define C_MODEM 0
#define C_IPX 0
#define C_SSHOT 0
#define C_DIRECTSERIAL 0
#define C_SET_PRIORITY 0
#define C_FPU 1
#define C_HAVE_MPROTECT 1
#define C_ATTRIBUTE_ALWAYS_INLINE 1
#define C_HAS_ATTRIBUTE 1
#define C_HAS_BUILTIN_EXPECT 1

#if defined(__x86_64__)
#define C_TARGETCPU X86_64
#define C_DYNREC 1
#define C_UNALIGNED_MEMORY 1
#elif defined(__i386__)
#define C_TARGETCPU X86
#define C_DYNAMIC_X86 1
#define C_FPU_X86 1
#define C_UNALIGNED_MEMORY 1
#define C_ATTRIBUTE_FASTCALL 1
#else
#define C_TARGETCPU UNKNOWN
#endif

/* environ (unistd.h): DOSBOX_SECTION_PROPERTY variables set config values */
#define ENVIRON_INCLUDED 1
#define ENVIRON_LINKED 1
#define DIRENT_HAS_D_TYPE 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define STDC_HEADERS 1

#if C_ATTRIBUTE_ALWAYS_INLINE
#define INLINE inline __attribute__((always_inline))
#else
#define INLINE inline
#endif

#if C_ATTRIBUTE_FASTCALL
#define DB_FASTCALL __attribute__((fastcall))
#else
#define DB_FASTCALL
#endif

#define GCC_ATTRIBUTE(x) __attribute__((x))
#define GCC_UNLIKELY(x) __builtin_expect((x), 0)
#define GCC_LIKELY(x) __builtin_expect((x), 1)

typedef double Real64;
typedef unsigned char Bit8u;
typedef signed char Bit8s;
typedef unsigned short Bit16u;
typedef signed short Bit16s;
typedef unsigned int Bit32u;
typedef signed int Bit32s;
typedef unsigned long long Bit64u;
typedef signed long long Bit64s;
#if __SIZEOF_POINTER__ == 4
typedef Bit32u Bitu;
typedef Bit32s Bits;
#else
typedef Bit64u Bitu;
typedef Bit64s Bits;
#endif

/* glibc's string.h declares strcasecmp and strncasecmp; here strings.h */
#include <strings.h>
