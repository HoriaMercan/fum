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

def MonadErrorMakeOp : Monad_Op<"error.make", [
    Pure,
    RangedTypesMatchWith<"payload types match the payload types of the result",
                         "result", "payload",
                         "::llvm::cast<::mlir::monad::ErrorType>($_self).getPayloadTypes()">]> {
  let summary = "Creates an error from its payload";
  let description = [{
    Creates the error of the result type carrying the given payload values.

    ```mlir
    %e = monad.error.make : !monad.error<@overflow>
    %f = monad.error.make %i, %n : !monad.error<@out_of_bounds, index, index>
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

def MonadErrorUnionSwitchOp : Monad_Op<"error_union.switch", [
    Terminator,
    DeclareOpInterfaceMethods<BranchOpInterface>]> {
  let summary = "Branches on the member of an error union";
  let description = [{
    Branches to the handler of the case that lists the error held by the
    input. A case is an error type, or an error union for a group of errors;
    its handler takes one argument of the case type. The cases are disjoint,
    and together they list every member of the union. The successor arguments
    are produced by the switch, which forwards no operands.

    ```mlir
    monad.error_union.switch %e [!monad.error<@div_by_zero> -> ^division,
                                 !monad.error<@overflow> -> ^overflow]
        : !monad.error_union<{!monad.error<@div_by_zero>,
                              !monad.error<@overflow>}>
    ^division(%d: !monad.error<@div_by_zero>):
    ^overflow(%o: !monad.error<@overflow>):
    ```
  }];
  let arguments = (ins MonadErrorUnionType:$input, TypeArrayAttr:$caseTypes);
  let successors = (successor VariadicSuccessor<AnySuccessor>:$handlers);
  let assemblyFormat = [{
    $input custom<Cases>($caseTypes, $handlers) attr-dict `:`
    qualified(type($input))
  }];
  let hasVerifier = 1;
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

//===----------------------------------------------------------------------===//
// Exception operations: either whose left type is an error or an error union
//===----------------------------------------------------------------------===//

def MonadEitherThrowOp : Monad_Op<"either.throw", [Pure]> {
  let summary = "Creates an either value that holds an error";
  let description = [{
    Creates the left either value holding the error `error`. The left type
    of the result is that error, or an error union of which it is a member.

    ```mlir
    %m = monad.either.throw %e : !monad.error<@overflow>
        -> !monad.either<!monad.error<@overflow>, i32>
    ```
  }];
  let arguments = (ins MonadErrorType:$error);
  let results = (outs MonadEitherType:$result);
  let assemblyFormat = [{
    $error attr-dict `:` qualified(type($error)) `->` qualified(type($result))
  }];
  let hasVerifier = 1;
}

def MonadEitherCatchOp : Monad_Op<"either.catch", [
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
    monad.either.catch %m, ^ok [!monad.error<@div_by_zero> -> ^recover]
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

def MonadEitherWidenOp : Monad_Op<"either.widen", [
    Pure,
    DeclareOpInterfaceMethods<CastOpInterface>]> {
  let summary = "Widens the errors of an either value";
  let description = [{
    Converts an either value whose left type is an error or an error union
    to an either type with the same value types and more errors. The errors
    of the input must be errors of the left type of the result.

    ```mlir
    %w = monad.either.widen %m
        : !monad.either<!monad.error_union<{!monad.error<@a>}>, i32>
        to !monad.either<!monad.error_union<{!monad.error<@a>,
                                             !monad.error<@b>}>, i32>
    ```
  }];
  let arguments = (ins MonadEitherType:$input);
  let results = (outs MonadEitherType:$result);
  let assemblyFormat = [{
    $input attr-dict `:` qualified(type($input)) `to` qualified(type($result))
  }];
}

#endif // MONAD_OPS
