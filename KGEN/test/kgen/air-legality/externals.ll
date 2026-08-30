; RUN: kgen-llvm-opt -passes=air-legality -disable-output %s 2>&1 | FileCheck %s

; Known, correctly typed AIR declarations are silent.
declare float @air.rsqrt.f32(float)
declare float @air.convert.f.f32.s.i32(i32)
declare i32 @air.simd_ballot.i32(i1)
declare void @air.wg.barrier(i32, i32)
declare <64 x float> @air.simdgroup_matrix_8x8_multiply_accumulate.v64f32.v64f16.v64f16.v64f32(<64 x half>, <64 x half>, <64 x float>)

; Unknown name, bad overload suffix, and bad ABI parameter type.
declare float @air.typo.f32(float)
declare float @air.rsqrt.u.i32(float)
declare float @air.simd_shuffle_xor.f32(float, i32)
declare float @air.convert.f.f16.s.i32(i32)

; Non-AIR declarations remain a separate rule.
declare void @not_allowed()

; CHECK-DAG: fail{{.*}}unknown-air-symbol{{.*}}@air.typo.f32: AIR runtime symbol is not registered
; CHECK-DAG: fail{{.*}}unknown-air-symbol{{.*}}@air.rsqrt.u.i32: name suffix '.u.i32' does not describe payload type
; CHECK-DAG: fail{{.*}}unknown-air-symbol{{.*}}@air.simd_shuffle_xor.f32: signature does not match family 'air.simd_shuffle_xor'
; CHECK-DAG: fail{{.*}}unknown-air-symbol{{.*}}@air.convert.f.f16.s.i32: air.convert name types do not match its LLVM function type
; CHECK-DAG: log{{.*}}unresolved-external{{.*}}@not_allowed
; CHECK-NOT: invalid AIR runtime declaration @air.rsqrt.f32
; CHECK-NOT: invalid AIR runtime declaration @air.convert.f.f32.s.i32
; CHECK-NOT: invalid AIR runtime declaration @air.simd_ballot.i32
; CHECK-NOT: invalid AIR runtime declaration @air.wg.barrier
; CHECK-NOT: invalid AIR runtime declaration @air.simdgroup_matrix_8x8_multiply_accumulate
; CHECK: 4 fail
