// RUN: fum-opt %s --convert-monad-to-cf | FileCheck %s

// The examples of the value-or-exception monad lowered to cf, arith and ub.
// `run-lowered.sh` at the root of the repository executes @main.

monad.exception.declare @div_by_zero
monad.exception.declare @overflow
monad.exception.declare @io(i32)
monad.exception.declare @silenceable_failure
monad.exception.declare @definite_failure

// The declarations and the may_throw attributes are gone.
// CHECK-NOT: monad.

// safeDiv a b: throws div_by_zero if b == 0, overflow if a == INT_MIN and
// b == -1, and returns a / b otherwise.
// CHECK-LABEL: func.func @safe_div
// CHECK-SAME: -> (i32, i32, i64)
// CHECK: %[[PASS_TAG:.+]] = arith.constant 0 : i32
// CHECK: %[[DIV_TAG:.+]] = arith.constant 1855107791 : i32
// CHECK: %[[CHECK_ZERO:.+]] = arith.select %{{.*}}, %[[DIV_TAG]], %[[PASS_TAG]] : i32
// CHECK: arith.cmpi eq, %[[CHECK_ZERO]], %{{.*}} : i32
// CHECK: cf.cond_br %{{.*}}, ^[[NONZERO:.+]], ^[[EXIT:.+]](%[[CHECK_ZERO]], %{{.*}}, %{{.*}} : i32, i32, i64)
// CHECK: ^[[NONZERO]]:
// CHECK: arith.constant 425502571 : i32
// CHECK: cf.cond_br %{{.*}}, ^[[SAFE:.+]], ^[[EXIT]](
// CHECK: ^[[SAFE]]:
// CHECK: arith.divsi
// CHECK: cf.br ^[[EXIT]](
// CHECK: ^[[EXIT]](%[[TAG:.+]]: i32, %[[VALUE:.+]]: i32, %[[WORD:.+]]: i64):
// CHECK: return %[[TAG]], %[[VALUE]], %[[WORD]] : i32, i32, i64
func.func @safe_div(%a: i32, %b: i32) -> !monad.value_or_exception<i32>
    attributes {monad.may_throw = [@div_by_zero, @overflow]} {
  %result = monad.do : !monad.value_or_exception<i32> {
    %pass = monad.return : !monad.value_or_exception<>
    %c0 = arith.constant 0 : i32
    %is_zero = arith.cmpi eq, %b, %c0 : i32
    %div_by_zero = monad.exception.make @div_by_zero
    %div_by_zero_failure = monad.throw %div_by_zero : !monad.value_or_exception<>
    %check_zero = arith.select %is_zero, %div_by_zero_failure, %pass : !monad.value_or_exception<>
    monad.bind %check_zero, ^nonzero : !monad.value_or_exception<>
  ^nonzero:
    %int_min = arith.constant -2147483648 : i32
    %minus_one = arith.constant -1 : i32
    %a_is_min = arith.cmpi eq, %a, %int_min : i32
    %b_is_minus_one = arith.cmpi eq, %b, %minus_one : i32
    %overflows = arith.andi %a_is_min, %b_is_minus_one : i1
    %overflow = monad.exception.make @overflow
    %overflow_failure = monad.throw %overflow : !monad.value_or_exception<>
    %check_overflow = arith.select %overflows, %overflow_failure, %pass : !monad.value_or_exception<>
    monad.bind %check_overflow, ^safe : !monad.value_or_exception<>
  ^safe:
    %quotient = arith.divsi %a, %b : i32
    %success = monad.return %quotient : !monad.value_or_exception<i32>
    monad.yield %success : !monad.value_or_exception<i32>
  }
  return %result : !monad.value_or_exception<i32>
}

// halfRatio a b = safeDiv a b `catchError` \e -> case e of
//   DivByZero -> return 0; other -> throwError other
// Success and other kinds end the do with the result of safe_div.
// CHECK-LABEL: func.func @half_ratio
// CHECK: %[[RATIO:.+]]:3 = call @safe_div(%{{.*}}, %{{.*}}) : (i32, i32) -> (i32, i32, i64)
// CHECK: cf.switch %[[RATIO]]#0 : i32, [
// CHECK-NEXT: default: ^[[EXIT:.+]](%[[RATIO]]#0, %[[RATIO]]#1, %[[RATIO]]#2 : i32, i32, i64),
// CHECK-NEXT: 0: ^[[EXIT]](%[[RATIO]]#0, %[[RATIO]]#1, %[[RATIO]]#2 : i32, i32, i64),
// CHECK-NEXT: 1855107791: ^[[RECOVER:.+]]
// CHECK-NEXT: ]
// CHECK: ^[[RECOVER]]:
// CHECK: cf.br ^[[EXIT]](
// CHECK: ^[[EXIT]](
func.func @half_ratio(%a: i32, %b: i32) -> !monad.value_or_exception<i32>
    attributes {monad.may_throw = [@overflow]} {
  %result = monad.do : !monad.value_or_exception<i32> {
    %ratio = func.call @safe_div(%a, %b) : (i32, i32) -> !monad.value_or_exception<i32>
    monad.catch %ratio [@div_by_zero -> ^recover] : !monad.value_or_exception<i32>
  ^recover:
    %c0 = arith.constant 0 : i32
    %zero = monad.return %c0 : !monad.value_or_exception<i32>
    monad.yield %zero : !monad.value_or_exception<i32>
  }
  return %result : !monad.value_or_exception<i32>
}

// A catch with ^ok, a payload, and a default: the payload is truncated from
// the payload word before the switch, and the default receives the tag and
// the payload word.
// CHECK-LABEL: func.func @payload
// CHECK-SAME: (%[[TAG:.+]]: i32, %[[VALUE:.+]]: i32, %[[WORD:.+]]: i64)
// CHECK: %[[CODE:.+]] = arith.trunci %[[WORD]] : i64 to i32
// CHECK: cf.switch %[[TAG]] : i32, [
// CHECK-NEXT: default: ^[[OTHER:.+]](%[[TAG]], %[[WORD]] : i32, i64),
// CHECK-NEXT: 0: ^[[OK:.+]](%[[VALUE]] : i32),
// CHECK-NEXT: 1110998065: ^[[IO:.+]](%[[CODE]] : i32)
// CHECK-NEXT: ]
// CHECK: ^[[OK]](%{{.*}}: i32):
// CHECK: ^[[IO]](%{{.*}}: i32):
// CHECK: ^[[OTHER]](%{{.*}}: i32, %{{.*}}: i64):
func.func @payload(%input: !monad.value_or_exception<i32>) -> !monad.value_or_exception<i32> {
  %result = monad.do : !monad.value_or_exception<i32> {
    monad.catch %input, ^ok [@io -> ^io, default -> ^other] : !monad.value_or_exception<i32>
  ^ok(%value: i32):
    %success = monad.return %value : !monad.value_or_exception<i32>
    monad.yield %success : !monad.value_or_exception<i32>
  ^io(%code: i32):
    %recovered = monad.return %code : !monad.value_or_exception<i32>
    monad.yield %recovered : !monad.value_or_exception<i32>
  ^other(%exception: !monad.exception):
    %failure = monad.throw %exception : !monad.value_or_exception<i32>
    monad.yield %failure : !monad.value_or_exception<i32>
  }
  return %result : !monad.value_or_exception<i32>
}

// Making an exception with a payload sign-extends it into the payload word.
// CHECK-LABEL: func.func @make_payload
// CHECK: %[[TAG:.+]] = arith.constant 1110998065 : i32
// CHECK: %[[WORD:.+]] = arith.extsi %{{.*}} : i32 to i64
// CHECK: %[[POISON:.+]] = ub.poison : i32
// CHECK: return %[[TAG]], %[[POISON]], %[[WORD]] : i32, i32, i64
func.func @make_payload(%code: i32) -> !monad.value_or_exception<i32> {
  %io = monad.exception.make @io(%code) : (i32)
  %failure = monad.throw %io : !monad.value_or_exception<i32>
  return %failure : !monad.value_or_exception<i32>
}

// The maybe monad lowers to a flag and the values.
// CHECK-LABEL: func.func @maybe
// CHECK-SAME: (%[[SOME:.+]]: i1, %[[VALUE:.+]]: i32) -> (i1, f32)
// CHECK: cf.cond_br %[[SOME]], ^[[NEXT:.+]](%[[VALUE]] : i32), ^[[EXIT:.+]](%{{.*}}, %{{.*}} : i1, f32)
func.func @maybe(%input: !monad.maybe<i32>) -> !monad.maybe<f32> {
  %result = monad.do : !monad.maybe<f32> {
    monad.bind %input, ^next : !monad.maybe<i32>
  ^next(%value: i32):
    %converted = arith.sitofp %value : i32 to f32
    %wrapped = monad.return %converted : !monad.maybe<f32>
    monad.yield %wrapped : !monad.maybe<f32>
  }
  return %result : !monad.maybe<f32>
}

// Stand-ins of the transform ops on i32 handles.
// tile_using_forall: silenceable failure if %target == 0, else
// (%target + 10, %target + 20).
func.func @tile_using_forall(%target: i32) -> !monad.value_or_exception<i32, i32>
    attributes {monad.may_throw = [@silenceable_failure]} {
  %c0 = arith.constant 0 : i32
  %c10 = arith.constant 10 : i32
  %c20 = arith.constant 20 : i32
  %cannot_tile = arith.cmpi eq, %target, %c0 : i32
  %silenceable = monad.exception.make @silenceable_failure
  %failure = monad.throw %silenceable : !monad.value_or_exception<i32, i32>
  %tiled_op = arith.addi %target, %c10 : i32
  %loop = arith.addi %target, %c20 : i32
  %success = monad.return %tiled_op, %loop : !monad.value_or_exception<i32, i32>
  %result = arith.select %cannot_tile, %failure, %success : !monad.value_or_exception<i32, i32>
  return %result : !monad.value_or_exception<i32, i32>
}

// fuse_into_containing_op: definite failure if %producer == 2, silenceable
// failure if %containing == 1, else (%producer + 100, %containing + 200).
func.func @fuse_into_containing_op(%producer: i32, %containing: i32)
    -> !monad.value_or_exception<i32, i32>
    attributes {monad.may_throw = [@silenceable_failure, @definite_failure]} {
  %c1 = arith.constant 1 : i32
  %c2 = arith.constant 2 : i32
  %c100 = arith.constant 100 : i32
  %c200 = arith.constant 200 : i32
  %not_single_op = arith.cmpi eq, %producer, %c2 : i32
  %cannot_fuse = arith.cmpi eq, %containing, %c1 : i32
  %definite = monad.exception.make @definite_failure
  %definite_failure = monad.throw %definite : !monad.value_or_exception<i32, i32>
  %silenceable = monad.exception.make @silenceable_failure
  %silenceable_failure = monad.throw %silenceable : !monad.value_or_exception<i32, i32>
  %fused_op = arith.addi %producer, %c100 : i32
  %new_loop = arith.addi %containing, %c200 : i32
  %success = monad.return %fused_op, %new_loop : !monad.value_or_exception<i32, i32>
  %fused = arith.select %cannot_fuse, %silenceable_failure, %success : !monad.value_or_exception<i32, i32>
  %result = arith.select %not_single_op, %definite_failure, %fused : !monad.value_or_exception<i32, i32>
  return %result : !monad.value_or_exception<i32, i32>
}

// Tile, then fuse, suppressing silenceable failures of both steps. Each step
// is an inner do, inlined after the outer one.
// CHECK-LABEL: func.func @tile_and_fuse
// CHECK: call @tile_using_forall
// CHECK: cf.switch %{{.*}} : i32, [
// CHECK-NEXT: default: ^[[TILING_EXIT:.+]](
// CHECK-NEXT: 0: ^[[TILING_EXIT]](
// CHECK-NEXT: 1661323397: ^[[TILING_SUPPRESSED:.+]]
// CHECK: ^[[TILING_SUPPRESSED]]:
// CHECK: cf.br ^[[TILING_EXIT]](
// CHECK: ^[[TILING_EXIT]](
// CHECK: cf.cond_br %{{.*}}, ^[[AFTER_TILING:.+]](%{{.*}}, %{{.*}} : i32, i32), ^[[EXIT:.+]](
// CHECK: ^[[AFTER_TILING]](
// CHECK: call @fuse_into_containing_op
// CHECK: cf.switch %{{.*}} : i32, [
// CHECK-NEXT: default: ^[[FUSION_EXIT:.+]](
// CHECK-NEXT: 0: ^[[FUSION_EXIT]](
// CHECK-NEXT: 1661323397: ^[[FUSION_SUPPRESSED:.+]]
// CHECK: ^[[FUSION_SUPPRESSED]]:
// CHECK: cf.br ^[[FUSION_EXIT]](
// CHECK: ^[[FUSION_EXIT]](
// CHECK: cf.br ^[[EXIT]](
// CHECK: ^[[EXIT]](
// CHECK: return
func.func @tile_and_fuse(%matmul: i32, %producer: i32) -> !monad.value_or_exception<i32, i32>
    attributes {monad.may_throw = [@definite_failure]} {
  %result = monad.do : !monad.value_or_exception<i32, i32> {
    %tiling_step = monad.do : !monad.value_or_exception<i32, i32> {
      %tiling = func.call @tile_using_forall(%matmul) : (i32) -> !monad.value_or_exception<i32, i32>
      monad.catch %tiling [@silenceable_failure -> ^tiling_suppressed] : !monad.value_or_exception<i32, i32>
    ^tiling_suppressed:
      %untiled = monad.return %matmul, %matmul : !monad.value_or_exception<i32, i32>
      monad.yield %untiled : !monad.value_or_exception<i32, i32>
    }
    monad.bind %tiling_step, ^after_tiling : !monad.value_or_exception<i32, i32>
  ^after_tiling(%op: i32, %loop: i32):
    %fusion_step = monad.do : !monad.value_or_exception<i32, i32> {
      %fusion = func.call @fuse_into_containing_op(%producer, %loop)
          : (i32, i32) -> !monad.value_or_exception<i32, i32>
      monad.catch %fusion [@silenceable_failure -> ^fusion_suppressed] : !monad.value_or_exception<i32, i32>
    ^fusion_suppressed:
      %unfused = monad.return %producer, %loop : !monad.value_or_exception<i32, i32>
      monad.yield %unfused : !monad.value_or_exception<i32, i32>
    }
    monad.yield %fusion_step : !monad.value_or_exception<i32, i32>
  }
  return %result : !monad.value_or_exception<i32, i32>
}

// Self-check: returns 0 if every check passes, else the number of the first
// failing check. It reads the components of the results with casts, which
// the lowering folds away.
// CHECK-LABEL: func.func @main
// CHECK-NOT: unrealized_conversion_cast
func.func @main() -> i32 {
  %success_tag = arith.constant 0 : i32
  %div_by_zero_tag = arith.constant 1855107791 : i32
  %overflow_tag = arith.constant 425502571 : i32
  %definite_tag = arith.constant 1772500520 : i32
  %c0 = arith.constant 0 : i32
  %c1 = arith.constant 1 : i32
  %c2 = arith.constant 2 : i32
  %c3 = arith.constant 3 : i32
  %c5 = arith.constant 5 : i32
  %c6 = arith.constant 6 : i32
  %c7 = arith.constant 7 : i32
  %c106 = arith.constant 106 : i32
  %c200 = arith.constant 200 : i32
  %c225 = arith.constant 225 : i32
  %c_minus_19 = arith.constant -19 : i32
  %int_min = arith.constant -2147483648 : i32
  %minus_one = arith.constant -1 : i32

  // 1. safe_div(7, 2) = success 3
  %r1 = func.call @safe_div(%c7, %c2) : (i32, i32) -> !monad.value_or_exception<i32>
  %k1, %v1, %p1 = builtin.unrealized_conversion_cast %r1 : !monad.value_or_exception<i32> to i32, i32, i64
  %k1_ok = arith.cmpi eq, %k1, %success_tag : i32
  %v1_ok = arith.cmpi eq, %v1, %c3 : i32
  %check1 = arith.andi %k1_ok, %v1_ok : i1
  // 2. safe_div(7, 0) = div_by_zero
  %r2 = func.call @safe_div(%c7, %c0) : (i32, i32) -> !monad.value_or_exception<i32>
  %k2, %v2, %p2 = builtin.unrealized_conversion_cast %r2 : !monad.value_or_exception<i32> to i32, i32, i64
  %check2 = arith.cmpi eq, %k2, %div_by_zero_tag : i32
  // 3. safe_div(INT_MIN, -1) = overflow
  %r3 = func.call @safe_div(%int_min, %minus_one) : (i32, i32) -> !monad.value_or_exception<i32>
  %k3, %v3, %p3 = builtin.unrealized_conversion_cast %r3 : !monad.value_or_exception<i32> to i32, i32, i64
  %check3 = arith.cmpi eq, %k3, %overflow_tag : i32
  // 4. half_ratio(7, 2) = success 3
  %r4 = func.call @half_ratio(%c7, %c2) : (i32, i32) -> !monad.value_or_exception<i32>
  %k4, %v4, %p4 = builtin.unrealized_conversion_cast %r4 : !monad.value_or_exception<i32> to i32, i32, i64
  %k4_ok = arith.cmpi eq, %k4, %success_tag : i32
  %v4_ok = arith.cmpi eq, %v4, %c3 : i32
  %check4 = arith.andi %k4_ok, %v4_ok : i1
  // 5. half_ratio(7, 0) = success 0
  %r5 = func.call @half_ratio(%c7, %c0) : (i32, i32) -> !monad.value_or_exception<i32>
  %k5, %v5, %p5 = builtin.unrealized_conversion_cast %r5 : !monad.value_or_exception<i32> to i32, i32, i64
  %k5_ok = arith.cmpi eq, %k5, %success_tag : i32
  %v5_ok = arith.cmpi eq, %v5, %c0 : i32
  %check5 = arith.andi %k5_ok, %v5_ok : i1
  // 6. half_ratio(INT_MIN, -1) = overflow
  %r6 = func.call @half_ratio(%int_min, %minus_one) : (i32, i32) -> !monad.value_or_exception<i32>
  %k6, %v6, %p6 = builtin.unrealized_conversion_cast %r6 : !monad.value_or_exception<i32> to i32, i32, i64
  %check6 = arith.cmpi eq, %k6, %overflow_tag : i32
  // 7. tile_and_fuse(5, 6) = success (106, 225)
  %r7 = func.call @tile_and_fuse(%c5, %c6) : (i32, i32) -> !monad.value_or_exception<i32, i32>
  %k7, %a7, %b7, %p7 = builtin.unrealized_conversion_cast %r7 : !monad.value_or_exception<i32, i32> to i32, i32, i32, i64
  %k7_ok = arith.cmpi eq, %k7, %success_tag : i32
  %a7_ok = arith.cmpi eq, %a7, %c106 : i32
  %b7_ok = arith.cmpi eq, %b7, %c225 : i32
  %ab7_ok = arith.andi %a7_ok, %b7_ok : i1
  %check7 = arith.andi %k7_ok, %ab7_ok : i1
  // 8. tile_and_fuse(0, 6) = success (106, 200)
  %r8 = func.call @tile_and_fuse(%c0, %c6) : (i32, i32) -> !monad.value_or_exception<i32, i32>
  %k8, %a8, %b8, %p8 = builtin.unrealized_conversion_cast %r8 : !monad.value_or_exception<i32, i32> to i32, i32, i32, i64
  %k8_ok = arith.cmpi eq, %k8, %success_tag : i32
  %a8_ok = arith.cmpi eq, %a8, %c106 : i32
  %b8_ok = arith.cmpi eq, %b8, %c200 : i32
  %ab8_ok = arith.andi %a8_ok, %b8_ok : i1
  %check8 = arith.andi %k8_ok, %ab8_ok : i1
  // 9. tile_and_fuse(-19, 6) = success (6, 1)
  %r9 = func.call @tile_and_fuse(%c_minus_19, %c6) : (i32, i32) -> !monad.value_or_exception<i32, i32>
  %k9, %a9, %b9, %p9 = builtin.unrealized_conversion_cast %r9 : !monad.value_or_exception<i32, i32> to i32, i32, i32, i64
  %k9_ok = arith.cmpi eq, %k9, %success_tag : i32
  %a9_ok = arith.cmpi eq, %a9, %c6 : i32
  %b9_ok = arith.cmpi eq, %b9, %c1 : i32
  %ab9_ok = arith.andi %a9_ok, %b9_ok : i1
  %check9 = arith.andi %k9_ok, %ab9_ok : i1
  // 10. tile_and_fuse(5, 2) = definite failure
  %r10 = func.call @tile_and_fuse(%c5, %c2) : (i32, i32) -> !monad.value_or_exception<i32, i32>
  %k10, %a10, %b10, %p10 = builtin.unrealized_conversion_cast %r10 : !monad.value_or_exception<i32, i32> to i32, i32, i32, i64
  %check10 = arith.cmpi eq, %k10, %definite_tag : i32

  // The first failing check wins: fold from the last check to the first.
  %n4 = arith.constant 4 : i32
  %n8 = arith.constant 8 : i32
  %n9 = arith.constant 9 : i32
  %n10 = arith.constant 10 : i32
  %r_10 = arith.select %check10, %c0, %n10 : i32
  %r_9 = arith.select %check9, %r_10, %n9 : i32
  %r_8 = arith.select %check8, %r_9, %n8 : i32
  %r_7 = arith.select %check7, %r_8, %c7 : i32
  %r_6 = arith.select %check6, %r_7, %c6 : i32
  %r_5 = arith.select %check5, %r_6, %c5 : i32
  %r_4 = arith.select %check4, %r_5, %n4 : i32
  %r_3 = arith.select %check3, %r_4, %c3 : i32
  %r_2 = arith.select %check2, %r_3, %c2 : i32
  %r_1 = arith.select %check1, %r_2, %c1 : i32
  return %r_1 : i32
}
