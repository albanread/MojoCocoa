; RUN: env APPLEGPU_AIR_RULES=all=permit,divergent-barrier=fail kgen-llvm-opt -passes=air-legality -disable-output %s 2>&1 | FileCheck --implicit-check-not=air-rules %s
; RUN: env APPLEGPU_AIR_RULES=all=permit,divergent-barrier=log kgen-llvm-opt -passes=air-legality -disable-output %s 2>&1 | FileCheck --check-prefix=DOWNGRADE --implicit-check-not=air-rules %s

declare void @air.wg.barrier(i32, i32)

; A per-thread branch is legal when both paths reconverge before one common
; barrier instance.
define void @reconverged(i32 %lane) {
entry:
  %is.first = icmp eq i32 %lane, 0
  br i1 %is.first, label %left, label %right

left:
  br label %join

right:
  br label %join

join:
  call void @air.wg.barrier(i32 2, i32 1)
  ret void
}

; A value uniform within the workgroup may guard a workgroup barrier. In
; particular, threadgroup_position_in_grid identifies the group, not a thread.
define void @group_uniform(i32 %group) {
entry:
  %is.first.group = icmp eq i32 %group, 0
  br i1 %is.first.group, label %barrier, label %exit

barrier:
  call void @air.wg.barrier(i32 2, i32 1)
  br label %exit

exit:
  ret void
}

; The local position flows through ordinary SSA operations before controlling
; the barrier. Only lane zero reaches this dynamic barrier instance.
define void @lane_guarded(<3 x i32> %local.position) {
entry:
  %lane = extractelement <3 x i32> %local.position, i32 0
  %is.first = icmp eq i32 %lane, 0
  br i1 %is.first, label %barrier, label %exit

barrier:
  call void @air.wg.barrier(i32 2, i32 1)
  br label %exit

exit:
  ret void
}

; Different simdgroups taking different loop trip counts is also divergent at
; workgroup scope. The barrier is skipped by groups whose trip count is zero.
define void @simdgroup_loop(i32 %simdgroup) {
entry:
  br label %header

header:
  %i = phi i32 [ 0, %entry ], [ %next, %body ]
  %continue = icmp ult i32 %i, %simdgroup
  br i1 %continue, label %body, label %exit

body:
  call void @air.wg.barrier(i32 2, i32 1)
  %next = add i32 %i, 1
  br label %header

exit:
  ret void
}

!air.kernel = !{!0, !4, !8, !12}
!0 = !{ptr @reconverged, !1, !2}
!1 = !{}
!2 = !{!3}
!3 = !{i32 0, !"air.thread_index_in_threadgroup", !"air.arg_type_name", !"uint", !"air.arg_name", !"thread_index_in_threadgroup"}
!4 = !{ptr @group_uniform, !5, !6}
!5 = !{}
!6 = !{!7}
!7 = !{i32 0, !"air.threadgroup_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"threadgroup_position_in_grid"}
!8 = !{ptr @lane_guarded, !9, !10}
!9 = !{}
!10 = !{!11}
!11 = !{i32 0, !"air.thread_position_in_threadgroup", !"air.arg_type_name", !"uint3", !"air.arg_name", !"thread_position_in_threadgroup"}
!12 = !{ptr @simdgroup_loop, !13, !14}
!13 = !{}
!14 = !{!15}
!15 = !{i32 0, !"air.simdgroup_index_in_threadgroup", !"air.arg_type_name", !"uint", !"air.arg_name", !"simdgroup_index_in_threadgroup"}

; CHECK-DAG: fail{{.*}}divergent-barrier{{.*}}workgroup barrier in %barrier is control-dependent on thread-varying conditional in %entry  [in @lane_guarded]
; CHECK-DAG: fail{{.*}}divergent-barrier{{.*}}workgroup barrier in %body is control-dependent on thread-varying conditional in %header  [in @simdgroup_loop]
; CHECK-NOT: [in @reconverged]
; CHECK-NOT: [in @group_uniform]
; CHECK: 2 fail

; DOWNGRADE-COUNT-2: log{{.*}}divergent-barrier
; DOWNGRADE: 0 fail
