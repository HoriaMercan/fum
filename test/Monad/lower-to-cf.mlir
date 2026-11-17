// RUN: fum-opt %s --convert-monad-to-cf | FileCheck %s

// The examples of the exception design, lowered to cf, arith, and ub. Handles
// are i32 stand-ins so that run-lowered.sh can execute @main, which returns 0
// if every check passes, and otherwise the number of the first failing check.
//
// The tags follow the declarations: out_of_bounds has the explicit tag 1,
// so the others take the next unused tags: div_by_zero 2, overflow 3,
// silenceable 4, and definite 5.

monad.error.declare @div_by_zero
monad.error.declare @overflow
monad.error.declare @silenceable
monad.error.declare @definite
monad.error.declare @out_of_bounds(i32, i32) tag 1

// A computation that throws an arithmetic error is an i32 tag, the values,
// and no payload slot; a throw is the constant tag of the error and poison.
// CHECK-LABEL: func.func @safe_div
// CHECK-SAME: (%{{.+}}: i32, %{{.+}}: i32) -> (i32, i32)
// CHECK: %[[DIVISION:.+]] = arith.constant 2 : i32
// CHECK: %[[CHECK:.+]] = arith.select %{{.+}}, %[[DIVISION]], %{{.+}} : i32
// CHECK: %[[POISON:.+]] = ub.poison : i32
// CHECK: arith.cmpi eq, %[[CHECK]]
// CHECK: cf.cond_br %{{.+}}, ^{{.+}}, ^[[EXIT:.+]](%[[CHECK]], %[[POISON]] : i32, i32)
// CHECK: arith.constant 3 : i32
// CHECK: arith.divsi
// CHECK: cf.br ^[[EXIT]](%{{.+}}, %{{.+}} : i32, i32)
// CHECK: ^[[EXIT]](%[[TAG:.+]]: i32, %[[VALUE:.+]]: i32):
// CHECK: return %[[TAG]], %[[VALUE]] : i32, i32
func.func @safe_div(%a: i32, %b: i32) -> !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32> {
  %result = monad.do : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32> {
    %pass = monad.return : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, none>
    %zero = arith.constant 0 : i32
    %is_zero = arith.cmpi eq, %b, %zero : i32
    %division_error = monad.error.throw : !monad.error<@div_by_zero>
    %division_failure_left = monad.error.widen %division_error : !monad.error<@div_by_zero> to !monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>
    %division_failure = monad.either.left %division_failure_left : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, none>
    %divisor_check = arith.select %is_zero, %division_failure, %pass : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, none>
    monad.bind %divisor_check, ^divisor_nonzero : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, none>
  ^divisor_nonzero:
    %int_min = arith.constant -2147483648 : i32
    %minus_one = arith.constant -1 : i32
    %a_is_int_min = arith.cmpi eq, %a, %int_min : i32
    %b_is_minus_one = arith.cmpi eq, %b, %minus_one : i32
    %overflows = arith.andi %a_is_int_min, %b_is_minus_one : i1
    %overflow_error = monad.error.throw : !monad.error<@overflow>
    %overflow_failure_left = monad.error.widen %overflow_error : !monad.error<@overflow> to !monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>
    %overflow_failure = monad.either.left %overflow_failure_left : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, none>
    %overflow_check = arith.select %overflows, %overflow_failure, %pass : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, none>
    monad.bind %overflow_check, ^safe : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, none>
  ^safe:
    %quotient = arith.divsi %a, %b : i32
    %success = monad.return %quotient : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
    monad.yield %success : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
  }
  return %result : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
}

// A catch is one switch on the tag: 0 goes to ^ok, a caught error to its
// handler, and the default leaves the do with the error.
// CHECK-LABEL: func.func @half_ratio
// CHECK: %[[RATIO:.+]]:2 = call @safe_div
// CHECK: cf.switch %[[RATIO]]#0 : i32, [
// CHECK-NEXT: default: ^[[EXIT:.+]](%[[RATIO]]#0, %{{.+}} : i32, i32),
// CHECK-NEXT: 0: ^[[OK:.+]](%[[RATIO]]#1 : i32),
// CHECK-NEXT: 2: ^[[RECOVER:.+]]
// CHECK-NEXT: ]
// CHECK: ^[[OK]](%{{.+}}: i32):
// CHECK: cf.br ^[[EXIT]]
// CHECK: ^[[RECOVER]]:
// CHECK: cf.br ^[[EXIT]]
// CHECK: ^[[EXIT]](%[[TAG:.+]]: i32, %[[VALUE:.+]]: i32):
// CHECK: return %[[TAG]], %[[VALUE]] : i32, i32
func.func @half_ratio(%a: i32, %b: i32) -> !monad.either<!monad.error<@overflow>, i32> {
  %result = monad.do : !monad.either<!monad.error<@overflow>, i32> {
    %ratio = func.call @safe_div(%a, %b) : (i32, i32) -> !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
    monad.error.catch %ratio, ^ok [!monad.error<@div_by_zero> -> ^recover] : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
  ^ok(%quotient: i32):
    %success = monad.return %quotient : !monad.either<!monad.error<@overflow>, i32>
    monad.yield %success : !monad.either<!monad.error<@overflow>, i32>
  ^recover(%division_error: !monad.error<@div_by_zero>):
    %zero = arith.constant 0 : i32
    %recovered = monad.return %zero : !monad.either<!monad.error<@overflow>, i32>
    monad.yield %recovered : !monad.either<!monad.error<@overflow>, i32>
  }
  return %result : !monad.either<!monad.error<@overflow>, i32>
}

// Stub of transform.structured.tile_using_forall: silenceable failure on 0,
// otherwise the handles %target + 10 and %target + 20.
// CHECK-LABEL: func.func @tile_using_forall
// CHECK-SAME: -> (i32, i32, i32)
func.func @tile_using_forall(%target: i32) -> !monad.either<!monad.error<@silenceable>, i32, i32> {
  %zero = arith.constant 0 : i32
  %ten = arith.constant 10 : i32
  %twenty = arith.constant 20 : i32
  %is_zero = arith.cmpi eq, %target, %zero : i32
  %error = monad.error.throw : !monad.error<@silenceable>
  %failure = monad.either.left %error : !monad.either<!monad.error<@silenceable>, i32, i32>
  %tiled_op = arith.addi %target, %ten : i32
  %loop = arith.addi %target, %twenty : i32
  %success = monad.return %tiled_op, %loop : !monad.either<!monad.error<@silenceable>, i32, i32>
  %result = arith.select %is_zero, %failure, %success : !monad.either<!monad.error<@silenceable>, i32, i32>
  return %result : !monad.either<!monad.error<@silenceable>, i32, i32>
}

// Stub of transform.structured.fuse_into_containing_op: definite failure if
// %producer is 2, silenceable failure if %containing is 1, otherwise the
// handles %producer + 100 and %containing + 200.
// CHECK-LABEL: func.func @fuse_into_containing_op
// CHECK-SAME: -> (i32, i32, i32)
func.func @fuse_into_containing_op(%producer: i32, %containing: i32)
    -> !monad.either<!monad.error_union<{!monad.error<@definite>, !monad.error<@silenceable>}>, i32, i32> {
  %one = arith.constant 1 : i32
  %two = arith.constant 2 : i32
  %hundred = arith.constant 100 : i32
  %two_hundred = arith.constant 200 : i32
  %is_definite = arith.cmpi eq, %producer, %two : i32
  %is_silenceable = arith.cmpi eq, %containing, %one : i32
  %definite_error = monad.error.throw : !monad.error<@definite>
  %definite_left = monad.error.widen %definite_error : !monad.error<@definite> to !monad.error_union<{!monad.error<@definite>, !monad.error<@silenceable>}>
  %definite = monad.either.left %definite_left : !monad.either<!monad.error_union<{!monad.error<@definite>, !monad.error<@silenceable>}>, i32, i32>
  %silenceable_error = monad.error.throw : !monad.error<@silenceable>
  %silenceable_left = monad.error.widen %silenceable_error : !monad.error<@silenceable> to !monad.error_union<{!monad.error<@definite>, !monad.error<@silenceable>}>
  %silenceable = monad.either.left %silenceable_left : !monad.either<!monad.error_union<{!monad.error<@definite>, !monad.error<@silenceable>}>, i32, i32>
  %fused_op = arith.addi %producer, %hundred : i32
  %new_loop = arith.addi %containing, %two_hundred : i32
  %success = monad.return %fused_op, %new_loop : !monad.either<!monad.error_union<{!monad.error<@definite>, !monad.error<@silenceable>}>, i32, i32>
  %not_definite = arith.select %is_silenceable, %silenceable, %success : !monad.either<!monad.error_union<{!monad.error<@definite>, !monad.error<@silenceable>}>, i32, i32>
  %result = arith.select %is_definite, %definite, %not_definite : !monad.either<!monad.error_union<{!monad.error<@definite>, !monad.error<@silenceable>}>, i32, i32>
  return %result : !monad.either<!monad.error_union<{!monad.error<@definite>, !monad.error<@silenceable>}>, i32, i32>
}

// Nested dos are inlined outer first; each ends in its own exit block, and
// the bind of the inner result tests its tag.
// CHECK-LABEL: func.func @tile_and_fuse
// CHECK-SAME: -> (i32, i32, i32)
// CHECK: call @tile_using_forall
// CHECK: cf.switch
// CHECK: 0: ^{{.+}}(%{{.+}}, %{{.+}} : i32, i32),
// CHECK-NEXT: 4: ^
// CHECK: arith.cmpi eq
// CHECK: cf.cond_br
// CHECK: call @fuse_into_containing_op
// CHECK: cf.switch
// CHECK: 4: ^
// CHECK-NOT: monad.
func.func @tile_and_fuse(%matmul: i32, %producer: i32) -> !monad.either<!monad.error<@definite>, i32, i32> {
  %result = monad.do : !monad.either<!monad.error<@definite>, i32, i32> {
    %tiled_or_untiled = monad.do : !monad.either<!monad.error<@definite>, i32, i32> {
      %tiling = func.call @tile_using_forall(%matmul) : (i32) -> !monad.either<!monad.error<@silenceable>, i32, i32>
      monad.error.catch %tiling, ^tiled [!monad.error<@silenceable> -> ^tiling_suppressed] : !monad.either<!monad.error<@silenceable>, i32, i32>
    ^tiled(%tiled_op: i32, %tiled_loop: i32):
      %tiled_pair = monad.return %tiled_op, %tiled_loop : !monad.either<!monad.error<@definite>, i32, i32>
      monad.yield %tiled_pair : !monad.either<!monad.error<@definite>, i32, i32>
    ^tiling_suppressed(%tiling_error: !monad.error<@silenceable>):
      %untiled_pair = monad.return %matmul, %matmul : !monad.either<!monad.error<@definite>, i32, i32>
      monad.yield %untiled_pair : !monad.either<!monad.error<@definite>, i32, i32>
    }
    monad.bind %tiled_or_untiled, ^after_tiling : !monad.either<!monad.error<@definite>, i32, i32>
  ^after_tiling(%tiled_or_matmul: i32, %loop: i32):
    %fused_or_unfused = monad.do : !monad.either<!monad.error<@definite>, i32, i32> {
      %fusion = func.call @fuse_into_containing_op(%producer, %loop) : (i32, i32) -> !monad.either<!monad.error_union<{!monad.error<@definite>, !monad.error<@silenceable>}>, i32, i32>
      monad.error.catch %fusion, ^fused [!monad.error<@silenceable> -> ^fusion_suppressed] : !monad.either<!monad.error_union<{!monad.error<@definite>, !monad.error<@silenceable>}>, i32, i32>
    ^fused(%fused_op: i32, %new_loop: i32):
      %fused_pair = monad.return %fused_op, %new_loop : !monad.either<!monad.error<@definite>, i32, i32>
      monad.yield %fused_pair : !monad.either<!monad.error<@definite>, i32, i32>
    ^fusion_suppressed(%fusion_error: !monad.error<@silenceable>):
      %unfused_pair = monad.return %producer, %loop : !monad.either<!monad.error<@definite>, i32, i32>
      monad.yield %unfused_pair : !monad.either<!monad.error<@definite>, i32, i32>
    }
    monad.yield %fused_or_unfused : !monad.either<!monad.error<@definite>, i32, i32>
  }
  return %result : !monad.either<!monad.error<@definite>, i32, i32>
}

// A general either is an i1 (set for a left), the left value, and the values.
// CHECK-LABEL: func.func @first_negative
// CHECK-SAME: -> i32
// CHECK: arith.constant true
// CHECK: cf.cond_br
// CHECK-NOT: monad.
func.func @first_negative(%x: i32, %y: i32, %z: i32) -> i32 {
  %search = monad.do : !monad.either<i32, none> {
    %keep_searching = monad.return : !monad.either<i32, none>
    %zero = arith.constant 0 : i32
    %x_is_negative = arith.cmpi slt, %x, %zero : i32
    %found_x = monad.either.left %x : !monad.either<i32, none>
    %x_step = arith.select %x_is_negative, %found_x, %keep_searching : !monad.either<i32, none>
    monad.bind %x_step, ^check_y : !monad.either<i32, none>
  ^check_y:
    %y_is_negative = arith.cmpi slt, %y, %zero : i32
    %found_y = monad.either.left %y : !monad.either<i32, none>
    %y_step = arith.select %y_is_negative, %found_y, %keep_searching : !monad.either<i32, none>
    monad.bind %y_step, ^check_z : !monad.either<i32, none>
  ^check_z:
    %z_is_negative = arith.cmpi slt, %z, %zero : i32
    %found_z = monad.either.left %z : !monad.either<i32, none>
    %z_step = arith.select %z_is_negative, %found_z, %keep_searching : !monad.either<i32, none>
    monad.yield %z_step : !monad.either<i32, none>
  }
  monad.either.branch %search, left ^found, right ^not_found : !monad.either<i32, none>
^found(%value: i32):
  return %value : i32
^not_found:
  %not_found_result = arith.constant 0 : i32
  return %not_found_result : i32
}

// An error with a payload occupies its payload slots; a catch without ^ok
// passes a right through, and the handler reads the payload.
// CHECK-LABEL: func.func @clamp_index
// CHECK-SAME: -> (i32, i32, i32, i32)
// CHECK: cf.switch
// CHECK: 0: ^[[EXIT:.+]](%{{.+}}, %{{.+}}, %{{.+}}, %{{.+}} : i32, i32, i32, i32),
// CHECK-NEXT: {{[0-9]+}}: ^[[HANDLER:.+]](%{{.+}}, %{{.+}} : i32, i32)
// CHECK: ^[[HANDLER]](%[[INDEX:.+]]: i32, %[[SIZE:.+]]: i32):
// CHECK: arith.subi %[[SIZE]]
func.func @clamp_index(%index: i32, %size: i32) -> !monad.either<!monad.error<@out_of_bounds, i32, i32>, i32> {
  %result = monad.do : !monad.either<!monad.error<@out_of_bounds, i32, i32>, i32> {
    %in_bounds = arith.cmpi slt, %index, %size : i32
    %error = monad.error.throw %index, %size : !monad.error<@out_of_bounds, i32, i32>
    %failure = monad.either.left %error : !monad.either<!monad.error<@out_of_bounds, i32, i32>, i32>
    %success = monad.return %index : !monad.either<!monad.error<@out_of_bounds, i32, i32>, i32>
    %checked = arith.select %in_bounds, %success, %failure : !monad.either<!monad.error<@out_of_bounds, i32, i32>, i32>
    monad.error.catch %checked [!monad.error<@out_of_bounds, i32, i32> -> ^clamp] : !monad.either<!monad.error<@out_of_bounds, i32, i32>, i32>
  ^clamp(%bounds_error: !monad.error<@out_of_bounds, i32, i32>):
    %bad_index, %bad_size = monad.error.payload %bounds_error : !monad.error<@out_of_bounds, i32, i32>
    %one = arith.constant 1 : i32
    %last = arith.subi %bad_size, %one : i32
    %clamped = monad.return %last : !monad.either<!monad.error<@out_of_bounds, i32, i32>, i32>
    monad.yield %clamped : !monad.either<!monad.error<@out_of_bounds, i32, i32>, i32>
  }
  return %result : !monad.either<!monad.error<@out_of_bounds, i32, i32>, i32>
}

// half_ratio written with the either layer and the error layer: the branch
// sends the left to ^left, whose switch recovers div_by_zero and throws the
// other errors again. It computes the same as @half_ratio.
// CHECK-LABEL: func.func @half_ratio_long
// CHECK: cf.cond_br %{{.+}}, ^[[RIGHT:.+]](%{{.+}} : i32), ^[[LEFT:.+]](%{{.+}} : i32)
// CHECK: ^[[LEFT]](%[[TAG:.+]]: i32):
// CHECK: cf.switch %[[TAG]] : i32, [
// CHECK-NEXT: default: ^{{.+}}(%[[TAG]] : i32),
// CHECK-NEXT: 2: ^{{.+}}
// CHECK-NEXT: ]
func.func @half_ratio_long(%a: i32, %b: i32) -> !monad.either<!monad.error<@overflow>, i32> {
  %result = monad.do : !monad.either<!monad.error<@overflow>, i32> {
    %ratio = func.call @safe_div(%a, %b) : (i32, i32) -> !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
    monad.either.branch %ratio, left ^left, right ^ok : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
  ^left(%error: !monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>):
    monad.error.switch %error [!monad.error<@div_by_zero> -> ^recover, default -> ^other]
        : !monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>
  ^recover(%division_error: !monad.error<@div_by_zero>):
    %zero = arith.constant 0 : i32
    %recovered = monad.return %zero : !monad.either<!monad.error<@overflow>, i32>
    monad.yield %recovered : !monad.either<!monad.error<@overflow>, i32>
  ^other(%others: !monad.error_union<{!monad.error<@overflow>}>):
    %again_left = monad.error.widen %others : !monad.error_union<{!monad.error<@overflow>}> to !monad.error<@overflow>
    %again = monad.either.left %again_left : !monad.either<!monad.error<@overflow>, i32>
    monad.yield %again : !monad.either<!monad.error<@overflow>, i32>
  ^ok(%quotient: i32):
    %success = monad.return %quotient : !monad.either<!monad.error<@overflow>, i32>
    monad.yield %success : !monad.either<!monad.error<@overflow>, i32>
  }
  return %result : !monad.either<!monad.error<@overflow>, i32>
}

//===----------------------------------------------------------------------===//
// Checks for @main
//===----------------------------------------------------------------------===//

// Widens the left of %m to the errors of safe_div: the error layer widens the
// error, and the either layer rebuilds the left.
func.func @widen_overflow(%m: !monad.either<!monad.error<@overflow>, i32>) -> !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32> {
  monad.either.branch %m, left ^left, right ^right : !monad.either<!monad.error<@overflow>, i32>
^left(%error: !monad.error<@overflow>):
  %errors = monad.error.widen %error : !monad.error<@overflow> to !monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>
  %widened = monad.either.left %errors : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
  return %widened : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
^right(%value: i32):
  %success = monad.return %value : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
  return %success : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
}

// Returns whether %m is a right holding %expected.
func.func @holds(%m: !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>, %expected: i32) -> i1 {
  monad.either.branch %m, left ^left, right ^right : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
^left(%error: !monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>):
  %false = arith.constant false
  return %false : i1
^right(%value: i32):
  %equal = arith.cmpi eq, %value, %expected : i32
  return %equal : i1
}

// Returns whether %m holds the error overflow (with %overflow set) or
// div_by_zero (with %overflow cleared).
// The switch on the union lists every member, so its last case is the default.
// CHECK-LABEL: func.func @throws
// CHECK: cf.cond_br
// CHECK: cf.switch %{{.+}} : i32, [
// CHECK-NEXT: default: ^{{.+}},
// CHECK-NEXT: {{[0-9]+}}: ^{{.+}}
// CHECK-NEXT: ]
func.func @throws(%m: !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>, %overflow: i1) -> i1 {
  monad.either.branch %m, left ^left, right ^right : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
^left(%error: !monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>):
  monad.error.switch %error [!monad.error<@overflow> -> ^is_overflow,
                             !monad.error<@div_by_zero> -> ^is_division]
      : !monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>
^is_overflow(%overflow_error: !monad.error<@overflow>):
  return %overflow : i1
^is_division(%division_error: !monad.error<@div_by_zero>):
  %true = arith.constant true
  %not_overflow = arith.xori %overflow, %true : i1
  return %not_overflow : i1
^right(%value: i32):
  %false = arith.constant false
  return %false : i1
}

// Returns whether %m is a right holding the handles %first and %second.
func.func @holds_pair(%m: !monad.either<!monad.error<@definite>, i32, i32>, %first: i32, %second: i32) -> i1 {
  monad.either.branch %m, left ^left, right ^right : !monad.either<!monad.error<@definite>, i32, i32>
^left(%error: !monad.error<@definite>):
  %false = arith.constant false
  return %false : i1
^right(%a: i32, %b: i32):
  %first_equal = arith.cmpi eq, %a, %first : i32
  %second_equal = arith.cmpi eq, %b, %second : i32
  %equal = arith.andi %first_equal, %second_equal : i1
  return %equal : i1
}

// Returns whether %m is a left.
func.func @fails(%m: !monad.either<!monad.error<@definite>, i32, i32>) -> i1 {
  monad.either.branch %m, left ^left, right ^right : !monad.either<!monad.error<@definite>, i32, i32>
^left(%error: !monad.error<@definite>):
  %true = arith.constant true
  return %true : i1
^right(%a: i32, %b: i32):
  %false = arith.constant false
  return %false : i1
}

// Returns 0 if every check passes, otherwise the number of the first failing
// check.
func.func @main() -> i32 {
  %true = arith.constant true
  %false = arith.constant false
  %zero = arith.constant 0 : i32
  %one = arith.constant 1 : i32
  %two = arith.constant 2 : i32
  %three = arith.constant 3 : i32
  %five = arith.constant 5 : i32
  %six = arith.constant 6 : i32
  %seven = arith.constant 7 : i32
  %minus_one = arith.constant -1 : i32
  %minus_four = arith.constant -4 : i32
  %minus_five = arith.constant -5 : i32
  %minus_nineteen = arith.constant -19 : i32
  %int_min = arith.constant -2147483648 : i32
  %c106 = arith.constant 106 : i32
  %c200 = arith.constant 200 : i32
  %c225 = arith.constant 225 : i32
  %c9 = arith.constant 9 : i32
  %c10 = arith.constant 10 : i32

  // 1-3: safe_div(7, 2) = 3, safe_div(7, 0) = div_by_zero,
  // safe_div(INT_MIN, -1) = overflow.
  %r1 = func.call @safe_div(%seven, %two) : (i32, i32) -> !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
  %ok1 = func.call @holds(%r1, %three) : (!monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>, i32) -> i1
  %r2 = func.call @safe_div(%seven, %zero) : (i32, i32) -> !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
  %ok2 = func.call @throws(%r2, %false) : (!monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>, i1) -> i1
  %r3 = func.call @safe_div(%int_min, %minus_one) : (i32, i32) -> !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
  %ok3 = func.call @throws(%r3, %true) : (!monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>, i1) -> i1

  // 4-6: half_ratio(7, 2) = 3, half_ratio(7, 0) = 0,
  // half_ratio(INT_MIN, -1) = overflow, widened by @widen_overflow to reuse
  // the checks.
  %h4 = func.call @half_ratio(%seven, %two) : (i32, i32) -> !monad.either<!monad.error<@overflow>, i32>
  %r4 = func.call @widen_overflow(%h4) : (!monad.either<!monad.error<@overflow>, i32>) -> !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
  %ok4 = func.call @holds(%r4, %three) : (!monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>, i32) -> i1
  %h5 = func.call @half_ratio(%seven, %zero) : (i32, i32) -> !monad.either<!monad.error<@overflow>, i32>
  %r5 = func.call @widen_overflow(%h5) : (!monad.either<!monad.error<@overflow>, i32>) -> !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
  %ok5 = func.call @holds(%r5, %zero) : (!monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>, i32) -> i1
  %h6 = func.call @half_ratio(%int_min, %minus_one) : (i32, i32) -> !monad.either<!monad.error<@overflow>, i32>
  %r6 = func.call @widen_overflow(%h6) : (!monad.either<!monad.error<@overflow>, i32>) -> !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
  %ok6 = func.call @throws(%r6, %true) : (!monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>, i1) -> i1

  // 7-10: tile_and_fuse(5, 6) = (106, 225), tile_and_fuse(0, 6) = (106, 200),
  // tile_and_fuse(-19, 6) = (6, 1), tile_and_fuse(5, 2) = definite.
  %r7 = func.call @tile_and_fuse(%five, %six) : (i32, i32) -> !monad.either<!monad.error<@definite>, i32, i32>
  %ok7 = func.call @holds_pair(%r7, %c106, %c225) : (!monad.either<!monad.error<@definite>, i32, i32>, i32, i32) -> i1
  %r8 = func.call @tile_and_fuse(%zero, %six) : (i32, i32) -> !monad.either<!monad.error<@definite>, i32, i32>
  %ok8 = func.call @holds_pair(%r8, %c106, %c200) : (!monad.either<!monad.error<@definite>, i32, i32>, i32, i32) -> i1
  %check9_expected_first = arith.constant 6 : i32
  %r9 = func.call @tile_and_fuse(%minus_nineteen, %six) : (i32, i32) -> !monad.either<!monad.error<@definite>, i32, i32>
  %ok9 = func.call @holds_pair(%r9, %check9_expected_first, %one) : (!monad.either<!monad.error<@definite>, i32, i32>, i32, i32) -> i1
  %r10 = func.call @tile_and_fuse(%five, %two) : (i32, i32) -> !monad.either<!monad.error<@definite>, i32, i32>
  %ok10 = func.call @fails(%r10) : (!monad.either<!monad.error<@definite>, i32, i32>) -> i1

  // 11-12: first_negative(3, -4, -5) = -4, first_negative(1, 2, 3) = 0.
  %r11 = func.call @first_negative(%three, %minus_four, %minus_five) : (i32, i32, i32) -> i32
  %ok11 = arith.cmpi eq, %r11, %minus_four : i32
  %r12 = func.call @first_negative(%one, %two, %three) : (i32, i32, i32) -> i32
  %ok12 = arith.cmpi eq, %r12, %zero : i32

  // 14-16: half_ratio_long gives the results of half_ratio: 3, 0, overflow.
  %l14 = func.call @half_ratio_long(%seven, %two) : (i32, i32) -> !monad.either<!monad.error<@overflow>, i32>
  %w14 = func.call @widen_overflow(%l14) : (!monad.either<!monad.error<@overflow>, i32>) -> !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
  %ok14 = func.call @holds(%w14, %three) : (!monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>, i32) -> i1
  %l15 = func.call @half_ratio_long(%seven, %zero) : (i32, i32) -> !monad.either<!monad.error<@overflow>, i32>
  %w15 = func.call @widen_overflow(%l15) : (!monad.either<!monad.error<@overflow>, i32>) -> !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
  %ok15 = func.call @holds(%w15, %zero) : (!monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>, i32) -> i1
  %l16 = func.call @half_ratio_long(%int_min, %minus_one) : (i32, i32) -> !monad.either<!monad.error<@overflow>, i32>
  %w16 = func.call @widen_overflow(%l16) : (!monad.either<!monad.error<@overflow>, i32>) -> !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
  %ok16 = func.call @throws(%w16, %true) : (!monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>, i1) -> i1

  // 13: clamp_index(10, 10) = 9, from the payload of out_of_bounds.
  %r13 = func.call @clamp_index(%c10, %c10) : (i32, i32) -> !monad.either<!monad.error<@out_of_bounds, i32, i32>, i32>
  monad.either.branch %r13, left ^bounds_left, right ^bounds_right : !monad.either<!monad.error<@out_of_bounds, i32, i32>, i32>
^bounds_left(%bounds_error: !monad.error<@out_of_bounds, i32, i32>):
  return %c10 : i32
^bounds_right(%clamped: i32):
  %ok13 = arith.cmpi eq, %clamped, %c9 : i32

  %results = arith.constant 0 : i32
  %f16 = arith.constant 16 : i32
  %f15 = arith.constant 15 : i32
  %f14 = arith.constant 14 : i32
  %f13 = arith.constant 13 : i32
  %f12 = arith.constant 12 : i32
  %f11 = arith.constant 11 : i32
  %f10 = arith.constant 10 : i32
  %f9 = arith.constant 9 : i32
  %f8 = arith.constant 8 : i32
  %f7 = arith.constant 7 : i32
  %f6 = arith.constant 6 : i32
  %f5 = arith.constant 5 : i32
  %f4 = arith.constant 4 : i32
  %f3 = arith.constant 3 : i32
  %f2 = arith.constant 2 : i32
  %f1 = arith.constant 1 : i32
  %s16 = arith.select %ok16, %results, %f16 : i32
  %s15 = arith.select %ok15, %s16, %f15 : i32
  %s14 = arith.select %ok14, %s15, %f14 : i32
  %s13 = arith.select %ok13, %s14, %f13 : i32
  %s12 = arith.select %ok12, %s13, %f12 : i32
  %s11 = arith.select %ok11, %s12, %f11 : i32
  %s10 = arith.select %ok10, %s11, %f10 : i32
  %s9 = arith.select %ok9, %s10, %f9 : i32
  %s8 = arith.select %ok8, %s9, %f8 : i32
  %s7 = arith.select %ok7, %s8, %f7 : i32
  %s6 = arith.select %ok6, %s7, %f6 : i32
  %s5 = arith.select %ok5, %s6, %f5 : i32
  %s4 = arith.select %ok4, %s5, %f4 : i32
  %s3 = arith.select %ok3, %s4, %f3 : i32
  %s2 = arith.select %ok2, %s3, %f2 : i32
  %s1 = arith.select %ok1, %s2, %f1 : i32
  return %s1 : i32
}
