//===- ADTTypes.cpp - ADT dialect types -------------------------*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "fum/Dialect/ADT/IR/ADTTypes.h"
#include "fum/Dialect/ADT/IR/ADTDialect.h"

#include "mlir/IR/Builders.h"
#include "mlir/IR/DialectImplementation.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/ADT/TypeSwitch.h"

using namespace mlir;
using namespace mlir::adt;

SmallVector<SumCase> mlir::adt::sortCasesByName(ArrayRef<SumCase> cases) {
  SmallVector<SumCase> sorted(cases);
  llvm::stable_sort(sorted, [](const SumCase &lhs, const SumCase &rhs) {
    return lhs.name.getValue() < rhs.name.getValue();
  });
  return sorted;
}

ArrayRef<SumCase> SumCase::copyCases(TypeStorageAllocator &allocator,
                                     ArrayRef<SumCase> cases) {
  SmallVector<SumCase> copies;
  copies.reserve(cases.size());
  for (const SumCase &sumCase : cases)
    copies.push_back({sumCase.name, allocator.copyInto(sumCase.fields)});
  return allocator.copyInto(ArrayRef<SumCase>(copies));
}

#define GET_TYPEDEF_CLASSES
#include "fum/Dialect/ADT/IR/ADTOpsTypes.cpp.inc"

/// Registers the types of the dialect.
void ADTDialect::registerTypes() {
  addTypes<
#define GET_TYPEDEF_LIST
#include "fum/Dialect/ADT/IR/ADTOpsTypes.cpp.inc"
      >();
}

/// Returns whether `name` is an identifier: a letter or an underscore,
/// followed by letters, digits, and underscores.
static bool isCaseName(StringRef name) {
  if (name.empty() || !(llvm::isAlpha(name.front()) || name.front() == '_'))
    return false;
  return llvm::all_of(name.drop_front(), [](char character) {
    return llvm::isAlnum(character) || character == '_';
  });
}

/// Parses `<case, ...>`, where a case is a name, followed by its field types
/// in parentheses if it has any. The cases may be written in any order.
Type SumType::parse(AsmParser &parser) {
  SMLoc loc = parser.getCurrentLocation();
  SmallVector<StringAttr> names;
  SmallVector<SmallVector<Type>> fields;
  auto parseCase = [&]() -> ParseResult {
    SMLoc caseLoc = parser.getCurrentLocation();
    Type unnamed;
    if (parser.parseOptionalType(unnamed).has_value())
      return parser.emitError(caseLoc, "expected a case name: every "
                                       "alternative of a sum is a named case");
    StringRef name;
    if (parser.parseOptionalKeyword(&name))
      return parser.emitError(caseLoc, "expected a case name: every "
                                       "alternative of a sum is a named case");
    names.push_back(parser.getBuilder().getStringAttr(name));
    SmallVector<Type> &caseFields = fields.emplace_back();
    if (failed(parser.parseOptionalLParen()))
      return success();
    if (succeeded(parser.parseOptionalRParen()))
      return parser.emitError(parser.getCurrentLocation(),
                              "expected a field type: a case without fields "
                              "is written without parentheses");
    return failure(parser.parseTypeList(caseFields) || parser.parseRParen());
  };
  if (parser.parseCommaSeparatedList(AsmParser::Delimiter::LessGreater,
                                     parseCase))
    return {};
  SmallVector<SumCase> cases;
  for (auto [name, caseFields] : llvm::zip_equal(names, fields))
    cases.push_back({name, caseFields});
  return parser.getChecked<SumType>(loc, parser.getContext(),
                                    sortCasesByName(cases));
}

/// Prints `<case, ...>`, sorted by name, with the field types of a case in
/// parentheses if it has any.
void SumType::print(AsmPrinter &printer) const {
  printer << '<';
  llvm::interleaveComma(getCases(), printer, [&](const SumCase &sumCase) {
    printer << sumCase.name.getValue();
    if (sumCase.fields.empty())
      return;
    printer << '(';
    llvm::interleaveComma(sumCase.fields, printer);
    printer << ')';
  });
  printer << '>';
}

LogicalResult SumType::verify(function_ref<InFlightDiagnostic()> emitError,
                              ArrayRef<SumCase> cases) {
  if (cases.empty())
    return emitError() << "expects at least one case, since a sum without "
                          "cases has no value";
  llvm::SmallDenseSet<StringAttr> names;
  for (const SumCase &sumCase : cases) {
    if (!sumCase.name || !isCaseName(sumCase.name.getValue()))
      return emitError() << "expects case names to be identifiers, got '"
                         << sumCase.name << "'";
    if (!names.insert(sumCase.name).second)
      return emitError() << "expects distinct case names, got '"
                         << sumCase.name.getValue() << "' twice";
    if (llvm::any_of(sumCase.fields, [](Type field) { return !field; }))
      return emitError() << "expects every field of case '"
                         << sumCase.name.getValue() << "' to have a type";
  }
  for (auto [previous, next] : llvm::zip(cases, cases.drop_front()))
    if (previous.name.getValue() > next.name.getValue())
      return emitError() << "expects the cases to be sorted by name, got '"
                         << previous.name.getValue() << "' before '"
                         << next.name.getValue() << "'";
  return success();
}

std::optional<unsigned> SumType::getCasePosition(StringRef name) const {
  for (auto [position, sumCase] : llvm::enumerate(getCases()))
    if (sumCase.name.getValue() == name)
      return position;
  return std::nullopt;
}

std::optional<SumCase> SumType::lookupCase(StringRef name) const {
  std::optional<unsigned> position = getCasePosition(name);
  if (!position)
    return std::nullopt;
  return getCases()[*position];
}

bool SumType::isIncludedIn(SumType other) const {
  return llvm::all_of(getCases(), [&](const SumCase &sumCase) {
    std::optional<SumCase> otherCase =
        other.lookupCase(sumCase.name.getValue());
    return otherCase && otherCase->fields == sumCase.fields;
  });
}
