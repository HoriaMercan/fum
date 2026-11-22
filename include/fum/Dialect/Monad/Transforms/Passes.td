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

def ConvertMonadToADTPass : Pass<"convert-monad-to-adt", "::mlir::ModuleOp"> {
  let summary = "Lower monadic computations to sum types and control flow";
  let description = [{
    Lowers the monad dialect, the high-level form, to the low-level form: sum
    types of the `adt` dialect and unstructured control flow. Every monadic
    type is the sum of its constructors:

    - `!monad.maybe<T...>` becomes `!adt.sum<just(T...), nothing>`; without
      value types, both cases have no field, and the sum is only a tag;
    - `!monad.either<L, R...>` becomes `!adt.sum<left(L), right(R...)>`;
    - `!monad.either<!adt.sum<C...>, R...>` becomes the merged sum
      `!adt.sum<C..., right(R...)>`, unless the cases `C...` contain `right`:
      a left holding a case of the errors is that case itself, so the sum
      needs one tag instead of two.

    Constructors become `adt.make` (`monad.return`, `monad.maybe.none`,
    `monad.either.left`), or `adt.widen` for a left of a merged sum. Each
    `monad.do` is inlined into the enclosing region, ending in a block that
    receives the result. `monad.bind` and `monad.either.branch` become
    `adt.switch`: a bind continues with the fields of the success case, and
    rebuilds every other case in the type of the `monad.do`, which it ends.

    A `monad.do` must not be nested in a region that takes a single block,
    such as a region of `adt.match`.
  }];
  let dependentDialects = [
    "::mlir::adt::ADTDialect",
    "::mlir::cf::ControlFlowDialect"
  ];
}

#endif // MONAD_PASSES
