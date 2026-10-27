// RUN: fum-opt %s | fum-opt | FileCheck %s

// The transform script of the Transform dialect tutorial
// (mlir/test/Examples/transform/Ch1/sequence.mlir) written with the maybe
// monad.

// Pair of handles produced by most transform operations.
!pair = tuple<!transform.any_op, !transform.any_op>
// Handles to the outlined function and to the call to it.
!outlined = tuple<!transform.any_op, !transform.op<"func.call">>

// Models of the transform operations used by the script.
func.func private @split_handle(!transform.op<"linalg.elementwise">)
    -> !monad.maybe<!pair>
func.func private @tile_using_forall(!transform.any_op) -> !monad.maybe<!pair>
func.func private @fuse_into_containing_op(!transform.any_op, !transform.any_op)
    -> !monad.maybe<!pair>
func.func private @loop_outline(!transform.any_op) -> !monad.maybe<!outlined>

// Projections of a pair of handles.
func.func private @first(!pair) -> !transform.any_op
func.func private @second(!pair) -> !transform.any_op

// CHECK-LABEL: func.func @__transform_main
// CHECK-SAME: -> !monad.maybe<tuple<!transform.any_op, !transform.op<"func.call">>>
// CHECK: %[[SPLIT:.+]] = call @split_handle
// CHECK: %[[RESULT:.+]] = monad.maybe.bind %[[SPLIT]]
// CHECK: func.call @tile_using_forall(%{{.*}}) {tile_sizes = array<i64: 8, 32>}
// CHECK: monad.maybe.bind
// CHECK: func.call @fuse_into_containing_op
// CHECK: monad.maybe.bind
// CHECK: transform.cast %{{.*}} : !transform.op<"linalg.matmul"> to !transform.any_op
// CHECK: func.call @fuse_into_containing_op
// CHECK: monad.maybe.bind
// CHECK: func.call @tile_using_forall(%{{.*}}) {tile_sizes = array<i64: 4, 4>}
// CHECK: monad.maybe.bind
// CHECK: func.call @fuse_into_containing_op
// CHECK: monad.maybe.bind
// CHECK: func.call @tile_using_forall(%{{.*}}) {tile_sizes = array<i64: 1>}
// CHECK: monad.maybe.bind
// CHECK: func.call @fuse_into_containing_op
// CHECK: monad.maybe.bind
// CHECK: %[[OUTLINED:.+]] = func.call @loop_outline(%{{.*}}) {func_name = "outlined"}
// CHECK-NEXT: monad.yield %[[OUTLINED]]
// CHECK: return %[[RESULT]]
func.func @__transform_main(%arg0: !transform.any_op,
                            %arg1: !transform.op<"linalg.matmul">,
                            %arg2: !transform.op<"linalg.elementwise">)
    -> !monad.maybe<!outlined> {
  // %add, %max = transform.split_handle %arg2
  %split = func.call @split_handle(%arg2)
      : (!transform.op<"linalg.elementwise">) -> !monad.maybe<!pair>
  %result = monad.maybe.bind %split
      : !monad.maybe<!pair> -> !monad.maybe<!outlined> {
  ^bb0(%add_max: !pair):
    %add = func.call @first(%add_max) : (!pair) -> !transform.any_op
    %max = func.call @second(%add_max) : (!pair) -> !transform.any_op
    // %tiled, %loop = transform.structured.tile_using_forall %max
    //     tile_sizes [8, 32]
    %tile = func.call @tile_using_forall(%max) {tile_sizes = array<i64: 8, 32>}
        : (!transform.any_op) -> !monad.maybe<!pair>
    %after_tile = monad.maybe.bind %tile
        : !monad.maybe<!pair> -> !monad.maybe<!outlined> {
    ^bb0(%tiled_loop: !pair):
      %loop = func.call @second(%tiled_loop) : (!pair) -> !transform.any_op
      // %add_fused, %loop2 = transform.structured.fuse_into_containing_op
      //     %add into %loop
      %fuse_add = func.call @fuse_into_containing_op(%add, %loop)
          : (!transform.any_op, !transform.any_op) -> !monad.maybe<!pair>
      %after_fuse_add = monad.maybe.bind %fuse_add
          : !monad.maybe<!pair> -> !monad.maybe<!outlined> {
      ^bb0(%add_fused_loop2: !pair):
        %add_fused = func.call @first(%add_fused_loop2)
            : (!pair) -> !transform.any_op
        %loop2 = func.call @second(%add_fused_loop2)
            : (!pair) -> !transform.any_op
        // %matmul_fused, %loop3 = transform.structured.fuse_into_containing_op
        //     %arg1 into %loop2
        %matmul = transform.cast %arg1
            : !transform.op<"linalg.matmul"> to !transform.any_op
        %fuse_matmul = func.call @fuse_into_containing_op(%matmul, %loop2)
            : (!transform.any_op, !transform.any_op) -> !monad.maybe<!pair>
        %after_fuse_matmul = monad.maybe.bind %fuse_matmul
            : !monad.maybe<!pair> -> !monad.maybe<!outlined> {
        ^bb0(%matmul_fused_loop3: !pair):
          %matmul_fused = func.call @first(%matmul_fused_loop3)
              : (!pair) -> !transform.any_op
          // %tiled_second, %loop_second =
          //     transform.structured.tile_using_forall %add_fused
          //     tile_sizes [4, 4]
          %tile_second = func.call @tile_using_forall(%add_fused)
              {tile_sizes = array<i64: 4, 4>}
              : (!transform.any_op) -> !monad.maybe<!pair>
          %after_tile_second = monad.maybe.bind %tile_second
              : !monad.maybe<!pair> -> !monad.maybe<!outlined> {
          ^bb0(%tiled_loop_second: !pair):
            %tiled_second = func.call @first(%tiled_loop_second)
                : (!pair) -> !transform.any_op
            %loop_second = func.call @second(%tiled_loop_second)
                : (!pair) -> !transform.any_op
            // %matmul_fused_2, %loop_second_2 =
            //     transform.structured.fuse_into_containing_op
            //     %matmul_fused into %loop_second
            %fuse_second = func.call @fuse_into_containing_op(%matmul_fused,
                                                              %loop_second)
                : (!transform.any_op, !transform.any_op) -> !monad.maybe<!pair>
            %after_fuse_second = monad.maybe.bind %fuse_second
                : !monad.maybe<!pair> -> !monad.maybe<!outlined> {
            ^bb0(%matmul_fused_loop_second_2: !pair):
              %matmul_fused_2 = func.call @first(%matmul_fused_loop_second_2)
                  : (!pair) -> !transform.any_op
              // %_0, %loop_third = transform.structured.tile_using_forall
              //     %tiled_second tile_sizes [1]
              %tile_third = func.call @tile_using_forall(%tiled_second)
                  {tile_sizes = array<i64: 1>}
                  : (!transform.any_op) -> !monad.maybe<!pair>
              %after_tile_third = monad.maybe.bind %tile_third
                  : !monad.maybe<!pair> -> !monad.maybe<!outlined> {
              ^bb0(%tiled_loop_third: !pair):
                %loop_third = func.call @second(%tiled_loop_third)
                    : (!pair) -> !transform.any_op
                // %_1, %outline_target =
                //     transform.structured.fuse_into_containing_op
                //     %matmul_fused_2 into %loop_third
                %fuse_third = func.call @fuse_into_containing_op(
                    %matmul_fused_2, %loop_third)
                    : (!transform.any_op, !transform.any_op)
                    -> !monad.maybe<!pair>
                %after_fuse_third = monad.maybe.bind %fuse_third
                    : !monad.maybe<!pair> -> !monad.maybe<!outlined> {
                ^bb0(%fused_outline_target: !pair):
                  %outline_target = func.call @second(%fused_outline_target)
                      : (!pair) -> !transform.any_op
                  // %func, %call = transform.loop.outline %outline_target
                  //     func_name = "outlined"
                  %outlined = func.call @loop_outline(%outline_target)
                      {func_name = "outlined"}
                      : (!transform.any_op) -> !monad.maybe<!outlined>
                  monad.yield %outlined : !monad.maybe<!outlined>
                }
                monad.yield %after_fuse_third : !monad.maybe<!outlined>
              }
              monad.yield %after_tile_third : !monad.maybe<!outlined>
            }
            monad.yield %after_fuse_second : !monad.maybe<!outlined>
          }
          monad.yield %after_tile_second : !monad.maybe<!outlined>
        }
        monad.yield %after_fuse_matmul : !monad.maybe<!outlined>
      }
      monad.yield %after_fuse_add : !monad.maybe<!outlined>
    }
    monad.yield %after_tile : !monad.maybe<!outlined>
  }
  return %result : !monad.maybe<!outlined>
}
