//===- ADTDialect.cpp - Algebraic data type dialect -------------*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "fum/Dialect/ADT/IR/ADTDialect.h"
#include "fum/Dialect/ADT/IR/ADTOps.h"
#include "fum/Dialect/ADT/IR/ADTTypes.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"

using namespace mlir;
using namespace mlir::adt;

#include "fum/Dialect/ADT/IR/ADTOpsDialect.cpp.inc"

/// Registers the operations and types of the dialect.
void ADTDialect::initialize() {
  addOperations<
#define GET_OP_LIST
#include "fum/Dialect/ADT/IR/ADTOps.cpp.inc"
      >();
  registerTypes();
}
