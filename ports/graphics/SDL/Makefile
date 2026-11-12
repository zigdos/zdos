# SDL2 for ZDOS: libSDL2.a from the prepared tree (build.sh makes it):
#   make -f Makefile TREE=<tree> OBJ=<objects> CC="zdos-cc --arch=..."
TREE ?= tree
OBJ ?= obj
CC ?= zdos-cc
CFLAGS ?= -O2

DIRS = src src/atomic src/audio src/audio/zdos src/audio/disk src/audio/dummy src/cpuinfo \
	src/events src/file src/filesystem/zdos src/haptic src/haptic/dummy src/hidapi \
	src/joystick src/joystick/dummy src/loadso/dummy src/locale src/locale/dummy \
	src/misc src/misc/dummy src/power src/render src/render/software src/sensor \
	src/sensor/dummy src/stdlib src/libm src/thread src/thread/pthread src/timer \
	src/timer/zdos src/video src/video/dummy src/video/yuv2rgb src/video/zdos

SOURCES = $(foreach d,$(DIRS),$(wildcard $(TREE)/$(d)/*.c))
OBJECTS = $(patsubst $(TREE)/%.c,$(OBJ)/%.o,$(SOURCES))

$(OBJ)/libSDL2.a: $(OBJECTS)
	rm -f $@
	zig ar rcs $@ $^

$(OBJ)/%.o: $(TREE)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -I$(TREE)/include -MMD -MP -c $< -o $@

-include $(OBJECTS:.o=.d)
