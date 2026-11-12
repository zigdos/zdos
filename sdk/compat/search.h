#pragma once
#ifndef _ZDOS_SEARCH_H_
#define _ZDOS_SEARCH_H_

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Binary search trees, one hash table, linear search (zdos_unix.c) */
typedef enum { preorder, postorder, endorder, leaf } VISIT;
typedef enum { FIND, ENTER } ACTION;
typedef struct entry {
    char *key;
    void *data;
} ENTRY;

void *tsearch(const void *key, void **root, int (*compare)(const void *, const void *));
void *tfind(const void *key, void *const *root, int (*compare)(const void *, const void *));
void *tdelete(const void *key, void **root, int (*compare)(const void *, const void *));
void twalk(const void *root, void (*action)(const void *, VISIT, int));
void tdestroy(void *root, void (*free_node)(void *));
int hcreate(size_t size);
void hdestroy(void);
ENTRY *hsearch(ENTRY item, ACTION action);
void *lfind(const void *key, const void *base, size_t *count, size_t size, int (*compare)(const void *, const void *));
void *lsearch(const void *key, void *base, size_t *count, size_t size, int (*compare)(const void *, const void *));

#ifdef __cplusplus
}
#endif
#endif
