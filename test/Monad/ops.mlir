// RUN: fum-opt %s | fum-opt | FileCheck %s
// RUN: fum-opt %s --mlir-print-op-generic | fum-opt | FileCheck %s

// Round-trip the maybe type with builtin and nested value types.
// CHECK-LABEL: func.func private @maybe_types
// CHECK-SAME: !monad.maybe<i32>
// CHECK-SAME: !monad.maybe<f32>
// CHECK-SAME: !monad.maybe<index>
// CHECK-SAME: !monad.maybe<!monad.maybe<i32>>
func.func private @maybe_types(!monad.maybe<i32>, !monad.maybe<f32>,
                               !monad.maybe<index>,
                               !monad.maybe<!monad.maybe<i32>>)

// Wrap a value as a success.
// CHECK-LABEL: func.func @wrap
// CHECK-SAME: (%[[VALUE:.+]]: i32) -> !monad.maybe<i32>
// CHECK: %[[RESULT:.+]] = monad.return %[[VALUE]] : !monad.maybe<i32>
// CHECK: return %[[RESULT]] : !monad.maybe<i32>
func.func @wrap(%value: i32) -> !monad.maybe<i32> {
  %result = monad.return %value : !monad.maybe<i32>
  return %result : !monad.maybe<i32>
}

// Wrap a monadic value into another layer of maybe.
// CHECK-LABEL: func.func @wrap_nested
// CHECK-SAME: (%[[VALUE:.+]]: !monad.maybe<i32>)
// CHECK: monad.return %[[VALUE]] : !monad.maybe<!monad.maybe<i32>>
func.func @wrap_nested(%value: !monad.maybe<i32>)
    -> !monad.maybe<!monad.maybe<i32>> {
  %result = monad.return %value : !monad.maybe<!monad.maybe<i32>>
  return %result : !monad.maybe<!monad.maybe<i32>>
}

// Create a failure.
// CHECK-LABEL: func.func @failure
// CHECK: %[[RESULT:.+]] = monad.fail : !monad.maybe<f32>
// CHECK: return %[[RESULT]] : !monad.maybe<f32>
func.func @failure() -> !monad.maybe<f32> {
  %result = monad.fail : !monad.maybe<f32>
  return %result : !monad.maybe<f32>
}
