# Users

ZDOS has users and file permissions as on Unix. They keep users' files apart and mistakes out, but are **not protection** yet: all programs share one memory and run with ZDOS's privileges.

## Files

- **Users**: `C:\CONF\USERS.CFG`, one per line as Unix's `/etc/passwd`: `name:uid:x:shell` (the shell empty for `COMSPEC`, or a program such as `C:\APPS\ASH.APP`). Without the file there is `ROOT` alone (user 0), without a password. User and group names compare ignoring case (`su root` is `ROOT`).
- **Passwords**: `C:\CONF\SHADOW.CFG`, as Unix's `/etc/shadow`: `name:hash`, readable by root alone (LOGIN, SU, SUDO and PASSWD run as root to read it). The hash is Argon2id with a random salt; an empty hash means no password.
- **Groups**: `C:\CONF\GROUPS.CFG`, as `/etc/group`: `name:gid:member,member`. Each user has a group of their own, numbered as the user. `ADMINS` (10) may use `SU` to root and `SUDO`.
- **Homes**: `\USERS\<name>` on the boot drive (`C:\USERS\ROOT`, `C:\USERS\alice` ...), made when missing.
- **Logging in**: without `LOGIN=true` ZDOS runs everything as root (only `USER`, `LOGNAME` and `HOME` are set). With `LOGIN=true` in `SYSTEM.CFG`, `AUTOEXEC.CMD` runs once as root, then `LOGIN.APP` asks for a name and password and starts the user's shell as that user, in the home folder, with `USER`, `LOGNAME` and `HOME` set; COMMAND runs `LOGIN.CMD` from the home folder if there is one. `EXIT` logs out.

## Permissions

Each program runs as its starter's user, and ZDOS checks every file and folder operation as Unix does: read, write and run (x) bits for the owner, the group and others; search (x) on the folders above; write on the folder to create, delete or rename in it; root may do anything else. Programs need read and run permission to start; root too needs a run bit. Libraries (`.ZDL`) need only read permission. Copying keeps permission bits; a program copied from FAT gets 0755. Changing a mode, attributes or date is for the owner or root; changing the owner or group (ash's `chown`), the disk tools (`FORMAT`, `FDISK`, `SYS`, `DISKLET` ...) and drive labels are root's. `KILL` and priority changes reach only your own tasks (root: any).

## Admins

Admins (root and the group `ADMINS`) may also set the clock (`DATE`), turn the computer off or restart it (`SHUTDOWN`, `REBOOT`), and set **global variables** (`SET` at the prompt, ash's `export`, a program's `setenv`): they are everyone's, and LOGIN, SU and SUDO run with them. Others' variables stay their own: a batch file's scope, ash's exports, a C program's `setenv`. Each login starts with the variables as they were after `AUTOEXEC.CMD`, not those the last user left.

- On **ext2 and Minix** drives the owners and modes are the file system's own; new files and folders belong to the user making them.
- **FAT** has neither, so (unless `FATOWNER=false`) the boot drive's are made up from where things are: `\USERS\<name>` and everything in it belong to that user, mode 0700 (nobody else may look in); `\TEMP` is everyone's (0777); `C:\CONF\SHADOW.CFG` and `C:\CONF\SUDO` are root's alone (0600, 0700); everything else belongs to root, 0755 (all may read and run, only root changes it). Other FAT drives (USB sticks ...) and what is inside `\TEMP` are everyone's: each user sees them as their own (as macOS shows FAT), so anyone may also delete folders there and use `chmod` and `ATTRIB`. The read-only attribute takes the write bits away.

## Commands

`WHOAMI` (whose rights the shell has), `ID` (user and groups: `uid=1000(alice) gid=1000(alice) groups=1000(alice),10(ADMINS)`), `PASSWD [name]` (your password, asking for the old one; root: anyone's; empty removes it), `ADDUSER` (lists users and groups), `ADDUSER name [-s shell] [-g group,group] [-u uid]` (the number: one above the highest, at least 1000, unless `-u` gives one; below 1000 for system accounts, as on Unix; 0 is root's), `USERMOD name [-g groups] [-s shell] [-u uid]` (a new number takes the home folder along; other files keep the old one: `chown -R` in ash), `DELUSER name [-r]` (`-r` with the home folder). Changing users is root's.

- `SU [-] [user] [-c command]`: a shell (or one command) as another user, root by default; asks for that user's password. Becoming root is for `ADMINS` only. `-`: in the user's home folder.
- `SUDO [-u user] command`: one command as root (or another user), for `ADMINS`; asks for **your own** password, then not again for 5 minutes (`SUDO -k` forgets it). Built-in commands work: `SUDO DEL C:\APPS\OLD.APP`.
- `LOGIN.APP`, `SU.APP`, `SUDO.APP` and `PASSWD.APP` in `C:\APPS` run as root whoever starts them (as setuid programs on Unix); on ext2 and Minix the setuid bit (`chmod 4755`) does the same for any program.
- C programs: `getuid`, `geteuid`, `getgroups`, `setuid`, `seteuid`, `setresuid` and the like work on these users; `getpwnam`, `getpwuid`, `getpwent` and `getlogin` read `USERS.CFG`. Zig: `zdos.getIds` / `zdos.setIds`, and `apps/zdos/users.zig` for the lists.
- `USER`, `HOME` and the other variables are global, as all variables are: everything running sees the last user's.
