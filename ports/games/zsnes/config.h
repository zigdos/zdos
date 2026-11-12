/* ZSNES 2's configuration for ZDOS, instead of its Makefile's -D flags (given
   to every source with -include): the Unix/SDL platform code on SDL 2 (through
   SDL3/SDL.h here), no OpenGL, PNG, PipeWire, libao or debugger */
#define __UNIXSDL__ 1
#define NO_PNG 1
#define NO_DEBUGGER 1
