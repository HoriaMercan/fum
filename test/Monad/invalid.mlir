// RUN: fum-opt %s --split-input-file --verify-diagnostics

func.func @return_value_type_mismatch(%value: i64) {
  // expected-error @below {{failed to verify that value types match the value types of the result}}
  %result = "monad.return"(%value) : (i64) -> !monad.maybe<i32>
  return
}

// -----

func.func @return_value_count_mismatch(%value: i32) {
  // expected-error @below {{failed to verify that value types match the value types of the result}}
  %result = "monad.return"(%value) : (i32) -> !monad.maybe<i32, i32>
  return
}

// -----

// expected-note @below {{prior use here}}
func.func @return_value_type_mismatch_custom_syntax(%value: i64) {
  // expected-error @below {{use of value '%value' expects different type than prior uses: 'i32' vs 'i64'}}
  %result = monad.return %value : !monad.maybe<i32>
  return
}

// -----

func.func @return_not_monadic(%value: i32) {
  // expected-error @below {{result #0 must be MonadTypeInterface instance, but got 'i32'}}
  %result = "monad.return"(%value) : (i32) -> i32
  return
}

// -----

func.func @return_unqualified_type(%value: i32) {
  // expected-error @below {{expected non-function type}}
  %result = monad.return %value : <i32>
  return
}

// -----

func.func @maybe_none_not_maybe() {
  // expected-error @below {{result #0 must be Maybe monad type, but got 'i32'}}
  %result = "monad.maybe.none"() : () -> i32
  return
}

// -----

func.func @maybe_none_with_operand(%error: i8) {
  // expected-error @below {{requires zero operands}}
  %result = "monad.maybe.none"(%error) : (i8) -> !monad.maybe<i32>
  return
}

// -----

// expected-error @below {{expected '<'}}
func.func private @maybe_without_parameters(!monad.maybe)

// -----

// expected-error @below {{expected non-function type}}
func.func private @maybe_with_trailing_comma(!monad.maybe<i32,>)

// -----

func.func @do_not_monadic() {
  // expected-error @below {{result #0 must be MonadTypeInterface instance, but got 'i32'}}
  %result = monad.do : i32 {
    %zero = arith.constant 0 : i32
    %wrapped = monad.return %zero : !monad.maybe<i32>
    monad.yield %wrapped : !monad.maybe<i32>
  }
  return
}

// -----

// -----

func.func @bind_outside_do(%input: !monad.maybe<i32>) {
  // expected-error @below {{expects parent op 'monad.do'}}
  monad.bind %input, ^next : !monad.maybe<i32>
^next(%value: i32):
  return
}

// -----

func.func @bind_input_not_monadic(%input: i32) {
  %result = monad.do : !monad.maybe<i32> {
    // expected-error @below {{operand #0 must be MonadTypeInterface instance, but got 'i32'}}
    "monad.bind"(%input) [^next] : (i32) -> ()
  ^next(%value: i32):
    %none = monad.maybe.none : !monad.maybe<i32>
    monad.yield %none : !monad.maybe<i32>
  }
  return
}

// -----

func.func @bind_successor_type_mismatch(%input: !monad.maybe<i32>) {
  %result = monad.do : !monad.maybe<i32> {
    // expected-error @below {{expects the successor to take arguments of types ('i32')}}
    monad.bind %input, ^next : !monad.maybe<i32>
  ^next(%value: f32):
    %none = monad.maybe.none : !monad.maybe<i32>
    monad.yield %none : !monad.maybe<i32>
  }
  return
}

// -----

func.func @bind_successor_count_mismatch(%input: !monad.maybe<i32, i32>) {
  %result = monad.do : !monad.maybe<i32> {
    // expected-error @below {{branch has 2 operands for successor #0, but target block has 1}}
    monad.bind %input, ^next : !monad.maybe<i32, i32>
  ^next(%value: i32):
    %none = monad.maybe.none : !monad.maybe<i32>
    monad.yield %none : !monad.maybe<i32>
  }
  return
}

// -----

func.func @bind_without_successor(%input: !monad.maybe<i32>) {
  %result = monad.do : !monad.maybe<i32> {
    // expected-error @below {{expected ','}}
    monad.bind %input : !monad.maybe<i32>
  }
  return
}

// -----

func.func @yield_outside_do(%input: !monad.maybe<i32>) -> !monad.maybe<i32> {
  // expected-error @below {{expects parent op 'monad.do'}}
  monad.yield %input : !monad.maybe<i32>
}

// -----

func.func @yield_type_mismatch(%input: !monad.maybe<i32>) {
  %result = monad.do : !monad.maybe<f32> {
    // expected-error @below {{expects the yielded value to be of the result type of the enclosing monad.do, '!monad.maybe<f32>', got '!monad.maybe<i32>'}}
    monad.yield %input : !monad.maybe<i32>
  }
  return
}

// -----

func.func @do_block_without_terminator(%input: !monad.maybe<i32>) {
  %result = monad.do : !monad.maybe<i32> {
    // expected-error @below {{block with no terminator}}
    %none = monad.maybe.none : !monad.maybe<i32>
  }
  return
}

// -----

// Reject a non-entry block without a predecessor.
func.func @do_block_without_predecessor(%input: !monad.maybe<i32>) {
  // expected-error @below {{expects every block except the first to have a unique predecessor}}
  %result = monad.do : !monad.maybe<i32> {
    monad.yield %input : !monad.maybe<i32>
  ^unreachable:
    monad.yield %input : !monad.maybe<i32>
  }
  return
}

// -----

// Reject a block reached by both the entry block and a backedge.
func.func @do_block_with_multiple_predecessors(%input: !monad.maybe<>) {
  // expected-error @below {{expects every block except the first to have a unique predecessor}}
  %result = monad.do : !monad.maybe<> {
    monad.bind %input, ^loop : !monad.maybe<>
  ^loop:
    monad.bind %input, ^loop : !monad.maybe<>
  }
  return
}

// -----

// Reject a foreign terminator in the entry block.
func.func @do_entry_block_with_foreign_terminator() {
  // expected-error @below {{expects every block terminator to belong to the monad dialect}}
  %result = monad.do : !monad.maybe<> {
    dep.yield
  }
  return
}

// -----

// Reject a foreign terminator in a continuation block.
func.func @do_continuation_with_foreign_terminator(%input: !monad.maybe<>) {
  // expected-error @below {{expects every block terminator to belong to the monad dialect}}
  %result = monad.do : !monad.maybe<> {
    monad.bind %input, ^next : !monad.maybe<>
  ^next:
    dep.yield
  }
  return
}

// -----

// Reject a block reached by two different terminators, even when one of them
// reaches it through several edges.
monad.exception.declare @a
monad.exception.declare @b
func.func @catch_and_bind_to_one_block(%input: !monad.value_or_exception<>) {
  // expected-error @below {{expects every block except the first to have a unique predecessor}}
  %result = monad.do : !monad.value_or_exception<> {
    monad.catch %input, ^next [@a -> ^handler, @b -> ^handler] : !monad.value_or_exception<>
  ^next:
    monad.bind %input, ^handler : !monad.value_or_exception<>
  ^handler:
    monad.yield %input : !monad.value_or_exception<>
  }
  return
}

// -----

func.func @declare_outside_module() {
  // expected-error @below {{expects parent op 'builtin.module'}}
  "monad.exception.declare"() {sym_name = "a", payloadTypes = []} : () -> ()
  return
}

// -----

func.func @make_undeclared() {
  // expected-error @below {{expects @a to reference a declared exception}}
  %e = monad.exception.make @a
  return
}

// -----

monad.exception.declare @io(i32)
func.func @make_wrong_payload(%code: i64) {
  // expected-error @below {{expects payload types ('i32') declared by @io, got ('i64')}}
  %e = monad.exception.make @io(%code) : (i64)
  return
}

// -----

monad.exception.declare @io(i32)
func.func @make_missing_payload() {
  // expected-error @below {{expects payload types ('i32') declared by @io, got ()}}
  %e = monad.exception.make @io
  return
}

// -----

// expected-error @below {{@b does not reference a declared exception}}
func.func private @may_throw_undeclared() attributes {monad.may_throw = [@b]}

// -----

// expected-error @below {{expects monad.may_throw to be an array of exception kinds}}
func.func private @may_throw_not_array() attributes {monad.may_throw = @b}

// -----

func.func @catch_undeclared(%input: !monad.value_or_exception<>) {
  %result = monad.do : !monad.value_or_exception<> {
    // expected-error @below {{expects @a to reference a declared exception}}
    monad.catch %input [@a -> ^handler] : !monad.value_or_exception<>
  ^handler:
    monad.yield %input : !monad.value_or_exception<>
  }
  return
}

// -----

monad.exception.declare @a
func.func @catch_kind_twice(%input: !monad.value_or_exception<>) {
  %result = monad.do : !monad.value_or_exception<> {
    // expected-error @below {{expects every exception kind to be listed once, got @a twice}}
    monad.catch %input [@a -> ^first, @a -> ^second] : !monad.value_or_exception<>
  ^first:
    monad.yield %input : !monad.value_or_exception<>
  ^second:
    monad.yield %input : !monad.value_or_exception<>
  }
  return
}

// -----

// The kinds of a case must share their payload types.
monad.exception.declare @io(i32)
monad.exception.declare @eof
func.func @catch_group_payload_mismatch(%input: !monad.value_or_exception<>) {
  %result = monad.do : !monad.value_or_exception<> {
    // expected-error @below {{expects the successor of @eof to take its payload types ()}}
    monad.catch %input [@io, @eof -> ^handler] : !monad.value_or_exception<>
  ^handler(%code: i32):
    monad.yield %input : !monad.value_or_exception<>
  }
  return
}

// -----

func.func @catch_ok_arguments(%input: !monad.value_or_exception<i32>) {
  %result = monad.do : !monad.value_or_exception<i32> {
    // expected-error @below {{expects the ^ok successor to take arguments of types ('i32')}}
    monad.catch %input, ^ok [] : !monad.value_or_exception<i32>
  ^ok:
    monad.yield %input : !monad.value_or_exception<i32>
  }
  return
}

// -----

func.func @catch_default_arguments(%input: !monad.value_or_exception<>) {
  %result = monad.do : !monad.value_or_exception<> {
    // expected-error @below {{expects the default successor to take one argument of type !monad.exception}}
    monad.catch %input [default -> ^other] : !monad.value_or_exception<>
  ^other:
    monad.yield %input : !monad.value_or_exception<>
  }
  return
}

// -----

// Without ^ok, a success ends the do with the input, so the types must match.
monad.exception.declare @a
func.func @catch_without_ok_type_mismatch(%input: !monad.value_or_exception<>) {
  %result = monad.do : !monad.value_or_exception<i32> {
    // expected-error @below {{expects the input to be of the result type of the enclosing monad.do without ^ok}}
    monad.catch %input [@a -> ^recover] : !monad.value_or_exception<>
  ^recover:
    %c0 = arith.constant 0 : i32
    %zero = monad.return %c0 : !monad.value_or_exception<i32>
    monad.yield %zero : !monad.value_or_exception<i32>
  }
  return
}

// -----

// Without default, an unmatched failure ends the do, which therefore produces
// a value-or-exception.
func.func @catch_without_default_in_maybe(%input: !monad.value_or_exception<i32>) {
  %result = monad.do : !monad.maybe<i32> {
    // expected-error @below {{expects the enclosing monad.do to produce a !monad.value_or_exception without default}}
    monad.catch %input, ^ok [] : !monad.value_or_exception<i32>
  ^ok(%value: i32):
    %wrapped = monad.return %value : !monad.maybe<i32>
    monad.yield %wrapped : !monad.maybe<i32>
  }
  return
}

// -----

func.func @catch_default_not_last(%input: !monad.value_or_exception<>) {
  %result = monad.do : !monad.value_or_exception<> {
    // expected-error @below {{expected ']'}}
    monad.catch %input [default -> ^other, @a -> ^other] : !monad.value_or_exception<>
  ^other(%e: !monad.exception):
    monad.yield %input : !monad.value_or_exception<>
  }
  return
}

// -----

func.func @bind_maybe_in_value_or_exception(%input: !monad.maybe<i32>) {
  %result = monad.do : !monad.value_or_exception<i32> {
    // expected-error @below {{expects the input to be of the monad of the enclosing monad.do}}
    monad.bind %input, ^next : !monad.maybe<i32>
  ^next(%value: i32):
    %wrapped = monad.return %value : !monad.value_or_exception<i32>
    monad.yield %wrapped : !monad.value_or_exception<i32>
  }
  return
}
