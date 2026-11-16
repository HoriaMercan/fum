#!/usr/bin/env bash
# Lowers test/Monad/lower-to-cf.mlir to LLVM IR and runs its @main, which
# returns 0 if every check passes, else the number of the first failing check.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${MLIR_BIN:-$root/../../mlir-dist/mlir_wheel/bin}"
fum_opt="${FUM_OPT:-$root/build/bin/fum-opt}"

"$fum_opt" --convert-monad-to-cf "$root/test/Monad/lower-to-cf.mlir" |
  "$bin/mlir-opt" --convert-scf-to-cf --convert-to-llvm \
    --reconcile-unrealized-casts |
  "$bin/mlir-translate" --mlir-to-llvmir |
  lli -opaque-pointers && status=0 || status=$?

if [ "$status" -eq 0 ]; then
  echo "all 10 checks passed"
else
  echo "check $status failed"
fi
exit "$status"
