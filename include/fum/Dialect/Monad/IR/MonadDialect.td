//===- MonadDialect.td - Monad dialect ---------------------*- tablegen -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef MONAD_DIALECT
#define MONAD_DIALECT

include "mlir/IR/OpBase.td"

//===----------------------------------------------------------------------===//
// Monad dialect definition.
//===----------------------------------------------------------------------===//

def Monad_Dialect : Dialect {
  let name = "monad";
  let summary = "A dialect for monadic computations in MLIR";
  let description = [{
    This dialect makes failure handling explicit through monadic types, such as
    `!monad.maybe<T>`, and operations that construct monadic values.
  }];
  let cppNamespace = "::mlir::monad";

  let useDefaultTypePrinterParser = 1;
  let extraClassDeclaration = [{
    /// Registers the types of the dialect.
    void registerTypes();
  }];
}

//===----------------------------------------------------------------------===//
// Base monad operation definition.
//===----------------------------------------------------------------------===//

class Monad_Op<string mnemonic, list<Trait> traits = []> :
    Op<Monad_Dialect, mnemonic, traits>;

#endif // MONAD_DIALECT
