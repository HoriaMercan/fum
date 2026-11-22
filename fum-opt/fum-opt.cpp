//===- fum-opt.cpp ---------------------------------------*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "fum/Dialect/Dep/Interfaces/DepTypeInteraces.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/Dialect/Transform/IR/TransformDialect.h"
#include "mlir/Dialect/UB/IR/UBOps.h"
#include "mlir/IR/BuiltinDialect.h"
#include "mlir/IR/MLIRContext.h"
#include "mlir/InitAllDialects.h"
#include "mlir/InitAllPasses.h"
#include "mlir/Support/FileUtilities.h"
#include "mlir/Tools/mlir-opt/MlirOptMain.h"

#include "fum/Dialect/ADT/IR/ADTDialect.h"
#include "fum/Dialect/ADT/Transforms/Passes.h"
#include "fum/Dialect/Dep/IR/DepDialect.h"
#include "fum/Dialect/Dep/Transforms/Passes.h"
#include "fum/Dialect/Monad/IR/MonadDialect.h"
#include "fum/Dialect/Monad/Transforms/Passes.h"

/// Attach dependent typing interfaces to upstream dialects.
static void registerExternalInterfaces(mlir::DialectRegistry &registry) {
  registry.addExtension(+[](mlir::MLIRContext *ctx,
                            mlir::BuiltinDialect *dialect) {
    mlir::IntegerType::attachInterface<mlir::dep::DepTypeParamInterface>(*ctx);
    mlir::IndexType::attachInterface<mlir::dep::DepTypeParamInterface>(*ctx);
  });
}

int main(int argc, char **argv) {
  mlir::registerAllPasses();
  mlir::adt::registerPasses();
  mlir::dep::registerPasses();
  mlir::monad::registerPasses();

  mlir::DialectRegistry registry;
  registry.insert<mlir::adt::ADTDialect, mlir::dep::DepDialect,
                  mlir::monad::MonadDialect, mlir::arith::ArithDialect,
                  mlir::cf::ControlFlowDialect, mlir::func::FuncDialect,
                  mlir::transform::TransformDialect, mlir::scf::SCFDialect,
                  mlir::ub::UBDialect>();
  registerExternalInterfaces(registry);

  // Add the following to include *all* MLIR Core dialects, or selectively
  // include what you need like above. You only need to register dialects that
  // will be *parsed* by the tool, not the one generated
  // registerAllDialects(registry);

  return mlir::asMainReturnCode(
      mlir::MlirOptMain(argc, argv, "fum optimizer driver\n", registry));
}
