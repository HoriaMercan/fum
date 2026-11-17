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
    receives the result; `monad.bind`, `monad.either.catch`, and
    `monad.either.branch` become conditional branches and switches. Monadic
    values are then expanded into several values:

    - `!monad.maybe<T...>` becomes an `i1` (set for `some`) and `T...`;
    - `!monad.either<!monad.error_union<{E...}>, R...>` becomes an `i32` tag
      (0 for a right, otherwise the tag of the error), `R...`, and the
      payload slots of every error of the union;
    - any other `!monad.either<L, R...>` becomes an `i1` (set for a left),
      the values of `L`, and `R...`;
    - `!monad.error<"name", P...>` becomes `P...`, and
      `!monad.error_union<{E...}>` an `i32` tag and the payload slots.

    The tag of an error is the FNV-1a hash of its name, masked to a positive
    `i32`; the pass fails if two errors of the module get the same tag.
    Unused slots hold `ub.poison`.
  }];
  let dependentDialects = [
    "::mlir::arith::ArithDialect",
    "::mlir::cf::ControlFlowDialect",
    "::mlir::ub::UBDialect"
  ];
}

#endif // MONAD_PASSES
