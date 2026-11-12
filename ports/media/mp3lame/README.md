# LAME

LAME is built as `MP3LAME.ZDL`, a per-program ZDOS library, with import stubs
installed as `build/sdk-ports/lib/<arch>/libmp3lame.a`. Its public
`lame.h` header is installed under `build/sdk-ports/include`. `LAMETEST.APP`
does a short in-memory MP3 encoding smoke test; it encoded successfully on
x86-64 under QEMU. The x86 and ARM64 builds have been compiled but not run.

```sh
ports/media/mp3lame/build.sh              # x86, x86_64 and arm64
ports/media/mp3lame/build.sh x86_64       # one or more architectures
```

The source tree is `$ZDOS_PORTS_SRC/mp3lame` (or `../mp3lame` when that
variable is unset); set `MP3LAME_SRC` to override it. Build intermediates are
kept in `build/mp3lame/<arch>/`. The port uses LAME's portable C
implementation, without NASM or its optional mpg123 decoder and command-line
frontend.

Use the API from a program as usual:

```sh
zdos-cc encoder.c -lmp3lame -o ENCODER.APP
```

No port-local `exports.def` is needed: the build generates the ordered table
from LAME's upstream `include/libmp3lame.sym` in `build/mp3lame/<arch>/`.
LAME is licensed under LGPL-2.0-or-later; its license is included in
`docs/COPYING/LAME.TXT`.
