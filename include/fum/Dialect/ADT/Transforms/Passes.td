//===- Passes.td - ADT dialect passes ----------------------*- tablegen -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef ADT_PASSES
#define ADT_PASSES

include "mlir/Pass/PassBase.td"

def ConvertADTToSCFPass : Pass<"convert-adt-to-scf", "::mlir::ModuleOp"> {
  let summary = "Lower sum types to tags and field slots";
  let description = [{
    Expands every value of type `!adt.sum<C...>` into an `i32` tag, the
    position of its case among the cases sorted by name, followed by the
    lowered field types of every case, in the same order. The slots of the
    cases other than the one the value holds are `ub.poison`.

    - `adt.make` becomes the constant tag and the fields in the slots of the
      case;
    - `adt.match` becomes `scf.index_switch` on the tag, with one region per
      listed case (a group is duplicated for each of its cases) and the
      `default` region, or a region yielding `ub.poison` if the match is
      exhaustive;
    - `adt.widen` maps every tag of the input to the tag of the same case in
      the result, and copies the slots of the cases of the input.

    Function signatures, calls, returns, branches, `arith.select`, and
    `ub.poison` of sum types are converted too.
  }];
  let dependentDialects = [
    "::mlir::arith::ArithDialect",
    "::mlir::scf::SCFDialect",
    "::mlir::ub::UBDialect"
  ];
}

#endif // ADT_PASSES
