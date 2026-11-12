#pragma once
#ifndef _ZDOS_MALLOC_H_
#define _ZDOS_MALLOC_H_

#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

/* glibc's: aligned blocks (freed with free) and a block's size */
void *memalign(size_t alignment, size_t size);
void *valloc(size_t size);
size_t malloc_usable_size(void *ptr);

#ifdef __cplusplus
}
#endif
#endif
