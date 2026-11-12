/* Wide characters (wchar.h, wctype.h, uchar.h, the multibyte
 * functions of stdlib.h): wchar_t holds a Unicode code point,
 * multibyte text is UTF-8. Character classes and case cover ASCII
 * exactly and the main alphabets beyond it (see wctype.h);
 * wcwidth knows combining marks and East Asian wide characters. */
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <uchar.h>
#include <wchar.h>
#include <wctype.h>

/* UTF-8 */

static size_t put_utf8(uint32_t c, char *out) {
    if (c < 0x80) {
        out[0] = (char)c;
        return 1;
    }
    if (c < 0x800) {
        out[0] = (char)(0xC0 | (c >> 6));
        out[1] = (char)(0x80 | (c & 0x3F));
        return 2;
    }
    if (c < 0x10000) {
        out[0] = (char)(0xE0 | (c >> 12));
        out[1] = (char)(0x80 | ((c >> 6) & 0x3F));
        out[2] = (char)(0x80 | (c & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | (c >> 18));
    out[1] = (char)(0x80 | ((c >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((c >> 6) & 0x3F));
    out[3] = (char)(0x80 | (c & 0x3F));
    return 4;
}

static int valid_char(uint32_t c) {
    return c <= 0x10FFFF && !(c >= 0xD800 && c <= 0xDFFF);
}

int mbsinit(const mbstate_t *st) {
    return st == NULL || st->need == 0;
}

/* One character from at most n bytes: the bytes it took (0 for NUL),
   (size_t)-2 if n ended inside it (st keeps what was read), (size_t)-1 and
   EILSEQ if the bytes aren't UTF-8 */
size_t mbrtowc(wchar_t *out, const char *s, size_t n, mbstate_t *st) {
    static mbstate_t own;
    if (st == NULL) {
        st = &own;
    }
    if (s == NULL) {
        s = "";
        n = 1;
        out = NULL;
    }
    if (n == 0) {
        return (size_t)-2;
    }
    size_t used = 0;
    uint32_t c = st->pending;
    unsigned need = st->need;
    unsigned seen = st->seen;
    if (need == 0) {
        unsigned char b = (unsigned char)s[used++];
        if (b < 0x80) {
            if (out != NULL) {
                *out = (wchar_t)b;
            }
            return b == 0 ? 0 : 1;
        }
        if (b >= 0xC2 && b <= 0xDF) {
            c = b & 0x1F;
            need = 1;
        } else if (b >= 0xE0 && b <= 0xEF) {
            c = b & 0x0F;
            need = 2;
        } else if (b >= 0xF0 && b <= 0xF4) {
            c = b & 0x07;
            need = 3;
        } else {
            errno = EILSEQ;
            return (size_t)-1;
        }
        seen = 1;
    }
    while (need > 0) {
        if (used == n) {
            st->pending = c;
            st->need = (unsigned char)need;
            st->seen = (unsigned char)seen;
            return (size_t)-2;
        }
        unsigned char b = (unsigned char)s[used++];
        if ((b & 0xC0) != 0x80) {
            *st = (mbstate_t){0};
            errno = EILSEQ;
            return (size_t)-1;
        }
        c = (c << 6) | (b & 0x3F);
        need--;
        seen++;
    }
    *st = (mbstate_t){0};
    /* Overlong forms, surrogates and beyond U+10FFFF aren't UTF-8 */
    if (!valid_char(c) || (seen == 3 && c < 0x800) || (seen == 4 && c < 0x10000)) {
        errno = EILSEQ;
        return (size_t)-1;
    }
    if (out != NULL) {
        *out = (wchar_t)c;
    }
    return c == 0 ? 0 : used;
}

size_t mbrlen(const char *s, size_t n, mbstate_t *st) {
    static mbstate_t own;
    return mbrtowc(NULL, s, n, st != NULL ? st : &own);
}

size_t wcrtomb(char *out, wchar_t c, mbstate_t *st) {
    (void)st;
    char buf[4];
    if (out == NULL) {
        return 1;
    }
    if (!valid_char((uint32_t)c)) {
        errno = EILSEQ;
        return (size_t)-1;
    }
    size_t n = put_utf8((uint32_t)c, buf);
    memcpy(out, buf, n);
    return n;
}

int mblen(const char *s, size_t n) {
    static mbstate_t st;
    if (s == NULL) {
        st = (mbstate_t){0};
        return 0;
    }
    size_t r = mbrtowc(NULL, s, n, &st);
    if (r == (size_t)-2) {
        st = (mbstate_t){0};
        errno = EILSEQ;
        return -1;
    }
    return r == (size_t)-1 ? -1 : (int)r;
}

int mbtowc(wchar_t *out, const char *s, size_t n) {
    if (s == NULL) {
        return 0; /* no shift states */
    }
    mbstate_t st = {0};
    size_t r = mbrtowc(out, s, n, &st);
    if (r == (size_t)-1 || r == (size_t)-2) {
        errno = EILSEQ;
        return -1;
    }
    return (int)r;
}

int wctomb(char *out, wchar_t c) {
    if (out == NULL) {
        return 0;
    }
    size_t r = wcrtomb(out, c, NULL);
    return r == (size_t)-1 ? -1 : (int)r;
}

size_t mbsnrtowcs(wchar_t *out, const char **src, size_t nms, size_t n, mbstate_t *st) {
    static mbstate_t own;
    if (st == NULL) {
        st = &own;
    }
    const char *s = *src;
    size_t count = 0;
    while (out == NULL || count < n) {
        wchar_t c;
        size_t r = mbrtowc(&c, s, nms, st);
        if (r == (size_t)-1) {
            if (out != NULL) {
                *src = s;
            }
            return (size_t)-1;
        }
        if (r == (size_t)-2) {
            s += nms;
            break;
        }
        if (r == 0) {
            if (out != NULL) {
                out[count] = 0;
                *src = NULL;
            }
            return count;
        }
        if (out != NULL) {
            out[count] = c;
        }
        s += r;
        nms -= r;
        count++;
    }
    if (out != NULL) {
        *src = s;
    }
    return count;
}

size_t mbsrtowcs(wchar_t *out, const char **src, size_t n, mbstate_t *st) {
    return mbsnrtowcs(out, src, SIZE_MAX, n, st);
}

size_t wcsnrtombs(char *out, const wchar_t **src, size_t nwc, size_t n, mbstate_t *st) {
    (void)st;
    const wchar_t *s = *src;
    size_t count = 0;
    for (; nwc > 0; nwc--, s++) {
        if (*s == 0) {
            if (out != NULL) {
                if (count < n) {
                    out[count] = '\0';
                }
                *src = NULL;
            }
            return count;
        }
        if (!valid_char((uint32_t)*s)) {
            errno = EILSEQ;
            if (out != NULL) {
                *src = s;
            }
            return (size_t)-1;
        }
        char buf[4];
        size_t k = put_utf8((uint32_t)*s, buf);
        if (out != NULL) {
            if (count + k > n) {
                break;
            }
            memcpy(out + count, buf, k);
        }
        count += k;
    }
    if (out != NULL) {
        *src = s;
    }
    return count;
}

size_t wcsrtombs(char *out, const wchar_t **src, size_t n, mbstate_t *st) {
    return wcsnrtombs(out, src, SIZE_MAX, n, st);
}

size_t mbstowcs(wchar_t *out, const char *s, size_t n) {
    mbstate_t st = {0};
    return mbsrtowcs(out, &s, n, &st);
}

size_t wcstombs(char *out, const wchar_t *s, size_t n) {
    return wcsrtombs(out, &s, n, NULL);
}

wint_t btowc(int c) {
    return c >= 0 && c < 0x80 ? (wint_t)c : WEOF;
}

int wctob(wint_t c) {
    return c < 0x80 ? (int)c : EOF;
}

/* char32_t is wchar_t's code point; char16_t pairs surrogates */
size_t mbrtoc32(char32_t *out, const char *s, size_t n, mbstate_t *st) {
    wchar_t c;
    size_t r = mbrtowc(&c, s, n, st);
    if (out != NULL && r != (size_t)-1 && r != (size_t)-2) {
        *out = (char32_t)c;
    }
    return r;
}

size_t c32rtomb(char *out, char32_t c, mbstate_t *st) {
    return wcrtomb(out, (wchar_t)c, st);
}

/* A character beyond U+FFFF gives its high surrogate first, the low one on
   the next call ((size_t)-3: from the state, no bytes taken) */
size_t mbrtoc16(char16_t *out, const char *s, size_t n, mbstate_t *st) {
    static mbstate_t own;
    if (st == NULL) {
        st = &own;
    }
    if (st->need == 0 && st->seen == 0xFF) {
        if (out != NULL) {
            *out = (char16_t)st->pending;
        }
        *st = (mbstate_t){0};
        return (size_t)-3;
    }
    wchar_t c;
    size_t r = mbrtowc(&c, s, n, st);
    if (r == (size_t)-1 || r == (size_t)-2) {
        return r;
    }
    uint32_t u = (uint32_t)c;
    if (u >= 0x10000) {
        u -= 0x10000;
        if (out != NULL) {
            *out = (char16_t)(0xD800 | (u >> 10));
        }
        st->pending = 0xDC00 | (u & 0x3FF);
        st->seen = 0xFF;
        return r;
    }
    if (out != NULL) {
        *out = (char16_t)u;
    }
    return r;
}

size_t c16rtomb(char *out, char16_t c, mbstate_t *st) {
    static mbstate_t own;
    if (st == NULL) {
        st = &own;
    }
    if (out == NULL) {
        *st = (mbstate_t){0};
        return 1;
    }
    if (c >= 0xD800 && c <= 0xDBFF) {
        st->pending = c;
        st->seen = 0xFE;
        return 0;
    }
    uint32_t u = c;
    if (c >= 0xDC00 && c <= 0xDFFF) {
        if (st->seen != 0xFE) {
            errno = EILSEQ;
            return (size_t)-1;
        }
        u = 0x10000 + ((st->pending - 0xD800) << 10) + (c - 0xDC00);
    }
    *st = (mbstate_t){0};
    return put_utf8(u, out);
}

/* WIDE STRINGS */

size_t wcslen(const wchar_t *s) {
    size_t n = 0;
    while (s[n] != 0) {
        n++;
    }
    return n;
}

size_t wcsnlen(const wchar_t *s, size_t max) {
    size_t n = 0;
    while (n < max && s[n] != 0) {
        n++;
    }
    return n;
}

wchar_t *wcscpy(wchar_t *dest, const wchar_t *src) {
    wchar_t *d = dest;
    while ((*d++ = *src++) != 0) {
    }
    return dest;
}

wchar_t *wcsncpy(wchar_t *dest, const wchar_t *src, size_t n) {
    size_t i = 0;
    for (; i < n && src[i] != 0; i++) {
        dest[i] = src[i];
    }
    for (; i < n; i++) {
        dest[i] = 0;
    }
    return dest;
}

wchar_t *wcscat(wchar_t *dest, const wchar_t *src) {
    wcscpy(dest + wcslen(dest), src);
    return dest;
}

wchar_t *wcsncat(wchar_t *dest, const wchar_t *src, size_t n) {
    wchar_t *d = dest + wcslen(dest);
    size_t i = 0;
    for (; i < n && src[i] != 0; i++) {
        d[i] = src[i];
    }
    d[i] = 0;
    return dest;
}

int wcscmp(const wchar_t *a, const wchar_t *b) {
    while (*a != 0 && *a == *b) {
        a++;
        b++;
    }
    return *a < *b ? -1 : *a > *b;
}

int wcsncmp(const wchar_t *a, const wchar_t *b, size_t n) {
    for (; n > 0; n--, a++, b++) {
        if (*a != *b || *a == 0) {
            return *a < *b ? -1 : *a > *b;
        }
    }
    return 0;
}

int wcscasecmp(const wchar_t *a, const wchar_t *b) {
    for (;; a++, b++) {
        wint_t x = towlower((wint_t)*a), y = towlower((wint_t)*b);
        if (x != y || x == 0) {
            return x < y ? -1 : x > y;
        }
    }
}

int wcsncasecmp(const wchar_t *a, const wchar_t *b, size_t n) {
    for (; n > 0; n--, a++, b++) {
        wint_t x = towlower((wint_t)*a), y = towlower((wint_t)*b);
        if (x != y || x == 0) {
            return x < y ? -1 : x > y;
        }
    }
    return 0;
}

int wcscoll(const wchar_t *a, const wchar_t *b) {
    return wcscmp(a, b);
}

int wcscoll_l(const wchar_t *a, const wchar_t *b, locale_t loc) {
    (void)loc;
    return wcscmp(a, b);
}

size_t wcsxfrm(wchar_t *dest, const wchar_t *src, size_t n) {
    size_t len = wcslen(src);
    if (len < n) {
        wcscpy(dest, src);
    }
    return len;
}

wchar_t *wcschr(const wchar_t *s, wchar_t c) {
    for (;; s++) {
        if (*s == c) {
            return (wchar_t *)s;
        }
        if (*s == 0) {
            return NULL;
        }
    }
}

wchar_t *wcsrchr(const wchar_t *s, wchar_t c) {
    const wchar_t *last = NULL;
    for (;; s++) {
        if (*s == c) {
            last = s;
        }
        if (*s == 0) {
            return (wchar_t *)last;
        }
    }
}

wchar_t *wcsstr(const wchar_t *hay, const wchar_t *needle) {
    size_t n = wcslen(needle);
    if (n == 0) {
        return (wchar_t *)hay;
    }
    for (; *hay != 0; hay++) {
        if (wcsncmp(hay, needle, n) == 0) {
            return (wchar_t *)hay;
        }
    }
    return NULL;
}

size_t wcsspn(const wchar_t *s, const wchar_t *set) {
    size_t n = 0;
    while (s[n] != 0 && wcschr(set, s[n]) != NULL) {
        n++;
    }
    return n;
}

size_t wcscspn(const wchar_t *s, const wchar_t *set) {
    size_t n = 0;
    while (s[n] != 0 && wcschr(set, s[n]) == NULL) {
        n++;
    }
    return n;
}

wchar_t *wcspbrk(const wchar_t *s, const wchar_t *set) {
    s += wcscspn(s, set);
    return *s != 0 ? (wchar_t *)s : NULL;
}

wchar_t *wcstok(wchar_t *s, const wchar_t *delim, wchar_t **save) {
    if (s == NULL) {
        s = *save;
    }
    s += wcsspn(s, delim);
    if (*s == 0) {
        *save = s;
        return NULL;
    }
    wchar_t *end = s + wcscspn(s, delim);
    if (*end != 0) {
        *end++ = 0;
    }
    *save = end;
    return s;
}

wchar_t *wcsdup(const wchar_t *s) {
    size_t n = (wcslen(s) + 1) * sizeof(wchar_t);
    wchar_t *d = malloc(n);
    if (d != NULL) {
        memcpy(d, s, n);
    }
    return d;
}

wchar_t *wmemcpy(wchar_t *dest, const wchar_t *src, size_t n) {
    return memcpy(dest, src, n * sizeof(wchar_t));
}

wchar_t *wmemmove(wchar_t *dest, const wchar_t *src, size_t n) {
    return memmove(dest, src, n * sizeof(wchar_t));
}

wchar_t *wmemset(wchar_t *dest, wchar_t c, size_t n) {
    for (size_t i = 0; i < n; i++) {
        dest[i] = c;
    }
    return dest;
}

int wmemcmp(const wchar_t *a, const wchar_t *b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (a[i] != b[i]) {
            return a[i] < b[i] ? -1 : 1;
        }
    }
    return 0;
}

wchar_t *wmemchr(const wchar_t *s, wchar_t c, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (s[i] == c) {
            return (wchar_t *)&s[i];
        }
    }
    return NULL;
}

/* NUMBERS: THE ASCII PART OF THE TEXT THROUGH THE NARROW FUNCTIONS */

#define NUM_MAX 128

static size_t narrow_number(const wchar_t *s, char *buf) {
    size_t n = 0;
    while (n < NUM_MAX - 1 && s[n] != 0 && s[n] < 0x80) {
        buf[n] = (char)s[n];
        n++;
    }
    buf[n] = '\0';
    return n;
}

#define WIDE_STRTO(name, type, call)                       \
    type name(const wchar_t *s, wchar_t **end, int base) { \
        char buf[NUM_MAX];                                  \
        narrow_number(s, buf);                              \
        char *e;                                            \
        type v = call(buf, &e, base);                       \
        if (end != NULL) {                                  \
            *end = (wchar_t *)s + (e - buf);                \
        }                                                   \
        return v;                                           \
    }
WIDE_STRTO(wcstol, long, strtol)
WIDE_STRTO(wcstoul, unsigned long, strtoul)
WIDE_STRTO(wcstoll, long long, strtoll)
WIDE_STRTO(wcstoull, unsigned long long, strtoull)

double wcstod(const wchar_t *s, wchar_t **end) {
    char buf[NUM_MAX];
    narrow_number(s, buf);
    char *e;
    double v = strtod(buf, &e);
    if (end != NULL) {
        *end = (wchar_t *)s + (e - buf);
    }
    return v;
}

float wcstof(const wchar_t *s, wchar_t **end) {
    return (float)wcstod(s, end);
}

long double wcstold(const wchar_t *s, wchar_t **end) {
    return wcstod(s, end);
}

/* CLASSES AND CASE */

typedef struct {
    uint32_t first, last;
} range;

static int in(uint32_t c, const range *r, size_t n) {
    size_t lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (c < r[mid].first) {
            hi = mid;
        } else if (c > r[mid].last) {
            lo = mid + 1;
        } else {
            return 1;
        }
    }
    return 0;
}

#define COUNT(a) (sizeof(a) / sizeof((a)[0]))

/* Letters beyond ASCII (main scripts; a few marks inside are counted too) */
static const range alpha_ranges[] = {
    {0x00AA, 0x00AA}, {0x00B5, 0x00B5}, {0x00BA, 0x00BA}, {0x00C0, 0x00D6}, {0x00D8, 0x00F6},
    {0x00F8, 0x02C1}, {0x0370, 0x0374}, {0x0376, 0x037D}, {0x0386, 0x0386}, {0x0388, 0x03FF},
    {0x0400, 0x0481}, {0x048A, 0x052F}, {0x0531, 0x0556}, {0x0561, 0x0587}, {0x05D0, 0x05EA},
    {0x0620, 0x064A}, {0x066E, 0x06D3}, {0x0904, 0x0939}, {0x0E01, 0x0E30}, {0x10A0, 0x10FF},
    {0x1100, 0x11FF}, {0x1E00, 0x1FFF}, {0x3041, 0x3096}, {0x30A1, 0x30FA}, {0x3105, 0x312F},
    {0x3400, 0x4DBF}, {0x4E00, 0x9FFF}, {0xA000, 0xA48C}, {0xAC00, 0xD7A3}, {0xF900, 0xFAFF},
    {0xFF21, 0xFF3A}, {0xFF41, 0xFF5A}, {0xFF66, 0xFFDC}, {0x20000, 0x2FA1F},
};

static const range space_ranges[] = {
    {0x0085, 0x0085}, {0x1680, 0x1680}, {0x2000, 0x2006}, {0x2008, 0x200A},
    {0x2028, 0x2029}, {0x205F, 0x205F}, {0x3000, 0x3000},
};

/* Decimal digits of other scripts are not iswdigit (C: only 0-9) */
static int is_upper_beyond(uint32_t c);
static int is_lower_beyond(uint32_t c);

int iswalpha(wint_t c) {
    if (c < 0x80) {
        return (c | 0x20) >= 'a' && (c | 0x20) <= 'z';
    }
    return in(c, alpha_ranges, COUNT(alpha_ranges));
}

int iswdigit(wint_t c) {
    return c >= '0' && c <= '9';
}

int iswxdigit(wint_t c) {
    return iswdigit(c) || ((c | 0x20) >= 'a' && (c | 0x20) <= 'f');
}

int iswalnum(wint_t c) {
    return iswalpha(c) || iswdigit(c);
}

int iswspace(wint_t c) {
    if (c < 0x80) {
        return c == ' ' || (c >= '\t' && c <= '\r');
    }
    return in(c, space_ranges, COUNT(space_ranges));
}

int iswblank(wint_t c) {
    return c == ' ' || c == '\t' || c == 0x1680 || (c >= 0x2000 && c <= 0x2006) || (c >= 0x2008 && c <= 0x200A) ||
        c == 0x205F || c == 0x3000;
}

int iswcntrl(wint_t c) {
    return c < 0x20 || (c >= 0x7F && c < 0xA0) || c == 0x2028 || c == 0x2029;
}

int iswprint(wint_t c) {
    if (c == WEOF || iswcntrl(c) || c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF) || c == 0xFFFE || c == 0xFFFF) {
        return 0;
    }
    return 1;
}

int iswgraph(wint_t c) {
    return iswprint(c) && !iswspace(c);
}

int iswpunct(wint_t c) {
    return iswgraph(c) && !iswalnum(c);
}

int iswupper(wint_t c) {
    if (c < 0x80) {
        return c >= 'A' && c <= 'Z';
    }
    return is_upper_beyond(c);
}

int iswlower(wint_t c) {
    if (c < 0x80) {
        return c >= 'a' && c <= 'z';
    }
    return is_lower_beyond(c);
}

/* Case: Latin-1, Latin Extended-A, Greek, Cyrillic, Armenian, full-width */
wint_t towlower(wint_t c) {
    if (c < 0x80) {
        return c >= 'A' && c <= 'Z' ? c + 32 : c;
    }
    if ((c >= 0xC0 && c <= 0xDE && c != 0xD7)) {
        return c + 32;
    }
    if (c >= 0x100 && c <= 0x17F) {
        if (c == 0x130) {
            return 'i';
        }
        if (c == 0x178) {
            return 0xFF;
        }
        if ((c >= 0x139 && c <= 0x148) || (c >= 0x179 && c <= 0x17E)) {
            return (c & 1) ? c + 1 : c;
        }
        if (c == 0x131 || c == 0x138 || c == 0x149 || c == 0x17F) {
            return c;
        }
        return (c & 1) ? c : c + 1;
    }
    if (c >= 0x391 && c <= 0x3AB && c != 0x3A2) {
        return c + 32;
    }
    if (c >= 0x386 && c <= 0x38F) {
        switch (c) {
            case 0x386: return 0x3AC;
            case 0x388: return 0x3AD;
            case 0x389: return 0x3AE;
            case 0x38A: return 0x3AF;
            case 0x38C: return 0x3CC;
            case 0x38E: return 0x3CD;
            case 0x38F: return 0x3CE;
        }
    }
    if (c >= 0x410 && c <= 0x42F) {
        return c + 32;
    }
    if (c >= 0x400 && c <= 0x40F) {
        return c + 80;
    }
    if (c >= 0x460 && c <= 0x4FF && c != 0x482 && !(c >= 0x483 && c <= 0x489) && c != 0x4C0) {
        if (c >= 0x4C1 && c <= 0x4CE) {
            return (c & 1) ? c + 1 : c;
        }
        return (c & 1) ? c : c + 1;
    }
    if (c >= 0x531 && c <= 0x556) {
        return c + 48;
    }
    if (c >= 0xFF21 && c <= 0xFF3A) {
        return c + 32;
    }
    return c;
}

wint_t towupper(wint_t c) {
    if (c < 0x80) {
        return c >= 'a' && c <= 'z' ? c - 32 : c;
    }
    if (c >= 0xE0 && c <= 0xFE && c != 0xF7) {
        return c - 32;
    }
    if (c == 0xFF) {
        return 0x178;
    }
    if (c == 0xB5) {
        return 0x39C;
    }
    if (c >= 0x100 && c <= 0x17F) {
        if (c == 0x131) {
            return 'I';
        }
        if (c == 0x17F) {
            return 'S';
        }
        if ((c >= 0x139 && c <= 0x148) || (c >= 0x179 && c <= 0x17E)) {
            return (c & 1) ? c : c - 1;
        }
        if (c == 0x130 || c == 0x138 || c == 0x149) {
            return c;
        }
        return (c & 1) ? c - 1 : c;
    }
    if (c >= 0x3B1 && c <= 0x3CB && c != 0x3C2) {
        return c - 32;
    }
    if (c == 0x3C2) {
        return 0x3A3;
    }
    switch (c) {
        case 0x3AC: return 0x386;
        case 0x3AD: return 0x388;
        case 0x3AE: return 0x389;
        case 0x3AF: return 0x38A;
        case 0x3CC: return 0x38C;
        case 0x3CD: return 0x38E;
        case 0x3CE: return 0x38F;
    }
    if (c >= 0x430 && c <= 0x44F) {
        return c - 32;
    }
    if (c >= 0x450 && c <= 0x45F) {
        return c - 80;
    }
    if (c >= 0x460 && c <= 0x4FF && c != 0x482 && !(c >= 0x483 && c <= 0x489) && c != 0x4CF) {
        if (c >= 0x4C1 && c <= 0x4CE) {
            return (c & 1) ? c : c - 1;
        }
        return (c & 1) ? c - 1 : c;
    }
    if (c >= 0x561 && c <= 0x586) {
        return c - 48;
    }
    if (c >= 0xFF41 && c <= 0xFF5A) {
        return c - 32;
    }
    return c;
}

static int is_upper_beyond(uint32_t c) {
    return towlower(c) != c;
}

static int is_lower_beyond(uint32_t c) {
    return towupper(c) != c || c == 0xDF;
}

static const struct {
    const char *name;
    int (*test)(wint_t);
} classes[] = {
    {"alnum", iswalnum}, {"alpha", iswalpha}, {"blank", iswblank}, {"cntrl", iswcntrl},
    {"digit", iswdigit}, {"graph", iswgraph}, {"lower", iswlower}, {"print", iswprint},
    {"punct", iswpunct}, {"space", iswspace}, {"upper", iswupper}, {"xdigit", iswxdigit},
};

wctype_t wctype(const char *name) {
    for (size_t i = 0; i < COUNT(classes); i++) {
        if (strcmp(name, classes[i].name) == 0) {
            return i + 1;
        }
    }
    return 0;
}

int iswctype(wint_t c, wctype_t type) {
    return type >= 1 && type <= COUNT(classes) ? classes[type - 1].test(c) != 0 : 0;
}

static const int trans_lower = 1, trans_upper = 2;

wctrans_t wctrans(const char *name) {
    if (strcmp(name, "tolower") == 0) {
        return &trans_lower;
    }
    if (strcmp(name, "toupper") == 0) {
        return &trans_upper;
    }
    return NULL;
}

wint_t towctrans(wint_t c, wctrans_t trans) {
    if (trans == &trans_lower) {
        return towlower(c);
    }
    if (trans == &trans_upper) {
        return towupper(c);
    }
    return c;
}

/* locale_t: only the C locale, so the plain functions */
int iswalnum_l(wint_t c, locale_t loc) { (void)loc; return iswalnum(c); }
int iswalpha_l(wint_t c, locale_t loc) { (void)loc; return iswalpha(c); }
int iswblank_l(wint_t c, locale_t loc) { (void)loc; return iswblank(c); }
int iswcntrl_l(wint_t c, locale_t loc) { (void)loc; return iswcntrl(c); }
int iswdigit_l(wint_t c, locale_t loc) { (void)loc; return iswdigit(c); }
int iswgraph_l(wint_t c, locale_t loc) { (void)loc; return iswgraph(c); }
int iswlower_l(wint_t c, locale_t loc) { (void)loc; return iswlower(c); }
int iswprint_l(wint_t c, locale_t loc) { (void)loc; return iswprint(c); }
int iswpunct_l(wint_t c, locale_t loc) { (void)loc; return iswpunct(c); }
int iswspace_l(wint_t c, locale_t loc) { (void)loc; return iswspace(c); }
int iswupper_l(wint_t c, locale_t loc) { (void)loc; return iswupper(c); }
int iswxdigit_l(wint_t c, locale_t loc) { (void)loc; return iswxdigit(c); }
wint_t towlower_l(wint_t c, locale_t loc) { (void)loc; return towlower(c); }
wint_t towupper_l(wint_t c, locale_t loc) { (void)loc; return towupper(c); }
wctype_t wctype_l(const char *name, locale_t loc) { (void)loc; return wctype(name); }
int iswctype_l(wint_t c, wctype_t type, locale_t loc) { (void)loc; return iswctype(c, type); }
size_t wcsxfrm_l(wchar_t *dest, const wchar_t *src, size_t n, locale_t loc) { (void)loc; return wcsxfrm(dest, src, n); }

/* WIDTH ON A TERMINAL */

static const range zero_width[] = {
    {0x0300, 0x036F}, {0x0483, 0x0489}, {0x0591, 0x05BD}, {0x05BF, 0x05BF}, {0x05C1, 0x05C2},
    {0x05C4, 0x05C5}, {0x05C7, 0x05C7}, {0x0610, 0x061A}, {0x064B, 0x065F}, {0x0670, 0x0670},
    {0x06D6, 0x06DC}, {0x06DF, 0x06E4}, {0x06E7, 0x06E8}, {0x06EA, 0x06ED}, {0x0900, 0x0902},
    {0x093A, 0x093A}, {0x093C, 0x093C}, {0x0941, 0x0948}, {0x094D, 0x094D}, {0x0951, 0x0957},
    {0x0E31, 0x0E31}, {0x0E34, 0x0E3A}, {0x0E47, 0x0E4E}, {0x1160, 0x11FF}, {0x200B, 0x200F},
    {0x202A, 0x202E}, {0x2060, 0x2064}, {0x20D0, 0x20F0}, {0xFE00, 0xFE0F}, {0xFE20, 0xFE2F},
    {0xFEFF, 0xFEFF}, {0x1F3FB, 0x1F3FF}, {0xE0001, 0xE007F}, {0xE0100, 0xE01EF},
};

static const range double_width[] = {
    {0x1100, 0x115F}, {0x231A, 0x231B}, {0x2329, 0x232A}, {0x23E9, 0x23EC}, {0x23F0, 0x23F0},
    {0x23F3, 0x23F3}, {0x25FD, 0x25FE}, {0x2614, 0x2615}, {0x2648, 0x2653}, {0x267F, 0x267F},
    {0x2693, 0x2693}, {0x26A1, 0x26A1}, {0x26AA, 0x26AB}, {0x26BD, 0x26BE}, {0x26C4, 0x26C5},
    {0x26CE, 0x26CE}, {0x26D4, 0x26D4}, {0x26EA, 0x26EA}, {0x26F2, 0x26F3}, {0x26F5, 0x26F5},
    {0x26FA, 0x26FA}, {0x26FD, 0x26FD}, {0x2705, 0x2705}, {0x270A, 0x270B}, {0x2728, 0x2728},
    {0x274C, 0x274C}, {0x274E, 0x274E}, {0x2753, 0x2755}, {0x2757, 0x2757}, {0x2795, 0x2797},
    {0x27B0, 0x27B0}, {0x27BF, 0x27BF}, {0x2B1B, 0x2B1C}, {0x2B50, 0x2B50}, {0x2B55, 0x2B55},
    {0x2E80, 0x303E}, {0x3041, 0x33FF}, {0x3400, 0x4DBF}, {0x4E00, 0x9FFF}, {0xA000, 0xA4CF},
    {0xA960, 0xA97F}, {0xAC00, 0xD7A3}, {0xF900, 0xFAFF}, {0xFE10, 0xFE19}, {0xFE30, 0xFE6F},
    {0xFF00, 0xFF60}, {0xFFE0, 0xFFE6}, {0x16FE0, 0x16FE4}, {0x17000, 0x18CFF}, {0x1B000, 0x1B2FF},
    {0x1F004, 0x1F004}, {0x1F0CF, 0x1F0CF}, {0x1F18E, 0x1F18E}, {0x1F191, 0x1F19A}, {0x1F200, 0x1F251},
    {0x1F300, 0x1F320}, {0x1F32D, 0x1F335}, {0x1F337, 0x1F37C}, {0x1F37E, 0x1F393}, {0x1F3A0, 0x1F3CA},
    {0x1F3CF, 0x1F3D3}, {0x1F3E0, 0x1F3F0}, {0x1F3F4, 0x1F3F4}, {0x1F3F8, 0x1F43E}, {0x1F440, 0x1F440},
    {0x1F442, 0x1F4FC}, {0x1F4FF, 0x1F53D}, {0x1F54B, 0x1F54E}, {0x1F550, 0x1F567}, {0x1F57A, 0x1F57A},
    {0x1F595, 0x1F596}, {0x1F5A4, 0x1F5A4}, {0x1F5FB, 0x1F64F}, {0x1F680, 0x1F6C5}, {0x1F6CC, 0x1F6CC},
    {0x1F6D0, 0x1F6D2}, {0x1F6D5, 0x1F6D7}, {0x1F6EB, 0x1F6EC}, {0x1F6F4, 0x1F6FC}, {0x1F7E0, 0x1F7EB},
    {0x1F90C, 0x1F93A}, {0x1F93C, 0x1F945}, {0x1F947, 0x1F9FF}, {0x1FA70, 0x1FAFF}, {0x20000, 0x2FFFD},
    {0x30000, 0x3FFFD},
};

int wcwidth(wchar_t wc) {
    uint32_t c = (uint32_t)wc;
    if (c == 0) {
        return 0;
    }
    if (c < 0x20 || (c >= 0x7F && c < 0xA0)) {
        return -1;
    }
    if (c < 0x300) {
        return 1;
    }
    if (in(c, zero_width, COUNT(zero_width))) {
        return 0;
    }
    return in(c, double_width, COUNT(double_width)) ? 2 : 1;
}

int wcswidth(const wchar_t *s, size_t n) {
    int total = 0;
    for (size_t i = 0; i < n && s[i] != 0; i++) {
        int w = wcwidth(s[i]);
        if (w < 0) {
            return -1;
        }
        total += w;
    }
    return total;
}

/* STREAMS */

wint_t fgetwc(FILE *f) {
    flockfile(f);
    wint_t c = fgetwc_unlocked(f);
    funlockfile(f);
    return c;
}

wint_t fgetwc_unlocked(FILE *f) {
    mbstate_t st = {0};
    for (;;) {
        int b = fgetc_unlocked(f);
        if (b == EOF) {
            if (!mbsinit(&st)) {
                errno = EILSEQ;
            }
            return WEOF;
        }
        char ch = (char)b;
        wchar_t c;
        size_t r = mbrtowc(&c, &ch, 1, &st);
        if (r == (size_t)-1) {
            return WEOF;
        }
        if (r != (size_t)-2) {
            return (wint_t)c;
        }
    }
}

wint_t getwc(FILE *f) {
    return fgetwc(f);
}

wint_t getwchar(void) {
    return fgetwc(stdin);
}

wint_t fputwc(wchar_t c, FILE *f) {
    char buf[4];
    size_t n = wcrtomb(buf, c, NULL);
    if (n == (size_t)-1 || fwrite(buf, 1, n, f) != n) {
        return WEOF;
    }
    return (wint_t)c;
}

wint_t putwc(wchar_t c, FILE *f) {
    return fputwc(c, f);
}

wint_t putwchar(wchar_t c) {
    return fputwc(c, stdout);
}

/* Only ASCII goes back (the stream keeps one byte) */
wint_t ungetwc(wint_t c, FILE *f) {
    if (c == WEOF || c >= 0x80) {
        return WEOF;
    }
    return ungetc((int)c, f) == EOF ? WEOF : c;
}

wchar_t *fgetws(wchar_t *s, int n, FILE *f) {
    int i = 0;
    flockfile(f);
    while (i < n - 1) {
        wint_t c = fgetwc_unlocked(f);
        if (c == WEOF) {
            break;
        }
        s[i++] = (wchar_t)c;
        if (c == '\n') {
            break;
        }
    }
    funlockfile(f);
    if (i == 0 || n <= 0) {
        return NULL;
    }
    s[i] = 0;
    return s;
}

int fputws(const wchar_t *s, FILE *f) {
    int result = 0;
    flockfile(f);
    for (; *s != 0; s++) {
        if (fputwc(*s, f) == WEOF) {
            result = -1;
            break;
        }
    }
    funlockfile(f);
    return result;
}

int fwide(FILE *f, int mode) {
    (void)f;
    return mode; /* no orientation: both kinds of calls work on a stream */
}

/* FORMATTING: THE FORMAT AND THE TEXT THROUGH UTF-8 */

#define WFMT_MAX 4096

static char *narrow_text(const wchar_t *w) {
    const wchar_t *src = w;
    size_t n = wcsrtombs(NULL, &src, 0, NULL);
    if (n == (size_t)-1) {
        return NULL;
    }
    char *s = malloc(n + 1);
    if (s != NULL) {
        src = w;
        wcsrtombs(s, &src, n + 1, NULL);
    }
    return s;
}

/* The text as formatted, into a buffer of WFMT_MAX bytes; its length or -1 */
static int format_narrow(char *buf, const wchar_t *format, va_list ap) {
    char *f = narrow_text(format);
    if (f == NULL) {
        errno = EILSEQ;
        return -1;
    }
    int n = vsnprintf(buf, WFMT_MAX, f, ap);
    free(f);
    return n;
}

int vswprintf(wchar_t *out, size_t n, const wchar_t *format, va_list ap) {
    char *buf = malloc(WFMT_MAX);
    if (buf == NULL) {
        return -1;
    }
    int len = format_narrow(buf, format, ap);
    int result = -1;
    if (len >= 0) {
        size_t count = mbstowcs(out, buf, n);
        if (count != (size_t)-1 && count < n) {
            out[count] = 0;
            result = (int)count;
        } else if (n > 0) {
            out[n - 1] = 0;
        }
    }
    free(buf);
    return result;
}

int swprintf(wchar_t *out, size_t n, const wchar_t *format, ...) {
    va_list ap;
    va_start(ap, format);
    int r = vswprintf(out, n, format, ap);
    va_end(ap);
    return r;
}

int vfwprintf(FILE *f, const wchar_t *format, va_list ap) {
    char *buf = malloc(WFMT_MAX);
    if (buf == NULL) {
        return -1;
    }
    int len = format_narrow(buf, format, ap);
    int result = -1;
    if (len >= 0) {
        size_t bytes = strlen(buf);
        if (fwrite(buf, 1, bytes, f) == bytes) {
            const char *p = buf;
            result = (int)mbsrtowcs(NULL, &p, 0, NULL);
        }
    }
    free(buf);
    return result;
}

int fwprintf(FILE *f, const wchar_t *format, ...) {
    va_list ap;
    va_start(ap, format);
    int r = vfwprintf(f, format, ap);
    va_end(ap);
    return r;
}

int vwprintf(const wchar_t *format, va_list ap) {
    return vfwprintf(stdout, format, ap);
}

int wprintf(const wchar_t *format, ...) {
    va_list ap;
    va_start(ap, format);
    int r = vfwprintf(stdout, format, ap);
    va_end(ap);
    return r;
}

size_t wcsftime(wchar_t *out, size_t n, const wchar_t *format, const struct tm *tm) {
    char *f = narrow_text(format);
    char buf[512];
    if (f == NULL) {
        return 0;
    }
    size_t len = strftime(buf, sizeof(buf), f, tm);
    free(f);
    if (len == 0) {
        return 0;
    }
    size_t count = mbstowcs(out, buf, n);
    return count == (size_t)-1 || count >= n ? 0 : count;
}
