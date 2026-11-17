// RUN: fum-opt %s --monad-check-may-throw | fum-opt | FileCheck %s

// Tile, then fuse, with the failures(suppress) semantics of the Transform
// dialect: a silenceable failure of either step is suppressed, and any other
// exception (a definite failure) propagates. Each step is an inner monad.do
// whose catch lists only the suppressed kind; success and the other kinds end
// the step with the result of the transform op.

!any = !transform.any_op
!handles = !monad.value_or_exception<!any, !any>

monad.exception.declare @silenceable_failure
monad.exception.declare @definite_failure

// Models of the transform operations.
func.func private @tile_using_forall(!any) -> !handles
    attributes {monad.may_throw = [@silenceable_failure]}
func.func private @fuse_into_containing_op(!any, !any) -> !handles
    attributes {monad.may_throw = [@silenceable_failure, @definite_failure]}

// CHECK-LABEL: func.func @tile_and_fuse
// CHECK-SAME: attributes {monad.may_throw = [@definite_failure]}
// CHECK: %[[TILING:.+]] = func.call @tile_using_forall
// CHECK: monad.catch %[[TILING]] [@silenceable_failure -> ^[[TILING_SUPPRESSED:.+]]] : !voe
// CHECK: ^[[TILING_SUPPRESSED]]:
// CHECK: monad.bind %{{.*}}, ^[[AFTER_TILING:.+]] : !voe
// CHECK: ^[[AFTER_TILING]](%{{.*}}: !transform.any_op, %[[LOOP:.+]]: !transform.any_op):
// CHECK: %[[FUSION:.+]] = func.call @fuse_into_containing_op(%{{.*}}, %[[LOOP]])
// CHECK: monad.catch %[[FUSION]] [@silenceable_failure -> ^[[FUSION_SUPPRESSED:.+]]] : !voe
// CHECK: ^[[FUSION_SUPPRESSED]]:
func.func @tile_and_fuse(%matmul: !any, %producer: !any) -> !handles
    attributes {monad.may_throw = [@definite_failure]} {
  %result = monad.do : !handles {
    %tiling_step = monad.do : !handles {
      %tiling = func.call @tile_using_forall(%matmul) : (!any) -> !handles
      monad.catch %tiling [@silenceable_failure -> ^tiling_suppressed] : !handles
    ^tiling_suppressed:
      // Continue with the untiled matmul as the loop.
      %untiled = monad.return %matmul, %matmul : !handles
      monad.yield %untiled : !handles
    }
    monad.bind %tiling_step, ^after_tiling : !handles
  ^after_tiling(%op: !any, %loop: !any):
    %fusion_step = monad.do : !handles {
      %fusion = func.call @fuse_into_containing_op(%producer, %loop)
          : (!any, !any) -> !handles
      monad.catch %fusion [@silenceable_failure -> ^fusion_suppressed] : !handles
    ^fusion_suppressed:
      // Continue with the producer and the loop.
      %unfused = monad.return %producer, %loop : !handles
      monad.yield %unfused : !handles
    }
    monad.yield %fusion_step : !handles
  }
  return %result : !handles
}
