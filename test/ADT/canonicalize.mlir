// RUN: fum-opt %s --canonicalize --split-input-file | FileCheck %s

// A match on a value built by adt.make reduces to the region of that case,
// with the fields as arguments.
// CHECK-LABEL: func.func @match_on_make
// CHECK-SAME: (%[[CODE:.*]]: i32)
// CHECK-NEXT: return %[[CODE]] : i32
func.func @match_on_make(%code: i32) -> i32 {
  %error = adt.make io(%code) : !adt.sum<div_by_zero, io(i32)>
  %result = adt.match %error : !adt.sum<div_by_zero, io(i32)> -> i32
  case div_by_zero {
    %zero = arith.constant 0 : i32
    adt.yield %zero : i32
  }
  case io(%value: i32) {
    adt.yield %value : i32
  }
  return %result : i32
}

// -----

// A case that no group lists reduces to the default region.
// CHECK-LABEL: func.func @match_on_make_default
// CHECK-NEXT: %[[SEVEN:.*]] = arith.constant 7 : i32
// CHECK-NEXT: return %[[SEVEN]] : i32
func.func @match_on_make_default() -> i32 {
  %error = adt.make overflow : !adt.sum<div_by_zero, overflow>
  %result = adt.match %error : !adt.sum<div_by_zero, overflow> -> i32
  case div_by_zero {
    %zero = arith.constant 0 : i32
    adt.yield %zero : i32
  }
  default {
    %seven = arith.constant 7 : i32
    adt.yield %seven : i32
  }
  return %result : i32
}

// -----

// Two widenings fold into one.
// CHECK-LABEL: func.func @widen_twice
// CHECK-SAME: (%[[ERROR:.*]]: !adt.sum<a>)
// CHECK-NEXT: %[[WIDER:.*]] = adt.widen %[[ERROR]] : !adt.sum<a> to !adt.sum<a, b, c>
// CHECK-NEXT: return %[[WIDER]]
func.func @widen_twice(%error: !adt.sum<a>) -> !adt.sum<a, b, c> {
  %ab = adt.widen %error : !adt.sum<a> to !adt.sum<a, b>
  %abc = adt.widen %ab : !adt.sum<a, b> to !adt.sum<a, b, c>
  return %abc : !adt.sum<a, b, c>
}

// -----

// A switch on a value built by adt.make branches to the successor of the
// case, with the fields.
// CHECK-LABEL: func.func @switch_on_make
// CHECK-SAME: (%[[CODE:.*]]: i32)
// CHECK-NEXT: return %[[CODE]] : i32
func.func @switch_on_make(%code: i32) -> i32 {
  %error = adt.make io(%code) : !adt.sum<eof, io(i32)>
  adt.switch %error : !adt.sum<eof, io(i32)>, [
    eof: ^eof,
    io: ^io
  ]
^io(%value: i32):
  return %value : i32
^eof:
  %zero = arith.constant 0 : i32
  return %zero : i32
}

// -----

// A switch on a select of two constructors is a conditional branch.
// CHECK-LABEL: func.func @switch_on_select
// CHECK-SAME: (%[[FLAG:.*]]: i1, %[[CODE:.*]]: i32)
// CHECK: cf.cond_br %[[FLAG]], ^[[IO:.*]](%[[CODE]] : i32), ^[[EOF:.*]]
func.func @switch_on_select(%flag: i1, %code: i32) -> i32 {
  %io = adt.make io(%code) : !adt.sum<eof, io(i32)>
  %eof = adt.make eof : !adt.sum<eof, io(i32)>
  %error = arith.select %flag, %io, %eof : !adt.sum<eof, io(i32)>
  adt.switch %error : !adt.sum<eof, io(i32)>, [
    eof: ^eof,
    io: ^io
  ]
^io(%value: i32):
  return %value : i32
^eof:
  %zero = arith.constant 0 : i32
  return %zero : i32
}

// -----

// Widening a constructor builds the same case in the wider sum.
// CHECK-LABEL: func.func @widen_of_make
// CHECK-NEXT: %[[MADE:.*]] = adt.make b : !adt.sum<a, b>
// CHECK-NEXT: return %[[MADE]]
func.func @widen_of_make() -> !adt.sum<a, b> {
  %b = adt.make b : !adt.sum<b>
  %wider = adt.widen %b : !adt.sum<b> to !adt.sum<a, b>
  return %wider : !adt.sum<a, b>
}
