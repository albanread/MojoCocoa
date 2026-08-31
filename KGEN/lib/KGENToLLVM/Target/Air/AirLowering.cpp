//===----------------------------------------------------------------------===//
// VEGA-FORK: MLIR-lowering policy for the AIR (Metal GPU) target.
//
// Owns the lowering of `llvm.air.*` builtin "intrinsics": those names are
// not real LLVM intrinsics, so they lower to calls of `air.*`-named external
// functions which the AIR backend later converts to kernel parameters /
// mangled AIR runtime calls. The conversion creates module-level function
// declarations, so it MUST run in the module-scoped, single-threaded
// LowerGlobalPOPToLLVM pass — doing it from the per-function LowerPOPToLLVM
// pass raced sibling function conversions on the symbol table (triage
// finding: duplicate declarations / crashes when several kernels share a
// builtin).
//===----------------------------------------------------------------------===//

#include "KGEN/POPDialect/POPOps.h"
#include "Target/Air/AirBuiltinRegistry.h"
#include "Target/Air/AirTraits.h"
#include "Target/TargetLowering.h"

#include "mlir/Conversion/LLVMCommon/Pattern.h"
#include "mlir/Conversion/LLVMCommon/TypeConverter.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/Matchers.h"
#include "mlir/IR/SymbolTable.h"

namespace M::KGEN {
namespace {

/// Passthrough attribute marking an exported AIR kernel between
/// LowerKGENToLLVM (which stamps it via markExportedKernel) and the object
/// backend (which recognizes it via isExportedKernel and scrubs it).
static constexpr llvm::StringLiteral kKernelMark = "air-kernel";

// AIR runtime functions are type-suffixed (air.simd_shuffle_xor.u.i32,
// .f32, .f16 — golden MSL probes). Mangle at declaration time so each
// payload type gets its own correctly-typed declaration; a shared bare stem
// asserts "bad signature" at translation when payload types differ.
//
// On the `.u.` below — measured, not assumed. AIR carries SEPARATE signed and
// unsigned integer symbols, and both exist:
//
//   declare i32 @air.simd_min.s.i32(i32)      declare i32 @air.simd_min.u.i32(i32)
//   declare i32 @air.simd_max.s.i32(i32)      declare i32 @air.simd_max.u.i32(i32)
//   declare i32 @air.simd_sum.s.i32(i32)      declare i32 @air.simd_sum.u.i32(i32)
//   declare i32 @air.simd_shuffle_xor.s.i32(i32, i16)
//   declare <2 x i32> @air.simd_shuffle_xor.s.v2i32(<2 x i32>, i16)
//
// We cannot tell which to pick here: the LLVM dialect's integer types are
// signless, and the stdlib emits bare stems ("llvm.air.simd_sum"), so the
// signedness is simply not in scope by this point. `.u.` is therefore a
// GUESS, and it is only sound where the two symbols compute the same bits:
//
//   sum, product, prefix sums -- two's-complement add/multiply are
//                                bit-identical signed vs unsigned.  SAFE.
//   shuffles                  -- a lane move does not interpret the payload.
//                                SAFE.
//   min, max                  -- genuinely different.  min(-1, 5) is -1
//                                signed and 5 unsigned.  NOT SAFE, and
//                                rejected below rather than guessed at.
//
// Today the stdlib never emits llvm.air.simd_min/max, so nothing hits that
// path; the guard is there so that wiring them up fails at compile time
// instead of silently computing the wrong reduction.
std::optional<std::string> airSuffixFor(mlir::Type ty) {
  if (ty.isF32())
    return Air::payloadTypeSuffix(/*isFloating=*/true, 32);
  if (ty.isF16())
    return Air::payloadTypeSuffix(/*isFloating=*/true, 16);
  if (auto it = llvm::dyn_cast<mlir::IntegerType>(ty)) {
    // No 64-bit case: MSL rejects simd-group ops on 64-bit types outright
    // ("no matching function for call to 'simd_shuffle_xor'").
    return Air::payloadTypeSuffix(/*isFloating=*/false, it.getWidth());
  }
  if (auto vt = llvm::dyn_cast<mlir::VectorType>(ty)) {
    mlir::Type elem = vt.getElementType();
    if (elem.isF16() || elem.isF32())
      return Air::payloadTypeSuffix(/*isFloating=*/true,
                                    elem.isF16() ? 16 : 32,
                                    vt.getNumElements());
    if (auto it = llvm::dyn_cast<mlir::IntegerType>(elem))
      return Air::payloadTypeSuffix(/*isFloating=*/false, it.getWidth(),
                                    vt.getNumElements());
  }
  return std::nullopt;
}

class ConvertAirIntrinsicToCall
    : public mlir::ConvertOpToLLVMPattern<POP::CallLLVMIntrinsicOp> {
public:
  ConvertAirIntrinsicToCall(mlir::LLVMTypeConverter &converter,
                            mlir::SymbolTable &symtab)
      : ConvertOpToLLVMPattern(converter, /*benefit=*/10), symtab(symtab) {}

  mlir::LogicalResult
  matchAndRewrite(POP::CallLLVMIntrinsicOp op, OpAdaptor adaptor,
                  mlir::ConversionPatternRewriter &rewriter) const override {
    llvm::StringRef intrin =
        llvm::cast<mlir::StringAttr>(op.getIntrin()).getValue();
    if (!intrin.starts_with("llvm.air."))
      return mlir::failure();

    llvm::SmallVector<mlir::Type> resultTypes;
    if (mlir::failed(getTypeConverter()->convertTypes(op.getResultTypes(),
                                                      resultTypes)))
      return mlir::failure();
    mlir::Type resType =
        resultTypes.empty()
            ? mlir::LLVM::LLVMVoidType::get(rewriter.getContext())
            : resultTypes[0];

    std::string fnName = intrin.drop_front(strlen("llvm.")).str();
    // KGEN packs multi-operand intrinsic args into a struct; AIR runtime
    // functions take flat scalar arguments — unpack at the LLVM level (the
    // module-scope analogue of LowerPOPToLLVM's expandOperands).
    llvm::SmallVector<mlir::Value> operands;
    for (mlir::Value v : adaptor.getOperands()) {
      if (auto st = llvm::dyn_cast<mlir::LLVM::LLVMStructType>(v.getType())) {
        for (auto [idx, elemTy] : llvm::enumerate(st.getBody())) {
          // Skip trailing byte-array padding. Mojo's Bool arrives as
          // {i1, [15 x i8]}, and flattening both halves gave
          // air.simdgroup_matrix_...(<8 x half>, i1, [15 x i8], ...) where
          // AIR declares (<8 x half>, i1, ...). No AIR builtin takes a byte
          // array, so a [N x i8] member is padding by construction.
          if (auto at = llvm::dyn_cast<mlir::LLVM::LLVMArrayType>(elemTy))
            if (at.getElementType().isInteger(8))
              continue;
          operands.push_back(rewriter.createOrFold<mlir::LLVM::ExtractValueOp>(
              op.getLoc(), v, idx));
        }
      } else {
        operands.push_back(v);
      }
    }
    llvm::SmallVector<mlir::Type> argTypes;
    for (mlir::Value v : operands)
      argTypes.push_back(v.getType());

    // Mangle the AIR type suffix at DECLARATION time for the families that
    // carry one. Reusing a single bare-stem declaration across e.g. a scalar
    // and a vector call yields a call whose operands do not match the callee
    // ("Calling a function with a bad signature").
    //
    // Builtins (thread_position_in_grid, …) and barriers must stay bare:
    // the AIR backend matches builtin stems by name to turn them into kernel
    // parameters, and barriers are unsuffixed in AIR.
    // The simdgroup_matrix MMA family is NOT mangled here. AIR names it by
    // full signature and encodes its transpose flags in the name, and those
    // flags are not constants at this point: KGEN packs the intrinsic's
    // arguments into one struct inside the still-uninlined llvm_intrinsic
    // wrapper, so each flag is an extractvalue with nothing to fold against.
    // AirBackend::mangleAirOps does it on LLVM IR after inlining, where the
    // i1 is a real ConstantInt. The declaration stays bare until then.
    if (Air::builtinNeedsTypeSuffix(fnName)) {
      mlir::Type keyTy = !operands.empty() ? operands[0].getType() : resType;
      // `.s.` vs `.u.` is unrecoverable here and the two differ for min/max
      // (see airSuffixFor). Refuse rather than pick one and be silently
      // wrong on negative inputs.
      if ((fnName == "air.simd_min" || fnName == "air.simd_max") &&
          llvm::isa<mlir::IntegerType>(keyTy))
        return op.emitError()
               << "cannot lower '" << fnName
               << "' for an integer payload: AIR has distinct .s./.u. symbols "
                  "with different semantics, and signedness is not available "
                  "at this point in the pipeline. Plumb it through the "
                  "intrinsic name before enabling integer simd_min/simd_max.";
      auto suffix = airSuffixFor(keyTy);
      if (!suffix)
        return op.emitError()
               << "no AIR type suffix for payload type of '" << fnName
               << "'; emitting the bare stem would name a symbol AIR does "
                  "not define, which crashes the Metal compiler service at "
                  "pipeline creation rather than failing here";
      fnName += *suffix;
    }
    // The function TYPE is the identity, not the name.
    //
    // The suffixing above covers the families that carry a type suffix, but
    // the MMA family and the builtins deliberately stay bare -- and a bare
    // stem is exactly what collides. One symbol served every (a, b) dtype
    // pair of the MMA family, so the first signature translated won and the
    // next call asserted inside MLIR's LLVM translation with "Calling a
    // function with a bad signature!": a compiler crash whose stack names no
    // user code. Uniquing here fixes the class once -- no per-intrinsic list
    // to keep in sync, no operand cross-product to enumerate.
    //
    // The suffix is a hash of the exact type, not a printed one. Printing
    // types and replacing punctuation is not injective, so it can only ever
    // be a hint; correctness comes from the check below, which compares the
    // FunctionType of any symbol we find. A hash collision then surfaces as
    // a located diagnostic rather than a miscompile.
    //
    // The tag itself never has to be correct, only unique:
    // AirBackend::airStem drops everything from '$' before parseBuiltinShim
    // matches a builtin stem or mangleAirOps derives the real air.* name.
    auto fnType = mlir::LLVM::LLVMFunctionType::get(resType, argTypes);
    std::string typeKey;
    {
      llvm::raw_string_ostream os(typeKey);
      os << fnType;
    }
    std::string symName =
        fnName + "$" + llvm::utohexstr(llvm::hash_value(typeKey));

    auto fn = symtab.lookup<mlir::LLVM::LLVMFuncOp>(symName);
    if (fn && fn.getFunctionType() != fnType)
      return op.emitError()
             << "AIR declaration '" << symName << "' already exists with type "
             << fn.getFunctionType() << " but this call requires " << fnType
             << "; the per-signature symbol hash collided. Widen the hash or "
                "encode the type exactly.";
    if (!fn) {
      auto module = llvm::cast<mlir::ModuleOp>(symtab.getOp());
      mlir::OpBuilder::InsertionGuard guard(rewriter);
      rewriter.setInsertionPointToStart(module.getBody());
      fn = mlir::LLVM::LLVMFuncOp::create(rewriter, op.getLoc(), symName,
                                          fnType);
      // Cross-lane and barrier ops must be `convergent` HERE, at creation,
      // not when the AIR module is finally legalised.
      //
      // A barrier only means anything if the whole threadgroup reaches the
      // same one. LLVM will happily clone a call it believes is ordinary --
      // loop unswitching duplicates the loop body per specialised predicate,
      // and if that predicate is per-lane (`col < N` on a ragged tile edge)
      // the lanes end up at DIFFERENT barrier instances and the threadgroup
      // never synchronises. `convergent` is what tells the unswitcher to
      // leave the loop alone.
      //
      // Setting it in the object backend, as AirBackend::applyAirCallAttributes
      // does, is far too late: by then the optimiser has already run and the
      // barrier has already been cloned. The attribute on the final module is
      // then correct and useless. Measured on test_matmul_1_sram -- 2 barriers
      // in source became 8 in the emitted AIR, in blocks carrying LLVM's `.us`
      // unswitch suffix, and the kernel read a threadgroup tile that only 22
      // of its 32 lanes had written.
      //
      // Which families need it is measured from `xcrun metal -S -emit-llvm`:
      // barriers and cross-lane ops carry `convergent mustprogress nounwind
      // willreturn`; plain math does NOT. Memory effects are deliberately
      // omitted -- `readnone`'s modern spelling is one the AIR reader
      // predates.
      if (Air::isConvergentBuiltin(fnName)) {
        fn.setPassthroughAttr(rewriter.getArrayAttr(
            {rewriter.getStringAttr("convergent"),
             rewriter.getStringAttr("nounwind"),
             rewriter.getStringAttr("willreturn")}));
      }
      symtab.insert(fn); // single-threaded pass: safe by construction
    }
    rewriter.replaceOpWithNewOp<mlir::LLVM::CallOp>(op, fn, operands);
    return mlir::success();
  }

private:
  mlir::SymbolTable &symtab;
};

class AirLowering final : public TargetLowering {
public:
  const TargetTraits *traits() const override { return &AirTraits::get(); }
  bool isBaseTarget() const override { return false; }

  /// Stamp an exported device kernel so later stages (and
  /// functionRequiresByVal in LowerKGENToLLVM) can recognize it. Travels as
  /// an LLVM passthrough attribute — a channel that survives translation —
  /// and the AIR backend scrubs it before emission; Apple's reader has never
  /// heard of it.
  void markExportedKernel(mlir::Operation *func) const override {
    auto f = llvm::dyn_cast<mlir::LLVM::LLVMFuncOp>(func);
    if (!f)
      return;
    llvm::SmallVector<mlir::Attribute, 4> passthrough =
        llvm::to_vector(f.getPassthroughAttr().getValue());
    mlir::Attribute mark = mlir::StringAttr::get(f->getContext(), kKernelMark);
    if (llvm::is_contained(passthrough, mark))
      return;
    passthrough.push_back(mark);
    f.setPassthroughAttr(mlir::ArrayAttr::get(f->getContext(), passthrough));
  }

  bool isExportedKernel(mlir::Operation *func) const override {
    auto f = llvm::dyn_cast<mlir::LLVM::LLVMFuncOp>(func);
    return f && llvm::is_contained(
                    f.getPassthroughAttr().getValue(),
                    mlir::StringAttr::get(f->getContext(), kKernelMark));
  }

  /// Borrowed kernel arguments pass `byval(<pointee>)` on the AIR target.
  ///
  /// This is the discriminator the capture-pack fix turns on. A kernel
  /// argument this target cannot pass in registers — a marshaled capture
  /// aggregate, the TileTensor packs of nn/index_tensor — is lifted to a
  /// pointer with ArgConvention::ReadMem by LowerArgConventions, and
  /// convertLLVMMetadata attaches byval with the pointee TYPE converted from
  /// the KGEN signature, where it still exists. By LLVM IR the parameter
  /// itself is an opaque pointer and the pointee is gone, but the byval
  /// attribute keeps it: `byval(%struct.Caps)` is a by-value argument pack
  /// (constant bytes on Metal, bound with setBytes), while a device buffer
  /// argument carries byval of a non-struct pointee or none at all and is
  /// ignored by the backend's pack rule. That is the same classification the
  /// launcher applies at enqueue time (`arg_is_device_ptr`: a device pointer
  /// is exactly pointer-sized and pushes one buffer), decided where the type
  /// still says so.
  llvm::StringRef getKernelByValArgAttrName() const override {
    return "llvm.byval";
  }

  bool isLoweredInGlobalPOPPass(mlir::Operation *op) const override {
    auto call = llvm::dyn_cast<POP::CallLLVMIntrinsicOp>(op);
    if (!call)
      return false;
    auto name = llvm::dyn_cast<mlir::StringAttr>(call.getIntrin());
    return name && name.getValue().starts_with("llvm.air.");
  }

  void populateLowerGlobalPOPToLLVMPatterns(
      mlir::RewritePatternSet &patterns, mlir::LLVMTypeConverter &converter,
      mlir::SymbolTable &symtab, TargetInfoAttr target) const override {
    patterns.insert<ConvertAirIntrinsicToCall>(converter, symtab);
  }
};

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wglobal-constructors"
RegisterTargetLowering<AirLowering> registerAirLowering;
#pragma GCC diagnostic pop

} // namespace
} // namespace M::KGEN
