#pragma once
#ifndef _ZDOS_WCTYPE_H_
#define _ZDOS_WCTYPE_H_

#include <wchar.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Classes cover ASCII exactly and the main alphabets beyond it; case maps
   only Latin-1, Latin Extended-A, Greek and Cyrillic. (zdos_wchar.c) */
typedef unsigned long wctype_t;
typedef const int *wctrans_t;

int iswalnum(wint_t c);
int iswalpha(wint_t c);
int iswblank(wint_t c);
int iswcntrl(wint_t c);
int iswdigit(wint_t c);
int iswgraph(wint_t c);
int iswlower(wint_t c);
int iswprint(wint_t c);
int iswpunct(wint_t c);
int iswspace(wint_t c);
int iswupper(wint_t c);
int iswxdigit(wint_t c);
wint_t towlower(wint_t c);
wint_t towupper(wint_t c);
wctype_t wctype(const char *name);
int iswctype(wint_t c, wctype_t type);
wctrans_t wctrans(const char *name);
wint_t towctrans(wint_t c, wctrans_t trans);

/* With a locale_t (from wchar.h): only the "C" locale, as the plain ones */
int iswalnum_l(wint_t c, locale_t loc);
int iswalpha_l(wint_t c, locale_t loc);
int iswblank_l(wint_t c, locale_t loc);
int iswcntrl_l(wint_t c, locale_t loc);
int iswdigit_l(wint_t c, locale_t loc);
int iswgraph_l(wint_t c, locale_t loc);
int iswlower_l(wint_t c, locale_t loc);
int iswprint_l(wint_t c, locale_t loc);
int iswpunct_l(wint_t c, locale_t loc);
int iswspace_l(wint_t c, locale_t loc);
int iswupper_l(wint_t c, locale_t loc);
int iswxdigit_l(wint_t c, locale_t loc);
wint_t towlower_l(wint_t c, locale_t loc);
wint_t towupper_l(wint_t c, locale_t loc);
wctype_t wctype_l(const char *name, locale_t loc);
int iswctype_l(wint_t c, wctype_t type, locale_t loc);

#ifdef __cplusplus
}
#endif

#endif
