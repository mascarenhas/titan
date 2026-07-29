/*
** Titan-private symbol namespace for the vendored LPegLabel engine.
**
** Keep this list synchronized with every non-static definition in the five
** upstream translation units, including definitions enabled by LPEG_DEBUG.
** Prefixing in source is required because the combined Titan provider is
** promoted with global visibility and its static form is flattened into
** consumers.
*/

#if !defined(titan_lpeglabel_namespace_h)
#define titan_lpeglabel_namespace_h

#define finddyncap titan_lpeglabel_finddyncap
#define getcaptures titan_lpeglabel_getcaptures
#define runtimecap titan_lpeglabel_runtimecap

#define checkaux titan_lpeglabel_checkaux
#define compile titan_lpeglabel_compile
#define fixedlen titan_lpeglabel_fixedlen
#define hascaptures titan_lpeglabel_hascaptures
#define realloccode titan_lpeglabel_realloccode
#define sizei titan_lpeglabel_sizei
#define tocharset titan_lpeglabel_tocharset

#define lp_gc titan_lpeglabel_lp_gc
#define numsiblings titan_lpeglabel_numsiblings
#define match titan_lpeglabel_match

#if defined(LPEG_DEBUG)
#define printcaplist titan_lpeglabel_printcaplist
#define printcharset titan_lpeglabel_printcharset
#define printinst titan_lpeglabel_printinst
#define printktable titan_lpeglabel_printktable
#define printpatt titan_lpeglabel_printpatt
#define printtree titan_lpeglabel_printtree
#endif

#define luaopen_lpeglabel titan_lpeglabel_open

#endif
