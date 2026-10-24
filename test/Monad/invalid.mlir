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
  // expected-error @below {{result #0 must be Maybe monad type, but got 'i32'}}
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

func.func @fail_not_monadic() {
  // expected-error @below {{result #0 must be Maybe monad type, but got 'i32'}}
  %result = "monad.fail"() : () -> i32
  return
}

// -----

func.func @fail_with_operand(%value: !monad.maybe<i32>) {
  // expected-error @below {{requires zero operands}}
  %result = "monad.fail"(%value) : (!monad.maybe<i32>) -> !monad.maybe<i32>
  return
}

// -----

// expected-error @below {{expected '<'}}
func.func private @maybe_without_parameter(!monad.maybe)

// -----

// expected-error @below {{expected '>'}}
func.func private @maybe_with_two_parameters(!monad.maybe<i32, i32>)
