# libml

The `long double` functions of `math.h` in their full precision: 80 bits on
x86 and x86-64, 128 on ARM64. musl's (1.2.5, as Zig bundles it: the `*l.c`
files of `src/math` with their 80- and 128-bit code, MIT,
`docs/COPYING/MUSL.TXT`); where musl's 128-bit version goes through double,
FreeBSD's msun (the files named `e_` `s_` `k_`, from `lib/msun/ld128` and
`src`, and Arm's `tgamma128.c` / `.h` from FreeBSD's contrib;
`docs/COPYING/MSUN.TXT`). The notices are in the files.

`libm.h` is musl's internal header (with `hidden`, `weak_alias`, and
NetBSD's `signgam`); `math_private.h` and `fpmath.h` hold what FreeBSD's
files take from FreeBSD's.

Changed (marked `ZDOS` in the files):
- `powl`: FreeBSD's (fdlibm's method) for the 80-bit format too; musl's
  (Moshier's) was 3 ulps off with `|y log2 x|` at 16, thousands at 10000.
- `exp10l`: `powl` for x with a fraction; `exp2l` (80 bits): FreeBSD's newer
  polynomial; `sqrtl` on x86: the x87's `fsqrt`.
- `__rem_pio2l` on x86: the x87 set to round to double around
  `__rem_pio2_large`, which clang computes in 80 bits otherwise (`sinl` of
  large arguments was 2000 ulps off).
- musl bugs: `remquol` (128 bits) read x's low word for y's; `tgammal`
  (80 bits) had the wrong sign for negative x with a fraction over 0.5 and
  overflowed early.
- FreeBSD's 128-bit `erfl` / `erfcl` / `log1pl` lost bits for tiny x.

`nearbyintl` and `fdiml` are NetBSD's (`../libm`). `ceill`, `floorl`,
`truncl`, `roundl`, `fmodl`, `fmal`, `fminl`, `fmaxl` and `fabsl` are the
compiler's runtime's; its `sinl`, `cosl`, `tanl`, `sincosl`, `expl`, `exp2l`,
`logl`, `log2l`, `log10l` and `sqrtl` go through double and are replaced
here (they are weak there).

Tested against mpmath: within 2.5 ulps (`tgammal` 6); more near
`lgammal`'s zeros below -2 (as musl and FreeBSD are), and in ARM64's
`powl` for results beyond 2^±8192 (up to 24). On ARM64 a division with a
subnormal result gives 0 (Zig 0.14's `__divtf3` flushes), so `erfcl` and
`tgammal` results below 2^-16382 do too.
