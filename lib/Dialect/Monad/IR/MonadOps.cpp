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
#include "mlir/IR/OpImplementation.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/StringSet.h"

using namespace mlir;
using namespace mlir::monad;

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
// MonadEitherBranchOp
//===----------------------------------------------------------------------===//

/// Verifies that the left successor takes one argument of the left type and
/// the right successor one argument of each value type.
LogicalResult MonadEitherBranchOp::verify() {
  EitherType inputType = getInput().getType();
  if (getLeft()->getArgumentTypes() != TypeRange(inputType.getLeftType()))
    return emitOpError() << "expects the left successor to take one argument "
                            "of type "
                         << inputType.getLeftType();
  if (getRight()->getArgumentTypes() != TypeRange(inputType.getValueTypes()))
    return emitOpError()
           << "expects the right successor to take arguments of types ("
           << inputType.getValueTypes() << ")";
  return success();
}

/// Returns the operands passed to a successor: none are forwarded, and the
/// branch produces the successor arguments.
SuccessorOperands MonadEitherBranchOp::getSuccessorOperands(unsigned index) {
  assert(index < 2 && "invalid successor index");
  unsigned produced =
      index == 0 ? 1 : getInput().getType().getValueTypes().size();
  return SuccessorOperands(produced, MutableOperandRange(getOperation(), 0, 0));
}

//===----------------------------------------------------------------------===//
// MonadThrowOp
//===----------------------------------------------------------------------===//

/// Verifies that the error is a member of the error union of the result.
LogicalResult MonadThrowOp::verify() {
  ErrorUnionType errors = getResult().getType().getErrorUnion();
  if (!errors)
    return emitOpError() << "expects the left type of the result to be an "
                            "error union";
  if (!errors.contains(getError().getType()))
    return emitOpError() << "expects " << getError().getType()
                         << " to be a member of " << errors;
  return success();
}

//===----------------------------------------------------------------------===//
// MonadCatchOp
//===----------------------------------------------------------------------===//

/// Returns the successor of a right, or null if a right ends the enclosing
/// monad.do.
Block *MonadCatchOp::getOk() {
  if (getDests().size() == getCaseTypes().size())
    return nullptr;
  return getDests().front();
}

/// Returns the handler successors, one per case.
SuccessorRange MonadCatchOp::getHandlers() {
  return getDests().drop_front(getDests().size() - getCaseTypes().size());
}

/// Parses `%m (, ^ok)? [CASE -> ^h, ...] attr-dict : T`.
ParseResult MonadCatchOp::parse(OpAsmParser &parser, OperationState &result) {
  OpAsmParser::UnresolvedOperand input;
  if (parser.parseOperand(input))
    return failure();
  SmallVector<Block *> dests;
  if (succeeded(parser.parseOptionalComma())) {
    Block *ok;
    if (parser.parseSuccessor(ok))
      return failure();
    dests.push_back(ok);
  }
  SmallVector<Type> caseTypes;
  if (parser.parseCommaSeparatedList(
          OpAsmParser::Delimiter::Square, [&]() -> ParseResult {
            Type caseType;
            Block *handler;
            if (parser.parseType(caseType) || parser.parseArrow() ||
                parser.parseSuccessor(handler))
              return failure();
            caseTypes.push_back(caseType);
            dests.push_back(handler);
            return success();
          }))
    return failure();
  Type inputType;
  if (parser.parseOptionalAttrDict(result.attributes) || parser.parseColon() ||
      parser.parseType(inputType) ||
      parser.resolveOperand(input, inputType, result.operands))
    return failure();
  result.addAttribute(getCaseTypesAttrName(result.name),
                      parser.getBuilder().getTypeArrayAttr(caseTypes));
  result.addSuccessors(dests);
  return success();
}

/// Prints `%m (, ^ok)? [CASE -> ^h, ...] attr-dict : T`.
void MonadCatchOp::print(OpAsmPrinter &printer) {
  printer << " " << getInput();
  if (Block *ok = getOk()) {
    printer << ", ";
    printer.printSuccessor(ok);
  }
  printer << " [";
  llvm::interleaveComma(
      llvm::zip_equal(getCaseTypes().getAsValueRange<TypeAttr>(),
                      getHandlers()),
      printer, [&](auto entry) {
        printer << std::get<0>(entry) << " -> ";
        printer.printSuccessor(std::get<1>(entry));
      });
  printer << "]";
  printer.printOptionalAttrDict((*this)->getAttrs(), {getCaseTypesAttrName()});
  printer << " : " << getInput().getType();
}

/// Verifies the catch against its input and the enclosing `monad.do`: the
/// cases are disjoint errors or error groups of the input, each handler takes
/// one argument of its case type, `^ok` takes the value types, and every error
/// that is not caught is a member of the error union of the `monad.do`.
LogicalResult MonadCatchOp::verify() {
  EitherType inputType = getInput().getType();
  ErrorUnionType inputErrors = inputType.getErrorUnion();
  if (!inputErrors)
    return emitOpError()
           << "expects the left type of the input to be an error union";
  EitherType doType = dyn_cast<EitherType>(getParentOp().getType());
  ErrorUnionType doErrors = doType ? doType.getErrorUnion() : nullptr;
  if (!doErrors)
    return emitOpError() << "expects the enclosing monad.do to produce an "
                            "either value whose left type is an error union";

  if (Block *ok = getOk()) {
    if (ok->getArgumentTypes() != TypeRange(inputType.getValueTypes()))
      return emitOpError()
             << "expects the ok successor to take arguments of types ("
             << inputType.getValueTypes() << ")";
  } else if (inputType != doType) {
    return emitOpError() << "expects the input to be of the result type of "
                            "the enclosing monad.do without an ok successor, "
                         << doType << ", got " << inputType;
  }

  llvm::StringSet<> caught;
  for (auto [caseType, handler] : llvm::zip_equal(
           getCaseTypes().getAsValueRange<TypeAttr>(), getHandlers())) {
    SmallVector<ErrorType> caseErrors;
    if (ErrorType error = dyn_cast<ErrorType>(caseType))
      caseErrors.push_back(error);
    else if (ErrorUnionType group = dyn_cast<ErrorUnionType>(caseType))
      llvm::append_range(caseErrors, group.getErrors());
    else
      return emitOpError() << "expects every case to be an error or an error "
                              "union, got "
                           << caseType;
    for (ErrorType error : caseErrors) {
      if (!inputErrors.contains(error))
        return emitOpError() << "expects the caught error " << error
                             << " to be a member of " << inputErrors;
      if (!caught.insert(error.getName().getValue()).second)
        return emitOpError()
               << "expects disjoint cases, got " << error << " twice";
    }
    if (handler->getArgumentTypes() != TypeRange(caseType))
      return emitOpError() << "expects the handler of " << caseType
                           << " to take one argument of that type";
  }

  for (ErrorType error : inputErrors.getErrors())
    if (!caught.contains(error.getName().getValue()) &&
        !doErrors.contains(error))
      return emitOpError() << "expects the uncaught error " << error
                           << " to be a member of " << doErrors
                           << " of the enclosing monad.do";
  return success();
}

/// Returns the operands passed to a successor: none are forwarded, and the
/// catch produces the values of a right for `^ok` and the error for a
/// handler.
SuccessorOperands MonadCatchOp::getSuccessorOperands(unsigned index) {
  assert(index < getDests().size() && "invalid successor index");
  unsigned produced =
      (index == 0 && getOk()) ? getInput().getType().getValueTypes().size() : 1;
  return SuccessorOperands(produced, MutableOperandRange(getOperation(), 0, 0));
}

//===----------------------------------------------------------------------===//
// MonadWidenOp
//===----------------------------------------------------------------------===//

/// Returns whether the input and the result are either types with the same
/// value types whose left types are error unions, the first a subset of the
/// second.
bool MonadWidenOp::areCastCompatible(TypeRange inputs, TypeRange outputs) {
  if (inputs.size() != 1 || outputs.size() != 1)
    return false;
  EitherType input = dyn_cast<EitherType>(inputs.front());
  EitherType output = dyn_cast<EitherType>(outputs.front());
  if (!input || !output || input.getValueTypes() != output.getValueTypes())
    return false;
  ErrorUnionType inputErrors = input.getErrorUnion();
  ErrorUnionType outputErrors = output.getErrorUnion();
  return inputErrors && outputErrors && inputErrors.isSubsetOf(outputErrors);
}
