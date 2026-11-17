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
            op, error.getSymbol());
    if (!declaration) {
      result = op->emitOpError() << "expects " << error.getSymbol()
                                 << " to reference a declared error";
      return;
    }
    if (TypeRange(error.getPayload()) !=
        TypeRange(llvm::to_vector(
            declaration.getPayloadTypes().getAsValueRange<TypeAttr>())))
      result = op->emitOpError()
               << "expects the payload types of " << error
               << " to be the payload types declared by " << error.getSymbol();
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
MONAD_VERIFY_ERROR_SYMBOLS(MonadErrorMakeOp)
MONAD_VERIFY_ERROR_SYMBOLS(MonadErrorPayloadOp)
MONAD_VERIFY_ERROR_SYMBOLS(MonadThrowOp)
MONAD_VERIFY_ERROR_SYMBOLS(MonadWidenOp)
MONAD_VERIFY_ERROR_SYMBOLS(MonadCatchOp)
#undef MONAD_VERIFY_ERROR_SYMBOLS

//===----------------------------------------------------------------------===//
// MonadDoOp
//===----------------------------------------------------------------------===//

/// Verifies that every block except the first has a unique predecessor
/// operation and that all terminators belong to Monad.
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
// MonadThrowOp
//===----------------------------------------------------------------------===//

/// Returns the errors of an error type or of an error union type, and none for
/// any other type.
static SmallVector<ErrorType> getErrorsOf(Type type) {
  if (auto error = dyn_cast<ErrorType>(type))
    return {error};
  if (auto errorUnion = dyn_cast<ErrorUnionType>(type))
    return llvm::to_vector(errorUnion.getErrors());
  return {};
}

/// Verifies that every error of the input type is an error of the result
/// type.
LogicalResult MonadThrowOp::verify() {
  ArrayRef<ErrorType> resultErrors = getResult().getType().getErrors();
  for (ErrorType error : getErrorsOf(getError().getType()))
    if (!llvm::is_contained(resultErrors, error))
      return emitOpError() << "expects every error of the input to be an "
                              "error of the result, got "
                           << error;
  return success();
}

//===----------------------------------------------------------------------===//
// MonadWidenOp
//===----------------------------------------------------------------------===//

/// Returns whether the input is a value-or-error type with the value types of
/// the output and a subset of its errors.
bool MonadWidenOp::areCastCompatible(TypeRange inputs, TypeRange outputs) {
  if (inputs.size() != 1 || outputs.size() != 1)
    return false;
  auto input = dyn_cast<ValueOrErrorType>(inputs.front());
  auto output = dyn_cast<ValueOrErrorType>(outputs.front());
  if (!input || !output || input.getValueTypes() != output.getValueTypes())
    return false;
  return llvm::all_of(input.getErrors(), [&](ErrorType error) {
    return llvm::is_contained(output.getErrors(), error);
  });
}

//===----------------------------------------------------------------------===//
// MonadCatchOp
//===----------------------------------------------------------------------===//

/// Parses `%input (, ^ok)? [(CASE -> ^handler),* (, default -> ^rest)?]
/// attr-dict : TYPE`.
ParseResult MonadCatchOp::parse(OpAsmParser &parser, OperationState &result) {
  Builder &builder = parser.getBuilder();
  Properties &properties = result.getOrAddProperties<Properties>();
  OpAsmParser::UnresolvedOperand input;
  SmallVector<Block *> dests;
  if (parser.parseOperand(input))
    return failure();
  if (succeeded(parser.parseOptionalComma())) {
    Block *ok;
    if (parser.parseSuccessor(ok))
      return failure();
    dests.push_back(ok);
    properties.has_ok = builder.getUnitAttr();
  }

  SmallVector<Attribute> cases;
  if (parser.parseCommaSeparatedList(
          OpAsmParser::Delimiter::Square, [&]() -> ParseResult {
            if (properties.has_default)
              return parser.emitError(parser.getCurrentLocation())
                     << "expected `default` to be the last case";
            if (succeeded(parser.parseOptionalKeyword("default"))) {
              properties.has_default = builder.getUnitAttr();
            } else {
              Type caseType;
              if (parser.parseType(caseType))
                return failure();
              cases.push_back(TypeAttr::get(caseType));
            }
            Block *dest;
            if (parser.parseArrow() || parser.parseSuccessor(dest))
              return failure();
            dests.push_back(dest);
            return success();
          }))
    return failure();
  properties.cases = builder.getArrayAttr(cases);

  Type inputType;
  if (parser.parseOptionalAttrDict(result.attributes) || parser.parseColon() ||
      parser.parseType(inputType) ||
      parser.resolveOperand(input, inputType, result.operands))
    return failure();
  result.addSuccessors(dests);
  return success();
}

/// Prints the catch in the form accepted by `parse`.
void MonadCatchOp::print(OpAsmPrinter &printer) {
  printer << " " << getInput();
  if (Block *ok = getOk()) {
    printer << ", ";
    printer.printSuccessor(ok);
  }
  printer << " [";
  llvm::interleaveComma(llvm::zip_equal(getCases(), getCaseHandlers()), printer,
                        [&](auto caseAndHandler) {
                          auto [caseType, handler] = caseAndHandler;
                          printer << cast<TypeAttr>(caseType).getValue()
                                  << " -> ";
                          printer.printSuccessor(handler);
                        });
  if (Block *rest = getDefault()) {
    if (!getCases().empty())
      printer << ", ";
    printer << "default -> ";
    printer.printSuccessor(rest);
  }
  printer << "]";
  printer.printOptionalAttrDict(
      (*this)->getAttrs(),
      {getCasesAttrName(), getHasOkAttrName(), getHasDefaultAttrName()});
  printer << " : " << getInput().getType();
}

/// Returns the successor of a success, or null without `^ok`.
Block *MonadCatchOp::getOk() {
  return getHasOk() ? getDests().front() : nullptr;
}

/// Returns the handlers of the cases, in the order of `cases`.
SuccessorRange MonadCatchOp::getCaseHandlers() {
  return getDests().slice(getHasOk() ? 1 : 0, getCases().size());
}

/// Returns the handler of `default`, or null without `default`.
Block *MonadCatchOp::getDefault() {
  return getHasDefault() ? getDests().back() : nullptr;
}

/// Returns the errors of the input that no case names, sorted by name.
SmallVector<ErrorType> MonadCatchOp::getUnnamedErrors() {
  SmallVector<ErrorType> unnamed;
  ArrayAttr cases = getCases();
  for (ErrorType error : getInput().getType().getErrors())
    if (llvm::none_of(cases, [&](Attribute caseType) {
          return llvm::is_contained(
              getErrorsOf(cast<TypeAttr>(caseType).getValue()), error);
        }))
      unnamed.push_back(error);
  return unnamed;
}

/// Verifies the successors, the cases and their handlers, and that the
/// uncaught errors are errors of the result type of the enclosing `monad.do`.
LogicalResult MonadCatchOp::verify() {
  ValueOrErrorType inputType = getInput().getType();
  auto doType = dyn_cast<ValueOrErrorType>(getParentOp().getType());
  if (!doType)
    return emitOpError() << "expects the enclosing monad.do to produce a "
                            "value-or-error type, got "
                         << getParentOp().getType();
  size_t numDests =
      (getHasOk() ? 1 : 0) + getCases().size() + (getHasDefault() ? 1 : 0);
  if (getDests().size() != numDests)
    return emitOpError() << "expects " << numDests << " successors, got "
                         << getDests().size();

  if (Block *ok = getOk()) {
    if (ok->getArgumentTypes() != inputType.getValueTypes())
      return emitOpError() << "expects ^ok to take arguments of types ("
                           << inputType.getValueTypes() << ")";
  } else if (inputType != doType) {
    return emitOpError() << "expects the input to be of the result type of "
                            "the enclosing monad.do without ^ok, "
                         << doType << ", got " << inputType;
  }

  llvm::StringSet<> named;
  for (auto [caseAttr, handler] :
       llvm::zip_equal(getCases(), getCaseHandlers())) {
    Type caseType = cast<TypeAttr>(caseAttr).getValue();
    SmallVector<ErrorType> caseErrors = getErrorsOf(caseType);
    if (caseErrors.empty())
      return emitOpError() << "expects every case to be an error or error "
                              "union type, got "
                           << caseType;
    for (ErrorType error : caseErrors) {
      if (!llvm::is_contained(inputType.getErrors(), error))
        return emitOpError()
               << "expects every case to name errors of the input, got "
               << error;
      if (!named.insert(error.getName()).second)
        return emitOpError()
               << "expects every error to be named by at most one case, got "
               << error << " twice";
    }
    if (handler->getArgumentTypes() != TypeRange(caseType))
      return emitOpError() << "expects the handler of " << caseType
                           << " to take one argument of that type";
  }

  SmallVector<ErrorType> unnamed = getUnnamedErrors();
  if (Block *rest = getDefault()) {
    if (unnamed.empty())
      return emitOpError() << "expects `default` to have errors to catch";
    Type restType = ErrorUnionType::get(getContext(), unnamed);
    if (rest->getArgumentTypes() != TypeRange(restType))
      return emitOpError() << "expects the handler of `default` to take one "
                              "argument of type "
                           << restType;
    return success();
  }
  for (ErrorType error : unnamed)
    if (!llvm::is_contained(doType.getErrors(), error))
      return emitOpError() << "expects the uncaught error " << error
                           << " to be an error of the result type of the "
                              "enclosing monad.do, "
                           << doType;
  return success();
}

/// Returns the operands passed to a successor: none are forwarded; the catch
/// produces the values of a success for `^ok` and the error for a handler.
SuccessorOperands MonadCatchOp::getSuccessorOperands(unsigned index) {
  assert(index < getDests().size() && "invalid successor index");
  unsigned numProduced = getHasOk() && index == 0
                             ? getInput().getType().getValueTypes().size()
                             : 1;
  return SuccessorOperands(numProduced,
                           MutableOperandRange(getOperation(), 0, 0));
}
