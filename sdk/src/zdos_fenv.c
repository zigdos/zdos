/* fenv.h: rounding modes and exception flags. x86-64: SSE's MXCSR and the
 * x87 kept alike; x86 (BIOS, built without SSE): the x87; ARM64: FPCR and
 * FPSR. */
#include <fenv.h>
#include <stdint.h>

#if defined(__aarch64__)

#define ROUND_MASK 0xc00000u
#define TRAPS 0x9f00u /* FPCR exception trap enables */

static uint32_t get_fpcr(void) {
    uint64_t v;
    __asm__ volatile("mrs %0, fpcr" : "=r"(v));
    return (uint32_t)v;
}

static void set_fpcr(uint32_t v) {
    __asm__ volatile("msr fpcr, %0" : : "r"((uint64_t)v));
}

static uint32_t get_fpsr(void) {
    uint64_t v;
    __asm__ volatile("mrs %0, fpsr" : "=r"(v));
    return (uint32_t)v;
}

static void set_fpsr(uint32_t v) {
    __asm__ volatile("msr fpsr, %0" : : "r"((uint64_t)v));
}

static unsigned raised(void) {
    return get_fpsr() & FE_ALL_EXCEPT;
}

static void set_flags(unsigned clear, unsigned set) {
    set_fpsr((get_fpsr() & ~clear) | set);
}

int fegetround(void) {
    return (int)(get_fpcr() & ROUND_MASK);
}

static void set_round(unsigned mode) {
    set_fpcr((get_fpcr() & ~ROUND_MASK) | mode);
}

int fegetenv(fenv_t *env) {
    env->fpcr = get_fpcr();
    env->fpsr = get_fpsr();
    return 0;
}

int fesetenv(const fenv_t *env) {
    if (env == FE_DFL_ENV) {
        set_fpcr(get_fpcr() & ~(ROUND_MASK | TRAPS));
        set_fpsr(0);
    } else {
        set_fpcr(env->fpcr);
        set_fpsr(env->fpsr);
    }
    return 0;
}

int feholdexcept(fenv_t *env) {
    fegetenv(env);
    set_fpcr(env->fpcr & ~TRAPS);
    set_fpsr(env->fpsr & ~FE_ALL_EXCEPT);
    return 0;
}

#else /* x86, x86-64 */

#define ROUND_MASK 0xc00u
#define X87_MASKS 0x3fu      /* control word: exceptions masked */
#define SSE_MASKS 0x1f80u    /* MXCSR: exceptions masked */
#define SSE_ROUND_SHIFT 3    /* MXCSR's rounding bits are the x87's << 3 */

/* What fnstenv stores (protected mode, 28 bytes) */
typedef struct {
    uint16_t control, unused1;
    uint16_t status, unused2;
    uint32_t rest[5];
} x87_env;

static uint16_t get_cw(void) {
    uint16_t cw;
    __asm__ volatile("fnstcw %0" : "=m"(cw));
    return cw;
}

static void set_cw(uint16_t cw) {
    __asm__ volatile("fldcw %0" : : "m"(cw));
}

static uint16_t get_sw(void) {
    uint16_t sw;
    __asm__ volatile("fnstsw %0" : "=m"(sw));
    return sw;
}

// The x87 has no instruction that sets flags: through its environment
static void set_x87_flags(unsigned clear, unsigned set) {
    x87_env e;
    __asm__ volatile("fnstenv %0" : "=m"(e));
    e.status = (uint16_t)((e.status & ~clear) | set);
    __asm__ volatile("fldenv %0" : : "m"(e));
}

#ifdef __x86_64__
static uint32_t get_mxcsr(void) {
    uint32_t v;
    __asm__ volatile("stmxcsr %0" : "=m"(v));
    return v;
}

static void set_mxcsr(uint32_t v) {
    __asm__ volatile("ldmxcsr %0" : : "m"(v));
}
#endif

static unsigned raised(void) {
    unsigned f = get_sw();
#ifdef __x86_64__
    f |= get_mxcsr();
#endif
    return f & FE_ALL_EXCEPT;
}

// x86-64 keeps new flags in MXCSR, where float and double raise them
static void set_flags(unsigned clear, unsigned set) {
#ifdef __x86_64__
    set_x87_flags(clear, 0);
    set_mxcsr((get_mxcsr() & ~clear) | set);
#else
    set_x87_flags(clear, set);
#endif
}

int fegetround(void) {
#ifdef __x86_64__
    return (int)((get_mxcsr() >> SSE_ROUND_SHIFT) & ROUND_MASK);
#else
    return (int)(get_cw() & ROUND_MASK);
#endif
}

static void set_round(unsigned mode) {
    set_cw((uint16_t)((get_cw() & ~ROUND_MASK) | mode));
#ifdef __x86_64__
    set_mxcsr((get_mxcsr() & ~(ROUND_MASK << SSE_ROUND_SHIFT)) | (mode << SSE_ROUND_SHIFT));
#endif
}

int fegetenv(fenv_t *env) {
    env->control = get_cw();
    env->status = (uint16_t)(get_sw() & FE_ALL_EXCEPT);
#ifdef __x86_64__
    env->mxcsr = get_mxcsr();
#else
    env->mxcsr = 0;
#endif
    return 0;
}

int fesetenv(const fenv_t *env) {
    x87_env e;
    __asm__ volatile("fnstenv %0" : "=m"(e));
    if (env == FE_DFL_ENV) {
        e.control = (uint16_t)((e.control & ~ROUND_MASK) | X87_MASKS); /* precision kept */
        e.status &= (uint16_t)~FE_ALL_EXCEPT;
    } else {
        e.control = env->control;
        e.status = (uint16_t)((e.status & ~FE_ALL_EXCEPT) | (env->status & FE_ALL_EXCEPT));
    }
    __asm__ volatile("fldenv %0" : : "m"(e));
#ifdef __x86_64__
    set_mxcsr(env == FE_DFL_ENV ? SSE_MASKS : env->mxcsr);
#endif
    return 0;
}

int feholdexcept(fenv_t *env) {
    fegetenv(env);
    set_flags(FE_ALL_EXCEPT, 0);
    set_cw((uint16_t)(env->control | X87_MASKS));
#ifdef __x86_64__
    set_mxcsr((get_mxcsr() | SSE_MASKS) & ~FE_ALL_EXCEPT);
#endif
    return 0;
}

#endif

int feclearexcept(int excepts) {
    set_flags((unsigned)excepts & FE_ALL_EXCEPT, 0);
    return 0;
}

int fetestexcept(int excepts) {
    return (int)(raised() & (unsigned)excepts);
}

int feraiseexcept(int excepts) {
    unsigned e = (unsigned)excepts & FE_ALL_EXCEPT;
    set_flags(0, e);
    return 0;
}

int fegetexceptflag(fexcept_t *flags, int excepts) {
    *flags = (fexcept_t)(raised() & (unsigned)excepts);
    return 0;
}

int fesetexceptflag(const fexcept_t *flags, int excepts) {
    unsigned e = (unsigned)excepts & FE_ALL_EXCEPT;
    set_flags(e, *flags & e);
    return 0;
}

int fesetround(int mode) {
    if (mode != FE_TONEAREST && mode != FE_DOWNWARD && mode != FE_UPWARD && mode != FE_TOWARDZERO) {
        return -1;
    }
    set_round((unsigned)mode);
    return 0;
}

int feupdateenv(const fenv_t *env) {
    unsigned e = raised();
    fesetenv(env);
    set_flags(0, e);
    return 0;
}
