//===- MonadTypeInterfaces.td - Monad type interfaces ------*- tablegen -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef FUM_DIALECT_MONAD_INTERFACES_MONADTYPEINTERFACES_TD
#define FUM_DIALECT_MONAD_INTERFACES_MONADTYPEINTERFACES_TD

include "mlir/IR/Interfaces.td"

def MonadTypeInterface : TypeInterface<"MonadTypeInterface"> {
  let description = [{
    Interface for monadic types. A value of a monadic type either is a success
    carrying a value of the value type, or represents a failure. Operations
    common to all monads access monadic types only through this interface.
  }];
  let cppNamespace = "::mlir::monad";

  let methods = [
    InterfaceMethod<
      /*desc=*/[{
        Returns the type of the value carried by a success.
      }],
      /*returnType=*/"::mlir::Type",
      /*name=*/"getValueType",
      /*arguments=*/(ins),
      /*methodBody=*/"",
      /*defaultImplementation=*/[{ return $_type.getValueType(); }]
    >
  ];
}

#endif // FUM_DIALECT_MONAD_INTERFACES_MONADTYPEINTERFACES_TD
