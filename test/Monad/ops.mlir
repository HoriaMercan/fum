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

// Create a maybe failure.
// CHECK-LABEL: func.func @maybe_failure
// CHECK: %[[RESULT:.+]] = monad.maybe.fail : !monad.maybe<f32>
// CHECK: return %[[RESULT]] : !monad.maybe<f32>
func.func @maybe_failure() -> !monad.maybe<f32> {
  %result = monad.maybe.fail : !monad.maybe<f32>
  return %result : !monad.maybe<f32>
}

// Bind the value carried by a maybe to a computation producing a maybe of
// another type.
// CHECK-LABEL: func.func @bind
// CHECK-SAME: (%[[INPUT:.+]]: !monad.maybe<i32>) -> !monad.maybe<f32>
// CHECK: %[[RESULT:.+]] = monad.maybe.bind %[[INPUT]] : !monad.maybe<i32> -> !monad.maybe<f32> {
// CHECK-NEXT: ^{{.*}}(%[[VALUE:.+]]: i32):
// CHECK-NEXT: %[[CONVERTED:.+]] = arith.sitofp %[[VALUE]] : i32 to f32
// CHECK-NEXT: %[[WRAPPED:.+]] = monad.return %[[CONVERTED]] : !monad.maybe<f32>
// CHECK-NEXT: monad.yield %[[WRAPPED]] : !monad.maybe<f32>
// CHECK-NEXT: }
// CHECK: return %[[RESULT]] : !monad.maybe<f32>
func.func @bind(%input: !monad.maybe<i32>) -> !monad.maybe<f32> {
  %result = monad.maybe.bind %input : !monad.maybe<i32> -> !monad.maybe<f32> {
  ^bb0(%value: i32):
    %converted = arith.sitofp %value : i32 to f32
    %wrapped = monad.return %converted : !monad.maybe<f32>
    monad.yield %wrapped : !monad.maybe<f32>
  }
  return %result : !monad.maybe<f32>
}

// Bind to a computation that fails.
// CHECK-LABEL: func.func @bind_to_failure
// CHECK: monad.maybe.bind %{{.*}} : !monad.maybe<i32> -> !monad.maybe<i32> {
// CHECK-NEXT: ^{{.*}}(%{{.*}}: i32):
// CHECK-NEXT: %[[FAILURE:.+]] = monad.maybe.fail : !monad.maybe<i32>
// CHECK-NEXT: monad.yield %[[FAILURE]] : !monad.maybe<i32>
// CHECK-NEXT: }
func.func @bind_to_failure(%input: !monad.maybe<i32>) -> !monad.maybe<i32> {
  %result = monad.maybe.bind %input : !monad.maybe<i32> -> !monad.maybe<i32> {
  ^bb0(%value: i32):
    %failure = monad.maybe.fail : !monad.maybe<i32>
    monad.yield %failure : !monad.maybe<i32>
  }
  return %result : !monad.maybe<i32>
}

// Use the result of a bind in further computations: add the values carried by
// two maybe values, which fails if either input fails.
// CHECK-LABEL: func.func @bind_chain
// CHECK-SAME: (%[[LHS:.+]]: !monad.maybe<i32>, %[[RHS:.+]]: !monad.maybe<i32>)
// CHECK: %[[SUM:.+]] = monad.maybe.bind %[[LHS]] : !monad.maybe<i32> -> !monad.maybe<i32> {
// CHECK-NEXT: ^{{.*}}(%[[X:.+]]: i32):
// CHECK-NEXT: %[[INNER:.+]] = monad.maybe.bind %[[RHS]] : !monad.maybe<i32> -> !monad.maybe<i32> {
// CHECK-NEXT: ^{{.*}}(%[[Y:.+]]: i32):
// CHECK-NEXT: %[[ADD:.+]] = arith.addi %[[X]], %[[Y]] : i32
// CHECK-NEXT: %[[WRAPPED:.+]] = monad.return %[[ADD]] : !monad.maybe<i32>
// CHECK-NEXT: monad.yield %[[WRAPPED]] : !monad.maybe<i32>
// CHECK-NEXT: }
// CHECK-NEXT: monad.yield %[[INNER]] : !monad.maybe<i32>
// CHECK-NEXT: }
// CHECK: %[[DOUBLED:.+]] = monad.maybe.bind %[[SUM]]
// CHECK: return %[[DOUBLED]] : !monad.maybe<i32>
func.func @bind_chain(%lhs: !monad.maybe<i32>, %rhs: !monad.maybe<i32>)
    -> !monad.maybe<i32> {
  %sum = monad.maybe.bind %lhs : !monad.maybe<i32> -> !monad.maybe<i32> {
  ^bb0(%x: i32):
    %inner = monad.maybe.bind %rhs : !monad.maybe<i32> -> !monad.maybe<i32> {
    ^bb0(%y: i32):
      %add = arith.addi %x, %y : i32
      %wrapped = monad.return %add : !monad.maybe<i32>
      monad.yield %wrapped : !monad.maybe<i32>
    }
    monad.yield %inner : !monad.maybe<i32>
  }
  %doubled = monad.maybe.bind %sum : !monad.maybe<i32> -> !monad.maybe<i32> {
  ^bb0(%s: i32):
    %twice = arith.addi %s, %s : i32
    %wrapped = monad.return %twice : !monad.maybe<i32>
    monad.yield %wrapped : !monad.maybe<i32>
  }
  return %doubled : !monad.maybe<i32>
}
