//===----------------------------------------------------------------------===//
// TargetBackend for Apple AIR (air64) — Metal GPU kernels.
//
// Ported from the x86-64 MacVegaFork, where this drove a Radeon Pro Vega II.
// Target parameters that the fork had to derive by hand (the Vega is not in
// upstream's tables at all) are taken from upstream here, since apple-m1..m5
// are supported targets. See AIR_APPLE_SILICON.md.
//
// The upstream Metal backend is not published; this is the fork's own,
// written against a hardware-verified golden sample: an .air produced by
// Xcode 15.2's `metal` and proven to load and run on a Vega II (spike S1).
// The profile replicated here, byte-for-byte where it matters -- with the
// version-bearing rows re-derived from a golden sample of this port's own,
// taken the same way from the Metal toolchain installed here:
//
//   target triple  air64_v28-apple-macosx26.0.0   (fork: ...macosx14.2.0)
//   air.version    2.8.0                          (fork: 2.6.0)
//   air.language_version  Metal 4.0.0             (fork: Metal 3.1.0)
//   module flags   SDK 26.0 (fork: 14.2), wchar_size 4, frame-pointer 2,
//                  air.max_* caps  -- the air.max_* values are UNCHANGED
//                  from the fork and confirmed against the golden sample
//   kernels        !air.kernel = {fn, !{}, !args}; buffer args carry
//                  air.buffer/air.location_index == parameter order (the
//                  same order AppleGPURT binds at launch); trailing builtin
//                  params carry e.g. air.thread_position_in_grid
//   encoding       LLVM-17 bitcode (BitcodeWriter17), opaque pointers
//
// Legalization performed here (the open MetalAIRPass, v1):
//   1. Retarget the module to the AIR triple (datalayout already matches —
//      the stdlib target attr carries the AIR layout string).
//   2. Convert calls to the stdlib's `llvm.air.<builtin>[.dim]` shims into
//      trailing kernel parameters with the right AIR argument metadata.
//   3. Emit !air.kernel argument metadata for the leading parameters
//      (buffers by address space, by-value scalars as-is).
//   4. Stamp the module-level AIR metadata.
//
// Packaging shells out to `xcrun metallib` (precedent: mojo-build already
// shells to `xcrun dsymutil`), which also validates the AIR structurally.
//===----------------------------------------------------------------------===//

#include "KGEN/Compiler/ObjectCompiler.h"
#include "KGEN/Compiler/SaveAsmOutput.h"
#include "KGEN/ToolCommon/CompilationOptions.h"
#include "AirLegality.h"
#include "Target/Air/AirTargetProfile.h"
#include "LLVM/Bitcode/17/BitcodeWriter17.h"
#include "LLVM/Transforms/LLVMIRDowngradePass.h"
#include "LLVM/Transforms/PointerRewriter.h"
#include "Target/Air/AirTraits.h"
#include "KGEN/Compiler/Target/TargetBackend.h"
#include "Target/TargetTraits.h"

#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Location.h"
#include "llvm/ADT/SmallString.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Metadata.h"
#include "llvm/IR/Module.h"
#include <functional>

#include "llvm/IR/PatternMatch.h"
#include "llvm/IR/Verifier.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/Transforms/IPO/AlwaysInliner.h"
#include "llvm/Transforms/Scalar/Scalarizer.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Program.h"
#include "llvm/Support/raw_ostream.h"

#include <sys/stat.h>
#include <unistd.h>

#include <optional>
#include <string>

namespace M::KGEN {
namespace {

/// A backend knob that can be flipped WITHOUT rebuilding anything.
///
/// The obvious way to gate an experimental pass is an environment variable,
/// and under bazel that is a trap: bazel does not forward the shell
/// environment into compile actions, so the only way to set one is
/// `--action_env=FOO=1`, which enters the key of EVERY action and invalidates
/// the entire graph. Flipping one boolean rebuilt 3,610 actions here --
/// including all of LLVM -- and flipping it back costs the same again. That
/// turns a two-minute A/B measurement into a two-hour one, so nobody runs the
/// experiment.
///
/// So look in a FILE as well. The file is not a bazel input, so writing it
/// invalidates nothing: the binary already contains both code paths, and the
/// choice is made when the compiler runs.
///
/// THE MOJO KERNEL CACHE DOES NOT KNOW ABOUT THIS FILE -- but only on one of
/// the two paths, and it matters which. `~/.cache/modular/.mojo_cache` is keyed
/// on the kernel body: not on the compiler binary, not on the environment, and
/// not on this file. Toggle a knob, recompile the same kernel through
/// `mojo build`, and you are handed the cached object compiled under the
/// previous setting -- the A/B reads "no change" whatever the pass does. Run
/// `./clear_cache.sh` between toggles there.
///
/// Under bazel it does NOT bite, measured rather than assumed: after
/// `clear_cache.sh` and two full mojo compile actions the cache directory is
/// still absent, so bazel's sandboxed actions never reach it (HOME is not
/// forwarded into them either -- see the search order below). A knob flipped
/// with the kernel bodies unchanged did take effect on all five kernels of a
/// test target. What gates a re-run under bazel is bazel's own action cache,
/// which the knob file is likewise not part of: change an input, or the action
/// simply does not run.
///
/// Search order, first hit wins:
///   1. the environment variable (works outside bazel, and in CI)
///   2. $APPLEGPU_XFORMS_FILE, if set
///   3. $HOME/.applegpu-xforms
///   4. /tmp/applegpu-xforms.conf, ONLY if owned by the current user
///
/// $HOME comes before /tmp, and the /tmp file is ownership-checked, because
/// /tmp is world-writable: without that, any local account can drop a file
/// there and silently change how everyone else's kernels are compiled.
///
/// Under bazel the ownership check is the ONLY guard, not a backstop. Measured:
/// bazel does not forward HOME into a compile action, so $HOME/.applegpu-xforms
/// is invisible there and /tmp is the only file the compiler reads. Outside
/// bazel -- `mojo build` from a shell -- $HOME is set and wins.
///
/// File format is one `key=value` per line; `#` starts a comment. Missing file
/// or missing key means "unset", and the caller's default stands.
static std::optional<std::string> airKnob(llvm::StringRef key) {
  // 1. environment first: an explicit --action_env should always win.
  {
    llvm::SmallString<64> envName(key);
    if (const char *v = ::getenv(envName.c_str()))
      return std::string(v);
  }
  // 2-4. then the config file, parsed once per process.
  static const llvm::StringMap<std::string> *table = [] {
    auto *m = new llvm::StringMap<std::string>();
    llvm::SmallVector<std::string, 3> paths;
    if (const char *p = ::getenv("APPLEGPU_XFORMS_FILE"))
      paths.push_back(p);
    if (const char *home = ::getenv("HOME"))
      paths.push_back(std::string(home) + "/.applegpu-xforms");
    paths.push_back("/tmp/applegpu-xforms.conf");
    // /tmp is world-writable and its sticky bit only stops you deleting
    // someone else's file, not creating one before they do. A knob file there
    // that this user does not own is somebody else's instruction about how to
    // compile our kernels, so read it as a warning rather than as config.
    auto ownedByUs = [](const std::string &path) {
      if (path.rfind("/tmp/", 0) != 0)
        return true;
      struct stat st;
      if (::stat(path.c_str(), &st) != 0)
        return false;
      if (st.st_uid == ::getuid())
        return true;
      llvm::errs() << "[applegpu] ignoring " << path
                   << ": owned by uid " << st.st_uid << ", not by you ("
                   << ::getuid() << ")\n";
      return false;
    };
    for (const std::string &path : paths) {
      if (!ownedByUs(path))
        continue;
      auto buf = llvm::MemoryBuffer::getFile(path);
      if (!buf)
        continue;
      llvm::SmallVector<llvm::StringRef, 16> lines;
      (*buf)->getBuffer().split(lines, '\n');
      for (llvm::StringRef line : lines) {
        line = line.take_until([](char c) { return c == '#'; }).trim();
        if (line.empty())
          continue;
        auto [k, v] = line.split('=');
        if (!v.empty() || line.contains('='))
          (*m)[k.trim()] = v.trim().str();
      }
      // The knob file is invisible to the kernel cache, so a stale hit is the
      // normal outcome of a toggle. Say it where it can actually be acted on.
      if (!m->empty())
        llvm::errs() << "[applegpu] " << m->size() << " AIR knob(s) loaded from "
                     << path
                     << " -- if you are running the compiler OUTSIDE bazel, the "
                        "Mojo kernel cache is keyed on the kernel body and not "
                        "on this file, so run ./clear_cache.sh after changing a "
                        "knob or you will measure the previously cached "
                        "codegen\n";
      break; // first readable file wins
    }
    return m;
  }();
  auto it = table->find(key);
  if (it == table->end())
    return std::nullopt;
  return it->second;
}

static bool airKnobEnabled(llvm::StringRef key, bool dflt) {
  auto v = airKnob(key);
  if (!v)
    return dflt;
  llvm::StringRef s(*v);
  return !(s == "0" || s.equals_insensitive("off") ||
           s.equals_insensitive("false") || s.equals_insensitive("no"));
}

// Verified against a golden sample from THIS machine's toolchain, the same
// way the x86-64 fork derived its own (spike S1):
//
//   xcrun metal -S -emit-llvm k.metal -o k.ll
//   -> target triple = "air64_v28-apple-macosx26.0.0"
//
// Note the AIR version is encoded IN the triple (`_v28` == AIR 2.8), so this
// string and kAirVersion below must move together. Do not substitute the bare
// "air64-apple-macosx" that std/gpu/host/info.mojo carries -- that is the
// KGEN target attribute, not what the Metal frontend stamps into a module.
// (The fork pinned air64-apple-macosx14.2.0 from Xcode 15.2 / AIR 2.6.)
// The literal that used to live here is now AirTargetProfile.h::kMetal4.
// Deriving the triple from the profile is what keeps `_v28` and
// air.version from drifting apart -- they encode the same number.

//===----------------------------------------------------------------------===//
// Builtin shims: the stdlib emits calls to functions named
// `llvm.air.<builtin>` or `llvm.air.<builtin>.<dim>`; AIR wants them as
// trailing kernel parameters carrying metadata.
//===----------------------------------------------------------------------===//

struct BuiltinKind {
  llvm::StringRef shimBase;  // e.g. "thread_position_in_grid"
  llvm::StringRef airTag;    // e.g. "air.thread_position_in_grid"
};

constexpr BuiltinKind kBuiltins[] = {
    {"thread_position_in_grid", "air.thread_position_in_grid"},
    {"thread_position_in_threadgroup", "air.thread_position_in_threadgroup"},
    {"threadgroup_position_in_grid", "air.threadgroup_position_in_grid"},
    {"threads_per_threadgroup", "air.threads_per_threadgroup"},
    {"threads_per_grid", "air.threads_per_grid"},
    {"threadgroups_per_grid", "air.threadgroups_per_grid"},
    {"thread_index_in_simdgroup", "air.thread_index_in_simdgroup"},
    {"simdgroup_index_in_threadgroup", "air.simdgroup_index_in_threadgroup"},
    {"threads_per_simdgroup", "air.threads_per_simdgroup"},
    {"thread_index_in_threadgroup", "air.thread_index_in_threadgroup"},
};

// Drop the per-signature tag LowerPOPToLLVM appends to `llvm.air.*` names.
//
// Those names are ours, not LLVM's, so they get none of the per-overload
// mangling that turns llvm.fma into llvm.fma.v4f32: every operand combination
// would otherwise resolve to ONE declaration, and the second signature
// asserts ("Calling a function with a bad signature!") during MLIR->LLVM
// translation -- a hard compiler crash in a stack naming no user code.
// ConvertPOPCallLLVMIntrinsic makes the symbol unique by appending
// `$<types>`. Nothing downstream wants to see that: the real air.* name is
// derived from the operand types here, so the tag only ever had to be
// unique, never correct.
llvm::StringRef airStem(llvm::StringRef name) {
  return name.take_front(name.find('$'));
}

// Parses "llvm.air.<base>[.<dim>]" into (kind, dim). dim: x=0,y=1,z=2, or
// nullopt for scalar builtins used undimensioned.
std::optional<std::pair<const BuiltinKind *, std::optional<unsigned>>>
parseBuiltinShim(llvm::StringRef name) {
  name = airStem(name); // before the .x/.y/.z test -- the tag would hide it
  name.consume_front("llvm."); // pre-lowering spelling
  if (!name.consume_front("air."))
    return std::nullopt;
  std::optional<unsigned> dim;
  if (name.ends_with(".x") || name.ends_with(".y") || name.ends_with(".z")) {
    dim = name.back() - 'x';
    name = name.drop_back(2);
  }
  for (const BuiltinKind &kind : kBuiltins)
    if (name == kind.shimBase)
      return std::make_pair(&kind, dim);
  return std::nullopt;
}

//===----------------------------------------------------------------------===//
// AIR legalization (the open MetalAIRPass, v1)
//===----------------------------------------------------------------------===//

struct KernelBuiltinUse {
  const BuiltinKind *kind;
  bool anyDimensioned = false; // used with .x/.y/.z -> uint3 param
  llvm::SmallVector<llvm::CallInst *, 8> calls;
};

llvm::MDNode *mdStrings(llvm::LLVMContext &c,
                        llvm::ArrayRef<llvm::Metadata *> elts) {
  return llvm::MDNode::get(c, elts);
}

llvm::Metadata *mdI32(llvm::LLVMContext &c, uint32_t v) {
  return llvm::ConstantAsMetadata::get(
      llvm::ConstantInt::get(llvm::Type::getInt32Ty(c), v));
}

llvm::Metadata *mdStr(llvm::LLVMContext &c, llvm::StringRef s) {
  return llvm::MDString::get(c, s);
}

// Propagates a changed pointer address space through the use graph, mutating
// derived pointer-typed values (GEPs, phis, selects, bitcasts) in place.
void propagatePointerAS(llvm::SmallVectorImpl<llvm::Value *> &retype) {
  while (!retype.empty()) {
    llvm::Value *v = retype.pop_back_val();
    for (llvm::User *user : v->users()) {
      auto *inst = llvm::dyn_cast<llvm::Instruction>(user);
      if (!inst)
        continue;
      llvm::Type *want = nullptr;
      if (llvm::isa<llvm::GetElementPtrInst>(inst) ||
          llvm::isa<llvm::PHINode>(inst) || llvm::isa<llvm::BitCastInst>(inst))
        want = v->getType();
      else if (auto *sel = llvm::dyn_cast<llvm::SelectInst>(inst);
               sel && sel->getCondition() != v)
        want = v->getType();
      else if (auto *cmp = llvm::dyn_cast<llvm::ICmpInst>(inst)) {
        // An icmp yields i1, so it is never itself retyped and the generic
        // path below never looks at it -- but comparing a retyped AS1
        // pointer against an operand still in AS0 is invalid IR. The
        // verifier calls it "Both operands to ICmp instruction are not of
        // the same type!"; the AIR reader would have said only "Invalid
        // record". Most often the sibling is a null constant, from a
        // captured pointer being null-checked.
        llvm::Type *want = v->getType();
        for (unsigned i = 0; i != 2; ++i) {
          llvm::Use &use = cmp->getOperandUse(i);
          llvm::Value *op = use.get();
          if (op == v || op->getType() == want || !op->getType()->isPointerTy())
            continue;
          if (llvm::isa<llvm::ConstantPointerNull>(op)) {
            use.set(llvm::ConstantPointerNull::get(
                llvm::cast<llvm::PointerType>(want)));
            continue;
          }
          llvm::IRBuilder<> b(cmp);
          llvm::Value *asInt = b.CreatePtrToInt(
              op, llvm::Type::getInt64Ty(cmp->getContext()));
          use.set(b.CreateIntToPtr(asInt, want));
        }
        continue;
      } else if (auto *call = llvm::dyn_cast<llvm::CallInst>(inst)) {
        // A retyped pointer flowing into a call: retype the matching params
        // of DEFINED callees so their bodies see the new address space
        // (external callees are adapted at the call site by the
        // PointerRewriter's universal argument bitcasts).
        llvm::Function *callee = call->getCalledFunction();
        if (callee && !callee->isDeclaration()) {
          for (unsigned ai = 0, ae = call->arg_size(); ai != ae; ++ai) {
            if (call->getArgOperand(ai) == v && ai < callee->arg_size()) {
              llvm::Argument *param = callee->getArg(ai);
              if (param->getType() != v->getType() &&
                  param->getType()->isPointerTy()) {
                param->mutateType(v->getType());
                retype.push_back(param);
              }
            }
          }
        }
        continue;
      }
      if (want && inst->getType() != want &&
          llvm::isa<llvm::PointerType>(inst->getType())) {
        inst->mutateType(want);
        retype.push_back(inst);
        // Reconcile SIBLING operands. Mutating a select or phi to the new
        // address space leaves any other pointer arm at the old one, which
        // is invalid IR -- llvm-as names it plainly ("both values to select
        // must have same type"), while a bitcode reader hitting the encoded
        // VSELECT can only say "Invalid record", which is how this actually
        // surfaced: every reader, Apple's AND modern LLVM's, refused the
        // module. Route mismatched arms through the ptrtoint/inttoptr pair
        // (the Apple idiom; AIR has no addrspacecast).
        auto fixOperand = [&](llvm::Use &use, llvm::Instruction *insertPt) {
          llvm::Value *op = use.get();
          if (op == v || op->getType() == want ||
              !op->getType()->isPointerTy())
            return;
          // A null pointer constant just gets rebuilt in the new space; no
          // instruction, and it keeps `icmp eq ptr, null` recognisable to
          // later passes rather than burying it under an inttoptr.
          if (llvm::isa<llvm::ConstantPointerNull>(op)) {
            use.set(llvm::ConstantPointerNull::get(
                llvm::cast<llvm::PointerType>(want)));
            return;
          }
          llvm::IRBuilder<> b(insertPt);
          llvm::Value *asInt = b.CreatePtrToInt(
              op, llvm::Type::getInt64Ty(inst->getContext()));
          use.set(b.CreateIntToPtr(asInt, want));
        };
        if (auto *sel = llvm::dyn_cast<llvm::SelectInst>(inst)) {
          fixOperand(sel->getOperandUse(1), sel);
          fixOperand(sel->getOperandUse(2), sel);
        } else if (auto *phi = llvm::dyn_cast<llvm::PHINode>(inst)) {
          for (unsigned i = 0, e = phi->getNumIncomingValues(); i != e; ++i)
            fixOperand(phi->getOperandUse(i),
                       phi->getIncomingBlock(i)->getTerminator());
        }
      }
    }
  }
}

// Re-resolve overloaded memory intrinsics after address-space retyping.
//
// llvm.memcpy/memmove/memset encode their pointers' address spaces IN THE
// NAME (llvm.memcpy.p0.p0.i64). Retyping an argument to addrspace(1) without
// re-resolving leaves the call disagreeing with its own callee:
//
//   Call parameter type does not match function signature!
//     call void @llvm.memcpy.p0.p0.i64(ptr %a, ptr addrspace(1) %b, ...)
//
// The AIR reader would have called that "Invalid record". Same family as the
// select/phi/icmp reconciliation above -- a retyped pointer whose consumer
// was left behind -- but here the consumer is a declaration whose identity
// depends on the types, so the fix is to look up the right overload rather
// than to cast the operand back.
void refreshOverloadedMemIntrinsics(llvm::Module &m) {
  llvm::SmallVector<llvm::CallInst *, 8> calls;
  for (llvm::Function &fn : m)
    for (llvm::BasicBlock &bb : fn)
      for (llvm::Instruction &inst : bb)
        if (auto *call = llvm::dyn_cast<llvm::CallInst>(&inst))
          if (llvm::Function *callee = call->getCalledFunction())
            switch (callee->getIntrinsicID()) {
            case llvm::Intrinsic::memcpy:
            case llvm::Intrinsic::memcpy_inline:
            case llvm::Intrinsic::memmove:
            case llvm::Intrinsic::memset:
            case llvm::Intrinsic::memset_inline:
              calls.push_back(call);
              break;
            default:
              break;
            }
  for (llvm::CallInst *call : calls) {
    llvm::Intrinsic::ID id = call->getCalledFunction()->getIntrinsicID();
    bool isSet = id == llvm::Intrinsic::memset ||
                 id == llvm::Intrinsic::memset_inline;
    llvm::SmallVector<llvm::Type *, 3> tys;
    tys.push_back(call->getArgOperand(0)->getType()); // dst
    if (!isSet)
      tys.push_back(call->getArgOperand(1)->getType()); // src
    tys.push_back(call->getArgOperand(2)->getType()); // length
    llvm::Function *want =
        llvm::Intrinsic::getOrInsertDeclaration(&m, id, tys);
    if (want != call->getCalledFunction())
      call->setCalledFunction(want);
  }
}

// Mojo's address-space numbering is NVPTX's (CONSTANT=4, LOCAL=5); AIR uses
// constant=2 and private=0. Remap module globals and propagate.
void remapAddressSpaces(llvm::Module &m) {
  auto mapAS = [](unsigned as) -> std::optional<unsigned> {
    if (as == 4)
      return 2u; // constant
    if (as == 5)
      return 0u; // thread-private
    return std::nullopt;
  };
  llvm::SmallVector<llvm::GlobalVariable *, 8> worklist;
  for (llvm::GlobalVariable &gv : m.globals())
    if (mapAS(gv.getAddressSpace()))
      worklist.push_back(&gv);
  for (llvm::GlobalVariable *gv : worklist) {
    unsigned newAS = *mapAS(gv->getAddressSpace());
    auto *replacement = new llvm::GlobalVariable(
        m, gv->getValueType(), gv->isConstant(), gv->getLinkage(),
        gv->hasInitializer() ? gv->getInitializer() : nullptr, "", gv,
        gv->getThreadLocalMode(), newAS, gv->isExternallyInitialized());
    replacement->takeName(gv);
    replacement->setAlignment(gv->getAlign());
    replacement->setUnnamedAddr(gv->getUnnamedAddr());
    gv->mutateType(replacement->getType());
    gv->replaceAllUsesWith(replacement);
    llvm::SmallVector<llvm::Value *, 16> retype;
    retype.push_back(replacement);
    propagatePointerAS(retype);
    gv->eraseFromParent();
  }
}

// Rewrites one kernel: builtin shim calls become trailing parameters; returns
// the new function (parameter lists are immutable, so the body is spliced
// into a fresh function) plus the per-argument AIR metadata list.
llvm::Function *legalizeKernel(llvm::Function &fn,
                               llvm::SmallVectorImpl<llvm::Metadata *> &argMD) {
  llvm::LLVMContext &c = fn.getContext();
  llvm::Module &m = *fn.getParent();

  // Collect builtin shim uses inside this kernel.
  llvm::SmallVector<KernelBuiltinUse, 4> uses;
  for (llvm::BasicBlock &bb : fn) {
    for (llvm::Instruction &inst : bb) {
      auto *call = llvm::dyn_cast<llvm::CallInst>(&inst);
      if (!call || !call->getCalledFunction())
        continue;
      auto parsed = parseBuiltinShim(call->getCalledFunction()->getName());
      if (!parsed)
        continue;
      KernelBuiltinUse *use = nullptr;
      for (KernelBuiltinUse &u : uses)
        if (u.kind == parsed->first)
          use = &u;
      if (!use) {
        uses.push_back({parsed->first, false, {}});
        use = &uses.back();
      }
      use->anyDimensioned |= parsed->second.has_value();
      use->calls.push_back(call);
    }
  }

  // New signature: original params + one param per used builtin kind.
  // Pointer params move to the AIR device address space (1): Mojo elaborates
  // device pointers as generic AS0, which NVPTX tolerates but AIR rejects —
  // this rewrite is the address-space half of the closed MetalAIRPass.
  llvm::LLVMContext &ctx_ = fn.getContext();

  // ── Captured pointers: NOT hoisted on Apple Silicon ────────────────────
  // The x86-64 fork hoisted every device pointer that arrived inside a
  // by-value capture struct into its own kernel buffer parameter, named
  // `__vega_cap_<srcParam>_<byteOffset>` so the runtime could recover by
  // pipeline reflection which capture-blob bytes held the address to bind.
  // That existed because AMD's Metal backend cannot resolve a raw address to
  // a buffer resource descriptor and crashed lowering any access through one.
  //
  // Apple Silicon does not need it, and it is actively harmful here:
  // air.max_device_buffers is 31, and hoisting spends one slot per captured
  // pointer, so a kernel Apple would bind as a single constant buffer can
  // exhaust the limit.
  //
  // The canonical Apple shape (verified with `xcrun metal -S -emit-llvm` on a
  // struct-with-device-pointer kernel) keeps the pointer in the struct and
  // describes it with nested metadata on ONE buffer:
  //
  //   !"air.indirect_buffer", !"air.struct_type_info", !N
  //   !N = ... !"p", !"air.indirect_argument", !M
  //   !M = ... !"air.buffer", !"air.address_space", i32 1
  //
  // TODO(air-indirect): emit air.indirect_buffer / air.struct_type_info for
  // capture-struct params, and type their pointer fields addrspace(1) rather
  // than relying on deviceizeCapturedPointers to retype the loads.
  //
  // NOT a correctness blocker. Kernels that dereference a device pointer out
  // of a capture struct work today: deviceizeCapturedPointers rewrites the
  // load to an inttoptr into addrspace(1) (Apple's own idiom), and the
  // runtime keeps the pointee alive with markAllResident(). That is what
  // test_function_mts exercises and it passes.
  //
  // What emitting the metadata buys is PRECISION. It tells Metal which bytes
  // of the blob are device pointers, so residency can be narrowed from "every
  // live allocation on the encoder" to just the reachable ones -- see
  // markAllResident in AppleGPUMetal.cpp, which is coarse by necessity
  // precisely because this metadata is missing.
  //
  // The exact target shape, golden-sampled from `xcrun metal -S -emit-llvm`
  // on a kernel taking `constant Caps& { device float* p; device float* q;
  // uint n; }`, including two details easy to miss:
  //
  //   !12 = !{i32 0, !"air.indirect_buffer", !"air.buffer_size", i32 24,
  //           !"air.location_index", i32 0, i32 1, !"air.read",
  //           !"air.address_space", i32 2, !"air.struct_type_info", !13, ...}
  //   !13 = !{i32 0,  i32 8, i32 0, !"float", !"p",
  //             !"air.indirect_argument", !14,
  //           i32 8,  i32 8, i32 0, !"float", !"q",
  //             !"air.indirect_argument", !15,
  //           i32 16, i32 4, i32 0, !"uint",  !"n",
  //             !"air.indirect_argument", !16}
  //   !14 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, ...
  //           !"air.address_space", i32 1, ...}
  //   !16 = !{i32 2, !"air.indirect_constant", !"air.location_index", i32 2, ...}
  //
  //   - struct_type_info is a FLAT tuple per field:
  //     <byteOffset>, <size>, 0, <typeName>, <fieldName>,
  //     "air.indirect_argument", <node>.
  //   - nested location_index is its OWN namespace, not the top-level buffer
  //     numbering (p and q take 0 and 1 here while a top-level buffer also
  //     uses 1), and non-pointer fields are air.indirect_constant, not
  //     air.buffer.
  //
  // The field layout is recoverable: legalizeKernel keeps each by-value
  // param's original type in scalarOrigTypes, so the struct and its pointer
  // offsets are still in hand at the point the metadata is written.

  // By-value scalar params become constant-address-space(2) pointer params —
  // AIR's model for MSL `constant T&` — loaded at entry; the runtime binds
  // them with setBytes at the same index. Generic pointers move to device
  // AS(1).
  llvm::SmallVector<llvm::Type *, 8> paramTypes;
  llvm::SmallVector<llvm::Type *, 8> scalarOrigTypes; // per-param, null if ptr
  for (llvm::Type *ty : fn.getFunctionType()->params()) {
    if (auto *pt = llvm::dyn_cast<llvm::PointerType>(ty)) {
      scalarOrigTypes.push_back(nullptr);
      paramTypes.push_back(pt->getAddressSpace() == 0
                               ? llvm::PointerType::get(ctx_, 1)
                               : ty);
    } else {
      scalarOrigTypes.push_back(ty);
      paramTypes.push_back(llvm::PointerType::get(ctx_, 2));
    }
  }
  // These coincide now that nothing is inserted between the original params
  // and the builtins; the fork's hoisted capture params sat in that gap.
  unsigned numOrigParams = paramTypes.size();

  // Dynamically-sized threadgroup memory is a PARAMETER in AIR, not a global.
  //
  // Mojo elaborates it as `@extern_ptr_syml = external addrspace(3) global`
  // and nothing ever defines that symbol, so metallib stops with
  //   LLVM ERROR: Undefined symbol: extern_ptr_syml
  // Apple's own compiler gives the kernel a `threadgroup float*` parameter
  // instead, and the host sizes it with setThreadgroupMemoryLength:atIndex:,
  // which AppleGPUMetal already calls. The runtime half was always there;
  // only the signature was wrong.
  llvm::SmallVector<llvm::GlobalVariable *, 2> tgGlobals;
  for (llvm::GlobalVariable &gv : m.globals()) {
    if (!gv.isDeclaration() || gv.getAddressSpace() != 3)
      continue;
    if (llvm::any_of(gv.users(), [&](const llvm::User *u) {
          auto *ins = llvm::dyn_cast<llvm::Instruction>(u);
          return ins && ins->getFunction() == &fn;
        }))
      tgGlobals.push_back(&gv);
  }
  for (unsigned t = 0; t < tgGlobals.size(); ++t)
    paramTypes.push_back(llvm::PointerType::get(ctx_, 3));

  unsigned firstBuiltinIdx = numOrigParams + tgGlobals.size();
  for (KernelBuiltinUse &use : uses)
    paramTypes.push_back(use.anyDimensioned
                             ? llvm::FixedVectorType::get(
                                   llvm::Type::getInt32Ty(c), 3)
                             : llvm::cast<llvm::Type>(
                                   llvm::Type::getInt32Ty(c)));

  auto *newTy =
      llvm::FunctionType::get(llvm::Type::getVoidTy(c), paramTypes, false);
  llvm::Function *newFn = llvm::Function::Create(
      newTy, fn.getLinkage(), fn.getAddressSpace(), "", &m);
  newFn->takeName(&fn);
  newFn->copyAttributesFrom(&fn);
  newFn->setCallingConv(fn.getCallingConv());

  // Splice the body and rewire the original arguments. Where a pointer
  // param changed address space, propagate the new pointer type through its
  // use graph (GEPs and friends), mutating derived pointer types in place.
  newFn->splice(newFn->begin(), &fn);
  llvm::IRBuilder<> entry(&newFn->getEntryBlock(),
                          newFn->getEntryBlock().begin());
  llvm::SmallVector<llvm::Value *, 16> retype;
  for (unsigned i = 0, e = fn.arg_size(); i != e; ++i) {
    llvm::Argument *oldArg = fn.getArg(i);
    llvm::Argument *newArg = newFn->getArg(i);
    if (scalarOrigTypes[i]) {
      // Scalar became constant-AS pointer: load the value at entry.
      llvm::Value *loaded =
          entry.CreateLoad(scalarOrigTypes[i], newArg,
                           llvm::Twine(oldArg->getName(), ".val"));
      oldArg->replaceAllUsesWith(loaded);
      newArg->setName(oldArg->getName());
      continue;
    }
    if (oldArg->getType() != newArg->getType()) {
      // Same representation, new address space: mutate the old arg's users.
      oldArg->mutateType(newArg->getType());
      retype.push_back(oldArg);
    }
    oldArg->replaceAllUsesWith(newArg);
    newArg->takeName(oldArg);
    if (!retype.empty() && retype.back() == oldArg) {
      retype.back() = newArg;
    }
  }
  propagatePointerAS(retype);

  // Replace shim calls with reads of the new parameters.
  // Point the old globals at their new parameters. The global itself stays
  // in the module but loses every use, so the later dead-global sweep drops
  // it -- and an undefined addrspace(3) global with no uses is still an
  // undefined symbol to the reader, so it must actually go.
  for (unsigned t = 0; t < tgGlobals.size(); ++t) {
    llvm::Argument *tgArg = newFn->getArg(numOrigParams + t);
    tgArg->setName("tg_mem");
    tgGlobals[t]->replaceAllUsesWith(tgArg);
  }

  // Threadgroup parameters. Same air.buffer record as a device buffer but
  // address_space 3, and note the location_index restarts at 0: threadgroup
  // bindings are numbered separately from device buffers, which is what
  // setThreadgroupMemoryLength:atIndex:0 on the host is addressing.
  for (unsigned t = 0; t < tgGlobals.size(); ++t) {
    unsigned idx = numOrigParams + t;
    llvm::Argument *arg = newFn->getArg(idx);
    argMD.push_back(mdStrings(
        c, {mdI32(c, idx), mdStr(c, "air.buffer"),
            mdStr(c, "air.location_index"), mdI32(c, t), mdI32(c, 1),
            mdStr(c, "air.read_write"),
            mdStr(c, "air.address_space"), mdI32(c, 3),
            mdStr(c, "air.arg_type_size"), mdI32(c, 4),
            mdStr(c, "air.arg_type_align_size"), mdI32(c, 4),
            mdStr(c, "air.arg_type_name"), mdStr(c, "void"),
            mdStr(c, "air.arg_name"), mdStr(c, arg->getName())}));
    arg->addAttr(llvm::Attribute::get(c, "air-buffer-no-alias"));
  }
  for (unsigned u = 0; u < uses.size(); ++u) {
    llvm::Argument *arg = newFn->getArg(firstBuiltinIdx + u);
    for (llvm::CallInst *call : uses[u].calls) {
      llvm::Value *replacement = arg;
      auto parsed = parseBuiltinShim(call->getCalledFunction()->getName());
      if (uses[u].anyDimensioned) {
        unsigned dim = parsed->second.value_or(0);
        llvm::IRBuilder<> b(call);
        replacement = b.CreateExtractElement(arg, b.getInt32(dim));
      }
      // Shims return i32/i64 variants; adjust width if needed.
      if (replacement->getType() != call->getType()) {
        llvm::IRBuilder<> b(call);
        replacement =
            b.CreateZExtOrTrunc(replacement, call->getType());
      }
      call->replaceAllUsesWith(replacement);
      call->eraseFromParent();
    }
  }

  // Per-argument AIR metadata. Leading params: pointers become air.buffer
  // entries whose location_index is the parameter index — the exact order
  // AppleGPURT binds buffers at launch. By-value scalars keep their position but
  // are not listed (the golden sample lists buffers and builtins only... it
  // listed all three including the by-value id as builtin; scalars passed
  // by value from Mojo become setBytes-bound constant buffers instead), so
  // v1 requires kernels whose leading params are all pointers.
  // Original params only — builtin params get their own records below, and
  // scalarOrigTypes is sized to the original parameter list.
  for (unsigned i = 0; i != numOrigParams; ++i) {
    llvm::Argument *arg = newFn->getArg(i);
    bool isScalar = scalarOrigTypes[i] != nullptr;
    unsigned as = isScalar
                      ? 2u
                      : llvm::cast<llvm::PointerType>(arg->getType())
                            ->getAddressSpace();
    unsigned size =
        isScalar ? static_cast<unsigned>(
                       m.getDataLayout().getTypeAllocSize(scalarOrigTypes[i]))
                 : 4u;
    argMD.push_back(mdStrings(
        c, {mdI32(c, i), mdStr(c, "air.buffer"),
            mdStr(c, "air.location_index"), mdI32(c, i), mdI32(c, 1),
            mdStr(c, isScalar ? "air.read" : "air.read_write"),
            mdStr(c, "air.address_space"), mdI32(c, as ? as : 1),
            mdStr(c, "air.arg_type_size"), mdI32(c, size),
            mdStr(c, "air.arg_type_align_size"), mdI32(c, size),
            mdStr(c, "air.arg_type_name"), mdStr(c, isScalar ? "uint" : "void"),
            mdStr(c, "air.arg_name"), mdStr(c, arg->getName())}));
    if (!isScalar)
      arg->addAttr(llvm::Attribute::get(c, "air-buffer-no-alias"));
  }
  for (unsigned u = 0; u < uses.size(); ++u) {
    unsigned idx = firstBuiltinIdx + u;
    argMD.push_back(mdStrings(
        c, {mdI32(c, idx), mdStr(c, uses[u].kind->airTag),
            mdStr(c, "air.arg_type_name"),
            mdStr(c, uses[u].anyDimensioned ? "uint3" : "uint"),
            mdStr(c, "air.arg_name"), mdStr(c, uses[u].kind->shimBase)}));
  }

  fn.eraseFromParent();

  // Drop now-unused `air.*` builtin declarations; the parameters replaced
  // every call, and stray unknown declarations have no place in AIR.
  llvm::SmallVector<llvm::Function *, 8> dead;
  for (llvm::Function &g : m)
    if (g.isDeclaration() && g.getName().starts_with("air.") && g.use_empty())
      dead.push_back(&g);
  for (llvm::Function *g : dead)
    g->eraseFromParent();
  return newFn;
}

// AIR runtime-function name mangling: the stdlib emits bare stems
// (`air.simd_shuffle_xor`); AIR's real functions carry type suffixes
// (`air.simd_shuffle_xor.u.i32`, `.f32`, `.f16` — from golden MSL probes).
// Integers use the unsigned spelling: shuffles move bits, not values.
std::optional<std::string> airTypeSuffix(llvm::Type *ty) {
  if (ty->isFloatTy())
    return ".f32";
  if (ty->isHalfTy())
    return ".f16";
  if (auto *it = llvm::dyn_cast<llvm::IntegerType>(ty)) {
    switch (it->getBitWidth()) {
    case 8:
      return ".u.i8";
    case 16:
      return ".u.i16";
    case 32:
      return ".u.i32";
    case 64:
      return ".u.i64";
    }
  }
  if (auto *vt = llvm::dyn_cast<llvm::FixedVectorType>(ty)) {
    if (auto inner = airTypeSuffix(vt->getElementType())) {
      std::string s = *inner;
      // ".f16" -> ".v2f16" style; ".u.i32" -> ".u.v2i32"
      size_t lastDot = s.rfind('.');
      return s.substr(0, lastDot + 1) + "v" +
             std::to_string(vt->getNumElements()) + s.substr(lastDot + 1);
    }
  }
  return std::nullopt;
}

// AIR runtime functions carry a type suffix; the stdlib emits bare stems.
// The math family additionally has a `fast_` variant selected by fast-math,
// which we do not enable, so the plain spelling is correct here.
bool needsAirTypeSuffix(llvm::StringRef name) {
  static const llvm::StringRef stems[] = {
      // shuffles / simd-group ops. Kept in sync with AirLowering.cpp's copy,
      // which carries the golden-sample evidence for these names.
      // `air.simd_prefix_sum` was wrong in both lists -- AIR spells them
      // air.simd_prefix_exclusive_sum / air.simd_prefix_inclusive_sum.
      "air.simd_shuffle_xor", "air.simd_shuffle_down", "air.simd_shuffle_up",
      "air.simd_shuffle", "air.simd_sum",
      "air.simd_prefix_exclusive_sum", "air.simd_prefix_inclusive_sum",
      "air.simd_min", "air.simd_max", "air.simd_product",
      // math
      "air.cos", "air.sin", "air.tan", "air.acos", "air.asin", "air.atan",
      "air.cosh", "air.sinh", "air.tanh", "air.exp", "air.exp2", "air.exp10",
      "air.log", "air.log2", "air.log10", "air.sqrt", "air.rsqrt",
      "air.fabs", "air.floor", "air.ceil", "air.rint", "air.trunc",
      "air.round", "air.fmin", "air.fmax", "air.fma", "air.pow", "air.powr",
      "air.fmod", "air.copysign", "air.frac", "air.divide", "air.recip"};
  for (llvm::StringRef stem : stems)
    if (name == stem)
      return true;
  return false;
}

// LLVM-style overload mangling, which is what AIR uses for the
// simdgroup_matrix family: v64f32, v8f16, bf16, i8.
std::optional<std::string> airLLVMTypeMangle(llvm::Type *ty) {
  if (ty->isFloatTy())
    return std::string("f32");
  if (ty->isHalfTy())
    return std::string("f16");
  if (ty->isBFloatTy())
    return std::string("bf16");
  if (auto *it = llvm::dyn_cast<llvm::IntegerType>(ty))
    return "i" + std::to_string(it->getBitWidth());
  if (auto *vt = llvm::dyn_cast<llvm::FixedVectorType>(ty))
    if (auto inner = airLLVMTypeMangle(vt->getElementType()))
      return "v" + std::to_string(vt->getNumElements()) + *inner;
  return std::nullopt;
}

bool isSimdgroupMatrixMMA(llvm::StringRef name) {
  return name.starts_with("air.simdgroup_matrix_") &&
         name.contains("multiply_accumulate");
}

// The simdgroup_matrix MMA family carries a full signature in its name, not
// the single payload suffix the other AIR builtins use, and the 16x16x16 form
// additionally encodes its transpose flags there.
//
// Golden-sampled with `xcrun metal -S -emit-llvm` on MSL simdgroup ops:
//
//   air.simdgroup_matrix_8x8_multiply_accumulate.v64f32.v64f16.v64f16.v64f32
//     <64 x float> (<64 x half>, <64 x half>, <64 x float>)
//   ...v64f32.v64bf16.v64bf16.v64f32     ...v64f32.v64f32.v64f32.v64f32
//
// and from Modular's compiler for the 16x16x16 form our stdlib calls:
//
//   air.simdgroup_matrix_16x16x16_multiply_accumulate.f.f.v8f32.v8f16.v8f16.v8f32
//     <8 x float> (<8 x half>, i1, <8 x half>, i1, <8 x float>)
//
// so the shape is  .[<transA>.<transB>.]<ret>.<A>.<B>.<C>  -- flags rendered
// f/t, kept as i1 operands but EXCLUDED from the type list.
//
// This runs on LLVM IR rather than in AirLowering because the flags have to
// be constants to be named at all, and they are not constants until the
// llvm_intrinsic wrapper has been inlined.
std::optional<std::string> simdgroupMatrixSuffix(llvm::CallInst *call) {
  std::string flags, types;
  for (llvm::Value *arg : call->args()) {
    if (arg->getType()->isIntegerTy(1)) {
      auto *c = llvm::dyn_cast<llvm::ConstantInt>(arg);
      if (!c)
        return std::nullopt; // a runtime transpose cannot be named
      flags += c->isZero() ? ".f" : ".t";
      continue;
    }
    auto m = airLLVMTypeMangle(arg->getType());
    if (!m)
      return std::nullopt;
    types += "." + *m;
  }
  auto ret = airLLVMTypeMangle(call->getType());
  if (!ret)
    return std::nullopt;
  return flags + "." + *ret + types;
}

// AIR has no native int<->float cast instructions: every conversion goes
// through an air.convert.* call. Apple emits ZERO sitofp/uitofp/fptosi/fptoui
// for a kernel that does all four, and the wheel does the same for the very
// kernel that made us look (test_mandelbrot).
//
// Leaving them native does not fail cleanly. metallib accepts the module and
// the Metal compiler SERVICE dies at pipeline creation with
// XPC_ERROR_CONNECTION_INTERRUPTED, naming nothing.
//
// Naming, golden-sampled with `xcrun metal -S -emit-llvm` on a kernel casting
// scalars and vectors both ways:
//
//   air.convert.f.f32.s.i32     air.convert.s.i32.f.f32
//   air.convert.f.f32.u.i32     air.convert.u.i32.f.f32
//   air.convert.f.v4f32.s.v4i32 air.convert.s.v4i32.f.v4f32
//
// i.e. air.convert.<dstKind>.<dstTy>.<srcKind>.<srcTy>, kind in {f,s,u} and
// types in the same overload mangling the simdgroup family uses.
void lowerIntFloatConverts(llvm::Module &m) {
  llvm::SmallVector<llvm::CastInst *, 8> casts;
  for (llvm::Function &fn : m) {
    if (fn.isDeclaration())
      continue;
    for (llvm::BasicBlock &bb : fn)
      for (llvm::Instruction &inst : bb)
        if (auto *ci = llvm::dyn_cast<llvm::CastInst>(&inst))
          switch (ci->getOpcode()) {
          case llvm::Instruction::SIToFP:
          case llvm::Instruction::UIToFP:
          case llvm::Instruction::FPToSI:
          case llvm::Instruction::FPToUI:
            casts.push_back(ci);
            break;
          case llvm::Instruction::FPExt:
          case llvm::Instruction::FPTrunc:
            // VECTOR float<->float only. Apple splits these: a scalar
            // half/bfloat <-> float stays a native fpext/fptrunc, while the
            // vector form becomes a call. Golden sample of a kernel doing
            // four scalar and four vector fp conversions emits exactly four
            // native casts and four air.convert:
            //
            //   air.convert.f.v4f32.f.v4bf16   air.convert.f.v4bf16.f.v4f32
            //   air.convert.f.v4f32.f.v4f16    air.convert.f.v4f16.f.v4f32
            //
            // This is what broke rms_norm on bfloat16 while every float32
            // case passed: an f32-only kernel has no fp<->fp conversion to
            // get wrong, and the bf16 path widens <8 x bfloat> to <8 x float>
            // to accumulate. Modular emits the calls; we emitted a native
            // vector fptrunc/fpext, which the driver does not compute
            // correctly -- no crash, no invalid IR, just wrong numbers.
            if (ci->getType()->isVectorTy())
              casts.push_back(ci);
            break;
          default:
            break;
          }
  }
  for (llvm::CastInst *ci : casts) {
    llvm::Type *dstTy = ci->getType();
    llvm::Type *srcTy = ci->getOperand(0)->getType();
    auto dst = airLLVMTypeMangle(dstTy);
    auto src = airLLVMTypeMangle(srcTy);
    if (!dst || !src)
      continue; // leave it; better a known-shape failure than a wrong symbol
    llvm::StringRef dstKind, srcKind;
    switch (ci->getOpcode()) {
    case llvm::Instruction::SIToFP: dstKind = "f"; srcKind = "s"; break;
    case llvm::Instruction::UIToFP: dstKind = "f"; srcKind = "u"; break;
    case llvm::Instruction::FPToSI: dstKind = "s"; srcKind = "f"; break;
    case llvm::Instruction::FPToUI: dstKind = "u"; srcKind = "f"; break;
    // fp<->fp: both sides are "f".
    default:                        dstKind = "f"; srcKind = "f"; break;
    }
    std::string name = ("air.convert." + dstKind + "." + *dst + "." + srcKind +
                        "." + *src).str();
    llvm::FunctionCallee fn = m.getOrInsertFunction(
        name, llvm::FunctionType::get(dstTy, {srcTy}, false));
    if (auto *decl = llvm::dyn_cast<llvm::Function>(fn.getCallee())) {
      decl->setDoesNotThrow();
      decl->setWillReturn();
      decl->setMustProgress();
      decl->setUnnamedAddr(llvm::GlobalValue::UnnamedAddr::Local);
    }
    llvm::IRBuilder<> b(ci);
    llvm::Value *call = b.CreateCall(fn, {ci->getOperand(0)});
    ci->replaceAllUsesWith(call);
    ci->eraseFromParent();
  }
}

// Vector fma must be air.fma.<ty>, not llvm.fma.<ty>.
//
// Apple's own compiler emits `air.fma.v4f32` for a float4 fma and keeps the
// LLVM intrinsic only for scalars -- the released compiler emits
// `llvm.fma.f32` and the reader accepts it. So the split is by width, exactly
// as it is for the fp<->fp converts above.
//
// A vector `llvm.fma` survives `metallib` and then kills the compiler service
// at pipeline creation with XPC_ERROR_CONNECTION_INTERRUPTED, naming no
// function and no instruction -- the symptom diagnostics.md tells you to read
// as a wrong symbol name before anything else. Found on test_mandelbrot by
// listing the module's declared symbols and diffing them against what
// `xcrun metal` emits for the same source.
//
// Only llvm.fma is handled here because that is what we were measured to
// emit. llvm.fmuladd would presumably need the same treatment; it has not
// been seen, so it is not guessed at.
// Erase LLVM intrinsic declarations nothing calls any more.
//
// Every lowering here works by replacing calls and leaving the old
// declaration behind, and that is not harmless: the AIR reader resolves each
// declared symbol, so a dead `declare <4 x i64> @llvm.stepvector.v4i64()` or
// `declare <4 x float> @llvm.fma.v4f32(...)` is as fatal as a live call --
// and much harder to spot, because nothing in the IR uses it. Both cost a
// separate diagnosis on test_mandelbrot before the pattern was obvious: the
// symbol list is what to look at, not the instruction stream.
//
// Restricted to llvm.* intrinsics. An unused air.* declaration names a
// function Apple actually provides, so it resolves.
// Lower InstCombine's mask-to-bitmask idiom, which asks for a type no GPU has.
//
// `if any(v < 4.0)` over a float4 becomes, after InstCombine:
//
//     %m  = fcmp ole <4 x float> %x, splat (float 4.0)
//     %b  = bitcast <4 x i1> %m to i4          ; <-- i4
//     %z  = icmp eq i4 %b, 0
//
// which is ordinary LLVM and completely legal. `i4` is not a register width
// any GPU implements, and AIR is no exception. Nothing catches it: the module
// verifies, `metallib` packages it, and `air-opt` is silent -- all three only
// check form. It fails when the metallib is compiled to a pipeline state, and
// the Metal compiler *service* is what dies, so the error surfaces as
// XPC_ERROR_CONNECTION_INTERRUPTED with no function, no instruction, and no
// hint that a type is involved.
//
// The comparison against zero is the whole point of the bitcast -- "no lane
// set" / "any lane set" -- so rewrite the pair as an OR reduction over the
// lanes and never materialise the odd-width integer. Only rewritten when
// every user is such a comparison; anything else is left alone, because a
// known-shape failure beats silently wrong code.
void lowerMaskBitcasts(llvm::Module &m) {
  using namespace llvm::PatternMatch;
  llvm::SmallVector<llvm::BitCastInst *, 8> dead;
  for (llvm::Function &fn : m)
    for (llvm::BasicBlock &bb : fn)
      for (llvm::Instruction &inst : bb) {
        auto *bc = llvm::dyn_cast<llvm::BitCastInst>(&inst);
        if (!bc)
          continue;
        auto *srcTy = llvm::dyn_cast<llvm::FixedVectorType>(bc->getSrcTy());
        auto *dstTy = llvm::dyn_cast<llvm::IntegerType>(bc->getDestTy());
        if (!srcTy || !dstTy || !srcTy->getElementType()->isIntegerTy(1))
          continue;
        if (dstTy->getBitWidth() != srcTy->getNumElements())
          continue;
        bool allZeroCompares = !bc->use_empty();
        for (llvm::User *u : bc->users()) {
          auto *cmp = llvm::dyn_cast<llvm::ICmpInst>(u);
          if (!cmp || !cmp->isEquality() ||
              !match(cmp->getOperand(1), m_Zero())) {
            allZeroCompares = false;
            break;
          }
        }
        if (allZeroCompares)
          dead.push_back(bc);
      }
  for (llvm::BitCastInst *bc : dead) {
    auto *srcTy = llvm::cast<llvm::FixedVectorType>(bc->getSrcTy());
    llvm::IRBuilder<> b(bc);
    // OR the lanes together: `any` is true iff the packed integer is nonzero.
    llvm::Value *any = b.CreateExtractElement(bc->getOperand(0), uint64_t(0));
    for (unsigned e = srcTy->getNumElements(), i = 1; i != e; ++i)
      any = b.CreateOr(any, b.CreateExtractElement(bc->getOperand(0), i));
    llvm::SmallVector<llvm::ICmpInst *, 4> cmps;
    for (llvm::User *u : bc->users())
      cmps.push_back(llvm::cast<llvm::ICmpInst>(u));
    for (llvm::ICmpInst *cmp : cmps) {
      llvm::IRBuilder<> cb(cmp);
      // `== 0` is "no lane set", `!= 0` is "any lane set".
      llvm::Value *rep = cmp->getPredicate() == llvm::CmpInst::ICMP_EQ
                             ? cb.CreateNot(any)
                             : any;
      cmp->replaceAllUsesWith(rep);
      cmp->eraseFromParent();
    }
    bc->eraseFromParent();
  }
}


void eraseDeadIntrinsicDeclarations(llvm::Module &m) {
  llvm::SmallVector<llvm::Function *, 8> dead;
  for (llvm::Function &fn : m)
    if (fn.isDeclaration() && fn.use_empty() && fn.isIntrinsic())
      dead.push_back(&fn);
  for (llvm::Function *fn : dead)
    fn->eraseFromParent();
}


void lowerVectorFMA(llvm::Module &m) {
  llvm::SmallVector<llvm::CallInst *, 8> calls;
  for (llvm::Function &fn : m)
    for (llvm::BasicBlock &bb : fn)
      for (llvm::Instruction &inst : bb) {
        auto *ci = llvm::dyn_cast<llvm::CallInst>(&inst);
        if (!ci || !ci->getCalledFunction())
          continue;
        if (ci->getCalledFunction()->getIntrinsicID() != llvm::Intrinsic::fma)
          continue;
        if (!ci->getType()->isVectorTy())
          continue;
        calls.push_back(ci);
      }
  for (llvm::CallInst *ci : calls) {
    llvm::Type *ty = ci->getType();
    auto mangled = airLLVMTypeMangle(ty);
    if (!mangled)
      continue; // better a known-shape failure than a wrong symbol
    std::string name = "air.fma." + std::string(*mangled);
    llvm::FunctionCallee fn = m.getOrInsertFunction(
        name, llvm::FunctionType::get(ty, {ty, ty, ty}, false));
    if (auto *decl = llvm::dyn_cast<llvm::Function>(fn.getCallee())) {
      decl->setDoesNotThrow();
      decl->setWillReturn();
      decl->setMustProgress();
      decl->setUnnamedAddr(llvm::GlobalValue::UnnamedAddr::Local);
    }
    llvm::IRBuilder<> b(ci);
    llvm::Value *call = b.CreateCall(
        fn, {ci->getArgOperand(0), ci->getArgOperand(1), ci->getArgOperand(2)});
    if (auto *newCall = llvm::dyn_cast<llvm::CallInst>(call))
      newCall->copyFastMathFlags(ci);
    ci->replaceAllUsesWith(call);
    ci->eraseFromParent();
  }
}

//===----------------------------------------------------------------------===//
// Gate 1 of 3: does the module satisfy LLVM's OWN rules?
//
// The AIR reader answers every kind of malformed input with the same few
// words -- "Invalid record", "Unexpected bitcode file!", or, once metallib
// has accepted it, XPC_ERROR_CONNECTION_INTERRUPTED from a compiler service
// that simply dies. None of them name a function or an instruction.
//
// A good share of what it was rejecting was not AIR-specific at all: it was
// IR that no reader accepts, ours included. `select` with mismatched pointer
// types and a same-address-space `addrspacecast` both reached metallib and
// came back as "Invalid record"; run through the verifier they are
//
//   both values to select must have same type
//
// which says where to look. So verify before serialising, and let the class
// of defect that is our own plain bug be reported as one.
//
// Gates 2 and 3 -- the bitstream record diff against Modular's output, and
// golden samples from `xcrun metal` -- cannot run in-process and live in
// spikes/air-gates.sh.
// Returns a diagnostic if the module is invalid, nullopt if it is clean.
// Returns a plain string rather than an Error so both error conventions in
// this file (llvm::Error in legalizeModule, KGEN Error in emitObject) can
// use it.

std::optional<std::string> verifyBeforeEmit(llvm::Module &m,
                                            llvm::StringRef stage) {
  std::string msg;
  llvm::raw_string_ostream os(msg);
  if (!llvm::verifyModule(m, &os)) {
    // Valid IR is not the same as legal AIR. See AirLegality.h: the LLVM
    // verifier is target-agnostic by construction and cannot see any of it.
    std::vector<Air::Finding> found = Air::checkLegality(m);
    std::string fatal;
    for (const Air::Finding &f : found) {
      if (f.action == Air::RuleAction::Fail)
        fatal += "  - [" + f.ruleId.str() + "] " + f.detail + "\n";
      else
        llvm::errs() << "[air-legality] " << f.ruleId << ": " << f.detail
                     << "\n";
    }
    if (fatal.empty())
      return std::nullopt;
    return ("AIR module is valid LLVM but illegal for the target after " +
            stage +
            ". These are target legality, not IR validity, so no verifier "
            "sees them and the reader reports only \"Invalid record\" or "
            "kills the compiler service at pipeline creation. Set "
            "APPLEGPU_AIR_RULES=<id>=log to downgrade one, or =list to see "
            "them all.\n" + fatal)
        .str();
  }
  return ("AIR module fails LLVM verification after " + stage +
          ". This is invalid IR, not an AIR restriction -- the AIR reader "
          "would report it only as \"Invalid record\". Verifier says:\n" +
          msg).str();
}

// Mark the cross-lane and barrier families `convergent`.
//
// Without it the optimiser believes the call has no cross-thread meaning and
// may sink it, hoist it, duplicate it, or move it across divergent control
// flow. For a shuffle that silently changes which lanes take part; for a
// BARRIER it means threads proceed before the threadgroup has finished
// writing shared memory.
//
// That is not theoretical. test_matmul_1_sram tiles through threadgroup
// memory with barrier() either side of the accumulate, and produced results
// that depended on the ROW and nothing else -- 360 at row 503, 359 at 504,
// one less per row -- which is the signature of threads reading a partially
// written tile. Our `air.wg.barrier` declaration carried no attributes at all.
//
// Which families get it is measured, not guessed. From `xcrun metal -S
// -emit-llvm` on a kernel using all of them at once:
//
//   air.fast_sqrt.f32         mustprogress nofree nosync nounwind readnone willreturn
//   air.fast_fabs.f32         (same -- math is NOT convergent)
//   air.wg.barrier            convergent mustprogress nounwind willreturn
//   air.simdgroup.barrier     convergent mustprogress nounwind willreturn
//   air.simd_shuffle_xor.f32  convergent mustprogress nounwind willreturn
//   air.simd_sum.f32          convergent mustprogress nounwind willreturn
//
// Memory effects are deliberately NOT set here. `readnone` is the attribute
// whose modern spelling the AIR reader predates, and math already works
// without it; adding it would trade a fixed miscompile for a rejected module.
// Drop the per-signature tag before emission. This is the real AIR symbol.
//
// AirLowering suffixes every `llvm.air.*` declaration with `$<hash>` so that
// distinct operand signatures cannot collide on one symbol during MLIR
// translation. That tag is an internal device and must never reach the
// driver: `air.wg.barrier$FBACEBCDEBF03022` is a name Apple has never heard
// of.
//
// mangleAirOps already strips it for the families it renames -- the converts
// and the simdgroup matrix ops -- which is why those come out clean. Anything
// it does NOT rename kept the tag all the way into the metallib. The barrier
// is the important case: an unresolvable barrier is not a link error, it is a
// barrier that does not synchronise, and test_matmul_1_sram was reading
// partially written threadgroup memory because of it.
//
// Two symbols reduced to the same stem would be a genuine AIR-level conflict
// -- AIR defines one signature per name -- so that is diagnosed rather than
// silently merged.
llvm::Error stripAirSignatureTags(llvm::Module &m) {
  llvm::SmallVector<llvm::Function *, 8> tagged;
  for (llvm::Function &fn : m)
    if (fn.getName().starts_with("air.") && fn.getName().contains('$'))
      tagged.push_back(&fn);
  for (llvm::Function *fn : tagged) {
    std::string stem = airStem(fn->getName()).str();
    if (llvm::Function *existing = m.getFunction(stem)) {
      if (existing->getFunctionType() != fn->getFunctionType())
        return llvm::createStringError(
            llvm::inconvertibleErrorCode(),
            "two AIR declarations reduce to '%s' with different signatures; "
            "AIR defines one signature per symbol, so one of them is wrong",
            stem.c_str());
      fn->replaceAllUsesWith(existing);
      fn->eraseFromParent();
      continue;
    }
    fn->setName(stem);
  }
  return llvm::Error::success();
}


bool isConvergentAirOp(llvm::StringRef name) {
  return name == "air.wg.barrier" || name == "air.simdgroup.barrier" ||
         name.starts_with("air.simd_") || name.starts_with("air.quad_") ||
         name.starts_with("air.simdgroup_matrix_");
}


/// Give AIR kernels the function attributes Apple's own toolchain sets.
///
/// Our kernels carried NONE. Dumping the final AIR for the same source through
/// this backend and through Modular's shipping 26.5.0 release, upstream's
/// kernel `define` reads
///
///   mustprogress nofree norecurse nosync nounwind willreturn
///   "approx-func-fp-math"="true" "no-infs-fp-math"="true"
///   "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true"
///   "no-trapping-math"="true" "unsafe-fp-math"="true"
///   "memory"="argmem: readwrite" "metal.kernel"="true"
///   "min-legal-vector-width"="0" "no-builtins"
///
/// and ours read `define void @kernel(...) {` with no attribute group at all.
///
/// The fast-math set is not an optimisation we are choosing to enable, it is
/// the semantics Metal already has: MSL compiles with fast math unless the
/// author opts out, so a kernel WITHOUT these attributes asks Apple's backend
/// to preserve strict IEEE behaviour it was never promised -- forbidding
/// reassociation and constraining scheduling for no benefit.
///
/// The `metal.thread_*_idx` attributes are deliberately NOT set here: they map
/// a parameter position to a thread-builtin, our parameter layout differs from
/// upstream's, and `!air.kernel` argument metadata already conveys it. Getting
/// them wrong would be worse than omitting them.
/// Whether `fn` can reach a convergent AIR operation, through any depth of
/// call in this module. An indirect call counts: it cannot be proved not to.
static bool
reachesConvergentAirOp(const llvm::Function &fn,
                       llvm::SmallPtrSetImpl<const llvm::Function *> &seen) {
  if (!seen.insert(&fn).second)
    return false;
  for (const llvm::BasicBlock &bb : fn)
    for (const llvm::Instruction &inst : bb) {
      const auto *call = llvm::dyn_cast<llvm::CallBase>(&inst);
      if (!call)
        continue;
      const llvm::Function *callee = call->getCalledFunction();
      if (!callee)
        return true;
      if (isConvergentAirOp(callee->getName()) ||
          callee->hasFnAttribute(llvm::Attribute::Convergent))
        return true;
      if (!callee->isDeclaration() && reachesConvergentAirOp(*callee, seen))
        return true;
    }
  return false;
}

static void applyAirKernelFnAttributes(llvm::Function &fn) {
  fn.setMustProgress();
  fn.setDoesNotThrow();
  fn.setWillReturn();
  fn.setDoesNotFreeMemory();
  fn.addFnAttr(llvm::Attribute::NoRecurse);
  // `nosync` asserts the function performs NO cross-thread synchronisation.
  // A kernel reaching air.wg.barrier or a simdgroup op does exactly that, and
  // claiming otherwise licenses the downstream AIR reader to move memory
  // operations across the barrier -- undoing the reason those ops are marked
  // convergent in the first place. Upstream's dumped kernel carries nosync
  // because that particular kernel has no barrier, not because every kernel
  // may claim it.
  llvm::SmallPtrSet<const llvm::Function *, 16> seen;
  if (!reachesConvergentAirOp(fn, seen))
    fn.addFnAttr(llvm::Attribute::NoSync);
  fn.addFnAttr("no-builtins");
  fn.addFnAttr("min-legal-vector-width", "0");
  fn.addFnAttr("metal.kernel", "true");
  fn.addFnAttr("approx-func-fp-math", "true");
  fn.addFnAttr("no-infs-fp-math", "true");
  fn.addFnAttr("no-nans-fp-math", "true");
  fn.addFnAttr("no-signed-zeros-fp-math", "true");
  fn.addFnAttr("no-trapping-math", "true");
  fn.addFnAttr("unsafe-fp-math", "true");
}

void applyAirCallAttributes(llvm::Module &m) {
  for (llvm::Function &fn : m) {
    if (!fn.isDeclaration() || !isConvergentAirOp(fn.getName()))
      continue;
    fn.setConvergent();
    fn.setDoesNotThrow();
    fn.setWillReturn();
    fn.setMustProgress();
    // Call sites carry their own copy of the attributes, and it is the CALL
    // the optimiser consults when deciding whether it may move something.
    for (llvm::User *u : fn.users())
      if (auto *cb = llvm::dyn_cast<llvm::CallBase>(u)) {
        cb->setConvergent();
        cb->setDoesNotThrow();
      }
  }
}


void mangleAirOps(llvm::Module &m) {
  llvm::SmallVector<llvm::CallInst *, 16> calls;
  for (llvm::Function &fn : m)
    for (llvm::BasicBlock &bb : fn)
      for (llvm::Instruction &inst : bb)
        if (auto *call = llvm::dyn_cast<llvm::CallInst>(&inst))
          if (llvm::Function *callee = call->getCalledFunction())
            if (needsAirTypeSuffix(airStem(callee->getName())) ||
                isSimdgroupMatrixMMA(airStem(callee->getName())))
              calls.push_back(call);
  for (llvm::CallInst *call : calls) {
    std::optional<std::string> suffix;
    if (isSimdgroupMatrixMMA(airStem(call->getCalledFunction()->getName()))) {
      suffix = simdgroupMatrixSuffix(call);
    } else {
      llvm::Type *keyTy = call->arg_size() ? call->getArgOperand(0)->getType()
                                           : call->getType();
      suffix = airTypeSuffix(keyTy);
    }
    if (!suffix)
      continue; // leaves the bare stem; fails loudly with a clear label
    // The tag comes off before the real suffix goes on.
    std::string mangled =
        (airStem(call->getCalledFunction()->getName()) + *suffix).str();
    llvm::FunctionCallee target = m.getOrInsertFunction(
        mangled, call->getFunctionType());
    // Match Apple's attribute set exactly. From golden samples of both
    // families (`xcrun metal -S -emit-llvm`):
    //
    //   declare float @air.simd_shuffle_xor.f32(float, i16) local_unnamed_addr #2
    //   declare <64 x float> @air.simdgroup_matrix_8x8_multiply_accumulate...  #2
    //   attributes #2 = { convergent mustprogress nounwind willreturn }
    //
    // Two corrections to what the fork set here:
    //
    //  - CONVERGENT was missing, and its absence is a latent miscompile
    //    independent of anything else. These are cross-lane operations; a
    //    shuffle or a simdgroup matmul is only meaningful with a defined set
    //    of participating lanes. Without `convergent` the optimiser is free
    //    to sink or hoist the call across divergent control flow and silently
    //    change which lanes take part.
    //
    //  - memory(none) is NOT what Apple emits, and it is the likelier half of
    //    "LLVM ERROR: Unexpected bitcode file!" from metallib: it is a modern
    //    memory-effects attribute whose bitcode encoding the AIR reader
    //    predates. The fork's rationale -- that without it the backend must
    //    assume the call clobbers memory -- is reasonable in the abstract and
    //    simply is not the trade Apple's own compiler makes.
    //
    // `nofree` also went, for the same reason: not in the golden sample.
    if (auto *decl = llvm::dyn_cast<llvm::Function>(target.getCallee())) {
      decl->setConvergent();
      decl->setDoesNotThrow();
      decl->setWillReturn();
      decl->setMustProgress();
      decl->setUnnamedAddr(llvm::GlobalValue::UnnamedAddr::Local);
    }
    call->setCalledFunction(target);
  }
}

// Device pointers captured in a kernel's packed argument buffer are loaded
// out of it as raw 64-bit addresses, i.e. as GENERIC (AS0) pointers. Apple
// silicon tolerates that — flat addressing — but AMD's Metal plugin must
// resolve every access to a buffer *resource descriptor* and null-derefs on
// a generic pointer: MTLCompilerService dies with SIGSEGV in
// ILTargetLowering::getPtrRsrcId <- getRsrcDescNode <- LowerSTORE, which the
// runtime reports only as "Compilation failed due to an interrupted
// connection: XPC_ERROR_CONNECTION_INTERRUPTED".
//
// Retype such loads to device AS1 and propagate through their use graph.
// Rebuild any function whose arguments no longer match its own type.
//
// propagatePointerAS retypes a defined callee's parameter with
// Argument::mutateType, which changes the ARGUMENT but not the FunctionType
// the argument belongs to. The two then disagree and the module is invalid:
//
//   Argument value does not match function argument type!
//   ptr addrspace(1) %0
//    ptr
//
// LLVM has no way to mutate a FunctionType in place, so the function has to be
// rebuilt around the types its arguments now have: new Function, splice the
// body across, repoint the call sites, erase the old one.
//
// This is the fifth consumer in the table in address-spaces.md -- "defined
// callees: retype the parameter and recurse". The recursion was there; what
// was missing is that retyping a parameter is not a local edit either.
void rebuildMismatchedSignatures(llvm::Module &m) {
  llvm::SmallVector<llvm::Function *, 4> stale;
  for (llvm::Function &fn : m) {
    if (fn.isDeclaration())
      continue;
    llvm::FunctionType *fTy = fn.getFunctionType();
    bool mismatch = false;
    for (unsigned i = 0, e = fn.arg_size(); i != e && !mismatch; ++i)
      mismatch = fn.getArg(i)->getType() != fTy->getParamType(i);
    if (mismatch)
      stale.push_back(&fn);
  }
  for (llvm::Function *fn : stale) {
    llvm::SmallVector<llvm::Type *, 8> params;
    for (llvm::Argument &a : fn->args())
      params.push_back(a.getType());
    auto *newTy = llvm::FunctionType::get(fn->getReturnType(), params,
                                          fn->isVarArg());
    llvm::Function *nf = llvm::Function::Create(newTy, fn->getLinkage(),
                                                fn->getAddressSpace(), "", &m);
    nf->takeName(fn);
    nf->copyAttributesFrom(fn);
    nf->setComdat(fn->getComdat());
    nf->splice(nf->begin(), fn);
    for (unsigned i = 0, e = fn->arg_size(); i != e; ++i) {
      llvm::Argument *oldA = fn->getArg(i), *newA = nf->getArg(i);
      newA->takeName(oldA);
      oldA->replaceAllUsesWith(newA);
    }
    // Call sites carry their own copy of the callee type; leaving the old one
    // is the same defect BitcodeWriter17 hits as "Explicit call type does not
    // match pointee type of callee operand".
    llvm::SmallVector<llvm::CallBase *, 8> calls;
    for (llvm::User *u : fn->users())
      if (auto *cb = llvm::dyn_cast<llvm::CallBase>(u))
        calls.push_back(cb);
    for (llvm::CallBase *cb : calls)
      cb->setCalledFunction(newTy, nf);
    fn->replaceAllUsesWith(nf);
    fn->eraseFromParent();
  }
}


void deviceizeCapturedPointers(llvm::Module &m) {
  llvm::LLVMContext &c = m.getContext();
  for (llvm::Function &fn : m) {
    if (fn.isDeclaration())
      continue;
    llvm::SmallVector<llvm::Instruction *, 8> sources;
    for (llvm::BasicBlock &bb : fn)
      for (llvm::Instruction &inst : bb) {
        auto *resultTy = llvm::dyn_cast<llvm::PointerType>(inst.getType());
        if (!resultTy || resultTy->getAddressSpace() != 0)
          continue;
        // A pointer loaded out of the constant argument buffer (AS2) or out
        // of device memory (AS1) is itself a device pointer...
        if (auto *ld = llvm::dyn_cast<llvm::LoadInst>(&inst)) {
          auto *srcTy = llvm::dyn_cast<llvm::PointerType>(
              ld->getPointerOperand()->getType());
          if (srcTy && (srcTy->getAddressSpace() == 2 ||
                        srcTy->getAddressSpace() == 1))
            sources.push_back(ld);
        }
        // A pointer pulled out of a capture struct with extractvalue. The
        // fork did not handle these here -- the hoisting pass in
        // legalizeKernel rewrote them into real buffer parameters instead,
        // because AMD needs a bound resource and not merely a device-space
        // address. That pass is gone on Apple Silicon (it burns one of the
        // 31 buffer slots per captured pointer), so the address space has to
        // be corrected here instead.
        //
        // The aggregate is the capture blob, which legalizeKernel has already
        // turned into an AS2 `constant T&` param loaded at entry -- so the
        // extracted pointer is a device pointer, exactly as Apple's own
        // compiler types it (`%struct.Caps = type { float addrspace(1)*, .. }`).
        if (auto *ev = llvm::dyn_cast<llvm::ExtractValueInst>(&inst)) {
          llvm::Value *agg = ev->getAggregateOperand();
          // Walk the aggregate chain to its root before judging it. A
          // descriptor blob holding several tensors arrives as a struct of
          // structs, and the frontend pulls the per-tensor struct out first
          // and its pointer out second -- so the aggregate here is usually
          // another extractvalue, not the load. Testing only the immediate
          // aggregate deviceized whichever pointer the frontend happened to
          // extract in one step and left every other one generic, which on
          // AIR means it is not addressable at all: the kernel's stores went
          // to addrspace(1) and its loads to addrspace(0), so writes landed
          // and reads returned zero. That is a whole output buffer of zeroes
          // with nothing reported anywhere.
            // ...and the chain is not always a straight line. A kernel choosing
            // between two descriptors emits `select` on the WHOLE struct, and a
            // loop-carried one emits `phi`; the pointer is extracted from that. So
            // the walk has to branch, and a value counts only if EVERY root reaching
            // it is constant-buffer derived -- one non-buffer root and this is not
            // necessarily a device address.
            //
            // Third shape of the same defect (direct load, nested extractvalue, now
            // select/phi). address-spaces.md says it plainly: write one of these and
            // you must write all of them, or they surface weeks apart.
            std::function<bool(llvm::Value *, unsigned)> rootsAreBuffer =
                [&](llvm::Value *v, unsigned depth) -> bool {
              if (depth > 16)
                return false; // give up rather than chase a cycle
              if (llvm::isa<llvm::Argument>(v))
                return true;
              if (auto *ld = llvm::dyn_cast<llvm::LoadInst>(v)) {
                auto *srcTy = llvm::dyn_cast<llvm::PointerType>(
                    ld->getPointerOperand()->getType());
                return srcTy && (srcTy->getAddressSpace() == 2 ||
                                 srcTy->getAddressSpace() == 1);
              }
              if (auto *outer = llvm::dyn_cast<llvm::ExtractValueInst>(v))
                return rootsAreBuffer(outer->getAggregateOperand(), depth + 1);
              if (auto *sel = llvm::dyn_cast<llvm::SelectInst>(v))
                return rootsAreBuffer(sel->getTrueValue(), depth + 1) &&
                       rootsAreBuffer(sel->getFalseValue(), depth + 1);
              if (auto *phi = llvm::dyn_cast<llvm::PHINode>(v)) {
                for (llvm::Value *in : phi->incoming_values())
                  if (!rootsAreBuffer(in, depth + 1))
                    return false;
                return phi->getNumIncomingValues() > 0;
              }
              if (auto *ins = llvm::dyn_cast<llvm::InsertValueInst>(v))
                return rootsAreBuffer(ins->getAggregateOperand(), depth + 1);
              return false;
            };
            if (rootsAreBuffer(agg, 0))
              sources.push_back(ev);
        }
      }
    for (llvm::Instruction *src : sources) {
      // Round-trip through an integer rather than addrspacecast'ing.
      //
      // The fork used addrspacecast here, on the grounds that inttoptr
      // destroys the pointer provenance AMD's getPtrRsrcId needs to find a
      // buffer resource. That is an AMD constraint and it does not apply to
      // Apple Silicon, where the reverse is true: an integer round trip is
      // Apple's OWN idiom and addrspacecast is not used at all.
      //
      // Golden samples say so plainly. Casting a raw 64-bit address to a
      // device pointer in MSL:
      //
      //   %6 = inttoptr i64 %5 to float addrspace(1)*
      //
      // and across every sample taken from `xcrun metal -S -emit-llvm` --
      // plain buffers, capture structs with device pointers, raw-address
      // deref, simd ops -- there are ZERO addrspacecast instructions and ZERO
      // addrspace(0) pointers. AIR has no generic address space to cast from,
      // so a generic->device addrspacecast is a construct Apple's own
      // compiler never emits, and the value it produced did not address
      // device memory: test_function_mts wrote a grid of zeroes through one.
      llvm::Instruction *insertPt = src->getNextNode();
      if (!insertPt)
        continue;
      llvm::IRBuilder<> b(insertPt);
      llvm::Value *asInt = b.CreatePtrToInt(src, llvm::Type::getInt64Ty(c),
                                            src->getName() + ".addr");
      llvm::Value *cast = b.CreateIntToPtr(
          asInt, llvm::PointerType::get(c, 1), src->getName() + ".dev");
      // replaceUsesWithIf demands identical types, which an addrspacecast
      // deliberately does not have; rewrite the uses directly.
      // Skip BOTH instructions we just created. `asInt` is the one that
      // consumes `src` now; rewriting its operand to `cast` would make the
      // ptrtoint feed on the inttoptr derived from it -- a cycle.
      llvm::SmallVector<llvm::Use *, 8> uses;
      for (llvm::Use &u : src->uses())
        if (u.getUser() != cast && u.getUser() != asInt)
          uses.push_back(&u);
      for (llvm::Use *u : uses)
        u->set(cast);
      llvm::SmallVector<llvm::Value *, 16> retype{cast};
      propagatePointerAS(retype);
    }
  }
}

// Full-module AIR legalization.
// Remove addrspacecasts whose source and destination address space are the
// same. Such a cast is the identity, and it is invalid IR -- LLVM requires
// the two spaces to differ -- so the AIR reader refuses the whole module:
//
//   air-opt: applegpu-kernel.air: error: Invalid cast
//   xcrun metallib: LLVM ERROR: Unexpected bitcode file!
//
// which names neither the instruction nor the function, and so reads like a
// corrupt file rather than one bad cast.
//
// They arrive from the frontend, not from anything here: the stdlib writes
// `unsafe_address_space_cast[target_space]()` (see
// max/mojo/max/gpu/memory/masked_load_apple.mojo) and nothing requires the
// target to differ from the source, so a GLOBAL->GLOBAL cast is a perfectly
// ordinary thing for it to emit. NVPTX and AMDGPU fold it away; Apple's
// LLVM-17-era reader validates first and rejects.
//
// Verified against the oracle: Modular's own compiler emits no such cast for
// the same source, going straight to a `bitcast ... to i8 addrspace(1)*`.
void dropNoOpAddrSpaceCasts(llvm::Module &m) {
  for (llvm::Function &fn : m) {
    if (fn.isDeclaration())
      continue;
    llvm::SmallVector<llvm::AddrSpaceCastInst *, 8> dead;
    for (llvm::BasicBlock &bb : fn)
      for (llvm::Instruction &inst : bb)
        if (auto *asc = llvm::dyn_cast<llvm::AddrSpaceCastInst>(&inst))
          if (asc->getSrcAddressSpace() == asc->getDestAddressSpace())
            dead.push_back(asc);
    for (llvm::AddrSpaceCastInst *asc : dead) {
      asc->replaceAllUsesWith(asc->getPointerOperand());
      asc->eraseFromParent();
    }
  }
}

// Inline every internal helper before anything else looks at the module.
//
// AIR has no call stack and Metal kernels are fully inlined regardless, so
// this costs nothing -- but doing it FIRST rather than after legalisation
// removes a whole class of defect that has now bitten three separate times:
//
//   - deviceizeCapturedPointers never saw code that inlining brought in later,
//     leaving device pointers generic (reads returned zero, silently);
//   - propagatePointerAS retyped a defined callee's parameter, which leaves
//     the enclosing FunctionType behind and the module invalid;
//   - a kernel using threadgroup memory THROUGH a helper could not have the
//     global rewritten to a parameter, because the argument does not exist
//     inside the callee.
//
// Every one of those is "the code moved after I legalised it". Inline first
// and the question does not arise.
void inlineInternalHelpers(llvm::Module &m) {
  for (llvm::Function &fn : m)
    if (!fn.isDeclaration() && fn.hasLocalLinkage()) {
      fn.removeFnAttr(llvm::Attribute::NoInline);
      fn.addFnAttr(llvm::Attribute::AlwaysInline);
    }
  llvm::PassBuilder pb;
  llvm::LoopAnalysisManager lam;
  llvm::FunctionAnalysisManager fam;
  llvm::CGSCCAnalysisManager cgam;
  llvm::ModuleAnalysisManager mam;
  pb.registerModuleAnalyses(mam);
  pb.registerCGSCCAnalyses(cgam);
  pb.registerFunctionAnalyses(fam);
  pb.registerLoopAnalyses(lam);
  pb.crossRegisterProxies(lam, fam, cgam, mam);
  llvm::ModulePassManager mpm;
  mpm.addPass(llvm::AlwaysInlinerPass());
  mpm.run(m, mam);
}

llvm::Error legalizeModule(llvm::Module &m) {
  // Resolve the target profile FIRST. The triple and every version stamp are
  // derived from it, and scrub() later strips `target-cpu`, which is where the
  // frontend leaves the selected arch (`metal:4` is normalised to `apple-m4`
  // upstream, so what arrives here is always the family form).
  llvm::StringRef arch;
  for (llvm::Function &fn : m)
    if (!fn.isDeclaration()) {
      arch = fn.getFnAttribute("target-cpu").getValueAsString();
      break;
    }
  bool unverifiedProfile = false;
  std::optional<Air::TargetProfile> profileOr =
      Air::profileForArch(arch, unverifiedProfile);
  if (!profileOr)
    return llvm::createStringError(
        llvm::inconvertibleErrorCode(),
        "no Apple AIR target profile for arch '%s'; expected apple-m1..apple-m5, "
        "optionally suffixed with a language profile (e.g. apple-m4-metal4)",
        arch.str().c_str());
  if (unverifiedProfile)
    return llvm::createStringError(
        llvm::inconvertibleErrorCode(),
        "AIR language profile '%s' has never been checked against a golden "
        "sample from an installed toolchain, so its SDK and deployment "
        "versions would be invented. Sample one with `xcrun metal -S "
        "-emit-llvm` and fill in AirTargetProfile.h before selecting it",
        profileOr->lang.name.str().c_str());
  const Air::TargetProfile &profile = *profileOr;
  if (::getenv("APPLEGPU_TRACE_PROFILE"))
    llvm::errs() << "[air-profile] " << profile.describe() << "\n";

  inlineInternalHelpers(m);
  llvm::LLVMContext &c = m.getContext();
  m.setTargetTriple(llvm::Triple(profile.triple()));
  lowerVectorFMA(m);
  lowerMaskBitcasts(m);
  // Table-driven transforms, all off by default (APPLEGPU_AIR_XFORMS).
  Air::applyTransforms(m);
  mangleAirOps(m);
  if (llvm::Error err = stripAirSignatureTags(m))
    return err;
  applyAirCallAttributes(m);
  eraseDeadIntrinsicDeclarations(m);
  lowerIntFloatConverts(m);
  remapAddressSpaces(m);
  deviceizeCapturedPointers(m);
  // After deviceize, which can leave a cast redundant by moving its
  // operand into the space it was casting to.
  refreshOverloadedMemIntrinsics(m);

  // Metal has no 64-bit floats anywhere (MSL has no `double`); emitting the
  // type produces bitcode the AIR reader rejects opaquely. Diagnose cleanly.
  for (llvm::Function &fn : m) {
    if (fn.isDeclaration())
      continue;
    for (llvm::BasicBlock &bb : fn)
      for (llvm::Instruction &inst : bb) {
        // Types Metal/AIR simply does not have. Emitting them yields
        // bitcode the driver rejects opaquely ("Compilation failed due to
        // an interrupted compilation"); diagnose at the source instead.
        auto unsupported = [](llvm::Type *ty) -> const char * {
          llvm::Type *scalar = ty->isVectorTy() ? ty->getScalarType() : ty;
          if (scalar->isDoubleTy() || scalar->isFP128Ty() ||
              scalar->isX86_FP80Ty())
            return "float64/float128";
          if (auto *it = llvm::dyn_cast<llvm::IntegerType>(scalar))
            if (it->getBitWidth() > 64)
              return "integers wider than 64 bits";
          return nullptr;
        };
        const char *bad = unsupported(inst.getType());
        for (llvm::Value *operand : inst.operands())
          if (!bad)
            bad = unsupported(operand->getType());
        if (bad)
          return llvm::createStringError(
              llvm::inconvertibleErrorCode(),
              "%s not supported on Metal/AIR (in kernel '%s'): Metal has "
              "neither a double nor a 128-bit integer type",
              bad, fn.getName().str().c_str());
      }
  }

  // Kernels: defined, externally-visible functions.
  llvm::SmallVector<llvm::Function *, 4> kernels;
  for (llvm::Function &fn : m)
    if (!fn.isDeclaration() && !fn.hasLocalLinkage())
      kernels.push_back(&fn);

  llvm::NamedMDNode *airKernels = m.getOrInsertNamedMetadata("air.kernel");
  for (llvm::Function *fn : kernels) {
    llvm::SmallVector<llvm::Metadata *, 8> argMD;
    llvm::Function *legal = legalizeKernel(*fn, argMD);
    legal->setCallingConv(llvm::CallingConv::C);
    if (airKnobEnabled("APPLEGPU_AIR_KERNEL_FN_ATTRS", false))
      applyAirKernelFnAttributes(*legal);
    airKernels->addOperand(llvm::MDNode::get(
        c, {llvm::ConstantAsMetadata::get(legal), llvm::MDNode::get(c, {}),
            llvm::MDNode::get(c, argMD)}));
  }

  // After legalizeKernel, not before it. Retyping a kernel's parameters to
  // their AIR address spaces turns casts that WERE meaningful into
  // same-space no-ops, so cleaning up earlier in this function missed every
  // one this loop had yet to create. Invisible until gate 1 started running
  // on canonical IR and reported "AddrSpaceCast must be between different
  // address spaces".
  // After the kernel loop, not before it: legalizeKernel is what retypes a
  // callee parameter, and Argument::mutateType leaves the enclosing
  // FunctionType behind. Reconcile the two before anything reads a signature.
  rebuildMismatchedSignatures(m);
  dropNoOpAddrSpaceCasts(m);

  // Module flags and AIR identification, per the golden sample.
  auto addFlag = [&](llvm::StringRef name, uint32_t value, uint32_t behavior) {
    m.addModuleFlag(static_cast<llvm::Module::ModFlagBehavior>(behavior), name,
                    value);
  };
  if (!m.getModuleFlag("wchar_size"))
    addFlag("wchar_size", 4, llvm::Module::Error);
  if (!m.getModuleFlag("frame-pointer"))
    addFlag("frame-pointer", 2, llvm::Module::Max);
  addFlag("air.max_device_buffers", profile.limits.deviceBuffers,
            llvm::Module::Max);
    addFlag("air.max_constant_buffers", profile.limits.constantBuffers,
            llvm::Module::Max);
    addFlag("air.max_threadgroup_buffers", profile.limits.threadgroupBuffers,
            llvm::Module::Max);
    addFlag("air.max_textures", profile.limits.textures, llvm::Module::Max);
    addFlag("air.max_read_write_textures", profile.limits.readWriteTextures,
            llvm::Module::Max);
    addFlag("air.max_samplers", profile.limits.samplers, llvm::Module::Max);
  if (!m.getModuleFlag("SDK Version")) {
    // Was {14, 2} for the fork's pinned Xcode 15.2. TODO: derive from the SDK
    // actually in use rather than pinning (`xcrun --show-sdk-version` reports
    // 26.0 here) -- pinned for now so bring-up has one variable fewer.
    llvm::SmallVector<uint32_t, 2> sdk = {26, 0};
    m.addModuleFlag(llvm::Module::Warning, "SDK Version",
                    llvm::ConstantDataArray::get(c, sdk));
  }

  auto setVersionMD = [&](llvm::StringRef name,
                          llvm::ArrayRef<llvm::Metadata *> elts) {
    llvm::NamedMDNode *node = m.getOrInsertNamedMetadata(name);
    if (node->getNumOperands() == 0)
      node->addOperand(llvm::MDNode::get(c, elts));
  };
  // AIR 2.8 / Metal 4.0 -- read off the golden sample, NOT guessed from
  // upstream's tables. std/gpu/host/info.mojo defines two profiles for every
  // Apple family: "+metal3_2,+air2_7_0" (named "M4") and "+metal4_0,+air2_8_0"
  // (named "M4 Metal4"). Picking the conservative one looked safe and was
  // wrong -- the Metal toolchain installed here
  // ("Apple metal version 32023.830") emits 2.8/4.0, and the triple above
  // agrees (`air64_v28`). Re-derive all three together after an Xcode update.
  setVersionMD("air.version", {mdI32(c, profile.lang.airMajor),
                               mdI32(c, profile.lang.airMinor),
                               mdI32(c, profile.lang.airPatch)});
  setVersionMD("air.language_version",
               {mdStr(c, "Metal"), mdI32(c, profile.lang.metalMajor),
                mdI32(c, profile.lang.metalMinor),
                mdI32(c, profile.lang.metalPatch)});
  setVersionMD("air.compile_options",
               {mdStr(c, "air.compile.denorms_disable")});
  setVersionMD("air.source_file_name", {mdStr(c, "mojo-kernel")});
  llvm::NamedMDNode *ident = m.getOrInsertNamedMetadata("llvm.ident");
  if (ident->getNumOperands() == 0)
    ident->addOperand(llvm::MDNode::get(
        c, {mdStr(c, "AIR backend (KGEN)")}));

  // The module is handed to Apple's clang-17-era `metal -x ir` as TEXT;
  // strip attributes whose llvm-22 textual spelling that parser rejects
  // (e.g. nocapture now prints as `captures(none)`, `range(...)` is new).
  auto scrub = [](llvm::Function &fn) {
    // Host-side target attributes are meaningless (and fatal) to the
    // driver's AIR->GCN compiler; the golden sample carries neither.
    fn.removeFnAttr("target-cpu");
    fn.removeFnAttr("target-features");
    fn.removeFnAttr("tune-cpu");
    // Only for functions that are NOT local. LLVM requires local linkage to
    // imply dso_local ("GlobalValue with local linkage or non-default
    // visibility must be dso_local!"), so clearing it unconditionally emitted
    // invalid IR for every internal helper -- print, the philox RNG, and so
    // on. The AIR reader tolerated it, so it passed unnoticed until gate 1
    // named it. The intent here is only to match the golden sample, which
    // carries no dso_local on its EXTERNAL declarations.
    if (!fn.hasLocalLinkage())
      fn.setDSOLocal(false);
    for (llvm::Argument &arg : fn.args()) {
      arg.removeAttr(llvm::Attribute::Captures);
      arg.removeAttr(llvm::Attribute::Range);
      arg.removeAttr(llvm::Attribute::Initializes);
      arg.removeAttr(llvm::Attribute::DeadOnUnwind);
      arg.removeAttr(llvm::Attribute::Writable);
    }
    fn.removeRetAttr(llvm::Attribute::Range);
  };
  for (llvm::Function &fn : m)
    scrub(fn);
  return llvm::Error::success();
}

//===----------------------------------------------------------------------===//
// Backend
//===----------------------------------------------------------------------===//

class AirBackend final : public TargetBackend {
public:
  const TargetTraits *traits() const override { return &AirTraits::get(); }

  SplitStrategy splitStrategy(const CompilationOptions &) const override {
    return SplitStrategy::PerExported;
  }
  bool isOffload() const override { return true; }
  bool isBaseTarget() const override { return false; }

  /// Verify that no AIR shim survived MLIR lowering. This USED to rewrite
  /// them, which was wrong twice over.
  ///
  /// AirLowering (KGENToLLVM/Target/Air) is the single owner of AIR
  /// declaration creation: it claims `llvm.air.*` in the module-scoped POP
  /// pass, unpacks operands, applies the type suffix and keys the symbol by
  /// signature. By the time the object backend sees the module the ops are
  /// already plain calls, so the walk below found nothing on real input --
  /// it ran before the lowering pipeline had created any CallIntrinsicOp.
  ///
  /// Worse, had it ever fired it would have looked a declaration up by NAME
  /// alone and reintroduced exactly the bare-symbol type collision
  /// AirLowering exists to prevent -- a dead fallback waiting to become
  /// live after an unrelated pipeline change. An object backend should not
  /// be reconstructing operation semantics from MLIR in the first place.
  ///
  /// So it verifies instead: reaching here means the target hooks did not
  /// run, and that is worth a hard, located failure rather than silent
  /// recovery.
  void
  prepareModuleForLowering(mlir::Operation *module,
                           const CompilationOptions &options) const override {
    auto moduleOp = llvm::dyn_cast<mlir::ModuleOp>(module);
    if (!moduleOp)
      return;
    moduleOp.walk([&](mlir::LLVM::CallIntrinsicOp op) {
      if (!op.getIntrin().starts_with("llvm.air."))
        return;
      op.emitError()
          << "AIR shim '" << op.getIntrin()
          << "' reached the object backend still as an llvm.call_intrinsic; "
             "AirLowering should have converted it in the module-scoped POP "
             "pass. The target lowering hook did not run for this module.";
    });
  }

  /// AIR has no LLVM codegen target. The TargetMachine (opt pipeline only —
  /// emission goes through emitObject/emitBitcode) is built for arm64, the
  /// same convention the upstream comment in CompilationOptions describes.
  CompilationOptions
  adjustOptionsForTargetMachine(const CompilationOptions &options,
                                llvm::StringRef moduleTriple) const override {
    CompilationOptions adjusted = options;
    adjusted.targetTriple = AirTraits::get().codegenTriple(moduleTriple);
    adjusted.targetCpu = "generic";
    adjusted.targetFeatures = "";
    return adjusted;
  }

protected:
  std::optional<unsigned> sharedMemoryAddressSpace() const override {
    return 3; // AIR threadgroup memory
  }

public:
  void emitBitcode(llvm::Module &module,
                   llvm::raw_pwrite_stream &os) const override {
    M::KGEN::LLVM::WriteBitcode17ToFile(module, os,
                               /*ShouldPreserveUseListOrder=*/false,
                               /*Index=*/nullptr, /*GenerateHash=*/false,
                               /*ModHash=*/nullptr);
  }

  ErrorOr<BufferRef> emitAssembly(llvm::Module &module,
                                  EmitContext &ctx) const override {
    // Legalized textual IR: the debugging/`--emit=asm` view of the AIR.
    if (llvm::Error err = legalizeModule(module))
      return Error("AIR legalization failed");
    WriteableBufferRef buf = WriteableBuffer::get();
    module.print(*buf, nullptr); // WriteableBuffer is a raw_pwrite_stream
    return buf;
  }

  ErrorOr<BufferRef> emitObject(llvm::Module &module,
                                EmitContext &ctx) const override {
    if (llvm::Error err = legalizeModule(module))
      return Error("AIR legalization failed");

    // Gate 1: verify while the IR is still CANONICAL -- after our own
    // legalization, before the downgrade pipeline.
    //
    // Not after the pipeline, which was the first placement and was wrong.
    // PointerRewriter deliberately rewrites pointers to TypedPointerType for
    // the LLVM-17 writer and (per MojoMacX64's triage) drops the
    // lifetime-on-alloca exemption on purpose, so a module that is correct
    // for its purpose fails verification there: 23 spurious
    // "llvm.lifetime.start/end can only be used on alloca or poison" against
    // 4 real findings. A gate that cries wolf gets switched off.
    if (auto bad = verifyBeforeEmit(module, "AIR legalization")) {
      // Keep the rejected module. The gate fires before any emission
      // debug hatch runs, so without this a rejection leaves no artefact
      // -- and the module IS the diagnosis.
      if (const char *keep = ::getenv("APPLEGPU_KEEP_AIR")) {
        std::error_code ec;
        llvm::raw_fd_ostream dbg(std::string(keep) + "/applegpu-rejected.ll",
                                 ec);
        if (!ec)
          module.print(dbg, nullptr);
      }
      return Error(*bad);
    }

    // Downgrade modern IR constructs to what the LLVM-17-era AIR reader
    // accepts (in-tree pass, built for exactly this).
    {
      llvm::PassBuilder pb;
      llvm::LoopAnalysisManager lam;
      llvm::FunctionAnalysisManager fam;
      llvm::CGSCCAnalysisManager cgam;
      llvm::ModuleAnalysisManager mam;
      pb.registerModuleAnalyses(mam);
      pb.registerCGSCCAnalyses(cgam);
      pb.registerFunctionAnalyses(fam);
      pb.registerLoopAnalyses(lam);
      pb.crossRegisterProxies(lam, fam, cgam, mam);
      llvm::ModulePassManager mpm;
      // Metal kernels are conventionally fully inlined, and AMD's backend
      // cannot trace a buffer resource across a call boundary — a store
      // through a pointer that arrived as a callee parameter crashes its
      // lowering. Force every internal helper into its caller.
      for (llvm::Function &fn : module)
        if (!fn.isDeclaration() && fn.hasLocalLinkage()) {
          fn.removeFnAttr(llvm::Attribute::NoInline);
          fn.addFnAttr(llvm::Attribute::AlwaysInline);
        }
      mpm.addPass(llvm::AlwaysInlinerPass());

      // Break wide float vector arithmetic into pieces the hardware has.
      //
      // An Apple GPU lane is scalar: the 32-wide SIMD is across THREADS, not
      // within one. A `<64 x float>` fmul inside a thread has no vector unit to
      // land on, so somebody must break it into 64 scalar operations before it
      // can execute. Metal Shading Language tops out at four components, so
      // anything wider than float4 is a shape Apple's own frontend never emits
      // and their backend therefore rarely sees.
      //
      // Measured on an M4 Max against Modular's shipping 26.5.0 release, from
      // the same source file (oracles bench/fma_peak_bench.mojo): upstream
      // emits NO vector float ops at any width -- its loop is scalarised into
      // 3*chains+4 scalar ops -- while this backend emitted exactly two, an
      // `fmul <N x float>` and an `fadd <N x float>`, at every width. Upstream
      // saturates at 16 chains where this port needs 64: an ILP deficit of the
      // shape a poor scalarisation schedule produces.
      //
      // ScalarizeMinBits=128 fragments anything wider than float4 while
      // leaving float2/3/4 intact, since those map to native MSL vector types.
      // Loads and stores are left alone (the pass default): vector memory
      // access is genuinely wide on this hardware, and splitting it would cost
      // rather than gain.
      if (airKnobEnabled("APPLEGPU_AIR_SCALARIZE_WIDE_VECTORS", false)) {
        unsigned minBits = 128;
        if (auto b = airKnob("APPLEGPU_AIR_SCALARIZE_MIN_BITS"))
          minBits = static_cast<unsigned>(atoi(b->c_str()));
        llvm::ScalarizerPassOptions opts;
        opts.ScalarizeMinBits = minBits;
        opts.ScalarizeLoadStore = false;
        mpm.addPass(llvm::createModuleToFunctionPassAdaptor(
            llvm::ScalarizerPass(opts)));
        if (airKnobEnabled("APPLEGPU_AIR_TRACE_KNOBS", false))
          llvm::errs() << "[applegpu] scalarize-wide-vectors ON, minBits="
                       << minBits << "\n";
      }
        mpm.run(module, mam);

        // Re-legalise address spaces now that inlining has run. legalizeModule
        // did this already, but only over the code that existed then: whatever
        // AlwaysInliner has just pulled in from a callee has never been through
        // it, and a device pointer in that code is still generic.
        //
        // On AIR that is not a missed optimisation, it is a wrong answer. AIR
        // has no generic address space, so a kernel left with its stores in
        // addrspace(1) and its loads in addrspace(0) writes correctly and reads
        // zero -- an output buffer full of zeroes, no diagnostic anywhere, and
        // nothing in the IR that any verifier objects to.
        deviceizeCapturedPointers(module);

        llvm::ModulePassManager mpm2;
      // The published Metal emission machinery, by its own declarations:
      // BitcodeWriter17.cpp:15 — "for writing Metal bitcode"; Apple's AIR
      // reader is LLVM-18-based (BitcodeWriter17.cpp ~1765) and requires
      // typed POINTER records (opaque record code 25 presents as "Failed to
      // upgrade function bitcode" at pipeline creation).
      // LLVMIRDowngradePass is the published MetalAIRPass skeleton
      // (LLVMIRDowngradePass.cpp:184) — lifetime-intrinsic downgrading
      // today; our legalizeModule above supplies the body that upstream
      // kept closed. PointerRewriter un-opaques for the writer.
      mpm2.addPass(LLVMIRDowngradePass());
      mpm2.addPass(PointerRewriter());
      mpm2.run(module, mam);
      // Again after the pipeline, not only in legalizeModule: inlining can
      // pull a same-space cast in from a callee, and the reader rejects the
      // module for one of them.
      dropNoOpAddrSpaceCasts(module);
    }



    // Debug hatch: dump post-pass text (after MetalAIRPass/PointerRewriter).
    if (const char *keep = ::getenv("APPLEGPU_KEEP_AIR")) {
      std::error_code ec;
      llvm::raw_fd_ostream dbg(std::string(keep) + "/applegpu-kernel.post.ll", ec);
      if (!ec)
        module.print(dbg, nullptr);
    }

    // Debug hatch: dump the legalized module as text before encoding, so a
    // module the reader rejects can still be inspected.
    if (const char *keep = ::getenv("APPLEGPU_KEEP_AIR")) {
      std::error_code ec;
      llvm::raw_fd_ostream dbg(std::string(keep) + "/applegpu-kernel.pre.ll", ec);
      if (!ec)
        module.print(dbg, nullptr);
    }

    // Last look at the finished module: which symbols is Apple's reader
    // going to have to resolve? This has to be HERE and not beside the other
    // gates -- the downgrade pipeline and PointerRewriter both strand
    // declarations after eraseDeadIntrinsicDeclarations has already run, and
    // an unresolved external is not rejected by metallib. It survives
    // packaging and kills the compiler service at pipeline creation with
    // XPC_ERROR_CONNECTION_INTERRUPTED, naming nothing at all.
    {
      std::string fatal;
      for (const Air::Finding &f : Air::checkExternals(module)) {
        if (f.action == Air::RuleAction::Fail)
          fatal += "  - " + f.detail + "\n";
        else
          llvm::errs() << "[air-legality] " << f.ruleId << ": " << f.detail
                       << "\n";
      }
      if (!fatal.empty())
        return Error(
            "AIR module declares symbols the Metal reader cannot resolve. "
            "These pass metallib and fail at pipeline creation with no "
            "diagnostic, so they are rejected here instead. Set "
            "APPLEGPU_AIR_RULES=unresolved-external=log to downgrade.\n" +
            fatal);
    }

    // Emission: AIR bitcode via the cooperating PointerRewriter +
    // BitcodeWriter17 pair (typed POINTER records), wrapped in the bitcode
    // wrapper header, packaged by `xcrun metallib`.
    llvm::SmallVector<char, 0> bc;
    {
      llvm::raw_svector_ostream bcos(bc);
      M::KGEN::LLVM::WriteBitcode17ToFile(module, bcos,
                                          /*ShouldPreserveUseListOrder=*/false,
                                          /*Index=*/nullptr,
                                          /*GenerateHash=*/false,
                                          /*ModHash=*/nullptr);
    }
    llvm::SmallString<128> llPath, libPath;
    if (llvm::sys::fs::createTemporaryFile("applegpu-kernel", "air", llPath))
      return Error("failed to create temporary .air file");
    if (llvm::sys::fs::createTemporaryFile("applegpu-kernel", "metallib", libPath))
      return Error("failed to create temporary .metallib file");
    {
      std::error_code ec;
      llvm::raw_fd_ostream out(llPath, ec);
      if (ec)
        return Error("failed to open temporary .air for writing");
      // WriteBitcode17ToFile emits the bitcode wrapper header itself.
      out.write(bc.data(), bc.size());
    }

    // Locate xcrun WITHOUT relying on PATH.
    //
    // Under Bazel there is no PATH to search: rules_mojo pins the compile
    // action's environment to PATH=/dev/null on purpose, for hermeticity
    // (alongside MODULAR_MOJO_MAX_{COMPILERRT,LLD}_PATH=/dev/null). Confirmed
    // with `bazel aquery 'mnemonic("MojoCompile", ...)'`. A bare
    // findProgramByName therefore always fails there, and --action_env=PATH
    // cannot fix it because the rule's own env wins.
    //
    // The failure that produced is worth remembering: the AIR bitcode is
    // generated FIRST and only packaging fails, so the whole codegen path can
    // be working and the build still stops with what reads like a compiler
    // error.
    //
    // /usr/bin/xcrun is the stable system stub on every macOS; it resolves the
    // active toolchain itself via DEVELOPER_DIR or xcode-select, and
    // rules_mojo does pass DEVELOPER_DIR through. Verified that `env -i
    // DEVELOPER_DIR=... /usr/bin/xcrun -sdk macosx metallib --version` works
    // with no PATH at all. Note it is NOT under DEVELOPER_DIR/usr/bin -- that
    // path does not exist on this install.
    // Keep the .air BEFORE packaging, not after. When metallib rejects the
    // bitcode ("Unexpected bitcode file!") the rejected file is exactly what
    // you need, and copying it only on success meant it was deleted at the
    // one moment it mattered.
    if (const char *keep = ::getenv("APPLEGPU_KEEP_AIR")) {
      // Unique per kernel: a module with several kernels overwrote this, and
      // the survivor was a kernel that PASSED while a different one failed --
      // which reads as "the file metallib rejects is fine when I run metallib
      // on it by hand".
      llvm::StringRef stem = llvm::sys::path::stem(llPath);
      llvm::sys::fs::copy_file(
          llPath, (std::string(keep) + "/" + stem.str() + ".air"));
      // The textual IR too, same stem: when a reader rejects the bitcode
      // (sometimes including modern LLVM's own -- writer bugs exist), the
      // text is the only view of what the module actually contained.
      std::error_code ec;
      llvm::raw_fd_ostream txt(std::string(keep) + "/" + stem.str() + ".ll",
                               ec);
      if (!ec)
        module.print(txt, nullptr);
    }

    llvm::ErrorOr<std::string> xcrun = llvm::sys::findProgramByName("xcrun");
    if (!xcrun && llvm::sys::fs::can_execute("/usr/bin/xcrun"))
      xcrun = std::string("/usr/bin/xcrun");
    if (!xcrun)
      return Error("xcrun not found on PATH or at /usr/bin/xcrun; the AIR "
                   "emitter needs Xcode command line tools");
    llvm::SmallString<128> errPath;
    if (llvm::sys::fs::createTemporaryFile("applegpu-metal", "err", errPath))
      return Error("failed to create temporary stderr file");
    llvm::SmallVector<llvm::StringRef, 12> args = {
        *xcrun, "-sdk", "macosx", "metallib", llPath, "-o", libPath};
    std::optional<llvm::StringRef> redirects[3] = {
        std::nullopt, std::nullopt, llvm::StringRef(errPath)};
    std::string errMsg;
    int rc = llvm::sys::ExecuteAndWait(*xcrun, args, std::nullopt, redirects,
                                       0, 0, &errMsg);
    if (rc != 0) {
      std::string toolErr;
      if (auto buf = llvm::MemoryBuffer::getFile(errPath))
        toolErr = (*buf)->getBuffer().str();
      llvm::sys::fs::remove(errPath);
      llvm::sys::fs::remove(libPath);
      // Keep the rejected .ll for postmortem.
      return Error(Twine("xcrun metallib failed (rc=") + Twine(rc) +
                   ") on " + llPath + ": " + toolErr + errMsg);
    }
    llvm::sys::fs::remove(errPath);

    // Debug escape hatch: APPLEGPU_KEEP_AIR=<dir> keeps the .ll and .metallib.
    if (const char *keep = ::getenv("APPLEGPU_KEEP_AIR")) {
      llvm::sys::fs::copy_file(
          libPath, (std::string(keep) + "/applegpu-kernel.metallib"));
    }
    auto libBufOr = llvm::MemoryBuffer::getFile(libPath);
    llvm::sys::fs::remove(llPath);
    if (!libBufOr) {
      llvm::sys::fs::remove(libPath);
      return Error("failed to read packed metallib");
    }
    llvm::sys::fs::remove(libPath);

    WriteableBufferRef out = WriteableBuffer::get();
    *out << (*libBufOr)->getBuffer();
    return out;
  }

  ErrorOr<BufferRef> createArchive(llvm::MutableArrayRef<BufferRef>,
                                   llvm::StringRef,
                                   EmitContext &) const override {
    return Error("AirBackend::createArchive is not wired");
  }
};

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wglobal-constructors"
RegisterTargetBackend<AirBackend> registerAirBackend;
#pragma GCC diagnostic pop

} // namespace
} // namespace M::KGEN
