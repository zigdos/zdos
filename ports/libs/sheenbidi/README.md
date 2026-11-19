# SheenBidi

SheenBidi 3.0.0 as a library: `C:\LIBS\SHNBIDI.ZDL`, a copy per program. It puts mixed left-to-right and right-to-left text (Hebrew, Arabic) in display order by the Unicode Bidirectional Algorithm, with Unicode 17's data. It offers FriBidi's functions, so programs written for FriBidi use it unchanged.

```sh
ports/libs/sheenbidi/build.sh             # all three CPUs
ports/libs/sheenbidi/build.sh x86_64      # one or more: x86, x86_64, arm64
zig build                                 # puts them onto drive C:
```

Sources: SheenBidi, unpacked unchanged into `$ZDOS_PORTS_SRC/SheenBidi` (`../SheenBidi` when that variable is unset; `SHEENBIDI_SRC=...`). Objects: `build/sheenbidi/<arch>/`; the sources are only read. The version for ZDOS is taken from `SBVersion.h`.

## How it is made

- One compile unit: SheenBidi's sources as its own unity build (`SheenBidi.c`, `SB_CONFIG_UNITY`) and `fribidi_sheen.c`, FriBidi's 31 functions on them. Without its scratch memory (`SB_CONFIG_DISABLE_SCRATCH_MEMORY`): that pool is `thread_local`, which a library can't have; `build.sh` stops if thread_local data appears.
- SheenBidi gives the bidi types, the bracket pairs, the mirrors and each paragraph's levels. `fribidi_sheen.c` does what FriBidi does around those: the base direction from the first strong letter, the levels of the marks rule X9 removes (the level before them), rule L1, a line's order (L2, L3), and FriBidi's return values. Brackets pair as FriBidi pairs them, by decomposition (the fullwidth ones with the plain ones).
- `fribidi.h`: FriBidi's types, values and functions, written for this library, so a program built for FriBidi's headers calls it unchanged. Installed into `build/sdk-ports/include/sheenbidi`; the stubs are `libsheenbidi.a`.
- No Arabic joining or shaping data: every character is non-joining, and `fribidi_shape` only mirrors.
- The table, `sheenbidi_zdl.c`: FriBidi's functions in the order of FriBidi's own list (`exports.def`). It only grows at its end.
