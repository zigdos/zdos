#pragma once
#ifndef _ZDOS_LOCALE_H_
#define _ZDOS_LOCALE_H_

#ifdef __cplusplus
extern "C" {
#endif

#ifndef NULL
#define NULL ((void *)0)
#endif

#define LC_ALL 0
#define LC_COLLATE 1
#define LC_CTYPE 2
#define LC_MONETARY 3
#define LC_NUMERIC 4
#define LC_TIME 5
#define LC_MESSAGES 6

#define LC_COLLATE_MASK (1 << LC_COLLATE)
#define LC_CTYPE_MASK (1 << LC_CTYPE)
#define LC_MONETARY_MASK (1 << LC_MONETARY)
#define LC_NUMERIC_MASK (1 << LC_NUMERIC)
#define LC_TIME_MASK (1 << LC_TIME)
#define LC_MESSAGES_MASK (1 << LC_MESSAGES)
#define LC_ALL_MASK 0x7E

/* Only the "C" locale exists */
struct lconv {
    char *decimal_point;
    char *thousands_sep;
    char *grouping;
    char *int_curr_symbol;
    char *currency_symbol;
    char *mon_decimal_point;
    char *mon_thousands_sep;
    char *mon_grouping;
    char *positive_sign;
    char *negative_sign;
    char int_frac_digits;
    char frac_digits;
    char p_cs_precedes;
    char p_sep_by_space;
    char n_cs_precedes;
    char n_sep_by_space;
    char p_sign_posn;
    char n_sign_posn;
    char int_p_cs_precedes;
    char int_p_sep_by_space;
    char int_n_cs_precedes;
    char int_n_sep_by_space;
    char int_p_sign_posn;
    char int_n_sign_posn;
};

char *setlocale(int category, const char *locale); /* "C", "POSIX" or "": "C"; others: NULL */
struct lconv *localeconv(void);

/* POSIX 2008 locale objects (and the *_l functions in ctype.h, string.h,
   stdlib.h, time.h, wchar.h, wctype.h): newlocale knows "C", "POSIX" and
   "" (the same), else NULL with ENOENT */
#ifndef _LOCALE_T_DEFINED
#define _LOCALE_T_DEFINED
typedef struct zdos_locale *locale_t;
#endif
#define LC_GLOBAL_LOCALE ((locale_t)-1)
locale_t newlocale(int mask, const char *name, locale_t base);
locale_t duplocale(locale_t loc);
void freelocale(locale_t loc);
locale_t uselocale(locale_t loc);

#ifdef __cplusplus
}
#endif

#endif
