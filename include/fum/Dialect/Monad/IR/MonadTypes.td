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

def MonadErrorType : Monad_Type<"Error", "error"> {
  let summary = "Error type";
  let description = [{
    A value of type `!monad.error<"name", P1, ..., Pn>` is the error named
    `name` carrying a payload of one value of each type `P1`, ..., `Pn`. The
    name identifies the error: within a set of errors, two errors with the
    same name are the same error. Without a payload, the type has exactly one
    value.

    ```mlir
    !monad.error<"div_by_zero">
    !monad.error<"silenceable", i32>
    ```
  }];
  let parameters = (ins
      StringRefParameter<"error name">:$name,
      OptionalArrayRefParameter<"::mlir::Type", "payload types">:$payload);
  let assemblyFormat = "`<` $name (`,` $payload^)? `>`";
  let genVerifyDecl = 1;
}

def MonadErrorUnionType : Monad_Type<"ErrorUnion", "error_union"> {
  let summary = "Type of one error out of a set of errors";
  let description = [{
    A value of type `!monad.error_union<{E1, ..., En}>` is a value of exactly
    one of the error types `E1`, ..., `En`. The errors are a non-empty set
    with distinct names; they are kept sorted by name, and the parser accepts
    them in any order.

    ```mlir
    !monad.error_union<{!monad.error<"div_by_zero">, !monad.error<"overflow">}>
    ```
  }];
  let parameters = (ins
      ArrayRefParameter<"::mlir::monad::ErrorType", "errors">:$errors);
  let assemblyFormat = "`<` custom<ErrorSet>($errors) `>`";
  let skipDefaultBuilders = 1;
  let builders = [
    TypeBuilder<(ins "::llvm::ArrayRef<::mlir::monad::ErrorType>":$errors)>
  ];
  let genVerifyDecl = 1;
}

def MonadValueOrErrorType : Monad_Type<"ValueOrError", "value_or_error",
    [MonadTypeInterface]> {
  let summary = "Value-or-error monad type";
  let description = [{
    A value of type `!monad.value_or_error<[T1, ..., Tn] throws {E1, ..., Em}>`
    is either a success carrying one value of each type `T1`, ..., `Tn`, or a
    failure carrying exactly one error of the error types `E1`, ..., `Em`. The
    value types are an ordered list and the errors a set of `!monad.error`
    types with distinct names; both may be empty. The errors are kept sorted by
    name, and the parser accepts them in any order.

    ```mlir
    // Either an i32, or an overflow or a division by zero.
    !monad.value_or_error<[i32] throws {!monad.error<"div_by_zero">,
                                        !monad.error<"overflow">}>
    ```
  }];
  let parameters = (ins
      OptionalArrayRefParameter<"::mlir::Type", "value types">:$valueTypes,
      OptionalArrayRefParameter<"::mlir::monad::ErrorType", "errors">:$errors);
  let assemblyFormat = [{
    `<` `[` custom<ValueTypes>($valueTypes) `]` `throws`
    custom<ErrorSet>($errors) `>`
  }];
  let skipDefaultBuilders = 1;
  let builders = [
    TypeBuilder<(ins "::mlir::TypeRange":$valueTypes,
                     "::llvm::ArrayRef<::mlir::monad::ErrorType>":$errors)>
  ];
  let genVerifyDecl = 1;
  let extraClassDeclaration = [{
    /// Returns the value-or-error type with the given value types and the
    /// errors of this type.
    MonadTypeInterface cloneWithValueTypes(::mlir::TypeRange valueTypes) const;
  }];
}

#endif // MONAD_TYPES
