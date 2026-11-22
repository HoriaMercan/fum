//===- ADTOps.td - ADT dialect ops -------------------------*- tablegen -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef ADT_OPS
#define ADT_OPS

include "fum/Dialect/ADT/IR/ADTTypes.td"
include "mlir/Interfaces/SideEffectInterfaces.td"

class ADT_Op<string mnemonic, list<Trait> traits = []> :
    Op<ADT_Dialect, mnemonic, traits>;

//===----------------------------------------------------------------------===//
// Introduction: constructors
//===----------------------------------------------------------------------===//

def ADT_MakeOp : ADT_Op<"make", [Pure]> {
  let summary = "Builds a value of one case of a sum";
  let description = [{
    Builds the value of the case `case_name` of the result sum, from one
    operand per field of that case. This is the constructor of the case, the
    injection of the product of its fields into the sum.

    ```mlir
    %division = adt.make div_by_zero : !adt.sum<div_by_zero, io(i32)>
    %io = adt.make io(%code) : !adt.sum<div_by_zero, io(i32)>
    ```

    The operand types are those of the fields of the case, so they are not
    written. A case without fields takes no operands and no parentheses.
  }];
  let arguments = (ins StrAttr:$case_name, Variadic<AnyType>:$fields);
  let results = (outs ADT_SumType:$result);
  let hasCustomAssemblyFormat = 1;
  let hasVerifier = 1;
}

//===----------------------------------------------------------------------===//
// Elimination: case analysis
//===----------------------------------------------------------------------===//

def ADT_MatchOp : ADT_Op<"match", [RecursiveMemoryEffects]> {
  let summary = "Case analysis on a sum";
  let description = [{
    Runs the region of the case that the input holds, with the fields of
    that case as the arguments of the region, and returns the values that the
    region yields. This is the eliminator of the sum.

    ```mlir
    %result = adt.match %error : !adt.sum<div_by_zero, overflow, io(i32)> -> i32
    case div_by_zero, overflow {
      %zero = arith.constant 0 : i32
      adt.yield %zero : i32
    }
    case io(%code: i32) {
      adt.yield %code : i32
    }
    ```

    - A `case` lists one or more case names of the input, followed by the
      arguments of its region, with the field types of the cases. Several
      names in one `case` form a group: their cases must have the same field
      types, and the region receives the fields of whichever case the input
      holds. A group is only syntax: it creates no type.
    - No case name is listed twice.
    - Without `default`, every case of the input is listed: the match is
      exhaustive.
    - With `default`, at least one case is not listed, and the `default`
      region runs for every case that is not listed. It takes no argument:
      the input is still in scope, with its own type. No type is derived for
      the cases that are left, as in the `DEFAULT` alternative of GHC Core.
    - Every region ends with `adt.yield` of values of the result types.

    The match is a region operation, not a terminator, so it may be used in
    any block, including the blocks of a `monad.do`.
  }];
  let arguments = (ins ADT_SumType:$input,
                       TypedArrayAttrBase<StrArrayAttr,
                                          "groups of case names">:$case_groups);
  let results = (outs Variadic<AnyType>:$results);
  let regions = (region MaxSizedRegion<1>:$defaultRegion,
                        VariadicRegion<SizedRegion<1>>:$caseRegions);
  let hasCustomAssemblyFormat = 1;
  let hasVerifier = 1;
  let hasRegionVerifier = 1;
  let hasCanonicalizer = 1;
  let extraClassDeclaration = [{
    /// Returns the type of the input.
    SumType getInputType() { return getInput().getType(); }

    /// Returns the region that handles the case named `name`: the region of
    /// the group that lists it, or the `default` region. Returns null if
    /// neither exists.
    ::mlir::Region *getRegionForCase(::llvm::StringRef name);

    /// Returns the names of the cases of the input that no group lists, in
    /// input order.
    ::llvm::SmallVector<::llvm::StringRef> getUnlistedCases();
  }];
}

def ADT_YieldOp : ADT_Op<"yield", [Pure, Terminator, HasParent<"MatchOp">]> {
  let summary = "Returns values from a region of adt.match";
  let description = [{
    Ends a region of `adt.match`, whose results become the operands.

    ```mlir
    adt.yield %value : i32
    ```
  }];
  let arguments = (ins Variadic<AnyType>:$values);
  let assemblyFormat = "($values^ `:` type($values))? attr-dict";
}

//===----------------------------------------------------------------------===//
// Coercion: inclusion into a larger sum
//===----------------------------------------------------------------------===//

def ADT_WidenOp : ADT_Op<"widen", [Pure]> {
  let summary = "Views a sum as a sum with at least its cases";
  let description = [{
    Returns the input as a value of a sum that has every case of the input,
    with the same field types, and possibly more cases, in any order. The
    case and the fields are kept. This is the inclusion of a sub-coproduct,
    the only conversion between sums: none is implicit.

    ```mlir
    %wider = adt.widen %error : !adt.sum<overflow> to !adt.sum<div_by_zero, overflow>
    ```

    The result type differs from the input type.
  }];
  let arguments = (ins ADT_SumType:$input);
  let results = (outs ADT_SumType:$result);
  let assemblyFormat = [{
    $input attr-dict `:` qualified(type($input)) `to` qualified(type($result))
  }];
  let hasVerifier = 1;
  let hasFolder = 1;
}

#endif // ADT_OPS
