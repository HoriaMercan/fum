//===- ConvertADTToSCF.h - Lower sum types to tags and slots ----*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef FUM_DIALECT_ADT_TRANSFORMS_CONVERTADTTOSCF_H
#define FUM_DIALECT_ADT_TRANSFORMS_CONVERTADTTOSCF_H

#include "fum/Dialect/ADT/IR/ADTTypes.h"
#include "mlir/Transforms/DialectConversion.h"

namespace mlir {
namespace adt {
/// Appends the lowered types of `sum` to `results`: an `i32` tag, then the
/// field types of every case, each lowered by `convertField`.
void convertSumType(
    SumType sum, SmallVectorImpl<Type> &results,
    function_ref<void(Type, SmallVectorImpl<Type> &)> convertField);

/// Adds the patterns that lower the operations of the dialect, and
/// `arith.select`, `ub.poison`, `cf.switch` and casts of sum types, under
/// `converter`, which must lower sums as `convertSumType` does.
void populateADTToSCFConversionPatterns(const TypeConverter &converter,
                                        RewritePatternSet &patterns);
} // namespace adt
} // namespace mlir

#endif // FUM_DIALECT_ADT_TRANSFORMS_CONVERTADTTOSCF_H
