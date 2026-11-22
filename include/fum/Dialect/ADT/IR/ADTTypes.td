//===- ADTTypes.td - ADT dialect types ---------------------*- tablegen -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef ADT_TYPES
#define ADT_TYPES

include "mlir/IR/AttrTypeBase.td"
include "fum/Dialect/ADT/IR/ADTDialect.td"

//===----------------------------------------------------------------------===//
// ADT type definitions
//===----------------------------------------------------------------------===//

/// The list of cases of a sum. The allocator also copies the field types of
/// every case into the storage of the type.
def ADT_SumCaseArrayParameter
    : ArrayRefParameter<"::mlir::adt::SumCase", "cases"> {
  let allocator = [{
    $_dst = ::mlir::adt::SumCase::copyCases($_allocator, $_self);
  }];
}

def ADT_SumType : TypeDef<ADT_Dialect, "Sum"> {
  let mnemonic = "sum";
  let summary = "Finite sum of named cases, each with a list of fields";
  let description = [{
    A value of type `!adt.sum<c1(T1, ..., Tk), c2, ...>` is exactly one of
    the cases `c1`, `c2`, ..., together with one value of each field type of
    that case. It is the coproduct of the products of the field types,
    labeled by the case names.

    ```mlir
    !adt.sum<div_by_zero, overflow>
    !adt.sum<div_by_zero, io(i32), out_of_bounds(index, index)>
    ```

    - A case is a name followed by its field types in parentheses. A case
      without fields is written without parentheses: it has exactly one
      value, like the builtin `none` type.
    - There is at least one case: a sum without cases would have no value.
    - Case names are distinct. They are labels, not symbols: nothing declares
      them, and the same name may appear in unrelated sums.
    - Every alternative is named. A union of types without names, such as
      `!adt.sum<i32, f32>`, is not expressible.
    - Order is not significant: a case is identified by its name, so
      `!adt.sum<a, b>` and `!adt.sum<b, a>` are the same type. The cases are
      kept sorted by name, which is the order in which the type is printed,
      and a case is identified by its position in that order once lowered.
    - Fields may have any type, including another sum. A sum cannot contain
      itself.
  }];
  let parameters = (ins ADT_SumCaseArrayParameter:$cases);
  let skipDefaultBuilders = 1;
  let builders = [
    TypeBuilder<(ins "::llvm::ArrayRef<::mlir::adt::SumCase>":$cases), [{
      ::llvm::SmallVector<::mlir::adt::SumCase> sorted =
          ::mlir::adt::sortCasesByName(cases);
      return $_get($_ctxt, sorted);
    }]>
  ];
  let hasCustomAssemblyFormat = 1;
  let genVerifyDecl = 1;
  let extraClassDeclaration = [{
    /// Returns the position of the case named `name`, if there is one.
    std::optional<unsigned> getCasePosition(::llvm::StringRef name) const;

    /// Returns the case named `name`, if there is one.
    std::optional<SumCase> lookupCase(::llvm::StringRef name) const;

    /// Returns whether every case of this sum is a case of `other`, with the
    /// same field types.
    bool isIncludedIn(SumType other) const;
  }];
}

#endif // ADT_TYPES
