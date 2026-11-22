// RUN: fum-opt %s | fum-opt | FileCheck %s
// RUN: fum-opt %s --mlir-print-op-generic | fum-opt | FileCheck %s

// A case without fields has one value and no parentheses; a case with fields
// lists their types; a field may be another sum. Cases print sorted by name.
// CHECK-LABEL: func.func private @types
// CHECK-SAME: !adt.sum<div_by_zero>
// CHECK-SAME: !adt.sum<div_by_zero, io(i32), out_of_bounds(index, index)>
// CHECK-SAME: !adt.sum<io(i32), parse(!adt.sum<eof, unexpected(i8)>)>
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
  // CHECK: adt.match %{{.*}} : !adt.sum<div_by_zero, io(i32), overflow> -> i32
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

// Widening to a sum with more cases; the order in which they are written
// does not matter.
// CHECK-LABEL: func.func @widen
func.func @widen(%error: !adt.sum<overflow, io(i32)>) -> !adt.sum<io(i32), div_by_zero, overflow> {
  // CHECK: adt.widen %{{.*}} : !adt.sum<io(i32), overflow> to !adt.sum<div_by_zero, io(i32), overflow>
  %wider = adt.widen %error : !adt.sum<overflow, io(i32)> to !adt.sum<io(i32), div_by_zero, overflow>
  return %wider : !adt.sum<io(i32), div_by_zero, overflow>
}

// The order in which the cases are written does not matter: both spellings
// are the same type, so no conversion is needed.
// CHECK-LABEL: func.func @same_type
// CHECK-SAME: (%[[ERROR:.*]]: !adt.sum<div_by_zero, io(i32)>) -> !adt.sum<div_by_zero, io(i32)>
// CHECK-NEXT: return %[[ERROR]] : !adt.sum<div_by_zero, io(i32)>
func.func @same_type(%error: !adt.sum<io(i32), div_by_zero>) -> !adt.sum<div_by_zero, io(i32)> {
  return %error : !adt.sum<io(i32), div_by_zero>
}

// A switch branches to the successor of the case, which receives its fields;
// the default case is printed first and takes no argument.
// CHECK-LABEL: func.func @switch
// CHECK: adt.switch %{{.*}} : !adt.sum<div_by_zero, io(i32), overflow>, [
// CHECK-NEXT: default: ^[[OTHER:.*]],
// CHECK-NEXT: io: ^[[IO:.*]]
// CHECK-NEXT: ]
// CHECK: ^[[IO]](%{{.*}}: i32):
// CHECK: ^[[OTHER]]:
func.func @switch(%error: !adt.sum<div_by_zero, io(i32), overflow>) -> i32 {
  adt.switch %error : !adt.sum<div_by_zero, io(i32), overflow>, [
    default: ^other,
    io: ^io
  ]
^io(%code: i32):
  return %code : i32
^other:
  %zero = arith.constant 0 : i32
  return %zero : i32
}

// Cases with the same fields may share a successor.
// CHECK-LABEL: func.func @switch_shared_successor
// CHECK: adt.switch %{{.*}} : !adt.sum<eof, read(i32), write(i32)>, [
// CHECK-NEXT: eof: ^{{.*}},
// CHECK-NEXT: read: ^[[CODE:.*]],
// CHECK-NEXT: write: ^[[CODE]]
func.func @switch_shared_successor(%error: !adt.sum<read(i32), write(i32), eof>) -> i32 {
  adt.switch %error : !adt.sum<read(i32), write(i32), eof>, [
    eof: ^end,
    read: ^code,
    write: ^code
  ]
^code(%code: i32):
  return %code : i32
^end:
  %zero = arith.constant 0 : i32
  return %zero : i32
}
