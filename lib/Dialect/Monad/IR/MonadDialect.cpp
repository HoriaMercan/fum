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

#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/OpImplementation.h"
#include "mlir/IR/SymbolTable.h"

using namespace mlir;
using namespace mlir::monad;

#include "fum/Dialect/Monad/IR/MonadOpsDialect.cpp.inc"

namespace {
/// Gives short aliases to the exception and value-or-exception types.
struct MonadOpAsmDialectInterface : public OpAsmDialectInterface {
  using OpAsmDialectInterface::OpAsmDialectInterface;

  /// Aliases `!monad.exception` as `!exception` and
  /// `!monad.value_or_exception<T...>` as `!voe` followed by the names of the
  /// value types when they are integer, index or float types.
  AliasResult getAlias(Type type, raw_ostream &os) const override {
    if (isa<ExceptionType>(type)) {
      os << "exception";
      return AliasResult::OverridableAlias;
    }
    auto voeType = dyn_cast<ValueOrExceptionType>(type);
    if (!voeType)
      return AliasResult::NoAlias;
    os << "voe";
    for (Type valueType : voeType.getValueTypes()) {
      if (!isa<IntegerType, IndexType, FloatType>(valueType))
        return AliasResult::OverridableAlias;
    }
    for (Type valueType : voeType.getValueTypes())
      os << "_" << valueType;
    return AliasResult::OverridableAlias;
  }
};
} // namespace

/// Registers the operations, types and interfaces of the dialect.
void MonadDialect::initialize() {
  addOperations<
#define GET_OP_LIST
#include "fum/Dialect/Monad/IR/MonadOps.cpp.inc"
      >();
  registerTypes();
  addInterfaces<MonadOpAsmDialectInterface>();
}

/// Verifies `monad.may_throw`: a list of declared exception kinds.
LogicalResult MonadDialect::verifyOperationAttribute(Operation *op,
                                                     NamedAttribute attr) {
  if (attr.getName() != kMayThrowAttrName)
    return op->emitError() << "unknown monad dialect attribute "
                           << attr.getName();
  auto kinds = dyn_cast<ArrayAttr>(attr.getValue());
  if (!kinds)
    return op->emitError() << "expects " << kMayThrowAttrName
                           << " to be an array of exception kinds";
  for (Attribute kind : kinds) {
    auto kindRef = dyn_cast<FlatSymbolRefAttr>(kind);
    if (!kindRef)
      return op->emitError()
             << "expects " << kMayThrowAttrName
             << " to be an array of exception kinds, got " << kind;
    if (!SymbolTable::lookupNearestSymbolFrom<MonadExceptionDeclareOp>(
            op, kindRef.getAttr()))
      return op->emitError()
             << kindRef << " does not reference a declared exception";
  }
  return success();
}
