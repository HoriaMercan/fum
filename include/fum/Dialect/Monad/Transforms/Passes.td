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
    Inlines every `monad.do` into its parent region, lowers `monad.bind` to a
    `cf.cond_br` and `monad.catch` to a `cf.switch` that leave the inlined
    region through its exit block, then converts every monadic value into its
    components:

    - `!monad.maybe<T...>` becomes `i1` (set on `some`) and `T...`;
    - `!monad.exception` becomes an `i32` tag and an `i64` payload word;
    - `!monad.value_or_exception<T...>` becomes an `i32` tag (0 on success),
      `T...`, and an `i64` payload word.

    The tag of an exception kind is the 32-bit FNV-1a hash of its name, masked
    to a positive value. The pass fails if two kinds of the module have the
    same tag, or if a kind has more than one payload value or a payload value
    other than an integer of at most 64 bits or an index. Unused components
    are `ub.poison`.
  }];
  let dependentDialects = [
    "::mlir::arith::ArithDialect",
    "::mlir::cf::ControlFlowDialect",
    "::mlir::ub::UBDialect"
  ];
}

#endif // MONAD_PASSES
