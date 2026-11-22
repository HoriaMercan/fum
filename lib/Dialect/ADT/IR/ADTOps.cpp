//===- ADTOps.cpp - ADT dialect ops -----------------------------*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "fum/Dialect/ADT/IR/ADTOps.h"

#include "mlir/IR/Builders.h"
#include "mlir/IR/OpImplementation.h"
#include "mlir/IR/PatternMatch.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/STLExtras.h"

using namespace mlir;
using namespace mlir::adt;

#define GET_OP_CLASSES
#include "fum/Dialect/ADT/IR/ADTOps.cpp.inc"

/// Returns `types` as a parenthesized, comma-separated list, as written in
/// the assembly format.
static std::string formatTypes(TypeRange types) {
  std::string text;
  llvm::raw_string_ostream stream(text);
  stream << '(';
  llvm::interleaveComma(types, stream);
  stream << ')';
  return text;
}

/// Parses an opening parenthesis that must not be followed directly by the
/// closing one: a case without fields is written without parentheses. Sets
/// `present` to whether the parenthesis is there.
static ParseResult parseOptionalNonEmptyParen(OpAsmParser &parser,
                                              bool &present) {
  present = succeeded(parser.parseOptionalLParen());
  if (present && succeeded(parser.parseOptionalRParen()))
    return parser.emitError(parser.getCurrentLocation(),
                            "expected a field: a case without fields is "
                            "written without parentheses");
  return success();
}

//===----------------------------------------------------------------------===//
// MakeOp
//===----------------------------------------------------------------------===//

/// Parses `case-name ( `(` fields `)` )? attr-dict `:` sum-type`.
ParseResult MakeOp::parse(OpAsmParser &parser, OperationState &result) {
  SMLoc caseLoc = parser.getCurrentLocation();
  StringRef caseName;
  if (parser.parseKeyword(&caseName))
    return failure();
  SMLoc fieldsLoc = parser.getCurrentLocation();
  SmallVector<OpAsmParser::UnresolvedOperand> fields;
  bool hasParen = false;
  if (parseOptionalNonEmptyParen(parser, hasParen))
    return failure();
  if (hasParen && (parser.parseOperandList(fields) || parser.parseRParen()))
    return failure();
  SumType type;
  if (parser.parseOptionalAttrDict(result.attributes) || parser.parseColon() ||
      parser.parseType(type))
    return failure();
  std::optional<SumCase> sumCase = type.lookupCase(caseName);
  if (!sumCase)
    return parser.emitError(caseLoc)
           << "expects '" << caseName << "' to be a case of " << type;
  if (fields.size() != sumCase->fields.size())
    return parser.emitError(fieldsLoc)
           << "expects " << sumCase->fields.size() << " fields for case '"
           << caseName << "', got " << fields.size();
  if (parser.resolveOperands(fields, sumCase->fields, fieldsLoc,
                             result.operands))
    return failure();
  result.addAttribute(getCaseNameAttrName(result.name),
                      parser.getBuilder().getStringAttr(caseName));
  result.addTypes(type);
  return success();
}

/// Prints `case-name ( `(` fields `)` )? attr-dict `:` sum-type`.
void MakeOp::print(OpAsmPrinter &printer) {
  printer << ' ' << getCaseName();
  if (!getFields().empty())
    printer << '(' << getFields() << ')';
  printer.printOptionalAttrDict((*this)->getAttrs(), {getCaseNameAttrName()});
  printer << " : " << getType();
}

LogicalResult MakeOp::verify() {
  std::optional<SumCase> sumCase = getType().lookupCase(getCaseName());
  if (!sumCase)
    return emitOpError() << "expects '" << getCaseName() << "' to be a case of "
                         << getType();
  if (TypeRange(getFields().getTypes()) != TypeRange(sumCase->fields))
    return emitOpError() << "expects the fields of case '" << getCaseName()
                         << "' to have types " << formatTypes(sumCase->fields);
  return success();
}

//===----------------------------------------------------------------------===//
// MatchOp
//===----------------------------------------------------------------------===//

/// Parses the arguments of a region in parentheses, if there are any, with
/// their types.
static ParseResult
parseRegionArguments(OpAsmParser &parser,
                     SmallVectorImpl<OpAsmParser::Argument> &arguments) {
  bool hasParen = false;
  if (parseOptionalNonEmptyParen(parser, hasParen))
    return failure();
  if (!hasParen)
    return success();
  return failure(parser.parseArgumentList(arguments,
                                          OpAsmParser::Delimiter::None,
                                          /*allowType=*/true) ||
                 parser.parseRParen());
}

/// Parses `%input : sum-type (-> result-types)? attr-dict`, then each
/// `case names (arguments)? region`, then `default region` if there is
/// one.
ParseResult MatchOp::parse(OpAsmParser &parser, OperationState &result) {
  OpAsmParser::UnresolvedOperand input;
  SumType inputType;
  if (parser.parseOperand(input) || parser.parseColon() ||
      parser.parseType(inputType) ||
      parser.resolveOperand(input, inputType, result.operands) ||
      parser.parseOptionalArrowTypeList(result.types) ||
      parser.parseOptionalAttrDict(result.attributes))
    return failure();

  Builder &builder = parser.getBuilder();
  SmallVector<Attribute> groups;
  SmallVector<std::unique_ptr<Region>> caseRegions;
  while (succeeded(parser.parseOptionalKeyword("case"))) {
    SmallVector<Attribute> names;
    if (parser.parseCommaSeparatedList([&]() -> ParseResult {
          StringRef name;
          if (parser.parseKeyword(&name))
            return failure();
          names.push_back(builder.getStringAttr(name));
          return success();
        }))
      return failure();
    groups.push_back(builder.getArrayAttr(names));
    SmallVector<OpAsmParser::Argument> arguments;
    std::unique_ptr<Region> &region =
        caseRegions.emplace_back(std::make_unique<Region>());
    if (parseRegionArguments(parser, arguments) ||
        parser.parseRegion(*region, arguments))
      return failure();
  }

  std::unique_ptr<Region> defaultRegion = std::make_unique<Region>();
  if (succeeded(parser.parseOptionalKeyword("default")) &&
      parser.parseRegion(*defaultRegion))
    return failure();

  result.addAttribute(getCaseGroupsAttrName(result.name),
                      builder.getArrayAttr(groups));
  result.addRegion(std::move(defaultRegion));
  for (std::unique_ptr<Region> &region : caseRegions)
    result.addRegion(std::move(region));
  return success();
}

/// Prints the arguments of the entry block of `region` in parentheses, if
/// there are any, then the region.
static void printRegionWithArguments(OpAsmPrinter &printer, Region &region) {
  Block &entry = region.front();
  if (entry.getNumArguments() != 0) {
    printer << '(';
    llvm::interleaveComma(
        entry.getArguments(), printer,
        [&](BlockArgument argument) { printer.printRegionArgument(argument); });
    printer << ')';
  }
  printer << ' ';
  printer.printRegion(region, /*printEntryBlockArgs=*/false);
}

/// Prints the form that `MatchOp::parse` parses.
void MatchOp::print(OpAsmPrinter &printer) {
  printer << ' ' << getInput() << " : " << getInputType();
  printer.printOptionalArrowTypeList(getResultTypes());
  printer.printOptionalAttrDict((*this)->getAttrs(), {getCaseGroupsAttrName()});
  for (auto [group, region] :
       llvm::zip_equal(getCaseGroups(), getCaseRegions())) {
    printer.printNewline();
    printer << "case ";
    llvm::interleaveComma(cast<ArrayAttr>(group).getAsValueRange<StringAttr>(),
                          printer);
    printRegionWithArguments(printer, region);
  }
  if (!getDefaultRegion().empty()) {
    printer.printNewline();
    printer << "default ";
    printer.printRegion(getDefaultRegion());
  }
}

/// Returns the case names of all groups of `match`.
static SmallVector<StringRef> getListedNames(MatchOp match) {
  SmallVector<StringRef> names;
  for (Attribute group : match.getCaseGroups())
    llvm::append_range(names,
                       cast<ArrayAttr>(group).getAsValueRange<StringAttr>());
  return names;
}

Region *MatchOp::getRegionForCase(StringRef name) {
  for (auto [group, region] :
       llvm::zip_equal(getCaseGroups(), getCaseRegions()))
    if (llvm::is_contained(cast<ArrayAttr>(group).getAsValueRange<StringAttr>(),
                           name))
      return &region;
  if (getDefaultRegion().empty())
    return nullptr;
  return &getDefaultRegion();
}

SmallVector<StringRef> MatchOp::getUnlistedCases() {
  SmallVector<StringRef> listed = getListedNames(*this);
  SmallVector<StringRef> unlisted;
  for (const SumCase &sumCase : getInputType().getCases())
    if (!llvm::is_contained(listed, sumCase.name.getValue()))
      unlisted.push_back(sumCase.name.getValue());
  return unlisted;
}

LogicalResult MatchOp::verify() {
  SumType inputType = getInputType();
  if (getCaseGroups().size() != getCaseRegions().size())
    return emitOpError() << "expects one region per group of cases, got "
                         << getCaseGroups().size() << " groups and "
                         << getCaseRegions().size() << " regions";
  if (getCaseGroups().empty())
    return emitOpError() << "expects at least one case";

  llvm::SmallDenseSet<StringRef> listed;
  for (Attribute groupAttr : getCaseGroups()) {
    ArrayAttr group = cast<ArrayAttr>(groupAttr);
    if (group.empty())
      return emitOpError() << "expects every case to list at least one name";
    std::optional<SumCase> first;
    for (StringRef name : group.getAsValueRange<StringAttr>()) {
      std::optional<SumCase> sumCase = inputType.lookupCase(name);
      if (!sumCase)
        return emitOpError()
               << "expects '" << name << "' to be a case of " << inputType;
      if (!listed.insert(name).second)
        return emitOpError()
               << "expects case '" << name << "' to be listed once";
      if (!first) {
        first = sumCase;
        continue;
      }
      if (sumCase->fields != first->fields)
        return emitOpError()
               << "expects the cases of a group to have the same field types, "
                  "got "
               << formatTypes(first->fields) << " for '"
               << first->name.getValue() << "' and "
               << formatTypes(sumCase->fields) << " for '" << name << "'";
    }
  }

  SmallVector<StringRef> unlisted = getUnlistedCases();
  if (getDefaultRegion().empty() && !unlisted.empty()) {
    InFlightDiagnostic diagnostic =
        emitOpError() << "expects every case to be handled, or a default "
                         "case; not handled:";
    for (StringRef name : unlisted)
      diagnostic << " '" << name << "'";
    return diagnostic;
  }
  if (!getDefaultRegion().empty() && unlisted.empty())
    return emitOpError() << "expects the default case to handle at least one "
                            "case, but every case is listed";
  return success();
}

/// Checks that `region` takes arguments of types `argumentTypes` and that
/// its `adt.yield` returns values of the result types of `match`. `what`
/// names the region in diagnostics.
static LogicalResult verifyMatchRegion(MatchOp match, Region &region,
                                       TypeRange argumentTypes,
                                       const Twine &what) {
  Block &entry = region.front();
  if (TypeRange(entry.getArgumentTypes()) != argumentTypes)
    return match.emitOpError()
           << "expects the region of " << what << " to take arguments of types "
           << formatTypes(argumentTypes);
  YieldOp yield = cast<YieldOp>(entry.getTerminator());
  if (TypeRange(yield.getValues().getTypes()) != match.getResultTypes())
    return yield.emitOpError() << "expects values of the result types "
                               << formatTypes(match.getResultTypes());
  return success();
}

LogicalResult MatchOp::verifyRegions() {
  SumType inputType = getInputType();
  for (auto [group, region] :
       llvm::zip_equal(getCaseGroups(), getCaseRegions())) {
    StringRef name =
        *cast<ArrayAttr>(group).getAsValueRange<StringAttr>().begin();
    SumCase sumCase = *inputType.lookupCase(name);
    if (failed(verifyMatchRegion(*this, region, sumCase.fields,
                                 "case '" + name + "'")))
      return failure();
  }
  if (getDefaultRegion().empty())
    return success();
  return verifyMatchRegion(*this, getDefaultRegion(), TypeRange(),
                           "the default case");
}

namespace {
/// Replaces a match on a value built by `adt.make` with the region of that
/// case, inlined with the fields as arguments: the reduction rule of a case
/// analysis on a known constructor.
struct MatchOnMake : public OpRewritePattern<MatchOp> {
  using OpRewritePattern<MatchOp>::OpRewritePattern;

  LogicalResult matchAndRewrite(MatchOp match,
                                PatternRewriter &rewriter) const override {
    MakeOp make = match.getInput().getDefiningOp<MakeOp>();
    if (!make)
      return failure();
    Region *region = match.getRegionForCase(make.getCaseName());
    SmallVector<Value> arguments;
    if (region != &match.getDefaultRegion())
      llvm::append_range(arguments, make.getFields());
    Block &entry = region->front();
    YieldOp yield = cast<YieldOp>(entry.getTerminator());
    rewriter.inlineBlockBefore(&entry, match, arguments);
    SmallVector<Value> results(yield.getValues());
    rewriter.eraseOp(yield);
    rewriter.replaceOp(match, results);
    return success();
  }
};
} // namespace

void MatchOp::getCanonicalizationPatterns(RewritePatternSet &patterns,
                                          MLIRContext *context) {
  patterns.add<MatchOnMake>(context);
}

//===----------------------------------------------------------------------===//
// WidenOp
//===----------------------------------------------------------------------===//

LogicalResult WidenOp::verify() {
  SumType inputType = getInput().getType();
  SumType resultType = getType();
  if (inputType == resultType)
    return emitOpError() << "expects the result type to differ from the "
                            "input type";
  for (const SumCase &sumCase : inputType.getCases()) {
    std::optional<SumCase> resultCase =
        resultType.lookupCase(sumCase.name.getValue());
    if (!resultCase)
      return emitOpError() << "expects case '" << sumCase.name.getValue()
                           << "' of the input to be a case of the result";
    if (resultCase->fields != sumCase.fields)
      return emitOpError() << "expects case '" << sumCase.name.getValue()
                           << "' to have the same field types in the input "
                              "and the result, got "
                           << formatTypes(sumCase.fields) << " and "
                           << formatTypes(resultCase->fields);
  }
  return success();
}

/// Folds two widenings into one.
OpFoldResult WidenOp::fold(FoldAdaptor adaptor) {
  WidenOp inner = getInput().getDefiningOp<WidenOp>();
  if (!inner)
    return {};
  getInputMutable().assign(inner.getInput());
  return getResult();
}
