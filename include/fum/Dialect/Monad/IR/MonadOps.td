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

def MonadReturnOp : Monad_Op<"return", [
    Pure,
    TypesMatchWith<"value type matches the value type of the result",
                   "result", "value",
                   "::llvm::cast<::mlir::monad::MaybeType>($_self).getValueType()">]> {
  let summary = "Wraps a value as a success";
  let description = [{
    Creates a monadic value that represents a success carrying the given value.
    The type of the value is the value type of the result.

    ```mlir
    %m = monad.return %v : !monad.maybe<i32>
    ```
  }];
  let arguments = (ins AnyType:$value);
  let results = (outs MonadMaybeType:$result);
  let assemblyFormat = "$value attr-dict `:` qualified(type($result))";
}

def MonadFailOp : Monad_Op<"fail", [Pure]> {
  let summary = "Creates a failure";
  let description = [{
    Creates a monadic value that represents a failure.

    ```mlir
    %m = monad.fail : !monad.maybe<i32>
    ```
  }];
  let results = (outs MonadMaybeType:$result);
  let assemblyFormat = "attr-dict `:` qualified(type($result))";
}

#endif // MONAD_OPS
