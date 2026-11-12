#pragma once
#ifndef _ZDOS_SYS_SYSMACROS_H_
#define _ZDOS_SYS_SYSMACROS_H_

#define major(dev) ((unsigned)(((dev) >> 8) & 0xfff))
#define minor(dev) ((unsigned)((dev) & 0xff))
#define makedev(ma, mi) ((dev_t)((((ma) & 0xfff) << 8) | ((mi) & 0xff)))

#endif
