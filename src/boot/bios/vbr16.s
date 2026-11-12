# FAT12 / FAT16 boot sector: loads ZIGDOS.SYS from the root to
# 0000:8000 and jumps there with the drive in DL. The BPB
# (bytes 3-61) is the file system's: only bytes 0-2 and the
# code from 62 are written. It needs hidden sectors = the
# volume's start, the type "FAT12" / "FAT16", and without LBA
# the BIOS's geometry. 448 bytes of code, all addressed
# through BP = 0x7C00.

.code16
.global _start

# BPB fields, from BP = 0x7C00:
.set SPC,       0x0D             # byte: sectors per cluster
.set RESERVED,  0x0E             # word: reserved sectors
.set NFATS,     0x10             # byte
.set ROOTENT,   0x11             # word: root directory entries
.set FATSZ,     0x16             # word: sectors per FAT
.set SPT,       0x18             # word: sectors per track (CHS)
.set HEADS,     0x1A             # word: heads (CHS)
.set HIDDEN,    0x1C             # dword: sectors before the volume
.set DRIVE,     0x24             # byte: the drive, set from DL at boot
.set FSTYPE4,   0x3A             # "FAT12   " / "FAT16   ": the '2' or '6'

# Below 0x7C00, the stack below them:
.set FAT_START,  -4              # dword: first FAT sector on the disk
.set DATA_START, -8              # dword: first data sector
.set ROOT_LBA,   -12             # dword: root directory sector being searched
.set FAT_CACHED, -16             # dword: FAT sector in BUF (and the next one)
.set DEST,       -18             # word: segment for the next sector of ZIGDOS.SYS
.set IS_FAT12,   -19             # byte
.set USE_LBA,    -20             # byte: the BIOS has LBA extensions
.set TRIES,      -21             # byte

.set BUF, 0x0700                 # 1 KiB: a root directory sector, or two FAT sectors

_start:
    jmp start
    nop
    .fill 0x3B, 1, 0             # BPB, filled by mkfs.fat

.org 0x3E
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
    jc 1f                        # (no check of BX = AA55: a carry is enough here)
    and $1, %cl
    mov %cl, USE_LBA(%bp)
1:
    # FATs after the reserved sectors, then the root, then data:
    movzwl RESERVED(%bp), %eax
    add HIDDEN(%bp), %eax
    mov %eax, FAT_START(%bp)
    movzwl FATSZ(%bp), %ebx
    movzbw NFATS(%bp), %cx
2:  add %ebx, %eax
    loop 2b
    mov %eax, ROOT_LBA(%bp)
    mov ROOTENT(%bp), %dx
    add $15, %dx
    shr $4, %dx                  # root directory sectors
    movzwl %dx, %ecx
    add %ecx, %eax
    mov %eax, DATA_START(%bp)
    orl $-1, FAT_CACHED(%bp)
    cmpb $'2', FSTYPE4(%bp)
    sete IS_FAT12(%bp)

    # "ZIGDOS  SYS" in the root:
search:
    mov ROOT_LBA(%bp), %eax
    mov $BUF, %bx
    call read_sector
    mov %bx, %di
3:  push %di
    mov $name, %si
    mov $11, %cx
    repe cmpsb
    pop %di
    je found
    add $32, %di
    cmp $BUF + 512, %di
    jb 3b
    incl ROOT_LBA(%bp)
    dec %dx
    jnz search
no_file:
    mov $no_file_msg, %si
    jmp fatal

found:
    movw $0x0800, DEST(%bp)
    mov 26(%di), %ax             # first cluster
load_cluster:
    push %ax
    dec %ax                      # first sector: DATA_START + (cluster - 2) * SPC
    dec %ax
    movzbw SPC(%bp), %cx
    mul %cx
    push %dx
    push %ax
    pop %eax
    add DATA_START(%bp), %eax
4:  mov DEST(%bp), %es
    xor %bx, %bx
    call read_sector
    addw $0x20, DEST(%bp)
    inc %eax
    loop 4b
    push %ds
    pop %es
    pop %ax
    call next_cluster
    cmp $0xFFF8, %ax
    jb load_cluster

    mov DRIVE(%bp), %dl
    jmp 0x8000

# AX = cluster -> AX = next (>= 0xFFF8 at the end)
next_cluster:
    mov %ax, %di
    xor %dx, %dx
    mov IS_FAT12(%bp), %cl
    test %cl, %cl
    je 1f
    shr $1, %ax                  # FAT12: 1.5 bytes per entry
    add %di, %ax
    jmp 2f
1:  shl $1, %ax                  # FAT16: 2 bytes per entry
    adc %dx, %dx
2:  mov %ax, %si
    and $511, %si                # offset in the sector
    push %dx
    push %ax
    pop %eax
    shr $9, %eax
    add FAT_START(%bp), %eax
    cmp FAT_CACHED(%bp), %eax
    je 3f
    mov %eax, FAT_CACHED(%bp)
    mov $BUF, %bx                # two sectors: a FAT12 entry may straddle them
    call read_sector
    inc %eax
    mov $BUF + 512, %bx
    call read_sector
3:  mov BUF(%si), %ax
    test %cl, %cl
    je 5f
    test $1, %di
    jz 4f
    shr $4, %ax
4:  and $0x0FFF, %ax
    cmp $0x0FF8, %ax
    jb 5f
    or $0xF000, %ax
5:  ret

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
    mov HEADS(%bp), %cx
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
1:  jmp 1b

name:        .ascii "ZIGDOS  SYS"
no_file_msg: .asciz "No ZIGDOS.SYS"
disk_msg:    .asciz "Disk error"

.org 510                         # fails to assemble if the code is too big
.word 0xAA55
