#pragma once
#ifndef _ZDOS_SYS_UTSNAME_H_
#define _ZDOS_SYS_UTSNAME_H_

#ifdef __cplusplus
extern "C" {
#endif

/* sysname "ZDOS", nodename the HOSTNAME variable (default "zdos"), release and
   version the program interface's version, machine x86_64 / i686 / aarch64 */
struct utsname {
    char sysname[65];
    char nodename[65];
    char release[65];
    char version[65];
    char machine[65];
};

int uname(struct utsname *name);

#ifdef __cplusplus
}
#endif

#endif
