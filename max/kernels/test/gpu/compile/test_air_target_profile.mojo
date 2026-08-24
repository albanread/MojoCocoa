# ===----------------------------------------------------------------------=== #
# The Apple target profile drives the triple and every version stamp.
#
# These used to be independent literals across three files, each carrying a
# comment warning that the others had to be changed to match:
#
#   AIR version 2.8      written TWICE -- air.version, and the triple's _v28
#   Metal version 4.0    air.language_version
#   SDK 26.0             the "SDK Version" module flag
#   min OS 26.0.0        the macosx part of the triple
#   bitcode version 17   stranded in AirTraits.h, a different file entirely
#
# One of them drifting is not a build failure. It produces a module the Metal
# reader rejects as "Invalid record", or accepts and then fails at pipeline
# creation naming nothing at all. So they are checked rather than trusted.
#
# `metal:4` is exercised alongside `apple-m4` on purpose: it selects M4
# HARDWARE, not Metal language version 4, and it reads the other way round.
# `apple-m2` is here because the AIR and Metal versions are properties of the
# installed TOOLCHAIN, not of the chip -- an M2 build gets the same stamps.
# ===----------------------------------------------------------------------=== #

from max.gpu.host import get_gpu_target
from max.gpu.host.compile import _compile_code
from std.gpu import global_idx


def profile_probe(p: UnsafePointer[Scalar[DType.float32], MutAnyOrigin]):
    p[global_idx.x] = Float32(1)


def main():
    # CHECK-LABEL: == apple-m4
    print("== apple-m4")
    print(
        _compile_code[
            profile_probe,
            target = get_gpu_target["apple-m4"](),
            emission_kind="asm",
        ]().asm
    )
    # The AIR version appears twice and both spellings must agree.
    # CHECK-DAG: target triple = "air64_v28-apple-macosx26.0.0"
    # CHECK-DAG: !air.version = !{![[M4AIR:[0-9]+]]}
    # CHECK-DAG: ![[M4AIR]] = !{i32 2, i32 8, i32 0}
    # CHECK-DAG: !air.language_version = !{![[M4LANG:[0-9]+]]}
    # CHECK-DAG: ![[M4LANG]] = !{!"Metal", i32 4, i32 0, i32 0}
    # CHECK-DAG: !"SDK Version", [2 x i32] [i32 26, i32 0]

    # CHECK-LABEL: == metal:4
    print("== metal:4")
    print(
        _compile_code[
            profile_probe,
            target = get_gpu_target["metal:4"](),
            emission_kind="asm",
        ]().asm
    )
    # CHECK-DAG: target triple = "air64_v28-apple-macosx26.0.0"
    # CHECK-DAG: !air.version = !{![[MTAIR:[0-9]+]]}
    # CHECK-DAG: ![[MTAIR]] = !{i32 2, i32 8, i32 0}

    # CHECK-LABEL: == apple-m2
    print("== apple-m2")
    print(
        _compile_code[
            profile_probe,
            target = get_gpu_target["apple-m2"](),
            emission_kind="asm",
        ]().asm
    )
    # CHECK-DAG: target triple = "air64_v28-apple-macosx26.0.0"
    # CHECK-DAG: !air.version = !{![[M2AIR:[0-9]+]]}
    # CHECK-DAG: ![[M2AIR]] = !{i32 2, i32 8, i32 0}
