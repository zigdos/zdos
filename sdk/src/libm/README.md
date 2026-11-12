# libm

The math functions the compiler's runtime doesn't supply, from NetBSD's
libm as Minix 3 carries it (`lib/libm/src`): Sun's fdlibm with NetBSD's
float versions. The files are unchanged, each with its copyright and license
notice (Sun Microsystems: "Permission to use, copy, modify, and distribute
this software is freely granted, provided that this notice is preserved";
the others BSD-style; collected in `docs/COPYING/NETBSD-LIBM.TXT`). Compiled with `_IEEE_LIBM` (the `w_*.c` wrappers call
the functions without SVID error handling) and `-I` this folder for the
small headers NetBSD's tree would supply (`namespace.h`, `machine/`, `sys/`).

The compiler's runtime has `sin`, `cos`, `tan`, `sqrt`, `exp`, `exp2`, `log`,
`log2`, `log10`, `floor`, `ceil`, `trunc`, `round`, `fmod`, `fma`, `fmin`,
`fmax` and `sincos` (float, double, long double); the internal
`__ieee754_*` versions here of some of them are only used by the others.
The `long double` functions are `../libml`'s (the runtime's `sinl` ... go
through double; `ceill`, `floorl`, `truncl`, `roundl`, `fmodl`, `fmal`,
`fminl`, `fmaxl` and `fabsl` stay the runtime's); `nearbyintl` and `fdiml`
are here.

On x86 (32-bit) `s_rint.c`, `s_rintf.c` and the `lrint` / `llrint` files are left out: they round by adding 2^52, which the x87's 80-bit registers don't round. `../zdos_math_x87.c` has those functions with the FPU's own instructions, as NetBSD's i386 assembly does.
