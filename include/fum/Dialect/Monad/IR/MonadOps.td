//===- MonadOps.td - Monad dialect ops ---------------------*- tablegen -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef MONAD_OPS
#define MONAD_OPS

include "fum/Dialect/Monad/IR/MonadTypes.td"
include "mlir/Interfaces/SideEffectInterfaces.td"

//===----------------------------------------------------------------------===//
// Operations common to all monads
//===----------------------------------------------------------------------===//

def MonadReturnOp : Monad_Op<"return", [
    Pure,
    TypesMatchWith<"value type matches the value type of the result",
                   "result", "value",
                   "::llvm::cast<::mlir::monad::MonadTypeInterface>($_self).getValueType()">]> {
  let summary = "Wraps a value as a success";
  let description = [{
    Creates a monadic value that represents a success carrying the given value.
    The type of the value is the value type of the result.

    ```mlir
    %m = monad.return %v : !monad.maybe<i32>
    ```
  }];
  let arguments = (ins AnyType:$value);
  let results = (outs AnyMonadType:$result);
  let assemblyFormat = "$value attr-dict `:` qualified(type($result))";
}

//===----------------------------------------------------------------------===//
// Maybe operations
//===----------------------------------------------------------------------===//

def MonadMaybeFailOp : Monad_Op<"maybe.fail", [Pure]> {
  let summary = "Creates a maybe failure";
  let description = [{
    Creates a maybe value that represents a failure, which carries no value.

    ```mlir
    %m = monad.maybe.fail : !monad.maybe<i32>
    ```
  }];
  let results = (outs MonadMaybeType:$result);
  let assemblyFormat = "attr-dict `:` qualified(type($result))";
}

def MonadMaybeBindOp : Monad_Op<"maybe.bind", [
    RecursiveMemoryEffects,
    SingleBlock]> {
  let summary = "Sequences a maybe value with a computation on its value";
  let description = [{
    Binds the value carried by the input to the argument of the body and
    produces the maybe value yielded by the body. If the input is a failure,
    the body is not executed and the result is a failure.

    ```mlir
    %r = monad.maybe.bind %m : !monad.maybe<i32> -> !monad.maybe<f32> {
    ^bb0(%x: i32):
      %y = arith.sitofp %x : i32 to f32
      %ok = monad.return %y : !monad.maybe<f32>
      monad.yield %ok : !monad.maybe<f32>
    }
    ```
  }];
  let arguments = (ins MonadMaybeType:$input);
  let results = (outs MonadMaybeType:$result);
  let regions = (region SizedRegion<1>:$body);
  let assemblyFormat = [{
    $input attr-dict `:` qualified(type($input)) `->` qualified(type($result))
    $body
  }];
  let hasRegionVerifier = 1;
}

//===----------------------------------------------------------------------===//
// Terminators
//===----------------------------------------------------------------------===//

def MonadYieldOp : Monad_Op<"yield", [
    Pure,
    Terminator,
    HasParent<"MonadMaybeBindOp">]> {
  let summary = "Yields the result of a monadic computation";
  let description = [{
    Terminates the body of a monadic operation. The yielded value becomes the
    result of the parent operation.

    ```mlir
    monad.yield %m : !monad.maybe<f32>
    ```
  }];
  let arguments = (ins AnyMonadType:$value);
  let assemblyFormat = "$value attr-dict `:` qualified(type($value))";
}

#endif // MONAD_OPS
