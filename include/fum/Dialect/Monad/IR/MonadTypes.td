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
  let summary = "Named error type";
  let description = [{
    A value of type `!monad.error<"name", P1, ..., Pk>` is the error `name`
    carrying one payload value of each type `P1`, ..., `Pk`. Without payload,
    the type has exactly one value, like the builtin `none` type. Errors are
    identified by their name: two errors with the same name must have the
    same payload types wherever they meet, for example in an
    `!monad.error_union`.

    ```mlir
    !monad.error<"overflow">
    !monad.error<"out_of_bounds", index, index>
    ```
  }];
  let parameters = (ins
      "::mlir::StringAttr":$name,
      OptionalArrayRefParameter<"::mlir::Type", "payload types">:$payloadTypes);
  let assemblyFormat = "`<` $name (`,` $payloadTypes^)? `>`";
  let genVerifyDecl = 1;
  let builders = [
    TypeBuilder<(ins "::llvm::StringRef":$name,
                     CArg<"::mlir::TypeRange", "{}">:$payloadTypes), [{
      return $_get($_ctxt, ::mlir::StringAttr::get($_ctxt, name),
                   ::llvm::to_vector(payloadTypes));
    }]>
  ];
}

def MonadErrorUnionType : Monad_Type<"ErrorUnion", "error_union"> {
  let summary = "Union of named error types";
  let description = [{
    A value of type `!monad.error_union<{E1, ..., Em}>` is exactly one value
    of one of the error types `E1`, ..., `Em`. The errors form a non-empty
    set: a union without members would have no value at all. Their names are
    distinct, and they are stored sorted by name. The parser and the builder
    accept them in any order.

    A union is not a monad. `monad.error_union.switch` branches on its
    member.

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
  let extraClassDeclaration = [{
    /// Returns the member error named `name`, or null if there is none.
    ErrorType lookup(::llvm::StringRef name) const;
    /// Returns whether `error` is a member of this union.
    bool contains(ErrorType error) const;
    /// Returns whether every member of this union is a member of `other`.
    bool isSubsetOf(ErrorUnionType other) const;
  }];
}

def MonadEitherType : Monad_Type<"Either", "either", [MonadTypeInterface]> {
  let summary = "Either monad type";
  let description = [{
    A value of type `!monad.either<L, R1, ..., Rn>` is either a left carrying
    one value of type `L`, or a right carrying one value of each type `R1`,
    ..., `Rn`. Both sides are always written. The right types are the value
    types of the monad. A right that carries nothing is written `none`, as
    in Haskell's `Either L ()`: the monad then has no value types, and
    `none` cannot appear among other right types.

    `monad.return` creates a right and `monad.either.left` a left.
    `monad.bind` continues on a right and ends the enclosing `monad.do` with
    a left. `monad.either.branch` branches on the side.

    When `L` is an `!monad.error` or an `!monad.error_union`, the type
    describes a computation that may throw: `monad.either.throw`,
    `monad.either.catch`, and `monad.either.widen` apply. A single error
    behaves as the union of that error.

    ```mlir
    // Either an i32, or an overflow or a division by zero.
    !monad.either<!monad.error_union<{!monad.error<"div_by_zero">,
                                      !monad.error<"overflow">}>, i32>
    // Either nothing, or a division by zero.
    !monad.either<!monad.error<"div_by_zero">, none>
    ```
  }];
  let parameters = (ins
      "::mlir::Type":$leftType,
      OptionalArrayRefParameter<"::mlir::Type", "value types">:$valueTypes);
  let assemblyFormat = "`<` $leftType `,` custom<RightTypes>($valueTypes) `>`";
  let genVerifyDecl = 1;
  let extraClassDeclaration = [{
    /// Returns the either type with the given value types and the left type
    /// of this type.
    MonadTypeInterface cloneWithValueTypes(::mlir::TypeRange valueTypes) const;
    /// Returns the errors of the left type: the left type if it is an error
    /// union, the union of the error if it is an error, and null otherwise.
    ErrorUnionType getErrorUnion() const;
  }];
}

#endif // MONAD_TYPES
