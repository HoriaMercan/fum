add_mlir_dialect_library(MLIRMonadTransforms
  ConvertMonadToADT.cpp

  ADDITIONAL_HEADER_DIRS
  ${PROJECT_SOURCE_DIR}/include/

  DEPENDS
  MLIRMonadPassesIncGen

  LINK_LIBS PUBLIC
  MLIRADTDialect
  MLIRControlFlowDialect
  MLIRControlFlowTransforms
  MLIRFuncDialect
  MLIRFuncTransforms
  MLIRMonadDialect
  MLIRPass
  MLIRTransforms
  )
