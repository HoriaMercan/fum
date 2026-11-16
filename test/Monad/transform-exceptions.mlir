// RUN: fum-opt %s | fum-opt | FileCheck %s

// A transform sequence with suppressed silenceable failures, modeled with the
// value-or-error monad: a silenceable failure of a step is suppressed and the
// sequence continues with fallback handles, a definite failure propagates.
// The silenceable error carries a diagnostic id that the handlers read.

// CHECK-LABEL: func.func @tile_and_fuse
// CHECK-SAME: -> !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!error_definite}>
// CHECK: monad.do
// CHECK: monad.catch %{{.*}}, ^[[TILED:.+]] [!error_silenceable -> ^[[TILING_FAILED:[a-z0-9_]+]]]
// CHECK: ^[[TILED]](%{{.*}}: !transform.any_op, %{{.*}}: !transform.any_op):
// CHECK: ^[[TILING_FAILED]](%[[TILING_ERROR:.+]]: !error_silenceable):
// CHECK: monad.error.payload %[[TILING_ERROR]] : !error_silenceable
// CHECK: monad.bind
// CHECK: monad.do
// CHECK: monad.catch %{{.*}}, ^[[FUSED:.+]] [!error_silenceable -> ^[[FUSION_FAILED:[a-z0-9_]+]]] : !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!error_definite, !error_silenceable}>
// CHECK: ^[[FUSED]](%{{.*}}: !transform.any_op, %{{.*}}: !transform.any_op):
// CHECK: ^[[FUSION_FAILED]](%{{.*}}: !error_silenceable):

// Models of the transform operations.
// tile_using_forall fails only silenceably.
func.func private @tile_using_forall(!transform.any_op)
    -> !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"silenceable", i32>}>
// fuse_into_containing_op fails silenceably (the producer cannot be fused) or
// definitely (the containing handle is not a single op).
func.func private @fuse_into_containing_op(!transform.any_op, !transform.any_op)
    -> !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"definite">, !monad.error<"silenceable", i32>}>
// Records the diagnostic id of a suppressed failure.
func.func private @report_suppressed(i32)


func.func @tile_and_fuse(%matmul: !transform.any_op, %producer: !transform.any_op)
    -> !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"definite">}> {
  %result = monad.do
      : !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"definite">}> {
    // Step 1, with its silenceable failure suppressed. A nested do is needed
    // because both outcomes continue with the same code, and a block of a do
    // may have only one predecessor. Its type is the sequence's type, so the
    // outer bind accepts it.
    %tiling = monad.do
        : !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"definite">}> {
      // %tiled, %loop = transform.structured.tile_using_forall %matmul
      %tile = func.call @tile_using_forall(%matmul) : (!transform.any_op)
          -> !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"silenceable", i32>}>
      monad.catch %tile, ^tiled [!monad.error<"silenceable", i32> -> ^tiling_failed]
          : !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"silenceable", i32>}>
    ^tiled(%tiled_op: !transform.any_op, %tiled_loop: !transform.any_op):
      %tiled_handles = monad.return %tiled_op, %tiled_loop
          : !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"definite">}>
      monad.yield %tiled_handles
          : !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"definite">}>
    ^tiling_failed(%tiling_error: !monad.error<"silenceable", i32>):
      // Read the diagnostic id carried by the error, then suppress it.
      %tiling_diagnostic = monad.error.payload %tiling_error : !monad.error<"silenceable", i32>
      func.call @report_suppressed(%tiling_diagnostic) : (i32) -> ()
      // Continue with the untiled matmul as both the tiled op and the loop.
      %untiled_handles = monad.return %matmul, %matmul
          : !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"definite">}>
      monad.yield %untiled_handles
          : !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"definite">}>
    }
    monad.bind %tiling, ^after_tiling
        : !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"definite">}>
  ^after_tiling(%tiled: !transform.any_op, %loop: !transform.any_op):
    // Step 2: silenceable failure suppressed, definite failure not caught.
    %fusion = monad.do
        : !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"definite">}> {
      // %fused, %new_loop = transform.structured.fuse_into_containing_op
      //     %producer into %loop
      %fuse = func.call @fuse_into_containing_op(%producer, %loop)
          : (!transform.any_op, !transform.any_op)
          -> !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"definite">, !monad.error<"silenceable", i32>}>
      // Success goes to ^fused, silenceable to ^fusion_failed; definite
      // leaves this do (and then, through the yield, the sequence).
      monad.catch %fuse, ^fused [!monad.error<"silenceable", i32> -> ^fusion_failed]
          : !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"definite">, !monad.error<"silenceable", i32>}>
    ^fused(%fused_op: !transform.any_op, %new_loop: !transform.any_op):
      %fused_handles = monad.return %fused_op, %new_loop
          : !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"definite">}>
      monad.yield %fused_handles
          : !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"definite">}>
    ^fusion_failed(%fusion_error: !monad.error<"silenceable", i32>):
      %fusion_diagnostic = monad.error.payload %fusion_error : !monad.error<"silenceable", i32>
      func.call @report_suppressed(%fusion_diagnostic) : (i32) -> ()
      // Continue with the unfused producer and the loop from step 1.
      %unfused_handles = monad.return %producer, %loop
          : !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"definite">}>
      monad.yield %unfused_handles
          : !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"definite">}>
    }
    // The last step's outcome is the sequence's outcome.
    monad.yield %fusion
        : !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"definite">}>
  }
  return %result
      : !monad.value_or_error<[!transform.any_op, !transform.any_op] throws {!monad.error<"definite">}>
}
