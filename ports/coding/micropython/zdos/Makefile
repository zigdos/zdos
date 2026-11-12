include ../../py/mkenv.mk

CROSS = 0

# qstr definitions (must come before including py.mk)
QSTR_DEFS = qstrdefsport.h

# MicroPython feature configurations
MICROPY_ROM_TEXT_COMPRESSION ?= 1

# include py core make definitions
include $(TOP)/py/py.mk

# --- ZDOS SDK ---
# The SDK directory: the copy zigdos_patch.sh installs as SDK/, or any other
# one, e.g. straight from the ZDOS tree: make SDK=/path/to/zigdos/sdk
SDK ?= SDK

# --- ZDOS architecture selection ---
ZDOS_ARCH ?= x86_64
ifeq ($(ZDOS_ARCH),x86)
ZDOS_TARGET = x86-freestanding
ZDOS_ARCH_FLAGS = -mcpu=i686
# The preprocessor (zig cc -E) takes the 32-bit target under two names:
# with several input files it hands the triple to clang, which wants
# "i686"; with one file Zig checks it itself and knows only "x86". The
# empty extra input (-x c /dev/null) makes every call one with several
# files, so "i686" always works, also when a rebuild preprocesses a
# single changed file. (MicroPython's manual "make <file>.pp" debugging
# rule uses -o and so doesn't work for x86 then.)
ZDOS_CPP_TARGET = i686-freestanding
ZDOS_CPP_FLAGS = -x c /dev/null
else ifeq ($(ZDOS_ARCH),x86_64)
ZDOS_TARGET = x86_64-freestanding
ZDOS_ARCH_FLAGS = -mno-red-zone
ZDOS_CPP_TARGET = $(ZDOS_TARGET)
ZDOS_CPP_FLAGS = $(ZDOS_ARCH_FLAGS)
else ifeq ($(ZDOS_ARCH),arm64)
ZDOS_TARGET = aarch64-freestanding
ZDOS_ARCH_FLAGS =
ZDOS_CPP_TARGET = $(ZDOS_TARGET)
ZDOS_CPP_FLAGS =
else
$(error Unsupported ZDOS_ARCH '$(ZDOS_ARCH)'; use x86, x86_64, or arm64)
endif

# --- ZDOS toolchain: the SDK's zdos-cc ---
# It compiles with ZDOS's target, headers and flags, and links with the C
# library and linker script. The preprocessor for MicroPython's qstr scans
# stays plain zig cc -E (see the x86 note above); the SDK's headers come
# with INC. Target and CPU flags live here, NOT in CFLAGS, because CFLAGS
# is also passed to the preprocessor.
CC  = $(SDK)/bin/zdos-cc --arch=$(ZDOS_ARCH)
CPP = zig cc -E -target $(ZDOS_CPP_TARGET) $(ZDOS_CPP_FLAGS) -D__zdos__=1
LD  = $(CC)
SIZE ?= size

INC += -I.
INC += -I$(TOP)
INC += -I$(BUILD)
INC += -I$(SDK)/src
INC += -I$(SDK)/compat

# Give each architecture an independent object tree unless BUILD was set
# explicitly on the make command line or in the environment.
ifeq ($(origin BUILD),file)
BUILD = build-$(ZDOS_ARCH)
endif

# MicroPython's shared clean rule uses CLEAN_EXTRA, so clean all target trees
# even when the current default is only one architecture.
CLEAN_EXTRA += build build-x86 build-x86_64 build-arm64

CFLAGS += -Os -ffreestanding -fno-builtin -DZDOS_NO_FLOAT_T # its libm has float_t / double_t
CFLAGS += $(INC) -Wall -Werror -Wno-unused-function -std=c99 $(COPT)
CFLAGS += -fdata-sections -ffunction-sections
CFLAGS += -DFFCONF_H=\"lib/oofatfs/ffconf.h\"

# ZDOS linker flags (zdos-cc adds the start code, library and linker script)
LDFLAGS = -Wl,--gc-sections

CSUPEROPT = -Os # save some code space

LIBS =

SRC_C = \
    main.c \
    zdos_vfs.c \
    modjson.c \
    modre.c \
    modheapq.c \
    modbinascii.c \
    modhashlib.c \
    modtime.c \
    modrandom.c \
    moddeflate.c \
    modplatform.c \
    timeutils.c \
    uart_core.c \
    shared/readline/readline.c \
    shared/runtime/pyexec.c \
    shared/runtime/stdout_helpers.c \
    shared/runtime/interrupt_char.c \

LIBM_DBL_SRC := $(filter-out thumb_vfp_sqrt.c,$(notdir $(wildcard ../../lib/libm_dbl/*.c)))
SRC_C += $(LIBM_DBL_SRC)
VPATH += ../../lib/libm_dbl
# A few bundled libm files include only <math.h>, where double_t is normally
# supplied by libc. This port supplies that typedef for those files alone.
$(BUILD)/log.o $(BUILD)/rint.o $(BUILD)/scalbn.o: CFLAGS += -DZDOS_LIBM_NEEDS_DOUBLE_T

SRC_QSTR += shared/readline/readline.c shared/runtime/pyexec.c zdos_vfs.c \
    $(addprefix ../../lib/libm_dbl/,$(LIBM_DBL_SRC)) \
    ../../extmod/modjson.c ../../extmod/modre.c ../../extmod/modheapq.c \
    ../../extmod/modbinascii.c ../../extmod/modhashlib.c ../../extmod/modtime.c
SRC_QSTR += ../../extmod/modrandom.c ../../extmod/moddeflate.c ../../extmod/modplatform.c
VPATH += ../../extmod
VPATH += ../../shared/timeutils

# VFS/os and selected freestanding utility modules. Hardware, networking, and
# host-OS extmod modules remain disabled in this port.
PY_O += $(BUILD)/extmod/vfs.o $(BUILD)/extmod/modvfs.o $(BUILD)/extmod/modos.o
SRC_QSTR += ../../extmod/vfs.c ../../extmod/modvfs.c ../../extmod/modos.c

OBJ += $(PY_CORE_O)
OBJ += $(BUILD)/extmod/vfs.o $(BUILD)/extmod/modvfs.o $(BUILD)/extmod/modos.o
OBJ += $(addprefix $(BUILD)/, $(SRC_C:.c=.o))
OBJ += $(addprefix $(BUILD)/, $(SRC_CXX:.cpp=.o))

all: $(BUILD)/micropython.elf

$(BUILD)/_frozen_mpy.c: $(TOP)/tests/assets/frozentest.mpy $(BUILD)/genhdr/qstrdefs.generated.h
	$(ECHO) "MISC freezing bytecode"
	$(Q)$(TOP)/tools/mpy-tool.py -f -q $(BUILD)/genhdr/qstrdefs.preprocessed.h -mlongint-impl=none $< > $@

$(BUILD)/micropython.elf: $(OBJ)
	$(ECHO) "LINK $@"
	$(Q)$(LD) $(LDFLAGS) -o $@ $^ $(LIBS)

include $(TOP)/py/mkrules.mk
