# Ash

## About

Ash (`ASH.APP`) is a Unix-style shell for ZDOS: the POSIX shell language (as BusyBox `ash` has it, with a few bash additions such as arrays), with the usual text tools built in, awk among them. It runs Unix shell scripts, often unchanged. The sources are `apps/ash.zig` and `apps/ash/`; it is a new implementation in Zig, not just a port of BusyBox.

```
ash                      interactive
ash SCRIPT [ARG...]      runs a script
ash -c 'COMMANDS' [NAME [ARG...]]
ash -s [ARG...]          runs the commands in the standard input
ash -e -u -x -o pipefail ...   options, as set takes them
```

Paths can be written with `/` (`/C:/APPS/ASH.APP`, `docs/x.txt`) or DOS-style in quotes (`'C:\APPS'`; unquoted, `\` quotes the next character as in any Unix shell).

## Interactive use

Left, right, Home, End, Backspace and Delete edit the line; up and down go through the last 32 lines; Tab completes command and file names. An unfinished command (an open quote, `if` without `fi`, a line ending in `|`) continues on the next line with the `PS2` prompt (`> `). Ctrl+C stops the running command, also a loop; Ctrl+D on an empty line ends ash.

`PS1` is the prompt (default `\w\$ `): `\w` is the current folder, `\$` a `#` when ash runs as root and a `$` for other users, as in bash; variables and `$(...)` are expanded each time. In a script, set it in single quotes (`PS1='\w\$ '`), as `\$` in double quotes is already a plain `$`.

At start, an interactive ash run by root runs the file named by `ENV`, or else `SCRIPTS\ashrc.sh` beside the folder ash is in (`C:\SCRIPTS\ashrc.sh` for `C:\APPS\ASH.APP`). For other users it runs `ashrc.sh` in their home folder (`%HOME%\ashrc.sh`, e.g. `C:\USERS\alice\ashrc.sh`) if there is one, and nothing otherwise (see [Users](USERS.md)). Scripts and `-c` don't run either.

## How it differs from a Unix shell

Ash runs in ZDOS's one address space, with its tasks:

- **Pipelines**: when every command after the first is a program, they run as tasks at the same time, joined by pipes: `yes | head` works, and `head` ending ends `yes` (SIGPIPE). Otherwise the commands run one after another, the output kept in memory.
- **Arguments** reach a program as one line (no `argv` array): plain words as they are, words that are empty or have blanks or quotes in `"..."` with `\"` for a quote. C programs get them back as `argv`.
- **Subshells** (`( ... )`, `$( ... )`, the parts of a pipeline, scripts) are not separate processes: ash saves its variables, functions and current folder and puts them back afterwards.
- **Variables** keep the case of their names. Exported ones are also ZDOS variables, which programs see, in capitals, at most 48 per scope and values up to 512 bytes. A variable a program sets for its caller is taken into the shell. `NAME=value prog` gives `prog` that variable alone.
- **Error messages** go to the error output (stream 2), not into pipes, files or `$(...)`. `2>file`, `2>/dev/null`, `2>&1` and `>&2` work, for built-ins and programs.
- **Background commands**: a program with `&` (redirections only, no function or built-in) runs as a task; `$!` is its number, `wait ID` gives its exit status (also after it was reported), `wait` alone waits for all. Finished jobs are reported before the next prompt (`[3] Done`, `[4] Exit 2`); the last 64 codes are kept. Anything else with `&` runs in the foreground. No `jobs`, `fg`, `bg`, or signals other than Ctrl+C; `trap` knows only `EXIT`.
- **Files** written through `>` get Unix line ends; the text tools read DOS line ends too.
- `/dev/null` and `NUL` are nowhere, `/dev/stdout` the output, `/dev/stderr` and `/dev/tty` the screen.

## The shell language

**Commands**: `a ; b`, `a && b`, `a || b`, `a | b` (a line may end after `|`, `&&`, `||`), `! a`, `( list )`, `{ list; }`, `if/then/elif/else/fi`, `while` and `until ... do ... done`, `for NAME [in WORDS]; do ... done`, `case WORD in PATTERN|PATTERN) ... ;; esac`, `break [N]`, `continue [N]`, functions `name() { ... }` or `function name { ... }` with `local` variables and `return [N]`. `#` starts a comment; `\` at the end of a line continues it.

**Redirections**: `<`, `>`, `>>`, `2>`, `2>>`, `2>&1`, `>&2`, `<<END` and `<<-END` (here-documents; `<<'END'` without expansions), `<<< word` (here-string). They also work after compound commands (`while read l; do ...; done < file`). `exec >file` keeps them.

**Quoting**: `'...'`, `"..."`, `\x`, `$'...'` (with `\n`, `\t`, `\033`, `\x41`).

**Expansions**, in POSIX order:
- `~` (HOME)
- `$name`, `${name}`, `$1` ... `${10}`, `$#`, `$@`, `"$@"` (one word each), `$*`, `$?`, `$0`, `$-`, `$$`
- `${x:-word}`, `${x-word}`, `${x:=word}`, `${x:+word}`, `${x:?message}`
- `${#x}` (length), `${x#pat}`, `${x##pat}`, `${x%pat}`, `${x%%pat}`, `${x/pat/new}`, `${x//pat/new}`, `${x/#pat/new}`, `${x/%pat/new}`, `${x:offset:length}`
- `$(commands)` and `` `commands` ``
- `$((arithmetic))`: 64-bit integers; `+ - * / % << >> & | ^ ~ ! && || == != < <= > >=`, `?:`, `=`, `+=` and the like, `++`, `--`; variable names without `$`; hex `0x1F` and octal `017`
- then words are split at `$IFS` (only the results of unquoted expansions), and words with `*`, `?` or `[...]` become the matching file names (sorted; letter case counts, as in POSIX shells, also on FAT drives; also over folders: `*/*.zig`); without a match the word stays.

**Arrays**: `a=(one "two three")`, `a+=(more)`, `a[5]=x`, `${a[1]}`, `${a[i+1]}`, `"${a[@]}"` (one word each), `${a[*]}`, `${#a[@]}`. `$a` is `${a[0]}`. Arrays are not sparse: setting an element past the end fills the gap with empty elements.

**Options** (`set -e` ... or `set -o name`, `+` switches off): `-e` (errexit: a failing command ends the script, except in conditions), `-u` (nounset), `-x` (xtrace, to the error output), `-f` (noglob), `-o pipefail`.

## Scripts

A script runs with `ash script.sh`, `. script.sh` (in the current shell), or by its name: `./script.sh`, or `script` for `script.sh` (or a file without extension) in the current folder or `PATH`. A script runs as a new shell: it sees only exported variables, and what it sets stays inside. A first line `#!` naming `ash`, `sh`, `bash` or `dash` (also through `/usr/bin/env`) runs it in ash; another interpreter is started as a program with the script's path as argument. Without `#!` ash runs it. DOS line ends are fine.

A script stops at its first syntax error (exit code 2) or at an expansion error, as `${x:?}` or a division by zero in `$((...))`.

## Built-in commands

`help` lists them. Each has the options real users rely on; others are refused with a message.

**The shell's own**: `.` / `source FILE [ARG...]`, `:`, `true`, `false`, `break [N]`, `continue [N]`, `cd [DIR | -]` (sets `PWD`, `OLDPWD`), `command [-v | -V] NAME` (`command NAME` skips functions), `echo [-n] [-e] [-E]`, `eval`, `exec [COMMAND]` (`exec >file`: redirections for the rest), `exit [N]`, `export [-p] [NAME[=VALUE]...]`, `local NAME[=VALUE]...`, `printf FORMAT [ARG...]` (`%s %b %c %d %i %u %o %x %X %e %f %g %%` with flags, width and precision, `*`; the format repeats while arguments are left; `'A` is the code of A), `pwd`, `read [-r] [-p PROMPT] [NAME...]` (splits at `$IFS`, `REPLY` without names), `readonly NAME=VALUE` (an assignment), `return [N]`, `set` (lists the variables; options; `set -- ARG...`), `shift [N]`, `test` / `[` (`-e -f -d -s -r -w -x -n -z`, `= != < >`, `-eq -ne -lt -le -gt -ge`, `-nt -ot`, `!`, `-a`, `-o`, `( )`), `trap 'COMMANDS' EXIT`, `type NAME`, `unset [-f] NAME...`, `wait [ID]` (background jobs: see above), `clear`, `env [NAME=VALUE...] [COMMAND]` (lists the exported variables), `help`.

**Files**: `cat [-n] [FILE...]` (byte for byte, as POSIX), `chmod [-R] MODE PATH...` (octal or `u+x,go-w`), `chown [-R] [OWNER][:GROUP] PATH...` (names or numbers: `alice`, `alice:games`, `:games`, `alice:` for alice and her own group; root only), `cp [-r] SOURCE... DEST`, `df [-h] [-a] [-T]` (`-T`: the file system type), `find` (below), `ls [-a] [-l] [-h] [-d] [-i] [PATH...]` (sorted; folders end in `/`; `-i`: inode numbers, `-` on FAT), `mkdir [-p]`, `mv SOURCE... DEST`, `rm [-r] [-f]`, `rmdir`, `touch [-c]`, `xxd [-c COLUMNS] [-g GROUP] [-l LENGTH] [-s OFFSET] [FILE]`. `copy`, `move`, `remove`, `del`, `list` and `dir` are the same as `cp`, `mv`, `rm` and `ls`.

**Text**: 
- `awk` (below)
- `basename PATH [SUFFIX]`, `dirname PATH`
- `cut -c LIST | -f LIST [-d CHAR] [-s] [FILE...]`
- `diff` and `patch` (below)
- `grep [-EFivncqlhHrowx] [-e PATTERN]... [PATTERN] [FILE...]`: basic regular expressions, `-E` extended, `-F` plain text; `-r` searches folders
- `sed` (below)
- `head [-n N | -N] [-c BYTES] [FILE...]`, `tail [-n N | -N | -n +N] [FILE...]`
- `sort [-rnfu] [-t CHAR] [-k F1[.C][nrf][,F2[.C]]]... [FILE...]`
- `uniq [-c] [-d | -u] [-i] [INPUT [OUTPUT]]`
- `wc [-l] [-w] [-c] [FILE...]`
- `xargs [-0] [-r] [-n N] [-I TEXT] [COMMAND [ARG...]]`: programs get as many words as fit in ZDOS's 4 KiB of argument text per run; built-in commands get them all

**Others**: `date [+FORMAT]` (`%Y %m %d %H %M %S %F %T %a %b`), `sleep SECONDS`, `which [-a] NAME...`, `where NAME...` (all matches in the current folder and `PATH`).

Other commands are programs: `NAME.APP` in the current folder or `PATH`. Each argument arrives whole (see **Arguments** above).

### sed

```
sed [-nEs] [-i[SUFFIX]] SCRIPT [FILE...]
sed [-nEs] [-i[SUFFIX]] [-e SCRIPT]... [-f SCRIPTFILE]... [FILE...]
```

The POSIX stream editor, with GNU sed's common additions. Options: `-n` (`--quiet`), `-E` / `-r` (extended regular expressions), `-s` (each file on its own: `$` and line numbers per file), `-i[SUFFIX]` (`--in-place`: edit the files themselves, keeping the originals as FILE + SUFFIX if given; a file with DOS line ends keeps them), `-e`, `-f`. Script files may have DOS line ends.

- Addresses: `N`, `$`, `/regex/` (also `\%regex%`, `I` for any case), `first~step`, `addr1,addr2`, `addr,+N`, `0,/regex/`, and `!` to negate.
- Commands: `{ }`, `s`, `y`, `p`, `P`, `d`, `D`, `n`, `N`, `g`, `G`, `h`, `H`, `x`, `a`, `i`, `c` (`a text` or `a\` with the text on the next lines), `=`, `l`, `q [code]`, `Q [code]`, `r file`, `w file` (`/dev/stdout`, `/dev/stderr`), `:label`, `b`, `t`, `T`, `F`, `z`, `#` comments (`#n` on the first line is `-n`).
- `s` flags: `g`, a number, `p`, `I`, `w file`. In the replacement `&` and `\1` to `\9` are what the pattern and its groups matched; `\n`, `\t`, `\r` work, and `\&` is a plain `&`. An empty pattern (`s//x/`) is the last one used.
- Regular expressions are basic ones (`\(...\)`, `\{n,m\}`, `\+`, `\?`, `\|`) or, with `-E`, extended ones, as grep has them, plus `\s \S \w \W`. A back-reference inside a pattern (`\(a\)\1`) is refused: the matcher works in linear time and can't have them. In the replacement they work.
- As in GNU sed, `N` on the last line prints the pattern space and ends, and a last line without a line end is written without one.

### diff and patch

```
diff [-abdiBpTtw] [-c | -e | -f | -n | -q | -u] [-I PATTERN] [-L LABEL]... FILE1 FILE2
diff ... -C N | -U N FILE1 FILE2
diff [-r] [-NPs] [-S NAME] [-x PATTERN]... [-X FILE] DIR1 DIR2
patch [-bCcEflNnRstu] [-B PREFIX] [-d DIR] [-F N] [-i PATCHFILE] [-o FILE] [-p N]
      [-r REJFILE] [-V none | simple] [-z SUFFIX] [--posix] [ORIGFILE [PATCHFILE]]
```

The options and output of BSD's diff and patch; their patches work with GNU diff and patch both ways.

- **diff** compares files line by line, and folders (`-r`); a "\r" at a line's end counts, as on Unix. Files with NUL bytes are binary (`-a`: as text). Very different files are cut short past 2048 edits (`-d`: always the shortest script). Exit code 0 the same, 1 different, 2 trouble.
- **patch** applies unified, context and normal diffs, with offsets and fuzz (`-F`, at most 2); hunks that don't fit go to `FILE.rej`. The original is kept as `FILE.orig` (`-V none`: no backups). With no question to ask, a patch that seems reversed is applied reversed (`-N` skips it). When patch and file differ only in "\r" line ends, the hunk applies and keeps the file's. Exit code 0, 1 when hunks failed, 2 trouble.

### find

```
find [PATH...] [EXPRESSION]
```

Tests: `-name PATTERN`, `-iname PATTERN` (any case), `-path PATTERN`, `-type f|d`, `-inum N` (the inode number, as in CHKEXT2's and CHKMFS's messages and `\lost+found\#N`; nothing on FAT). Actions: `-print` (the default), `-print0`, `-prune`, `-exec COMMAND {} ;`, `-exec COMMAND {} +`. Options: `-maxdepth N`, `-mindepth N`. Operators: `!` / `-not`, `-a` / `-and` (or nothing), `-o` / `-or`, `( )` (written `\( \)` in the shell).

### awk

```
awk [-F FS] [-v NAME=VALUE]... 'PROGRAM' [FILE | NAME=VALUE]...
awk [-F FS] [-v NAME=VALUE]... -f PROGFILE... [FILE | NAME=VALUE]...
```

The POSIX awk language: `BEGIN`, `END`, patterns (expressions, `/regex/`, ranges `a, b`), functions (arrays as parameters by reference), `if`, `while`, `do`, `for`, `for (k in a)`, `next`, `nextfile`, `exit`, `return`, `delete`, `getline` in all its forms, `print` and `printf` with `>`, `>>` and `| "command"`.

Variables: `NR NF FNR FS OFS ORS RS FILENAME SUBSEP RSTART RLENGTH CONVFMT OFMT ENVIRON ARGC ARGV`. Functions: `length substr index split sub gsub match sprintf sin cos atan2 exp log sqrt int rand srand tolower toupper system close fflush`. Regular expressions are POSIX extended ones (`[[:alpha:]]` and `{n,m}` included). `RS=""` reads paragraphs.

Output to a command (`print | "sort"`) is collected and the command runs when the stream is closed (`close()` or the end of the program); a command read by `"cmd" | getline` runs to its end first. Commands run in ash.

Numbers print as integers when they are whole (below 10^16), else with `OFMT` (`%.6g`). `010` is ten, not octal (gawk differs there).

## Tests

`scripts/demoa.sh` tests the shell and every built-in command, module by module:

```
cd /C:/
ash /C:/SCRIPTS/demoa.sh
```

It works in a folder `ash_demo_tmp`, prints a line per module and the tests that fail, and removes the folder. `tools/loc.sh` (lines of code per file type, a bash script using arrays, `find -prune`, `xargs -0` and two awk programs) runs unchanged on ZDOS once copied onto it: `ash loc.sh /C:/`.
