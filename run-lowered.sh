#!/usr/bin/env bash
# Lowers test/Monad/lower-to-adt.mlir with fum-opt --convert-monad-to-adt and
# --convert-adt-to-scf, then to LLVM IR, and runs its @main with lli. @main
# returns 0 if every check passes, and otherwise the number of the first
# failing check.
set -euo pipefail
cd "$(dirname "$0")"
BIN=/home/horia/Desktop/Facultate/master/mlir-dist/mlir_wheel/bin
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

build/bin/fum-opt --convert-monad-to-adt --convert-adt-to-scf test/Monad/lower-to-adt.mlir -o "$OUT/cf.mlir"
"$BIN/mlir-opt" "$OUT/cf.mlir" --convert-scf-to-cf --convert-to-llvm \
  --reconcile-unrealized-casts -o "$OUT/llvm.mlir"
"$BIN/mlir-translate" --mlir-to-llvmir "$OUT/llvm.mlir" -o "$OUT/main.ll"
set +e
lli -opaque-pointers "$OUT/main.ll"
status=$?
set -e
echo "@main returned $status"
exit "$status"
