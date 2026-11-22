// RUN: fum-opt %s | fum-opt | FileCheck %s
// RUN: fum-opt %s --mlir-print-op-generic | fum-opt | FileCheck %s

// Round-trip the maybe type with one, several, no, and nested value types.
// CHECK-LABEL: func.func private @maybe_types
// CHECK-SAME: !monad.maybe<i32>
// CHECK-SAME: !monad.maybe<i32, f32>
// CHECK-SAME: !monad.maybe<>
// CHECK-SAME: !monad.maybe<!monad.maybe<i32>>
func.func private @maybe_types(!monad.maybe<i32>, !monad.maybe<i32, f32>,
                               !monad.maybe<>, !monad.maybe<!monad.maybe<i32>>)

// Wrap several values, or none, as a success.
// CHECK-LABEL: func.func @wrap_values
// CHECK-SAME: (%[[A:.+]]: i32, %[[B:.+]]: f32)
// CHECK: monad.return %[[A]], %[[B]] : !monad.maybe<i32, f32>
// CHECK: monad.return : !monad.maybe<>
func.func @wrap_values(%a: i32, %b: f32)
    -> (!monad.maybe<i32, f32>, !monad.maybe<>) {
  %values = monad.return %a, %b : !monad.maybe<i32, f32>
  %nothing = monad.return : !monad.maybe<>
  return %values, %nothing : !monad.maybe<i32, f32>, !monad.maybe<>
}

// Create the maybe value that carries no value.
// CHECK-LABEL: func.func @maybe_none
// CHECK: monad.maybe.none : !monad.maybe<f32>
func.func @maybe_none() -> !monad.maybe<f32> {
  %result = monad.maybe.none : !monad.maybe<f32>
  return %result : !monad.maybe<f32>
}

// Bind the value carried by a maybe to a computation producing a maybe of
// another type.
// CHECK-LABEL: func.func @bind
// CHECK-SAME: (%[[INPUT:.+]]: !monad.maybe<i32>)
// CHECK: monad.do : !monad.maybe<f32> {
// CHECK: monad.bind %[[INPUT]], ^[[NEXT:.+]] : !monad.maybe<i32>
// CHECK: ^[[NEXT]](%{{.*}}: i32):
// CHECK: %[[WRAPPED:.+]] = monad.return %{{.*}} : !monad.maybe<f32>
// CHECK: monad.yield %[[WRAPPED]] : !monad.maybe<f32>
func.func @bind(%input: !monad.maybe<i32>) -> !monad.maybe<f32> {
  %result = monad.do : !monad.maybe<f32> {
    monad.bind %input, ^next : !monad.maybe<i32>
  ^next(%value: i32):
    %converted = arith.sitofp %value : i32 to f32
    %wrapped = monad.return %converted : !monad.maybe<f32>
    monad.yield %wrapped : !monad.maybe<f32>
  }
  return %result : !monad.maybe<f32>
}

// Bind a maybe carrying several values, and one carrying none.
// CHECK-LABEL: func.func @bind_values
// CHECK: monad.bind %{{.*}}, ^[[NEXT:.+]] : !monad.maybe<i32, i32>
// CHECK: ^[[NEXT]](%{{.*}}: i32, %{{.*}}: i32):
// CHECK: monad.bind %{{.*}}, ^[[GUARDED:.+]] : !monad.maybe<>
// CHECK: ^[[GUARDED]]:
func.func @bind_values(%pair: !monad.maybe<i32, i32>, %guard: !monad.maybe<>)
    -> !monad.maybe<i32> {
  %result = monad.do : !monad.maybe<i32> {
    monad.bind %pair, ^next : !monad.maybe<i32, i32>
  ^next(%a: i32, %b: i32):
    monad.bind %guard, ^guarded : !monad.maybe<>
  ^guarded:
    %sum = arith.addi %a, %b : i32
    %wrapped = monad.return %sum : !monad.maybe<i32>
    monad.yield %wrapped : !monad.maybe<i32>
  }
  return %result : !monad.maybe<i32>
}

// A single-block computation needs no predecessor for its entry block.
// CHECK-LABEL: func.func @do_single_block
// CHECK: monad.do : !monad.maybe<i32> {
// CHECK: monad.yield %{{.*}} : !monad.maybe<i32>
func.func @do_single_block(%input: !monad.maybe<i32>) -> !monad.maybe<i32> {
  %result = monad.do : !monad.maybe<i32> {
    monad.yield %input : !monad.maybe<i32>
  }
  return %result : !monad.maybe<i32>
}

// Build lefts and rights of a general either, and branch on them.
// CHECK-LABEL: func.func @either_general
// CHECK: monad.either.left %{{.+}} : !monad.either<i32, f32>
// CHECK: monad.return %{{.+}} : !monad.either<i32, f32>
// CHECK: monad.either.branch %{{.+}}, left ^[[LEFT:.+]], right ^[[RIGHT:.+]] : !monad.either<i32, f32>
// CHECK: ^[[LEFT]](%{{.+}}: i32):
// CHECK: ^[[RIGHT]](%{{.+}}: f32):
func.func @either_general(%x: i32, %y: f32, %flag: i1) -> i32 {
  %left = monad.either.left %x : !monad.either<i32, f32>
  %right = monad.return %y : !monad.either<i32, f32>
  %either = arith.select %flag, %left, %right : !monad.either<i32, f32>
  monad.either.branch %either, left ^left, right ^right : !monad.either<i32, f32>
^left(%l: i32):
  return %l : i32
^right(%r: f32):
  %converted = arith.fptosi %r : f32 to i32
  return %converted : i32
}

// One terminator may reach one block along several edges: both sides of an
// either with equal left and value types continue in the same block.
// CHECK-LABEL: func.func @branch_sides_to_one_block
// CHECK: monad.either.branch %{{.+}}, left ^[[MERGE:.+]], right ^[[MERGE]] : !monad.either<i32, i32>
func.func @branch_sides_to_one_block(%input: !monad.either<i32, i32>) -> !monad.maybe<i32> {
  %result = monad.do : !monad.maybe<i32> {
    monad.either.branch %input, left ^merge, right ^merge : !monad.either<i32, i32>
  ^merge(%value: i32):
    %wrapped = monad.return %value : !monad.maybe<i32>
    monad.yield %wrapped : !monad.maybe<i32>
  }
  return %result : !monad.maybe<i32>
}

// Branch on the side of an either value inside a do, whatever its left type.
// CHECK-LABEL: func.func @either_branch_in_do
// CHECK: monad.do : !monad.maybe<f32>
// CHECK: monad.either.branch %{{.+}}, left ^[[LEFT:.+]], right ^[[RIGHT:.+]] : !monad.either<i32, f32>
// CHECK: ^[[LEFT]](%{{.+}}: i32):
// CHECK: ^[[RIGHT]](%{{.+}}: f32):
func.func @either_branch_in_do(%input: !monad.either<i32, f32>) -> !monad.maybe<f32> {
  %as_maybe = monad.do : !monad.maybe<f32> {
    monad.either.branch %input, left ^left, right ^right : !monad.either<i32, f32>
  ^left(%l: i32):
    %none = monad.maybe.none : !monad.maybe<f32>
    monad.yield %none : !monad.maybe<f32>
  ^right(%r: f32):
    %some = monad.return %r : !monad.maybe<f32>
    monad.yield %some : !monad.maybe<f32>
  }
  return %as_maybe : !monad.maybe<f32>
}

// An either whose left type is a sum of errors: a failure is a case of the
// sum, put on the left; a right without values is written none.
// CHECK-LABEL: func.func @either_of_sum
// CHECK: %[[ERROR:.+]] = adt.make div_by_zero : !adt.sum<div_by_zero, overflow>
// CHECK: monad.either.left %[[ERROR]] : !monad.either<!adt.sum<div_by_zero, overflow>, none>
// CHECK: monad.return : !monad.either<!adt.sum<div_by_zero, overflow>, none>
func.func @either_of_sum(%flag: i1) -> !monad.either<!adt.sum<div_by_zero, overflow>, none> {
  %error = adt.make div_by_zero : !adt.sum<div_by_zero, overflow>
  %failure = monad.either.left %error : !monad.either<!adt.sum<div_by_zero, overflow>, none>
  %success = monad.return : !monad.either<!adt.sum<div_by_zero, overflow>, none>
  %result = arith.select %flag, %failure, %success : !monad.either<!adt.sum<div_by_zero, overflow>, none>
  return %result : !monad.either<!adt.sum<div_by_zero, overflow>, none>
}

// Catching: branch on the either, then match on the error; the handled case
// recovers, the other is rebuilt in the narrower left type of the result.
// CHECK-LABEL: func.func @catch_with_match
// CHECK: monad.either.branch %{{.+}}, left ^[[FAILED:.+]], right ^[[OK:.+]] : !monad.either<!adt.sum<div_by_zero, overflow>, i32>
// CHECK: ^[[FAILED]](%[[ERROR:.+]]: !adt.sum<div_by_zero, overflow>):
// CHECK: adt.match %[[ERROR]] : !adt.sum<div_by_zero, overflow> -> !monad.either<!adt.sum<overflow>, i32>
func.func @catch_with_match(%ratio: !monad.either<!adt.sum<div_by_zero, overflow>, i32>)
    -> !monad.either<!adt.sum<overflow>, i32> {
  %result = monad.do : !monad.either<!adt.sum<overflow>, i32> {
    monad.either.branch %ratio, left ^failed, right ^ok : !monad.either<!adt.sum<div_by_zero, overflow>, i32>
  ^failed(%error: !adt.sum<div_by_zero, overflow>):
    %handled = adt.match %error : !adt.sum<div_by_zero, overflow> -> !monad.either<!adt.sum<overflow>, i32>
    case div_by_zero {
      %zero = arith.constant 0 : i32
      %recovered = monad.return %zero : !monad.either<!adt.sum<overflow>, i32>
      adt.yield %recovered : !monad.either<!adt.sum<overflow>, i32>
    }
    case overflow {
      %overflow = adt.make overflow : !adt.sum<overflow>
      %rethrown = monad.either.left %overflow : !monad.either<!adt.sum<overflow>, i32>
      adt.yield %rethrown : !monad.either<!adt.sum<overflow>, i32>
    }
    monad.yield %handled : !monad.either<!adt.sum<overflow>, i32>
  ^ok(%value: i32):
    %success = monad.return %value : !monad.either<!adt.sum<overflow>, i32>
    monad.yield %success : !monad.either<!adt.sum<overflow>, i32>
  }
  return %result : !monad.either<!adt.sum<overflow>, i32>
}

// Inside a do, a block can branch on the case of an error to the block that
// handles it with adt.switch.
// CHECK-LABEL: func.func @switch_in_do
// CHECK: monad.either.branch %{{.+}}, left ^[[FAILED:.+]], right ^[[OK:.+]] : !monad.either<!adt.sum<div_by_zero, overflow>, i32>
// CHECK: ^[[FAILED]](%[[ERROR:.+]]: !adt.sum<div_by_zero, overflow>):
// CHECK: adt.switch %[[ERROR]] : !adt.sum<div_by_zero, overflow>, [
// CHECK-NEXT: div_by_zero: ^[[RECOVER:.+]],
// CHECK-NEXT: overflow: ^[[RETHROW:.+]]
func.func @switch_in_do(%ratio: !monad.either<!adt.sum<div_by_zero, overflow>, i32>)
    -> !monad.either<!adt.sum<overflow>, i32> {
  %result = monad.do : !monad.either<!adt.sum<overflow>, i32> {
    monad.either.branch %ratio, left ^failed, right ^ok : !monad.either<!adt.sum<div_by_zero, overflow>, i32>
  ^failed(%error: !adt.sum<div_by_zero, overflow>):
    adt.switch %error : !adt.sum<div_by_zero, overflow>, [
      div_by_zero: ^recover,
      overflow: ^rethrow
    ]
  ^recover:
    %zero = arith.constant 0 : i32
    %recovered = monad.return %zero : !monad.either<!adt.sum<overflow>, i32>
    monad.yield %recovered : !monad.either<!adt.sum<overflow>, i32>
  ^rethrow:
    %overflow = adt.make overflow : !adt.sum<overflow>
    %rethrown = monad.either.left %overflow : !monad.either<!adt.sum<overflow>, i32>
    monad.yield %rethrown : !monad.either<!adt.sum<overflow>, i32>
  ^ok(%value: i32):
    %success = monad.return %value : !monad.either<!adt.sum<overflow>, i32>
    monad.yield %success : !monad.either<!adt.sum<overflow>, i32>
  }
  return %result : !monad.either<!adt.sum<overflow>, i32>
}
