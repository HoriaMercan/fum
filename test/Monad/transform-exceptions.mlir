// RUN: fum-opt %s | fum-opt | FileCheck %s
// RUN: fum-opt %s --convert-monad-to-adt --canonicalize | FileCheck %s --check-prefix=LOWERED

// P3 of the exception design: tile a matmul, then fuse a producer into the
// loop, suppressing the silenceable failures of both steps. Definite failures
// leave the function. The transform ops are modeled as functions returning
// either values whose left type is a sum of failures.

// CHECK-LABEL: func.func @tile_and_fuse
// CHECK: monad.do : !monad.either<!adt.sum<definite>, !transform.any_op, !transform.any_op>
// CHECK: monad.either.branch %{{.+}}, left ^{{.+}}, right ^{{.+}} : !monad.either<!adt.sum<silenceable>, !transform.any_op, !transform.any_op>
// CHECK: adt.switch %{{.+}} : !adt.sum<silenceable>, [
// CHECK: monad.bind
// CHECK: adt.switch %{{.+}} : !adt.sum<definite, silenceable>, [

// At the low level, every either is merged with its sum of failures: the
// only failure that leaves the function is definite.
// LOWERED-LABEL: func.func @tile_and_fuse
// LOWERED-SAME: -> !adt.sum<definite, right(!transform.any_op, !transform.any_op)>
// LOWERED: call @tile_using_forall(%{{.+}}) : (!transform.any_op) -> !adt.sum<right(!transform.any_op, !transform.any_op), silenceable>
// LOWERED: adt.switch
// LOWERED: call @fuse_into_containing_op
// LOWERED: adt.switch
// LOWERED-NOT: monad.
func.func private @tile_using_forall(%target: !transform.any_op)
    -> !monad.either<!adt.sum<silenceable>, !transform.any_op, !transform.any_op>

func.func private @fuse_into_containing_op(%producer: !transform.any_op, %containing: !transform.any_op)
    -> !monad.either<!adt.sum<definite, silenceable>, !transform.any_op, !transform.any_op>

func.func @tile_and_fuse(%matmul: !transform.any_op, %producer: !transform.any_op)
    -> !monad.either<!adt.sum<definite>, !transform.any_op, !transform.any_op> {
  %result = monad.do : !monad.either<!adt.sum<definite>, !transform.any_op, !transform.any_op> {
    // Step 1: tiling, with its silenceable failure suppressed. The inner do
    // cannot fail, and is bound to continue with the pair it produces.
    %tiled_or_untiled = monad.do : !monad.either<!adt.sum<definite>, !transform.any_op, !transform.any_op> {
      %tiling = func.call @tile_using_forall(%matmul)
          : (!transform.any_op) -> !monad.either<!adt.sum<silenceable>, !transform.any_op, !transform.any_op>
      monad.either.branch %tiling, left ^tiling_failed, right ^tiled
          : !monad.either<!adt.sum<silenceable>, !transform.any_op, !transform.any_op>
    ^tiling_failed(%tiling_error: !adt.sum<silenceable>):
      adt.switch %tiling_error : !adt.sum<silenceable>, [
        silenceable: ^tiling_suppressed
      ]
    ^tiling_suppressed:
      %untiled_pair = monad.return %matmul, %matmul
          : !monad.either<!adt.sum<definite>, !transform.any_op, !transform.any_op>
      monad.yield %untiled_pair : !monad.either<!adt.sum<definite>, !transform.any_op, !transform.any_op>
    ^tiled(%tiled_op: !transform.any_op, %tiled_loop: !transform.any_op):
      %tiled_pair = monad.return %tiled_op, %tiled_loop
          : !monad.either<!adt.sum<definite>, !transform.any_op, !transform.any_op>
      monad.yield %tiled_pair : !monad.either<!adt.sum<definite>, !transform.any_op, !transform.any_op>
    }
    monad.bind %tiled_or_untiled, ^after_tiling
        : !monad.either<!adt.sum<definite>, !transform.any_op, !transform.any_op>
  ^after_tiling(%tiled_or_matmul: !transform.any_op, %loop: !transform.any_op):
    // Step 2: fusion. Silenceable is suppressed; definite is rebuilt in the
    // result's Left and ends the sequence.
    %fusion = func.call @fuse_into_containing_op(%producer, %loop)
        : (!transform.any_op, !transform.any_op)
        -> !monad.either<!adt.sum<definite, silenceable>, !transform.any_op, !transform.any_op>
    monad.either.branch %fusion, left ^fusion_failed, right ^fused
        : !monad.either<!adt.sum<definite, silenceable>, !transform.any_op, !transform.any_op>
  ^fusion_failed(%fusion_error: !adt.sum<definite, silenceable>):
    adt.switch %fusion_error : !adt.sum<definite, silenceable>, [
      definite: ^aborted,
      silenceable: ^fusion_suppressed
    ]
  ^fusion_suppressed:
    %unfused_pair = monad.return %producer, %loop
        : !monad.either<!adt.sum<definite>, !transform.any_op, !transform.any_op>
    monad.yield %unfused_pair : !monad.either<!adt.sum<definite>, !transform.any_op, !transform.any_op>
  ^aborted:
    %definite_error = adt.make definite : !adt.sum<definite>
    %abort = monad.either.left %definite_error
        : !monad.either<!adt.sum<definite>, !transform.any_op, !transform.any_op>
    monad.yield %abort : !monad.either<!adt.sum<definite>, !transform.any_op, !transform.any_op>
  ^fused(%fused_op: !transform.any_op, %new_loop: !transform.any_op):
    %fused_pair = monad.return %fused_op, %new_loop
        : !monad.either<!adt.sum<definite>, !transform.any_op, !transform.any_op>
    monad.yield %fused_pair : !monad.either<!adt.sum<definite>, !transform.any_op, !transform.any_op>
  }
  return %result : !monad.either<!adt.sum<definite>, !transform.any_op, !transform.any_op>
}
