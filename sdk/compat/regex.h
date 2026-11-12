#pragma once
#ifndef _ZDOS_REGEX_H_
#define _ZDOS_REGEX_H_

#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* POSIX regular expressions with the GNU additions \w \W \s \S \b \B \< \>
   (and \+ \? \| in basic ones). "." takes a whole UTF-8 character; [...]
   sets hold bytes. Matching stops after 10 million steps with the best
   match so far. (zdos_regex.c) */
typedef ssize_t regoff_t;

typedef struct {
    size_t re_nsub; /* the groups ( ) in the pattern */
    void *re_prog;  /* the compiled pattern */
    int re_flags;
} regex_t;

typedef struct {
    regoff_t rm_so; /* start, -1 for a group that took no part */
    regoff_t rm_eo; /* end (one past) */
} regmatch_t;

/* regcomp flags */
#define REG_EXTENDED 1
#define REG_ICASE 2
#define REG_NOSUB 4
#define REG_NEWLINE 8
/* regexec flags */
#define REG_NOTBOL 1
#define REG_NOTEOL 2
#define REG_STARTEND 4 /* the text is pmatch[0].rm_so .. rm_eo */

/* Results */
#define REG_NOMATCH 1
#define REG_BADPAT 2
#define REG_ECOLLATE 3
#define REG_ECTYPE 4
#define REG_EESCAPE 5
#define REG_ESUBREG 6
#define REG_EBRACK 7
#define REG_EPAREN 8
#define REG_EBRACE 9
#define REG_BADBR 10
#define REG_ERANGE 11
#define REG_ESPACE 12
#define REG_BADRPT 13

int regcomp(regex_t *re, const char *pattern, int flags);
int regexec(const regex_t *re, const char *text, size_t nmatch, regmatch_t pmatch[], int flags);
size_t regerror(int code, const regex_t *re, char *buf, size_t size);
void regfree(regex_t *re);

#ifdef __cplusplus
}
#endif

#endif
