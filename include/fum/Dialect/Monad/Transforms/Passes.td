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

    The tag of an exception kind is the tag of its declaration in the module,
    as `monad.exception.declare` describes. The pass fails if a kind has more
    than one payload value or a payload value other than an integer of at most
    64 bits or an index. Unused components are `ub.poison`.
  }];
  let dependentDialects = [
    "::mlir::arith::ArithDialect",
    "::mlir::cf::ControlFlowDialect",
    "::mlir::ub::UBDialect"
  ];
}

def CheckMayThrowPass : Pass<"monad-check-may-throw", "::mlir::ModuleOp"> {
  let summary = "Check that functions list the exceptions they may throw";
  let description = [{
    Checks that the `monad.may_throw` attribute of every function with a body
    lists every exception kind that the results of the function may hold.
    Functions without the attribute are not checked.

    The kinds of a value are those of the `monad.exception.make` operations
    whose exceptions reach it: through `monad.throw`, `arith.select`,
    `monad.do`, the binds and catches that let a failure out of a
    `monad.do`, and the default case of `monad.catch`, which receives the
    kinds that no case lists. A call contributes the `monad.may_throw` of its
    callee, or, if the callee has none, the kinds computed from the body of
    the callee. Any other source, such as a function argument or a call to an
    external function without `monad.may_throw`, may hold any kind, which
    fails the check of an annotated function.

    ```mlir
    // Accepted: div_by_zero is caught, so only overflow may be thrown.
    func.func @half_ratio(%a: i32, %b: i32) -> !monad.value_or_exception<i32>
        attributes {monad.may_throw = [@overflow]} {
      %result = monad.do : !monad.value_or_exception<i32> {
        %ratio = func.call @safe_div(%a, %b)
            : (i32, i32) -> !monad.value_or_exception<i32>
        monad.catch %ratio [@div_by_zero -> ^recover]
            : !monad.value_or_exception<i32>
      ^recover:
        ...
      }
      return %result : !monad.value_or_exception<i32>
    }
    ```
  }];
}

#endif // MONAD_PASSES
