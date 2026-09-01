//===- CocoaKBDatabase.cpp - Compile-time reads of cocoa.sqlite ----------===//
//
// See CocoaKBDatabase.h. The SQL lives here so a schema change is a one-line
// fix in one file rather than a break in every caller: a binding asks for
// "struct_size", never for a SELECT.
//
//===----------------------------------------------------------------------===//

#include "KGEN/CocoaKB/CocoaKBDatabase.h"

#include "KGEN/Support/Configuration.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/ScopeExit.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/ErrorOr.h"
#include "llvm/Support/Format.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/SHA256.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <map>
#include <sqlite3.h>
#include <vector>

using namespace llvm;

namespace M::KGEN::CocoaKB {
namespace {


/// The queries this exposes, by the name Mojo passes as the first operand.
/// A binding asks for "struct_size", not for SQL, so the schema stays an
/// implementation detail of the compiler; a metadata layout change is a
/// one-line fix here instead of a break in every caller.
struct CocoaKBQueryDef {
  StringRef name;
  unsigned argCount;
  StringRef sql;
};

constexpr StringRef kStructSizeSQL =
    "SELECT size FROM structs WHERE name = ?1";
constexpr StringRef kStructAlignSQL =
    "SELECT align FROM structs WHERE name = ?1";
constexpr StringRef kFieldOffsetSQL =
    "SELECT offset FROM struct_fields WHERE struct = ?1 AND name = ?2";

// BridgeSupport value64 is text; CAST gives the signed reading, which is the
// one that survives narrowing in both directions (see the sister port's
// HKEY_LOCAL_MACHINE lesson in COCOA_DESIGN.md D6).
constexpr StringRef kEnumValueSQL =
    "SELECT CAST(value AS INTEGER) FROM bs_enums WHERE name = ?1 LIMIT 1";

// Extern-symbol constants (NSFontAttributeName...) are runtime addresses,
// not comptime values: the database supplies the declared type and the
// binding dlsyms the symbol at runtime.
constexpr StringRef kConstantTypeSQL =
    "SELECT type64 FROM bs_constants WHERE name = ?1 LIMIT 1";

constexpr StringRef kSuperclassSQL =
    "SELECT superclass FROM rt_classes WHERE name = ?1";

// Which framework declares a class. Needed before the runtime can be asked
// anything about it: objc_getClass("NSView") is nil until AppKit is in the
// process, and objc_allocateClassPair against a nil superclass builds a root
// class that silently does nothing. BridgeSupport carries the attribution the
// runtime dump cannot -- see "Two oracles" in COCOA_CLASS_DESIGN.md.
// Ordered, not just LIMIT 1: BridgeSupport lists NSObject in every framework
// that mentions it -- around seventy of them -- so an unordered pick answers
// "AVFAudio" for NSObject and the compiler emits a dlopen of AVFAudio into
// every class that inherits from it. Foundation first, then AppKit, then
// alphabetically so the answer is at least the same on two runs.
constexpr StringRef kClassFrameworkSQL =
    "SELECT framework FROM bs_classes WHERE name = ?1 "
    "ORDER BY CASE framework WHEN 'Foundation' THEN 0 WHEN 'AppKit' THEN 1 "
    "ELSE 2 END, framework LIMIT 1";

// Method lookups walk the superclass chain: the runtime ingest records a
// method on the class that DEFINES it, and inheritance is a query, not
// codegen. ORDER BY depth so the nearest definition (an override) wins.
#define COCOAKB_METHOD_CTE(expr, table)                                        \
  "WITH RECURSIVE chain(c, depth) AS ("                                        \
  "  SELECT ?1, 0"                                                             \
  "  UNION ALL"                                                                \
  "  SELECT rc.superclass, chain.depth + 1 FROM rt_classes rc, chain"          \
  "    WHERE rc.name = chain.c AND rc.superclass IS NOT NULL)"                 \
  " SELECT " expr " FROM chain JOIN " table " m"                              \
  "   ON m.class = chain.c AND m.selector = ?2"                                \
  "  AND m.is_class = CAST(?3 AS INTEGER)"                                     \
  " ORDER BY chain.depth LIMIT 1"

constexpr StringRef kMethodEncodingSQL =
    COCOAKB_METHOD_CTE("m.encoding", "rt_methods");

// arm64 has exactly one send. objc_msgSend_stret and objc_msgSend_fpret do
// not exist here -- verified absent from this machine's libobjc -- because
// AAPCS64 returns a small/homogeneous aggregate in x0-x1 or v0-v3 and a large
// one through the x8 indirect-result register, all via the ordinary send. So
// the variant is a constant rather than a lookup.
//
// The query is kept, with its name and its D4 contract intact: an encoding
// the ABI pass could not model still answers '?', and a call through such a
// method still fails to compile rather than guessing. Only the answer for the
// modelable case got simpler.
constexpr StringRef kMsgSendVariantSQL = COCOAKB_METHOD_CTE(
    "CASE WHEN m.ret_class = '?' OR m.arg_classes LIKE '%?%' THEN '?' "
    "ELSE 'objc_msgSend' END",
    "method_abi");
constexpr StringRef kMethodRetClassSQL =
    COCOAKB_METHOD_CTE("m.ret_class", "method_abi");
constexpr StringRef kMethodArgClassesSQL =
    COCOAKB_METHOD_CTE("m.arg_classes", "method_abi");

// The KIND of a method's result -- what TYPE to give the call site, as
// distinct from which register the answer arrives in. `method_ret_class`
// cannot tell an Int from a Bool from an object because AAPCS64 puts all
// three in x0; this can, because it comes from the @encode string:
//
//   @ object   # Class    : SEL      * char*
//   i signed   u unsigned  d float    B bool     v void
//   R NSRect   P NSPoint   S NSSize   N NSRange  { other struct
//   ^ pointer  ? unmodelable
//
// Returned as the character's CODE POINT rather than the character, so it
// arrives as an integer the parameter evaluator can fold into a conditional
// type. The table itself stays readable.
constexpr StringRef kMethodRetKindSQL =
    COCOAKB_METHOD_CTE("unicode(m.kind)", "method_ret_kind");

// WHICH object a method returns, where that is knowable. The method's own
// encoding never says -- `method_getTypeEncoding` gives a bare `@` for every
// object in the system -- but a PROPERTY's attribute string does
// (`T@"NSTextStorage"`), and a property is read by a selector. That plus the
// instancetype family covers a little over half of every object-returning
// instance method.
//
// The stored `@self` -- the instancetype rule, on methods declared upstream on
// NSObject -- is resolved HERE, to ?1, because ?1 is the receiver: the chain
// walk starts at the class being asked about. So `[NSString alloc]` answers
// NSString rather than the NSObject a naive chain walk would find, and no
// consumer has to know the sentinel exists.
//
// Resolving it in SQL rather than in the caller is not only tidier. The
// caller would have to compare the answer against "@self", and a string
// comparison does not fold during parameter evaluation -- so a type
// conditioned on it stays symbolic and the whole point is lost.
constexpr StringRef kMethodRetObjCClassSQL = COCOAKB_METHOD_CTE(
    // ?1, not chain.c: the chain walk finds `alloc` on NSObject, which is
    // where it is DECLARED, and the whole point of the sentinel is that the
    // answer is where the message was SENT. `[NSString alloc]` is an
    // NSString.
    "CASE WHEN m.ret_class = '@self' THEN ?1 ELSE m.ret_class END",
    "method_ret_class");
#undef COCOAKB_METHOD_CTE

// Selector-keyed ABI: for a protocol-typed object (id<MTLTexture>, a Cocoa
// delegate, ...) the concrete class is unknown at compile time, but a selector
// carries the same ABI wherever it is implemented. Take the majority reading
// across implementing classes so one odd class can't skew it.
// The CALL direction's name mapping, done in SQL so that it FOLDS.
//
// `view.setFrameSize(sz)` has to become `setFrameSize:`, and
// `tv.insertText_replacementRange(t, r)` has to become
// `insertText:replacementRange:` -- the same underscore rule the declare
// direction uses, read backwards, with the argument count supplying the last
// colon. Doing that in Mojo would mean comptime string surgery, and string
// operations do not fold during parameter evaluation, so a type conditioned
// on the result would stay symbolic. SQLite's `replace` has no such problem.
//
// ?1 class, ?2 the Mojo-side name, ?3 is_class, ?4 the argument count. The
// answer is the selector itself, which then keys every other query -- and
// because it comes back as a folded constant, it can.
#define COCOAKB_NAME_CTE(expr, table)                                          \
  "WITH RECURSIVE chain(c, depth) AS ("                                        \
  "  SELECT ?1, 0"                                                             \
  "  UNION ALL"                                                                \
  "  SELECT rc.superclass, chain.depth + 1 FROM rt_classes rc, chain"          \
  "    WHERE rc.name = chain.c AND rc.superclass IS NOT NULL)"                 \
  " SELECT " expr " FROM chain JOIN " table " m"                               \
  "   ON m.class = chain.c"                                                    \
  "  AND m.selector = CASE WHEN CAST(?4 AS INTEGER) = 0"                       \
  "                       THEN replace(?2, '_', ':')"                          \
  "                       ELSE replace(?2, '_', ':') || ':' END"               \
  "  AND m.is_class = CAST(?3 AS INTEGER)"                                     \
  " ORDER BY chain.depth LIMIT 1"

constexpr StringRef kSelectorForNameSQL =
    COCOAKB_NAME_CTE("m.selector", "rt_methods");
// Answers 0 rather than nothing for a name the class does not have. A
// missing row would make the query fail to fold, the result type would stay
// symbolic, and the author would see a wall of unevaluated conditional
// instead of "NSString has no lenght". The caller turns 0 into that sentence.
constexpr StringRef kRetKindForNameSQL =
    "WITH RECURSIVE chain(c, depth) AS ("
    "  SELECT ?1, 0"
    "  UNION ALL"
    "  SELECT rc.superclass, chain.depth + 1 FROM rt_classes rc, chain"
    "    WHERE rc.name = chain.c AND rc.superclass IS NOT NULL)"
    " SELECT COALESCE(("
    "   SELECT unicode(m.kind) FROM chain JOIN method_ret_kind m"
    "     ON m.class = chain.c"
    "    AND m.selector = CASE WHEN CAST(?4 AS INTEGER) = 0"
    "                        THEN replace(?2, '_', ':')"
    "                        ELSE replace(?2, '_', ':') || ':' END"
    "    AND m.is_class = CAST(?3 AS INTEGER)"
    "  ORDER BY chain.depth LIMIT 1), 0)";
// An object whose class is not recorded is answered as NSObject, which is
// true of every object and is the honest upper bound: precise where the SDK
// knows, sound where it does not. Always returns a row, so a caller can ask
// unconditionally and use the answer only when the kind says object.
// COALESCE has to wrap the whole lookup, not the selected column: a JOIN
// that matches nothing returns NO ROWS, and a default inside the projection
// never runs. Written out rather than macro-generated for that reason.
constexpr StringRef kRetClassForNameSQL =
    "WITH RECURSIVE chain(c, depth) AS ("
    "  SELECT ?1, 0"
    "  UNION ALL"
    "  SELECT rc.superclass, chain.depth + 1 FROM rt_classes rc, chain"
    "    WHERE rc.name = chain.c AND rc.superclass IS NOT NULL)"
    " SELECT COALESCE(("
    "   SELECT CASE WHEN m.ret_class = '@self' THEN ?1 ELSE m.ret_class END"
    "     FROM chain JOIN method_ret_class m"
    "       ON m.class = chain.c"
    "      AND m.selector = CASE WHEN CAST(?4 AS INTEGER) = 0"
    "                          THEN replace(?2, '_', ':')"
    "                          ELSE replace(?2, '_', ':') || ':' END"
    "      AND m.is_class = CAST(?3 AS INTEGER)"
    "    ORDER BY chain.depth LIMIT 1), 'NSObject')";
#undef COCOAKB_NAME_CTE

// The KEYWORD-ARGUMENT form of the same three lookups. A call like
// `win.setFrame(aRect, display=True)` carries the selector's trailing parts
// as labels, and they arrive here as separate strings because joining them
// in Mojo would be string surgery, which does not fold. The selector is
// assembled in SQL: `?2 || ':' || ?4 || ':'` for one label, each further
// label appending `?N || ':'`. The first argument is positional and its
// part is the method name itself (?2), so `setFrame` + `display` is
// `setFrame:display:` -- the same selector the underscore rule builds, read
// from the other direction. Labels beyond five are not wrapped (a six-label
// selector is rarer than one in a thousand); the positional tier covers the
// whole span.
#define COCOAKB_PARTS_CTE(expr, table, sel)                                     \
  "WITH RECURSIVE chain(c, depth) AS ("                                        \
  "  SELECT ?1, 0"                                                             \
  "  UNION ALL"                                                                \
  "  SELECT rc.superclass, chain.depth + 1 FROM rt_classes rc, chain"          \
  "    WHERE rc.name = chain.c AND rc.superclass IS NOT NULL)"                 \
  " SELECT " expr " FROM chain JOIN " table " m"                               \
  "   ON m.class = chain.c"                                                    \
  "  AND m.selector = (" sel ")"                                               \
  "  AND m.is_class = CAST(?3 AS INTEGER)"                                     \
  " ORDER BY chain.depth LIMIT 1"

#define COCOAKB_PARTS_COALESCE_CTE(expr, table, sel, fallback)                  \
  "WITH RECURSIVE chain(c, depth) AS ("                                        \
  "  SELECT ?1, 0"                                                             \
  "  UNION ALL"                                                                \
  "  SELECT rc.superclass, chain.depth + 1 FROM rt_classes rc, chain"          \
  "    WHERE rc.name = chain.c AND rc.superclass IS NOT NULL)"                 \
  " SELECT COALESCE(("                                                         \
  "   SELECT " expr " FROM chain JOIN " table " m"                             \
  "     ON m.class = chain.c"                                                  \
  "    AND m.selector = (" sel ")"                                             \
  "    AND m.is_class = CAST(?3 AS INTEGER)"                                   \
  "  ORDER BY chain.depth LIMIT 1), " fallback ")"

#define COCOAKB_PARTS_QUERIES(suffix, argcount, sel)                           \
  constexpr StringRef kSelectorForParts##suffix##SQL =                         \
      COCOAKB_PARTS_CTE("m.selector", "rt_methods", sel);                      \
  constexpr StringRef kRetKindForParts##suffix##SQL =                          \
      COCOAKB_PARTS_COALESCE_CTE("unicode(m.kind)", "method_ret_kind", sel,    \
                                 "0");                                         \
  constexpr StringRef kRetClassForParts##suffix##SQL =                         \
      COCOAKB_PARTS_COALESCE_CTE(                                              \
          "CASE WHEN m.ret_class = '@self' THEN ?1 ELSE m.ret_class END",      \
          "method_ret_class", sel, "'NSObject'");

COCOAKB_PARTS_QUERIES(1, 4, "?2 || ':' || ?4 || ':'")
COCOAKB_PARTS_QUERIES(2, 5, "?2 || ':' || ?4 || ':' || ?5 || ':'")
COCOAKB_PARTS_QUERIES(3, 6,
                      "?2 || ':' || ?4 || ':' || ?5 || ':' || ?6 || ':'")
COCOAKB_PARTS_QUERIES(4, 7,
                      "?2 || ':' || ?4 || ':' || ?5 || ':' || ?6 || ':'"
                      " || ?7 || ':'")
COCOAKB_PARTS_QUERIES(
    5, 8, "?2 || ':' || ?4 || ':' || ?5 || ':' || ?6 || ':' || ?7 || ':'"
          " || ?8 || ':'")
#undef COCOAKB_PARTS_QUERIES
#undef COCOAKB_PARTS_COALESCE_CTE
#undef COCOAKB_PARTS_CTE

// Construction, sprint P2: `NSWindow(contentRect=..., styleMask=...)` with
// no wrapper written down. Two spellings name a constructor, and the labels
// decide which:
//
//   the FACTORY form -- a class method whose selector's parts are the
//   labels verbatim (`buttonWithTitle:target:action:` for
//   `NSButton(buttonWithTitle=..., target=..., action=...)`). One send.
//
//   the INIT form -- `alloc` plus an initialiser whose FIRST part is
//   'initWith' with the first label capitalised onto it
//   (`initWithContentRect:styleMask:backing:defer:` for
//   `NSWindow(contentRect=..., styleMask=..., backing=..., defer=...)`),
//   the remaining labels the selector's remaining parts. Two sends.
//
// Factory wins when both exist: one send instead of two, and the labels
// matching a class method verbatim is the stronger signal. Existence rides
// rt_methods, NOT ret_class: the '@self' instancetype marker is recorded on
// whichever class the ingest resolved it to -- NSWindow's own
// initWithContentRect: carries none, its subclasses do -- so requiring it
// would refuse the most standard constructor in AppKit.
#define COCOAKB_INIT_STATEMENT(f_branch, i_branch, else_branch, exact, init)    \
  "WITH RECURSIVE chain(c, depth) AS ("                                         \
  "  SELECT ?1, 0"                                                              \
  "  UNION ALL"                                                                 \
  "  SELECT rc.superclass, chain.depth + 1 FROM rt_classes rc, chain"           \
  "    WHERE rc.name = chain.c AND rc.superclass IS NOT NULL)"                  \
  " SELECT CASE"                                                                \
  "  WHEN EXISTS (SELECT 1 FROM chain JOIN rt_methods m ON m.class = chain.c"   \
  "    AND m.is_class = 1 AND m.selector = (" exact ")) THEN " f_branch         \
  "  WHEN EXISTS (SELECT 1 FROM chain JOIN rt_methods m ON m.class = chain.c"   \
  "    AND m.is_class = 0 AND m.selector = (" init ")) THEN " i_branch          \
  "  ELSE " else_branch " END"

#define COCOAKB_INIT_QUERIES(suffix, argcount, exact, init)                     \
  constexpr StringRef kInitForm##suffix##SQL =                                  \
      COCOAKB_INIT_STATEMENT("1", "2", "0", exact, init);                       \
  constexpr StringRef kInitSelector##suffix##SQL =                              \
      COCOAKB_INIT_STATEMENT("(" exact ")", "(" init ")", "''", exact, init);

COCOAKB_INIT_QUERIES(1, 2, "?2 || ':'",
                     "'initWith' || upper(substr(?2, 1, 1)) || substr(?2, 2)"
                     " || ':'")
COCOAKB_INIT_QUERIES(2, 3, "?2 || ':' || ?3 || ':'",
                     "'initWith' || upper(substr(?2, 1, 1)) || substr(?2, 2)"
                     " || ':' || ?3 || ':'")
COCOAKB_INIT_QUERIES(3, 4, "?2 || ':' || ?3 || ':' || ?4 || ':'",
                     "'initWith' || upper(substr(?2, 1, 1)) || substr(?2, 2)"
                     " || ':' || ?3 || ':' || ?4 || ':'")
COCOAKB_INIT_QUERIES(
    4, 5, "?2 || ':' || ?3 || ':' || ?4 || ':' || ?5 || ':'",
    "'initWith' || upper(substr(?2, 1, 1)) || substr(?2, 2)"
    " || ':' || ?3 || ':' || ?4 || ':' || ?5 || ':'")
COCOAKB_INIT_QUERIES(
    5, 6, "?2 || ':' || ?3 || ':' || ?4 || ':' || ?5 || ':' || ?6 || ':'",
    "'initWith' || upper(substr(?2, 1, 1)) || substr(?2, 2)"
    " || ':' || ?3 || ':' || ?4 || ':' || ?5 || ':' || ?6 || ':'")
#undef COCOAKB_INIT_QUERIES
#undef COCOAKB_INIT_STATEMENT

// A PROPERTY WRITE, sprint P3: `win.title = x` means setTitle:, found the
// same way everything else here is found -- the selector is assembled from
// the name in SQL ('set' + the name with its first letter capitalised + ':')
// and its existence on the class or a superclass settles the write at
// compile time. A miss is an ERROR, not an empty answer: a property with no
// setter is read-only, and the caller should hear that as a sentence naming
// the class and the property.
#define COCOAKB_SETTER_CTE(expr, table)                                         \
  "WITH RECURSIVE chain(c, depth) AS ("                                         \
  "  SELECT ?1, 0"                                                             \
  "  UNION ALL"                                                                \
  "  SELECT rc.superclass, chain.depth + 1 FROM rt_classes rc, chain"           \
  "    WHERE rc.name = chain.c AND rc.superclass IS NOT NULL)"                  \
  " SELECT " expr " FROM chain JOIN " table " m"                                \
  "   ON m.class = chain.c"                                                    \
  "  AND m.selector = ('set' || upper(substr(?2, 1, 1)) || substr(?2, 2)"       \
  "                    || ':')"                                                 \
  "  AND m.is_class = 0"                                                       \
  " ORDER BY chain.depth LIMIT 1"

constexpr StringRef kSetterForNameSQL =
    COCOAKB_SETTER_CTE("m.selector", "rt_methods");
#undef COCOAKB_SETTER_CTE

constexpr StringRef kSelectorVariantSQL =
    "SELECT CASE WHEN ret_class = '?' OR arg_classes LIKE '%?%' THEN '?' "
    "ELSE 'objc_msgSend' END FROM method_abi WHERE selector = ?1 "
    "GROUP BY 1 ORDER BY COUNT(*) DESC LIMIT 1";
constexpr StringRef kSelectorArgClassesSQL =
    "SELECT arg_classes FROM method_abi WHERE selector = ?1 "
    "GROUP BY arg_classes ORDER BY COUNT(*) DESC LIMIT 1";
constexpr StringRef kSelectorRetKindSQL =
    "SELECT unicode(kind) FROM method_ret_kind WHERE selector = ?1 "
    "GROUP BY kind ORDER BY COUNT(*) DESC LIMIT 1";
constexpr StringRef kSelectorRetClassSQL =
    "SELECT ret_class FROM method_abi WHERE selector = ?1 "
    "GROUP BY ret_class ORDER BY COUNT(*) DESC LIMIT 1";
// The verbatim @encode signature for a selector, majority reading. Used to
// type a Mojo-implemented method when defining an ObjC class at runtime
// (class_addMethod), so even a callback's signature comes from the SDK.
constexpr StringRef kSelectorEncodingSQL =
    "SELECT encoding FROM rt_methods WHERE selector = ?1 "
    "GROUP BY encoding ORDER BY COUNT(*) DESC LIMIT 1";

constexpr StringRef kPosixSigSQL =
    "SELECT qualtype FROM posix_functions WHERE name = ?1";
constexpr StringRef kPosixRetClassSQL =
    "SELECT ret_class FROM posix_function_abi WHERE name = ?1";
constexpr StringRef kPosixArgClassesSQL =
    "SELECT arg_classes FROM posix_function_abi WHERE name = ?1";

const CocoaKBQueryDef kCocoaQueries[] = {
    {"struct_size", 1, kStructSizeSQL},
    {"struct_align", 1, kStructAlignSQL},
    {"field_offset", 2, kFieldOffsetSQL},
    {"enum_value", 1, kEnumValueSQL},
    {"constant_type", 1, kConstantTypeSQL},
    {"superclass", 1, kSuperclassSQL},
    {"class_framework", 1, kClassFrameworkSQL},
    {"method_encoding", 3, kMethodEncodingSQL},
    {"msgsend_variant", 3, kMsgSendVariantSQL},
    {"method_ret_class", 3, kMethodRetClassSQL},
    {"method_arg_classes", 3, kMethodArgClassesSQL},
    {"method_ret_kind", 3, kMethodRetKindSQL},
    // Distinct from `method_ret_class` above, which is an ABI REGISTER
    // class (g/f/h4/...). This one is the Objective-C class of the
    // object that comes back.
    {"method_ret_objc_class", 3, kMethodRetObjCClassSQL},
    // The call direction: keyed on the MOJO-side name and argument count.
    {"selector_for_name", 4, kSelectorForNameSQL},
    {"ret_kind_for_name", 4, kRetKindForNameSQL},
    {"ret_class_for_name", 4, kRetClassForNameSQL},
    // The call direction, keyword form: keyed on the method name and the
    // selector's trailing parts as separate strings. Argument count is 3 +
    // label count (class, name, is_class, then one string per label).
    {"selector_for_parts_1", 4, kSelectorForParts1SQL},
    {"ret_kind_for_parts_1", 4, kRetKindForParts1SQL},
    {"ret_class_for_parts_1", 4, kRetClassForParts1SQL},
    {"selector_for_parts_2", 5, kSelectorForParts2SQL},
    {"ret_kind_for_parts_2", 5, kRetKindForParts2SQL},
    {"ret_class_for_parts_2", 5, kRetClassForParts2SQL},
    {"selector_for_parts_3", 6, kSelectorForParts3SQL},
    {"ret_kind_for_parts_3", 6, kRetKindForParts3SQL},
    {"ret_class_for_parts_3", 6, kRetClassForParts3SQL},
    {"selector_for_parts_4", 7, kSelectorForParts4SQL},
    {"ret_kind_for_parts_4", 7, kRetKindForParts4SQL},
    {"ret_class_for_parts_4", 7, kRetClassForParts4SQL},
    {"selector_for_parts_5", 8, kSelectorForParts5SQL},
    {"ret_kind_for_parts_5", 8, kRetKindForParts5SQL},
    {"ret_class_for_parts_5", 8, kRetClassForParts5SQL},
    // Construction, keyword form: (class, label...). Form answers 1 factory,
    // 2 alloc+init, 0 neither; selector answers the text ('' when neither).
    // Argument count is 1 + label count.
    {"init_form_for_parts_1", 2, kInitForm1SQL},
    {"init_selector_for_parts_1", 2, kInitSelector1SQL},
    {"init_form_for_parts_2", 3, kInitForm2SQL},
    {"init_selector_for_parts_2", 3, kInitSelector2SQL},
    {"init_form_for_parts_3", 4, kInitForm3SQL},
    {"init_selector_for_parts_3", 4, kInitSelector3SQL},
    {"init_form_for_parts_4", 5, kInitForm4SQL},
    {"init_selector_for_parts_4", 5, kInitSelector4SQL},
    {"init_form_for_parts_5", 6, kInitForm5SQL},
    {"init_selector_for_parts_5", 6, kInitSelector5SQL},
    // A property write: the setter a plain name means.
    {"selector_for_setter", 2, kSetterForNameSQL},
    {"selector_variant", 1, kSelectorVariantSQL},
    {"selector_arg_classes", 1, kSelectorArgClassesSQL},
    {"selector_ret_class", 1, kSelectorRetClassSQL},
    {"selector_ret_kind", 1, kSelectorRetKindSQL},
    {"selector_encoding", 1, kSelectorEncodingSQL},
    {"posix_sig", 1, kPosixSigSQL},
    {"posix_ret_class", 1, kPosixRetClassSQL},
    {"posix_arg_classes", 1, kPosixArgClassesSQL},
};

/// An Objective-C method type encoding reads: retval, total size, then
/// (type, offset) pairs for self, _cmd, and each argument. Bridging only
/// needs each argument's FIRST character -- '@' object, ':' SEL, 'B' bool,
/// '{' struct, an integer width -- so that is all this collects: argument i
/// (after self and _cmd) lands in bits 7*i of the answer, low argument
/// first, so a comptime `(kinds >> (7*i)) & 127` in Mojo folds where any
/// string operation would not. Braces and brackets nest ({CGRect={CGPoint=
/// dd}{CGSize=dd}}); '^' prefixes a pointee type that belongs to the same
/// argument. Arguments beyond eight do not fit and read as 0 (NUL): pass
/// through unbridged, which is the safe default.
/// Scan one @encode type starting at encoding[i], leaving i past it; braces
/// and brackets nest ({CGRect={CGPoint=dd}{CGSize=dd}}), and '^' prefixes a
/// pointee type that belongs to the same argument. Reports the type's first
/// character. Recursive, so it is a function rather than a lambda -- an
/// `auto` lambda cannot name itself.
static bool scanEncodingType(StringRef encoding, size_t &i, char &first) {
  if (i >= encoding.size())
    return false;
  first = encoding[i];
  auto scanMatching = [&](char open, char close) -> bool {
    size_t depth = 0;
    while (i < encoding.size()) {
      if (encoding[i] == open)
        ++depth;
      else if (encoding[i] == close && --depth == 0) {
        ++i;
        return true;
      }
      ++i;
    }
    return false;
  };
  if (first == '{')
    return scanMatching('{', '}');
  if (first == '[')
    return scanMatching('[', ']');
  ++i;
  if (first == '^') {
    char pointee = 0;
    if (!scanEncodingType(encoding, i, pointee))
      return false;
  }
  return true;
}

static int64_t parseArgKinds(StringRef encoding) {
  size_t i = 0;
  auto scanOffset = [&] {
    while (i < encoding.size() && isDigit(encoding[i]))
      ++i;
  };

  char first = 0;
  if (!scanEncodingType(encoding, i, first)) // return type
    return 0;
  scanOffset(); // total size (or the return's offset -- same skip)

  uint64_t kinds = 0;
  int argIndex = 0; // counts self, _cmd, then the arguments
  while (scanEncodingType(encoding, i, first)) {
    scanOffset();
    if (argIndex < 2) { // self, _cmd
      ++argIndex;
      continue;
    }
    int position = argIndex - 2;
    if (position >= 8)
      break;
    kinds |= static_cast<uint64_t>(static_cast<unsigned char>(first))
             << (7 * position);
    ++argIndex;
  }
  return static_cast<int64_t>(kinds);
}

//===----------------------------------------------------------------------===//
// SQL timing
//
// "Is the compiler slow because of the Cocoa database" is a question this
// fork keeps having to answer with guesses. These timers move the answer into
// the process that runs the queries: one clock read per query when the report
// is off (MODULAR_COCOAKB_TIMING unset), one table on stderr at process exit
// when it is on -- per query name, so the table attributes time across
// components (parser bridging asks selector_for_name..., class resolution
// asks class_framework, completion asks completeSelectors, ...).
//===----------------------------------------------------------------------===//

class QueryTimingCollector {
public:
  static QueryTimingCollector &get() {
    static QueryTimingCollector instance;
    return instance;
  }

  void record(StringRef what, uint64_t nanoseconds, uint64_t rowCount) {
    if (!enabled)
      return;
    std::lock_guard<std::mutex> lock(mutex);
    Row &row = table[what.str()];
    ++row.count;
    row.totalNs += nanoseconds;
    row.maxNs = std::max(row.maxNs, nanoseconds);
    row.rows += rowCount;
  }

  void dump() {
    std::lock_guard<std::mutex> lock(mutex);
    if (printed || table.empty())
      return;
    printed = true;

    struct Line {
      uint64_t totalNs, count, maxNs, rows;
      std::string what;
    };
    std::vector<Line> lines;
    uint64_t totalCount = 0, totalNs = 0;
    for (const auto &[what, row] : table) {
      lines.push_back({row.totalNs, row.count, row.maxNs, row.rows, what});
      totalCount += row.count;
      totalNs += row.totalNs;
    }
    std::sort(lines.begin(), lines.end(),
              [](const Line &a, const Line &b) {
                return a.totalNs > b.totalNs;
              });

    llvm::errs() << "== CocoaKB SQL: " << totalCount << " reads, "
                 << llvm::format("%.1f", totalNs / 1e6) << " ms total ==\n"
                 << "   count   total_ms     avg_us     max_ms      rows  read\n";
    for (const Line &line : lines) {
      double avgUs = double(line.totalNs) / double(line.count) / 1e3;
      llvm::errs() << llvm::format("%8llu %10.1f %10.1f %10.1f %10llu  %s\n",
                                   (unsigned long long)line.count,
                                   line.totalNs / 1e6, avgUs,
                                   line.maxNs / 1e6,
                                   (unsigned long long)line.rows,
                                   line.what.c_str());
    }
  }

private:
  QueryTimingCollector()
      : enabled(getenv("MODULAR_COCOAKB_TIMING") != nullptr) {}
  // The report prints from the destructor -- the collector is a static, so
  // that is exit(), which is how the language server ends. No atexit
  // registration: it would fire after the destructor has already destroyed
  // the mutex this dump takes.
  ~QueryTimingCollector() { dump(); }

  struct Row {
    uint64_t count = 0;
    uint64_t totalNs = 0;
    uint64_t maxNs = 0;
    uint64_t rows = 0;
  };
  std::mutex mutex;
  std::map<std::string, Row> table;
  bool printed = false;
  bool enabled = false;
};

/// Times one read for the report; the destructor records, so every return
/// path in the timed function is covered.
class ScopedQueryTimer {
public:
  explicit ScopedQueryTimer(StringRef what) : what(what) {}
  ~ScopedQueryTimer() {
    auto nanoseconds = std::chrono::duration_cast<std::chrono::nanoseconds>(
                           std::chrono::steady_clock::now() - start)
                           .count();
    QueryTimingCollector::get().record(what, nanoseconds, /*rowCount=*/0);
  }
  ScopedQueryTimer(const ScopedQueryTimer &) = delete;
  ScopedQueryTimer &operator=(const ScopedQueryTimer &) = delete;

private:
  StringRef what;
  std::chrono::steady_clock::time_point start =
      std::chrono::steady_clock::now();
};

} // namespace

llvm::Error CocoaKBDatabase::openLocked() {
  ScopedQueryTimer timer("(open)");
  if (attempted)
    return openError.empty()
               ? llvm::Error::success()
               : llvm::createStringError(llvm::inconvertibleErrorCode(),
                                         openError);
  attempted = true;

  ErrorOr<MojoConfig> configOr = MojoConfig::open();
  if (configOr.isError()) {
    openError = "cannot read the Mojo configuration to locate the Cocoa "
                "metadata database";
    return llvm::createStringError(llvm::inconvertibleErrorCode(), openError);
  }
  // The config owns the string, so copy it before the config goes away.
  std::string path = configOr.get().getCocoaKBPath().str();
  if (path.empty()) {
    openError = "no Cocoa metadata database is configured; set "
                "MODULAR_MOJO_MAX_COCOAKB_PATH to cocoa.sqlite";
    return llvm::createStringError(llvm::inconvertibleErrorCode(), openError);
  }

  // Read-only, and never created: a missing database is a configuration error
  // to report, not an empty one to invent and then answer wrongly from.
  openedPath = path;
  int rc = sqlite3_open_v2(path.c_str(), &db, SQLITE_OPEN_READONLY, nullptr);
  if (rc != SQLITE_OK) {
    openError = "cannot open the Cocoa metadata database at '" + path +
                "': " + std::string(db ? sqlite3_errmsg(db) : "out of memory");
    if (db) {
      sqlite3_close(db);
      db = nullptr;
    }
    return llvm::createStringError(llvm::inconvertibleErrorCode(), openError);
  }
  return llvm::Error::success();
}

llvm::Expected<sqlite3_stmt *>
CocoaKBDatabase::prepare(StringRef query, ArrayRef<StringRef> args) {
  const CocoaKBQueryDef *def = nullptr;
  for (const auto &candidate : kCocoaQueries)
    if (candidate.name == query)
      def = &candidate;

  if (!def) {
    std::string known;
    for (const auto &candidate : kCocoaQueries)
      known += (known.empty() ? "" : ", ") + candidate.name.str();
    return llvm::createStringError(llvm::inconvertibleErrorCode(),
                                   "unknown Cocoa metadata query '" +
                                       query.str() +
                                       "'; known queries: " + known);
  }

  if (args.size() != def->argCount)
    return llvm::createStringError(
        llvm::inconvertibleErrorCode(),
        "Cocoa metadata query '" + query.str() + "' takes " +
            std::to_string(def->argCount) + " argument(s), got " +
            std::to_string(args.size()));

  if (auto err = openLocked())
    return std::move(err);

  sqlite3_stmt *stmt = nullptr;
  if (sqlite3_prepare_v2(db, def->sql.str().c_str(), -1, &stmt, nullptr) !=
      SQLITE_OK)
    return llvm::createStringError(llvm::inconvertibleErrorCode(),
                                   StringRef(sqlite3_errmsg(db)));

  for (auto [index, arg] : llvm::enumerate(args))
    sqlite3_bind_text(stmt, static_cast<int>(index + 1), arg.data(),
                      static_cast<int>(arg.size()), SQLITE_TRANSIENT);
  return stmt;
}

llvm::Expected<int64_t> CocoaKBDatabase::queryInt(StringRef query,
                                                  ArrayRef<StringRef> args) {
  std::lock_guard<std::mutex> lock(mutex);
  // Times the SQL, not the mutex wait: the clock starts with the lock held.
  ScopedQueryTimer timer(query);

  // Sprint P4: per-argument KIND characters for the keyword tiers, packed
  // into one integer because an integer is what a comptime branch can
  // decompose -- argument i's @encode first character sits in bits 7*i.
  // Bridging needs to know an argument is an object ('@') rather than an
  // integer or a struct, and the only place that character lives is the
  // encoding string -- which cannot be parsed in Mojo (string surgery does
  // not fold) and is misery in SQL. This file is where the fork already
  // puts knowledge that must not live in Mojo, so the parser lives here:
  // the same reasoning that put the selector assembly in SQLite.
  StringRef argKindsSuffix;
  if (query.starts_with("arg_kinds_for_parts_"))
    argKindsSuffix = query.substr(strlen("arg_kinds_for_parts_"));
  else if (query.starts_with("arg_kinds_for_init_parts_"))
    argKindsSuffix = query.substr(strlen("arg_kinds_for_init_parts_"));
  else if (query.starts_with("arg_kinds_for_name_"))
    argKindsSuffix = query.substr(strlen("arg_kinds_for_name_"));
  else if (query == "arg_kinds_for_setter") {
    auto selector = queryStringLocked("selector_for_setter", args);
    if (!selector)
      return 0;
    auto encoding = queryStringLocked(
        "method_encoding", {args.front(), *selector, "0"});
    if (!encoding)
      return 0;
    return parseArgKinds(*encoding);
  }
  if (!argKindsSuffix.empty()) {
    // Which selector the labels (or the name) mean, then its encoding. The
    // families take different arguments, and the name family's arity rides
    // the query name exactly where selector_for_name expects its nargs
    // operand.
    SmallVector<StringRef, 9> selectorArgs;
    SmallString<32> target;
    bool isName = query.starts_with("arg_kinds_for_name_");
    bool isInit = query.starts_with("arg_kinds_for_init_parts_");
    if (isName) {
      target.append("selector_for_name");
      selectorArgs.append(args.begin(), args.end());
      selectorArgs.push_back(argKindsSuffix);
    } else {
      if (isInit)
        target.append("init_selector_for_parts_");
      else
        target.append("selector_for_parts_");
      target.append(argKindsSuffix);
      selectorArgs.append(args.begin(), args.end());
    }

    auto selector = queryStringLocked(target.str(), selectorArgs);
    if (!selector)
      return 0; // No selector: the caller's own assert reports the miss.
    // The initialiser form decides the side: a factory selector is class
    // side, an initWith... one is instance side. The name family states its
    // side directly.
    // The name family states its side as its last argument; the parts
    // family carries it third (class, name, is_class, part...).
    StringRef isClass = "0";
    if (isName)
      isClass = args.back();
    else if (!isInit && args.size() >= 3)
      isClass = args[2];
    if (isInit) {
      SmallString<32> formTarget("init_form_for_parts_");
      formTarget.append(argKindsSuffix);
      auto form = queryStringLocked(formTarget.str(), args);
      if (form && *form == "1")
        isClass = "1";
    }
    auto encoding = queryStringLocked(
        "method_encoding", {args.front(), *selector, isClass});
    if (!encoding)
      return 0;
    return parseArgKinds(*encoding);
  }

  auto stmt = prepare(query, args);
  if (!stmt)
    return stmt.takeError();
  llvm::scope_exit cleanup([&] { sqlite3_finalize(*stmt); });

  int rc = sqlite3_step(*stmt);
  if (rc != SQLITE_ROW)
    return llvm::createStringError(llvm::inconvertibleErrorCode(),
                                   "the Cocoa metadata has no '" + query.str() +
                                       "' for " + llvm::join(args, ", "));
  // A NULL column means the metadata knows the entity but not this property,
  // which is a different failure from not knowing the entity at all.
  if (sqlite3_column_type(*stmt, 0) == SQLITE_NULL)
    return llvm::createStringError(llvm::inconvertibleErrorCode(),
                                   "the Cocoa metadata records no " +
                                       query.str() + " for " +
                                       llvm::join(args, ", "));
  return sqlite3_column_int64(*stmt, 0);
}

llvm::Expected<std::string>
CocoaKBDatabase::queryStringLocked(StringRef query, ArrayRef<StringRef> args) {
  // The reproducibility pin: a compiler whose semantics depend on a database
  // must be able to say WHICH database. Hashed lazily and cached, so tooling
  // can record the exact metadata revision a binary was built against.
  if (query == "db_hash") {
    if (!args.empty())
      return llvm::createStringError(llvm::inconvertibleErrorCode(),
                                     "'db_hash' takes no arguments");
    if (auto err = openLocked())
      return std::move(err);
    if (cachedHash.empty()) {
      llvm::ErrorOr<std::unique_ptr<llvm::MemoryBuffer>> bufferOr =
          llvm::MemoryBuffer::getFile(openedPath, /*IsText=*/false);
      if (!bufferOr)
        return llvm::createStringError(
            llvm::inconvertibleErrorCode(),
            "cannot read the Cocoa metadata database for hashing");
      llvm::SHA256 sha;
      sha.update((*bufferOr)->getBuffer());
      cachedHash = llvm::toHex(sha.final(), /*LowerCase=*/true);
    }
    return cachedHash;
  }
  auto stmt = prepare(query, args);
  if (!stmt)
    return stmt.takeError();
  llvm::scope_exit cleanup([&] { sqlite3_finalize(*stmt); });

  int rc = sqlite3_step(*stmt);
  if (rc != SQLITE_ROW || sqlite3_column_type(*stmt, 0) == SQLITE_NULL)
    return llvm::createStringError(llvm::inconvertibleErrorCode(),
                                   "the Cocoa metadata has no '" + query.str() +
                                       "' for " + llvm::join(args, ", "));

  const auto *text = sqlite3_column_text(*stmt, 0);
  return std::string(reinterpret_cast<const char *>(text),
                     sqlite3_column_bytes(*stmt, 0));
}

llvm::Expected<std::string>
CocoaKBDatabase::queryString(StringRef query, ArrayRef<StringRef> args) {
  std::lock_guard<std::mutex> lock(mutex);
  ScopedQueryTimer timer(query);
  return queryStringLocked(query, args);
}

llvm::Error CocoaKBDatabase::availability() {
  std::lock_guard<std::mutex> lock(mutex);
  return openLocked();
}

std::optional<std::string>
CocoaKBDatabase::lookup(StringRef query, ArrayRef<StringRef> args) {
  auto value = queryString(query, args);
  if (!value) {
    // A miss is not news here; the caller asked precisely because it did not
    // know. Consume the error so it does not trip llvm::Expected's assertion.
    llvm::consumeError(value.takeError());
    return std::nullopt;
  }
  return *value;
}

void recordQueryTiming(StringRef what, uint64_t nanoseconds, uint64_t rows) {
  QueryTimingCollector::get().record(what, nanoseconds, rows);
}

} // namespace M::KGEN::CocoaKB
