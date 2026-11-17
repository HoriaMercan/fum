// RUN: fum-opt %s --split-input-file --convert-monad-to-cf --verify-diagnostics

// expected-error @below {{cannot lower the payload of "pair": expects at most one integer of at most 64 bits or index}}
monad.exception.declare @pair(i32, i32)

// -----

// expected-error @below {{cannot lower the payload of "real": expects at most one integer of at most 64 bits or index}}
monad.exception.declare @real(f32)
