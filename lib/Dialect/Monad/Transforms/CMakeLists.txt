add_mlir_dialect_library(MLIRMonadTransforms
  CheckMayThrow.cpp
  ConvertMonadToCF.cpp

  ADDITIONAL_HEADER_DIRS
  ${PROJECT_SOURCE_DIR}/include/

  DEPENDS
  MLIRMonadPassesIncGen

  LINK_LIBS PUBLIC
  MLIRArithDialect
  MLIRControlFlowDialect
  MLIRControlFlowTransforms
  MLIRFuncDialect
  MLIRFuncTransforms
  MLIRMonadDialect
  MLIRPass
  MLIRTransforms
  MLIRUBDialect
  )
