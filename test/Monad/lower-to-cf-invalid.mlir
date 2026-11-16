// RUN: fum-opt %s --split-input-file --convert-monad-to-cf --verify-diagnostics

// Two kinds whose names hash to the same tag.
monad.exception.declare @kind_631618
// expected-error @below {{the tag of exception kind "kind_819496" collides with kind_631618}}
monad.exception.declare @kind_819496

// -----

// expected-error @below {{cannot lower the payload of "pair": expects at most one integer of at most 64 bits or index}}
monad.exception.declare @pair(i32, i32)

// -----

// expected-error @below {{cannot lower the payload of "real": expects at most one integer of at most 64 bits or index}}
monad.exception.declare @real(f32)
