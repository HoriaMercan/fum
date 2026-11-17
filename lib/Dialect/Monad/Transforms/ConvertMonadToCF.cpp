//===- ConvertMonadToCF.cpp - Lower the monad dialect to cf -----*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// The lowering runs in two steps:
//
// 1. Control flow. Every `monad.do` is inlined into the enclosing region,
//    outer first, like the `scf.execute_region` lowering: the region blocks
//    are moved before a new exit block whose argument replaces the result.
//    The terminators `monad.yield`, `monad.bind`, `monad.either.catch`, and
//    `monad.either.branch` become `cf` branches. Their operands are still
//    monadic values: the lowered values are read from and packed into
//    monadic values with `builtin.unrealized_conversion_cast`.
// 2. Types. A dialect conversion expands every monadic value into several
//    values (a 1:N type conversion), lowers the remaining monad operations,
//    and updates functions, calls, and branches with the upstream patterns.
//    The casts of step 1 then cancel out.
//
//===----------------------------------------------------------------------===//

#include "fum/Dialect/Monad/Transforms/Passes.h"

#include "fum/Dialect/Monad/IR/MonadDialect.h"
#include "fum/Dialect/Monad/IR/MonadOps.h"
#include "fum/Dialect/Monad/IR/MonadTypes.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/ControlFlow/Transforms/StructuralTypeConversions.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/Func/Transforms/FuncConversions.h"
#include "mlir/Transforms/DialectConversion.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/ADT/StringSet.h"

namespace mlir {
namespace monad {
#define GEN_PASS_DEF_CONVERTMONADTOCFPASS
#include "fum/Dialect/Monad/Transforms/Passes.h.inc"
} // namespace monad
} // namespace mlir

using namespace mlir;
using namespace mlir::monad;

//===----------------------------------------------------------------------===//
// Layout of lowered values
//===----------------------------------------------------------------------===//

/// Returns the tag of the error named `name`: its FNV-1a 32-bit hash, masked
/// to a positive value so that it differs from the tag 0 of a right.
static int32_t getErrorTag(StringRef name) {
  uint32_t hash = 2166136261u;
  for (char character : name) {
    hash ^= static_cast<uint8_t>(character);
    hash *= 16777619u;
  }
  hash &= 0x7fffffffu;
  return hash == 0 ? 1 : static_cast<int32_t>(hash);
}

/// Appends the lowered types of `type` to `results`.
static void convertMonadType(Type type, SmallVectorImpl<Type> &results);

/// Appends the lowered types of every type of `types` to `results`.
static void convertMonadTypes(TypeRange types, SmallVectorImpl<Type> &results) {
  for (Type type : types)
    convertMonadType(type, results);
}

/// Appends the payload slots of every error of `errors` to `results`.
static void convertPayloadSlots(ErrorUnionType errors,
                                SmallVectorImpl<Type> &results) {
  for (ErrorType error : errors.getErrors())
    convertMonadTypes(error.getPayloadTypes(), results);
}

static void convertMonadType(Type type, SmallVectorImpl<Type> &results) {
  MLIRContext *context = type.getContext();
  if (MaybeType maybe = dyn_cast<MaybeType>(type)) {
    results.push_back(IntegerType::get(context, 1));
    convertMonadTypes(maybe.getValueTypes(), results);
  } else if (ErrorType error = dyn_cast<ErrorType>(type)) {
    convertMonadTypes(error.getPayloadTypes(), results);
  } else if (ErrorUnionType errors = dyn_cast<ErrorUnionType>(type)) {
    results.push_back(IntegerType::get(context, 32));
    convertPayloadSlots(errors, results);
  } else if (EitherType either = dyn_cast<EitherType>(type)) {
    if (ErrorUnionType errors = either.getErrorUnion()) {
      results.push_back(IntegerType::get(context, 32));
      convertMonadTypes(either.getValueTypes(), results);
      convertPayloadSlots(errors, results);
    } else {
      results.push_back(IntegerType::get(context, 1));
      convertMonadType(either.getLeftType(), results);
      convertMonadTypes(either.getValueTypes(), results);
    }
  } else {
    results.push_back(type);
  }
}

/// Returns the lowered types of `types`.
static SmallVector<Type> getLoweredTypes(TypeRange types) {
  SmallVector<Type> results;
  convertMonadTypes(types, results);
  return results;
}

/// Returns `ub.poison` values of the lowered types of `types`.
static SmallVector<Value> createPoison(OpBuilder &builder, Location loc,
                                       TypeRange types) {
  SmallVector<Value> values;
  for (Type type : getLoweredTypes(types))
    values.push_back(ub::PoisonOp::create(builder, loc, type));
  return values;
}

/// Returns the `i32` constant `value`.
static Value createI32(OpBuilder &builder, Location loc, int32_t value) {
  return arith::ConstantIntOp::create(builder, loc, value, 32);
}

/// Returns the payload slots of the union `to` filled from the payload slots
/// `slots` of the union `from`: the slots of an error of both unions are
/// copied, and the other slots are poison.
static SmallVector<Value> remapPayloadSlots(OpBuilder &builder, Location loc,
                                            ErrorUnionType from,
                                            ValueRange slots,
                                            ErrorUnionType to) {
  llvm::StringMap<ValueRange> slotsByName;
  for (ErrorType error : from.getErrors()) {
    size_t size = getLoweredTypes(error.getPayloadTypes()).size();
    slotsByName[error.getName().getValue()] = slots.take_front(size);
    slots = slots.drop_front(size);
  }
  SmallVector<Value> results;
  for (ErrorType error : to.getErrors()) {
    auto it = slotsByName.find(error.getName().getValue());
    if (it != slotsByName.end())
      llvm::append_range(results, it->second);
    else
      llvm::append_range(results,
                         createPoison(builder, loc, error.getPayloadTypes()));
  }
  return results;
}

/// Returns the payload slots of the union `errors` holding `payload` in the
/// slots of `error` and poison elsewhere.
static SmallVector<Value> createPayloadSlots(OpBuilder &builder, Location loc,
                                             ErrorUnionType errors,
                                             ErrorType error,
                                             ValueRange payload) {
  SmallVector<Value> results;
  for (ErrorType member : errors.getErrors()) {
    if (member == error)
      llvm::append_range(results, payload);
    else
      llvm::append_range(results,
                         createPoison(builder, loc, member.getPayloadTypes()));
  }
  return results;
}

/// Splits `values`, the lowered values of `types`, into one range per type.
static SmallVector<ValueRange> splitLoweredValues(TypeRange types,
                                                  ValueRange values) {
  SmallVector<ValueRange> ranges;
  for (Type type : types) {
    size_t size = getLoweredTypes(type).size();
    ranges.push_back(values.take_front(size));
    values = values.drop_front(size);
  }
  return ranges;
}

//===----------------------------------------------------------------------===//
// Step 1: control flow
//===----------------------------------------------------------------------===//

/// Returns the lowered values of `value`, read with a cast if its type is
/// lowered to other types.
static SmallVector<Value> unpack(OpBuilder &builder, Location loc,
                                 Value value) {
  SmallVector<Type> types = getLoweredTypes(value.getType());
  if (types.size() == 1 && types.front() == value.getType())
    return {value};
  if (types.empty())
    return {};
  return llvm::to_vector_of<Value>(
      UnrealizedConversionCastOp::create(builder, loc, types, value)
          .getResults());
}

/// Returns a value of type `type` whose lowered values are `values`, packed
/// with a cast if the type is lowered to other types.
static Value pack(OpBuilder &builder, Location loc, Type type,
                  ValueRange values) {
  if (values.size() == 1 && values.front().getType() == type)
    return values.front();
  return UnrealizedConversionCastOp::create(builder, loc, type, values)
      .getResult(0);
}

/// Returns one value of each type of `types` whose lowered values are
/// `values`.
static SmallVector<Value> packEach(OpBuilder &builder, Location loc,
                                   TypeRange types, ValueRange values) {
  SmallVector<Value> results;
  for (auto [type, range] :
       llvm::zip_equal(types, splitLoweredValues(types, values)))
    results.push_back(pack(builder, loc, type, range));
  return results;
}

/// The lowered values of an either value whose left type is an error union.
struct ThrowingParts {
  /// The tag: 0 for a right, the tag of the error otherwise.
  Value tag;
  /// The lowered values of the right.
  ValueRange values;
  /// The payload slots of the errors.
  ValueRange slots;
};

/// Splits the lowered values `lowered` of an either value of type `type`
/// whose left type is an error union.
static ThrowingParts splitThrowing(EitherType type, ValueRange lowered) {
  size_t valueCount = getLoweredTypes(type.getValueTypes()).size();
  return {lowered.front(), lowered.slice(1, valueCount),
          lowered.drop_front(1 + valueCount)};
}

/// The lowered values of an either value whose left type is not an error
/// union.
struct GeneralParts {
  /// Set for a left.
  Value isLeft;
  /// The lowered values of the left.
  ValueRange left;
  /// The lowered values of the right.
  ValueRange values;
};

/// Splits the lowered values `lowered` of an either value of type `type`
/// whose left type is not an error union.
static GeneralParts splitGeneral(EitherType type, ValueRange lowered) {
  size_t leftCount = getLoweredTypes(type.getLeftType()).size();
  return {lowered.front(), lowered.slice(1, leftCount),
          lowered.drop_front(1 + leftCount)};
}

/// Lowers `monad.bind %m, ^next` in a `monad.do` producing `doType` and
/// ending in `exit`: a right continues in `^next`, anything else ends the
/// computation with the same left (or `none`).
static void lowerBind(MonadBindOp bind, Block *exit, Type doType) {
  OpBuilder builder(bind);
  Location loc = bind.getLoc();
  Type inputType = bind.getInput().getType();
  SmallVector<Value> lowered = unpack(builder, loc, bind.getInput());
  TypeRange doValueTypes = cast<MonadTypeInterface>(doType).getValueTypes();
  Block *next = bind.getNext();
  TypeRange valueTypes = cast<MonadTypeInterface>(inputType).getValueTypes();

  if (isa<MaybeType>(inputType)) {
    SmallVector<Value> none{lowered.front()};
    llvm::append_range(none, createPoison(builder, loc, doValueTypes));
    cf::CondBranchOp::create(
        builder, loc, lowered.front(), next,
        packEach(builder, loc, valueTypes, ValueRange(lowered).drop_front()),
        exit, pack(builder, loc, doType, none));
  } else if (EitherType either = dyn_cast<EitherType>(inputType);
             either.getErrorUnion()) {
    ThrowingParts parts = splitThrowing(either, lowered);
    SmallVector<Value> failure{parts.tag};
    llvm::append_range(failure, createPoison(builder, loc, doValueTypes));
    llvm::append_range(failure, parts.slots);
    Value isRight =
        arith::CmpIOp::create(builder, loc, arith::CmpIPredicate::eq, parts.tag,
                              createI32(builder, loc, 0));
    cf::CondBranchOp::create(builder, loc, isRight, next,
                             packEach(builder, loc, valueTypes, parts.values),
                             exit, pack(builder, loc, doType, failure));
  } else {
    GeneralParts parts = splitGeneral(either, lowered);
    SmallVector<Value> left{parts.isLeft};
    llvm::append_range(left, parts.left);
    llvm::append_range(left, createPoison(builder, loc, doValueTypes));
    cf::CondBranchOp::create(builder, loc, parts.isLeft, exit,
                             pack(builder, loc, doType, left), next,
                             packEach(builder, loc, valueTypes, parts.values));
  }
  bind.erase();
}

/// Lowers `monad.either.catch` in a `monad.do` producing `doType` and ending in
/// `exit` to one `cf.switch` on the tag.
static void lowerCatch(MonadEitherCatchOp catchOp, Block *exit,
                       EitherType doType) {
  OpBuilder builder(catchOp);
  Location loc = catchOp.getLoc();
  EitherType inputType = catchOp.getInput().getType();
  ErrorUnionType inputErrors = inputType.getErrorUnion();
  SmallVector<Value> lowered = unpack(builder, loc, catchOp.getInput());
  ThrowingParts parts = splitThrowing(inputType, lowered);

  // An uncaught error ends the computation with the same error.
  SmallVector<Value> uncaught{parts.tag};
  llvm::append_range(uncaught,
                     createPoison(builder, loc, doType.getValueTypes()));
  llvm::append_range(uncaught,
                     remapPayloadSlots(builder, loc, inputErrors, parts.slots,
                                       doType.getErrorUnion()));
  Value defaultOperand = pack(builder, loc, doType, uncaught);

  // A right continues in ^ok, or ends the computation with the input.
  SmallVector<int32_t> caseValues{0};
  SmallVector<Block *> caseDests;
  SmallVector<SmallVector<Value>> caseOperands;
  if (Block *ok = catchOp.getOk()) {
    caseDests.push_back(ok);
    caseOperands.push_back(
        packEach(builder, loc, inputType.getValueTypes(), parts.values));
  } else {
    caseDests.push_back(exit);
    caseOperands.push_back({catchOp.getInput()});
  }

  // Every error of a case goes to the handler with the error, or the group.
  for (auto [caseType, handler] :
       llvm::zip_equal(catchOp.getCaseTypes().getAsValueRange<TypeAttr>(),
                       catchOp.getHandlers())) {
    if (ErrorType error = dyn_cast<ErrorType>(caseType)) {
      SmallVector<Value> payload =
          remapPayloadSlots(builder, loc, inputErrors, parts.slots,
                            ErrorUnionType::get(builder.getContext(), {error}));
      caseValues.push_back(getErrorTag(error.getName().getValue()));
      caseDests.push_back(handler);
      caseOperands.push_back({pack(builder, loc, error, payload)});
      continue;
    }
    ErrorUnionType group = cast<ErrorUnionType>(caseType);
    SmallVector<Value> groupValues{parts.tag};
    llvm::append_range(groupValues, remapPayloadSlots(builder, loc, inputErrors,
                                                      parts.slots, group));
    Value groupValue = pack(builder, loc, group, groupValues);
    for (ErrorType error : group.getErrors()) {
      caseValues.push_back(getErrorTag(error.getName().getValue()));
      caseDests.push_back(handler);
      caseOperands.push_back({groupValue});
    }
  }

  SmallVector<ValueRange> caseOperandRanges(caseOperands.begin(),
                                            caseOperands.end());
  cf::SwitchOp::create(builder, loc, parts.tag, exit, defaultOperand,
                       caseValues, caseDests, caseOperandRanges);
  catchOp.erase();
}

/// Lowers `monad.either.branch` to a conditional branch.
static void lowerEitherBranch(MonadEitherBranchOp branch) {
  OpBuilder builder(branch);
  Location loc = branch.getLoc();
  EitherType type = branch.getInput().getType();
  SmallVector<Value> lowered = unpack(builder, loc, branch.getInput());
  if (ErrorUnionType errors = type.getErrorUnion()) {
    ThrowingParts parts = splitThrowing(type, lowered);
    SmallVector<Value> errorValues{parts.tag};
    llvm::append_range(errorValues, parts.slots);
    Value isRight =
        arith::CmpIOp::create(builder, loc, arith::CmpIPredicate::eq, parts.tag,
                              createI32(builder, loc, 0));
    cf::CondBranchOp::create(
        builder, loc, isRight, branch.getRight(),
        packEach(builder, loc, type.getValueTypes(), parts.values),
        branch.getLeft(), pack(builder, loc, errors, errorValues));
  } else {
    GeneralParts parts = splitGeneral(type, lowered);
    cf::CondBranchOp::create(
        builder, loc, parts.isLeft, branch.getLeft(),
        pack(builder, loc, type.getLeftType(), parts.left), branch.getRight(),
        packEach(builder, loc, type.getValueTypes(), parts.values));
  }
  branch.erase();
}

/// Inlines `doOp` into the enclosing region and lowers the terminators of its
/// blocks. The blocks of nested `monad.do` operations are left as they are.
static void lowerDo(MonadDoOp doOp) {
  Location loc = doOp.getLoc();
  Type doType = doOp.getType();
  Block *before = doOp->getBlock();
  Block *exit = before->splitBlock(std::next(doOp->getIterator()));
  doOp.getResult().replaceAllUsesWith(exit->addArgument(doType, loc));

  Region &body = doOp.getBody();
  Block *entry = &body.front();
  for (Block &block : body) {
    Operation *terminator = block.getTerminator();
    if (MonadYieldOp yield = dyn_cast<MonadYieldOp>(terminator)) {
      OpBuilder builder(yield);
      cf::BranchOp::create(builder, yield.getLoc(), exit, yield.getValue());
      yield.erase();
    } else if (MonadBindOp bind = dyn_cast<MonadBindOp>(terminator)) {
      lowerBind(bind, exit, doType);
    } else if (MonadEitherCatchOp catchOp =
                   dyn_cast<MonadEitherCatchOp>(terminator)) {
      lowerCatch(catchOp, exit, cast<EitherType>(doType));
    }
  }
  exit->getParent()->getBlocks().splice(exit->getIterator(), body.getBlocks());
  OpBuilder builder = OpBuilder::atBlockEnd(before);
  cf::BranchOp::create(builder, loc, entry);
  doOp.erase();
}

//===----------------------------------------------------------------------===//
// Step 2: types
//===----------------------------------------------------------------------===//

namespace {
/// Lowers `monad.return` to the lowered values of a right (or `some`).
struct ReturnLowering : public OpConversionPattern<MonadReturnOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Builds the flag or tag, the values, and poison for the other slots.
  LogicalResult
  matchAndRewrite(MonadReturnOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    Location loc = op.getLoc();
    Type type = op.getType();
    SmallVector<Value> values;
    for (ValueRange range : adaptor.getValues())
      llvm::append_range(values, range);
    SmallVector<Value> results;
    if (isa<MaybeType>(type)) {
      results.push_back(arith::ConstantIntOp::create(rewriter, loc, 1, 1));
      llvm::append_range(results, values);
    } else if (ErrorUnionType errors = cast<EitherType>(type).getErrorUnion()) {
      results.push_back(createI32(rewriter, loc, 0));
      llvm::append_range(results, values);
      SmallVector<Type> slotTypes;
      convertPayloadSlots(errors, slotTypes);
      llvm::append_range(results, createPoison(rewriter, loc, slotTypes));
    } else {
      results.push_back(arith::ConstantIntOp::create(rewriter, loc, 0, 1));
      llvm::append_range(
          results,
          createPoison(rewriter, loc, cast<EitherType>(type).getLeftType()));
      llvm::append_range(results, values);
    }
    rewriter.replaceOpWithMultiple(op, {results});
    return success();
  }
};

/// Lowers `monad.maybe.none` to a cleared flag and poison values.
struct MaybeNoneLowering : public OpConversionPattern<MonadMaybeNoneOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Builds the cleared flag and poison values.
  LogicalResult
  matchAndRewrite(MonadMaybeNoneOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    Location loc = op.getLoc();
    SmallVector<Value> results{
        arith::ConstantIntOp::create(rewriter, loc, 0, 1)};
    llvm::append_range(
        results, createPoison(rewriter, loc, op.getType().getValueTypes()));
    rewriter.replaceOpWithMultiple(op, {results});
    return success();
  }
};

/// Lowers `monad.either.left` to a set flag, the left value, and poison.
struct EitherLeftLowering : public OpConversionPattern<MonadEitherLeftOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Builds the set flag, the left value, and poison values.
  LogicalResult
  matchAndRewrite(MonadEitherLeftOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    Location loc = op.getLoc();
    EitherType type = op.getType();
    SmallVector<Value> results;
    ValueRange left = adaptor.getValue();
    if (type.getErrorUnion()) {
      // The lowered error union is a tag followed by the payload slots.
      results.push_back(left.front());
      llvm::append_range(results,
                         createPoison(rewriter, loc, type.getValueTypes()));
      llvm::append_range(results, left.drop_front());
    } else {
      results.push_back(arith::ConstantIntOp::create(rewriter, loc, 1, 1));
      llvm::append_range(results, left);
      llvm::append_range(results,
                         createPoison(rewriter, loc, type.getValueTypes()));
    }
    rewriter.replaceOpWithMultiple(op, {results});
    return success();
  }
};

/// Lowers `monad.either.throw` to the tag of the error, poison values, and the
/// payload in the slots of the error.
struct ThrowLowering : public OpConversionPattern<MonadEitherThrowOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Builds the tag, poison values, and the payload slots.
  LogicalResult
  matchAndRewrite(MonadEitherThrowOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    Location loc = op.getLoc();
    EitherType type = op.getType();
    ErrorType error = op.getError().getType();
    SmallVector<Value> results{
        createI32(rewriter, loc, getErrorTag(error.getName().getValue()))};
    llvm::append_range(results,
                       createPoison(rewriter, loc, type.getValueTypes()));
    llvm::append_range(results,
                       createPayloadSlots(rewriter, loc, type.getErrorUnion(),
                                          error, adaptor.getError()));
    rewriter.replaceOpWithMultiple(op, {results});
    return success();
  }
};

/// Lowers `monad.error.make` to its payload.
struct ErrorMakeLowering : public OpConversionPattern<MonadErrorMakeOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Replaces the error with its payload values.
  LogicalResult
  matchAndRewrite(MonadErrorMakeOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    SmallVector<Value> results;
    for (ValueRange range : adaptor.getPayload())
      llvm::append_range(results, range);
    rewriter.replaceOpWithMultiple(op, {results});
    return success();
  }
};

/// Lowers `monad.error.payload` to the lowered values of the error.
struct ErrorPayloadLowering : public OpConversionPattern<MonadErrorPayloadOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Replaces each payload value with its lowered values.
  LogicalResult
  matchAndRewrite(MonadErrorPayloadOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    rewriter.replaceOpWithMultiple(
        op,
        ArrayRef<ValueRange>(splitLoweredValues(
            op.getError().getType().getPayloadTypes(), adaptor.getError())));
    return success();
  }
};

/// Lowers `monad.either.widen` by moving the payload slots to those of the
/// larger union.
struct WidenLowering : public OpConversionPattern<MonadEitherWidenOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Keeps the tag and the values and remaps the payload slots.
  LogicalResult
  matchAndRewrite(MonadEitherWidenOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    EitherType inputType = op.getInput().getType();
    ThrowingParts parts = splitThrowing(inputType, adaptor.getInput());
    SmallVector<Value> results{parts.tag};
    llvm::append_range(results, parts.values);
    llvm::append_range(results,
                       remapPayloadSlots(rewriter, op.getLoc(),
                                         inputType.getErrorUnion(), parts.slots,
                                         op.getType().getErrorUnion()));
    rewriter.replaceOpWithMultiple(op, {results});
    return success();
  }
};

/// Lowers `arith.select` of a value whose type is lowered to several values
/// to one `arith.select` per lowered value.
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

/// Removes the casts of step 1 between monadic values and their lowered
/// values, which the conversion makes redundant.
struct CastLowering : public OpConversionPattern<UnrealizedConversionCastOp> {
  using OpConversionPattern::OpConversionPattern;

  /// Replaces the results with the lowered values of the inputs.
  LogicalResult
  matchAndRewrite(UnrealizedConversionCastOp op, OneToNOpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    SmallVector<Value> inputs;
    for (ValueRange range : adaptor.getInputs())
      llvm::append_range(inputs, range);
    SmallVector<Type> resultTypes;
    if (failed(getTypeConverter()->convertTypes(op.getResultTypes(),
                                                resultTypes)) ||
        TypeRange(inputs) != TypeRange(resultTypes))
      return failure();
    rewriter.replaceOpWithMultiple(op, ArrayRef<ValueRange>(splitLoweredValues(
                                           op.getResultTypes(), inputs)));
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
    /// Returns the lowered values of the given operand groups, flattened.
    auto flatten = [](ArrayRef<ValueRange> groups) {
      SmallVector<Value> values;
      for (ValueRange group : groups)
        llvm::append_range(values, group);
      return values;
    };
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

/// Lowers monadic computations to control flow.
struct ConvertMonadToCFPass
    : public monad::impl::ConvertMonadToCFPassBase<ConvertMonadToCFPass> {
  /// Checks the error tags, lowers the control flow, then the types.
  void runOnOperation() override {
    ModuleOp module = getOperation();
    if (failed(checkErrorTags(module)))
      return signalPassFailure();

    SmallVector<MonadDoOp> doOps;
    module.walk<WalkOrder::PreOrder>(
        [&](MonadDoOp doOp) { doOps.push_back(doOp); });
    for (MonadDoOp doOp : doOps)
      lowerDo(doOp);
    module.walk([](MonadEitherBranchOp branch) { lowerEitherBranch(branch); });

    TypeConverter converter;
    converter.addConversion([](Type type) { return type; });
    converter.addConversion(
        [](Type type,
           SmallVectorImpl<Type> &results) -> std::optional<LogicalResult> {
          if (!isa<MonadDialect>(type.getDialect()))
            return std::nullopt;
          convertMonadType(type, results);
          return success();
        });

    ConversionTarget target(getContext());
    target.addIllegalDialect<MonadDialect>();
    target.markUnknownOpDynamicallyLegal([&](Operation *op) {
      if (FunctionOpInterface function = dyn_cast<FunctionOpInterface>(op))
        return converter.isSignatureLegal(
            cast<FunctionType>(function.getFunctionType()));
      return converter.isLegal(op);
    });

    RewritePatternSet patterns(&getContext());
    patterns.add<ReturnLowering, MaybeNoneLowering, EitherLeftLowering,
                 ThrowLowering, ErrorMakeLowering, ErrorPayloadLowering,
                 WidenLowering, SelectLowering, CastLowering>(converter,
                                                              &getContext());
    patterns.add<SwitchLowering>(converter, &getContext(), /*benefit=*/2);
    populateFunctionOpInterfaceTypeConversionPattern<func::FuncOp>(patterns,
                                                                   converter);
    populateCallOpTypeConversionPattern(patterns, converter);
    populateReturnOpTypeConversionPattern(patterns, converter);
    cf::populateCFStructuralTypeConversions(converter, patterns);
    if (failed(applyPartialConversion(module, target, std::move(patterns))))
      return signalPassFailure();
  }

  /// Fails if two errors of the module have the same tag.
  LogicalResult checkErrorTags(ModuleOp module) {
    llvm::StringSet<> names;
    auto collect = [&](ErrorType error) {
      names.insert(error.getName().getValue());
    };
    module.walk([&](Operation *op) {
      for (Type type : op->getOperandTypes())
        type.walk(collect);
      for (Type type : op->getResultTypes())
        type.walk(collect);
      op->getAttrDictionary().walk(collect);
      for (Region &region : op->getRegions())
        for (Block &block : region)
          for (Type type : block.getArgumentTypes())
            type.walk(collect);
    });
    DenseMap<int32_t, StringRef> nameByTag;
    for (StringRef name : names.keys()) {
      auto [it, inserted] = nameByTag.try_emplace(getErrorTag(name), name);
      if (!inserted)
        return module.emitError()
               << "errors \"" << it->second << "\" and \"" << name
               << "\" have the same tag " << it->first;
    }
    return success();
  }
};
} // namespace
