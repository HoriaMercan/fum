// RUN: fum-opt %s --convert-monad-to-cf --verify-diagnostics

// The lowering needs the declaration of every error, also of errors that no
// operation of the monad dialect uses.
// expected-error @below {{uses '!monad.error<@missing>', which no error of the module declares with these payload types}}
func.func private @signature_only(!monad.error<@missing>)
