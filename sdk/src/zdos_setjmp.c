/* setjmp and longjmp in top-level assembly, for zig cc and GCC alike.
 * jmp_buf:
 *
 *   i686 (cdecl):    0 ebx, 1 esi, 2 edi, 3 ebp, 4 esp, 5 return address
 *   x86-64 (SysV):   0 rbx, 1 rbp, 2 r12, 3 r13, 4 r14, 5 r15,
 *                    6 rsp, 7 return address
 *   ARM64 (AAPCS64): 0-9 x19-x28, 10 x29, 11 x30 (return address),
 *                    12 sp, 13-20 d8-d15 (the lower 64 bits)
 *
 * Words are unsigned long, as big as a pointer on each CPU.
 */

#include <setjmp.h>

#if defined(__i386__)

__asm__(
    ".text\n"
    ".globl setjmp\n"
    ".type setjmp, @function\n"
    ".p2align 4\n"
    "setjmp:\n"
    "    movl 4(%esp), %eax\n"      /* env */
    "    movl %ebx, 0(%eax)\n"
    "    movl %esi, 4(%eax)\n"
    "    movl %edi, 8(%eax)\n"
    "    movl %ebp, 12(%eax)\n"
    "    leal 4(%esp), %ecx\n"      /* the stack pointer after the return */
    "    movl %ecx, 16(%eax)\n"
    "    movl (%esp), %ecx\n"       /* the return address */
    "    movl %ecx, 20(%eax)\n"
    "    xorl %eax, %eax\n"
    "    ret\n"
    ".size setjmp, .-setjmp\n"

    ".globl longjmp\n"
    ".type longjmp, @function\n"
    ".p2align 4\n"
    "longjmp:\n"
    "    movl 4(%esp), %edx\n"      /* env */
    "    movl 8(%esp), %eax\n"      /* val */
    "    testl %eax, %eax\n"
    "    jnz 1f\n"
    "    movl $1, %eax\n"           /* longjmp(env, 0) returns 1 */
    "1:\n"
    "    movl 0(%edx), %ebx\n"
    "    movl 4(%edx), %esi\n"
    "    movl 8(%edx), %edi\n"
    "    movl 12(%edx), %ebp\n"
    "    movl 16(%edx), %esp\n"
    "    jmp *20(%edx)\n"
    ".size longjmp, .-longjmp\n"
);

#elif defined(__x86_64__)

__asm__(
    ".text\n"
    ".globl setjmp\n"
    ".type setjmp, @function\n"
    ".p2align 4\n"
    "setjmp:\n"                     /* rdi = env */
    "    movq %rbx, 0(%rdi)\n"
    "    movq %rbp, 8(%rdi)\n"
    "    movq %r12, 16(%rdi)\n"
    "    movq %r13, 24(%rdi)\n"
    "    movq %r14, 32(%rdi)\n"
    "    movq %r15, 40(%rdi)\n"
    "    leaq 8(%rsp), %rdx\n"      /* the stack pointer after the return */
    "    movq %rdx, 48(%rdi)\n"
    "    movq (%rsp), %rdx\n"       /* the return address */
    "    movq %rdx, 56(%rdi)\n"
    "    xorl %eax, %eax\n"
    "    ret\n"
    ".size setjmp, .-setjmp\n"

    ".globl longjmp\n"
    ".type longjmp, @function\n"
    ".p2align 4\n"
    "longjmp:\n"                    /* rdi = env, esi = val */
    "    movl %esi, %eax\n"
    "    testl %eax, %eax\n"
    "    jnz 1f\n"
    "    movl $1, %eax\n"           /* longjmp(env, 0) returns 1 */
    "1:\n"
    "    movq 0(%rdi), %rbx\n"
    "    movq 8(%rdi), %rbp\n"
    "    movq 16(%rdi), %r12\n"
    "    movq 24(%rdi), %r13\n"
    "    movq 32(%rdi), %r14\n"
    "    movq 40(%rdi), %r15\n"
    "    movq 48(%rdi), %rsp\n"
    "    jmp *56(%rdi)\n"
    ".size longjmp, .-longjmp\n"
);

#elif defined(__aarch64__)

__asm__(
    ".text\n"
    ".globl setjmp\n"
    ".type setjmp, %function\n"
    ".p2align 4\n"
    "setjmp:\n"                     /* x0 = env */
    "    stp x19, x20, [x0, #0]\n"
    "    stp x21, x22, [x0, #16]\n"
    "    stp x23, x24, [x0, #32]\n"
    "    stp x25, x26, [x0, #48]\n"
    "    stp x27, x28, [x0, #64]\n"
    "    stp x29, x30, [x0, #80]\n" /* x30: the return address */
    "    mov x1, sp\n"
    "    str x1, [x0, #96]\n"       /* the stack pointer */
    "    stp d8, d9, [x0, #104]\n"
    "    stp d10, d11, [x0, #120]\n"
    "    stp d12, d13, [x0, #136]\n"
    "    stp d14, d15, [x0, #152]\n"
    "    mov x0, #0\n"
    "    ret\n"
    ".size setjmp, .-setjmp\n"

    ".globl longjmp\n"
    ".type longjmp, %function\n"
    ".p2align 4\n"
    "longjmp:\n"                    /* x0 = env, w1 = val */
    "    cbnz w1, 1f\n"
    "    mov w1, #1\n"              /* longjmp(env, 0) returns 1 */
    "1:\n"
    "    ldp x19, x20, [x0, #0]\n"
    "    ldp x21, x22, [x0, #16]\n"
    "    ldp x23, x24, [x0, #32]\n"
    "    ldp x25, x26, [x0, #48]\n"
    "    ldp x27, x28, [x0, #64]\n"
    "    ldp x29, x30, [x0, #80]\n"
    "    ldr x2, [x0, #96]\n"
    "    mov sp, x2\n"
    "    ldp d8, d9, [x0, #104]\n"
    "    ldp d10, d11, [x0, #120]\n"
    "    ldp d12, d13, [x0, #136]\n"
    "    ldp d14, d15, [x0, #152]\n"
    "    mov w0, w1\n"              /* the value, returned by setjmp */
    "    ret\n"                     /* to x30, the caller of setjmp */
    ".size longjmp, .-longjmp\n"
);

#else
#error "zdos setjmp: this CPU has no implementation yet (see zdos_setjmp.c)"
#endif
