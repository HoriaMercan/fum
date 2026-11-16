//===- ConvertMonadToCF.cpp - Lower the monad dialect to cf -----*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// The lowering runs in two steps. The first step keeps the monadic types and
// replaces the control flow of every `monad.do` by `cf` branches; it reads the
// components of a monadic value through an `unrealized_conversion_cast`. The
// second step is a dialect conversion that splits every monadic value into its
// components and folds away the casts from or to monadic types.
//
//===----------------------------------------------------------------------===//

#include "fum/Dialect/Monad/Transforms/Passes.h"

#include "fum/Dialect/Monad/IR/MonadDialect.h"
#include "fum/Dialect/Monad/IR/MonadOps.h"
#include "fum/Dialect/Monad/IR/MonadTypes.h"
#include "mlir/Dialect/ControlFlow/Transforms/StructuralTypeConversions.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/Func/Transforms/FuncConversions.h"
#include "mlir/IR/PatternMatch.h"
#include "mlir/Transforms/DialectConversion.h"
#include "llvm/ADT/DenseMap.h"

namespace mlir {
namespace monad {
#define GEN_PASS_DEF_CONVERTMONADTOCFPASS
#include "fum/Dialect/Monad/Transforms/Passes.h.inc"
} // namespace monad
} // namespace mlir

using namespace mlir;
using namespace mlir::monad;

/// Tags of the exception kinds of the module, by kind name.
using KindTags = llvm::DenseMap<StringAttr, int32_t>;

//===----------------------------------------------------------------------===//
// Representation
//===----------------------------------------------------------------------===//

/// Returns the 32-bit FNV-1a hash of `name` with the sign bit cleared.
static int32_t getKindTag(StringRef name) {
  uint32_t hash = 2166136261u;
  for (char c : name) {
    hash ^= static_cast<uint8_t>(c);
    hash *= 16777619u;
  }
  return static_cast<int32_t>(hash & 0x7fffffffu);
}

/// Returns true if `type` fits the payload word.
static bool isPayloadWordType(Type type) {
  if (isa<IndexType>(type))
    return true;
  auto intType = dyn_cast<IntegerType>(type);
  return intType && intType.getWidth() <= 64;
}

/// Returns the types of the components of a monadic value one level deep: the
/// value types stay unconverted.
static SmallVector<Type> getComponentTypes(Type type) {
  MLIRContext *ctx = type.getContext();
  Type tagType = IntegerType::get(ctx, 32);
  Type wordType = IntegerType::get(ctx, 64);
  SmallVector<Type> components;
  if (auto maybeType = dyn_cast<MaybeType>(type)) {
    components.push_back(IntegerType::get(ctx, 1));
    llvm::append_range(components, maybeType.getValueTypes());
  } else if (auto voeType = dyn_cast<ValueOrExceptionType>(type)) {
    components.push_back(tagType);
    llvm::append_range(components, voeType.getValueTypes());
    components.push_back(wordType);
  } else if (isa<ExceptionType>(type)) {
    components.append({tagType, wordType});
  }
  return components;
}

/// Returns true if `type` is a type of the monad dialect.
static bool isMonadType(Type type) {
  return isa<MonadDialect>(type.getDialect());
}

/// Creates a cast from `inputs` to `types`, which the second step folds away.
static ValueRange createUnpackCast(OpBuilder &builder, Location loc,
                                   TypeRange types, ValueRange inputs) {
  return UnrealizedConversionCastOp::create(builder, loc, types, inputs)
      .getResults();
}

/// Returns true if `cast` casts from or to a type of the monad dialect.
static bool isMonadCast(UnrealizedConversionCastOp cast) {
  return llvm::any_of(cast.getInputs().getTypes(), isMonadType) ||
         llvm::any_of(cast.getResultTypes(), isMonadType);
}

/// Returns the components of the monadic value `value`.
static ValueRange unpack(OpBuilder &builder, Location loc, Value value) {
  return createUnpackCast(builder, loc, getComponentTypes(value.getType()),
                          value);
}

/// Returns true if the components of a monadic value of type `type` are a
/// success.
static Value isSuccess(OpBuilder &builder, Location loc, Type type,
                       ValueRange components) {
  if (isa<MaybeType>(type))
    return components.front();
  Value zero = arith::ConstantIntOp::create(builder, loc, 0, 32);
  return arith::CmpIOp::create(builder, loc, arith::CmpIPredicate::eq,
                               components.front(), zero);
}

/// Returns the failure of type `resultType` with the exception of `failure`, a
/// failure of the same monad.
static Value castFailure(OpBuilder &builder, Location loc, Value failure,
                         ValueRange components, Type resultType) {
  if (failure.getType() == resultType)
    return failure;
  if (isa<MaybeType>(resultType))
    return MonadMaybeNoneOp::create(builder, loc, resultType);
  Value exception =
      createUnpackCast(builder, loc, ExceptionType::get(builder.getContext()),
                       {components.front(), components.back()})[0];
  return MonadThrowOp::create(builder, loc, resultType, exception);
}

/// Returns the payload of type `type` held by the payload word `word`.
static Value decodePayload(OpBuilder &builder, Location loc, Value word,
                           Type type) {
  if (isa<IndexType>(type))
    return arith::IndexCastOp::create(builder, loc, type, word);
  if (type.getIntOrFloatBitWidth() == 64)
    return word;
  return arith::TruncIOp::create(builder, loc, type, word);
}

/// Returns the payload word holding `payload`.
static Value encodePayload(OpBuilder &builder, Location loc, Value payload) {
  Type wordType = builder.getI64Type();
  Type type = payload.getType();
  if (isa<IndexType>(type))
    return arith::IndexCastOp::create(builder, loc, wordType, payload);
  unsigned width = type.getIntOrFloatBitWidth();
  if (width == 64)
    return payload;
  if (width == 1)
    return arith::ExtUIOp::create(builder, loc, wordType, payload);
  return arith::ExtSIOp::create(builder, loc, wordType, payload);
}

//===----------------------------------------------------------------------===//
// Step 1: control flow
//===----------------------------------------------------------------------===//

/// Replaces `bind` by a branch to its successor on success and to `exit` with
/// the failure otherwise.
static void lowerBind(IRRewriter &rewriter, MonadBindOp bind, Block *exit,
                      Type resultType) {
  Location loc = bind.getLoc();
  rewriter.setInsertionPoint(bind);
  Value input = bind.getInput();
  ValueRange components = unpack(rewriter, loc, input);
  size_t numValues = bind.getInput().getType().getValueTypes().size();
  Value succeeded = isSuccess(rewriter, loc, input.getType(), components);
  Value failure = castFailure(rewriter, loc, input, components, resultType);
  rewriter.replaceOpWithNewOp<cf::CondBranchOp>(bind, succeeded, bind.getNext(),
                                                components.slice(1, numValues),
                                                exit, failure);
}

/// Replaces `catch` by one `cf.switch` on the tag of its input.
static void lowerCatch(IRRewriter &rewriter, MonadCatchOp catchOp, Block *exit,
                       Type resultType, const KindTags &tags) {
  Location loc = catchOp.getLoc();
  rewriter.setInsertionPoint(catchOp);
  Value input = catchOp.getInput();
  ValueRange components = unpack(rewriter, loc, input);
  Value tag = components.front();
  Value word = components.back();
  size_t numValues = catchOp.getInput().getType().getValueTypes().size();

  SmallVector<int32_t> caseValues;
  SmallVector<Block *> caseDests;
  SmallVector<SmallVector<Value>> caseOperands;
  caseValues.push_back(0);
  if (Block *ok = catchOp.getOkDest()) {
    caseDests.push_back(ok);
    caseOperands.push_back(llvm::to_vector(components.slice(1, numValues)));
  } else {
    caseDests.push_back(exit);
    caseOperands.push_back({input});
  }
  for (auto [group, dest] :
       llvm::zip(catchOp.getCaseKinds(), catchOp.getCaseDests())) {
    SmallVector<Value> payload;
    for (Type type : dest->getArgumentTypes())
      payload.push_back(decodePayload(rewriter, loc, word, type));
    for (Attribute kind : cast<ArrayAttr>(group)) {
      caseValues.push_back(tags.at(cast<FlatSymbolRefAttr>(kind).getAttr()));
      caseDests.push_back(dest);
      caseOperands.push_back(payload);
    }
  }

  Block *defaultDest = catchOp.getDefaultDest();
  Value defaultOperand;
  if (defaultDest) {
    defaultOperand = createUnpackCast(rewriter, loc,
                                      ExceptionType::get(rewriter.getContext()),
                                      {tag, word})[0];
  } else {
    defaultDest = exit;
    defaultOperand = castFailure(rewriter, loc, input, components, resultType);
  }
  SmallVector<ValueRange> caseOperandRanges(caseOperands.begin(),
                                            caseOperands.end());
  rewriter.replaceOpWithNewOp<cf::SwitchOp>(
      catchOp, tag, defaultDest, ValueRange(defaultOperand), caseValues,
      caseDests, caseOperandRanges);
}

/// Inlines the region of `doOp` into its parent region, like the lowering of
/// `scf.execute_region`: the region ends by branching to a new block whose
/// argument replaces the result.
static void lowerDo(IRRewriter &rewriter, MonadDoOp doOp,
                    const KindTags &tags) {
  Location loc = doOp.getLoc();
  Type resultType = doOp.getType();
  Block *before = doOp->getBlock();
  Block *exit = rewriter.splitBlock(before, std::next(doOp->getIterator()));
  Value result = exit->addArgument(resultType, loc);
  rewriter.replaceAllUsesWith(doOp.getResult(), result);

  for (Block &block : doOp.getBody()) {
    Operation *terminator = block.getTerminator();
    if (auto yield = dyn_cast<MonadYieldOp>(terminator)) {
      rewriter.setInsertionPoint(yield);
      rewriter.replaceOpWithNewOp<cf::BranchOp>(yield, exit, yield.getValue());
    } else if (auto bind = dyn_cast<MonadBindOp>(terminator)) {
      lowerBind(rewriter, bind, exit, resultType);
    } else if (auto catchOp = dyn_cast<MonadCatchOp>(terminator)) {
      lowerCatch(rewriter, catchOp, exit, resultType, tags);
    }
  }

  Block *entry = &doOp.getBody().front();
  rewriter.inlineRegionBefore(doOp.getBody(), exit);
  rewriter.setInsertionPointToEnd(before);
  cf::BranchOp::create(rewriter, loc, entry);
  rewriter.eraseOp(doOp);
}

//===----------------------------------------------------------------------===//
// Step 2: type conversion
//===----------------------------------------------------------------------===//

namespace {

/// Splits a monadic value into its components, recursively.
struct MonadTypeConverter : public TypeConverter {
  /// Registers the conversions.
  MonadTypeConverter() {
    addConversion([](Type type) { return type; });
    addConversion(
        [this](Type type,
               SmallVectorImpl<Type> &results) -> std::optional<LogicalResult> {
          if (!isMonadType(type))
            return std::nullopt;
          return convertTypes(getComponentTypes(type), results);
        });
  }
};

/// Returns the values of `ranges` concatenated.
static SmallVector<Value> flatten(ArrayRef<ValueRange> ranges) {
  SmallVector<Value> values;
  for (ValueRange range : ranges)
    llvm::append_range(values, range);
  return values;
}

/// Creates one `ub.poison` for each type in `types`.
static void appendPoison(OpBuilder &builder, Location loc, TypeRange types,
                         SmallVectorImpl<Value> &values) {
  for (Type type : types)
    values.push_back(ub::PoisonOp::create(builder, loc, type));
}

/// Lowers `monad.return` to a success: the set flag or the zero tag, the
/// values, and a poison payload word.
struct ReturnLowering : public OpConversionPattern<MonadReturnOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Rewrites the op.
  LogicalResult
  matchAndRewrite(MonadReturnOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    Location loc = op.getLoc();
    SmallVector<Value> values;
    Type type = op.getType();
    if (isa<MaybeType>(type)) {
      values.push_back(arith::ConstantIntOp::create(rewriter, loc, 1, 1));
      llvm::append_range(values, flatten(adaptor.getValues()));
    } else if (isa<ValueOrExceptionType>(type)) {
      values.push_back(arith::ConstantIntOp::create(rewriter, loc, 0, 32));
      llvm::append_range(values, flatten(adaptor.getValues()));
      appendPoison(rewriter, loc, rewriter.getI64Type(), values);
    } else {
      return failure();
    }
    rewriter.replaceOpWithMultiple(op, {values});
    return success();
  }
};

/// Lowers `monad.maybe.none` to a cleared flag and poison values.
struct MaybeNoneLowering : public OpConversionPattern<MonadMaybeNoneOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Rewrites the op.
  LogicalResult
  matchAndRewrite(MonadMaybeNoneOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    Location loc = op.getLoc();
    SmallVector<Type> types;
    if (failed(getTypeConverter()->convertType(op.getType(), types)))
      return failure();
    SmallVector<Value> values;
    values.push_back(arith::ConstantIntOp::create(rewriter, loc, 0, 1));
    appendPoison(rewriter, loc, TypeRange(types).drop_front(), values);
    rewriter.replaceOpWithMultiple(op, {values});
    return success();
  }
};

/// Lowers `monad.exception.make` to the tag of its kind and its payload word.
struct ExceptionMakeLowering
    : public OpConversionPattern<MonadExceptionMakeOp> {
  /// Creates the pattern with the tags of the module.
  ExceptionMakeLowering(const TypeConverter &converter, MLIRContext *ctx,
                        const KindTags &tags)
      : OpConversionPattern(converter, ctx), tags(tags) {}

  /// Rewrites the op.
  LogicalResult
  matchAndRewrite(MonadExceptionMakeOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    Location loc = op.getLoc();
    SmallVector<Value> values;
    values.push_back(arith::ConstantIntOp::create(
        rewriter, loc, tags.at(op.getKindAttr().getAttr()), 32));
    SmallVector<Value> payload = flatten(adaptor.getPayload());
    if (payload.empty())
      appendPoison(rewriter, loc, rewriter.getI64Type(), values);
    else
      values.push_back(encodePayload(rewriter, loc, payload.front()));
    rewriter.replaceOpWithMultiple(op, {values});
    return success();
  }

  /// Tags of the exception kinds of the module.
  const KindTags &tags;
};

/// Lowers `monad.throw` to the tag, poison values, and the payload word.
struct ThrowLowering : public OpConversionPattern<MonadThrowOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Rewrites the op.
  LogicalResult
  matchAndRewrite(MonadThrowOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    SmallVector<Type> types;
    if (failed(getTypeConverter()->convertType(op.getType(), types)))
      return failure();
    ValueRange exception = adaptor.getException();
    SmallVector<Value> values;
    values.push_back(exception.front());
    appendPoison(rewriter, op.getLoc(),
                 TypeRange(types).slice(1, types.size() - 2), values);
    values.push_back(exception.back());
    rewriter.replaceOpWithMultiple(op, {values});
    return success();
  }
};

/// Lowers `arith.select` of monadic values to one select per component.
struct SelectLowering : public OpConversionPattern<arith::SelectOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Rewrites the op.
  LogicalResult
  matchAndRewrite(arith::SelectOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    if (!isMonadType(op.getType()) || adaptor.getCondition().size() != 1)
      return failure();
    SmallVector<Value> values;
    for (auto [trueValue, falseValue] :
         llvm::zip_equal(adaptor.getTrueValue(), adaptor.getFalseValue()))
      values.push_back(arith::SelectOp::create(rewriter, op.getLoc(),
                                               adaptor.getCondition().front(),
                                               trueValue, falseValue));
    rewriter.replaceOpWithMultiple(op, {values});
    return success();
  }
};

/// Folds the casts from or to monadic types: the components of the operands
/// are the components of the results.
struct UnpackLowering : public OpConversionPattern<UnrealizedConversionCastOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Rewrites the op.
  LogicalResult
  matchAndRewrite(UnrealizedConversionCastOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    if (!isMonadCast(op))
      return failure();
    SmallVector<Value> components = flatten(adaptor.getInputs());
    SmallVector<SmallVector<Value>> results;
    size_t position = 0;
    for (Type type : op.getResultTypes()) {
      SmallVector<Type> types;
      if (failed(getTypeConverter()->convertType(type, types)))
        return failure();
      results.push_back(
          llvm::to_vector(ArrayRef(components).slice(position, types.size())));
      position += types.size();
    }
    if (position != components.size())
      return failure();
    rewriter.replaceOpWithMultiple(op, std::move(results));
    return success();
  }
};

/// Converts the operands of `cf.switch` 1:N, which the upstream structural
/// conversion of `cf.switch` does not support.
struct SwitchConversion : public OpConversionPattern<cf::SwitchOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Rewrites the op.
  LogicalResult
  matchAndRewrite(cf::SwitchOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    if (adaptor.getFlag().size() != 1)
      return failure();
    const TypeConverter *converter = getTypeConverter();
    for (unsigned index = 0, e = op->getNumSuccessors(); index < e; ++index) {
      Block *dest = op->getSuccessor(index);
      if (converter->isLegal(dest->getArgumentTypes()))
        continue;
      TypeConverter::SignatureConversion conversion(dest->getNumArguments());
      if (failed(converter->convertSignatureArgs(dest->getArgumentTypes(),
                                                 conversion)))
        return failure();
      rewriter.applySignatureConversion(dest, conversion, converter);
    }
    SmallVector<SmallVector<Value>> caseOperands;
    for (ArrayRef<ValueRange> operands : adaptor.getCaseOperands())
      caseOperands.push_back(flatten(operands));
    SmallVector<ValueRange> caseOperandRanges(caseOperands.begin(),
                                              caseOperands.end());
    rewriter.replaceOpWithNewOp<cf::SwitchOp>(
        op, adaptor.getFlag().front(), op.getDefaultDestination(),
        flatten(adaptor.getDefaultOperands()), op.getCaseValuesAttr(),
        op.getCaseDestinations(), caseOperandRanges);
    return success();
  }
};

/// Lowers the monad dialect to cf, arith and ub.
struct ConvertMonadToCFPass
    : public monad::impl::ConvertMonadToCFPassBase<ConvertMonadToCFPass> {
  /// Runs the pass.
  void runOnOperation() override;

  /// Computes the tags of the exception kinds of the module, and checks that
  /// they are distinct and that the payloads fit the payload word.
  LogicalResult computeTags(KindTags &tags);
};

} // namespace

LogicalResult ConvertMonadToCFPass::computeTags(KindTags &tags) {
  llvm::DenseMap<int32_t, MonadExceptionDeclareOp> kindsByTag;
  WalkResult result = getOperation().walk([&](MonadExceptionDeclareOp op) {
    ArrayAttr payloadTypes = op.getPayloadTypes();
    if (payloadTypes.size() > 1 ||
        !llvm::all_of(payloadTypes.getAsValueRange<TypeAttr>(),
                      isPayloadWordType)) {
      op.emitError() << "cannot lower the payload of " << op.getSymNameAttr()
                     << ": expects at most one integer of at most 64 bits or "
                        "index";
      return WalkResult::interrupt();
    }
    int32_t tag = getKindTag(op.getSymName());
    auto [it, inserted] = kindsByTag.try_emplace(tag, op);
    if (tag == 0 || !inserted) {
      op.emitError() << "the tag of exception kind " << op.getSymNameAttr()
                     << " collides with "
                     << (tag == 0 ? StringRef("success")
                                  : it->second.getSymName());
      return WalkResult::interrupt();
    }
    tags[op.getSymNameAttr()] = tag;
    return WalkResult::advance();
  });
  return failure(result.wasInterrupted());
}

void ConvertMonadToCFPass::runOnOperation() {
  ModuleOp module = getOperation();
  MLIRContext *ctx = &getContext();
  KindTags tags;
  if (failed(computeTags(tags)))
    return signalPassFailure();

  // Step 1: inline every monad.do, outer ones first.
  SmallVector<MonadDoOp> doOps;
  module.walk<WalkOrder::PreOrder>(
      [&](MonadDoOp doOp) { doOps.push_back(doOp); });
  IRRewriter rewriter(ctx);
  for (MonadDoOp doOp : doOps)
    lowerDo(rewriter, doOp, tags);

  // Step 2: split the monadic values into their components.
  MonadTypeConverter converter;
  ConversionTarget target(*ctx);
  target.addLegalDialect<arith::ArithDialect, cf::ControlFlowDialect,
                         ub::UBDialect>();
  target.addIllegalDialect<MonadDialect>();
  target.addLegalOp<MonadExceptionDeclareOp>();
  auto isLegal = [&](Operation *op) { return converter.isLegal(op); };
  target.addDynamicallyLegalOp<arith::SelectOp, func::CallOp, func::ReturnOp>(
      isLegal);
  target.addDynamicallyLegalOp<func::FuncOp>([&](func::FuncOp op) {
    return converter.isSignatureLegal(op.getFunctionType());
  });
  target.addDynamicallyLegalOp<UnrealizedConversionCastOp>(
      [](UnrealizedConversionCastOp op) { return !isMonadCast(op); });

  RewritePatternSet patterns(ctx);
  patterns.add<ReturnLowering, MaybeNoneLowering, ThrowLowering, SelectLowering,
               UnpackLowering>(converter, ctx);
  patterns.add<SwitchConversion>(converter, ctx, /*benefit=*/2);
  patterns.add<ExceptionMakeLowering>(converter, ctx, tags);
  populateFunctionOpInterfaceTypeConversionPattern<func::FuncOp>(patterns,
                                                                 converter);
  populateCallOpTypeConversionPattern(patterns, converter);
  populateReturnOpTypeConversionPattern(patterns, converter);
  // Unlike populateBranchOpInterfaceTypeConversionPattern, these patterns
  // support 1:N conversions.
  cf::populateCFStructuralTypeConversionsAndLegality(converter, patterns,
                                                     target);
  if (failed(applyPartialConversion(module, target, std::move(patterns))))
    return signalPassFailure();

  // The declarations and the attributes naming them have no use left.
  module.walk([](Operation *op) {
    op->removeAttr(MonadDialect::kMayThrowAttrName);
    if (isa<MonadExceptionDeclareOp>(op))
      op->erase();
  });
}
