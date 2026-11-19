# Lua 5.5 for ZDOS

`LUA.APP` is the Lua 5.5 interpreter, built from Lua's own `onelua.c` (all of Lua in one file) with the SDK. No Lua source is changed: `luaconf-zdos.h` is included before it with `-include`, and every setting it doesn't name is Lua's default.
You can get `onelua.c` from here: https://github.com/lua/lua/blob/master/onelua.c if it does not appear in your lua source files.

```sh
ports/coding/lua/build.sh             # all three editions
ports/coding/lua/build.sh x86         # one: x86 (BIOS), x86_64, arm64
```

The sources are `../lua/src` next to the ZDOS folder (the folder with `onelua.c`; `LUA_SRC=` moves it). The version for ZDOS is taken from `lua.h` (`version.c`). `lua.app` goes into `build/<edition>/APPS_3RD/` (for x86-64 and ARM64 both the UEFI and the metal edition's), and the next `zig build` puts it into `C:\APPS`.

## Status

- [x] Builds for all three editions.
- [x] Runs on ZDOS: the REPL, its line editing, and `scripts/luademo.lua` (including `io.popen` and temporary files) pass.
- [ ] Lua's own test suite (`testes/`) not run yet.
- [ ] Not checked: the screen's redirection being put back when an `io.popen` command fails or is interrupted.

## What works

- The whole language and the standard libraries: `base`, `coroutine`, `string`, `utf8`, `table`, `math`, `io`, `os`, `debug`, `package`.
- The interpreter: a script file, `-e`, `-l`, `-i`, `arg`, and the REPL without arguments. Ctrl+Z or Ctrl+D at the start of a line ends it. Its lines are edited by the SDK's keyboard input (arrows, Home, End, Delete, history), not readline.
- Modules: `./?.lua;./?/init.lua;/LUA/?.lua;/LUA/?/init.lua`, or `LUA_PATH`. Lua modules only: no C modules, `package.loadlib` returns an error.
- `os.execute(cmd)` and `io.popen(cmd)` run the command through ZDOS's command interpreter; the status is its exit code (ERRORLEVEL). `io.popen` runs the command to its end first: `"r"` then reads the whole output from memory, `"w"` gives the command its input when the file is closed. Up to 8 at a time.
- `os.date`, `os.time`: C locale, no time zone (`%z` is `+0000`, `%Z` is `UTC`).
- `os.getenv` reads ZDOS variables.
- `os.tmpname`, `io.tmpfile`: in the folder of `TEMP` (`TEMP=C:\TEMP` in `conf/SYSTEM.CFG`, made when missing), named `ZDnnnnnn.TMP`. Without `TEMP` they fail.
- Math from the SDK: the compiler's runtime and NetBSD's libm (fdlibm, `sdk/src/libm`), the same code BSDs and many C libraries use (within 1 ulp for most functions).
- Every program has a 1 MB stack; Lua's C-stack limit (`LUAI_MAXCCALLS`, 200) is the default.

## Floating point

The BIOS kernel turns the FPU on at boot (and SSE where the CPU has it, `enableFpu` in `src/arch/x86.zig`); 32-bit Lua uses the x87 unit. Each task has its own FPU state (the BIOS kernel saves it on every switch), and the SDK's start sets the x87 to double precision (control word `027F`, as ZDOS's Zig programs do), so Lua's numbers are the doubles they are on x86-64 and ARM64; Lua doesn't change the control word. x86-64 uses SSE, ARM64 its own FP registers. On ARM64 `setjmp` / `longjmp` save x19-x30, sp and d8-d15, but not FPCR / FPSR.

## Tests (not yet run)

From Lua's `testes/`: the self-contained ones (`math.lua`, `strings.lua`, `sort.lua` ...); not `files.lua`, `main.lua`, `cstack.lua`.
