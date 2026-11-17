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
func.func private @union_with_duplicate_name(!monad.error_union<{!monad.error<"a">, !monad.error<"a", i32>}>)

// -----

// expected-error @below {{expected an error type, got 'i32'}}
func.func private @union_with_non_error(!monad.error_union<{i32}>)

// -----

// expected-error @below {{expects at least one error}}
func.func private @empty_union(!monad.error_union<{}>)

// -----

// expected-error @below {{expected non-function type}}
// expected-error @below {{failed to parse MonadEitherType parameter 'leftType'}}
func.func private @either_without_left(!monad.either<>)

// -----

// expected-error @below {{expected ','}}
func.func private @either_without_right(!monad.either<i32>)

// -----

// expected-error @below {{expected '(' in the right side of an either type}}
func.func private @either_right_without_parentheses(!monad.either<i32, f32>)

// -----

func.func @error_make_wrong_payload(%value: i64) {
  // expected-error @below {{failed to verify that payload types match the payload types of the result}}
  %error = "monad.error.make"(%value) : (i64) -> !monad.error<"a", i32>
  return
}

// -----

func.func @either_left_wrong_type(%value: i64) {
  // expected-error @below {{failed to verify that value type matches the left type of the result}}
  %left = "monad.either.left"(%value) : (i64) -> !monad.either<i32, ()>
  return
}

// -----

func.func @either_branch_wrong_left(%input: !monad.either<i32, (f32)>) {
  // expected-error @below {{expects the left successor to take one argument of type 'i32'}}
  monad.either.branch %input, left ^left, right ^right : !monad.either<i32, (f32)>
^left(%l: f32):
  return
^right(%r: f32):
  return
}

// -----

func.func @throw_non_member() {
  %error = monad.error.make : !monad.error<"c">
  // expected-error @below {{expects '!monad.error<"c">' to be a member of '!monad.error_union<{!monad.error<"a">}>'}}
  %thrown = monad.either.throw %error : !monad.error<"c"> -> !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  return
}

// -----

func.func @throw_into_general_either() {
  %error = monad.error.make : !monad.error<"a">
  // expected-error @below {{expects the left type of the result to be an error union}}
  %thrown = monad.either.throw %error : !monad.error<"a"> -> !monad.either<i32, ()>
  return
}

// -----

func.func @throw_other_payload(%value: i32) {
  %error = monad.error.make %value : !monad.error<"a", i32>
  // expected-error @below {{to be a member of}}
  %thrown = monad.either.throw %error : !monad.error<"a", i32> -> !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  return
}

// -----

func.func @widen_to_smaller(%input: !monad.either<!monad.error_union<{!monad.error<"a">, !monad.error<"b">}>, (i32)>) {
  // expected-error @below {{operand type}}
  %widened = monad.either.widen %input : !monad.either<!monad.error_union<{!monad.error<"a">, !monad.error<"b">}>, (i32)> to !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  return
}

// -----

func.func @widen_other_values(%input: !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>) {
  // expected-error @below {{operand type}}
  %widened = monad.either.widen %input : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)> to !monad.either<!monad.error_union<{!monad.error<"a">}>, (i64)>
  return
}

// -----

func.func @catch_outside_do(%input: !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>) {
  // expected-error @below {{expects parent op 'monad.do'}}
  monad.either.catch %input [!monad.error<"a"> -> ^handler] : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
^handler(%error: !monad.error<"a">):
  return
}

// -----

func.func @catch_general_either(%input: !monad.either<i32, (i32)>) {
  %result = monad.do : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)> {
    // expected-error @below {{expects the left type of the input to be an error union}}
    monad.either.catch %input, ^ok [] : !monad.either<i32, (i32)>
  ^ok(%value: i32):
    %wrapped = monad.return %value : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
    monad.yield %wrapped : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  }
  return
}

// -----

func.func @catch_in_maybe_do(%input: !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>) {
  %result = monad.do : !monad.maybe<i32> {
    // expected-error @below {{expects the enclosing monad.do to produce an either value whose left type is an error union}}
    monad.either.catch %input, ^ok [!monad.error<"a"> -> ^handler] : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  ^ok(%value: i32):
    %wrapped = monad.return %value : !monad.maybe<i32>
    monad.yield %wrapped : !monad.maybe<i32>
  ^handler(%error: !monad.error<"a">):
    %none = monad.maybe.none : !monad.maybe<i32>
    monad.yield %none : !monad.maybe<i32>
  }
  return
}

// -----

func.func @catch_ok_wrong_arguments(%input: !monad.either<!monad.error_union<{!monad.error<"a">, !monad.error<"b">}>, (i32)>) {
  %result = monad.do : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)> {
    // expected-error @below {{expects the ok successor to take arguments of types ('i32')}}
    monad.either.catch %input, ^ok [!monad.error<"b"> -> ^handler] : !monad.either<!monad.error_union<{!monad.error<"a">, !monad.error<"b">}>, (i32)>
  ^ok(%value: i64):
    %error = monad.error.make : !monad.error<"a">
    %thrown = monad.either.throw %error : !monad.error<"a"> -> !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
    monad.yield %thrown : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  ^handler(%caught: !monad.error<"b">):
    %error2 = monad.error.make : !monad.error<"a">
    %thrown2 = monad.either.throw %error2 : !monad.error<"a"> -> !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
    monad.yield %thrown2 : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  }
  return
}

// -----

// Without ^ok, the input must be of the result type of the do.
func.func @catch_without_ok_other_type(%input: !monad.either<!monad.error_union<{!monad.error<"a">, !monad.error<"b">}>, (i32)>) {
  %result = monad.do : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)> {
    // expected-error @below {{expects the input to be of the result type of the enclosing monad.do without an ok successor}}
    monad.either.catch %input [!monad.error<"b"> -> ^handler] : !monad.either<!monad.error_union<{!monad.error<"a">, !monad.error<"b">}>, (i32)>
  ^handler(%error: !monad.error<"b">):
    %zero = arith.constant 0 : i32
    %wrapped = monad.return %zero : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
    monad.yield %wrapped : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  }
  return
}

// -----

func.func @catch_non_member(%input: !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>) {
  %result = monad.do : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)> {
    // expected-error @below {{expects the listed error '!monad.error<"b">' to be a member of '!monad.error_union<{!monad.error<"a">}>'}}
    monad.either.catch %input [!monad.error<"b"> -> ^handler] : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  ^handler(%error: !monad.error<"b">):
    %zero = arith.constant 0 : i32
    %wrapped = monad.return %zero : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
    monad.yield %wrapped : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  }
  return
}

// -----

func.func @catch_successor_count(%input: !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>) {
  %result = monad.do : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)> {
    // expected-error @below {{expects one successor per case, and optionally an ok successor before them, got 3 successors for 1 cases}}
    "monad.either.catch"(%input)[^next, ^next, ^next] {caseTypes = [!monad.error<"a">]} : (!monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>) -> ()
  ^next(%value: i32):
    %wrapped = monad.return %value : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
    monad.yield %wrapped : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  }
  return
}

// -----

func.func @catch_overlapping_cases(%input: !monad.either<!monad.error_union<{!monad.error<"a">, !monad.error<"b">}>, (i32)>) {
  %result = monad.do : !monad.either<!monad.error_union<{!monad.error<"a">, !monad.error<"b">}>, (i32)> {
    // expected-error @below {{expects disjoint cases, got '!monad.error<"a">' twice}}
    monad.either.catch %input [!monad.error<"a"> -> ^first, !monad.error_union<{!monad.error<"a">, !monad.error<"b">}> -> ^second] : !monad.either<!monad.error_union<{!monad.error<"a">, !monad.error<"b">}>, (i32)>
  ^first(%error: !monad.error<"a">):
    %zero = arith.constant 0 : i32
    %wrapped = monad.return %zero : !monad.either<!monad.error_union<{!monad.error<"a">, !monad.error<"b">}>, (i32)>
    monad.yield %wrapped : !monad.either<!monad.error_union<{!monad.error<"a">, !monad.error<"b">}>, (i32)>
  ^second(%errors: !monad.error_union<{!monad.error<"a">, !monad.error<"b">}>):
    %one = arith.constant 1 : i32
    %wrapped1 = monad.return %one : !monad.either<!monad.error_union<{!monad.error<"a">, !monad.error<"b">}>, (i32)>
    monad.yield %wrapped1 : !monad.either<!monad.error_union<{!monad.error<"a">, !monad.error<"b">}>, (i32)>
  }
  return
}

// -----

func.func @catch_case_not_error(%input: !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>) {
  %result = monad.do : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)> {
    // expected-error @below {{expects every case to be an error or an error union, got 'i32'}}
    monad.either.catch %input [i32 -> ^handler] : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  ^handler(%error: i32):
    %wrapped = monad.return %error : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
    monad.yield %wrapped : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  }
  return
}

// -----

func.func @catch_handler_wrong_argument(%input: !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>) {
  %result = monad.do : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)> {
    // expected-error @below {{expects the handler of '!monad.error<"a">' to take one argument of that type}}
    monad.either.catch %input [!monad.error<"a"> -> ^handler] : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  ^handler(%error: !monad.error<"b">):
    %zero = arith.constant 0 : i32
    %wrapped = monad.return %zero : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
    monad.yield %wrapped : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  }
  return
}

// -----

// The do admits only "a", but "b" is not caught.
func.func @catch_uncaught_not_in_do(%input: !monad.either<!monad.error_union<{!monad.error<"a">, !monad.error<"b">}>, (i32)>) {
  %result = monad.do : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)> {
    // expected-error @below {{expects the uncaught error '!monad.error<"b">' to be a member of '!monad.error_union<{!monad.error<"a">}>' of the enclosing monad.do}}
    monad.either.catch %input, ^ok [!monad.error<"a"> -> ^handler] : !monad.either<!monad.error_union<{!monad.error<"a">, !monad.error<"b">}>, (i32)>
  ^ok(%value: i32):
    %wrapped = monad.return %value : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
    monad.yield %wrapped : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  ^handler(%error: !monad.error<"a">):
    %zero = arith.constant 0 : i32
    %recovered = monad.return %zero : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
    monad.yield %recovered : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  }
  return
}

// -----

func.func @bind_other_left(%input: !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>) {
  %result = monad.do : !monad.either<!monad.error_union<{!monad.error<"b">}>, (i32)> {
    // expected-error @below {{expects the input to be of the monad of the enclosing monad.do}}
    monad.bind %input, ^next : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  ^next(%value: i32):
    %wrapped = monad.return %value : !monad.either<!monad.error_union<{!monad.error<"b">}>, (i32)>
    monad.yield %wrapped : !monad.either<!monad.error_union<{!monad.error<"b">}>, (i32)>
  }
  return
}

// -----

func.func @bind_maybe_in_either(%input: !monad.maybe<i32>) {
  %result = monad.do : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)> {
    // expected-error @below {{expects the input to be of the monad of the enclosing monad.do}}
    monad.bind %input, ^next : !monad.maybe<i32>
  ^next(%value: i32):
    %wrapped = monad.return %value : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
    monad.yield %wrapped : !monad.either<!monad.error_union<{!monad.error<"a">}>, (i32)>
  }
  return
}

// -----

func.func @switch_missing_member(%error: !monad.error_union<{!monad.error<"a">, !monad.error<"b">}>) {
  // expected-error @below {{expects a case for every member of '!monad.error_union<{!monad.error<"a">, !monad.error<"b">}>', got none for '!monad.error<"b">'}}
  monad.error_union.switch %error [!monad.error<"a"> -> ^a] : !monad.error_union<{!monad.error<"a">, !monad.error<"b">}>
^a(%a: !monad.error<"a">):
  return
}

// -----

func.func @switch_handler_count(%error: !monad.error_union<{!monad.error<"a">}>) {
  // expected-error @below {{expects one handler per case, got 2 handlers for 1 cases}}
  "monad.error_union.switch"(%error)[^a, ^a] {caseTypes = [!monad.error<"a">]} : (!monad.error_union<{!monad.error<"a">}>) -> ()
^a(%a: !monad.error<"a">):
  return
}

// -----

func.func @switch_non_member(%error: !monad.error_union<{!monad.error<"a">}>) {
  // expected-error @below {{expects the listed error '!monad.error<"b">' to be a member of '!monad.error_union<{!monad.error<"a">}>'}}
  monad.error_union.switch %error [!monad.error<"a"> -> ^a, !monad.error<"b"> -> ^b] : !monad.error_union<{!monad.error<"a">}>
^a(%a: !monad.error<"a">):
  return
^b(%b: !monad.error<"b">):
  return
}
