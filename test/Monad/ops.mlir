// RUN: fum-opt %s | fum-opt | FileCheck %s
// RUN: fum-opt %s --mlir-print-op-generic | fum-opt | FileCheck %s

// Error types are printed as aliases named after the error, and the aliases
// are parsed back.
// CHECK-DAG: !error_a = !monad.error<@a>
// CHECK-DAG: !error_b = !monad.error<@b>
// CHECK-DAG: !error_overflow = !monad.error<@overflow>
// CHECK-DAG: !error_silenceable = !monad.error<@silenceable, i32>

// The errors of the tests; @silenceable has an explicit tag.
// CHECK: monad.error.declare @a{{$}}
// CHECK: monad.error.declare @silenceable(i32) tag 7{{$}}
monad.error.declare @a
monad.error.declare @b
monad.error.declare @overflow
monad.error.declare @silenceable(i32) tag 7

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

// Round-trip the error types, with and without payload, and an error union.
// CHECK-LABEL: func.func private @error_types
// CHECK-SAME: !error_overflow, !error_silenceable, !monad.error_union<{!error_a, !error_b}>
func.func private @error_types(
    !monad.error<@overflow>, !monad.error<@silenceable, i32>,
    !monad.error_union<{!monad.error<@a>, !monad.error<@b>}>)

// Round-trip the value-or-error type with one, several, no, and nested value
// types, and with one and several errors.
// CHECK-LABEL: func.func private @value_or_error_types
// CHECK-SAME: !monad.value_or_error<[i32] throws {!error_overflow}>
// CHECK-SAME: !monad.value_or_error<[i8, i32] throws {!error_a, !error_overflow}>
// CHECK-SAME: !monad.value_or_error<[] throws {!error_overflow}>
// CHECK-SAME: !monad.value_or_error<[!monad.maybe<i32>] throws {!error_silenceable}>
func.func private @value_or_error_types(
    !monad.value_or_error<[i32] throws {!monad.error<@overflow>}>,
    !monad.value_or_error<[i8, i32] throws {!monad.error<@a>, !monad.error<@overflow>}>,
    !monad.value_or_error<[] throws {!monad.error<@overflow>}>,
    !monad.value_or_error<[!monad.maybe<i32>] throws {!monad.error<@silenceable, i32>}>)

// The errors are sets: they are printed sorted by name, whatever their order
// in the input.
// CHECK-LABEL: func.func private @error_order
// CHECK-SAME: !monad.value_or_error<[i32] throws {!error_a, !error_b}>
// CHECK-SAME: !monad.error_union<{!error_a, !error_b}>
func.func private @error_order(
    !monad.value_or_error<[i32] throws {!monad.error<@b>, !monad.error<@a>}>,
    !monad.error_union<{!monad.error<@b>, !monad.error<@a>}>)

// Make an error with a payload, read the payload back, and throw it.
// CHECK-LABEL: func.func @error_make_payload_throw
// CHECK: %[[ERROR:.+]] = monad.error.make %{{.*}} : !error_silenceable
// CHECK: monad.error.payload %[[ERROR]] : !error_silenceable
// CHECK: monad.throw %[[ERROR]] : !error_silenceable -> !monad.value_or_error<[i32] throws {!error_a, !error_silenceable}>
func.func @error_make_payload_throw(%id: i32)
    -> (i32, !monad.value_or_error<[i32] throws {!monad.error<@a>, !monad.error<@silenceable, i32>}>) {
  %error = monad.error.make %id : !monad.error<@silenceable, i32>
  %payload = monad.error.payload %error : !monad.error<@silenceable, i32>
  %failure = monad.throw %error : !monad.error<@silenceable, i32>
      -> !monad.value_or_error<[i32] throws {!monad.error<@a>, !monad.error<@silenceable, i32>}>
  return %payload, %failure
      : i32, !monad.value_or_error<[i32] throws {!monad.error<@a>, !monad.error<@silenceable, i32>}>
}

// Throw one error of a union, and widen the errors of a value.
// CHECK-LABEL: func.func @throw_union_widen
// CHECK: monad.throw %{{.*}} : !monad.error_union<{!error_a, !error_b}> -> !monad.value_or_error<[] throws {!error_a, !error_b}>
// CHECK: monad.widen %{{.*}} : !monad.value_or_error<[i32] throws {!error_a}> to !monad.value_or_error<[i32] throws {!error_a, !error_b}>
func.func @throw_union_widen(
    %errors: !monad.error_union<{!monad.error<@a>, !monad.error<@b>}>,
    %input: !monad.value_or_error<[i32] throws {!monad.error<@a>}>)
    -> (!monad.value_or_error<[] throws {!monad.error<@a>, !monad.error<@b>}>,
        !monad.value_or_error<[i32] throws {!monad.error<@a>, !monad.error<@b>}>) {
  %failure = monad.throw %errors : !monad.error_union<{!monad.error<@a>, !monad.error<@b>}>
      -> !monad.value_or_error<[] throws {!monad.error<@a>, !monad.error<@b>}>
  %widened = monad.widen %input : !monad.value_or_error<[i32] throws {!monad.error<@a>}>
      to !monad.value_or_error<[i32] throws {!monad.error<@a>, !monad.error<@b>}>
  return %failure, %widened
      : !monad.value_or_error<[] throws {!monad.error<@a>, !monad.error<@b>}>,
        !monad.value_or_error<[i32] throws {!monad.error<@a>, !monad.error<@b>}>
}

// Bind a value-or-error value in a do with the same errors and other value
// types.
// CHECK-LABEL: func.func @value_or_error_bind
// CHECK: monad.do : !monad.value_or_error<[f32] throws {!error_overflow}>
// CHECK: monad.bind %{{.*}}, ^[[NEXT:.+]] : !monad.value_or_error<[i32] throws {!error_overflow}>
// CHECK: ^[[NEXT]](%{{.*}}: i32):
func.func @value_or_error_bind(%input: !monad.value_or_error<[i32] throws {!monad.error<@overflow>}>)
    -> !monad.value_or_error<[f32] throws {!monad.error<@overflow>}> {
  %result = monad.do : !monad.value_or_error<[f32] throws {!monad.error<@overflow>}> {
    monad.bind %input, ^next : !monad.value_or_error<[i32] throws {!monad.error<@overflow>}>
  ^next(%value: i32):
    %converted = arith.sitofp %value : i32 to f32
    %wrapped = monad.return %converted : !monad.value_or_error<[f32] throws {!monad.error<@overflow>}>
    monad.yield %wrapped : !monad.value_or_error<[f32] throws {!monad.error<@overflow>}>
  }
  return %result : !monad.value_or_error<[f32] throws {!monad.error<@overflow>}>
}

// Catch with ^ok, a case with a payload, a grouped case, and default; the
// grouped handler is reached through two edges of one catch.
// CHECK-LABEL: func.func @catch_with_ok
// CHECK: monad.catch %{{.*}}, ^[[OK:.+]] [!error_silenceable -> ^[[SILENCEABLE:.+]], !monad.error_union<{!error_a, !error_b}> -> ^[[GROUP:.+]], default -> ^[[REST:.+]]] : !monad.value_or_error<[i32] throws {!error_a, !error_b, !error_overflow, !error_silenceable}>
// CHECK: ^[[OK]](%{{.*}}: i32):
// CHECK: ^[[SILENCEABLE]](%{{.*}}: !error_silenceable):
// CHECK: ^[[GROUP]](%{{.*}}: !monad.error_union<{!error_a, !error_b}>):
// CHECK: ^[[REST]](%{{.*}}: !monad.error_union<{!error_overflow}>):
func.func @catch_with_ok(
    %input: !monad.value_or_error<[i32] throws {!monad.error<@a>, !monad.error<@b>, !monad.error<@overflow>, !monad.error<@silenceable, i32>}>)
    -> !monad.value_or_error<[i32] throws {!monad.error<@overflow>}> {
  %result = monad.do : !monad.value_or_error<[i32] throws {!monad.error<@overflow>}> {
    monad.catch %input, ^ok [
        !monad.error<@silenceable, i32> -> ^silenceable,
        !monad.error_union<{!monad.error<@a>, !monad.error<@b>}> -> ^group,
        default -> ^rest]
        : !monad.value_or_error<[i32] throws {!monad.error<@a>, !monad.error<@b>, !monad.error<@overflow>, !monad.error<@silenceable, i32>}>
  ^ok(%value: i32):
    %success = monad.return %value : !monad.value_or_error<[i32] throws {!monad.error<@overflow>}>
    monad.yield %success : !monad.value_or_error<[i32] throws {!monad.error<@overflow>}>
  ^silenceable(%error: !monad.error<@silenceable, i32>):
    %id = monad.error.payload %error : !monad.error<@silenceable, i32>
    %recovered = monad.return %id : !monad.value_or_error<[i32] throws {!monad.error<@overflow>}>
    monad.yield %recovered : !monad.value_or_error<[i32] throws {!monad.error<@overflow>}>
  ^group(%errors: !monad.error_union<{!monad.error<@a>, !monad.error<@b>}>):
    %zero = arith.constant 0 : i32
    %fallback = monad.return %zero : !monad.value_or_error<[i32] throws {!monad.error<@overflow>}>
    monad.yield %fallback : !monad.value_or_error<[i32] throws {!monad.error<@overflow>}>
  ^rest(%other: !monad.error_union<{!monad.error<@overflow>}>):
    %rethrown = monad.throw %other : !monad.error_union<{!monad.error<@overflow>}>
        -> !monad.value_or_error<[i32] throws {!monad.error<@overflow>}>
    monad.yield %rethrown : !monad.value_or_error<[i32] throws {!monad.error<@overflow>}>
  }
  return %result : !monad.value_or_error<[i32] throws {!monad.error<@overflow>}>
}

// Catch without ^ok: a success and the uncaught overflow end the do with the
// input.
// CHECK-LABEL: func.func @catch_without_ok
// CHECK: monad.catch %{{.*}} [!error_a -> ^[[RECOVER:.+]]] : !monad.value_or_error<[i32] throws {!error_a, !error_overflow}>
// CHECK: ^[[RECOVER]](%{{.*}}: !error_a):
func.func @catch_without_ok(%input: !monad.value_or_error<[i32] throws {!monad.error<@a>, !monad.error<@overflow>}>)
    -> !monad.value_or_error<[i32] throws {!monad.error<@a>, !monad.error<@overflow>}> {
  %result = monad.do : !monad.value_or_error<[i32] throws {!monad.error<@a>, !monad.error<@overflow>}> {
    monad.catch %input [!monad.error<@a> -> ^recover]
        : !monad.value_or_error<[i32] throws {!monad.error<@a>, !monad.error<@overflow>}>
  ^recover(%error: !monad.error<@a>):
    %zero = arith.constant 0 : i32
    %recovered = monad.return %zero : !monad.value_or_error<[i32] throws {!monad.error<@a>, !monad.error<@overflow>}>
    monad.yield %recovered : !monad.value_or_error<[i32] throws {!monad.error<@a>, !monad.error<@overflow>}>
  }
  return %result : !monad.value_or_error<[i32] throws {!monad.error<@a>, !monad.error<@overflow>}>
}
