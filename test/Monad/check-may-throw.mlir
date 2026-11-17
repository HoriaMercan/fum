// RUN: fum-opt %s --monad-check-may-throw --split-input-file --verify-diagnostics

// Accepted: a catch removes div_by_zero, the default case receives overflow
// and timeout and throws them again, and functions without monad.may_throw
// contribute the kinds of their bodies, also through recursion.

monad.exception.declare @div_by_zero
monad.exception.declare @overflow
monad.exception.declare @timeout

func.func private @safe_div(i32, i32) -> !monad.value_or_exception<i32>
    attributes {monad.may_throw = [@div_by_zero, @overflow]}

func.func @half_ratio(%a: i32, %b: i32) -> !monad.value_or_exception<i32>
    attributes {monad.may_throw = [@overflow]} {
  %result = monad.do : !monad.value_or_exception<i32> {
    %ratio = func.call @safe_div(%a, %b) : (i32, i32) -> !monad.value_or_exception<i32>
    monad.catch %ratio [@div_by_zero -> ^recover] : !monad.value_or_exception<i32>
  ^recover:
    %zero = arith.constant 0 : i32
    %recovered = monad.return %zero : !monad.value_or_exception<i32>
    monad.yield %recovered : !monad.value_or_exception<i32>
  }
  return %result : !monad.value_or_exception<i32>
}

func.func private @wait(%ticks: i32) -> !monad.value_or_exception<i32> {
  %zero = arith.constant 0 : i32
  %done = arith.cmpi eq, %ticks, %zero : i32
  %timeout = monad.exception.make @timeout
  %failure = monad.throw %timeout : !monad.value_or_exception<i32>
  %one = arith.constant 1 : i32
  %fewer = arith.subi %ticks, %one : i32
  %again = func.call @wait(%fewer) : (i32) -> !monad.value_or_exception<i32>
  %result = arith.select %done, %failure, %again : !monad.value_or_exception<i32>
  return %result : !monad.value_or_exception<i32>
}

func.func @rethrow_others(%a: i32, %b: i32) -> !monad.value_or_exception<i32>
    attributes {monad.may_throw = [@overflow, @timeout]} {
  %result = monad.do : !monad.value_or_exception<i32> {
    %ratio = func.call @safe_div(%a, %b) : (i32, i32) -> !monad.value_or_exception<i32>
    monad.bind %ratio, ^divided : !monad.value_or_exception<i32>
  ^divided(%quotient: i32):
    %waited = func.call @wait(%quotient) : (i32) -> !monad.value_or_exception<i32>
    monad.catch %waited, ^ok [default -> ^other] : !monad.value_or_exception<i32>
  ^ok(%value: i32):
    %success = monad.return %value : !monad.value_or_exception<i32>
    monad.yield %success : !monad.value_or_exception<i32>
  ^other(%exception: !monad.exception):
    %failure = monad.throw %exception : !monad.value_or_exception<i32>
    monad.yield %failure : !monad.value_or_exception<i32>
  }
  %checked = monad.do : !monad.value_or_exception<i32> {
    monad.catch %result [@div_by_zero -> ^recover] : !monad.value_or_exception<i32>
  ^recover:
    %zero = arith.constant 0 : i32
    %recovered = monad.return %zero : !monad.value_or_exception<i32>
    monad.yield %recovered : !monad.value_or_exception<i32>
  }
  return %checked : !monad.value_or_exception<i32>
}

// -----

monad.exception.declare @div_by_zero
monad.exception.declare @overflow

// expected-error @below {{expects monad.may_throw to list @overflow, which the function may throw}}
func.func @made_and_thrown(%flag: i1) -> !monad.value_or_exception<i32>
    attributes {monad.may_throw = [@div_by_zero]} {
  %division = monad.exception.make @div_by_zero
  // expected-note @below {{@overflow may be thrown here}}
  %overflow = monad.exception.make @overflow
  %exception = arith.select %flag, %division, %overflow : !monad.exception
  %failure = monad.throw %exception : !monad.value_or_exception<i32>
  return %failure : !monad.value_or_exception<i32>
}

// -----

monad.exception.declare @a
monad.exception.declare @b

func.func private @throws_a_and_b() -> !monad.value_or_exception<i32>
    attributes {monad.may_throw = [@a, @b]}

// The default case receives the kinds that no case lists, here b.
// expected-error @below {{expects monad.may_throw to list @b, which the function may throw}}
func.func @default_rethrows() -> !monad.value_or_exception<i32>
    attributes {monad.may_throw = []} {
  %result = monad.do : !monad.value_or_exception<i32> {
    // expected-note @below {{@b may be thrown here}}
    %m = func.call @throws_a_and_b() : () -> !monad.value_or_exception<i32>
    monad.catch %m [@a -> ^a, default -> ^other] : !monad.value_or_exception<i32>
  ^a:
    %zero = arith.constant 0 : i32
    %recovered = monad.return %zero : !monad.value_or_exception<i32>
    monad.yield %recovered : !monad.value_or_exception<i32>
  ^other(%exception: !monad.exception):
    %failure = monad.throw %exception : !monad.value_or_exception<i32>
    monad.yield %failure : !monad.value_or_exception<i32>
  }
  return %result : !monad.value_or_exception<i32>
}

// -----

monad.exception.declare @a
monad.exception.declare @b

// The summary of a callee without monad.may_throw points into its body.
func.func private @helper() -> !monad.value_or_exception<i32> {
  // expected-note @below {{@b may be thrown here}}
  %b = monad.exception.make @b
  %failure = monad.throw %b : !monad.value_or_exception<i32>
  return %failure : !monad.value_or_exception<i32>
}

// A failure that a bind lets out of the do leaves the function.
// expected-error @below {{expects monad.may_throw to list @b, which the function may throw}}
func.func @bind_lets_out() -> !monad.value_or_exception<i32>
    attributes {monad.may_throw = [@a]} {
  %result = monad.do : !monad.value_or_exception<i32> {
    %m = func.call @helper() : () -> !monad.value_or_exception<i32>
    monad.bind %m, ^next : !monad.value_or_exception<i32>
  ^next(%value: i32):
    %success = monad.return %value : !monad.value_or_exception<i32>
    monad.yield %success : !monad.value_or_exception<i32>
  }
  return %result : !monad.value_or_exception<i32>
}

// -----

monad.exception.declare @a

// expected-error @below {{expects the exception kinds that the function may throw to be known, to check monad.may_throw}}
func.func @argument(
    // expected-note @below {{the exception kinds of this function argument are unknown}}
    %m: !monad.value_or_exception<i32>) -> !monad.value_or_exception<i32>
    attributes {monad.may_throw = [@a]} {
  return %m : !monad.value_or_exception<i32>
}

// -----

monad.exception.declare @a

func.func private @unannotated() -> !monad.value_or_exception<i32>

// expected-error @below {{expects the exception kinds that the function may throw to be known, to check monad.may_throw}}
func.func @external_call() -> !monad.value_or_exception<i32>
    attributes {monad.may_throw = [@a]} {
  // expected-note @below {{the exception kinds of this call to an external function without monad.may_throw are unknown}}
  %m = func.call @unannotated() : () -> !monad.value_or_exception<i32>
  return %m : !monad.value_or_exception<i32>
}
