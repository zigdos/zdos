#pragma once
#ifndef _ZDOS_SYS_WAIT_H_
#define _ZDOS_SYS_WAIT_H_

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The status as on Linux: exit code << 8, or the signal that ended it */
#define WNOHANG 1
#define WUNTRACED 2
#define WEXITSTATUS(s) (((s) >> 8) & 0xff)
#define WTERMSIG(s) ((s) & 0x7f)
#define WSTOPSIG(s) WEXITSTATUS(s)
#define WIFEXITED(s) (WTERMSIG(s) == 0)
#define WIFSIGNALED(s) (WTERMSIG(s) != 0 && WTERMSIG(s) != 0x7f)
#define WIFSTOPPED(s) (((s) & 0xff) == 0x7f)

/* pid > 0: that child; -1 (or 0): any child */
pid_t waitpid(pid_t pid, int *status, int options);
pid_t wait(int *status);

#ifdef __cplusplus
}
#endif

#endif
