/* Lua 5.5 settings for ZDOS, -included before onelua.c (see README.md) */
#ifndef LUA_ZDOS_CONF_H
#define LUA_ZDOS_CONF_H

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "zdos.h"
#include "zdos_errno.h"

/* No LUA_USE_POSIX / LINUX / DLOPEN / READLINE: the SDK has some POSIX calls
   (popen, mkstemp, isatty) but not sys/wait.h, sigaction or dlopen, so the
   pieces Lua needs are set here one by one. No dlopen, so no C modules. */
#define LUA_PATH_DEFAULT \
    "./?.lua;./?/init.lua;/LUA/?.lua;/LUA/?/init.lua"
#define LUA_CPATH_DEFAULT ""

/* e set: lua_tmpnam failed (no usable TEMP) */
#define LUA_TMPNAMBUFSIZE 32
#define lua_tmpnam(b,e)  { e = (zdos_tmpname_create((b), LUA_TMPNAMBUFSIZE) != 0); }

/* io.popen: the SDK's popen and pclose (over the program API's pipes).
   pclose returns the command's ERRORLEVEL; errno is cleared when it worked,
   as luaL_execresult expects. */
static int zdos_lua_pclose(FILE *file) {
    int status = pclose(file);
    if (status >= 0) {
        errno = 0;
    }
    return status;
}

#define l_popen(L,c,m)   ((void)(L), popen(c, m))
#define l_pclose(L,file) ((void)(L), zdos_lua_pclose(file))

#endif
