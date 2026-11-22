add_mlir_dialect_library(MLIRADTTransforms
  ConvertADTToSCF.cpp

  ADDITIONAL_HEADER_DIRS
  ${PROJECT_SOURCE_DIR}/include/

  DEPENDS
  MLIRADTPassesIncGen

  LINK_LIBS PUBLIC
  MLIRADTDialect
  MLIRArithDialect
  MLIRControlFlowDialect
  MLIRControlFlowTransforms
  MLIRFuncDialect
  MLIRFuncTransforms
  MLIRPass
  MLIRSCFDialect
  MLIRSCFTransforms
  MLIRTransforms
  MLIRUBDialect
  )
