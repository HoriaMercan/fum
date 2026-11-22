// RUN: fum-opt %s --convert-adt-to-scf --split-input-file | FileCheck %s

// A sum becomes an i32 tag and the slots of every case, in name order; a
// case gets its position as tag, and poison in the slots of the other cases.
// CHECK-LABEL: func.func @make
// CHECK-SAME: (%[[CODE:.*]]: i32) -> (i32, i32)
// CHECK: %[[TAG_IO:.*]] = arith.constant 1 : i32
// CHECK: return %[[TAG_IO]], %[[CODE]] : i32, i32
func.func @make(%code: i32) -> !adt.sum<io(i32), div_by_zero> {
  %error = adt.make io(%code) : !adt.sum<io(i32), div_by_zero>
  return %error : !adt.sum<div_by_zero, io(i32)>
}

// -----

// A match becomes scf.index_switch on the tag; the fields of a case are its
// slots. An exhaustive match yields poison in the default region.
// CHECK-LABEL: func.func @match
// CHECK-SAME: (%[[TAG:.*]]: i32, %[[CODE:.*]]: i32) -> i32
// CHECK: %[[INDEX:.*]] = arith.index_cast %[[TAG]] : i32 to index
// CHECK: %[[RESULT:.*]] = scf.index_switch %[[INDEX]] -> i32
// CHECK: case 0 {
// CHECK: scf.yield %{{.*}} : i32
// CHECK: case 1 {
// CHECK-NEXT: scf.yield %[[CODE]] : i32
// CHECK: default {
// CHECK-NEXT: %[[POISON:.*]] = ub.poison : i32
// CHECK-NEXT: scf.yield %[[POISON]] : i32
// CHECK: return %[[RESULT]] : i32
func.func @match(%error: !adt.sum<div_by_zero, io(i32)>) -> i32 {
  %result = adt.match %error : !adt.sum<div_by_zero, io(i32)> -> i32
  case div_by_zero {
    %zero = arith.constant 0 : i32
    adt.yield %zero : i32
  }
  case io(%code: i32) {
    adt.yield %code : i32
  }
  return %result : i32
}

// -----

// A group gets one switch case per case of the group, and the default region
// is kept.
// CHECK-LABEL: func.func @match_group_default
// CHECK: scf.index_switch %{{.*}} -> i32
// CHECK: case 1 {
// CHECK: case 2 {
// CHECK: default {
// CHECK-NEXT: %[[SEVEN:.*]] = arith.constant 7 : i32
// CHECK-NEXT: scf.yield %[[SEVEN]] : i32
func.func @match_group_default(%error: !adt.sum<a, b, c>) -> i32 {
  %result = adt.match %error : !adt.sum<a, b, c> -> i32
  case b, c {
    %one = arith.constant 1 : i32
    adt.yield %one : i32
  }
  default {
    %seven = arith.constant 7 : i32
    adt.yield %seven : i32
  }
  return %result : i32
}

// -----

// A widening maps every tag of the input to the tag of the same case in the
// result, and copies the slots of the cases of the input.
// CHECK-LABEL: func.func @widen
// CHECK-SAME: (%[[TAG:.*]]: i32, %[[CODE:.*]]: i32) -> (i32, i32)
// CHECK-DAG: %[[ONE:.*]] = arith.constant 1 : i32
// CHECK-DAG: %[[TWO:.*]] = arith.constant 2 : i32
// CHECK: %[[IS_OVERFLOW:.*]] = arith.cmpi eq, %[[TAG]], %{{.*}} : i32
// CHECK: %[[NEW_TAG:.*]] = arith.select %[[IS_OVERFLOW]], %[[TWO]], %[[ONE]] : i32
// CHECK: return %[[NEW_TAG]], %[[CODE]] : i32, i32
func.func @widen(%error: !adt.sum<io(i32), overflow>) -> !adt.sum<div_by_zero, io(i32), overflow> {
  %wider = adt.widen %error : !adt.sum<io(i32), overflow> to !adt.sum<div_by_zero, io(i32), overflow>
  return %wider : !adt.sum<div_by_zero, io(i32), overflow>
}
