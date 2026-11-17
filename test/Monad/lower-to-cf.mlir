// RUN: fum-opt %s --convert-monad-to-cf | FileCheck %s --implicit-check-not=monad. --implicit-check-not=unrealized_conversion_cast

// The programs of the exception examples lowered to cf, arith and ub. The
// transform handles of tile_and_fuse are i32 stand-ins so that run-lowered.sh
// can execute @main, which returns 0 when every check passes and otherwise
// the number of the first failing check.
//
// Tags: silenceable has the explicit tag 1, so the others take the next
// unused tags in declaration order: div_by_zero 2, overflow 3, definite 4.

monad.error.declare @div_by_zero
monad.error.declare @overflow
monad.error.declare @definite
monad.error.declare @silenceable(i32) tag 1

!div_by_zero = !monad.error<@div_by_zero>
!overflow = !monad.error<@overflow>
!definite = !monad.error<@definite>
!silenceable = !monad.error<@silenceable, i32>
!check = !monad.value_or_error<[] throws {!div_by_zero, !overflow}>
!quotient = !monad.value_or_error<[i32] throws {!div_by_zero, !overflow}>
!half = !monad.value_or_error<[i32] throws {!overflow}>
!tiling = !monad.value_or_error<[i32, i32] throws {!silenceable}>
!fusion = !monad.value_or_error<[i32, i32] throws {!definite, !silenceable}>
!sequence = !monad.value_or_error<[i32, i32] throws {!definite}>

// A failed check ends the do with its tag; the quotient slot is poison.
// CHECK-LABEL: func.func @safe_div
// CHECK-SAME: -> (i32, i32)
// CHECK: %[[DIV_TAG:.+]] = arith.constant 2 : i32
// CHECK: %[[CHECK:.+]] = arith.select %{{.*}}, %[[DIV_TAG]], %{{.*}} : i32
// CHECK: %[[FAILED:.+]] = arith.cmpi ne, %[[CHECK]], %{{.*}} : i32
// CHECK: cf.cond_br %[[FAILED]], ^[[EXIT:.+]](%[[CHECK]], %{{.*}} : i32, i32), ^{{.*}}
// CHECK: arith.constant 3 : i32
// CHECK: cf.cond_br %{{.*}}, ^[[EXIT]](%{{.*}}, %{{.*}} : i32, i32), ^{{.*}}
// CHECK: arith.divsi
// CHECK: cf.br ^[[EXIT]](%{{.*}}, %{{.*}} : i32, i32)
// CHECK: ^[[EXIT]](%[[TAG:.+]]: i32, %[[VALUE:.+]]: i32):
// CHECK: return %[[TAG]], %[[VALUE]] : i32, i32
func.func @safe_div(%a: i32, %b: i32) -> !quotient {
  %result = monad.do : !quotient {
    %pass = monad.return : !check
    %c0 = arith.constant 0 : i32
    %is_zero = arith.cmpi eq, %b, %c0 : i32
    %div_by_zero = monad.error.make : !div_by_zero
    %div_by_zero_failure = monad.throw %div_by_zero : !div_by_zero -> !check
    %check_divisor = arith.select %is_zero, %div_by_zero_failure, %pass : !check
    monad.bind %check_divisor, ^divisor_nonzero : !check
  ^divisor_nonzero:
    %min = arith.constant -2147483648 : i32
    %minus_one = arith.constant -1 : i32
    %a_is_min = arith.cmpi eq, %a, %min : i32
    %b_is_minus_one = arith.cmpi eq, %b, %minus_one : i32
    %overflows = arith.andi %a_is_min, %b_is_minus_one : i1
    %overflow = monad.error.make : !overflow
    %overflow_failure = monad.throw %overflow : !overflow -> !check
    %check_overflow = arith.select %overflows, %overflow_failure, %pass : !check
    monad.bind %check_overflow, ^safe : !check
  ^safe:
    %quotient = arith.divsi %a, %b : i32
    %success = monad.return %quotient : !quotient
    monad.yield %success : !quotient
  }
  return %result : !quotient
}

// One switch: success to ^ok, div_by_zero to the handler, and the uncaught
// overflow to the exit with its tag.
// CHECK-LABEL: func.func @half_ratio
// CHECK: %[[QUOTIENT:.+]]:2 = call @safe_div
// CHECK: cf.switch %[[QUOTIENT]]#0 : i32, [
// CHECK-NEXT: default: ^[[EXIT:.+]](%[[QUOTIENT]]#0, %{{.*}} : i32, i32),
// CHECK-NEXT: 0: ^[[OK:.+]](%[[QUOTIENT]]#1 : i32),
// CHECK-NEXT: 2: ^[[RECOVER:[a-z0-9_]+]]
// CHECK-NEXT: ]
// CHECK: ^[[OK]](%{{.*}}: i32):
// CHECK: cf.br ^[[EXIT]]
// CHECK: ^[[RECOVER]]:
// CHECK: cf.br ^[[EXIT]]
// CHECK: ^[[EXIT]](%{{.*}}: i32, %{{.*}}: i32):
func.func @half_ratio(%a: i32, %b: i32) -> !half {
  %result = monad.do : !half {
    %quotient = func.call @safe_div(%a, %b) : (i32, i32) -> !quotient
    monad.catch %quotient, ^ok [!div_by_zero -> ^recover] : !quotient
  ^ok(%value: i32):
    %success = monad.return %value : !half
    monad.yield %success : !half
  ^recover(%error: !div_by_zero):
    %zero = arith.constant 0 : i32
    %recovered = monad.return %zero : !half
    monad.yield %recovered : !half
  }
  return %result : !half
}

// The diagnostic id of the last suppressed failure.
memref.global "private" @last_suppressed_diagnostic : memref<i32> = dense<0>

// Records the diagnostic id of a suppressed failure.
func.func @report_suppressed(%diagnostic: i32) {
  %last = memref.get_global @last_suppressed_diagnostic : memref<i32>
  memref.store %diagnostic, %last[] : memref<i32>
  return
}

// Fails silenceably with diagnostic id 1 if %target is 0, else succeeds with
// (%target + 10, %target + 20).
// CHECK-LABEL: func.func @tile_using_forall
// CHECK-SAME: -> (i32, i32, i32, i32)
func.func @tile_using_forall(%target: i32) -> !tiling {
  %c0 = arith.constant 0 : i32
  %is_zero = arith.cmpi eq, %target, %c0 : i32
  cf.cond_br %is_zero, ^fail, ^tile
^fail:
  %diagnostic_id = arith.constant 1 : i32
  %error = monad.error.make %diagnostic_id : !silenceable
  %failure = monad.throw %error : !silenceable -> !tiling
  return %failure : !tiling
^tile:
  %c10 = arith.constant 10 : i32
  %c20 = arith.constant 20 : i32
  %tiled = arith.addi %target, %c10 : i32
  %loop = arith.addi %target, %c20 : i32
  %success = monad.return %tiled, %loop : !tiling
  return %success : !tiling
}

// Fails definitely if %producer is 2, silenceably with diagnostic id 2 if
// %loop is 1, else succeeds with (%producer + 100, %loop + 200).
// CHECK-LABEL: func.func @fuse_into_containing_op
// CHECK-SAME: -> (i32, i32, i32, i32)
func.func @fuse_into_containing_op(%producer: i32, %loop: i32) -> !fusion {
  %c1 = arith.constant 1 : i32
  %c2 = arith.constant 2 : i32
  %not_single = arith.cmpi eq, %producer, %c2 : i32
  cf.cond_br %not_single, ^definite, ^check_fusable
^definite:
  %definite = monad.error.make : !definite
  %definite_failure = monad.throw %definite : !definite -> !fusion
  return %definite_failure : !fusion
^check_fusable:
  %not_fusable = arith.cmpi eq, %loop, %c1 : i32
  cf.cond_br %not_fusable, ^silenceable, ^fuse
^silenceable:
  %diagnostic_id = arith.constant 2 : i32
  %silenceable = monad.error.make %diagnostic_id : !silenceable
  %silenceable_failure = monad.throw %silenceable : !silenceable -> !fusion
  return %silenceable_failure : !fusion
^fuse:
  %c100 = arith.constant 100 : i32
  %c200 = arith.constant 200 : i32
  %fused = arith.addi %producer, %c100 : i32
  %new_loop = arith.addi %loop, %c200 : i32
  %success = monad.return %fused, %new_loop : !fusion
  return %success : !fusion
}

// Two nested dos inlined into the function: the tiling catches every error
// (its default is unreachable), the fusion forwards the definite failure.
// CHECK-LABEL: func.func @tile_and_fuse
// CHECK-SAME: -> (i32, i32, i32)
// CHECK: %[[TILE:.+]]:4 = call @tile_using_forall
// CHECK: cf.switch %[[TILE]]#0 : i32, [
// CHECK-NEXT: default: ^[[UNREACHABLE:.+]],
// CHECK-NEXT: 0: ^{{.*}}(%[[TILE]]#1, %[[TILE]]#2 : i32, i32),
// CHECK-NEXT: 1: ^{{.*}}(%[[TILE]]#3 : i32)
// CHECK: call @report_suppressed
// CHECK: ^[[UNREACHABLE]]:
// CHECK-NEXT: ub.unreachable
// CHECK: arith.cmpi ne
// CHECK: cf.cond_br
// CHECK: %[[FUSE:.+]]:4 = call @fuse_into_containing_op
// CHECK: cf.switch %[[FUSE]]#0 : i32, [
// CHECK-NEXT: default: ^{{.*}}(%[[FUSE]]#0, %{{.*}}, %{{.*}} : i32, i32, i32),
// CHECK-NEXT: 0: ^{{.*}}(%[[FUSE]]#1, %[[FUSE]]#2 : i32, i32),
// CHECK-NEXT: 1: ^{{.*}}(%[[FUSE]]#3 : i32)
// CHECK: call @report_suppressed
func.func @tile_and_fuse(%matmul: i32, %producer: i32) -> !sequence {
  %result = monad.do : !sequence {
    %tiling = monad.do : !sequence {
      %tile = func.call @tile_using_forall(%matmul) : (i32) -> !tiling
      monad.catch %tile, ^tiled [!silenceable -> ^tiling_failed] : !tiling
    ^tiled(%tiled_op: i32, %tiled_loop: i32):
      %tiled_handles = monad.return %tiled_op, %tiled_loop : !sequence
      monad.yield %tiled_handles : !sequence
    ^tiling_failed(%tiling_error: !silenceable):
      %tiling_diagnostic = monad.error.payload %tiling_error : !silenceable
      func.call @report_suppressed(%tiling_diagnostic) : (i32) -> ()
      %untiled_handles = monad.return %matmul, %matmul : !sequence
      monad.yield %untiled_handles : !sequence
    }
    monad.bind %tiling, ^after_tiling : !sequence
  ^after_tiling(%tiled: i32, %loop: i32):
    %fusion = monad.do : !sequence {
      %fuse = func.call @fuse_into_containing_op(%producer, %loop) : (i32, i32) -> !fusion
      monad.catch %fuse, ^fused [!silenceable -> ^fusion_failed] : !fusion
    ^fused(%fused_op: i32, %new_loop: i32):
      %fused_handles = monad.return %fused_op, %new_loop : !sequence
      monad.yield %fused_handles : !sequence
    ^fusion_failed(%fusion_error: !silenceable):
      %fusion_diagnostic = monad.error.payload %fusion_error : !silenceable
      func.call @report_suppressed(%fusion_diagnostic) : (i32) -> ()
      %unfused_handles = monad.return %producer, %loop : !sequence
      monad.yield %unfused_handles : !sequence
    }
    monad.yield %fusion : !sequence
  }
  return %result : !sequence
}

// Runs the checks. The results are taken apart with casts to the lowered
// components, which cancel out with the lowering of the calls. A value slot
// is compared only when the tag is success.
// CHECK-LABEL: func.func @main
func.func @main() -> i32 {
  %success = arith.constant 0 : i32
  %div_by_zero_tag = arith.constant 2 : i32
  %overflow_tag = arith.constant 3 : i32
  %definite_tag = arith.constant 4 : i32
  %min = arith.constant -2147483648 : i32
  %minus_one = arith.constant -1 : i32
  %c0 = arith.constant 0 : i32
  %c1 = arith.constant 1 : i32
  %c2 = arith.constant 2 : i32
  %c3 = arith.constant 3 : i32
  %c4 = arith.constant 4 : i32
  %c5 = arith.constant 5 : i32
  %c6 = arith.constant 6 : i32
  %c7 = arith.constant 7 : i32
  %c8 = arith.constant 8 : i32
  %c9 = arith.constant 9 : i32
  %c10 = arith.constant 10 : i32
  %c11 = arith.constant 11 : i32
  %c12 = arith.constant 12 : i32
  %c106 = arith.constant 106 : i32
  %c200 = arith.constant 200 : i32
  %c225 = arith.constant 225 : i32
  %c_minus_19 = arith.constant -19 : i32

  // 1: safe_div(7, 2) = success 3
  %r1 = func.call @safe_div(%c7, %c2) : (i32, i32) -> !quotient
  %t1, %v1 = builtin.unrealized_conversion_cast %r1 : !quotient to i32, i32
  %t1_ok = arith.cmpi eq, %t1, %success : i32
  %v1_safe = arith.select %t1_ok, %v1, %c0 : i32
  %v1_ok = arith.cmpi eq, %v1_safe, %c3 : i32
  %ok1 = arith.andi %t1_ok, %v1_ok : i1
  cf.cond_br %ok1, ^check2, ^fail(%c1 : i32)
^check2:
  // 2: safe_div(7, 0) = div_by_zero
  %r2 = func.call @safe_div(%c7, %c0) : (i32, i32) -> !quotient
  %t2, %v2 = builtin.unrealized_conversion_cast %r2 : !quotient to i32, i32
  %ok2 = arith.cmpi eq, %t2, %div_by_zero_tag : i32
  cf.cond_br %ok2, ^check3, ^fail(%c2 : i32)
^check3:
  // 3: safe_div(INT_MIN, -1) = overflow
  %r3 = func.call @safe_div(%min, %minus_one) : (i32, i32) -> !quotient
  %t3, %v3 = builtin.unrealized_conversion_cast %r3 : !quotient to i32, i32
  %ok3 = arith.cmpi eq, %t3, %overflow_tag : i32
  cf.cond_br %ok3, ^check4, ^fail(%c3 : i32)
^check4:
  // 4: half_ratio(7, 2) = success 3
  %r4 = func.call @half_ratio(%c7, %c2) : (i32, i32) -> !half
  %t4, %v4 = builtin.unrealized_conversion_cast %r4 : !half to i32, i32
  %t4_ok = arith.cmpi eq, %t4, %success : i32
  %v4_safe = arith.select %t4_ok, %v4, %c0 : i32
  %v4_ok = arith.cmpi eq, %v4_safe, %c3 : i32
  %ok4 = arith.andi %t4_ok, %v4_ok : i1
  cf.cond_br %ok4, ^check5, ^fail(%c4 : i32)
^check5:
  // 5: half_ratio(7, 0) = success 0
  %r5 = func.call @half_ratio(%c7, %c0) : (i32, i32) -> !half
  %t5, %v5 = builtin.unrealized_conversion_cast %r5 : !half to i32, i32
  %t5_ok = arith.cmpi eq, %t5, %success : i32
  %v5_safe = arith.select %t5_ok, %v5, %c1 : i32
  %v5_ok = arith.cmpi eq, %v5_safe, %c0 : i32
  %ok5 = arith.andi %t5_ok, %v5_ok : i1
  cf.cond_br %ok5, ^check6, ^fail(%c5 : i32)
^check6:
  // 6: half_ratio(INT_MIN, -1) = overflow
  %r6 = func.call @half_ratio(%min, %minus_one) : (i32, i32) -> !half
  %t6, %v6 = builtin.unrealized_conversion_cast %r6 : !half to i32, i32
  %ok6 = arith.cmpi eq, %t6, %overflow_tag : i32
  cf.cond_br %ok6, ^check7, ^fail(%c6 : i32)
^check7:
  // 7: tile_and_fuse(5, 6) = success (106, 225)
  %r7 = func.call @tile_and_fuse(%c5, %c6) : (i32, i32) -> !sequence
  %t7, %h7a, %h7b = builtin.unrealized_conversion_cast %r7 : !sequence to i32, i32, i32
  %t7_ok = arith.cmpi eq, %t7, %success : i32
  %h7a_safe = arith.select %t7_ok, %h7a, %c0 : i32
  %h7b_safe = arith.select %t7_ok, %h7b, %c0 : i32
  %h7a_ok = arith.cmpi eq, %h7a_safe, %c106 : i32
  %h7b_ok = arith.cmpi eq, %h7b_safe, %c225 : i32
  %h7_ok = arith.andi %h7a_ok, %h7b_ok : i1
  %ok7 = arith.andi %t7_ok, %h7_ok : i1
  cf.cond_br %ok7, ^check8, ^fail(%c7 : i32)
^check8:
  // 8: tile_and_fuse(0, 6) = success (106, 200)
  %r8 = func.call @tile_and_fuse(%c0, %c6) : (i32, i32) -> !sequence
  %t8, %h8a, %h8b = builtin.unrealized_conversion_cast %r8 : !sequence to i32, i32, i32
  // Read now for check 11: the tiling's diagnostic id 1 was suppressed.
  %last8 = memref.get_global @last_suppressed_diagnostic : memref<i32>
  %diagnostic8 = memref.load %last8[] : memref<i32>
  %t8_ok = arith.cmpi eq, %t8, %success : i32
  %h8a_safe = arith.select %t8_ok, %h8a, %c0 : i32
  %h8b_safe = arith.select %t8_ok, %h8b, %c0 : i32
  %h8a_ok = arith.cmpi eq, %h8a_safe, %c106 : i32
  %h8b_ok = arith.cmpi eq, %h8b_safe, %c200 : i32
  %h8_ok = arith.andi %h8a_ok, %h8b_ok : i1
  %ok8 = arith.andi %t8_ok, %h8_ok : i1
  cf.cond_br %ok8, ^check9, ^fail(%c8 : i32)
^check9:
  // 9: tile_and_fuse(-19, 6) = success (6, 1)
  %r9 = func.call @tile_and_fuse(%c_minus_19, %c6) : (i32, i32) -> !sequence
  %t9, %h9a, %h9b = builtin.unrealized_conversion_cast %r9 : !sequence to i32, i32, i32
  // Read now for check 12: the fusion's diagnostic id 2 was suppressed.
  %last9 = memref.get_global @last_suppressed_diagnostic : memref<i32>
  %diagnostic9 = memref.load %last9[] : memref<i32>
  %t9_ok = arith.cmpi eq, %t9, %success : i32
  %h9a_safe = arith.select %t9_ok, %h9a, %c0 : i32
  %h9b_safe = arith.select %t9_ok, %h9b, %c0 : i32
  %h9a_ok = arith.cmpi eq, %h9a_safe, %c6 : i32
  %h9b_ok = arith.cmpi eq, %h9b_safe, %c1 : i32
  %h9_ok = arith.andi %h9a_ok, %h9b_ok : i1
  %ok9 = arith.andi %t9_ok, %h9_ok : i1
  cf.cond_br %ok9, ^check10, ^fail(%c9 : i32)
^check10:
  // 10: tile_and_fuse(5, 2) = definite failure
  %r10 = func.call @tile_and_fuse(%c5, %c2) : (i32, i32) -> !sequence
  %t10, %h10a, %h10b = builtin.unrealized_conversion_cast %r10 : !sequence to i32, i32, i32
  %ok10 = arith.cmpi eq, %t10, %definite_tag : i32
  cf.cond_br %ok10, ^check11, ^fail(%c10 : i32)
^check11:
  // 11: the handler of tile_and_fuse(0, 6) read diagnostic id 1
  %ok11 = arith.cmpi eq, %diagnostic8, %c1 : i32
  cf.cond_br %ok11, ^check12, ^fail(%c11 : i32)
^check12:
  // 12: the handler of tile_and_fuse(-19, 6) read diagnostic id 2
  %ok12 = arith.cmpi eq, %diagnostic9, %c2 : i32
  cf.cond_br %ok12, ^pass, ^fail(%c12 : i32)
^pass:
  return %success : i32
^fail(%failed_check: i32):
  return %failed_check : i32
}
