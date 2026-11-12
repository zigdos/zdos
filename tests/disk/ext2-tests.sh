#!/usr/bin/env bash
# Tests ZDOS's ext2 driver (BIOS edition) against e2fsprogs;
# ext2-tests.py runs it all unattended.
#   ext2-tests.sh make | run | check | fsck
# In ZDOS: cd /E:/ ; fstest.sh F:   (E: ext2 ZTEST, F: the FAT ZFAT)
# BLOCK=1024 ... 65536 picks the block size (default 1024: deeper maps).
# BIG=1: sparse files past 2, 4, 16 and 18 GiB on ext2big.img; run
# bigfiles.sh in the root of each ZBIG volume.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
# EXT2_OUT overrides:
OUT=${EXT2_OUT:-$repo/build/ext2-tests}
mkdir -p "$OUT"
IMG=$OUT/ext2.img
FS=$OUT/ext2.fs # the partition alone, for e2fsprogs
SEED=$OUT/ext2_seed
BLOCK=${BLOCK:-1024}
BIG=${BIG:-0}
BIGIMG=$OUT/ext2big.img
BIG_SEED=$OUT/ext2big_seed
BIG_PART=$((512 * 2048)) # sectors: 512 MiB each
BIG_P1=2048
BIG_P2=$((BIG_P1 + BIG_PART))
NEAR2G=$((2147483648 - 4)) # sizes before the appends
NEAR4G=$((4294967296 - 4))
BIG_P3=$((BIG_P2 + BIG_PART))
NEAR18G=$((18 * 1073741824 - 4))
# The end of a 1 KB-block map: 12 direct, 256, 256^2, 256^3 blocks:
LIMIT1K=$(((12 + 256 + 65536 + 16777216) * 1024))
NEAR16G=$((LIMIT1K - 4))
SIZE_MB=64
PART_START=2048 # sectors
FAT_SECTORS=$((8 * 2048)) # the FAT partition after it: 8 MiB, up to the backup GPT (33 sectors at the end)
PART_SECTORS=$((SIZE_MB * 2048 - PART_START - FAT_SECTORS - 34))
FAT_START=$((PART_START + PART_SECTORS))
FATFS=$OUT/ext2_fat.fs
export MTOOLS_SKIP_CHECK=1

need() {
    for c in "$@"; do
        command -v "$c" >/dev/null || { echo "missing: $c"; exit 1; }
    done
}

# Runs in ZDOS's ash, from the root of the ext2 volume:
write_fstest() {
    cat >"$1" <<'EOF'
# ZDOS ext2 driver test: cd /E:/ ; fstest.sh F:
log=fstest.log
# The steps change the disk: a second run would fail:
if [ -e $log ]; then
    echo "fstest.sh ran on this disk already: make a fresh one (ext2-tests.sh make)"
    exit 1
fi
echo "fstest start" > $log

# step NAME WANT STATUS: WANT is ok or fail (must be refused)
step() {
    if [ "$2" = ok ]; then
        if [ "$3" = 0 ]; then r=PASS; else r=FAIL; fi
    else
        if [ "$3" = 0 ]; then r=FAIL; else r=PASS; fi
    fi
    echo "$r $1 (status $3)" >> $log
    echo "$r $1"
}

echo "new file" > t_new.txt
step "create file with >" ok $?
echo "line2" >> t_new.txt
step "append to new file" ok $?
echo "appended" >> hello.txt
step "append to existing file" ok $?
echo "short" > overwrite.txt
step "truncate 200 KB file with >" ok $?
touch t_touch.txt
step "touch creates empty file" ok $?

mkdir t_dir
step "mkdir" ok $?
mkdir -p t_dir/outer/middle/inner
step "mkdir -p nested" ok $?
echo "deep" > t_dir/outer/middle/inner/deep.txt
step "create file in nested dir" ok $?

cp big.bin t_dir/big_copy.bin
step "cp 1 MB file (indirect blocks)" ok $?
cp t_dir/big_copy.bin big2.bin
step "cp the 1 MB copy again (reads what ZDOS wrote)" ok $?

mv t_new.txt t_dir/moved.txt
step "mv file into dir" ok $?
mv t_dir/outer t_dir/renamed
step "rename dir" ok $?
mv t_dir/renamed/middle ./moved
step "move dir to other parent" ok $?
mv CaseTest.txt casetest.txt
step "rename changing case only" ok $?

rm delete_me.txt
step "rm file" ok $?
rmdir empty_dir
step "rmdir empty dir" ok $?
rmdir t_dir
step "rmdir non-empty dir refused" fail $?
rm -r tree_del
step "rm -r tree" ok $?
rm link_a.txt
step "rm one name of a hard link" ok $?

st=0
i=0
while [ $i -lt 150 ]; do
    echo "new $i" > many/new_$i.txt || st=1
    i=$((i + 1))
done
step "create 150 files in hashed dir" ok $st
st=0
i=0
while [ $i -lt 50 ]; do
    rm many/f_$i.txt || st=1
    i=$((i + 1))
done
step "delete 50 files in hashed dir" ok $st

echo "x" > readonly.txt
step "write to read-only file refused" fail $?

# Permissions and owners, checked with debugfs afterwards:
chmod 600 perm.txt
step "chmod 600" ok $?
chmod u+x,go-r perm2.txt
step "chmod u+x,go-r" ok $?
chmod -R 750 permdir
step "chmod -R 750" ok $?
chown 1000:100 own.txt
step "chown 1000:100" ok $?
chown :200 grp.txt
step "chown :200 (group only)" ok $?
chown 70000:70001 bigid.txt
step "chown ids above 65535" ok $?
chmod 444 ro2.txt
step "chmod 444" ok $?
echo "no" > ro2.txt
step "write after chmod 444 refused" fail $?
chmod 644 ro2.txt
step "chmod 644" ok $?
echo "yes" > ro2.txt
step "write after chmod 644" ok $?
ls -l perm.txt own.txt > t_ls.txt
step "ls -l" ok $?
chmod 9999 perm.txt
step "chmod 9999 refused" fail $?
chown 5 no_such_file.txt
step "chown of a missing file refused" fail $?

# FAT: only the read-only attribute, no owners:
fat=${1:-}
if [ -z "$fat" ]; then fat=$(DRIVES | grep ZFAT | awk '{ print $1 }'); fi
if [ -z "$fat" ]; then
    step "FAT drive ZFAT found (give it: fstest.sh F:)" ok 1
else
    chmod 444 /$fat/ro.txt
    step "FAT: chmod 444 sets read-only" ok $?
    echo "x" > /$fat/ro.txt
    step "FAT: write to it refused" fail $?
    chmod 644 /$fat/rw.txt
    step "FAT: chmod 644 clears read-only" ok $?
    echo "fat" > /$fat/rw.txt
    step "FAT: write after chmod 644" ok $?
    ls -l /$fat/ro.txt > t_fatls.txt
    step "FAT: ls -l" ok $?
    chown 1000 /$fat/rw.txt
    step "FAT: chown refused (no owners)" fail $?
fi

cp -r t_dir t_dir_copy
step "cp -r dir tree" ok $?

# The driver's machinery: directory packing, the name index, multi
# block reads and writes, freeing in batches:
mkdir pack
st=0
i=0
while [ $i -lt 200 ]; do
    echo "p $i" > pack/pack_$i.txt || st=1
    i=$((i + 1))
done
step "create 200 files in a new dir" ok $st
rm pack/pack_10.txt
step "delete one of them" ok $?
echo "again" > pack/pack_10.txt
step "create the deleted name again" ok $?
cat PACK/PACK_20.TXT > t_fold.txt
step "letter case counts: PACK/PACK_20.TXT is not pack/pack_20.txt" fail $?
echo "upper" > Both.txt
echo "lower" > both.txt
step "two names differing only in letter case" ok $?
mkdir pack2
step "mkdir pack2" ok $?
mv pack/pack_30.txt pack2/pack_30.txt
step "move a file to another dir" ok $?
cat pack2/pack_30.txt > t_moved.txt
step "read the moved file" ok $?
cat pack/pack_30.txt > t_gone.txt
step "the moved file is gone from its old dir" fail $?
cp odd.bin odd2.bin
step "copy an odd-sized file" ok $?
echo "appended" >> odd2.bin
step "append past its odd end" ok $?
cp odd2.bin odd3.bin
step "copy the result" ok $?
cp big.bin big3.bin
step "make another 1 MB copy" ok $?
rm big3.bin
step "delete a 1 MB file" ok $?
echo "short" > odd3.bin
step "truncate the 300 KB copy" ok $?

echo "fstest done" >> $log
echo "fstest done: see fstest.log"
EOF
    chmod +x "$1" # run as fstest.sh / bigfiles.sh: Unix needs the bit
}

cmd_make() {
    need mke2fs e2fsck dumpe2fs debugfs sfdisk md5sum mkfs.fat mcopy mattrib
    rm -rf "$SEED"
    mkdir -p "$SEED"
    printf 'Hello from Linux\n' >"$SEED/hello.txt"
    head -c 1048576 /dev/urandom >"$SEED/big.bin"
    head -c 300001 /dev/urandom >"$SEED/odd.bin" # no block size divides it
    head -c 204800 /dev/urandom >"$SEED/overwrite.txt"
    printf 'delete me\n' >"$SEED/delete_me.txt"
    printf 'case\n' >"$SEED/CaseTest.txt"
    printf 'read only\n' >"$SEED/readonly.txt"
    chmod 444 "$SEED/readonly.txt"
    for f in perm perm2 own grp bigid ro2; do printf '%s\n' "$f" >"$SEED/$f.txt"; done
    mkdir "$SEED/permdir"
    printf 'inner\n' >"$SEED/permdir/inner.txt"
    chmod 644 "$SEED"/perm.txt "$SEED"/perm2.txt "$SEED"/own.txt "$SEED"/grp.txt "$SEED"/bigid.txt "$SEED"/ro2.txt
    mkdir "$SEED/empty_dir"
    mkdir -p "$SEED/tree_del/sub/subsub"
    printf 'a\n' >"$SEED/tree_del/a.txt"
    printf 'b\n' >"$SEED/tree_del/sub/b.txt"
    head -c 30000 /dev/urandom >"$SEED/tree_del/sub/subsub/c.bin"
    printf 'linked\n' >"$SEED/link_a.txt"
    ln "$SEED/link_a.txt" "$SEED/link_b.txt"
    mkdir "$SEED/many"
    for i in $(seq 0 299); do printf 'f %d\n' "$i" >"$SEED/many/f_$i.txt"; done
    write_fstest "$SEED/fstest.sh"

    rm -f "$FS" "$IMG"
    truncate -s $((PART_SECTORS * 512)) "$FS"
    mke2fs -q -F -t ext2 -b "$BLOCK" -L ZTEST -d "$SEED" "$FS"
    # Index the big directory (dir_index), as Linux would have:
    set +e
    e2fsck -fyD "$FS" >/dev/null
    rc=$?
    set -e
    [ $rc -le 1 ] || { echo "e2fsck -D failed ($rc)"; exit 1; }
    chmod 644 "$SEED/readonly.txt" # so make can be run again (the image keeps 444)

    truncate -s ${SIZE_MB}M "$IMG"
    printf '%s\n' "start=$PART_START, size=$PART_SECTORS, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=\"fstest\"" \
        "start=$FAT_START, size=$FAT_SECTORS, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name=\"zfat\"" |
        sfdisk --quiet --label gpt "$IMG"
    dd if="$FS" of="$IMG" bs=512 seek=$PART_START conv=notrunc status=none
    rm -f "$FS"
    # The FAT partition: ro.txt writable, rw.txt read-only (fstest swaps):
    rm -f "$FATFS"
    mkfs.fat -C -n ZFAT "$FATFS" $((FAT_SECTORS / 2)) >/dev/null
    printf 'fat ro\n' >"$SEED/ro.txt"
    printf 'fat rw\n' >"$SEED/rw.txt"
    mcopy -i "$FATFS" "$SEED/ro.txt" "$SEED/rw.txt" ::/
    mattrib -i "$FATFS" +r ::/rw.txt
    dd if="$FATFS" of="$IMG" bs=512 seek=$FAT_START conv=notrunc status=none
    rm -f "$FATFS" "$SEED/ro.txt" "$SEED/rw.txt"

    echo "ext2.img made (block size $BLOCK). Features:"
    extract
    dumpe2fs -h "$FS" 2>/dev/null | grep -E 'features|Block size|Inode size' || true
    if debugfs -R "htree /many" "$FS" 2>/dev/null | grep -q 'Root node'; then
        echo "/many is a hashed (dir_index) directory"
    fi
    set +e
    e2fsck -fn "$FS" >/dev/null 2>&1
    rc=$?
    set -e
    rm -f "$FS"
    [ $rc -eq 0 ] && echo "fresh image: e2fsck clean" || echo "fresh image: e2fsck reports $rc (unexpected)"
}

cmd_run() {
    if [ "$BIG" = 1 ]; then
        [ -f "$BIGIMG" ] || { echo "no ext2big.img: run BIG=1 ext2-tests.sh make first"; exit 1; }
        echo "In ZDOS: ls /   then for each ZBIG drive (ZBIG2G, ZBIG4G, ZBIG18):   cd /X:/   bigfiles.sh"
        exec "$repo/run-bios-x86.sh" -drive "file=$BIGIMG,format=raw,if=ide,index=2"
    fi
    [ -f "$IMG" ] || { echo "no ext2.img: run ext2-tests.sh make first"; exit 1; }
    echo "In ZDOS: ls /   then   cd /X:/   (the ext2 drive, ZTEST)   then   fstest.sh Y:   (the FAT drive, ZFAT)"
    exec "$repo/run-bios-x86.sh" -drive "file=$IMG,format=raw,if=ide,index=2"
}

# For e2fsprogs.
extract() {
    dd if="$IMG" of="$FS" bs=512 skip=$PART_START count=$PART_SECTORS status=none
}

pass=0
fail=0
ok() {
    pass=$((pass + 1))
    echo "  PASS $1"
}
bad() {
    fail=$((fail + 1))
    echo "  FAIL $1"
}

content() { debugfs -R "cat $1" "$FS" 2>/dev/null; }
# Without \r: files from other systems may have DOS line ends.
text() { content "$1" | tr -d '\r'; }
exists() { debugfs -R "stat $1" "$FS" 2>/dev/null | grep -q '^Inode:'; }
md5_img() { { content "$1" || true; } | md5sum | cut -d' ' -f1; }
md5_seed() { md5sum <"$SEED/$1" | cut -d' ' -f1; }

expect_content() { # PATH TEXT
    local got
    got=$(text "$1" || true)
    if [ "$got" = "$2" ]; then ok "$1 has the expected text"; else bad "$1: expected $(printf %q "$2"), got $(printf %q "$got")"; fi
}
expect_exists() { if exists "$1"; then ok "$1 exists"; else bad "$1 missing"; fi; }
expect_missing() { if exists "$1"; then bad "$1 still exists"; else ok "$1 gone"; fi; }
expect_same() { # PATH SEEDFILE
    if exists "$1" && [ "$(md5_img "$1")" = "$(md5_seed "$2")" ]; then ok "$1 matches $2"; else bad "$1 differs from $2"; fi
}
expect_mode() { # PATH OCTAL
    local m
    m=$(debugfs -R "stat $1" "$FS" 2>/dev/null | sed -n 's/.*Mode: *\([0-7]*\).*/\1/p' | head -1 || true)
    if [ "$m" = "$2" ]; then ok "$1 has mode $2"; else bad "$1 has mode ${m:-?}, expected $2"; fi
}
expect_ids() { # PATH UID GID (- for either)
    local st u g
    st=$(debugfs -R "stat $1" "$FS" 2>/dev/null || true)
    u=$(echo "$st" | sed -n 's/.*User: *\([0-9]*\).*/\1/p' | head -1)
    g=$(echo "$st" | sed -n 's/.*Group: *\([0-9]*\).*/\1/p' | head -1)
    if { [ "$2" = - ] || [ "$u" = "$2" ]; } && [ "$g" = "$3" ]; then ok "$1 is owned by $2:$3"; else
        bad "$1 is owned by ${u:-?}:${g:-?}, expected $2:$3"
    fi
}
expect_has() { # PATH TEXT: the file's text contains TEXT
    if text "$1" | grep -qF -- "$2"; then ok "$1 shows $(printf %q "$2")"; else bad "$1 lacks $(printf %q "$2")"; fi
}
fat_attr_r() { mattrib -i "$FATFS" "::/$1" 2>/dev/null | sed 's/::.*//' | grep -q R; }

expect_size() { # PATH BYTES
    local s
    s=$(debugfs -R "stat $1" "$FS" 2>/dev/null | sed -n 's/.*Size: \([0-9]*\).*/\1/p' | head -1 || true)
    if [ "$s" = "$2" ]; then ok "$1 is $2 bytes"; else bad "$1 is ${s:-?} bytes, expected $2"; fi
}
expect_links() { # PATH COUNT
    local n
    n=$(debugfs -R "stat $1" "$FS" 2>/dev/null | sed -n 's/.*Links: \([0-9]*\).*/\1/p' | head -1 || true)
    if [ "$n" = "$2" ]; then ok "$1 has $2 link(s)"; else bad "$1 has ${n:-?} links, expected $2"; fi
}

cmd_fsck() {
    need e2fsck
    extract
    set +e
    e2fsck -fn "$FS"
    rc=$?
    set -e
    rm -f "$FS"
    return $rc
}

cmd_check() {
    need e2fsck debugfs dumpe2fs md5sum mattrib mtype
    [ -f "$IMG" ] || { echo "no ext2.img"; exit 1; }
    extract

    echo "e2fsck -fn:"
    set +e
    out=$(e2fsck -fn "$FS" 2>&1)
    rc=$?
    set -e
    if [ $rc -eq 0 ]; then ok "e2fsck: clean"; else
        bad "e2fsck exit $rc:"
        echo "$out" | sed 's/^/      /'
    fi

    echo "fstest.log:"
    log=$(text /fstest.log || true)
    if [ -z "$log" ]; then bad "no /fstest.log: did fstest.sh run on this disk?"; else
        echo "$log" | sed 's/^/      /'
        if echo "$log" | grep -q '^fstest done'; then ok "fstest.sh ran to the end"; else bad "fstest.sh did not finish"; fi
        if echo "$log" | grep -q '^FAIL'; then bad "fstest.sh reported FAIL steps"; else ok "no FAIL step in fstest.sh"; fi
    fi

    echo "Results on the disk:"
    expect_missing /t_new.txt
    expect_content /t_dir/moved.txt $'new file\nline2'
    expect_content /hello.txt $'Hello from Linux\nappended'
    expect_content /overwrite.txt "short"
    expect_size /overwrite.txt 6 # "short\n"
    expect_exists /t_touch.txt
    expect_size /t_touch.txt 0
    expect_exists /t_dir/renamed
    expect_missing /t_dir/outer
    expect_missing /t_dir/renamed/middle
    expect_content /moved/inner/deep.txt "deep"
    expect_same /t_dir/big_copy.bin big.bin
    expect_same /big2.bin big.bin
    expect_same /big.bin big.bin
    # On ext2 a change of letter case renames between two names:
    expect_exists /casetest.txt
    expect_missing /CaseTest.txt
    expect_missing /delete_me.txt
    expect_missing /empty_dir
    expect_missing /tree_del
    expect_exists /t_dir
    expect_missing /link_a.txt
    expect_content /link_b.txt "linked"
    expect_links /link_b.txt 1
    expect_content /readonly.txt "read only"
    expect_content /t_dir_copy/moved.txt $'new file\nline2'
    expect_same /t_dir_copy/big_copy.bin big.bin
    expect_exists /t_dir_copy/renamed
    # Directory link counts: 2 + subdirectories:
    expect_links /t_dir 3         # renamed
    expect_links /t_dir/renamed 2 # middle moved away
    expect_links /moved 3         # inner

    local listing new_count f_count
    listing=$(debugfs -R "ls -p /many" "$FS" 2>/dev/null || true)
    # Entries with inode 0 are deleted ones (a block's first is kept so):
    listing=$(echo "$listing" | grep '^/[1-9]' || true)
    new_count=$(echo "$listing" | grep -c '/new_[0-9]*\.txt/' || true)
    f_count=$(echo "$listing" | grep -c '/f_[0-9]*\.txt/' || true)
    if [ "$new_count" = 150 ]; then ok "/many has 150 new files"; else bad "/many has $new_count new files, expected 150"; fi
    if [ "$f_count" = 250 ]; then ok "/many has 250 of the original files"; else bad "/many has $f_count original files, expected 250"; fi
    expect_content /many/new_149.txt "new 149"
    expect_missing /many/f_0.txt
    expect_content /many/f_50.txt "f 50"

    echo "Directory packing, index, multi-block I/O, freeing:"
    local pack_list pack_count pack_size bs limit
    pack_list=$(debugfs -R "ls -p /pack" "$FS" 2>/dev/null | grep '^/[1-9]' || true)
    pack_count=$(echo "$pack_list" | grep -c '/pack_[0-9]*\.txt/' || true)
    if [ "$pack_count" = 199 ]; then ok "/pack has 199 files"; else bad "/pack has $pack_count files, expected 199"; fi
    if [ "$(echo "$pack_list" | grep -c '/pack_10\.txt/' || true)" = 1 ]; then ok "/pack/pack_10.txt is there once"; else
        bad "/pack/pack_10.txt is not there exactly once"
    fi
    # 200 entries of at most 24 bytes, ".", "..": packed, not 2 per block:
    bs=$(dumpe2fs -h "$FS" 2>/dev/null | sed -n 's/^Block size: *//p')
    pack_size=$(debugfs -R "stat /pack" "$FS" 2>/dev/null | sed -n 's/.*Size: \([0-9]*\).*/\1/p' | head -1 || true)
    limit=$(((4824 / bs + 2) * bs))
    if [ -n "$pack_size" ] && [ "$pack_size" -le "$limit" ]; then ok "/pack is $pack_size bytes (at most $limit)"; else
        bad "/pack is ${pack_size:-?} bytes, more than $limit: entries not packed"
    fi
    expect_content /pack/pack_10.txt "again"
    expect_size /t_fold.txt 0
    expect_content /Both.txt "upper"
    expect_content /both.txt "lower"
    expect_content /pack2/pack_30.txt "p 30"
    expect_content /t_moved.txt "p 30"
    expect_missing /pack/pack_30.txt
    if [ "$(md5_img /odd2.bin)" = "$({ cat "$SEED/odd.bin"; printf 'appended\n'; } | md5sum | cut -d' ' -f1)" ]; then
        ok "/odd2.bin is odd.bin and the appended line"
    else
        bad "/odd2.bin is not odd.bin and the appended line"
    fi
    expect_size /odd2.bin 300010
    expect_content /odd3.bin "short"
    expect_missing /big3.bin
    # QEMU is just stopped: every change ends with the volume clean again:
    if dumpe2fs -h "$FS" 2>/dev/null | grep -q '^Filesystem state: *clean'; then ok "superblock: clean"; else
        bad "superblock: not clean after the last change"
    fi

    echo "Permissions:"
    expect_mode /perm.txt 0600
    expect_mode /perm2.txt 0700
    expect_mode /permdir 0750
    expect_mode /permdir/inner.txt 0750
    expect_ids /own.txt 1000 100
    expect_ids /grp.txt - 200
    expect_ids /bigid.txt 70000 70001
    expect_mode /ro2.txt 0644
    expect_content /ro2.txt "yes"
    expect_has /t_ls.txt "-rw------- "
    expect_has /t_ls.txt " 1000   100 "

    echo "FAT partition:"
    dd if="$IMG" of="$FATFS" bs=512 skip=$FAT_START count=$FAT_SECTORS status=none
    if fat_attr_r ro.txt; then ok "FAT ro.txt is read-only"; else bad "FAT ro.txt is not read-only"; fi
    if fat_attr_r rw.txt; then bad "FAT rw.txt is still read-only"; else ok "FAT rw.txt is writable"; fi
    got=$(mtype -i "$FATFS" ::/rw.txt 2>/dev/null | tr -d '\r' || true)
    if [ "$got" = "fat" ]; then ok "FAT rw.txt was written"; else bad "FAT rw.txt: $(printf %q "$got")"; fi
    got=$(mtype -i "$FATFS" ::/ro.txt 2>/dev/null | tr -d '\r' || true)
    if [ "$got" = "fat ro" ]; then ok "FAT ro.txt kept its text"; else bad "FAT ro.txt: $(printf %q "$got")"; fi
    rm -f "$FATFS"
    # FAT's made-up mode (everyone's drive: 0777, the read-only
    # attribute takes the write bits) and owner (who asks: root here):
    expect_has /t_fatls.txt "-r-xr-xr-x "
    expect_has /t_fatls.txt "    0     0 "

    rm -f "$FS"
    echo
    echo "passed $pass, failed $fail"
    [ $fail -eq 0 ]
}

# BIG=1

write_bigfiles() {
    cat >"$1" <<'ZBIG'
# ZDOS ext2 big-file test: cd /X:/ ; bigfiles.sh in each ZBIG volume
log=bigfiles.log
echo "bigfiles start" > $log

step() {
    if [ "$2" = ok ]; then
        if [ "$3" = 0 ]; then r=PASS; else r=FAIL; fi
    else
        if [ "$3" = 0 ]; then r=FAIL; else r=PASS; fi
    fi
    echo "$r $1 (status $3)" >> $log
    echo "$r $1"
}

if [ -f near2g.bin ]; then
    xxd -s 2147483628 -l 16 near2g.bin > end_before.txt
    step "read the end of a 2 GiB file (seek)" ok $?
    echo "PAST2G" >> near2g.bin
    step "append past 2 GiB (sets large_file)" ok $?
    xxd -s 2147483640 -l 16 near2g.bin > end_after.txt
    step "read back past 2 GiB" ok $?
fi
if [ -f near4g.bin ]; then
    echo "PAST4G" >> near4g.bin
    step "append past 4 GiB (i_size_high, triple indirect)" ok $?
    xxd -s 4294967288 -l 16 near4g.bin > end_after.txt
    step "read back past 4 GiB" ok $?
    rm del4g.bin
    step "delete a 4 GiB sparse file (triple-indirect tree)" ok $?
fi
if [ -f near16g.bin ]; then
    printf "ab" >> near16g.bin
    step "append up to the end of the 1 KB block map" ok $?
    echo "TOOLONG" >> near16g.bin
    step "append past the end of the block map refused" fail $?
    xxd -s 17247252472 -l 16 near16g.bin > end16_after.txt
    step "read the end of the 16 GiB file" ok $?
fi
if [ -f near18g.bin ]; then
    echo "PAST18G" >> near18g.bin
    step "append past 18 GiB on 4 KB blocks (triple indirect)" ok $?
    xxd -s 19327352824 -l 16 near18g.bin > end_after.txt
    step "read back past 18 GiB" ok $?
fi
echo "bigfiles done" >> $log
echo "bigfiles done: see bigfiles.log"
ZBIG
    chmod +x "$1" # run as fstest.sh / bigfiles.sh: Unix needs the bit
}

# PATH SIZE: "HEAD" at 0, "TAIL" in the last 4 bytes, a hole between
sparse_file() {
    truncate -s "$2" "$1"
    printf HEAD | dd of="$1" conv=notrunc status=none
    printf TAIL | dd of="$1" bs=1 seek=$(($2 - 4)) conv=notrunc status=none
}

# FS BLOCK LABEL SEEDDIR [mke2fs options]
make_fs() {
    local fs=$1 block=$2 label=$3 seed=$4
    shift 4
    rm -f "$fs"
    truncate -s $((BIG_PART * 512)) "$fs"
    mke2fs -q -F -t ext2 -b "$block" -L "$label" "$@" -d "$seed" "$fs"
}

big_extract() { # FS START
    dd if="$BIGIMG" of="$1" bs=512 skip="$2" count=$BIG_PART conv=sparse status=none
}

has_feature() { dumpe2fs -h "$1" 2>/dev/null | grep -i '^Filesystem features' | grep -qw "$2"; }

# LEN bytes of PATH at OFFSET, unprintable ones and holes as "."
read_bytes() { # FS PATH OFFSET LEN
    local fs=$1 path=$2 off=$3 len=$4 bs out="" lblk in n phys
    bs=$(dumpe2fs -h "$fs" 2>/dev/null | sed -n 's/^Block size: *//p')
    while [ "$len" -gt 0 ]; do
        lblk=$((off / bs))
        in=$((off % bs))
        n=$((bs - in))
        [ $n -gt "$len" ] && n=$len
        phys=$(debugfs -R "bmap $path $lblk" "$fs" 2>/dev/null | tail -1 || true)
        if [ -z "$phys" ] || [ "$phys" = 0 ]; then
            out+=$(printf '%*s' $n '' | tr ' ' '.')
        else
            out+=$(dd if="$fs" bs=1 skip=$((phys * bs + in)) count=$n status=none | tr -c '[:print:]' '.')
        fi
        off=$((off + n))
        len=$((len - n))
    done
    printf %s "$out"
}

big_make() {
    need mke2fs e2fsck dumpe2fs debugfs sfdisk truncate
    rm -rf "$BIG_SEED"
    mkdir -p "$BIG_SEED/part1" "$BIG_SEED/part2"
    sparse_file "$BIG_SEED/part1/near2g.bin" $NEAR2G
    sparse_file "$BIG_SEED/part2/near4g.bin" $NEAR4G
    sparse_file "$BIG_SEED/part2/del4g.bin" $((4294967296 + 100))
    sparse_file "$BIG_SEED/part2/near16g.bin" $NEAR16G
    mkdir -p "$BIG_SEED/part3"
    sparse_file "$BIG_SEED/part3/near18g.bin" $NEAR18G
    write_bigfiles "$BIG_SEED/part1/bigfiles.sh"
    write_bigfiles "$BIG_SEED/part2/bigfiles.sh"
    write_bigfiles "$BIG_SEED/part3/bigfiles.sh"

    local fs1=$OUT/ext2big1.fs fs2=$OUT/ext2big2.fs fs3=$OUT/ext2big3.fs
    # resize_inode's inode is over 2 GiB and would bring large_file back:
    make_fs "$fs1" 4096 ZBIG2G "$BIG_SEED/part1" -O ^large_file,^resize_inode
    make_fs "$fs2" 1024 ZBIG4G "$BIG_SEED/part2"
    make_fs "$fs3" 4096 ZBIG18 "$BIG_SEED/part3"
    if has_feature "$fs1" large_file; then
        echo "ZBIG2G got large_file from mke2fs: the test needs it off"
        exit 1
    fi

    rm -f "$BIGIMG"
    truncate -s $(((BIG_P3 + BIG_PART + 2048) * 512)) "$BIGIMG"
    local linux=0FC63DAF-8483-4772-8E79-3D69D8477DE4
    printf 'start=%d, size=%d, type=%s, name="bigfiles2g"\nstart=%d, size=%d, type=%s, name="bigfiles4g"\nstart=%d, size=%d, type=%s, name="bigfiles18"\n' \
        $BIG_P1 $BIG_PART $linux $BIG_P2 $BIG_PART $linux $BIG_P3 $BIG_PART $linux | sfdisk --quiet --label gpt "$BIGIMG"
    dd if="$fs1" of="$BIGIMG" bs=512 seek=$BIG_P1 conv=notrunc,sparse status=none
    dd if="$fs2" of="$BIGIMG" bs=512 seek=$BIG_P2 conv=notrunc,sparse status=none
    dd if="$fs3" of="$BIGIMG" bs=512 seek=$BIG_P3 conv=notrunc,sparse status=none

    for fs in "$fs1" "$fs2" "$fs3"; do
        set +e
        e2fsck -fn "$fs" >/dev/null 2>&1
        rc=$?
        set -e
        echo "$(basename "$fs"): e2fsck $([ $rc -eq 0 ] && echo clean || echo "reports $rc (unexpected)")"
    done
    rm -f "$fs1" "$fs2" "$fs3"
    echo "ext2big.img made: ZBIG2G (4 KB blocks, no large_file), ZBIG4G (1 KB blocks), ZBIG18 (4 KB blocks)"
}

big_part_check() { # FS LABEL
    local fs=$1 label=$2 out log rc
    echo "$label: e2fsck -fn:"
    set +e
    out=$(e2fsck -fn "$fs" 2>&1)
    rc=$?
    set -e
    if [ $rc -eq 0 ]; then ok "$label: e2fsck clean"; else
        bad "$label: e2fsck exit $rc:"
        echo "$out" | sed 's/^/      /'
    fi
    log=$(debugfs -R "cat /bigfiles.log" "$fs" 2>/dev/null | tr -d '\r' || true)
    if [ -z "$log" ]; then
        bad "$label: no /bigfiles.log: did bigfiles.sh run on this volume?"
        return
    fi
    echo "$log" | sed 's/^/      /'
    if echo "$log" | grep -q '^bigfiles done'; then ok "$label: bigfiles.sh ran to the end"; else bad "$label: bigfiles.sh did not finish"; fi
    if echo "$log" | grep -q '^FAIL'; then bad "$label: bigfiles.sh reported FAIL steps"; else ok "$label: no FAIL step"; fi
}

expect_bytes() { # FS PATH OFFSET LEN TEXT
    local got
    got=$(read_bytes "$1" "$2" "$3" "$4")
    if [ "$got" = "$5" ]; then ok "$2 at $3: $got"; else bad "$2 at $3: expected $5, got $got"; fi
}

expect_fs_size() { # FS PATH BYTES
    local s
    s=$(debugfs -R "stat $2" "$1" 2>/dev/null | sed -n 's/.*Size: \([0-9]*\).*/\1/p' | head -1 || true)
    if [ "$s" = "$3" ]; then ok "$2 is $3 bytes"; else bad "$2 is ${s:-?} bytes, expected $3"; fi
}

expect_text_in() { # FS PATH TEXT WHAT
    if debugfs -R "cat $2" "$1" 2>/dev/null | grep -q "$3"; then ok "$4"; else bad "$4: $2 lacks $3"; fi
}

expect_gone_in() { # FS PATH
    if debugfs -R "stat $2" "$1" 2>/dev/null | grep -q '^Inode:'; then bad "$2 still exists"; else ok "$2 gone"; fi
}

big_check() {
    need e2fsck debugfs dumpe2fs
    [ -f "$BIGIMG" ] || { echo "no ext2big.img"; exit 1; }
    local fs1=$OUT/ext2big1.fs fs2=$OUT/ext2big2.fs fs3=$OUT/ext2big3.fs
    big_extract "$fs1" $BIG_P1
    big_extract "$fs2" $BIG_P2
    big_extract "$fs3" $BIG_P3

    big_part_check "$fs1" ZBIG2G
    if has_feature "$fs1" large_file; then ok "ZBIG2G: large_file is set now"; else bad "ZBIG2G: large_file not set"; fi
    expect_fs_size "$fs1" /near2g.bin $((NEAR2G + 7)) # "PAST2G\n"
    expect_bytes "$fs1" /near2g.bin 0 4 HEAD
    expect_bytes "$fs1" /near2g.bin $((NEAR2G - 4)) 12 "TAILPAST2G.."
    expect_text_in "$fs1" /end_before.txt TAIL "ZDOS read TAIL at the end before the append"
    expect_text_in "$fs1" /end_after.txt TAILPAST2G "ZDOS read back past 2 GiB"

    big_part_check "$fs2" ZBIG4G
    expect_fs_size "$fs2" /near4g.bin $((NEAR4G + 7)) # "PAST4G\n"
    expect_bytes "$fs2" /near4g.bin 0 4 HEAD
    expect_bytes "$fs2" /near4g.bin $((NEAR4G - 4)) 12 "TAILPAST4G.."
    expect_text_in "$fs2" /end_after.txt TAILPAST4G "ZDOS read back past 4 GiB"
    expect_gone_in "$fs2" /del4g.bin
    expect_fs_size "$fs2" /near16g.bin $((NEAR16G + 2)) # "ab"; "TOOLONG" refused
    expect_bytes "$fs2" /near16g.bin $((NEAR16G - 4)) 6 "TAILab"
    expect_text_in "$fs2" /end16_after.txt TAILab "ZDOS read the end of the 16 GiB file"

    big_part_check "$fs3" ZBIG18
    expect_fs_size "$fs3" /near18g.bin $((NEAR18G + 8)) # "PAST18G\n"
    expect_bytes "$fs3" /near18g.bin 0 4 HEAD
    expect_bytes "$fs3" /near18g.bin $((NEAR18G - 4)) 13 "TAILPAST18G.."
    expect_text_in "$fs3" /end_after.txt TAILPAST18G "ZDOS read back past 18 GiB"

    rm -f "$fs1" "$fs2" "$fs3"
    echo
    echo "passed $pass, failed $fail"
    [ $fail -eq 0 ]
}

case "${1:-}" in
make) if [ "$BIG" = 1 ]; then big_make; else cmd_make; fi ;;
run) cmd_run ;;
check) if [ "$BIG" = 1 ]; then big_check; else cmd_check; fi ;;
fsck) cmd_fsck ;;
*)
    sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
