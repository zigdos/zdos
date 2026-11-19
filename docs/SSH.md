# SSH

An SSH client (`SSH`, `SCP`) and server (`SSHD`), written in Zig (`apps/ssh/`), with Zig's cryptography from `\LIBS\ZCRYPT.ZDL`, one copy for every program. They need the [network](NETWORK.md) and tasks (UEFI's are cooperative: see [API](API.md#tasks-systemzig)). On CPUs without a random-number instruction (RDRAND, RNDR: PCs before 2012, the Raspberry Pi 4), keys are made from weak randomness: see the Todo.

- Key exchange: curve25519-sha256, with OpenSSH's strict key exchange.
- Ciphers: chacha20-poly1305@openssh.com, aes256-gcm@openssh.com, aes128-gcm@openssh.com.
- Host keys: Ed25519 (the client also checks ECDSA P-256 servers).
- User keys: Ed25519, in OpenSSH's file format, with or without a passphrase.

The key exchange's math, signatures, password checks and the encryption of large packets (4 KiB and up: file transfers) run on another CPU core when one is free; the task waiting for it lets others run meanwhile.

## Client

- `SSH [-p PORT] [-i KEYFILE] [-l USER] [user@]host`: the remote shell on this screen. ZDOS shows it as an xterm would: colors, full-screen programs such as `vim`, `less` and `top`. Enter `~` `.` ends the connection.
- `SSH ... host COMMAND`: runs one command; its output comes here, input redirected with `<` goes to it, and its exit code is SSH's.
- `SCP [-P PORT] [-i KEYFILE] [-r] [-q] SOURCE... TARGET`: copies files (`-r`: folders) over the SCP protocol; one side is `[user@]host:path`. (There is no SFTP client yet.)
- `SSHKEY [-f FILE] [-C COMMENT]`: makes an Ed25519 key pair, `%HOME%\.SSH\ID_ED25519` and `ID_ED25519.PUB`; the `.PUB` line goes into the server's `authorized_keys`. `SSHKEY -l FILE` shows a key's fingerprint.

The key is `-i`'s, else `%HOME%\.SSH\ID_ED25519`. Without one that the server accepts, SSH asks for the password. A server not met before is shown with its key's fingerprint and asked about; accepted ones go into `%HOME%\.SSH\KNOWN_HOSTS`. A changed key is refused.

## Server

`SSHD` is a service: in `\CONF\SERVICES.CFG`, `SSHD=true` starts it at boot. Settings are in `\CONF\SSHD.CFG`:

```ini
PORT=22
PASSWORDS=true
```

- **Logging in**: by key, from `\USERS\<name>\.SSH\AUTHORIZED_KEYS` (OpenSSH's lines), or by password (the user's from `SHADOW.CFG`; empty passwords don't work over the network). `PASSWORDS=false` allows keys only.
- **Host key**: made on the first start, `\CONF\SSHHOST.KEY`.
- **Sessions**: the user's shell (`COMSPEC`, or their own) on a remote console, in their home folder, with `USER`, `HOME` and `TERM=vt100` of their own; `ssh host COMMAND` runs a command line. Graphics programs don't work there.
- **SCP and SFTP**: `scp -O` uses the SCP protocol (`SCP -t` / `-f` on this side); plain `scp`, `sftp` and graphical clients (WinSCP, FileZilla) use SFTP, served by `SFTPSRV.APP` (version 3), started as the user. Paths: `/C:/USERS/alice/x.txt` is `C:\USERS\alice\x.txt`, relative ones start at the home folder, and `/` lists the drives.
- **Limits**: up to 8 connections, and 4 channels each.
- **Log**: `LOG=` in `SSHD.CFG` names it; the shipped file has `LOG=C:\DATA\LOGS\sshd.log`. Without `LOG=`, or with it empty: none.

ZDOS programs share all memory, so a user who logs in can do anything root can (see [Users](USERS.md)). Run SSHD only on networks you trust.

`tests/net/ssh-tests.py` tests both sides in QEMU: OpenSSH's `ssh` and `scp` against SSHD, and ZDOS's SSH and SCP against an sshd on the host (`SSHTEST`).
