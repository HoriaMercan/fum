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

//===----------------------------------------------------------------------===//
// Cases of monad.either.catch and monad.error_union.switch
//===----------------------------------------------------------------------===//

/// Parses the cases `[CASE -> ^handler, ...]`, appending the handlers to
/// `handlers`.
static ParseResult parseCases(OpAsmParser &parser, ArrayAttr &caseTypes,
                              SmallVectorImpl<Block *> &handlers) {
  SmallVector<Type> types;
  if (parser.parseCommaSeparatedList(
          OpAsmParser::Delimiter::Square, [&]() -> ParseResult {
            return failure(parser.parseType(types.emplace_back()) ||
                           parser.parseArrow() ||
                           parser.parseSuccessor(handlers.emplace_back()));
          }))
    return failure();
  caseTypes = parser.getBuilder().getTypeArrayAttr(types);
  return success();
}

/// Prints the cases `[CASE -> ^handler, ...]`.
static void printCases(OpAsmPrinter &printer, Operation *, ArrayAttr caseTypes,
                       SuccessorRange handlers) {
  printer << "[";
  llvm::interleaveComma(
      llvm::zip_equal(caseTypes.getAsValueRange<TypeAttr>(), handlers), printer,
      [&](auto entry) {
        printer << std::get<0>(entry) << " -> ";
        printer.printSuccessor(std::get<1>(entry));
      });
  printer << "]";
}

/// Verifies that every case is an error or an error union whose errors are
/// members of `errors`, that the cases are disjoint, and that each handler
/// takes one argument of its case type. Inserts the names of the listed
/// errors into `listed`.
static LogicalResult verifyCases(Operation *op, ErrorUnionType errors,
                                 ArrayAttr caseTypes, SuccessorRange handlers,
                                 llvm::StringSet<> &listed) {
  for (auto [caseType, handler] :
       llvm::zip_equal(caseTypes.getAsValueRange<TypeAttr>(), handlers)) {
    SmallVector<ErrorType> caseErrors;
    if (ErrorType error = dyn_cast<ErrorType>(caseType))
      caseErrors.push_back(error);
    else if (ErrorUnionType group = dyn_cast<ErrorUnionType>(caseType))
      llvm::append_range(caseErrors, group.getErrors());
    else
      return op->emitOpError()
             << "expects every case to be an error or an error union, got "
             << caseType;
    for (ErrorType error : caseErrors) {
      if (!errors.contains(error))
        return op->emitOpError() << "expects the listed error " << error
                                 << " to be a member of " << errors;
      if (!listed.insert(error.getName().getValue()).second)
        return op->emitOpError()
               << "expects disjoint cases, got " << error << " twice";
    }
    if (handler->getArgumentTypes() != TypeRange(caseType))
      return op->emitOpError() << "expects the handler of " << caseType
                               << " to take one argument of that type";
  }
  return success();
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
// MonadErrorUnionSwitchOp
//===----------------------------------------------------------------------===//

/// Verifies that there is one handler per case and that the cases list every
/// member of the input exactly once.
LogicalResult MonadErrorUnionSwitchOp::verify() {
  if (getHandlers().size() != getCaseTypes().size())
    return emitOpError() << "expects one handler per case, got "
                         << getHandlers().size() << " handlers for "
                         << getCaseTypes().size() << " cases";
  ErrorUnionType errors = getInput().getType();
  llvm::StringSet<> listed;
  if (failed(verifyCases(*this, errors, getCaseTypes(), getHandlers(), listed)))
    return failure();
  for (ErrorType error : errors.getErrors())
    if (!listed.contains(error.getName().getValue()))
      return emitOpError() << "expects a case for every member of " << errors
                           << ", got none for " << error;
  return success();
}

/// Returns the operands passed to a handler: none are forwarded, and the
/// switch produces the error, or the group, of the case.
SuccessorOperands
MonadErrorUnionSwitchOp::getSuccessorOperands(unsigned index) {
  assert(index < getHandlers().size() && "invalid successor index");
  return SuccessorOperands(1, MutableOperandRange(getOperation(), 0, 0));
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
// MonadEitherThrowOp
//===----------------------------------------------------------------------===//

/// Verifies that the error is a member of the error union of the result.
LogicalResult MonadEitherThrowOp::verify() {
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
// MonadEitherCatchOp
//===----------------------------------------------------------------------===//

/// Returns the successor of a right, or null if a right ends the enclosing
/// monad.do.
Block *MonadEitherCatchOp::getOk() {
  if (getDests().size() != getCaseTypes().size() + 1)
    return nullptr;
  return getDests().front();
}

/// Returns the handler successors, one per case.
SuccessorRange MonadEitherCatchOp::getHandlers() {
  return getDests().drop_front(getOk() ? 1 : 0);
}

/// Parses `%m (, ^ok)? [CASE -> ^h, ...] attr-dict : T`.
ParseResult MonadEitherCatchOp::parse(OpAsmParser &parser,
                                      OperationState &result) {
  OpAsmParser::UnresolvedOperand input;
  if (parser.parseOperand(input))
    return failure();
  SmallVector<Block *> dests;
  if (succeeded(parser.parseOptionalComma()) &&
      parser.parseSuccessor(dests.emplace_back()))
    return failure();
  ArrayAttr caseTypes;
  Type inputType;
  if (parseCases(parser, caseTypes, dests) ||
      parser.parseOptionalAttrDict(result.attributes) || parser.parseColon() ||
      parser.parseType(inputType) ||
      parser.resolveOperand(input, inputType, result.operands))
    return failure();
  result.addAttribute(getCaseTypesAttrName(result.name), caseTypes);
  result.addSuccessors(dests);
  return success();
}

/// Prints `%m (, ^ok)? [CASE -> ^h, ...] attr-dict : T`.
void MonadEitherCatchOp::print(OpAsmPrinter &printer) {
  printer << " " << getInput();
  if (Block *ok = getOk()) {
    printer << ", ";
    printer.printSuccessor(ok);
  }
  printer << " ";
  printCases(printer, *this, getCaseTypes(), getHandlers());
  printer.printOptionalAttrDict((*this)->getAttrs(), {getCaseTypesAttrName()});
  printer << " : " << getInput().getType();
}

/// Verifies the catch against its input and the enclosing `monad.do`: the
/// cases are disjoint errors or error groups of the input, each handler takes
/// one argument of its case type, `^ok` takes the value types, and every error
/// that is not caught is a member of the error union of the `monad.do`.
LogicalResult MonadEitherCatchOp::verify() {
  size_t caseCount = getCaseTypes().size();
  if (getDests().size() != caseCount && getDests().size() != caseCount + 1)
    return emitOpError() << "expects one successor per case, and optionally "
                            "an ok successor before them, got "
                         << getDests().size() << " successors for " << caseCount
                         << " cases";

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
  if (failed(verifyCases(*this, inputErrors, getCaseTypes(), getHandlers(),
                         caught)))
    return failure();
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
SuccessorOperands MonadEitherCatchOp::getSuccessorOperands(unsigned index) {
  assert(index < getDests().size() && "invalid successor index");
  unsigned produced =
      (index == 0 && getOk()) ? getInput().getType().getValueTypes().size() : 1;
  return SuccessorOperands(produced, MutableOperandRange(getOperation(), 0, 0));
}

//===----------------------------------------------------------------------===//
// MonadEitherWidenOp
//===----------------------------------------------------------------------===//

/// Returns whether the input and the result are either types with the same
/// value types whose left types are error unions, the first a subset of the
/// second.
bool MonadEitherWidenOp::areCastCompatible(TypeRange inputs,
                                           TypeRange outputs) {
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
