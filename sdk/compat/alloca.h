#pragma once
#ifndef _ALLOCA_H_
#define _ALLOCA_H_

#include <stddef.h>

#ifndef alloca
#define alloca(size) __builtin_alloca(size)
#endif

#endif
