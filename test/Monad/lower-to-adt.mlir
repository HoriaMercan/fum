// RUN: fum-opt %s --convert-monad-to-adt | FileCheck %s
// RUN: fum-opt %s --convert-monad-to-adt --canonicalize | FileCheck %s --check-prefix=CANON

// Lowering of the monad dialect to sum types and control flow. The programs
// at the end are executed by run-lowered.sh: @main returns 0 if every check
// passes, and otherwise the number of the first failing check.

// A maybe is the sum of just and nothing; without values, it is only a tag.
// CHECK-LABEL: func.func private @maybe_types
// CHECK-SAME: !adt.sum<just(i32, f32), nothing>
// CHECK-SAME: !adt.sum<just, nothing>
func.func private @maybe_types(!monad.maybe<i32, f32>, !monad.maybe<>)

// An either is the sum of left and right; an either whose left type is a sum
// is merged with it, unless the sum has a case named right.
// CHECK-LABEL: func.func private @either_types
// CHECK-SAME: !adt.sum<left(i32), right(f32)>
// CHECK-SAME: !adt.sum<div_by_zero, overflow, right(i32)>
// CHECK-SAME: !adt.sum<div_by_zero, right>
// CHECK-SAME: !adt.sum<left(!adt.sum<right, wrong>), right(i32)>
func.func private @either_types(!monad.either<i32, f32>,
                                !monad.either<!adt.sum<div_by_zero, overflow>, i32>,
                                !monad.either<!adt.sum<div_by_zero>, none>,
                                !monad.either<!adt.sum<right, wrong>, i32>)

// A bind becomes a switch: just continues, nothing is rebuilt in the type of
// the do, which it ends.
// CHECK-LABEL: func.func @maybe_bind
// CHECK: adt.switch %{{.+}} : !adt.sum<just(i32), nothing>, [
// CHECK-NEXT: just: ^[[NEXT:.+]],
// CHECK-NEXT: nothing: ^[[NOTHING:.+]]
// CHECK-NEXT: ]
// CHECK: ^[[NOTHING]]:
// CHECK-NEXT: %[[REBUILT:.+]] = adt.make nothing : !adt.sum<just(f32), nothing>
// CHECK-NEXT: cf.br ^[[EXIT:.+]](%[[REBUILT]] : !adt.sum<just(f32), nothing>)
// CHECK: ^[[NEXT]](%{{.+}}: i32):
func.func @maybe_bind(%input: !monad.maybe<i32>) -> !monad.maybe<f32> {
  %result = monad.do : !monad.maybe<f32> {
    monad.bind %input, ^next : !monad.maybe<i32>
  ^next(%value: i32):
    %converted = arith.sitofp %value : i32 to f32
    %success = monad.return %converted : !monad.maybe<f32>
    monad.yield %success : !monad.maybe<f32>
  }
  return %result : !monad.maybe<f32>
}

// A bind whose input has the type of the do passes the input on as is.
// CHECK-LABEL: func.func @bind_same_type
// CHECK-SAME: (%[[INPUT:.+]]: !adt.sum<just(i32), nothing>)
// CHECK: adt.switch %[[INPUT]] : !adt.sum<just(i32), nothing>, [
// CHECK-NEXT: default: ^[[PROPAGATE:.+]],
// CHECK-NEXT: just: ^{{.+}}
// CHECK: ^[[PROPAGATE]]:
// CHECK-NEXT: cf.br ^{{.+}}(%[[INPUT]] : !adt.sum<just(i32), nothing>)
func.func @bind_same_type(%input: !monad.maybe<i32>) -> !monad.maybe<i32> {
  %result = monad.do : !monad.maybe<i32> {
    monad.bind %input, ^next : !monad.maybe<i32>
  ^next(%value: i32):
    %success = monad.return %value : !monad.maybe<i32>
    monad.yield %success : !monad.maybe<i32>
  }
  return %result : !monad.maybe<i32>
}

// A left of a merged either keeps the case of the error: it is the widening
// of the error, which canonicalization folds into the constructor.
// CHECK-LABEL: func.func @merged_left
// CHECK: %[[ERROR:.+]] = adt.make overflow : !adt.sum<div_by_zero, overflow>
// CHECK: adt.widen %[[ERROR]] : !adt.sum<div_by_zero, overflow> to !adt.sum<div_by_zero, overflow, right(i32)>
// CANON-LABEL: func.func @merged_left
// CANON-NEXT: %[[MADE:.+]] = adt.make overflow : !adt.sum<div_by_zero, overflow, right(i32)>
// CANON-NEXT: return %[[MADE]]
func.func @merged_left() -> !monad.either<!adt.sum<div_by_zero, overflow>, i32> {
  %error = adt.make overflow : !adt.sum<div_by_zero, overflow>
  %failure = monad.either.left %error : !monad.either<!adt.sum<div_by_zero, overflow>, i32>
  return %failure : !monad.either<!adt.sum<div_by_zero, overflow>, i32>
}

// A left of an either that is not merged is the case left.
// CHECK-LABEL: func.func @general_left
// CHECK: adt.make left(%{{.+}}) : !adt.sum<left(i32), right(f32)>
func.func @general_left(%value: i32) -> !monad.either<i32, f32> {
  %failure = monad.either.left %value : !monad.either<i32, f32>
  return %failure : !monad.either<i32, f32>
}

// A branch on a merged either rebuilds the error in the left type before
// branching to the left successor.
// CHECK-LABEL: func.func @merged_branch
// CHECK: adt.switch %{{.+}} : !adt.sum<div_by_zero, overflow, right(i32)>, [
// CHECK-NEXT: right: ^[[RIGHT:.+]],
// CHECK-NEXT: div_by_zero: ^[[DIV:.+]],
// CHECK-NEXT: overflow: ^{{.+}}
// CHECK: ^[[DIV]]:
// CHECK-NEXT: %[[ERROR:.+]] = adt.make div_by_zero : !adt.sum<div_by_zero, overflow>
// CHECK-NEXT: cf.br ^[[LEFT:.+]](%[[ERROR]] : !adt.sum<div_by_zero, overflow>)
func.func @merged_branch(%input: !monad.either<!adt.sum<div_by_zero, overflow>, i32>) -> i32 {
  monad.either.branch %input, left ^left, right ^right : !monad.either<!adt.sum<div_by_zero, overflow>, i32>
^left(%error: !adt.sum<div_by_zero, overflow>):
  %code = adt.match %error : !adt.sum<div_by_zero, overflow> -> i32
  case div_by_zero, overflow {
    %minus_one = arith.constant -1 : i32
    adt.yield %minus_one : i32
  }
  return %code : i32
^right(%value: i32):
  return %value : i32
}

// safe_div lowers to the definition it was written from: two checks and
// three constructors of one merged sum.
// CANON-LABEL: func.func @safe_div
// CANON-SAME: -> !adt.sum<div_by_zero, overflow, right(i32)>
// CANON: cf.cond_br
// CANON: adt.make div_by_zero : !adt.sum<div_by_zero, overflow, right(i32)>
// CANON: cf.cond_br
// CANON: adt.make overflow : !adt.sum<div_by_zero, overflow, right(i32)>
// CANON: arith.divsi
// CANON: adt.make right(%{{.+}}) : !adt.sum<div_by_zero, overflow, right(i32)>
// CANON-NOT: adt.switch
// CANON-LABEL: func.func @half_ratio

// After case-of-case threading, half_ratio switches once on the result of
// safe_div: div_by_zero recovers, overflow is passed on, right is halved.
// CANON: adt.switch %{{.+}} : !adt.sum<div_by_zero, overflow, right(i32)>, [
// CANON-NEXT: right: ^[[HALVE:.+]],
// CANON-NEXT: div_by_zero: ^[[RECOVER:.+]],
// CANON-NEXT: overflow: ^[[PASS:.+]]
// CANON-NEXT: ]
// CANON: ^[[RECOVER]]:
// CANON-NEXT: adt.make right(%{{.+}}) : !adt.sum<overflow, right(i32)>
// CANON: ^[[PASS]]:
// CANON-NEXT: adt.make overflow : !adt.sum<overflow, right(i32)>
// CANON-NOT: adt.switch
// CANON-LABEL: func.func @half_if_even

//===----------------------------------------------------------------------===//
// Executed programs
//===----------------------------------------------------------------------===//

// safeDiv a b: div_by_zero if b == 0, overflow if a == INT_MIN and b == -1.
func.func @safe_div(%a: i32, %b: i32) -> !monad.either<!adt.sum<div_by_zero, overflow>, i32> {
  %result = monad.do : !monad.either<!adt.sum<div_by_zero, overflow>, i32> {
    %pass = monad.return : !monad.either<!adt.sum<div_by_zero, overflow>, none>
    %zero = arith.constant 0 : i32
    %is_zero = arith.cmpi eq, %b, %zero : i32
    %division_error = adt.make div_by_zero : !adt.sum<div_by_zero, overflow>
    %division_failure = monad.either.left %division_error : !monad.either<!adt.sum<div_by_zero, overflow>, none>
    %divisor_check = arith.select %is_zero, %division_failure, %pass : !monad.either<!adt.sum<div_by_zero, overflow>, none>
    monad.bind %divisor_check, ^divisor_nonzero : !monad.either<!adt.sum<div_by_zero, overflow>, none>
  ^divisor_nonzero:
    %minimum = arith.constant -2147483648 : i32
    %minus_one = arith.constant -1 : i32
    %is_minimum = arith.cmpi eq, %a, %minimum : i32
    %is_minus_one = arith.cmpi eq, %b, %minus_one : i32
    %overflows = arith.andi %is_minimum, %is_minus_one : i1
    %overflow_error = adt.make overflow : !adt.sum<div_by_zero, overflow>
    %overflow_failure = monad.either.left %overflow_error : !monad.either<!adt.sum<div_by_zero, overflow>, none>
    %overflow_check = arith.select %overflows, %overflow_failure, %pass : !monad.either<!adt.sum<div_by_zero, overflow>, none>
    monad.bind %overflow_check, ^safe : !monad.either<!adt.sum<div_by_zero, overflow>, none>
  ^safe:
    %quotient = arith.divsi %a, %b : i32
    %success = monad.return %quotient : !monad.either<!adt.sum<div_by_zero, overflow>, i32>
    monad.yield %success : !monad.either<!adt.sum<div_by_zero, overflow>, i32>
  }
  return %result : !monad.either<!adt.sum<div_by_zero, overflow>, i32>
}

// halfRatio a b: safe_div, recovering from div_by_zero with 0, then halved.
func.func @half_ratio(%a: i32, %b: i32) -> !monad.either<!adt.sum<overflow>, i32> {
  %result = monad.do : !monad.either<!adt.sum<overflow>, i32> {
    %ratio = func.call @safe_div(%a, %b) : (i32, i32) -> !monad.either<!adt.sum<div_by_zero, overflow>, i32>
    monad.either.branch %ratio, left ^failed, right ^divided : !monad.either<!adt.sum<div_by_zero, overflow>, i32>
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
    %overflow_error = adt.make overflow : !adt.sum<overflow>
    %rethrown = monad.either.left %overflow_error : !monad.either<!adt.sum<overflow>, i32>
    monad.yield %rethrown : !monad.either<!adt.sum<overflow>, i32>
  ^divided(%quotient: i32):
    %two = arith.constant 2 : i32
    %half = arith.divsi %quotient, %two : i32
    %success = monad.return %half : !monad.either<!adt.sum<overflow>, i32>
    monad.yield %success : !monad.either<!adt.sum<overflow>, i32>
  }
  return %result : !monad.either<!adt.sum<overflow>, i32>
}

// halfIfEven x: just x / 2 if x is even, nothing otherwise.
func.func @half_if_even(%x: i32) -> !monad.maybe<i32> {
  %two = arith.constant 2 : i32
  %zero = arith.constant 0 : i32
  %remainder = arith.remsi %x, %two : i32
  %even = arith.cmpi eq, %remainder, %zero : i32
  %half = arith.divsi %x, %two : i32
  %just = monad.return %half : !monad.maybe<i32>
  %nothing = monad.maybe.none : !monad.maybe<i32>
  %result = arith.select %even, %just, %nothing : !monad.maybe<i32>
  return %result : !monad.maybe<i32>
}

// quarter x = halfIfEven x >>= halfIfEven
func.func @quarter(%x: i32) -> !monad.maybe<i32> {
  %result = monad.do : !monad.maybe<i32> {
    %half = func.call @half_if_even(%x) : (i32) -> !monad.maybe<i32>
    monad.bind %half, ^halved : !monad.maybe<i32>
  ^halved(%value: i32):
    %quartered = func.call @half_if_even(%value) : (i32) -> !monad.maybe<i32>
    monad.yield %quartered : !monad.maybe<i32>
  }
  return %result : !monad.maybe<i32>
}

// The two transform ops, with i32 stand-ins for handles: tiling fails
// silenceably on 0; fusion fails definitely if the producer is 2 and
// silenceably if the loop is 1.
func.func @tile_using_forall(%target: i32) -> !monad.either<!adt.sum<silenceable>, i32, i32> {
  %zero = arith.constant 0 : i32
  %fails = arith.cmpi eq, %target, %zero : i32
  %error = adt.make silenceable : !adt.sum<silenceable>
  %failure = monad.either.left %error : !monad.either<!adt.sum<silenceable>, i32, i32>
  %ten = arith.constant 10 : i32
  %twenty = arith.constant 20 : i32
  %tiled = arith.addi %target, %ten : i32
  %loop = arith.addi %target, %twenty : i32
  %success = monad.return %tiled, %loop : !monad.either<!adt.sum<silenceable>, i32, i32>
  %result = arith.select %fails, %failure, %success : !monad.either<!adt.sum<silenceable>, i32, i32>
  return %result : !monad.either<!adt.sum<silenceable>, i32, i32>
}

func.func @fuse_into_containing_op(%producer: i32, %loop: i32)
    -> !monad.either<!adt.sum<definite, silenceable>, i32, i32> {
  %one = arith.constant 1 : i32
  %two = arith.constant 2 : i32
  %is_definite = arith.cmpi eq, %producer, %two : i32
  %is_silenceable = arith.cmpi eq, %loop, %one : i32
  %definite_error = adt.make definite : !adt.sum<definite, silenceable>
  %definite = monad.either.left %definite_error : !monad.either<!adt.sum<definite, silenceable>, i32, i32>
  %silenceable_error = adt.make silenceable : !adt.sum<definite, silenceable>
  %silenceable = monad.either.left %silenceable_error : !monad.either<!adt.sum<definite, silenceable>, i32, i32>
  %hundred = arith.constant 100 : i32
  %two_hundred = arith.constant 200 : i32
  %fused = arith.addi %producer, %hundred : i32
  %new_loop = arith.addi %loop, %two_hundred : i32
  %success = monad.return %fused, %new_loop : !monad.either<!adt.sum<definite, silenceable>, i32, i32>
  %not_definite = arith.select %is_silenceable, %silenceable, %success : !monad.either<!adt.sum<definite, silenceable>, i32, i32>
  %result = arith.select %is_definite, %definite, %not_definite : !monad.either<!adt.sum<definite, silenceable>, i32, i32>
  return %result : !monad.either<!adt.sum<definite, silenceable>, i32, i32>
}

// transform.sequence failures(suppress) { tile; fuse }: silenceable failures
// are suppressed, definite failures leave.
func.func @tile_and_fuse(%matmul: i32, %producer: i32) -> !monad.either<!adt.sum<definite>, i32, i32> {
  %result = monad.do : !monad.either<!adt.sum<definite>, i32, i32> {
    %tiled_or_untiled = monad.do : !monad.either<!adt.sum<definite>, i32, i32> {
      %tiling = func.call @tile_using_forall(%matmul) : (i32) -> !monad.either<!adt.sum<silenceable>, i32, i32>
      monad.either.branch %tiling, left ^tiling_failed, right ^tiled : !monad.either<!adt.sum<silenceable>, i32, i32>
    ^tiling_failed(%tiling_error: !adt.sum<silenceable>):
      %untiled = monad.return %matmul, %matmul : !monad.either<!adt.sum<definite>, i32, i32>
      monad.yield %untiled : !monad.either<!adt.sum<definite>, i32, i32>
    ^tiled(%tiled_op: i32, %tiled_loop: i32):
      %tiled_pair = monad.return %tiled_op, %tiled_loop : !monad.either<!adt.sum<definite>, i32, i32>
      monad.yield %tiled_pair : !monad.either<!adt.sum<definite>, i32, i32>
    }
    monad.bind %tiled_or_untiled, ^after_tiling : !monad.either<!adt.sum<definite>, i32, i32>
  ^after_tiling(%tiled_or_matmul: i32, %loop: i32):
    %fusion = func.call @fuse_into_containing_op(%producer, %loop) : (i32, i32) -> !monad.either<!adt.sum<definite, silenceable>, i32, i32>
    monad.either.branch %fusion, left ^fusion_failed, right ^fused : !monad.either<!adt.sum<definite, silenceable>, i32, i32>
  ^fusion_failed(%fusion_error: !adt.sum<definite, silenceable>):
    adt.switch %fusion_error : !adt.sum<definite, silenceable>, [
      definite: ^aborted,
      silenceable: ^fusion_suppressed
    ]
  ^fusion_suppressed:
    %unfused = monad.return %producer, %loop : !monad.either<!adt.sum<definite>, i32, i32>
    monad.yield %unfused : !monad.either<!adt.sum<definite>, i32, i32>
  ^aborted:
    %definite_error = adt.make definite : !adt.sum<definite>
    %abort = monad.either.left %definite_error : !monad.either<!adt.sum<definite>, i32, i32>
    monad.yield %abort : !monad.either<!adt.sum<definite>, i32, i32>
  ^fused(%fused_op: i32, %new_loop: i32):
    %fused_pair = monad.return %fused_op, %new_loop : !monad.either<!adt.sum<definite>, i32, i32>
    monad.yield %fused_pair : !monad.either<!adt.sum<definite>, i32, i32>
  }
  return %result : !monad.either<!adt.sum<definite>, i32, i32>
}

// Each describe function turns a result into one i32: the value of a
// success, or a negative code per failure.
func.func @describe_arith(%m: !monad.either<!adt.sum<div_by_zero, overflow>, i32>) -> i32 {
  monad.either.branch %m, left ^left, right ^right : !monad.either<!adt.sum<div_by_zero, overflow>, i32>
^left(%error: !adt.sum<div_by_zero, overflow>):
  %code = adt.match %error : !adt.sum<div_by_zero, overflow> -> i32
  case div_by_zero {
    %minus_one = arith.constant -1 : i32
    adt.yield %minus_one : i32
  }
  case overflow {
    %minus_two = arith.constant -2 : i32
    adt.yield %minus_two : i32
  }
  return %code : i32
^right(%value: i32):
  return %value : i32
}

func.func @describe_overflow(%m: !monad.either<!adt.sum<overflow>, i32>) -> i32 {
  monad.either.branch %m, left ^left, right ^right : !monad.either<!adt.sum<overflow>, i32>
^left(%error: !adt.sum<overflow>):
  %minus_two = arith.constant -2 : i32
  return %minus_two : i32
^right(%value: i32):
  return %value : i32
}

// The monad dialect has no eliminator of a maybe outside a monad.do, so this
// one is written at the low level, on the sum of the maybe.
func.func @describe_maybe(%m: !adt.sum<just(i32), nothing>) -> i32 {
  %code = adt.match %m : !adt.sum<just(i32), nothing> -> i32
  case just(%value: i32) {
    adt.yield %value : i32
  }
  case nothing {
    %minus_four = arith.constant -4 : i32
    adt.yield %minus_four : i32
  }
  return %code : i32
}

func.func @describe_pair(%m: !monad.either<!adt.sum<definite>, i32, i32>) -> i32 {
  monad.either.branch %m, left ^left, right ^right : !monad.either<!adt.sum<definite>, i32, i32>
^left(%error: !adt.sum<definite>):
  %minus_three = arith.constant -3 : i32
  return %minus_three : i32
^right(%first: i32, %second: i32):
  %thousand = arith.constant 1000 : i32
  %scaled = arith.muli %first, %thousand : i32
  %code = arith.addi %scaled, %second : i32
  return %code : i32
}

/// Returns `failure` if `code` differs from `expected`, and `earlier`
/// otherwise; chained from the last check to the first, it gives the first
/// failing check.
func.func @check(%code: i32, %expected: i32, %failure: i32, %earlier: i32) -> i32 {
  %passes = arith.cmpi eq, %code, %expected : i32
  %result = arith.select %passes, %earlier, %failure : i32
  return %result : i32
}

func.func @main() -> i32 {
  %c0 = arith.constant 0 : i32
  %c2 = arith.constant 2 : i32
  %c5 = arith.constant 5 : i32
  %c6 = arith.constant 6 : i32
  %c7 = arith.constant 7 : i32
  %c12 = arith.constant 12 : i32
  %c14 = arith.constant 14 : i32
  %minus_19 = arith.constant -19 : i32
  %minimum = arith.constant -2147483648 : i32
  %minus_one = arith.constant -1 : i32

  %r1 = func.call @safe_div(%c7, %c2) : (i32, i32) -> !monad.either<!adt.sum<div_by_zero, overflow>, i32>
  %d1 = func.call @describe_arith(%r1) : (!monad.either<!adt.sum<div_by_zero, overflow>, i32>) -> i32
  %r2 = func.call @safe_div(%c7, %c0) : (i32, i32) -> !monad.either<!adt.sum<div_by_zero, overflow>, i32>
  %d2 = func.call @describe_arith(%r2) : (!monad.either<!adt.sum<div_by_zero, overflow>, i32>) -> i32
  %r3 = func.call @safe_div(%minimum, %minus_one) : (i32, i32) -> !monad.either<!adt.sum<div_by_zero, overflow>, i32>
  %d3 = func.call @describe_arith(%r3) : (!monad.either<!adt.sum<div_by_zero, overflow>, i32>) -> i32
  %r4 = func.call @half_ratio(%c14, %c2) : (i32, i32) -> !monad.either<!adt.sum<overflow>, i32>
  %d4 = func.call @describe_overflow(%r4) : (!monad.either<!adt.sum<overflow>, i32>) -> i32
  %r5 = func.call @half_ratio(%c7, %c0) : (i32, i32) -> !monad.either<!adt.sum<overflow>, i32>
  %d5 = func.call @describe_overflow(%r5) : (!monad.either<!adt.sum<overflow>, i32>) -> i32
  %r6 = func.call @half_ratio(%minimum, %minus_one) : (i32, i32) -> !monad.either<!adt.sum<overflow>, i32>
  %d6 = func.call @describe_overflow(%r6) : (!monad.either<!adt.sum<overflow>, i32>) -> i32
  %r7 = func.call @quarter(%c12) : (i32) -> !monad.maybe<i32>
  %s7 = builtin.unrealized_conversion_cast %r7 : !monad.maybe<i32> to !adt.sum<just(i32), nothing>
  %d7 = func.call @describe_maybe(%s7) : (!adt.sum<just(i32), nothing>) -> i32
  %r8 = func.call @quarter(%c6) : (i32) -> !monad.maybe<i32>
  %s8 = builtin.unrealized_conversion_cast %r8 : !monad.maybe<i32> to !adt.sum<just(i32), nothing>
  %d8 = func.call @describe_maybe(%s8) : (!adt.sum<just(i32), nothing>) -> i32
  %r9 = func.call @quarter(%c7) : (i32) -> !monad.maybe<i32>
  %s9 = builtin.unrealized_conversion_cast %r9 : !monad.maybe<i32> to !adt.sum<just(i32), nothing>
  %d9 = func.call @describe_maybe(%s9) : (!adt.sum<just(i32), nothing>) -> i32
  %r10 = func.call @tile_and_fuse(%c5, %c6) : (i32, i32) -> !monad.either<!adt.sum<definite>, i32, i32>
  %d10 = func.call @describe_pair(%r10) : (!monad.either<!adt.sum<definite>, i32, i32>) -> i32
  %r11 = func.call @tile_and_fuse(%c0, %c6) : (i32, i32) -> !monad.either<!adt.sum<definite>, i32, i32>
  %d11 = func.call @describe_pair(%r11) : (!monad.either<!adt.sum<definite>, i32, i32>) -> i32
  %r12 = func.call @tile_and_fuse(%minus_19, %c6) : (i32, i32) -> !monad.either<!adt.sum<definite>, i32, i32>
  %d12 = func.call @describe_pair(%r12) : (!monad.either<!adt.sum<definite>, i32, i32>) -> i32
  %r13 = func.call @tile_and_fuse(%c5, %c2) : (i32, i32) -> !monad.either<!adt.sum<definite>, i32, i32>
  %d13 = func.call @describe_pair(%r13) : (!monad.either<!adt.sum<definite>, i32, i32>) -> i32
  %expected_13 = arith.constant -3 : i32
  %index_13 = arith.constant 13 : i32
  %first_13 = func.call @check(%d13, %expected_13, %index_13, %c0) : (i32, i32, i32, i32) -> i32
  %expected_12 = arith.constant 6001 : i32
  %index_12 = arith.constant 12 : i32
  %first_12 = func.call @check(%d12, %expected_12, %index_12, %first_13) : (i32, i32, i32, i32) -> i32
  %expected_11 = arith.constant 106200 : i32
  %index_11 = arith.constant 11 : i32
  %first_11 = func.call @check(%d11, %expected_11, %index_11, %first_12) : (i32, i32, i32, i32) -> i32
  %expected_10 = arith.constant 106225 : i32
  %index_10 = arith.constant 10 : i32
  %first_10 = func.call @check(%d10, %expected_10, %index_10, %first_11) : (i32, i32, i32, i32) -> i32
  %expected_9 = arith.constant -4 : i32
  %index_9 = arith.constant 9 : i32
  %first_9 = func.call @check(%d9, %expected_9, %index_9, %first_10) : (i32, i32, i32, i32) -> i32
  %expected_8 = arith.constant -4 : i32
  %index_8 = arith.constant 8 : i32
  %first_8 = func.call @check(%d8, %expected_8, %index_8, %first_9) : (i32, i32, i32, i32) -> i32
  %expected_7 = arith.constant 3 : i32
  %index_7 = arith.constant 7 : i32
  %first_7 = func.call @check(%d7, %expected_7, %index_7, %first_8) : (i32, i32, i32, i32) -> i32
  %expected_6 = arith.constant -2 : i32
  %index_6 = arith.constant 6 : i32
  %first_6 = func.call @check(%d6, %expected_6, %index_6, %first_7) : (i32, i32, i32, i32) -> i32
  %expected_5 = arith.constant 0 : i32
  %index_5 = arith.constant 5 : i32
  %first_5 = func.call @check(%d5, %expected_5, %index_5, %first_6) : (i32, i32, i32, i32) -> i32
  %expected_4 = arith.constant 3 : i32
  %index_4 = arith.constant 4 : i32
  %first_4 = func.call @check(%d4, %expected_4, %index_4, %first_5) : (i32, i32, i32, i32) -> i32
  %expected_3 = arith.constant -2 : i32
  %index_3 = arith.constant 3 : i32
  %first_3 = func.call @check(%d3, %expected_3, %index_3, %first_4) : (i32, i32, i32, i32) -> i32
  %expected_2 = arith.constant -1 : i32
  %index_2 = arith.constant 2 : i32
  %first_2 = func.call @check(%d2, %expected_2, %index_2, %first_3) : (i32, i32, i32, i32) -> i32
  %expected_1 = arith.constant 3 : i32
  %index_1 = arith.constant 1 : i32
  %first_1 = func.call @check(%d1, %expected_1, %index_1, %first_2) : (i32, i32, i32, i32) -> i32
  return %first_1 : i32
}
