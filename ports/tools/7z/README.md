# 7-Zip

7-Zip 26.06's console program `7zz` with all its formats: `C:\APPS\7ZZ.APP`. It packs and unpacks 7z, zip, gzip, bzip2, xz, tar and wim, and unpacks many more (RAR, zstd, cab, iso, arj, lzh, rpm, deb, dmg ...).

```sh
ports/tools/7z/build.sh             # all three CPUs
ports/tools/7z/build.sh x86_64      # one or more: x86, x86_64, arm64
zig build                           # puts it onto drive C:
```

Sources: 7-Zip's source package in `$ZDOS_PORTS_SRC/7z` (`../7z` when that variable is unset; `SEVENZIP_SRC=...`). They are copied into `build/7z/tree`, where `7z-zdos.patch` is applied; objects go to `build/7z/<arch>/`.

## How it is made

7-Zip's own `CPP/7zip/Bundles/Alone2/makefile.gcc` with `zdos-cc` and `zdos-c++`: C instead of 7-Zip's assembler, threads through the SDK's pthreads. `7z-zdos.patch`: the RAM size from `sysconf` (no `sysinfo` on ZDOS), no `umask` (new files get `022`'s modes), and DOS paths:
- On the command line, `\` is turned into `/` and `C:\X` into `/C:/X`, in file arguments, `@` lists, `-o`, `-w`, `-i`, `-x`, `-ai` and `-ax`. Names are then stored as on Windows (`7ZZ a A.7Z C:\DOCS` stores `DOCS\...`). Passwords and the other switches stay as typed.
- When unpacking, `:` and `\` in an archive's names become `_`, as on Windows, so a name such as `C:/X` or `a\..\..\X` stays inside the folder it is unpacked into.

Test: `tests/ports/7z-tests.py [editions]` (`SEVENZIP_RAR=file.rar` adds a compressed RAR, checked against `unrar`).

## Using it

```
7ZZ a backup.7z C:\DOCS          (pack)
7ZZ x backup.7z -oC:\TEMP\OUT    (unpack with folders)
7ZZ l archive.rar                (list)
7ZZ t archive.zip                (test)
```

Memory: packing at the default level (`-mx5`) takes about 200 MB, `-mx9` about 700 MB; with 256 MB use `-mx3` or a smaller dictionary (`-md=8m`). Unpacking needs about the archive's dictionary size.