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

// expected-error @below {{expects a non-empty error name}}
func.func private @error_with_empty_name(!monad.error<"">)

// -----

// expected-error @below {{expected distinct error names, got "a" twice}}
func.func private @value_or_error_with_duplicate_error(!monad.value_or_error<[i32] throws {!monad.error<"a">, !monad.error<"a", i32>}>)

// -----

// expected-error @below {{expected an error type, got 'i32'}}
func.func private @value_or_error_with_non_error(!monad.value_or_error<[i32] throws {i32}>)

// -----

// expected-error @below {{expected 'throws'}}
func.func private @value_or_error_without_errors(!monad.value_or_error<[i32]>)

// -----

// expected-error @below {{expects at least one error}}
func.func private @empty_error_union(!monad.error_union<{}>)

// -----

func.func @error_make_payload_mismatch(%payload: i64) {
  // expected-error @below {{payload types match the payload types of the error}}
  %error = "monad.error.make"(%payload) : (i64) -> !monad.error<"a", i32>
  return
}

// -----

func.func @throw_other_error(%error: !monad.error<"a">) {
  // expected-error @below {{expects every error of the input to be an error of the result, got '!monad.error<"a">'}}
  %failure = monad.throw %error : !monad.error<"a"> -> !monad.value_or_error<[] throws {!monad.error<"b">}>
  return
}

// -----

func.func @throw_error_with_other_payload(%error: !monad.error<"a", i32>) {
  // expected-error @below {{expects every error of the input to be an error of the result}}
  %failure = monad.throw %error : !monad.error<"a", i32> -> !monad.value_or_error<[] throws {!monad.error<"a">}>
  return
}

// -----

func.func @widen_to_fewer_errors(%input: !monad.value_or_error<[i32] throws {!monad.error<"a">}>) {
  // expected-error @below {{operand type '!monad.value_or_error<[i32] throws {!monad.error<"a">}>' and result type '!monad.value_or_error<[i32] throws {}>' are cast incompatible}}
  %widened = monad.widen %input : !monad.value_or_error<[i32] throws {!monad.error<"a">}> to !monad.value_or_error<[i32] throws {}>
  return
}

// -----

func.func @bind_other_errors(%input: !monad.value_or_error<[i32] throws {!monad.error<"a">}>) {
  %result = monad.do : !monad.value_or_error<[i32] throws {!monad.error<"b">}> {
    // expected-error @below {{expects the input to be of the monad of the enclosing monad.do}}
    monad.bind %input, ^next : !monad.value_or_error<[i32] throws {!monad.error<"a">}>
  ^next(%value: i32):
    %wrapped = monad.return %value : !monad.value_or_error<[i32] throws {!monad.error<"b">}>
    monad.yield %wrapped : !monad.value_or_error<[i32] throws {!monad.error<"b">}>
  }
  return
}

// -----

func.func @bind_maybe_in_value_or_error(%input: !monad.maybe<i32>) {
  %result = monad.do : !monad.value_or_error<[i32] throws {!monad.error<"a">}> {
    // expected-error @below {{expects the input to be of the monad of the enclosing monad.do}}
    monad.bind %input, ^next : !monad.maybe<i32>
  ^next(%value: i32):
    %wrapped = monad.return %value : !monad.value_or_error<[i32] throws {!monad.error<"a">}>
    monad.yield %wrapped : !monad.value_or_error<[i32] throws {!monad.error<"a">}>
  }
  return
}

// -----

func.func @catch_in_maybe_do(%input: !monad.value_or_error<[] throws {}>) {
  %result = monad.do : !monad.maybe<> {
    // expected-error @below {{expects the enclosing monad.do to produce a value-or-error type, got '!monad.maybe<>'}}
    monad.catch %input, ^ok [] : !monad.value_or_error<[] throws {}>
  ^ok:
    %none = monad.maybe.none : !monad.maybe<>
    monad.yield %none : !monad.maybe<>
  }
  return
}

// -----

func.func @catch_ok_type_mismatch(%input: !monad.value_or_error<[i32] throws {}>) {
  %result = monad.do : !monad.value_or_error<[] throws {}> {
    // expected-error @below {{expects ^ok to take arguments of types ('i32')}}
    monad.catch %input, ^ok [] : !monad.value_or_error<[i32] throws {}>
  ^ok(%value: f32):
    %done = monad.return : !monad.value_or_error<[] throws {}>
    monad.yield %done : !monad.value_or_error<[] throws {}>
  }
  return
}

// -----

func.func @catch_without_ok_other_type(%input: !monad.value_or_error<[i32] throws {!monad.error<"a">}>) {
  %result = monad.do : !monad.value_or_error<[i64] throws {}> {
    // expected-error @below {{expects the input to be of the result type of the enclosing monad.do without ^ok}}
    monad.catch %input [!monad.error<"a"> -> ^recover] : !monad.value_or_error<[i32] throws {!monad.error<"a">}>
  ^recover(%error: !monad.error<"a">):
    %zero = arith.constant 0 : i64
    %recovered = monad.return %zero : !monad.value_or_error<[i64] throws {}>
    monad.yield %recovered : !monad.value_or_error<[i64] throws {}>
  }
  return
}

// -----

func.func @catch_case_not_an_error(%input: !monad.value_or_error<[] throws {!monad.error<"a">}>) {
  %result = monad.do : !monad.value_or_error<[] throws {}> {
    // expected-error @below {{expects every case to be an error or error union type, got 'i32'}}
    monad.catch %input, ^ok [i32 -> ^recover] : !monad.value_or_error<[] throws {!monad.error<"a">}>
  ^ok:
    %done = monad.return : !monad.value_or_error<[] throws {}>
    monad.yield %done : !monad.value_or_error<[] throws {}>
  ^recover(%error: i32):
    %recovered = monad.return : !monad.value_or_error<[] throws {}>
    monad.yield %recovered : !monad.value_or_error<[] throws {}>
  }
  return
}

// -----

func.func @catch_error_not_thrown(%input: !monad.value_or_error<[] throws {!monad.error<"a">}>) {
  %result = monad.do : !monad.value_or_error<[] throws {}> {
    // expected-error @below {{expects every case to name errors of the input, got '!monad.error<"b">'}}
    monad.catch %input, ^ok [!monad.error<"b"> -> ^recover] : !monad.value_or_error<[] throws {!monad.error<"a">}>
  ^ok:
    %done = monad.return : !monad.value_or_error<[] throws {}>
    monad.yield %done : !monad.value_or_error<[] throws {}>
  ^recover(%error: !monad.error<"b">):
    %recovered = monad.return : !monad.value_or_error<[] throws {}>
    monad.yield %recovered : !monad.value_or_error<[] throws {}>
  }
  return
}

// -----

func.func @catch_error_named_twice(%input: !monad.value_or_error<[] throws {!monad.error<"a">, !monad.error<"b">}>) {
  %result = monad.do : !monad.value_or_error<[] throws {}> {
    // expected-error @below {{expects every error to be named by at most one case, got '!monad.error<"a">' twice}}
    monad.catch %input, ^ok [!monad.error<"a"> -> ^recover, !monad.error_union<{!monad.error<"a">, !monad.error<"b">}> -> ^recover_both] : !monad.value_or_error<[] throws {!monad.error<"a">, !monad.error<"b">}>
  ^ok:
    %done = monad.return : !monad.value_or_error<[] throws {}>
    monad.yield %done : !monad.value_or_error<[] throws {}>
  ^recover(%error: !monad.error<"a">):
    %recovered = monad.return : !monad.value_or_error<[] throws {}>
    monad.yield %recovered : !monad.value_or_error<[] throws {}>
  ^recover_both(%errors: !monad.error_union<{!monad.error<"a">, !monad.error<"b">}>):
    %recovered_both = monad.return : !monad.value_or_error<[] throws {}>
    monad.yield %recovered_both : !monad.value_or_error<[] throws {}>
  }
  return
}

// -----

func.func @catch_handler_type_mismatch(%input: !monad.value_or_error<[] throws {!monad.error<"a", i32>}>) {
  %result = monad.do : !monad.value_or_error<[] throws {}> {
    // expected-error @below {{expects the handler of '!monad.error<"a", i32>' to take one argument of that type}}
    monad.catch %input, ^ok [!monad.error<"a", i32> -> ^recover] : !monad.value_or_error<[] throws {!monad.error<"a", i32>}>
  ^ok:
    %done = monad.return : !monad.value_or_error<[] throws {}>
    monad.yield %done : !monad.value_or_error<[] throws {}>
  ^recover(%payload: i32):
    %recovered = monad.return : !monad.value_or_error<[] throws {}>
    monad.yield %recovered : !monad.value_or_error<[] throws {}>
  }
  return
}

// -----

func.func @catch_default_type_mismatch(%input: !monad.value_or_error<[] throws {!monad.error<"a">, !monad.error<"b">}>) {
  %result = monad.do : !monad.value_or_error<[] throws {}> {
    // expected-error @below {{expects the handler of `default` to take one argument of type '!monad.error_union<{!monad.error<"b">}>'}}
    monad.catch %input, ^ok [!monad.error<"a"> -> ^recover, default -> ^rest] : !monad.value_or_error<[] throws {!monad.error<"a">, !monad.error<"b">}>
  ^ok:
    %done = monad.return : !monad.value_or_error<[] throws {}>
    monad.yield %done : !monad.value_or_error<[] throws {}>
  ^recover(%error: !monad.error<"a">):
    %recovered = monad.return : !monad.value_or_error<[] throws {}>
    monad.yield %recovered : !monad.value_or_error<[] throws {}>
  ^rest(%errors: !monad.error_union<{!monad.error<"a">, !monad.error<"b">}>):
    %rest_recovered = monad.return : !monad.value_or_error<[] throws {}>
    monad.yield %rest_recovered : !monad.value_or_error<[] throws {}>
  }
  return
}

// -----

func.func @catch_default_without_errors(%input: !monad.value_or_error<[] throws {!monad.error<"a">}>) {
  %result = monad.do : !monad.value_or_error<[] throws {}> {
    // expected-error @below {{expects `default` to have errors to catch}}
    monad.catch %input, ^ok [!monad.error<"a"> -> ^recover, default -> ^recover] : !monad.value_or_error<[] throws {!monad.error<"a">}>
  ^ok:
    %done = monad.return : !monad.value_or_error<[] throws {}>
    monad.yield %done : !monad.value_or_error<[] throws {}>
  ^recover(%error: !monad.error<"a">):
    %recovered = monad.return : !monad.value_or_error<[] throws {}>
    monad.yield %recovered : !monad.value_or_error<[] throws {}>
  }
  return
}

// -----

func.func @catch_default_not_last(%input: !monad.value_or_error<[] throws {!monad.error<"a">}>) {
  %result = monad.do : !monad.value_or_error<[] throws {}> {
    // expected-error @below {{expected `default` to be the last case}}
    monad.catch %input, ^ok [default -> ^rest, !monad.error<"a"> -> ^rest] : !monad.value_or_error<[] throws {!monad.error<"a">}>
  }
  return
}

// -----

func.func @catch_uncaught_error_not_in_do(%input: !monad.value_or_error<[] throws {!monad.error<"a">, !monad.error<"b">}>) {
  %result = monad.do : !monad.value_or_error<[] throws {!monad.error<"b">}> {
    // expected-error @below {{expects the uncaught error '!monad.error<"a">' to be an error of the result type of the enclosing monad.do}}
    monad.catch %input, ^ok [!monad.error<"b"> -> ^recover] : !monad.value_or_error<[] throws {!monad.error<"a">, !monad.error<"b">}>
  ^ok:
    %done = monad.return : !monad.value_or_error<[] throws {!monad.error<"b">}>
    monad.yield %done : !monad.value_or_error<[] throws {!monad.error<"b">}>
  ^recover(%error: !monad.error<"b">):
    %recovered = monad.return : !monad.value_or_error<[] throws {!monad.error<"b">}>
    monad.yield %recovered : !monad.value_or_error<[] throws {!monad.error<"b">}>
  }
  return
}

// -----

// The unique-predecessor rule still rejects a block reached from two
// different terminators.
func.func @catch_and_bind_to_same_block(%input: !monad.value_or_error<[] throws {!monad.error<"a">}>) {
  // expected-error @below {{expects every block except the first to have a unique predecessor}}
  %result = monad.do : !monad.value_or_error<[] throws {}> {
    monad.catch %input, ^ok [!monad.error<"a"> -> ^recover] : !monad.value_or_error<[] throws {!monad.error<"a">}>
  ^ok:
    %error = monad.error.make : !monad.error<"a">
    %wrapped = monad.return %error : !monad.value_or_error<[!monad.error<"a">] throws {}>
    monad.bind %wrapped, ^recover : !monad.value_or_error<[!monad.error<"a">] throws {}>
  ^recover(%caught: !monad.error<"a">):
    %recovered = monad.return : !monad.value_or_error<[] throws {}>
    monad.yield %recovered : !monad.value_or_error<[] throws {}>
  }
  return
}
