//===- CheckMayThrow.cpp - Check monad.may_throw annotations ----*- C++ -*-===//
//
// This file is licensed under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Every value of type `!monad.exception` or `!monad.value_or_exception` gets
// the set of exception kinds it may hold: the kind of the exception, or the
// kind of the exception of a failure. The set is computed on demand from the
// operation or the block that defines the value. A call takes the
// `monad.may_throw` of its callee, or, for a callee without one, a summary
// computed from the callee's body, iterated to a fixpoint over the calls.
// A value whose kinds cannot be followed may hold any kind.
//
//===----------------------------------------------------------------------===//

#include "fum/Dialect/Monad/Transforms/Passes.h"

#include "fum/Dialect/Monad/IR/MonadDialect.h"
#include "fum/Dialect/Monad/IR/MonadOps.h"
#include "fum/Dialect/Monad/IR/MonadTypes.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/IR/SymbolTable.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/MapVector.h"
#include "llvm/ADT/StringSet.h"

#include <optional>
#include <string>

namespace mlir {
namespace monad {
#define GEN_PASS_DEF_CHECKMAYTHROWPASS
#include "fum/Dialect/Monad/Transforms/Passes.h.inc"
} // namespace monad
} // namespace mlir

using namespace mlir;
using namespace mlir::monad;

namespace {
/// The exception kinds that a value may hold.
struct KindSet {
  /// Each kind, with the location of an operation that may introduce it.
  llvm::MapVector<StringAttr, Location> kinds;
  /// Set if any kind may occur: the location and a description of the first
  /// value whose kinds cannot be followed.
  std::optional<std::pair<Location, std::string>> unknown;

  /// Returns the set of any kind, introduced by `what` at `loc`.
  static KindSet getUnknown(Location loc, const Twine &what) {
    KindSet set;
    set.unknown = {loc, what.str()};
    return set;
  }

  /// Adds the kinds of `other`, and returns whether this set changed.
  bool join(const KindSet &other) {
    bool changed = false;
    for (auto [kind, loc] : other.kinds)
      changed |= kinds.insert({kind, loc}).second;
    if (other.unknown && !unknown) {
      unknown = other.unknown;
      changed = true;
    }
    return changed;
  }
};

/// Computes the exception kinds of values and of the results of functions.
class KindAnalysis {
public:
  /// Creates the analysis of the functions of `module`.
  explicit KindAnalysis(ModuleOp module) : symbolTable(module) {}

  /// Returns the kinds that the results of the body of `function` may hold.
  KindSet getBodyKinds(func::FuncOp function) {
    KindSet set;
    for (Block &block : function.getBody())
      if (func::ReturnOp ret = dyn_cast<func::ReturnOp>(block.getTerminator()))
        for (Value operand : ret.getOperands())
          if (isTracked(operand.getType()))
            set.join(getKinds(operand));
    return set;
  }

  /// Computes the summaries of the functions without `monad.may_throw` that
  /// have a body, iterating until no summary changes.
  void computeSummaries(ModuleOp module) {
    bool changed = true;
    while (changed) {
      changed = false;
      cache.clear();
      for (func::FuncOp function : module.getOps<func::FuncOp>())
        if (!function.isExternal() && !getDeclaredKinds(function))
          changed |= summaries[function].join(getBodyKinds(function));
    }
    cache.clear();
  }

  /// Returns the `monad.may_throw` attribute of `function`, or null.
  static ArrayAttr getDeclaredKinds(func::FuncOp function) {
    return function->getAttrOfType<ArrayAttr>(MonadDialect::kMayThrowAttrName);
  }

private:
  /// Returns whether values of `type` hold exception kinds.
  static bool isTracked(Type type) {
    return isa<ExceptionType, ValueOrExceptionType>(type);
  }

  /// Returns the kinds that `value` may hold.
  KindSet getKinds(Value value) {
    auto it = cache.find(value);
    if (it != cache.end())
      return it->second;
    KindSet set = computeKinds(value);
    cache.try_emplace(value, set);
    return set;
  }

  /// Computes the kinds that `value` may hold from its definition.
  KindSet computeKinds(Value value) {
    if (BlockArgument argument = dyn_cast<BlockArgument>(value))
      return computeArgumentKinds(argument);
    Operation *op = value.getDefiningOp();
    if (MonadExceptionMakeOp make = dyn_cast<MonadExceptionMakeOp>(op)) {
      KindSet set;
      set.kinds.insert({make.getKindAttr().getAttr(), make.getLoc()});
      return set;
    }
    if (MonadThrowOp throwOp = dyn_cast<MonadThrowOp>(op))
      return getKinds(throwOp.getException());
    if (isa<MonadReturnOp>(op))
      return KindSet();
    if (arith::SelectOp select = dyn_cast<arith::SelectOp>(op)) {
      KindSet set = getKinds(select.getTrueValue());
      set.join(getKinds(select.getFalseValue()));
      return set;
    }
    if (func::CallOp call = dyn_cast<func::CallOp>(op))
      return getCallKinds(call);
    if (MonadDoOp doOp = dyn_cast<MonadDoOp>(op))
      return getDoKinds(doOp);
    return KindSet::getUnknown(
        op->getLoc(), "the result of '" + op->getName().getStringRef() + "'");
  }

  /// Computes the kinds of a block argument: the argument of the default
  /// successor of a `monad.catch` holds the kinds that no case lists.
  KindSet computeArgumentKinds(BlockArgument argument) {
    Block *block = argument.getOwner();
    if (block->isEntryBlock() && isa<func::FuncOp>(block->getParentOp()))
      return KindSet::getUnknown(argument.getLoc(), "this function argument");
    if (Block *predecessor = block->getUniquePredecessor())
      if (MonadCatchOp catchOp =
              dyn_cast<MonadCatchOp>(predecessor->getTerminator()))
        if (catchOp.getDefaultDest() == block)
          return getUnlistedKinds(catchOp);
    return KindSet::getUnknown(argument.getLoc(), "this block argument");
  }

  /// Returns the kinds of the input of `catchOp` that none of its cases
  /// lists.
  KindSet getUnlistedKinds(MonadCatchOp catchOp) {
    llvm::StringSet<> listed;
    for (Attribute group : catchOp.getCaseKinds())
      for (Attribute kind : cast<ArrayAttr>(group))
        listed.insert(cast<FlatSymbolRefAttr>(kind).getValue());
    KindSet input = getKinds(catchOp.getInput());
    KindSet set;
    set.unknown = input.unknown;
    for (auto [kind, loc] : input.kinds)
      if (!listed.contains(kind.getValue()))
        set.kinds.insert({kind, loc});
    return set;
  }

  /// Returns the kinds of the failures with which `doOp` may end: the failures
  /// that its yields, binds, and catches without a default case let out.
  KindSet getDoKinds(MonadDoOp doOp) {
    KindSet set;
    for (Block &block : doOp.getBody()) {
      Operation *terminator = block.getTerminator();
      if (MonadYieldOp yield = dyn_cast<MonadYieldOp>(terminator))
        set.join(getKinds(yield.getValue()));
      else if (MonadBindOp bind = dyn_cast<MonadBindOp>(terminator))
        set.join(getKinds(bind.getInput()));
      else if (MonadCatchOp catchOp = dyn_cast<MonadCatchOp>(terminator))
        if (!catchOp.getDefaultDest())
          set.join(getUnlistedKinds(catchOp));
    }
    return set;
  }

  /// Returns the kinds of the results of `call`: the `monad.may_throw` of the
  /// callee if it has one, and otherwise the summary of its body.
  KindSet getCallKinds(func::CallOp call) {
    func::FuncOp callee =
        symbolTable.lookup<func::FuncOp>(call.getCalleeAttr().getAttr());
    if (!callee)
      return KindSet::getUnknown(call.getLoc(), "this call");
    if (ArrayAttr declared = getDeclaredKinds(callee)) {
      KindSet set;
      for (Attribute kind : declared)
        set.kinds.insert(
            {cast<FlatSymbolRefAttr>(kind).getAttr(), call.getLoc()});
      return set;
    }
    if (callee.isExternal())
      return KindSet::getUnknown(call.getLoc(),
                                 "this call to an external function without " +
                                     MonadDialect::kMayThrowAttrName);
    return summaries[callee];
  }

  /// The functions of the module.
  SymbolTable symbolTable;
  /// The kinds of the values computed so far.
  llvm::DenseMap<Value, KindSet> cache;
  /// The kinds of the results of the functions without `monad.may_throw`.
  llvm::DenseMap<Operation *, KindSet> summaries;
};

/// Checks that every function lists in `monad.may_throw` all the exception
/// kinds that its results may hold.
struct CheckMayThrowPass
    : public monad::impl::CheckMayThrowPassBase<CheckMayThrowPass> {
  /// Computes the summaries, then checks every annotated function.
  void runOnOperation() override {
    ModuleOp module = getOperation();
    KindAnalysis analysis(module);
    analysis.computeSummaries(module);
    bool failed = false;
    for (func::FuncOp function : module.getOps<func::FuncOp>()) {
      ArrayAttr declared = KindAnalysis::getDeclaredKinds(function);
      if (!declared || function.isExternal())
        continue;
      if (::mlir::failed(checkFunction(function, declared,
                                       analysis.getBodyKinds(function))))
        failed = true;
    }
    if (failed)
      signalPassFailure();
  }

  /// Checks the kinds `kinds` of the results of `function` against its
  /// declared kinds `declared`, with one error per kind that is not declared.
  static LogicalResult checkFunction(func::FuncOp function, ArrayAttr declared,
                                     const KindSet &kinds) {
    if (kinds.unknown) {
      InFlightDiagnostic diagnostic =
          function.emitError()
          << "expects the exception kinds that the function may throw to be "
             "known, to check "
          << MonadDialect::kMayThrowAttrName;
      diagnostic.attachNote(kinds.unknown->first)
          << "the exception kinds of " << kinds.unknown->second
          << " are unknown";
      return failure();
    }
    llvm::StringSet<> listed;
    for (Attribute kind : declared)
      listed.insert(cast<FlatSymbolRefAttr>(kind).getValue());
    LogicalResult result = success();
    for (auto [kind, loc] : kinds.kinds) {
      if (listed.contains(kind.getValue()))
        continue;
      FlatSymbolRefAttr kindRef = FlatSymbolRefAttr::get(kind);
      InFlightDiagnostic diagnostic =
          function.emitError()
          << "expects " << MonadDialect::kMayThrowAttrName << " to list "
          << kindRef << ", which the function may throw";
      diagnostic.attachNote(loc) << kindRef << " may be thrown here";
      result = failure();
    }
    return result;
  }
};
} // namespace
