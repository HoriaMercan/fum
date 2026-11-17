//===- MonadTypes.cpp - Monad dialect types ---------------------*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "fum/Dialect/Monad/IR/MonadTypes.h"

#include "fum/Dialect/Monad/IR/MonadDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/DialectImplementation.h"
#include "llvm/ADT/TypeSwitch.h"

using namespace mlir;
using namespace mlir::monad;

/// Parses a possibly empty comma-separated list of value types.
static ParseResult parseValueTypes(AsmParser &parser,
                                   SmallVector<Type> &valueTypes) {
  Type type;
  OptionalParseResult first = parser.parseOptionalType(type);
  if (!first.has_value())
    return success();
  if (failed(*first))
    return failure();
  valueTypes.push_back(type);
  while (succeeded(parser.parseOptionalComma())) {
    if (parser.parseType(type))
      return failure();
    valueTypes.push_back(type);
  }
  return success();
}

/// Prints a comma-separated list of value types.
static void printValueTypes(AsmPrinter &printer, ArrayRef<Type> valueTypes) {
  llvm::interleaveComma(valueTypes, printer);
}

/// Parses the value types of the right side of an either type: a non-empty
/// comma-separated list of types, where `none` alone stands for no value
/// types.
static ParseResult parseRightTypes(AsmParser &parser,
                                   SmallVector<Type> &valueTypes) {
  SMLoc loc = parser.getCurrentLocation();
  if (parser.parseCommaSeparatedList(
          [&]() { return parser.parseType(valueTypes.emplace_back()); }))
    return failure();
  if (valueTypes.size() == 1 && isa<NoneType>(valueTypes.front())) {
    valueTypes.clear();
    return success();
  }
  if (llvm::any_of(valueTypes, llvm::IsaPred<NoneType>))
    return parser.emitError(loc)
           << "expects 'none' to be the only right type of an either type";
  return success();
}

/// Prints the value types of the right side of an either type, or `none` if
/// there are none.
static void printRightTypes(AsmPrinter &printer, ArrayRef<Type> valueTypes) {
  if (valueTypes.empty()) {
    printer << "none";
    return;
  }
  llvm::interleaveComma(valueTypes, printer);
}

/// Sorts error types by name.
static void sortErrors(MutableArrayRef<ErrorType> errors) {
  llvm::sort(errors, [](ErrorType lhs, ErrorType rhs) {
    return lhs.getName().getValue() < rhs.getName().getValue();
  });
}

/// Parses a set of error types in braces, in any order, rejects duplicate
/// names, and sorts the errors by name. The verifier rejects an empty set.
static ParseResult parseErrorSet(AsmParser &parser,
                                 SmallVector<ErrorType> &errors) {
  if (parser.parseCommaSeparatedList(
          AsmParser::Delimiter::Braces, [&]() -> ParseResult {
            SMLoc loc = parser.getCurrentLocation();
            Type type;
            if (parser.parseType(type))
              return failure();
            ErrorType error = dyn_cast<ErrorType>(type);
            if (!error)
              return parser.emitError(loc)
                     << "expected an error type, got " << type;
            if (llvm::any_of(errors, [&](ErrorType other) {
                  return other.getName() == error.getName();
                }))
              return parser.emitError(loc)
                     << "expected distinct error names, got " << error.getName()
                     << " twice";
            errors.push_back(error);
            return success();
          }))
    return failure();
  sortErrors(errors);
  return success();
}

/// Prints a set of error types in braces.
static void printErrorSet(AsmPrinter &printer, ArrayRef<ErrorType> errors) {
  printer << "{";
  llvm::interleaveComma(errors, printer);
  printer << "}";
}

#define GET_TYPEDEF_CLASSES
#include "fum/Dialect/Monad/IR/MonadOpsTypes.cpp.inc"

//===----------------------------------------------------------------------===//
// MaybeType
//===----------------------------------------------------------------------===//

/// Returns the maybe type with the given value types.
MonadTypeInterface MaybeType::cloneWithValueTypes(TypeRange valueTypes) const {
  return MaybeType::get(getContext(), llvm::to_vector(valueTypes));
}

//===----------------------------------------------------------------------===//
// ErrorType
//===----------------------------------------------------------------------===//

/// Verifies that the error name is not empty.
LogicalResult ErrorType::verify(function_ref<InFlightDiagnostic()> emitError,
                                FlatSymbolRefAttr name,
                                ArrayRef<Type> payloadTypes) {
  if (name.getValue().empty())
    return emitError() << "expects a non-empty error name";
  return success();
}

//===----------------------------------------------------------------------===//
// ErrorUnionType
//===----------------------------------------------------------------------===//

/// Returns the union of the given errors, sorted by name.
ErrorUnionType ErrorUnionType::get(MLIRContext *context,
                                   ArrayRef<ErrorType> errors) {
  SmallVector<ErrorType> sorted(errors);
  sortErrors(sorted);
  return Base::get(context, sorted);
}

/// Returns the union of the given errors, sorted by name, or null and emits
/// an error if their names are not distinct.
ErrorUnionType
ErrorUnionType::getChecked(function_ref<InFlightDiagnostic()> emitError,
                           MLIRContext *context, ArrayRef<ErrorType> errors) {
  SmallVector<ErrorType> sorted(errors);
  sortErrors(sorted);
  return Base::getChecked(emitError, context, sorted);
}

/// Verifies that there is at least one error, that the errors are sorted by
/// name, and that their names are distinct.
LogicalResult
ErrorUnionType::verify(function_ref<InFlightDiagnostic()> emitError,
                       ArrayRef<ErrorType> errors) {
  if (errors.empty())
    return emitError() << "expects at least one error";
  for (size_t index = 1, size = errors.size(); index < size; ++index)
    if (errors[index - 1].getName().getValue() >=
        errors[index].getName().getValue())
      return emitError() << "expects the errors to be sorted by name and to "
                            "have distinct names, got "
                         << errors[index - 1] << " before " << errors[index];
  return success();
}

/// Returns the member error named `name`, or null if there is none.
ErrorType ErrorUnionType::lookup(StringRef name) const {
  for (ErrorType error : getErrors())
    if (error.getName().getValue() == name)
      return error;
  return nullptr;
}

/// Returns whether `error` is a member of this union.
bool ErrorUnionType::contains(ErrorType error) const {
  return lookup(error.getName().getValue()) == error;
}

/// Returns whether every member of this union is a member of `other`.
bool ErrorUnionType::isSubsetOf(ErrorUnionType other) const {
  return llvm::all_of(getErrors(),
                      [&](ErrorType error) { return other.contains(error); });
}

//===----------------------------------------------------------------------===//
// EitherType
//===----------------------------------------------------------------------===//

/// Returns the either type with the given value types and the left type of
/// this type.
MonadTypeInterface EitherType::cloneWithValueTypes(TypeRange valueTypes) const {
  return EitherType::get(getContext(), getLeftType(),
                         llvm::to_vector(valueTypes));
}

/// Verifies that no value type is `none`, which is printed for an empty list
/// of value types.
LogicalResult EitherType::verify(function_ref<InFlightDiagnostic()> emitError,
                                 Type leftType, ArrayRef<Type> valueTypes) {
  if (llvm::any_of(valueTypes, llvm::IsaPred<NoneType>))
    return emitError() << "expects no 'none' value type; an either type "
                          "without value types is written with 'none'";
  return success();
}

/// Returns the errors of the left type: the left type if it is an error
/// union, the union of the error if it is an error, and null otherwise.
ErrorUnionType EitherType::getErrorUnion() const {
  if (ErrorType error = dyn_cast<ErrorType>(getLeftType()))
    return ErrorUnionType::get(getContext(), {error});
  return dyn_cast<ErrorUnionType>(getLeftType());
}

void MonadDialect::registerTypes() {
  addTypes<
#define GET_TYPEDEF_LIST
#include "fum/Dialect/Monad/IR/MonadOpsTypes.cpp.inc"
      >();
}
