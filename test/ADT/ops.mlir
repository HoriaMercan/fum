// RUN: fum-opt %s | fum-opt | FileCheck %s
// RUN: fum-opt %s --mlir-print-op-generic | fum-opt | FileCheck %s

// A case without fields has one value and no parentheses; a case with fields
// lists their types; a field may be another sum.
// CHECK-LABEL: func.func private @types
// CHECK-SAME: !adt.sum<div_by_zero>
// CHECK-SAME: !adt.sum<div_by_zero, io(i32), out_of_bounds(index, index)>
// CHECK-SAME: !adt.sum<parse(!adt.sum<eof, unexpected(i8)>), io(i32)>
func.func private @types(!adt.sum<div_by_zero>,
                         !adt.sum<div_by_zero, io(i32), out_of_bounds(index, index)>,
                         !adt.sum<parse(!adt.sum<eof, unexpected(i8)>), io(i32)>)

// CHECK-LABEL: func.func @make
func.func @make(%code: i32) -> (!adt.sum<div_by_zero, io(i32)>, !adt.sum<div_by_zero, io(i32)>) {
  // CHECK: adt.make div_by_zero : !adt.sum<div_by_zero, io(i32)>
  %division = adt.make div_by_zero : !adt.sum<div_by_zero, io(i32)>
  // CHECK: adt.make io(%{{.*}}) : !adt.sum<div_by_zero, io(i32)>
  %io = adt.make io(%code) : !adt.sum<div_by_zero, io(i32)>
  return %division, %io : !adt.sum<div_by_zero, io(i32)>, !adt.sum<div_by_zero, io(i32)>
}

// An exhaustive match: a group of two cases without fields, and a case with
// one field.
// CHECK-LABEL: func.func @match_exhaustive
func.func @match_exhaustive(%error: !adt.sum<div_by_zero, overflow, io(i32)>) -> i32 {
  // CHECK: adt.match %{{.*}} : !adt.sum<div_by_zero, overflow, io(i32)> -> i32
  // CHECK-NEXT: case div_by_zero, overflow {
  // CHECK: adt.yield %{{.*}} : i32
  // CHECK: case io(%[[CODE:.*]]: i32) {
  // CHECK-NEXT: adt.yield %[[CODE]] : i32
  %result = adt.match %error : !adt.sum<div_by_zero, overflow, io(i32)> -> i32
  case div_by_zero, overflow {
    %zero = arith.constant 0 : i32
    adt.yield %zero : i32
  }
  case io(%code: i32) {
    adt.yield %code : i32
  }
  return %result : i32
}

// A group of cases with the same fields binds them once.
// CHECK-LABEL: func.func @match_group_with_fields
func.func @match_group_with_fields(%error: !adt.sum<read(i32), write(i32), eof>) -> i32 {
  // CHECK: case read, write(%[[CODE:.*]]: i32) {
  // CHECK-NEXT: adt.yield %[[CODE]] : i32
  // CHECK: case eof {
  %result = adt.match %error : !adt.sum<read(i32), write(i32), eof> -> i32
  case read, write(%code: i32) {
    adt.yield %code : i32
  }
  case eof {
    %zero = arith.constant 0 : i32
    adt.yield %zero : i32
  }
  return %result : i32
}

// The default case runs for the cases that are not listed, and takes no
// argument: the input is still in scope.
// CHECK-LABEL: func.func @match_default
// CHECK-SAME: (%[[ERROR:.*]]: !adt.sum<div_by_zero, io(i32), overflow>)
func.func @match_default(%error: !adt.sum<div_by_zero, io(i32), overflow>)
    -> !adt.sum<div_by_zero, io(i32), overflow> {
  // CHECK: adt.match %[[ERROR]] : !adt.sum<div_by_zero, io(i32), overflow> -> !adt.sum<div_by_zero, io(i32), overflow>
  // CHECK: case io(%{{.*}}: i32) {
  // CHECK: default {
  // CHECK-NEXT: adt.yield %[[ERROR]] : !adt.sum<div_by_zero, io(i32), overflow>
  %result = adt.match %error : !adt.sum<div_by_zero, io(i32), overflow> -> !adt.sum<div_by_zero, io(i32), overflow>
  case io(%code: i32) {
    %overflow = adt.make overflow : !adt.sum<div_by_zero, io(i32), overflow>
    adt.yield %overflow : !adt.sum<div_by_zero, io(i32), overflow>
  }
  default {
    adt.yield %error : !adt.sum<div_by_zero, io(i32), overflow>
  }
  return %result : !adt.sum<div_by_zero, io(i32), overflow>
}

// A match without results.
// CHECK-LABEL: func.func @match_no_results
func.func @match_no_results(%error: !adt.sum<a, b>) {
  // CHECK: adt.match %{{.*}} : !adt.sum<a, b>{{$}}
  // CHECK-NEXT: case a {
  // CHECK-NEXT: adt.yield{{$}}
  adt.match %error : !adt.sum<a, b>
  case a {
    adt.yield
  }
  case b {
    adt.yield
  }
  return
}

// Widening to a sum with more cases, in another order.
// CHECK-LABEL: func.func @widen
func.func @widen(%error: !adt.sum<overflow, io(i32)>) -> !adt.sum<io(i32), div_by_zero, overflow> {
  // CHECK: adt.widen %{{.*}} : !adt.sum<overflow, io(i32)> to !adt.sum<io(i32), div_by_zero, overflow>
  %wider = adt.widen %error : !adt.sum<overflow, io(i32)> to !adt.sum<io(i32), div_by_zero, overflow>
  return %wider : !adt.sum<io(i32), div_by_zero, overflow>
}
