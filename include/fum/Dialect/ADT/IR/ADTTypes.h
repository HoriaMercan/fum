//===- ADTTypes.h - ADT dialect types ---------------------------*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef FUM_DIALECT_ADT_IR_ADTTYPES_H
#define FUM_DIALECT_ADT_IR_ADTTYPES_H

#include "mlir/IR/BuiltinAttributes.h"
#include "mlir/IR/BuiltinTypes.h"
#include "mlir/IR/TypeSupport.h"
#include "llvm/ADT/Hashing.h"

#include <optional>

namespace mlir {
namespace adt {
/// One case of a sum type: its name and the types of its fields.
struct SumCase {
  /// The name of the case.
  StringAttr name;
  /// The types of the fields of the case, possibly none.
  ArrayRef<Type> fields;

  /// Returns whether both cases have the same name and field types.
  bool operator==(const SumCase &other) const {
    return name == other.name && fields == other.fields;
  }

  /// Copies `cases`, and the field types of every case, into `allocator`.
  static ArrayRef<SumCase> copyCases(TypeStorageAllocator &allocator,
                                     ArrayRef<SumCase> cases);
};

/// Returns `cases` sorted by name, keeping the order of equal names.
SmallVector<SumCase> sortCasesByName(ArrayRef<SumCase> cases);

/// Hashes the name and the field types of `sumCase`.
inline llvm::hash_code hash_value(const SumCase &sumCase) {
  return llvm::hash_combine(
      sumCase.name,
      llvm::hash_combine_range(sumCase.fields.begin(), sumCase.fields.end()));
}
} // namespace adt
} // namespace mlir

#define GET_TYPEDEF_CLASSES
#include "fum/Dialect/ADT/IR/ADTOpsTypes.h.inc"

#endif // FUM_DIALECT_ADT_IR_ADTTYPES_H
