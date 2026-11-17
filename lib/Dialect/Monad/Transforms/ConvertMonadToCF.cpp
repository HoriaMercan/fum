//===- ConvertMonadToCF.cpp - Lower the monad dialect to cf -----*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// The lowering runs in two steps. The first step inlines every `monad.do` and
// expands every monad operation in place, keeping the monadic types: a
// monadic value is taken apart into its components ("unpacked") and built from
// components ("packed") with `builtin.unrealized_conversion_cast` operations
// whose component types are the converted types of the monadic type. The
// second step converts the monadic types 1:N in function signatures, calls,
// returns, branches (with their successor blocks) and selects, with the
// upstream type conversion patterns for functions and `cf`, and local patterns
// for `cf.switch` and `arith.select`.
// The packs and unpacks then cancel out with the casts materialized by the
// conversion and are removed by reconciling the casts.
//
//===----------------------------------------------------------------------===//

#include "fum/Dialect/Monad/Transforms/Passes.h"

#include "fum/Dialect/Monad/IR/MonadDialect.h"
#include "fum/Dialect/Monad/IR/MonadOps.h"
#include "fum/Dialect/Monad/IR/MonadTypes.h"

#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/ControlFlow/Transforms/StructuralTypeConversions.h"
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

/// The tags of the errors of the module, by error name, from their
/// declarations; the tag 0 is a success.
using ErrorTags = llvm::DenseMap<StringAttr, int32_t>;

/// Returns the types of the payload slots of the given errors, in order.
static SmallVector<Type> getPayloadSlotTypes(ArrayRef<ErrorType> errors) {
  SmallVector<Type> types;
  for (ErrorType error : errors)
    llvm::append_range(types, error.getPayload());
  return types;
}

namespace {

/// Converts the monadic types to their components.
struct MonadTypeConverter : public TypeConverter {
  /// Creates the converter with the conversions and cast materializations.
  MonadTypeConverter(MLIRContext *context) {
    Type i1 = IntegerType::get(context, 1);
    Type i32 = IntegerType::get(context, 32);
    addConversion([](Type type) { return type; });
    addConversion([=](MaybeType type, SmallVectorImpl<Type> &results) {
      results.push_back(i1);
      llvm::append_range(results, type.getValueTypes());
      return success();
    });
    addConversion([=](ValueOrErrorType type, SmallVectorImpl<Type> &results) {
      results.push_back(i32);
      llvm::append_range(results, type.getValueTypes());
      llvm::append_range(results, getPayloadSlotTypes(type.getErrors()));
      return success();
    });
    addConversion([](ErrorType type, SmallVectorImpl<Type> &results) {
      llvm::append_range(results, type.getPayload());
      return success();
    });
    addConversion([=](ErrorUnionType type, SmallVectorImpl<Type> &results) {
      results.push_back(i32);
      llvm::append_range(results, getPayloadSlotTypes(type.getErrors()));
      return success();
    });
    addSourceMaterialization([](OpBuilder &builder, Type resultType,
                                ValueRange inputs, Location loc) -> Value {
      return UnrealizedConversionCastOp::create(builder, loc, resultType,
                                                inputs)
          .getResult(0);
    });
    addTargetMaterialization([](OpBuilder &builder, TypeRange resultTypes,
                                ValueRange inputs,
                                Location loc) -> SmallVector<Value> {
      return SmallVector<Value>(
          UnrealizedConversionCastOp::create(builder, loc, resultTypes, inputs)
              .getResults());
    });
  }
};

/// Converts an `arith.select` of a monadic type into one select per
/// component.
struct SelectOpConversion : public OpConversionPattern<arith::SelectOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Selects each component of the converted operands.
  LogicalResult
  matchAndRewrite(arith::SelectOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    ValueRange condition = adaptor.getCondition();
    ValueRange trueValues = adaptor.getTrueValue();
    ValueRange falseValues = adaptor.getFalseValue();
    if (condition.size() != 1 || trueValues.size() != falseValues.size())
      return failure();
    SmallVector<Value> results;
    for (auto [trueValue, falseValue] :
         llvm::zip_equal(trueValues, falseValues))
      results.push_back(arith::SelectOp::create(
          rewriter, op.getLoc(), condition.front(), trueValue, falseValue));
    rewriter.replaceOpWithMultiple(op, {results});
    return success();
  }
};

/// Converts a `cf.switch` whose operands are converted 1:N, and the argument
/// types of its successors. The upstream `cf.switch` pattern supports 1:1
/// conversions only.
struct SwitchOpConversion : public OpConversionPattern<cf::SwitchOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Replaces the switch with one that forwards the converted operands to
  /// the converted successors.
  LogicalResult
  matchAndRewrite(cf::SwitchOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    if (adaptor.getFlag().size() != 1)
      return failure();
    SmallVector<Value> defaultOperands = flatten(adaptor.getDefaultOperands());
    FailureOr<Block *> defaultDest = convertBlock(
        rewriter, op, op.getDefaultDestination(), TypeRange(defaultOperands));
    if (failed(defaultDest))
      return failure();

    SmallVector<Block *> caseDests;
    SmallVector<SmallVector<Value>> caseOperands;
    for (auto [index, dest] : llvm::enumerate(op.getCaseDestinations())) {
      caseOperands.push_back(flatten(adaptor.getCaseOperands()[index]));
      FailureOr<Block *> caseDest =
          convertBlock(rewriter, op, dest, TypeRange(caseOperands.back()));
      if (failed(caseDest))
        return failure();
      caseDests.push_back(*caseDest);
    }
    SmallVector<ValueRange> caseOperandRanges(caseOperands.begin(),
                                              caseOperands.end());
    rewriter.replaceOpWithNewOp<cf::SwitchOp>(
        op, adaptor.getFlag().front(), *defaultDest, defaultOperands,
        op.getCaseValuesAttr(), caseDests, caseOperandRanges);
    return success();
  }

private:
  /// Returns the values of the given ranges in order.
  static SmallVector<Value> flatten(ArrayRef<ValueRange> ranges) {
    SmallVector<Value> values;
    for (ValueRange range : ranges)
      llvm::append_range(values, range);
    return values;
  }

  /// Returns `block` with its argument types converted, failing if they
  /// differ from `expectedTypes`.
  FailureOr<Block *> convertBlock(ConversionPatternRewriter &rewriter,
                                  Operation *op, Block *block,
                                  TypeRange expectedTypes) const {
    if (block->getArgumentTypes() == expectedTypes)
      return block;
    std::optional<TypeConverter::SignatureConversion> conversion =
        getTypeConverter()->convertBlockSignature(block);
    if (!conversion ||
        TypeRange(conversion->getConvertedTypes()) != expectedTypes)
      return rewriter.notifyMatchFailure(op, "cannot convert the successor");
    return rewriter.applySignatureConversion(block, *conversion,
                                             getTypeConverter());
  }
};

/// Expands the monad operations of a module in place, keeping the monadic
/// types (the first step of the lowering).
class MonadExpander {
public:
  /// Creates an expander that unpacks values into the components given by
  /// `converter` and gives errors the tags `tags`.
  MonadExpander(MLIRContext *context, const TypeConverter &converter,
                const ErrorTags &tags)
      : rewriter(context), converter(converter), tags(tags) {}

  /// Inlines every `monad.do` of `module`, outermost first, and then expands
  /// the remaining monad operations.
  void run(ModuleOp module) {
    SmallVector<MonadDoOp> doOps;
    module.walk<WalkOrder::PreOrder>(
        [&](MonadDoOp doOp) { doOps.push_back(doOp); });
    for (MonadDoOp doOp : doOps)
      inlineDo(doOp);

    SmallVector<Operation *> ops;
    module.walk([&](Operation *op) {
      if (isa<MonadReturnOp, MonadMaybeNoneOp, MonadErrorMakeOp,
              MonadErrorPayloadOp, MonadThrowOp, MonadWidenOp>(op))
        ops.push_back(op);
    });
    for (Operation *op : ops)
      expandValueOp(op);
  }

private:
  /// Returns the tag of `error`.
  int32_t getErrorTag(ErrorType error) const {
    return tags.at(error.getSymbol().getAttr());
  }

  /// Returns a constant integer of the given width.
  Value getConstant(Location loc, int64_t value, unsigned width) {
    return arith::ConstantOp::create(
        rewriter, loc,
        rewriter.getIntegerAttr(rewriter.getIntegerType(width), value));
  }

  /// Returns the constant tag of a success.
  Value getSuccessTag(Location loc) { return getConstant(loc, 0, 32); }

  /// Returns one poison value of each of the given types.
  SmallVector<Value> getPoison(Location loc, TypeRange types) {
    SmallVector<Value> values;
    for (Type type : types)
      values.push_back(ub::PoisonOp::create(rewriter, loc, type));
    return values;
  }

  /// Builds a value of the monadic `type` from its components.
  Value pack(Location loc, Type type, ValueRange components) {
    return UnrealizedConversionCastOp::create(rewriter, loc, type, components)
        .getResult(0);
  }

  /// Returns the components of a monadic value.
  SmallVector<Value> unpack(Location loc, Value value) {
    SmallVector<Type> types;
    (void)converter.convertType(value.getType(), types);
    if (types.empty())
      return {};
    return SmallVector<Value>(
        UnrealizedConversionCastOp::create(rewriter, loc, types, value)
            .getResults());
  }

  /// Returns the payload slots of the errors `to`, given the payload slots
  /// `slots` of the errors `from`: the slots of an error in both are copied,
  /// the others are poison.
  SmallVector<Value> remapPayloads(Location loc, ArrayRef<ErrorType> from,
                                   ValueRange slots, ArrayRef<ErrorType> to) {
    SmallVector<Value> result;
    for (ErrorType error : to) {
      size_t offset = 0;
      const ErrorType *found = llvm::find(from, error);
      for (const ErrorType *it = from.begin(); it != found; ++it)
        offset += it->getPayload().size();
      if (found == from.end())
        llvm::append_range(result, getPoison(loc, error.getPayload()));
      else
        llvm::append_range(result,
                           slots.slice(offset, error.getPayload().size()));
    }
    return result;
  }

  /// Builds a failure of `type` with the given tag, poison values, and the
  /// payload slots `slots` of the errors `from`.
  Value packFailure(Location loc, ValueOrErrorType type, Value tag,
                    ArrayRef<ErrorType> from, ValueRange slots) {
    SmallVector<Value> components = {tag};
    llvm::append_range(components, getPoison(loc, type.getValueTypes()));
    llvm::append_range(components,
                       remapPayloads(loc, from, slots, type.getErrors()));
    return pack(loc, type, components);
  }

  /// Inlines `doOp` into its parent block: the region is placed before a new
  /// exit block that takes the result, and its terminators are expanded into
  /// branches.
  void inlineDo(MonadDoOp doOp) {
    Location loc = doOp.getLoc();
    Block *current = doOp->getBlock();
    Block *exit = rewriter.splitBlock(current, std::next(doOp->getIterator()));
    Value result = exit->addArgument(doOp.getType(), loc);

    SmallVector<Operation *> terminators;
    for (Block &block : doOp.getBody())
      terminators.push_back(block.getTerminator());
    Block *entry = &doOp.getBody().front();
    rewriter.inlineRegionBefore(doOp.getBody(), exit);
    rewriter.replaceOp(doOp, result);
    rewriter.mergeBlocks(entry, current);

    for (Operation *terminator : terminators) {
      rewriter.setInsertionPoint(terminator);
      if (auto yieldOp = dyn_cast<MonadYieldOp>(terminator))
        rewriter.replaceOpWithNewOp<cf::BranchOp>(yieldOp, exit,
                                                  yieldOp.getValue());
      else if (auto bindOp = dyn_cast<MonadBindOp>(terminator))
        expandBind(bindOp, exit);
      else if (auto catchOp = dyn_cast<MonadCatchOp>(terminator))
        expandCatch(catchOp, exit);
    }
  }

  /// Expands a bind into a branch to the next block on success and to the
  /// exit block with the failure otherwise.
  void expandBind(MonadBindOp bindOp, Block *exit) {
    Location loc = bindOp.getLoc();
    Type resultType = exit->getArgument(0).getType();
    SmallVector<Value> components = unpack(loc, bindOp.getInput());
    size_t numValues = bindOp.getInput().getType().getValueTypes().size();
    ValueRange values = ValueRange(components).slice(1, numValues);
    Value failure;
    Value failed;
    if (auto maybeType = dyn_cast<MaybeType>(resultType)) {
      SmallVector<Value> none = {getConstant(loc, 0, 1)};
      llvm::append_range(none, getPoison(loc, maybeType.getValueTypes()));
      failure = pack(loc, maybeType, none);
      failed = arith::XOrIOp::create(rewriter, loc, components.front(),
                                     getConstant(loc, 1, 1));
    } else {
      auto valueOrErrorType = cast<ValueOrErrorType>(resultType);
      ValueRange slots = ValueRange(components).drop_front(1 + numValues);
      failure = packFailure(loc, valueOrErrorType, components.front(),
                            valueOrErrorType.getErrors(), slots);
      failed = arith::CmpIOp::create(rewriter, loc, arith::CmpIPredicate::ne,
                                     components.front(), getSuccessTag(loc));
    }
    rewriter.replaceOpWithNewOp<cf::CondBranchOp>(
        bindOp, failed, exit, ValueRange(failure), bindOp.getNext(), values);
  }

  /// Expands a catch into one `cf.switch` on the tag of the input.
  void expandCatch(MonadCatchOp catchOp, Block *exit) {
    Location loc = catchOp.getLoc();
    auto resultType = cast<ValueOrErrorType>(exit->getArgument(0).getType());
    ValueOrErrorType inputType = catchOp.getInput().getType();
    ArrayRef<ErrorType> inputErrors = inputType.getErrors();
    SmallVector<Value> components = unpack(loc, catchOp.getInput());
    Value tag = components.front();
    size_t numValues = inputType.getValueTypes().size();
    ValueRange values = ValueRange(components).slice(1, numValues);
    ValueRange slots = ValueRange(components).drop_front(1 + numValues);

    SmallVector<int32_t> caseValues = {0};
    SmallVector<Block *> caseDests;
    SmallVector<SmallVector<Value>> caseOperands;
    if (Block *ok = catchOp.getOk()) {
      caseDests.push_back(ok);
      caseOperands.push_back(llvm::to_vector(values));
    } else {
      caseDests.push_back(exit);
      caseOperands.push_back({catchOp.getInput()});
    }

    // Adds one switch case per error of `caseType` to `handler`, which takes
    // the error, or the error union, built from the input.
    auto addCase = [&](Type caseType, Block *handler) {
      SmallVector<ErrorType> errors;
      Value error;
      if (auto errorType = dyn_cast<ErrorType>(caseType)) {
        errors.push_back(errorType);
        error = pack(loc, errorType,
                     remapPayloads(loc, inputErrors, slots, errors));
      } else {
        auto unionType = cast<ErrorUnionType>(caseType);
        llvm::append_range(errors, unionType.getErrors());
        SmallVector<Value> unionComponents = {tag};
        llvm::append_range(unionComponents,
                           remapPayloads(loc, inputErrors, slots, errors));
        error = pack(loc, unionType, unionComponents);
      }
      for (ErrorType errorType : errors) {
        caseValues.push_back(getErrorTag(errorType));
        caseDests.push_back(handler);
        caseOperands.push_back({error});
      }
    };
    for (auto [caseAttr, handler] :
         llvm::zip_equal(catchOp.getCases(), catchOp.getCaseHandlers()))
      addCase(cast<TypeAttr>(caseAttr).getValue(), handler);

    SmallVector<ErrorType> unnamed = catchOp.getUnnamedErrors();
    Block *defaultDest;
    SmallVector<Value> defaultOperands;
    if (Block *rest = catchOp.getDefault()) {
      addCase(ErrorUnionType::get(rewriter.getContext(), unnamed), rest);
      defaultDest = createUnreachableBlock(exit);
    } else if (!unnamed.empty()) {
      defaultDest = exit;
      defaultOperands.push_back(
          packFailure(loc, resultType, tag, inputErrors, slots));
    } else {
      defaultDest = createUnreachableBlock(exit);
    }

    rewriter.setInsertionPoint(catchOp);
    SmallVector<ValueRange> caseOperandRanges(caseOperands.begin(),
                                              caseOperands.end());
    cf::SwitchOp::create(rewriter, loc, tag, defaultDest, defaultOperands,
                         caseValues, caseDests, caseOperandRanges);
    rewriter.eraseOp(catchOp);
  }

  /// Creates a block before `before` that ends with `ub.unreachable`.
  Block *createUnreachableBlock(Block *before) {
    OpBuilder::InsertionGuard guard(rewriter);
    Block *block = rewriter.createBlock(before);
    ub::UnreachableOp::create(rewriter, rewriter.getUnknownLoc());
    return block;
  }

  /// Expands an operation that builds or takes apart a monadic value.
  void expandValueOp(Operation *op) {
    Location loc = op->getLoc();
    rewriter.setInsertionPoint(op);
    if (auto returnOp = dyn_cast<MonadReturnOp>(op)) {
      SmallVector<Value> components;
      if (auto maybeType = dyn_cast<MaybeType>(returnOp.getType())) {
        components.push_back(getConstant(loc, 1, 1));
        llvm::append_range(components, returnOp.getValues());
      } else {
        auto valueOrErrorType = cast<ValueOrErrorType>(returnOp.getType());
        components.push_back(getSuccessTag(loc));
        llvm::append_range(components, returnOp.getValues());
        llvm::append_range(
            components,
            getPoison(loc, getPayloadSlotTypes(valueOrErrorType.getErrors())));
      }
      rewriter.replaceOp(op, pack(loc, returnOp.getType(), components));
    } else if (auto noneOp = dyn_cast<MonadMaybeNoneOp>(op)) {
      SmallVector<Value> components = {getConstant(loc, 0, 1)};
      llvm::append_range(components,
                         getPoison(loc, noneOp.getType().getValueTypes()));
      rewriter.replaceOp(op, pack(loc, noneOp.getType(), components));
    } else if (auto makeOp = dyn_cast<MonadErrorMakeOp>(op)) {
      rewriter.replaceOp(op, pack(loc, makeOp.getType(), makeOp.getPayload()));
    } else if (auto payloadOp = dyn_cast<MonadErrorPayloadOp>(op)) {
      rewriter.replaceOp(op, unpack(loc, payloadOp.getError()));
    } else if (auto throwOp = dyn_cast<MonadThrowOp>(op)) {
      SmallVector<Value> components = unpack(loc, throwOp.getError());
      Value tag;
      SmallVector<ErrorType> errors;
      ValueRange slots = components;
      if (auto errorType = dyn_cast<ErrorType>(throwOp.getError().getType())) {
        tag = getConstant(loc, getErrorTag(errorType), 32);
        errors.push_back(errorType);
      } else {
        auto unionType = cast<ErrorUnionType>(throwOp.getError().getType());
        tag = components.front();
        slots = slots.drop_front();
        llvm::append_range(errors, unionType.getErrors());
      }
      rewriter.replaceOp(
          op, packFailure(loc, throwOp.getType(), tag, errors, slots));
    } else if (auto widenOp = dyn_cast<MonadWidenOp>(op)) {
      ValueOrErrorType inputType = widenOp.getInput().getType();
      ValueOrErrorType resultType = widenOp.getType();
      SmallVector<Value> components = unpack(loc, widenOp.getInput());
      size_t numValues = inputType.getValueTypes().size();
      SmallVector<Value> widened(components.begin(),
                                 components.begin() + 1 + numValues);
      llvm::append_range(
          widened,
          remapPayloads(loc, inputType.getErrors(),
                        ValueRange(components).drop_front(1 + numValues),
                        resultType.getErrors()));
      rewriter.replaceOp(op, pack(loc, resultType, widened));
    }
  }

  /// The rewriter used for all changes.
  IRRewriter rewriter;
  /// The converter that gives the components of monadic types.
  const TypeConverter &converter;
  /// The tags of the errors of the module.
  const ErrorTags &tags;
};

/// Lowers the monad dialect to cf, arith and ub.
struct ConvertMonadToCFPass
    : public monad::impl::ConvertMonadToCFPassBase<ConvertMonadToCFPass> {
  /// Checks the types of the module, expands the monad operations, and
  /// converts the monadic types.
  void runOnOperation() override {
    ModuleOp module = getOperation();
    MLIRContext *context = &getContext();
    if (failed(checkTypes(module)))
      return signalPassFailure();

    MonadTypeConverter converter(context);
    ErrorTags tags = getErrorTags(module);
    MonadExpander(context, converter, tags).run(module);

    RewritePatternSet patterns(context);
    populateFunctionOpInterfaceTypeConversionPattern<func::FuncOp>(patterns,
                                                                   converter);
    populateCallOpTypeConversionPattern(patterns, converter);
    populateReturnOpTypeConversionPattern(patterns, converter);
    cf::populateCFStructuralTypeConversions(converter, patterns);
    patterns.add<SelectOpConversion>(converter, context);
    patterns.add<SwitchOpConversion>(converter, context, /*benefit=*/2);

    ConversionTarget target(*context);
    target.addLegalOp<UnrealizedConversionCastOp>();
    target.addIllegalDialect<MonadDialect>();
    target.addLegalOp<MonadErrorDeclareOp>();
    target.addDynamicallyLegalOp<func::FuncOp>([&](func::FuncOp funcOp) {
      return converter.isSignatureLegal(funcOp.getFunctionType());
    });
    target.markUnknownOpDynamicallyLegal(
        [&](Operation *op) { return converter.isLegal(op); });
    if (failed(applyPartialConversion(module, target, std::move(patterns))))
      return signalPassFailure();

    SmallVector<UnrealizedConversionCastOp> casts;
    module.walk(
        [&](UnrealizedConversionCastOp cast) { casts.push_back(cast); });
    reconcileUnrealizedCasts(casts);
    for (MonadErrorDeclareOp declaration :
         llvm::make_early_inc_range(module.getOps<MonadErrorDeclareOp>()))
      declaration.erase();
  }

  /// Rejects monadic value and payload types, and errors without a
  /// declaration with the same payload types. The operations of the monad
  /// dialect verify the errors they use; this also covers other operations,
  /// such as functions, and block arguments.
  LogicalResult checkTypes(ModuleOp module) {
    SymbolTable symbolTable(module);
    WalkResult result = module.walk([&](Operation *op) -> WalkResult {
      LogicalResult status = success();
      auto checkType = [&](Type type) {
        SmallVector<Type> components;
        if (auto maybeType = dyn_cast<MaybeType>(type))
          llvm::append_range(components, maybeType.getValueTypes());
        if (auto valueOrErrorType = dyn_cast<ValueOrErrorType>(type))
          llvm::append_range(components, valueOrErrorType.getValueTypes());
        if (auto errorType = dyn_cast<ErrorType>(type)) {
          llvm::append_range(components, errorType.getPayload());
          MonadErrorDeclareOp declaration =
              symbolTable.lookup<MonadErrorDeclareOp>(errorType.getName());
          if (!declaration ||
              TypeRange(errorType.getPayload()) !=
                  TypeRange(llvm::to_vector(declaration.getPayloadTypes()
                                                .getAsValueRange<TypeAttr>())))
            status = op->emitOpError()
                     << "uses " << errorType << ", which no error of the "
                     << "module declares with these payload types";
        }
        if (llvm::any_of(components, [](Type component) {
              return isa<MonadDialect>(component.getDialect());
            }))
          status = op->emitOpError()
                   << "uses " << type
                   << ", whose lowering with monad-typed components is not "
                      "supported";
      };
      auto walkType = [&](Type type) { type.walk(checkType); };
      llvm::for_each(op->getOperandTypes(), walkType);
      llvm::for_each(op->getResultTypes(), walkType);
      for (Region &region : op->getRegions())
        for (Block &block : region)
          llvm::for_each(block.getArgumentTypes(), walkType);
      op->getAttrDictionary().walk(checkType);
      return failed(status) ? WalkResult::interrupt() : WalkResult::advance();
    });
    return failure(result.wasInterrupted());
  }
};

} // namespace
