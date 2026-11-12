# A standard DOS-style MBR that starts the active partition.
# Loaded to 0000:7C00, it moves itself to 0000:0600, loads the
# partition's boot sector to 0000:7C00 and jumps there with DL =
# drive, DS:SI = the entry. Only the first 440 bytes are code.

.code16
.global _start

.set PART_TABLE, 0x0600 + 0x1BE

_start:
    cli
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov $0x7C00, %sp
    cld
    mov $0x7C00, %si             # make room for the partition's boot sector
    mov $0x0600, %di
    mov $256, %cx
    rep movsw
    ljmp $0, $relocated          # linked at 0x0600

relocated:
    sti
    mov %dl, drive

    # The active partition:
    mov $PART_TABLE, %si
    mov $4, %cx
1:  cmpb $0x80, (%si)
    je found
    add $16, %si
    loop 1b
    mov $no_active_msg, %si
    jmp fatal

found:
    mov %si, entry
    movb $5, tries
read:
    # LBA extensions (int 13h AH=41h), else the entry's CHS:
    mov $0x41, %ah
    mov $0x55AA, %bx
    mov drive, %dl
    int $0x13
    jc chs
    cmp $0xAA55, %bx
    jne chs
    test $1, %cl
    jz chs
    mov entry, %si
    mov 8(%si), %eax
    mov %eax, dap_lba
    mov $disk_packet, %si
    mov $0x42, %ah
    mov drive, %dl
    int $0x13
    jnc loaded
    jmp failed
chs:
    mov entry, %si
    mov 1(%si), %dh              # head
    mov 2(%si), %cx              # sector, cylinder
    mov $0x7C00, %bx
    mov $0x0201, %ax
    mov drive, %dl
    int $0x13
    jnc loaded
failed:
    xor %ah, %ah                 # reset the drive and try again
    mov drive, %dl
    int $0x13
    decb tries
    jnz read
    mov $disk_msg, %si
    jmp fatal

loaded:
    cmpw $0xAA55, 0x7DFE
    jne no_system
    mov entry, %si
    mov drive, %dl
    ljmp $0, $0x7C00

no_system:
    mov $no_system_msg, %si
fatal:
    lodsb
    or %al, %al
    jz 1f
    mov $0x0E, %ah
    xor %bx, %bx
    int $0x10
    jmp fatal
1:  jmp 1b

drive: .byte 0
tries: .byte 0
entry: .word 0

.align 4
disk_packet:
    .byte 0x10, 0
    .word 1                      # one sector
    .word 0x7C00, 0              # to 0000:7C00
dap_lba:
    .quad 0

no_active_msg: .asciz "No active partition"
disk_msg:      .asciz "Disk error"
no_system_msg: .asciz "No operating system"

# Code ends here: the disk signature and partition table follow.
.org 440
