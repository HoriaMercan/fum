// RUN: fum-opt %s --split-input-file --verify-diagnostics

// A sum without cases would have no value.
// expected-error @below {{expects at least one case, since a sum without cases has no value}}
func.func private @empty_sum(!adt.sum<>)

// -----

// Every alternative is a named case: no union of types.
// expected-error @below {{expected a case name: every alternative of a sum is a named case}}
func.func private @unnamed_case(!adt.sum<i32, f32>)

// -----

// expected-error @below {{expects distinct case names, got 'io' twice}}
func.func private @duplicate_case(!adt.sum<io(i32), io(i64)>)

// -----

// A case without fields has one spelling, without parentheses.
// expected-error @below {{expected a field type: a case without fields is written without parentheses}}
func.func private @empty_fields(!adt.sum<eof()>)

// -----

func.func @make_unknown_case() {
  // expected-error @below {{expects 'eof' to be a case of '!adt.sum<io(i32)>'}}
  %error = adt.make eof : !adt.sum<io(i32)>
  return
}

// -----

func.func @make_missing_field() {
  // expected-error @below {{expects 1 fields for case 'io', got 0}}
  %error = adt.make io : !adt.sum<io(i32)>
  return
}

// -----

func.func @make_field_type(%code: i64) {
  // expected-error @below {{expects the fields of case 'io' to have types (i32)}}
  %error = "adt.make"(%code) <{case_name = "io"}> : (i64) -> !adt.sum<io(i32)>
  return
}

// -----

func.func @match_not_exhaustive(%error: !adt.sum<a, b, c>) {
  // expected-error @below {{expects every case to be handled, or a default case; not handled: 'b' 'c'}}
  adt.match %error : !adt.sum<a, b, c>
  case a {
    adt.yield
  }
  return
}

// -----

func.func @match_unknown_case(%error: !adt.sum<b, a>) {
  // expected-error @below {{expects 'c' to be a case of '!adt.sum<a, b>'}}
  adt.match %error : !adt.sum<b, a>
  case a, b {
    adt.yield
  }
  case c {
    adt.yield
  }
  return
}

// -----

func.func @match_twice(%error: !adt.sum<a, b>) {
  // expected-error @below {{expects case 'a' to be listed once}}
  adt.match %error : !adt.sum<a, b>
  case a {
    adt.yield
  }
  case a, b {
    adt.yield
  }
  return
}

// -----

func.func @match_group_fields(%error: !adt.sum<read(i32), eof>) {
  // expected-error @below {{expects the cases of a group to have the same field types, got (i32) for 'read' and () for 'eof'}}
  adt.match %error : !adt.sum<read(i32), eof>
  case read, eof {
    adt.yield
  }
  return
}

// -----

func.func @match_argument_types(%error: !adt.sum<io(i32), eof>) {
  // expected-error @below {{expects the region of case 'io' to take arguments of types (i32)}}
  adt.match %error : !adt.sum<io(i32), eof>
  case io(%code: i64) {
    adt.yield
  }
  case eof {
    adt.yield
  }
  return
}

// -----

func.func @match_useless_default(%error: !adt.sum<a, b>) {
  // expected-error @below {{expects the default case to handle at least one case, but every case is listed}}
  adt.match %error : !adt.sum<a, b>
  case a, b {
    adt.yield
  }
  default {
    adt.yield
  }
  return
}

// -----

// No type is derived for the cases that the default case handles.
func.func @match_default_argument(%error: !adt.sum<a, b, c>) {
  adt.match %error : !adt.sum<a, b, c>
  case a {
    adt.yield
  }
  // expected-error @below {{expected '{' to begin a region}}
  default(%rest: !adt.sum<b, c>) {
    adt.yield
  }
  return
}

// -----

func.func @match_yield_types(%error: !adt.sum<a>) -> i32 {
  %result = adt.match %error : !adt.sum<a> -> i32
  case a {
    %zero = arith.constant 0 : i64
    // expected-error @below {{expects values of the result types (i32)}}
    adt.yield %zero : i64
  }
  return %result : i32
}

// -----

func.func @widen_missing_case(%error: !adt.sum<a, b>) {
  // expected-error @below {{expects case 'b' of the input to be a case of the result}}
  %wider = adt.widen %error : !adt.sum<a, b> to !adt.sum<a, c>
  return
}

// -----

func.func @widen_field_types(%error: !adt.sum<io(i32)>) {
  // expected-error @below {{expects case 'io' to have the same field types in the input and the result, got (i32) and (i64)}}
  %wider = adt.widen %error : !adt.sum<io(i32)> to !adt.sum<io(i64), eof>
  return
}

// -----

// A reordering is the same type, so it is not a widening.
func.func @widen_same_type(%error: !adt.sum<a, b>) {
  // expected-error @below {{expects the result type to differ from the input type}}
  %wider = adt.widen %error : !adt.sum<a, b> to !adt.sum<b, a>
  return
}

// -----

func.func @switch_not_exhaustive(%error: !adt.sum<a, b, c>) {
  // expected-error @below {{expects every case to be handled, or a default case; not handled: 'c'}}
  adt.switch %error : !adt.sum<a, b, c>, [
    a: ^a,
    b: ^a
  ]
^a:
  return
}

// -----

func.func @switch_arguments(%error: !adt.sum<io(i32), eof>) {
  // expected-error @below {{expects the successor of case 'io' to take arguments of types (i32)}}
  adt.switch %error : !adt.sum<io(i32), eof>, [
    io: ^io,
    eof: ^eof
  ]
^io(%code: i64):
  return
^eof:
  return
}

// -----

func.func @switch_default_argument(%error: !adt.sum<io(i32), eof>) {
  // expected-error @below {{branch has 0 operands for successor #1, but target block has 1}}
  adt.switch %error : !adt.sum<io(i32), eof>, [
    default: ^other,
    eof: ^eof
  ]
^other(%code: i32):
  return
^eof:
  return
}

// -----

func.func @switch_default_last(%error: !adt.sum<io(i32), eof>) {
  adt.switch %error : !adt.sum<io(i32), eof>, [
    eof: ^eof,
    // expected-error @below {{expected the default case first, and only once}}
    default: ^eof
  ]
^eof:
  return
}
