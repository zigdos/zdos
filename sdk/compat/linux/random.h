#pragma once
#ifndef _ZDOS_LINUX_RANDOM_H_
#define _ZDOS_LINUX_RANDOM_H_

/* What code for Linux takes from here: getrandom's flags (sys/random.h).
   RNDGETENTCNT asks the entropy count: ZDOS's ioctl doesn't know it
   (ENOTTY), and getrandom never runs short */
#include <sys/random.h>
#define RNDGETENTCNT 0x80045200

#endif
