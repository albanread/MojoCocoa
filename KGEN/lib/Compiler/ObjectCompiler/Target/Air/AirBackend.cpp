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
#include "llvm/IR/PassManager.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Transforms/IPO/AlwaysInliner.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Program.h"
#include "llvm/Support/raw_ostream.h"

#include <optional>
#include <string>

namespace M::KGEN {
namespace {

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
constexpr const char *kAirTriple = "air64_v28-apple-macosx26.0.0";

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

// Parses "llvm.air.<base>[.<dim>]" into (kind, dim). dim: x=0,y=1,z=2, or
// nullopt for scalar builtins used undimensioned.
std::optional<std::pair<const BuiltinKind *, std::optional<unsigned>>>
parseBuiltinShim(llvm::StringRef name) {
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
      else if (auto *call = llvm::dyn_cast<llvm::CallInst>(inst)) {
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
      }
    }
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
  unsigned firstBuiltinIdx = numOrigParams;
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

void mangleAirOps(llvm::Module &m) {
  llvm::SmallVector<llvm::CallInst *, 16> calls;
  for (llvm::Function &fn : m)
    for (llvm::BasicBlock &bb : fn)
      for (llvm::Instruction &inst : bb)
        if (auto *call = llvm::dyn_cast<llvm::CallInst>(&inst))
          if (llvm::Function *callee = call->getCalledFunction())
            if (needsAirTypeSuffix(callee->getName()) ||
                isSimdgroupMatrixMMA(callee->getName()))
              calls.push_back(call);
  for (llvm::CallInst *call : calls) {
    std::optional<std::string> suffix;
    if (isSimdgroupMatrixMMA(call->getCalledFunction()->getName())) {
      suffix = simdgroupMatrixSuffix(call);
    } else {
      llvm::Type *keyTy = call->arg_size() ? call->getArgOperand(0)->getType()
                                           : call->getType();
      suffix = airTypeSuffix(keyTy);
    }
    if (!suffix)
      continue; // leaves the bare stem; fails loudly with a clear label
    std::string mangled =
        (call->getCalledFunction()->getName() + *suffix).str();
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
          bool fromConstantBuffer = llvm::isa<llvm::Argument>(agg);
          if (auto *ld = llvm::dyn_cast<llvm::LoadInst>(agg)) {
            auto *srcTy = llvm::dyn_cast<llvm::PointerType>(
                ld->getPointerOperand()->getType());
            fromConstantBuffer =
                srcTy && (srcTy->getAddressSpace() == 2 ||
                          srcTy->getAddressSpace() == 1);
          }
          if (fromConstantBuffer)
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

llvm::Error legalizeModule(llvm::Module &m) {
  llvm::LLVMContext &c = m.getContext();
  m.setTargetTriple(llvm::Triple(kAirTriple));
  mangleAirOps(m);
  remapAddressSpaces(m);
  deviceizeCapturedPointers(m);
  // After deviceize, which can leave a cast redundant by moving its
  // operand into the space it was casting to.
  dropNoOpAddrSpaceCasts(m);

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
    airKernels->addOperand(llvm::MDNode::get(
        c, {llvm::ConstantAsMetadata::get(legal), llvm::MDNode::get(c, {}),
            llvm::MDNode::get(c, argMD)}));
  }

  // Module flags and AIR identification, per the golden sample.
  auto addFlag = [&](llvm::StringRef name, uint32_t value, uint32_t behavior) {
    m.addModuleFlag(static_cast<llvm::Module::ModFlagBehavior>(behavior), name,
                    value);
  };
  if (!m.getModuleFlag("wchar_size"))
    addFlag("wchar_size", 4, llvm::Module::Error);
  if (!m.getModuleFlag("frame-pointer"))
    addFlag("frame-pointer", 2, llvm::Module::Max);
  addFlag("air.max_device_buffers", 31, llvm::Module::Max);
  addFlag("air.max_constant_buffers", 31, llvm::Module::Max);
  addFlag("air.max_threadgroup_buffers", 31, llvm::Module::Max);
  addFlag("air.max_textures", 128, llvm::Module::Max);
  addFlag("air.max_read_write_textures", 8, llvm::Module::Max);
  addFlag("air.max_samplers", 16, llvm::Module::Max);
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
  setVersionMD("air.version", {mdI32(c, 2), mdI32(c, 8), mdI32(c, 0)});
  setVersionMD("air.language_version",
               {mdStr(c, "Metal"), mdI32(c, 4), mdI32(c, 0), mdI32(c, 0)});
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

  /// The stdlib reaches AIR builtins through `llvm.call_intrinsic` ops named
  /// `llvm.air.*`, which are not real LLVM intrinsics and fail MLIR->LLVM
  /// translation. Rewrite them into plain calls to `air.*`-named external
  /// functions (legal names); the AIR legalizer converts those calls into
  /// trailing kernel parameters later.
  void
  prepareModuleForLowering(mlir::Operation *module,
                           const CompilationOptions &options) const override {
    auto moduleOp = llvm::dyn_cast<mlir::ModuleOp>(module);
    if (!moduleOp)
      return;
    mlir::SymbolTable symtab(moduleOp);
    llvm::SmallVector<mlir::LLVM::CallIntrinsicOp, 8> worklist;
    moduleOp.walk([&](mlir::LLVM::CallIntrinsicOp op) {
      if (op.getIntrin().starts_with("llvm.air."))
        worklist.push_back(op);
    });
    for (mlir::LLVM::CallIntrinsicOp op : worklist) {
      llvm::StringRef airName = op.getIntrin().drop_front(strlen("llvm."));
      mlir::OpBuilder b(op);
      auto fn = symtab.lookup<mlir::LLVM::LLVMFuncOp>(airName);
      if (!fn) {
        mlir::OpBuilder declBuilder(moduleOp.getBodyRegion());
        auto fnType = mlir::LLVM::LLVMFunctionType::get(
            op.getNumResults() ? op.getResult(0).getType()
                               : mlir::LLVM::LLVMVoidType::get(
                                     moduleOp.getContext()),
            llvm::to_vector(op.getArgs().getTypes()));
        fn = declBuilder.create<mlir::LLVM::LLVMFuncOp>(op.getLoc(), airName,
                                                        fnType);
        symtab.insert(fn);
      }
      auto call =
          b.create<mlir::LLVM::CallOp>(op.getLoc(), fn, op.getArgs());
      if (op.getNumResults())
        op.getResult(0).replaceAllUsesWith(call.getResult());
      op.erase();
    }
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
      // The published Metal emission machinery, by its own declarations:
      // BitcodeWriter17.cpp:15 — "for writing Metal bitcode"; Apple's AIR
      // reader is LLVM-18-based (BitcodeWriter17.cpp ~1765) and requires
      // typed POINTER records (opaque record code 25 presents as "Failed to
      // upgrade function bitcode" at pipeline creation).
      // LLVMIRDowngradePass is the published MetalAIRPass skeleton
      // (LLVMIRDowngradePass.cpp:184) — lifetime-intrinsic downgrading
      // today; our legalizeModule above supplies the body that upstream
      // kept closed. PointerRewriter un-opaques for the writer.
      mpm.addPass(LLVMIRDowngradePass());
      mpm.addPass(PointerRewriter());
      mpm.run(module, mam);
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
    if (const char *keep = ::getenv("APPLEGPU_KEEP_AIR"))
      llvm::sys::fs::copy_file(llPath,
                               (std::string(keep) + "/applegpu-kernel.air"));

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
