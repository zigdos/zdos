/* FriBidi's interface (1.0.18) for SHNBIDI.ZDL, built on SheenBidi:
 * its types, values and functions, so programs built with FriBidi's
 * own headers call this library unchanged. */
#ifndef ZDOS_FRIBIDI_H
#define ZDOS_FRIBIDI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FRIBIDI_MAJOR_VERSION 1
#define FRIBIDI_MINOR_VERSION 0
#define FRIBIDI_MICRO_VERSION 18
#define FRIBIDI_VERSION "1.0.18"
#define FRIBIDI_INTERFACE_VERSION 4
#define FRIBIDI_UNICODE_VERSION "17.0.0" /* SheenBidi's data */

typedef int fribidi_boolean;
typedef uint32_t FriBidiChar;
typedef int FriBidiStrIndex;
typedef signed char FriBidiLevel;
typedef uint32_t FriBidiCharType;
typedef uint32_t FriBidiParType;
typedef FriBidiChar FriBidiBracketType;
typedef uint8_t FriBidiJoiningType;
typedef uint8_t FriBidiArabicProp;
typedef uint32_t FriBidiFlags;
typedef int FriBidiCharSet;

/* BIDI TYPES: masks, then the types made of them */

#define FRIBIDI_MASK_RTL 0x00000001U
#define FRIBIDI_MASK_ARABIC 0x00000002U
#define FRIBIDI_MASK_STRONG 0x00000010U
#define FRIBIDI_MASK_WEAK 0x00000020U
#define FRIBIDI_MASK_NEUTRAL 0x00000040U
#define FRIBIDI_MASK_SENTINEL 0x00000080U
#define FRIBIDI_MASK_LETTER 0x00000100U
#define FRIBIDI_MASK_NUMBER 0x00000200U
#define FRIBIDI_MASK_NUMSEPTER 0x00000400U
#define FRIBIDI_MASK_SPACE 0x00000800U
#define FRIBIDI_MASK_EXPLICIT 0x00001000U
#define FRIBIDI_MASK_SEPARATOR 0x00002000U
#define FRIBIDI_MASK_OVERRIDE 0x00004000U
#define FRIBIDI_MASK_ISOLATE 0x00008000U
#define FRIBIDI_MASK_ES 0x00010000U
#define FRIBIDI_MASK_ET 0x00020000U
#define FRIBIDI_MASK_CS 0x00040000U
#define FRIBIDI_MASK_NSM 0x00080000U
#define FRIBIDI_MASK_BN 0x00100000U
#define FRIBIDI_MASK_BS 0x00200000U
#define FRIBIDI_MASK_SS 0x00400000U
#define FRIBIDI_MASK_WS 0x00800000U
#define FRIBIDI_MASK_PRIVATE 0x01000000U
#define FRIBIDI_MASK_FIRST 0x02000000U

#define FRIBIDI_TYPE_LTR 0x00000110U
#define FRIBIDI_TYPE_RTL 0x00000111U
#define FRIBIDI_TYPE_AL 0x00000113U
#define FRIBIDI_TYPE_EN 0x00000220U
#define FRIBIDI_TYPE_AN 0x00000222U
#define FRIBIDI_TYPE_ES 0x00010420U
#define FRIBIDI_TYPE_ET 0x00020420U
#define FRIBIDI_TYPE_CS 0x00040420U
#define FRIBIDI_TYPE_NSM 0x00080020U
#define FRIBIDI_TYPE_BN 0x00100820U
#define FRIBIDI_TYPE_BS 0x00202840U
#define FRIBIDI_TYPE_SS 0x00402840U
#define FRIBIDI_TYPE_WS 0x00800840U
#define FRIBIDI_TYPE_ON 0x00000040U
#define FRIBIDI_TYPE_LRE 0x00001010U
#define FRIBIDI_TYPE_RLE 0x00001011U
#define FRIBIDI_TYPE_LRO 0x00005010U
#define FRIBIDI_TYPE_RLO 0x00005011U
#define FRIBIDI_TYPE_PDF 0x00001020U
#define FRIBIDI_TYPE_LRI 0x00008040U
#define FRIBIDI_TYPE_RLI 0x00008041U
#define FRIBIDI_TYPE_FSI 0x02008040U
#define FRIBIDI_TYPE_PDI 0x00008060U
#define FRIBIDI_TYPE_WLTR 0x00000020U
#define FRIBIDI_TYPE_WRTL 0x00000021U
#define FRIBIDI_TYPE_SENTINEL 0x00000080U
#define FRIBIDI_TYPE_L FRIBIDI_TYPE_LTR
#define FRIBIDI_TYPE_R FRIBIDI_TYPE_RTL
#define FRIBIDI_TYPE_B FRIBIDI_TYPE_BS
#define FRIBIDI_TYPE_S FRIBIDI_TYPE_SS

#define FRIBIDI_PAR_LTR FRIBIDI_TYPE_LTR
#define FRIBIDI_PAR_RTL FRIBIDI_TYPE_RTL
#define FRIBIDI_PAR_ON FRIBIDI_TYPE_ON
#define FRIBIDI_PAR_WLTR FRIBIDI_TYPE_WLTR
#define FRIBIDI_PAR_WRTL FRIBIDI_TYPE_WRTL

#define FRIBIDI_LEVEL_IS_RTL(lev) ((lev) & 1)
#define FRIBIDI_LEVEL_TO_DIR(lev) (FRIBIDI_LEVEL_IS_RTL(lev) ? FRIBIDI_TYPE_RTL : FRIBIDI_TYPE_LTR)
#define FRIBIDI_DIR_TO_LEVEL(dir) ((FriBidiLevel)((dir) & 1))
#define FRIBIDI_IS_RTL(p) ((p) & FRIBIDI_MASK_RTL)
#define FRIBIDI_IS_ARABIC(p) ((p) & FRIBIDI_MASK_ARABIC)
#define FRIBIDI_IS_STRONG(p) ((p) & FRIBIDI_MASK_STRONG)
#define FRIBIDI_IS_WEAK(p) ((p) & FRIBIDI_MASK_WEAK)
#define FRIBIDI_IS_NEUTRAL(p) ((p) & FRIBIDI_MASK_NEUTRAL)
#define FRIBIDI_IS_LETTER(p) ((p) & FRIBIDI_MASK_LETTER)
#define FRIBIDI_IS_NUMBER(p) ((p) & FRIBIDI_MASK_NUMBER)
#define FRIBIDI_IS_SPACE(p) ((p) & FRIBIDI_MASK_SPACE)
#define FRIBIDI_IS_EXPLICIT(p) ((p) & FRIBIDI_MASK_EXPLICIT)
#define FRIBIDI_IS_ISOLATE(p) ((p) & FRIBIDI_MASK_ISOLATE)
#define FRIBIDI_IS_SEPARATOR(p) ((p) & FRIBIDI_MASK_SEPARATOR)
#define FRIBIDI_IS_OVERRIDE(p) ((p) & FRIBIDI_MASK_OVERRIDE)

/* BRACKETS: the opening bracket's code point, with the open bit */

#define FRIBIDI_NO_BRACKET 0
#define FRIBIDI_BRACKET_OPEN_MASK 0x80000000U
#define FRIBIDI_BRACKET_ID_MASK 0x7FFFFFFFU
#define FRIBIDI_IS_BRACKET_OPEN(bt) (((bt) & FRIBIDI_BRACKET_OPEN_MASK) > 0)
#define FRIBIDI_BRACKET_ID(bt) ((bt) & FRIBIDI_BRACKET_ID_MASK)

/* JOINING (Arabic): no data here, every character is non-joining */

#define FRIBIDI_MASK_JOINS_RIGHT 0x01
#define FRIBIDI_MASK_JOINS_LEFT 0x02
#define FRIBIDI_MASK_ARAB_SHAPES 0x04
#define FRIBIDI_MASK_TRANSPARENT 0x08
#define FRIBIDI_MASK_IGNORED 0x10
#define FRIBIDI_MASK_LIGATURED 0x20
#define FRIBIDI_JOINING_TYPE_U 0x00
#define FRIBIDI_JOINING_TYPE_R 0x05
#define FRIBIDI_JOINING_TYPE_D 0x07
#define FRIBIDI_JOINING_TYPE_C 0x03
#define FRIBIDI_JOINING_TYPE_T 0x0C
#define FRIBIDI_JOINING_TYPE_L 0x06
#define FRIBIDI_JOINING_TYPE_G 0x10

/* FLAGS */

#define FRIBIDI_FLAG_SHAPE_MIRRORING 0x00000001U
#define FRIBIDI_FLAG_REORDER_NSM 0x00000002U
#define FRIBIDI_FLAG_SHAPE_ARAB_PRES 0x00000100U
#define FRIBIDI_FLAG_SHAPE_ARAB_LIGA 0x00000200U
#define FRIBIDI_FLAG_SHAPE_ARAB_CONSOLE 0x00000400U
#define FRIBIDI_FLAG_REMOVE_BIDI 0x00010000U
#define FRIBIDI_FLAG_REMOVE_JOINING 0x00020000U
#define FRIBIDI_FLAG_REMOVE_SPECIALS 0x00040000U
#define FRIBIDI_FLAGS_DEFAULT (FRIBIDI_FLAG_SHAPE_MIRRORING | FRIBIDI_FLAG_REORDER_NSM | FRIBIDI_FLAG_REMOVE_SPECIALS)
#define FRIBIDI_FLAGS_ARABIC (FRIBIDI_FLAG_SHAPE_ARAB_PRES | FRIBIDI_FLAG_SHAPE_ARAB_LIGA)

/* CHARACTER SETS: UTF-8 only */

#define FRIBIDI_CHAR_SET_NOT_FOUND 0
#define FRIBIDI_CHAR_SET_UTF8 1

/* FUNCTIONS, in FriBidi's export order */

FriBidiStrIndex fribidi_charset_to_unicode(FriBidiCharSet char_set, const char *s, FriBidiStrIndex len, FriBidiChar *us);
int fribidi_debug_status(void);
FriBidiCharType fribidi_get_bidi_type(FriBidiChar ch);
const char *fribidi_get_bidi_type_name(FriBidiCharType t);
void fribidi_get_bidi_types(const FriBidiChar *str, const FriBidiStrIndex len, FriBidiCharType *btypes);
FriBidiBracketType fribidi_get_bracket(FriBidiChar ch);
void fribidi_get_bracket_types(const FriBidiChar *str, const FriBidiStrIndex len, const FriBidiCharType *types,
                               FriBidiBracketType *btypes);
FriBidiJoiningType fribidi_get_joining_type(FriBidiChar ch);
const char *fribidi_get_joining_type_name(FriBidiJoiningType j);
void fribidi_get_joining_types(const FriBidiChar *str, const FriBidiStrIndex len, FriBidiJoiningType *jtypes);
fribidi_boolean fribidi_get_mirror_char(FriBidiChar ch, FriBidiChar *mirrored_ch);
FriBidiParType fribidi_get_par_direction(const FriBidiCharType *bidi_types, const FriBidiStrIndex len);
FriBidiLevel fribidi_get_par_embedding_levels(const FriBidiCharType *bidi_types, const FriBidiStrIndex len,
                                              FriBidiParType *pbase_dir, FriBidiLevel *embedding_levels);
FriBidiLevel fribidi_get_par_embedding_levels_ex(const FriBidiCharType *bidi_types,
                                                 const FriBidiBracketType *bracket_types, const FriBidiStrIndex len,
                                                 FriBidiParType *pbase_dir, FriBidiLevel *embedding_levels);
FriBidiCharType fribidi_get_type(FriBidiChar ch);
FriBidiCharType fribidi_get_type_internal(FriBidiChar ch);
void fribidi_join_arabic(const FriBidiCharType *bidi_types, const FriBidiStrIndex len,
                         const FriBidiLevel *embedding_levels, FriBidiArabicProp *ar_props);
FriBidiLevel fribidi_log2vis(const FriBidiChar *str, const FriBidiStrIndex len, FriBidiParType *pbase_dir,
                             FriBidiChar *visual_str, FriBidiStrIndex *positions_L_to_V,
                             FriBidiStrIndex *positions_V_to_L, FriBidiLevel *embedding_levels);
FriBidiLevel fribidi_log2vis_get_embedding_levels(const FriBidiCharType *bidi_types, const FriBidiStrIndex len,
                                                  FriBidiParType *pbase_dir, FriBidiLevel *embedding_levels);
fribidi_boolean fribidi_mirroring_status(void);
FriBidiCharSet fribidi_parse_charset(const char *s);
FriBidiStrIndex fribidi_remove_bidi_marks(FriBidiChar *str, const FriBidiStrIndex len,
                                          FriBidiStrIndex *positions_to_this, FriBidiStrIndex *position_from_this_list,
                                          FriBidiLevel *embedding_levels);
FriBidiLevel fribidi_reorder_line(FriBidiFlags flags, const FriBidiCharType *bidi_types, const FriBidiStrIndex len,
                                  const FriBidiStrIndex off, const FriBidiParType base_dir,
                                  FriBidiLevel *embedding_levels, FriBidiChar *visual_str, FriBidiStrIndex *map);
fribidi_boolean fribidi_reorder_nsm_status(void);
int fribidi_set_debug(int state);
fribidi_boolean fribidi_set_mirroring(fribidi_boolean state);
fribidi_boolean fribidi_set_reorder_nsm(fribidi_boolean state);
void fribidi_shape(FriBidiFlags flags, const FriBidiLevel *embedding_levels, const FriBidiStrIndex len,
                   FriBidiArabicProp *ar_props, FriBidiChar *str);
void fribidi_shape_arabic(FriBidiFlags flags, const FriBidiLevel *embedding_levels, const FriBidiStrIndex len,
                          FriBidiArabicProp *ar_props, FriBidiChar *str);
void fribidi_shape_mirroring(const FriBidiLevel *embedding_levels, const FriBidiStrIndex len, FriBidiChar *str);
FriBidiStrIndex fribidi_unicode_to_charset(FriBidiCharSet char_set, const FriBidiChar *us, FriBidiStrIndex len,
                                           char *s);

#ifdef __cplusplus
}
#endif

#endif
