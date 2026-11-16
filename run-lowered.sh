#!/usr/bin/env bash
# Lowers test/Monad/lower-to-cf.mlir with fum-opt, compiles it to LLVM IR and
# runs its @main, which returns 0 when every check passes and otherwise the
# number of the first failing check.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN=/home/horia/Desktop/Facultate/master/mlir-dist/mlir_wheel/bin
FUM_OPT="${FUM_OPT:-$ROOT/build/bin/fum-opt}"

set +e
"$FUM_OPT" --convert-monad-to-cf "$ROOT/test/Monad/lower-to-cf.mlir" |
  "$BIN/mlir-opt" --convert-scf-to-cf --convert-to-llvm \
    --reconcile-unrealized-casts |
  "$BIN/mlir-translate" --mlir-to-llvmir |
  lli -opaque-pointers
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "run-lowered: all checks passed"
else
  echo "run-lowered: check $status failed"
fi
exit "$status"
