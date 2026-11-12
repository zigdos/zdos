#pragma once
#ifndef _ZDOS_SPAWN_H_
#define _ZDOS_SPAWN_H_

#include <sys/types.h>
#include <signal.h>
#include <sched.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Metal editions only (elsewhere ENOSYS). The child gets only descriptors
   0-2 (as the file actions leave them); envp is ignored; of the attributes
   only the priority counts. */

struct zdos_spawn_action;

typedef struct {
    int count;
    struct zdos_spawn_action *actions;
} posix_spawn_file_actions_t;

typedef struct {
    short flags;
    sigset_t sigmask;
    sigset_t sigdefault;
    int priority; /* -1: the parent's */
} posix_spawnattr_t;

#define POSIX_SPAWN_RESETIDS 0x01
#define POSIX_SPAWN_SETPGROUP 0x02
#define POSIX_SPAWN_SETSIGDEF 0x04
#define POSIX_SPAWN_SETSIGMASK 0x08
#define POSIX_SPAWN_SETSCHEDPARAM 0x10
#define POSIX_SPAWN_SETSCHEDULER 0x20

int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                const posix_spawnattr_t *attr, char *const argv[], char *const envp[]);
int posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *actions,
                 const posix_spawnattr_t *attr, char *const argv[], char *const envp[]);

int posix_spawn_file_actions_init(posix_spawn_file_actions_t *actions);
int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *actions);
int posix_spawn_file_actions_addclose(posix_spawn_file_actions_t *actions, int fd);
int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *actions, int fd, int new_fd);
int posix_spawn_file_actions_addopen(posix_spawn_file_actions_t *actions, int fd, const char *path, int flags, mode_t mode);

int posix_spawnattr_init(posix_spawnattr_t *attr);
int posix_spawnattr_destroy(posix_spawnattr_t *attr);
int posix_spawnattr_setflags(posix_spawnattr_t *attr, short flags);
int posix_spawnattr_getflags(const posix_spawnattr_t *attr, short *flags);
int posix_spawnattr_setsigmask(posix_spawnattr_t *attr, const sigset_t *mask);
int posix_spawnattr_getsigmask(const posix_spawnattr_t *attr, sigset_t *mask);
int posix_spawnattr_setsigdefault(posix_spawnattr_t *attr, const sigset_t *set);
int posix_spawnattr_getsigdefault(const posix_spawnattr_t *attr, sigset_t *set);
int posix_spawnattr_setschedparam(posix_spawnattr_t *attr, const struct sched_param *param);
int posix_spawnattr_getschedparam(const posix_spawnattr_t *attr, struct sched_param *param);
int posix_spawnattr_setpgroup(posix_spawnattr_t *attr, pid_t group);

#ifdef __cplusplus
}
#endif

#endif
