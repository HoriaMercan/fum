//===- MonadTypes.td - Monad dialect types -----------------*- tablegen -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef MONAD_TYPES
#define MONAD_TYPES

include "mlir/IR/AttrTypeBase.td"
include "fum/Dialect/Monad/IR/MonadDialect.td"
include "fum/Dialect/Monad/Interfaces/MonadTypeInterfaces.td"

//===----------------------------------------------------------------------===//
// Monad type definitions
//===----------------------------------------------------------------------===//

class Monad_Type<string name, string typeMnemonic, list<Trait> traits = []>
    : TypeDef<Monad_Dialect, name, traits> {
  let mnemonic = typeMnemonic;
}

def MonadMaybeType : Monad_Type<"Maybe", "maybe", [MonadTypeInterface]> {
  let summary = "Maybe monad type";
  let description = [{
    A value of type `!monad.maybe<T1, ..., Tn>` is either `some` value
    carrying one value of each type `T1`, ..., `Tn`, or `none`, which carries
    nothing. The list of value types may be empty.
  }];
  let parameters = (ins
      OptionalArrayRefParameter<"::mlir::Type", "value types">:$valueTypes);
  let assemblyFormat = "`<` custom<ValueTypes>($valueTypes) `>`";
  let extraClassDeclaration = [{
    /// Returns the maybe type with the given value types.
    MonadTypeInterface cloneWithValueTypes(::mlir::TypeRange valueTypes) const;
  }];
}

def MonadExceptionType : Monad_Type<"Exception", "exception"> {
  let summary = "Exception type";
  let description = [{
    A value of type `!monad.exception` is an exception: a kind, which is a
    symbol declared by `monad.exception.declare`, and the payload values that
    the kind declares. Every exception has this one type, so the set of kinds
    is open.
  }];
}

def MonadValueOrExceptionType
    : Monad_Type<"ValueOrException", "value_or_exception",
                 [MonadTypeInterface]> {
  let summary = "Value-or-exception monad type";
  let description = [{
    A value of type `!monad.value_or_exception<T1, ..., Tn>` is either a
    success carrying one value of each type `T1`, ..., `Tn`, or a failure
    carrying one `!monad.exception`. The type does not say which exception
    kinds may occur. The list of value types may be empty.

    ```mlir
    !monad.value_or_exception<i32>
    ```
  }];
  let parameters = (ins
      OptionalArrayRefParameter<"::mlir::Type", "value types">:$valueTypes);
  let assemblyFormat = "`<` custom<ValueTypes>($valueTypes) `>`";
  let extraClassDeclaration = [{
    /// Returns the value-or-exception type with the given value types.
    MonadTypeInterface cloneWithValueTypes(::mlir::TypeRange valueTypes) const;
  }];
}

#endif // MONAD_TYPES
