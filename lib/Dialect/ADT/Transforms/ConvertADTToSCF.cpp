//===- ConvertADTToSCF.cpp - Lower sum types to tags and slots --*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// A value of type `!adt.sum<C...>` is expanded into an `i32` tag, the
// position of its case, and the lowered field types of every case, in the
// order of the cases. `adt.match` becomes `scf.index_switch` on the tag.
//
//===----------------------------------------------------------------------===//

#include "fum/Dialect/ADT/Transforms/ConvertADTToSCF.h"
#include "fum/Dialect/ADT/Transforms/Passes.h"

#include "fum/Dialect/ADT/IR/ADTDialect.h"
#include "fum/Dialect/ADT/IR/ADTOps.h"
#include "fum/Dialect/ADT/IR/ADTTypes.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/ControlFlow/Transforms/StructuralTypeConversions.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/Func/Transforms/FuncConversions.h"
#include "mlir/Dialect/SCF/Transforms/Patterns.h"
#include "mlir/Transforms/DialectConversion.h"

namespace mlir {
namespace adt {
#define GEN_PASS_DEF_CONVERTADTTOSCFPASS
#include "fum/Dialect/ADT/Transforms/Passes.h.inc"
} // namespace adt
} // namespace mlir

using namespace mlir;
using namespace mlir::adt;

void mlir::adt::convertSumType(
    SumType sum, SmallVectorImpl<Type> &results,
    function_ref<void(Type, SmallVectorImpl<Type> &)> convertField) {
  results.push_back(IntegerType::get(sum.getContext(), 32));
  for (const SumCase &sumCase : sum.getCases())
    for (Type field : sumCase.fields)
      convertField(field, results);
}

namespace {
/// Returns the lowered types of `types` under `converter`.
SmallVector<Type> getLoweredTypes(const TypeConverter &converter,
                                  TypeRange types) {
  SmallVector<Type> results;
  if (failed(converter.convertTypes(types, results)))
    llvm::report_fatal_error("expected every type to be convertible");
  return results;
}

/// Splits `values`, the lowered values of `types` one after the other, into
/// the lowered values of each type.
SmallVector<ValueRange> splitLoweredValues(const TypeConverter &converter,
                                           TypeRange types, ValueRange values) {
  SmallVector<ValueRange> groups;
  for (Type type : types) {
    size_t count = getLoweredTypes(converter, type).size();
    groups.push_back(values.take_front(count));
    values = values.drop_front(count);
  }
  return groups;
}

/// Returns the lowered values of the fields of every case of `sum`, given
/// the lowered values `lowered` of a value of that sum: the tag is skipped.
SmallVector<ValueRange> splitCaseSlots(const TypeConverter &converter,
                                       SumType sum, ValueRange lowered) {
  ValueRange slots = lowered.drop_front();
  SmallVector<ValueRange> cases;
  for (const SumCase &sumCase : sum.getCases()) {
    size_t count = getLoweredTypes(converter, sumCase.fields).size();
    cases.push_back(slots.take_front(count));
    slots = slots.drop_front(count);
  }
  return cases;
}

/// Returns `ub.poison` values of the lowered types of `types`.
SmallVector<Value> createPoison(const TypeConverter &converter,
                                OpBuilder &builder, Location loc,
                                TypeRange types) {
  SmallVector<Value> values;
  for (Type type : getLoweredTypes(converter, types))
    values.push_back(ub::PoisonOp::create(builder, loc, type));
  return values;
}

/// Returns the `i32` constant `value`.
Value createI32(OpBuilder &builder, Location loc, int64_t value) {
  return arith::ConstantIntOp::create(builder, loc, value, 32);
}

/// Returns the values of the given groups, flattened.
SmallVector<Value> flatten(ArrayRef<ValueRange> groups) {
  SmallVector<Value> values;
  for (ValueRange group : groups)
    llvm::append_range(values, group);
  return values;
}

/// Lowers `adt.make` to the constant tag of its case, its fields in the slots
/// of the case, and poison in the other slots.
struct MakeLowering : public OpConversionPattern<MakeOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Builds the lowered values of the result.
  LogicalResult
  matchAndRewrite(MakeOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    Location loc = op.getLoc();
    SumType sum = op.getType();
    unsigned position = *sum.getCasePosition(op.getCaseName());
    SmallVector<Value> lowered = {createI32(rewriter, loc, position)};
    for (auto [index, sumCase] : llvm::enumerate(sum.getCases())) {
      if (index == position)
        llvm::append_range(lowered, flatten(adaptor.getFields()));
      else
        llvm::append_range(lowered, createPoison(*getTypeConverter(), rewriter,
                                                 loc, sumCase.fields));
    }
    rewriter.replaceOpWithMultiple(op, {lowered});
    return success();
  }
};

/// Lowers `adt.widen`: each tag of the input becomes the tag of the same case
/// in the result, and the slots of the cases of the input are copied.
struct WidenLowering : public OpConversionPattern<WidenOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Builds the lowered values of the result.
  LogicalResult
  matchAndRewrite(WidenOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    Location loc = op.getLoc();
    SumType input = op.getInput().getType();
    SumType result = op.getType();
    ValueRange lowered = adaptor.getInput();
    SmallVector<ValueRange> inputSlots =
        splitCaseSlots(*getTypeConverter(), input, lowered);
    Value tag;
    for (auto [index, sumCase] : llvm::enumerate(input.getCases())) {
      Value resultTag = createI32(
          rewriter, loc, *result.getCasePosition(sumCase.name.getValue()));
      if (!tag) {
        tag = resultTag;
        continue;
      }
      Value isCase = arith::CmpIOp::create(
          rewriter, loc, arith::CmpIPredicate::eq, lowered.front(),
          createI32(rewriter, loc, index));
      tag = arith::SelectOp::create(rewriter, loc, isCase, resultTag, tag);
    }
    SmallVector<Value> results = {tag};
    for (const SumCase &sumCase : result.getCases()) {
      std::optional<unsigned> inputPosition =
          input.getCasePosition(sumCase.name.getValue());
      if (inputPosition)
        llvm::append_range(results, inputSlots[*inputPosition]);
      else
        llvm::append_range(results, createPoison(*getTypeConverter(), rewriter,
                                                 loc, sumCase.fields));
    }
    rewriter.replaceOpWithMultiple(op, {results});
    return success();
  }
};

/// Lowers `adt.match` to `scf.index_switch` on the tag. A group of cases is
/// copied for each of its cases; an exhaustive match gets a default region
/// that yields poison, since no tag reaches it.
struct MatchLowering : public OpConversionPattern<MatchOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Builds the switch and moves the regions into it.
  LogicalResult
  matchAndRewrite(MatchOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    Location loc = op.getLoc();
    SumType sum = op.getInputType();
    ValueRange lowered = adaptor.getInput();
    SmallVector<ValueRange> caseSlots =
        splitCaseSlots(*getTypeConverter(), sum, lowered);

    SmallVector<int64_t> positions;
    SmallVector<Region *> sources;
    for (auto [group, region] :
         llvm::zip_equal(op.getCaseGroups(), op.getCaseRegions()))
      for (StringRef name :
           cast<ArrayAttr>(group).getAsValueRange<StringAttr>()) {
        positions.push_back(*sum.getCasePosition(name));
        sources.push_back(&region);
      }

    SmallVector<Type> resultTypes =
        getLoweredTypes(*getTypeConverter(), op.getResultTypes());
    Value index = arith::IndexCastOp::create(
        rewriter, loc, rewriter.getIndexType(), lowered.front());
    scf::IndexSwitchOp switchOp = scf::IndexSwitchOp::create(
        rewriter, loc, resultTypes, index, positions, positions.size());

    for (auto [position, source, destination] :
         llvm::zip_equal(positions, sources, switchOp.getCaseRegions()))
      moveRegion(*getTypeConverter(), rewriter, *source, destination,
                 caseSlots[position], sum.getCases()[position].fields);
    if (op.getDefaultRegion().empty()) {
      Block *block = rewriter.createBlock(&switchOp.getDefaultRegion());
      rewriter.setInsertionPointToStart(block);
      scf::YieldOp::create(rewriter, loc,
                           createPoison(*getTypeConverter(), rewriter, loc,
                                        op.getResultTypes()));
    } else {
      moveRegion(*getTypeConverter(), rewriter, op.getDefaultRegion(),
                 switchOp.getDefaultRegion(), ValueRange(), TypeRange());
    }
    rewriter.replaceOpWithMultiple(
        op, splitLoweredValues(*getTypeConverter(), op.getResultTypes(),
                               switchOp.getResults()));
    return success();
  }

  /// Copies the single block of `source` into the empty region `destination`,
  /// replacing its arguments, of types `fieldTypes`, with the lowered values
  /// `slots`. A field whose type is lowered to several values is rebuilt with
  /// a cast, which the conversion then removes.
  static void moveRegion(const TypeConverter &converter,
                         ConversionPatternRewriter &rewriter, Region &source,
                         Region &destination, ValueRange slots,
                         TypeRange fieldTypes) {
    Block *entry = rewriter.createBlock(&destination);
    rewriter.cloneRegionBefore(source, destination, destination.end());
    Block *copy = &destination.back();
    rewriter.setInsertionPointToStart(entry);
    SmallVector<Value> arguments;
    for (auto [fieldType, fieldSlots] : llvm::zip_equal(
             fieldTypes, splitLoweredValues(converter, fieldTypes, slots))) {
      if (fieldSlots.size() == 1 && fieldSlots.front().getType() == fieldType)
        arguments.push_back(fieldSlots.front());
      else
        arguments.push_back(
            UnrealizedConversionCastOp::create(
                rewriter, copy->getParentOp()->getLoc(), fieldType, fieldSlots)
                .getResult(0));
    }
    rewriter.mergeBlocks(copy, entry, arguments);
  }
};

/// Lowers `adt.yield` to `scf.yield` of the lowered values.
struct YieldLowering : public OpConversionPattern<YieldOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Replaces the yield.
  LogicalResult
  matchAndRewrite(YieldOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    rewriter.replaceOpWithNewOp<scf::YieldOp>(op, flatten(adaptor.getValues()));
    return success();
  }
};

/// Lowers `ub.poison` of a sum to poison of every lowered type.
struct PoisonLowering : public OpConversionPattern<ub::PoisonOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Replaces the poison of a sum.
  LogicalResult
  matchAndRewrite(ub::PoisonOp op, OpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    if (!isa<SumType>(op.getType()))
      return failure();
    rewriter.replaceOpWithMultiple(op,
                                   {createPoison(*getTypeConverter(), rewriter,
                                                 op.getLoc(), op.getType())});
    return success();
  }
};

/// Lowers `arith.select` of a sum to one select per lowered value.
struct SelectLowering : public OpConversionPattern<arith::SelectOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Selects each lowered value.
  LogicalResult
  matchAndRewrite(arith::SelectOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    if (adaptor.getCondition().size() != 1)
      return failure();
    SmallVector<Value> results;
    for (auto [trueValue, falseValue] :
         llvm::zip_equal(adaptor.getTrueValue(), adaptor.getFalseValue()))
      results.push_back(arith::SelectOp::create(rewriter, op.getLoc(),
                                                adaptor.getCondition().front(),
                                                trueValue, falseValue));
    rewriter.replaceOpWithMultiple(op, {results});
    return success();
  }
};

/// Removes the casts that rebuild a sum from its lowered values.
struct CastLowering : public OpConversionPattern<UnrealizedConversionCastOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Replaces the result with the lowered values of the inputs.
  LogicalResult
  matchAndRewrite(UnrealizedConversionCastOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    SmallVector<Value> inputs = flatten(adaptor.getInputs());
    if (TypeRange(inputs) !=
        TypeRange(getLoweredTypes(*getTypeConverter(), op.getResultTypes())))
      return failure();
    rewriter.replaceOpWithMultiple(
        op,
        splitLoweredValues(*getTypeConverter(), op.getResultTypes(), inputs));
    return success();
  }
};

/// Updates the operands of `cf.switch` to their lowered values and converts
/// the signatures of its successors. The upstream structural pattern only
/// supports 1:1 conversions of the case operands.
struct SwitchLowering : public OpConversionPattern<cf::SwitchOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Rebuilds the switch with the flattened lowered operands.
  LogicalResult
  matchAndRewrite(cf::SwitchOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    SmallVector<SmallVector<Value>> caseOperands;
    for (ArrayRef<ValueRange> groups : adaptor.getCaseOperands())
      caseOperands.push_back(flatten(groups));
    SmallVector<ValueRange> caseOperandRanges(caseOperands.begin(),
                                              caseOperands.end());
    DenseMap<Block *, Block *> convertedBlocks;
    /// Returns `block` with its signature converted.
    auto convertBlock = [&](Block *block) -> Block * {
      auto [it, inserted] = convertedBlocks.try_emplace(block, block);
      if (!inserted)
        return it->second;
      std::optional<TypeConverter::SignatureConversion> conversion =
          getTypeConverter()->convertBlockSignature(block);
      if (conversion)
        it->second = rewriter.applySignatureConversion(block, *conversion,
                                                       getTypeConverter());
      return it->second;
    };
    Block *defaultDest = convertBlock(op.getDefaultDestination());
    SmallVector<Block *> caseDests;
    for (Block *dest : op.getCaseDestinations())
      caseDests.push_back(convertBlock(dest));
    rewriter.replaceOpWithNewOp<cf::SwitchOp>(
        op, adaptor.getFlag().front(), defaultDest,
        flatten(adaptor.getDefaultOperands()),
        op.getCaseValues().value_or(DenseIntElementsAttr()), caseDests,
        caseOperandRanges);
    return success();
  }
};

} // namespace

void mlir::adt::populateADTToSCFConversionPatterns(
    const TypeConverter &converter, RewritePatternSet &patterns) {
  patterns.add<MakeLowering, WidenLowering, MatchLowering, YieldLowering,
               PoisonLowering, SelectLowering, CastLowering>(
      converter, patterns.getContext());
  patterns.add<SwitchLowering>(converter, patterns.getContext(),
                               /*benefit=*/2);
}

namespace {
/// Appends the lowered types of `type`: a sum becomes its tag and the
/// lowered fields of every case; any other type is kept.
void convertType(Type type, SmallVectorImpl<Type> &results) {
  if (SumType sum = dyn_cast<SumType>(type))
    convertSumType(sum, results, convertType);
  else
    results.push_back(type);
}

/// Lowers sum types and the operations of the dialect.
struct ConvertADTToSCFPass
    : public adt::impl::ConvertADTToSCFPassBase<ConvertADTToSCFPass> {
  /// Converts every operation that uses a sum type.
  void runOnOperation() override {
    ModuleOp module = getOperation();
    TypeConverter converter;
    converter.addConversion([](Type type) { return type; });
    converter.addConversion(
        [](SumType type,
           SmallVectorImpl<Type> &results) -> std::optional<LogicalResult> {
          convertType(type, results);
          return success();
        });

    ConversionTarget target(getContext());
    target.addIllegalDialect<ADTDialect>();
    target.markUnknownOpDynamicallyLegal([&](Operation *op) {
      if (FunctionOpInterface function = dyn_cast<FunctionOpInterface>(op))
        return converter.isSignatureLegal(
            cast<FunctionType>(function.getFunctionType()));
      return converter.isLegal(op);
    });

    RewritePatternSet patterns(&getContext());
    populateADTToSCFConversionPatterns(converter, patterns);
    populateFunctionOpInterfaceTypeConversionPattern<func::FuncOp>(patterns,
                                                                   converter);
    populateCallOpTypeConversionPattern(patterns, converter);
    populateReturnOpTypeConversionPattern(patterns, converter);
    cf::populateCFStructuralTypeConversions(converter, patterns);
    scf::populateSCFStructuralTypeConversions(converter, patterns);
    if (failed(applyPartialConversion(module, target, std::move(patterns))))
      signalPassFailure();
  }
};
} // namespace
