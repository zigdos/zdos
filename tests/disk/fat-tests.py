#!/usr/bin/env python3
# FAT driver test suite, unattended: ash runs fstest.sh on ZFAT12,
# ZFAT16 and ZFAT32, then the host checks them with fsck.fat -n, its
# own directory reader and mtools. On UEFI it tests the firmware's
# driver (its short aliases are not checked by name).
#   fat-tests.py run
# Default metal x86_64; another edition (common.py):
#   ZDOS_EDITION=uefi ZDOS_ARCH=x86_64 python3 tests/disk/fat-tests.py run
# The image is kept when a volume fails.
import hashlib
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import common as h  # noqa: E402

OUT = h.suite_dir("fat-tests")
SHOTS = os.path.join(OUT, "shots")
IMG = os.path.join(OUT, "fat.img")
SEED = os.path.join(OUT, "seed.bin")
SEED_SIZE = 300001  # no cluster size divides it
FSTEST_TIME = 900  # seconds for one volume's fstest.sh
STALL_TIME = 240  # seconds without a new line in fstest.log: stuck

# (name, mkfs.fat options, MiB) in GPT order: E:, F:, G:
VOLUMES = [
    ("fat12", ["-F", "12", "-s", "8", "-r", "256"], 15),
    ("fat16", ["-F", "16", "-r", "512"], 32),
    ("fat32", ["-F", "32", "-s", "1"], 64),
]
START = 2048  # sectors: the first partition

FSTEST = r'''# ZDOS FAT driver test: run in a FAT volume's root (fstest.sh 12|16|32 bios|uefi)
log=fstest.log
kind=$1
platform=$2
if [ -e $log ]; then
    echo "fstest.sh ran on this volume already: make a fresh image"
    exit 1
fi
echo "fstest start" > $log

step() {
    if [ "$2" = ok ]; then
        if [ "$3" = 0 ]; then r=PASS; else r=FAIL; fi
    else
        if [ "$3" = 0 ]; then r=FAIL; else r=PASS; fi
    fi
    echo "$r $1 (status $3)" >> $log
    echo "$r $1"
}

# Short names and letter case: one entry, whatever case it is named in:
echo "lower" > lower.txt
step "create lower.txt" ok $?
echo "upper" > UPPER.TXT
step "create UPPER.TXT" ok $?
cat LOWER.TXT > t_case.txt
step "open lower.txt as LOWER.TXT" ok $?
echo "again" > Lower.Txt
step "overwrite it as Lower.Txt" ok $?

# Long names and their short aliases, past ~9:
echo "long" > "A long file name.text"
step "create a long name with spaces" ok $?
st=0
i=1
while [ $i -le 12 ]; do
    echo "alias $i" > "longname_alias_$i.txt" || st=1
    i=$((i + 1))
done
step "create 12 names sharing an alias prefix" ok $st
cat "LONGNAME_ALIAS_11.TXT" > t_alias.txt
step "open a long name in other case" ok $?
if [ "$platform" != uefi ]; then
    # ZDOS's driver makes the aliases; the firmware's has its own scheme:
    cat LONGNA~1.TXT > t_short.txt
    step "open a file by its short alias" ok $?
fi

# Many entries, more than the sector cache holds; half deleted, then
# names of one and of three slots put in again:
mkdir many
step "mkdir many" ok $?
st=0
i=0
while [ $i -lt 1200 ]; do
    echo "f $i" > many/f_$i.txt || st=1
    i=$((i + 1))
done
step "create 1200 files" ok $st
st=0
i=0
while [ $i -lt 1200 ]; do
    rm many/f_$i.txt || st=1
    i=$((i + 2))
done
step "delete the 600 even ones" ok $st
st=0
i=0
while [ $i -lt 300 ]; do
    echo "long $i" > "many/long entry number $i.txt" || st=1
    i=$((i + 1))
done
step "create 300 long names (runs of slots)" ok $st
st=0
i=0
while [ $i -lt 300 ]; do
    echo "g $i" > many/g_$i.txt || st=1
    i=$((i + 1))
done
step "create 300 short names (into the gaps)" ok $st
echo "back" > many/f_0.txt
step "create a deleted name again" ok $?
cat many/F_1199.TXT > t_last.txt
step "open the last of the 1200" ok $?
cat many/f_2.txt > t_deleted.txt
step "a deleted file is gone" fail $?

# A deleted directory's cluster taken by a new one: nothing of the old
# directory may show:
mkdir olddir
st=0
i=0
while [ $i -lt 20 ]; do
    echo "x $i" > olddir/x_$i.txt || st=1
    i=$((i + 1))
done
step "fill olddir" ok $st
rm olddir/x_*.txt
step "empty olddir" ok $?
rmdir olddir
step "rmdir olddir" ok $?
mkdir newdir
step "mkdir newdir" ok $?
echo "new" > newdir/x_3.txt
step "create in newdir a name olddir had" ok $?
cat newdir/x_4.txt > t_ghost.txt
step "no file of olddir shows in newdir" fail $?

# Renames and moves (a directory's ".." changes):
mkdir source
mkdir target
echo "moved" > "source/moved file.txt"
step "create a file to move" ok $?
mv "source/moved file.txt" "target/moved file.txt"
step "move it to another directory" ok $?
mv target "dest dir renamed"
step "rename a directory to a long name" ok $?
mv "dest dir renamed" source/inner
step "move a directory into another" ok $?
cat "source/inner/moved file.txt" > t_moved.txt
step "read the moved file through its new path" ok $?
mv UPPER.TXT upper.txt
step "rename changing case only" ok $?

# Data over many clusters:
cp seed.bin copy.bin
step "copy a 300 KB file" ok $?
cp copy.bin copy2.bin
step "copy the copy" ok $?
echo "short" > copy2.bin
step "truncate the second copy" ok $?
cp seed.bin gone.bin
rm gone.bin
step "delete a 300 KB file" ok $?

# Read-only entries are not deleted:
echo "ro" > ro.txt
chmod 444 ro.txt
step "make ro.txt read-only" ok $?
rm ro.txt
step "deleting it is refused" fail $?
chmod 644 ro.txt
rm ro.txt
step "delete it once writable" ok $?

# FAT12: the fixed root fills up, then empties again:
if [ "$kind" = 12 ]; then
    st=0
    i=0
    while [ $i -lt 300 ]; do
        echo "r" > r_$i.txt || st=1
        i=$((i + 1))
    done
    step "a full fixed root refuses more" fail $st
    rm r_*.txt
    step "delete what fit" ok $?
    echo "after" > after_full.txt
    step "create a file after that" ok $?
fi

echo "fstest done" >> $log
echo "fstest done: see fstest.log"
'''


def make():
    # The GPT disk with the three volumes, fstest.sh and seed.bin in each:
    os.makedirs(OUT, exist_ok=True)
    seed = os.urandom(SEED_SIZE)
    with open(SEED, "wb") as f:
        f.write(seed)
    script = os.path.join(OUT, "fstest.sh")
    with open(script, "w") as f:
        f.write(FSTEST)
    starts = []
    pos = START
    for _, _, mib in VOLUMES:
        starts.append(pos)
        pos += mib * h.MB
    sectors = pos + 2048  # room for the backup GPT
    if os.path.exists(IMG):
        os.remove(IMG)
    h.make_disk(IMG, sectors)
    table = "".join(f"start={s}, size={mib * h.MB}, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name=\"{name}\"\n"
                    for s, (name, _, mib) in zip(starts, VOLUMES))
    subprocess.run(["sfdisk", "--quiet", "--label", "gpt", IMG], input=table, text=True, check=True,
                   stdout=subprocess.DEVNULL)
    env = dict(os.environ, MTOOLS_SKIP_CHECK="1")
    for s, (name, options, mib) in zip(starts, VOLUMES):
        vol = os.path.join(OUT, f"{name}.vol")
        if os.path.exists(vol):
            os.remove(vol)
        h.run("mkfs.fat", "-C", *options, "-n", "Z" + name.upper(), vol, str(mib * 1024))
        for src, dst in ((script, "fstest.sh"), (SEED, "seed.bin")):
            subprocess.run(["mcopy", "-i", vol, src, f"::/{dst}"], check=True, env=env)
        with open(vol, "rb") as src, open(IMG, "r+b") as dst:
            dst.seek(s * h.SECTOR)
            shutil.copyfileobj(src, dst)
        os.remove(vol)
    os.remove(script)
    return starts


# READING A VOLUME'S DIRECTORIES ON THE HOST

LFN_OFFSETS = (1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30)


def short_text(raw):
    # "NAME    EXT" as NAME.EXT, lower case where the NT flags say so.
    base, ext = raw[:8].rstrip(b" "), raw[8:11].rstrip(b" ")
    if base[:1] == b"\x05":
        base = b"\xe5" + base[1:]
    if raw[12] & 0x08:
        base = base.lower()
    if raw[12] & 0x10:
        ext = ext.lower()
    name = base.decode("cp437")
    return name + ("." + ext.decode("cp437") if ext else "")


def entries(vol, first=None):
    # (name, short name, raw entry), labels and deleted ones left out.
    out = []
    pieces = {}
    for pos in vol.dir_offsets(first):
        raw = vol.read(pos, 32)
        if raw[0] == 0:
            break
        if raw[0] == 0xE5:
            pieces = {}
            continue
        if raw[11] & 0x3F == 0x0F:
            units = [h.u16(raw, o) for o in LFN_OFFSETS]
            pieces[raw[0] & 0x1F] = units
            continue
        if raw[11] & 0x08:
            pieces = {}
            continue
        long_name = None
        if pieces:
            units = []
            for k in sorted(pieces):
                units += pieces[k]
            units = [u for u in units if u not in (0, 0xFFFF)]
            long_name = bytes(b for u in units for b in u.to_bytes(2, "little")).decode("utf-16-le", "replace")
        short = short_text(raw)
        out.append((long_name or short, short, raw))
        pieces = {}
    return out


def find_dir(vol, path):
    # None for the root, False if missing.
    first = None
    for part in [p for p in path.split("/") if p]:
        match = [raw for name, short, raw in entries(vol, first)
                 if part.lower() in (name.lower(), short.lower()) and raw[11] & 0x10]
        if not match:
            return False
        first = first_cluster(vol, match[0])
    return first


def first_cluster(vol, raw):
    hi = h.u16(raw, 20) if vol.kind == "fat32" else 0
    return (hi << 16) | h.u16(raw, 26)


def names_in(vol, path):
    first = find_dir(vol, path)
    if first is False:
        return None
    return [name for name, _, _ in entries(vol, first) if name not in (".", "..")]


def short_names_in(vol, path):
    first = find_dir(vol, path)
    if first is False:
        return None
    return [raw[:11] for _, _, raw in entries(vol, first) if raw[:1] != b"."]


def read_file(base, path):
    env = dict(os.environ, MTOOLS_SKIP_CHECK="1")
    p = subprocess.run(["mtype", "-i", f"{IMG}@@{base * h.SECTOR}", f"::/{path}"],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
    return p.stdout if p.returncode == 0 else None


def text_of(base, path):
    data = read_file(base, path)
    return None if data is None else data.replace(b"\r", b"").decode("latin-1")


def check_volume(name, start, mib):
    # (passed, detail lines) for one volume after its fstest.sh.
    lines = []
    fails = []

    def check(ok, what):
        lines.append(("PASS " if ok else "FAIL ") + what)
        if not ok:
            fails.append(what)

    ok, report = h.fsck(IMG, start, mib * h.MB)
    check(ok is True, f"fsck.fat -n: {report}")
    log = text_of(start, "fstest.log") or ""
    check("fstest done" in log, "fstest.sh ran to the end")
    guest_fails = [line for line in log.splitlines() if line.startswith("FAIL")]
    check(not guest_fails, "no FAIL step in fstest.sh" + ("" if not guest_fails else ": " + "; ".join(guest_fails[:5])))

    vol = h.Vol(IMG, start * h.SECTOR)
    for d in ("", "many", "newdir", "source", "source/inner"):
        names = names_in(vol, d)
        if names is None:
            check(False, f"/{d} exists")
            continue
        folded = [n.lower() for n in names]
        check(len(folded) == len(set(folded)), f"/{d}: no name twice (ignoring case)")
        shorts = short_names_in(vol, d)
        check(len(shorts) == len(set(shorts)), f"/{d}: no short name twice")

    root = names_in(vol, "") or []
    check(root.count("lower.txt") == 1, "one lower.txt in the root, in lower case")
    check(text_of(start, "lower.txt") == "again\n", "lower.txt holds what Lower.Txt wrote")
    check("upper.txt" in root and "UPPER.TXT" not in root, "UPPER.TXT renamed to upper.txt")
    check(text_of(start, "A long file name.text") == "long\n", "the long name with spaces")
    for i in range(1, 13):
        check(text_of(start, f"longname_alias_{i}.txt") == f"alias {i}\n", f"longname_alias_{i}.txt")
    check(text_of(start, "t_alias.txt") == "alias 11\n", "opened by long name in other case")
    if h.EDITION != "uefi":
        # ZDOS'S ALIASES (UEFI: the firmware's driver has its own): LONGNA~1 ... LONGNA~9, THEN LONGN~10 ... LONGN~12:
        check(text_of(start, "t_short.txt") == "alias 1\n", "opened by its alias LONGNA~1.TXT")
        shorts = {s.decode("cp437") for s in (short_names_in(vol, "") or [])}
        want_aliases = {f"LONGNA~{i}TXT" for i in range(1, 10)} | {f"LONGN~{i}TXT" for i in range(10, 13)}
        check(want_aliases <= shorts, "aliases LONGNA~1 ... LONGNA~9, LONGN~10 ... LONGN~12"
              + ("" if want_aliases <= shorts else f" (missing {sorted(want_aliases - shorts)[:4]})"))

    many = sorted(n.lower() for n in (names_in(vol, "many") or []))
    want = sorted([f"f_{i}.txt" for i in range(1, 1200, 2)] + ["f_0.txt"] +
                  [f"long entry number {i}.txt" for i in range(300)] + [f"g_{i}.txt" for i in range(300)])
    check(many == want, f"/many holds exactly the {len(want)} expected names"
          + ("" if many == want else f" (has {len(many)})"))
    check(text_of(start, "many/f_0.txt") == "back\n", "/many/f_0.txt created again")
    check(text_of(start, "many/long entry number 299.txt") == "long 299\n", "a long name in /many")
    check(text_of(start, "t_last.txt") == "f 1199\n", "opened /many/f_1199.txt")

    newdir = names_in(vol, "newdir")
    check(newdir == ["x_3.txt"], "/newdir holds only x_3.txt (nothing of the deleted olddir)")
    check(names_in(vol, "olddir") is None, "/olddir is gone")
    check(text_of(start, "source/inner/moved file.txt") == "moved\n", "the moved file, under its moved directory")
    check(names_in(vol, "target") is None and names_in(vol, "dest dir renamed") is None, "old directory names gone")
    inner = find_dir(vol, "source/inner")
    src = find_dir(vol, "source")
    if inner and src is not False:
        dotdot = [raw for name, _, raw in entries(vol, inner) if name == ".."]
        check(bool(dotdot) and first_cluster(vol, dotdot[0]) == (src or 0), "source/inner's \"..\" points at source")

    seed_md5 = hashlib.md5(open(SEED, "rb").read()).hexdigest()
    copy = read_file(start, "copy.bin")
    check(copy is not None and hashlib.md5(copy).hexdigest() == seed_md5, "copy.bin matches seed.bin")
    check(text_of(start, "copy2.bin") == "short\n", "copy2.bin truncated")
    check("gone.bin" not in root and "ro.txt" not in root, "gone.bin and ro.txt deleted")

    if name == "fat12":
        check(not any(n.startswith("r_") for n in root), "the root's r_ files deleted")
        check(text_of(start, "after_full.txt") == "after\n", "a file created after the full root emptied")
    return not fails, lines


def main():
    if len(sys.argv) != 2 or sys.argv[1] != "run":
        raise SystemExit("Usage: fat-tests.py run")
    h.require_system()
    for tool in ("mkfs.fat", "fsck.fat", "mcopy", "mtype", "sfdisk"):
        if shutil.which(tool) is None:
            raise SystemExit(f"{tool} is missing (dosfstools, mtools, util-linux)")
    os.makedirs(OUT, exist_ok=True)
    starts = make()

    finished = {}
    stalled = {}
    steps = [("wait", 2)] + h.command("ASH", 3)
    for i, (name, _, _) in enumerate(VOLUMES):
        drive = "Z" + name.upper()  # its label: the letters differ between BIOS and UEFI
        progress = {"len": -1, "since": time.time()}

        def until(start=starts[i], name=name, drive=drive, progress=progress):
            # Done, or stuck: fstest.log hasn't grown for STALL_TIME seconds:
            log = text_of(start, "fstest.log") or ""
            finished[name] = "fstest done" in log
            if len(log) != progress["len"]:
                progress["len"], progress["since"] = len(log), time.time()
            elif time.time() - progress["since"] > STALL_TIME:
                last = log.strip().splitlines()[-1] if log.strip() else "nothing logged"
                stalled[name] = f"fstest.sh stopped making progress after: {last}"
                print(f"  {name} ({drive}) seems stuck after: {last}", flush=True)
                return True
            return finished[name]

        steps += h.cd_label(drive, 2) + h.command(f"fstest.sh {name[3:]} {h.EDITION}", 1) + \
            [("until", until, FSTEST_TIME), ("wait", 2), ("shot", f"0{i + 1}-{name}", f"fstest.sh on {name} ({drive})")]
    sock = os.path.join(OUT, "mon.sock")
    shots = h.run_qemu(h.machine_args(sock, IMG, OUT), steps, SHOTS, sock, boot_wait=h.BOOT_WAIT)

    results = []
    all_passed = True
    for i, (name, _, mib) in enumerate(VOLUMES):
        passed, lines = check_volume(name, starts[i], mib)
        if not finished.get(name):
            passed = False
            lines.insert(0, "FAIL " + stalled.get(name, f"fstest.sh didn't finish in {FSTEST_TIME} s"))
        with open(os.path.join(OUT, f"{name}-check.txt"), "w") as f:
            f.write("\n".join(lines) + "\n")
        fails = [line[5:] for line in lines if line.startswith("FAIL ")]
        detail = f"{len(lines) - len(fails)} checks passed" + ("" if not fails else ": " + "; ".join(fails[:6]))
        results.append((name, passed, f"fstest.sh on {name}: every step PASS, fsck.fat clean, every change as expected",
                        detail, [s for s in shots if name in s[0]]))
        print(f"{'PASS' if passed else 'FAIL'}  {name}: {detail}", flush=True)
        all_passed = all_passed and passed
    h.write_results(os.path.join(OUT, "RESULTS.md"), f"FAT test results ({h.EDITION})", results)
    if all_passed:
        os.remove(IMG)
    os.remove(SEED)
    sys.exit(1 if h.summary(results) else 0)


if __name__ == "__main__":
    main()
