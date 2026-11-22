//===- Passes.h - Monad dialect passes --------------------------*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef FUM_DIALECT_MONAD_TRANSFORMS_PASSES_H
#define FUM_DIALECT_MONAD_TRANSFORMS_PASSES_H

#include "fum/Dialect/ADT/IR/ADTDialect.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"

namespace mlir {
namespace monad {
#define GEN_PASS_DECL
#include "fum/Dialect/Monad/Transforms/Passes.h.inc"

#define GEN_PASS_REGISTRATION
#include "fum/Dialect/Monad/Transforms/Passes.h.inc"
} // namespace monad
} // namespace mlir

#endif // FUM_DIALECT_MONAD_TRANSFORMS_PASSES_H
