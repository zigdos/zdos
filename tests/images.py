#!/usr/bin/env python3
# Disk images for the test suites: MBR and GPT tables, marked test
# disks and their checks, GPT disks put together from volume images,
# FAT volumes (mkfs.fat, fsck.fat, mtools). tests/common.py has them
# all too (h.make_disk ...).

import hashlib
import json
import os
import shutil
import struct
import subprocess
import uuid
import zlib

SECTOR = 512


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# DISK IMAGES

def make_disk(path, sectors, fill=None):
    # Zero (sparse) or filled with one byte.
    with open(path, "wb") as f:
        if fill is None:
            f.truncate(sectors * SECTOR)
            return
        chunk = bytes([fill]) * (SECTOR * 2048)
        left = sectors
        while left > 0:
            n = min(left, 2048)
            f.write(chunk[:n * SECTOR])
            left -= n


def read_sector(path, lba, count=1):
    with open(path, "rb") as f:
        f.seek(lba * SECTOR)
        return f.read(count * SECTOR)


def write_sector(path, lba, data):
    with open(path, "r+b") as f:
        f.seek(lba * SECTOR)
        f.write(data)


def file_hash(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            block = f.read(1 << 20)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def fingerprint(path):
    # To see whether it changed: the whole file, or of a large sparse
    # image its first 64 MB (where tables, boot sectors and FATs go).
    if os.path.getsize(path) <= (1 << 30):
        return file_hash(path)
    with open(path, "rb") as f:
        return hashlib.sha256(f.read(64 << 20)).hexdigest()


def copy_to(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)
    return dst


def put_entry(sec, i, kind, start, size, status=0):
    # Entry i (0-3), in LBA form.
    off = 446 + 16 * i
    sec[off:off + 16] = bytes(16)
    sec[off] = status
    sec[off + 4] = kind
    struct.pack_into("<II", sec, off + 8, start, size)


def write_table(path, lba, entries):
    # At lba (MBR or EBR), entries (kind, start, sectors[, status]). Bytes
    # outside the table are kept.
    sec = bytearray(read_sector(path, lba))
    for i in range(4):
        sec[446 + 16 * i:462 + 16 * i] = bytes(16)
    for i, e in enumerate(entries):
        put_entry(sec, i, *e)
    sec[510:512] = b"\x55\xaa"
    write_sector(path, lba, bytes(sec))


def read_entries(data, offset=0):
    # At offset 446.
    out = []
    for i in range(4):
        at = offset + 446 + 16 * i
        status, kind = data[at], data[at + 4]
        start, count = struct.unpack_from("<II", data, at + 8)
        out.append({"status": status, "type": kind, "start": start, "sectors": count})
    return out


def table_of(path):
    # The primary entries, and the logical ones of the first extended
    # partition, as CHKDSK follows them: ebr is the record's sector,
    # start_rel the partition's start from it.
    with open(path, "rb") as f:
        mbr = f.read(SECTOR)
        if mbr[510:512] != b"\x55\xaa":
            return [{"status": 0, "type": 0, "start": 0, "sectors": 0}] * 4, []
        prim = read_entries(mbr)
        logical = []
        ext = next((e["start"] for e in prim if e["type"] in (0x05, 0x0F) and e["start"] != 0), None)
        if ext is None:
            return prim, logical
        at = ext
        for _ in range(32):
            f.seek(at * SECTOR)
            rec = f.read(SECTOR)
            if rec[510:512] != b"\x55\xaa":
                break
            part, nxt = read_entries(rec)[:2]
            if part["type"] != 0:
                logical.append({"ebr": at, "type": part["type"], "start_rel": part["start"],
                                "sectors": part["sectors"]})
            if nxt["type"] not in (0x05, 0x0F):
                break
            at = ext + nxt["start"]
    return prim, logical


def describe_table(prim, logical):
    text = "primary " + (", ".join(
        f"{i + 1}: type {e['type']:02x} start {e['start']} sectors {e['sectors']} status {e['status']:02x}"
        for i, e in enumerate(prim) if e["type"] != 0) or "none")
    if logical:
        text += "; logical " + ", ".join(
            f"ebr {x['ebr']} type {x['type']:02x} start {x['start_rel']} sectors {x['sectors']}" for x in logical)
    return text


# GPT. Type GUIDs, in their on-disk byte order:
GPT_BASIC_DATA = uuid.UUID("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7").bytes_le
GPT_LINUX = uuid.UUID("0FC63DAF-8483-4772-8E79-3D69D8477DE4").bytes_le
GPT_ESP = uuid.UUID("C12A7328-F81F-11D2-BA4B-00A0C93EC93B").bytes_le
GPT_ENTRIES = 128  # entries of 128 bytes: 32 sectors


def gpt_tables(disk_sectors):
    # The protective MBR, header and entries at the start,
    # the backups at the end.
    return set(range(0, 34)) | set(range(disk_sectors - 33, disk_sectors))


def _gpt_header(my_lba, alt_lba, entries_lba, disk_sectors, disk_guid, entries_crc):
    hdr = bytearray(92)
    hdr[0:8] = b"EFI PART"
    struct.pack_into("<IIIIQQQQ", hdr, 8, 0x00010000, 92, 0, 0, my_lba, alt_lba, 34, disk_sectors - 34)
    hdr[56:72] = disk_guid
    struct.pack_into("<QIII", hdr, 72, entries_lba, GPT_ENTRIES, 128, entries_crc)
    struct.pack_into("<I", hdr, 16, zlib.crc32(bytes(hdr)))
    return bytes(hdr) + bytes(SECTOR - 92)


def write_gpt(path, disk_sectors, slots):
    # slots[i] is entry i (partition i + 1): None or (type, first, last, name).
    entries = bytearray(GPT_ENTRIES * 128)
    for i, part in enumerate(slots):
        if part is None:
            continue
        kind, first, last, name = part
        e = 128 * i
        entries[e:e + 16] = kind
        entries[e + 16:e + 32] = uuid.uuid4().bytes_le
        struct.pack_into("<QQQ", entries, e + 32, first, last, 0)
        label = name.encode("utf-16-le")[:72]
        entries[e + 56:e + 56 + len(label)] = label
    crc = zlib.crc32(bytes(entries))
    disk_guid = uuid.uuid4().bytes_le
    write_table(path, 0, [(0xEE, 1, min(disk_sectors - 1, 0xFFFFFFFF))])
    write_sector(path, 1, _gpt_header(1, disk_sectors - 1, 2, disk_sectors, disk_guid, crc))
    write_sector(path, 2, bytes(entries))
    write_sector(path, disk_sectors - 33, bytes(entries))
    write_sector(path, disk_sectors - 1, _gpt_header(disk_sectors - 1, 1, disk_sectors - 33, disk_sectors,
                                                     disk_guid, crc))


def read_gpt(path, disk_sectors):
    # (problems, entries): both headers and arrays checked (signature,
    # CRCs, copies equal); entries[i] is None or (type, first, last).
    problems = []
    arrays = []
    for name, lba in (("primary", 1), ("backup", disk_sectors - 1)):
        hdr = read_sector(path, lba)
        if hdr[0:8] != b"EFI PART":
            problems.append(f"{name} GPT header missing")
            continue
        size = u32(hdr, 12)
        check = bytearray(hdr[:size])
        struct.pack_into("<I", check, 16, 0)
        if zlib.crc32(bytes(check)) != u32(hdr, 16):
            problems.append(f"{name} GPT header CRC wrong")
        entries_lba, count, esize, crc = struct.unpack_from("<QIII", hdr, 72)
        data = read_sector(path, entries_lba, (count * esize + SECTOR - 1) // SECTOR)[:count * esize]
        if zlib.crc32(data) != crc:
            problems.append(f"{name} GPT entries CRC wrong")
        arrays.append(data)
    if len(arrays) == 2 and arrays[0] != arrays[1]:
        problems.append("the GPT copies differ")
    entries = []
    if arrays:
        data = arrays[0]
        for i in range(len(data) // 128):
            e = data[128 * i:128 * (i + 1)]
            if e[:16] == bytes(16):
                entries.append(None)
            else:
                entries.append((e[:16], struct.unpack_from("<Q", e, 32)[0], struct.unpack_from("<Q", e, 40)[0]))
    return problems, entries


# MARKED TEST DISKS: a maker writes the image and returns where its
# volume is ("start", "sectors") and the table sectors ("tables", left
# out of the marker check); "no_marker" for a disk that has none.
MARK = 0xA5
MARKER = bytes([MARK]) * SECTOR
MB = 2048  # sectors
DISK_SECTORS = 64 * MB


def marked(sectors=DISK_SECTORS):
    def make(path, entries=(), ebrs=()):
        make_disk(path, sectors, fill=MARK)
        if entries:
            write_table(path, 0, entries)
        for lba, e in ebrs:
            write_table(path, lba, e)
    return make


def one_partition(kind, start, count, disk_sectors=DISK_SECTORS):
    def make(path):
        marked(disk_sectors)(path, [(kind, start, count)])
        return {"start": start, "sectors": count, "tables": {0}}
    return make


EXT_LOGICAL = (36864, 32768)


def with_logical(path):
    # A 16 MB primary, then an extended one holding one logical partition:
    # partition 3 starts at 36864.
    marked()(path, [(0x06, 2048, 32768), (0x05, 34816, 47104)], [(34816, [(0x06, 2048, 32768)])])
    return {"start": EXT_LOGICAL[0], "sectors": EXT_LOGICAL[1], "tables": {0, 34816}}


def whole_disk(sectors):
    # No partition table: the disk is partition 1.
    def make(path):
        marked(sectors)(path)
        return {"start": 0, "sectors": sectors, "tables": set()}
    return make


def gpt_disk(slots, volume_slot, disk_sectors=DISK_SECTORS):
    # slots as write_gpt; the volume is slot volume_slot's.
    def make(path):
        make_disk(path, disk_sectors, fill=MARK)
        write_gpt(path, disk_sectors, slots)
        _, first, last, _ = slots[volume_slot]
        return {"start": first, "sectors": last - first + 1, "tables": gpt_tables(disk_sectors),
                "gpt": disk_sectors}
    return make


def gpt_no_header(path):
    # A protective MBR whose GPT header is missing.
    marked()(path, [(0xEE, 1, DISK_SECTORS - 1)])
    return {"tables": {0}}


def formatted_partition(path):
    # FAT16 by mkfs.fat, so that it has a drive letter.
    marked()(path, [(0x06, 2048, 32768)])
    vol = path + ".vol"
    mkfs(vol, "16", 16384, "OLDVOL")
    with open(vol, "rb") as f:
        write_sector(path, 2048, f.read())
    os.remove(vol)
    return {"start": 2048, "sectors": 32768, "tables": {0}}


def fat_superfloppy(sectors=DISK_SECTORS):
    # One FAT volume, no table: its boot sector ends in 55 AA, but its boot
    # code is no table.
    def make(path):
        mkfs(path, "16", sectors // 2, "SUPER")
        return {"start": 0, "sectors": sectors, "tables": set(), "no_marker": True}
    return make


def outside_changed(image, layout):
    # Outside the volume and tables, that lost the marker.
    start, count, tables = layout.get("start", 0), layout.get("sectors", 0), layout["tables"]
    changed = []
    with open(image, "rb") as f:
        lba = 0
        while True:
            block = f.read(SECTOR * 2048)
            if not block:
                break
            for i in range(len(block) // SECTOR):
                at = lba + i
                if start <= at < start + count or at in tables:
                    continue
                if block[i * SECTOR:(i + 1) * SECTOR] != MARKER:
                    changed.append(at)
            lba += len(block) // SECTOR
    return changed


def marked_inside(image, start, count):
    # Inside the volume, that still hold the marker.
    left = []
    with open(image, "rb") as f:
        f.seek(start * SECTOR)
        for i in range(count):
            if f.read(SECTOR) == MARKER:
                left.append(start + i)
    return left


def extract(path, base, sectors, target):
    # Zero blocks are skipped, so a mostly empty copy stays sparse.
    with open(path, "rb") as src, open(target, "wb") as dst:
        src.seek(base * SECTOR)
        left = sectors * SECTOR if sectors is not None else None
        size = 0
        while left is None or left > 0:
            block = src.read(1 << 20 if left is None else min(left, 1 << 20))
            if not block:
                break
            if block.count(0) == len(block):
                dst.seek(len(block), 1)
            else:
                dst.write(block)
            size += len(block)
            if left is not None:
                left -= len(block)
        dst.truncate(size)
    return target


# FAT VOLUMES

def u16(b, at):
    return struct.unpack_from("<H", b, at)[0]


def u32(b, at):
    return struct.unpack_from("<I", b, at)[0]


def name83(name):
    base, _, ext = name.partition(".")
    return f"{base:<8}{ext:<3}"


class Vol:
    # Starting base bytes into the file.
    def __init__(self, path, base=0):
        self.path = path
        self.base = base
        boot = self.read(0, SECTOR)
        self.boot = boot
        self.spc = boot[13]
        self.reserved = u16(boot, 14)
        self.fats = boot[16]
        self.root_entries = u16(boot, 17)
        self.total = u16(boot, 19) or u32(boot, 32)
        self.fat_sectors = u16(boot, 22) or u32(boot, 36)
        self.root_sectors = (self.root_entries * 32 + SECTOR - 1) // SECTOR
        self.data_start = self.reserved + self.fats * self.fat_sectors + self.root_sectors
        self.clusters = (self.total - self.data_start) // self.spc
        if self.clusters < 4085:
            self.kind = "fat12"
        elif self.clusters < 65525:
            self.kind = "fat16"
        else:
            self.kind = "fat32"
        self.root_cluster = u32(boot, 44) if self.kind == "fat32" else 0
        self.fsinfo = u16(boot, 48) if self.kind == "fat32" else 0
        self.eoc = {"fat12": 0xFF8, "fat16": 0xFFF8, "fat32": 0x0FFFFFF8}[self.kind]

    def read(self, pos, n):
        with open(self.path, "rb") as f:
            f.seek(self.base + pos)
            return f.read(n)

    def write(self, pos, data):
        with open(self.path, "r+b") as f:
            f.seek(self.base + pos)
            f.write(data)

    def fat_pos(self, copy, c):
        if self.kind == "fat12":
            off, size = c + c // 2, 2
        elif self.kind == "fat16":
            off, size = 2 * c, 2
        else:
            off, size = 4 * c, 4
        return (self.reserved + copy * self.fat_sectors) * SECTOR + off, size

    def fat_get(self, c, copy=0):
        pos, size = self.fat_pos(copy, c)
        value = int.from_bytes(self.read(pos, size), "little")
        if self.kind == "fat12":
            return value >> 4 if c & 1 else value & 0xFFF
        if self.kind == "fat32":
            return value & 0x0FFFFFFF
        return value

    def fat_set(self, c, value, copies=(0, 1)):
        for copy in copies:
            if copy >= self.fats:
                continue
            pos, size = self.fat_pos(copy, c)
            old = int.from_bytes(self.read(pos, size), "little")
            if self.kind == "fat12":
                new = (old & 0xF000) | (value & 0xFFF) if c % 2 == 0 else (old & 0x000F) | ((value & 0xFFF) << 4)
            elif self.kind == "fat32":
                new = (old & 0xF0000000) | (value & 0x0FFFFFFF)
            else:
                new = value & 0xFFFF
            self.write(pos, new.to_bytes(size, "little"))

    def free_clusters(self):
        return sum(1 for c in range(2, self.clusters + 2) if self.fat_get(c) == 0)

    def chain(self, first):
        clusters = []
        c = first
        while 2 <= c < self.clusters + 2 and c not in clusters:
            clusters.append(c)
            c = self.fat_get(c)
            if c >= self.eoc:
                break
        return clusters

    def dir_offsets(self, first=None):
        # Of the 32-byte entries of a folder, or of the root.
        if first is None and self.kind == "fat32":
            first = self.root_cluster
        if first is None:
            start = self.reserved + self.fats * self.fat_sectors
            sectors = [start + i for i in range(self.root_sectors)]
        else:
            sectors = []
            for c in self.chain(first):
                base = self.data_start + (c - 2) * self.spc
                sectors += [base + i for i in range(self.spc)]
        return [s * SECTOR + e for s in sectors for e in range(0, SECTOR, 32)]

    def find(self, name, first=None):
        for pos in self.dir_offsets(first):
            raw = self.read(pos, 32)
            if raw[0] == 0:
                break
            if raw[0] == 0xE5 or raw[11] == 0x0F:
                continue
            if raw[:11] == name.encode():
                return pos
        return None

    def first_cluster(self, pos):
        raw = self.read(pos, 32)
        hi = u16(raw, 20) if self.kind == "fat32" else 0
        return (hi << 16) | u16(raw, 26)

    def set_first(self, pos, first):
        self.write(pos + 26, (first & 0xFFFF).to_bytes(2, "little"))
        if self.kind == "fat32":
            self.write(pos + 20, (first >> 16).to_bytes(2, "little"))

    def set_size(self, pos, size):
        self.write(pos + 28, size.to_bytes(4, "little"))

    def free_slot(self):
        # The first never-used root entry (the end marker):
        for pos in self.dir_offsets(None):
            if self.read(pos, 1)[0] == 0:
                return pos
        raise SystemExit("no free root entry")


def mkfs(path, fat, kib, label):
    if os.path.exists(path):
        os.remove(path)  # mkfs.fat -C doesn't overwrite
    run("mkfs.fat", "-C", "-F", fat, "-n", label, path, str(kib))


def fsck(path, base=0, sectors=None):
    # fsck.fat -n: (ok, output), or (None, reason) without fsck.fat.
    tool = shutil.which("fsck.fat") or shutil.which("dosfsck")
    if tool is None:
        return None, "fsck.fat not installed"
    target = path
    if base or sectors is not None:
        target = extract(path, base, sectors, path + ".vol")
    p = subprocess.run([tool, "-n", target], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if target != path:
        os.remove(target)
    lines = [l for l in p.stdout.splitlines() if l.strip()]
    return p.returncode == 0, ("clean" if p.returncode == 0 else "; ".join(lines[-4:]))


def mtools_read(path, base, name):
    # Through mtools, or None.
    if shutil.which("mtype") is None:
        return None
    env = dict(os.environ, MTOOLS_SKIP_CHECK="1")
    p = subprocess.run(["mtype", "-i", f"{path}@@{base * SECTOR}", f"::/{name}"],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
    return p.stdout if p.returncode == 0 else b""


# GPT DISKS FROM VOLUME IMAGES: sfdisk's types; NO_LETTER: the GPT
# attribute ZDOS gives no letter for

TYPE_BASIC = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
TYPE_LINUX = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
NO_LETTER = 'attrs="GUID:63"'


def gpt_from_parts(disk, sectors, parts):
    # parts: (image, start, sectors, type[, attrs]), each image written
    # at its start; leave a MiB at the end for GPT's backup.
    with open(disk, "wb") as f:
        f.truncate(sectors * SECTOR)
    table = "label: gpt\n" + "".join(
        f"start={p[1]}, size={p[2]}, type={p[3]}{', ' + p[4] if len(p) > 4 and p[4] else ''}\n" for p in parts)
    subprocess.run(["sfdisk", "-q", disk], input=table, text=True, check=True)
    with open(disk, "r+b") as d:
        for image, start, *_ in parts:
            with open(image, "rb") as src:
                d.seek(start * SECTOR)
                shutil.copyfileobj(src, d)
    return disk


def minix_volume(system_img):
    # A system disk's Minix volume (p2): start and sectors
    r = subprocess.run(["sfdisk", "-J", system_img], capture_output=True, text=True, check=True)
    p = json.loads(r.stdout)["partitiontable"]["partitions"][1]
    return p["start"], p["size"]


def checker_tree(path):
    # Files for a checked volume: chkfs-damage.py's ext2 damage wants
    # some in the root and in /docs
    os.makedirs(os.path.join(path, "sub", "inner"))
    os.makedirs(os.path.join(path, "docs"))
    for i in range(1, 6):
        with open(os.path.join(path, f"file{i}.txt"), "w") as f:
            f.write(f"data {i}\n" * (i * 300))
    with open(os.path.join(path, "sub", "inner", "deep.txt"), "w") as f:
        f.write("deep\n")
    for i in range(30):
        with open(os.path.join(path, "docs", f"n{i}.txt"), "w") as f:
            f.write(str(i))
    return path
