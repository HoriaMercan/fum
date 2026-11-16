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

#include "fum/Dialect/Monad/IR/MonadOpsDialect.cpp.inc"

namespace {
/// Gives error types short aliases in the printed IR, such as
/// `!error_div_by_zero = !monad.error<"div_by_zero">`.
struct MonadOpAsmDialectInterface : public OpAsmDialectInterface {
  using OpAsmDialectInterface::OpAsmDialectInterface;

  /// Returns the alias `error_<name>` for an error type.
  AliasResult getAlias(Type type, raw_ostream &os) const override {
    if (auto error = dyn_cast<ErrorType>(type)) {
      os << "error_" << error.getName();
      return AliasResult::OverridableAlias;
    }
    return AliasResult::NoAlias;
  }
};
} // namespace

/// Registers the operations and types of the dialect.
void MonadDialect::initialize() {
  addOperations<
#define GET_OP_LIST
#include "fum/Dialect/Monad/IR/MonadOps.cpp.inc"
      >();
  registerTypes();
  addInterfaces<MonadOpAsmDialectInterface>();
}
