#pragma once
#ifndef _ZDOS_PWD_H_
#define _ZDOS_PWD_H_

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ZDOS's users: \CONF\USERS.CFG on the boot drive (LOGIN,
   ADDUSER), homes \USERS\<name>; the current user is USER
   (root without LOGIN). Users are a convenience, not protection: each has a
   group of the same number. */
struct passwd {
    char *pw_name;
    char *pw_passwd; /* "" */
    uid_t pw_uid;
    gid_t pw_gid;
    char *pw_gecos;
    char *pw_dir;
    char *pw_shell; /* the user's, else COMSPEC */
};

struct passwd *getpwuid(uid_t uid);
int getpwuid_r(uid_t uid, struct passwd *pw, char *buf, size_t size, struct passwd **result);
struct passwd *getpwnam(const char *name);
struct passwd *getpwent(void); /* the users in turn, NULL at the end */
void setpwent(void);
void endpwent(void);

#ifdef __cplusplus
}
#endif

#endif
