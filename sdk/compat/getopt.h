#pragma once
#ifndef _ZDOS_GETOPT_H_
#define _ZDOS_GETOPT_H_

#ifdef __cplusplus
extern "C" {
#endif

/* getopt as POSIX has it; getopt_long permutes arguments as GNU does ('+'
   and '-' at the start of optstring work too). */
extern char *optarg;
extern int optind, opterr, optopt;

#define no_argument 0
#define required_argument 1
#define optional_argument 2

struct option {
    const char *name;
    int has_arg;
    int *flag; /* not NULL: *flag = val, and getopt_long returns 0 */
    int val;
};

int getopt(int argc, char *const argv[], const char *optstring);
int getopt_long(int argc, char *const argv[], const char *optstring, const struct option *longopts, int *longindex);
int getopt_long_only(int argc, char *const argv[], const char *optstring, const struct option *longopts,
                     int *longindex);

#ifdef __cplusplus
}
#endif

#endif
