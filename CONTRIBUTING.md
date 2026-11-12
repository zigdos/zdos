# Contributing to ZDOS

Use these rules to keep the source tree consistent.
Ask when one does not fit. Ask if going to implement significant things.
Read the documents on how APP, ZDL, and SYS files are created.

## Code
- Zig 0.14 for now. Waiting while the language stabilizes.
- File names: avoid `" * : < > ? |`.
- Avoid symbolic links in the code tree for FAT compatibility.
- Metal gets its own drivers. Do not change BIOS-only drivers to serve Metal.
- The Minix driver stays compatible with real Minix 3 for now (no labels, no triple indirect blocks).
- Pure computation (crypto, hashing, compression) runs on free cores through the `cores` group when there are any; `apps/ssh/cores.zig` has a helper.
- MMIO drivers read registers through `src/arch/mmio.zig`.

## Program API
- The API stays the same version until the upcoming release; it changes in place, without compatibility code, and freezes on release.
- A new function takes the next reserved slot of its group's section, in both `src/kernel/abi.zig` and `sdk/src/zdos.h` (same position), and goes into the group's table in `src/kernel/api.zig`. Both files check each group's slot count at compile time. The SDK for C programs needs updates on API changes.
- If you are going to implement many new functions, create new API groups (with few slots if extending is foreseeable); then integrate them the same way in ABI, API, and SDK.

## Ports
- If you can write a program from scratch in Zig, write in Zig instead of porting C or Rust code.
- Try to minimize file sizes and memory consumption; turn off or delete functions that are never used in practice.
- Try to avoid unnecessary dependencies and rely on existing ZDL libraries. Small dependencies - compile into binaries. Large libraries that are useful for other apps - create as ZDLs.
- Sources outside the tree (`ZDOS_PORTS_SRC`) are typically only read. Build in `build/<port>/`; patch a copy there when the port needs changes.
- A build prints short progress lines; the compiler's output goes to a log named in the error when the build fails.

## Testing
- Test on separate disk images in the scratchpad directory; do not place various test apps into the APPS directory or other system folders.
- Test on all applicable editions, unless the port is so simple that it obviously will run everywhere.

## Comments
- Make code self-explanatory and comments succint; use comments when code is unclear.
- A small comment inside a function ends with a colon: `// the root itself:`
- Sections are in capitals: `// FILES`; do not use `====` or `----`. Large scripts get such sections too.
- Line length: about 56-64 characters in the kernel (`src/`); at most 80 elsewhere.
- When wrapping, do not leave a one- or two-word tail of a sentence on its own line; break logically before a sentence or after a semicolon.
- App and library headers: a usage line, or what it is in a few words; nothing if the file is self-explanatory.
- No licence text or links in comments (licences live in `docs/COPYING/`); only keep a notice if a licence requires.
- Do not explain other, even related module (file), in a module's (file's) comments.
- Third-party code (lwIP, libm, vendored sources) keeps its own style.

## Documentation
- Docs explain how things work; general docs do not list every driver, port, or program. Each item describes itself in its own header or README.
- Do not repeat things that are explained elsewhere; if necessary, link to them; but if explanation is small or links could be avoided - avoid such links.
- Purely experimental features do not go to docs. A feature that works gets a short mention where ZDOS lists its features (README, [docs/BIOS.md](docs/BIOS.md), ...).
- Port READMEs: a concise explanation without restating every single change or function.
- New work goes into [docs/DEVLOG.md](docs/DEVLOG.md) under the current release (`[x]` and a short sentence); open work goes into [docs/TODO.md](docs/TODO.md).

## Licences
- No GPL or copyleft code in the core: kernel, `apps/`, ash, the SDK's libraries. Base Unix tools on BSD sources (e.g. Minix) or write them from scratch.
- Copyleft or other code is fine in optional ports under `ports/`, stated in `docs/COPYING/`.