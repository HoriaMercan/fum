//===- MonadOps.cpp - Monad dialect ops -------------------------*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "fum/Dialect/Monad/IR/MonadOps.h"
#include "fum/Dialect/Monad/IR/MonadDialect.h"

#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/OpImplementation.h"
#include "mlir/IR/SymbolTable.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallPtrSet.h"

using namespace mlir;
using namespace mlir::monad;

/// Parses an optional parenthesized, non-empty list of payload types.
static ParseResult parsePayloadTypes(OpAsmParser &parser,
                                     ArrayAttr &payloadTypes) {
  SmallVector<Attribute> types;
  if (succeeded(parser.parseOptionalLParen())) {
    if (parser.parseCommaSeparatedList([&]() -> ParseResult {
          Type type;
          if (parser.parseType(type))
            return failure();
          types.push_back(TypeAttr::get(type));
          return success();
        }) ||
        parser.parseRParen())
      return failure();
  }
  payloadTypes = parser.getBuilder().getArrayAttr(types);
  return success();
}

/// Prints the payload types in parentheses, or nothing if there are none.
static void printPayloadTypes(OpAsmPrinter &printer, Operation *,
                              ArrayAttr payloadTypes) {
  if (payloadTypes.empty())
    return;
  printer << "(";
  llvm::interleaveComma(payloadTypes.getAsValueRange<TypeAttr>(), printer);
  printer << ")";
}

#define GET_OP_CLASSES
#include "fum/Dialect/Monad/IR/MonadOps.cpp.inc"

//===----------------------------------------------------------------------===//
// MonadDoOp
//===----------------------------------------------------------------------===//

/// Verifies block predecessors and that all terminators belong to Monad.
LogicalResult MonadDoOp::verifyRegions() {
  for (Block &block : llvm::drop_begin(getBody())) {
    if (!block.getUniquePredecessor())
      return emitOpError()
             << "expects every block except the first to have a unique "
                "predecessor";
  }
  for (Block &block : getBody()) {
    if (!isa_and_nonnull<MonadDialect>(block.getTerminator()->getDialect()))
      return emitOpError()
             << "expects every block terminator to belong to the monad dialect";
  }
  return success();
}

//===----------------------------------------------------------------------===//
// MonadBindOp
//===----------------------------------------------------------------------===//

/// Verifies that the input is of the monad of the enclosing `monad.do`, that
/// is, of its result type up to the value types, and that the successor takes
/// one argument of each value type of the input.
LogicalResult MonadBindOp::verify() {
  MonadTypeInterface inputType = getInput().getType();
  MonadTypeInterface resultType = getParentOp().getType();
  if (inputType.cloneWithValueTypes(resultType.getValueTypes()) != resultType)
    return emitOpError() << "expects the input to be of the monad of the "
                            "enclosing monad.do, got "
                         << inputType << " in a monad.do producing "
                         << resultType;

  TypeRange valueTypes = inputType.getValueTypes();
  if (getNext()->getArgumentTypes() != valueTypes)
    return emitOpError() << "expects the successor to take arguments of types ("
                         << valueTypes << ")";
  return success();
}

/// Returns the operands passed to the successor: none are forwarded, and the
/// bind produces one argument of each value type of the input.
SuccessorOperands MonadBindOp::getSuccessorOperands(unsigned index) {
  assert(index == 0 && "invalid successor index");
  return SuccessorOperands(getInput().getType().getValueTypes().size(),
                           MutableOperandRange(getOperation(), 0, 0));
}

//===----------------------------------------------------------------------===//
// MonadYieldOp
//===----------------------------------------------------------------------===//

/// Verifies that the yielded value is of the result type of the enclosing
/// `monad.do`.
LogicalResult MonadYieldOp::verify() {
  Type resultType = getParentOp().getType();
  if (getValue().getType() != resultType)
    return emitOpError() << "expects the yielded value to be of the result "
                            "type of the enclosing monad.do, "
                         << resultType << ", got " << getValue().getType();
  return success();
}

//===----------------------------------------------------------------------===//
// MonadExceptionMakeOp
//===----------------------------------------------------------------------===//

/// Returns the declaration of the exception kind `kind` seen from `op`, or
/// emits an error and returns null.
static MonadExceptionDeclareOp
lookupExceptionKind(Operation *op, SymbolTableCollection &symbolTable,
                    FlatSymbolRefAttr kind) {
  auto declaration =
      symbolTable.lookupNearestSymbolFrom<MonadExceptionDeclareOp>(op, kind);
  if (!declaration)
    op->emitOpError() << "expects " << kind
                      << " to reference a declared exception";
  return declaration;
}

/// Returns the payload types declared by an exception kind.
static SmallVector<Type> getPayloadTypes(MonadExceptionDeclareOp declaration) {
  return llvm::to_vector(
      declaration.getPayloadTypes().getAsValueRange<TypeAttr>());
}

/// Verifies that the kind is declared and that the payload has the declared
/// types.
LogicalResult
MonadExceptionMakeOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  MonadExceptionDeclareOp declaration =
      lookupExceptionKind(*this, symbolTable, getKindAttr());
  if (!declaration)
    return failure();
  SmallVector<Type> payloadTypes = getPayloadTypes(declaration);
  if (TypeRange(getPayload().getTypes()) != TypeRange(payloadTypes))
    return emitOpError() << "expects payload types (" << payloadTypes
                         << ") declared by " << getKindAttr() << ", got ("
                         << getPayload().getTypes() << ")";
  return success();
}

//===----------------------------------------------------------------------===//
// MonadCatchOp
//===----------------------------------------------------------------------===//

/// Parses `%m (, ^ok)? [cases (, default -> ^d)?] attr-dict : type`, where a
/// case is `@k1, ..., @kn -> ^block`.
ParseResult MonadCatchOp::parse(OpAsmParser &parser, OperationState &result) {
  OpAsmParser::UnresolvedOperand input;
  SmallVector<Block *> dests;
  SmallVector<Attribute> caseKinds;
  Builder &builder = parser.getBuilder();
  if (parser.parseOperand(input))
    return failure();
  if (succeeded(parser.parseOptionalComma())) {
    Block *ok;
    if (parser.parseSuccessor(ok))
      return failure();
    dests.push_back(ok);
    result.addAttribute(getHasOkAttrName(result.name), builder.getUnitAttr());
  }
  if (parser.parseLSquare())
    return failure();
  if (failed(parser.parseOptionalRSquare())) {
    while (true) {
      Block *dest;
      if (succeeded(parser.parseOptionalKeyword("default"))) {
        if (parser.parseArrow() || parser.parseSuccessor(dest) ||
            parser.parseRSquare())
          return failure();
        dests.push_back(dest);
        result.addAttribute(getHasDefaultAttrName(result.name),
                            builder.getUnitAttr());
        break;
      }
      SmallVector<Attribute> group;
      do {
        FlatSymbolRefAttr kind;
        if (parser.parseAttribute(kind))
          return failure();
        group.push_back(kind);
      } while (succeeded(parser.parseOptionalComma()));
      if (parser.parseArrow() || parser.parseSuccessor(dest))
        return failure();
      caseKinds.push_back(builder.getArrayAttr(group));
      dests.push_back(dest);
      if (succeeded(parser.parseOptionalRSquare()))
        break;
      if (parser.parseComma())
        return failure();
    }
  }
  result.addAttribute(getCaseKindsAttrName(result.name),
                      builder.getArrayAttr(caseKinds));
  result.addSuccessors(dests);
  Type inputType;
  if (parser.parseOptionalAttrDict(result.attributes) ||
      parser.parseColonType(inputType) ||
      parser.resolveOperand(input, inputType, result.operands))
    return failure();
  return success();
}

/// Prints the catch in the form accepted by `parse`.
void MonadCatchOp::print(OpAsmPrinter &printer) {
  printer << " " << getInput();
  if (Block *ok = getOkDest()) {
    printer << ", ";
    printer.printSuccessor(ok);
  }
  printer << " [";
  bool first = true;
  for (auto [kinds, dest] : llvm::zip(getCaseKinds(), getCaseDests())) {
    if (!first)
      printer << ", ";
    first = false;
    llvm::interleaveComma(cast<ArrayAttr>(kinds), printer,
                          [&](Attribute kind) { printer << kind; });
    printer << " -> ";
    printer.printSuccessor(dest);
  }
  if (Block *dest = getDefaultDest()) {
    if (!first)
      printer << ", ";
    printer << "default -> ";
    printer.printSuccessor(dest);
  }
  printer << "]";
  printer.printOptionalAttrDict(
      (*this)->getAttrs(),
      {getCaseKindsAttrName(), getHasOkAttrName(), getHasDefaultAttrName()});
  printer << " : " << getInput().getType();
}

/// Verifies the shape of the cases, the arguments of the `^ok` and default
/// blocks, and the result type of the enclosing `monad.do` required by the
/// paths that end it.
LogicalResult MonadCatchOp::verify() {
  size_t expectedDests =
      (getHasOk() ? 1 : 0) + getCaseKinds().size() + (getHasDefault() ? 1 : 0);
  if (getDests().size() != expectedDests)
    return emitOpError() << "expects " << expectedDests << " successors, got "
                         << getDests().size();
  llvm::SmallPtrSet<Attribute, 8> seen;
  for (Attribute group : getCaseKinds()) {
    auto kinds = dyn_cast<ArrayAttr>(group);
    if (!kinds || kinds.empty())
      return emitOpError() << "expects every case to list exception kinds";
    for (Attribute kind : kinds) {
      if (!isa<FlatSymbolRefAttr>(kind))
        return emitOpError() << "expects exception kinds, got " << kind;
      if (!seen.insert(kind).second)
        return emitOpError() << "expects every exception kind to be listed "
                                "once, got "
                             << kind << " twice";
    }
  }

  ValueOrExceptionType inputType = getInput().getType();
  if (Block *ok = getOkDest()) {
    if (ok->getArgumentTypes() != inputType.getValueTypes())
      return emitOpError() << "expects the ^ok successor to take arguments of "
                              "types ("
                           << inputType.getValueTypes() << ")";
  }
  if (Block *dest = getDefaultDest()) {
    if (dest->getArgumentTypes() != TypeRange(ExceptionType::get(getContext())))
      return emitOpError() << "expects the default successor to take one "
                              "argument of type !monad.exception";
  }

  MonadTypeInterface resultType = getParentOp().getType();
  if (!getHasOk() && inputType != resultType)
    return emitOpError() << "expects the input to be of the result type of "
                            "the enclosing monad.do without ^ok, "
                         << resultType << ", got " << inputType;
  if (!getHasDefault() && !isa<ValueOrExceptionType>(resultType))
    return emitOpError() << "expects the enclosing monad.do to produce a "
                            "!monad.value_or_exception without default, got "
                         << resultType;
  return success();
}

/// Verifies that the kinds are declared, that the kinds of a case share their
/// payload types, and that the block of a case takes them.
LogicalResult
MonadCatchOp::verifySymbolUses(SymbolTableCollection &symbolTable) {
  for (auto [group, dest] : llvm::zip(getCaseKinds(), getCaseDests())) {
    for (Attribute kind : cast<ArrayAttr>(group)) {
      MonadExceptionDeclareOp declaration = lookupExceptionKind(
          *this, symbolTable, cast<FlatSymbolRefAttr>(kind));
      if (!declaration)
        return failure();
      SmallVector<Type> payloadTypes = getPayloadTypes(declaration);
      if (dest->getArgumentTypes() != TypeRange(payloadTypes))
        return emitOpError()
               << "expects the successor of " << kind
               << " to take its payload types (" << payloadTypes << ")";
    }
  }
  return success();
}

/// Returns the operands passed to a successor: none are forwarded. The catch
/// produces the success values for `^ok`, the payload for a case, and the
/// exception for the default block.
SuccessorOperands MonadCatchOp::getSuccessorOperands(unsigned index) {
  return SuccessorOperands(getDests()[index]->getNumArguments(),
                           MutableOperandRange(getOperation(), 0, 0));
}
