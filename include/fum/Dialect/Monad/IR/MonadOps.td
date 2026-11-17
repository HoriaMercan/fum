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
    types. Every block except the first must have a unique predecessor
    operation, which may branch to it through several edges. Every block must end with a terminator from the monad
    dialect.

    How a bind continues depends on the monad. For the maybe monad, binding
    `some` value branches to the next block with the values it carries, and
    binding `none` ends the computation with `none`. For the value-or-error
    monad, binding a success branches to the next block, and binding a failure
    ends the computation with that failure.

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

/// An error type or a union of error types.
def Monad_AnyErrorType : AnyTypeOf<[MonadErrorType, MonadErrorUnionType],
                                   "error or error union type">;

def MonadErrorDeclareOp : Monad_Op<"error.declare", [
    SymbolName,
    SymbolVisibility,
    Symbol,
    HasParent<"::mlir::ModuleOp">]> {
  let summary = "Declares an error and its payload types";
  let description = [{
    Declares the error `@name`, which carries one payload value of each listed
    type. The payload list is omitted when it is empty. The type of the error
    is `!monad.error<@name, P1, ..., Pn>`.

    The declarations of a module are the registry of its errors. Each error
    has a positive tag that identifies it once lowered: the explicit `tag` if
    given, which no other declaration of the module may use, and otherwise
    the next unused tag in the order of the declarations, starting at 1.
    Explicit tags keep the tags of separately compiled modules in agreement.

    ```mlir
    monad.error.declare @div_by_zero
    monad.error.declare @silenceable(i32) tag 7
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
    RangedTypesMatchWith<"payload types match the payload types of the error",
                         "error", "payload",
                         "::llvm::cast<::mlir::monad::ErrorType>($_self).getPayload()">]> {
  let summary = "Creates an error";
  let description = [{
    Creates the error of the result type carrying the given payload, one
    value of each payload type of the error.

    ```mlir
    %e = monad.error.make : !monad.error<@div_by_zero>
    %s = monad.error.make %id : !monad.error<@silenceable, i32>
    ```
  }];
  let arguments = (ins Variadic<AnyType>:$payload);
  let results = (outs MonadErrorType:$error);
  let assemblyFormat = "($payload^)? attr-dict `:` qualified(type($error))";
}

def MonadErrorPayloadOp : Monad_Op<"error.payload", [
    Pure,
    RangedTypesMatchWith<"payload types match the payload types of the error",
                         "error", "payload",
                         "::llvm::cast<::mlir::monad::ErrorType>($_self).getPayload()">]> {
  let summary = "Reads the payload of an error";
  let description = [{
    Returns the payload carried by the error, one value of each payload type
    of the error.

    ```mlir
    %id = monad.error.payload %s : !monad.error<@silenceable, i32>
    ```
  }];
  let arguments = (ins MonadErrorType:$error);
  let results = (outs Variadic<AnyType>:$payload);
  let assemblyFormat = "$error attr-dict `:` qualified(type($error))";
}

//===----------------------------------------------------------------------===//
// Value-or-error operations
//===----------------------------------------------------------------------===//

def MonadThrowOp : Monad_Op<"throw", [Pure]> {
  let summary = "Creates a failure from an error";
  let description = [{
    Creates the failure carrying the given error, which is an error or one
    error of an error union. Every error of the input type must be an error
    of the result type.

    ```mlir
    %f = monad.throw %e : !monad.error<@div_by_zero>
        -> !monad.value_or_error<[i32] throws {!monad.error<@div_by_zero>}>
    ```
  }];
  let arguments = (ins Monad_AnyErrorType:$error);
  let results = (outs MonadValueOrErrorType:$result);
  let assemblyFormat = [{
    $error attr-dict `:` qualified(type($error)) `->` qualified(type($result))
  }];
  let hasVerifier = 1;
}

def MonadWidenOp : Monad_Op<"widen", [
    Pure,
    DeclareOpInterfaceMethods<CastOpInterface>]> {
  let summary = "Widens the errors of a value-or-error value";
  let description = [{
    Returns the input as a value of a value-or-error type with the same value
    types and a superset of its errors.

    ```mlir
    %w = monad.widen %m
        : !monad.value_or_error<[i32] throws {!monad.error<@div_by_zero>}>
        to !monad.value_or_error<[i32] throws {!monad.error<@div_by_zero>,
                                               !monad.error<@overflow>}>
    ```
  }];
  let arguments = (ins MonadValueOrErrorType:$input);
  let results = (outs MonadValueOrErrorType:$result);
  let assemblyFormat = [{
    $input attr-dict `:` qualified(type($input)) `to` qualified(type($result))
  }];
}

def MonadCatchOp : Monad_Op<"catch", [
    Terminator,
    HasParent<"MonadDoOp">,
    DeclareOpInterfaceMethods<BranchOpInterface>]> {
  let summary = "Dispatches on the outcome of a value-or-error value";
  let description = [{
    Continues the enclosing `monad.do` depending on the outcome of the input.

    A success continues to `^ok` with its values bound to the arguments of
    `^ok`. Without `^ok`, a success ends the `monad.do` with the input, whose
    type must then be the result type of the `monad.do`.

    A failure continues to the handler of the case that names its error. A
    case is an error type of the input, or an error union of several of
    them; its handler takes one argument of the case type. No error may be
    named by two cases. The optional `default` case, which must come last,
    takes the error union of the errors of the input that no other case names.
    Errors that no case names leave the `monad.do` unchanged, so they must be
    errors of its result type.

    The handler arguments are produced by the catch, which forwards no
    operands. The same block may be the successor of several cases.

    ```mlir
    monad.catch %m, ^ok [!monad.error<@div_by_zero> -> ^recover,
                         default -> ^rest]
        : !monad.value_or_error<[i32] throws {!monad.error<@div_by_zero>,
                                              !monad.error<@overflow>}>
    ^ok(%value: i32):
    ^recover(%e: !monad.error<@div_by_zero>):
    ^rest(%r: !monad.error_union<{!monad.error<@overflow>}>):
    ```
  }];
  let arguments = (ins
      MonadValueOrErrorType:$input,
      TypeArrayAttr:$cases,
      UnitAttr:$has_ok,
      UnitAttr:$has_default);
  let successors = (successor VariadicSuccessor<AnySuccessor>:$dests);
  let hasCustomAssemblyFormat = 1;
  let hasVerifier = 1;
  let extraClassDeclaration = [{
    /// Returns the successor of a success, or null without `^ok`.
    ::mlir::Block *getOk();
    /// Returns the handlers of the cases, in the order of `cases`.
    ::mlir::SuccessorRange getCaseHandlers();
    /// Returns the handler of `default`, or null without `default`.
    ::mlir::Block *getDefault();
    /// Returns the errors of the input that no case names, sorted by name.
    ::llvm::SmallVector<::mlir::monad::ErrorType> getUnnamedErrors();
  }];
}

#endif // MONAD_OPS
