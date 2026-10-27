// RUN: fum-opt %s --split-input-file --verify-diagnostics

func.func @return_value_type_mismatch(%value: i64) {
  // expected-error @below {{failed to verify that value type matches the value type of the result}}
  %result = "monad.return"(%value) : (i64) -> !monad.maybe<i32>
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
  // expected-error @below {{result #0 must be monadic type, but got 'i32'}}
  %result = "monad.return"(%value) : (i32) -> i32
  return
}

// -----

func.func @return_not_monadic_custom_syntax(%value: i32) {
  // expected-error @below {{'result' must be monadic type, but got 'i32'}}
  %result = monad.return %value : i32
  return
}

// -----

func.func @return_unqualified_type(%value: i32) {
  // expected-error @below {{expected non-function type}}
  %result = monad.return %value : <i32>
  return
}

// -----

func.func @maybe_fail_not_maybe() {
  // expected-error @below {{result #0 must be Maybe monad type, but got 'i32'}}
  %result = "monad.maybe.fail"() : () -> i32
  return
}

// -----

func.func @maybe_fail_not_maybe_custom_syntax() {
  // expected-error @below {{result #0 must be Maybe monad type, but got 'i32'}}
  %result = monad.maybe.fail : i32
  return
}

// -----

func.func @maybe_fail_with_operand(%error: i8) {
  // expected-error @below {{requires zero operands}}
  %result = "monad.maybe.fail"(%error) : (i8) -> !monad.maybe<i32>
  return
}

// -----

// expected-error @below {{expected '<'}}
func.func private @maybe_without_parameter(!monad.maybe)

// -----

// expected-error @below {{expected '>'}}
func.func private @maybe_with_two_parameters(!monad.maybe<i32, i32>)

// -----

func.func @bind_input_not_maybe(%input: i32) {
  // expected-error @below {{operand #0 must be Maybe monad type, but got 'i32'}}
  %result = "monad.maybe.bind"(%input) ({
  ^bb0(%value: i32):
    %failure = monad.maybe.fail : !monad.maybe<f32>
    monad.yield %failure : !monad.maybe<f32>
  }) : (i32) -> !monad.maybe<f32>
  return
}

// -----

func.func @bind_argument_type_mismatch(%input: !monad.maybe<i32>) {
  // expected-error @below {{expects the body to take a single argument of type 'i32'}}
  %result = monad.maybe.bind %input : !monad.maybe<i32> -> !monad.maybe<f32> {
  ^bb0(%value: f32):
    %failure = monad.maybe.fail : !monad.maybe<f32>
    monad.yield %failure : !monad.maybe<f32>
  }
  return
}

// -----

func.func @bind_without_argument(%input: !monad.maybe<i32>) {
  // expected-error @below {{expects the body to take a single argument of type 'i32'}}
  %result = monad.maybe.bind %input : !monad.maybe<i32> -> !monad.maybe<f32> {
    %failure = monad.maybe.fail : !monad.maybe<f32>
    monad.yield %failure : !monad.maybe<f32>
  }
  return
}

// -----

func.func @bind_yield_type_mismatch(%input: !monad.maybe<i32>) {
  // expected-error @below {{expects the body to yield '!monad.maybe<f32>', got '!monad.maybe<i32>'}}
  %result = monad.maybe.bind %input : !monad.maybe<i32> -> !monad.maybe<f32> {
  ^bb0(%value: i32):
    %failure = monad.maybe.fail : !monad.maybe<i32>
    monad.yield %failure : !monad.maybe<i32>
  }
  return
}

// -----

func.func @bind_other_terminator(%input: !monad.maybe<i32>) {
  // expected-error @below {{expects the body to be terminated by monad.yield}}
  %result = monad.maybe.bind %input : !monad.maybe<i32> -> !monad.maybe<f32> {
  ^bb0(%value: i32):
    %failure = monad.maybe.fail : !monad.maybe<f32>
    dep.yield %failure : !monad.maybe<f32>
  }
  return
}

// -----

func.func @bind_two_blocks(%input: !monad.maybe<i32>) {
  // expected-error @below {{expects region #0 to have 0 or 1 blocks}}
  %result = monad.maybe.bind %input : !monad.maybe<i32> -> !monad.maybe<f32> {
  ^bb0(%value: i32):
    %failure = monad.maybe.fail : !monad.maybe<f32>
    monad.yield %failure : !monad.maybe<f32>
  ^bb1:
    %other = monad.maybe.fail : !monad.maybe<f32>
    monad.yield %other : !monad.maybe<f32>
  }
  return
}

// -----

func.func @bind_without_body(%input: !monad.maybe<i32>) {
  // expected-error @below {{expected '{' to begin a region}}
  %result = monad.maybe.bind %input : !monad.maybe<i32> -> !monad.maybe<f32>
  return
}

// -----

func.func @yield_outside_bind(%input: !monad.maybe<i32>) -> !monad.maybe<i32> {
  // expected-error @below {{expects parent op 'monad.maybe.bind'}}
  monad.yield %input : !monad.maybe<i32>
}
