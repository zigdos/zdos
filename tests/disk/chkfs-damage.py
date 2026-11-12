#!/usr/bin/env python3
# Damages Minix 3 and ext2 images for the CHKMFS / CHKEXT2 tests:
#   chkfs-damage.py mfs IMAGE [OFFSET] | ext2 IMAGE
# A wrong link count, a lost file and folder, map bits cleared, a
# cross-link (-F copies it), a garbage inode (only -D fixes it: it is
# deleted), and (ext2) wrong free counts and a stale backup superblock.
import struct
import subprocess
import sys


def mfs(path, base=0):
    f = open(path, "r+b")

    def rd(off, n):
        f.seek(base + off)
        return f.read(n)

    def wr(off, data):
        f.seek(base + off)
        f.write(data)

    sb = rd(1024, 32)
    ninodes, = struct.unpack_from("<I", sb, 0)
    imap, zmap = struct.unpack_from("<HH", sb, 6)
    zones, = struct.unpack_from("<I", sb, 20)
    bs, = struct.unpack_from("<H", sb, 28)
    ilist = (2 + imap + zmap) * bs
    first = 2 + imap + zmap + (ninodes + bs // 64 - 1) // (bs // 64)

    def inode(i):
        return bytearray(rd(ilist + (i - 1) * 64, 64))

    def put_inode(i, n):
        wr(ilist + (i - 1) * 64, bytes(n))

    def entries(dir_ino):
        n = inode(dir_ino)
        z, = struct.unpack_from("<I", n, 24)
        size, = struct.unpack_from("<I", n, 8)
        for off in range(0, min(size, bs), 64):
            e = rd(z * bs + off, 64)
            ino, = struct.unpack_from("<I", e, 0)
            name = e[4:].split(b"\0")[0]
            if ino and name not in (b".", b".."):
                yield z * bs + off, ino, name

    def is_dir(i):
        return struct.unpack_from("<H", inode(i), 0)[0] & 0o170000 == 0o040000

    def bit(map_block, b, on):
        off = map_block * bs + b // 8
        v = rd(off, 1)[0]
        v = v | (1 << (b % 8)) if on else v & ~(1 << (b % 8))
        wr(off, bytes([v]))

    # A folder with three files, and a folder of the root without it:
    seen, queue, paths = [], [(1, "")], {}
    while queue:
        d, path = queue.pop(0)
        seen.append((d, path))
        for off, ino, name in entries(d):
            if is_dir(ino) and ino not in paths:
                paths[ino] = path + "/" + name.decode()
                queue.append((ino, paths[ino]))
    for d, path in seen:
        files = [e for e in entries(d) if not is_dir(e[1])]
        if len(files) >= 6:
            break
    dirs = [e for e in entries(1) if is_dir(e[1]) and not (path + "/").startswith(paths[e[1]] + "/")]
    # A file: wrong link count:
    n = inode(files[0][1])
    struct.pack_into("<H", n, 2, 7)
    put_inode(files[0][1], n)
    # A file: lost (entry cleared):
    wr(files[1][0], b"\0" * 64)
    # A folder: lost:
    wr(dirs[0][0], b"\0" * 64)
    # Map bits of a used inode and its first zone, cleared:
    victim = files[2][1]
    bit(2, victim, False)
    z, = struct.unpack_from("<I", inode(victim), 24)
    if z:
        bit(2 + imap, z - first + 1, False)
    # A cross-link: files[4]'s first zone is files[3]'s (files[4]
    # comes second in the folder: it gets the copy):
    owner, = struct.unpack_from("<I", inode(files[3][1]), 24)
    n = inode(files[4][1])
    struct.pack_into("<I", n, 24, owner)
    put_inode(files[4][1], n)
    # A garbage inode: all ten zone pointers far outside the volume:
    n = inode(files[5][1])
    for i in range(10):
        struct.pack_into("<I", n, 24 + 4 * i, 0xF0000000 + i)
    put_inode(files[5][1], n)
    # The clean flag, as an interrupted write leaves it:
    flags, = struct.unpack_from("<H", rd(1024 + 14, 2), 0)
    wr(1024 + 14, struct.pack("<H", flags & ~1))
    print(f"lost file {files[1][2].decode()} (inode {files[1][1]}), lost folder {dirs[0][2].decode()} "
          f"(inode {dirs[0][1]}), link count of {files[0][2].decode()}, map bits of {files[2][2].decode()}, "
          f"cross-link {files[4][2].decode()} -> {files[3][2].decode()}, garbage inode {files[5][2].decode()}")


def ext2(path):
    def dbg(cmd):
        return subprocess.run(["debugfs", "-w", "-R", cmd, path], capture_output=True, text=True).stdout

    out = dbg("ls -p /").splitlines()
    files, dirs = [], []
    for l in out:
        parts = l.split("/")  # /ino/mode/uid/gid/name/size/
        if len(parts) < 6 or parts[5] in (".", "..", "lost+found"):
            continue
        (dirs if parts[2].startswith("04") else files).append(parts[5])
    # First, while /docs is still linked (it may be the lost folder).
    # A cross-link: n2.txt's first block is n1.txt's:
    shared = dbg("bmap /docs/n1.txt 0").strip()
    dbg(f"sif /docs/n2.txt block[0] {shared}")
    # A garbage inode: all twelve direct pointers far outside the volume:
    for i in range(12):
        dbg(f"sif /docs/n3.txt block[{i}] {4000000000 + i}")
    dbg(f"sif /{files[0]} links_count 7")
    dbg(f"unlink /{files[1]}")
    dbg(f"unlink /{dirs[0]}")
    block = dbg(f"bmap /{files[2]} 0").strip()
    dbg(f"freeb {block}")
    dbg(f"freei /{files[2]}")
    dbg("ssv free_blocks_count 1234")
    dbg("set_bg 0 free_inodes_count 3")
    # The backup superblock of group 1, a different UUID:
    with open(path, "r+b") as f:
        f.seek(1024)
        sb = f.read(1024)
        first_data, log_bs, bpg = struct.unpack_from("<I", sb, 20)[0], struct.unpack_from("<I", sb, 24)[0], struct.unpack_from("<I", sb, 32)[0]
        bs = 1024 << log_bs
        f.seek((first_data + bpg) * bs + 104)
        f.write(bytes(range(16)))
    print(f"lost file {files[1]}, lost folder {dirs[0]}, link count of {files[0]}, map bits of {files[2]}, "
          f"cross-link /docs/n2.txt -> /docs/n1.txt, garbage inode /docs/n3.txt, stale backup in group 1")


if __name__ == "__main__":
    if sys.argv[1] == "mfs":
        mfs(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 0)
    else:
        ext2(sys.argv[2])
