# Stage 2 of the BIOS boot loader, and the BIOS-call thunk:
# the first 4 KiB of ZIGDOS.SYS, followed by the LZ4 kernel.
# The VBR loads the file to 0000:8000 and jumps here with the
# drive in DL. It sets 80x25 text, A20, the memory map and
# protected mode, unpacks the kernel to 1 MiB and jumps to it
# with EAX = &boot_info. It stays resident: the kernel uses its
# GDT and bios_call. KERNEL_PACKED:
# as --32 --defsym KERNEL_PACKED=N.

.set E820_BUF,       0x1000
.set E820_MAX,       128          # 24-byte entries: up to 0x1C00
.set SCRATCH,        0x2000
.set RM_STACK,       0x7C00
.set KERNEL_LOAD,    0x9000
.set KERNEL_ADDR,    0x100000
.set BOUNCE,         0x10000
.set BOUNCE_SIZE,    0x10000

.set CODE32, 0x08
.set DATA32, 0x10
.set CODE16, 0x18
.set DATA16, 0x20

.code16
.global _start
_start:
    jmp stage2_start

# Must match BootInfo in platform/bios/realmode.zig:
.align 4
boot_info:
    .long 0x534F445A             # magic "ZDOS"
    .long bios_call              # void bios_call(u32 int_no, Regs *regs), cdecl
bi_e820_count:
    .long 0
    .long E820_BUF               # memory map entries (24 bytes each)
    .long BOUNCE
    .long BOUNCE_SIZE
    .long SCRATCH
bi_boot_drive:
    .long 0
bi_boot_lba:
    .long 0                      # first sector of the volume booted from

stage2_start:
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov $RM_STACK, %sp
    cld
    movzbl %dl, %edx
    mov %edx, bi_boot_drive
    # "Hidden sectors" in the BPB: where the boot volume starts:
    mov 0x7C1C, %eax
    mov %eax, bi_boot_lba

    # 80x25 color text mode (also clears the screen):
    mov $0x0003, %ax
    int $0x10

    call enable_a20
    call memory_map

    # Protected mode:
    cli
    lgdt gdt_descriptor
    mov %cr0, %eax
    or $1, %eax
    mov %eax, %cr0
    ljmp $CODE32, $pm_start

# The BIOS, the keyboard controller,
# then "fast A20" (port 0x92).
enable_a20:
    call a20_check
    jnz a20_done
    mov $0x2401, %ax
    int $0x15
    call a20_check
    jnz a20_done

    call kbc_wait
    mov $0xD1, %al               # write output port
    out %al, $0x64
    call kbc_wait
    mov $0xDF, %al               # A20 on, CPU running
    out %al, $0x60
    call kbc_wait
    call a20_check
    jnz a20_done

    in $0x92, %al
    test $2, %al
    jnz 1f
    or $2, %al
    and $0xFE, %al               # bit 0 would reset the machine
    out %al, $0x92
1:  call a20_check
    jnz a20_done
    mov $a20_msg, %si
    jmp fatal
a20_done:
    ret

# ZF clear if A20 is on: 0000:0500 and
# FFFF:0510 are the same byte if off.
a20_check:
    push %ds
    push %es
    xor %ax, %ax
    mov %ax, %ds
    mov $0xFFFF, %ax
    mov %ax, %es
    movb 0x0500, %bl
    movb %es:0x0510, %bh
    movb $0x00, 0x0500
    movb $0xFF, %es:0x0510
    cmpb $0xFF, 0x0500
    movb %bh, %es:0x0510         # mov does not change the flags
    movb %bl, 0x0500
    pop %es
    pop %ds
    ret

# With a time limit: some PCs have no keyboard controller.
kbc_wait:
    mov $0xFFFF, %cx
1:  in $0x64, %al
    test $2, %al
    jz 2f
    loop 1b
2:  ret

# 24-byte E820_BUF entries: base u64, length u64, type u32 (1:
# RAM), attributes u32.
memory_map:
    mov $E820_BUF, %di
    xor %ebx, %ebx
    xor %bp, %bp                 # entries stored
e820_next:
    mov $0xE820, %eax
    mov $24, %ecx
    mov $0x534D4150, %edx        # "SMAP"
    movl $1, %es:20(%di)         # valid attributes, for BIOSes returning only 20 bytes
    int $0x15
    jc e820_end
    cmp $0x534D4150, %eax
    jne e820_end
    jcxz e820_skip
    cmp $20, %cl
    jbe e820_keep
    testb $1, %es:20(%di)        # ACPI 3.0: bit 0 clear means "ignore this entry"
    jz e820_skip
e820_keep:
    inc %bp
    add $24, %di
    cmp $E820_MAX, %bp
    jae e820_end
e820_skip:
    test %ebx, %ebx
    jnz e820_next
e820_end:
    test %bp, %bp
    jnz e820_done

    # No E820:
    # E801 gives KiB from 1 to 16 MiB and 64 KiB blocks above:
    mov $E820_BUF, %di
    mov $0xE801, %ax
    xor %cx, %cx
    xor %dx, %dx
    int $0x15
    jc e88
    jcxz 1f                      # some BIOSes answer in AX/BX, others in CX/DX
    mov %cx, %ax
    mov %dx, %bx
1:  movzwl %ax, %eax
    shl $10, %eax
    mov $0x100000, %edx
    call add_entry
    movzwl %bx, %eax
    test %eax, %eax
    jz e820_done
    shl $16, %eax
    mov $0x1000000, %edx
    call add_entry
    jmp e820_done
e88:
    # Oldest: KiB above 1 MiB, up to 64 MiB:
    mov $0x88, %ah
    int $0x15
    jc e820_done
    movzwl %ax, %eax
    shl $10, %eax
    mov $0x100000, %edx
    call add_entry
e820_done:
    movzwl %bp, %eax
    mov %eax, bi_e820_count
    ret

# At ES:DI: base EDX, length EAX.
add_entry:
    mov %edx, %es:0(%di)
    movl $0, %es:4(%di)
    mov %eax, %es:8(%di)
    movl $0, %es:12(%di)
    movl $1, %es:16(%di)
    movl $1, %es:20(%di)
    inc %bp
    add $24, %di
    ret

# ERRORS (real mode)

fatal:
    lodsb
    or %al, %al
    jz 1f
    mov $0x0E, %ah
    mov $0x0007, %bx
    int $0x10
    jmp fatal
1:  cli
    hlt
    jmp 1b

a20_msg: .asciz "ZDOS: cannot enable the A20 line\r\n"

.code32
pm_start:
    mov $DATA32, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss
    mov $RM_STACK, %esp

    # The kernel was linked to run at 1 MiB:
    mov $KERNEL_LOAD, %esi
    mov $(KERNEL_LOAD + KERNEL_PACKED), %ebx
    mov $KERNEL_ADDR, %edi
    cld
    call unpack

    mov $boot_info, %eax
    jmp KERNEL_ADDR

# ESI (to EBX) to EDI: a token (literals' length, match
# length - 4; 15: more bytes follow, added while 255), the
# literals, the 2-byte distance back.
unpack:
1:  cmp %ebx, %esi
    jae 9f
    movzbl (%esi), %edx
    inc %esi
    mov %edx, %ecx
    shr $4, %ecx
    cmp $15, %ecx
    jne 3f
2:  movzbl (%esi), %eax
    inc %esi
    add %eax, %ecx
    cmp $255, %eax
    je 2b
3:  rep movsb
    cmp %ebx, %esi               # the last sequence has no match
    jae 9f
    movzwl (%esi), %eax
    add $2, %esi
    and $15, %edx
    cmp $15, %edx
    jne 5f
4:  movzbl (%esi), %ecx
    inc %esi
    add %ecx, %edx
    cmp $255, %ecx
    je 4b
5:  add $4, %edx
    push %esi
    mov %edi, %esi
    sub %eax, %esi
6:  movb (%esi), %al             # byte by byte: a match may overlap what it makes
    movb %al, (%edi)
    inc %esi
    inc %edi
    dec %edx
    jnz 6b
    pop %esi
    jmp 1b
9:  ret

# void bios_call(u32 int_no, Regs *regs)   (cdecl)
# Regs, 10 dwords: eax ebx ecx edx esi edi ebp ds es eflags,
# loaded before the interrupt and stored back after it (flags:
# low 16 bits). Buffers must be below 1 MiB.
# Interrupts are on only while the BIOS runs.

# BIOS CALLS FROM PROTECTED MODE
.set REGS_DWORDS, 10

bios_call:
    pushal
    mov 36(%esp), %eax           # int_no
    mov 40(%esp), %esi           # regs
    mov %esi, regs_ptr
    movzbl %al, %eax
    mov (,%eax,4), %eax          # the handler's address from the real-mode IVT
    mov %eax, int_vector
    mov $rm_regs, %edi
    mov $REGS_DWORDS, %ecx
    cld
    rep movsl
    mov %esp, saved_esp
    sidt saved_idt
    ljmp $CODE16, $pm16

.code16
pm16:
    # 16-bit segments with 64 KiB limits, as real mode expects:
    mov $DATA16, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss
    mov %cr0, %eax
    and $0xFFFFFFFE, %eax
    mov %eax, %cr0
    ljmp $0, $real_mode

real_mode:
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %ss
    mov %ax, %fs
    mov %ax, %gs
    mov $RM_STACK, %esp
    lidt rm_idt

    mov rm_regs + 32, %ax
    mov %ax, %es
    mov rm_regs + 0, %eax
    mov rm_regs + 4, %ebx
    mov rm_regs + 8, %ecx
    mov rm_regs + 12, %edx
    mov rm_regs + 16, %esi
    mov rm_regs + 20, %edi
    mov rm_regs + 24, %ebp
    pushw rm_regs + 28
    pop %ds

    sti
    pushfw                       # pushf + far call = int, through the saved vector
    lcallw *%cs:int_vector
    cli

    pushfw
    pushw %ds
    pushl %eax
    xor %ax, %ax
    mov %ax, %ds
    popl rm_regs + 0
    popw rm_regs + 28
    popw rm_regs + 36
    movw $0, rm_regs + 38
    movw $0, rm_regs + 30
    mov %ebx, rm_regs + 4
    mov %ecx, rm_regs + 8
    mov %edx, rm_regs + 12
    mov %esi, rm_regs + 16
    mov %edi, rm_regs + 20
    mov %ebp, rm_regs + 24
    movl $0, rm_regs + 32
    mov %es, rm_regs + 32

    lgdt gdt_descriptor          # in case the BIOS changed it
    mov %cr0, %eax
    or $1, %eax
    mov %eax, %cr0
    ljmpl $CODE32, $back_to_pm

.code32
back_to_pm:
    mov $DATA32, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss
    mov saved_esp, %esp
    lidt saved_idt
    mov $rm_regs, %esi
    mov regs_ptr, %edi
    mov $REGS_DWORDS, %ecx
    cld
    rep movsl
    popal
    ret

.align 4
rm_regs:    .fill REGS_DWORDS, 4, 0
regs_ptr:   .long 0
int_vector: .long 0
saved_esp:  .long 0
saved_idt:  .word 0
            .long 0
rm_idt:     .word 0x3FF          # the real-mode interrupt table at address 0
            .long 0

.align 8
gdt_start:
    .quad 0x0000000000000000
    .quad 0x00CF9A000000FFFF     # 0x08: 32-bit code, base 0, 4 GiB
    .quad 0x00CF92000000FFFF     # 0x10: 32-bit data, base 0, 4 GiB
    .quad 0x00009A000000FFFF     # 0x18: 16-bit code, base 0, 64 KiB (for bios_call)
    .quad 0x000092000000FFFF     # 0x20: 16-bit data, base 0, 64 KiB
    .quad 0x00CF92000000FFFF     # 0x28: thread pointer (GS), base set by the kernel
gdt_end:

gdt_descriptor:
    .word gdt_end - gdt_start - 1
    .long gdt_start
