#ifndef ZDOS_ERRNO_MAP_H
#define ZDOS_ERRNO_MAP_H

/* The errno value for ZDOS->last_error(): call it right after the ZDOS call
   that failed (before any other call that can fail). Defined in zdos_fs.c. */
int zdos_errno_from_last_error(void);

/* The errno value for a zdos_error code */
int zdos_errno_from_code(unsigned int code);

#endif
