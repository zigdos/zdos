# FAT32 boot code, as vbr16.s. The bigger BPB leaves 420 bytes,
# so it is two sectors, as Microsoft's: part 1 in sector 0 loads
# part 2 from sector 2 to 0000:7E00. The BPB is bytes 3-89; the
# copies go into the backup boot sector (6) and sector 8.
# All addressed through BP = 0x7C00.

.code16
.global _start

# FAT32 BPB fields, from BP = 0x7C00:
.set SPC,       0x0D             # byte: sectors per cluster
.set RESERVED,  0x0E             # word: reserved sectors
.set NFATS,     0x10             # byte
.set SPT,       0x18             # word: sectors per track (CHS)
.set HEADS,     0x1A             # word: heads (CHS)
.set HIDDEN,    0x1C             # dword: sectors before the volume
.set FATSZ,     0x24             # dword: sectors per FAT
.set EXTFLAGS,  0x28             # word: bit 7 = only one FAT in use, bits 0-3 = which
.set ROOTCLUS,  0x2C             # dword: first cluster of the root directory
.set DRIVE,     0x40             # byte: the drive, set from DL at boot

# Below 0x7C00, the stack below them:
.set FAT_START,  -4              # dword: first sector of the FAT in use
.set DATA_START, -8              # dword: first data sector (cluster 2)
.set FAT_CACHED, -12             # dword: FAT sector in FATBUF
.set CLUSTER,    -16             # dword: the cluster being read
.set DEST,       -18             # word: segment for the next sector of ZIGDOS.SYS
.set USE_LBA,    -19             # byte: the BIOS has LBA extensions
.set TRIES,      -20             # byte

.set PART2,  0x7E00              # where part 2 is loaded
.set DIRBUF, 0x0700              # a root directory sector
.set FATBUF, 0x0900              # a FAT sector

# PART 1: SECTOR 0

_start:
    jmp start
    nop
    .fill 0x57, 1, 0             # BPB, filled by mkfs.fat

.org 0x5A
start:
    cli
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov $0x7C00, %bp
    lea -32(%bp), %sp
    sti
    cld
    mov %dl, DRIVE(%bp)

    mov $0x41, %ah               # LBA extensions?
    mov $0x55AA, %bx
    int $0x13
    jc 1f
    cmp $0xAA55, %bx
    jne 1f
    and $1, %cl
    mov %cl, USE_LBA(%bp)
1:
    # Part 2 from sector 2; it ends with the signature AA55:
    mov HIDDEN(%bp), %eax
    add $2, %eax
    mov $PART2, %bx
    call read_sector
    cmpw $0xAA55, PART2 + 510
    je part2
    mov $part2_msg, %si
    jmp fatal

# Sector EAX (from the start of the
# disk) to ES:BX; keeps all registers.
read_sector:
    pushal
    movb $5, TRIES(%bp)
retry:
    mov %sp, %di                 # the frame, also to restore SP after the call
    mov 28(%di), %eax            # EAX as pushed
    cmpb $0, USE_LBA(%bp)
    je chs
    pushl $0                     # disk address packet: LBA, buffer, 1 sector
    pushl %eax
    push %es
    push %bx
    push $1
    push $16
    mov %sp, %si
    mov $0x42, %ah
    jmp 1f
chs:
    xor %edx, %edx
    movzwl SPT(%bp), %ecx
    div %ecx                     # EAX = track, DX = sector - 1
    inc %dx
    mov %dx, %si
    xor %edx, %edx
    movzwl HEADS(%bp), %ecx
    div %ecx                     # EAX = cylinder, DL = head
    mov %dl, %dh
    mov %si, %cx
    mov %al, %ch
    shl $6, %ah
    or %ah, %cl
    mov $0x0201, %ax
1:  mov DRIVE(%bp), %dl
    int $0x13
    mov %di, %sp                 # drops the packet; mov keeps the carry flag
    jnc 2f
    xor %ah, %ah                 # reset the drive and try again
    mov DRIVE(%bp), %dl
    int $0x13
    decb TRIES(%bp)
    jnz retry
    mov $disk_msg, %si
    jmp fatal
2:  popal
    ret

fatal:
    lodsb
    or %al, %al
    jz 1f
    mov $0x0E, %ah
    xor %bx, %bx
    int $0x10
    jmp fatal
1:  cli
    hlt
    jmp 1b

part2_msg: .asciz "No boot code in sector 2"
disk_msg:  .asciz "Disk error"

.org 510                         # fails to assemble if part 1 is too big
.word 0xAA55

# PART 2: SECTOR 2, LOADED TO 0x7E00

part2:
    # The first FAT, or EXTFLAGS's if mirroring is off:
    movzwl RESERVED(%bp), %eax
    add HIDDEN(%bp), %eax
    mov FATSZ(%bp), %ebx
    mov %eax, FAT_START(%bp)
    movzwl EXTFLAGS(%bp), %ecx
    test $0x80, %cl
    jz 2f
    and $0x0F, %cx
    jcxz 2f
1:  add %ebx, FAT_START(%bp)
    loop 1b
2:  movzbw NFATS(%bp), %cx       # data after all FATs
3:  add %ebx, %eax
    loop 3b
    mov %eax, DATA_START(%bp)
    orl $-1, FAT_CACHED(%bp)

    # "ZIGDOS  SYS" in the root (a cluster chain):
    mov ROOTCLUS(%bp), %eax
search_cluster:
    mov %eax, CLUSTER(%bp)
    call cluster_sector
    movzbw SPC(%bp), %cx
search_sector:
    mov $DIRBUF, %bx
    call read_sector
    mov %bx, %di
4:  cmpb $0, (%di)               # end of the directory
    je no_file
    push %cx
    push %di
    mov $name, %si
    mov $11, %cx
    repe cmpsb
    pop %di
    pop %cx
    je found
    add $32, %di
    cmp $DIRBUF + 512, %di
    jb 4b
    inc %eax
    loop search_sector
    mov CLUSTER(%bp), %eax
    call next_cluster
    cmp $0x0FFFFFF8, %eax
    jb search_cluster
no_file:
    mov $no_file_msg, %si
    jmp fatal

found:
    mov 20(%di), %ax             # first cluster: high word, low word
    shl $16, %eax
    mov 26(%di), %ax
    cmp $2, %eax
    jb no_file                   # empty file
    movw $0x0800, DEST(%bp)
load_cluster:
    mov %eax, CLUSTER(%bp)
    call cluster_sector
    movzbw SPC(%bp), %cx
5:  cmpw $0x8000, DEST(%bp)      # ZIGDOS.SYS must end below 0x80000
    jae too_big
    mov DEST(%bp), %es
    xor %bx, %bx
    call read_sector
    addw $0x20, DEST(%bp)
    inc %eax
    loop 5b
    push %ds
    pop %es
    mov CLUSTER(%bp), %eax
    call next_cluster
    cmp $0x0FFFFFF8, %eax
    jb load_cluster

    mov DRIVE(%bp), %dl
    jmp 0x8000

too_big:
    mov $too_big_msg, %si
    jmp fatal

# EAX = cluster -> EAX = its first sector; changes ECX, EDX
cluster_sector:
    sub $2, %eax
    movzbl SPC(%bp), %ecx
    mul %ecx
    add DATA_START(%bp), %eax
    ret

# EAX = cluster -> EAX = next (>= 0x0FFFFFF8 at the end; a free
# or reserved entry counts as the end).
next_cluster:
    mov %ax, %si
    and $127, %si
    shl $2, %si                  # offset in the FAT sector: 4 bytes per entry
    shr $7, %eax
    add FAT_START(%bp), %eax
    cmp FAT_CACHED(%bp), %eax
    je 1f
    mov %eax, FAT_CACHED(%bp)
    mov $FATBUF, %bx
    call read_sector
1:  mov FATBUF(%si), %eax
    and $0x0FFFFFFF, %eax
    cmp $2, %eax
    jae 2f
    mov $0x0FFFFFFF, %eax
2:  ret

name:        .ascii "ZIGDOS  SYS"
no_file_msg: .asciz "No ZIGDOS.SYS"
too_big_msg: .asciz "ZIGDOS.SYS too big"

.org 1022                        # fails to assemble if part 2 is too big
.word 0xAA55
