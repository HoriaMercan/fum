set(LIBS
    MLIRArithDialect
    MLIRControlFlowDialect
    MLIROptLib
    MLIRRegisterAllDialects
    MLIRRegisterAllPasses
    MLIRDepDialect
    MLIRDepInterfaces
    MLIRDepTransforms
    MLIRMonadDialect
    MLIRMonadTransforms
    MLIRTransformDialect
    MLIRUBDialect
  )
add_llvm_executable(fum-opt fum-opt.cpp)

llvm_update_compile_flags(fum-opt)
target_link_libraries(fum-opt PRIVATE ${LIBS})

mlir_check_all_link_libraries(fum-opt)
