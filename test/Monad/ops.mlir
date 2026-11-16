// RUN: fum-opt %s | fum-opt | FileCheck %s
// RUN: fum-opt %s --mlir-print-op-generic | fum-opt | FileCheck %s

// The exception types print as aliases.
// CHECK-DAG: !exception = !monad.exception
// CHECK-DAG: !voe = !monad.value_or_exception<>
// CHECK-DAG: !voe_i32 = !monad.value_or_exception<i32>
// CHECK-DAG: !voe_i8_f32 = !monad.value_or_exception<i8, f32>
// CHECK-DAG: !{{voe[0-9]*}} = !monad.value_or_exception<!monad.maybe<i32>>

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

// Exception kinds used by the value-or-exception tests.
// CHECK: monad.exception.declare @div_by_zero{{$}}
// CHECK: monad.exception.declare @overflow{{$}}
// CHECK: monad.exception.declare @io(i32)
// CHECK: monad.exception.declare @timeout(i32)
// CHECK: monad.exception.declare @pair(i1, index)
monad.exception.declare @div_by_zero
monad.exception.declare @overflow
monad.exception.declare @io(i32)
monad.exception.declare @timeout(i32)
monad.exception.declare @pair(i1, index)

// Round-trip the exception types with empty, one, several, and nested value
// types; the types print as aliases (checked at the top of the file).
// CHECK-LABEL: func.func private @exception_types
// CHECK-SAME: (!exception, !voe, !voe_i32, !voe_i8_f32, !{{voe[0-9]*}})
func.func private @exception_types(
    !monad.exception,
    !monad.value_or_exception<>,
    !monad.value_or_exception<i32>,
    !monad.value_or_exception<i8, f32>,
    !monad.value_or_exception<!monad.maybe<i32>>)

// The aliases parse back.
// CHECK-LABEL: func.func private @exception_aliases
// CHECK-SAME: (!exception, !voe_i32)
!exception_alias = !monad.exception
!voe_alias = !monad.value_or_exception<i32>
func.func private @exception_aliases(!exception_alias, !voe_alias)

// The may_throw attribute lists declared kinds.
// CHECK-LABEL: func.func private @may_throw
// CHECK-SAME: attributes {monad.may_throw = [@div_by_zero, @io]}
func.func private @may_throw() -> !monad.value_or_exception<i32>
    attributes {monad.may_throw = [@div_by_zero, @io]}

// Make exceptions without and with payloads, and throw them.
// CHECK-LABEL: func.func @make_and_throw
// CHECK: monad.exception.make @div_by_zero{{$}}
// CHECK: monad.exception.make @io(%{{.*}}) : (i32)
// CHECK: monad.exception.make @pair(%{{.*}}, %{{.*}}) : (i1, index)
// CHECK: monad.throw %{{.*}} : !voe_i32
func.func @make_and_throw(%code: i32, %flag: i1, %index: index)
    -> !monad.value_or_exception<i32> {
  %div_by_zero = monad.exception.make @div_by_zero
  %io = monad.exception.make @io(%code) : (i32)
  %pair = monad.exception.make @pair(%flag, %index) : (i1, index)
  %failure = monad.throw %io : !monad.value_or_exception<i32>
  return %failure : !monad.value_or_exception<i32>
}

// Catch with ^ok, a grouped case with a payload, a case without payload, and
// a default receiving the exception, which it re-throws.
// CHECK-LABEL: func.func @catch_with_ok
// CHECK: monad.catch %{{.*}}, ^[[OK:.+]] [@io, @timeout -> ^[[IO:.+]], @div_by_zero -> ^[[DIV:.+]], default -> ^[[OTHER:.+]]] : !voe_i32
// CHECK: ^[[OK]](%{{.*}}: i32):
// CHECK: ^[[IO]](%{{.*}}: i32):
// CHECK: ^[[DIV]]:
// CHECK: ^[[OTHER]](%{{.*}}: !exception):
// CHECK: monad.throw %{{.*}} : !voe_i32
func.func @catch_with_ok(%input: !monad.value_or_exception<i32>)
    -> !monad.value_or_exception<i32> {
  %result = monad.do : !monad.value_or_exception<i32> {
    monad.catch %input, ^ok [@io, @timeout -> ^io, @div_by_zero -> ^div,
                             default -> ^other] : !monad.value_or_exception<i32>
  ^ok(%value: i32):
    %success = monad.return %value : !monad.value_or_exception<i32>
    monad.yield %success : !monad.value_or_exception<i32>
  ^io(%code: i32):
    %recovered = monad.return %code : !monad.value_or_exception<i32>
    monad.yield %recovered : !monad.value_or_exception<i32>
  ^div:
    %c0 = arith.constant 0 : i32
    %zero = monad.return %c0 : !monad.value_or_exception<i32>
    monad.yield %zero : !monad.value_or_exception<i32>
  ^other(%exception: !monad.exception):
    %failure = monad.throw %exception : !monad.value_or_exception<i32>
    monad.yield %failure : !monad.value_or_exception<i32>
  }
  return %result : !monad.value_or_exception<i32>
}

// Catch without ^ok and without default: success and unmatched failures end
// the do with the input. Two kinds may also reach one block through two cases.
// CHECK-LABEL: func.func @catch_without_ok
// CHECK: monad.catch %{{.*}} [@div_by_zero -> ^[[RECOVER:.+]], @overflow -> ^[[RECOVER]]] : !voe_i32
// CHECK: ^[[RECOVER]]:
func.func @catch_without_ok(%input: !monad.value_or_exception<i32>)
    -> !monad.value_or_exception<i32> {
  %result = monad.do : !monad.value_or_exception<i32> {
    monad.catch %input [@div_by_zero -> ^recover, @overflow -> ^recover]
        : !monad.value_or_exception<i32>
  ^recover:
    %c0 = arith.constant 0 : i32
    %zero = monad.return %c0 : !monad.value_or_exception<i32>
    monad.yield %zero : !monad.value_or_exception<i32>
  }
  return %result : !monad.value_or_exception<i32>
}

// A catch with ^ok and no cases binds the input; its failure ends the do,
// whose value types differ.
// CHECK-LABEL: func.func @catch_no_cases
// CHECK: monad.catch %{{.*}}, ^{{.+}} [] : !voe{{$}}
func.func @catch_no_cases(%input: !monad.value_or_exception<>)
    -> !monad.value_or_exception<i32> {
  %result = monad.do : !monad.value_or_exception<i32> {
    monad.catch %input, ^ok [] : !monad.value_or_exception<>
  ^ok:
    %c1 = arith.constant 1 : i32
    %one = monad.return %c1 : !monad.value_or_exception<i32>
    monad.yield %one : !monad.value_or_exception<i32>
  }
  return %result : !monad.value_or_exception<i32>
}

// Bind a value-or-exception value in a do with other value types.
// CHECK-LABEL: func.func @value_or_exception_bind
// CHECK: monad.bind %{{.*}}, ^{{.+}} : !voe_i32
func.func @value_or_exception_bind(%input: !monad.value_or_exception<i32>)
    -> !monad.value_or_exception<f32> {
  %result = monad.do : !monad.value_or_exception<f32> {
    monad.bind %input, ^next : !monad.value_or_exception<i32>
  ^next(%value: i32):
    %converted = arith.sitofp %value : i32 to f32
    %wrapped = monad.return %converted : !monad.value_or_exception<f32>
    monad.yield %wrapped : !monad.value_or_exception<f32>
  }
  return %result : !monad.value_or_exception<f32>
}
