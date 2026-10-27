//===- MonadOps.cpp - Monad dialect ops -------------------------*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "fum/Dialect/Monad/IR/MonadOps.h"

#include "mlir/IR/Builders.h"
#include "mlir/IR/OpImplementation.h"

using namespace mlir;
using namespace mlir::monad;

#define GET_OP_CLASSES
#include "fum/Dialect/Monad/IR/MonadOps.cpp.inc"

//===----------------------------------------------------------------------===//
// MonadMaybeBindOp
//===----------------------------------------------------------------------===//

/// Verifies that the body takes the value carried by the input and yields the
/// result.
LogicalResult MonadMaybeBindOp::verifyRegions() {
  Block &body = getBody().front();
  Type valueType = getInput().getType().getValueType();
  if (body.getNumArguments() != 1 || body.getArgument(0).getType() != valueType)
    return emitOpError()
           << "expects the body to take a single argument of type "
           << valueType;

  auto yield = dyn_cast<MonadYieldOp>(body.back());
  if (!yield)
    return emitOpError() << "expects the body to be terminated by "
                         << MonadYieldOp::getOperationName();
  if (yield.getValue().getType() != getType())
    return emitOpError() << "expects the body to yield " << getType()
                         << ", got " << yield.getValue().getType();
  return success();
}
