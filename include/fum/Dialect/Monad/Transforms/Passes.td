//===- Passes.td - Monad dialect passes --------------------*- tablegen -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef MONAD_PASSES
#define MONAD_PASSES

include "mlir/Pass/PassBase.td"

def ConvertMonadToCFPass : Pass<"convert-monad-to-cf", "::mlir::ModuleOp"> {
  let summary = "Lower the monad dialect to cf, arith and ub";
  let description = [{
    Inlines every `monad.do` into its parent region, outermost first, and
    expands the monad operations into control flow on the components of the
    monadic values. The monadic types are then converted 1:N:

    - `!monad.maybe<T...>` becomes `i1` (true for `some`) and `T...`;
    - `!monad.value_or_error<[T...] throws {E...}>` becomes an `i32` tag,
      `T...`, and the payload slots of each error `E` in order;
    - `!monad.error<@name, P...>` becomes `P...`;
    - `!monad.error_union<{E...}>` becomes an `i32` tag and the payload slots
      of each error `E` in order.

    The tag of a success is 0, and the tag of an error is the tag of its
    declaration in the module, as `monad.error.declare` describes. The pass
    fails if the module uses an error without a declaration with the same
    payload types. Unused slots hold `ub.poison`. Value and
    payload types that are themselves types of the monad dialect are not
    supported.
  }];
  let dependentDialects = [
    "::mlir::arith::ArithDialect",
    "::mlir::cf::ControlFlowDialect",
    "::mlir::func::FuncDialect",
    "::mlir::ub::UBDialect"
  ];
}

#endif // MONAD_PASSES
