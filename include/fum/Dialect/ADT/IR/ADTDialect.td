//===- ADTDialect.td - Algebraic data type dialect ---------*- tablegen -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef ADT_DIALECT
#define ADT_DIALECT

include "mlir/IR/OpBase.td"

//===----------------------------------------------------------------------===//
// ADT dialect definition.
//===----------------------------------------------------------------------===//

def ADT_Dialect : Dialect {
  let name = "adt";
  let summary = "Finite sum types and pattern matching on them";
  let description = [{
    This dialect provides finite, structural sum types and the operations
    that introduce and eliminate their values. It knows nothing about monads
    or errors: an error set is one use of a sum, as the Left of an Either.

    In type-theoretic terms, `!adt.sum<c1(T11, ..., T1m), ..., cn(Tn1, ...)>`
    is the labeled coproduct `c1 : T11 × ... × T1m + ... + cn : Tn1 × ...`:
    a value is exactly one case together with one value of each of its field
    types. The dialect has one introduction form, `adt.make` (a constructor),
    one elimination form, `adt.match` (case analysis), and one coercion,
    `adt.widen` (the inclusion of a sum into a sum with more cases).

    The sums are structural: two sums with the same cases in the same order
    are the same type, and nothing is declared. They are not recursive, since
    a structural type cannot refer to itself.
  }];
  let cppNamespace = "::mlir::adt";

  let useDefaultTypePrinterParser = 1;
  let extraClassDeclaration = [{
    /// Registers the types of the dialect.
    void registerTypes();
  }];
}

#endif // ADT_DIALECT
