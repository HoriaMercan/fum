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

/// Returns the errors sorted by name.
static SmallVector<ErrorType> sortErrors(ArrayRef<ErrorType> errors) {
  SmallVector<ErrorType> sorted(errors);
  llvm::sort(sorted, [](ErrorType lhs, ErrorType rhs) {
    return lhs.getName() < rhs.getName();
  });
  return sorted;
}

/// Verifies that the errors are sorted by name and have distinct names.
static LogicalResult
verifyErrorSet(function_ref<InFlightDiagnostic()> emitError,
               ArrayRef<ErrorType> errors) {
  for (size_t index = 1, size = errors.size(); index < size; ++index)
    if (errors[index - 1].getName() >= errors[index].getName())
      return emitError()
             << "expects the errors to be sorted by name and distinct, got "
             << errors[index - 1] << " before " << errors[index];
  return success();
}

/// Parses a possibly empty set of error types in braces, in any order, rejects
/// errors with the same name, and sorts the errors by name.
static ParseResult parseErrorSet(AsmParser &parser,
                                 SmallVector<ErrorType> &errors) {
  if (parser.parseCommaSeparatedList(
          AsmParser::Delimiter::Braces, [&]() -> ParseResult {
            SMLoc loc = parser.getCurrentLocation();
            Type type;
            if (parser.parseType(type))
              return failure();
            auto error = dyn_cast<ErrorType>(type);
            if (!error)
              return parser.emitError(loc)
                     << "expected an error type, got " << type;
            if (llvm::any_of(errors, [&](ErrorType other) {
                  return other.getName() == error.getName();
                }))
              return parser.emitError(loc)
                     << "expected distinct error names, got \""
                     << error.getName() << "\" twice";
            errors.push_back(error);
            return success();
          }))
    return failure();
  errors = sortErrors(errors);
  return success();
}

/// Prints a set of error types in braces.
static void printErrorSet(AsmPrinter &printer, ArrayRef<ErrorType> errors) {
  printer << "{";
  llvm::interleaveComma(errors, printer,
                        [&](ErrorType error) { printer.printType(error); });
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

/// Verifies that the name is not empty.
LogicalResult ErrorType::verify(function_ref<InFlightDiagnostic()> emitError,
                                StringRef name, ArrayRef<Type> payload) {
  if (name.empty())
    return emitError() << "expects a non-empty error name";
  return success();
}

//===----------------------------------------------------------------------===//
// ErrorUnionType
//===----------------------------------------------------------------------===//

/// Returns the union of the given errors, sorted by name.
ErrorUnionType ErrorUnionType::get(MLIRContext *context,
                                   ArrayRef<ErrorType> errors) {
  return Base::get(context, sortErrors(errors));
}

/// Returns the union of the given errors, sorted by name, or emits an error
/// and returns null if they are not a valid set.
ErrorUnionType
ErrorUnionType::getChecked(function_ref<InFlightDiagnostic()> emitError,
                           MLIRContext *context, ArrayRef<ErrorType> errors) {
  return Base::getChecked(emitError, context, sortErrors(errors));
}

/// Verifies that the errors are a non-empty set sorted by name.
LogicalResult
ErrorUnionType::verify(function_ref<InFlightDiagnostic()> emitError,
                       ArrayRef<ErrorType> errors) {
  if (errors.empty())
    return emitError() << "expects at least one error";
  return verifyErrorSet(emitError, errors);
}

//===----------------------------------------------------------------------===//
// ValueOrErrorType
//===----------------------------------------------------------------------===//

/// Returns the value-or-error type with the given value types and errors,
/// sorting the errors by name.
ValueOrErrorType ValueOrErrorType::get(MLIRContext *context,
                                       TypeRange valueTypes,
                                       ArrayRef<ErrorType> errors) {
  return Base::get(context, llvm::to_vector(valueTypes), sortErrors(errors));
}

/// Returns the value-or-error type with the given value types and errors,
/// sorting the errors by name, or emits an error and returns null if the
/// errors are not a valid set.
ValueOrErrorType
ValueOrErrorType::getChecked(function_ref<InFlightDiagnostic()> emitError,
                             MLIRContext *context, TypeRange valueTypes,
                             ArrayRef<ErrorType> errors) {
  return Base::getChecked(emitError, context, llvm::to_vector(valueTypes),
                          sortErrors(errors));
}

/// Verifies that the errors are sorted by name and distinct.
LogicalResult
ValueOrErrorType::verify(function_ref<InFlightDiagnostic()> emitError,
                         ArrayRef<Type> valueTypes,
                         ArrayRef<ErrorType> errors) {
  return verifyErrorSet(emitError, errors);
}

/// Returns the value-or-error type with the given value types and the errors
/// of this type.
MonadTypeInterface
ValueOrErrorType::cloneWithValueTypes(TypeRange valueTypes) const {
  return ValueOrErrorType::get(getContext(), valueTypes, getErrors());
}

void MonadDialect::registerTypes() {
  addTypes<
#define GET_TYPEDEF_LIST
#include "fum/Dialect/Monad/IR/MonadOpsTypes.cpp.inc"
      >();
}
