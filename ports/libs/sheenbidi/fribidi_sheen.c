/* FriBidi's functions on SheenBidi, compiled in one unit with it
 * as SB_CONFIG_UNITY lets. FriBidi's own steps around SheenBidi's
 * levels follow FriBidi; there is no Arabic joining data. */
#include "SheenBidi.c"

#include <stdlib.h>
#include <string.h>
#include "fribidi.h"

#define SHEEN_TO_FRIBIDI_TYPES                                                                  \
    X(L, LTR, 0x61) X(R, RTL, 0x5D0) X(AL, AL, 0x627) X(BN, BN, 0x200B) X(NSM, NSM, 0x300)     \
    X(AN, AN, 0x660) X(EN, EN, 0x30) X(ET, ET, 0x23) X(ES, ES, 0x2B) X(CS, CS, 0x2C)          \
    X(WS, WS, 0x20) X(S, SS, 0x09) X(B, BS, 0x2029) X(ON, ON, 0x21) X(LRI, LRI, 0x2066)       \
    X(RLI, RLI, 0x2067) X(FSI, FSI, 0x2068) X(PDI, PDI, 0x2069) X(LRE, LRE, 0x202A)            \
    X(RLE, RLE, 0x202B) X(LRO, LRO, 0x202D) X(RLO, RLO, 0x202E) X(PDF, PDF, 0x202C)

/* TYPES */

FriBidiCharType fribidi_get_bidi_type(FriBidiChar ch) {
    switch (SBCodepointGetBidiType(ch)) {
#define X(sb, fb, cp) case SBBidiType##sb: return FRIBIDI_TYPE_##fb;
        SHEEN_TO_FRIBIDI_TYPES
#undef X
    default: return FRIBIDI_TYPE_LTR;
    }
}

/* A character of that type, for SheenBidi, which reads text */
static SBCodepoint stand_in(FriBidiCharType t) {
    switch (t) {
#define X(sb, fb, cp) case FRIBIDI_TYPE_##fb: return cp;
        SHEEN_TO_FRIBIDI_TYPES
#undef X
    default: return 0x21;
    }
}

void fribidi_get_bidi_types(const FriBidiChar *str, const FriBidiStrIndex len, FriBidiCharType *btypes) {
    for (FriBidiStrIndex i = 0; i < len; i++) btypes[i] = fribidi_get_bidi_type(str[i]);
}

FriBidiCharType fribidi_get_type(FriBidiChar ch) {
    return fribidi_get_bidi_type(ch);
}

FriBidiCharType fribidi_get_type_internal(FriBidiChar ch) {
    return fribidi_get_bidi_type(ch);
}

const char *fribidi_get_bidi_type_name(FriBidiCharType t) {
    switch (t) {
#define X(sb, fb, cp) case FRIBIDI_TYPE_##fb: return #fb;
        SHEEN_TO_FRIBIDI_TYPES
#undef X
    case FRIBIDI_TYPE_WLTR: return "WLTR";
    case FRIBIDI_TYPE_WRTL: return "WRTL";
    default: return "?";
    }
}

/* BRACKETS */

/* An opening bracket's id as FriBidi has it: its decomposition, so
 * 〈 pairs with 〉 and the fullwidth ones with the plain ones */
static FriBidiChar canonical(FriBidiChar ch) {
    switch (ch) {
    case 0x2329: return 0x3008;
    case 0x207D: case 0x208D: case 0xFE59: case 0xFF08: return 0x28;
    case 0xFF3B: return 0x5B;
    case 0xFE5B: case 0xFF5B: return 0x7B;
    case 0xFE5D: return 0x3014;
    case 0xFF5F: return 0x2985;
    case 0xFF62: return 0x300C;
    default: return ch;
    }
}

FriBidiBracketType fribidi_get_bracket(FriBidiChar ch) {
    BracketType kind = BracketTypeNone;
    SBCodepoint pair = LookupBracketPair(ch, &kind);
    if (pair == 0 || (kind & BracketTypePrimaryMask) == BracketTypeNone) return FRIBIDI_NO_BRACKET;
    if (kind & BracketTypeOpen) return (canonical(ch) & FRIBIDI_BRACKET_ID_MASK) | FRIBIDI_BRACKET_OPEN_MASK;
    return canonical(pair) & FRIBIDI_BRACKET_ID_MASK;
}

void fribidi_get_bracket_types(const FriBidiChar *str, const FriBidiStrIndex len, const FriBidiCharType *types,
                               FriBidiBracketType *btypes) {
    for (FriBidiStrIndex i = 0; i < len; i++) {
        btypes[i] = types[i] == FRIBIDI_TYPE_ON ? fribidi_get_bracket(str[i]) : FRIBIDI_NO_BRACKET;
    }
}

/* LEVELS */

/* P2, P3 as FriBidi: the first letter outside isolates */
static FriBidiParType first_strong(const FriBidiCharType *types, FriBidiStrIndex len) {
    int isolates = 0;
    for (FriBidiStrIndex i = 0; i < len; i++) {
        if (types[i] == FRIBIDI_TYPE_PDI) {
            if (isolates > 0) isolates--;
        } else if (FRIBIDI_IS_ISOLATE(types[i])) {
            isolates++;
        } else if (isolates == 0 && FRIBIDI_IS_LETTER(types[i])) {
            return FRIBIDI_LEVEL_TO_DIR(FRIBIDI_DIR_TO_LEVEL(types[i]));
        }
    }
    return FRIBIDI_PAR_ON;
}

/* As first_strong, but a paragraph separator ends the isolates */
FriBidiParType fribidi_get_par_direction(const FriBidiCharType *bidi_types, const FriBidiStrIndex len) {
    int isolates = 0;
    for (FriBidiStrIndex i = 0; i < len; i++) {
        if (bidi_types[i] == FRIBIDI_TYPE_PDI) {
            if (isolates > 0) isolates--;
        } else if (FRIBIDI_IS_ISOLATE(bidi_types[i])) {
            isolates++;
        } else if (bidi_types[i] == FRIBIDI_TYPE_BS) {
            isolates = 0;
        } else if (isolates == 0 && FRIBIDI_IS_LETTER(bidi_types[i])) {
            return FRIBIDI_IS_RTL(bidi_types[i]) ? FRIBIDI_PAR_RTL : FRIBIDI_PAR_LTR;
        }
    }
    return FRIBIDI_PAR_ON;
}

static int removed_by_x9(FriBidiCharType t) {
    return t == FRIBIDI_TYPE_BN || (FRIBIDI_IS_EXPLICIT(t) && !FRIBIDI_IS_ISOLATE(t));
}

FriBidiLevel fribidi_get_par_embedding_levels_ex(const FriBidiCharType *bidi_types,
                                                 const FriBidiBracketType *bracket_types, const FriBidiStrIndex len,
                                                 FriBidiParType *pbase_dir, FriBidiLevel *embedding_levels) {
    if (len <= 0) return 1;
    FriBidiLevel base = FRIBIDI_DIR_TO_LEVEL(*pbase_dir);
    if (!FRIBIDI_IS_STRONG(*pbase_dir)) {
        FriBidiParType found = first_strong(bidi_types, len);
        if (found != FRIBIDI_PAR_ON) {
            base = FRIBIDI_DIR_TO_LEVEL(found);
            *pbase_dir = found;
        }
    }

    // The text SheenBidi reads: a character of each type; brackets as
    // their pairs, closing ones by the opening one's mirror:
    SBCodepoint *text = malloc((size_t)len * sizeof *text);
    if (text == NULL) return 0;
    for (FriBidiStrIndex i = 0; i < len; i++) {
        FriBidiBracketType b = bracket_types ? bracket_types[i] : FRIBIDI_NO_BRACKET;
        if (b != FRIBIDI_NO_BRACKET && bidi_types[i] == FRIBIDI_TYPE_ON) {
            SBCodepoint open = FRIBIDI_BRACKET_ID(b);
            text[i] = FRIBIDI_IS_BRACKET_OPEN(b) ? open : SBCodepointGetMirror(open);
        } else {
            text[i] = stand_in(bidi_types[i]);
        }
    }

    // Its levels, a paragraph at a time, all at FriBidi's base level:
    SBCodepointSequence seq = {SBStringEncodingUTF32, text, (SBUInteger)len};
    SBAlgorithmRef algorithm = SBAlgorithmCreate(&seq);
    int ok = algorithm != NULL;
    FriBidiLevel max = base;
    SBUInteger at = 0;
    while (ok && at < (SBUInteger)len) {
        SBParagraphRef par = SBAlgorithmCreateParagraph(algorithm, at, (SBUInteger)len - at, (SBLevel)base);
        if (par == NULL) {
            ok = 0;
            break;
        }
        SBUInteger n = SBParagraphGetLength(par);
        const SBLevel *levels = SBParagraphGetLevelsPtr(par);
        for (SBUInteger i = 0; i < n; i++) {
            embedding_levels[at + i] = (FriBidiLevel)levels[i];
            if (!removed_by_x9(bidi_types[at + i]) && embedding_levels[at + i] > max) max = embedding_levels[at + i];
        }
        SBParagraphRelease(par);
        at += n;
        if (n == 0) ok = 0;
    }
    if (algorithm) SBAlgorithmRelease(algorithm);
    free(text);
    if (!ok) return 0;

    // What X9 removed takes the level before it, as FriBidi puts it back:
    for (FriBidiStrIndex i = 0; i < len; i++) {
        if (removed_by_x9(bidi_types[i])) embedding_levels[i] = i > 0 ? embedding_levels[i - 1] : base;
    }

    // L1, parts 1 to 3, and white space and isolates at the end:
    int resetting = 1;
    for (FriBidiStrIndex i = len - 1; i >= 0; i--) {
        FriBidiCharType t = bidi_types[i];
        if (FRIBIDI_IS_SEPARATOR(t)) {
            resetting = 1;
        } else if (resetting && !(removed_by_x9(t) || t == FRIBIDI_TYPE_WS || FRIBIDI_IS_ISOLATE(t))) {
            resetting = 0;
        }
        if (resetting) embedding_levels[i] = base;
    }
    return (FriBidiLevel)(max + 1);
}

FriBidiLevel fribidi_get_par_embedding_levels(const FriBidiCharType *bidi_types, const FriBidiStrIndex len,
                                              FriBidiParType *pbase_dir, FriBidiLevel *embedding_levels) {
    return fribidi_get_par_embedding_levels_ex(bidi_types, NULL, len, pbase_dir, embedding_levels);
}

FriBidiLevel fribidi_log2vis_get_embedding_levels(const FriBidiCharType *bidi_types, const FriBidiStrIndex len,
                                                  FriBidiParType *pbase_dir, FriBidiLevel *embedding_levels) {
    return fribidi_get_par_embedding_levels(bidi_types, len, pbase_dir, embedding_levels);
}

/* REORDERING */

static void reverse_chars(FriBidiChar *s, FriBidiStrIndex n) {
    for (FriBidiStrIndex i = 0; i < n / 2; i++) {
        FriBidiChar t = s[i];
        s[i] = s[n - 1 - i];
        s[n - 1 - i] = t;
    }
}

static void reverse_indexes(FriBidiStrIndex *s, FriBidiStrIndex n) {
    for (FriBidiStrIndex i = 0; i < n / 2; i++) {
        FriBidiStrIndex t = s[i];
        s[i] = s[n - 1 - i];
        s[n - 1 - i] = t;
    }
}

static int x9_or_ws(FriBidiCharType t) {
    return removed_by_x9(t) || t == FRIBIDI_TYPE_WS;
}

FriBidiLevel fribidi_reorder_line(FriBidiFlags flags, const FriBidiCharType *bidi_types, const FriBidiStrIndex len,
                                  const FriBidiStrIndex off, const FriBidiParType base_dir,
                                  FriBidiLevel *embedding_levels, FriBidiChar *visual_str, FriBidiStrIndex *map) {
    if (len <= 0) return 1;
    FriBidiStrIndex end = off + len;

    // L1, part 4: white space at the end of the line:
    for (FriBidiStrIndex i = end - 1; i >= off && x9_or_ws(bidi_types[i]); i--) {
        embedding_levels[i] = FRIBIDI_DIR_TO_LEVEL(base_dir);
    }

    // L3: marks of a right-to-left run stay after their base:
    if (flags & FRIBIDI_FLAG_REORDER_NSM) {
        for (FriBidiStrIndex i = end - 1; i >= off; i--) {
            if (!FRIBIDI_LEVEL_IS_RTL(embedding_levels[i]) || bidi_types[i] != FRIBIDI_TYPE_NSM) continue;
            FriBidiStrIndex last = i;
            FriBidiLevel level = embedding_levels[i];
            for (i--; i >= off && embedding_levels[i] == level &&
                      (removed_by_x9(bidi_types[i]) || bidi_types[i] == FRIBIDI_TYPE_NSM);
                 i--)
                ;
            if (i < off || embedding_levels[i] != level) i++;
            if (visual_str) reverse_chars(visual_str + i, last - i + 1);
            if (map) reverse_indexes(map + i, last - i + 1);
        }
    }

    // L2: from the highest level down, every run at least that high reversed:
    FriBidiLevel max = 0;
    for (FriBidiStrIndex i = off; i < end; i++) {
        if (embedding_levels[i] > max) max = embedding_levels[i];
    }
    for (FriBidiLevel level = max; level > 0; level--) {
        for (FriBidiStrIndex i = off; i < end; i++) {
            if (embedding_levels[i] < level) continue;
            FriBidiStrIndex start = i;
            while (i < end && embedding_levels[i] >= level) i++;
            if (visual_str) reverse_chars(visual_str + start, i - start);
            if (map) reverse_indexes(map + start, i - start);
        }
    }
    return (FriBidiLevel)(max + 1);
}

/* MIRRORING, JOINING, SHAPING */

fribidi_boolean fribidi_get_mirror_char(FriBidiChar ch, FriBidiChar *mirrored_ch) {
    SBCodepoint m = SBCodepointGetMirror(ch);
    if (mirrored_ch) *mirrored_ch = m ? m : ch;
    return m != 0;
}

void fribidi_shape_mirroring(const FriBidiLevel *embedding_levels, const FriBidiStrIndex len, FriBidiChar *str) {
    for (FriBidiStrIndex i = 0; i < len; i++) {
        if (FRIBIDI_LEVEL_IS_RTL(embedding_levels[i])) fribidi_get_mirror_char(str[i], &str[i]);
    }
}

FriBidiJoiningType fribidi_get_joining_type(FriBidiChar ch) {
    (void)ch;
    return FRIBIDI_JOINING_TYPE_U;
}

void fribidi_get_joining_types(const FriBidiChar *str, const FriBidiStrIndex len, FriBidiJoiningType *jtypes) {
    (void)str;
    memset(jtypes, FRIBIDI_JOINING_TYPE_U, (size_t)(len > 0 ? len : 0));
}

const char *fribidi_get_joining_type_name(FriBidiJoiningType j) {
    return j == FRIBIDI_JOINING_TYPE_U ? "U" : "?";
}

void fribidi_join_arabic(const FriBidiCharType *bidi_types, const FriBidiStrIndex len,
                         const FriBidiLevel *embedding_levels, FriBidiArabicProp *ar_props) {
    (void)bidi_types;
    (void)embedding_levels;
    (void)ar_props;
    (void)len;
}

void fribidi_shape_arabic(FriBidiFlags flags, const FriBidiLevel *embedding_levels, const FriBidiStrIndex len,
                          FriBidiArabicProp *ar_props, FriBidiChar *str) {
    (void)flags;
    (void)embedding_levels;
    (void)len;
    (void)ar_props;
    (void)str;
}

void fribidi_shape(FriBidiFlags flags, const FriBidiLevel *embedding_levels, const FriBidiStrIndex len,
                   FriBidiArabicProp *ar_props, FriBidiChar *str) {
    if (str == NULL || embedding_levels == NULL) return;
    if (flags & FRIBIDI_FLAG_SHAPE_MIRRORING) fribidi_shape_mirroring(embedding_levels, len, str);
    fribidi_shape_arabic(flags, embedding_levels, len, ar_props, str);
}

/* WHOLE PARAGRAPHS */

FriBidiStrIndex fribidi_remove_bidi_marks(FriBidiChar *str, const FriBidiStrIndex len,
                                          FriBidiStrIndex *positions_to_this, FriBidiStrIndex *position_from_this_list,
                                          FriBidiLevel *embedding_levels) {
    if (len <= 0 || str == NULL) return 0;
    FriBidiStrIndex j = 0;
    int private_to_this = 0;
    if (positions_to_this && !position_from_this_list) {
        position_from_this_list = malloc((size_t)len * sizeof *position_from_this_list);
        if (position_from_this_list == NULL) return -1;
        private_to_this = 1;
        for (FriBidiStrIndex i = 0; i < len; i++) position_from_this_list[positions_to_this[i]] = i;
    }
    for (FriBidiStrIndex i = 0; i < len; i++) {
        FriBidiCharType t = fribidi_get_bidi_type(str[i]);
        int mark = removed_by_x9(t) || FRIBIDI_IS_ISOLATE(t) || str[i] == 0x200E || str[i] == 0x200F ||
                   str[i] == 0x061C;
        if (mark) continue;
        str[j] = str[i];
        if (embedding_levels) embedding_levels[j] = embedding_levels[i];
        if (position_from_this_list) position_from_this_list[j] = position_from_this_list[i];
        j++;
    }
    if (positions_to_this) {
        for (FriBidiStrIndex i = 0; i < len; i++) positions_to_this[i] = -1;
        for (FriBidiStrIndex i = 0; i < j; i++) positions_to_this[position_from_this_list[i]] = i;
    }
    if (private_to_this) free(position_from_this_list);
    return j;
}

FriBidiLevel fribidi_log2vis(const FriBidiChar *str, const FriBidiStrIndex len, FriBidiParType *pbase_dir,
                             FriBidiChar *visual_str, FriBidiStrIndex *positions_L_to_V,
                             FriBidiStrIndex *positions_V_to_L, FriBidiLevel *embedding_levels) {
    if (len <= 0) return 1;
    FriBidiCharType *types = malloc((size_t)len * sizeof *types);
    FriBidiBracketType *brackets = malloc((size_t)len * sizeof *brackets);
    FriBidiLevel *levels = embedding_levels ? embedding_levels : malloc((size_t)len * sizeof *levels);
    FriBidiStrIndex *map = positions_V_to_L ? positions_V_to_L : malloc((size_t)len * sizeof *map);
    FriBidiLevel result = 0;
    if (types && brackets && levels && map) {
        fribidi_get_bidi_types(str, len, types);
        fribidi_get_bracket_types(str, len, types, brackets);
        result = fribidi_get_par_embedding_levels_ex(types, brackets, len, pbase_dir, levels);
        if (result) {
            for (FriBidiStrIndex i = 0; i < len; i++) map[i] = i;
            if (visual_str) {
                memcpy(visual_str, str, (size_t)len * sizeof *str);
                fribidi_shape(FRIBIDI_FLAGS_DEFAULT | FRIBIDI_FLAGS_ARABIC, levels, len, NULL, visual_str);
            }
            result = fribidi_reorder_line(FRIBIDI_FLAGS_DEFAULT, types, len, 0, *pbase_dir, levels, visual_str, map);
            if (positions_L_to_V) {
                for (FriBidiStrIndex i = 0; i < len; i++) positions_L_to_V[map[i]] = i;
            }
        }
    }
    free(types);
    free(brackets);
    if (levels != embedding_levels) free(levels);
    if (map != positions_V_to_L) free(map);
    return result;
}

/* SETTINGS AND CHARACTER SETS */

static fribidi_boolean mirroring = 1, reorder_nsm = 0;

fribidi_boolean fribidi_mirroring_status(void) {
    return mirroring;
}

fribidi_boolean fribidi_set_mirroring(fribidi_boolean state) {
    return mirroring = state;
}

fribidi_boolean fribidi_reorder_nsm_status(void) {
    return reorder_nsm;
}

fribidi_boolean fribidi_set_reorder_nsm(fribidi_boolean state) {
    return reorder_nsm = state;
}

int fribidi_debug_status(void) {
    return 0;
}

int fribidi_set_debug(int state) {
    (void)state;
    return 0;
}

FriBidiCharSet fribidi_parse_charset(const char *s) {
    return s && (strcmp(s, "UTF-8") == 0 || strcmp(s, "utf-8") == 0 || strcmp(s, "UTF8") == 0)
               ? FRIBIDI_CHAR_SET_UTF8
               : FRIBIDI_CHAR_SET_NOT_FOUND;
}

FriBidiStrIndex fribidi_charset_to_unicode(FriBidiCharSet char_set, const char *s, FriBidiStrIndex len,
                                           FriBidiChar *us) {
    if (char_set != FRIBIDI_CHAR_SET_UTF8) return 0;
    FriBidiStrIndex n = 0;
    SBUInteger at = 0;
    while (at < (SBUInteger)len) {
        us[n++] = SBCodepointDecodeNextFromUTF8((const SBUInt8 *)s, (SBUInteger)len, &at);
    }
    return n;
}

FriBidiStrIndex fribidi_unicode_to_charset(FriBidiCharSet char_set, const FriBidiChar *us, FriBidiStrIndex len,
                                           char *s) {
    if (char_set != FRIBIDI_CHAR_SET_UTF8) return 0;
    FriBidiStrIndex n = 0;
    for (FriBidiStrIndex i = 0; i < len; i++) {
        FriBidiChar c = us[i];
        if (c < 0x80) {
            s[n++] = (char)c;
        } else if (c < 0x800) {
            s[n++] = (char)(0xC0 | c >> 6);
            s[n++] = (char)(0x80 | (c & 0x3F));
        } else if (c < 0x10000) {
            s[n++] = (char)(0xE0 | c >> 12);
            s[n++] = (char)(0x80 | (c >> 6 & 0x3F));
            s[n++] = (char)(0x80 | (c & 0x3F));
        } else {
            s[n++] = (char)(0xF0 | c >> 18);
            s[n++] = (char)(0x80 | (c >> 12 & 0x3F));
            s[n++] = (char)(0x80 | (c >> 6 & 0x3F));
            s[n++] = (char)(0x80 | (c & 0x3F));
        }
    }
    s[n] = 0;
    return n;
}
