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
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/SHA256.h"

#include <sqlite3.h>

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
#undef COCOAKB_METHOD_CTE

// Selector-keyed ABI: for a protocol-typed object (id<MTLTexture>, a Cocoa
// delegate, ...) the concrete class is unknown at compile time, but a selector
// carries the same ABI wherever it is implemented. Take the majority reading
// across implementing classes so one odd class can't skew it.
constexpr StringRef kSelectorVariantSQL =
    "SELECT CASE WHEN ret_class = '?' OR arg_classes LIKE '%?%' THEN '?' "
    "ELSE 'objc_msgSend' END FROM method_abi WHERE selector = ?1 "
    "GROUP BY 1 ORDER BY COUNT(*) DESC LIMIT 1";
constexpr StringRef kSelectorArgClassesSQL =
    "SELECT arg_classes FROM method_abi WHERE selector = ?1 "
    "GROUP BY arg_classes ORDER BY COUNT(*) DESC LIMIT 1";
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
    {"selector_variant", 1, kSelectorVariantSQL},
    {"selector_arg_classes", 1, kSelectorArgClassesSQL},
    {"selector_encoding", 1, kSelectorEncodingSQL},
    {"posix_sig", 1, kPosixSigSQL},
    {"posix_ret_class", 1, kPosixRetClassSQL},
    {"posix_arg_classes", 1, kPosixArgClassesSQL},
};

} // namespace

llvm::Error CocoaKBDatabase::openLocked() {
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
CocoaKBDatabase::queryString(StringRef query, ArrayRef<StringRef> args) {
  std::lock_guard<std::mutex> lock(mutex);

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

} // namespace M::KGEN::CocoaKB
