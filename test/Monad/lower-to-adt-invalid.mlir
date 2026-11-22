// RUN: fum-opt %s --convert-monad-to-adt --verify-diagnostics

// A monad.do is inlined into the enclosing region, which a region of
// adt.match cannot hold, since it takes a single block.
func.func @do_in_match(%error: !adt.sum<a, b>, %input: !monad.maybe<i32>) -> !monad.maybe<i32> {
  %result = adt.match %error : !adt.sum<a, b> -> !monad.maybe<i32>
  case a, b {
    // expected-error @below {{cannot be lowered in a region that takes a single block}}
    %inner = monad.do : !monad.maybe<i32> {
      monad.yield %input : !monad.maybe<i32>
    }
    adt.yield %inner : !monad.maybe<i32>
  }
  return %result : !monad.maybe<i32>
}
