#!/usr/bin/env bash
# Minix V3 file system tests. Images are in build/mfs-tests.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
OUT=${MFS_OUT:-$repo/build/mfs-tests}
IMG=$OUT/mfs.img
FS=$OUT/mfs.fs
FATFS=$OUT/mfs_fat.fs
TEST=$OUT/fstest.sh
SEED=$OUT/mfs_seed # files the test copies in, kept for the check
PART_START=2048
SIZE_MB=64
MFS_BLOCK_SIZE=${MFS_BLOCK_SIZE:-4096}
FAT_SECTORS=$((8 * 2048))
PART_SECTORS=$((SIZE_MB * 2048 - PART_START - FAT_SECTORS - 34))
FAT_START=$((PART_START + PART_SECTORS))

need() {
    for c in "$@"; do command -v "$c" >/dev/null || { echo "missing: $c"; exit 1; }; done
}

write_test() {
    cat >"$1" <<'ASH'
# Run from the Minix volume root: ash /X:/fstest.sh (X: MFS_TOOLS)
log=fstest.log
if [ -e "$log" ]; then
    echo "fstest already ran on this image; make a fresh image"
    exit 1
fi
echo "fstest start" > "$log"
step() {
    name=$1; want=$2; status=$3
    if [ "$want" = ok ]; then
        if [ "$status" -eq 0 ]; then result=PASS; else result=FAIL; fi
    else
        if [ "$status" -eq 0 ]; then result=FAIL; else result=PASS; fi
    fi
    echo "$result $name (status $status)" >> "$log"
    echo "$result $name"
}

# Small-file I/O:
printf 'alpha\n' > append.txt
step "create file" ok $?
printf 'beta\n' >> append.txt
step "append to file" ok $?
if [ "$(cat append.txt)" = "$(printf 'alpha\nbeta')" ]; then st=0; else st=1; fi
step "read appended contents" ok "$st"
cp append.txt copied.txt
step "copy a small file" ok $?
if [ "$(cat copied.txt)" = "$(cat append.txt)" ]; then st=0; else st=1; fi
step "read copied file" ok "$st"

printf 'temporary contents\n' > overwrite.txt
printf 'short\n' > overwrite.txt
step "overwrite and truncate file" ok $?
if [ "$(cat overwrite.txt)" = short ] && [ "$(wc -c < overwrite.txt)" -eq 6 ]; then st=0; else st=1; fi
step "check truncated file" ok "$st"
touch empty.txt
step "create empty file" ok $?
if [ -f empty.txt ] && [ "$(wc -c < empty.txt)" -eq 0 ]; then st=0; else st=1; fi
step "check empty file" ok "$st"
mkdir empty_dir
step "create empty directory" ok $?
rmdir empty_dir
step "remove empty directory" ok $?

# A shallow tree, a file rename, and a directory rename:
mkdir parent
step "create parent directory" ok $?
mkdir parent/child
step "create child directory" ok $?
printf 'inside\n' > parent/child/note.txt
step "create file in child directory" ok $?
mv parent/child/note.txt parent/child/renamed.txt
step "rename file in directory" ok $?
mv parent/child parent/renamed
step "rename child directory" ok $?
if [ "$(cat parent/renamed/renamed.txt)" = inside ]; then st=0; else st=1; fi
step "read file after directory rename" ok "$st"
rmdir parent
step "refuse to remove non-empty directory" fail $?
rm parent/renamed/renamed.txt
step "remove nested file" ok $?
rmdir parent/renamed
step "remove child directory" ok $?
rmdir parent
step "remove now-empty parent" ok $?

# Many small files in one directory; only the batch result is logged,
# so logging doesn't dominate the workload:
tree=bulk_dir
mkdir "$tree"
step "create bulk directory" ok $?
st=0
i=0
while [ "$i" -lt 100 ]; do
    name=file_$i.txt
    printf 'item %d\n' "$i" > "$tree/$name" || st=1
    i=$((i + 1))
done
step "create 100 non-empty files in the directory" ok "$st"

# Permissions and owners:
printf 'permissions\n' > permissions.txt
chmod 600 permissions.txt
step "chmod 600" ok $?
chmod 444 permissions.txt
step "chmod read-only" ok $?
printf 'denied\n' >> permissions.txt 2>/dev/null
step "refuse write to read-only file" fail $?
chmod 644 permissions.txt
step "restore write permission" ok $?
printf 'allowed\n' >> permissions.txt
step "write after restoring permission" ok $?
chown 1234:4321 permissions.txt
step "change uid and gid" ok $?
chmod 9999 permissions.txt 2>/dev/null
step "reject invalid mode bits" fail $?
chown 70000:70001 permissions.txt 2>/dev/null
step "reject uid and gid above Minix V3 limit" fail $?
ls -l permissions.txt > metadata.txt
step "list updated metadata" ok $?

# Large files: past single indirect, copied in runs of blocks,
# truncated and deleted (zones freed in batches):
tools=$(DRIVES | grep MFS_TOOLS | awk '{ print $1 }')
cp /$tools/big5m.bin big5m.bin
step "copy a 5 MB file in (double indirect)" ok $?
cp big5m.bin big5m_copy.bin
step "copy it again on the volume" ok $?
printf 'short\n' > big5m_copy.bin
step "truncate the 5 MB copy" ok $?
cp big5m.bin big5m_del.bin
step "make another 5 MB copy" ok $?
rm big5m_del.bin
step "delete a 5 MB file" ok $?

# Read-only entries are not deleted, as in DOS:
printf 'ro\n' > ro.txt
chmod 444 ro.txt
step "chmod 444 ro.txt" ok $?
rm ro.txt 2>/dev/null
step "refuse to delete a read-only file" fail $?
chmod 644 ro.txt
rm ro.txt
step "delete it once writable" ok $?

# The name index under churn: deletes, names created again, moves:
mkdir churn
st=0
i=0
while [ "$i" -lt 150 ]; do
    printf 'c %d\n' "$i" > "churn/c_$i.txt" || st=1
    i=$((i + 1))
done
step "create 150 files" ok "$st"
st=0
i=0
while [ "$i" -lt 50 ]; do
    rm "churn/c_$i.txt" || st=1
    i=$((i + 1))
done
step "delete 50 of them" ok "$st"
st=0
i=0
while [ "$i" -lt 10 ]; do
    printf 'again %d\n' "$i" > "churn/c_$i.txt" || st=1
    i=$((i + 1))
done
step "create 10 deleted names again" ok "$st"
mkdir moved_dir
mv churn/c_100.txt moved_dir/moved.txt
step "move a file to another directory" ok $?
cat churn/c_100.txt > /dev/null 2>&1
step "the moved file is gone from its old directory" fail $?
if [ "$(cat moved_dir/moved.txt)" = "c 100" ]; then st=0; else st=1; fi
step "read the moved file" ok "$st"
if [ "$(cat churn/c_0.txt)" = "again 0" ]; then st=0; else st=1; fi
step "read a name created again" ok "$st"

rm append.txt copied.txt overwrite.txt empty.txt
step "remove remaining files" ok $?
echo "fstest done" >> "$log"
echo "fstest done"
ASH
}

cmd_make() {
    need mkfs.fat mcopy sfdisk truncate dd
    # The host's Minix formatter: zig build makes it (once)
    mkmfs3=$repo/build/host/mkmfs3
    [ -x "$mkmfs3" ] || (cd "$repo" && zig build mkmfs3) || { echo "cannot build $mkmfs3 (zig build mkmfs3)"; exit 1; }
    mkdir -p "$OUT"
    rm -f "$IMG" "$FS" "$FATFS" "$TEST"
    rm -rf "$SEED"
    mkdir -p "$SEED"
    # Past 7 + 1024 blocks of 4 KiB: double indirect, odd-sized:
    head -c 5000001 /dev/urandom >"$SEED/big5m.bin"
    write_test "$TEST"
    "$mkmfs3" "$FS" $((PART_SECTORS * 512)) -b "$MFS_BLOCK_SIZE" -i 2048
    truncate -s $((SIZE_MB * 1024 * 1024)) "$IMG"
    printf '%s\n' \
        "start=$PART_START, size=$PART_SECTORS, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=\"mfs\"" \
        "start=$FAT_START, size=$FAT_SECTORS, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name=\"mfs-tools\"" |
        sfdisk --quiet --label gpt "$IMG"
    dd if="$FS" of="$IMG" bs=512 seek=$PART_START conv=notrunc status=none
    rm -f "$FS"
    mkfs.fat -C -n MFS_TOOLS "$FATFS" $((FAT_SECTORS / 2)) >/dev/null
    mcopy -i "$FATFS" "$TEST" ::/fstest.sh
    mcopy -i "$FATFS" "$SEED/big5m.bin" ::/big5m.bin
    dd if="$FATFS" of="$IMG" bs=512 seek=$FAT_START conv=notrunc status=none
    echo "Made $IMG with an empty Minix V3 volume and the small test script on FAT."
    echo "In ZDOS: cd to the Minix drive, then ash /X:/fstest.sh (X: the MFS_TOOLS drive; see DRIVES)"
}

cmd_run() {
    [ -f "$IMG" ] || { echo "no $IMG; run $0 make"; exit 1; }
    exec "$repo/run-bios-x86.sh" -drive "file=$IMG,format=raw,if=ide,index=2"
}

extract() {
    dd if="$IMG" of="$FS" bs=512 skip=$PART_START count=$PART_SECTORS status=none
}

cmd_check() {
    need python3
    [ -f "$IMG" ] || { echo "no $IMG"; exit 1; }
    extract
    block_size=$(python3 -c 'import struct,sys; print(struct.unpack_from("<H", open(sys.argv[1],"rb").read(2048), 1024+28)[0])' "$FS")
    if [ "$block_size" = 1024 ]; then
        if ! command -v fsck.minix >/dev/null; then echo "missing: fsck.minix"; exit 1; fi
        echo "fsck.minix -f -v:"
        set +e
        fsck_out=$(fsck.minix -f -v "$FS" 2>&1)
        fsck_rc=$?
        set -e
        printf '%s\n' "$fsck_out"
        if [ "$fsck_rc" -ne 0 ] || printf '%s\n' "$fsck_out" | grep -Eiq 'marked in use|not used|invalid|incorrect'; then
            echo "FAIL Minix filesystem check"
        else
            echo "PASS Minix filesystem check"
        fi
    else
        echo "SKIP fsck.minix: util-linux supports only 1 KiB Minix blocks; validating the 4 KiB image structure directly."
    fi
    python3 - "$FS" "$SEED/big5m.bin" <<'PY'
import hashlib, struct, sys
image = open(sys.argv[1], 'rb').read()
seed_big = open(sys.argv[2], 'rb').read()
u16 = lambda b, n: struct.unpack_from('<H', b, n)[0]
u32 = lambda b, n: struct.unpack_from('<I', b, n)[0]
sb = image[1024:2048]
if u16(sb, 24) != 0x4d5a: raise SystemExit('FAIL image is not Minix V3')
bs = u16(sb, 28); imap = u16(sb, 6); zmap = u16(sb, 8); ninodes = u32(sb, 0); zones = u32(sb, 20)
istart = 2 + imap + zmap
first_zone = u16(sb, 10) or istart + (ninodes + bs // 64 - 1) // (bs // 64)
if bs not in (1024, 2048, 4096): raise SystemExit('FAIL unsupported Minix V3 block size')
if imap * bs * 8 < ninodes + 1: raise SystemExit('FAIL inode bitmap is too small')
if zmap * bs * 8 < zones - first_zone + 1: raise SystemExit('FAIL zone bitmap is too small')
if first_zone != istart + (ninodes + bs // 64 - 1) // (bs // 64): raise SystemExit('FAIL inconsistent first data zone')
def block(n):
    if n == 0 or n >= zones: return bytes(bs)
    return image[n * bs:(n + 1) * bs]
def inode(n):
    if not n or n > ninodes: raise ValueError('inode out of range')
    off = (istart + (n - 1) // (bs // 64)) * bs + ((n - 1) % (bs // 64)) * 64
    b = image[off:off + 64]
    return {'mode':u16(b,0), 'links':u16(b,2), 'uid':u16(b,4), 'gid':u16(b,6), 'size':u32(b,8), 'zones':[u32(b,24+4*i) for i in range(10)]}
def zone_at(z, n):
    ppb=bs//4
    if n<7: return z[n]
    n-=7
    if n<ppb: return u32(block(z[7]),n*4) if z[7] else 0
    n-=ppb
    if not z[8]: return 0
    leaf=u32(block(z[8]),(n//ppb)*4)
    return u32(block(leaf),(n%ppb)*4) if leaf else 0
def data(n):
    x=inode(n); out=bytearray()
    for i in range((x['size']+bs-1)//bs):
        z=zone_at(x['zones'],i); out += block(z)
    return bytes(out[:x['size']])
def entries(n):
    raw=data(n); result=[]
    for p in range(0,len(raw)-63,64):
        e=raw[p:p+64]; number=u32(e,0)
        if number: result.append((e[4:64].split(b'\0',1)[0].decode(errors='replace'),number))
    return result
def find(path):
    n=1
    for part in path.strip('/').split('/'):
        if not part: continue
        n=next((ino for name,ino in entries(n) if name.lower()==part.lower()),None)
        if n is None: return None
    return n
def get(path):
    n=find(path)
    return None if n is None else data(n)
def check(ok, message): print(('PASS ' if ok else 'FAIL ')+message)
root = inode(1)
check((root['mode'] & 0xf000) == 0x4000 and root['links'] >= 2 and root['zones'][0] == first_zone,
      'root inode and first data zone are valid')
imap_data = image[2*bs:2*bs+bs]
zmap_start = (2+imap)*bs
zmap_data = image[zmap_start:zmap_start+bs]
check(bool(imap_data[0] & 0x02) and bool(zmap_data[0] & 0x02),
      'root inode and root zone are allocated in bitmaps')
try:
    log=get('/fstest.log').decode('ascii','replace').replace('\r','')
except Exception as e:
    log=''; print(f'FAIL could not read fstest.log: {e}')
print(log,end='' if log.endswith('\n') else '\n')
check('fstest done' in log,'guest test completed')
check(not any(line.startswith('FAIL ') for line in log.splitlines()),'guest reported no failed cases')
for path, expected in (('/append.txt',None),('/copied.txt',None),('/overwrite.txt',None),('/permissions.txt',b'permissions\nallowed\n')):
    actual=get(path)
    if actual is not None: actual=actual.replace(b'\r',b'')
    check((actual==expected) if expected is not None else find(path) is None, f'{path} final state')
check(find('/empty.txt') is None,'empty test file was removed')
check(find('/parent') is None,'directory tree was removed')
check(find('/empty_dir') is None,'empty directory was removed')
bulk_dir=find('/bulk_dir')
check(bulk_dir is not None,'bulk directory exists')
bulk_entries=[] if bulk_dir is None else [(name,ino) for name,ino in entries(bulk_dir) if name not in ('.','..')]
check(len(bulk_entries)==100,'bulk directory contains 100 files')
check(all(len(name.encode()) <= 16 and name.startswith('file_') and inode(ino)['size'] > 0 for name,ino in bulk_entries),'all filenames are short and files are non-empty')
n=find('/permissions.txt')
if n:
    x=inode(n)
    check((x['mode']&0o7777)==0o644,'permissions.txt mode is 0644')
    check((x['uid'],x['gid'])==(1234,4321),'permissions.txt owner is 1234:4321')

# Large files, read-only delete:
big=get('/big5m.bin')
check(big is not None and hashlib.md5(big).digest()==hashlib.md5(seed_big).digest(),
      '/big5m.bin matches the 5 MB seed (double indirect, multi-block I/O)')
copy=get('/big5m_copy.bin')
check(copy is not None and copy.replace(b'\r',b'')==b'short\n','/big5m_copy.bin was truncated to "short"')
check(find('/big5m_del.bin') is None,'/big5m_del.bin was deleted')
check(find('/ro.txt') is None,'/ro.txt was deleted once writable')

# The name index under churn:
churn=find('/churn')
names=sorted(name for name,_ in entries(churn)) if churn else []
expected=sorted(['.','..']+[f'c_{i}.txt' for i in range(150) if i>=50 and i!=100]+[f'c_{i}.txt' for i in range(10)])
check(names==expected,f'/churn holds exactly the expected {len(expected)-2} files, each once')
c0=get('/churn/c_0.txt')
check(c0 is not None and c0.replace(b'\r',b'')==b'again 0\n','/churn/c_0.txt is the name created again')
moved=get('/moved_dir/moved.txt')
check(moved is not None and moved.replace(b'\r',b'')==b'c 100\n','/moved_dir/moved.txt is the moved file')

# Bitmaps against the tree: every inode reachable from the root, and
# its zones, marked in use, nothing else:
def bit(bitmap_start, blocks, n):
    raw=image[bitmap_start*bs:(bitmap_start+blocks)*bs]
    return bool(raw[n//8] & (1 << (n%8)))
def zones_of(x):
    ppb=bs//4; zs=[z for z in x['zones'][:7] if z]
    if x['zones'][7]:
        zs.append(x['zones'][7]); t=block(x['zones'][7])
        zs+=[u32(t,4*i) for i in range(ppb) if u32(t,4*i)]
    if x['zones'][8]:
        zs.append(x['zones'][8]); o=block(x['zones'][8])
        for i in range(ppb):
            leaf=u32(o,4*i)
            if leaf:
                zs.append(leaf); t=block(leaf)
                zs+=[u32(t,4*j) for j in range(ppb) if u32(t,4*j)]
    return zs
reachable=set(); todo=[1]
while todo:
    n=todo.pop()
    if n in reachable: continue
    reachable.add(n)
    if (inode(n)['mode'] & 0xf000)==0x4000:
        todo+=[ino for name,ino in entries(n) if name not in ('.','..')]
marked={n for n in range(1,ninodes+1) if bit(2,imap,n)}
check(marked==reachable,f'inode bitmap matches the tree ({len(reachable)} in use'
      + ('' if marked==reachable else f'; marked only: {sorted(marked-reachable)[:5]}, unmarked: {sorted(reachable-marked)[:5]}') + ')')
used=[]
for n in reachable: used+=zones_of(inode(n))
check(len(used)==len(set(used)),'no zone is used twice')
used_bits={z-first_zone+1 for z in used}
zone_bits={b for b in range(1,zones-first_zone+1) if bit(2+imap,zmap,b)}
check(zone_bits==used_bits,f'zone bitmap matches the zones in use ({len(used_bits)}'
      + ('' if zone_bits==used_bits else f'; marked only: {len(zone_bits-used_bits)}, unmarked: {len(used_bits-zone_bits)}') + ')')

# QEMU is just stopped: every change ends with the volume clean again:
check(u16(sb,14) & 1 == 1,'superblock: clean')
PY
    rm -f "$FS"
}

case "${1:-}" in
    make) cmd_make ;;
    run) cmd_run ;;
    check) cmd_check ;;
    *) echo "Usage: $0 {make|run|check}"; exit 2 ;;
esac
