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
include "mlir/Interfaces/CastInterfaces.td"
include "mlir/Interfaces/ControlFlowInterfaces.td"
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
    predecessor, which may branch to it along several edges. Every block must end with a terminator from the monad
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
// Error operations
//===----------------------------------------------------------------------===//

def MonadErrorDeclareOp : Monad_Op<"error.declare", [
    SymbolName,
    SymbolVisibility,
    Symbol,
    HasParent<"::mlir::ModuleOp">]> {
  let summary = "Declares an error and its payload types";
  let description = [{
    Declares the error `@name`, which carries one payload value of each listed
    type. The payload list is omitted when it is empty. The type of the error
    is `!monad.error<@name, P1, ..., Pk>`.

    The declarations of a module are the registry of its errors. Each error
    has a positive tag that identifies it once lowered: the explicit `tag` if
    given, which no other declaration of the module may use, and otherwise
    the next unused tag in the order of the declarations, starting at 1.
    Explicit tags keep the tags of separately compiled modules in agreement.

    ```mlir
    monad.error.declare @div_by_zero
    monad.error.declare @out_of_bounds(index, index) tag 7
    ```
  }];
  let arguments = (ins SymbolNameAttr:$sym_name,
                       TypeArrayAttr:$payloadTypes,
                       OptionalAttr<ConfinedAttr<I32Attr, [IntPositive]>>:$tag,
                       OptionalAttr<StrAttr>:$sym_visibility);
  let assemblyFormat = [{
    $sym_name `` custom<PayloadTypes>($payloadTypes) (`tag` $tag^)? attr-dict
  }];
  let hasVerifier = 1;
}

def MonadErrorThrowOp : Monad_Op<"error.throw", [
    Pure,
    RangedTypesMatchWith<"payload types match the payload types of the result",
                         "result", "payload",
                         "::llvm::cast<::mlir::monad::ErrorType>($_self).getPayloadTypes()">]> {
  let summary = "Creates an error from its payload";
  let description = [{
    Creates the error of the result type, an exception value carrying the
    given payload values. The error is a plain value: a computation fails
    with it once `monad.either.left` puts it, or a union holding it, on the
    left of an either value that is bound or caught.

    ```mlir
    %e = monad.error.throw : !monad.error<@overflow>
    %f = monad.error.throw %i, %n : !monad.error<@out_of_bounds, index, index>
    ```
  }];
  let arguments = (ins Variadic<AnyType>:$payload);
  let results = (outs MonadErrorType:$result);
  let assemblyFormat = "$payload attr-dict `:` qualified(type($result))";
}

def MonadErrorPayloadOp : Monad_Op<"error.payload", [
    Pure,
    RangedTypesMatchWith<"result types match the payload types of the error",
                         "error", "payload",
                         "::llvm::cast<::mlir::monad::ErrorType>($_self).getPayloadTypes()">]> {
  let summary = "Returns the payload of an error";
  let description = [{
    Returns the payload values carried by an error.

    ```mlir
    %i, %n = monad.error.payload %f : !monad.error<@out_of_bounds, index, index>
    ```
  }];
  let arguments = (ins MonadErrorType:$error);
  let results = (outs Variadic<AnyType>:$payload);
  let assemblyFormat = "$error attr-dict `:` qualified(type($error))";
}

def MonadErrorSwitchOp : Monad_Op<"error.switch", [
    Terminator,
    DeclareOpInterfaceMethods<BranchOpInterface>]> {
  let summary = "Branches on the error held by an error or an error union";
  let description = [{
    Branches to the handler of the case that lists the error held by the
    input, an error or an error union; a single error behaves as the union
    of that error. A case is an error type, or an error union for a group of
    errors; its handler takes one argument of the case type. The cases are
    disjoint. The optional `default` case, which comes last, takes the error
    union of the errors that no case lists, and requires at least one such
    error. Without `default`, the cases list every error of the input. The
    successor arguments are produced by the switch, which forwards no
    operands.

    ```mlir
    monad.error.switch %e [!monad.error<@div_by_zero> -> ^division,
                           default -> ^other]
        : !monad.error_union<{!monad.error<@div_by_zero>,
                              !monad.error<@overflow>}>
    ^division(%d: !monad.error<@div_by_zero>):
    ^other(%o: !monad.error_union<{!monad.error<@overflow>}>):
    ```
  }];
  let arguments = (ins AnyTypeOf<[MonadErrorType, MonadErrorUnionType]>:$input,
                       TypeArrayAttr:$caseTypes,
                       UnitAttr:$hasDefault);
  let successors = (successor VariadicSuccessor<AnySuccessor>:$handlers);
  let assemblyFormat = [{
    $input custom<SwitchCases>($caseTypes, $hasDefault, $handlers) attr-dict
    `:` qualified(type($input))
  }];
  let hasVerifier = 1;
  let extraClassDeclaration = [{
    /// Returns the errors of the input: the union, or the union of the error.
    ErrorUnionType getInputErrors();
    /// Returns the handlers of the cases, in the order of the cases.
    ::mlir::SuccessorRange getCaseHandlers();
    /// Returns the handler of `default`, or null without `default`.
    ::mlir::Block *getDefaultHandler();
    /// Returns the errors of the input that no case lists, sorted by name.
    ::llvm::SmallVector<ErrorType> getUnlistedErrors();
  }];
}

//===----------------------------------------------------------------------===//
// Either operations
//===----------------------------------------------------------------------===//

def MonadEitherLeftOp : Monad_Op<"either.left", [
    Pure,
    TypesMatchWith<"value type matches the left type of the result",
                   "result", "value",
                   "::llvm::cast<::mlir::monad::EitherType>($_self).getLeftType()">]> {
  let summary = "Creates a left either value";
  let description = [{
    Creates the left either value carrying the given value.

    ```mlir
    %m = monad.either.left %x : !monad.either<i32, f32>
    ```
  }];
  let arguments = (ins AnyType:$value);
  let results = (outs MonadEitherType:$result);
  let assemblyFormat = "$value attr-dict `:` qualified(type($result))";
}

def MonadEitherBranchOp : Monad_Op<"either.branch", [
    Terminator,
    DeclareOpInterfaceMethods<BranchOpInterface>]> {
  let summary = "Branches on the side of an either value";
  let description = [{
    Branches to `left` with the value of a left, and to `right` with the
    values of a right. The `left` successor takes one argument of the left
    type, and the `right` successor one argument of each value type. These
    arguments are produced by the branch, which forwards no operands.

    ```mlir
    monad.either.branch %m, left ^l, right ^r : !monad.either<i32, f32>
    ^l(%x: i32):
    ^r(%y: f32):
    ```
  }];
  let arguments = (ins MonadEitherType:$input);
  let successors = (successor AnySuccessor:$left, AnySuccessor:$right);
  let assemblyFormat = [{
    $input `,` `left` $left `,` `right` $right attr-dict `:`
    qualified(type($input))
  }];
  let hasVerifier = 1;
}

def MonadEitherCatchOp : Monad_Op<"either.catch", [
    Terminator,
    HasParent<"MonadDoOp">,
    DeclareOpInterfaceMethods<BranchOpInterface>]> {
  let summary = "Handles the left of an either value";
  let description = [{
    Continues the enclosing `monad.do` depending on the side of the input,
    as Haskell's `catchError` does for `Either`:

    - a left branches to `left` with the left value, whatever its type;
    - a right branches to `right` with its values; without `right`, the
      `monad.do` ends with the input, whose type must then be the result
      type of the `monad.do`.

    The successor arguments are produced by the catch, which forwards no
    operands. `monad.error.catch` is the same with the left dispatched on
    its errors.

    ```mlir
    monad.either.catch %m, left ^handler, right ^ok : !monad.either<i32, f32>
    ^handler(%l: i32):
    ^ok(%r: f32):
    ```
  }];
  let arguments = (ins MonadEitherType:$input, UnitAttr:$hasRight);
  let successors = (successor VariadicSuccessor<AnySuccessor>:$dests);
  let hasCustomAssemblyFormat = 1;
  let hasVerifier = 1;
  let extraClassDeclaration = [{
    /// Returns the successor of a left.
    ::mlir::Block *getLeft();
    /// Returns the successor of a right, or null if a right ends the
    /// enclosing monad.do.
    ::mlir::Block *getRight();
  }];
}

//===----------------------------------------------------------------------===//
// Exception operations: either whose left type is an error or an error union
//===----------------------------------------------------------------------===//

def MonadErrorCatchOp : Monad_Op<"error.catch", [
    Terminator,
    HasParent<"MonadDoOp">,
    DeclareOpInterfaceMethods<BranchOpInterface>]> {
  let summary = "Handles the errors of an either value";
  let description = [{
    Continues the enclosing `monad.do` depending on the input, an either
    value whose left type is an error or an error union. A single error
    behaves as the union of that error:

    - a right branches to `^ok` with its values; without `^ok`, the
      `monad.do` ends with the input, whose type must then be the result
      type of the `monad.do`;
    - an error that a case lists branches to the handler of the case, with
      one argument of the case type: an error type, or an error union for a
      group of errors;
    - any other error ends the `monad.do` with that error, which must
      therefore be an error of the left type of the `monad.do`.

    The cases are disjoint, and their errors are errors of the left type of
    the input. The successor arguments are produced by the catch, which
    forwards no operands.

    ```mlir
    monad.error.catch %m, ^ok [!monad.error<@div_by_zero> -> ^recover]
        : !monad.either<!monad.error_union<{!monad.error<@div_by_zero>,
                                            !monad.error<@overflow>}>, i32>
    ^ok(%x: i32):
    ^recover(%e: !monad.error<@div_by_zero>):
    ```
  }];
  let arguments = (ins MonadEitherType:$input, TypeArrayAttr:$caseTypes);
  let successors = (successor VariadicSuccessor<AnySuccessor>:$dests);
  let hasCustomAssemblyFormat = 1;
  let hasVerifier = 1;
  let extraClassDeclaration = [{
    /// Returns the successor of a right, or null if a right ends the
    /// enclosing monad.do.
    ::mlir::Block *getOk();
    /// Returns the handler successors, one per case.
    ::mlir::SuccessorRange getHandlers();
  }];
}

def MonadErrorWidenOp : Monad_Op<"error.widen", [
    Pure,
    DeclareOpInterfaceMethods<CastOpInterface>]> {
  let summary = "Converts an error or an error union to a larger union";
  let description = [{
    Converts an error or an error union to an error union that holds the
    same error, and whose errors include those of the input. The result may
    also be a single error when the input holds only that error.

    ```mlir
    %u = monad.error.widen %e : !monad.error<@a>
        to !monad.error_union<{!monad.error<@a>, !monad.error<@b>}>
    ```
  }];
  let arguments = (ins AnyTypeOf<[MonadErrorType, MonadErrorUnionType]>:$input);
  let results = (outs AnyTypeOf<[MonadErrorType, MonadErrorUnionType]>:$result);
  let assemblyFormat = [{
    $input attr-dict `:` qualified(type($input)) `to` qualified(type($result))
  }];
}

#endif // MONAD_OPS
