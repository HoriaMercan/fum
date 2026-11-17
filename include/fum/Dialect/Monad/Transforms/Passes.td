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
  let summary = "Lower monadic computations to control flow";
  let description = [{
    Lowers the monad dialect to the `cf`, `arith`, and `ub` dialects. Each
    `monad.do` is inlined into the enclosing region, ending in a block that
    receives the result; `monad.bind`, `monad.error.catch`,
    `monad.either.branch`, and `monad.error.switch` become conditional
    branches and switches. Monadic values are then expanded into several
    values:

    - `!monad.maybe<T...>` becomes an `i1` (set for `some`) and `T...`;
    - `!monad.either<!monad.error_union<{E...}>, R...>` becomes an `i32` tag
      (0 for a right, otherwise the tag of the error), `R...`, and the
      payload slots of every error of the union; an either whose left type
      is one error is lowered as the union of that error;
    - any other `!monad.either<L, R...>` becomes an `i1` (set for a left),
      the values of `L`, and `R...`;
    - `!monad.error<@name, P...>` becomes `P...`, and
      `!monad.error_union<{E...}>` an `i32` tag and the payload slots.

    The tag of an error is the tag of its declaration in the module, as
    `monad.error.declare` describes; the pass fails if the module uses an
    error without a declaration with the same payload types. Unused slots
    hold `ub.poison`.
  }];
  let dependentDialects = [
    "::mlir::arith::ArithDialect",
    "::mlir::cf::ControlFlowDialect",
    "::mlir::ub::UBDialect"
  ];
}

#endif // MONAD_PASSES
