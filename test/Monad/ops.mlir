// RUN: fum-opt %s | fum-opt | FileCheck %s
// RUN: fum-opt %s --mlir-print-op-generic | fum-opt | FileCheck %s

// Error types and error unions print as aliases at the top of the module.
// CHECK-DAG: ![[OVERFLOW:error_overflow]] = !monad.error<@overflow>
// CHECK-DAG: ![[BOUNDS:error_out_of_bounds]] = !monad.error<@out_of_bounds, index, index>
// CHECK-DAG: ![[DIV:error_div_by_zero]] = !monad.error<@div_by_zero>
// CHECK-DAG: ![[ARITH:errors_div_by_zero_overflow]] = !monad.error_union<{![[DIV]], ![[OVERFLOW]]}>

// The errors of the tests; @payload has an explicit tag.
// CHECK: monad.error.declare @overflow{{$}}
// CHECK: monad.error.declare @out_of_bounds(index, index){{$}}
// CHECK: monad.error.declare @payload(i32) tag 7{{$}}
monad.error.declare @overflow
monad.error.declare @out_of_bounds(index, index)
monad.error.declare @div_by_zero
monad.error.declare @other
monad.error.declare @payload(i32) tag 7

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

// Round-trip error types with and without payload.
// CHECK-LABEL: func.func private @error_types
// CHECK-SAME: ![[OVERFLOW]], ![[BOUNDS]]
func.func private @error_types(!monad.error<@overflow>,
    !monad.error<@out_of_bounds, index, index>)

// Aliases written by hand parse back.
!error_by_hand = !monad.error<@overflow>
// CHECK-LABEL: func.func private @error_alias
// CHECK-SAME: ![[OVERFLOW]]
func.func private @error_alias(!error_by_hand)

// The errors of a union are a set: they are printed sorted by name, whatever
// their order in the input.
// CHECK-LABEL: func.func private @error_union_types
// CHECK-SAME: ![[ARITH]], ![[ARITH]]
func.func private @error_union_types(
    !monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>,
    !monad.error_union<{!monad.error<@overflow>, !monad.error<@div_by_zero>}>)

// Round-trip the either type with any left type, and one, several, and no
// value types on the right, the latter written none; a function type is a
// single value type.
// CHECK-LABEL: func.func private @either_types
// CHECK-SAME: !monad.either<i32, f32>
// CHECK-SAME: !monad.either<![[ARITH]], i8, i32>
// CHECK-SAME: !monad.either<i32, none>
// CHECK-SAME: !monad.either<!monad.maybe<i32>, !monad.either<i1, i32>>
// CHECK-SAME: !monad.either<i1, (i32) -> i32>
func.func private @either_types(!monad.either<i32, f32>,
    !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i8, i32>,
    !monad.either<i32, none>, !monad.either<!monad.maybe<i32>, !monad.either<i1, i32>>,
    !monad.either<i1, (i32) -> i32>)

// Make an error with a payload and read the payload back.
// CHECK-LABEL: func.func @error_payload
// CHECK: %[[ERROR:.+]] = monad.error.throw %{{.+}}, %{{.+}} : ![[BOUNDS]]
// CHECK: monad.error.payload %[[ERROR]] : ![[BOUNDS]]
// CHECK: monad.error.throw : ![[OVERFLOW]]
func.func @error_payload(%index: index, %size: index) -> (index, index) {
  %error = monad.error.throw %index, %size : !monad.error<@out_of_bounds, index, index>
  %first, %second = monad.error.payload %error : !monad.error<@out_of_bounds, index, index>
  %overflow = monad.error.throw : !monad.error<@overflow>
  return %first, %second : index, index
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

// Branch on the member of an error union: one case lists a single error, the
// other a group of the remaining members.
// CHECK-LABEL: func.func @error_union_switch
// CHECK: monad.error.switch %{{.+}} [![[OVERFLOW]] -> ^[[SINGLE:.+]], !errors_div_by_zero_other -> ^[[GROUP:.+]]] : !errors_div_by_zero_other_overflow
// CHECK: ^[[SINGLE]](%{{.+}}: ![[OVERFLOW]]):
// CHECK: ^[[GROUP]](%{{.+}}: !errors_div_by_zero_other):
func.func @error_union_switch(%error: !monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@other>, !monad.error<@overflow>}>) -> i32 {
  monad.error.switch %error [!monad.error<@overflow> -> ^single,
                             !monad.error_union<{!monad.error<@other>, !monad.error<@div_by_zero>}> -> ^group]
      : !monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@other>, !monad.error<@overflow>}>
^single(%overflow: !monad.error<@overflow>):
  %one = arith.constant 1 : i32
  return %one : i32
^group(%others: !monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@other>}>):
  %two = arith.constant 2 : i32
  return %two : i32
}

// Bind an either value in a do with the same left type and other value types.
// CHECK-LABEL: func.func @either_bind
// CHECK: monad.do : !monad.either<![[ARITH]], f32>
// CHECK: monad.bind %{{.+}}, ^[[NEXT:.+]] : !monad.either<![[ARITH]], i32>
// CHECK: ^[[NEXT]](%{{.+}}: i32):
func.func @either_bind(%input: !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>)
    -> !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, f32> {
  %result = monad.do : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, f32> {
    monad.bind %input, ^next : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
  ^next(%value: i32):
    %converted = arith.sitofp %value : i32 to f32
    %wrapped = monad.return %converted : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, f32>
    monad.yield %wrapped : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, f32>
  }
  return %result : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, f32>
}

// Create an error, widen it to a union, and put it on the left of an either.
// CHECK-LABEL: func.func @throw_widen_left
// CHECK: %[[ERROR:.+]] = monad.error.throw : ![[OVERFLOW]]
// CHECK: %[[ERRORS:.+]] = monad.error.widen %[[ERROR]] : ![[OVERFLOW]] to ![[ARITH]]
// CHECK: monad.either.left %[[ERRORS]] : !monad.either<![[ARITH]], i32>
func.func @throw_widen_left() -> !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32> {
  %error = monad.error.throw : !monad.error<@overflow>
  %errors = monad.error.widen %error : !monad.error<@overflow> to !monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>
  %failure = monad.either.left %errors : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
  return %failure : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
}

// Catch one error with an ok successor; the other error leaves the do, whose
// left type is that single error.
// CHECK-LABEL: func.func @catch_with_ok
// CHECK: monad.error.catch %{{.+}}, ^[[OK:.+]] [![[DIV]] -> ^[[RECOVER:.+]]] : !monad.either<![[ARITH]], i32>
// CHECK: ^[[OK]](%{{.+}}: i32):
// CHECK: ^[[RECOVER]](%{{.+}}: ![[DIV]]):
func.func @catch_with_ok(%input: !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>)
    -> !monad.either<!monad.error<@overflow>, i32> {
  %result = monad.do : !monad.either<!monad.error<@overflow>, i32> {
    monad.error.catch %input, ^ok [!monad.error<@div_by_zero> -> ^recover]
        : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>, i32>
  ^ok(%value: i32):
    %wrapped = monad.return %value : !monad.either<!monad.error<@overflow>, i32>
    monad.yield %wrapped : !monad.either<!monad.error<@overflow>, i32>
  ^recover(%error: !monad.error<@div_by_zero>):
    %zero = arith.constant 0 : i32
    %recovered = monad.return %zero : !monad.either<!monad.error<@overflow>, i32>
    monad.yield %recovered : !monad.either<!monad.error<@overflow>, i32>
  }
  return %result : !monad.either<!monad.error<@overflow>, i32>
}

// Catch the only error of an input whose left type is one error; the do may
// fail with another single error.
// CHECK-LABEL: func.func @catch_single_error
// CHECK: monad.error.catch %{{.+}}, ^{{.+}} [![[DIV]] -> ^{{.+}}] : !monad.either<![[DIV]], i32>
func.func @catch_single_error(%input: !monad.either<!monad.error<@div_by_zero>, i32>)
    -> !monad.either<!monad.error<@overflow>, i32> {
  %result = monad.do : !monad.either<!monad.error<@overflow>, i32> {
    monad.error.catch %input, ^ok [!monad.error<@div_by_zero> -> ^recover]
        : !monad.either<!monad.error<@div_by_zero>, i32>
  ^ok(%value: i32):
    %wrapped = monad.return %value : !monad.either<!monad.error<@overflow>, i32>
    monad.yield %wrapped : !monad.either<!monad.error<@overflow>, i32>
  ^recover(%error: !monad.error<@div_by_zero>):
    %zero = arith.constant 0 : i32
    %recovered = monad.return %zero : !monad.either<!monad.error<@overflow>, i32>
    monad.yield %recovered : !monad.either<!monad.error<@overflow>, i32>
  }
  return %result : !monad.either<!monad.error<@overflow>, i32>
}

// Catch without an ok successor: a right ends the do with the input. The
// handler of a group case receives the group.
// CHECK-LABEL: func.func @catch_without_ok
// CHECK: monad.error.catch %{{.+}} [![[ARITH]] -> ^[[HANDLER:.+]], !error_payload -> ^[[PAYLOAD:.+]]] : !monad.either<!errors_div_by_zero_other_overflow_payload, i32>
// CHECK: ^[[HANDLER]](%{{.+}}: ![[ARITH]]):
// CHECK: ^[[PAYLOAD]](%{{.+}}: !error_payload):
// CHECK: monad.error.payload
func.func @catch_without_ok(%input: !monad.either<!monad.error_union<{!monad.error<@payload, i32>, !monad.error<@overflow>, !monad.error<@div_by_zero>, !monad.error<@other>}>, i32>)
    -> !monad.either<!monad.error_union<{!monad.error<@payload, i32>, !monad.error<@overflow>, !monad.error<@div_by_zero>, !monad.error<@other>}>, i32> {
  %result = monad.do : !monad.either<!monad.error_union<{!monad.error<@payload, i32>, !monad.error<@overflow>, !monad.error<@div_by_zero>, !monad.error<@other>}>, i32> {
    monad.error.catch %input [!monad.error_union<{!monad.error<@overflow>, !monad.error<@div_by_zero>}> -> ^handler,
                              !monad.error<@payload, i32> -> ^payload]
        : !monad.either<!monad.error_union<{!monad.error<@payload, i32>, !monad.error<@overflow>, !monad.error<@div_by_zero>, !monad.error<@other>}>, i32>
  ^handler(%error: !monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@overflow>}>):
    %zero = arith.constant 0 : i32
    %recovered = monad.return %zero : !monad.either<!monad.error_union<{!monad.error<@payload, i32>, !monad.error<@overflow>, !monad.error<@div_by_zero>, !monad.error<@other>}>, i32>
    monad.yield %recovered : !monad.either<!monad.error_union<{!monad.error<@payload, i32>, !monad.error<@overflow>, !monad.error<@div_by_zero>, !monad.error<@other>}>, i32>
  ^payload(%payload_error: !monad.error<@payload, i32>):
    %value = monad.error.payload %payload_error : !monad.error<@payload, i32>
    %wrapped = monad.return %value : !monad.either<!monad.error_union<{!monad.error<@payload, i32>, !monad.error<@overflow>, !monad.error<@div_by_zero>, !monad.error<@other>}>, i32>
    monad.yield %wrapped : !monad.either<!monad.error_union<{!monad.error<@payload, i32>, !monad.error<@overflow>, !monad.error<@div_by_zero>, !monad.error<@other>}>, i32>
  }
  return %result : !monad.either<!monad.error_union<{!monad.error<@payload, i32>, !monad.error<@overflow>, !monad.error<@div_by_zero>, !monad.error<@other>}>, i32>
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

// A switch with a default case: the default receives the union of the errors
// that no case lists. A single error can be switched on too.
// CHECK-LABEL: func.func @error_switch_default
// CHECK: monad.error.switch %{{.+}} [![[DIV]] -> ^[[DIVISION:.+]], default -> ^[[REST:.+]]] : !errors_div_by_zero_other_overflow
// CHECK: ^[[DIVISION]](%{{.+}}: ![[DIV]]):
// CHECK: ^[[REST]](%{{.+}}: !errors_other_overflow):
// CHECK: monad.error.switch %{{.+}} [![[OVERFLOW]] -> ^{{.+}}] : ![[OVERFLOW]]
func.func @error_switch_default(%error: !monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@other>, !monad.error<@overflow>}>,
                                %single: !monad.error<@overflow>) -> i32 {
  monad.error.switch %error [!monad.error<@div_by_zero> -> ^division, default -> ^rest]
      : !monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@other>, !monad.error<@overflow>}>
^division(%division_error: !monad.error<@div_by_zero>):
  %one = arith.constant 1 : i32
  return %one : i32
^rest(%others: !monad.error_union<{!monad.error<@other>, !monad.error<@overflow>}>):
  monad.error.switch %single [!monad.error<@overflow> -> ^overflow] : !monad.error<@overflow>
^overflow(%overflow: !monad.error<@overflow>):
  %two = arith.constant 2 : i32
  return %two : i32
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

// Widening a union to a larger union, and a union of one error to that error.
// CHECK-LABEL: func.func @widen_union
// CHECK: monad.error.widen %{{.+}} : !errors_other_overflow to !errors_div_by_zero_other_overflow
// CHECK: monad.error.widen %{{.+}} : !errors_overflow to ![[OVERFLOW]]
func.func @widen_union(%errors: !monad.error_union<{!monad.error<@other>, !monad.error<@overflow>}>,
                       %one: !monad.error_union<{!monad.error<@overflow>}>)
    -> (!monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@other>, !monad.error<@overflow>}>, !monad.error<@overflow>) {
  %larger = monad.error.widen %errors : !monad.error_union<{!monad.error<@other>, !monad.error<@overflow>}>
      to !monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@other>, !monad.error<@overflow>}>
  %single = monad.error.widen %one : !monad.error_union<{!monad.error<@overflow>}> to !monad.error<@overflow>
  return %larger, %single : !monad.error_union<{!monad.error<@div_by_zero>, !monad.error<@other>, !monad.error<@overflow>}>, !monad.error<@overflow>
}
