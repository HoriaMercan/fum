//===- MonadOps.h - Monad dialect ops ---------------------------*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef FUM_DIALECT_MONAD_IR_MONADOPS_H
#define FUM_DIALECT_MONAD_IR_MONADOPS_H

#include "mlir/Bytecode/BytecodeOpInterface.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Dialect.h"
#include "mlir/IR/OpDefinition.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/Interfaces/CastInterfaces.h"
#include "mlir/Interfaces/ControlFlowInterfaces.h"
#include "mlir/Interfaces/SideEffectInterfaces.h"
#include "llvm/ADT/DenseMap.h"

#include "fum/Dialect/Monad/IR/MonadDialect.h"
#include "fum/Dialect/Monad/IR/MonadTypes.h"

#define GET_OP_CLASSES
#include "fum/Dialect/Monad/IR/MonadOps.h.inc"

namespace mlir {
namespace monad {
/// Returns the tag of every error declared in `module`, by error name: the
/// explicit tag of the declaration, or otherwise the next tag that no
/// explicit tag uses, in the order of the declarations, starting at 1.
llvm::DenseMap<StringAttr, int32_t> getErrorTags(ModuleOp module);
} // namespace monad
} // namespace mlir

#endif // FUM_DIALECT_MONAD_IR_MONADOPS_H
