//===- MonadOps.td - Monad dialect ops ---------------------*- tablegen -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef MONAD_OPS
#define MONAD_OPS

include "fum/Dialect/Monad/IR/MonadTypes.td"
include "mlir/Interfaces/ControlFlowInterfaces.td"
include "mlir/IR/SymbolInterfaces.td"
include "mlir/Interfaces/SideEffectInterfaces.td"

//===----------------------------------------------------------------------===//
// Operations common to all monads
//===----------------------------------------------------------------------===//

def MonadReturnOp : Monad_Op<"return", [
    Pure,
    RangedTypesMatchWith<"value types match the value types of the result",
                         "result", "values",
                         "::llvm::cast<::mlir::monad::MonadTypeInterface>($_self).getValueTypes()">]> {
  let summary = "Wraps values into a monadic value";
  let description = [{
    Creates a monadic value from one value of each value type of the result,
    the `return` (or `pure`) of the monad. For the maybe monad, this is
    `some` value carrying the values.

    ```mlir
    %m = monad.return %a, %b : !monad.maybe<i32, f32>
    ```
  }];
  let arguments = (ins Variadic<AnyType>:$values);
  let results = (outs MonadTypeInterface:$result);
  let assemblyFormat = "$values attr-dict `:` qualified(type($result))";
}

def MonadDoOp : Monad_Op<"do", [RecursiveMemoryEffects]> {
  let summary = "Sequences monadic computations";
  let description = [{
    Runs its region, a sequence of monadic computations in the style of
    Haskell's do-notation, and produces the monadic value it yields. Blocks
    are continuations: `monad.bind` ends a block by binding the values of a
    monadic value to the arguments of the next block, and `monad.yield` ends
    the computation with its result. Every value bound in the region is of the
    same monad as the result: its type is the result type up to the value
    types. Every block except the first must have a unique
    predecessor, which may reach it through several edges. Every block must end with a terminator from the monad
    dialect.

    How a bind continues depends on the monad. For the maybe monad, binding
    `some` value branches to the next block with the values it carries, and
    binding `none` ends the computation with `none`.

    Because a bind may leave the region, this operation does not implement
    `RegionBranchOpInterface`, and data-flow analyses treat its result
    conservatively.

    ```mlir
    %r = monad.do : !monad.maybe<f32> {
      monad.bind %m, ^next : !monad.maybe<i32>
    ^next(%x: i32):
      %y = arith.sitofp %x : i32 to f32
      %ok = monad.return %y : !monad.maybe<f32>
      monad.yield %ok : !monad.maybe<f32>
    }
    ```
  }];
  let results = (outs MonadTypeInterface:$result);
  let regions = (region MinSizedRegion<1>:$body);
  let hasRegionVerifier = 1;
  let assemblyFormat = "attr-dict `:` qualified(type($result)) $body";
}

def MonadBindOp : Monad_Op<"bind", [
    Terminator,
    HasParent<"MonadDoOp">,
    DeclareOpInterfaceMethods<BranchOpInterface>]> {
  let summary = "Binds the values of a monadic value to the next block";
  let description = [{
    Continues the enclosing `monad.do` with the values of the input bound to
    the arguments of the successor. The successor takes one argument
    of each value type of the input. These arguments are produced by the bind,
    which forwards no operands.

    ```mlir
    monad.bind %m, ^next : !monad.maybe<i32, f32>
    ^next(%a: i32, %b: f32):
    ```
  }];
  let arguments = (ins MonadTypeInterface:$input);
  let successors = (successor AnySuccessor:$next);
  let assemblyFormat = [{
    $input `,` $next attr-dict `:` qualified(type($input))
  }];
  let hasVerifier = 1;
}

def MonadYieldOp : Monad_Op<"yield", [
    Pure,
    Terminator,
    HasParent<"MonadDoOp">]> {
  let summary = "Ends a monadic computation with its result";
  let description = [{
    Ends the region of the enclosing `monad.do`, whose result becomes the
    yielded value.

    ```mlir
    monad.yield %m : !monad.maybe<f32>
    ```
  }];
  let arguments = (ins MonadTypeInterface:$value);
  let assemblyFormat = "$value attr-dict `:` qualified(type($value))";
  let hasVerifier = 1;
}

//===----------------------------------------------------------------------===//
// Maybe operations
//===----------------------------------------------------------------------===//

def MonadMaybeNoneOp : Monad_Op<"maybe.none", [Pure]> {
  let summary = "Creates the maybe value that carries no value";
  let description = [{
    Creates `none`, the maybe value that carries no value.

    ```mlir
    %m = monad.maybe.none : !monad.maybe<i32>
    ```
  }];
  let results = (outs MonadMaybeType:$result);
  let assemblyFormat = "attr-dict `:` qualified(type($result))";
}

//===----------------------------------------------------------------------===//
// Value-or-exception operations
//===----------------------------------------------------------------------===//

def MonadExceptionDeclareOp : Monad_Op<"exception.declare", [
    SymbolName,
    SymbolVisibility,
    Symbol,
    HasParent<"::mlir::ModuleOp">]> {
  let summary = "Declares an exception kind and its payload types";
  let description = [{
    Declares the exception kind `@name`, whose exceptions carry one payload
    value of each listed type. The payload list is omitted when it is empty.

    ```mlir
    monad.exception.declare @div_by_zero
    monad.exception.declare @io(i32)
    ```
  }];
  let arguments = (ins SymbolNameAttr:$sym_name,
                       TypeArrayAttr:$payloadTypes,
                       OptionalAttr<StrAttr>:$sym_visibility);
  let assemblyFormat = [{
    $sym_name `` custom<PayloadTypes>($payloadTypes) attr-dict
  }];
}

def MonadExceptionMakeOp : Monad_Op<"exception.make", [
    Pure,
    DeclareOpInterfaceMethods<SymbolUserOpInterface>]> {
  let summary = "Creates an exception of a declared kind";
  let description = [{
    Creates an exception of kind `@kind` carrying the payload values, whose
    types must be the payload types declared for the kind.

    ```mlir
    %e = monad.exception.make @div_by_zero
    %f = monad.exception.make @io(%code) : (i32)
    ```
  }];
  let arguments = (ins FlatSymbolRefAttr:$kind, Variadic<AnyType>:$payload);
  let results = (outs MonadExceptionType:$result);
  let assemblyFormat = [{
    $kind (`(` $payload^ `)` `:` `(` type($payload) `)`)? attr-dict
  }];
}

def MonadThrowOp : Monad_Op<"throw", [Pure]> {
  let summary = "Creates a failure carrying an exception";
  let description = [{
    Creates the failure of the value-or-exception monad that carries the
    exception. Throwing a caught exception again re-throws it unchanged.

    ```mlir
    %m = monad.throw %e : !monad.value_or_exception<i32>
    ```
  }];
  let arguments = (ins MonadExceptionType:$exception);
  let results = (outs MonadValueOrExceptionType:$result);
  let assemblyFormat = "$exception attr-dict `:` qualified(type($result))";
}

def MonadCatchOp : Monad_Op<"catch", [
    Terminator,
    HasParent<"MonadDoOp">,
    DeclareOpInterfaceMethods<SymbolUserOpInterface>,
    DeclareOpInterfaceMethods<BranchOpInterface>]> {
  let summary = "Dispatches a value-or-exception value on its exception kind";
  let description = [{
    Continues the enclosing `monad.do` depending on the input:

    - on success, with the optional `^ok` block, which takes one argument of
      each value type of the input; without `^ok`, the `monad.do` ends with
      the input, whose type must then be the result type of the `monad.do`;
    - on a failure whose kind is listed in a case, with the block of the case.
      A case lists one or more kinds, which share their payload types; its
      block takes one argument of each payload type;
    - on any other failure, with the `default` block if present, which takes
      the exception; otherwise the `monad.do` ends with the failure (an
      implicit re-throw), so its result type must be a value-or-exception
      type.

    Every kind is declared and listed at most once.

    ```mlir
    monad.catch %m, ^ok [@a, @b -> ^ab, @c -> ^c, default -> ^other]
        : !monad.value_or_exception<i32>
    monad.catch %m [@a -> ^recover] : !monad.value_or_exception<i32>
    ```
  }];
  let arguments = (ins MonadValueOrExceptionType:$input,
                       ArrayAttr:$caseKinds,
                       UnitAttr:$hasOk,
                       UnitAttr:$hasDefault);
  let successors = (successor VariadicSuccessor<AnySuccessor>:$dests);
  let hasCustomAssemblyFormat = 1;
  let hasVerifier = 1;
  let extraClassDeclaration = [{
    /// Returns the case blocks, one per group of kinds in `caseKinds`.
    ::mlir::SuccessorRange getCaseDests() {
      return getDests().drop_front(getHasOk() ? 1 : 0)
          .take_front(getCaseKinds().size());
    }
    /// Returns the default block, or null if there is none.
    ::mlir::Block *getDefaultDest() {
      return getHasDefault() ? getDests().back() : nullptr;
    }
    /// Returns the `^ok` block, or null if there is none.
    ::mlir::Block *getOkDest() {
      return getHasOk() ? getDests().front() : nullptr;
    }
  }];
}

#endif // MONAD_OPS
