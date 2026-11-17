// RUN: fum-opt %s | fum-opt | FileCheck %s
// RUN: fum-opt %s --convert-monad-to-cf | FileCheck %s --check-prefix=LOWERED

// P3 of the exception design: tile a matmul, then fuse a producer into the
// loop, suppressing the silenceable failures of both steps. Definite failures
// leave the function. The transform ops are modeled as functions returning
// either values whose left type is an error or an error union.

monad.error.declare @silenceable
monad.error.declare @definite

// CHECK-LABEL: func.func @tile_and_fuse
// CHECK: monad.do : !monad.either<!error_definite, !transform.any_op, !transform.any_op>
// CHECK: monad.do : !monad.either<!error_definite, !transform.any_op, !transform.any_op>
// CHECK: monad.error.catch %{{.+}}, ^[[TILED:.+]] [!error_silenceable -> ^[[SUPPRESSED:.+]]] : !monad.either<!error_silenceable, !transform.any_op, !transform.any_op>
// CHECK: ^[[TILED]](%{{.+}}: !transform.any_op, %{{.+}}: !transform.any_op):
// CHECK: ^[[SUPPRESSED]](%{{.+}}: !error_silenceable):
// CHECK: monad.bind
// CHECK: monad.error.catch %{{.+}}, ^{{.+}} [!error_silenceable -> ^{{.+}}] : !monad.either<!errors_definite_silenceable, !transform.any_op, !transform.any_op>

// The handles stay as they are in the value slots of the lowered values.
// LOWERED-LABEL: func.func @tile_and_fuse
// LOWERED-SAME: -> (i32, !transform.any_op, !transform.any_op)
// LOWERED: call @tile_using_forall(%{{.+}}) : (!transform.any_op) -> (i32, !transform.any_op, !transform.any_op)
// LOWERED: cf.switch
// LOWERED: call @fuse_into_containing_op
// LOWERED: cf.switch
// LOWERED-NOT: monad.
func.func private @tile_using_forall(%target: !transform.any_op)
    -> !monad.either<!monad.error<@silenceable>,
                     !transform.any_op, !transform.any_op>
// fuse_into_containing_op fails silenceably (producer cannot be fused) or definitely
// (containing handle is not a single op).
func.func private @fuse_into_containing_op(%producer: !transform.any_op, %containing: !transform.any_op)
    -> !monad.either<!monad.error_union<{!monad.error<@definite>, !monad.error<@silenceable>}>,
                     !transform.any_op, !transform.any_op>

func.func @tile_and_fuse(%matmul: !transform.any_op, %producer: !transform.any_op)
    -> !monad.either<!monad.error<@definite>,
                     !transform.any_op, !transform.any_op> {
  %result = monad.do
      : !monad.either<!monad.error<@definite>,
                      !transform.any_op, !transform.any_op> {
    // Step 1 with suppression. Both outcomes continue to step 2, but a block of a do has one
    // predecessor, so the "tiled or untiled" pair is computed by an inner do and then bound.
    %tiled_or_untiled = monad.do
        : !monad.either<!monad.error<@definite>,
                        !transform.any_op, !transform.any_op> {
      %tiling = func.call @tile_using_forall(%matmul) : (!transform.any_op)
          -> !monad.either<!monad.error<@silenceable>,
                           !transform.any_op, !transform.any_op>
      // Success goes to ^tiled; the silenceable failure is suppressed in ^tiling_suppressed.
      monad.error.catch %tiling, ^tiled [!monad.error<@silenceable> -> ^tiling_suppressed]
          : !monad.either<!monad.error<@silenceable>,
                          !transform.any_op, !transform.any_op>
    ^tiled(%tiled_op: !transform.any_op, %tiled_loop: !transform.any_op):
      %tiled_pair = monad.return %tiled_op, %tiled_loop
          : !monad.either<!monad.error<@definite>,
                          !transform.any_op, !transform.any_op>
      monad.yield %tiled_pair
          : !monad.either<!monad.error<@definite>,
                          !transform.any_op, !transform.any_op>
    ^tiling_suppressed(%tiling_error: !monad.error<@silenceable>):
      // Continue with the untiled matmul as both the tiled op and the "loop".
      %untiled_pair = monad.return %matmul, %matmul
          : !monad.either<!monad.error<@definite>,
                          !transform.any_op, !transform.any_op>
      monad.yield %untiled_pair
          : !monad.either<!monad.error<@definite>,
                          !transform.any_op, !transform.any_op>
    }
    // The inner do cannot fail; bind it to continue with the pair.
    monad.bind %tiled_or_untiled, ^after_tiling
        : !monad.either<!monad.error<@definite>,
                        !transform.any_op, !transform.any_op>
  ^after_tiling(%tiled_or_matmul: !transform.any_op, %loop: !transform.any_op):
    // Step 2 with suppression: the last step, so its inner do is the result of the sequence.
    %fused_or_unfused = monad.do
        : !monad.either<!monad.error<@definite>,
                        !transform.any_op, !transform.any_op> {
      %fusion = func.call @fuse_into_containing_op(%producer, %loop)
          : (!transform.any_op, !transform.any_op)
          -> !monad.either<!monad.error_union<{!monad.error<@definite>, !monad.error<@silenceable>}>,
                           !transform.any_op, !transform.any_op>
      // Success goes to ^fused; silenceable is suppressed; definite is not caught, so it ends
      // the inner do (whose union contains definite) and then the sequence.
      monad.error.catch %fusion, ^fused [!monad.error<@silenceable> -> ^fusion_suppressed]
          : !monad.either<!monad.error_union<{!monad.error<@definite>, !monad.error<@silenceable>}>,
                          !transform.any_op, !transform.any_op>
    ^fused(%fused_op: !transform.any_op, %new_loop: !transform.any_op):
      %fused_pair = monad.return %fused_op, %new_loop
          : !monad.either<!monad.error<@definite>,
                          !transform.any_op, !transform.any_op>
      monad.yield %fused_pair
          : !monad.either<!monad.error<@definite>,
                          !transform.any_op, !transform.any_op>
    ^fusion_suppressed(%fusion_error: !monad.error<@silenceable>):
      // Continue with the unfused producer and the loop from step 1.
      %unfused_pair = monad.return %producer, %loop
          : !monad.either<!monad.error<@definite>,
                          !transform.any_op, !transform.any_op>
      monad.yield %unfused_pair
          : !monad.either<!monad.error<@definite>,
                          !transform.any_op, !transform.any_op>
    }
    monad.yield %fused_or_unfused
        : !monad.either<!monad.error<@definite>,
                        !transform.any_op, !transform.any_op>
  }
  return %result
      : !monad.either<!monad.error<@definite>,
                      !transform.any_op, !transform.any_op>
}
// Ops in the body: do; do, call, catch, return, yield, return, yield; bind;
// do, call, catch, return, yield, return, yield; yield; func.return = 18.
//
// Alternatives (judged):
//  (a) KEPT: the inner dos have the outer do's type, so `bind` accepts them directly.
//  (b) precise inner types: step 1 cannot fail at all. The empty union is rejected, since
//      it has no value, so step 1 has no either type: its handles would come from a
//      monad.either.branch outside the do, which splits the sequence. Rejected.
//  (c) catch without ^ok (P2 alternative c): ^tiled and ^fused only re-wrap their arguments,
//      so they would disappear (18 -> 14 ops).
//  (d) failures(propagate) instead of suppress: no inner dos, but the tiling result must be
//      widened before it can be bound in the sequence's do:
//        %tiling_widened = monad.error.widen %tiling
//            : !monad.either<!monad.error<@silenceable>,
//                            (!transform.any_op, !transform.any_op)>
//            to !monad.either<!monad.error_union<{!monad.error<@definite>,
//                                                 !monad.error<@silenceable>}>,
//                             (!transform.any_op, !transform.any_op)>
//        monad.bind %tiling_widened, ^after_tiling
//            : !monad.either<!monad.error_union<{!monad.error<@definite>,
//                                                !monad.error<@silenceable>}>,
//                            (!transform.any_op, !transform.any_op)>
