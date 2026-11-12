#!/usr/bin/env python3
# A disk image (one file system, no partition table) holding a folder:
#   tools/disk/mkimage.py mfs3|ext2|fat32 FOLDER [--size MIB]
# Writes scratchpad/images/<folder, lower case>.img; the size is
# worked out from the folder unless given.
# MFS3: build/host/mfsdir (zig build mfsdir). EXT2: mke2fs -d.
# FAT32: mkfs.fat and mcopy (mtools).

import argparse
import math
import os
import platform
import shutil
import subprocess
import sys

ROOT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
OUT = os.path.join(ROOT, "scratchpad", "images")
MFSDIR = os.path.join(ROOT, "build", "host", "mfsdir")
BLOCK = 4096
MIB = 1 << 20
MIN_MIB = {"mfs3": 4, "ext2": 4, "fat32": 40}  # FAT32: 65525 clusters

# macOS: Homebrew's e2fsprogs is keg-only, not on PATH
DARWIN = platform.system() == "Darwin"
if DARWIN and shutil.which("brew"):
    keg = subprocess.run(["brew", "--prefix", "e2fsprogs"], capture_output=True, text=True).stdout.strip()
    if keg and os.path.isdir(os.path.join(keg, "sbin")):
        os.environ["PATH"] = os.path.join(keg, "sbin") + os.pathsep + os.environ["PATH"]
# Where the tools come from:
PACKAGE = {"mke2fs": "e2fsprogs", "mkfs.fat": "dosfstools", "mcopy": "mtools", "zig": "zig"}


def fail(text):
    print("mkimage: " + text, file=sys.stderr)
    sys.exit(1)


def run(*cmd):
    if shutil.which(cmd[0]) is None and not os.path.isabs(cmd[0]):
        how = "brew install" if DARWIN else "the package"
        fail(f"{cmd[0]} not found: {how} {PACKAGE.get(cmd[0], cmd[0])}")
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                       env=dict(os.environ, MTOOLS_SKIP_CHECK="1"))
    if r.returncode != 0:
        fail(f"{os.path.basename(cmd[0])} failed:\n{r.stdout.strip()}")


# Blocks the folder takes, with room for the file system's own:
def needed_mib(folder, fs):
    used = 0
    for dirpath, dirs, names in os.walk(folder):
        used += BLOCK * (1 + len(dirs) + len(names))  # entries, inodes
        for n in names:
            used += math.ceil(os.path.getsize(os.path.join(dirpath, n)) / BLOCK) * BLOCK
    return max(MIN_MIB[fs], math.ceil(used * 1.25 / MIB) + 2)


def main():
    ap = argparse.ArgumentParser(description="A disk image holding a folder")
    ap.add_argument("fs", choices=("mfs3", "ext2", "fat32"))
    ap.add_argument("folder")
    ap.add_argument("--size", type=int, metavar="MIB", help="default: from the folder")
    a = ap.parse_args()
    folder = os.path.realpath(a.folder)
    if not os.path.isdir(folder):
        fail(f"{a.folder}: not a folder")
    name = os.path.basename(folder).lower()
    mib = a.size or needed_mib(folder, a.fs)
    os.makedirs(OUT, exist_ok=True)
    img = os.path.join(OUT, name + ".img")
    if os.path.exists(img):
        os.remove(img)

    if a.fs == "mfs3":
        if not os.path.exists(MFSDIR):
            run("zig", "build", "mfsdir")  # in ROOT: see cwd below
        run(MFSDIR, img, str(mib * 1024), folder)
    elif a.fs == "ext2":
        run("mke2fs", "-q", "-F", "-t", "ext2", "-b", str(BLOCK), "-L", name[:16], "-d", folder, img, f"{mib}M")
    else:
        run("mkfs.fat", "-F", "32", "-n", name.upper()[:11], "-C", img, str(mib * 1024))
        entries = [os.path.join(folder, n) for n in sorted(os.listdir(folder))]
        if entries:
            run("mcopy", "-s", "-Q", "-i", img, *entries, "::/")
    print(f"{img}: {a.fs}, {mib} MiB")


if __name__ == "__main__":
    os.chdir(ROOT)
    main()
