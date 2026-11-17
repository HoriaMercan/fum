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
#include "mlir/IR/SymbolTable.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/StringSet.h"

using namespace mlir;
using namespace mlir::monad;

//===----------------------------------------------------------------------===//
// Cases of monad.error.catch and monad.error.switch
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
/// members of `errors`, the errors of `errorsType`, that the cases are
/// disjoint, and that each handler takes one argument of its case type.
/// Inserts the names of the listed errors into `listed`.
static LogicalResult verifyCases(Operation *op, Type errorsType,
                                 ErrorUnionType errors, ArrayAttr caseTypes,
                                 SuccessorRange handlers,
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
                                 << " to be an error of " << errorsType;
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

/// Parses the cases of `monad.error.switch`: `[CASE -> ^handler, ...]`,
/// optionally ending with `default -> ^handler`.
static ParseResult parseSwitchCases(OpAsmParser &parser, ArrayAttr &caseTypes,
                                    UnitAttr &hasDefault,
                                    SmallVectorImpl<Block *> &handlers) {
  SmallVector<Type> types;
  if (parser.parseCommaSeparatedList(
          OpAsmParser::Delimiter::Square, [&]() -> ParseResult {
            if (hasDefault)
              return parser.emitError(parser.getCurrentLocation(),
                                      "expects the default case to be last");
            if (succeeded(parser.parseOptionalKeyword("default"))) {
              hasDefault = parser.getBuilder().getUnitAttr();
            } else if (parser.parseType(types.emplace_back())) {
              return failure();
            }
            return failure(parser.parseArrow() ||
                           parser.parseSuccessor(handlers.emplace_back()));
          }))
    return failure();
  caseTypes = parser.getBuilder().getTypeArrayAttr(types);
  return success();
}

/// Prints the cases of `monad.error.switch`, with the default case last.
static void printSwitchCases(OpAsmPrinter &printer, Operation *,
                             ArrayAttr caseTypes, UnitAttr hasDefault,
                             SuccessorRange handlers) {
  printer << "[";
  llvm::interleaveComma(
      llvm::zip(caseTypes.getAsValueRange<TypeAttr>(), handlers), printer,
      [&](auto entry) {
        printer << std::get<0>(entry) << " -> ";
        printer.printSuccessor(std::get<1>(entry));
      });
  if (hasDefault && handlers.size() == caseTypes.size() + 1) {
    if (!caseTypes.empty())
      printer << ", ";
    printer << "default -> ";
    printer.printSuccessor(handlers.back());
  }
  printer << "]";
}

#define GET_OP_CLASSES
#include "fum/Dialect/Monad/IR/MonadOps.cpp.inc"

//===----------------------------------------------------------------------===//
// Error declarations
//===----------------------------------------------------------------------===//

/// Verifies that no earlier declaration of the module uses the explicit tag of
/// this declaration.
LogicalResult MonadErrorDeclareOp::verify() {
  std::optional<uint32_t> tag = getTag();
  if (!tag)
    return success();
  for (Operation &op : *getOperation()->getBlock()) {
    if (&op == getOperation())
      break;
    MonadErrorDeclareOp other = dyn_cast<MonadErrorDeclareOp>(op);
    if (other && other.getTag() == tag)
      return emitOpError() << "expects a tag that no other error uses, got "
                           << *tag << ", the tag of " << other.getSymNameAttr();
  }
  return success();
}

/// Returns the tag of every error declared in `module`, by error name: the
/// explicit tag of the declaration, or otherwise the next tag that no
/// explicit tag uses, in the order of the declarations, starting at 1.
llvm::DenseMap<StringAttr, int32_t> mlir::monad::getErrorTags(ModuleOp module) {
  llvm::DenseSet<int32_t> explicitTags;
  for (MonadErrorDeclareOp declaration : module.getOps<MonadErrorDeclareOp>())
    if (std::optional<uint32_t> tag = declaration.getTag())
      explicitTags.insert(*tag);
  llvm::DenseMap<StringAttr, int32_t> tags;
  int32_t next = 1;
  for (MonadErrorDeclareOp declaration : module.getOps<MonadErrorDeclareOp>()) {
    if (std::optional<uint32_t> tag = declaration.getTag()) {
      tags[declaration.getSymNameAttr()] = *tag;
      continue;
    }
    while (explicitTags.contains(next))
      ++next;
    tags[declaration.getSymNameAttr()] = next++;
  }
  return tags;
}

/// Verifies every error type that `op` uses, in its operand and result types
/// and in its type attributes, against its declaration: the declaration must
/// exist and have the payload types of the error type.
static LogicalResult verifyErrorSymbols(Operation *op,
                                        SymbolTableCollection &symbolTable) {
  LogicalResult result = success();
  auto verifyError = [&](ErrorType error) {
    if (failed(result))
      return;
    MonadErrorDeclareOp declaration =
        symbolTable.lookupNearestSymbolFrom<MonadErrorDeclareOp>(
            op, error.getName());
    if (!declaration) {
      result = op->emitOpError()
               << "expects " << error.getName() << " to reference a declared "
               << "error";
      return;
    }
    if (TypeRange(error.getPayloadTypes()) !=
        TypeRange(llvm::to_vector(
            declaration.getPayloadTypes().getAsValueRange<TypeAttr>())))
      result = op->emitOpError()
               << "expects the payload types of " << error
               << " to be the payload types declared by " << error.getName();
  };
  for (Type type : op->getOperandTypes())
    type.walk(verifyError);
  for (Type type : op->getResultTypes())
    type.walk(verifyError);
  op->getAttrDictionary().walk(verifyError);
  return result;
}

/// Defines `verifySymbolUses` of the operation `OpClass` as the verification
/// of the error types it uses.
#define MONAD_VERIFY_ERROR_SYMBOLS(OpClass)                                    \
  LogicalResult OpClass::verifySymbolUses(                                     \
      SymbolTableCollection &symbolTable) {                                    \
    return verifyErrorSymbols(getOperation(), symbolTable);                    \
  }
MONAD_VERIFY_ERROR_SYMBOLS(MonadReturnOp)
MONAD_VERIFY_ERROR_SYMBOLS(MonadDoOp)
MONAD_VERIFY_ERROR_SYMBOLS(MonadBindOp)
MONAD_VERIFY_ERROR_SYMBOLS(MonadYieldOp)
MONAD_VERIFY_ERROR_SYMBOLS(MonadMaybeNoneOp)
MONAD_VERIFY_ERROR_SYMBOLS(MonadErrorDeclareOp)
MONAD_VERIFY_ERROR_SYMBOLS(MonadErrorPayloadOp)
MONAD_VERIFY_ERROR_SYMBOLS(MonadErrorSwitchOp)
MONAD_VERIFY_ERROR_SYMBOLS(MonadEitherLeftOp)
MONAD_VERIFY_ERROR_SYMBOLS(MonadEitherBranchOp)
MONAD_VERIFY_ERROR_SYMBOLS(MonadEitherCatchOp)
MONAD_VERIFY_ERROR_SYMBOLS(MonadErrorThrowOp)
MONAD_VERIFY_ERROR_SYMBOLS(MonadErrorCatchOp)
MONAD_VERIFY_ERROR_SYMBOLS(MonadErrorWidenOp)
#undef MONAD_VERIFY_ERROR_SYMBOLS

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
// MonadErrorSwitchOp
//===----------------------------------------------------------------------===//

/// Returns the errors of the input: the union, or the union of the error.
ErrorUnionType MonadErrorSwitchOp::getInputErrors() {
  Type type = getInput().getType();
  if (ErrorType error = dyn_cast<ErrorType>(type))
    return ErrorUnionType::get(getContext(), {error});
  return cast<ErrorUnionType>(type);
}

/// Returns the handlers of the cases, in the order of the cases.
SuccessorRange MonadErrorSwitchOp::getCaseHandlers() {
  return getHandlers().take_front(getCaseTypes().size());
}

/// Returns the handler of `default`, or null without `default`.
Block *MonadErrorSwitchOp::getDefaultHandler() {
  return getHasDefault() ? getHandlers().back() : nullptr;
}

/// Returns the errors of the input that no case lists, sorted by name.
SmallVector<ErrorType> MonadErrorSwitchOp::getUnlistedErrors() {
  llvm::StringSet<> listed;
  for (Type caseType : getCaseTypes().getAsValueRange<TypeAttr>()) {
    if (ErrorType error = dyn_cast<ErrorType>(caseType))
      listed.insert(error.getName().getValue());
    else if (ErrorUnionType group = dyn_cast<ErrorUnionType>(caseType))
      for (ErrorType error : group.getErrors())
        listed.insert(error.getName().getValue());
  }
  SmallVector<ErrorType> unlisted;
  for (ErrorType error : getInputErrors().getErrors())
    if (!listed.contains(error.getName().getValue()))
      unlisted.push_back(error);
  return unlisted;
}

/// Verifies the cases against the input, and that `default` takes the union
/// of the errors that no case lists, or that, without `default`, the cases
/// list every error of the input.
LogicalResult MonadErrorSwitchOp::verify() {
  size_t expected = getCaseTypes().size() + (getHasDefault() ? 1 : 0);
  if (getHandlers().size() != expected)
    return emitOpError() << "expects one handler per case, got "
                         << getHandlers().size() << " handlers for " << expected
                         << " cases";
  llvm::StringSet<> listed;
  if (failed(verifyCases(*this, getInput().getType(), getInputErrors(),
                         getCaseTypes(), getCaseHandlers(), listed)))
    return failure();
  SmallVector<ErrorType> unlisted = getUnlistedErrors();
  Block *defaultHandler = getDefaultHandler();
  if (!defaultHandler) {
    if (!unlisted.empty())
      return emitOpError() << "expects a case for every error of "
                           << getInput().getType() << ", got none for "
                           << unlisted.front();
    return success();
  }
  if (unlisted.empty())
    return emitOpError() << "expects the default case to receive at least one "
                            "error that no case lists";
  ErrorUnionType rest = ErrorUnionType::get(getContext(), unlisted);
  if (defaultHandler->getArgumentTypes() != TypeRange(rest))
    return emitOpError() << "expects the default handler to take one argument "
                            "of type "
                         << rest;
  return success();
}

/// Returns the operands passed to a handler: none are forwarded, and the
/// switch produces the error, or the group, of the case.
SuccessorOperands MonadErrorSwitchOp::getSuccessorOperands(unsigned index) {
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
// MonadEitherCatchOp
//===----------------------------------------------------------------------===//

/// Returns the successor of a left.
Block *MonadEitherCatchOp::getLeft() { return getDests().front(); }

/// Returns the successor of a right, or null if a right ends the enclosing
/// monad.do.
Block *MonadEitherCatchOp::getRight() {
  return getHasRight() && getDests().size() == 2 ? getDests().back() : nullptr;
}

/// Parses `%m, left ^l (, right ^r)? attr-dict : T`.
ParseResult MonadEitherCatchOp::parse(OpAsmParser &parser,
                                      OperationState &result) {
  OpAsmParser::UnresolvedOperand input;
  SmallVector<Block *> dests;
  if (parser.parseOperand(input) || parser.parseComma() ||
      parser.parseKeyword("left") ||
      parser.parseSuccessor(dests.emplace_back()))
    return failure();
  if (succeeded(parser.parseOptionalComma())) {
    if (parser.parseKeyword("right") ||
        parser.parseSuccessor(dests.emplace_back()))
      return failure();
    result.addAttribute(getHasRightAttrName(result.name),
                        parser.getBuilder().getUnitAttr());
  }
  Type inputType;
  if (parser.parseOptionalAttrDict(result.attributes) || parser.parseColon() ||
      parser.parseType(inputType) ||
      parser.resolveOperand(input, inputType, result.operands))
    return failure();
  result.addSuccessors(dests);
  return success();
}

/// Prints `%m, left ^l (, right ^r)? attr-dict : T`.
void MonadEitherCatchOp::print(OpAsmPrinter &printer) {
  printer << " " << getInput() << ", left ";
  printer.printSuccessor(getLeft());
  if (Block *right = getRight()) {
    printer << ", right ";
    printer.printSuccessor(right);
  }
  printer.printOptionalAttrDict((*this)->getAttrs(), {getHasRightAttrName()});
  printer << " : " << getInput().getType();
}

/// Verifies that the left successor takes the left value, that the right
/// successor takes the value types, and that, without a right successor, the
/// input is of the result type of the enclosing `monad.do`.
LogicalResult MonadEitherCatchOp::verify() {
  size_t expected = getHasRight() ? 2 : 1;
  if (getDests().size() != expected)
    return emitOpError() << "expects " << expected << " successors, got "
                         << getDests().size();
  EitherType inputType = getInput().getType();
  if (getLeft()->getArgumentTypes() != TypeRange(inputType.getLeftType()))
    return emitOpError() << "expects the left successor to take one argument "
                            "of type "
                         << inputType.getLeftType();
  if (Block *right = getRight()) {
    if (right->getArgumentTypes() != TypeRange(inputType.getValueTypes()))
      return emitOpError()
             << "expects the right successor to take arguments of types ("
             << inputType.getValueTypes() << ")";
    return success();
  }
  Type doType = getParentOp().getType();
  if (inputType != doType)
    return emitOpError() << "expects the input to be of the result type of "
                            "the enclosing monad.do without a right "
                            "successor, "
                         << doType << ", got " << inputType;
  return success();
}

/// Returns the operands passed to a successor: none are forwarded, and the
/// catch produces the left value or the right values.
SuccessorOperands MonadEitherCatchOp::getSuccessorOperands(unsigned index) {
  assert(index < getDests().size() && "invalid successor index");
  unsigned produced =
      index == 0 ? 1 : getInput().getType().getValueTypes().size();
  return SuccessorOperands(produced, MutableOperandRange(getOperation(), 0, 0));
}

//===----------------------------------------------------------------------===//
// MonadErrorCatchOp
//===----------------------------------------------------------------------===//

/// Returns the successor of a right, or null if a right ends the enclosing
/// monad.do.
Block *MonadErrorCatchOp::getOk() {
  if (getDests().size() != getCaseTypes().size() + 1)
    return nullptr;
  return getDests().front();
}

/// Returns the handler successors, one per case.
SuccessorRange MonadErrorCatchOp::getHandlers() {
  return getDests().drop_front(getOk() ? 1 : 0);
}

/// Parses `%m (, ^ok)? [CASE -> ^h, ...] attr-dict : T`.
ParseResult MonadErrorCatchOp::parse(OpAsmParser &parser,
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
void MonadErrorCatchOp::print(OpAsmPrinter &printer) {
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
LogicalResult MonadErrorCatchOp::verify() {
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
           << "expects the left type of the input to be an error or an error "
              "union";
  EitherType doType = dyn_cast<EitherType>(getParentOp().getType());
  ErrorUnionType doErrors = doType ? doType.getErrorUnion() : nullptr;
  if (!doErrors)
    return emitOpError() << "expects the enclosing monad.do to produce an "
                            "either value whose left type is an error or an "
                            "error union";

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
  if (failed(verifyCases(*this, inputType.getLeftType(), inputErrors,
                         getCaseTypes(), getHandlers(), caught)))
    return failure();
  for (ErrorType error : inputErrors.getErrors())
    if (!caught.contains(error.getName().getValue()) &&
        !doErrors.contains(error))
      return emitOpError() << "expects the uncaught error " << error
                           << " to be an error of " << doType.getLeftType()
                           << ", the left type of the enclosing monad.do";
  return success();
}

/// Returns the operands passed to a successor: none are forwarded, and the
/// catch produces the values of a right for `^ok` and the error for a
/// handler.
SuccessorOperands MonadErrorCatchOp::getSuccessorOperands(unsigned index) {
  assert(index < getDests().size() && "invalid successor index");
  unsigned produced =
      (index == 0 && getOk()) ? getInput().getType().getValueTypes().size() : 1;
  return SuccessorOperands(produced, MutableOperandRange(getOperation(), 0, 0));
}

//===----------------------------------------------------------------------===//
// MonadErrorWidenOp
//===----------------------------------------------------------------------===//

/// Returns the errors of `type`, an error or an error union, as a union, or
/// null for any other type.
static ErrorUnionType getErrors(Type type) {
  if (ErrorType error = dyn_cast<ErrorType>(type))
    return ErrorUnionType::get(type.getContext(), {error});
  return dyn_cast<ErrorUnionType>(type);
}

/// Returns whether the input and the result are errors or error unions, the
/// errors of the input being errors of the result.
bool MonadErrorWidenOp::areCastCompatible(TypeRange inputs, TypeRange outputs) {
  if (inputs.size() != 1 || outputs.size() != 1)
    return false;
  ErrorUnionType input = getErrors(inputs.front());
  ErrorUnionType output = getErrors(outputs.front());
  return input && output && input.isSubsetOf(output);
}
