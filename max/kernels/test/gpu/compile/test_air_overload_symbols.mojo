# ===----------------------------------------------------------------------=== #
# Apple AIR: one shim stem, many signatures, in more than one kernel.
#
# `llvm.air.*` names are this fork's own convention, not LLVM's, so they get
# none of the per-overload mangling that turns `llvm.fma` into
# `llvm.fma.v4f32`. Before AirLowering keyed declarations by signature, every
# operand combination of a stem resolved to ONE declaration: the first
# signature translated won, and the next call asserted inside MLIR's LLVM
# translation with "Calling a function with a bad signature!" -- a compiler
# crash whose stack named no user code.
#
# This test exists to make that failure mode impossible to reintroduce
# silently. It is a COMPILE test: reaching codegen at all is the assertion.
# Each kernel below mixes payload widths and element types on shared stems,
# and the MMA calls span the operand cross-product rather than one diagonal --
# (f16, bf16) and (f16, f32) collide under any scheme that keys on the first
# operand alone, which an earlier per-call-site fix did.
# ===----------------------------------------------------------------------=== #
# CHECK: compiled True True

from max.gpu.compute.arch.mma_apple import _mma_apple_8x8
from max.gpu.host import get_gpu_target
from max.gpu.host.compile import _compile_code

comptime APPLE_TARGET = get_gpu_target["apple-m4"]()


def _mma_pair[
    a_dtype: DType, b_dtype: DType
](d_ptr: UnsafePointer[Scalar[DType.float32], MutAnyOrigin]):
    var d = SIMD[DType.float32, 2](0)
    var a = SIMD[a_dtype, 2](1)
    var b = SIMD[b_dtype, 2](2)
    var c = SIMD[DType.float32, 2](0)
    _mma_apple_8x8(d, a, b, c)
    d_ptr[0] = d[0]


# Kernel one: the float cross-product that shares a first operand type.
def kernel_mixed_mma(d_ptr: UnsafePointer[Scalar[DType.float32], MutAnyOrigin]):
    _mma_pair[DType.float16, DType.float16](d_ptr)
    _mma_pair[DType.float16, DType.bfloat16](d_ptr)
    _mma_pair[DType.float16, DType.float32](d_ptr)


# Kernel two: the same stems again, from a DIFFERENT kernel. Declarations are
# module-scoped, so a second kernel is what proves the key is shared correctly
# rather than accidentally per-function.
def kernel_mixed_mma_again(
    d_ptr: UnsafePointer[Scalar[DType.float32], MutAnyOrigin]
):
    _mma_pair[DType.bfloat16, DType.float16](d_ptr)
    _mma_pair[DType.float32, DType.float32](d_ptr)
    _mma_pair[DType.float16, DType.float16](d_ptr)  # repeat: must REUSE, not clash


def main():
    # Compiling for the accelerator is the whole test: a signature collision
    # aborts the compiler rather than producing a diagnostic, so any regression
    # shows up here as a crash, not a wrong answer.
    var one = _compile_code[
        kernel_mixed_mma, target=APPLE_TARGET, emission_kind="llvm"
    ]()
    var two = _compile_code[
        kernel_mixed_mma_again, target=APPLE_TARGET, emission_kind="llvm"
    ]()
    print("compiled", one.asm != "", two.asm != "")
