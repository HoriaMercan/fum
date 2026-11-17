//===- MonadDialect.cpp - Monad dialect -------------------------*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "fum/Dialect/Monad/IR/MonadDialect.h"
#include "fum/Dialect/Monad/IR/MonadOps.h"
#include "fum/Dialect/Monad/IR/MonadTypes.h"

#include "mlir/IR/OpImplementation.h"

using namespace mlir;
using namespace mlir::monad;

namespace {
/// Prints short aliases for error types and error unions, such as
/// `!error_overflow = !monad.error<"overflow">`.
struct MonadOpAsmDialectInterface : public OpAsmDialectInterface {
  using OpAsmDialectInterface::OpAsmDialectInterface;

  /// Returns the alias of error and error union types.
  AliasResult getAlias(Type type, raw_ostream &os) const override {
    if (ErrorType error = dyn_cast<ErrorType>(type)) {
      os << "error_" << error.getName().getValue();
      return AliasResult::FinalAlias;
    }
    if (ErrorUnionType errors = dyn_cast<ErrorUnionType>(type)) {
      os << "errors";
      for (ErrorType error : errors.getErrors())
        os << "_" << error.getName().getValue();
      return AliasResult::OverridableAlias;
    }
    return AliasResult::NoAlias;
  }
};
} // namespace

#include "fum/Dialect/Monad/IR/MonadOpsDialect.cpp.inc"

/// Registers the operations and types of the dialect.
void MonadDialect::initialize() {
  addOperations<
#define GET_OP_LIST
#include "fum/Dialect/Monad/IR/MonadOps.cpp.inc"
      >();
  registerTypes();
  addInterfaces<MonadOpAsmDialectInterface>();
}
