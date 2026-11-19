# QuickJS for ZDOS

`qjs.app` is QuickJS-NG's JavaScript interpreter: modern JavaScript, its REPL, and the `qjs:std` and `qjs:os` modules, with ZDOS's own modules `zdos:web`, `zdos:sqlite` and `zdos:net`.

```sh
ports/coding/quickjs/build.sh             # all three CPUs
ports/coding/quickjs/build.sh x86_64      # one or more: x86, x86_64, arm64
zig build                                 # puts it onto drive C:
```

The sources are `$ZDOS_PORTS_SRC/quickjs` (`QUICKJS_SRC=` moves it), QuickJS-NG's tree with its `gen/` folder. The version for ZDOS is taken from `quickjs.h` (`version.c`).

## How it is made

- The files of QuickJS's `qjs` (its `CMakeLists.txt`), with `quickjs-zdos.h` included first: `sighandler_t`, `S_ISUID` and `S_ISGID`, which the SDK lacks.
- `quickjs-zdos.patch`: `os.exec()` searches through the C library's `execvpe` (ZDOS paths); `qjs.c` adds `zdos:net` and `zdos:sqlite` to each context; the module loader takes `zdos:web` from inside the program.
- ZDOS's modules: `zdos_net.c`, `zdos_sqlite.c` and `web.js` (embedded by `zdos_web.c`), on the Mbed TLS and SQLite ports; `qjs.app` needs `C:\LIBS\SQLITE.ZDL`.

## Using it

```
qjs                          the REPL
qjs SCRIPT.JS a b            a script (or an ES module) with arguments (scriptArgs)
qjs -e "console.log(6*7)"    one expression
qjs --std -e "std.exit(3)"   std and os as globals
```

- Modules: `import ... from "./LIB.JS"`, `import * as std from "qjs:std"`, `import * as os from "qjs:os"`. Top-level `await` works.
- `qjs:std`: files (`std.open()`, `loadFile()`, `writeFile()`, `printf()`), `getenv()` (ZDOS variables), `exit()` (the exit code is the ERRORLEVEL).
- `qjs:os`: `stat()`, `readdir()`, `mkdir()`, `rename()`, `remove()`, timers (`setTimeout()`, `sleepAsync()`), `exec()` (another program, with its standard handles redirected and its exit code returned), and `Worker` (threads).

## ZDOS's modules

- `zdos:web`: a web framework in the manner of Express, HTTP and HTTPS: [ZDOSWEB.md](ZDOSWEB.md).
- `zdos:sqlite`: SQLite in the manner of better-sqlite3, and `zdos:net`: TCP server sockets and TLS: [ZDOSMODS.md](ZDOSMODS.md).

## Test

- `scripts/jsdemo.js`: run by `tests/run-all.py` (`qjs C:\SCRIPTS\JSDEMO.JS`).
- `tests/ports/quickjs/web-tests.py [editions]`: the web modules, with this computer as the HTTP and HTTPS client; `--host` runs the checks on this computer.
