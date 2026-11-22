//===- ConvertMonadToADT.cpp - Lower monads to sum types --------*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// A monadic type is the sum of its constructors: a maybe is `just` or
// `nothing`, an either is `left` or `right`. The lowering runs in two steps.
// The first inlines every `monad.do` and turns `monad.bind` and
// `monad.either.branch` into `adt.switch`, crossing between a monadic value
// and its sum with `unrealized_conversion_cast`. The second converts every
// type and the constructors, which makes the casts redundant.
//
//===----------------------------------------------------------------------===//

#include "fum/Dialect/Monad/Transforms/Passes.h"

#include "fum/Dialect/ADT/IR/ADTOps.h"
#include "fum/Dialect/ADT/IR/ADTTypes.h"
#include "fum/Dialect/Monad/IR/MonadDialect.h"
#include "fum/Dialect/Monad/IR/MonadOps.h"
#include "fum/Dialect/Monad/IR/MonadTypes.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/ControlFlow/Transforms/StructuralTypeConversions.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/Func/Transforms/FuncConversions.h"
#include "mlir/Interfaces/FunctionInterfaces.h"
#include "mlir/Transforms/DialectConversion.h"

namespace mlir {
namespace monad {
#define GEN_PASS_DEF_CONVERTMONADTOADTPASS
#include "fum/Dialect/Monad/Transforms/Passes.h.inc"
} // namespace monad
} // namespace mlir

using namespace mlir;
using namespace mlir::monad;

namespace {
/// The case of a maybe that carries the values.
constexpr StringLiteral kJust = "just";
/// The case of a maybe that carries nothing.
constexpr StringLiteral kNothing = "nothing";
/// The case of an either that carries the left value.
constexpr StringLiteral kLeft = "left";
/// The case of an either that carries the values.
constexpr StringLiteral kRight = "right";

/// A case of a sum under construction, owning its field types.
struct CaseSpec {
  /// The name of the case.
  StringRef name;
  /// The types of the fields of the case.
  SmallVector<Type> fields;
};

/// Returns the sum of the cases `cases`.
adt::SumType getSum(MLIRContext *context, ArrayRef<CaseSpec> cases) {
  SmallVector<adt::SumCase> sumCases;
  for (const CaseSpec &spec : cases)
    sumCases.push_back({StringAttr::get(context, spec.name), spec.fields});
  return adt::SumType::get(context, sumCases);
}

Type convertType(Type type);

/// Returns the converted types of `types`.
SmallVector<Type> convertTypes(TypeRange types) {
  return llvm::map_to_vector(types, convertType);
}

/// Returns the left type of `either` converted, if it is a sum that the
/// either is merged with: a sum without a case named `right`.
adt::SumType getMergedLeft(EitherType either) {
  adt::SumType left = dyn_cast<adt::SumType>(convertType(either.getLeftType()));
  if (!left || left.lookupCase(kRight))
    return nullptr;
  return left;
}

/// Returns the type that `type` lowers to: a monadic type becomes the sum of
/// its constructors, a sum gets its field types converted, and any other
/// type is kept.
Type convertType(Type type) {
  MLIRContext *context = type.getContext();
  if (MaybeType maybe = dyn_cast<MaybeType>(type))
    return getSum(context, {{kJust, convertTypes(maybe.getValueTypes())},
                            {kNothing, {}}});
  if (EitherType either = dyn_cast<EitherType>(type)) {
    SmallVector<Type> right = convertTypes(either.getValueTypes());
    if (adt::SumType left = getMergedLeft(either)) {
      SmallVector<CaseSpec> cases;
      for (const adt::SumCase &sumCase : left.getCases())
        cases.push_back(
            {sumCase.name.getValue(), llvm::to_vector(sumCase.fields)});
      cases.push_back({kRight, right});
      return getSum(context, cases);
    }
    return getSum(context, {{kLeft, {convertType(either.getLeftType())}},
                            {kRight, right}});
  }
  if (adt::SumType sum = dyn_cast<adt::SumType>(type)) {
    SmallVector<CaseSpec> cases;
    for (const adt::SumCase &sumCase : sum.getCases())
      cases.push_back({sumCase.name.getValue(), convertTypes(sumCase.fields)});
    return getSum(context, cases);
  }
  return type;
}

/// Returns the case of the sum of `type` that carries the values.
StringRef getSuccessCase(Type type) {
  return isa<MaybeType>(type) ? kJust : kRight;
}

/// Returns `value` cast to `type`; the second step removes the cast.
Value castTo(OpBuilder &builder, Location loc, Value value, Type type) {
  if (value.getType() == type)
    return value;
  return UnrealizedConversionCastOp::create(builder, loc, type, value)
      .getResult(0);
}

//===----------------------------------------------------------------------===//
// Step 1: control flow
//===----------------------------------------------------------------------===//

/// Replaces `bind`, in a block of the inlined body of a `monad.do` of type
/// `doType` whose result is the argument of `exit`, with an `adt.switch` on
/// the sum of its input: the success case continues in the successor of the
/// bind; every other case ends the `monad.do`, rebuilt in its sum, or as is
/// if both sums agree. The blocks that end the `monad.do` follow the block of
/// the bind.
void lowerBind(MonadBindOp bind, Block *exit, Type doType) {
  OpBuilder builder(bind);
  Location loc = bind.getLoc();
  Type inputType = bind.getInput().getType();
  adt::SumType inputSum = cast<adt::SumType>(convertType(inputType));
  adt::SumType doSum = cast<adt::SumType>(convertType(doType));
  StringRef success = getSuccessCase(inputType);
  Value input = castTo(builder, loc, bind.getInput(), inputSum);

  SmallVector<Attribute> names = {builder.getStringAttr(success)};
  SmallVector<Block *> destinations = {bind.getNext()};
  Block *after = bind->getBlock()->getNextNode();
  if (inputSum == doSum) {
    Block *propagate = builder.createBlock(after);
    cf::BranchOp::create(builder, loc, exit, bind.getInput());
    destinations.push_back(propagate);
  } else {
    for (const adt::SumCase &sumCase : inputSum.getCases()) {
      if (sumCase.name.getValue() == success)
        continue;
      SmallVector<Location> locations(sumCase.fields.size(), loc);
      Block *rebuild = builder.createBlock(after, sumCase.fields, locations);
      Value failure = adt::MakeOp::create(builder, loc, doSum, sumCase.name,
                                          rebuild->getArguments());
      cf::BranchOp::create(builder, loc, exit,
                           castTo(builder, loc, failure, doType));
      names.push_back(sumCase.name);
      destinations.push_back(rebuild);
    }
  }
  builder.setInsertionPoint(bind);
  adt::SwitchOp::create(builder, loc, input, builder.getArrayAttr(names),
                        destinations);
  bind.erase();
}

/// Replaces `branch` with an `adt.switch` on the sum of its input. For a
/// merged sum, every case of the left type is rebuilt in the left type
/// before branching to the left successor.
void lowerEitherBranch(MonadEitherBranchOp branch) {
  OpBuilder builder(branch);
  Location loc = branch.getLoc();
  EitherType type = branch.getInput().getType();
  adt::SumType sum = cast<adt::SumType>(convertType(type));
  Value input = castTo(builder, loc, branch.getInput(), sum);

  SmallVector<Attribute> names = {builder.getStringAttr(kRight)};
  SmallVector<Block *> destinations = {branch.getRight()};
  if (adt::SumType left = getMergedLeft(type)) {
    Region *region = branch->getBlock()->getParent();
    Region::iterator after = std::next(branch->getBlock()->getIterator());
    for (const adt::SumCase &sumCase : left.getCases()) {
      SmallVector<Location> locations(sumCase.fields.size(), loc);
      Block *rebuild =
          builder.createBlock(region, after, sumCase.fields, locations);
      Value error = adt::MakeOp::create(builder, loc, left, sumCase.name,
                                        rebuild->getArguments());
      cf::BranchOp::create(builder, loc, branch.getLeft(),
                           castTo(builder, loc, error, type.getLeftType()));
      names.push_back(sumCase.name);
      destinations.push_back(rebuild);
    }
  } else {
    names.push_back(builder.getStringAttr(kLeft));
    destinations.push_back(branch.getLeft());
  }
  builder.setInsertionPoint(branch);
  adt::SwitchOp::create(builder, loc, input, builder.getArrayAttr(names),
                        destinations);
  branch.erase();
}

/// Inlines the body of `doOp` into the enclosing region: a new block after
/// the operation receives the result, every yield branches to it, and every
/// bind becomes a switch.
LogicalResult lowerDo(MonadDoOp doOp) {
  Operation *parent = doOp->getParentOp();
  if (parent->hasTrait<OpTrait::SingleBlock>() || isa<adt::MatchOp>(parent))
    return doOp.emitOpError()
           << "cannot be lowered in a region that takes a single block";
  Location loc = doOp.getLoc();
  Type doType = doOp.getType();
  Block *before = doOp->getBlock();
  Block *exit = before->splitBlock(std::next(doOp->getIterator()));
  doOp.getResult().replaceAllUsesWith(exit->addArgument(doType, loc));

  Region &body = doOp.getBody();
  Block *entry = &body.front();
  SmallVector<Block *> blocks =
      llvm::map_to_vector(body, [](Block &block) { return &block; });
  exit->getParent()->getBlocks().splice(exit->getIterator(), body.getBlocks());
  for (Block *block : blocks) {
    Operation *terminator = block->getTerminator();
    if (MonadYieldOp yield = dyn_cast<MonadYieldOp>(terminator)) {
      OpBuilder builder(yield);
      cf::BranchOp::create(builder, yield.getLoc(), exit, yield.getValue());
      yield.erase();
    } else if (MonadBindOp bind = dyn_cast<MonadBindOp>(terminator)) {
      lowerBind(bind, exit, doType);
    }
  }
  OpBuilder builder = OpBuilder::atBlockEnd(before);
  cf::BranchOp::create(builder, loc, entry);
  doOp.erase();
  return success();
}

//===----------------------------------------------------------------------===//
// Step 2: types and constructors
//===----------------------------------------------------------------------===//

/// Lowers `monad.return` to `adt.make` of the success case.
struct ReturnLowering : public OpConversionPattern<MonadReturnOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Builds the success case with the values.
  LogicalResult
  matchAndRewrite(MonadReturnOp op, OpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    rewriter.replaceOpWithNewOp<adt::MakeOp>(
        op, convertType(op.getType()),
        rewriter.getStringAttr(getSuccessCase(op.getType())),
        adaptor.getValues());
    return success();
  }
};

/// Lowers `monad.maybe.none` to `adt.make` of `nothing`.
struct MaybeNoneLowering : public OpConversionPattern<MonadMaybeNoneOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Builds `nothing`.
  LogicalResult
  matchAndRewrite(MonadMaybeNoneOp op, OpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    rewriter.replaceOpWithNewOp<adt::MakeOp>(op, convertType(op.getType()),
                                             rewriter.getStringAttr(kNothing),
                                             ValueRange());
    return success();
  }
};

/// Lowers `monad.either.left` to `adt.make` of `left`, or, for a merged sum,
/// to `adt.widen` of the left value, whose case is kept.
struct EitherLeftLowering : public OpConversionPattern<MonadEitherLeftOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Builds the left.
  LogicalResult
  matchAndRewrite(MonadEitherLeftOp op, OpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    Type sum = convertType(op.getType());
    if (getMergedLeft(op.getType()))
      rewriter.replaceOpWithNewOp<adt::WidenOp>(op, sum, adaptor.getValue());
    else
      rewriter.replaceOpWithNewOp<adt::MakeOp>(
          op, sum, rewriter.getStringAttr(kLeft), adaptor.getValue());
    return success();
  }
};

/// Removes the casts of step 1, whose input and result have the same
/// converted type.
struct CastLowering : public OpConversionPattern<UnrealizedConversionCastOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Replaces the result with the converted input.
  LogicalResult
  matchAndRewrite(UnrealizedConversionCastOp op, OpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    if (op.getNumOperands() != 1 || op.getNumResults() != 1 ||
        adaptor.getInputs().front().getType() !=
            convertType(op.getResult(0).getType()))
      return failure();
    rewriter.replaceOp(op, adaptor.getInputs());
    return success();
  }
};

/// Rebuilds any other operation with converted operand, result, region
/// argument, and successor argument types, keeping its name, properties,
/// and attributes.
struct GenericTypeConversion : public ConversionPattern {
  /// Matches any operation, with a lower benefit than the specific patterns.
  GenericTypeConversion(const TypeConverter &converter, MLIRContext *context)
      : ConversionPattern(converter, MatchAnyOpTypeTag(), /*benefit=*/0,
                          context) {}

  /// Rebuilds `op`.
  LogicalResult
  matchAndRewrite(Operation *op, ArrayRef<Value> operands,
                  ConversionPatternRewriter &rewriter) const override {
    if (isa<FunctionOpInterface>(op))
      return failure();
    SmallVector<Type> resultTypes;
    if (failed(getTypeConverter()->convertTypes(op->getResultTypes(),
                                                resultTypes)))
      return failure();
    SmallVector<Block *> successors;
    for (Block *successor : op->getSuccessors()) {
      std::optional<TypeConverter::SignatureConversion> conversion =
          getTypeConverter()->convertBlockSignature(successor);
      successors.push_back(conversion
                               ? rewriter.applySignatureConversion(
                                     successor, *conversion, getTypeConverter())
                               : successor);
    }
    OperationState state(
        op->getLoc(), op->getName().getStringRef(), operands, resultTypes,
        llvm::to_vector(op->getDiscardableAttrs()), successors);
    state.propertiesAttr = op->getPropertiesAsAttribute();
    for (Region &region : op->getRegions()) {
      Region *converted = state.addRegion();
      rewriter.inlineRegionBefore(region, *converted, converted->end());
      if (failed(rewriter.convertRegionTypes(converted, *getTypeConverter())))
        return failure();
    }
    rewriter.replaceOp(op, rewriter.create(state)->getResults());
    return success();
  }
};

/// Lowers monadic computations to sum types and control flow.
struct ConvertMonadToADTPass
    : public monad::impl::ConvertMonadToADTPassBase<ConvertMonadToADTPass> {
  /// Lowers the control flow, then the types.
  void runOnOperation() override {
    ModuleOp module = getOperation();
    SmallVector<MonadDoOp> doOps;
    module.walk<WalkOrder::PreOrder>(
        [&](MonadDoOp doOp) { doOps.push_back(doOp); });
    for (MonadDoOp doOp : doOps)
      if (failed(lowerDo(doOp)))
        return signalPassFailure();
    SmallVector<MonadEitherBranchOp> branches;
    module.walk(
        [&](MonadEitherBranchOp branch) { branches.push_back(branch); });
    for (MonadEitherBranchOp branch : branches)
      lowerEitherBranch(branch);

    TypeConverter converter;
    converter.addConversion([](Type type) { return convertType(type); });

    ConversionTarget target(getContext());
    target.addIllegalDialect<MonadDialect>();
    target.markUnknownOpDynamicallyLegal([&](Operation *op) {
      if (FunctionOpInterface function = dyn_cast<FunctionOpInterface>(op))
        return converter.isSignatureLegal(
            cast<FunctionType>(function.getFunctionType()));
      if (!converter.isLegal(op))
        return false;
      if (!llvm::all_of(op->getRegions(), [&](Region &region) {
            return converter.isLegal(&region);
          }))
        return false;
      return llvm::all_of(op->getSuccessors(), [&](Block *successor) {
        return converter.isLegal(successor->getArgumentTypes());
      });
    });

    RewritePatternSet patterns(&getContext());
    patterns.add<ReturnLowering, MaybeNoneLowering, EitherLeftLowering,
                 CastLowering, GenericTypeConversion>(converter, &getContext());
    populateFunctionOpInterfaceTypeConversionPattern<func::FuncOp>(patterns,
                                                                   converter);
    populateCallOpTypeConversionPattern(patterns, converter);
    populateReturnOpTypeConversionPattern(patterns, converter);
    cf::populateCFStructuralTypeConversions(converter, patterns);
    if (failed(applyPartialConversion(module, target, std::move(patterns))))
      signalPassFailure();
  }
};
} // namespace
