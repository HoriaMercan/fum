//===- Passes.h - ADT dialect passes ----------------------------*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef FUM_DIALECT_ADT_TRANSFORMS_PASSES_H
#define FUM_DIALECT_ADT_TRANSFORMS_PASSES_H

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/Dialect/UB/IR/UBOps.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"

namespace mlir {
namespace adt {
#define GEN_PASS_DECL
#include "fum/Dialect/ADT/Transforms/Passes.h.inc"

#define GEN_PASS_REGISTRATION
#include "fum/Dialect/ADT/Transforms/Passes.h.inc"
} // namespace adt
} // namespace mlir

#endif // FUM_DIALECT_ADT_TRANSFORMS_PASSES_H
