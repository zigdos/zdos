#pragma once
#ifndef _ZDOS_GRP_H_
#define _ZDOS_GRP_H_

#include <sys/types.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ZDOS's groups: \\CONF\\GROUPS.CFG on the boot drive, as /etc/group;
   each user also has their own group, numbered as the user (README.md,
   Users). (zdos_unix.c) */
struct group {
    char *gr_name;
    char *gr_passwd;
    gid_t gr_gid;
    char **gr_mem;
};

struct group *getgrnam(const char *name);
struct group *getgrgid(gid_t gid);
/* The same into the caller's buffer: 0, *result NULL if there is none;
   ERANGE if buf is too small */
int getgrnam_r(const char *name, struct group *grp, char *buf, size_t len, struct group **result);
int getgrgid_r(gid_t gid, struct group *grp, char *buf, size_t len, struct group **result);
struct group *getgrent(void);
void setgrent(void);
void endgrent(void);
/* The groups user is in, group first: -1 if more than *count, which then
   says how many */
int getgrouplist(const char *user, gid_t group, gid_t *groups, int *count);
/* The running program's groups to user's (root only) */
int initgroups(const char *user, gid_t group);

#ifdef __cplusplus
}
#endif
#endif
