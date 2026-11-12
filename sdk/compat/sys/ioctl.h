#pragma once
#ifndef _ZDOS_SYS_IOCTL_H_
#define _ZDOS_SYS_IOCTL_H_

#ifdef __cplusplus
extern "C" {
#endif

/* TIOCGWINSZ: the screen's size in characters; FIONREAD: bytes of a key
   already read but not yet taken (raw terminal input) */
#define TIOCGWINSZ 0x5413
#define FIONREAD 0x541B

struct winsize {
    unsigned short ws_row;
    unsigned short ws_col;
    unsigned short ws_xpixel;
    unsigned short ws_ypixel;
};

int ioctl(int fd, unsigned long request, ...);

#ifdef __cplusplus
}
#endif

#endif
