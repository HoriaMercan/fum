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

// A widening followed by a widening back to the input type folds away.
// CHECK-LABEL: func.func @widen_back
// CHECK-SAME: (%[[ERROR:.*]]: !adt.sum<a, b>)
// CHECK-NEXT: return %[[ERROR]] : !adt.sum<a, b>
func.func @widen_back(%error: !adt.sum<a, b>) -> !adt.sum<a, b> {
  %reordered = adt.widen %error : !adt.sum<a, b> to !adt.sum<b, a>
  %back = adt.widen %reordered : !adt.sum<b, a> to !adt.sum<a, b>
  return %back : !adt.sum<a, b>
}
