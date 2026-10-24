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

//===----------------------------------------------------------------------===//
// Monad type definitions
//===----------------------------------------------------------------------===//

class Monad_Type<string name, string typeMnemonic, list<Trait> traits = []>
    : TypeDef<Monad_Dialect, name, traits> {
  let mnemonic = typeMnemonic;
}

def MonadMaybeType : Monad_Type<"Maybe", "maybe"> {
  let summary = "Maybe monad type";
  let description = [{
    A value of type `!monad.maybe<T>` is either a success carrying a value of
    type `T`, or a failure carrying nothing.
  }];
  let parameters = (ins "::mlir::Type":$valueType);
  let assemblyFormat = "`<` $valueType `>`";
}

#endif // MONAD_TYPES
