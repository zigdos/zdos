/* The version for ZDOS: Lua's (lua.h's LUA_VERSION_*_N), expanded
 * before ZDOS_FILE_VERSION's # */
#include "lua.h"
#include "zdos.h"

#define LUA_FILE_VERSION(a, b, c) ZDOS_FILE_VERSION(a, b, c, 0)
#define LUA_FILE_VERSION_OF(a, b, c) LUA_FILE_VERSION(a, b, c)
LUA_FILE_VERSION_OF(LUA_VERSION_MAJOR_N, LUA_VERSION_MINOR_N, LUA_VERSION_RELEASE_N);
