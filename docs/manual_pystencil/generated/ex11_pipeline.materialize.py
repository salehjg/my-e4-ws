from pystencils.backend.transformations import (
    MaterializeAxes, ReductionsToMemory, EliminateConstants)

kernel_ast = MaterializeAxes(ctx)(kernel_ast)      # loops, pragmas, vectorized body
kernel_ast = ReductionsToMemory(ctx, ctx.reduction_data.values())(kernel_ast)
kernel_ast = canonicalize(kernel_ast)
kernel_ast = EliminateConstants(ctx, extract_constant_exprs=True)(kernel_ast)
